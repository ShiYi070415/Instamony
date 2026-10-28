/*
 * **IG 密码登录**（`node relay.js --login-password`）。
 *
 * ## 为什么需要它
 * 前面查清了：IG 的两条"设备信任"通道 —— iris 实时订阅（`edge-mqtt`）和 FBNS 推送注册
 * （`mqtt-mini`）—— 都不接受"网页 Cookie 派生"的会话。只有**真机登录过一次**的会话
 * 才能进这两条路（instagrapi / instagram_mqtt 的用户能用，正因为他们都是密码登录）。
 * 所以要亚秒级推送，就绕不开这一步。
 *
 * ## 密码怎么加密（`#PWD_INSTAGRAM:4:`）
 * IG 不用明文传输，也不是简单 RSA 加密，而是"RSA 传会话密钥 + AES-GCM 传密码"：
 *   1. `GET /api/v1/qe/sync/` 的**响应头**里给出公钥和 key id
 *      （`ig-set-password-encryption-pub-key` / `-key-id`）；
 *   2. 随机 32 字节 session_key、12 字节 iv；
 *   3. 用公钥 RSA/PKCS1v1.5 加密 session_key；
 *   4. 用 session_key + iv 做 AES-256-GCM 加密密码，**AAD 是时间戳**；
 *   5. 拼 `\x01 + keyid(1B) + iv(12B) + len(rsa)(2B,LE) + rsa + tag(16B) + 密文`，base64；
 *   6. 最终 `#PWD_INSTAGRAM:4:<timestamp>:<base64>`。
 * 照的是 instagrapi 的 `mixins/password.py`（`password_encrypt`）。
 *
 * ## 隐私
 * 用户名/密码只在**本机**输入（stdin，密码不回显），只发往 IG，
 * 不进命令行参数、不写日志、不落盘；落盘的只有登录成功后的会话 cookie。
 */

'use strict';

const crypto = require('crypto');
const https = require('https');
const path = require('path');
const fs = require('fs');
const querystring = require('querystring');

const { loadDeviceIdentity } = require('./realtime.js');
const { MOBILE_UA } = require('./fbns.js');

const IG_APP_ID = '567067343352427';
/**
 * 登录时的客户端版本。UA 里的版本号就是它 —— 
eeds_upgrade 就是按它判的，
 * 所以做成可配置，好在不改代码的情况下试不同版本。
 */
let appVersion = '449.0.0.52.84';
let versionCode = '1079242191';

/** 按当前版本号拼 UA（与 instagrapi 的 USER_AGENT_BASE 同格式）。 */
function userAgentNow() {
  return 'Instagram ' + appVersion +
    ' Android (34/14; 480dpi; 1344x2992; Google/google; Pixel 8 Pro; husky; husky; en_US; ' +
    versionCode + ')';
}
/** 密码加密里那个公钥不是固定的，从 qe/sync 的响应头现取。 */
const QE_SYNC_URL = 'https://i.instagram.com/api/v1/qe/sync/';
const LOGIN_URL = 'https://i.instagram.com/api/v1/accounts/login/';
const TWO_FACTOR_URL = 'https://i.instagram.com/api/v1/accounts/two_factor_login/';

/* --------------------------------------------------------------- HTTP 小工具 */

function requestRaw(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        resolve({
          status: res.statusCode || 0,
          headers: res.headers,
          body: Buffer.concat(chunks).toString('utf8')
        });
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

/** 把 Set-Cookie 数组揉成"cookie 串"（同名后到的覆盖先到的）。 */
function cookieStringOf(setCookieHeaders) {
  const map = new Map();
  for (const line of setCookieHeaders || []) {
    const first = String(line).split(';')[0];
    const eq = first.indexOf('=');
    if (eq <= 0) continue;
    map.set(first.slice(0, eq).trim(), first.slice(eq + 1).trim());
  }
  const parts = [];
  for (const [name, value] of map) {
    if (value.length > 0) parts.push(`${name}=${value}`);
  }
  return parts.join('; ');
}

/** instagrapi 的 `generate_jazoest`：`2` + phone_id 各字符码之和。 */
function jazoest(phoneId) {
  let sum = 0;
  for (const ch of phoneId) sum += ch.charCodeAt(0);
  return '2' + sum;
}

/**
 * 取公钥并对密码加密，返回 `#PWD_INSTAGRAM:4:<ts>:<base64>`。
 *
 * 算法照 instagrapi `mixins/password.py::password_encrypt` 逐字节实现。
 */
async function encryptPassword(password, publicKeyId, publicKeyBase64) {
  const sessionKey = crypto.randomBytes(32);
  const iv = crypto.randomBytes(12);
  const timestamp = String(Math.floor(Date.now() / 1000));

  const rsaEncrypted = crypto.publicEncrypt({
    key: Buffer.from(publicKeyBase64, 'base64'),
    padding: crypto.constants.RSA_PKCS1_PADDING
  }, sessionKey);

  const cipher = crypto.createCipheriv('aes-256-gcm', sessionKey, iv);
  // ⚠️ AAD 必须是那个时间戳字符串：IG 那边用同样的值校验，漏了就对不上。
  cipher.setAAD(Buffer.from(timestamp, 'utf8'));
  const aesEncrypted = Buffer.concat([cipher.update(password, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();

  const sizeBuffer = Buffer.alloc(2);
  sizeBuffer.writeUInt16LE(rsaEncrypted.length, 0);

  const payload = Buffer.concat([
    Buffer.from([0x01, publicKeyId & 0xFF]),
    iv,
    sizeBuffer,
    rsaEncrypted,
    tag,
    aesEncrypted
  ]).toString('base64');

  return `#PWD_INSTAGRAM:4:${timestamp}:${payload}`;
}

/** 取 qe/sync 响应头里的公钥与 key id。 */
async function fetchPasswordKey(device) {
  const headers = {
    'User-Agent': userAgentNow(),
    'X-IG-App-ID': IG_APP_ID,
    'X-IG-Capabilities': '3brTv10=',
    'X-IG-Connection-Type': 'WIFI',
    'X-IG-Device-ID': device.uuid,
    'X-IG-Android-ID': device.androidId,
    'X-IG-Family-Device-ID': device.phoneId,
    Accept: '*/*'
  };
  const res = await requestRaw({
    hostname: 'i.instagram.com',
    path: '/api/v1/qe/sync/',
    method: 'GET',
    headers: headers,
    timeout: 20000
  });
  const keyId = res.headers['ig-set-password-encryption-key-id'];
  const pubKey = res.headers['ig-set-password-encryption-pub-key'];
  if (!keyId || !pubKey) {
    throw new Error('qe/sync 没给公钥（HTTP ' + res.status + '）：'
      + '可能被限流或接口变了，稍后重试');
  }
  return { keyId: Number(keyId), publicKey: String(pubKey) };
}

/* ------------------------------------------------------------------ 登录 */

/**
 * 用账号密码登录，成功后返回会话材料。
 *
 * @returns {cookie, userId, sessionid, csrf, authorization, twoFactor?:{identifier}}
 */
async function passwordLogin(options) {
  const log = options.log || ((text) => console.log(text));
  const device = options.device || loadDeviceIdentity(options.stateDir || __dirname);
  const guide = device.uuid;
  const advertisingId = crypto.randomUUID();
  const androidDeviceId = 'android-' + crypto.createHash('sha256')
    .update(String(Date.now())).digest('hex').slice(0, 16);

  log('取密码加密公钥…');
  const key = await fetchPasswordKey(device);
  log('公钥 key id = ' + key.keyId);
  const encPassword = await encryptPassword(options.password, key.keyId, key.publicKey);

  const form = querystring.stringify({
    jazoest: jazoest(device.phoneId),
    country_codes: JSON.stringify([{ country_code: '86', source: ['default'] }]),
    phone_id: device.phoneId,
    enc_password: encPassword,
    username: options.username,
    adid: advertisingId,
    guid: guide,
    device_id: androidDeviceId,
    google_tokens: '[]',
    login_attempt_count: '0'
  });

  log('提交登录…');
  const res = await requestRaw({
    hostname: 'i.instagram.com',
    path: '/api/v1/accounts/login/',
    method: 'POST',
    timeout: 30000,
    /*
     * 登录请求**不带** Authorization / Cookie（还没有会话），但**必须带全客户端身份头**：
     * 少了 X-Bloks-Version-Id / X-Pigeon-* / X-IG-Bandwidth-* / X-FB-* 这些，
     * IG 会直接判定"客户端版本太旧"回 `needs_upgrade` —— 而不是告诉你密码对不对。
     * 这一组是照 instagrapi 的 base_headers 抄的。
     */
    headers: {
      'User-Agent': userAgentNow(),
      'X-IG-App-ID': IG_APP_ID,
      'X-IG-Capabilities': '3brTv10=',
      'X-IG-Connection-Type': 'WIFI',
      'X-IG-Device-ID': guide,
      'X-IG-Android-ID': androidDeviceId,
      'X-IG-Family-Device-ID': device.phoneId,
      'X-IG-App-Locale': 'en_US',
      'X-IG-Device-Locale': 'en_US',
      'X-IG-Mapped-Locale': 'en_US',
      'X-Pigeon-Session-Id': 'UFS-' + crypto.randomUUID() + '-1',
      'X-Pigeon-Rawclienttime': (Date.now() / 1000).toFixed(3),
      'X-IG-Bandwidth-Speed-KBPS': '-1.000',
      'X-IG-Bandwidth-TotalBytes-B': '0',
      'X-IG-Bandwidth-TotalTime-MS': '0',
      'X-IG-App-Startup-Country': 'US',
      'X-Bloks-Version-Id': '799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b',
      'X-Bloks-Is-Layout-RTL': 'false',
      'X-Bloks-Is-Panorama-Enabled': 'true',
      'X-IG-Timezone-Offset': String(-new Date().getTimezoneOffset() * 60),
      'X-FB-HTTP-Engine': 'Tigon/MNS/TCP',
      'X-Tigon-Is-Retry': 'False',
      'X-Zero-Balance': 'INIT',
      'X-Zero-State': 'unknown',
      'Zero-HTTP-Network-Interface': 'wifi',
      'X-FB-Client-IP': 'True',
      'X-FB-Server-Cluster': 'True',
      'X-IG-WWW-Claim': '0',
      'IG-INTENDED-USER-ID': '0',
      'X-IG-Nav-Chain': '9MV:self_profile:2,ProfileMediaTabFragment:self_profile:3,9Xf:self_following:4',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Content-Length': Buffer.byteLength(form),
      Accept: '*/*'
    }
  }, form);

  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = { raw: res.body.slice(0, 400) };
  }
  const cookie = cookieStringOf(res.headers['set-cookie']);
  const authorization = String(res.headers['ig-set-authorization'] || '');

  if (data.status === 'ok') {
    const sessionid = pickCookie(cookie, 'sessionid');
    const userId = pickCookie(cookie, 'ds_user_id') || String(
      (data.logged_in_user && data.logged_in_user.pk) || '');
    log('登录成功：账号 ' + userId);
    return { cookie, userId, sessionid, csrf: pickCookie(cookie, 'csrftoken'), authorization };
  }

  const message = String(data.message || '');
  if (data.two_factor_required === true || data.two_factor_info !== undefined
    || message === 'two_factor_required') {
    const identifier = (data.two_factor_info && data.two_factor_info.two_factor_identifier)
      || data.two_factor_identifier || '';
    log('需要两步验证（identifier=' + (identifier || '无') + '）');
    return { cookie, twoFactor: { identifier: String(identifier), raw: data } };
  }
  if (message === 'challenge_required') {
    throw new Error('IG 要求人机校验（challenge_required）。'
      + '请先在手机 App 里完成验证（或点「这是我」），几分钟后重试本命令。');
  }
  if (data.error_type === 'bad_password') {
    throw new Error('密码被拒（bad_password）。确认账号密码；'
      + '若刚在别处改过密码，稍等几分钟再试。');
  }
  throw new Error('登录失败：' + JSON.stringify(data).slice(0, 300));
}

/** 两步验证：拿验证码换会话。 */
async function completeTwoFactor(options) {
  const log = options.log || ((text) => console.log(text));
  const form = querystring.stringify({
    verification_code: options.code,
    phone_id: options.phoneId,
    _csrftoken: options.csrf || '',
    two_factor_identifier: options.identifier,
    username: options.username,
    trust_this_device: '0',
    guid: options.guid,
    device_id: options.androidDeviceId,
    waterfall_id: crypto.randomUUID(),
    verification_method: '3'
  });
  log('提交两步验证码…');
  const res = await requestRaw({
    hostname: 'i.instagram.com',
    path: '/api/v1/accounts/two_factor_login/',
    method: 'POST',
    timeout: 30000,
    headers: Object.assign({
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Content-Length': Buffer.byteLength(form),
      Accept: '*/*'
    }, options.headers || {})
  }, form);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = { raw: res.body.slice(0, 400) };
  }
  if (data.status === 'ok') {
    const cookie = cookieStringOf(res.headers['set-cookie']);
    log('两步验证通过：账号 ' + pickCookie(cookie, 'ds_user_id'));
    return {
      cookie,
      userId: pickCookie(cookie, 'ds_user_id'),
      sessionid: pickCookie(cookie, 'sessionid'),
      csrf: pickCookie(cookie, 'csrftoken'),
      authorization: String(res.headers['ig-set-authorization'] || '')
    };
  }
  throw new Error('两步验证失败：' + JSON.stringify(data).slice(0, 300));
}

function pickCookie(cookie, name) {
  for (const part of String(cookie || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return '';
}

/* ------------------------------------------------------- 交互式入口（stdin） */

/** 读一行（密码用 `hidden: true` 不回显）。 */
function readLine(prompt, hidden) {
  return new Promise((resolve) => {
    const stdin = process.stdin;
    const stdout = process.stdout;
    stdout.write(prompt);
    if (hidden && stdin.isTTY) {
      stdin.setRawMode(true);
      let buffer = '';
      const onData = (chunk) => {
        const text = chunk.toString('utf8');
        for (const ch of text) {
          if (ch === '\r' || ch === '\n') {
            stdin.setRawMode(false);
            stdin.pause();
            stdin.removeListener('data', onData);
            stdout.write('\n');
            resolve(buffer);
            return;
          }
          if (ch === '\u0003') {            // Ctrl+C
            stdin.setRawMode(false);
            process.exit(0);
          }
          if (ch === '\u007f' || ch === '\b') {
            buffer = buffer.slice(0, -1);
            continue;
          }
          buffer += ch;
        }
      };
      stdin.resume();
      stdin.setEncoding('utf8');
      stdin.on('data', onData);
      return;
    }
    stdin.resume();
    stdin.once('data', (chunk) => {
      stdin.pause();
      resolve(chunk.toString('utf8').replace(/[\r\n]+$/, ''));
    });
  });
}

/**
 * 交互式登录并把会话写进 `session.json`（放到 config.json 旁边）。
 *
 * 为什么单独存文件而不塞进 config.json：会话里含 authorization（等同密码），
 * 单独一个文件便于 gitignore 和"重新登录只覆盖它"。
 */
async function interactiveLogin(stateDir, log) {
  const username = (await readLine('IG 用户名：')).trim();
  if (username.length === 0) {
    throw new Error('没输入用户名');
  }
  const password = await readLine('IG 密码（不回显）：', true);
  if (password.length === 0) {
    throw new Error('没输入密码');
  }
  const device = loadDeviceIdentity(stateDir);
  let result = await passwordLogin({ username, password, device, stateDir, log });

  if (result.twoFactor !== undefined) {
    const code = (await readLine('两步验证码（短信/TOTP 六位）：')).trim();
    if (code.length === 0) {
      throw new Error('没输入验证码');
    }
    result = await completeTwoFactor({
      code,
      identifier: result.twoFactor.identifier,
      phoneId: device.phoneId,
      guid: device.uuid,
      androidDeviceId: 'android-' + crypto.createHash('sha256')
        .update(String(Date.now())).digest('hex').slice(0, 16),
      username,
      csrf: result.csrf
    });
  }

  const sessionFile = path.join(stateDir, 'session.json');
  const session = {
    username,
    userId: result.userId,
    cookie: result.cookie,
    sessionid: result.sessionid,
    csrf: result.csrf,
    authorization: result.authorization,
    device,
    savedAt: Date.now()
  };
  fs.writeFileSync(sessionFile, JSON.stringify(session, null, 2), 'utf8');
  log('会话已写入 ' + sessionFile);
  return session;
}

/* ------------------------------------------- 导入 instagrapi 的会话（settings.json） */

/**
 * 把 **instagrapi 的 `settings.json`** 转成本项目要的会话 + 设备身份。
 *
 * 为什么走这条：IG 已经把旧的 `/api/v1/accounts/login/` 整体停用 —— 实测 5 个版本号、
 * 完整客户端头、甚至**不存在的用户名**，一律回 `needs_upgrade`。真正还能登录的是
 * **Bloks CAA 流程**，而 instagrapi 已经把它跑通并持续维护。
 * 与其在 Node 里重写一遍脆弱流程，不如借它登录一次，再把会话导进来：
 *
 *   1. 用 instagrapi 登录（CAA / 2FA / challenge 它都处理了）；
 *   2. `cl.dump_settings("settings.json")`；
 *   3. 这里导入 —— 得到的才是**真机登录过**的会话，iris / FBNS 才有希望放行。
 */
function importInstagrapiSettings(settingsPath, stateDir) {
  const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  const cookies = settings.cookies || {};
  const parts = [];
  for (const name of Object.keys(cookies)) {
    const value = cookies[name];
    if (value !== undefined && value !== null && String(value).length > 0) {
      parts.push(`${name}=${String(value)}`);
    }
  }
  const cookie = parts.join('; ');
  const sessionid = pickCookie(cookie, 'sessionid');
  if (sessionid.length === 0) {
    throw new Error('settings.json 的 cookies 里没有 sessionid —— 这份会话不算登录成功');
  }
  const uuids = settings.uuids || {};
  const phoneId = String(uuids.phone_id || '');
  const deviceUuid = String(uuids.uuid || '');
  let androidId = String(uuids.android_device_id || '');
  if (androidId.startsWith('android-')) {
    androidId = androidId.slice('android-'.length);
  }
  if (phoneId.length === 0 || deviceUuid.length === 0 || androidId.length === 0) {
    throw new Error('settings.json 的 uuids 不全（需要 phone_id / uuid / android_device_id）');
  }

  // 设备身份：mqtt-device.json（实时通道与收件箱请求都读它）
  const identity = { phoneId, uuid: deviceUuid, androidId, createdAt: Date.now() };
  fs.writeFileSync(path.join(stateDir, 'mqtt-device.json'),
    JSON.stringify(identity, null, 2), 'utf8');

  // 会话：session.json
  const authData = settings.authorization_data || {};
  const authorization = Object.keys(authData).length === 0
    ? '' : 'Bearer IGT:2:' + Buffer.from(JSON.stringify(authData)).toString('base64');
  const session = {
    source: 'instagrapi',
    userId: pickCookie(cookie, 'ds_user_id'),
    cookie,
    sessionid,
    csrf: pickCookie(cookie, 'csrftoken'),
    authorization,
    device: identity,
    appVersion: String((settings.device_settings || {}).app_version || ''),
    userAgent: String(settings.user_agent || ''),
    mid: String(settings.mid || ''),
    savedAt: Date.now()
  };
  fs.writeFileSync(path.join(stateDir, 'session.json'),
    JSON.stringify(session, null, 2), 'utf8');
  return session;
}

module.exports = {
  setAppVersion: function (version, code) { appVersion = version; versionCode = String(code); },
  userAgentNow: userAgentNow,
  importInstagrapiSettings,
  passwordLogin,
  completeTwoFactor,
  interactiveLogin,
  encryptPassword,
  fetchPasswordKey,
  cookieStringOf,
  jazoest,
  pickCookie
};
