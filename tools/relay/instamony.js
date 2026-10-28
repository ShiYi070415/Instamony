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
 *   node instamony.js --caa-login      # 用账号密码登录（Node 版 CAA，不需要 Python）
 *   node instamony.js --verify-session # 会话自证：形状 + 探活 + 设备信任闸门（push 注册）
 *   node instamony.js --import-session settings.json
 *   node instamony.js --test-push 文本
 *   node instamony.js --clear          # 清除所有登录态（演练；加 --yes 真删，加 --all 连设备身份）
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
// 会话形状转换（纯函数、可单测；`--import-session` 与 `--caa-login` 共用同一份实现）
const { sessionFromSettings, settingsShapeOf, sessionProblemOf } = require('./session-format.js');

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
    // 去掉可能的 BOM：Windows 的记事本 / `Set-Content -Encoding UTF8`（PS 5.1）都会写 BOM，
    // 而 `JSON.parse` 见到 BOM 直接抛 —— 表现是"文件明明在，却报读不到"（真踩过）。
    const text = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
    return JSON.parse(text);
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

/** 通用 HTTP 请求：按 URL 协议自动选 http / https（网关常是 http，推送接口是 https）。 */
function httpRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const client = target.protocol === 'http:' ? require('http') : https;
    const req = client.request({
      hostname: target.hostname,
      port: target.port || (target.protocol === 'http:' ? 80 : 443),
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
function importSession(settingsPath, options) {
  const opts = options || {};
  const dryRun = opts.dryRun === true;
  const settings = readJson(path.resolve(settingsPath), null);
  if (settings === null) {
    die('读不到 ' + settingsPath);
  }
  // 解析逻辑在纯模块里（session-format.js）：`--caa-login` 产出的文件也走它，
  // 这样"两条登录路等价"才是同一份代码验出来的，而不是两处各解释一遍。
  let parsed = null;
  try {
    parsed = sessionFromSettings(settings);
  } catch (error) {
    if (dryRun) {
      throw error;
    }
    die('settings.json ' + error.message);
  }
  const session = parsed.session;
  const device = parsed.device;
  if (dryRun) {
    return session;
  }
  fs.writeFileSync(SESSION_FILE, JSON.stringify(session, null, 2), 'utf8');
  fs.writeFileSync(DEVICE_FILE,
    JSON.stringify({ phoneId: device.phoneId, uuid: device.uuid, androidId: device.androidId,
      createdAt: Date.now() }, null, 2), 'utf8');

  // FBNS 的设备凭据在换会话后要重拿（ck/di 跟会话绑定）
  try {
    fs.unlinkSync(path.join(DIR, 'fbns-auth.json'));
    log('已清掉旧的 FBNS 设备凭据（换会话后需重新引导）');
  } catch (error) {
    // 本来就没有
  }

  log('会话已写入 ' + SESSION_FILE);
  log('设备身份已写入 ' + DEVICE_FILE + '（phoneId ' + device.phoneId + '）');
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
 * 发一条通知。
 *
 * 两种模式，按 config.json 自动选：
 *   · **网关模式**（`notify.gateway = {url,key}`）：把内容 POST 到网关，由网关用服务账号私钥
 *     发华为。适合分发给其他用户 —— 他们机器上不需要华为私钥。
 *   · **本机模式**（配置了 `notify.agc`）：自己签 JWT 直接发华为。
 *
 * `appMessageId` 的字符集只有 `[A-Za-z0-9+/=_-]`（带冒号会被整条拒收，回 80100003
 * 且表现为"完全收不到消息"），这里统一清洗。
 */
async function pushToPhone(cfg, title, body, itemKey) {
  const notifyCfg = cfg.notify || {};
  const rawId = String(itemKey || Date.now());
  const messageId = /^[A-Za-z0-9+/=_\-\s]{1,64}$/.test(rawId) ? rawId : String(notifyIdOf(rawId));
  const token = process.env.INSTAMONY_PUSH_TOKEN || notifyCfg.pushToken || '';

  const gateway = notifyCfg.gateway || null;
  if (gateway !== null && typeof gateway.url === 'string' && gateway.url.length > 0) {
    if (token.length < 20) throw new Error('config.json 的 notify.pushToken 为空');
    const payload = JSON.stringify({ token, title, body, itemKey: rawId, messageId });
    const res = await httpRequest(gateway.url, {
      method: 'POST',
      headers: {
        'X-Gateway-Key': String(gateway.key || ''),
        'Content-Type': 'application/json; charset=UTF-8',
        'Content-Length': Buffer.byteLength(payload)
      }
    }, payload);
    let data = {};
    try {
      data = JSON.parse(res.body);
    } catch (error) {
      data = {};
    }
    if (data.ok === true) {
      log('已通过网关推送到手机（' + (data.requestId || '') + '）');
      return true;
    }
    throw new Error('网关返回失败（HTTP ' + res.status + '）：' + res.body.slice(0, 200));
  }

  const agc = notifyCfg.agc || {};
  const saFile = agc.serviceAccountFile
    ? path.resolve(DIR, agc.serviceAccountFile) : DEFAULT_SA_FILE;
  const sa = readJson(saFile, null);
  if (sa === null) {
    throw new Error('找不到服务账号密钥 ' + saFile
      + '（ACP → API Console → 服务账号密钥 → 下载推送服务 API 的 json）');
  }
  const projectId = sa.project_id;
  if (!projectId) throw new Error('密钥文件里没有 project_id');
  if (token.length < 20) throw new Error('config.json 的 notify.pushToken 为空（App 里「复制中转材料」可拿到）');

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

/**
 * 会话还能不能用：打一发 `accounts/current_user/`。
 *
 * 为什么守护进程要问这个：会话文件在手 ≠ 会话还活着（密码改了、别处登出、被风控踢掉都会失效）。
 * 失效时直接连 FBNS 会一路 400，日志看起来像"推送坏了"，实际只是该重新登录。
 */
async function sessionAlive(session, device) {
  if (session === null || typeof session.cookie !== 'string' || session.cookie.length === 0) {
    return false;
  }
  try {
    const res = await httpRequest(
      'https://i.instagram.com/api/v1/accounts/current_user/?edit=true',
      { method: 'GET', headers: igHeaders(session, device) });
    return res.status === 200;
  } catch (error) {
    warn('会话探活失败（网络？）：' + error.message);
    return false;
  }
}

/** 环境变量里有没有账号密码（有就能在后台自动重登，不用人守）。 */
function hasEnvCredentials() {
  return String(process.env.INSTAMONY_IG_USER || '').trim().length > 0
    && String(process.env.INSTAMONY_IG_PASS || '').length > 0;
}

/**
 * **把登录接进 relay 的启动流程**：没有会话、或会话已失效时，就地登录一次。
 *
 * 为什么放在这里面：以前要先用 `--caa-login` 登录、再启动守护进程，两条命令；
 * 用户忘了先登录，守护进程只会报"缺少有效会话"就退出。现在启动时自己判断：
 *   · 有会话且活着 → 直接开跑（不打扰）；
 *   · 没有 / 已失效 → 交互登录（或读 `INSTAMONY_IG_USER` / `INSTAMONY_IG_PASS`）；
 *   · 后台（非 TTY）又没有环境变量 → 给一句明确的命令提示后退出，不卡在无人应答的输入上。
 */
async function ensureDaemonSession(argv) {
  const existing = readJson(SESSION_FILE, null);
  const device = loadDevice();
  if (existing !== null && typeof existing.cookie === 'string' && existing.cookie.length > 0) {
    if (await sessionAlive(existing, device)) {
      log('会话可用（账号 ' + (existing.userId || '?') + '），直接启动');
      return;
    }
    warn('现有会话已失效（accounts/current_user 非 200）→ 需要重新登录');
  } else {
    log('还没有会话 → 先登录一次（之后常驻会自动复用）');
  }
  if (!hasEnvCredentials() && !process.stdin.isTTY) {
    die('没有可用会话，且当前不是交互终端，无法提示输入账号密码。\n'
      + '先跑一次：node instamony.js --caa-login\n'
      + '或用环境变量（仅自动化场景）：INSTAMONY_IG_USER / INSTAMONY_IG_PASS');
  }
  await runCaaLogin(argv);
  // runCaaLogin 成功时已经把 session.json / settings.caa.json 写好；失败会自己 exit。
  const refreshed = readJson(SESSION_FILE, null);
  if (refreshed === null) {
    die('登录流程结束了但没有会话文件，无法启动');
  }
  log('登录完成（账号 ' + (refreshed.userId || '?') + '），继续启动');
}

async function runDaemon(cfg, argv) {
  await ensureDaemonSession(argv);
  let session = loadSession();
  let device = loadDevice();
  await acquireLock();
  log('启动 FBNS 实时通道（只走推送，不轮询）');

  const reloadSession = () => {
    session = loadSession();
    device = loadDevice();
  };

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
        /*
         * **运行中会话失效的自愈**：注册被判失败时先探一次 `current_user`，
         * 真失效了且环境变量里有账号密码 → 自动重登一次并重连（换会话后 FBNS 凭据也要换，
         * runCaaLogin 会删掉 fbns-auth.json，所以重连就是重新引导）。
         * 没有环境变量时只提示，不擅自弹交互输入（后台守护进程里没人应答）。
         */
        const alive = await sessionAlive(session, device);
        if (!alive) {
          warn('会话已失效（current_user 非 200）');
          if (hasEnvCredentials()) {
            log('环境变量里有账号密码 → 自动重新登录');
            try {
              await runCaaLogin([]);
              reloadSession();
              log('重登完成，重连 FBNS');
              client.close();
              connect();
            } catch (loginError) {
              warn('自动重登失败：' + loginError.message);
            }
          } else {
            log('提示：设 INSTAMONY_IG_USER / INSTAMONY_IG_PASS 可自动重登；'
              + '或停掉本进程后重跑（启动时会引导登录）');
          }
        }
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

/**
 * `--verify-session`：**会话自证**（一条命令把"能不能真的收推送"验掉）。
 *
 * 为什么要单独一条：**登录成功 ≠ 通道能用**。实测过太多次"登录成功、脚本全绿、手机不响"，
 * 判据只有三样，一个都不能省：
 *   1. **形状**：`sessionid` / `ds_user_id` / `authorization` 齐不齐
 *      （authorization 是 `Bearer IGT:2:…`，设备信任看它）；
 *   2. **还活着**：`accounts/current_user/` 回 200；
 *   3. **设备信任闸门**：FBNS 申请 push token → 交给 IG（`push/register/`）。
 *      网页 Cookie 派生的会话在这一步回 400（实测），真机登录的会话回 `{"status":"ok"}` ——
 *      这一条过了，常驻进程才有可能真的收到推送。
 */
async function runVerifySession() {
  const session = loadSession();
  const device = loadDevice();
  const sid = cookieValueOf(session.cookie, 'sessionid');
  const uid = session.userId || cookieValueOf(session.cookie, 'ds_user_id');
  const auth = igAuthorization(session);

  log('① 会话形状');
  log('   sessionid     ' + (sid.length > 0 ? '有（' + sid.length + ' 字符）' : '缺'));
  log('   ds_user_id    ' + (uid.length > 0 ? uid : '缺'));
  log('   authorization ' + (auth.length > 0 ? '有（' + auth.length + ' 字符）'
    : '缺（会退回用 cookie 里的 sessionid 拼）'));
  if (sid.length === 0 || uid.length === 0) {
    warn('会话不完整：先跑 node instamony.js --caa-login');
    process.exitCode = 1;
    return;
  }

  log('② 会话探活（accounts/current_user/）');
  try {
    const res = await httpRequest(
      'https://i.instagram.com/api/v1/accounts/current_user/?edit=true',
      { method: 'GET', headers: igHeaders(session, device) });
    let username = '';
    try {
      username = String((JSON.parse(res.body).user || {}).username || '');
    } catch (error) {
      // 非 JSON（多半是未登录的 HTML）：下面按状态码处理
    }
    if (res.status === 200) {
      log('   HTTP 200 —— 会话有效' + (username.length > 0 ? '（@' + username + '）' : ''));
    } else {
      warn('   HTTP ' + res.status + ' —— 会话可能已失效：' + res.body.slice(0, 160));
      process.exitCode = 1;
      return;
    }
  } catch (error) {
    warn('   探活失败：' + error.message);
    process.exitCode = 1;
    return;
  }

  /*
   * ③ 等价性：`settings.caa.json`（CAA 登录产出的 instagrapi 形状文件）经同一条导入路径解析，
   * 解出来的会话必须和现在这份一模一样。**这一点比形状检查更能说明"等价"**：不是字段长得像，
   * 而是真的能被 Python 那条路的格式吃下去、还原成同一份会话。
   */
  const caaFile = path.join(DIR, 'settings.caa.json');
  if (fs.existsSync(caaFile)) {
    log('③ 与 instagrapi settings 的等价性（settings.caa.json）');
    try {
      const reread = importSession(caaFile, { dryRun: true });
      const sameSid = reread.sessionid === sid;
      const sameAuth = reread.authorization === auth;
      const sameUser = String(reread.userId) === String(uid);
      log('   sessionid ' + (sameSid ? '一致' : '**不一致**')
        + '，authorization ' + (sameAuth ? '一致' : '**不一致**')
        + '，账号 ' + (sameUser ? '一致' : '**不一致**'));
      if (!sameSid || !sameAuth || !sameUser) {
        warn('   等价性没过：settings.caa.json 与 session.json 不是同一份会话');
      }
    } catch (error) {
      warn('   解析 settings.caa.json 失败：' + error.message);
    }
  } else {
    log('③ 等价性：没有 settings.caa.json（只有 --caa-login 会产出，跳过）');
  }

  log('④ 设备信任闸门（FBNS 申请 token → push/register/）');
  const ok = await pushRegisterGate(session, device);
  if (ok) {
    log('结论：会话是**设备级**的 —— 常驻进程可以收到 IG 主动推送');
    process.exitCode = 0;
  } else {
    warn('结论：闸门没过 —— 常驻进程收不到推送（会话来源多半是网页 Cookie）');
    process.exitCode = 2;
  }
}

/** 闸门本体：连 FBNS 拿 push token，再交给 IG 注册。返回是否通过。 */
function pushRegisterGate(session, device) {
  return new Promise((resolve) => {
    const client = new FbnsClient({
      stateDir: DIR,
      clientId: session.userId,
      userId: Number(session.userId) || 0,
      log: (text) => log('   ' + text)
    });
    let finished = false;
    const finish = (value) => {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timer);
      try {
        client.close();
      } catch (error) {
        // 关连接失败不影响结论
      }
      resolve(value);
    };
    const timer = setTimeout(() => {
      warn('   超时：60 秒内 FBNS 没给出 push token');
      finish(false);
    }, 60000);

    client.on('up', () => client.requestPushToken());
    client.on('down', (reason) => log('   FBNS 断开：' + reason));
    client.on('registered', async (payload) => {
      const token = payload && payload.token ? String(payload.token) : '';
      if (token.length === 0) {
        warn('   没拿到 push token：' + JSON.stringify(payload).slice(0, 160));
        finish(false);
        return;
      }
      log('   拿到 push token（' + token.length + ' 字符），交给 IG 注册');
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
        const passed = res.status === 200 && res.body.indexOf('"ok"') >= 0;
        if (passed) {
          log('   push/register/ HTTP 200 {"status":"ok"} —— 设备信任**通过**');
        } else {
          warn('   push/register/ HTTP ' + res.status + '：' + res.body.slice(0, 200));
        }
        finish(passed);
      } catch (error) {
        warn('   push/register/ 异常：' + error.message);
        finish(false);
      }
    });
    client.connect().catch((error) => {
      warn('   FBNS 连接失败：' + error.message);
      finish(false);
    });
  });
}

/* ------------------------------------------------- 交互输入（CAA 登录用） */

/*
 * **非 TTY（管道 / 重定向）下的按行读取**。
 *
 * 早先每个问题都挂一次 `stdin.once('data')`，而管道会把**多行一起**送过来：
 * 用户名那一问把密码那一行也吃掉了，第二问永远等不到 data —— 进程在事件循环空掉时
 * **静默退出（exit 0）**。自测时就是这样：只看到两个提示符，什么结论都没有。
 * 现在改成"把 stdin 读完 → 按行切队列 → 谁来问就发一行"，EOF 时回空串（让调用方 die）。
 */
const PIPED_LINES = [];
let pipedRemainder = '';
let pipedDone = false;
let pipedHooks = false;
const lineWaiters = [];

function flushPipedLines() {
  while (lineWaiters.length > 0) {
    if (PIPED_LINES.length > 0) {
      lineWaiters.shift()(PIPED_LINES.shift());
    } else if (pipedDone) {
      lineWaiters.shift()('');
    } else {
      break;
    }
  }
}

function installPipedReader() {
  if (pipedHooks) {
    return;
  }
  pipedHooks = true;
  const stdin = process.stdin;
  stdin.setEncoding('utf8');
  stdin.on('data', (chunk) => {
    pipedRemainder += String(chunk);
    let cut = pipedRemainder.indexOf('\n');
    while (cut >= 0) {
      PIPED_LINES.push(pipedRemainder.slice(0, cut).replace(/\r$/, ''));
      pipedRemainder = pipedRemainder.slice(cut + 1);
      cut = pipedRemainder.indexOf('\n');
    }
    flushPipedLines();
  });
  stdin.on('end', () => {
    if (pipedRemainder.length > 0) {
      PIPED_LINES.push(pipedRemainder.replace(/\r$/, ''));
      pipedRemainder = '';
    }
    pipedDone = true;
    flushPipedLines();
  });
  stdin.resume();
}

function readPipedLine() {
  installPipedReader();
  return new Promise((resolve) => {
    lineWaiters.push(resolve);
    flushPipedLines();
  });
}

/** 读一行；`hidden` 时密码不回显（TTY）。 */
function readLine(prompt, hidden) {
  process.stdout.write(prompt);
  const stdin = process.stdin;
  if (!stdin.isTTY) {
    // 管道/重定向：走上面的按行队列（回显本来就无所谓）。
    return readPipedLine();
  }
  return new Promise((resolve) => {
    if (hidden) {
      stdin.setRawMode(true);
      let buffer = '';
      const onData = (chunk) => {
        for (const ch of chunk.toString('utf8')) {
          if (ch === '\r' || ch === '\n') {
            stdin.setRawMode(false);
            stdin.pause();
            stdin.removeListener('data', onData);
            process.stdout.write('\n');
            resolve(buffer);
            return;
          }
          if (ch === '\u0003') {              // Ctrl+C
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

/** 内置的设备/应用默认档（没有 settings.json、也还没落过 device-profile.json 时用）。 */
const FALLBACK_PROFILE = {
  appVersion: '449.0.0.52.84',
  versionCode: '1079242191',
  bloksVersionId: '799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b',
  userAgent: MOBILE_UA
};

/**
 * 本机设备档案（`--caa-login` 自己落的一份）。
 *
 * **为什么必须有**：以前没有 settings.json 时每次运行都随机生成一套设备身份 ——
 * 在 IG 眼里就是"每次登录都换一台新手机"，风控更严（更容易要验证码/恢复确认）。
 * 真机是常量，所以这里也落盘复用。存的东西不含会话材料（phoneId / uuid / androidId /
 * mid / 版本号 / UA），删掉只会让下次被当成新设备。
 */
const DEVICE_PROFILE_FILE = path.join(DIR, 'device-profile.json');

function saveDeviceProfile(profile) {
  try {
    fs.writeFileSync(DEVICE_PROFILE_FILE, JSON.stringify({
      phoneId: profile.phoneId,
      uuid: profile.uuid,
      androidId: profile.androidId,
      mid: profile.mid,
      appVersion: profile.appVersion,
      versionCode: profile.versionCode,
      bloksVersionId: profile.bloksVersionId,
      userAgent: profile.userAgent,
      savedAt: Date.now()
    }, null, 2), 'utf8');
  } catch (error) {
    warn('写 device-profile.json 失败：' + error.message);
  }
}

function loadSavedProfile() {
  const saved = readJson(DEVICE_PROFILE_FILE, null);
  if (saved === null) {
    return null;
  }
  const phoneId = String(saved.phoneId || '');
  const uuid = String(saved.uuid || '');
  const androidId = String(saved.androidId || '').replace(/^android-/, '');
  if (phoneId.length === 0 || uuid.length === 0 || androidId.length === 0) {
    return null;
  }
  return {
    phoneId,
    uuid,
    androidId,
    mid: String(saved.mid || ''),
    appVersion: String(saved.appVersion || FALLBACK_PROFILE.appVersion),
    versionCode: String(saved.versionCode || FALLBACK_PROFILE.versionCode),
    bloksVersionId: String(saved.bloksVersionId || FALLBACK_PROFILE.bloksVersionId),
    userAgent: String(saved.userAgent || FALLBACK_PROFILE.userAgent)
  };
}

/**
 * 解析设备档案（`--caa-login` 与 `--caa-preflight` 共用）。
 *
 * 取法（按优先级）：`settings.json`（`--settings` 可指定）→ `device-profile.json`
 * （上一次用过的那一套）→ 新生成一套并落盘。**同一台机器始终是同一台"手机"**。
 */
function resolveDeviceProfile(argv) {
  const { loadDeviceProfile } = require('./caa-login.js');
  const settingsAt = argv.indexOf('--settings');
  const settingsFile = settingsAt >= 0 && argv[settingsAt + 1]
    ? path.resolve(DIR, argv[settingsAt + 1]) : path.join(DIR, 'settings.json');
  let profile = null;
  if (fs.existsSync(settingsFile)) {
    try {
      profile = loadDeviceProfile(settingsFile);
      log('设备档案取自 ' + settingsFile);
    } catch (error) {
      warn('读 settings.json 的设备档案失败：' + error.message);
    }
  }
  if (profile === null) {
    profile = loadSavedProfile();
    if (profile !== null) {
      log('设备档案取自 device-profile.json（沿用本机上次那一套）');
    }
  }
  if (profile === null) {
    const cryptoMod = require('crypto');
    profile = {
      phoneId: 'android-' + cryptoMod.randomUUID(),
      uuid: cryptoMod.randomUUID(),
      androidId: cryptoMod.randomBytes(8).toString('hex'),
      mid: '',
      appVersion: FALLBACK_PROFILE.appVersion,
      versionCode: FALLBACK_PROFILE.versionCode,
      bloksVersionId: FALLBACK_PROFILE.bloksVersionId,
      userAgent: FALLBACK_PROFILE.userAgent
    };
    log('没有 settings.json / device-profile.json → 生成一套设备档案并记下（下次复用同一台设备）');
  }
  saveDeviceProfile(profile);
  return profile;
}

/**
 * `--caa-preflight`：**只跑密码之前那半条链**（不需要账号密码）。
 *
 * 跑三步 + 一个前置检查：
 *   1. USDID 注册（`graphql_www`，设备签名身份）；
 *   2. attestation（`challenge_nonce`）；
 *   3. 取 aac（`process_client_data`）；
 *   4. `qe/sync` 的密码加密公钥（提交密码那一步的最后一块拼图）。
 *
 * 为什么要它：这四项是**与账号无关**的，任何机器人都能随时验。等真账号登录时如果卡住，
 * 这四项已绿就说明问题出在"账号 ↔ 密码/2FA"那一侧，而不是设备/协议。也方便用户先跑一次
 * 确认网络能通 IG 的 CAA 端点（有些网络会把 `b.i.instagram.com` 掐掉）。
 */
async function runCaaPreflight(argv) {
  const { caaLogin, passwordKeyOf } = require('./caa-login.js');
  const profile = resolveDeviceProfile(argv);
  log('前检开始（不带账号）');
  const result = await caaLogin(profile, '', '', (text) => log(text), { preflightOnly: true });
  let failures = 0;
  for (const step of result.steps) {
    log('  ' + step.step + ' → HTTP ' + step.status + (step.aac ? '（aac ' + step.aac + '）' : ''));
    if (step.status !== 200) {
      failures++;
    }
  }
  if (result.aac.length === 0) {
    warn('没拿到 aac —— 前检没过：' + (result.reason || '原因未知'));
    failures++;
  } else {
    log('  aac 长度 ' + result.aac.length);
  }
  try {
    const keys = await passwordKeyOf(profile);
    /*
     * **405 是正常的**。IG 对 `GET /api/v1/qe/sync/` 固定回 405，但响应头里照样下发
     * `ig-set-password-encryption-key-id` / `-pub-key`（instagrapi 也是 GET，走同一条路）。
     * 所以判据是"头有没有"，不是状态码 —— 这里把这句话直接打出来，免得看日志的人误判。
     */
    const statusNote = keys.status === 200 ? ''
      : '（HTTP ' + keys.status + ' 属预期：IG 对 GET 回 ' + keys.status + '，但公钥头照常下发）';
    log('  qe/sync 密码公钥 → keyId=' + keys.keyId + '，公钥 ' + keys.publicKey.length
      + ' 字符（base64）' + statusNote);
  } catch (error) {
    warn('  拿不到密码加密公钥：' + error.message);
    failures++;
  }
  if (failures > 0) {
    warn('前检结论：有 ' + failures + ' 项没过（设备/网络这一侧的问题，和账号无关）');
    process.exitCode = 2;
    return;
  }
  log('前检结论：设备身份 / attestation / aac / 密码公钥 全通 —— 剩下的只取决于账号');
  process.exitCode = 0;
}

/**
 * `--caa-replay <file>`：**从一份已保存的响应里重建会话**（不需要再登录一次）。
 *
 * 用途：登录过程中解析出错时，响应已经落盘（`.tmp/caa-last-response.json`），修好解析器后
 * 用这条命令重放即可拿到会话 —— R12 真机就是这么救回来的（2FA 那条链其实已经成功，
 * 只是解析没命中）。也方便排查"某次响应该产出什么会话"。
 *
 * 接受两种输入：
 *   · relay 落盘的 dump（带 `raw` 字段）；
 *   · 直接是那一坨响应 JSON。
 */
async function runCaaReplay(argv) {
  const at = argv.indexOf('--caa-replay');
  const file = at >= 0 ? argv[at + 1] : '';
  if (!file) {
    die('用法：node instamony.js --caa-replay <.tmp/caa-last-response.json>');
  }
  const dump = readJson(path.resolve(DIR, file), null);
  if (dump === null) {
    die('读不到 ' + file);
  }
  const raw = dump.raw !== undefined && dump.raw !== null ? dump.raw : dump;
  const { extractLoginPayloadDeep } = require('./caa-login.js');
  const parsed = extractLoginPayloadDeep(raw);
  if (parsed === null) {
    warn('这份响应里没有登录结果（可能不是成功响应，或解析又漏了）');
    process.exitCode = 2;
    return;
  }
  const headers = parsed.headers || {};
  const authorization = String(headers['IG-Set-Authorization']
    || headers['ig-set-authorization'] || '').replace(/^IG-Set-Authorization:\s*/i, '');
  const { sessionHeadersOf } = require('./caa-login.js');
  const sessionHeaders = sessionHeadersOf(headers);
  const profile = resolveDeviceProfile(argv);
  const cookie = Object.keys(parsed.cookies || {})
    .map((name) => `${name}=${parsed.cookies[name]}`).join('; ');
  const session = {
    source: 'caa-replay',
    userId: cookieValueOf(cookie, 'ds_user_id'),
    cookie,
    sessionid: cookieValueOf(cookie, 'sessionid'),
    csrf: cookieValueOf(cookie, 'csrftoken'),
    authorization,
    appVersion: profile.appVersion,
    userAgent: profile.userAgent,
    mid: sessionHeaders.mid || profile.mid,
    rur: sessionHeaders.rur || '',
    claim: sessionHeaders.claim || '',
    savedAt: Date.now()
  };
  const problem = sessionProblemOf(session);
  if (problem.length > 0) {
    warn('响应里的会话不完整（' + problem + '）—— **不覆盖现有会话**');
    process.exitCode = 3;
    return;
  }
  fs.writeFileSync(SESSION_FILE, JSON.stringify(session, null, 2), 'utf8');
  // settingsShapeOf 要的是 `{cookies, authorization, mid}` 这种"登录结果"形状（不是原始响应），
  // 传错会让 settings.caa.json 里的 authorization_data 变成空对象（等价性自检才发现）。
  const shape = settingsShapeOf({
    cookies: parsed.cookies || {},
    authorization,
    mid: session.mid
  }, {
    phoneId: profile.phoneId,
    uuid: profile.uuid,
    androidId: profile.androidId,
    mid: session.mid,
    appVersion: profile.appVersion,
    versionCode: profile.versionCode,
    userAgent: profile.userAgent
  });
  const settingsFile = path.join(DIR, 'settings.caa.json');
  fs.writeFileSync(settingsFile, JSON.stringify(shape, null, 2), 'utf8');
  try {
    fs.unlinkSync(path.join(DIR, 'fbns-auth.json'));
  } catch (error) {
    // 没有就算了
  }
  log('已从响应重建会话：账号 ' + session.userId + '，sessionid '
    + session.sessionid.length + ' 字符，authorization ' + session.authorization.length + ' 字符');
  log('会话写入 ' + SESSION_FILE + '，instagrapi 形状写入 ' + settingsFile);
  const reread = importSession(settingsFile, { dryRun: true });
  log('等价性自检：sessionid ' + (reread.sessionid === session.sessionid ? '一致' : '**不一致**')
    + '，authorization ' + (reread.authorization === session.authorization ? '一致' : '**不一致**'));
  log('下一步：node instamony.js --verify-session');
}

/**
 * `--caa-login`：用**账号密码**登录（CAA/Bloks 流程，Node 版，不需要 Python）。
 */
/*
 * **429 冷却**：IG 的限流是按"尝试次数"记的，被拒之后继续点只会把窗口推远。
 * 本地记一个时间戳，10 分钟内不再发起登录（App 侧 `CaaSession.rateLimitWaitMinutes()` 同一套逻辑）。
 */
const RATE_LIMIT_FILE = path.join(DIR, '.tmp', 'ratelimit.json');
const RATE_LIMIT_GUARD_MINUTES = 10;

/** 还要等几分钟（0 = 没限流记录 / 已过冷却）。 */
function rateLimitWaitMinutes() {
  const mark = readJson(RATE_LIMIT_FILE, null);
  if (mark === null || typeof mark.at !== 'number') {
    return 0;
  }
  const left = RATE_LIMIT_GUARD_MINUTES - (Date.now() - mark.at) / 60000;
  return left > 0 ? Math.ceil(left) : 0;
}

async function runCaaLogin(argv) {
  const { caaLogin } = require('./caa-login.js');

  /*
   * **429 冷却闸门**：上一次被 IG 限流的话，这次直接拦住，别再把窗口往后推。
   *
   * 限流是账号级、按尝试次数算的"失信分"：被 429 之后继续点，等的时间只会变长，
   * 甚至轮到"临时禁止登录"。所以宁可本地先拦住（10 分钟），比 IG 那边拦（可能几十分钟
   * 到几天）划算得多。记号在 `.tmp/ratelimit.json`，`--clear` 会一并清掉。
   */
  const waitMin = rateLimitWaitMinutes();
  if (waitMin > 0 && argv.indexOf('--force') < 0) {
    die('上一次登录被 IG 限流（HTTP 429），还要等 ' + waitMin + ' 分钟才能再试。'
      + '\n  · 这段时间别再点登录（点一次 IG 就把窗口推远一次）；'
      + '\n  · 等着急就先用已有会话：node instamony.js --verify-session；'
      + '\n  · 确实想硬试一次：node instamony.js --caa-login --force（很可能还是 429）。');
  }

  const profile = resolveDeviceProfile(argv);

  /*
   * 凭据来源：交互输入优先，其次环境变量（`INSTAMONY_IG_USER` / `INSTAMONY_IG_PASS`）。
   *
   * 环境变量只为**自动化/自测**（比如用假账号确认链路形状没变）；密码不会落盘、不会打印。
   */
  const envUser = String(process.env.INSTAMONY_IG_USER || '').trim();
  const envPass = String(process.env.INSTAMONY_IG_PASS || '');
  const username = envUser.length > 0 ? envUser : (await readLine('IG 用户名：')).trim();
  if (username.length === 0) die('没输入用户名');
  const password = envPass.length > 0 ? envPass : await readLine('IG 密码（不回显）：', true);
  if (password.length === 0) die('没输入密码');

  // 两步验证时按需提示输入验证码（TOTP 六位 / 短信码 / 备用码八位都走这里）
  const result = await caaLogin(profile, username, password, (text) => log(text), {
    getCode: () => readLine('两步验证码（验证器/短信 6 位，或备用码 8 位）：')
  });

  for (const step of result.steps) {
    log('  ' + step.step + ' → HTTP ' + step.status);
  }

  if (result.loggedIn !== true) {
    warn('登录未成功：' + (result.reason || '未知原因'));
    /*
     * **限流要留个记号**：半小时内再跑直接拒绝，省得把 IG 的窗口越推越远。
     * 记号存在 `.tmp/ratelimit.json`（本机、不进仓库）。
     */
    if (result.rateLimited === true) {
      try {
        fs.mkdirSync(path.join(DIR, '.tmp'), { recursive: true });
        fs.writeFileSync(RATE_LIMIT_FILE,
          JSON.stringify({ at: Date.now() }, null, 2), 'utf8');
        log('已记下冷却：' + RATE_LIMIT_GUARD_MINUTES + ' 分钟内 --caa-login 会被本地拦住'
          + '（`.tmp/ratelimit.json`，`--clear` 可清）');
      } catch (error) {
        // 记不下来也不影响提示
      }
      process.exit(5);
    }
    if (typeof result.twoStepContext === 'string' && result.twoStepContext.length > 0) {
      const ranTwoStep = Array.isArray(result.steps)
        && result.steps.some((one) => String(one.step || '').indexOf('2sv_') === 0);
      if (!ranTwoStep) {
        log('两步验证票据（two_step_verification_context）长度 ' + result.twoStepContext.length
          + ' —— 这次没走 2FA 链？重跑 --caa-login 会提示输入验证码');
      } else {
        log('两步验证票据长度 ' + result.twoStepContext.length + '，2FA 链已尝试（见上面 2sv_* 各步状态）');
      }
    }
    /*
     * **把完整响应落盘**（本地文件，不提交）。
     *
     * 为什么要：形状一变，只靠终端里截断的 600 字符根本没法对齐（R12 就是这么卡住的：
     * 结果是 `CAA_LOGIN_FALLBACK:fallback_triggered` + `embedded_payloads` + 2FA 票据）。
     * 落盘之后可以用工具扫一遍，不必再让用户重跑一次登录。
     */
    if ((result.raw !== undefined && result.raw !== null)
      || (result.sendRaw !== undefined && result.sendRaw !== null)) {
      try {
        const dumpDir = path.join(DIR, '.tmp');
        fs.mkdirSync(dumpDir, { recursive: true });
        const dumpFile = path.join(dumpDir, 'caa-last-response.json');
        fs.writeFileSync(dumpFile, JSON.stringify({
          at: new Date().toISOString(),
          reason: result.reason,
          twoStepContextLength: typeof result.twoStepContext === 'string'
            ? result.twoStepContext.length : 0,
          steps: result.steps,
          raw: result.raw === undefined ? null : result.raw
        }, null, 2), 'utf8');
        log('完整响应已保存：' + dumpFile + '（形状变了的话，把这个文件发我）');
        if (result.sendRaw !== undefined && result.sendRaw !== null) {
          const sendFile = path.join(dumpDir, 'caa-send-response.json');
          fs.writeFileSync(sendFile, JSON.stringify({
            at: new Date().toISOString(),
            steps: result.steps,
            raw: result.sendRaw
          }, null, 2), 'utf8');
          log('提交密码那一步的响应也已保存：' + sendFile + '（2FA 的 app id 就在里面）');
        }
      } catch (error) {
        warn('保存完整响应失败：' + error.message);
      }
    }
    process.exit(3);
  }

  // 成功：写会话 + 设备身份（格式与 --import-session 一致，后续命令可直接跑）
  const cookieParts = [];
  for (const name of Object.keys(result.cookies || {})) {
    if (String(result.cookies[name]).length > 0) {
      cookieParts.push(`${name}=${result.cookies[name]}`);
    }
  }
  const cookie = cookieParts.join('; ');
  /*
   * **`mid` 优先用登录响应带回来的那一份**（`ig-set-x-mid`）。
   *
   * 为什么不能只用设备档案里的：全新机器上档案是本地生成的、`mid` 可能是空；而 IG 在登录
   * 响应里会把真正的机器 id 下发给客户端（instagrapi 也是在 `_send_private_request` 里捡它）。
   * 之后每个移动 API 请求都带 `X-MID`，缺了等于"没有机器 id 的客户端"。
   */
  const sessionMid = String(result.mid || '').length > 0 ? String(result.mid) : profile.mid;
  const session = {
    source: 'caa-login',
    userId: cookieValueOf(cookie, 'ds_user_id'),
    cookie,
    sessionid: cookieValueOf(cookie, 'sessionid'),
    csrf: cookieValueOf(cookie, 'csrftoken'),
    authorization: result.authorization || '',
    appVersion: profile.appVersion,
    userAgent: profile.userAgent,
    mid: sessionMid,
    rur: String(result.rur || ''),
    claim: String(result.claim || ''),
    savedAt: Date.now()
  };
  /*
   * **落盘前先验一遍**：解析出"登录成功"不等于拿到了可用会话。
   *
   * 没有 `sessionid` 的会话写下去只会把**上一份好会话覆盖掉**，之后 `--check` / 常驻全部
   * 报"缺少有效会话"，而人还以为登录成功了。这里宁可什么都不写、把现场打出来（含原始
   * 响应片段），让人知道是"布局形状变了"而不是"我密码错了"。
   */
  if (session.sessionid.length === 0 || session.userId.length === 0) {
    warn('响应里解析出了登录结果，但会话不完整（' + sessionProblemOf(session)
      + '）—— **不覆盖现有会话**');
    // 只打名字（值里是会话材料）；这几行足够判断"布局变了"还是"cookie 少了"。
    log('解析到的 cookie 名：' + JSON.stringify(result.cookieNames || []));
    log('响应里的 header 名：' + JSON.stringify(result.headerNames || []));
    log('login_response.status：' + (result.loginStatus || '(无)')
      + '，message：' + (result.loginMessage || '(无)'));
    /*
     * **把现场整份落盘**（本地文件，不提交）。
     *
     * 为什么要：这次的核心疑问是"IG 到底回了什么" —— cookies 空、headers 里却有
     * `IG-Set-Authorization` / `ig-set-ig-u-ds-user-id`，要么是**中间态**（让重投密码），
     * 要么是我们抠到了错的那个对象。没有原始响应就只能猜，而猜就是在赌账号。
     * 落盘之后用 `--caa-replay` 离线对齐，不必再登录一次。
     */
    if (result.raw !== undefined && result.raw !== null) {
      try {
        const dumpDir = path.join(DIR, '.tmp');
        fs.mkdirSync(dumpDir, { recursive: true });
        const dumpFile = path.join(dumpDir, 'caa-last-response.json');
        fs.writeFileSync(dumpFile, JSON.stringify({
          at: new Date().toISOString(),
          kind: 'incomplete-session',
          reason: '解析出登录结果但没有 sessionid',
          loginStatus: result.loginStatus || '',
          loginMessage: result.loginMessage || '',
          cookieNames: result.cookieNames || [],
          headerNames: result.headerNames || [],
          steps: result.steps,
          raw: result.raw
        }, null, 2), 'utf8');
        log('完整响应已保存：' + dumpFile + '（这次别重试，把这个文件给我就够对齐了）');
      } catch (error) {
        warn('保存完整响应失败：' + error.message);
      }
    } else {
      log('没有拿到原始响应（解析层没把它带回来）—— 需要先修 caa-login.js 才能离线对齐');
    }
    process.exit(4);
  }
  fs.writeFileSync(SESSION_FILE, JSON.stringify(session, null, 2), 'utf8');
  fs.writeFileSync(DEVICE_FILE, JSON.stringify({
    phoneId: profile.phoneId,
    uuid: profile.uuid,
    androidId: profile.androidId,
    createdAt: Date.now()
  }, null, 2), 'utf8');
  try {
    fs.unlinkSync(path.join(DIR, 'fbns-auth.json'));
  } catch (error) {
    // 没有就算了
  }
  log('登录成功：账号 ' + (session.userId || '?'));
  log('会话已写入 ' + SESSION_FILE + '，设备身份已写入 ' + DEVICE_FILE);

  /*
   * **再写一份 instagrapi 形状的会话**（`settings.caa.json`），并当场自检等价性。
   *
   * 目标里要的是"产出与 instagrapi settings.json 等价的会话"。只写我们自己的 session.json
   * 只能证明"我们认得自己"；这份文件能直接喂给 `--import-session`（原先只有 Python 那条路
   * 才产出的格式）——**同一条导入路径能吃下去、且解出来是同一份会话**，才算等价。
   */
  const settingsCaaFile = path.join(DIR, 'settings.caa.json');
  try {
    fs.writeFileSync(settingsCaaFile,
      JSON.stringify(settingsShapeOf(result, profile), null, 2), 'utf8');
    const reread = importSession(settingsCaaFile, { dryRun: true });
    const sameSid = reread.sessionid === session.sessionid;
    const sameAuth = reread.authorization === session.authorization;
    log('等价性自检：settings.caa.json 经 --import-session 解析 → 账号 ' + (reread.userId || '?')
      + '，sessionid ' + (sameSid ? '一致' : '**不一致**')
      + '，authorization ' + (sameAuth ? '一致' : '**不一致**'));
    if (!sameSid || !sameAuth) {
      warn('等价性自检没过：两份会话不一致，别把 settings.caa.json 当等价物用');
    }
  } catch (error) {
    warn('写 settings.caa.json 失败：' + error.message);
  }
  log('下一步：node instamony.js --verify-session   （自证能收推送）然后 node instamony.js');
}

/* -------------------------------------------------------------- 清除会话 */

/*
 * `--clear`：**把本机所有登录态清干净**（退出登录 / 换账号 / 怀疑串号时用）。
 *
 * 为什么要有它：这台机器上"登录态"散在 8 个地方（会话、instagrapi 形状的两份、FBNS 设备凭据、
 * push token 缓存、失败响应转储、429 冷却标记、playwright 浏览器档案）。手动删容易漏 ——
 * 漏一个就等于没退出登录：比如 `fbns-auth.json` 还在，旧账号的 FBNS 连接会被"复活"；
 * `.tmp/caa-last-response.json` 里可能还躺着 set-cookie；`.tmp/ratelimit.json` 还在会让
 * 下一次登录直接被自己拦住 10 分钟。
 *
 * 分两档：
 *   1. `--clear`      —— 只清**会话**（含会话备份、转储、限流标记、浏览器档案）；
 *   2. `--clear --all` —— 连**设备身份**一起清（`mqtt-device.json` / `device-profile.json` /
 *                       `usdid.json`）。换账号**不需要**清设备身份；只有"想换一台设备"或
 *                       "设备身份被 IG 拉黑"时才要清 —— 清完下次登录就是一台全新机器，IG 会
 *                       当成新设备（更容易触发风控），登录尝试次数也会重新算。
 *
 * 安全默认：**不带 `--yes` 只演练**（列出会删什么，不动文件）。删除是真删，不进回收站。
 */
const SESSION_STATE = [
  { file: path.join(DIR, 'session.json'), what: '中转会话（cookie + authorization + mid）' },
  { file: path.join(DIR, 'settings.json'), what: 'instagrapi 形状会话（login_ig.py 产出，--import-session 的来源）' },
  { file: path.join(DIR, 'settings.caa.json'), what: 'instagrapi 形状会话（--caa-login 产出）' },
  { file: path.join(DIR, 'fbns-auth.json'), what: 'FBNS 设备凭据（与登录态绑定，不清会被"复活"）' },
  { file: path.join(DIR, 'token.json'), what: '华为 push token 缓存' },
  { file: path.join(DIR, '.tmp', 'caa-last-response.json'), what: '上次 CAA 响应转储（可能含 set-cookie）' },
  { file: path.join(DIR, '.tmp', 'caa-send-response.json'), what: '上次 send_login_request 响应转储' },
  { file: RATE_LIMIT_FILE, what: '429 限流冷却标记（不清会拦住下一次登录）' },
  { file: path.join(DIR, '.tmp', 'session.json.bak'), what: '会话备份' },
  { file: path.join(DIR, '.tmp', 'session.json.keep'), what: '会话备份' },
  { file: path.join(DIR, '.login-profile'), what: 'playwright 浏览器档案（里面是 IG 网页会话）' }
];

const IDENTITY_STATE = [
  { file: path.join(DIR, 'mqtt-device.json'), what: 'FBNS 设备三元组' },
  { file: path.join(DIR, 'device-profile.json'), what: '本机设备档案（机型/版本/mid）' },
  { file: path.join(DIR, 'usdid.json'), what: 'CAA 设备签名私钥 + USDID 注册状态' }
];

/** 端口是否已被占用（判断常驻中转还在不在跑；只探测，不惊动对端）。 */
function portBusy(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ port, host: '127.0.0.1' });
    const done = (busy) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(busy);
    };
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
    socket.setTimeout(800, () => done(false));
  });
}

function sizeOf(file) {
  try {
    const stat = fs.statSync(file);
    return stat.isDirectory() ? (fs.readdirSync(file).length + ' 项') : (stat.size + ' 字节');
  } catch (error) {
    return '?';
  }
}

async function runClear(argv) {
  const apply = argv.indexOf('--yes') >= 0 || argv.indexOf('-y') >= 0;
  const withIdentity = argv.indexOf('--all') >= 0 || argv.indexOf('--device') >= 0;
  const targets = withIdentity ? SESSION_STATE.concat(IDENTITY_STATE) : SESSION_STATE;

  // 常驻进程手里的会话在内存里：不清掉它，删完文件它照样能推、还可能把会话写回去。
  if (await portBusy(LOCK_PORT)) {
    warn('检测到常驻中转还在跑（127.0.0.1:' + LOCK_PORT + ' 有响应）：'
      + '先停掉它（Ctrl+C）再清，否则它内存里的旧会话还在用。');
  }

  log('将清除' + (withIdentity ? '**会话 + 设备身份**' : '**会话**')
    + '（' + (apply ? '真删' : '演练，不动文件') + '）');
  const hits = [];
  for (const item of targets) {
    const shown = path.relative(DIR, item.file).replace(/\\/g, '/');
    if (fs.existsSync(item.file)) {
      hits.push(item);
      log('  [删] ' + shown + '（' + sizeOf(item.file) + '）  — ' + item.what);
    } else {
      log('  [无] ' + shown + '（不存在，跳过）');
    }
  }

  if (!apply) {
    log('');
    if (hits.length === 0) {
      log('没有任何会话文件，本机已经是"未登录"状态');
    } else {
      log('这是演练：共 ' + hits.length + ' 项会被删除。确认无误后加 --yes 真删：');
      log('  node instamony.js --clear --yes');
      if (!withIdentity) {
        log('（要连设备身份一起清：node instamony.js --clear --yes --all）');
      }
    }
    return;
  }

  let removed = 0;
  const failed = [];
  for (const item of hits) {
    try {
      fs.rmSync(item.file, { recursive: true, force: true });
      removed++;
    } catch (error) {
      failed.push(item.file + '：' + error.message);
    }
  }
  log('');
  log('已删除 ' + removed + '/' + hits.length + ' 项（' + (withIdentity ? '会话 + 设备身份' : '会话')
    + '）');
  for (const text of failed) {
    warn('删不掉：' + text);
  }
  if (!withIdentity) {
    log('设备身份保留（mqtt-device.json / device-profile.json / usdid.json）：'
      + '换账号不用重造设备；要一起清用 --clear --yes --all');
  }
  log('现在处于**未登录**状态。重新登录：node instamony.js --caa-login（或 --import-session <文件>）');
  if (failed.length > 0) {
    process.exit(4);
  }
}

/* ------------------------------------------------------------------ 入口 */

async function main() {
  const argv = process.argv.slice(2);
  quiet = argv.indexOf('--quiet') >= 0;

  if (argv.indexOf('--caa-login') >= 0) {
    await runCaaLogin(argv);
    return;
  }

  /*
   * `--clear`（别名 `--logout` / `--sign-out`）：清除本机所有登录态。
   * 放在最前面 —— 它不该依赖 config.json 能读、也不该被别的分支截走。
   */
  if (argv.indexOf('--clear') >= 0 || argv.indexOf('--logout') >= 0
    || argv.indexOf('--sign-out') >= 0) {
    await runClear(argv);
    return;
  }

  if (argv.indexOf('--caa-preflight') >= 0) {
    await runCaaPreflight(argv);
    return;
  }

  if (argv.indexOf('--caa-replay') >= 0) {
    await runCaaReplay(argv);
    return;
  }

  const importAt = argv.indexOf('--import-session');
  if (importAt >= 0) {
    const file = argv[importAt + 1];
    if (!file) die('用法：node instamony.js --import-session <settings.json>');
    importSession(file);
    return;
  }

  /*
   * `--import-check <file>`：**只解析、不落盘**。
   *
   * 用途：拿到一份 `settings.caa.json`（或 App 里「复制当前会话」导出的那份）时，
   * 先确认"能不能被吃下、里面有没有 sessionid / authorization"，再决定要不要覆盖现有会话。
   */
  const checkAt = argv.indexOf('--import-check');
  if (checkAt >= 0) {
    const file = argv[checkAt + 1];
    if (!file) die('用法：node instamony.js --import-check <settings.caa.json>');
    log('解析 ' + file + '（不落盘）');
    const parsed = importSession(file, { dryRun: true });
    log('  账号          ' + (parsed.userId || '（缺 ds_user_id）'));
    log('  sessionid     ' + parsed.sessionid.length + ' 字符');
    log('  authorization ' + (parsed.authorization.length > 0 ? '有（' + parsed.authorization.length
      + ' 字符）' : '无（会退回用 cookie 拼）'));
    log('  mid           ' + (parsed.mid.length > 0 ? parsed.mid : '（无）'));
    log('  app_version   ' + (parsed.appVersion || '（无）'));
    log('结论：这份文件**可以**用 --import-session 导入');
    return;
  }

  const cfg = loadConfig();

  if (argv.indexOf('--check') >= 0) {
    await runCheck(cfg);
    return;
  }

  if (argv.indexOf('--verify-session') >= 0) {
    await runVerifySession();
    return;
  }

  const testAt = argv.indexOf('--test-push');
  if (testAt >= 0) {
    const text = argv[testAt + 1] || 'Instamony 自检';
    await pushToPhone(cfg, 'Instamony', text, 'test_' + Date.now());
    return;
  }

  await runDaemon(cfg, argv);
}

main().catch((error) => {
  warn('异常退出：' + (error && error.message ? error.message : error));
  releaseLock();
  process.exit(1);
});
