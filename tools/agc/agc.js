#!/usr/bin/env node
/*
 * AGC（AppGallery Connect）自检小工具 —— 用来把"推送为什么不工作"从猜变成事实。
 *
 * 为什么需要它：真机上 `pushService.getToken()` 回的是 `1000900010 Illegal application
 * identity`，上游 `VerifyCloudCapability result:1003400002` —— 这是**云端应用身份**没认上，
 * 要么是 AGC 里这个应用的签名证书指纹与本地打包证书不一致，要么是 Push 权益没生效。
 * 光看手机日志分不出来，得从 AGC 侧查。
 *
 * 用法（凭据放在同目录的 credentials.json，不进 git，见 .gitignore）：
 *   node agc.js --whoami           # 只打印服务账号里的 project_id / key_id / sub_account 有没有值
 *   node agc.js --push "测试内容"   # 用服务账号 JWT 给手机发一条测试推送
 *   node agc.js --token            # （旧）验证 OAuth 凭据能不能换到 token
 *   node agc.js --app / --certs    # （旧）查应用信息 / 证书列表
 *
 * credentials.json 长这样：
 *   {
 *     "pushToken": "手机里「复制中转材料」得到的 pushToken（--push 必需）",
 *     "serviceAccountFile": "private.json",
 *     "category": "IM",
 *     "testMessage": true,
 *     "appId": "（只有旧的 --app/--certs/--token 才需要）",
 *     "clientId": "旧 OAuth 客户端（Push 用不上，别浪费时间）",
 *     "clientSecret": "..."
 *   }
 *
 * private.json 是官方「服务账号密钥」文件，从
 *   https://developer.huawei.com/consumer/cn/console/api/myApi
 * 选所在项目 → 创建「服务账号密钥」凭证 → 下载「推送服务 API」的密钥文件。
 * 文件里必须含：project_id / key_id / private_key / sub_account。
 *
 * 为什么要这么改（这是踩过的坑，别再走回去）：
 *   HarmonyOS 5+ 的 Push Kit **不再支持 OAuth 2.0 开放鉴权**，只认服务账号 JWT；
 *   而且接口必须是 **v3**（v2 只给 HarmonyOS 3.x/4.x）。
 *   见 https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-jwt-token
 * 于是老代码里 v1 + client_credentials 那条路永远只会拿到 1101/20003，
 * 跟手机、证书、应用身份都没关系 —— 纯粹是协议过时。
 */

'use strict';

const fs = require('fs');
const https = require('https');
const path = require('path');
const querystring = require('querystring');

const CONNECT_TOKEN = 'https://connect-api.cloud.huawei.com/api/oauth2/v1/token';
const CONNECT_APPINFO = 'https://connect-api.cloud.huawei.com/api/publish/v2/app-info';
const CONNECT_CERTS = 'https://connect-api.cloud.huawei.com/api/publish/v2/certificates';
const PUSH_TOKEN = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
/** 官方文档：v3/{projectId}/messages:send（v2 只服务 HarmonyOS 3.x/4.x）。 */
const PUSH_SEND = 'https://push-api.cloud.huawei.com/v3/%s/messages:send';
const SA_SCOPE_AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';

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

function loadCredentials() {
  const file = path.join(__dirname, 'credentials.json');
  if (!fs.existsSync(file)) {
    console.error('缺少 ' + file + '（模板见本文件头部的注释）。');
    process.exit(2);
  }
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

/** 老的 OAuth 路径才需要 client_id/secret；Push 走服务账号，不查这两个。 */
function requireOAuth(cred) {
  if (!cred.clientId || !cred.clientSecret) {
    console.error('这个命令要 credentials.json 里的 clientId / clientSecret。');
    process.exit(2);
  }
}

/** 读服务账号密钥文件（官方下载的 private.json）。 */
function loadServiceAccount(cred) {
  const name = cred.serviceAccountFile || 'private.json';
  const file = path.isAbsolute(name) ? name : path.join(__dirname, name);
  if (!fs.existsSync(file)) {
    console.error('缺少服务账号密钥文件 ' + file);
    console.error('去 https://developer.huawei.com/consumer/cn/console/api/myApi');
    console.error('选所在项目 → 创建「服务账号密钥」凭证 → 下载「推送服务 API」的密钥文件。');
    process.exit(2);
  }
  const sa = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!sa.private_key) {
    console.error(file + ' 里找不到 private_key。');
    process.exit(2);
  }
  return sa;
}

/**
 * 服务账号 JWT —— 按官方文档第 3/4/5 步：Header(alg=PS256,kid=key_id) +
 * Payload(aud=tokne接口,iss=sub_account,iat,exp) + 私钥 PS256 签名。
 * 这个 JWT **本身就是** Authorization 里的 Bearer，不需要再换 access_token。
 */
function serviceJwt(sa) {
  const crypto = require('crypto');
  const now = Math.floor(Date.now() / 1000);
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const signingInput = b64({ kid: sa.key_id, typ: 'JWT', alg: 'PS256' })
    + '.' + b64({ aud: SA_SCOPE_AUD, iss: sa.sub_account, iat: now, exp: now + 3600 });
  const privateKey = String(sa.private_key).replace(/\\n/g, '\n');
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: privateKey,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST
  }).toString('base64url');
  return signingInput + '.' + signature;
}

/** Connect API 的项目级 token（查应用/证书用）。 */
async function connectToken(cred) {
  const body = JSON.stringify({
    grant_type: 'client_credentials',
    client_id: cred.clientId,
    client_secret: cred.clientSecret
  });
  const res = await request(CONNECT_TOKEN, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(body)
    }
  }, body);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = {};
  }
  if (!data.access_token) {
    throw new Error('换 token 失败（HTTP ' + res.status + '）：' + res.body.slice(0, 240));
  }
  return data.access_token;
}

/** Push Kit 的 token（发推送用，和 Connect API 是两个不同的地址）。 */
async function pushToken(cred) {
  const body = querystring.stringify({
    grant_type: 'client_credentials',
    client_id: cred.clientId,
    client_secret: cred.clientSecret
  });
  const res = await request(PUSH_TOKEN, {
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
  if (!data.access_token) {
    throw new Error('Push token 失败（HTTP ' + res.status + '）：' + res.body.slice(0, 240));
  }
  return data.access_token;
}

async function cmdToken(cred) {
  requireOAuth(cred);
  const token = await connectToken(cred);
  console.log('Connect API token OK，长度 ' + token.length + '（有效期约 1 小时）');
  try {
    const push = await pushToken(cred);
    console.log('Push Kit token OK，长度 ' + push.length);
  } catch (error) {
    console.log('Push Kit token 失败：' + error.message);
    console.log('→ 正常。HarmonyOS 5+ 不再支持 OAuth 2.0 开放鉴权，这条只是历史探针，');
    console.log('  真正的推送请用 --push（服务账号 JWT）。');
  }
}

async function cmdApp(cred) {
  requireOAuth(cred);
  if (!cred.appId) {
    console.error('credentials.json 里缺 appId。');
    process.exit(2);
  }
  const token = await connectToken(cred);
  const res = await request(CONNECT_APPINFO + '?appId=' + encodeURIComponent(cred.appId), {
    headers: {
      Authorization: 'Bearer ' + token,
      client_id: cred.clientId
    }
  });
  if (res.status !== 200) {
    console.log('查应用信息失败（HTTP ' + res.status + '）：' + res.body.slice(0, 400));
    return;
  }
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    console.log('回包不是 JSON：' + res.body.slice(0, 240));
    return;
  }
  const info = data.appInfo || data;
  // 只打和身份有关的字段（不打 secret 之类）。
  const keys = ['appId', 'appName', 'packageName', 'bundleName', 'appType', 'platform',
    'sha256', 'certFingerprint', 'fingerprints', 'releaseState', 'appStatus'];
  for (const key of keys) {
    if (info[key] !== undefined) {
      console.log(key + ' = ' + JSON.stringify(info[key]));
    }
  }
  console.log('--- 原始字段名（便于核对 API 版本差异）---');
  console.log(Object.keys(info).join(', '));
}

async function cmdCerts(cred) {
  requireOAuth(cred);
  const token = await connectToken(cred);
  const res = await request(CONNECT_CERTS, {
    headers: {
      Authorization: 'Bearer ' + token,
      client_id: cred.clientId
    }
  });
  if (res.status !== 200) {
    console.log('查证书失败（HTTP ' + res.status + '）：' + res.body.slice(0, 400));
    return;
  }
  try {
    const data = JSON.parse(res.body);
    console.log(JSON.stringify(data, null, 2).slice(0, 4000));
  } catch (error) {
    console.log(res.body.slice(0, 400));
  }
}

/** 只核对密钥文件填得对不对，不发网络请求（避免拿 400 猜原因）。 */
async function cmdWhoami(cred) {
  const sa = loadServiceAccount(cred);
  const mask = (v) => {
    const s = String(v || '');
    if (!s) return '（缺失！）';
    return s.length <= 8 ? s : s.slice(0, 4) + '***' + s.slice(-4) + '（长度 ' + s.length + '）';
  };
  console.log('密钥文件      = ' + (cred.serviceAccountFile || 'private.json'));
  console.log('project_id    = ' + mask(sa.project_id));
  console.log('key_id        = ' + mask(sa.key_id));
  console.log('sub_account   = ' + mask(sa.sub_account));
  console.log('private_key   = ' + (sa.private_key ? '有（' + String(sa.private_key).length + ' 字符）' : '（缺失！）'));
  console.log('pushToken     = ' + mask(cred.pushToken));
  console.log('category      = ' + (cred.category || 'IM'));
  console.log('testMessage   = ' + (cred.testMessage !== false));
  const jwt = serviceJwt(sa);
  console.log('JWT           = 已生成，长度 ' + jwt.length + '（' + jwt.split('.').length + ' 段）');
  console.log('推送地址       = ' + PUSH_SEND.replace('%s', sa.project_id || '（缺 project_id！）'));
  if (!sa.key_id || !sa.sub_account) {
    console.log('缺 key_id / sub_account —— 这个文件不是「服务账号密钥」，换一个。');
  }
}

/**
 * 按官方文档发一条通知消息（push-type: 0）。
 * 结构：payload.notification + target.token + 可选 pushOptions。
 */
async function cmdPush(cred, text, categoryArg) {
  const sa = loadServiceAccount(cred);
  if (!cred.pushToken) {
    console.error('发测试推送需要 credentials.json 里的 pushToken（App 里「复制中转材料」能拿到）。');
    process.exit(2);
  }
  const projectId = sa.project_id || cred.projectId;
  if (!projectId) {
    console.error('密钥文件里没有 project_id，无法拼 v3 地址。');
    process.exit(2);
  }
  const category = categoryArg || cred.category || 'IM';
  const jwt = serviceJwt(sa);
  const body = JSON.stringify({
    payload: {
      notification: {
        category: category,
        title: 'Instamony',
        body: text || '这是一条测试推送',
        clickAction: { actionType: 0 },
        style: 0
      }
    },
    target: { token: [cred.pushToken] },
    pushOptions: { testMessage: cred.testMessage !== false, ttl: 3600 }
  });
  const res = await request(PUSH_SEND.replace('%s', projectId), {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + jwt,
      'Content-Type': 'application/json; charset=UTF-8',
      'Content-Length': Buffer.byteLength(body),
      'push-type': '0'
    }
  }, body);
  console.log('POST ' + PUSH_SEND.replace('%s', projectId) + '（push-type: 0, category=' + category + '）');
  console.log('HTTP ' + res.status);
  console.log(res.body.slice(0, 800));
  if (res.status === 200 && res.body.indexOf('"code":"80000000"') >= 0) {
    console.log('→ 成功。手机应该已经弹通知了。');
  }
}

async function main() {
  const argv = process.argv.slice(2);
  const cred = loadCredentials();
  if (argv.indexOf('--whoami') >= 0) return cmdWhoami(cred);
  const at = argv.indexOf('--push');
  if (at >= 0) return cmdPush(cred, argv[at + 1], argv[at + 2]);
  if (argv.indexOf('--token') >= 0) return cmdToken(cred);
  if (argv.indexOf('--app') >= 0) return cmdApp(cred);
  if (argv.indexOf('--certs') >= 0) return cmdCerts(cred);
  console.log('用法：');
  console.log('  node agc.js --whoami                       # 核对服务账号密钥文件');
  console.log('  node agc.js --push "测试内容" [category]    # 发一条推送（category 默认 IM）');
  console.log('  node agc.js --token | --app | --certs      # 旧的 OAuth 探针（Push 用不上）');
}

if (require.main === module) {
  main().catch((error) => {
    console.error('失败：' + (error && error.message ? error.message : error));
    process.exit(1);
  });
}

module.exports = { serviceJwt, loadServiceAccount, cmdPush, PUSH_SEND };
