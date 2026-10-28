#!/usr/bin/env node
/*
 * **推送网关**：把"用华为 Push Kit 发通知"这件事开放给其他用户，但私钥不出这台机器。
 *
 * ## 为什么要有它
 * 别人想用 instamony.js 收私信通知，就必须能发华为推送；而发推送需要**服务账号私钥**
 * （AGC 的 `private.json`）。把私钥发给每个人等于把推送权交出去（谁拿到都能给任意 token 发）。
 * 所以改成：他们本机只跑 IG 那半段，通知内容 POST 到这台网关，由网关用私钥发出去。
 *
 * ## 接口（极简，够用）
 *   POST /register   {"token":"<华为 pushToken>"}   头 `X-Gateway-Key: <我们发给他的 key>`
 *                    → 把这个 token 记在该 key 名下（`/send` 只会发给同名下的 token）
 *   POST /send       {"title":"…","body":"…","itemKey":"…"}
 *                    → 用私钥发到该 key 名下的所有 token
 *   GET  /health     → 自报状态（不需要 key）
 *
 * ## 安全边界（必须知道）
 *   · 每个用户一个 key，只能发到**自己注册的 token**（不能指定别人的）；
 *   · 密钥与服务账号私钥都只在本机，`tokens.json` 也在本机（已 gitignore）；
 *   · 仍然建议放在内网/隧道后面，别裸奔在公网（虽然泄露 key 只影响自己那台设备）。
 *
 * ## 跑起来
 *   node gateway.js                       # 默认监听 config.json 里的 port
 *   node gateway.js --port 8788
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');

const DIR = __dirname;
const CONFIG_FILE = path.join(DIR, 'config.json');
const TOKENS_FILE = path.join(DIR, 'tokens.json');

const SA_SCOPE_AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const PUSH_SEND = 'https://push-api.cloud.huawei.com/v3/%s/messages:send';
const DEFAULT_SA_FILE = path.join(DIR, '..', 'agc', 'private.json');

const clock = () => new Date().toTimeString().slice(0, 8);
const log = (text) => console.log(`[${clock()}] ${text}`);
const warn = (text) => console.error(`[${clock()}] ${text}`);

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
    console.error('缺少 ' + CONFIG_FILE);
    console.error('复制模板：copy config.example.json config.json，然后填 keys');
    process.exit(2);
  }
  if (!Array.isArray(cfg.keys) || cfg.keys.length === 0) {
    console.error('config.json 里 keys 是空的 —— 至少给一个用户配 key');
    process.exit(2);
  }
  return cfg;
}

/* ------------------------------------------------------- tokens.json（按 key 分组） */

function loadTokens() {
  const data = readJson(TOKENS_FILE, {});
  return data !== null && typeof data === 'object' ? data : {};
}

function saveTokens(tokens) {
  const tmp = TOKENS_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(tokens, null, 2), 'utf8');
  fs.renameSync(tmp, TOKENS_FILE);
}

/** key → 它名下的 token 列表（key 本身不落盘，只落 hash 前 16 位，避免文件泄露即失效）。 */
function keySlot(key) {
  return crypto.createHash('sha256').update(String(key)).digest('hex').slice(0, 16);
}

/* --------------------------------------------------- 华为 Push Kit（发送侧） */

let jwtCache = { value: '', exp: 0 };

function serviceJwt(sa) {
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

function notifyIdOf(text) {
  let sum = 0;
  const raw = String(text || '');
  for (let index = 0; index < raw.length; index++) {
    sum = (sum * 31 + raw.charCodeAt(index)) % 2147483647;
  }
  return sum > 0 ? sum : 1;
}

function httpsRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const req = require('https').request({
      hostname: target.hostname,
      path: target.pathname + target.search,
      method: (options && options.method) || 'GET',
      headers: (options && options.headers) || {},
      timeout: 20000
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

/**
 * 给某个用户的 token 发通知。
 *
 * `appMessageId` / `notifyId` 的字符集与长度限制很硬（带冒号会被整条拒收，回 80100003），
 * 这里统一做一次清洗。
 */
/**
 * 通知的点击跳转 URI（与 App 侧 `core/DeepLink` / `core/NotifyRoute` 同一套约定）。
 *
 * `instarmony://open?route=direct&id=<会话id>&from=notify` —— `from=notify` 让 App
 * 走"通知点击"分支（直接进会话），而不是外部深链的落地页。
 *
 * 为什么必须有：华为 Push Kit 的点按行为由服务端下发的 `clickAction` 决定；
 * 只写 `{actionType:0}` 的话点开永远是 App 首页（用户报的"没进正确会话"就是这个）。
 */
function deepLinkOf(threadId) {
  const id = String(threadId || '').trim();
  if (id.length === 0) {
    return '';
  }
  return 'instarmony://open?route=direct&id=' + encodeURIComponent(id) + '&from=notify';
}

async function sendToTokens(cfg, tokens, title, body, itemKey, threadId) {
  const agc = cfg.agc || {};
  const saFile = agc.serviceAccountFile
    ? path.resolve(DIR, agc.serviceAccountFile) : DEFAULT_SA_FILE;
  const sa = readJson(saFile, null);
  if (sa === null) throw new Error('找不到服务账号密钥 ' + saFile);
  const projectId = sa.project_id;
  if (!projectId) throw new Error('密钥文件里没有 project_id');

  const rawId = String(itemKey || Date.now());
  const messageId = /^[A-Za-z0-9+/=_\-\s]{1,64}$/.test(rawId) ? rawId : String(notifyIdOf(rawId));
  const link = deepLinkOf(threadId);
  const payload = JSON.stringify({
    payload: {
      notification: {
        category: agc.category || 'IM',
        title: title,
        body: body,
        // 点通知直达那条会话（见 deepLinkOf）；没有会话 id 时退回首页
        clickAction: link.length > 0 ? { actionType: 3, uri: link } : { actionType: 0 },
        style: 0,
        notifyId: notifyIdOf(rawId),
        appMessageId: messageId
      }
    },
    target: { token: tokens },
    pushOptions: { testMessage: agc.testMessage !== false, ttl: 3600, collapseKey: -1 }
  });
  const res = await httpsRequest(PUSH_SEND.replace('%s', projectId), {
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
  if (data.code !== '80000000') {
    throw new Error('推送失败（HTTP ' + res.status + '）：' + res.body.slice(0, 200));
  }
  return data.requestId || '';
}

/* ------------------------------------------------------------------ HTTP 服务 */

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

function startServer(cfg) {
  const port = Number(process.argv.indexOf('--port') >= 0
    ? process.argv[process.argv.indexOf('--port') + 1] : (cfg.port || 8788));
  const keySet = new Set(cfg.keys.map((item) => String(item.key || '')).filter((k) => k.length >= 8));
  if (keySet.size === 0) {
    console.error('config.json 里的 key 都太短（至少 8 个字符）');
    process.exit(2);
  }

  const server = http.createServer(async (req, res) => {
    const reply = (code, obj) => {
      const text = JSON.stringify(obj);
      res.writeHead(code, { 'Content-Type': 'application/json; charset=UTF-8' });
      res.end(text);
    };
    const url = new URL(req.url || '/', 'http://127.0.0.1');

    if (req.method === 'GET' && url.pathname === '/health') {
      const tokens = loadTokens();
      let total = 0;
      for (const slot of Object.keys(tokens)) total += (tokens[slot].length || 0);
      reply(200, { ok: true, keys: keySet.size, tokens: total, now: Date.now() });
      return;
    }

    const given = String(req.headers['x-gateway-key'] || url.searchParams.get('key') || '');
    if (!keySet.has(given)) {
      warn('拒绝：key 不对（来源 ' + (req.socket.remoteAddress || '-') + '）');
      reply(401, { ok: false, error: 'bad key' });
      return;
    }
    const slot = keySlot(given);

    if (req.method === 'POST' && url.pathname === '/register') {
      const raw = await readBody(req, 4096);
      if (raw === null) { reply(413, { ok: false, error: 'body too large' }); return; }
      let body = {};
      try {
        body = JSON.parse(raw || '{}');
      } catch (error) {
        reply(400, { ok: false, error: 'body is not json' });
        return;
      }
      const token = String(body.token || '').trim();
      if (token.length < 20) {
        reply(400, { ok: false, error: 'token 太短' });
        return;
      }
      const tokens = loadTokens();
      const list = Array.isArray(tokens[slot]) ? tokens[slot] : [];
      if (list.indexOf(token) < 0) list.push(token);
      tokens[slot] = list.slice(-10);      // 每个 key 最多留 10 个（重装会换 token）
      saveTokens(tokens);
      log('登记 token（key ' + slot.slice(0, 6) + '…，现有 ' + tokens[slot].length + ' 个）');
      reply(200, { ok: true, tokens: tokens[slot].length });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/send') {
      const raw = await readBody(req, 8192);
      if (raw === null) { reply(413, { ok: false, error: 'body too large' }); return; }
      let body = {};
      try {
        body = JSON.parse(raw || '{}');
      } catch (error) {
        reply(400, { ok: false, error: 'body is not json' });
        return;
      }
      const tokens = loadTokens();
      /*
       * **优先用客户端自带的 token**（无状态模式，和 serverless 版一致）：
       * 这样网关不需要保存任何用户数据，也就不依赖磁盘/数据库，
       * 直接搬到 Vercel 之类的免费函数托管也能跑。
       * 没带 token 时才回退到 /register 登记过的列表（老用法）。
       */
      const inlineToken = String(body.token || '').trim();
      let list = [];
      if (inlineToken.length >= 20) {
        list = [inlineToken];
      } else {
        list = Array.isArray(tokens[slot]) ? tokens[slot] : [];
      }
      if (list.length === 0) {
        reply(412, { ok: false, error: '请求体没有 token，且这个 key 也没登记过 token（先调 /register）' });
        return;
      }
      const title = String(body.title || 'Instamony').slice(0, 100);
      const text = String(body.body || '').slice(0, 300);
      try {
        const requestId = await sendToTokens(cfg, list, title, text, body.itemKey, body.threadId);
        log('已发（key ' + slot.slice(0, 6) + '…）：' + title + ' —— ' + text + '  [' + requestId + ']');
        reply(200, { ok: true, requestId });
      } catch (error) {
        warn('发送失败：' + error.message);
        reply(502, { ok: false, error: error.message });
      }
      return;
    }

    reply(404, { ok: false, error: 'not found' });
  });

  server.on('error', (error) => {
    if (error.code === 'EADDRINUSE') {
      console.error('端口 ' + port + ' 被占用 —— 可能已经有一个网关在跑');
      process.exit(2);
    }
    console.error('网关启动失败：' + error.message);
    process.exit(1);
  });
  server.listen(port, '0.0.0.0', () => {
    log('推送网关已启动：http://<本机IP>:' + port);
    log('  已配置 ' + keySet.size + ' 个用户的 key');
    log('  其他用户：POST /register 登记 token → POST /send 发通知');
    log('  健康检查：GET /health');
  });
}

startServer(loadConfig());
