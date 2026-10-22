/*
 * MQTToT / MQTT **收发链路**探针（一次性诊断，验完把 pages/Index 里那一发删掉即可）。
 *
 * ## 为什么要重写（上一版结论不可用）
 * 上一版三段探针（对照组 broker.emqx.io、目标 edge-mqtt、备选 mqtt-mini）在真机上的结果是：
 *
 *   control broker.emqx.io:8883  tls=ok remote=34.243.217.54:8883 sent=30  recv=0 connack=-1
 *   target  edge-mqtt:443        tls=ok remote=57.145.12.144:443  sent=948 recv=0 connack=-1
 *
 * **连公共 broker 都一个字节没回** —— 那就不是 IG 不认我们，而是我们这侧的**收包路径**有问题
 * （或者 TLS 用法有问题）。上一版把三发都打在 TLS 上，变量混在一起，分不出是哪一层断的。
 *
 * ## 这一版怎么分（每一发只改一个变量）
 *   ① `1.1.1.1:80` + `GET / HTTP/1.0`（**纯 TCP**，不涉及 TLS、不涉及 MQTT）
 *      —— 收到任何字节就说明"裸 TCP 能读"，问题在 TLS 或报文；
 *   ② `broker.emqx.io:1883` + 标准 MQTT 3.1.1 CONNECT（**纯 TCP + MQTT**）
 *      —— 收到 CONNACK 就说明报文拼得对、broker 认；
 *   ③ `broker.emqx.io:8883` + 标准 CONNECT（**TLS + MQTT**，监听器改成 connect 之后再注册）
 *      —— 与上一版唯一的差别就是"注册时机"，用它验证那条猜想；
 *   ④ `edge-mqtt.facebook.com:443` + MQTToT（真目标，监听器同样 connect 后注册）。
 *
 * 每一发都记：`tls/tcp 是否成立`、`getState()`（OHOS 认为连接是否 connected/bound）、
 * `sent`、`recv`、`首 12 字节`、`CONNACK 返回码`、`异常`。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MobileIdentity, MobileSession } from './MobileSession';
import { hexOf, textOf, utf8 } from './MobileSign';
import { Inflate } from './Inflate';
import { MobileMqtt, MqttPacketInfo } from './MobileMqtt';
import { IrisState, MobileRealtime, RealtimeEvent } from './MobileRealtime';
import { MobileDirect } from './MobileDirect';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MqttProbe';

/** IG 的 iris/MQTToT broker（instagrapi 的 `REALTIME_HOST`）。 */
const MQTT_HOST: string = 'edge-mqtt.facebook.com';
const MQTT_PORT: number = 443;
/** 公共 broker（对照组：标准 MQTT 3.1.1）。 */
const CONTROL_HOST: string = 'broker.emqx.io';
const CONTROL_TLS_PORT: number = 8883;
const CONTROL_PLAIN_PORT: number = 1883;
/** 纯 TCP 的对照组：Cloudflare 的 80 端口，任何 HTTP 请求都会回一段明文。 */
const TCP_HOST: string = '1.1.1.1';
const TCP_PORT: number = 80;
/** keepalive（秒）。instagrapi 的 `write_connect_packet(keep_alive=20)`。 */
const KEEP_ALIVE_S: number = 20;
/** TLS/TCP 握手超时（毫秒）。 */
const CONNECT_TIMEOUT_MS: number = 10000;
/** 每一发发出去之后等多久（毫秒）。之前给到 8~14 秒，实测那样在真机上很拖启动。 */
const WAIT_MS: number = 6000;
/** 实时通道连上之后观察多久（毫秒）：够收一条 region hint + 一次心跳。 */
const OBSERVE_MS: number = 15000;

/** 一次尝试的结果（见 MqttProbe.runCase）。 */
class CaseResult {
  readonly label: string;
  readonly host: string;
  readonly port: number;
  readonly secure: boolean;
  /** 传输层是否连上（TCP 连上 / TLS 握手完成）。 */
  transport: boolean = false;
  /** 连上之后 OHOS 报的状态（`getState()`）。 */
  state: string = '-';
  sent: number = 0;
  recv: number = 0;
  /** 收到的头 12 个字节（十六进制），判断"回的是什么"用。 */
  head: string = '-';
  /** CONNACK 返回码（没收到就是 -1）。 */
  connack: number = -1;
  closed: boolean = false;
  error: string = '';

  constructor(label: string, host: string, port: number, secure: boolean) {
    this.label = label;
    this.host = host;
    this.port = port;
    this.secure = secure;
  }

  /** 一行结论（直接进日志）。 */
  summary(): string {
    return `[${this.label}] ${this.host}:${this.port} ${this.secure ? 'tls' : 'tcp'}=${this.transport ? 'ok' : 'fail'}`
      + ` state=${this.state} sent=${this.sent} recv=${this.recv} head=${this.head}`
      + ` connack=${this.connack} closed=${this.closed ? 'y' : 'n'}`
      + ` err=${this.error.length > 0 ? this.error : '-'}`;
  }
}

export class MqttProbe {
  /** 本次运行是否已经跑过（避免重复连 broker）。 */
  private static probed: boolean = false;

  /**
   * 跑四段探针，结论全进日志。
   *
   * @param force 传 true 可忽略"跑过"标记（调试时手动重跑用）。
   */
  static async probe(force: boolean = false): Promise<void> {
    if (MqttProbe.probed && !force) {
      return;
    }
    MqttProbe.probed = true;
    try {
      const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
      if (identity === null || !identity.isComplete()) {
        hilog.info(DOMAIN, TAG, 'probe skipped: no mobile session');
        return;
      }
      const mqttot: Uint8Array = MobileMqtt.buildConnect(identity, KEEP_ALIVE_S);
      hilog.info(DOMAIN, TAG, 'probe start mqttot len=%{public}d user=%{public}s',
        mqttot.length, identity.userId);

      // ① 纯 TCP + HTTP：只验证"裸 socket 能不能收到字节"。
      const http: Uint8Array = utf8('GET / HTTP/1.0\r\nHost: one.one.one.one\r\n\r\n');
      const plain: CaseResult = await MqttProbe.runCase(TCP_HOST, TCP_PORT, false, http);
      hilog.info(DOMAIN, TAG, 'case1 %{public}s', plain.summary());

      // ② 纯 TCP + 标准 MQTT CONNECT。
      const plainConnect: Uint8Array =
        MqttProbe.buildPlainConnect(`igar-p-${Date.now() % 100000}`, 30);
      const plainMqtt: CaseResult =
        await MqttProbe.runCase(CONTROL_HOST, CONTROL_PLAIN_PORT, false, plainConnect);
      hilog.info(DOMAIN, TAG, 'case2 %{public}s', plainMqtt.summary());

      // ③ TLS + 标准 MQTT（监听器 connect 之后才注册 —— 与上一版唯一的差别）。
      const tlsPlainConnect: Uint8Array =
        MqttProbe.buildPlainConnect(`igar-t-${Date.now() % 100000}`, 30);
      const tlsMqtt: CaseResult =
        await MqttProbe.runCase(CONTROL_HOST, CONTROL_TLS_PORT, true, tlsPlainConnect);
      hilog.info(DOMAIN, TAG, 'case3 %{public}s', tlsMqtt.summary());

      // ④ 真目标：**用正式客户端**（core/mobileapi/MobileRealtime）连上并观察一段时间。
      //    它内部和 instagrapi 的 RealtimeClient 一致：CONNECT → CONNACK → 心跳 → 收包派发。
      MobileRealtime.onEvent((event: RealtimeEvent): void => {
        hilog.info(DOMAIN, TAG, 'realtime event topic=%{public}s len=%{public}d text=%{public}s',
          event.topic, event.text.length, event.text.substring(0, 200));
      });
      const up: boolean = await MobileRealtime.start();
      hilog.info(DOMAIN, TAG, 'case4 realtime start=%{public}s %{public}s',
        `${up}`, MobileRealtime.status());
      // 有收件箱给的同步状态就顺手把私信订阅也发了（这才是实时私信的关键那一发）。
      if (MobileDirect.syncSeqId > 0) {
        await MobileRealtime.subscribeDirect(
          new IrisState(MobileDirect.syncSeqId, MobileDirect.syncSnapshotAtMs));
      } else {
        hilog.info(DOMAIN, TAG, 'iris_subscribe skipped: 还没有 seq_id（收件箱还没拉过）');
      }
      await MqttProbe.sleep(OBSERVE_MS);
      hilog.info(DOMAIN, TAG, 'case4 realtime after %{public}dms %{public}s',
        OBSERVE_MS, MobileRealtime.status());

      hilog.info(DOMAIN, TAG, 'probe done tcp=%{public}d plainMqtt=%{public}d tlsMqtt=%{public}d realtime=%{public}s',
        plain.recv, plainMqtt.connack, tlsMqtt.connack, `${up}`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'probe failed: %{public}s', (error as Error).message ?? 'unknown');
    }
  }

  /**
   * 一次"连上 → 发包 → 等回包"。
   *
   * 监听器**在 connect 之后注册**：上一版是在 connect 之前注册的，真机上一点数据都没收到，
   * 这一版把它当作一个变量单独验证（如果这样能收到，那就是注册时机的问题）。
   */
  private static async runCase(host: string, port: number, secure: boolean,
                               packet: Uint8Array): Promise<CaseResult> {
    const result: CaseResult = new CaseResult(secure ? 'tls' : 'tcp', host, port, secure);
    let tcp: socket.TCPSocket | null = null;
    let tls: socket.TLSSocket | null = null;
    try {
      if (secure) {
        const ref: socket.TLSSocket = socket.constructTLSSocketInstance();
        tls = ref;
        await ref.bind({ address: '0.0.0.0', port: 0 });
        const options: socket.TLSConnectOptions = {
          address: { address: host, port: port },
          // 空 secureOptions = 用系统预置 CA（和 core/DmRealtime 的写法一致）。
          secureOptions: {},
          timeout: CONNECT_TIMEOUT_MS
        };
        await ref.connect(options);
        result.transport = true;
        await MqttProbe.attachTls(ref, result, 'tls');
        await MqttProbe.afterConnect(ref, result, port);
        await ref.send(packet.buffer as ArrayBuffer);
        result.sent = packet.length;
      } else {
        const ref: socket.TCPSocket = socket.constructTCPSocketInstance();
        tcp = ref;
        await ref.bind({ address: '0.0.0.0', port: 0 });
        await ref.connect({ address: { address: host, port: port }, timeout: CONNECT_TIMEOUT_MS });
        result.transport = true;
        await MqttProbe.attachTcp(ref, result, 'tcp');
        const state: socket.SocketStateBase = await ref.getState();
        result.state = `conn=${state.isConnected} bind=${state.isBound}`;
        // TCPSocket 的 send 吃的是 options 对象（TLSSocket 才是裸 buffer）。
        await ref.send({ data: packet.buffer as ArrayBuffer });
        result.sent = packet.length;
      }
      await MqttProbe.sleep(WAIT_MS);
    } catch (error) {
      result.error = (error as Error).message ?? 'unknown';
    } finally {
      if (tls !== null) {
        try {
          tls.close();
        } catch (inner) {
        }
      }
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (inner) {
        }
      }
    }
    return result;
  }

  /** TLS socket 的事件（connect 之后调用，见 runCase 的说明）。 */
  private static async attachTls(ref: socket.TLSSocket, result: CaseResult,
                                 label: string): Promise<void> {
    ref.on('close', (): void => {
      result.closed = true;
    });
    ref.on('error', (err: BusinessError): void => {
      result.error = `socket error: ${err.message ?? 'unknown'}`;
    });
    ref.on('message', (info: socket.SocketMessageInfo): void => {
      MqttProbe.onBytes(result, label, info.message);
    });
    try {
      const remote: socket.NetAddress = await ref.getRemoteAddress();
      const remoteText: string = `${remote.address}:${remote.port}`;
      result.state = `remote=${remoteText}`;
    } catch (error) {
    }
  }

  /** 纯 TCP socket 的事件。 */
  private static async attachTcp(ref: socket.TCPSocket, result: CaseResult,
                                 label: string): Promise<void> {
    ref.on('close', (): void => {
      result.closed = true;
    });
    ref.on('error', (err: BusinessError): void => {
      result.error = `socket error: ${err.message ?? 'unknown'}`;
    });
    ref.on('message', (info: socket.SocketMessageInfo): void => {
      MqttProbe.onBytes(result, label, info.message);
    });
    try {
      const remote: socket.NetAddress = await ref.getRemoteAddress();
      result.state = `remote=${remote.address}:${remote.port}`;
    } catch (error) {
    }
  }

  /** 收到一段字节：记账 + 认是不是 CONNACK。 */
  private static onBytes(result: CaseResult, label: string, raw: ArrayBuffer): void {
    const bytes: Uint8Array = new Uint8Array(raw);
    result.recv += bytes.length;
    if (result.head === '-') {
      result.head = hexOf(bytes.slice(0, Math.min(12, bytes.length)));
    }
    const decoded: MqttPacketInfo = MobileMqtt.decodePacket(bytes);
    hilog.info(DOMAIN, TAG, '%{public}s recv %{public}s len=%{public}d rc=%{public}d topic=%{public}s',
      label, decoded.typeName, decoded.bytes, decoded.returnCode,
      decoded.topic.length > 0 ? decoded.topic : '-');
    if (decoded.type === 2 && result.connack < 0) {
      result.connack = decoded.returnCode;
    }
    if (decoded.type === 3 && decoded.body !== null) {
      // PUBLISH：载荷通常是 zlib 压缩的 JSON（IG 的 region hint / iris 消息都是）。
      // 用它验证 core/mobileapi/Inflate 对**真实 IG 数据**能不能解开。
      const inflated: Uint8Array = Inflate.tryDecompress(decoded.body);
      hilog.info(DOMAIN, TAG, 'publish topic=%{public}s raw=%{public}d inflated=%{public}d text=%{public}s',
        decoded.topic, decoded.body.length, inflated.length, textOf(inflated).substring(0, 220));
    }
  }

  /** connect 之后补一条状态（TLS 那边 `getState` 也要看）。 */
  private static async afterConnect(ref: socket.TLSSocket, result: CaseResult,
                                    port: number): Promise<void> {
    try {
      const state: socket.SocketStateBase = await ref.getState();
      result.state = `${result.state} conn=${state.isConnected} bind=${state.isBound}`;
    } catch (error) {
    }
  }

  /**
   * 标准 MQTT 3.1.1 CONNECT（只给对照组用：公共 broker 说的是标准协议）。
   *
   * 与 `MobileMqtt.buildConnect` 的差别就在载荷：这里协议名是 `MQTT`、级别 4、载荷是明文 client id。
   */
  private static buildPlainConnect(clientId: string, keepAlive: number): Uint8Array {
    const body: Array<number> = [];
    body.push(0x00, 0x04, 0x4D, 0x51, 0x54, 0x54); // "MQTT"
    body.push(0x04);                                // 协议级别 4（3.1.1）
    body.push(0x02);                                // clean session
    body.push((keepAlive >> 8) & 0xFF, keepAlive & 0xFF);
    const raw: Uint8Array = utf8(clientId);
    body.push((raw.length >> 8) & 0xFF, raw.length & 0xFF);
    for (let index: number = 0; index < raw.length; index++) {
      body.push(raw[index]);
    }
    const out: Array<number> = [0x10];
    let left: number = body.length;
    do {
      let digit: number = left % 128;
      left = Math.floor(left / 128);
      if (left > 0) {
        digit = digit | 0x80;
      }
      out.push(digit);
    } while (left > 0);
    for (let index: number = 0; index < body.length; index++) {
      out.push(body[index]);
    }
    return new Uint8Array(out);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
