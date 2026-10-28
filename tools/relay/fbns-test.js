#!/usr/bin/env node
/*
 * FBNS 通道验证器：连上 `mqtt-mini.facebook.com` → 申请 push token → 打印收到的推送。
 *
 * 为什么要单独一个：FBNS 有两步容易卡住（CONNACK 里的设备凭据、80 号 topic 的注册响应），
 * 混在 relay 主循环里排查很痛苦。这里只做"连上 → 拿 token → 等推送"。
 *
 * 用法：
 *   node fbns-test.js             # 连上并等推送（Ctrl+C 停）
 *   node fbns-test.js 180         # 跑 180 秒
 *
 * 期望输出：
 *   [fbns] CONNACK rc=0
 *   [fbns] 申请 push token…（随后 topic 80 回 {"token":"..."}）
 *   [fbns] 推送：{"collapse_key":"direct_v2_message", ...}   ← 有人给你发私信
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { FbnsClient } = require('./fbns.js');

const CONFIG = path.join(__dirname, 'config.json');

function pick(cookie, name) {
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return '';
}

const clock = () => new Date().toTimeString().slice(0, 8);
const log = (text) => console.log(`[${clock()}] ${text}`);

/**
 * 把 FBNS 的 push token 注册给 IG（`push/register/`）。
 *
 * 不注册的话，broker 那边连上了也不会推东西过来 —— 这是"最后一步"。
 * 字段照抄 instagrapi 的 `register_push_token`（device_type=android_mqtt 等）。
 */
function registerPushToken(cookie, userId, token) {
  const https = require('https');
  const querystring = require('querystring');
  const pick2 = (name) => pick(cookie, name);
  const auth = 'Bearer IGT:2:' + Buffer.from(JSON.stringify({
    ds_user_id: pick2('ds_user_id'),
    sessionid: decodeURIComponent(pick2('sessionid')),
    should_use_header_over_cookies: true
  })).toString('base64url');
  const form = querystring.stringify({
    device_type: 'android_mqtt',
    is_main_push_channel: 'true',
    device_sub_type: '2',
    device_token: token,
    _csrftoken: pick2('csrftoken'),
    guid: pick2('ig_did') || userId,
    uuid: pick2('ig_did') || userId,
    users: userId,
    family_device_id: pick2('ig_did') || userId
  });
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: 'i.instagram.com',
      path: '/api/v1/push/register/',
      method: 'POST',
      headers: {
        Cookie: cookie,
        Authorization: auth,
        'User-Agent': 'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; o1s; exynos2100; en_US; 1079242191)',
        'X-IG-App-ID': '567067343352427',
        'X-IG-Capabilities': '3brTv10=',
        'X-IG-Connection-Type': 'WIFI',
        'X-IG-WWW-Claim': '0',
        'X-CSRFToken': pick2('csrftoken'),
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(form),
        Accept: '*/*'
      }
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { raw += chunk; });
      res.on('end', () => {
        try {
          resolve(JSON.parse(raw));
        } catch (error) {
          resolve({ status: res.statusCode, body: raw.slice(0, 300) });
        }
      });
    });
    req.on('error', reject);
    req.write(form);
    req.end();
  });
}

async function main() {
  const seconds = Number(process.argv[2] || 0);
  let cookie = '';
  try {
    cookie = JSON.parse(fs.readFileSync(CONFIG, 'utf8')).ig.cookie || '';
  } catch (error) {
    console.error('读不到 config.json 的 ig.cookie');
    process.exit(2);
  }
  const userId = pick(cookie, 'ds_user_id');
  if (userId.length === 0) {
    console.error('cookie 里没有 ds_user_id');
    process.exit(2);
  }

  const client = new FbnsClient({
    stateDir: __dirname,
    clientId: userId,
    userId: Number(userId),
    log: log
  });

  client.on('up', () => {
    log('CONNACK rc=0，申请 push token');
    client.requestPushToken();
  });
  client.on('registered', async (payload) => {
    log('注册响应：' + JSON.stringify(payload).slice(0, 400));
    const token = payload && payload.token ? String(payload.token) : '';
    if (token.length === 0) return;
    try {
      const result = await registerPushToken(cookie, userId, token);
      log('push/register/ → ' + JSON.stringify(result).slice(0, 300));
      log('注册完成：现在让另一台设备给你发私信，观察是否出现「推送：」');
    } catch (error) {
      log('push/register/ 失败：' + error.message);
    }
  });
  client.on('push', (payload) => {
    log('推送：' + JSON.stringify(payload).slice(0, 600));
  });
  client.on('down', (reason) => log('断开：' + reason));

  await client.connect();
  log('已连接，等待 IG 推送（让别人给你发一条私信）…');

  const stop = () => {
    log(`统计：报文 ${client.stats.packets}，推送 ${client.stats.pushes}`);
    client.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  if (seconds > 0) setTimeout(stop, seconds * 1000);
}

main().catch((error) => {
  console.error('失败：' + (error && error.message ? error.message : error));
  process.exit(1);
});
