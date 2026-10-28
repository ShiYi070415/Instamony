/*
 * **推送网关（Serverless 版）** —— 可直接部署到 Vercel / Netlify 等免费托管的函数。
 *
 * ## 为什么是无状态的
 * 免费托管（Vercel 函数、Workers）没有常驻磁盘，存不了"用户 → token"的映射。
 * 所以让**客户端每次自带 token**：网关只做两件事 —— 校验 key、用私钥转发给华为。
 * 好处：零存储、零数据库、天然可水平扩展；代价：key 泄露者可以给"他知道的 token"发通知
 * （token 是 100+ 字符的随机串，且每人一个 key 可随时吊销）。
 *
 * ## 部署（Vercel，5 分钟）
 *   1. 把这个 `vercel` 目录推到 GitHub，或本地 `npx vercel`；
 *   2. 项目设置里加两个环境变量：
 *        HUAWEI_SA_JSON   = tools/agc/private.json 的**完整内容**（一段 JSON）
 *        GATEWAY_KEYS     = 用逗号分隔的 key 列表，例如 "keyA123456,keyB123456"
 *   3. 部署后拿到域名，形如 https://xxx.vercel.app/api/push
 *
 * ## 接口
 *   POST /api/push
 *   Header: X-Gateway-Key: <某个 GATEWAY_KEYS 里的 key>
 *   Body:   {"token":"<华为 pushToken>","title":"…","body":"…","itemKey":"…"}
 *   返回:   {"ok":true,"requestId":"…"} 或 {"ok":false,"error":"…"}
 *
 *   GET /api/push   → 健康检查（不需要 key）
 */

'use strict';

const crypto = require('crypto');

const SA_SCOPE_AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const PUSH_SEND = 'https://push-api.cloud.huawei.com/v3/%s/messages:send';

/** 每个实例内缓存 JWT（有效期 1 小时），避免每次都做 RSA 签名。 */
let jwtCache = { value: '', exp: 0 };

function readServiceAccount() {
  const raw = process.env.HUAWEI_SA_JSON || '';
  if (raw.length === 0) {
    throw new Error('没配环境变量 HUAWEI_SA_JSON（服务账号密钥的完整 JSON）');
  }
  const sa = JSON.parse(raw);
  if (!sa.private_key || !sa.project_id) {
    throw new Error('HUAWEI_SA_JSON 里缺 private_key / project_id');
  }
  return sa;
}

function allowedKeys() {
  return String(process.env.GATEWAY_KEYS || '')
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item.length >= 8);
}

/** 服务账号 JWT（PS256），这个 JWT 本身就是 Authorization 里的 Bearer。 */
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

/** 字符串 → 31 位整数（华为 notifyId 的取值域）。 */
function notifyIdOf(text) {
  let sum = 0;
  const raw = String(text || '');
  for (let index = 0; index < raw.length; index++) {
    sum = (sum * 31 + raw.charCodeAt(index)) % 2147483647;
  }
  return sum > 0 ? sum : 1;
}

/**
 * 通过华为 Push Kit v3 发一条通知。
 *
 * 两个坑都踩过了，别再改回去：
 *   · `appMessageId` 只允许 `[A-Za-z0-9+/=_-]`，带冒号会被整条拒收（80100003）；
 *   · 请求头必须带 `push-type: 0`，否则接口报参数错误。
 */
/**
 * 通知的点击跳转 URI（与 App 侧 `core/DeepLink` / `core/NotifyRoute` 同一套约定）。
 *
 * `instarmony://open?route=direct&id=<会话id>&from=notify`：`from=notify` 让 App 走
 * "通知点击"分支直接进会话，而不是外部深链的落地页。
 *
 * 为什么必须有：华为 Push Kit 的点按行为由服务端下发的 `clickAction` 决定；
 * `{actionType:0}` 点开永远是首页 —— 用户报的"没进正确会话"就是这个。
 */
function deepLinkOf(threadId) {
  const id = String(threadId || '').trim();
  if (id.length === 0) {
    return '';
  }
  return 'instarmony://open?route=direct&id=' + encodeURIComponent(id) + '&from=notify';
}

async function sendPush(sa, token, title, body, itemKey, threadId) {
  const rawId = String(itemKey || Date.now());
  const messageId = /^[A-Za-z0-9+/=_\-\s]{1,64}$/.test(rawId) ? rawId : String(notifyIdOf(rawId));
  const link = deepLinkOf(threadId);
  const payload = JSON.stringify({
    payload: {
      notification: {
        category: process.env.PUSH_CATEGORY || 'IM',
        title: title,
        body: body,
        // 点通知直达那条会话（见 deepLinkOf）；没有会话 id 时退回首页
        clickAction: link.length > 0 ? { actionType: 3, uri: link } : { actionType: 0 },
        style: 0,
        notifyId: notifyIdOf(rawId),
        appMessageId: messageId
      }
    },
    target: { token: [token] },
    pushOptions: { testMessage: false, ttl: 3600, collapseKey: -1 }
  });
  const res = await fetch(PUSH_SEND.replace('%s', sa.project_id), {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + serviceJwt(sa),
      'Content-Type': 'application/json; charset=UTF-8',
      'push-type': '0'
    },
    body: payload
  });
  const text = await res.text();
  let data = {};
  try {
    data = JSON.parse(text);
  } catch (error) {
    data = {};
  }
  if (data.code !== '80000000') {
    throw new Error('华为返回失败（HTTP ' + res.status + '）：' + text.slice(0, 200));
  }
  return data.requestId || '';
}

/** Vercel / Netlify 通用入口（Node 运行时）。 */
module.exports = async function handler(req, res) {
  const reply = (code, obj) => {
    res.statusCode = code;
    res.setHeader('Content-Type', 'application/json; charset=UTF-8');
    res.end(JSON.stringify(obj));
  };

  if (req.method === 'GET') {
    reply(200, {
      ok: true,
      service: 'instamony-push-gateway',
      keys: allowedKeys().length,
      now: Date.now()
    });
    return;
  }
  if (req.method !== 'POST') {
    reply(405, { ok: false, error: '只支持 POST' });
    return;
  }

  const given = String(
    (req.headers && (req.headers['x-gateway-key'] || req.headers['X-Gateway-Key'])) || ''
  );
  if (allowedKeys().indexOf(given) < 0) {
    reply(401, { ok: false, error: 'bad key' });
    return;
  }

  // Vercel 自动解析 JSON 到 req.body；拿不到就自己读流
  let body = req.body;
  if (body === undefined || body === null || typeof body === 'string') {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const raw = Buffer.concat(chunks).toString('utf8');
    try {
      body = JSON.parse(raw || '{}');
    } catch (error) {
      reply(400, { ok: false, error: 'body 不是 JSON' });
      return;
    }
  }

  const token = String(body.token || '').trim();
  if (token.length < 20) {
    reply(400, { ok: false, error: 'token 缺失或太短' });
    return;
  }
  const title = String(body.title || 'Instamony').slice(0, 100);
  const text = String(body.body || '').slice(0, 300);

  try {
    const requestId = await sendPush(readServiceAccount(), token, title, text, body.itemKey,
      body.threadId);
    reply(200, { ok: true, requestId });
  } catch (error) {
    reply(502, { ok: false, error: error.message });
  }
};
