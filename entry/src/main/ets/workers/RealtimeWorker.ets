/*
 * **实时通道 Worker**（MQTToT 的连接、心跳、拆帧、解压、JSON 解析全在这条线程上）。
 *
 * ## 为什么要把它搬出主线程
 * 现在（重构前）这一整套都跑在 UI 线程：TLS 收包回调 → 拆帧 → **纯 TS 的 zlib inflate** →
 * JSON.parse。inflate 是这里唯一的重 CPU 活，而私信 `message_sync`（topic 146）的载荷
 * 常常几十 KB 到几百 KB —— 它每次都在 UI 线程上跑，会直接顶掉一两帧。
 * 私信会话、私信列表、通知这些东西越做越实时，这条链路的负载只会更重，所以先把它整体搬走。
 *
 * ## 线程边界（重要）
 * Worker 里**不许碰 AppStorage / UI / 单例上下文**，只有纯计算 + 网络。所以：
 *   · 进来：`{cmd:'start', identity:{…}, keepAlive}` / `{cmd:'stop'}` / `{cmd:'publish', topic, json}`
 *     身份是**纯数据**（MqttIdentity 的字段），由主线程从 MobileSession 拍平后传进来；
 *   · 出去：`{type:'state'|'frame'|'log'}` —— `frame` 带的是**已经解压并转成字符串**的载荷，
 *     主线程拿到就能直接用，不需要再解压（省一道）。
 *
 * ## 为什么不用 TaskPool
 * TaskPool 适合"一来一回的短任务"，而这里是一条**常驻连接**（要长期持有 socket 与心跳定时器），
 * 那种生命周期只有 Worker 撑得住。
 */

import { worker, MessageEvents, ThreadWorkerGlobalScope } from '@kit.ArkTS';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MobileMqtt, MqttIdentity, MqttPacketInfo } from '../core/mobileapi/MobileMqtt';
import { Inflate } from '../core/mobileapi/Inflate';
import { textOf, utf8 } from '../core/mobileapi/MobileSign';
import { WorkerCommand, WorkerEvent, WorkerIdentity } from '../core/mobileapi/RealtimeProtocol';

/** IG 的 iris/MQTToT broker（与主线程那份常量同值，见 core/mobileapi/MobileRealtime）。 */
const HOST: string = 'edge-mqtt.facebook.com';
const PORT: number = 443;
const CONNECT_TIMEOUT_MS: number = 10000;
const CONNACK_WAIT_MS: number = 8000;
/** 心跳：CONNECT 里报 20 秒，这里 12 秒发一次（和主线程那版一致）。 */
const PING_EVERY_MS: number = 12000;
const PING_TIMEOUT_MS: number = 8000;

/** 会带"文本载荷"的 topic（其余只报长度，省得白解析）。 */
const TEXT_TOPICS: Array<string> = ['133', '135', '146', '149', '88', '102'];

class WorkerState {
  sock: socket.TLSSocket | null = null;
  buffer: Array<number> = [];
  connected: boolean = false;
  packetId: number = 0;
  pingTimer: number = 0;
  pingPending: boolean = false;
  pingSentAt: number = 0;
  eventCount: number = 0;
  lastError: string = '';
}

const state: WorkerState = new WorkerState();
const port: ThreadWorkerGlobalScope = worker.workerPort;

/** 往主线程发一条消息（只有这一个出口，方便排查）。 */
function post(message: WorkerEvent): void {
  try {
    port.postMessage(message);
  } catch (error) {
    // 主线程已经退出：这里没法报，静默即可。
  }
}

function log(text: string): void {
  post(WorkerEvent.log(text));
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/** 取一条完整 MQTT 帧（不够一条返回 null，等下一次数据）。 */
function takeFrame(): Uint8Array | null {
  const buf: Array<number> = state.buffer;
  if (buf.length < 2) {
    return null;
  }
  let offset: number = 1;
  let remaining: number = 0;
  let shift: number = 0;
  let complete: boolean = false;
  while (offset < buf.length && shift < 28) {
    const byte: number = buf[offset];
    offset++;
    remaining = remaining | ((byte & 0x7F) << shift);
    shift += 7;
    if ((byte & 0x80) === 0) {
      complete = true;
      break;
    }
  }
  if (!complete) {
    return null;
  }
  const total: number = offset + remaining;
  if (buf.length < total) {
    return null;
  }
  const frame: Uint8Array = new Uint8Array(total);
  for (let index: number = 0; index < total; index++) {
    frame[index] = buf[index];
  }
  state.buffer = buf.slice(total);
  return frame;
}

/** 处理一条报文：CONNACK / PINGRESP / PUBLISH（回 PUBACK + 解压 + 上报）。 */
function onPacket(info: MqttPacketInfo): void {
  if (info.type === 2) {
    state.connected = info.returnCode === 0;
    post(WorkerEvent.state(state.connected, `connack rc=${info.returnCode}`));
    return;
  }
  if (info.type === 13) {
    state.pingPending = false;
    post(WorkerEvent.log('PINGRESP'));
    return;
  }
  if (info.type !== 3 || info.body === null) {
    return;
  }
  // QoS1：必须先回 PUBACK，否则 broker 会一直重发。
  if (info.packetId >= 0 && state.sock !== null) {
    const ack: Uint8Array = MobileMqtt.buildPuback(info.packetId);
    state.sock.send(ack.buffer as ArrayBuffer).catch((): void => {
    });
  }
  state.eventCount++;
  const plain: Uint8Array = Inflate.tryDecompress(info.body);
  const topic: string = info.topic;
  if (TEXT_TOPICS.indexOf(topic) < 0) {
    post(WorkerEvent.frame(topic, plain.length, '', state.eventCount));
    return;
  }
  const text: string = textOf(plain);
  post(WorkerEvent.frame(topic, plain.length,
    text.length > 4000 ? text.substring(0, 4000) : text, state.eventCount));
}

function onBytes(bytes: Uint8Array): void {
  for (let index: number = 0; index < bytes.length; index++) {
    state.buffer.push(bytes[index]);
  }
  while (true) {
    const frame: Uint8Array | null = takeFrame();
    if (frame === null) {
      return;
    }
    onPacket(MobileMqtt.decodePacket(frame));
  }
}

function schedulePing(keepAlive: number): void {
  clearPing();
  state.pingTimer = setTimeout((): void => {
    if (!state.connected || state.sock === null) {
      return;
    }
    if (state.pingPending && Date.now() - state.pingSentAt > PING_TIMEOUT_MS) {
      state.lastError = 'ping-timeout';
      post(WorkerEvent.state(false, 'ping-timeout'));
      closeSocket('ping-timeout');
      return;
    }
    state.pingPending = true;
    state.pingSentAt = Date.now();
    state.sock.send(MobileMqtt.buildPingreq().buffer as ArrayBuffer).catch((error: Error): void => {
      state.lastError = `ping: ${error.message ?? 'unknown'}`;
    });
    schedulePing(keepAlive);
  }, PING_EVERY_MS);
}

function clearPing(): void {
  if (state.pingTimer !== 0) {
    clearTimeout(state.pingTimer);
    state.pingTimer = 0;
  }
}

function closeSocket(why: string): void {
  clearPing();
  state.connected = false;
  const ref: socket.TLSSocket | null = state.sock;
  state.sock = null;
  if (ref !== null) {
    ref.close().catch((): void => {
    });
  }
  post(WorkerEvent.state(false, why));
}

/** 握手：TLS 连上 → 发 CONNECT → 等 CONNACK。 */
async function start(identity: MqttIdentity, keepAlive: number): Promise<void> {
  if (state.connected) {
    post(WorkerEvent.state(true, 'already-connected'));
    return;
  }
  if (!identity.complete()) {
    post(WorkerEvent.state(false, 'identity-incomplete'));
    return;
  }
  try {
    const ref: socket.TLSSocket = socket.constructTLSSocketInstance();
    state.sock = ref;
    await ref.bind({ address: '0.0.0.0', port: 0 });
    await ref.connect({
      address: { address: HOST, port: PORT },
      secureOptions: {},
      timeout: CONNECT_TIMEOUT_MS
    });
    // ⚠️ 监听器必须在 connect 之后注册（OHOS 的坑，见主线程那版的注释）。
    ref.on('message', (info: socket.SocketMessageInfo): void => {
      onBytes(new Uint8Array(info.message));
    });
    ref.on('close', (): void => {
      closeSocket('close');
    });
    ref.on('error', (err: BusinessError): void => {
      state.lastError = `socket: ${err.message ?? 'unknown'}`;
      closeSocket('error');
    });
    state.buffer = [];
    const packet: Uint8Array = MobileMqtt.buildConnect(identity, keepAlive);
    await ref.send(packet.buffer as ArrayBuffer);
    log(`connect sent len=${packet.length} user=${identity.userId}`);
    const deadline: number = Date.now() + CONNACK_WAIT_MS;
    while (Date.now() < deadline && !state.connected) {
      await sleep(80);
    }
    if (state.connected) {
      log('realtime ready (worker)');
      schedulePing(keepAlive);
    } else {
      closeSocket('no-connack');
    }
  } catch (error) {
    state.lastError = (error as Error).message ?? 'unknown';
    post(WorkerEvent.state(false, `start-failed: ${state.lastError}`));
    closeSocket('start-failed');
  }
}

/** 发一条 JSON（内部按 stored 块压成 zlib，同主线程那版）。 */
async function publish(topic: string, json: string): Promise<boolean> {
  const ref: socket.TLSSocket | null = state.sock;
  if (ref === null || !state.connected) {
    return false;
  }
  try {
    state.packetId = state.packetId >= 0xFFFF ? 1 : state.packetId + 1;
    const payload: Uint8Array = MobileMqtt.zlibStored(utf8(json));
    const packet: Uint8Array = MobileMqtt.buildPublish(topic, payload, state.packetId);
    await ref.send(packet.buffer as ArrayBuffer);
    return true;
  } catch (error) {
    state.lastError = `publish: ${(error as Error).message ?? 'unknown'}`;
    return false;
  }
}

/** 主线程来的指令。 */
port.onmessage = (event: MessageEvents): void => {
  const data: WorkerCommand = event.data as WorkerCommand;
  const cmd: string = `${data.cmd ?? ''}`;
  if (cmd === 'start') {
    const raw: WorkerIdentity = data.identity ?? new WorkerIdentity();
    const identity: MqttIdentity = new MqttIdentity(raw.phoneId, raw.userId, raw.userAgent,
      raw.appVersion, raw.locale, raw.sessionId);
    const keepAlive: number = Number(data.keepAlive ?? 20);
    start(identity, keepAlive).catch((error: Error): void => {
      post(WorkerEvent.state(false, `start-throw: ${error.message}`));
    });
    return;
  }
  if (cmd === 'stop') {
    closeSocket('asked');
    return;
  }
  if (cmd === 'publish') {
    publish(`${data.topic ?? ''}`, `${data.json ?? ''}`).then((ok: boolean): void => {
      post(WorkerEvent.log(`publish topic=${data.topic} ok=${ok}`));
    }).catch((): void => {
    });
    return;
  }
  if (cmd === 'status') {
    post(WorkerEvent.state(state.connected,
      `events=${state.eventCount} err=${state.lastError}`));
  }
};
