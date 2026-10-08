/*
 * 私信**实时通道**（IG 的 iris / MQTT）—— 第一步：只验证"能不能连上 broker"。
 *
 * 计划分步走，每步都能单独验证：
 *   ① 本文件：TLS 连 `edge-mqtt.facebook.com:443`，确认网络/TLS 这层通（日志里给出结论）；
 *   ② 下一步：发 MQTT CONNECT（用户名 = 自己的 fbid、密码 = 会话令牌，见
 *      `IGDMqttSetupStandaloneQuery` 拿到的 `id` 与 `iris_inactive_subscription_uq_seq_id`），
 *      读 CONNACK 的返回码；
 *   ③ 再往后：SUBSCRIBE 私信 topic、解析 IG 的封套（外层 JSON + Base64/Thrift）、
 *      按 `iris_inactive_subscription_uq_seq_id` 做一次离线补偿，最后把 4 秒轮询放宽成兜底。
 *
 * 为什么先做这一步：第 ② 步能不能过是最不确定的一环（IG 可能像封 REST 读接口那样要求
 * 签名身份）。先把"连得上/连不上、被谁拒"这件事变成日志里一行确定的话，再决定往下做多少。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket, webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DmRealtime';
/** IG 的 iris（MQTT）broker：固定域名，不随会话变化。 */
const MQTT_HOST: string = 'edge-mqtt.facebook.com';
const MQTT_PORT: number = 443;
/** 连接超时（毫秒）。 */
const CONNECT_TIMEOUT_MS: number = 12000;

export class DmRealtime {
  /**
   * **第三步：走 WebSocket（`wss://edge-mqtt.facebook.com/`，子协议 `mqtt`）再发一次 CONNECT。**
   *
   * 为什么试这条：裸 TLS 上发标准 MQTT CONNECT（3.1.1 和 3.1 都试过）对方**一声不吭** ——
   * 连接开着、没有 CONNACK、也不关连接，典型的"协议层面对不上"。Facebook 家这套推送（iris）
   * 常见做法是 MQTT over WebSocket：先用 HTTP Upgrade 升到 wss，再把 MQTT 包塞进二进制帧。
   * 升不上去的话，日志里会有明确的握手原因，据此决定要不要去还原 iris 的自定义握手。
   */
  static async probeWs(): Promise<void> {
    try {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      if (!jar.signedIn) {
        hilog.warn(DOMAIN, TAG, 'ws: not signed in');
        return;
      }
      const userId: string = DmRealtime.cookieValue(jar.cookie, 'ds_user_id');
      const session: string = DmRealtime.cookieValue(jar.cookie, 'sessionid');
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      let opened: boolean = false;
      ws.on('open', (err: BusinessError): void => {
        opened = true;
        hilog.info(DOMAIN, TAG, 'ws open —— 握手成功（子协议 mqtt）');
        const packet: Uint8Array = DmRealtime.connectPacket(`ig${userId}`, userId, session);
        ws.send(packet.buffer as ArrayBuffer).then((): void => {
          hilog.info(DOMAIN, TAG, 'ws mqtt connect sent len=%{public}d', packet.length);
        }).catch((error: Error): void => {
          hilog.warn(DOMAIN, TAG, 'ws send failed: %{public}s', error.message);
        });
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer): void => {
        if (typeof value === 'string') {
          hilog.info(DOMAIN, TAG, 'ws text msg len=%{public}d head=%{public}s',
            value.length, value.substring(0, 120));
          return;
        }
        const bytes: Uint8Array = new Uint8Array(value as ArrayBuffer);
        const rc: number = bytes.length >= 4 ? bytes[3] : -1;
        hilog.info(DOMAIN, TAG, 'ws binary msg len=%{public}d first=[%{public}s] connackRc=%{public}d',
          bytes.length, Array.from(bytes).slice(0, 10).join(','), rc);
      });
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult): void => {
        hilog.warn(DOMAIN, TAG, 'ws closed code=%{public}d reason=%{public}s',
          value.code, value.reason);
      });
      ws.on('error', (err: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'ws error: %{public}s', err.message ?? 'unknown');
      });
      const options: webSocket.WebSocketRequestOptions = {
        header: { 'Sec-WebSocket-Protocol': 'mqtt' }
      };
      ws.connect('wss://edge-mqtt.facebook.com/', options, (err: BusinessError): void => {
        if (err !== undefined && err !== null && err.code !== 0) {
          hilog.warn(DOMAIN, TAG, 'ws connect callback err=%{public}d %{public}s',
            err.code, err.message ?? '');
        } else {
          hilog.info(DOMAIN, TAG, 'ws connect callback ok opened=%{public}s', `${opened}`);
        }
      });
      await DmRealtime.sleep(8000);
      hilog.info(DOMAIN, TAG, 'ws probe done opened=%{public}s', `${opened}`);
      try {
        ws.close();
      } catch (error) {
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'ws probe failed: %{public}s', (error as Error).message ?? 'unknown');
    }
  }

  /**
   * **第二步：发 MQTT CONNECT，读 CONNACK 的返回码。**
   *
   * 这一步要回答的问题只有一个：**IG 认不认我们这套身份**。CONNACK 的返回码里
   * `0` = 通过、`4` = 用户名/密码不对、`5` = 没授权 —— 拿到它就知道后面能不能做。
   *
   * CONNECT 报文（MQTT 3.1.1）：固定头 `0x10 + 剩余长度`；可变头 `00 04 M Q T T` + 协议级别 4 +
   * 连接标志 `0xC2`（clean session + 用户名 + 密码）+ keepalive 60；载荷依次是 clientId、用户名、密码。
   * 用户名用会话里的用户 id，密码用 `sessionid` Cookie —— 这是 IG 那套 iris 通道常见的凭据形态，
   * 不对的话返回码会直接告诉我们。
   */
  static async probeConnect(): Promise<void> {
    let tcp: socket.TLSSocket | null = null;
    try {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      if (!jar.signedIn) {
        hilog.warn(DOMAIN, TAG, 'mqtt: not signed in');
        return;
      }
      const userId: string = DmRealtime.cookieValue(jar.cookie, 'ds_user_id');
      const session: string = DmRealtime.cookieValue(jar.cookie, 'sessionid');
      const clientId: string = `ig${userId}`;
      const packet: Uint8Array = DmRealtime.connectPacket(clientId, userId, session);
      tcp = socket.constructTLSSocketInstance();
      // 把 close/error 也听上：broker 若直接关连接（很可能就是"身份不认"），只有这两个事件能说清。
      tcp.on('close', (): void => {
        hilog.warn(DOMAIN, TAG, 'mqtt socket closed by peer');
      });
      tcp.on('error', (err: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'mqtt socket error: %{public}s', err.message ?? 'unknown');
      });
      tcp.on('message', (info: socket.SocketMessageInfo): void => {
        const bytes: Uint8Array = new Uint8Array(info.message);
        const head: string = Array.from(bytes).slice(0, 12).join(',');
        // CONNACK：0x20 0x02 <sessionPresent> <returnCode>
        const rc: number = bytes.length >= 4 ? bytes[3] : -1;
        hilog.info(DOMAIN, TAG,
          'mqtt connack head=[%{public}s] rc=%{public}d len=%{public}d (0=通过 4=用户名密码错 5=未授权)',
          head, rc, bytes.length);
      });
      const options: socket.TLSConnectOptions = {
        address: { address: MQTT_HOST, port: MQTT_PORT },
        secureOptions: {},
        timeout: CONNECT_TIMEOUT_MS
      };
      await tcp.bind({ address: '0.0.0.0', port: 0 });
      await tcp.connect(options);
      await tcp.send(packet.buffer as ArrayBuffer);
      hilog.info(DOMAIN, TAG, 'mqtt connect sent clientId=%{public}s user=%{public}s passLen=%{public}d',
        clientId, userId, session.length);
      await DmRealtime.sleep(6000);
      hilog.info(DOMAIN, TAG, 'mqtt probe done');
      try {
        tcp.close();
      } catch (error) {
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'mqtt probe failed: %{public}s', (error as Error).message ?? 'unknown');
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (inner) {
        }
      }
    }
  }

  /** 组一条 CONNECT 报文（见 probeConnect 的说明）。 */
  private static connectPacket(clientId: string, user: string, pass: string): Uint8Array {
    const body: Array<number> = [];
    const pushString = (text: string): void => {
      body.push((text.length >> 8) & 0xFF, text.length & 0xFF);
      for (let index: number = 0; index < text.length; index++) {
        body.push(text.charCodeAt(index) & 0xFF);
      }
    };
    // Facebook 家的 broker 走的是 MQTT **3.1**（协议名 `MQIsdp`、级别 3），不是 3.1.1 的 `MQTT`/4 ——
    // 3.1.1 那版发过去对方一声不吭（真机实测：既没有 CONNACK，也不关连接）。
    body.push(0x00, 0x06, 0x4D, 0x51, 0x49, 0x73, 0x64, 0x70); // "MQIsdp"
    body.push(0x03);                                // 协议级别 3（MQTT 3.1）
    body.push(0xC2);                                // clean session + username + password
    body.push(0x00, 0x3C);                          // keepalive 60s
    pushString(clientId);
    pushString(user);
    pushString(pass);
    const out: Array<number> = [0x10];
    // 剩余长度：MQTT 的 varint（这里报文都在 127 字节上下，两字节分支够用，但仍按规范写全）
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

  private static cookieValue(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const pair: string = parts[index].trim();
      if (pair.startsWith(`${name}=`)) {
        return pair.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 连一次 broker 并把结论打进日志（连上就立刻断开 —— 这一步只验证可达性）。
   */
  static async probeTls(): Promise<void> {
    let tcp: socket.TLSSocket | null = null;
    try {
      tcp = socket.constructTLSSocketInstance();
      const options: socket.TLSConnectOptions = {
        address: { address: MQTT_HOST, port: MQTT_PORT },
        // 空的 secureOptions = 用系统预设 CA（SDK 里 ca 的注释写明：默认就是预置 CA 证书）。
        secureOptions: {},
        timeout: CONNECT_TIMEOUT_MS
      };
      // **必须先 bind**：真机上不 bind 直接 connect 会报 `No bind socket`（TLSSocket 内部要拿
      // 已绑定的本地套接字）。0.0.0.0 + 端口 0 = 让系统自己挑本地地址/端口。
      await tcp.bind({ address: '0.0.0.0', port: 0 });
      await tcp.connect(options);
      hilog.info(DOMAIN, TAG, 'tls connect ok host=%{public}s port=%{public}d —— 可以进下一步（MQTT CONNECT）',
        MQTT_HOST, MQTT_PORT);
      try {
        tcp.close();
      } catch (error) {
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'tls connect failed host=%{public}s: %{public}s',
        MQTT_HOST, (error as Error).message ?? 'unknown');
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (inner) {
        }
      }
    }
  }
}
