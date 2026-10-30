/*
 * **FBNS 推送通道（App 侧移植）**——对应 `tools/relay/fbns.js`。
 *
 * App 原来直连 iris 的 `edge-mqtt`（`MobileRealtime`，`cookie_auth`）。换成**设备级会话**
 * （只有 `Authorization: Bearer IGT:2:…`、没有 sessionid）之后，那条路走不通：
 * `MqttIdentity.complete()` 要 sessionid，勉强发出去也是 `CONNACK rc=5`。
 * IG 真正给设备推消息的是 FBNS（`mqtt-mini.facebook.com`，`clientType="device_auth"`），
 * 命令行中继早就走这条路并实测可用。
 *
 * ## 两段式握手（照 `fbns.js` 搬，别"顺手优化"）
 * 1. **空身份连一次**：`userId=0`、无密码。回 `CONNACK rc=0`，载荷下发
 *    `{"ck":账号id,"cs":密钥,"di":设备id,"ds":设备密钥}`。实测带 userId 或密码一律 rc=4。
 * 2. **带凭据重连**：`clientId=deviceId` 前 20 字符、`userId=ck`、`password=cs`，
 *    再加 `fbnsDeviceId` / `fbnsDeviceSecret`。
 * 3. 订阅 topic 76（推送），往 79 发 `{pkg_name, appid}`（zlib 压缩），token 从 topic 80 回。
 *
 * ## 与 iris 的三处区别
 * `clientType="device_auth"` / `appId=567310203415052`；`endpointCapabilities=128`、
 * `noAutomaticForeground=true`、`isInitiallyForeground=false`；多带设备凭据与 `anotherUnknown=-1`。
 *
 * ## 为什么要自己写 inflate
 * `@ohos.zlib` 只有文件级接口，而 FBNS 下行载荷是内存里的 zlib 流（首字节 `0x78`）。
 * 上行不需要压缩器：deflate 的 **stored 块**是标准的一部分，`FbnsWire.zlibStored` 就够。
 */

export const FBNS_HOST: string = 'mqtt-mini.facebook.com';
export const FBNS_PORT: number = 443;
export const FBNS_APP_ID: number = 567310203415052;
export const FBNS_PACKAGE: string = 'com.instagram.android';
export const FBNS_TOPIC_PUSH: string = '76';
export const FBNS_TOPIC_REGISTER: string = '80';
export const FBNS_TOPIC_REQUEST: string = '79';
export const FBNS_KEEPALIVE_S: number = 60;
/**
 * FBNS 连接用的 UA —— **必须与 `tools/relay/fbns.js` 的 `MOBILE_UA` 完全一致**。
 *
 * 注意这与 App 打私有 API 用的 UA（`MobileConfig.USER_AGENT_BASE`，按本机机型填）不是同一份：
 * FBNS 那条连接是独立客户端，relay 用这一份实测能连上、能拿到 token。改成本机机型等于
 * 让"同一条链路的两个客户端"用不同身份，出问题时无从对比（离线对拍也会立刻红）。
 */
const FBNS_UA: string =
  'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; o1s; '
    + 'exynos2100; en_US; 1079242191)';

const T_STOP: number = 0x00;
const T_TRUE: number = 0x01;
const T_FALSE: number = 0x02;
const T_BYTE: number = 0x03;
const T_I32: number = 0x05;
const T_I64: number = 0x06;
const T_BINARY: number = 0x08;
const T_LIST: number = 0x09;
const T_STRUCT: number = 0x0C;

/** FBNS 设备凭据（两段式握手拿到；必须落盘，IG 按设备认人）。 */
export class FbnsAuth {
  clientId: string = '';
  userId: number = 0;
  /** `fbnsConnectionSecret`（CONNACK 的 `cs`）。 */
  password: string = '';
  /** `fbnsDeviceId`（CONNACK 的 `di`）。 */
  deviceId: string = '';
  /** `fbnsDeviceSecret`（CONNACK 的 `ds`）。 */
  deviceSecret: string = '';

  constructor(clientId: string = '', userId: number = 0) {
    this.clientId = clientId;
    this.userId = userId;
  }

  hasCredentials(): boolean {
    return this.deviceId.length > 0 && this.password.length > 0;
  }
}

/** 解出来的一帧。 */
export class FbnsPacket {
  kind: string = 'other';
  returnCode: number = -1;
  topic: string = '';
  packetId: number = -1;
  payload: Uint8Array = new Uint8Array(0);
  code: number = 0;

  constructor(kind: string) {
    this.kind = kind;
  }
}

/*
 * Thrift Compact 写入器：**静态方法 + 显式状态**（`cur` = 当前字段号，`stack` = 嵌套栈）。
 * 不用实例字段的理由：这些方法要能被离线测试直接摘源码跑（见 test-fbns-arkts.js）。
 */
export class FbnsThrift {
  static varint(out: Array<number>, value: number): void {
    let rest: number = Math.floor(value);
    for (;;) {
      const next: number = Math.floor(rest / 128);
      if (next === 0) {
        out.push(rest & 0x7F);
        return;
      }
      out.push((rest & 0x7F) | 0x80);
      rest = next;
    }
  }

  static zigzag(value: number): number {
    return value >= 0 ? value * 2 : -value * 2 - 1;
  }

  static field(out: Array<number>, cur: Array<number>, field: number, type: number): void {
    const delta: number = field - cur[0];
    const kind: number = type & 0x0F;
    if (delta > 0 && delta <= 15) {
      out.push((delta << 4) | kind);
    } else {
      out.push(kind);
      FbnsThrift.varint(out, FbnsThrift.zigzag(field));
    }
    cur[0] = field;
  }

  static pushStruct(out: Array<number>, cur: Array<number>, stack: Array<number>,
                    field: number): void {
    FbnsThrift.field(out, cur, field, T_STRUCT);
    stack.push(cur[0]);
    cur[0] = 0;
  }

  static stop(out: Array<number>, cur: Array<number>, stack: Array<number>): void {
    out.push(T_STOP);
    if (stack.length > 0) {
      cur[0] = stack.pop() as number;
    }
  }

  static strDirect(out: Array<number>, text: string): void {
    const bytes: Array<number> = FbnsThrift.utf8(text);
    FbnsThrift.varint(out, bytes.length);
    for (let index: number = 0; index < bytes.length; index++) {
      out.push(bytes[index]);
    }
  }

  static str(out: Array<number>, cur: Array<number>, field: number, text: string): void {
    FbnsThrift.field(out, cur, field, T_BINARY);
    FbnsThrift.strDirect(out, text);
  }

  static bool(out: Array<number>, cur: Array<number>, field: number, value: boolean): void {
    FbnsThrift.field(out, cur, field, value ? T_TRUE : T_FALSE);
  }

  static int(out: Array<number>, cur: Array<number>, field: number, value: number,
             bits: number): void {
    const type: number = bits === 8 ? T_BYTE : (bits === 64 ? T_I64 : T_I32);
    FbnsThrift.field(out, cur, field, type);
    if (bits === 8) {
      out.push(value & 0xFF);
    } else {
      FbnsThrift.varint(out, FbnsThrift.zigzag(value));
    }
  }

  static intList(out: Array<number>, cur: Array<number>, field: number,
                 values: Array<number>): void {
    FbnsThrift.field(out, cur, field, T_LIST);
    if (values.length < 0x0F) {
      out.push((values.length << 4) | T_I32);
    } else {
      out.push(0xF0 | T_I32);
      FbnsThrift.varint(out, values.length);
    }
    for (let index: number = 0; index < values.length; index++) {
      FbnsThrift.varint(out, FbnsThrift.zigzag(values[index]));
    }
  }

  /** UTF-8 编码（手写，保持这段能离线裸跑）。 */
  static utf8(text: string): Array<number> {
    const out: Array<number> = [];
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
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      } else {
        out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
          0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return out;
  }

  /** UTF-8 解码（同上）。 */
  static textOf(bytes: Uint8Array): string {
    let text: string = '';
    let index: number = 0;
    while (index < bytes.length) {
      const one: number = bytes[index];
      let code: number = one;
      let extra: number = 0;
      if (one >= 0xF0) {
        code = one & 0x07;
        extra = 3;
      } else if (one >= 0xE0) {
        code = one & 0x0F;
        extra = 2;
      } else if (one >= 0xC0) {
        code = one & 0x1F;
        extra = 1;
      }
      index++;
      for (let step: number = 0; step < extra && index < bytes.length; step++) {
        code = (code << 6) | (bytes[index] & 0x3F);
        index++;
      }
      if (code >= 0x10000) {
        const offset: number = code - 0x10000;
        text += String.fromCharCode(0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF));
      } else {
        text += String.fromCharCode(code);
      }
    }
    return text;
  }
}

/** MQTT 的剩余长度 / zlib 封装。 */
export class FbnsWire {
  static pushRemaining(out: Array<number>, length: number): void {
    let left: number = length;
    for (;;) {
      let digit: number = left % 128;
      left = Math.floor(left / 128);
      if (left > 0) {
        digit = digit | 0x80;
      }
      out.push(digit);
      if (left <= 0) {
        return;
      }
    }
  }

  /** 把 `bytes` 包成**只含 stored 块**的 zlib 流（上行不压缩；对端只要能 inflate 就行）。 */
  static zlibStored(bytes: Array<number>): Array<number> {
    const body: Array<number> = [];
    let index: number = 0;
    if (bytes.length === 0) {
      body.push(0x01, 0x00, 0x00, 0xFF, 0xFF);
    }
    while (index < bytes.length) {
      const take: number = Math.min(65535, bytes.length - index);
      const last: boolean = index + take >= bytes.length;
      body.push(last ? 0x01 : 0x00);
      body.push(take & 0xFF, (take >> 8) & 0xFF);
      body.push((~take) & 0xFF, ((~take) >> 8) & 0xFF);
      for (let step: number = 0; step < take; step++) {
        body.push(bytes[index + step]);
      }
      index += take;
    }
    const out: Array<number> = [0x78, 0x01];
    for (let pos: number = 0; pos < body.length; pos++) {
      out.push(body[pos]);
    }
    const adler: number = FbnsWire.adler32(bytes);
    out.push((adler >>> 24) & 0xFF, (adler >>> 16) & 0xFF, (adler >>> 8) & 0xFF, adler & 0xFF);
    return out;
  }

  static adler32(bytes: Array<number>): number {
    let a: number = 1;
    let b: number = 0;
    for (let index: number = 0; index < bytes.length; index++) {
      a = (a + bytes[index]) % 65521;
      b = (b + a) % 65521;
    }
    return ((b << 16) | a) >>> 0;
  }
}

export class MobileFbns {
  /**
   * CONNECT 的 **Thrift 段**（压缩之前）。
   *
   * 抽出来是为了离线对拍：ArkTS 用 stored 块、Node 用 deflate，压缩结果必然不同，
   * 但**解压后必须逐字节一致**，所以比的是这一段。
   *
   * @param nowMs 时间戳（注入以便复现）
   */
  static buildConnectThrift(auth: FbnsAuth, nowMs: number): Uint8Array {
    const out: Array<number> = [];
    const cur: Array<number> = [0];
    const stack: Array<number> = [];
    FbnsThrift.str(out, cur, 1, auth.clientId.substring(0, 20));
    FbnsThrift.pushStruct(out, cur, stack, 4);
    FbnsThrift.int(out, cur, 1, auth.userId, 64);
    FbnsThrift.str(out, cur, 2, FBNS_UA);
    FbnsThrift.int(out, cur, 3, 183, 64);
    FbnsThrift.int(out, cur, 4, 128, 64);
    FbnsThrift.int(out, cur, 5, 1, 32);
    FbnsThrift.bool(out, cur, 6, true);
    FbnsThrift.bool(out, cur, 7, false);
    FbnsThrift.str(out, cur, 8, auth.deviceId.length > 0 ? auth.deviceId : '');
    FbnsThrift.bool(out, cur, 9, false);
    FbnsThrift.int(out, cur, 10, 1, 32);
    FbnsThrift.int(out, cur, 11, 0, 32);
    FbnsThrift.int(out, cur, 12, nowMs % 4294967296, 64);
    FbnsThrift.intList(out, cur, 14, [76, 80, 231]);
    FbnsThrift.str(out, cur, 15, 'device_auth');
    FbnsThrift.int(out, cur, 16, FBNS_APP_ID, 64);
    FbnsThrift.str(out, cur, 20, auth.deviceSecret.length > 0 ? auth.deviceSecret : '');
    FbnsThrift.int(out, cur, 21, 3, 8);
    FbnsThrift.int(out, cur, 26, -1, 64);
    if (auth.password.length > 0) {
      FbnsThrift.str(out, cur, 23, auth.password);
    }
    if (auth.deviceId.length > 0) {
      FbnsThrift.str(out, cur, 24, auth.deviceId);
    }
    if (auth.deviceSecret.length > 0) {
      FbnsThrift.str(out, cur, 25, auth.deviceSecret);
    }
    FbnsThrift.stop(out, cur, stack);
    FbnsThrift.str(out, cur, 5, auth.password.length > 0 ? auth.password : '');
    FbnsThrift.stop(out, cur, stack);
    const result: Uint8Array = new Uint8Array(out.length);
    for (let index: number = 0; index < out.length; index++) {
      result[index] = out[index];
    }
    return result;
  }

  /** FBNS 的 CONNECT 报文（固定头 + MQTToT 前导 + zlib(Thrift)）。 */
  static buildConnect(auth: FbnsAuth, keepAliveSeconds: number, nowMs: number): Uint8Array {
    const thrift: Uint8Array = MobileFbns.buildConnectThrift(auth, nowMs);
    const raw: Array<number> = [];
    for (let index: number = 0; index < thrift.length; index++) {
      raw.push(thrift[index]);
    }
    const payload: Array<number> = FbnsWire.zlibStored(raw);
    const body: Array<number> = [0x00, 0x06, 0x4D, 0x51, 0x54, 0x54, 0x6F, 0x54,
      0x03, 0xC2, (keepAliveSeconds >> 8) & 0xFF, keepAliveSeconds & 0xFF];
    for (let index: number = 0; index < payload.length; index++) {
      body.push(payload[index]);
    }
    const packet: Array<number> = [0x10];
    FbnsWire.pushRemaining(packet, body.length);
    for (let index: number = 0; index < body.length; index++) {
      packet.push(body[index]);
    }
    return new Uint8Array(packet);
  }

  static buildPublish(topic: string, payload: Uint8Array, packetId: number): Uint8Array {
    const topicBytes: Array<number> = FbnsThrift.utf8(topic);
    const body: Array<number> = [(topicBytes.length >> 8) & 0xFF, topicBytes.length & 0xFF];
    for (let index: number = 0; index < topicBytes.length; index++) {
      body.push(topicBytes[index]);
    }
    body.push((packetId >> 8) & 0xFF, packetId & 0xFF);
    for (let index: number = 0; index < payload.length; index++) {
      body.push(payload[index]);
    }
    const out: Array<number> = [0x32];
    FbnsWire.pushRemaining(out, body.length);
    for (let index: number = 0; index < body.length; index++) {
      out.push(body[index]);
    }
    return new Uint8Array(out);
  }

  static buildSubscribe(topic: string, packetId: number): Uint8Array {
    const topicBytes: Array<number> = FbnsThrift.utf8(topic);
    const body: Array<number> = [(packetId >> 8) & 0xFF, packetId & 0xFF,
      (topicBytes.length >> 8) & 0xFF, topicBytes.length & 0xFF];
    for (let index: number = 0; index < topicBytes.length; index++) {
      body.push(topicBytes[index]);
    }
    body.push(0x01);
    const out: Array<number> = [0x82];
    FbnsWire.pushRemaining(out, body.length);
    for (let index: number = 0; index < body.length; index++) {
      out.push(body[index]);
    }
    return new Uint8Array(out);
  }

  static buildPuback(packetId: number): Uint8Array {
    return new Uint8Array([0x40, 0x02, (packetId >> 8) & 0xFF, packetId & 0xFF]);
  }

  static buildPingreq(): Uint8Array {
    return new Uint8Array([0xC0, 0x00]);
  }

  /** 解一帧。 */
  static decodePacket(bytes: Uint8Array): FbnsPacket {
    const type: number = bytes[0] >> 4;
    let offset: number = 1;
    let remaining: number = 0;
    let multiplier: number = 1;
    while (offset < bytes.length && offset <= 4) {
      const one: number = bytes[offset];
      remaining += (one & 0x7F) * multiplier;
      multiplier *= 128;
      offset++;
      if ((one & 0x80) === 0) {
        break;
      }
    }
    const end: number = Math.min(offset + remaining, bytes.length);
    const body: Uint8Array = bytes.subarray(offset, end);
    if (type === 2) {
      const packet: FbnsPacket = new FbnsPacket('connack');
      packet.returnCode = body.length > 1 ? body[1] : -1;
      packet.payload = body.subarray(2);
      return packet;
    }
    if (type === 3) {
      const qos: number = (bytes[0] >> 1) & 0x03;
      let cursor: number = 0;
      let topic: string = '';
      if (body.length >= 2) {
        const topicLen: number = (body[0] << 8) | body[1];
        cursor = 2;
        if (cursor + topicLen <= body.length) {
          topic = FbnsThrift.textOf(body.subarray(cursor, cursor + topicLen));
          cursor += topicLen;
        }
      }
      let packetId: number = -1;
      if (qos > 0 && cursor + 2 <= body.length) {
        packetId = (body[cursor] << 8) | body[cursor + 1];
        cursor += 2;
      }
      const packet: FbnsPacket = new FbnsPacket('publish');
      packet.topic = topic;
      packet.packetId = packetId;
      packet.payload = body.subarray(cursor);
      return packet;
    }
    if (type === 13) {
      return new FbnsPacket('pingresp');
    }
    const other: FbnsPacket = new FbnsPacket('other');
    other.code = type;
    return other;
  }

  /** zlib 解压（实现见 `FbnsInflate`）。 */
  static inflate(payload: Uint8Array): Uint8Array {
    return FbnsInflate.build(payload);
  }

  /** 载荷 → 去掉 2 字节长度前缀 → JSON（解不开返回字符串）。 */
  static parsePayload(payload: Uint8Array): ESObject {
    let body: Uint8Array = payload;
    if (body.length > 0 && body[0] === 0x78) {
      try {
        body = FbnsInflate.build(body);
      } catch (error) {
        body = payload;
      }
    }
    if (body.length >= 3) {
      const size: number = (body[0] << 8) | body[1];
      if (size === body.length - 2 && (body[2] === 0x7B || body[2] === 0x5B)) {
        body = body.subarray(2);
      }
    }
    const text: string = FbnsThrift.textOf(body);
    try {
      return JSON.parse(text) as ESObject;
    } catch (error) {
      return text;
    }
  }
}

/**
 * **DEFLATE 解码器**（zlib 的 inflate；只解不压）。
 *
 * 算法照 zlib 参考实现 `puff`：规范 Huffman 建表 + 逐位读取。
 * 状态放 `state`（`[pos, bit]`），不搞闭包/实例 —— 离线测试能把源码原样摘出来跑，
 * 与 Node 的 `zlib.deflateSync` 对拍（见 `tools/relay/test-fbns-arkts.js`）。
 */
class FbnsInflate {
  static bits(src: Uint8Array, state: Array<number>, count: number): number {
    let value: number = 0;
    for (let index: number = 0; index < count; index++) {
      const one: number = (src[state[0]] >> state[1]) & 1;
      state[1]++;
      if (state[1] === 8) {
        state[1] = 0;
        state[0]++;
      }
      value |= one << index;
    }
    return value;
  }

  /** 规范 Huffman 建表：返回 `[count, symbols]`。 */
  static buildDecoder(lengths: Array<number>): Array<Array<number>> {
    const maxBits: number = 15;
    const count: Array<number> = [];
    for (let index: number = 0; index <= maxBits; index++) {
      count.push(0);
    }
    for (let index: number = 0; index < lengths.length; index++) {
      const len: number = lengths[index];
      if (len > 0 && len <= maxBits) {
        count[len]++;
      }
    }
    const offs: Array<number> = [];
    for (let index: number = 0; index <= maxBits; index++) {
      offs.push(0);
    }
    for (let len: number = 1; len < maxBits; len++) {
      offs[len + 1] = offs[len] + count[len];
    }
    const symbols: Array<number> = [];
    for (let index: number = 0; index < lengths.length; index++) {
      if (lengths[index] > 0) {
        symbols.push(0);
      }
    }
    for (let symbol: number = 0; symbol < lengths.length; symbol++) {
      const len: number = lengths[symbol];
      if (len > 0 && len <= maxBits) {
        symbols[offs[len]] = symbol;
        offs[len]++;
      }
    }
    return [count, symbols];
  }

  /** 解一个符号（puff 的 decode）。 */
  static decodeSymbol(decoder: Array<Array<number>>, src: Uint8Array,
                      state: Array<number>): number {
    const count: Array<number> = decoder[0];
    const symbols: Array<number> = decoder[1];
    let code: number = 0;
    let first: number = 0;
    let index: number = 0;
    for (let len: number = 1; len <= 15; len++) {
      code |= FbnsInflate.bits(src, state, 1);
      const total: number = count[len];
      if (code - total < first) {
        return symbols[index + (code - first)];
      }
      index += total;
      first = (first + total) << 1;
      code <<= 1;
    }
    return -1;
  }

  /** 解一整段 zlib 流（含 2 字节头；adler 不校验）。 */
  static build(payload: Uint8Array): Uint8Array {
    const state: Array<number> = [0, 0];
    FbnsInflate.bits(payload, state, 8);
    const flg: number = FbnsInflate.bits(payload, state, 8);
    if ((flg & 0x20) !== 0) {
      FbnsInflate.bits(payload, state, 32);
    }
    const lengthBase: Array<number> = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
      35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
    const lengthExtra: Array<number> = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
      4, 4, 4, 4, 5, 5, 5, 5, 0];
    const distBase: Array<number> = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
      385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
    const distExtra: Array<number> = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
      9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
    const fixedLit: Array<number> = [];
    for (let code: number = 0; code < 288; code++) {
      fixedLit.push(code < 144 ? 8 : (code < 256 ? 9 : (code < 280 ? 7 : 8)));
    }
    const fixedDist: Array<number> = [];
    for (let code: number = 0; code < 30; code++) {
      fixedDist.push(5);
    }
    const clcOrder: Array<number> = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    const out: Array<number> = [];
    let final: boolean = false;
    let broken: boolean = false;
    while (!final && !broken) {
      final = FbnsInflate.bits(payload, state, 1) === 1;
      const type: number = FbnsInflate.bits(payload, state, 2);
      if (type === 0) {
        if (state[1] !== 0) {
          state[1] = 0;
          state[0]++;
        }
        const len: number = payload[state[0]] | (payload[state[0] + 1] << 8);
        state[0] += 4;
        for (let index: number = 0; index < len; index++) {
          out.push(payload[state[0]]);
          state[0]++;
        }
        continue;
      }
      let litLengths: Array<number> = [];
      let distLengths: Array<number> = [];
      if (type === 1) {
        litLengths = fixedLit;
        distLengths = fixedDist;
      } else if (type === 2) {
        const hlit: number = FbnsInflate.bits(payload, state, 5) + 257;
        const hdist: number = FbnsInflate.bits(payload, state, 5) + 1;
        const hclen: number = FbnsInflate.bits(payload, state, 4) + 4;
        const clc: Array<number> = [];
        for (let index: number = 0; index < 19; index++) {
          clc.push(0);
        }
        for (let index: number = 0; index < hclen; index++) {
          clc[clcOrder[index]] = FbnsInflate.bits(payload, state, 3);
        }
        const clcDecoder: Array<Array<number>> = FbnsInflate.buildDecoder(clc);
        const all: Array<number> = [];
        while (all.length < hlit + hdist) {
          const sym: number = FbnsInflate.decodeSymbol(clcDecoder, payload, state);
          if (sym < 0) {
            broken = true;
            break;
          }
          if (sym < 16) {
            all.push(sym);
          } else if (sym === 16) {
            const prev: number = all.length > 0 ? all[all.length - 1] : 0;
            const repeat: number = 3 + FbnsInflate.bits(payload, state, 2);
            for (let index: number = 0; index < repeat; index++) {
              all.push(prev);
            }
          } else if (sym === 17) {
            const repeat: number = 3 + FbnsInflate.bits(payload, state, 3);
            for (let index: number = 0; index < repeat; index++) {
              all.push(0);
            }
          } else if (sym === 18) {
            const repeat: number = 11 + FbnsInflate.bits(payload, state, 7);
            for (let index: number = 0; index < repeat; index++) {
              all.push(0);
            }
          }
        }
        if (broken) {
          break;
        }
        litLengths = all.slice(0, hlit);
        distLengths = all.slice(hlit, hlit + hdist);
      } else {
        broken = true;
        break;
      }
      const litDecoder: Array<Array<number>> = FbnsInflate.buildDecoder(litLengths);
      const distDecoder: Array<Array<number>> = FbnsInflate.buildDecoder(distLengths);
      for (;;) {
        const sym: number = FbnsInflate.decodeSymbol(litDecoder, payload, state);
        if (sym < 0) {
          broken = true;
          break;
        }
        if (sym < 256) {
          out.push(sym);
          continue;
        }
        if (sym === 256) {
          break;
        }
        const lengthIndex: number = sym - 257;
        if (lengthIndex >= lengthBase.length) {
          broken = true;
          break;
        }
        let length: number = lengthBase[lengthIndex];
        const extraLen: number = lengthExtra[lengthIndex];
        if (extraLen > 0) {
          length += FbnsInflate.bits(payload, state, extraLen);
        }
        const distSym: number = FbnsInflate.decodeSymbol(distDecoder, payload, state);
        if (distSym < 0 || distSym >= distBase.length) {
          broken = true;
          break;
        }
        let distance: number = distBase[distSym];
        const extraDist: number = distExtra[distSym];
        if (extraDist > 0) {
          distance += FbnsInflate.bits(payload, state, extraDist);
        }
        const from: number = out.length - distance;
        if (from < 0) {
          broken = true;
          break;
        }
        for (let index: number = 0; index < length; index++) {
          out.push(out[from + index]);
        }
      }
    }
    const result: Uint8Array = new Uint8Array(out.length);
    for (let index: number = 0; index < out.length; index++) {
      result[index] = out[index];
    }
    return result;
  }
}
