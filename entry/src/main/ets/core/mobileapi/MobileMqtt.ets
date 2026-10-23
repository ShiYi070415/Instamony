/*
 * IG 的**实时通道**：MQTToT 握手（对应 instagrapi 的 `realtime/mqttot.py` + `realtime/client.py`）。
 *
 * ## 为什么不是 WebSocket
 * 上一版（见 core/DmRealtime）先试了裸 TLS 上的标准 MQTT 3.1 CONNECT，又试了
 * `wss://edge-mqtt.facebook.com/`（子协议 `mqtt`）—— 前者对方一声不吭，后者升级失败。
 * instagrapi 里的答案很明确：Facebook 家这套自研的是 **MQTToT**，报文长得像 MQTT，
 * 但 CONNECT 的载荷是 **Thrift 编码 + zlib 压缩**，凭据是 `clientType: "cookie_auth"`
 * 加 `password = "sessionid=<sessionid>"`。协议名仍然写 `MQTToT`、级别 3。
 * 所以标准 CONNECT 打过去，broker 只会当成"协议对不上"而不回应 —— 与实测现象一致。
 *
 * ## 这个文件做什么
 * 只做**报文本身**：`buildConnect()` 组 CONNECT、`decodePacket()` 认回包类型。
 * 真正去连 broker 的探针在 `api/MqttProbe`，接线（订阅私信、收消息派发）还没写 ——
 * 订阅要 `iris_subscribe(seq_id, snapshot_at_ms)`，这两个值来自收件箱响应
 * （instagrapi 的 `direct_threads()` 里的 `last_json`），解析层还没接出来。
 *
 * ## 为什么自己写 Thrift / zlib
 * ArkTS 的 `@ohos.zlib` 只有**文件**级压缩接口，没有内存 buffer 版本；MQTToT 只需要
 * "能被对端 inflate 出来"的合法 zlib 流，而 deflate 的 **stored（未压缩）块**是标准的一部分：
 * `78 01` + `01/00 <len> <~len> <原始字节>` + Adler-32。载荷不到 1KB，这样写的字节数和
 * 真压缩差不了几十字节，还省掉一整个压缩器的移植。
 */

import { MobileIdentity } from './MobileSession';
import { IG_CAPABILITIES } from './MobileConfig';
import { textOf, utf8 } from './MobileSign';

/** 安卓客户端 app id（instagrapi 的 `IG_REALTIME_APP_ID`，与 REST 那个同值）。 */
const MQTT_APP_ID: number = 567067343352427;
/** 握手要订阅的 topic 号（instagrapi 的 `REALTIME_SUBSCRIBE_TOPICS`）。 */
const SUBSCRIBE_TOPICS: Array<number> = [88, 135, 149, 150, 133, 146];

// ---- Thrift 类型号（instagrapi 的 `ThriftTypes`） ----
const THRIFT_STOP: number = 0x00;
const THRIFT_TRUE: number = 0x01;
const THRIFT_FALSE: number = 0x02;
const THRIFT_BYTE: number = 0x03;
const THRIFT_INT_32: number = 0x05;
const THRIFT_INT_64: number = 0x06;
const THRIFT_BINARY: number = 0x08;
const THRIFT_LIST: number = 0x09;
const THRIFT_MAP: number = 0x0B;
const THRIFT_STRUCT: number = 0x0C;

/**
 * Thrift 的 zigzag 整数编码（`(v << 1) ^ (v >> (bits-1))`）。
 *
 * 不能用 JS 的 `<<`：那是 32 位运算，而这里要编码到 64 位（`appId` 就有 15 位十进制）。
 * 好在这些值都在 2^53 以内，直接按数学定义算即可。
 */
function zigzag(value: number): number {
  return value >= 0 ? value * 2 : -value * 2 - 1;
}

/** zlib 的 Adler-32（deflate 流尾部的校验和）。 */
function adler32(bytes: Array<number>): number {
  let low: number = 1;
  let high: number = 0;
  for (let index: number = 0; index < bytes.length; index++) {
    low = (low + bytes[index]) % 65521;
    high = (high + low) % 65521;
  }
  return high * 65536 + low;
}

/**
 * 把原始字节包成一个**只含 stored 块的 zlib 流**（见文件头"为什么自己写 zlib"）。
 *
 * 格式：`78 01` | 若干 deflate stored 块 | Adler-32(大端 4 字节)。
 * 每个 stored 块 = `<BFINAL>` + `<LEN 小端>` + `<~LEN 小端>` + 原始字节（最长 65535）。
 */
function zlibStored(bytes: Array<number>): Array<number> {
  const out: Array<number> = [0x78, 0x01];
  const pushStored = (offset: number, size: number, last: boolean): void => {
    out.push(last ? 0x01 : 0x00);
    out.push(size & 0xFF, (size >> 8) & 0xFF);
    const inverse: number = (~size) & 0xFFFF;
    out.push(inverse & 0xFF, (inverse >> 8) & 0xFF);
    for (let index: number = 0; index < size; index++) {
      out.push(bytes[offset + index]);
    }
  };
  if (bytes.length === 0) {
    pushStored(0, 0, true);
  } else {
    let offset: number = 0;
    while (offset < bytes.length) {
      const size: number = Math.min(65535, bytes.length - offset);
      pushStored(offset, size, offset + size >= bytes.length);
      offset += size;
    }
  }
  const sum: number = adler32(bytes);
  out.push((sum >>> 24) & 0xFF, (sum >>> 16) & 0xFF, (sum >>> 8) & 0xFF, sum & 0xFF);
  return out;
}

/**
 * Thrift **紧凑协议**（Compact Protocol）写入器 —— 只实现 CONNECT 用到的那几种类型。
 *
 * 字段头是"增量 + 类型"：与上一个字段号的差在 1..15 内就一字节 `(delta<<4)|type`，
 * 否则写成 `<type>` + `zigzag(字段号)` 的 varint。容器有自己的头字节。
 */
class ThriftWriter {
  readonly bytes: Array<number> = [];
  /** 进入子结构前的字段号（`STOP` 时恢复，见 writeStop）。 */
  private fieldStack: Array<number> = [];
  private field: number = 0;

  /** 结束当前结构：写 STOP，并恢复外层的字段号。 */
  writeStop(): void {
    this.bytes.push(THRIFT_STOP);
    const previous: number | undefined = this.fieldStack.pop();
    if (previous !== undefined) {
      this.field = previous;
    }
  }

  /** 进入子结构（写 STRUCT 字段头并把字段号重置为 0）。 */
  pushStruct(field: number): void {
    this.writeField(field, THRIFT_STRUCT);
    this.fieldStack.push(this.field);
    this.field = 0;
  }

  writeField(field: number, type: number): void {
    const delta: number = field - this.field;
    const kind: number = type & 0x0F;
    if (delta > 0 && delta <= 15) {
      this.bytes.push((delta << 4) | kind);
    } else {
      this.bytes.push(kind);
      this.writeVarint(zigzag(field));
    }
    this.field = field;
  }

  writeVarint(value: number): void {
    let rest: number = Math.floor(value);
    while (true) {
      const next: number = Math.floor(rest / 128);
      if (next === 0) {
        this.bytes.push(rest & 0x7F);
        return;
      }
      this.bytes.push((rest & 0x7F) | 0x80);
      rest = next;
    }
  }

  /** 字符串（BINARY）：varint 长度 + UTF-8 字节（**不带**字段头）。 */
  writeStringDirect(text: string): void {
    const raw: Uint8Array = utf8(text);
    this.writeVarint(raw.length);
    for (let index: number = 0; index < raw.length; index++) {
      this.bytes.push(raw[index]);
    }
  }

  writeString(field: number, text: string): void {
    this.writeField(field, THRIFT_BINARY);
    this.writeStringDirect(text);
  }

  writeBool(field: number, value: boolean): void {
    this.writeField(field, value ? THRIFT_TRUE : THRIFT_FALSE);
  }

  /** 整数（`bits` = 8 / 32 / 64）。8 位是裸字节，其余 zigzag varint。 */
  writeInt(field: number, value: number, bits: number): void {
    const type: number = bits === 8 ? THRIFT_BYTE : (bits === 64 ? THRIFT_INT_64 : THRIFT_INT_32);
    this.writeField(field, type);
    if (bits === 8) {
      this.bytes.push(value & 0xFF);
    } else {
      this.writeVarint(zigzag(value));
    }
  }

  /** `list<i32>`（CONNECT 里的 `subscribeTopics`）。 */
  writeIntList(field: number, values: Array<number>): void {
    this.writeField(field, THRIFT_LIST);
    if (values.length < 0x0F) {
      this.bytes.push((values.length << 4) | THRIFT_INT_32);
    } else {
      this.bytes.push(0xF0 | THRIFT_INT_32);
      this.writeVarint(values.length);
    }
    for (let index: number = 0; index < values.length; index++) {
      this.writeVarint(zigzag(values[index]));
    }
  }

  /** `map<binary, binary>`（CONNECT 里的 `appSpecificInfo`），键序即写入顺序。 */
  writeBinaryMap(field: number, keys: Array<string>, values: Array<string>): void {
    this.writeField(field, THRIFT_MAP);
    this.writeVarint(keys.length);
    if (keys.length === 0) {
      return;
    }
    this.bytes.push((THRIFT_BINARY << 4) | THRIFT_BINARY);
    for (let index: number = 0; index < keys.length; index++) {
      this.writeStringDirect(keys[index]);
      this.writeStringDirect(values[index]);
    }
  }
}

/** 对端回包的类型（只给日志/派发用，不是完整解码器）。 */
export class MqttPacketInfo {
  readonly type: number;
  readonly typeName: string;
  readonly bytes: number;
  /** CONNACK 的返回码（其他包为 -1）。 */
  readonly returnCode: number;
  /** PUBLISH 的 topic（其他包为空串）。 */
  readonly topic: string;
  /** PUBLISH 的 packet id（QoS>0 才有，其他为 -1）。 */
  readonly packetId: number;
  /** PUBLISH 的载荷（可能是 zlib 压缩的，其他包为 null）。 */
  readonly body: Uint8Array | null;

  constructor(type: number, typeName: string, bytes: number, returnCode: number,
              topic: string = '', packetId: number = -1, body: Uint8Array | null = null) {
    this.type = type;
    this.typeName = typeName;
    this.bytes = bytes;
    this.returnCode = returnCode;
    this.topic = topic;
    this.packetId = packetId;
    this.body = body;
  }
}

export class MobileMqtt {

  /**
   * 组一条 MQTToT CONNECT 报文（instagrapi 的 `write_connect_packet` + `build_connection`）。
   *
   * 结构：`0x10 <剩余长度>` + `"\x00\x06MQTToT"` + `03` + `C2` + `<keepalive 2 字节>` +
   * **zlib(Thrift 结构)**。Thrift 那部分字段照抄 instagrapi 的 descriptors
   * （clientIdentifier=1 / clientInfo=4 / password=5 / appSpecificInfo=10）。
   */
  static buildConnect(identity: MobileIdentity, keepAlive: number): Uint8Array {
    const writer: ThriftWriter = new ThriftWriter();
    // 1: clientIdentifier —— instagrapi 取的是 phone_id 的**前 20 个字符**。
    writer.writeString(1, identity.phoneId.length > 20 ? identity.phoneId.substring(0, 20) : identity.phoneId);
    // 4: clientInfo（子结构）
    writer.pushStruct(4);
    writer.writeInt(1, Number(identity.userId), 64);
    writer.writeString(2, identity.userAgent());
    writer.writeInt(3, 183, 64);           // clientCapabilities
    writer.writeInt(4, 0, 64);             // endpointCapabilities
    writer.writeInt(5, 1, 32);             // publishFormat
    writer.writeBool(6, false);            // noAutomaticForeground
    writer.writeBool(7, true);             // makeUserAvailableInForeground
    writer.writeString(8, identity.phoneId); // deviceId
    writer.writeBool(9, true);             // isInitiallyForeground
    writer.writeInt(10, 1, 32);            // networkType = wifi
    writer.writeInt(11, 0, 32);            // networkSubtype
    /*
     * 12: clientMqttSessionId —— **不能写 `Date.now() & 0xFFFFFFFF`**：
     * JS 的 `&` 走的是**有符号 int32**，10 位量级的时间戳取低 32 位后约一半概率是**负数**，
     * 再按 i64 编出去就变成一个负的 session id。
     * 参考实现里 instagrapi 是 Python 的 `int(time.time()*1000) & 0xFFFFFFFF`（恒非负），
     * instagram4j 直接写完整毫秒值 —— 两者都落在非负区间。所以这里用取模，效果同 Python 那行。
     */
    writer.writeInt(12, Date.now() % 4294967296, 64); // clientMqttSessionId
    writer.writeIntList(14, SUBSCRIBE_TOPICS);
    writer.writeString(15, 'cookie_auth'); // clientType
    writer.writeInt(16, MQTT_APP_ID, 64);
    writer.writeString(20, '');            // deviceSecret（空串也要发，见 client.py）
    writer.writeInt(21, 3, 8);             // clientStack
    writer.writeStop();
    // 5: password —— 网页会话直接当密码用，这是 cookie_auth 的核心。
    writer.writeString(5, `sessionid=${identity.sessionId}`);
    // 10: appSpecificInfo
    MobileMqtt.writeAppSpecificInfo(writer, identity);
    writer.writeStop();

    const payload: Array<number> = zlibStored(writer.bytes);
    const body: Array<number> = [];
    // 协议名：注意是 `MQTToT`（不是 MQTT / MQIsdp），级别 3。
    body.push(0x00, 0x06, 0x4D, 0x51, 0x54, 0x54, 0x6F, 0x54);
    body.push(0x03);
    body.push(0xC2);                        // clean session + will + will retain?（照抄 instagrapi）
    body.push((keepAlive >> 8) & 0xFF, keepAlive & 0xFF);
    for (let index: number = 0; index < payload.length; index++) {
      body.push(payload[index]);
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

  /** `appSpecificInfo`（instagrapi 的 `build_connection` 里那一份，键序也照抄）。 */
  private static writeAppSpecificInfo(writer: ThriftWriter, identity: MobileIdentity): void {
    const everclear: string = '{"inapp_notification_subscribe_comment":"17899377895239777",'
      + '"inapp_notification_subscribe_comment_mention_and_reply":"17899377895239777",'
      + '"video_call_participant_state_delivery":"17977239895057311",'
      + '"presence_subscribe":"17846944882223835"}';
    const userAgent: string = identity.userAgent();
    const keys: Array<string> = [
      'app_version',
      'X-IG-Capabilities',
      'everclear_subscriptions',
      'User-Agent',
      'Accept-Language',
      'platform',
      'ig_mqtt_route',
      'pubsub_msg_type_blacklist',
      'auth_cache_enabled'
    ];
    const values: Array<string> = [
      identity.app.appVersion,
      IG_CAPABILITIES,
      everclear,
      userAgent,
      identity.locale.replace('_', '-'),
      'android',
      'django',
      'direct, typing_type',
      '0'
    ];
    writer.writeBinaryMap(10, keys, values);
  }

  /** 只认出包类型（CONNACK / PINGRESP / PUBLISH / SUBACK…），不做完整解码。 */
  static decodePacket(bytes: Uint8Array): MqttPacketInfo {
    if (bytes.length === 0) {
      return new MqttPacketInfo(-1, 'empty', 0, -1);
    }
    const type: number = bytes[0] >> 4;
    // 剩余长度的 varint（最多 4 字节），跳过它取 body 起点。
    let offset: number = 1;
    let remaining: number = 0;
    let shift: number = 0;
    while (offset < bytes.length && shift < 28) {
      const byte: number = bytes[offset];
      offset++;
      remaining = remaining | ((byte & 0x7F) << shift);
      shift += 7;
      if ((byte & 0x80) === 0) {
        break;
      }
    }
    const names: Array<string> = ['reserved', 'connect', 'connack', 'publish', 'puback', 'pubrec',
      'pubrel', 'pubcomp', 'subscribe', 'suback', 'unsubscribe', 'unsuback', 'pingreq', 'pingresp',
      'disconnect', 'reserved'];
    const name: string = type >= 0 && type < names.length ? names[type] : 'unknown';
    // CONNACK 的 body 是 <sessionPresent> <returnCode>；其余包返回码记 -1。
    let returnCode: number = -1;
    if (type === 2 && offset + 1 < bytes.length) {
      returnCode = bytes[offset + 1];
    }
    if (type === 3) {
      // PUBLISH：<topic 长度 2 字节> <topic> [<packet id 2 字节>（QoS>0）] <载荷>
      const qos: number = (bytes[0] >> 1) & 0x03;
      let cursor: number = offset;
      let topic: string = '';
      let packetId: number = -1;
      if (cursor + 2 <= bytes.length) {
        const topicLen: number = (bytes[cursor] << 8) | bytes[cursor + 1];
        cursor += 2;
        if (cursor + topicLen <= bytes.length) {
          topic = textOf(bytes.slice(cursor, cursor + topicLen));
          cursor += topicLen;
        }
      }
      if (qos > 0 && cursor + 2 <= bytes.length) {
        packetId = (bytes[cursor] << 8) | bytes[cursor + 1];
        cursor += 2;
      }
      const body: Uint8Array = cursor < bytes.length ? bytes.slice(cursor) : new Uint8Array(0);
      return new MqttPacketInfo(type, name, bytes.length, returnCode, topic, packetId, body);
    }
    return new MqttPacketInfo(type, name, bytes.length, returnCode);
  }

  /**
   * 组一条 **PUBLISH**（QoS 1）。
   *
   * 订阅相关的三个 topic 都靠它发（对应 instagrapi 的 `write_publish_packet`）：
   *   · 134 `iris_subscribe`（私信实时同步的开关，载荷是 JSON）
   *   · 149 `graph_ql_subscribe`（realtime sub，前端那套订阅）
   *   · 88  pubsub（skywalker）
   */
  static buildPublish(topic: string, payload: Uint8Array, packetId: number): Uint8Array {
    const topicBytes: Uint8Array = utf8(topic);
    const body: Array<number> = [];
    body.push((topicBytes.length >> 8) & 0xFF, topicBytes.length & 0xFF);
    for (let index: number = 0; index < topicBytes.length; index++) {
      body.push(topicBytes[index]);
    }
    body.push((packetId >> 8) & 0xFF, packetId & 0xFF);
    for (let index: number = 0; index < payload.length; index++) {
      body.push(payload[index]);
    }
    const out: Array<number> = [0x32];          // PUBLISH + QoS 1
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

  /** 组一条 **PUBACK**（收到 QoS 1 的 publish 必须回，否则 broker 会重发）。 */
  static buildPuback(packetId: number): Uint8Array {
    return new Uint8Array([0x40, 0x02, (packetId >> 8) & 0xFF, packetId & 0xFF]);
  }

  /** 组一条 **PINGREQ**（keepalive 20 秒，见 CONNECT 里那个值）。 */
  static buildPingreq(): Uint8Array {
    return new Uint8Array([0xC0, 0x00]);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
