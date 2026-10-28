#!/usr/bin/env node
/*
 * Instamony BYO 中转 —— **跨平台低功耗版**（Windows / Linux / Android-Termux 同一份文件）
 *
 * 干什么：低频、只读地看一眼 IG 收件箱；有新私信就推到你手机。
 * 不干什么：不发消息、不点赞、不关注；不存聊天正文（state.json 只有"每条会话最后一条消息 id + 时间戳"）。
 *
 * 为什么省电（这几条是本版的重点，改之前请先看）：
 *   1. **连接复用**：一个 keepAlive Agent 走到底 —— 每轮不再重新 TLS 握手（这是长时间轮询里
 *      最费电的一步，握手比一次小响应贵得多）；
 *   2. **gzip**：带 `Accept-Encoding: gzip`，几十 KB 的收件箱压到几 KB，无线电唤醒时间更短；
 *   3. **自适应间隔**：有动静就按 `activeSeconds`（默认 90 秒），一直没动静就逐步退到
 *      `idleMaxSeconds`（默认 5 分钟）—— 深夜没人发消息时几乎不耗电；
 *   4. **不做无谓的磁盘写**：state 只在真的变了才落盘（并且是 tmp+rename 原子替换）；
 *   5. **一轮一批**：同一轮里有多条新私信只推一条汇总，避免手机被连续唤醒 N 次；
 *   6. **安静时段**：`quietHours` 内只记账不推送（也不会攒着早上一次性弹出来）。
 *
 * 用法：
 *   node relay.js            # 常驻
 *   node relay.js --once     # 只跑一轮，验配置
 *   node relay.js --quiet    # 只打警告和错误
 *
 * 依赖：只要 Node ≥ 14（零 npm 依赖）。Android 上装在 Termux 里（见 README）。
 */

'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const zlib = require('zlib');
const querystring = require('querystring');

const INBOX_URL = 'https://www.instagram.com/api/v1/direct_v2/inbox/';
const WEB_APP_ID = '936619743392459';
const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const MIN_POLL_SECONDS = 60;
/** 官方文档：HarmonyOS 5+ 只认服务账号 JWT + v3 接口（v2 只服务 3.x/4.x）。 */
const PUSH_SEND = 'https://push-api.cloud.huawei.com/v3/%s/messages:send';
const SA_SCOPE_AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
/** 默认去隔壁 agc 工具目录找服务账号密钥，省得每处都配一遍。 */
const DEFAULT_SA_FILE = path.join(__dirname, '..', 'agc', 'private.json');

/** keepAlive Agent：整轮轮询只建一次连接（省电的主要来源，别改成每发新建）。 */
const agent = new https.Agent({ keepAlive: true, keepAliveMsecs: 120000, maxSockets: 2 });

let quiet = false;

function log(msg) {
  if (quiet) return;
  const stamp = new Date().toTimeString().slice(0, 8);
  console.log('[' + stamp + '] ' + msg);
}

function warn(msg) {
  const stamp = new Date().toTimeString().slice(0, 8);
  console.error('[' + stamp + '] ' + msg);
}

function die(msg) {
  console.error(msg);
  process.exit(2);
}

/* ------------------------------------------------------------------ 配置 */

function configPath() {
  const at = process.argv.indexOf('--config');
  if (at >= 0 && process.argv[at + 1]) return path.resolve(process.argv[at + 1]);
  return path.join(__dirname, 'config.json');
}

function loadConfig() {
  const file = configPath();
  if (!fs.existsSync(file)) {
    /*
     * `--report-only` 是"只收 token"的调试模式，不碰 IG、不需要 cookie/通道配置。
     * 所以没 config.json 也让它跑起来（否则想验证上报还得先抄一份配置模板，太绕）。
     */
    if (process.argv.indexOf('--report-only') >= 0) {
      warn('没有 ' + file + '，按 --report-only 的空配置跑（只验上报，不推任何东西）。');
      return { notify: { channel: 'agc' }, listen: {}, ig: {} };
    }
    die('找不到 ' + file + ' —— 先 cp config.example.json config.json 再填。');
  }
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const notify = cfg.notify || {};
  const channel = notify.channel || 'agc';
  if (channel === 'agc') {
    const agc = notify.agc || {};
    if (agc.clientId || agc.clientSecret) {
      warn('notify.agc 里的 clientId/clientSecret 已经作废（HarmonyOS 5+ 不再支持 OAuth 2.0 开放鉴权，'
        + 'v1 接口也停用了）。这两个字段会被忽略，请改用 serviceAccountFile。');
    }
    if (!notify.pushToken && readTokenFile() === null) {
      // 配了上报端口就不算错：先起来，等 App 把 token 报上来。
      const canReport = Number((cfg.listen && cfg.listen.port) || 0) > 0
        || process.argv.indexOf('--listen') >= 0;
      if (!canReport) {
        die('channel=agc 但既没有 pushToken，也没有 App 上报过的 token。'
          + '\n要么先把 App 里复制出来的 token 填进 notify.pushToken，'
          + '\n要么配 listen.port 让 App 自己上报。');
      }
      log('还没有 pushToken：等 App 上报（POST /token）之后才能推。');
    }
    const saFile = resolveServiceAccountFile(agc);
    if (!fs.existsSync(saFile)) {
      die('找不到服务账号密钥文件 ' + saFile
        + '\n去 AGC → API Console 创建「服务账号密钥」凭证，下载推送服务 API 的 json。');
    }
  } else if (channel === 'meow') {
    if (!(notify.meow && notify.meow.nickname)) die('channel=meow 但没填昵称。');
  } else if (channel === 'telegram') {
    if (!(notify.telegram && notify.telegram.botToken && notify.telegram.chatId)) {
      die('channel=telegram 但 botToken/chatId 没填。');
    }
  } else if (channel === 'webhook') {
    if (!(notify.webhook && notify.webhook.url)) die('channel=webhook 但 url 没填。');
  } else {
    die('未知的 notify.channel: ' + channel);
  }
  return cfg;
}

/** IG cookie 只有"真的要轮询"时才需要，--test-push 不碰它。 */
function requireIgCookie(cfg) {
  const cookie = (cfg.ig && cfg.ig.cookie) || '';
  if (cookie.length < 20) {
    die('config.ig.cookie 无效：先到 App「设定 → 诊断 → 复制中转材料」。');
  }
}

/* ------------------------------------------------------------- HTTP 小工具 */

function request(url, options, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const headers = Object.assign({ 'Accept-Encoding': 'gzip' }, (options && options.headers) || {});
    const req = https.request({
      hostname: target.hostname,
      path: target.pathname + target.search,
      method: (options && options.method) || 'GET',
      headers: headers,
      agent: agent,
      timeout: 30000
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const raw = Buffer.concat(chunks);
        const gz = String(res.headers['content-encoding'] || '').indexOf('gzip') >= 0;
        const done = (buf) => resolve({ status: res.statusCode || 0, body: buf.toString('utf8') });
        if (gz) {
          zlib.gunzip(raw, (error, out) => done(error ? raw : out));
        } else {
          done(raw);
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function csrfOf(cookie) {
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === 'csrftoken') return part.slice(eq + 1).trim();
  }
  return '';
}

/* --------------------------------------------------------------- 拉收件箱 */

async function fetchInbox(cfg) {
  const cookie = cfg.ig.cookie;
  const query = querystring.stringify({
    limit: '15',
    thread_message_limit: '2',
    visual_message_return_type: 'unseen',
    persistentBadging: 'true'
  });
  let res;
  try {
    res = await request(INBOX_URL + '?' + query, {
      headers: {
        Cookie: cookie,
        'User-Agent': DEFAULT_UA,
        'X-IG-App-ID': WEB_APP_ID,
        'X-CSRFToken': csrfOf(cookie),
        'X-ASBD-ID': '129477',
        'X-IG-WWW-Claim': '0',
        'X-Requested-With': 'XMLHttpRequest',
        Referer: 'https://www.instagram.com/direct/inbox/'
      }
    });
  } catch (error) {
    log('IG 请求失败，本轮跳过：' + error.message);
    return [];
  }
  if (res.status === 401 || res.status === 403 || res.body.indexOf('login_required') >= 0) {
    warn('IG 拒绝：会话失效（HTTP ' + res.status + '）。请在 App 里重新登录后重新导出材料。');
    process.exit(3);
  }
  if (res.status !== 200) {
    log('IG HTTP ' + res.status + '，本轮跳过：' + res.body.slice(0, 140));
    return [];
  }
  let data;
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    log('IG 回的不是 JSON，本轮跳过：' + res.body.slice(0, 140));
    return [];
  }
  return (data.inbox || {}).threads || [];
}

/* ------------------------------------------------------------------ 状态 */

function loadState(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return {};
  }
}

function saveState(file, state) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

const KIND_TEXT = {
  media_share: '[分享的帖子]',
  xma_media_share: '[分享的帖子]',
  clip: '[分享的 Reels]',
  xma_clip: '[分享的 Reels]',
  reel_share: '[分享的 Reels]',
  reel_media: '[Reels]',
  link: '[链接]',
  media: '[图片/视频]',
  voice_media: '[语音]',
  animated_media: '[动图]',
  raven_media: '[阅后即焚]',
  like: '[赞了你的消息]'
};

function newestOf(thread) {
  const items = thread.items || [];
  let best = null;
  for (const item of items) {
    const stamp = Number(item.timestamp || 0);
    if (best !== null && stamp <= best.ts) continue;
    let text = item.text || '';
    if (!text) text = KIND_TEXT[item.item_type] || '[消息]';
    const viewerId = thread.viewer_id ? String(thread.viewer_id) : '';
    const mine = !!(viewerId && item.user_id && String(item.user_id) === viewerId);
    best = { id: String(item.item_id || ''), ts: stamp, text: text.slice(0, 120), mine: mine };
  }
  return best;
}

/* ------------------------------------------------- 自分类 IM 合规过滤 */

/**
 * 为什么要"过滤"而不是"能发就发"：
 * 我们给通知消息申请的 category 是 IM（即时聊天）。官方对 IM 的硬性承诺是
 * **只包含互相关注用户之间的点对点私信**，明确排除：未关注人的私信请求
 * （message request / 首次搭话）、官方号或商家批量推送、任何广告内容。
 * 违反分类标准会按《通知违规处罚标准》处理（轻则收回权益、重则判违规），
 * 所以宁可不推，也不要为了一条陌生人的私信把 IM 权益搞掉。
 *
 * 判据都是"保守方向"的：拿不准就当消息请求，不推。
 */

/** 线程标了 pending / 需要审批 —— Instagram 对陌生人首条的处理方式。 */
function looksLikeMessageRequest(thread) {
  if (thread.is_pending === true) return true;
  if (thread.pending === true) return true;
  if (thread.approval_factor !== undefined && thread.approval_factor !== null) return true;
  return false;
}

/**
 * 是否"已有历史往来"。
 * 收件箱请求带 thread_message_limit=2，最多回两条消息：
 *   - 回来的只有 1 条 → 这就是这条会话的第一条消息（首次搭话 / 消息请求），不推；
 *   - 回来 2 条 → 说明前面还有消息，属正常往来，可以推。
 */
function hasConversationHistory(thread) {
  return (thread.items || []).length >= 2;
}

/**
 * 返回空串表示可以推，否则返回跳过原因（会打进日志，便于事后核对）。
 * 顺序有意义：先认消息请求，再认"没有历史"。
 */
function complianceVerdict(thread) {
  if (looksLikeMessageRequest(thread)) return 'message-request';
  if (!hasConversationHistory(thread)) return 'no-history';
  return '';
}

/* ------------------------------------------------------------- 安静时段 */

function inQuietHours(cfg) {
  const q = cfg.notify && cfg.notify.quietHours;
  if (!q || !Array.isArray(q) || q.length !== 2) return false;
  const hour = new Date().getHours();
  const from = Number(q[0]);
  const to = Number(q[1]);
  if (from === to) return false;
  return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to);
}

/* ------------------------------------------------------------------ 推送 */

/** 服务账号密钥文件路径：配置优先，否则用 tools/agc/private.json。 */
function resolveServiceAccountFile(agc) {
  const name = (agc && agc.serviceAccountFile) || DEFAULT_SA_FILE;
  return path.isAbsolute(name) ? name : path.resolve(__dirname, name);
}

function loadServiceAccount(agc) {
  const file = resolveServiceAccountFile(agc);
  const sa = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!sa.private_key) throw new Error(file + ' 里找不到 private_key');
  return sa;
}

/**
 * 服务账号 JWT（PS256）——按官方文档：header 带 kid=key_id、alg=PS256，
 * payload 的 iss=sub_account、aud 固定、exp=iat+3600。这个 JWT 本身**就是**
 * Authorization 里的 Bearer，不用再换 access_token。
 *
 * 有效期一小时，所以缓存起来：轮询每分钟一轮，没必要每轮都 RSA 签一次。
 */
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

async function pushAgc(cfg, title, body, threadId) {
  const agc = cfg.notify.agc || {};
  const sa = loadServiceAccount(agc);
  const projectId = sa.project_id || agc.projectId;
  if (!projectId) throw new Error('服务账号密钥文件里没有 project_id，拼不出 v3 地址');
  const payload = JSON.stringify({
    payload: {
      notification: {
        category: agc.category || 'IM',
        title: title,
        body: body,
        clickAction: { actionType: 0, data: { threadId: threadId } },
        style: 0
      }
    },
    target: { token: [pushTokenNow()] },
    pushOptions: { testMessage: agc.testMessage !== false, ttl: 3600 }
  });
  const res = await request(PUSH_SEND.replace('%s', projectId), {
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
    log('AGC 推送成功：' + (data.requestId || ''));
    return;
  }
  // pushToken 失效（应用重装/清数据/HMS 更新）是最常见的一种，单独点明怎么修。
  warn('AGC 推送失败（HTTP ' + res.status + '）：' + res.body.slice(0, 220));
  if (res.status === 401 || res.status === 403) {
    warn('鉴权失败 = 服务账号 JWT 不对（alg/aud/key_id/project_id）。不是 token 的问题。');
  } else {
    warn('如果反复失败且通知到不了，先在 App 里「复制中转材料」重新取一次 pushToken。');
  }
}

async function pushMeow(cfg, title, body) {
  const nick = cfg.notify.meow.nickname;
  const url = 'https://api.chuckfang.com/' + encodeURIComponent(nick) +
    '/Instamony/' + encodeURIComponent(body.slice(0, 200)) +
    '?url=' + encodeURIComponent(cfg.openUrl || 'instamony://direct');
  const res = await request(url, {});
  log('MeoW 推送：' + res.body.slice(0, 160));
}

async function pushTelegram(cfg, title, body) {
  const tg = cfg.notify.telegram;
  const payload = querystring.stringify({
    chat_id: tg.chatId,
    text: title + '\n' + body,
    disable_web_page_preview: 'true'
  });
  const res = await request('https://api.telegram.org/bot' + tg.botToken + '/sendMessage', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(payload)
    }
  }, payload);
  log('Telegram 推送：' + res.body.slice(0, 120));
}

/**
 * 通用 webhook —— 顺手支持几种**不需要向华为申请任何权限**的 IM 机器人。
 *
 * 为什么要这几个格式：HarmonyOS 原生推送（Push Kit）要走 AGC 审核，走不通时最实际的办法
 * 是"推到手机上一个本来就有通知能力的 App"。企业微信 / 飞书在 HarmonyOS 上都有原生客户端，
 * 群机器人只要一个 webhook URL，零审批、零费用，所以这里按它们的报文格式发：
 *   format = "wecom"  企业微信群机器人      {"msgtype":"text","text":{"content":"…"}}
 *   format = "feishu" 飞书自定义机器人      {"msg_type":"text","content":{"text":"…"}}
 *   format = "bark"   Bark（iOS 用）        GET /{key}/{text}
 *   format = "generic" 默认，原样 POST {title, body, threadId, url}
 */
async function pushWebhook(cfg, title, body, threadId) {
  const hook = cfg.notify.webhook;
  const format = String(hook.format || 'generic');
  const text = title + '\n' + body;
  const link = cfg.openUrl || 'instamony://direct';

  if (format === 'bark') {
    const base = hook.url.replace(/\/+$/, '');
    const url = base + '/' + encodeURIComponent(title) + '/' + encodeURIComponent(body) +
      '?url=' + encodeURIComponent(link);
    const res = await request(url, {});
    log('Bark 推送：' + res.body.slice(0, 120));
    return;
  }

  let payload;
  if (format === 'wecom') {
    payload = JSON.stringify({ msgtype: 'text', text: { content: text } });
  } else if (format === 'feishu') {
    payload = JSON.stringify({ msg_type: 'text', content: { text: text } });
  } else {
    payload = JSON.stringify({ title: title, body: body, threadId: threadId, url: link });
  }
  const headers = {
    'Content-Type': 'application/json; charset=UTF-8',
    'Content-Length': Buffer.byteLength(payload)
  };
  const extra = hook.headers || {};
  for (const key of Object.keys(extra)) headers[key] = String(extra[key]);
  const res = await request(hook.url, { method: 'POST', headers: headers }, payload);
  log('Webhook(' + format + ') 推送：' + res.body.slice(0, 120));
}

async function send(cfg, title, body, threadId) {
  const channel = cfg.notify.channel;
  if (channel === 'agc') return pushAgc(cfg, title, body, threadId);
  if (channel === 'meow') return pushMeow(cfg, title, body);
  if (channel === 'telegram') return pushTelegram(cfg, title, body);
  return pushWebhook(cfg, title, body, threadId);
}

/* --------------------------------------------- token 上报（App → 中转） */

/**
 * 为什么要有这个：pushToken 会变 —— 重装 App、清数据、系统更新 HMS、恢复出厂，
 * 每次变都等于"中转手上那条是废的"，表现是**推送静默失败**（接口还回成功，
 * 因为华为收下了，只是这个 token 不再对应任何设备）。
 * 以前靠人手在设置页「复制中转材料」再粘进配置，几乎必然忘。
 *
 * 现在的路：App 启动和 `tokenUpdate` 时 POST 到这个中转，中转落盘即用。
 * 协议极简（一条 JSON + 一个共享密钥），够用就好，别把它做成一门 RPC。
 *
 *   POST /token   {"token":"…","reason":"startup|tokenUpdate|manual","bundle":"…","version":"…"}
 *   GET  /health  → 中转自报状态（有没有 token、多旧、走哪个通道）
 *
 * 只在配了 `listen.port`（或命令行 `--listen`）时才开端口：不配就完全不开，
 * 免得默认给本机多开一个监听。
 */

const TOKEN_FILE = path.join(__dirname, 'token.json');
/** App 上报的 token（优先于 config.json 里那条）。 */
let liveToken = { token: '', at: 0, reason: '', source: 'config' };
let liveTokenLoaded = false;

function readTokenFile() {
  try {
    const data = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
    if (data && typeof data.token === 'string' && data.token.length > 0) {
      return data;
    }
  } catch (error) {
    // 没有就是第一次跑
  }
  return null;
}

function saveTokenFile(state) {
  const tmp = TOKEN_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmp, TOKEN_FILE);
}

/** 启动时定一次"当前该用哪个 token"，之后由上报端口更新。 */
function initToken(cfg) {
  if (liveTokenLoaded) return;
  liveTokenLoaded = true;
  const reported = readTokenFile();
  if (reported !== null) {
    liveToken = Object.assign({ source: 'report' }, reported);
    log('pushToken 用 App 上报的那条（' + new Date(Number(reported.at) || 0).toLocaleString() + '）');
    return;
  }
  liveToken = { token: (cfg.notify && cfg.notify.pushToken) || '', at: 0, reason: 'config', source: 'config' };
}

/** 实际发推送用的 token。 */
function pushTokenNow() {
  return liveToken.token || '';
}

/** App 上报进来一条 token：落盘 + 立刻生效（下一轮推送就用新的）。 */
function acceptToken(body) {
  const token = String(body.token || '').trim();
  if (token.length < 20) {
    return { ok: false, error: 'token 太短，不像 Push Kit 的 token' };
  }
  const state = {
    token: token,
    at: Date.now(),
    reason: String(body.reason || 'unknown'),
    bundle: String(body.bundle || ''),
    version: String(body.version || '')
  };
  liveToken = Object.assign({ source: 'report' }, state);
  try {
    saveTokenFile(state);
  } catch (error) {
    warn('token 落盘失败：' + error.message + '（本次运行内仍生效）');
  }
  log('收到 App 上报的 pushToken：长度 ' + token.length + '，原因 ' + state.reason
    + '，版本 ' + (state.version || '-') + '（已生效）');
  return { ok: true, at: state.at, tokenLength: token.length };
}

function maskedToken() {
  const token = pushTokenNow();
  if (token.length === 0) return '';
  return token.slice(0, 8) + '…' + token.slice(-4) + '（' + token.length + '）';
}

/** 读请求体（限长，别让一个畸形请求把内存吃了）。 */
function readBody(req, limit) {
  return new Promise((resolve) => {
    let raw = '';
    let tooBig = false;
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      if (tooBig) return;
      raw += chunk;
      if (raw.length > limit) {
        tooBig = true;
        req.destroy();
      }
    });
    req.on('end', () => resolve(tooBig ? null : raw));
    req.on('error', () => resolve(null));
  });
}

function listenPortOf(cfg) {
  const at = process.argv.indexOf('--listen');
  if (at >= 0 && process.argv[at + 1]) return Number(process.argv[at + 1]);
  return Number((cfg.listen && cfg.listen.port) || 0);
}

function listenKeyOf(cfg) {
  const at = process.argv.indexOf('--key');
  if (at >= 0 && process.argv[at + 1]) return String(process.argv[at + 1]);
  return String((cfg.listen && cfg.listen.key) || '');
}

/**
 * 开上报端口。没配端口就返回 null（不监听）。
 *
 * 安全：配了 key 就必须带 `X-Relay-Key`（或 `?key=`）—— 这个端口只该在内网，
 * 但它能改"往哪台设备推送"，所以别裸奔在公网上。
 */
function startReportServer(cfg) {
  const port = listenPortOf(cfg);
  if (!port) return null;
  const key = listenKeyOf(cfg);
  if (key.length < 8) {
    warn('上报端口没设 key（或太短）：局域网里谁都能改推送目标。建议 --key 一串随机字符。');
  }
  const server = http.createServer((req, res) => {
    const send2xx = (code, obj) => {
      const text = JSON.stringify(obj);
      res.writeHead(code, { 'Content-Type': 'application/json; charset=UTF-8' });
      res.end(text);
    };
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/health') {
      const age = liveToken.at > 0 ? Math.round((Date.now() - liveToken.at) / 1000) : -1;
      send2xx(200, {
        ok: true,
        tokenSet: pushTokenNow().length > 0,
        tokenAgeSeconds: age,
        tokenSource: liveToken.source || '',
        tokenPreview: maskedToken(),
        channel: (cfg.notify && cfg.notify.channel) || '',
        now: Date.now()
      });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/token') {
      const given = String(req.headers['x-relay-key'] || url.searchParams.get('key') || '');
      if (key.length >= 8 && given !== key) {
        warn('上报被拒：key 不对（来源 ' + (req.socket.remoteAddress || '-') + '）');
        send2xx(401, { ok: false, error: 'bad key' });
        return;
      }
      readBody(req, 8192).then((raw) => {
        if (raw === null) {
          send2xx(413, { ok: false, error: 'body too large' });
          return;
        }
        let body = {};
        try {
          body = JSON.parse(raw || '{}');
        } catch (error) {
          send2xx(400, { ok: false, error: 'body is not json' });
          return;
        }
        const result = acceptToken(body);
        send2xx(result.ok ? 200 : 400, result);
      });
      return;
    }
    send2xx(404, { ok: false, error: 'not found' });
  });
  server.on('error', (error) => {
    warn('上报端口开不起来（' + port + '）：' + error.message);
  });
  server.listen(port, '0.0.0.0', () => {
    log('上报端口已开：http://<本机IP>:' + port + '（POST /token，GET /health）');
    log('在 App 里「设定 → 中转上报」填 http://<本机IP>:' + port + ' 和同一串 key');
  });
  return server;
}

/* --------------------------------------------------------- 单实例 + 收尾 */

function lockFile() {
  return path.join(__dirname, '.relay.lock');
}

function acquireLock() {
  const file = lockFile();
  try {
    const old = Number(fs.readFileSync(file, 'utf8').trim());
    if (old > 0) {
      try {
        process.kill(old, 0);
        die('已经有一个中转在跑（pid ' + old + '），先停掉它。');
      } catch (error) {
        // 进程不在了：把旧锁当垃圾清掉
      }
    }
  } catch (error) {
    // 没有锁文件：正常
  }
  fs.writeFileSync(file, String(process.pid), 'utf8');
}

function releaseLock() {
  try {
    fs.unlinkSync(lockFile());
  } catch (error) {
    // 忽略
  }
}

/* ------------------------------------------------------------------ 主循环 */

async function main() {
  quiet = process.argv.indexOf('--quiet') >= 0;
  const once = process.argv.indexOf('--once') >= 0;
  const cfg = loadConfig();
  // 先定"当前用哪个 token"：App 上报过就用那条，否则用配置里那条。
  initToken(cfg);
  const reportServer = startReportServer(cfg);
  const testAt = process.argv.indexOf('--test-push');
  if (testAt >= 0) {
    // 只验通道：不看 IG、不占锁、不写 state —— 让"手机到底能不能收到"独立成一步。
    const text = process.argv[testAt + 1] || '中转通道自检';
    try {
      await send(cfg, 'Instamony', text, 'channel-test');
    } finally {
      if (reportServer !== null) reportServer.close();
    }
    return;
  }
  /*
   * 只开上报端口、不轮询：用来"先把 token 收上来"（还没拿到 IG cookie，
   * 或者只想单独确定上报这条路通不通）。进程靠 server 的 handle 活着。
   */
  if (process.argv.indexOf('--report-only') >= 0) {
    if (reportServer === null) {
      die('--report-only 需要配 listen.port 或带 --listen <端口>。');
    }
    log('只开上报端口，不轮询（Ctrl+C 停）');
    return;
  }
  requireIgCookie(cfg);
  const ig = cfg.ig || {};
  const activeGap = Math.max(MIN_POLL_SECONDS, Number(ig.pollSeconds || 90));
  const idleMax = Math.max(activeGap, Number(ig.idleMaxSeconds || 300));
  const stateFile = path.resolve(__dirname, cfg.stateFile || 'state.json');
  if (!once) acquireLock();

  let state = loadState(stateFile);
  let dirty = false;
  let firstRound = true;
  let gap = activeGap;

  const finish = () => {
    if (dirty) saveState(stateFile, state);
    if (reportServer !== null) reportServer.close();
    if (!once) releaseLock();
    process.exit(0);
  };
  process.on('SIGINT', finish);
  process.on('SIGTERM', finish);
  process.on('SIGHUP', finish);

  log('启动：发起间隔 ' + activeGap + 's → 空闲退到 ' + idleMax + 's，通道 ' + cfg.notify.channel);

  for (;;) {
    const threads = await fetchInbox(cfg);
    const fresh = [];
    const skipped = [];
    for (const thread of threads) {
      const threadId = String(thread.thread_id || thread.thread_v2_id || '');
      if (!threadId) continue;
      const newest = newestOf(thread);
      if (!newest) continue;
      const last = state[threadId];
      if (!last) {
        // 第一次见这条会话：只记账不推送（否则一启动就把历史全弹一遍）。
        state[threadId] = { id: newest.id, ts: newest.ts };
        dirty = true;
        continue;
      }
      if (newest.id !== last.id && newest.ts > Number(last.ts || 0)) {
        state[threadId] = { id: newest.id, ts: newest.ts };
        dirty = true;
        if (newest.mine || firstRound) continue;
        // IM 分类的合规红线：消息请求 / 没有历史往来的一律不推。
        // 记账照记（上面已写 state），这样同一会话后续真成了正常往来还能正常推。
        const verdict = complianceVerdict(thread);
        if (verdict) {
          skipped.push(verdict + ':' + (thread.thread_title || threadId));
          continue;
        }
        fresh.push({ id: threadId, title: thread.thread_title || '私信', text: newest.text });
      }
    }

    if (skipped.length > 0) {
      log('合规过滤跳过 ' + skipped.length + ' 条（不推 IM 类以外的场景）：' + skipped.join('，'));
    }

    if (fresh.length > 0) {
      if (inQuietHours(cfg)) {
        log('安静时段：' + fresh.length + ' 条新私信只记账不推送');
      } else {
        try {
          if (fresh.length === 1) {
            await send(cfg, fresh[0].title, fresh[0].text || '你有一条新私信', fresh[0].id);
          } else {
            // **一轮只推一条汇总**：手机少被唤醒几次，也避免连续弹一串。
            await send(cfg, '私信',
              fresh.length + ' 条新私信（' + fresh[0].title + ' 等）', fresh[0].id);
          }
        } catch (error) {
          log('推送失败（下一轮重新判定）：' + error.message);
        }
      }
      log('本轮 ' + fresh.length + ' 条新私信');
    }

    if (dirty) {
      saveState(stateFile, state);
      dirty = false;
    }
    firstRound = false;

    // **自适应间隔**：这一轮有动静就回到活跃档，一直安静就慢慢退到 idleMax。
    gap = fresh.length > 0 ? activeGap : Math.min(idleMax, Math.round(gap * 1.25));
    if (once) {
      if (!quiet) {
        let total = 0;
        for (const key of Object.keys(state)) total++;
        log('一轮跑完：记了 ' + total + ' 条会话的时间点（state 已落盘）');
      }
      releaseLock();
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, Math.round(gap * 1000 * (0.85 + Math.random() * 0.3))));
  }
}

if (require.main === module) {
  main().catch((error) => {
    warn('中转异常退出：' + (error && error.stack ? error.stack : error));
    if (process.argv.indexOf('--once') < 0) releaseLock();
    process.exit(1);
  });
}

module.exports = { complianceVerdict, looksLikeMessageRequest, hasConversationHistory };
