'use strict';
/* FBNS 首连试错：clientId 来源 + password 形态，各试一次看 CONNACK 返回码。 */
const fs = require('fs');
const path = require('path');
const tls = require('tls');
const zlib = require('zlib');
const { loadDeviceIdentity } = require('./realtime.js');

const CONFIG = 'C:/HMStudy/Instamony/tools/relay/config.json';
const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
const cookie = cfg.ig.cookie;
const pick = (n) => {
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === n) return part.slice(eq + 1).trim();
  }
  return '';
};
const dsUserId = pick('ds_user_id');
const sessionId = decodeURIComponent(pick('sessionid'));
const device = loadDeviceIdentity('C:/HMStudy/Instamony/tools/relay');

// 复用 fbns.js 的组装函数无法直接传入不同 auth，所以这里最小复制一份连接尝试
const { IG_FBNS_APP_ID, FBNS_HOST, FBNS_PORT, MOBILE_UA } = require('./fbns.js');

const T = { STOP: 0, T: 1, F: 2, BYTE: 3, I32: 5, I64: 6, BIN: 8, LIST: 9, STRUCT: 12 };
const zz = (v) => (v >= 0 ? v * 2 : -v * 2 - 1);
class W {
  constructor() { this.b = []; this.stack = []; this.field = 0; }
  varint(v) { let r = Math.floor(v); for (;;) { const n = Math.floor(r / 128); if (n === 0) { this.b.push(r & 0x7F); return; } this.b.push((r & 0x7F) | 0x80); r = n; } }
  fieldWrite(f, t) { const d = f - this.field; if (d > 0 && d <= 15) this.b.push((d << 4) | (t & 0xF)); else { this.b.push(t & 0xF); this.varint(zz(f)); } this.field = f; }
  pushStruct(f) { this.fieldWrite(f, T.STRUCT); this.stack.push(this.field); this.field = 0; }
  stop() { this.b.push(T.STOP); const p = this.stack.pop(); if (p !== undefined) this.field = p; }
  strDirect(s) { const r = Buffer.from(s, 'utf8'); this.varint(r.length); for (const x of r) this.b.push(x); }
  str(f, s) { this.fieldWrite(f, T.BIN); this.strDirect(s); }
  bool(f, v) { this.fieldWrite(f, v ? T.T : T.F); }
  int(f, v, bits) { const t = bits === 8 ? T.BYTE : (bits === 64 ? T.I64 : T.I32); this.fieldWrite(f, t); if (bits === 8) this.b.push(v & 0xFF); else this.varint(zz(v)); }
  intList(f, vs) { this.fieldWrite(f, T.LIST); this.b.push((vs.length << 4) | T.I32); for (const v of vs) this.varint(zz(v)); }
}

function connectPacket(auth) {
  const w = new W();
  w.str(1, String(auth.clientId).slice(0, 20));
  w.pushStruct(4);
  w.int(1, Number(auth.userId || 0), 64);
  w.str(2, MOBILE_UA);
  w.int(3, 183, 64);
  w.int(4, 128, 64);
  w.int(5, 1, 32);
  w.bool(6, true);
  w.bool(7, false);
  w.str(8, auth.deviceId || '');
  w.bool(9, false);
  w.int(10, 1, 32);
  w.int(11, 0, 32);
  w.int(12, Date.now() % 4294967296, 64);
  w.intList(14, [76, 80, 231]);
  w.str(15, 'device_auth');
  w.int(16, IG_FBNS_APP_ID, 64);
  w.str(20, auth.deviceSecret || '');
  w.int(21, 3, 8);
  w.int(26, -1, 64);
  if (auth.password) w.str(23, auth.password);
  if (auth.deviceId) w.str(24, auth.deviceId);
  if (auth.deviceSecret) w.str(25, auth.deviceSecret);
  w.stop();
  w.str(5, auth.password || '');
  w.stop();
  const payload = zlib.deflateSync(Buffer.from(w.b));
  const body = [0x00, 0x06, 0x4D, 0x51, 0x54, 0x54, 0x6F, 0x54, 0x03, 0xC2, 0x00, 0x3C];
  for (const x of payload) body.push(x);
  const out = [0x10];
  let left = body.length;
  do { let d = left % 128; left = Math.floor(left / 128); if (left > 0) d |= 0x80; out.push(d); } while (left > 0);
  for (const x of body) out.push(x);
  return Buffer.from(out);
}

function attempt(label, auth) {
  return new Promise((resolve) => {
    const sock = tls.connect({ host: FBNS_HOST, port: FBNS_PORT, servername: FBNS_HOST, minVersion: 'TLSv1.2' });
    let done = false;
    const finish = (text) => { if (done) return; done = true; try { sock.destroy(); } catch (e) {} console.log(label + ' → ' + text); resolve(); };
    const timer = setTimeout(() => finish('超时'), 12000);
    sock.on('secureConnect', () => sock.write(connectPacket(auth)));
    sock.on('data', (chunk) => {
      clearTimeout(timer);
      const type = chunk[0] >> 4;
      if (type === 2) {
        // connack: 0x20 len ackflags rc
        const rc = chunk[3];
        const payload = chunk.subarray(4);
        let extra = '';
        if (rc === 0 && payload.length > 4) {
          try { extra = ' 载荷=' + zlib.inflateSync(payload).toString('utf8').slice(0, 200); } catch (e) { extra = ' 载荷(未压缩)=' + payload.toString('utf8').slice(0, 200); }
        }
        finish('CONNACK rc=' + rc + extra);
      } else {
        finish('首个报文 type=' + type);
      }
    });
    sock.on('error', (e) => { clearTimeout(timer); finish('socket error: ' + e.message); });
  });
}

(async () => {
  console.log('设备身份：phoneId=' + device.phoneId + ' uuid=' + device.uuid);
  await attempt('A clientId=phoneId[:20], userId=ds_user_id, 无密码',
    { clientId: device.phoneId, userId: dsUserId, password: '', deviceId: '', deviceSecret: '' });
  await attempt('B clientId=device.uuid[:20], userId=ds_user_id, 无密码',
    { clientId: device.uuid, userId: dsUserId, password: '', deviceId: '', deviceSecret: '' });
  await attempt('C clientId=phoneId[:20], password=sessionid',
    { clientId: device.phoneId, userId: dsUserId, password: sessionId, deviceId: '', deviceSecret: '' });
  await attempt('D clientId=phoneId[:20], deviceId=phoneId, 无密码',
    { clientId: device.phoneId, userId: dsUserId, password: '', deviceId: device.phoneId, deviceSecret: '' });
  await attempt('E clientId=phoneId[:20], userId 留空',
    { clientId: device.phoneId, userId: 0, password: '', deviceId: '', deviceSecret: '' });
  process.exit(0);
})();
