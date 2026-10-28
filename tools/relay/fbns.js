/*
 * **FBNS 推送通道**（`mqtt-mini.facebook.com`）—— 这是 IG 真正"主动推给服务器"的那条路。
 *
 * ## 为什么它比 iris 有用
 * iris（`edge-mqtt`）那条我们订阅不了（`Iris_IrisValidationException`，见 REALTIME.md）。
 * FBNS 是**另一条独立连接**，用 `clientType: "device_auth"` 而不是 cookie_auth：
 * 连上 → CONNACK 里下发设备凭据（ck/cs/di/ds）→ 订阅 topic 76 → 申请一个 push token →
 * 用 HTTP 把 token 注册给 IG → 之后 IG 就会把推送（`fbpushnotif`，含
 * `collapse_key: "direct_v2_message"`）主动推过来。
 *
 * 出处：instagrapi 的 `realtime/fbns.py`，其官方文档明确写着
 * "Use FBNS when you need Instagram push payloads, for example Direct message
 * notification callbacks."
 *
 * ## 与轮询的关系
 * FBNS 事件到达 = **毫秒级**（IG 主动推）。拿到事件后我们再去拉一次收件箱读出内容后推送
 * （一次 HTTP，约 0.3 秒）。所以端到端从"1~2 秒"变成"亚秒级"。
 * 轮询继续保留作为兜底（FBNS 断线、被降级、或事件类型变了的时候仍然能收到）。
 */

'use strict';

const fs = require('fs');
const path = require('path');
const tls = require('tls');
const zlib = require('zlib');

/** FBNS 的 broker（与 iris 的 edge-mqtt 不是同一台）。 */
const FBNS_HOST = 'mqtt-mini.facebook.com';
const FBNS_PORT = 443;
/** FBNS 自己的 app id（注意：与 iris 的 567067343352427 不同）。 */
const IG_FBNS_APP_ID = 567310203415052;
const FBNS_PACKAGE_NAME = 'com.instagram.android';
/** 连上就订阅的 topic：76=推送消息、80=注册响应、231=实验日志。 */
const FBNS_SUBSCRIBE_TOPICS = [76, 80, 231];
const KEEPALIVE_SECONDS = 60;
/** 移动端 UA（身份的一部分，和拉收件箱用的保持一致）。 */
const MOBILE_UA =
  'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; ' +
  'o1s; exynos2100; en_US; 1079242191)';

/* Thrift Compact（与 realtime.js 同一套，FBNS 的 CONNECT 只是字段不同） */
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
    if (previous !== undefined) this.field = previous;
  }

  writeStringDirect(text) {
    const raw = Buffer.from(text, 'utf8');
    this.writeVarint(raw.length);
    for (const byte of raw) this.bytes.push(byte);
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
    for (const value of values) this.writeVarint(zigzag(value));
  }
}

function pushRemaining(out, length) {
  let left = length;
  do {
    let digit = left % 128;
    left = Math.floor(left / 128);
    if (left > 0) digit = digit | 0x80;
    out.push(digit);
  } while (left > 0);
}

/* ---------------------------------------------------------------- 报文组装 */

/**
 * FBNS 的 CONNECT（`write_connect_packet` + `build_connection`）。
 *
 * 与 iris 的区别就三处：
 *   · `clientType = "device_auth"`、`appId = 567310203415052`；
 *   · `endpointCapabilities = 128`、`noAutomaticForeground = true`、`isInitiallyForeground = false`；
 *   · 带 `deviceSecret` / `fbnsConnectionSecret` / `fbnsDeviceId` / `fbnsDeviceSecret`、`anotherUnknown = -1`。
 */
/**
 * CONNECT 的 **Thrift 载荷**（压缩之前的那一段）。
 *
 * 单独抽出来是为了能被离线对拍：ArkTS 侧用 `zlibStored`（stored 块）替代 Node 的
 * `deflateSync`，两者压缩结果必然不同 —— 但**解压之后必须逐字节一致**，所以真正要比的是
 * 这一段的字节，而不是最终报文。
 *
 * @param nowMs 时间戳（注入是为了让对比可复现）
 */
function buildConnectThrift(auth, nowMs) {
  const writer = new ThriftWriter();
  const clientId = auth.clientId || '';
  writer.writeString(1, clientId.slice(0, 20));
  writer.pushStruct(4);
  writer.writeInt(1, Number(auth.userId || 0), 64);
  writer.writeString(2, MOBILE_UA);
  writer.writeInt(3, 183, 64);
  writer.writeInt(4, 128, 64);          // endpointCapabilities
  writer.writeInt(5, 1, 32);
  writer.writeBool(6, true);            // noAutomaticForeground
  writer.writeBool(7, false);           // makeUserAvailableInForeground
  writer.writeString(8, auth.deviceId || '');
  writer.writeBool(9, false);           // isInitiallyForeground
  writer.writeInt(10, 1, 32);
  writer.writeInt(11, 0, 32);
  writer.writeInt(12, (nowMs === undefined ? Date.now() : nowMs) % 4294967296, 64);
  writer.writeIntList(14, FBNS_SUBSCRIBE_TOPICS);
  writer.writeString(15, 'device_auth');
  writer.writeInt(16, IG_FBNS_APP_ID, 64);
  writer.writeString(20, auth.deviceSecret || '');
  writer.writeInt(21, 3, 8);
  writer.writeInt(26, -1, 64);          // anotherUnknown
  if (auth.password) writer.writeString(23, auth.password);       // fbnsConnectionSecret
  if (auth.deviceId) writer.writeString(24, auth.deviceId);       // fbnsDeviceId
  if (auth.deviceSecret) writer.writeString(25, auth.deviceSecret); // fbnsDeviceSecret
  writer.writeStop();
  writer.writeString(5, auth.password || '');
  writer.writeStop();
  return Buffer.from(writer.bytes);
}

function buildConnect(auth, keepAliveSeconds) {
  const payload = zlib.deflateSync(buildConnectThrift(auth));
  const body = [];
  body.push(0x00, 0x06, 0x4D, 0x51, 0x54, 0x54, 0x6F, 0x54);
  body.push(0x03);
  body.push(0xC2);
  body.push((keepAliveSeconds >> 8) & 0xFF, keepAliveSeconds & 0xFF);
  for (const byte of payload) body.push(byte);
  const out = [0x10];
  pushRemaining(out, body.length);
  for (const byte of body) out.push(byte);
  return Buffer.from(out);
}

/** PUBLISH（QoS1）。 */
function buildPublish(topic, payload, packetId) {
  const topicBytes = Buffer.from(topic, 'utf8');
  const body = [];
  body.push((topicBytes.length >> 8) & 0xFF, topicBytes.length & 0xFF);
  for (const byte of topicBytes) body.push(byte);
  body.push((packetId >> 8) & 0xFF, packetId & 0xFF);
  for (const byte of payload) body.push(byte);
  const out = [0x32];
  pushRemaining(out, body.length);
  for (const byte of body) out.push(byte);
  return Buffer.from(out);
}

/** SUBSCRIBE（QoS1）。 */
function buildSubscribe(topic, packetId) {
  const topicBytes = Buffer.from(topic, 'utf8');
  const body = [];
  body.push((packetId >> 8) & 0xFF, packetId & 0xFF);
  body.push((topicBytes.length >> 8) & 0xFF, topicBytes.length & 0xFF);
  for (const byte of topicBytes) body.push(byte);
  body.push(0x01);                       // 请求的 QoS
  const out = [0x82];
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

/** 分帧（与 realtime.js 同一实现）。 */
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
  const body = bytes.subarray(offset, offset + remaining);
  if (type === 2) {
    return { type: 'connack', returnCode: body.length > 1 ? body[1] : -1, payload: body.subarray(2) };
  }
  if (type === 3) {
    const qos = (bytes[0] >> 1) & 0x03;
    let cursor = 0;
    let topic = '';
    if (body.length >= 2) {
      const topicLen = (body[0] << 8) | body[1];
      cursor = 2;
      if (cursor + topicLen <= body.length) {
        topic = body.subarray(cursor, cursor + topicLen).toString('utf8');
        cursor += topicLen;
      }
    }
    let packetId = -1;
    if (qos > 0 && cursor + 2 <= body.length) {
      packetId = (body[cursor] << 8) | body[cursor + 1];
      cursor += 2;
    }
    return { type: 'publish', topic, packetId, payload: body.subarray(cursor) };
  }
  if (type === 13) return { type: 'pingresp' };
  return { type: 'other', code: type };
}

/**
 * FBNS 的载荷是"2 字节长度前缀 + JSON"（`_strip_length_prefixed_json`）。
 * 先解压，再判断前缀是不是长度，最后当 JSON 解析。
 */
function parsePayload(payload) {
  let body = payload;
  try {
    if (body.length > 0 && body[0] === 0x78) body = zlib.inflateSync(body);
  } catch (error) {
    body = payload;
  }
  if (body.length >= 3) {
    const size = (body[0] << 8) | body[1];
    if (size === body.length - 2 && (body[2] === 0x7B || body[2] === 0x5B)) {
      body = body.subarray(2);
    }
  }
  const text = body.toString('utf8');
  try {
    return JSON.parse(text);
  } catch (error) {
    return text;
  }
}

/* ------------------------------------------------------------------ 客户端 */

class FbnsClient {
  constructor(options) {
    this.stateDir = options.stateDir;
    this.log = options.log || ((text) => console.log(text));
    this.clientId = options.clientId || '';
    this.userId = Number(options.userId || 0);
    this.authFile = path.join(this.stateDir, 'fbns-auth.json');
    this.auth = this.loadAuth();
    this.socket = null;
    this.reader = new FrameReader();
    this.up = false;
    this.packetId = 1;
    this.pingTimer = null;
    this.handlers = { push: [], registered: [], up: [], down: [] };
    this.stats = { pushes: 0, packets: 0 };
  }

  loadAuth() {
    const cookieId = this.clientId || '';
    const fallback = {
      clientId: cookieId.slice(0, 20),
      userId: this.userId,
      password: '',
      deviceId: '',
      deviceSecret: ''
    };
    try {
      const data = JSON.parse(fs.readFileSync(this.authFile, 'utf8'));
      if (data && typeof data.clientId === 'string' && data.clientId.length > 0) {
        return Object.assign(fallback, data);
      }
    } catch (error) {
      // 第一次跑
    }
    return fallback;
  }

  saveAuth() {
    try {
      fs.writeFileSync(this.authFile, JSON.stringify({
        clientId: this.auth.clientId,
        userId: this.auth.userId,
        password: this.auth.password,
        deviceId: this.auth.deviceId,
        deviceSecret: this.auth.deviceSecret,
        savedAt: Date.now()
      }, null, 2), 'utf8');
    } catch (error) {
      this.log('[fbns] 凭据落盘失败：' + error.message);
    }
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
        this.log(`[fbns] handler ${name} threw: ${error.message}`);
      }
    }
  }

  /** 接受 CONNACK 里下发的设备凭据（ck/cs/di/ds）。 */
  absorbAuth(payload) {
    const parsed = parsePayload(payload);
    if (parsed === null || typeof parsed !== 'object') return;
    let changed = false;
    if (parsed.ck !== undefined) {
      this.auth.userId = Number(parsed.ck) || this.auth.userId;
      changed = true;
    }
    if (parsed.cs !== undefined) {
      this.auth.password = String(parsed.cs);
      changed = true;
    }
    if (parsed.di !== undefined) {
      this.auth.deviceId = String(parsed.di);
      this.auth.clientId = this.auth.deviceId.slice(0, 20);
      changed = true;
    }
    if (parsed.ds !== undefined) {
      this.auth.deviceSecret = String(parsed.ds);
      changed = true;
    }
    if (changed) {
      this.saveAuth();
      this.log('[fbns] 已从 CONNACK 拿到设备凭据（deviceId ' + (this.auth.deviceId || '-') + '）');
    }
  }

  /**
   * 连上 FBNS。**两段式**：
   *
   *   · 手上没有设备凭据时，先用**空身份**连一次（`userId=0`、无密码）——
   *     这一发会回 `CONNACK rc=0`，并在回包载荷里下发设备凭据
   *     `{"ck":账号id,"cs":密钥,"di":设备id,"ds":设备密钥}`；落盘后断开；
   *   · 再用这份凭据重连一次（带 deviceSecret / fbnsConnectionSecret 等字段）。
   *
   * 为什么第一次必须留空 userId：实测 `userId=ds_user_id` 或带密码一律回 rc=4
   * （bad user name or password）；留空反而成功。这一条是试出来的，别"顺手改回去"。
   */
  async connect() {
    if (this.auth.deviceId.length === 0) {
      this.log('[fbns] 手上没有设备凭据，先用空身份换一次…');
      const boot = await this.connectOnce({
        clientId: this.auth.clientId || 'android-' + Date.now().toString(16),
        userId: 0,
        password: '',
        deviceId: '',
        deviceSecret: ''
      });
      if (boot.returnCode !== 0) {
        throw new Error('FBNS 引导连接失败：CONNACK rc=' + boot.returnCode);
      }
      this.absorbAuth(boot.payload);
      this.disconnectSocket();
      if (this.auth.deviceId.length === 0) {
        throw new Error('FBNS 引导连接没拿到设备凭据');
      }
    }
    const result = await this.connectOnce(this.auth);
    if (result.returnCode !== 0) {
      throw new Error('FBNS 连接失败：CONNACK rc=' + result.returnCode);
    }
    this.up = true;
    this.startPing();
    this.emit('up');
    return true;
  }

  /** 发一次 CONNECT 并等 CONNACK；成功时返回 {returnCode, payload}（socket 保持连接）。 */
  connectOnce(auth) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error, value) => {
        if (settled) return;
        settled = true;
        if (error) reject(error);
        else resolve(value);
      };
      const socket = tls.connect({
        host: FBNS_HOST,
        port: FBNS_PORT,
        servername: FBNS_HOST,
        rejectUnauthorized: true,
        minVersion: 'TLSv1.2'
      });
      this.socket = socket;
      this.reader = new FrameReader();
      const timer = setTimeout(() => finish(new Error('FBNS CONNACK 超时')), 15000);

      socket.on('secureConnect', () => {
        socket.write(buildConnect(auth, KEEPALIVE_SECONDS));
      });
      socket.on('data', (chunk) => {
        for (const raw of this.reader.push(chunk)) {
          const packet = decodePacket(raw);
          this.stats.packets++;
          if (packet.type === 'connack') {
            clearTimeout(timer);
            finish(null, { returnCode: packet.returnCode, payload: packet.payload });
            continue;
          }
          if (packet.type === 'publish') {
            this.handlePublish(packet);
          }
        }
      });
      const drop = (reason) => {
        clearTimeout(timer);
        this.stopPing();
        const wasUp = this.up;
        this.up = false;
        if (wasUp) this.emit('down', reason);
        finish(new Error(reason));
      };
      socket.on('error', (error) => drop('FBNS socket error: ' + error.message));
      socket.on('close', () => drop('FBNS socket closed'));
    });
  }

  /** 只关 socket，不改 up 状态（引导连接用完就走这里）。 */
  disconnectSocket() {
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

  handlePublish(packet) {
    if (packet.packetId >= 0) {
      try {
        this.socket.write(buildPuback(packet.packetId));
      } catch (error) {
        // 忽略
      }
    }
    const parsed = parsePayload(packet.payload);
    if (packet.topic === '80') {
      this.emit('registered', parsed);
      return;
    }
    if (packet.topic === '76') {
      let push = parsed;
      if (parsed !== null && typeof parsed === 'object' && parsed.fbpushnotif !== undefined) {
        push = parsed.fbpushnotif;
        if (typeof push === 'string') {
          try {
            push = JSON.parse(push);
          } catch (error) {
            push = { value: push };
          }
        }
      }
      this.stats.pushes++;
      this.emit('push', push);
      return;
    }
    // 231 / 34 等：只记一行，便于排查
    this.log('[fbns] topic=' + packet.topic + ' ' + JSON.stringify(parsed).slice(0, 160));
  }

  /** 申请 push token：先 SUBSCRIBE 76，再往 79 发注册请求，响应在 80。 */
  requestPushToken() {
    this.packetId += 1;
    this.socket.write(buildSubscribe('76', this.packetId));
    this.packetId += 1;
    const body = Buffer.from(JSON.stringify({
      pkg_name: FBNS_PACKAGE_NAME,
      appid: IG_FBNS_APP_ID
    }), 'utf8');
    this.socket.write(buildPublish('79', zlib.deflateSync(body), this.packetId));
    return true;
  }

  startPing() {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      if (!this.up || this.socket === null) return;
      try {
        this.socket.write(buildPingreq());
      } catch (error) {
        this.log('[fbns] ping failed: ' + error.message);
      }
    }, 30 * 1000);
    if (typeof this.pingTimer.unref === 'function') this.pingTimer.unref();
  }

  stopPing() {
    if (this.pingTimer !== null) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  close() {
    this.stopPing();
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
  FbnsClient,
  parsePayload,
  IG_FBNS_APP_ID,
  FBNS_HOST,
  FBNS_PORT,
  MOBILE_UA,
  // 报文组装（离线对拍用：见 test-fbns-arkts.js）
  buildConnectThrift,
  buildPublish,
  buildSubscribe,
  buildPuback,
  buildPingreq
};
