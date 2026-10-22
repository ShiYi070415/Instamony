/*
 * IG 的**实时通道**（iris / MQTToT）—— 常驻客户端。
 *
 * 对应 instagrapi 的 `realtime/client.py`（RealtimeClient），这一版只做**只读**：
 * 连上 → CONNACK → 心跳 → 收 PUBLISH → 解压 → 派发；`iris_subscribe` 单独一个入口，
 * 等收件箱把 `seq_id` / `snapshot_at_ms` 给出来再调（见 subscribeDirect）。
 *
 * ## 真机上踩过的两个坑（都在这条链路里）
 *   1. **`on('message')` 必须在 `connect()` 之后注册**。在 connect 之前注册，OHOS 的
 *      TLSSocket 会把事件丢光 —— 连公共 broker 都一个字节收不到（实测：`recv=0`）。
 *      改成 connect 之后注册，四段探针全部立刻通了（CONNACK rc=0，之后能收到 topic 150）。
 *   2. **载荷是 zlib 压缩的**，而 ArkTS 没有内存版 zlib（见 core/mobileapi/Inflate 的文件头）。
 *
 * ## 为什么自己维护一个分帧器
 * socket 的 `message` 事件是**字节流**，不保证一个事件正好一条 MQTT 报文（大私信会被拆，
 * 小包会粘）。所以这里按 MQTT 的"1 字节固定头 + varint 剩余长度"自己攒包，
 * 攒够一条才派发 —— 少了这一层，超过几 KB 的消息会永远解析失败。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileMqtt, MqttPacketInfo } from './MobileMqtt';
import { Inflate } from './Inflate';
import { textOf } from './MobileSign';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileRealtime';

/** IG 的 iris/MQTToT broker（instagrapi 的 `REALTIME_HOST`）。 */
const HOST: string = 'edge-mqtt.facebook.com';
const PORT: number = 443;
/** keepalive（秒）：CONNECT 里报给 broker 的值（instagrapi 给 20）。 */
const KEEP_ALIVE_S: number = 20;
/** 心跳间隔（毫秒）：比 keepalive 短一半，给网络抖动留余地。 */
const PING_EVERY_MS: number = 12000;
/** 发完 PINGREQ 等 PINGRESP 的上限（毫秒），超了就当连接死了。 */
const PING_TIMEOUT_MS: number = 8000;
/** TLS 连接超时。 */
const CONNECT_TIMEOUT_MS: number = 10000;
/**
 * "解压+派发"超过这个毫秒数就当"占住主线程了"，打 warn（见 decodeAndDispatch）。
 *
 * 一帧 16ms；这条工作已经挪到独立的一拍里，超过 8ms 就该查是不是补丁特别大。
 */
const DECODE_SLOW_MS: number = 8;
/** 重连退避（毫秒，按次数取，取完停在最后一个）。 */
const BACKOFF_MS: Array<number> = [2000, 5000, 15000, 60000];

/** 一条收到的实时事件（给上层派发用）。 */
export class RealtimeEvent {
  readonly topic: string;
  /** 解压后的文本（JSON 或纯文本；解不出来就是空串）。 */
  readonly text: string;
  readonly at: number;

  constructor(topic: string, text: string) {
    this.topic = topic;
    this.text = text;
    this.at = Date.now();
  }
}

/** 订阅私信用到的两个值（来自收件箱响应，见 instagrapi 的 `direct_subscribe`）。 */
export class IrisState {
  readonly seqId: number;
  readonly snapshotAtMs: number;

  constructor(seqId: number, snapshotAtMs: number) {
    this.seqId = seqId;
    this.snapshotAtMs = snapshotAtMs;
  }
}

export class MobileRealtime {
  private static connected: boolean = false;
  private static connecting: boolean = false;
  /** 想不想要连着（stop 之后不再自动重连）。 */
  private static wanted: boolean = false;
  private static sock: socket.TLSSocket | null = null;
  /** 自发包序号（PUBLISH 的 packet id，1..65535 循环）。 */
  private static packetId: number = 0;
  /** 收包缓冲（见文件头"为什么要自己维护一个分帧器"）。 */
  private static buffer: Array<number> = [];
  private static pingTimer: number = 0;
  private static pingSentAt: number = 0;
  private static pingPending: boolean = false;
  private static reconnectTimer: number = 0;
  private static attempts: number = 0;
  private static eventCount: number = 0;
  private static lastError: string = '-';
  private static handlers: Array<(event: RealtimeEvent) => void> = [];

  /** 状态一行（诊断/界面都看它）。 */
  static status(): string {
    return `connected=${MobileRealtime.connected} events=${MobileRealtime.eventCount}`
      + ` buffered=${MobileRealtime.buffer.length} err=${MobileRealtime.lastError}`;
  }

  /** 订阅事件（只读通道：私信推送、region hint、presence 都在这里出来）。 */
  static onEvent(handler: (event: RealtimeEvent) => void): void {
    MobileRealtime.handlers.push(handler);
  }

  /**
   * 连上 broker（幂等：已经连着就什么都不做）。
   *
   * @returns 是否连上（CONNACK 返回码 0）。
   */
  static async start(): Promise<boolean> {
    MobileRealtime.wanted = true;
    if (MobileRealtime.connected) {
      return true;
    }
    if (MobileRealtime.connecting) {
      return false;
    }
    MobileRealtime.connecting = true;
    try {
      const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
      if (identity === null || !identity.isComplete()) {
        MobileRealtime.lastError = 'no-session';
        hilog.info(DOMAIN, TAG, 'start skipped: no mobile session');
        return false;
      }
      const ref: socket.TLSSocket = socket.constructTLSSocketInstance();
      MobileRealtime.sock = ref;
      await ref.bind({ address: '0.0.0.0', port: 0 });
      const options: socket.TLSConnectOptions = {
        address: { address: HOST, port: PORT },
        secureOptions: {},
        timeout: CONNECT_TIMEOUT_MS
      };
      await ref.connect(options);
      // ⚠️ 监听器**必须在这里（connect 之后）注册**，理由见文件头的坑 1。
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        MobileRealtime.onBytes(new Uint8Array(info.message));
      });
      ref.on('close', (): void => {
        MobileRealtime.onClosed('close');
      });
      ref.on('error', (err: BusinessError): void => {
        MobileRealtime.lastError = `socket: ${err.message ?? 'unknown'}`;
        MobileRealtime.onClosed('error');
      });
      MobileRealtime.buffer = [];
      const packet: Uint8Array = MobileMqtt.buildConnect(identity, KEEP_ALIVE_S);
      await ref.send(packet.buffer as ArrayBuffer);
      hilog.info(DOMAIN, TAG, 'connect sent len=%{public}d user=%{public}s',
        packet.length, identity.userId);
      // CONNACK 会在收包回调里置 connected（见 onPacket），这里只等一小会儿。
      await MobileRealtime.sleep(1500);
      MobileRealtime.attempts = 0;
      if (MobileRealtime.connected) {
        MobileRealtime.schedulePing();
      } else {
        MobileRealtime.onClosed('no-connack');
      }
      return MobileRealtime.connected;
    } catch (error) {
      MobileRealtime.lastError = (error as Error).message ?? 'unknown';
      hilog.warn(DOMAIN, TAG, 'start failed: %{public}s', MobileRealtime.lastError);
      MobileRealtime.onClosed('start-failed');
      return false;
    } finally {
      MobileRealtime.connecting = false;
    }
  }

  /** 主动断开（不再自动重连）。 */
  static async stop(): Promise<void> {
    MobileRealtime.wanted = false;
    MobileRealtime.clearTimers();
    const ref: socket.TLSSocket | null = MobileRealtime.sock;
    MobileRealtime.sock = null;
    MobileRealtime.connected = false;
    if (ref === null) {
      return;
    }
    try {
      await ref.send(new Uint8Array([0xE0, 0x00]).buffer as ArrayBuffer);
    } catch (error) {
    }
    try {
      ref.off('message');
      ref.off('close');
      ref.off('error');
      ref.close();
    } catch (error) {
    }
    hilog.info(DOMAIN, TAG, 'stopped %{public}s', MobileRealtime.status());
  }

  /**
   * **订阅私信实时同步**（instagrapi 的 `iris_subscribe(seq_id, snapshot_at_ms)`，发到 topic 134）。
   *
   * `seqId` / `snapshotAtMs` 来自**收件箱响应**（见 MobileDirect 的 inbox：顶层 `seq_id`、
   * `snapshot_at_ms`）。第三个字段 `snapshot_app_version` **必须填我们自己的 app 版本**：
   * 真机上填空串时 IG 直接拒：
   *
   *   topic=135 {"succeeded":false,"error_type":1,
   *              "error_message":"Resnapshot for app upgrade", "seq_id":null}
   *
   * 也就是说"拿某个版本的快照去订阅，就要报那个版本号"；不报就让你重新快照一遍。
   */
  static async subscribeDirect(state: IrisState): Promise<boolean> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    const version: string = identity === null ? '' : identity.app.appVersion;
    const body: string = `{"seq_id":${state.seqId},`
      + `"snapshot_at_ms":${state.snapshotAtMs},`
      + `"snapshot_app_version":${JSON.stringify(version)}}`;
    const ok: boolean = await MobileRealtime.publish('134', body);
    hilog.info(DOMAIN, TAG, 'iris_subscribe seq=%{public}d snapshot=%{public}d app=%{public}s sent=%{public}s',
      state.seqId, state.snapshotAtMs, version, `${ok}`);
    return ok;
  }

  /** 发一条 JSON 文本（内部会 zlib 压缩，同 instagrapi 的 `publish_json`）。 */
  static async publish(topic: string, json: string): Promise<boolean> {
    const ref: socket.TLSSocket | null = MobileRealtime.sock;
    if (ref === null || !MobileRealtime.connected) {
      return false;
    }
    try {
      MobileRealtime.packetId = MobileRealtime.packetId >= 0xFFFF ? 1 : MobileRealtime.packetId + 1;
      // 出站压缩用"stored 块"即可（见 MobileMqtt 的 zlibStored 说明），对端照样能 inflate。
      const payload: Uint8Array = MobileRealtime.zlibStored(textToBytes(json));
      const packet: Uint8Array = MobileMqtt.buildPublish(topic, payload, MobileRealtime.packetId);
      await ref.send(packet.buffer as ArrayBuffer);
      return true;
    } catch (error) {
      MobileRealtime.lastError = `publish: ${(error as Error).message ?? 'unknown'}`;
      return false;
    }
  }

  // ------------------------------------------------------------------ 收包

  /** 收到一段字节：进缓冲 → 按 MQTT 帧拆 → 逐条处理。 */
  private static onBytes(bytes: Uint8Array): void {
    for (let index: number = 0; index < bytes.length; index++) {
      MobileRealtime.buffer.push(bytes[index]);
    }
    while (true) {
      const frame: Uint8Array | null = MobileRealtime.takeFrame();
      if (frame === null) {
        return;
      }
      MobileRealtime.onPacket(MobileMqtt.decodePacket(frame));
    }
  }

  /**
   * 从缓冲里取出一条**完整**报文（不够一条就返回 null，等下一次数据）。
   *
   * MQTT 帧 = `1 字节固定头` + `varint 剩余长度` + `剩余长度` 字节。
   */
  private static takeFrame(): Uint8Array | null {
    const buf: Array<number> = MobileRealtime.buffer;
    if (buf.length < 2) {
      return null;
    }
    let offset: number = 1;
    let remaining: number = 0;
    let shift: number = 0;
    while (offset < buf.length && shift < 28) {
      const byte: number = buf[offset];
      offset++;
      remaining = remaining | ((byte & 0x7F) << shift);
      shift += 7;
      if ((byte & 0x80) === 0) {
        break;
      }
    }
    const total: number = offset + remaining;
    if (buf.length < total) {
      return null;
    }
    const frame: Uint8Array = new Uint8Array(total);
    for (let index: number = 0; index < total; index++) {
      frame[index] = buf[index];
    }
    MobileRealtime.buffer = buf.slice(total);
    return frame;
  }

  /** 一条完整报文：CONNACK / PINGRESP / PUBLISH（回 PUBACK、解压、派发）。 */
  private static onPacket(info: MqttPacketInfo): void {
    if (info.type === 2) {
      // CONNACK：返回码 0 才算真的连上。
      if (info.returnCode === 0) {
        MobileRealtime.connected = true;
        MobileRealtime.attempts = 0;
        hilog.info(DOMAIN, TAG, 'CONNACK 0 —— 实时通道已连上');
      } else {
        MobileRealtime.lastError = `connack rc=${info.returnCode}`;
        hilog.warn(DOMAIN, TAG, 'CONNACK rc=%{public}d', info.returnCode);
        MobileRealtime.onClosed('connack-fail');
      }
      return;
    }
    if (info.type === 13) {
      MobileRealtime.pingPending = false;
      hilog.debug(DOMAIN, TAG, 'PINGRESP');
      return;
    }
    if (info.type !== 3) {
      hilog.debug(DOMAIN, TAG, 'packet type=%{public}s len=%{public}d',
        info.typeName, info.bytes);
      return;
    }
    // PUBLISH：QoS1 要回 PUBACK，否则 broker 会一直重发。
    if (info.packetId > 0) {
      const ref: socket.TLSSocket | null = MobileRealtime.sock;
      if (ref !== null) {
        try {
          ref.send(MobileMqtt.buildPuback(info.packetId).buffer as ArrayBuffer);
        } catch (error) {
        }
      }
    }
    const raw: Uint8Array = info.body === null ? new Uint8Array(0) : info.body;
    const topic: string = info.topic;
    /*
     * **解压 + 派发挪到下一拍**（需求："不要占据主线程"）。
     *
     * 收包回调是 socket 的读线程切回主线程的那一下，这时候做 zlib 解压（纯 TS 实现，见
     * core/mobileapi/Inflate）和 JSON 补丁解析，会把这一帧的其它渲染/手势往后推。
     * 挪到下一拍只是晚一个 tick（16ms 级），换来的是**绝不占住收包这一帧**。
     * 耗时也记一行（`inflate+dispatch ms=`）：真变重了日志里立刻能看到。
     */
    setTimeout((): void => {
      MobileRealtime.decodeAndDispatch(topic, raw);
    }, 0);
  }

  /** 解压一条 PUBLISH 的载荷并派发给订阅者（见 onPacket 里为什么单独一步）。 */
  private static decodeAndDispatch(topic: string, raw: Uint8Array): void {
    const started: number = Date.now();
    try {
      const inflated: Uint8Array = Inflate.tryDecompress(raw);
      const text: string = textOf(inflated);
      MobileRealtime.eventCount++;
      hilog.info(DOMAIN, TAG, 'event #%{public}d topic=%{public}s raw=%{public}d size=%{public}d text=%{public}s',
        MobileRealtime.eventCount, topic, raw.length, inflated.length,
        text.substring(0, 160));
      const event: RealtimeEvent = new RealtimeEvent(topic, text);
      for (let index: number = 0; index < MobileRealtime.handlers.length; index++) {
        try {
          MobileRealtime.handlers[index](event);
        } catch (error) {
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'decode failed topic=%{public}s raw=%{public}d: %{public}s',
        topic, raw.length, (error as Error).message ?? '-');
    } finally {
      const cost: number = Date.now() - started;
      if (cost >= DECODE_SLOW_MS) {
        hilog.warn(DOMAIN, TAG, 'inflate+dispatch slow ms=%{public}d raw=%{public}d',
          cost, raw.length);
      } else {
        hilog.debug(DOMAIN, TAG, 'inflate+dispatch ms=%{public}d raw=%{public}d',
          cost, raw.length);
      }
    }
  }

  // ------------------------------------------------------------------ 心跳 / 重连

  /** 按间隔发 PINGREQ（没回就当连接死了）。 */
  private static schedulePing(): void {
    MobileRealtime.clearTimers();
    MobileRealtime.pingTimer = setTimeout((): void => {
      if (!MobileRealtime.connected) {
        return;
      }
      if (MobileRealtime.pingPending && MobileRealtime.pingSentAt > 0
        && Date.now() - MobileRealtime.pingSentAt > PING_TIMEOUT_MS) {
        MobileRealtime.lastError = 'ping-timeout';
        hilog.warn(DOMAIN, TAG, 'PINGRESP timeout → reconnect');
        MobileRealtime.onClosed('ping-timeout');
        return;
      }
      const ref: socket.TLSSocket | null = MobileRealtime.sock;
      if (ref !== null) {
        try {
          ref.send(MobileMqtt.buildPingreq().buffer as ArrayBuffer);
          MobileRealtime.pingPending = true;
          MobileRealtime.pingSentAt = Date.now();
        } catch (error) {
        }
      }
      MobileRealtime.schedulePing();
    }, PING_EVERY_MS);
  }

  /** 连接断了：清状态 + 按退避重连（`stop()` 之后不再重连）。 */
  private static onClosed(reason: string): void {
    if (!MobileRealtime.connected && MobileRealtime.reconnectTimer !== 0) {
      return;
    }
    MobileRealtime.connected = false;
    MobileRealtime.clearTimers();
    const ref: socket.TLSSocket | null = MobileRealtime.sock;
    MobileRealtime.sock = null;
    if (ref !== null) {
      try {
        ref.close();
      } catch (error) {
      }
    }
    hilog.info(DOMAIN, TAG, 'closed (%{public}s) %{public}s', reason, MobileRealtime.status());
    if (!MobileRealtime.wanted) {
      return;
    }
    const index: number = MobileRealtime.attempts < BACKOFF_MS.length
      ? MobileRealtime.attempts : BACKOFF_MS.length - 1;
    const wait: number = BACKOFF_MS[index];
    MobileRealtime.attempts++;
    hilog.info(DOMAIN, TAG, 'reconnect in %{public}dms (attempt %{public}d)',
      wait, MobileRealtime.attempts);
    MobileRealtime.reconnectTimer = setTimeout((): void => {
      MobileRealtime.reconnectTimer = 0;
      MobileRealtime.start();
    }, wait);
  }

  private static clearTimers(): void {
    if (MobileRealtime.pingTimer !== 0) {
      clearTimeout(MobileRealtime.pingTimer);
      MobileRealtime.pingTimer = 0;
    }
    if (MobileRealtime.reconnectTimer !== 0) {
      clearTimeout(MobileRealtime.reconnectTimer);
      MobileRealtime.reconnectTimer = 0;
    }
    MobileRealtime.pingPending = false;
    MobileRealtime.pingSentAt = 0;
  }

  // ------------------------------------------------------------------ 小工具

  /** 把 payload 包成只含 stored 块的 zlib 流（出站用；同 MobileMqtt 的那份）。 */
  private static zlibStored(bytes: Uint8Array): Uint8Array {
    const out: Array<number> = [0x78, 0x01];
    if (bytes.length === 0) {
      out.push(0x01, 0x00, 0x00, 0xFF, 0xFF);
    } else {
      let offset: number = 0;
      while (offset < bytes.length) {
        const size: number = Math.min(65535, bytes.length - offset);
        const last: boolean = offset + size >= bytes.length;
        out.push(last ? 0x01 : 0x00);
        out.push(size & 0xFF, (size >> 8) & 0xFF);
        const inverse: number = (~size) & 0xFFFF;
        out.push(inverse & 0xFF, (inverse >> 8) & 0xFF);
        for (let index: number = 0; index < size; index++) {
          out.push(bytes[offset + index]);
        }
        offset += size;
      }
    }
    // Adler-32（stored 块之后必须有）
    let low: number = 1;
    let high: number = 0;
    for (let index: number = 0; index < bytes.length; index++) {
      low = (low + bytes[index]) % 65521;
      high = (high + low) % 65521;
    }
    const sum: number = high * 65536 + low;
    out.push((sum >>> 24) & 0xFF, (sum >>> 16) & 0xFF, (sum >>> 8) & 0xFF, sum & 0xFF);
    return new Uint8Array(out);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}

/** 字符串 → UTF-8 字节（只给 publish 用，避免再引一个依赖）。 */
function textToBytes(text: string): Uint8Array {
  const encoded: Uint8Array = new Uint8Array(text.length * 4);
  let length: number = 0;
  for (let index: number = 0; index < text.length; index++) {
    let code: number = text.charCodeAt(index);
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) {
      const low: number = text.charCodeAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        index++;
      }
    }
    if (code < 0x80) {
      encoded[length++] = code;
    } else if (code < 0x800) {
      encoded[length++] = 0xC0 | (code >> 6);
      encoded[length++] = 0x80 | (code & 0x3F);
    } else if (code < 0x10000) {
      encoded[length++] = 0xE0 | (code >> 12);
      encoded[length++] = 0x80 | ((code >> 6) & 0x3F);
      encoded[length++] = 0x80 | (code & 0x3F);
    } else {
      encoded[length++] = 0xF0 | (code >> 18);
      encoded[length++] = 0x80 | ((code >> 12) & 0x3F);
      encoded[length++] = 0x80 | ((code >> 6) & 0x3F);
      encoded[length++] = 0x80 | (code & 0x3F);
    }
  }
  return encoded.slice(0, length);
}
