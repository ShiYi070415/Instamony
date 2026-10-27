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
const AGC_TOKEN_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const AGC_PUSH_URL = 'https://push-api.cloud.huawei.com/v1/%s/messages:send';

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
    die('找不到 ' + file + ' —— 先 cp config.example.json config.json 再填。');
  }
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const cookie = (cfg.ig && cfg.ig.cookie) || '';
  if (cookie.length < 20) {
    die('config.ig.cookie 无效：先到 App「设定 → 诊断 → 复制中转材料」。');
  }
  const notify = cfg.notify || {};
  const channel = notify.channel || 'agc';
  if (channel === 'agc') {
    const agc = notify.agc || {};
    if (!agc.appId || !agc.clientId || !agc.clientSecret) {
      die('channel=agc 但 appId/clientId/clientSecret 没填全。');
    }
    if (!notify.pushToken) die('channel=agc 但 pushToken 是空的（App 里还没拿到 token）。');
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

async function agcAccessToken(agc) {
  const body = querystring.stringify({
    grant_type: 'client_credentials',
    client_id: agc.clientId,
    client_secret: agc.clientSecret
  });
  const res = await request(AGC_TOKEN_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(body)
    }
  }, body);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = {};
  }
  if (!data.access_token) throw new Error('AGC 取 token 失败：' + res.body.slice(0, 200));
  return data.access_token;
}

async function pushAgc(cfg, title, body, threadId) {
  const agc = cfg.notify.agc;
  const token = await agcAccessToken(agc);
  const payload = JSON.stringify({
    validate_only: false,
    message: {
      data: JSON.stringify({ threadId: threadId, kind: 'direct' }),
      notification: { title: title, body: body },
      android: { ttl: '86400s', data: JSON.stringify({ threadId: threadId }) },
      token: [cfg.notify.pushToken]
    }
  });
  const res = await request(AGC_PUSH_URL.replace('%s', agc.appId), {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/json; charset=UTF-8',
      'Content-Length': Buffer.byteLength(payload)
    }
  }, payload);
  log('AGC 推送：' + res.body.slice(0, 160));
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

async function pushWebhook(cfg, title, body, threadId) {
  const hook = cfg.notify.webhook;
  const payload = JSON.stringify({
    title: title,
    body: body,
    threadId: threadId,
    url: cfg.openUrl || 'instamony://direct'
  });
  const headers = {
    'Content-Type': 'application/json; charset=UTF-8',
    'Content-Length': Buffer.byteLength(payload)
  };
  const extra = hook.headers || {};
  for (const key of Object.keys(extra)) headers[key] = String(extra[key]);
  const res = await request(hook.url, { method: 'POST', headers: headers }, payload);
  log('Webhook 推送：' + res.body.slice(0, 120));
}

async function send(cfg, title, body, threadId) {
  const channel = cfg.notify.channel;
  if (channel === 'agc') return pushAgc(cfg, title, body, threadId);
  if (channel === 'meow') return pushMeow(cfg, title, body);
  if (channel === 'telegram') return pushTelegram(cfg, title, body);
  return pushWebhook(cfg, title, body, threadId);
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
        fresh.push({ id: threadId, title: thread.thread_title || '私信', text: newest.text });
      }
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

main().catch((error) => {
  warn('中转异常退出：' + (error && error.stack ? error.stack : error));
  if (process.argv.indexOf('--once') < 0) releaseLock();
  process.exit(1);
});
