/*
 * **CAA（Bloks）密码登录 —— Node 移植版**
 *
 * ## 为什么要它
 * `login_ig.py` 依赖 Python + instagrapi。把这个流程移植成 JS 之后，其他用户
 * 只需要 Node（不用装 Python）；而且这套协议就是 App 内登录要用的同一套。
 *
 * ## 旧接口为什么不能用
 * `/api/v1/accounts/login/` 现在对任何请求都可能回
 * `{"error_type":"needs_upgrade"}`（实测 5 个版本号 + 完整客户端头 + 假用户名都是），
 * 真正还能登录的是 **CAA（Bloks）流程**，也就是这里移植的这套。
 *
 * ## 流程（照 instagrapi 的 mixins/attestation.py + bloks.py）
 *   1. **USDID**：本地生成 P-256 密钥 → 用 ES256 签一个注册令牌 →
 *      GraphQL `IGUSDIDRegistrationMutation` 把公钥登记给 IG；
 *   2. **attestation**：`POST attestation/create_android_keystore/` 拿 `challenge_nonce`；
 *      IG 接受"keystore 不可用"这一状态（`errors: [-1013]`），所以**不需要 Play Integrity**；
 *   3. **取 aac**：`bloks/async_action/com.bloks.www.bloks.caa.login.process_client_data_and_redirect/`
 *      从返回的 Bloks 布局里取出服务端下发的 `CAA_ACCOUNT_ACCESS_CONTEXT:aac`；
 *   4. **oauth token fetch**：`com.bloks.www.caa.login.oauth.token.fetch.async`；
 *   5. **提交账号密码**：`com.bloks.www.bloks.caa.login.async.send_login_request`，
 *      密码用 `#PWD_INSTAGRAM:4:` 混合加密，请求头带 `X-IG-Attest-Params`；
 *   6. 成功时响应里嵌着 login_response / headers / cookies（两步验证另走 ap.two_step_verification 链）。
 *
 * ## 当前状态
 * 第 1~5 步已实现；**成功/两步验证的响应解析**先做成"尽力解析 + 原样打印"，
 * 因为不同账号返回的 Bloks 布局形状不同，需要拿真实响应来对齐（见 LOGIN.md）。
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const https = require('https');
const querystring = require('querystring');

const DIR = __dirname;
const IG_APP_ID = '567067343352427';
const CAA_API_DOMAIN = 'b.i.instagram.com';
/** IG 的 GraphQL 直连端点（Bloks / USDID 都走它）。 */
const GRAPHQL_DOMAIN = 'i.instagram.com';
const USDID_REGISTRATION_CLIENT_DOC_ID = '124930351917786857261002920888';
const MOBILE_UA =
  'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1344x2992; Google/google; ' +
  'Pixel 8 Pro; husky; husky; en_US; 1079242191)';
const BLOKS_VERSION_ID = '799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b';

/** instagrapi 的 `dumps`：紧凑 JSON（无空格）。 */
const dumps = (obj) => JSON.stringify(obj);
const b64u = (buffer) => Buffer.from(buffer).toString('base64url');

/* ------------------------------------------------------------------ HTTP */

function request(options, body) {
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

/* ------------------------------------------------------- 设备 / 应用档案 */

/**
 * 从 instagrapi 的 settings.json 里取设备与应用档案。
 *
 * 为什么依赖它：CAA 登录要用到**同一套设备身份 + app_version + version_code +
 * bloks_versioning_id + mid**，这些必须与后续请求一致，否则会被判为伪造客户端。
 * 所以 `--caa-login` 之前需要先有一份 settings.json（哪怕是别的账号的也行，
 * 只取设备档案；那份会话本身不会被复用）。
 */
function loadDeviceProfile(file) {
  // 去 BOM（Windows 编辑器可能加），否则 JSON.parse 直接抛
  const settings = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  const uuids = settings.uuids || {};
  const app = settings.device_settings || {};
  const profile = {
    phoneId: String(uuids.phone_id || ''),
    uuid: String(uuids.uuid || ''),
    androidId: String(uuids.android_device_id || '').replace(/^android-/, ''),
    mid: String(settings.mid || ''),
    appVersion: String(app.app_version || '449.0.0.52.84'),
    versionCode: String(app.version_code || '1079242191'),
    bloksVersionId: String(app.bloks_versioning_id || BLOKS_VERSION_ID),
    userAgent: String(settings.user_agent || MOBILE_UA)
  };
  if (profile.phoneId.length === 0 || profile.uuid.length === 0) {
    throw new Error('settings.json 的 uuids 不全（需要 phone_id / uuid）');
  }
  return profile;
}

/** 移动端请求头（随设备档案走，登录前后都用这一套）。 */
function headersFor(profile, extra) {
  const headers = {
    'User-Agent': profile.userAgent,
    'X-IG-App-ID': IG_APP_ID,
    'X-IG-Capabilities': '3brTv10=',
    'X-IG-Connection-Type': 'WIFI',
    'X-IG-WWW-Claim': '0',
    'X-IG-Device-ID': profile.uuid,
    'X-IG-Android-ID': profile.androidId,
    'X-IG-Family-Device-ID': profile.phoneId,
    'X-IG-App-Locale': 'en_US',
    'X-IG-Device-Locale': 'en_US',
    'X-IG-Mapped-Locale': 'en_US',
    'X-Pigeon-Session-Id': 'UFS-' + crypto.randomUUID() + '-1',
    'X-Pigeon-Rawclienttime': (Date.now() / 1000).toFixed(3),
    'X-IG-Bandwidth-Speed-KBPS': '-1.000',
    'X-IG-Bandwidth-TotalBytes-B': '0',
    'X-IG-Bandwidth-TotalTime-MS': '0',
    'X-Bloks-Version-Id': profile.bloksVersionId,
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
    Accept: '*/*',
    Connection: 'keep-alive'
  };
  if (profile.mid.length > 0) headers['X-MID'] = profile.mid;
  /*
   * `X-Meta-Usdid`：设备签名头。instagrapi 的 base_headers 在"有 usdid 私钥"时
   * 一定会带上它；CAA 登录期间缺这个头容易被判成非本机设备。
   */
  if (profile.usdidHeader && profile.usdidHeader.length > 0) {
    headers['X-Meta-Usdid'] = profile.usdidHeader;
  }
  return Object.assign(headers, extra || {});
}

/* ------------------------------------------------------------- USDID 身份 */

/**
 * USDID = 设备侧的一对 P-256 密钥。IG 用它给请求做**设备级签名**。
 *
 * 两个产物：
 *   · `X-Meta-Usdid` 头：`{usdid}.{expires}.{sig}`（sig 是对前者DER ECDSA 签名）；
 *   · 注册令牌：一个 ES256 的 JWT（这里用手工拼装，因为结构是 IG 自定义的
 *     `{payload, signatures:[{protected, signature}]}`）。
 */
class Usdid {
  constructor(profile, stateFile) {
    this.profile = profile;
    this.stateFile = stateFile;
    this.state = this.load();
  }

  load() {
    try {
      const data = JSON.parse(fs.readFileSync(this.stateFile, 'utf8').replace(/^\uFEFF/, ''));
      if (data && typeof data.privateKey === 'string' && data.privateKey.length > 0) {
        return data;
      }
    } catch (error) {
      // 第一次
    }
    return this.generate();
  }

  generate() {
    const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', {
      namedCurve: 'P-256',
      publicKeyEncoding: { type: 'spki', format: 'der' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
    });
    const state = {
      usdid: crypto.randomUUID(),
      kid: b64u(crypto.randomBytes(32)),
      privateKey: privateKey,
      publicKeyDer: Buffer.from(publicKey).toString('base64'),
      registered: false,
      createdAt: Date.now()
    };
    try {
      fs.writeFileSync(this.stateFile, JSON.stringify(state, null, 2), 'utf8');
    } catch (error) {
      // 落盘失败也能跑一次
    }
    this.state = state;
    return state;
  }

  /** DER 编码的 ECDSA 签名（与 instagrapi 的 encoding="der" 一致）。 */
  sign(message) {
    return crypto.sign('sha256', Buffer.from(message, 'utf8'), {
      key: this.state.privateKey,
      dsaEncoding: 'der'
    });
  }

  /** `X-Meta-Usdid: {usdid}.{expires}.{sig}` */
  header(ttlSeconds = 3600) {
    const expires = Math.floor(Date.now() / 1000) + ttlSeconds;
    const signedPart = `${this.state.usdid}.${expires}`;
    return `${signedPart}.${b64u(this.sign(signedPart))}`;
  }

  /** 注册令牌：IG 自定义的 `{payload, signatures}` 结构。 */
  registrationToken(ttlSeconds = 3600) {
    const now = Math.floor(Date.now() / 1000);
    const payload = b64u(Buffer.from(dumps({
      sub: this.state.usdid,
      iat: now,
      aud: IG_APP_ID,
      exp: now + ttlSeconds,
      pub: this.state.publicKeyDer,
      alg: 'ES256'
    }), 'utf8'));
    const protectedPart = b64u(Buffer.from(dumps({
      typ: 'JWT',
      alg: 'ES256',
      kid: this.state.kid,
      aid: IG_APP_ID,
      ver: '1'
    }), 'utf8'));
    const signature = b64u(this.sign(`${protectedPart}.${payload}`));
    return b64u(Buffer.from(dumps({
      payload,
      signatures: [{ protected: protectedPart, signature }]
    }), 'utf8'));
  }

  markRegistered() {
    this.state.registered = true;
    try {
      fs.writeFileSync(this.stateFile, JSON.stringify(this.state, null, 2), 'utf8');
    } catch (error) {
      // 忽略
    }
  }
}

/* ------------------------------------------------ GraphQL（USDID 注册用） */

/**
 * instagrapi 的 `private_graphql_www_request`：把 GraphQL 查询塞进 Bloks 风格的
 * `graphql_www` 端点。USDID 注册只用到这一个 mutation，所以这里只实现通用形态。
 */
async function graphqlWww(profile, friendlyName, variables, clientDocId, extraHeaders) {
  const body = querystring.stringify({
    client_doc_id: clientDocId,
    variables: dumps(variables),
    server_timestamps: 'true',
    fb_api_caller_class: 'graphql',
    fb_api_req_friendly_name: friendlyName
  });
  const headers = headersFor(profile, Object.assign({
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'Content-Length': Buffer.byteLength(body),
    'X-FB-Friendly-Name': friendlyName,
    'X-Graphql-Client-Library': 'pando'
  }, extraHeaders || {}));
  const res = await request({
    hostname: GRAPHQL_DOMAIN,
    path: '/graphql_www',
    method: 'POST',
    headers: headers,
    timeout: 25000
  }, body);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = { raw: res.body.slice(0, 400) };
  }
  return { status: res.status, headers: res.headers, data };
}

/* ------------------------------------------------------------- Bloks 调用 */

/** Bloks 请求体：`params` / `_uuid` / `bk_client_context` / `bloks_versioning_id`。 */
function bloksPayload(profile, params) {
  return querystring.stringify({
    params: dumps(params),
    _uuid: profile.uuid,
    bk_client_context: dumps({
      bloks_version: profile.bloksVersionId,
      styles_id: 'instagram'
    }),
    bloks_versioning_id: profile.bloksVersionId
  });
}

/**
 * `POST https://b.i.instagram.com/api/v1/bloks/async_action/{action}/`
 *
 * 注意域名是 **b.i.instagram.com**（CAA 专用），不是 i.instagram.com。
 */
async function bloksAsyncAction(profile, action, params, extraHeaders) {
  const body = bloksPayload(profile, params);
  const headers = headersFor(profile, Object.assign({
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'Content-Length': Buffer.byteLength(body),
    'X-FB-Friendly-Name': `IgApi: bloks/async_action/${action}/`
  }, extraHeaders || {}));
  const res = await request({
    hostname: CAA_API_DOMAIN,
    path: `/api/v1/bloks/async_action/${action}/`,
    method: 'POST',
    headers: headers,
    timeout: 30000
  }, body);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = { raw: res.body.slice(0, 600) };
  }
  return { status: res.status, headers: res.headers, data };
}

/** `POST https://b.i.instagram.com/api/v1/bloks/apps/{app}/`（两步验证用）。 */
async function bloksApp(profile, app, params) {
  const body = bloksPayload(profile, params);
  const headers = headersFor(profile, {
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'Content-Length': Buffer.byteLength(body)
  });
  const res = await request({
    hostname: CAA_API_DOMAIN,
    path: `/api/v1/bloks/apps/${app}/`,
    method: 'POST',
    headers: headers,
    timeout: 30000
  }, body);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = { raw: res.body.slice(0, 600) };
  }
  return { status: res.status, headers: res.headers, data };
}

/* --------------------------------------------------------- 密码加密（混合） */

/**
 * 公钥输入统一成 PEM。
 *
 * `qe/sync` 的响应头 `ig-set-password-encryption-pub-key` 是 **base64(PEM)**；
 * 但测试/其他调用方可能直接给 PEM 或 base64(DER)。三种都收，统一转成 PEM 再交给 OpenSSL
 * —— 早先只按 base64 解、直接当 key 传给 `publicEncrypt`，遇到 DER 就报
 * `DECODER routines::unsupported`（离线自检就是这么发现的）。
 */
function publicKeyPemOf(text) {
  const raw = String(text || '').trim();
  if (raw.length === 0) {
    throw new Error('公钥是空的');
  }
  if (raw.indexOf('-----BEGIN') >= 0) {
    return raw;
  }
  let decoded = '';
  try {
    decoded = Buffer.from(raw, 'base64').toString('utf8');
  } catch (error) {
    decoded = '';
  }
  if (decoded.indexOf('-----BEGIN') >= 0) {
    return decoded;
  }
  // 剩下的当 base64(DER)：包成 PEM
  const compact = raw.replace(/\s+/g, '');
  const lines = compact.match(/.{1,64}/g) || [];
  return '-----BEGIN PUBLIC KEY-----\n' + lines.join('\n') + '\n-----END PUBLIC KEY-----\n';
}

/**
 * 纯加密部分：**不联网**（公钥 keyId/公钥由调用方给），方便单测。
 *
 * 报文格式（`#PWD_INSTAGRAM:4:<timestamp>:<base64>` 的 base64 段）：
 *   `0x01 | keyId(1B) | iv(12B) | u16le(RSABlockLen) | RSA(sessionKey, PKCS1v1.5) | tag(16B) | AES-Ct`
 * AES 是 AES-256-GCM，**AAD 必须是那个时间戳字符串**。
 */
function encryptPasswordWithKey(password, publicKeyText, keyId) {
  const sessionKey = crypto.randomBytes(32);
  const iv = crypto.randomBytes(12);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const rsaEncrypted = crypto.publicEncrypt({
    key: publicKeyPemOf(publicKeyText),
    padding: crypto.constants.RSA_PKCS1_PADDING
  }, sessionKey);
  const cipher = crypto.createCipheriv('aes-256-gcm', sessionKey, iv);
  cipher.setAAD(Buffer.from(timestamp, 'utf8'));
  const aesEncrypted = Buffer.concat([cipher.update(password, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  const sizeBuffer = Buffer.alloc(2);
  sizeBuffer.writeUInt16LE(rsaEncrypted.length, 0);
  const payload = Buffer.concat([
    Buffer.from([0x01, keyId & 0xFF]), iv, sizeBuffer, rsaEncrypted, tag, aesEncrypted
  ]).toString('base64');
  return `#PWD_INSTAGRAM:4:${timestamp}:${payload}`;
}

/**
 * 取密码加密公钥（`qe/sync` 的响应头）。
 *
 * 单独一条是为了**不联网登录也能验**：`--caa-preflight` 用它证明"到了提交密码那一步之前的
 * 最后一块拼图（公钥）拿得到"，不需要任何账号。
 *
 * @returns `{ keyId, publicKey }`（publicKey 是 base64(PEM)）
 */
async function passwordKeyOf(profile) {
  const res = await request({
    hostname: 'i.instagram.com',
    path: '/api/v1/qe/sync/',
    method: 'GET',
    headers: headersFor(profile),
    timeout: 20000
  });
  const keyId = Number(res.headers['ig-set-password-encryption-key-id']);
  const publicKey = String(res.headers['ig-set-password-encryption-pub-key'] || '');
  if (!keyId || publicKey.length === 0) {
    throw new Error('qe/sync 没给密码加密公钥（HTTP ' + res.status + '）');
  }
  return { keyId, publicKey, status: res.status };
}

/**
 * `#PWD_INSTAGRAM:4:<timestamp>:<base64>`（RSA 传会话密钥 + AES-GCM 传密码）。
 * 公钥从 `qe/sync` 的响应头取；AES-GCM 的 **AAD 必须是那个时间戳**。
 */
async function encryptPassword(profile, password) {
  const keys = await passwordKeyOf(profile);
  return encryptPasswordWithKey(password, keys.publicKey, keys.keyId);
}

/* ------------------------------------------------------------- 响应解析 */

/** 收集 JSON 里所有字符串（Bloks 布局把上下文藏在 lispy 字符串里）。 */
function collectStrings(value, output) {
  if (typeof value === 'string') {
    output.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, output);
  } else if (value !== null && typeof value === 'object') {
    for (const key of Object.keys(value)) collectStrings(value[key], output);
  }
}

/**
 * 取 `aac`（CAA 账号访问上下文）。
 *
 * Bloks 布局里形如 `data: [{key: "CAA_ACCOUNT_ACCESS_CONTEXT:aac", initial: "..."}]`；
 * 有时只在 `initial_lispy` 的 lispy 表达式里，所以两种都试。
 */
function extractAac(data) {
  const layout = (data || {}).layout || {};
  const payload = layout.bloks_payload || {};
  const list = payload.data || [];
  if (Array.isArray(list)) {
    for (const node of list) {
      const entry = node && node.data;
      if (!entry || entry.key !== 'CAA_ACCOUNT_ACCESS_CONTEXT:aac') continue;
      if (typeof entry.initial === 'string' && entry.initial.trim().length > 0) {
        return entry.initial;
      }
      const lispy = String(entry.initial_lispy || '');
      const quote = lispy.indexOf('"');
      if (quote >= 0) {
        try {
          const value = JSON.parse(lispy.slice(quote, lispy.indexOf('"', quote + 1) + 1));
          if (typeof value === 'string' && value.length > 0) return value;
        } catch (error) {
          // 继续
        }
      }
    }
  }
  return '';
}

/** 从响应里找 `two_step_verification_context`（两步验证要用）。 */
function extractTwoStepContext(data) {
  const strings = [];
  collectStrings(data, strings);
  for (const text of strings) {
    if (text.indexOf('two_step_verification_context') < 0) continue;
    const index = text.indexOf('two_step_verification_context');
    const tail = text.slice(index);
    const quote = tail.indexOf('"', tail.indexOf(':'));
    if (quote >= 0) {
      try {
        const value = JSON.parse(tail.slice(quote, tail.indexOf('"', quote + 1) + 1));
        if (typeof value === 'string' && value.length > 0) return value;
      } catch (error) {
        // 继续
      }
    }
  }
  return '';
}

/**
 * 从一个 `"` 开始，取**完整的 JSON 字符串字面量**（含两端引号）。
 *
 * 为什么要自己走一遍：真实 payload 里的字符串**层层转义**（`\"login_response\"`），
 * 直接用 `indexOf('"', start + 1)` 找结尾会停在第一个转义引号上，截出来的东西
 * `JSON.parse` 必然失败 —— 于是"登录成功却解析不出会话"。离线自检就是这么暴露的。
 */
function jsonStringAt(text, start) {
  if (text[start] !== '"') {
    return '';
  }
  let escaped = false;
  for (let index = start + 1; index < text.length; index++) {
    const ch = text[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      escaped = true;
      continue;
    }
    if (ch === '"') {
      return text.slice(start, index + 1);
    }
  }
  return '';
}

/** Cookie 串里那些**是属性、不是 Cookie** 的名字（按 Python `SimpleCookie` 的语义）。 */
const COOKIE_ATTRIBUTES = [
  'path', 'domain', 'expires', 'max-age', 'secure', 'httponly', 'samesite', 'priority',
  'comment', 'commenturl', 'version', 'port', 'discard'
];

/**
 * 解析 Bloks 给的 Cookie 串（行为对齐 instagrapi 用的 Python `SimpleCookie`）。
 *
 * 为什么不能只按 `;` 切：真实响应里有两种形状
 *   ① `sessionid=x; Path=/; Domain=.instagram.com; HttpOnly`（后面全是属性）
 *   ② `Set-Cookie: sessionid=x; Path=/, Set-Cookie: ds_user_id=1; Path=/`（多颗，逗号分隔）
 * 只按 `;` 切会把 `Path`、`Domain` 当成 Cookie 塞进罐里，而 `ds_user_id` 会因为名字带
 * `, Set-Cookie: ` 前缀**整个丢掉** —— 离线自检里就是这么暴露的（网页会话能建、账号 id 空）。
 */
function parseCookieHeader(text) {
  const out = {};
  const raw = String(text || '').replace(/Set-Cookie:\s*/gi, '');
  for (const part of raw.split(/[;,]/)) {
    const one = part.trim();
    if (one.length === 0) {
      continue;
    }
    const cut = one.indexOf('=');
    if (cut <= 0) {
      continue;
    }
    const name = one.slice(0, cut).trim();
    const value = one.slice(cut + 1).trim();
    if (name.length === 0 || value.length === 0) {
      continue;
    }
    if (COOKIE_ATTRIBUTES.indexOf(name.toLowerCase()) >= 0) {
      continue;
    }
    out[name] = value;
  }
  return out;
}

/**
 * 从登录响应头里捡**会话材料**（不只是 authorization）。
 *
 * instagrapi 在 `_send_private_request` 里就会捡这几条（`ig-set-x-mid` 等），我们也要捡：
 * 全新安装时本机 `mid` 是空的，而 `X-MID` 是移动 API 的身份头之一；不把它从登录响应里
 * 带回来的话，登录成功之后的请求等于"没有机器 id 的客户端"。
 *
 * @returns `{ mid, rur, claim }`（没有的项是空串）
 */
function sessionHeadersOf(headers) {
  const out = { mid: '', rur: '', claim: '' };
  const map = headers || {};
  for (const key of Object.keys(map)) {
    const lower = key.toLowerCase();
    const value = String(map[key] === undefined || map[key] === null ? '' : map[key])
      .replace(/^[A-Za-z-]+:\s*/, '').trim();
    if (lower === 'ig-set-x-mid' && value.length > 0) {
      out.mid = value;
    } else if (lower === 'ig-set-ig-u-rur' && value.length > 0) {
      out.rur = value;
    } else if (lower === 'x-ig-set-www-claim' && value.length > 0) {
      out.claim = value;
    }
  }
  return out;
}

/**
 * 从 Bloks 响应里抠出登录结果（cookie + authorization）。
 *
 * 成功时响应 `layout.bloks_payload.action` 里嵌着一段 JSON 字符串，含
 * `login_response` / `headers` / `cookies`。这里把它解出来。
 */
function extractLoginPayload(data) {
  const action = ((data || {}).layout || {}).bloks_payload;
  if (!action || typeof action.action !== 'string') return null;
  const text = action.action;
  const marker = text.indexOf('login_response');
  if (marker < 0) return null;
  // 从 marker 往前找最近的字符串起点，逐个试（越靠近 marker 越可能是那一段）。
  for (let start = marker; start >= 0; start--) {
    if (text[start] !== '"') continue;
    // 转义引号（`\"`）不是起点。
    if (start > 0 && text[start - 1] === '\\') continue;
    const literal = jsonStringAt(text, start);
    if (literal.length === 0) continue;
    let decoded = '';
    try {
      decoded = JSON.parse(literal);
    } catch (error) {
      continue;
    }
    if (typeof decoded !== 'string' || decoded.indexOf('login_response') < 0) continue;
    try {
      const raw = JSON.parse(decoded);
      const loginResponse = JSON.parse(raw.login_response || '{}');
      const headers = JSON.parse(raw.headers || '{}');
      const cookieHeader = String(raw.cookies || '');
      const cookies = parseCookieHeader(cookieHeader);
      // 同时给一份 `cookie` 串：ArkTS 那份（CaaLoginPayload）就是这个字段名，
      // 两边同名同形，读代码/写测试时才不会拿错（这里踩过一次）。
      const cookie = Object.keys(cookies).map((name) => `${name}=${cookies[name]}`).join('; ');
      return { loginResponse, headers, cookies, cookie, cookieHeader, raw };
    } catch (error) {
      continue;
    }
  }
  return null;
}

/* ------------------------------------------------- 两步验证（ap.2sv 链） */

const AP_2SV_ENTRYPOINT = 'com.bloks.www.ap.two_step_verification.entrypoint_async';
const AP_2SV_CODE_ENTRY = 'com.bloks.www.ap.two_step_verification.code_entry';
const AP_2SV_CODE_ENTRY_ASYNC = 'com.bloks.www.ap.two_step_verification.code_entry_async';

/** 取一对平衡括号内的表达式（Bloks 的 lispy 字符串里会嵌套、且含引号）。 */
function bloksParenthesized(value, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < value.length; index++) {
    const ch = value[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      if (depth === 0) return value.slice(start, index + 1);
    }
  }
  return '';
}

/** 读表达式的直接操作数（不展开嵌套表达式）。 */
function bloksExpressionItems(value) {
  if (!value.startsWith('(') || !value.endsWith(')')) return [];
  const items = [];
  let index = 1;
  while (index < value.length - 1) {
    const ch = value[index];
    if (/\s/.test(ch)) {
      index++;
      continue;
    }
    let item = '';
    if (ch === '(') {
      item = bloksParenthesized(value, index);
      if (item.length === 0) return [];
    } else if (ch === '"') {
      let end = index + 1;
      let escaped = false;
      for (; end < value.length; end++) {
        if (escaped) {
          escaped = false;
          continue;
        }
        if (value[end] === '\\') {
          escaped = true;
          continue;
        }
        if (value[end] === '"') break;
      }
      item = value.slice(index, end + 1);
    } else {
      const match = /^[^()\s"]+/.exec(value.slice(index));
      if (match === null) return [];
      item = match[0];
    }
    items.push(item);
    index += item.length;
  }
  return items;
}

/**
 * 从 Bloks 布局里取出"绑定在某个 app id 上的 context_data"。
 *
 * 布局里有 lispy 字符串形如 `(f4i (dkc "key1" "key2" …) (dkc "v1" "v2" …))`：
 * 找到目标 app id 之后的第一处 `(f4i …)`，把键值对齐后取 `context_data`。
 * 这是两步验证链唯一的通行证，取不到就走不下去。
 */
function bloksExtractContextValue(data, appId, contextKey) {
  const strings = [];
  collectStrings(data, strings);
  const anchor = JSON.stringify(appId);
  for (const text of strings) {
    let from = 0;
    for (;;) {
      const found = text.indexOf(anchor, from);
      if (found < 0) break;
      from = found + anchor.length;
      const mapStart = text.indexOf('(f4i', found);
      if (mapStart < 0) continue;
      const tail = text.slice(found + anchor.length);
      const nextApp = /(^|[^_a-zA-Z0-9])com\.bloks\.[_a-zA-Z0-9.]+/.exec(tail);
      if (nextApp !== null && (found + anchor.length + nextApp.index) < mapStart) continue;
      let expression = bloksParenthesized(text, mapStart);
      while (expression.length > 0) {
        const items = bloksExpressionItems(expression);
        if (items.length !== 3 || items[0] !== 'f4i') break;
        const keys = bloksExpressionItems(items[1]);
        const values = bloksExpressionItems(items[2]);
        if (keys[0] !== 'dkc' || values[0] !== 'dkc' || keys.length !== values.length) break;
        expression = '';
        for (let index = 1; index < keys.length; index++) {
          const key = keys[index];
          const value = values[index];
          if (!key.startsWith('"')) continue;
          let name = '';
          try {
            name = JSON.parse(key);
          } catch (error) {
            continue;
          }
          if (name === contextKey) {
            if (!value.startsWith('"')) return '';
            try {
              return JSON.parse(value);
            } catch (error) {
              return '';
            }
          }
          if (name === 'server_params') expression = value;
        }
      }
    }
  }
  return '';
}

/** 所有字符串拼起来（判断"是否需要两步验证"）。 */
function bloksAllText(data) {
  const strings = [];
  collectStrings(data, strings);
  return strings.join('\n');
}

/** 是否走了两步验证（布局里出现 ap.two_step_verification.entrypoint）。 */
function bloksNeedsTwoStep(data) {
  return bloksAllText(data).indexOf(AP_2SV_ENTRYPOINT) >= 0;
}

/** 从失败响应里挑出给人看的错误文案（IG 把它放在 UI 文本里）。 */
function bloksErrorMessage(data) {
  const text = bloksAllText(data);
  const known = [
    "Can't find account",
    "We can't find",
    'password you entered',
    'incorrect',
    'too many',
    'wait a few minutes',
    'suspended',
    'checkpoint'
  ];
  for (const phrase of known) {
    const index = text.indexOf(phrase);
    if (index >= 0) {
      return text.slice(index, Math.min(index + 120, text.length)).replace(/\s+/g, ' ').trim();
    }
  }
  return '';
}

/**
 * 走完两步验证链：entrypoint → code_entry → 提交验证码。
 *
 * @param getCode 异步回调，返回用户输入的验证码
 */
async function resolveTwoStep(profile, sendData, getCode, log) {
  const entryContext = bloksExtractContextValue(sendData, AP_2SV_ENTRYPOINT, 'context_data');
  if (entryContext.length === 0) {
    return { loggedIn: false, reason: '两步验证：没取到 entrypoint 的 context_data' };
  }
  log('    两步验证 1/3：打开验证入口');
  const entry = await bloksAsyncAction(profile, AP_2SV_ENTRYPOINT, {
    client_input_params: {
      auth_secure_device_id: '',
      accounts_list: [],
      has_whatsapp_installed: 0,
      family_device_id: profile.phoneId,
      machine_id: profile.mid
    },
    server_params: {
      use_open_instead_of_push: 0,
      context_data: entryContext,
      INTERNAL__latency_qpl_marker_id: 36707139,
      INTERNAL__latency_qpl_instance_id: Date.now(),
      device_id: profile.uuid,
      use_close_instead_of_back: 0
    }
  });

  const codeContext = bloksExtractContextValue(entry.data, AP_2SV_CODE_ENTRY, 'context_data');
  if (codeContext.length === 0) {
    return { loggedIn: false, reason: '两步验证：没取到 code_entry 的 context_data' };
  }
  log('    两步验证 2/3：打开验证码输入页');
  const codeEntry = await bloksApp(profile, AP_2SV_CODE_ENTRY, {
    client_input_params: { aac: profile.caaAac || '' },
    server_params: {
      context_data: codeContext,
      show_close_button: 0,
      device_id: profile.uuid,
      INTERNAL_INFRA_screen_id: 'generic_code_entry',
      is_dismissable: 1
    }
  });

  const submitContext = bloksExtractContextValue(codeEntry.data, AP_2SV_CODE_ENTRY_ASYNC, 'context_data');
  if (submitContext.length === 0) {
    return { loggedIn: false, reason: '两步验证：没取到 code_entry_async 的 context_data' };
  }
  const code = String(await getCode()).trim();
  if (code.length === 0) {
    return { loggedIn: false, reason: '两步验证：没有输入验证码' };
  }
  log('    两步验证 3/3：提交验证码');
  const submit = await bloksAsyncAction(profile, AP_2SV_CODE_ENTRY_ASYNC, {
    client_input_params: {
      auth_secure_device_id: '',
      aac: profile.caaAac || '',
      code: code,
      family_device_id: profile.phoneId,
      device_id: profile.androidId,
      machine_id: profile.mid
    },
    server_params: {
      context_data: submitContext,
      INTERNAL__latency_qpl_marker_id: 36707139,
      INTERNAL__latency_qpl_instance_id: Date.now(),
      device_id: profile.uuid
    }
  });
  const parsed = extractLoginPayload(submit.data);
  if (parsed === null) {
    return {
      loggedIn: false,
      reason: '两步验证已提交，但响应里没找到登录结果：' + (bloksErrorMessage(submit.data) || '未知'),
      raw: submit.data
    };
  }
  return { loggedIn: true, parsed };
}

/* ---------------------------------------------------------------- 主流程 */

/**
 * 走一遍 CAA 登录。返回结构化结果（**不直接抛**，方便 CLI 打印现场）：
 *   { loggedIn, aac, cookies, authorization, twoStepContext, steps: [...] }
 */
async function caaLogin(profile, username, password, log, options) {
  const steps = [];
  const usdid = new Usdid(profile, path.join(DIR, 'usdid.json'));
  // 之后所有请求都带设备签名头
  profile.usdidHeader = usdid.header();

  // 1. USDID 注册（设备签名身份）
  if (!usdid.state.registered) {
    log('1/5 注册设备身份（USDID）…');
    const registration = await graphqlWww(profile,
      'IGUSDIDRegistrationMutation',
      { input: { usdid_token: { sensitive_string_value: usdid.registrationToken() }, fdid: { sensitive_string_value: profile.phoneId } } },
      USDID_REGISTRATION_CLIENT_DOC_ID,
      { 'X-Root-Field-Name': 'usdid_registration' });
    steps.push({ step: 'usdid', status: registration.status, data: registration.data });
    const data = registration.data || {};
    const keys = Object.keys(data.data || {});
    let ok = false;
    for (const key of keys) {
      if (key.indexOf('usdid_registration') >= 0 && data.data[key] && data.data[key].success) ok = true;
    }
    if (ok) {
      usdid.markRegistered();
      log('    设备身份已注册');
    } else {
      log('    ⚠️ USDID 注册没成功（IG 可能已注册过或返回变了），继续尝试');
    }
  } else {
    log('1/5 设备身份已注册过，复用 usdid.json');
  }

  // 2. attestation（拿 challenge_nonce；keystore 不可用是可接受状态）
  log('2/5 申请 attestation nonce…');
  const attestationBody = querystring.stringify({
    app_scoped_device_id: profile.uuid,
    key_hash: ''
  });
  const attestation = await request({
    hostname: 'i.instagram.com',
    path: '/api/v1/attestation/create_android_keystore/',
    method: 'POST',
    headers: headersFor(profile, Object.assign({
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Content-Length': Buffer.byteLength(attestationBody),
      'X-FB-Friendly-Name': 'IgApi: attestation/create_android_keystore/',
      'X-Meta-Usdid': usdid.header()
    })),
    timeout: 25000
  }, attestationBody);
  let attestationData = {};
  try {
    attestationData = JSON.parse(attestation.body);
  } catch (error) {
    attestationData = {};
  }
  const challengeNonce = String(attestationData.challenge_nonce || '');
  steps.push({ step: 'attestation', status: attestation.status, data: attestationData });
  if (challengeNonce.length === 0) {
    log('    ⚠️ 没拿到 challenge_nonce（后续请求可能被拒）');
  }
  const attestParams = challengeNonce.length === 0 ? '' : dumps({
    attestation: [{
      version: 2,
      type: 'keystore',
      errors: [-1013],
      challenge_nonce: challengeNonce,
      signed_nonce: '',
      key_hash: ''
    }]
  });

  // 3. 取 aac（CAA 的账号访问上下文）
  log('3/5 取 CAA 账号访问上下文（aac）…');
  const waterfallId = crypto.randomUUID();
  const processData = await bloksAsyncAction(profile,
    'com.bloks.www.bloks.caa.login.process_client_data_and_redirect', {
      is_from_logged_out: false,
      logged_out_user: '',
      qpl_join_id: null,
      family_device_id: profile.phoneId,
      device_id: profile.androidId,
      offline_experiment_group: 'caa_iteration_v3_perf_ig_4',
      waterfall_id: waterfallId,
      logout_source: '',
      show_internal_settings: false,
      last_auto_login_time: 0,
      disable_auto_login: false,
      qe_device_id: profile.uuid,
      use_auto_login_interstitial: true,
      disable_recursive_auto_login_interstitial: true,
      auto_login_interstitial_experiment_group_name: '',
      is_from_logged_in_switcher: false,
      switcher_logged_in_uid: '',
      account_list: [],
      blocked_uid: [],
      INTERNAL_INFRA_THEME: 'THREE_NEUTRAL_GRAY',
      layered_homepage_experiment_group: 'Deploy: Not in Experiment',
      launched_url: '',
      sim_phone_numbers: [],
      is_from_registration_reminder: false
    });
  const aac = extractAac(processData.data);
  steps.push({ step: 'process_client_data', status: processData.status, aac: aac.slice(0, 24) + (aac.length > 24 ? '…' : '') });
  if (aac.length === 0) {
    return { loggedIn: false, aac: '', cookies: {}, authorization: '', twoStepContext: '', steps,
      reason: '没拿到 aac（process_client_data 的响应形状可能变了）' };
  }
  log('    拿到 aac（长度 ' + aac.length + '）');
  if (options && options.preflightOnly === true) {
    return {
      loggedIn: false, aac, cookies: {}, authorization: '', twoStepContext: '',
      steps, reason: 'preflight only（1~3 步通过）'
    };
  }

  // 4. oauth token fetch（提交密码前的前置）
  log('4/5 oauth token 预取…');
  const oauth = await bloksAsyncAction(profile, 'com.bloks.www.caa.login.oauth.token.fetch.async', {
    client_input_params: {
      username_input: username,
      si_device_param_network_info: networkInfo(),
      aac: aac,
      lois_settings: { lois_token: '' },
      cloud_trust_token: null,
      zero_balance_state: '',
      network_bssid: null
    },
    server_params: {
      is_from_logged_out: 0,
      layered_homepage_experiment_group: 'Deploy: Not in Experiment',
      device_id: profile.androidId,
      login_surface: 'login_home',
      waterfall_id: waterfallId,
      INTERNAL__latency_qpl_instance_id: Date.now(),
      is_platform_login: 0,
      login_entry_point: 'logged_out',
      INTERNAL__latency_qpl_marker_id: 36707139,
      family_device_id: profile.phoneId,
      offline_experiment_group: 'caa_iteration_v3_perf_ig_4',
      access_flow_version: 'pre_mt_behavior',
      is_from_logged_in_switcher: 0,
      qe_device_id: profile.uuid
    }
  });
  steps.push({ step: 'oauth_token_fetch', status: oauth.status });

  // 5. 提交账号密码
  log('5/5 提交账号密码…');
  const encryptedPassword = await encryptPassword(profile, password);
  const textInputId = `${crypto.randomBytes(2).toString('hex')}ig`;
  const send = await bloksAsyncAction(profile,
    'com.bloks.www.bloks.caa.login.async.send_login_request', {
      client_input_params: {
        blocked_uids: [],
        aac: aac,
        sim_phones: [],
        aymh_accounts: [],
        network_bssid: null,
        secure_family_device_id: '',
        has_granted_read_contacts_permissions: 0,
        auth_secure_device_id: '',
        has_whatsapp_installed: 0,
        si_device_param_network_info: networkInfo(),
        password: encryptedPassword,
        sso_token_map_json_string: '',
        block_store_machine_id: '',
        ig_vetted_device_nonces: null,
        cloud_trust_token: null,
        event_flow: 'login_manual',
        password_contains_non_ascii: String(!/^[\x00-\x7F]*$/.test(password)),
        client_known_key_hash: '',
        sso_accounts_auth_data: [],
        encrypted_msisdn: '',
        has_granted_read_phone_permissions: 0,
        app_manager_id: '',
        should_show_nested_nta_from_aymh: 0,
        device_id: profile.androidId,
        zero_balance_state: '',
        login_attempt_count: 1,
        machine_id: profile.mid,
        flash_call_permission_status: {
          READ_PHONE_STATE: 'DENIED',
          READ_CALL_LOG: 'DENIED',
          ANSWER_PHONE_CALLS: 'DENIED'
        },
        accounts_list: [],
        gms_incoming_call_retriever_eligibility: 'eligible',
        family_device_id: profile.phoneId,
        fb_ig_device_id: [],
        device_emails: [],
        try_num: 1,
        lois_settings: { lois_token: '' },
        event_step: 'home_page',
        headers_infra_flow_id: '',
        openid_tokens: {},
        contact_point: username
      },
      server_params: {
        should_trigger_override_login_2fa_action: 0,
        is_from_logged_out: 0,
        should_trigger_override_login_success_action: 0,
        login_credential_type: 'none',
        server_login_source: 'login',
        waterfall_id: waterfallId,
        two_step_login_type: 'one_step_login',
        login_source: 'Login',
        is_platform_login: 0,
        login_entry_point: 'logged_out',
        INTERNAL__latency_qpl_marker_id: 36707139,
        is_from_aymh: 0,
        offline_experiment_group: 'caa_iteration_v3_perf_ig_4',
        is_from_landing_page: 0,
        left_nav_button_action: 'NONE',
        password_text_input_id: `${textInputId}:82`,
        is_from_empty_password: 0,
        is_from_msplit_fallback: 0,
        ar_event_source: 'login_home_page',
        qe_device_id: profile.uuid,
        username_text_input_id: `${textInputId}:81`,
        layered_homepage_experiment_group: 'Deploy: Not in Experiment',
        device_id: profile.androidId,
        login_surface: 'login_home',
        INTERNAL__latency_qpl_instance_id: Date.now(),
        reg_flow_source: 'login_home_native_integration_point',
        is_caa_perf_enabled: 1,
        credential_type: 'password',
        is_from_password_entry_page: 0,
        caller: 'gslr',
        family_device_id: profile.phoneId,
        is_from_assistive_id: 0,
        access_flow_version: 'pre_mt_behavior',
        is_from_logged_in_switcher: 0
      }
    }, attestParams.length > 0 ? { 'X-IG-Attest-Params': attestParams } : null);
  steps.push({ step: 'send_login_request', status: send.status });

  const parsed = extractLoginPayload(send.data);
  if (parsed !== null) {
    const authorization = String(parsed.headers['IG-Set-Authorization']
      || parsed.headers['ig-set-authorization'] || '');
    const sessionHeaders = sessionHeadersOf(parsed.headers);
    return {
      loggedIn: true,
      aac,
      cookies: parsed.cookies,
      authorization: authorization.replace(/^IG-Set-Authorization:\s*/i, ''),
      mid: sessionHeaders.mid,
      rur: sessionHeaders.rur,
      claim: sessionHeaders.claim,
      // 只给"名字"用于诊断（值里是会话材料，不能打到日志里）
      cookieNames: Object.keys(parsed.cookies),
      headerNames: Object.keys(parsed.headers),
      twoStepContext: '',
      steps
    };
  }

  /*
   * 登录结果没直接给。三种可能，按顺序判：
   *   1. 走了两步验证（布局里有 ap.two_step_verification.entrypoint）
   *      → 有 getCode 回调就把链走完，没有就把现场交回去；
   *   2. 账号密码错 / 账号不存在 → IG 把文案放在 UI 文本里（如 "Can't find account"）；
   *   3. 布局形状变了 → 返回原始响应供对齐。
   */
  profile.caaAac = aac;
  if (bloksNeedsTwoStep(send.data)) {
    if (typeof (options || {}).getCode === 'function') {
      const resolved = await resolveTwoStep(profile, send.data, options.getCode, log);
      if (resolved.loggedIn === true) {
        const headers = resolved.parsed.headers || {};
        const authorization = String(headers['IG-Set-Authorization'] || headers['ig-set-authorization'] || '');
        const sessionHeaders = sessionHeadersOf(headers);
        return {
          loggedIn: true,
          aac,
          cookies: resolved.parsed.cookies || {},
          authorization: authorization.replace(/^IG-Set-Authorization:\s*/i, ''),
          mid: sessionHeaders.mid,
          rur: sessionHeaders.rur,
          claim: sessionHeaders.claim,
          cookieNames: Object.keys(resolved.parsed.cookies || {}),
          headerNames: Object.keys(headers),
          twoStepContext: '',
          steps
        };
      }
      return {
        loggedIn: false, aac, cookies: {}, authorization: '', twoStepContext: '',
        steps, reason: resolved.reason, raw: resolved.raw
      };
    }
    return {
      loggedIn: false, aac, cookies: {}, authorization: '', twoStepContext: '',
      steps, reason: '需要两步验证：重新运行并允许输入验证码（--caa-login 会提示）', raw: send.data
    };
  }

  const errorText = bloksErrorMessage(send.data);
  return {
    loggedIn: false,
    aac,
    cookies: {},
    authorization: '',
    twoStepContext: extractTwoStepContext(send.data),
    steps,
    reason: errorText.length > 0
      ? '登录失败：' + errorText
      : '响应里没找到登录结果（布局形状可能变了，见 LOGIN.md）',
    raw: send.data
  };
}

/** 设备网络信息（CAA 请求体要求的一段固定结构）。 */
function networkInfo() {
  return {
    active_subscriptions_info: null,
    default_subscription_info: {
      network_type: null,
      is_data_roaming: 1,
      is_esim: null,
      is_gsm_roaming: 0,
      is_sim_sms_capable: null,
      is_mobile_data_enabled: 1,
      sim_carrier_id: 1,
      sim_carrier_id_name: null,
      sim_state: 5,
      sim_operator: '310260',
      sim_operator_name: 'T-Mobile',
      signal_strength: null,
      group_id_level_1: null,
      network_operator: '310260'
    },
    is_airplane_mode: 0,
    is_active_network_cellular: 0,
    is_device_sms_capable: 1,
    sim_count: 1,
    is_wifi: 1
  };
}

module.exports = {
  caaLogin,
  loadDeviceProfile,
  encryptPassword,
  passwordKeyOf,
  // 纯函数部分（导出给 test-caa-parse.js 做离线自检：成功响应的解析路径只有真账号才会
  // 走到，测试用合成布局把这条路先验一遍）
  encryptPasswordWithKey,
  publicKeyPemOf,
  Usdid,
  extractAac,
  extractTwoStepContext,
  extractLoginPayload,
  parseCookieHeader,
  sessionHeadersOf,
  bloksExtractContextValue,
  bloksNeedsTwoStep,
  bloksErrorMessage
};
