/*
 * IG 的**实时通道**（iris / MQTToT）—— Node 版，零依赖。
 *
 * 为什么要它：轮询是"每 60 秒问一次"（一天 1440 次请求），而私信是"来一条推一条"的场景，
 * 实时通道连上之后**只有心跳**（20 秒一个 2 字节包），几乎不产生请求，
 * 延迟从"最多 60 秒"降到"1~2 秒"。
 *
 * ## 移植来源（都是已验证过的，不是猜的）
 *   · ArkTS：`entry/src/main/ets/core/mobileapi/MobileMqtt.ets`（CONNECT / PUBLISH 组包）
 *     + `MobileRealtime.ets`（连、心跳、订阅、收包）
 *     那边文件头记着真机实测结论：`CONNACK rc=0`，之后能收到 topic 150。
 *   · 上游：instagrapi 的 `realtime/mqttot.py` + `client.py`。
 *
 * ## 三件必须记住的事
 *   1. **协议名是 `MQTToT`**，级别 3；不是标准 MQTT，LOAD 标准 CONNECT 会被一声不吭地丢掉。
 *   2. CONNECT 的载荷是 **Thrift Compact + zlib**；凭据走 `clientType="cookie_auth"` +
 *      `password="sessionid=<sessionid>"`（网页会话直接当密码用）。
 *   3. `iris_subscribe` 必须带 `snapshot_app_version`，而且要和拿 `seq_id` 那次的版本一致，
 *      否则回 `{"succeeded":false,"error_type":1,"error_message":"Resnapshot for app upgrade"}`。
 *
 * ## 设计取舍：**只当触发器，不当数据源**
 * 实时帧里的消息体结构会随 IG 版本变（而且有多种 topic）。这里只判断"来了一条私信相关事件"，
 * 然后让上层去拉一次收件箱拿权威数据 —— 一次请求换一次确定性，
 * 比解析一份可能随时变形的帧结构稳得多。
 */

'use strict';

const fs = require('fs');
const path = require('path');
const tls = require('tls');
const zlib = require('zlib');

/** IG 的 iris/MQTToT broker（instagrapi 的 REALTIME_HOST，端口 443 走 TLS）。 */
const MQTT_HOST = 'edge-mqtt.facebook.com';
const MQTT_PORT = 443;
/** 安卓客户端 app id（instagrapi 的 IG_REALTIME_APP_ID，与 REST 那个同值）。 */
const MQTT_APP_ID = 567067343352427;
/** 握手要订阅的 topic 号（instagrapi 的 REALTIME_SUBSCRIBE_TOPICS）。 */
const SUBSCRIBE_TOPICS = [88, 135, 149, 150, 133, 146];
/** 心跳秒数（写进 CONNECT，也是我们发 PINGREQ 的节奏）。 */
const KEEPALIVE_SECONDS = 20;
/** 私信实时订阅的出口 topic（instagrapi 的 iris_subscribe）。 */
const TOPIC_IRIS_SUBSCRIBE = '134';
/** 订阅结果回在 topic 135；私信事件表现在 150（也可能落 146 那类，都算"有动静"）。 */
const TOPIC_SUBSCRIBE_RESULT = '135';
/** 跟私信有关、值得触发一次收件箱刷新的 topic。 */
const DIRECT_TOPICS = ['150', '146', '149', '133'];

/** 移动端 UA（和 relay 拉收件箱用的一致；对端会拿它做身份判据）。 */
const MOBILE_UA =
  'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; ' +
  'o1s; exynos2100; en_US; 1079242191)';
/**
 * App 版本：**必须用 instagrapi 的 DEFAULT_APP_VERSION（449.0.0.52.84）这一档**。
 * 一开始我照 App 里另一处 UA 常量填了 448.0.0.52.84，订阅直接被判
 * Iris_IrisValidationException —— 版本号不在对端认可的客户端清单里。
 * 同一档的 version_code = 1079242191（见 App 的 MobileConfig.APP_SETTINGS）。
 */
const APP_VERSION = '449.0.0.52.84';

/* ------------------------------------------------------------- Thrift Compact */

const T_STOP = 0x00;
const T_TRUE = 0x01;
const T_FALSE = 0x02;
const T_BYTE = 0x03;
const T_I32 = 0x05;
const T_I64 = 0x06;
const T_BINARY = 0x08;
const T_LIST = 0x09;
const T_MAP = 0x0B;
const T_STRUCT = 0x0C;

/** zigzag：不能用 `<<`（32 位），这些值都在 2^53 内，按数学定义算。 */
function zigzag(value) {
  return value >= 0 ? value * 2 : -value * 2 - 1;
}

class ThriftWriter {
  constructor() {
    this.bytes = [];
    this.fieldStack = [];
    this.field = 0;
  }

  writeVarint(value) {
    let rest = Math.floor(value);
    for (;;) {
      const next = Math.floor(rest / 128);
      if (next === 0) {
        this.bytes.push(rest & 0x7F);
        return;
      }
      this.bytes.push((rest & 0x7F) | 0x80);
      rest = next;
    }
  }

  writeField(field, type) {
    const delta = field - this.field;
    const kind = type & 0x0F;
    if (delta > 0 && delta <= 15) {
      this.bytes.push((delta << 4) | kind);
    } else {
      this.bytes.push(kind);
      this.writeVarint(zigzag(field));
    }
    this.field = field;
  }

  pushStruct(field) {
    this.writeField(field, T_STRUCT);
    this.fieldStack.push(this.field);
    this.field = 0;
  }

  writeStop() {
    this.bytes.push(T_STOP);
    const previous = this.fieldStack.pop();
    if (previous !== undefined) {
      this.field = previous;
    }
  }

  writeStringDirect(text) {
    const raw = Buffer.from(text, 'utf8');
    this.writeVarint(raw.length);
    for (const byte of raw) {
      this.bytes.push(byte);
    }
  }

  writeString(field, text) {
    this.writeField(field, T_BINARY);
    this.writeStringDirect(text);
  }

  writeBool(field, value) {
    this.writeField(field, value ? T_TRUE : T_FALSE);
  }

  writeInt(field, value, bits) {
    const type = bits === 8 ? T_BYTE : (bits === 64 ? T_I64 : T_I32);
    this.writeField(field, type);
    if (bits === 8) {
      this.bytes.push(value & 0xFF);
    } else {
      this.writeVarint(zigzag(value));
    }
  }

  writeIntList(field, values) {
    this.writeField(field, T_LIST);
    if (values.length < 0x0F) {
      this.bytes.push((values.length << 4) | T_I32);
    } else {
      this.bytes.push(0xF0 | T_I32);
      this.writeVarint(values.length);
    }
    for (const value of values) {
      this.writeVarint(zigzag(value));
    }
  }

  writeBinaryMap(field, keys, values) {
    this.writeField(field, T_MAP);
    this.writeVarint(keys.length);
    if (keys.length === 0) return;
    this.bytes.push((T_BINARY << 4) | T_BINARY);
    for (let index = 0; index < keys.length; index++) {
      this.writeStringDirect(keys[index]);
      this.writeStringDirect(values[index]);
    }
  }
}

/* ------------------------------------------------------------------ 报文组装 */

/** MQTT 的"剩余长度" varint（最多 4 字节）。 */
function pushRemaining(out, length) {
  let left = length;
  do {
    let digit = left % 128;
    left = Math.floor(left / 128);
    if (left > 0) digit = digit | 0x80;
    out.push(digit);
  } while (left > 0);
}

/**
 * `appSpecificInfo`（instagrapi 的 build_connection 里那一份，**键序也照抄**）。
 *
 * 服务端会读里面的 `app_version` / `User-Agent` / `everclear_subscriptions` 等做判据，
 * 少一项都可能被判成"非官方客户端"。
 */
function writeAppSpecificInfo(writer, identity) {
  const everclear = '{"inapp_notification_subscribe_comment":"17899377895239777",'
    + '"inapp_notification_subscribe_comment_mention_and_reply":"17899377895239777",'
    + '"video_call_participant_state_delivery":"17977239895057311",'
    + '"presence_subscribe":"17846944882223835"}';
  writer.writeBinaryMap(10, [
    'app_version',
    'X-IG-Capabilities',
    'everclear_subscriptions',
    'User-Agent',
    'Accept-Language',
    'platform',
    'ig_mqtt_route',
    'pubsub_msg_type_blacklist',
    'auth_cache_enabled'
  ], [
    identity.appVersion,
    '3brTv10=',
    everclear,
    identity.userAgent,
    identity.locale.replace('_', '-'),
    'android',
    'django',
    'direct, typing_type',
    '0'
  ]);
}

/** 组 CONNECT（`0x10 <len>` + `MQTToT` + 级别 3 + flags + keepalive + zlib(Thrift)）。 */
function buildConnect(identity, keepAliveSeconds) {
  const writer = new ThriftWriter();
  writer.writeString(1, identity.phoneId.slice(0, 20));
  writer.pushStruct(4);
  writer.writeInt(1, Number(identity.userId), 64);
  writer.writeString(2, identity.userAgent);
  writer.writeInt(3, 183, 64);        // clientCapabilities
  writer.writeInt(4, 0, 64);          // endpointCapabilities
  writer.writeInt(5, 1, 32);          // publishFormat
  writer.writeBool(6, false);         // noAutomaticForeground
  writer.writeBool(7, true);          // makeUserAvailableInForeground
  writer.writeString(8, identity.phoneId);
  writer.writeBool(9, true);          // isInitiallyForeground
  writer.writeInt(10, 1, 32);         // networkType = wifi
  writer.writeInt(11, 0, 32);         // networkSubtype
  writer.writeInt(12, Date.now() % 4294967296, 64); // clientMqttSessionId
  writer.writeIntList(14, SUBSCRIBE_TOPICS);
  writer.writeString(15, 'cookie_auth');
  writer.writeInt(16, MQTT_APP_ID, 64);
  writer.writeString(20, '');         // deviceSecret（空串也要发）
  writer.writeInt(21, 3, 8);          // clientStack
  writer.writeStop();
  // 5: password —— 网页会话直接当密码用，这是 cookie_auth 的核心。
  writer.writeString(5, `sessionid=${identity.sessionId}`);
  writeAppSpecificInfo(writer, identity);
  writer.writeStop();

  const payload = zlib.deflateSync(Buffer.from(writer.bytes));
  const body = [];
  body.push(0x00, 0x06, 0x4D, 0x51, 0x54, 0x54, 0x6F, 0x54); // "\x00\x06MQTToT"
  body.push(0x03);
  body.push(0xC2);                    // clean session + will（照抄 instagrapi）
  body.push((keepAliveSeconds >> 8) & 0xFF, keepAliveSeconds & 0xFF);
  for (const byte of payload) body.push(byte);

  const out = [0x10];
  pushRemaining(out, body.length);
  for (const byte of body) out.push(byte);
  return Buffer.from(out);
}

/** 组 PUBLISH（QoS 1）。 */
function buildPublish(topic, payload, packetId) {
  const topicBytes = Buffer.from(topic, 'utf8');
  const body = [];
  body.push((topicBytes.length >> 8) & 0xFF, topicBytes.length & 0xFF);
  for (const byte of topicBytes) body.push(byte);
  body.push((packetId >> 8) & 0xFF, packetId & 0xFF);
  for (const byte of payload) body.push(byte);
  const out = [0x32];                 // PUBLISH + QoS 1
  pushRemaining(out, body.length);
  for (const byte of body) out.push(byte);
  return Buffer.from(out);
}

function buildPuback(packetId) {
  return Buffer.from([0x40, 0x02, (packetId >> 8) & 0xFF, packetId & 0xFF]);
}

function buildPingreq() {
  return Buffer.from([0xC0, 0x00]);
}

/* ---------------------------------------------------------------- 分帧 + 解码 */

/**
 * 从字节流里切出完整报文。
 *
 * socket 的 data 事件是**字节流**，不保证一条事件一条报文（大私信会被拆，小包会粘）。
 * 少了这一层，超过几 KB 的消息会永远解析失败（App 侧同一处踩过，见 MobileRealtime 文件头）。
 */
class FrameReader {
  constructor() {
    this.buffer = Buffer.alloc(0);
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const packets = [];
    for (;;) {
      if (this.buffer.length < 2) break;
      let multiplier = 1;
      let remaining = 0;
      let offset = 1;
      let complete = false;
      while (offset < this.buffer.length && offset <= 4) {
        const byte = this.buffer[offset];
        remaining += (byte & 0x7F) * multiplier;
        multiplier *= 128;
        offset++;
        if ((byte & 0x80) === 0) {
          complete = true;
          break;
        }
      }
      if (!complete) break;
      const total = offset + remaining;
      if (this.buffer.length < total) break;
      packets.push(this.buffer.subarray(0, total));
      this.buffer = this.buffer.subarray(total);
    }
    return packets;
  }
}

/** 认一条报文：类型、CONNACK 返回码、PUBLISH 的 topic/packetId/载荷。 */
function decodePacket(bytes) {
  const type = bytes[0] >> 4;
  let offset = 1;
  let remaining = 0;
  let multiplier = 1;
  while (offset < bytes.length && offset <= 4) {
    const byte = bytes[offset];
    remaining += (byte & 0x7F) * multiplier;
    multiplier *= 128;
    offset++;
    if ((byte & 0x80) === 0) break;
  }
  if (type === 2 && offset + 1 < bytes.length) {
    return { type: 'connack', returnCode: bytes[offset + 1] };
  }
  if (type === 3) {
    const qos = (bytes[0] >> 1) & 0x03;
    let cursor = offset;
    let topic = '';
    if (cursor + 2 <= bytes.length) {
      const topicLen = (bytes[cursor] << 8) | bytes[cursor + 1];
      cursor += 2;
      if (cursor + topicLen <= bytes.length) {
        topic = bytes.subarray(cursor, cursor + topicLen).toString('utf8');
        cursor += topicLen;
      }
    }
    let packetId = -1;
    if (qos > 0 && cursor + 2 <= bytes.length) {
      packetId = (bytes[cursor] << 8) | bytes[cursor + 1];
      cursor += 2;
    }
    return { type: 'publish', topic, packetId, payload: bytes.subarray(cursor) };
  }
  if (type === 13) return { type: 'pingresp' };
  return { type: 'other', code: type };
}

/* ------------------------------------------------------------ 设备身份（持久化） */

/**
 * MQTT 的 "设备身份"：`clientIdentifier` 取它前 20 字符，`deviceId` 用它全串。
 *
 * **必须跨重启稳定**，否则每次连上都像一台新设备；同时也**故意不用 App 那台的身份**：
 * 两个客户端共用一个 deviceId 会被对端当成同一台设备而互相踢掉。
 * 所以这里单独存一份（`mqtt-device.json`），首次随机生成，之后一直沿用。
 */
function loadDeviceId(dir) {
  const file = path.join(dir, 'mqtt-device.json');
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (data && typeof data.phoneId === 'string' && data.phoneId.length >= 16) {
      return data.phoneId;
    }
  } catch (error) {
    // 第一次跑
  }
  // 形如 android-<uuid4>，长度足够切片也不会撞。
  const uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const random = Math.floor(Math.random() * 16);
    const value = ch === 'x' ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
  const phoneId = `android-${uuid}`;
  try {
    fs.writeFileSync(file, JSON.stringify({ phoneId, createdAt: Date.now() }, null, 2), 'utf8');
  } catch (error) {
    // 落盘失败也能继续跑（下次会换一个身份）
  }
  return phoneId;
}

/* ------------------------------------------------------------------ 客户端 */

/**
 * 实时通道客户端。事件式：`on('up')` / `on('down')` / `on('event', topic, text)`。
 *
 * 只做"连上 + 订阅 + 收帧"，**不解析消息内容**（见文件头"只当触发器"）。
 */
class RealtimeClient {
  /**
   * @param options.sessionId IG 的 sessionid（cookie 里那个，已 decode 过）
   * @param options.userId    ds_user_id
   * @param options.deviceDir 放 mqtt-device.json 的目录
   * @param options.log       日志函数（默认 console.log）
   */
  constructor(options) {
    this.sessionId = options.sessionId;
    this.userId = options.userId;
    this.deviceDir = options.deviceDir;
    this.log = options.log || ((text) => console.log(text));
    this.identity = null;
    this.socket = null;
    this.reader = new FrameReader();
    this.up = false;
    this.closed = false;
    this.packetId = Math.floor(Math.random() * 1000) + 1;
    this.pingTimer = null;
    this.connack = -1;
    this.handlers = { up: [], down: [], event: [], subscribe: [] };
    this.stats = { frames: 0, packets: 0, events: 0, since: Date.now() };
  }

  on(name, fn) {
    if (this.handlers[name]) this.handlers[name].push(fn);
    return this;
  }

  emit(name, ...args) {
    for (const fn of this.handlers[name] || []) {
      try {
        fn(...args);
      } catch (error) {
        this.log(`[realtime] handler ${name} threw: ${error.message}`);
      }
    }
  }

  /** 连上去（返回 Promise：CONNACK rc=0 才算成功）。 */
  connect(timeoutMs = 15000) {
    if (this.identity === null) {
      this.identity = {
        phoneId: loadDeviceId(this.deviceDir),
        userId: this.userId,
        sessionId: this.sessionId,
        userAgent: MOBILE_UA,
        appVersion: APP_VERSION,
        locale: 'en_US'
      };
    }
    this.closed = false;
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        if (error) reject(error);
        else resolve(true);
      };
      const socket = tls.connect({
        host: MQTT_HOST,
        port: MQTT_PORT,
        servername: MQTT_HOST,
        // 对端只认它自己的证书链，校验失败就是真的有问题（别关校验）
        rejectUnauthorized: true,
        minVersion: 'TLSv1.2'
      });
      this.socket = socket;
      const timer = setTimeout(() => {
        finish(new Error('CONNACK 超时'));
      }, timeoutMs);

      socket.on('secureConnect', () => {
        const packet = buildConnect(this.identity, KEEPALIVE_SECONDS);
        socket.write(packet);
      });
      socket.on('data', (chunk) => {
        for (const raw of this.reader.push(chunk)) {
          const packet = decodePacket(raw);
          this.stats.packets++;
          if (packet.type === 'connack') {
            this.connack = packet.returnCode;
            clearTimeout(timer);
            if (packet.returnCode === 0) {
              this.up = true;
              this.startHeartbeat();
              this.emit('up');
              finish(null);
            } else {
              finish(new Error(`CONNACK rc=${packet.returnCode}`));
            }
            continue;
          }
          if (packet.type === 'publish') {
            this.handlePublish(packet);
            continue;
          }
          // pingresp / other：不用管
        }
      });
      const drop = (reason) => {
        clearTimeout(timer);
        this.stopHeartbeat();
        const wasUp = this.up;
        this.up = false;
        if (wasUp) this.emit('down', reason);
        finish(new Error(reason));
      };
      socket.on('error', (error) => drop(`socket error: ${error.message}`));
      socket.on('close', () => drop('socket closed'));
    });
  }

  handlePublish(packet) {
    if (packet.packetId >= 0) {
      try {
        this.socket.write(buildPuback(packet.packetId));
      } catch (error) {
        // 回不了 PUBACK 也不要紧，下一帧还会来
      }
    }
    let text = '';
    try {
      // IG 的载荷是 zlib 压缩的（也可能有个别不压缩）；两种都试。
      text = zlib.inflateSync(packet.payload).toString('utf8');
    } catch (error) {
      text = packet.payload.toString('utf8');
    }
    this.stats.frames++;
    if (packet.topic === TOPIC_SUBSCRIBE_RESULT) {
      this.emit('subscribe', text);
      return;
    }
    if (DIRECT_TOPICS.indexOf(packet.topic) >= 0) {
      this.stats.events++;
      this.emit('event', packet.topic, text);
    }
  }

  startHeartbeat() {
    this.stopHeartbeat();
    this.pingTimer = setInterval(() => {
      if (!this.up || this.socket === null) return;
      try {
        this.socket.write(buildPingreq());
      } catch (error) {
        this.log(`[realtime] ping failed: ${error.message}`);
      }
    }, KEEPALIVE_SECONDS * 1000);
    // 心跳定时器不该拖住进程退出
    if (typeof this.pingTimer.unref === 'function') this.pingTimer.unref();
  }

  stopHeartbeat() {
    if (this.pingTimer !== null) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  /** 发一条 JSON（内部 zlib 压缩，同 instagrapi 的 publish_json）。 */
  publishJson(topic, json) {
    if (!this.up || this.socket === null) return false;
    this.packetId = this.packetId >= 0xFFFF ? 1 : this.packetId + 1;
    try {
      this.socket.write(buildPublish(topic, zlib.deflateSync(Buffer.from(json, 'utf8')), this.packetId));
      return true;
    } catch (error) {
      this.log(`[realtime] publish failed: ${error.message}`);
      return false;
    }
  }

  /**
   * 订阅私信实时同步（instagrapi 的 `iris_subscribe`）。
   *
   * `snapshotAppVersion` **必须**和拿 seq_id 那次用的客户端版本一致，否则对端会回
   * `Resnapshot for app upgrade`（App 侧实测）。
   */
  subscribeDirect(seqId, snapshotAtMs, snapshotAppVersion) {
    const body = JSON.stringify({
      seq_id: Number(seqId),
      snapshot_at_ms: Number(snapshotAtMs),
      snapshot_app_version: String(snapshotAppVersion || APP_VERSION)
    });
    const sent = this.publishJson(TOPIC_IRIS_SUBSCRIBE, body);
    this.log(`[realtime] iris_subscribe seq=${seqId} snapshot=${snapshotAtMs} sent=${sent}`);
    return sent;
  }

  close() {
    this.closed = true;
    this.stopHeartbeat();
    this.up = false;
    if (this.socket !== null) {
      try {
        this.socket.end();
        this.socket.destroy();
      } catch (error) {
        // 忽略
      }
      this.socket = null;
    }
  }
}

module.exports = {
  RealtimeClient,
  loadDeviceId,
  buildConnect,
  buildPublish,
  decodePacket,
  FrameReader,
  APP_VERSION,
  MOBILE_UA,
  MQTT_HOST,
  MQTT_PORT
};
