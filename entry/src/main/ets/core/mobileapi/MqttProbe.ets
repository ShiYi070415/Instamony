/*
 * MQTToT **握手可行性探针**（一次性验证；验完把 `Index.aboutToAppear` 里那一发删掉即可）。
 *
 * ## 上一版为什么不够
 * 只对着 `edge-mqtt.facebook.com` 发 MQTToT CONNECT、等 8 秒，日志是**一片安静**：
 * TLS 连上了、包发出去了、对端既不给 CONNACK 也不关连接。这种"沉默"有三种可能
 * （报文不对 / 这条链路根本不通 / 这个域名不认这台客户端），只靠一次尝试分不开。
 *
 * ## 这一版怎么分
 * 三段，每段一个变量：
 *   ① **对照组**：`broker.emqx.io:8883` + 标准 MQTT 3.1.1 CONNECT。它回 CONNACK 就证明
 *      "TLS socket + 我们自己拼报文 + 收包"这三件都没问题（问题只可能出在 IG 侧）；
 *   ② **目标**：`edge-mqtt.facebook.com:443` + MQTToT（Thrift）CONNECT；
 *   ③ **备选主机**：`mqtt-mini.facebook.com:443` + 同一个 MQTToT 报文（FB 家接入点不止一个域名）。
 *
 * 判据仍然是 CONNACK 的返回码：`0` 才算握手通过。
 *
 * 顺带把 MQTToT 报文**整段十六进制**打进日志（按 64 字节切行）：Thrift + zlib 的载荷
 * 光看长度和头几个字节判不出对错，有了全量就能在电脑上跑一遍解码器逐字段核对。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MobileIdentity, MobileSession } from './MobileSession';
import { hexOf, utf8 } from './MobileSign';
import { MobileMqtt, MqttPacketInfo } from './MobileMqtt';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MqttProbe';

/** IG 的 iris/MQTToT broker（instagrapi 的 `REALTIME_HOST`）。 */
const MQTT_HOST: string = 'edge-mqtt.facebook.com';
/** FB 的轻量 MQTT 接入点（备选）。 */
const MINI_HOST: string = 'mqtt-mini.facebook.com';
const MQTT_PORT: number = 443;
/** 对照组：公共 broker（EMQX 官方测试服，支持 TLS + 标准 MQTT）。 */
const CONTROL_HOST: string = 'broker.emqx.io';
const CONTROL_PORT: number = 8883;
/** keepalive（秒）。instagrapi 的 `write_connect_packet(keep_alive=20)`。 */
const KEEP_ALIVE_S: number = 20;
/** TLS 握手超时（毫秒）。 */
const CONNECT_TIMEOUT_MS: number = 12000;
/** 老目标是 8 秒不够（很可能只是慢），这次给 14 秒；对照组不需要那么久。 */
const CONNACK_WAIT_MS: number = 14000;
const CONTROL_WAIT_MS: number = 8000;
/** 收到 CONNACK 之后隔多久发 PINGREQ（毫秒）。 */
const PING_DELAY_MS: number = 2500;
/** 十五进制转储每行多少字节。 */
const DUMP_LINE_BYTES: number = 64;

/** 一次连接尝试的结果（见 MqttProbe.attempt）。 */
class MqttAttempt {
  readonly host: string;
  readonly port: number;
  /** TLS 握手是否完成。 */
  tls: boolean = false;
  /** TLS 对端地址（握手后拿得到才填）。 */
  remote: string = '';
  /** 发出去的字节数。 */
  sent: number = 0;
  /** 收到的字节数。 */
  bytes: number = 0;
  /** CONNACK 返回码（没收到就是 -1）。 */
  connackRc: number = -1;
  /** 对端是否关了连接。 */
  closed: boolean = false;
  /** 有没有收到 PINGRESP（握手通过后再看这个判断连接是否真可用）。 */
  pingResp: boolean = false;
  /** 异常信息（TLS 失败之类）。 */
  error: string = '';

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }

  /** 一行结论（直接打日志）。 */
  summary(): string {
    return `${this.host}:${this.port} tls=${this.tls ? 'ok' : 'fail'} remote=${this.remote} `
      + `sent=${this.sent} recv=${this.bytes} connack=${this.connackRc} `
      + `pingresp=${this.pingResp ? 'y' : 'n'} closed=${this.closed ? 'y' : 'n'} `
      + `err=${this.error.length > 0 ? this.error : '-'}`;
  }
}

export class MqttProbe {
  /** 本次运行是否已经跑过（避免重复连 broker）。 */
  private static probed: boolean = false;

  /**
   * 跑三段探针，结论全进日志。
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
      const packet: Uint8Array = MobileMqtt.buildConnect(identity, KEEP_ALIVE_S);
      hilog.info(DOMAIN, TAG, 'mqttot packet len=%{public}d user=%{public}s',
        packet.length, identity.userId);
      MqttProbe.dumpHex('mqttot', packet);
      // ① 对照组：公共 broker + 标准 CONNECT（client id 随便，关键是看有没有 CONNACK）。
      const control: Uint8Array = MqttProbe.buildPlainConnect(`igar-probe-${Date.now() % 100000}`, 30);
      const controlResult: MqttAttempt =
        await MqttProbe.attempt(CONTROL_HOST, CONTROL_PORT, control, CONTROL_WAIT_MS, 'control');
      hilog.info(DOMAIN, TAG, 'control (标准 MQTT 3.1.1) %{public}s', controlResult.summary());
      // ② 目标主机。
      const edgeResult: MqttAttempt =
        await MqttProbe.attempt(MQTT_HOST, MQTT_PORT, packet, CONNACK_WAIT_MS, 'edge-mqtt');
      hilog.info(DOMAIN, TAG, 'target edge-mqtt (MQTToT) %{public}s', edgeResult.summary());
      if (edgeResult.connackRc === 0) {
        hilog.info(DOMAIN, TAG, 'CONNACK 0 —— MQTToT 握手通过，可以往下做订阅');
        return;
      }
      // ③ 备选主机（同一个报文；FB 家的接入点不止一个域名）。
      const miniResult: MqttAttempt =
        await MqttProbe.attempt(MINI_HOST, MQTT_PORT, packet, CONNACK_WAIT_MS, 'mqtt-mini');
      hilog.info(DOMAIN, TAG, 'target mqtt-mini (MQTToT) %{public}s', miniResult.summary());
      hilog.info(DOMAIN, TAG, 'probe done control=%{public}d edge=%{public}d mini=%{public}d',
        controlResult.connackRc, edgeResult.connackRc, miniResult.connackRc);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'probe failed: %{public}s', (error as Error).message ?? 'unknown');
    }
  }

  /**
   * 对一个主机做一次"连上 → 发包 → 等回包"（三段探针共用）。
   *
   * **异常也当成结果返回**：`TLS 被拒` 和 `连上了但没人应答` 是两种完全不同的失败，
   * 都要能在日志里区分开（这正是上一版最缺的信息）。
   */
  private static async attempt(host: string, port: number, packet: Uint8Array, waitMs: number,
                               label: string): Promise<MqttAttempt> {
    const result: MqttAttempt = new MqttAttempt(host, port);
    let tcp: socket.TLSSocket | null = null;
    try {
      const ref: socket.TLSSocket = socket.constructTLSSocketInstance();
      tcp = ref;
      ref.on('close', (): void => {
        result.closed = true;
      });
      ref.on('error', (err: BusinessError): void => {
        result.error = `socket error: ${err.message ?? 'unknown'}`;
      });
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        const bytes: Uint8Array = new Uint8Array(info.message);
        result.bytes += bytes.length;
        const decoded: MqttPacketInfo = MobileMqtt.decodePacket(bytes);
        hilog.info(DOMAIN, TAG,
          '%{public}s recv %{public}s len=%{public}d rc=%{public}d head=%{public}s',
          label, decoded.typeName, decoded.bytes, decoded.returnCode, hexOf(bytes.slice(0, 12)));
        if (decoded.type === 2 && result.connackRc < 0) {
          result.connackRc = decoded.returnCode;
          // 握上了就 ping 一发：能收到 PINGRESP 才算这条连接真的可用。
          if (decoded.returnCode === 0) {
            setTimeout((): void => {
              try {
                ref.send(new Uint8Array([0xC0, 0x00]).buffer as ArrayBuffer);
              } catch (error) {
              }
            }, PING_DELAY_MS);
          }
        }
        if (decoded.type === 13) {
          result.pingResp = true;
          hilog.info(DOMAIN, TAG, '%{public}s PINGRESP —— 连接可用', label);
        }
      });
      await ref.bind({ address: '0.0.0.0', port: 0 });
      const options: socket.TLSConnectOptions = {
        address: { address: host, port: port },
        // 空的 secureOptions = 用系统预置 CA（与 core/DmRealtime 的写法一致）。
        secureOptions: {},
        timeout: CONNECT_TIMEOUT_MS
      };
      await ref.connect(options);
      result.tls = true;
      try {
        const remote: socket.NetAddress = await ref.getRemoteAddress();
        result.remote = `${remote.address}:${remote.port}`;
      } catch (error) {
      }
      await ref.send(packet.buffer as ArrayBuffer);
      result.sent = packet.length;
      await MqttProbe.sleep(waitMs);
    } catch (error) {
      result.error = (error as Error).message ?? 'unknown';
    } finally {
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (inner) {
        }
      }
    }
    return result;
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

  /**
   * 把报文整段打进日志（**只在探针里用**）。
   *
   * 按 64 字节一行切开，避免单条日志被系统截断（hilog 单条有长度上限）。
   */
  private static dumpHex(label: string, bytes: Uint8Array): void {
    for (let offset: number = 0; offset < bytes.length; offset += DUMP_LINE_BYTES) {
      const end: number = Math.min(bytes.length, offset + DUMP_LINE_BYTES);
      hilog.info(DOMAIN, TAG, 'hex %{public}s @%{public}d %{public}s',
        label, offset, hexOf(bytes.slice(offset, end)));
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
