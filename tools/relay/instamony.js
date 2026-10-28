#!/usr/bin/env node
/*
 * Instamony 中转（**只走 FBNS 实时推送**，不轮询）
 *
 * ## 它是干什么的
 * 手机上的 Instamony 被系统杀掉之后，收不到新私信。这个脚本在你自己的机器上常驻，
 * 借 IG 的 **FBNS 推送通道**（IG 主动推给服务器）收私信，再用**华为 Push Kit** 推到手机。
 *
 * ## 为什么只走 FBNS
 * 之前试过两条路并存的方案，实测结论（详见 LOGIN.md / REALTIME.md）：
 *   · 轮询：受接口往返限制，最好 1~2 秒，且请求量大；
 *   · FBNS：IG **主动推**，载荷里直接带消息正文，**亚秒级**，且几乎不产生请求。
 * 所以这里不留轮询 —— 只保留"启动时拉一次收件箱"用来缓存会话名（FBNS 不带名字）。
 *
 * ## 全流程（三步）
 *   1. **登录**（拿"真机登录过"的会话，这是 FBNS/实时通道的唯一门槛）：
 *        python login_ig.py                      # instagrapi 登录，产出 settings.json
 *        node instamony.js --import-session settings.json
 *   2. **注册设备**（FBNS 两段式握手 + 申请 push token + 注册给 IG）：
 *        node instamony.js --check               # 检查会话/设备/配置
 *        node instamony.js                       # 常驻（会自动完成注册）
 *   3. **接发通知**：
 *        IG 推 → 解析正文/会话/发信人 → 华为 Push Kit → 手机
 *        node instamony.js --test-push "自检"    # 只测"发"这一半
 *
 * ## 用法
 *   node instamony.js                  # 常驻
 *   node instamony.js --check          # 打印当前会话/设备/配置状态
 *   node instamony.js --import-session settings.json
 *   node instamony.js --test-push 文本
 *   node instamony.js --quiet          # 只打警告和错误
 */

'use strict';

const fs = require('fs');
const path = require('path');
const net = require('net');
const zlib = require('zlib');
const https = require('https');
const querystring = require('querystring');

const { FbnsClient, MOBILE_UA } = require('./fbns.js');

const DIR = __dirname;
const CONFIG_FILE = path.join(DIR, 'config.json');
const SESSION_FILE = path.join(DIR, 'session.json');
const DEVICE_FILE = path.join(DIR, 'mqtt-device.json');
const LOCK_PORT = 47999;

const IG_APP_ID = '567067343352427';
const SA_SCOPE_AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const PUSH_SEND = 'https://push-api.cloud.huawei.com/v3/%s/messages:send';
const DEFAULT_SA_FILE = path.join(DIR, '..', 'agc', 'private.json');

let quiet = false;
const clock = () => new Date().toTimeString().slice(0, 8);
function log(text) {
  if (!quiet) console.log(`[${clock()}] ${text}`);
}
function warn(text) {
  console.error(`[${clock()}] ${text}`);
}
function die(text) {
  console.error(text);
  process.exit(2);
}

/* ------------------------------------------------------------------ 配置 */

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return fallback;
  }
}

function loadConfig() {
  const cfg = readJson(CONFIG_FILE, null);
  if (cfg === null) {
    die('缺少 ' + CONFIG_FILE + '\n先复制模板：copy config.example.json config.json');
  }
  return cfg;
}

/** 会话：只有 import 过（或将来 App 导出的）会话才能走 FBNS。 */
function loadSession() {
  const session = readJson(SESSION_FILE, null);
  if (session === null || typeof session.cookie !== 'string' || session.cookie.length < 20) {
    die('缺少有效会话 ' + SESSION_FILE + '\n'
      + '先登录并导入：\n'
      + '  python login_ig.py\n'
      + '  node instamony.js --import-session settings.json');
  }
  return session;
}

function loadDevice() {
  const device = readJson(DEVICE_FILE, null);
  if (device === null || typeof device.phoneId !== 'string') {
    die('缺少设备身份 ' + DEVICE_FILE + '\n它由 --import-session 从 instagrapi 的 settings.json 生成');
  }
  return device;
}

/* ------------------------------------------------------------- IG HTTP 工具 */

function cookieValueOf(cookie, name) {
  for (const part of String(cookie || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return '';
}

/** `Authorization: Bearer IGT:2:<base64url{ds_user_id,sessionid,should_use_header_over_cookies}>` */
function igAuthorization(session) {
  if (typeof session.authorization === 'string' && session.authorization.length > 0) {
    return session.authorization;
  }
  const userId = cookieValueOf(session.cookie, 'ds_user_id');
  const sessionId = decodeURIComponent(cookieValueOf(session.cookie, 'sessionid'));
  if (userId.length === 0 || sessionId.length === 0) return '';
  return 'Bearer IGT:2:' + Buffer.from(JSON.stringify({
    ds_user_id: userId,
    sessionid: sessionId,
    should_use_header_over_cookies: true
  })).toString('base64url');
}

function igHeaders(session, device) {
  const cookie = session.cookie;
  const userAgent = session.userAgent && session.userAgent.length > 0 ? session.userAgent : MOBILE_UA;
  const headers = {
    Cookie: cookie,
    Authorization: igAuthorization(session),
    'User-Agent': userAgent,
    'X-IG-App-ID': IG_APP_ID,
    'X-IG-Capabilities': '3brTv10=',
    'X-IG-Connection-Type': 'WIFI',
    'X-IG-WWW-Claim': '0',
    'X-IG-Device-ID': device.uuid,
    'X-IG-Android-ID': device.androidId,
    'X-IG-Family-Device-ID': device.phoneId,
    'X-CSRFToken': cookieValueOf(cookie, 'csrftoken'),
    Accept: '*/*'
  };
  const mid = cookieValueOf(cookie, 'mid') || (session.mid || '');
  if (mid.length > 0) headers['X-MID'] = mid;
  return headers;
}

function httpRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = https.request({
      hostname: target.hostname,
      path: target.pathname + target.search,
      method: (options && options.method) || 'GET',
      headers: (options && options.headers) || {},
      timeout: 20000
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        let text = Buffer.concat(chunks).toString('utf8');
        // 有些接口回 gzip（我们没主动要，但防一手）
        if (String(res.headers['content-encoding'] || '').indexOf('gzip') >= 0) {
          try {
            text = zlib.gunzipSync(Buffer.concat(chunks)).toString('utf8');
          } catch (error) {
            // 保持原样
          }
        }
        resolve({ status: res.statusCode || 0, headers: res.headers, body: text });
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

/* ------------------------------------------------ 会话导入（instagrapi） */

/**
 * 把 instagrapi 的 settings.json 转成本脚本的两份状态文件。
 *
 * 为什么需要"导入"这一步：IG 已停用旧的密码登录接口（回 needs_upgrade），
 * 现在能登录的是 Bloks CAA 流程，由 instagrapi 维护着（见 LOGIN.md）。
 */
function importSession(settingsPath) {
  const settings = readJson(path.resolve(settingsPath), null);
  if (settings === null) {
    die('读不到 ' + settingsPath);
  }
  const cookies = settings.cookies || {};
  const parts = [];
  for (const name of Object.keys(cookies)) {
    const value = cookies[name];
    if (value !== undefined && value !== null && String(value).length > 0) {
      parts.push(`${name}=${String(value)}`);
    }
  }
  const cookie = parts.join('; ');
  if (cookieValueOf(cookie, 'sessionid').length === 0) {
    die('settings.json 里没有 sessionid —— 这份会话不算登录成功');
  }
  const uuids = settings.uuids || {};
  const phoneId = String(uuids.phone_id || '');
  const uuid = String(uuids.uuid || '');
  let androidId = String(uuids.android_device_id || '');
  if (androidId.startsWith('android-')) androidId = androidId.slice('android-'.length);
  if (phoneId.length === 0 || uuid.length === 0 || androidId.length === 0) {
    die('settings.json 的 uuids 不全（需要 phone_id / uuid / android_device_id）');
  }
  const authData = settings.authorization_data || {};
  const authorization = Object.keys(authData).length === 0
    ? '' : 'Bearer IGT:2:' + Buffer.from(JSON.stringify(authData)).toString('base64');

  const session = {
    source: 'instagrapi',
    userId: cookieValueOf(cookie, 'ds_user_id'),
    cookie,
    sessionid: cookieValueOf(cookie, 'sessionid'),
    csrf: cookieValueOf(cookie, 'csrftoken'),
    authorization,
    appVersion: String((settings.device_settings || {}).app_version || ''),
    userAgent: String(settings.user_agent || ''),
    mid: String(settings.mid || ''),
    savedAt: Date.now()
  };
  fs.writeFileSync(SESSION_FILE, JSON.stringify(session, null, 2), 'utf8');
  fs.writeFileSync(DEVICE_FILE,
    JSON.stringify({ phoneId, uuid, androidId, createdAt: Date.now() }, null, 2), 'utf8');

  // FBNS 的设备凭据在换会话后要重拿（ck/di 跟会话绑定）
  try {
    fs.unlinkSync(path.join(DIR, 'fbns-auth.json'));
    log('已清掉旧的 FBNS 设备凭据（换会话后需重新引导）');
  } catch (error) {
    // 本来就没有
  }

  log('会话已写入 ' + SESSION_FILE);
  log('设备身份已写入 ' + DEVICE_FILE + '（phoneId ' + phoneId + '）');
  log('账号 ' + session.userId);
  return session;
}

/* --------------------------------------------------- 华为 Push Kit（发送侧） */

let jwtCache = { value: '', exp: 0 };

function serviceJwt(sa) {
  const crypto = require('crypto');
  const now = Math.floor(Date.now() / 1000);
  if (jwtCache.value && jwtCache.exp - 60 > now) return jwtCache.value;
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const signingInput = b64({ kid: sa.key_id, typ: 'JWT', alg: 'PS256' })
    + '.' + b64({ aud: SA_SCOPE_AUD, iss: sa.sub_account, iat: now, exp: now + 3600 });
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: String(sa.private_key).replace(/\\n/g, '\n'),
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST
  }).toString('base64url');
  jwtCache = { value: signingInput + '.' + signature, exp: now + 3600 };
  return jwtCache.value;
}

/** 会话/消息唯一 → 稳定的 31 位整数（华为 notifyId 的取值域）。 */
function notifyIdOf(text) {
  let sum = 0;
  const raw = String(text || '');
  for (let index = 0; index < raw.length; index++) {
    sum = (sum * 31 + raw.charCodeAt(index)) % 2147483647;
  }
  return sum > 0 ? sum : 1;
}

/**
 * 发一条通知（华为 Push Kit v3 + 服务账号 JWT）。
 *
 * `appMessageId` 的字符集只有 `[A-Za-z0-9+/=_-]`（实测带冒号会被整条拒收，
 * 回 `80100003 invalid appMessageId`，表现为"完全收不到消息"）。
 */
async function pushToPhone(cfg, title, body, itemKey) {
  const agc = cfg.notify.agc || {};
  const saFile = agc.serviceAccountFile
    ? path.resolve(DIR, agc.serviceAccountFile) : DEFAULT_SA_FILE;
  const sa = readJson(saFile, null);
  if (sa === null) {
    throw new Error('找不到服务账号密钥 ' + saFile
      + '（AGC → API Console → 服务账号密钥 → 下载推送服务 API 的 json）');
  }
  const projectId = sa.project_id;
  if (!projectId) throw new Error('密钥文件里没有 project_id');
  const token = process.env.INSTAMONY_PUSH_TOKEN || cfg.notify.pushToken || '';
  if (token.length < 20) throw new Error('config.json 的 notify.pushToken 为空（App 里「复制中转材料」可拿到）');

  const rawId = String(itemKey || Date.now());
  const messageId = /^[A-Za-z0-9+/=_\-\s]{1,64}$/.test(rawId) ? rawId : String(notifyIdOf(rawId));
  const payload = JSON.stringify({
    payload: {
      notification: {
        category: agc.category || 'IM',
        title: title,
        body: body,
        clickAction: { actionType: 0 },
        style: 0,
        // 每条消息一条通知（堆叠）；同一条消息重复投递由 appMessageId 兜住
        notifyId: notifyIdOf(rawId),
        appMessageId: messageId
      }
    },
    target: { token: [token] },
    pushOptions: { testMessage: agc.testMessage !== false, ttl: 3600, collapseKey: -1 }
  });
  const res = await httpRequest(PUSH_SEND.replace('%s', projectId), {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + serviceJwt(sa),
      'Content-Type': 'application/json; charset=UTF-8',
      'Content-Length': Buffer.byteLength(payload),
      'push-type': '0'
    }
  }, payload);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = {};
  }
  if (data.code === '80000000') {
    log('已推送到手机（' + (data.requestId || '') + '）');
    return true;
  }
  throw new Error('推送失败（HTTP ' + res.status + '）：' + res.body.slice(0, 200));
}

/* ------------------------------------------------- 会话名（通知标题用） */

const nameCache = new Map();

/** 用发信人 id 查用户名（缓存）。查不到就用兜底文案。 */
async function usernameOf(session, device, userId) {
  const key = String(userId || '');
  if (key.length === 0) return '';
  if (nameCache.has(key)) return nameCache.get(key);
  try {
    const res = await httpRequest(
      `https://i.instagram.com/api/v1/users/${encodeURIComponent(key)}/info/`,
      { headers: igHeaders(session, device) });
    if (res.status === 200) {
      const data = JSON.parse(res.body);
      const name = String((data.user || {}).username || '');
      if (name.length > 0) {
        nameCache.set(key, name);
        return name;
      }
    }
  } catch (error) {
    // 查不到不影响推送
  }
  nameCache.set(key, '');
  return '';
}

/* ------------------------------------------------------------ FBNS 推送 */

const seenItems = new Set();
function alreadySeen(id) {
  const key = String(id || '');
  if (key.length === 0) return false;
  if (seenItems.has(key)) return true;
  seenItems.add(key);
  if (seenItems.size > 800) {
    seenItems.delete(seenItems.values().next().value);
  }
  return false;
}

function inQuietHours(cfg) {
  const q = cfg.notify && cfg.notify.quietHours;
  if (!Array.isArray(q) || q.length !== 2) return false;
  const hour = new Date().getHours();
  const from = Number(q[0]);
  const to = Number(q[1]);
  if (from === to) return false;
  return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to);
}

/**
 * 处理一条 FBNS 推送。
 *
 * 实测载荷：{"m":"正文","t_id":"会话","s":"发信人","n":"消息 id",
 *            "c":"direct_v2_text","a":"头像 URL","mid":"…","ig":"深链"}
 * `m` 直接就是正文 —— 所以**不需要再请求收件箱**，这是亚秒级的关键。
 */
async function handlePush(cfg, session, device, push) {
  if (push === null || typeof push !== 'object') return;
  const threadId = String(push.t_id || '');
  const itemId = String(push.n || push.mid || '');
  const kind = String(push.c || '');
  const text = String(push.m || '').trim().slice(0, 120);
  if (threadId.length === 0) return;
  // 只处理私信类
  if (kind.length > 0 && kind.indexOf('direct') < 0 && kind.indexOf('text') < 0) return;
  // 自己发的（防御）
  if (String(push.s || '') === String(session.userId || '')) return;
  if (alreadySeen(itemId)) return;
  if (inQuietHours(cfg)) {
    log('安静时段：只记账不弹（' + threadId + '）');
    return;
  }
  const sender = await usernameOf(session, device, push.s);
  const title = sender.length > 0 ? sender : '私信';
  const body = text.length > 0 ? text : '你有一条新私信';
  await pushToPhone(cfg, title, body, `${threadId}_${itemId || Date.now()}`);
  log('即时推送：' + title + ' —— ' + body);
}

/* ------------------------------------------------------------- 单实例互斥 */

let mutex = null;

function acquireLock() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', (error) => {
      if (error.code === 'EADDRINUSE') {
        die('已经有一个中转在跑（本地端口 ' + LOCK_PORT + ' 被占用）。'
          + '\n先停掉它再启动 —— 两个实例会各推一遍，同一条消息会收到两次。');
      }
      warn('单实例检查异常（' + error.code + '）：' + error.message + '，继续');
      resolve(false);
    });
    server.listen(LOCK_PORT, '127.0.0.1', () => {
      mutex = server;
      resolve(true);
    });
  });
}

function releaseLock() {
  if (mutex !== null) {
    try {
      mutex.close();
    } catch (error) {
      // 忽略
    }
    mutex = null;
  }
}

/* ------------------------------------------------------------------ 状态检查 */

async function runCheck(cfg) {
  const session = loadSession();
  const device = loadDevice();
  const agc = cfg.notify.agc || {};
  const saFile = agc.serviceAccountFile ? path.resolve(DIR, agc.serviceAccountFile) : DEFAULT_SA_FILE;
  const sa = readJson(saFile, null);
  const fbnsAuth = readJson(path.join(DIR, 'fbns-auth.json'), null);
  const token = process.env.INSTAMONY_PUSH_TOKEN || cfg.notify.pushToken || '';
  const mask = (text) => (text.length <= 8 ? (text.length > 0 ? '有' : '无')
    : text.slice(0, 4) + '***' + text.slice(-4));
  log('会话文件      ' + (fs.existsSync(SESSION_FILE) ? '有' : '无'));
  log('账号          ' + (session.userId || '?'));
  log('设备 phoneId  ' + (device.phoneId || '?'));
  log('设备 uuid     ' + (device.uuid || '?'));
  log('authorization ' + (igAuthorization(session).length > 0 ? '有' : '无（会退回用 cookie 里拼）'));
  log('服务账号密钥  ' + (sa === null ? '缺（' + saFile + '）' : ('有，project ' + (sa.project_id || '?'))));
  log('pushToken     ' + (token.length >= 20 ? mask(token) : '缺（App 里「复制中转材料」）'));
  log('FBNS 设备凭据 ' + (fbnsAuth === null ? '无（首次运行会自动引导）' : '有'));
  log('quietHours    ' + JSON.stringify((cfg.notify && cfg.notify.quietHours) || null));
  if (cfg.notify.pushToken === undefined) {
    log('提示：把 pushToken 填进 config.json 的 notify.pushToken');
  }
}

/* ------------------------------------------------------------------ 主流程 */

async function runDaemon(cfg) {
  const session = loadSession();
  const device = loadDevice();
  await acquireLock();
  log('启动 FBNS 实时通道（只走推送，不轮询）');

  const client = new FbnsClient({
    stateDir: DIR,
    clientId: session.userId,
    userId: Number(session.userId) || 0,
    log: (text) => log(text)
  });

  client.on('up', () => {
    log('FBNS 已连上，申请 push token');
    client.requestPushToken();
  });

  client.on('registered', async (payload) => {
    const token = payload && payload.token ? String(payload.token) : '';
    if (token.length === 0) {
      warn('没拿到 push token：' + JSON.stringify(payload).slice(0, 160));
      return;
    }
    // 注册：把 token 交给 IG，之后它才会往这条连接推私信
    const form = querystring.stringify({
      device_type: 'android_mqtt',
      is_main_push_channel: 'true',
      device_sub_type: '2',
      device_token: token,
      _csrftoken: cookieValueOf(session.cookie, 'csrftoken'),
      guid: cookieValueOf(session.cookie, 'ig_did') || device.uuid,
      uuid: cookieValueOf(session.cookie, 'ig_did') || device.uuid,
      users: session.userId,
      family_device_id: device.uuid
    });
    try {
      const res = await httpRequest('https://i.instagram.com/api/v1/push/register/', {
        method: 'POST',
        headers: Object.assign(igHeaders(session, device), {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(form)
        })
      }, form);
      if (res.body.indexOf('"ok"') >= 0) {
        log('push token 注册成功 —— 之后新私信由 IG 主动推过来');
      } else {
        warn('push token 注册失败（' + res.status + '）：' + res.body.slice(0, 160));
      }
    } catch (error) {
      warn('push token 注册异常：' + error.message);
    }
  });

  client.on('push', (push) => {
    handlePush(cfg, session, device, push).catch((error) => {
      warn('处理推送失败：' + error.message);
    });
  });

  client.on('down', (reason) => {
    log('FBNS 断开：' + reason + '（30 秒后重连）');
  });

  const connect = () => {
    client.connect().catch((error) => log('FBNS 连接失败：' + error.message));
  };
  connect();
  const retry = setInterval(() => {
    if (!client.up) connect();
  }, 30000);

  const shutdown = () => {
    log('退出中…');
    clearInterval(retry);
    client.close();
    releaseLock();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  log('就绪：手机被杀了也能收到新私信通知（Ctrl+C 停）');
}

/* ------------------------------------------------------------------ 入口 */

async function main() {
  const argv = process.argv.slice(2);
  quiet = argv.indexOf('--quiet') >= 0;

  const importAt = argv.indexOf('--import-session');
  if (importAt >= 0) {
    const file = argv[importAt + 1];
    if (!file) die('用法：node instamony.js --import-session <settings.json>');
    importSession(file);
    return;
  }

  const cfg = loadConfig();

  if (argv.indexOf('--check') >= 0) {
    await runCheck(cfg);
    return;
  }

  const testAt = argv.indexOf('--test-push');
  if (testAt >= 0) {
    const text = argv[testAt + 1] || 'Instamony 自检';
    await pushToPhone(cfg, 'Instamony', text, 'test_' + Date.now());
    return;
  }

  await runDaemon(cfg);
}

main().catch((error) => {
  warn('异常退出：' + (error && error.message ? error.message : error));
  releaseLock();
  process.exit(1);
});
