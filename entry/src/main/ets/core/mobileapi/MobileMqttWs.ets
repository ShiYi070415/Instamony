/*
 * **MQTT over WebSocket**：真正实时的私信通道，跑在隐藏 WebView 的网络栈上。
 *
 * ## 为什么不在原生做
 * 上一轮把这条路的三层逐一验过（见 core/mobileapi/NetProbe，可复跑）：
 *   · 明文 TCP 收发正常（`example.com:80` 拿到 889 字节）；
 *   · **`TLSSocket` 收不到任何数据**（`example.com:443` 同样请求，`calls=0 recv=0`）；
 *   · 我们拼的 MQTT CONNECT 是**对的**（`broker.emqx.io:1883` 回了 `CONNACK 0`）；
 *   · FB 的明文 5222 连不上。
 * 也就是说：卡住的是"ArkTS 的 TLS 收包"，不是协议。而应用里那个常驻的隐藏 WebView
 * 用的是 Chromium 的网络栈（WSS 完全没问题）——所以把**帧的收发**交给它，
 * 原生只负责**拼包与解包**（Thrift + zlib 那套已经在 core/mobileapi/MobileMqtt 里了）。
 *
 * ## 分工
 *   原生：`MobileMqtt.buildConnect()` → base64 → 注入 JS；收到 base64 帧 → 解码 → 认包类型；
 *   网页：`new WebSocket('wss://edge-mqtt.facebook.com/', 'mqtt')`，二进制帧透传，
 *         通过 `window.ogNative.onMqttEvent(kind, data)` 回传（见 bridge/PageBridge）。
 *
 * ## 这一版做到哪
 * 先打通到 **CONNACK**（这是"IG 认不认这套 cookie_auth 身份"的唯一判据）。
 * 订阅（iris_subscribe / 私信 topic）与消息派发留到握手确认之后 —— 因为如果 CONNACK 不是 0，
 * 后面的订阅全都没有意义（参见 instagrapi 的 realtime/client.py）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileMqtt } from './MobileMqtt';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileMqttWs';

/**
 * **总开关**：默认关。
 *
 * 2026-10-19 真机实测（六个候选端点全试）：FB 的 WSS 接入点**全部握手被拒**
 * （每个都是先 `onerror` 再 `close 1006`，连 open 都没有）：
 *
 *   edge-mqtt/           1006     edge-mqtt/mqtt      1006
 *   mqtt-mini/           1006     edge-chat/          1006
 *   edge-mqtt/(mqttv3.1) 1006     edge-mqtt/(无子协议) 1006
 *
 * 加上此前净探针的三条结论（明文 TCP 收得到 / **TLS socket 收不到** / 我们的 MQTT 报文正确、
 * FB 5222 不通），可以定案：**在这台设备 + 这条网络下，拿不到 IG 的 MQTToT 长连接**。
 * 真正的实时推送因此只能等"能收包的 TLS 栈"（系统更新）或自建服务端中转，
 * 代码留着：开关打开就会按候选表重试，届时只需看 `status()`。
 */
const WS_ENABLED: boolean = false;

/** IG 的 MQTToT 接入点（WebSocket 版走同一个域名的 wss）。 */
const WS_URL: string = 'wss://edge-mqtt.facebook.com/';
/** 子协议：MQTT over WebSocket 的标准取值。 */
const WS_SUBPROTOCOL: string = 'mqtt';
/** keepalive（秒）。与 instagrapi 的 write_connect_packet(keep_alive=20) 一致。 */
const KEEP_ALIVE_S: number = 20;

/**
 * 候选端点（一次全试，逐个汇报结果）。
 *
 * 为什么不是一个一个手改：`edge-mqtt.facebook.com` 的 WSS 握手直接被拒（`close 1006`，
 * 连 open 都没有）。FB 家对外提供 MQTT-over-WS 的位置不止一个，子协议写法也有几种
 * （`mqtt` / `mqttv3.1`），一次把组合跑完就能定位是哪一维不对，而不用来回装包。
 */
class WsCandidate {
  readonly url: string;
  readonly proto: string;
  readonly name: string;

  constructor(name: string, url: string, proto: string) {
    this.name = name;
    this.url = url;
    this.proto = proto;
  }
}

const CANDIDATES: Array<WsCandidate> = [
  new WsCandidate('edge-mqtt/', 'wss://edge-mqtt.facebook.com/', 'mqtt'),
  new WsCandidate('edge-mqtt/mqtt', 'wss://edge-mqtt.facebook.com/mqtt', 'mqtt'),
  new WsCandidate('mini', 'wss://mqtt-mini.facebook.com/', 'mqtt'),
  new WsCandidate('edge-chat', 'wss://edge-chat.facebook.com/', 'mqtt'),
  new WsCandidate('edge-mqtt/v31', 'wss://edge-mqtt.facebook.com/', 'mqttv3.1'),
  new WsCandidate('edge-mqtt/none', 'wss://edge-mqtt.facebook.com/', '')
];

export class MobileMqttWs {
  /** 本次运行是否已经起过（幂等）。 */
  private static started: boolean = false;
  /** 握手是否已经拿到 CONNACK。 */
  private static connected: boolean = false;
  /** 收到的帧数 / 字节数（诊断用）。 */
  private static frames: number = 0;
  private static bytes: number = 0;
  /** 最近一次的失败原因（给界面/日志用）。 */
  private static lastError: string = '-';
  /** 每个候选端点的尝试结论（顺序即尝试顺序）。 */
  private static attempts: Array<string> = [];

  static status(): string {
    const tries: string = MobileMqttWs.attempts.length > 0
      ? ` tries=[${MobileMqttWs.attempts.join(' ')}]` : '';
    return `connected=${MobileMqttWs.connected ? 'y' : 'n'} frames=${MobileMqttWs.frames}`
      + ` bytes=${MobileMqttWs.bytes} err=${MobileMqttWs.lastError}${tries}`;
  }

  /**
   * 起连接（幂等）。
   *
   * @param controller 隐藏 WebView 的控制器（帧收发都在它的页面里跑）
   */
  static async start(controller: webview.WebviewController | null): Promise<void> {
    if (!WS_ENABLED) {
      // 见 WS_ENABLED 的说明：六个 WSS 端点全被 1006 拒，默认不跑。
      hilog.info(DOMAIN, TAG, 'ws disabled (see WS_ENABLED)');
      return;
    }
    if (MobileMqttWs.started || controller === null) {
      return;
    }
    MobileMqttWs.started = true;
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || !identity.isComplete()) {
      MobileMqttWs.lastError = 'no-session';
      hilog.info(DOMAIN, TAG, 'skip: no mobile session');
      return;
    }
    const packet: Uint8Array = MobileMqtt.buildConnect(MobileMqtt.identityOf(identity), KEEP_ALIVE_S);
    const b64: string = MobileMqttWs.encode(packet);
    hilog.info(DOMAIN, TAG, 'connect packet len=%{public}d b64=%{public}d user=%{public}s',
      packet.length, b64.length, identity.userId);
    const script: string = MobileMqttWs.script(b64);
    try {
      controller.runJavaScript(script).catch((error: Error): void => {
        MobileMqttWs.lastError = `inject: ${error.message}`;
        hilog.warn(DOMAIN, TAG, 'inject failed: %{public}s', error.message);
      });
    } catch (error) {
      MobileMqttWs.lastError = `inject threw: ${(error as Error).message}`;
      hilog.warn(DOMAIN, TAG, 'inject threw: %{public}s', (error as Error).message);
    }
  }

  /**
   * 网页侧的回调（`window.ogNative.onMqttEvent(kind, data)`）。
   *
   * 只在**原生**这一层解包：网页只管搬字节，协议理解留在 ArkTS（与 MobileMqtt 共用）。
   */
  static onEvent(kind: string, data: string): void {
    if (kind === 'try') {
      hilog.info(DOMAIN, TAG, 'ws try %{public}s', data);
      return;
    }
    if (kind === 'fail') {
      MobileMqttWs.attempts.push(data);
      MobileMqttWs.lastError = `fail ${data}`;
      hilog.warn(DOMAIN, TAG, 'ws fail %{public}s', data);
      return;
    }
    if (kind === 'open') {
      MobileMqttWs.attempts.push(`open:${data}`);
      hilog.info(DOMAIN, TAG, 'ws open %{public}s', data);
      return;
    }
    if (kind === 'error') {
      MobileMqttWs.lastError = `ws error ${data}`;
      hilog.warn(DOMAIN, TAG, 'ws error %{public}s', data);
      return;
    }
    if (kind === 'close') {
      MobileMqttWs.lastError = `ws closed ${data}`;
      hilog.warn(DOMAIN, TAG, 'ws closed code=%{public}s', data);
      return;
    }
    if (kind === 'text') {
      hilog.info(DOMAIN, TAG, 'ws text len=%{public}d head=%{public}s',
        data.length, data.substring(0, 40));
      return;
    }
    if (kind !== 'bin') {
      return;
    }
    MobileMqttWs.frames++;
    const frame: Uint8Array = MobileMqttWs.decode(data);
    MobileMqttWs.bytes += frame.length;
    MobileMqttWs.handleFrame(frame);
  }

  /** 认一帧 MQTT（CONNACK / PINGRESP / SUBACK / PUBLISH …），打一行结论。 */
  private static handleFrame(frame: Uint8Array): void {
    const info: MqttPacketInfo = MobileMqttWs.parse(frame);
    hilog.info(DOMAIN, TAG, 'frame type=%{public}s len=%{public}d rc=%{public}d head=%{public}s',
      info.typeName, frame.length, info.returnCode, MobileMqttWs.hex(frame.slice(0, 12)));
    if (info.type === 2) {
      MobileMqttWs.connected = info.returnCode === 0;
      MobileMqttWs.lastError = info.returnCode === 0 ? '-' : `connack ${info.returnCode}`;
      hilog.info(DOMAIN, TAG, 'CONNACK rc=%{public}d (0=通过)', info.returnCode);
    }
  }

  /** 极简 MQTT 包头解析（只要类型与 CONNACK 返回码）。 */
  private static parse(frame: Uint8Array): MqttPacketInfo {
    if (frame.length === 0) {
      return new MqttPacketInfo(-1, 'empty', -1);
    }
    const type: number = frame[0] >> 4;
    // 跳过剩余长度的 varint。
    let offset: number = 1;
    let shift: number = 0;
    while (offset < frame.length && shift < 28) {
      const byte: number = frame[offset];
      offset++;
      shift += 7;
      if ((byte & 0x80) === 0) {
        break;
      }
    }
    const names: Array<string> = ['reserved', 'connect', 'connack', 'publish', 'puback', 'pubrec',
      'pubrel', 'pubcomp', 'subscribe', 'suback', 'unsubscribe', 'unsuback', 'pingreq', 'pingresp',
      'disconnect', 'reserved'];
    const name: string = type >= 0 && type < names.length ? names[type] : 'unknown';
    let rc: number = -1;
    if (type === 2 && offset + 1 < frame.length) {
      rc = frame[offset + 1];
    }
    return new MqttPacketInfo(type, name, rc);
  }

  /**
   * 注入到页面里的脚本。
   *
   * 几个要点：
   *   · **幂等**：`window.__igarMqtt` 已存在就直接返回（重复注入不会开第二条连接）；
   *   · `binaryType='arraybuffer'`：否则二进制帧会变成 Blob，读不出来；
   *   · 子协议 `mqtt`：MQTT over WebSocket 的标准取值，服务端据此认协议；
   *   · 收到的帧转 base64 回传（字符串能安全跨 JS proxy），错误与关闭都要报回来，
   *     否则原生只能干等。
   *
   * @param b64Connect 已 base64 的 MQTToT CONNECT 报文
   */
  private static script(b64Connect: string): string {
    // 候选端点表（JSON），JS 侧顺序尝试。
    const list: Array<Record<string, string>> = [];
    for (let index: number = 0; index < CANDIDATES.length; index++) {
      const one: WsCandidate = CANDIDATES[index];
      const row: Record<string, string> = {};
      row['name'] = one.name;
      row['url'] = one.url;
      row['proto'] = one.proto;
      list.push(row);
    }
    return `(function(){
  if (window.__igarMqtt) { return; }
  function b64buf(b64) {
    var bin = atob(b64), out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) { out[i] = bin.charCodeAt(i); }
    return out.buffer;
  }
  function buf64(buf) {
    var b = new Uint8Array(buf), s = '';
    for (var i = 0; i < b.length; i++) { s += String.fromCharCode(b[i]); }
    return btoa(s);
  }
  function report(kind, data) {
    try { window.ogNative.onMqttEvent(kind, String(data)); } catch (e) {}
  }
  var list = ${JSON.stringify(list)};
  var idx = 0;
  function attempt() {
    if (idx >= list.length) { window.__igarMqtt = null; return; }
    var one = list[idx++];
    report('try', one.name);
    var ws = null;
    try {
      ws = one.proto ? new WebSocket(one.url, one.proto) : new WebSocket(one.url);
    } catch (err) {
      report('fail', one.name + ':ctor');
      attempt();
      return;
    }
    ws.binaryType = 'arraybuffer';
    var settled = false;
    ws.onopen = function () {
      settled = true;
      report('open', one.name);
      ws.send(b64buf(${JSON.stringify(b64Connect)}));
      window.__igarMqtt = ws;
    };
    ws.onmessage = function (e) {
      if (typeof e.data === 'string') { report('text', e.data.substring(0, 400)); }
      else { report('bin', buf64(e.data)); }
    };
    ws.onerror = function () {
      if (settled) { report('error', one.name); return; }
      report('fail', one.name + ':err');
      attempt();
    };
    ws.onclose = function (e) {
      if (settled) { report('close', (e && e.code) || 0); window.__igarMqtt = null; return; }
      report('fail', one.name + ':' + ((e && e.code) || 0));
      attempt();
    };
  }
  attempt();
})();`;
  }

  private static encode(bytes: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(bytes, util.Type.BASIC);
  }

  private static decode(text: string): Uint8Array {
    try {
      return new util.Base64Helper().decodeSync(text, util.Type.BASIC);
    } catch (error) {
      return new Uint8Array(0);
    }
  }

  private static hex(bytes: Uint8Array): string {
    const out: Array<string> = [];
    for (let index: number = 0; index < bytes.length; index++) {
      const one: string = bytes[index].toString(16);
      out.push(one.length === 1 ? `0${one}` : one);
    }
    return out.join('');
  }
}

/** 一帧 MQTT 的类型（只给日志用）。 */
class MqttPacketInfo {
  /** 包类型号（2 = CONNACK，13 = PINGRESP…）。 */
  readonly type: number;
  readonly typeName: string;
  readonly returnCode: number;

  constructor(type: number, typeName: string, returnCode: number) {
    this.type = type;
    this.typeName = typeName;
    this.returnCode = returnCode;
  }
}
