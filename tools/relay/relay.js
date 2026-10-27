#!/usr/bin/env node
/*
 * Instamony BYO 中转（Node 版，零依赖 —— 不用 npm install，也不要求装 Python）
 *
 * 干什么：每 90 秒左右只读地看一眼 IG 收件箱，发现新私信就推到你手机。
 * 不干什么：不发消息、不点赞、不关注；不存聊天正文（state.json 只有"每条会话最后一条消息 id + 时间戳"）。
 *
 * 用法：
 *   1) App：设定 → 诊断 → 复制中转材料（会话 + 推送 token）
 *   2) 把拿到的 JSON 粘进同目录的 config.json（模板见 config.example.json）
 *   3) node relay.js            # 常驻
 *      node relay.js --once     # 只跑一轮，验配置
 *
 * 推送通道（config.notify.channel）：
 *   agc       HarmonyOS 原生通知（需要 AGC 的 appId/clientId/clientSecret + 手机 token）
 *   meow      MeoW 推送（昵称即可，接口见 chuckfang.com/MeoW/api_doc.html）
 *   telegram  Telegram 机器人（botToken + chatId）
 *   webhook   POST 一个 JSON 到你自己的地址（企业微信/钉钉/Bark/自建都行）
 */

'use strict';

const fs = require('fs');
const https = require('https');
const path = require('path');
const querystring = require('querystring');

const INBOX_URL = 'https://www.instagram.com/api/v1/direct_v2/inbox/';
const WEB_APP_ID = '936619743392459';
const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const MIN_POLL_SECONDS = 60;
const AGC_TOKEN_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const AGC_PUSH_URL = 'https://push-api.cloud.huawei.com/v1/%s/messages:send';

function log(msg) {
  const stamp = new Date().toTimeString().slice(0, 8);
  console.log('[' + stamp + '] ' + msg);
}

function die(msg) {
  console.error(msg);
  process.exit(2);
}

/* ------------------------------------------------------------------ 配置 */

function loadConfig() {
  const file = path.join(__dirname, 'config.json');
  if (!fs.existsSync(file)) {
    die('找不到 config.json —— 先 cp config.example.json config.json 再填。');
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
    if (!notify.pushToken) {
      die('channel=agc 但 pushToken 是空的（App 里还没拿到 token）。');
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

/* ------------------------------------------------------------- HTTP 小工具 */

function request(url, options, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = https.request({
      hostname: target.hostname,
      path: target.pathname + target.search,
      method: (options && options.method) || 'GET',
      headers: (options && options.headers) || {},
      timeout: 30000
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { raw += chunk; });
      res.on('end', () => resolve({ status: res.statusCode || 0, body: raw }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function csrfOf(cookie) {
  const parts = cookie.split(';');
  for (const part of parts) {
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
    thread_message_limit: '3',
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
        Referer: 'https://www.instagram.com/direct/inbox/',
        Accept: '*/*'
      }
    });
  } catch (error) {
    log('IG 请求失败，本轮跳过：' + error.message);
    return [];
  }
  if (res.status === 401 || res.status === 403 || res.body.indexOf('login_required') >= 0) {
    log('IG 拒绝：会话失效（HTTP ' + res.status + '）。请在 App 里重新登录后再导出一次。');
    process.exit(3);
  }
  if (res.status !== 200) {
    log('IG HTTP ' + res.status + '，本轮跳过：' + res.body.slice(0, 160));
    return [];
  }
  let data;
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    log('IG 回的不是 JSON，本轮跳过：' + res.body.slice(0, 160));
    return [];
  }
  const inbox = data.inbox || {};
  return inbox.threads || [];
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

async function pushMeow(cfg, title, body, threadId) {
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
  const headers = { 'Content-Type': 'application/json; charset=UTF-8', 'Content-Length': Buffer.byteLength(payload) };
  const extra = hook.headers || {};
  for (const key of Object.keys(extra)) headers[key] = String(extra[key]);
  const res = await request(hook.url, { method: 'POST', headers: headers }, payload);
  log('Webhook 推送：' + res.body.slice(0, 120));
}

async function notify(cfg, title, body, threadId) {
  try {
    const channel = cfg.notify.channel;
    if (channel === 'agc') await pushAgc(cfg, title, body, threadId);
    else if (channel === 'meow') await pushMeow(cfg, title, body, threadId);
    else if (channel === 'telegram') await pushTelegram(cfg, title, body);
    else await pushWebhook(cfg, title, body, threadId);
  } catch (error) {
    log('推送失败（下一轮会重新判定）：' + error.message);
  }
}

/* ------------------------------------------------------------------ 主循环 */

async function main() {
  const once = process.argv.indexOf('--once') >= 0;
  const cfg = loadConfig();
  const gap = Math.max(MIN_POLL_SECONDS, Number((cfg.ig && cfg.ig.pollSeconds) || 90));
  const stateFile = path.join(__dirname, cfg.stateFile || 'state.json');
  const state = loadState(stateFile);
  log('启动：每 ' + gap + ' 秒看一次收件箱（±15% 抖动），推送通道 ' + cfg.notify.channel);
  let firstRound = true;

  for (;;) {
    const threads = await fetchInbox(cfg);
    let fresh = 0;
    for (const thread of threads) {
      const threadId = String(thread.thread_id || thread.thread_v2_id || '');
      if (!threadId) continue;
      const newest = newestOf(thread);
      if (!newest) continue;
      const last = state[threadId];
      if (!last) {
        // 第一次见这条会话：只记账，不推送（否则一启动就把历史全弹一遍）。
        state[threadId] = { id: newest.id, ts: newest.ts };
        continue;
      }
      if (newest.id !== last.id && newest.ts > Number(last.ts || 0)) {
        state[threadId] = { id: newest.id, ts: newest.ts };
        if (newest.mine || firstRound) continue;
        const title = thread.thread_title || '私信';
        const body = newest.text || '你有一条新私信';
        log('新私信：' + title + ' — ' + body);
        await notify(cfg, title, body, threadId);
        fresh++;
      }
    }
    saveState(stateFile, state);
    if (fresh > 0) log('本轮推送 ' + fresh + ' 条');
    firstRound = false;
    if (once) return;
    const sleepMs = Math.round(gap * 1000 * (0.85 + Math.random() * 0.3));
    await new Promise((resolve) => setTimeout(resolve, sleepMs));
  }
}

main().catch((error) => {
  console.error('中转异常退出：' + (error && error.stack ? error.stack : error));
  process.exit(1);
});
