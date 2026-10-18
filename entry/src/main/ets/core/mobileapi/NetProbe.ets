/*
 * **套接字收发最小验证**（诊断用，一次性）。
 *
 * ## 要回答的问题
 * 私信的"实时接收"必须有一条长连接（IG 的 MQTToT）。但在真机上发 MQTToT CONNECT 之后
 * 连**公共 MQTT broker 都不回 CONNACK**（`recv=0`）—— 这种"一个字节都没有"有两种可能：
 *   ① 我们的套接字代码收不到数据（事件没绑上 / API 用法不对）；
 *   ② 报文发了但对端不认（协议层）。
 * 只测 MQTT 是分不清的，所以这里用**必然有响应**的 HTTP 请求做对照：
 *   `example.com:80` 上发一句 `GET / HTTP/1.0`，正常情况会立刻回一段 `HTTP/1.1 …`。
 *
 * 结论只有两种，日志里一行就够：
 *   · `recv>0` → 收发路径是通的，问题在 MQTT 报文/协议层（可以继续做实时通道）；
 *   · `recv=0` → 收发路径不通，MQTT 这条路暂时别指望（要先解决 socket 层）。
 *
 * 它**不改任何状态**，验完就可以整段删掉（Index 里那一发也一并删）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket, webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { hexOf, utf8 } from './MobileSign';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileMqtt } from './MobileMqtt';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NetProbe';
/** 必然有响应的对照端点。 */
const HTTP_HOST: string = 'example.com';
const HTTP_PORT: number = 80;
const HTTPS_PORT: number = 443;
/** 公共 MQTT broker 的明文端口（用来单独验"我们拼的 MQTT CONNECT 对不对"）。 */
const MQTT_HOST: string = 'broker.emqx.io';
const MQTT_TCP_PORT: number = 1883;
/** FB 的两台接入机（④⑤ 用明文 5222 试）。 */
const FB_HOST: string = 'edge-mqtt.facebook.com';
const FB_MINI_HOST: string = 'mqtt-mini.facebook.com';
/** MQTT over WebSocket 的两个端点：公共 broker（用来验证组包）+ FB。 */
const WS_PUBLIC_URL: string = 'wss://broker.emqx.io:8084/mqtt';
const WS_FB_URL: string = 'wss://edge-mqtt.facebook.com/';
/** 连接超时 / 等回包（毫秒）。 */
const CONNECT_TIMEOUT_MS: number = 10000;
const WAIT_MS: number = 5000;

/** 一次探测的结论（只给日志用）。 */
class ProbeResult {
  readonly name: string;
  sent: number = 0;
  bytes: number = 0;
  calls: number = 0;
  error: string = '';

  constructor(name: string) {
    this.name = name;
  }

  summary(): string {
    return `${this.name} sent=${this.sent} calls=${this.calls} recv=${this.bytes}`
      + ` err=${this.error.length > 0 ? this.error : '-'}`;
  }
}

export class NetProbe {
  private static ran: boolean = false;
  /** 屏幕提示的标题（toast 里第一行）。 */
  private static readonly HEAD: string = '网络探针';
  private static readonly TOAST_MS: number = 30000;

  /**
   * 跑三个对照（见文件头）：
   *   ① 明文 TCP + HTTP/1.0（**必然**有响应）；
   *   ② TLS + HTTP/1.0（验 TLS socket 能不能收）；
   *   ③ 明文 TCP + 标准 MQTT CONNECT（验我们拼的 MQTT 报文对不对）。
   */
  /**
   * 跑全部对照，**每完成一步就回调一次**（调用方把它弹到屏幕上）。
   *
   * 为什么一步步回调：探针里有一发会卡（FB 5222 连不通，要等超时）。如果只在末尾汇报，
   * 卡住时屏幕上什么都不会出现，就分不清"没跑"和"卡住了"。逐步更新能看出卡在哪一步。
   */
  static async run(onUpdate: (text: string) => void): Promise<void> {
    if (NetProbe.ran) {
      return;
    }
    NetProbe.ran = true;
    const lines: Array<string> = [];
    const step = (one: ProbeResult): void => {
      lines.push(one.summary());
      hilog.info(DOMAIN, TAG, '%{public}s', one.summary());
      onUpdate(lines.join('\n'));
    };
    step(await NetProbe.plainHttp());
    step(await NetProbe.tlsHttp());
    step(await NetProbe.plainMqtt());
    step(await NetProbe.mqttotTcp(FB_HOST, 5222, '④fb-5222'));
    step(await NetProbe.mqttOverWs(WS_PUBLIC_URL, '⑥ws-emqx',
      NetProbe.plainConnect(`ws-probe-${Date.now() % 100000}`)));
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity !== null && identity.isComplete()) {
      step(await NetProbe.mqttOverWs(WS_FB_URL, '⑦ws-fb',
        MobileMqtt.buildConnect(identity, 20)));
    }
  }

  /**
   * 把一段 MQTT 报文塞进 WebSocket 的**二进制帧**发出去，看有没有字节回来。
   *
   * @param url  ws(s) 地址（EMQX 的 WSS MQTT 入口形如 `wss://host:8084/mqtt`）
   * @param name 日志里的名字
   * @param packet 要发的 MQTT 报文（CONNECT）
   */
  private static async mqttOverWs(url: string, name: string, packet: Uint8Array): Promise<ProbeResult> {
    const result: ProbeResult = new ProbeResult(`${name} ${url}`);
    let ws: webSocket.WebSocket | null = null;
    try {
      ws = webSocket.createWebSocket();
      const opened: Promise<void> = new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        if (ws === null) {
          reject(new Error('no ws'));
          return;
        }
        ws.on('open', (): void => {
          resolve();
        });
        ws.on('error', (err: BusinessError): void => {
          result.error = `ws error: ${err.message ?? 'unknown'}`;
          reject(new Error(result.error));
        });
        ws.on('close', (): void => {
        });
        // 注意签名：ArkTS 的 ws.on('message') 是 `(err, value)` 两个参数（一参会被当成
        // 'headerReceive' 那个重载，编译报 "No overload matches"）。
        ws.on('message', (err: BusinessError, payload: string | ArrayBuffer): void => {
          result.calls++;
          if (typeof payload === 'string') {
            hilog.info(DOMAIN, TAG, '%{public}s text len=%{public}d', name, payload.length);
            return;
          }
          const data: Uint8Array = new Uint8Array(payload as ArrayBuffer);
          result.bytes += data.length;
          hilog.info(DOMAIN, TAG, '%{public}s recv %{public}d bytes head=%{public}s',
            name, data.length, hexOf(data.slice(0, 12)));
        });
      });
      const options: webSocket.WebSocketRequestOptions = {
        header: { 'Sec-WebSocket-Protocol': 'mqtt' }
      };
      ws.connect(url, options, (err: BusinessError): void => {
        if (err !== undefined && err !== null && err.code !== 0) {
          result.error = `connect cb: ${err.message ?? err.code}`;
        }
      });
      await Promise.race([opened, NetProbe.sleep(WAIT_MS)]);
      if (ws !== null) {
        ws.send(packet.buffer as ArrayBuffer);
        result.sent = packet.length;
      }
      await NetProbe.sleep(WAIT_MS);
    } catch (e) {
      result.error = (e as Error).message ?? 'unknown';
    } finally {
      if (ws !== null) {
        try {
          ws.close();
        } catch (inner) {
        }
      }
    }
    return result;
  }

  /**
   * 用**真的 MQTToT 报文**（Thrift + cookie_auth）打一个**明文**端口，看有没有 CONNACK。
   *
   * 报文由 `MobileMqtt.buildConnect` 生成（与共用编码器一致），所以这一发验证的是
   * "端点认不认我们这套身份"，不是"报文对不对"（后者已由 ③ 验过）。
   */
  private static async mqttotTcp(host: string, port: number, name: string): Promise<ProbeResult> {
    const result: ProbeResult = new ProbeResult(`${name} ${host}:${port}`);
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || !identity.isComplete()) {
      result.error = 'no session';
      return result;
    }
    const packet: Uint8Array = MobileMqtt.buildConnect(identity, 20);
    let tcp: socket.TCPSocket | null = null;
    try {
      const ref: socket.TCPSocket = socket.constructTCPSocketInstance();
      tcp = ref;
      ref.on('close', (): void => {
      });
      ref.on('error', (err: BusinessError): void => {
        result.error = err.message ?? 'unknown';
      });
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        result.calls++;
        const data: Uint8Array = new Uint8Array(info.message);
        result.bytes += data.length;
        hilog.info(DOMAIN, TAG, '%{public}s recv %{public}d bytes head=%{public}s',
          name, data.length, hexOf(data.slice(0, 12)));
      });
      await ref.bind({ address: '0.0.0.0', port: 0, family: 1 });
      await ref.connect({ address: { address: host, port: port }, timeout: CONNECT_TIMEOUT_MS });
      await ref.send({ data: packet.buffer as ArrayBuffer });
      result.sent = packet.length;
      await NetProbe.sleep(WAIT_MS);
    } catch (e) {
      result.error = (e as Error).message ?? 'unknown';
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

  /** 明文 TCP + HTTP/1.0。 */
  private static async plainHttp(): Promise<ProbeResult> {
    return NetProbe.httpOver((ref: socket.TCPSocket, result: ProbeResult): void => {
      ref.send({ data: utf8(NetProbe.httpRequest()).buffer as ArrayBuffer });
      result.sent = NetProbe.httpRequest().length;
    }, new ProbeResult(`①tcp-http ${HTTP_HOST}:${HTTP_PORT}`));
  }

  /** TLS + HTTP/1.0（同一个主机，换成 TLS 口）。 */
  private static async tlsHttp(): Promise<ProbeResult> {
    const result: ProbeResult = new ProbeResult(`②tls-http ${HTTP_HOST}:${HTTPS_PORT}`);
    let tls: socket.TLSSocket | null = null;
    try {
      const ref: socket.TLSSocket = socket.constructTLSSocketInstance();
      tls = ref;
      ref.on('close', (): void => {
      });
      ref.on('error', (err: BusinessError): void => {
        result.error = err.message ?? 'unknown';
      });
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        result.calls++;
        const data: Uint8Array = new Uint8Array(info.message);
        result.bytes += data.length;
        hilog.info(DOMAIN, TAG, 'tls-http recv %{public}d bytes', data.length);
      });
      await ref.bind({ address: '0.0.0.0', port: 0 });
      await ref.connect({ address: { address: HTTP_HOST, port: HTTPS_PORT },
        secureOptions: {}, timeout: CONNECT_TIMEOUT_MS });
      const request: string = NetProbe.httpRequest();
      await ref.send(request);
      result.sent = request.length;
      await NetProbe.sleep(WAIT_MS);
    } catch (e) {
      result.error = (e as Error).message ?? 'unknown';
    } finally {
      if (tls !== null) {
        try {
          tls.close();
        } catch (inner) {
        }
      }
    }
    return result;
  }

  /** 明文 TCP + 标准 MQTT 3.1.1 CONNECT（公共 broker 必回 CONNACK）。 */
  private static async plainMqtt(): Promise<ProbeResult> {
    const result: ProbeResult = new ProbeResult(`③tcp-mqtt ${MQTT_HOST}:${MQTT_TCP_PORT}`);
    let tcp: socket.TCPSocket | null = null;
    try {
      const ref: socket.TCPSocket = socket.constructTCPSocketInstance();
      tcp = ref;
      ref.on('close', (): void => {
      });
      ref.on('error', (err: BusinessError): void => {
        result.error = err.message ?? 'unknown';
      });
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        result.calls++;
        const data: Uint8Array = new Uint8Array(info.message);
        result.bytes += data.length;
        hilog.info(DOMAIN, TAG, 'tcp-mqtt recv %{public}d bytes head=%{public}s',
          data.length, hexOf(data.slice(0, 8)));
      });
      await ref.bind({ address: '0.0.0.0', port: 0, family: 1 });
      await ref.connect({ address: { address: MQTT_HOST, port: MQTT_TCP_PORT },
        timeout: CONNECT_TIMEOUT_MS });
      const packet: Uint8Array = NetProbe.plainConnect(`netprobe-${Date.now() % 100000}`);
      await ref.send({ data: packet.buffer as ArrayBuffer });
      result.sent = packet.length;
      await NetProbe.sleep(WAIT_MS);
    } catch (e) {
      result.error = (e as Error).message ?? 'unknown';
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

  /** 明文 TCP 上的通用流程（①用）。 */
  private static async httpOver(send: (ref: socket.TCPSocket, result: ProbeResult) => void,
                                result: ProbeResult): Promise<ProbeResult> {
    let tcp: socket.TCPSocket | null = null;
    try {
      const ref: socket.TCPSocket = socket.constructTCPSocketInstance();
      tcp = ref;
      ref.on('close', (): void => {
      });
      ref.on('error', (err: BusinessError): void => {
        result.error = err.message ?? 'unknown';
      });
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        result.calls++;
        const data: Uint8Array = new Uint8Array(info.message);
        result.bytes += data.length;
        hilog.info(DOMAIN, TAG, 'tcp-http recv %{public}d bytes', data.length);
      });
      await ref.bind({ address: '0.0.0.0', port: 0, family: 1 });
      await ref.connect({ address: { address: HTTP_HOST, port: HTTP_PORT },
        timeout: CONNECT_TIMEOUT_MS });
      send(ref, result);
      await NetProbe.sleep(WAIT_MS);
    } catch (e) {
      result.error = (e as Error).message ?? 'unknown';
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

  private static httpRequest(): string {
    return 'GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n';
  }

  /** 标准 MQTT 3.1.1 CONNECT（client id 明文，clean session）。 */
  private static plainConnect(clientId: string): Uint8Array {
    const body: Array<number> = [];
    body.push(0x00, 0x04, 0x4D, 0x51, 0x54, 0x54); // "MQTT"
    body.push(0x04);                                // 协议级别 4
    body.push(0x02);                                // clean session
    body.push(0x00, 0x3C);                          // keepalive 60
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
