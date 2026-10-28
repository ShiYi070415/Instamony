'use strict';
/*
 * 用 **instagrapi 的完整头集**重试 push/register/。
 *
 * 差异点：instagrapi 的 private_headers 会带 IG-U-*、IG-INTENDED-USER-ID、X-MID、
 * X-FB-Client-IP / X-FB-Server-Cluster、X-Pigeon-*、X-IG-Bandwidth-* 等约 40 个头。
 * 我们之前只发了 12 个 —— 400 Invalid request 很可能就是这个原因。
 */
const fs = require('fs');
const https = require('https');
const querystring = require('querystring');
const { loadDeviceIdentity } = require('./realtime.js');
const { FbnsClient, MOBILE_UA } = require('./fbns.js');

const DIR = 'C:/HMStudy/Instamony/tools/relay';
const cfg = JSON.parse(fs.readFileSync(DIR + '/config.json', 'utf8'));
const cookie = cfg.ig.cookie;
const fbnsAuth = JSON.parse(fs.readFileSync(DIR + '/fbns-auth.json', 'utf8'));
const device = loadDeviceIdentity(DIR);

const pick = (n) => {
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === n) return part.slice(eq + 1).trim();
  }
  return '';
};
const dsUserId = pick('ds_user_id');
const csrf = pick('csrftoken');
const mid = pick('mid');
const rur = decodeURIComponent(pick('rur'));
const igAuth = 'Bearer IGT:2:' + Buffer.from(JSON.stringify({
  ds_user_id: dsUserId,
  sessionid: decodeURIComponent(pick('sessionid')),
  should_use_header_over_cookies: true
})).toString('base64url');

function uuid4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const r = Math.floor(Math.random() * 16);
    return (ch === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

/** instagrapi base_headers 的完整复刻（只保留能自洽的字段）。 */
function fullHeaders(deviceIdOverride, appIdOverride) {
  const now = new Date();
  const tzOffset = -now.getTimezoneOffset() * 60;
  const nextYear = Math.floor(Date.now() / 1000) + 31536000;
  return {
    Cookie: cookie,
    Authorization: igAuth,
    'X-IG-App-Locale': 'en_US',
    'X-IG-Device-Locale': 'en_US',
    'X-IG-Mapped-Locale': 'en_US',
    'X-Pigeon-Session-Id': 'UFS-' + uuid4() + '-1',
    'X-Pigeon-Rawclienttime': (Date.now() / 1000).toFixed(3),
    'X-IG-Bandwidth-Speed-KBPS': '-1.000',
    'X-IG-Bandwidth-TotalBytes-B': '0',
    'X-IG-Bandwidth-TotalTime-MS': '0',
    'X-IG-App-Startup-Country': 'US',
    'X-Bloks-Version-Id': '799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b',
    'X-IG-WWW-Claim': '0',
    'X-Bloks-Is-Layout-RTL': 'false',
    'X-Bloks-Is-Panorama-Enabled': 'true',
    'X-IG-Device-ID': deviceIdOverride || device.uuid,
    'X-IG-Family-Device-ID': deviceIdOverride || device.phoneId,
    'X-IG-Android-ID': deviceIdOverride || device.androidId,
    'X-IG-Timezone-Offset': String(tzOffset),
    'X-IG-Connection-Type': 'WIFI',
    'X-IG-Capabilities': '3brTv10=',
    'X-IG-App-ID': appIdOverride || '567067343352427',
    Priority: 'u=3',
    'User-Agent': MOBILE_UA,
    'Accept-Language': 'en-US, en',
    'X-MID': mid,
    'X-FB-HTTP-Engine': 'Tigon/MNS/TCP',
    'X-Tigon-Is-Retry': 'False',
    'X-Zero-Balance': 'INIT',
    'X-Zero-State': 'unknown',
    'Zero-HTTP-Network-Interface': 'wifi',
    Connection: 'keep-alive',
    'X-FB-Client-IP': 'True',
    'X-FB-Server-Cluster': 'True',
    'IG-INTENDED-USER-ID': dsUserId,
    'X-IG-Nav-Chain': '9MV:self_profile:2,ProfileMediaTabFragment:self_profile:3,9Xf:self_following:4',
    'IG-U-DS-USER-ID': dsUserId,
    'IG-U-RUR': rur,
    'IG-U-SHBID': `12695,${dsUserId},${nextYear}:01f778d9c9f7546cf3722578fbf9b85143cd6e5132723e5c93f40f55ca0459c8ef8a0d9f`,
    'IG-U-SHBTS': `${Math.floor(Date.now() / 1000)},${dsUserId},${nextYear}:01f7ace11925d0388080078d0282b75b8059844855da27e23c90a362270fddfb3fae7e28`,
    'IG-U-IG-DIRECT-REGION-HINT': `LLA,${dsUserId},${nextYear}:01f7bae7d8b131877d8e0ae1493252280d72f6d0d554447cb1dc9049b6b2c507c08605b7`,
    Accept: '*/*',
    'X-CSRFToken': csrf,
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'
  };
}

function postForm(form, deviceIdOverride, appIdOverride) {
  return new Promise((resolve) => {
    const body = querystring.stringify(form);
    const headers = fullHeaders(deviceIdOverride, appIdOverride);
    headers['Content-Length'] = Buffer.byteLength(body);
    const req = https.request({
      hostname: 'i.instagram.com',
      path: '/api/v1/push/register/',
      method: 'POST',
      headers: headers
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { raw += c; });
      res.on('end', () => resolve({ code: res.statusCode, body: raw.slice(0, 300) }));
    });
    req.on('error', (e) => resolve({ code: -1, body: e.message }));
    req.write(body);
    req.end();
  });
}

(async () => {
  const client = new FbnsClient({ stateDir: DIR, clientId: fbnsAuth.clientId, userId: fbnsAuth.userId, log: () => {} });
  let token = '';
  client.on('registered', (p) => { token = p && p.token ? String(p.token) : ''; if (p && p.error) console.log('broker 报错: ' + p.error); });
  await client.connect();
  client.requestPushToken();
  for (let i = 0; i < 40 && token === ''; i++) await new Promise((r) => setTimeout(r, 300));
  client.close();
  if (token === '') { console.log('没拿到 token'); process.exit(1); }

  const variants = [
    ['完整头 + form（照 instagrapi）', {
      device_type: 'android_mqtt',
      is_main_push_channel: true,
      device_sub_type: 2,
      device_token: token,
      _csrftoken: csrf,
      guid: device.uuid,
      uuid: device.uuid,
      users: dsUserId,
      family_device_id: uuid4()
    }],
    ['完整头 + signed_body', null]
  ];

  const form = variants[0][1];
  const r1 = await postForm(form);
  console.log('完整头 + form → HTTP ' + r1.code + ' ' + r1.body);

  // signed_body 变体
  const signedBody = 'signed_body=SIGNATURE.' + encodeURIComponent(JSON.stringify(form));
  const r2 = await new Promise((resolve) => {
    const headers = fullHeaders();
    headers['Content-Length'] = Buffer.byteLength(signedBody);
    const req = https.request({
      hostname: 'i.instagram.com',
      path: '/api/v1/push/register/',
      method: 'POST',
      headers: headers
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { raw += c; });
      res.on('end', () => resolve({ code: res.statusCode, body: raw.slice(0, 300) }));
    });
    req.on('error', (e) => resolve({ code: -1, body: e.message }));
    req.write(signedBody);
    req.end();
  });
  console.log('完整头 + signed_body → HTTP ' + r2.code + ' ' + r2.body);

  // 让请求头里的设备 id 与 token 内部的 di（FBNS 设备 id）一致
  const fbnsDeviceId = fbnsAuth.deviceId;
  const consistent = {
    device_type: 'android_mqtt',
    is_main_push_channel: true,
    device_sub_type: 2,
    device_token: token,
    _csrftoken: csrf,
    guid: fbnsDeviceId,
    uuid: fbnsDeviceId,
    users: dsUserId,
    family_device_id: fbnsDeviceId
  };
  const r3 = await postForm(consistent, fbnsDeviceId);
  console.log('设备 id 与 token 一致（' + fbnsDeviceId + '）→ HTTP ' + r3.code + ' ' + r3.body);

  const withCk = Object.assign({}, consistent, { users: String(fbnsAuth.userId) });
  const r4 = await postForm(withCk, fbnsDeviceId);
  console.log('同上但 users=ck → HTTP ' + r4.code + ' ' + r4.body);

  // FBNS 那个 app id 作为 X-IG-App-ID（token 内部 ai 就是它）
  const r5 = await postForm(consistent, fbnsDeviceId, '567310203415052');
  console.log('X-IG-App-ID=567310203415052 → HTTP ' + r5.code + ' ' + r5.body);

  // is_main_push_channel 用数字 1
  const numeric = Object.assign({}, consistent, { is_main_push_channel: 1, device_sub_type: 2 });
  const r6 = await postForm(numeric, fbnsDeviceId, '567310203415052');
  console.log('is_main_push_channel=1 → HTTP ' + r6.code + ' ' + r6.body);
  process.exit(0);
})();
