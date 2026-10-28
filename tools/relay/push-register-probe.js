'use strict';
/* push/register/ 字段试错：uuid 来源、family_device_id、bool 形式、App-ID。 */
const fs = require('fs');
const https = require('https');
const querystring = require('querystring');
const { loadDeviceIdentity } = require('./realtime.js');

const DIR = 'C:/HMStudy/Instamony/tools/relay';
const cfg = JSON.parse(fs.readFileSync(DIR + '/config.json', 'utf8'));
const cookie = cfg.ig.cookie;
const authFile = JSON.parse(fs.readFileSync(DIR + '/fbns-auth.json', 'utf8'));
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
const igAuth = 'Bearer IGT:2:' + Buffer.from(JSON.stringify({
  ds_user_id: dsUserId,
  sessionid: decodeURIComponent(pick('sessionid')),
  should_use_header_over_cookies: true
})).toString('base64url');

// 用 fbns-test 里同样的方式拿一个 token（这里直接复用 broker 一次）
const { FbnsClient } = require('./fbns.js');

function uuid4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const r = Math.floor(Math.random() * 16);
    return (ch === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function post(form, appId, mode) {
  return new Promise((resolve) => {
    const kind = mode || 'form';
    let body;
    let contentType = 'application/x-www-form-urlencoded';
    if (kind === 'signed') {
      const payload = JSON.stringify(form);
      body = 'signed_body=SIGNATURE.' + encodeURIComponent(payload);
    } else if (kind === 'json') {
      body = JSON.stringify(form);
      contentType = 'application/json; charset=UTF-8';
    } else {
      body = querystring.stringify(form);
    }
    const req = https.request({
      hostname: 'i.instagram.com',
      path: '/api/v1/push/register/',
      method: 'POST',
      headers: {
        Cookie: cookie,
        Authorization: igAuth,
        'User-Agent': 'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; o1s; exynos2100; en_US; 1079242191)',
        'X-IG-App-ID': appId,
        'X-IG-Capabilities': '3brTv10=',
        'X-IG-Connection-Type': 'WIFI',
        'X-IG-WWW-Claim': '0',
        'X-IG-Device-ID': device.uuid,
        'X-IG-Android-ID': device.androidId,
        'X-IG-Family-Device-ID': device.phoneId,
        'X-CSRFToken': pick('csrftoken'),
        'Content-Type': contentType,
        'Content-Length': Buffer.byteLength(body),
        Accept: '*/*'
      }
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { raw += c; });
      res.on('end', () => resolve({ code: res.statusCode, body: raw.slice(0, 240) }));
    });
    req.on('error', (e) => resolve({ code: -1, body: e.message }));
    req.write(body);
    req.end();
  });
}

(async () => {
  const client = new FbnsClient({ stateDir: DIR, clientId: authFile.clientId, userId: authFile.userId, log: () => {} });
  let token = '';
  client.on('registered', (p) => { token = p && p.token ? String(p.token) : ''; });
  await client.connect();
  client.requestPushToken();
  for (let i = 0; i < 30 && token === ''; i++) {
    await new Promise((r) => setTimeout(r, 300));
  }
  client.close();
  if (token === '') { console.log('没拿到 token，中止'); process.exit(1); }
  console.log('token 长度 =', token.length);

  const base = {
    device_type: 'android_mqtt',
    device_sub_type: '2',
    device_token: token,
    _csrftoken: pick('csrftoken'),
    users: dsUserId
  };
  const variants = [
    ['A ig_did + bool true + 默认 appId', Object.assign({}, base, { is_main_push_channel: 'true', guid: pick('ig_did') || device.uuid, uuid: pick('ig_did') || device.uuid, family_device_id: uuid4() }), '567067343352427'],
    ['B device.uuid + True 大写', Object.assign({}, base, { is_main_push_channel: 'True', guid: device.uuid, uuid: device.uuid, family_device_id: uuid4() }), '567067343352427'],
    ['C device.uuid + appId=567310203415052', Object.assign({}, base, { is_main_push_channel: 'true', guid: device.uuid, uuid: device.uuid, family_device_id: uuid4() }), '567310203415052'],
    ['D device.uuid + family=device.phoneId', Object.assign({}, base, { is_main_push_channel: 'true', guid: device.uuid, uuid: device.uuid, family_device_id: device.phoneId }), '567067343352427'],
    ['E 加 _uid + device.uuid', Object.assign({}, base, { is_main_push_channel: 'true', guid: device.uuid, uuid: device.uuid, family_device_id: uuid4(), _uid: dsUserId }), '567067343352427']
  ];
  for (const [label, form, appId] of variants) {
    const r = await post(form, appId);
    console.log(`${label} → HTTP ${r.code} ${r.body}`);
  }
  const baseF = Object.assign({}, base, {
    is_main_push_channel: true, guid: device.uuid, uuid: device.uuid, family_device_id: uuid4()
  });
  const rF = await post(baseF, '567067343352427', 'signed');
  console.log('F signed_body + bool true → HTTP ' + rF.code + ' ' + rF.body);
  const rG = await post(baseF, '567067343352427', 'json');
  console.log('G JSON body → HTTP ' + rG.code + ' ' + rG.body);
  const baseH = Object.assign({}, baseF, { device_id: device.phoneId, phone_id: device.phoneId });
  const rH = await post(baseH, '567067343352427', 'signed');
  console.log('H signed + device_id/phone_id → HTTP ' + rH.code + ' ' + rH.body);

  // FBNS 下发的内部 id（ck）与设备 id（di）当作 users/guid
  let innerToken = token;
  try {
    const parsedToken = JSON.parse(token);
    if (parsedToken && parsedToken.k) innerToken = String(parsedToken.k);
  } catch (error) {
    // 保持原样
  }
  const baseI = {
    device_type: 'android_mqtt',
    is_main_push_channel: true,
    device_sub_type: 2,
    device_token: innerToken,
    _csrftoken: pick('csrftoken'),
    guid: authFile.deviceId,
    uuid: authFile.deviceId,
    users: String(authFile.userId),
    family_device_id: authFile.deviceId
  };
  const rI = await post(baseI, '567067343352427', 'signed');
  console.log('I users=ck, guid=di, token=内层 k → HTTP ' + rI.code + ' ' + rI.body);
  const baseJ = Object.assign({}, baseI, { device_token: token, family_device_id: uuid4() });
  const rJ = await post(baseJ, '567067343352427', 'form');
  console.log('J users=ck, token=整串, form → HTTP ' + rJ.code + ' ' + rJ.body);
  process.exit(0);
})();
