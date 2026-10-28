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
/**
 * 私有 API 的默认域名（instagrapi 的 `API_DOMAIN`）。
 *
 * **新版 2FA 的那几个 Bloks app 在这个域名上**，而 CAA 登录的 app 在 `b.i.instagram.com`
 * —— 打错域名会回 404 + "Payload returned is null"（R12 真机实测）。
 */
const PRIVATE_API_DOMAIN = 'i.instagram.com';
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
 * `POST https://{host}/api/v1/bloks/async_action/{action}/`
 *
 * `host` 默认 **b.i.instagram.com**（CAA 专用）。但**新版 2FA** 那几个 app 必须走
 * `i.instagram.com`（instagrapi 的 `bloks_two_step_verification_*` 不传 domain，
 * 走的就是默认的私有 API 域名）—— 打错域名时 IG 回 404 +
 * `{"message":"Payload returned is null...field_exception..."}`，看起来像"形状变了"，
 * 实际上只是 app 不在那个域名上。
 */
async function bloksAsyncAction(profile, action, params, extraHeaders, host) {
  const target = host || CAA_API_DOMAIN;
  const body = bloksPayload(profile, params);
  const headers = headersFor(profile, Object.assign({
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'Content-Length': Buffer.byteLength(body),
    'X-FB-Friendly-Name': `IgApi: bloks/async_action/${action}/`
  }, extraHeaders || {}));
  const res = await request({
    hostname: target,
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
  return { status: res.status, headers: res.headers, data, host: target };
}

/** `POST https://{host}/api/v1/bloks/apps/{app}/`（两步验证用；host 语义同上）。 */
async function bloksApp(profile, app, params, host) {
  const target = host || CAA_API_DOMAIN;
  const body = bloksPayload(profile, params);
  const headers = headersFor(profile, {
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'Content-Length': Buffer.byteLength(body)
  });
  const res = await request({
    hostname: target,
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
  return { status: res.status, headers: res.headers, data, host: target };
}

/**
 * 这个响应是不是"app 不在这个域名上"（Bloks VM 的空载荷失败）。
 *
 * 判据取自 IG 的真实响应：HTTP 404 且 body 里是
 * `Payload returned is null. A server error field_exception occured.`（R12 真机实测）。
 */
function isNullPayloadReply(reply) {
  const body = JSON.stringify((reply || {}).data || {});
  return body.indexOf('Payload returned is null') >= 0
    || (body.toLowerCase().indexOf('field_exception') >= 0 && body.indexOf('null') >= 0);
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
 * 解析 Bloks 给的 Cookie 串（对齐 instagrapi 用的 Python `SimpleCookie`）。
 *
 * 真实形状（R12 真机实测，`\r\n` 分隔、每颗后面跟一串属性）：
 *   `Set-Cookie: csrftoken=…; Domain=.instagram.com; expires=02-Dec-2027 13:57:44 GMT;
 *    Max-Age=…; Path=/; Secure\r\nSet-Cookie: ds_user_id=…; …\r\n
 *    Set-Cookie: sessionid=…; …; HttpOnly; …`
 *
 * 所以切分符要包含**换行**：早先只按 `;` 与 `,` 切，`Secure\r\nSet-Cookie: ds_user_id`
 * 会被当成一颗叫这名儿的 Cookie（于是 sessionid 明明在、却解析不出来）。
 * 另外属性值里可能带空格（`expires=02-Dec-2027 13:57:44 GMT`），名字必须做合法性过滤。
 */
function parseCookieHeader(text) {
  const out = {};
  const raw = String(text || '').replace(/Set-Cookie:\s*/gi, '');
  const NAME_OK = /^[A-Za-z0-9_\-%]+$/;
  for (const part of raw.split(/[;,\r\n]+/)) {
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
    if (!NAME_OK.test(name)) {
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
 * 从**一段文本**里抠登录结果（cookie + authorization）。
 *
 * 做法：**正向**遍历这段文本里的每一个字符串字面量，逐个试解。
 *
 * 为什么不能"从 `login_response` 第一次出现的地方往回找"（以前的写法）：真机响应里
 * 第一次出现的地方是一句日志文本 `"[trait:called_handle_login_response] Calling
 * HandleLoginResponse"` —— 它**包含** `login_response` 这几个字，于是往回找的扫描
 * 永远只在它前面转，而真正的载荷在它**后面**，所以一直解析不出来。
 * （R12 真机：2FA 全 200、登录其实成功，却报"没找到登录结果"，就是这个原因。）
 */
function loginPayloadFromText(text) {
  const source = String(text || '');
  if (source.indexOf('login_response') < 0 && source.indexOf('ig-set-authorization') < 0) {
    return null;
  }
  /*
   * **优先"带 cookie 的那一份"**。
   *
   * 为什么：同一份响应里可能有好几个带 `login_response`/`headers` 的对象（布局规范、
   * 中间态、真正的结果各有一份）。以前"第一个能解析的就返回"，于是可能拿到一个
   * `headers` 有值、`cookies` 是空的中间对象 —— 表现是"解析出登录结果，但没有 sessionid"。
   * 现在先把第一个候选留住当兜底，一旦遇到真正带 cookie 的就换掉。
   */
  let fallback = null;
  for (let index = 0; index < source.length; index++) {
    if (source[index] !== '"') continue;
    // 转义引号（`\"`）不是字符串起点。
    if (index > 0 && source[index - 1] === '\\') continue;
    const literal = jsonStringAt(source, index);
    if (literal.length === 0) continue;
    index += literal.length - 1;
    let decoded = '';
    try {
      decoded = JSON.parse(literal);
    } catch (error) {
      continue;
    }
    if (typeof decoded !== 'string' || decoded.indexOf('login_response') < 0) continue;
    try {
      const raw = JSON.parse(decoded);
      if (raw === null || typeof raw !== 'object') continue;
      // 必须是"登录结果那种对象"（有 login_response / cookies / headers 之一）
      if (!('login_response' in raw) && !('cookies' in raw) && !('headers' in raw)) continue;
      const loginResponse = JSON.parse(raw.login_response || '{}');
      const headers = JSON.parse(raw.headers || '{}');
      const cookieHeader = String(raw.cookies || '');
      const cookies = parseCookieHeader(cookieHeader);
      // 同时给一份 `cookie` 串：ArkTS 那份（CaaLoginPayload）就是这个字段名，
      // 两边同名同形，读代码/写测试时才不会拿错（这里踩过一次）。
      const cookie = Object.keys(cookies).map((name) => `${name}=${cookies[name]}`).join('; ');
      const found = { loginResponse, headers, cookies, cookie, cookieHeader, raw };
      if (Object.keys(cookies).length > 0) {
        return found;
      }
      if (fallback === null) {
        fallback = found;
      }
    } catch (error) {
      // 换下一个字面量
    }
  }
  return fallback;
}

/** 从 `layout.bloks_payload.action` 里抠（老位置）。 */
function extractLoginPayload(data) {
  const action = ((data || {}).layout || {}).bloks_payload;
  if (!action || typeof action.action !== 'string') return null;
  return loginPayloadFromText(action.action);
}

/**
 * **按结构**找登录结果：整棵树里那个带 `login_response`（以及 `headers` / `cookies`）的对象。
 *
 * 真机响应（R12）里 `embedded_payloads[].payload` 是**对象**，登录结果可能就平铺在里面，
 * 不再是"藏在某个字符串里的 JSON 文本"。所以除了抠文本，还要认这种结构。
 */
function findLoginObjectDeep(value, depth = 0) {
  if (depth > 12 || value === null || value === undefined) {
    return null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const hit = findLoginObjectDeep(item, depth + 1);
      if (hit !== null) return hit;
    }
    return null;
  }
  if (typeof value === 'object') {
    const record = value;
    if (typeof record.login_response === 'string'
      || typeof record.headers === 'string' || typeof record.cookies === 'string') {
      const parsed = loginPayloadFromObject(record);
      if (parsed !== null) return parsed;
    }
    for (const child of Object.values(record)) {
      const hit = findLoginObjectDeep(child, depth + 1);
      if (hit !== null) return hit;
    }
    return null;
  }
  if (typeof value === 'string' && value.length < 400000 && value.indexOf('login_response') >= 0) {
    try {
      return findLoginObjectDeep(JSON.parse(value), depth + 1);
    } catch (error) {
      return null;
    }
  }
  return null;
}

/** 把一个已是对象的 `{login_response, headers, cookies}` 解析成登录结果。 */
function loginPayloadFromObject(raw) {
  try {
    const loginResponse = typeof raw.login_response === 'string'
      ? JSON.parse(raw.login_response) : (raw.login_response || {});
    const headers = typeof raw.headers === 'string' ? JSON.parse(raw.headers) : (raw.headers || {});
    const cookieHeader = typeof raw.cookies === 'string'
      ? raw.cookies : Object.keys(raw.cookies || {}).map((name) => `${name}=${raw.cookies[name]}`).join('; ');
    const cookies = parseCookieHeader(cookieHeader);
    if (Object.keys(headers).length === 0 && Object.keys(cookies).length === 0) {
      return null;
    }
    const cookie = Object.keys(cookies).map((name) => `${name}=${cookies[name]}`).join('; ');
    return { loginResponse, headers, cookies, cookie, cookieHeader, raw };
  } catch (error) {
    return null;
  }
}

/**
 * **在整棵响应里找**登录结果（老位置 → 字符串里 → 结构里，三级）。
 *
 * 为什么需要：IG 现在会把结果塞进 `embedded_payloads` / `initial_lispy` 里（真机那次
 * `CAA_LOGIN_FALLBACK:fallback_triggered` 就是这种形状）。只看 `bloks_payload.action`
 * 会把"其实已经登录成功"判成"没找到登录结果"。
 */
function extractLoginPayloadDeep(data) {
  const direct = extractLoginPayload(data);
  if (direct !== null) {
    return direct;
  }
  const strings = [];
  collectStrings(data, strings);
  for (const text of strings) {
    if (text.indexOf('login_response') < 0) continue;
    const parsed = loginPayloadFromText(text);
    if (parsed !== null) {
      return parsed;
    }
  }
  return findLoginObjectDeep(data);
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
 * 在整棵 JSON 里递归找一个键（对齐 instagrapi 的 `_find_login_response_value`）。
 *
 * 为什么需要：Bloks 的响应会把东西藏进 `embedded_payloads`、`initial_lispy` 里的 JSON 串，
 * 甚至再嵌一层。只按 `layout.bloks_payload.action` 找会漏 —— 真机那次
 * `two_step_verification_context` 就是这么出来的。
 */
function findValueDeep(value, key, depth = 0) {
  if (depth > 12 || value === null || value === undefined) {
    return undefined;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const hit = findValueDeep(item, key, depth + 1);
      if (hit !== undefined) return hit;
    }
    return undefined;
  }
  if (typeof value === 'object') {
    const own = value[key];
    if (own !== undefined && own !== null && own !== '') return own;
    for (const child of Object.values(value)) {
      const hit = findValueDeep(child, key, depth + 1);
      if (hit !== undefined) return hit;
    }
    return undefined;
  }
  if (typeof value === 'string' && value.indexOf('"') >= 0 && value.length < 400000) {
    // 有些字段是**再嵌一层**的 JSON 文本
    if (value.indexOf(key) < 0) return undefined;
    try {
      return findValueDeep(JSON.parse(value), key, depth + 1);
    } catch (error) {
      return undefined;
    }
  }
  return undefined;
}

/** 把 `(f4i (dkc "k1" "k2" …) (dkc "v1" "v2" …))` 解成 `{k1: v1, k2: v2}`（值必须是字面量）。 */
function lispyPairMap(expr) {
  const out = {};
  for (const entry of lispyMapEntries(expr)) {
    if (entry.value.startsWith('"')) {
      try {
        out[entry.key] = JSON.parse(entry.value);
      } catch (error) {
        out[entry.key] = '';
      }
    } else {
      out[entry.key] = entry.value;
    }
  }
  return out;
}

/**
 * 解 `(f4i (dkc "k1" "k2" …) (dkc v1 v2 …))` → `[{key, value}]`。
 *
 * `value` 可能是**字面量**（以 `"` 开头）也可能是**嵌套表达式**（以 `(` 开头）——
 * 2FA 的调用规范里就是这样：`server_params` 的值本身又是一个 `(f4i (dkc …) (dkc …))`。
 */
function lispyMapEntries(expr) {
  const items = bloksExpressionItems(expr);
  if (items.length !== 3 || items[0] !== 'f4i') return [];
  const keys = bloksExpressionItems(items[1]);
  const values = bloksExpressionItems(items[2]);
  if (keys[0] !== 'dkc' || values[0] !== 'dkc' || keys.length !== values.length) return [];
  const out = [];
  for (let index = 1; index < keys.length; index++) {
    const key = keys[index];
    if (!key.startsWith('"')) continue;
    let name = '';
    try {
      name = JSON.parse(key);
    } catch (error) {
      continue;
    }
    out.push({ key: name, value: values[index] });
  }
  return out;
}

/**
 * 从一个 `(fma …)` 表达式里取出 `{ serverParams, clientParams }`。
 *
 * 真实形状（R12 真机）：`(fma (f4i (dkc "server_params" "client_input_params")
 *                                  (dkc <serverExpr> <clientExpr>)))`
 * 也兼容 `(fma <serverExpr> <clientExpr>)` 这种两参数变体。
 */
function paramsFromFma(fmaExpr) {
  const items = bloksExpressionItems(fmaExpr);
  if (items.length < 2 || items[0] !== 'fma') {
    return { serverParams: {}, clientParams: {} };
  }
  if (items.length >= 3) {
    return { serverParams: lispyPairMap(items[1]), clientParams: lispyPairMap(items[2]) };
  }
  const entries = lispyMapEntries(items[1]);
  let serverParams = {};
  let clientParams = {};
  for (const entry of entries) {
    if (entry.key === 'server_params') {
      serverParams = lispyPairMap(entry.value);
    } else if (entry.key === 'client_input_params') {
      clientParams = lispyPairMap(entry.value);
    }
  }
  return { serverParams, clientParams };
}

/**
 * **从响应里读出"下一步该调哪个 app、带什么参数"**（Bloks 布局里的调用规范）。
 *
 * 真机实测（R12 第三次）：响应的 lispy 里明写着
 *   `35 "com.bloks.www.two_step_verification.entrypoint" … (f6m 6 "params" (fma
 *     (f4i (dkc "server_params" "client_input_params")
 *          (dkc (f4i (dkc "two_step_verification_context" "flow_source" …)
 *                    (dkc "AWR7ihSM…（700+ 字符）" …)) …)))`
 * 也就是说：**IG 直接把该调什么、该带什么值告诉客户端了**。我们之前从别处硬抓一个
 * 13 字符的"票据"去调，IG 当然回空载荷 —— 这是本次失败的真正原因。
 *
 * @returns `Array<{ appId, serverParams, clientParams }>`
 */
function nextCallSpecs(data) {
  const strings = [];
  collectStrings(data, strings);
  const out = [];
  for (const text of strings) {
    let from = 0;
    for (;;) {
      const paramsAt = text.indexOf('"params"', from);
      if (paramsAt < 0) break;
      const fmaAt = text.indexOf('(fma', paramsAt);
      if (fmaAt < 0) break;
      const expr = bloksParenthesized(text, fmaAt);
      if (expr.length === 0) break;
      // app id：在 params 之前找最近的一个 `35 "com.bloks.…"`
      const head = text.slice(0, paramsAt);
      const re = /35\s+"(com\.bloks\.[A-Za-z0-9_.]+)"/g;
      let appId = '';
      let match = re.exec(head);
      while (match !== null) {
        appId = match[1];
        match = re.exec(head);
      }
      const parsed = paramsFromFma(expr);
      out.push({ appId, serverParams: parsed.serverParams, clientParams: parsed.clientParams });
      from = fmaAt + expr.length;
    }
  }
  return out;
}

/** 从规范列表里挑出 app id 命中关键词的第一个。 */
function pickCallSpec(specs, keywords) {
  for (const spec of specs) {
    const lower = String(spec.appId || '').toLowerCase();
    if (keywords.some((word) => lower.indexOf(word) >= 0)) {
      return spec;
    }
  }
  return null;
}

/** 规范里的票据（真实值有几百字符；取不到才回退旧逻辑）。 */
function twoStepContextOf(data) {
  const specs = nextCallSpecs(data);
  for (const spec of specs) {
    const value = spec.serverParams['two_step_verification_context'];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
  }
  const deep = findValueDeep(data, 'two_step_verification_context');
  if (typeof deep === 'string' && deep.trim().length > 0) {
    return deep.trim();
  }
  return extractTwoStepContext(data);
}

/** 有没有走到"新版 2FA（context 链）"或"旧版（ap.* 链）"。 */
function bloksFallbackMarkers(data) {
  const text = bloksAllText(data);
  const out = [];
  const re = /CAA_LOGIN_FALLBACK:[a-zA-Z0-9_]+/g;
  let match = re.exec(text);
  while (match !== null) {
    out.push(match[0]);
    match = re.exec(text);
  }
  return out;
}

/* ---------------------------------------- 新版 2FA（two_step_verification_context） */

const TSV_ENTRYPOINT = 'com.bloks.www.two_step_verification.entrypoint';
const TSV_METHOD_PICKER = 'com.bloks.www.two_step_verification.method_picker';
const TSV_SELECT_METHOD = 'com.bloks.www.two_step_verification.method_picker.navigation.async';
const TSV_ENTER_BACKUP = 'com.bloks.www.two_factor_login.enter_backup_code';
const TSV_VERIFY = 'com.bloks.www.two_step_verification.verify_code.async';
const TSV_FLOW_SOURCE = 'two_factor_login';

/** 登录响应里那些"开了哪种 2FA"的布尔（instagrapi 的 `_login_response_bool`）。 */
function loginResponseBool(data, key) {
  const value = findValueDeep(data, key);
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  if (typeof value === 'string') {
    const lower = value.trim().toLowerCase();
    return lower === '1' || lower === 'true' || lower === 'yes';
  }
  return false;
}

/**
 * 推断这次的 2FA 方式（对齐 instagrapi `_infer_bloks_two_factor_challenge`）：
 *   · 8 位数字 ⇒ 备用码（backup_codes）；
 *   · 只开了短信、没开 TOTP ⇒ sms；
 *   · 其余 ⇒ totp（验证器 App）。
 */
function inferChallenge(data, code) {
  const normalized = String(code).replace(/[\s-]+/g, '');
  if (/^\d{8}$/.test(normalized)) {
    return 'backup_codes';
  }
  const sms = loginResponseBool(data, 'sms_two_factor_on');
  const totp = loginResponseBool(data, 'totp_two_factor_on');
  if (sms && !totp) {
    return 'sms';
  }
  return 'totp';
}

/**
 * **从响应里收集候选 Bloks app id**（按关键词过滤）。
 *
 * 为什么不写死：新版 2FA 的 app id 可能随 IG 客户端改版而变，而**响应本身**通常就带着
 * 下一步该调哪个 app（布局里会出现 `com.bloks.www.two_step_verification.…` 这样的字符串）。
 * 与其猜，不如把候选抓出来逐个试。
 */
function bloksCandidateApps(data, keywords) {
  const text = bloksAllText(data);
  const re = /com\.bloks\.[A-Za-z0-9_.]+/g;
  const seen = new Set();
  const out = [];
  let match = re.exec(text);
  while (match !== null) {
    const id = match[0];
    if (seen.has(id)) {
      match = re.exec(text);
      continue;
    }
    seen.add(id);
    const lower = id.toLowerCase();
    if (keywords.some((word) => lower.indexOf(word) >= 0)) {
      out.push(id);
    }
    match = re.exec(text);
  }
  return out;
}

/** 把规范里以字符串给出的布尔/数字字段还原成合适类型（`"false"` → `false`）。 */
function normalizeFlags(params) {
  const out = Object.assign({}, params);
  for (const key of Object.keys(out)) {
    const value = out[key];
    if (typeof value !== 'string') continue;
    const lower = value.trim().toLowerCase();
    if (lower === 'true') {
      out[key] = true;
    } else if (lower === 'false') {
      out[key] = false;
    } else if (/^-?\d+$/.test(lower)) {
      out[key] = Number(lower);
    }
  }
  return out;
}

/** 在多个 app id / 多个域名里找一个"能回载荷"的组合。 */
async function firstLiveAppCall(profile, appIds, params, log, label) {
  const hosts = [PRIVATE_API_DOMAIN, CAA_API_DOMAIN];
  for (const appId of appIds) {
    for (const host of hosts) {
      const reply = await bloksApp(profile, appId, params, host);
      const dead = isNullPayloadReply(reply);
      log('      ' + label + ' @' + host + ' ' + appId.split('.').slice(-1)[0]
        + ' → HTTP ' + reply.status + (dead ? '（空载荷）' : '（有载荷）'));
      if (!dead) {
        return { appId, host, reply };
      }
    }
  }
  return null;
}

/** 同上，但打 `bloks/async_action/` 端点（选方法、提交验证码走它）。 */
async function firstLiveAsyncAction(profile, actionIds, params, log, label) {
  const hosts = [PRIVATE_API_DOMAIN, CAA_API_DOMAIN];
  for (const actionId of actionIds) {
    for (const host of hosts) {
      const reply = await bloksAsyncAction(profile, actionId, params, null, host);
      const dead = isNullPayloadReply(reply);
      log('      ' + label + ' @' + host + ' ' + actionId.split('.').slice(-1)[0]
        + ' → HTTP ' + reply.status + (dead ? '（空载荷）' : '（有载荷）'));
      if (!dead) {
        return { appId: actionId, host, reply };
      }
    }
  }
  return null;
}

/**
 * **新版 2FA 链**（入口拿到 `two_step_verification_context` 时走它）：
 * entrypoint → method_picker → select_method →（备用码才走 enter_backup_code）→ verify_code。
 *
 * 每一跳的 app id **优先从上一跳的响应里抓**（`bloksCandidateApps`），抓不到才退回
 * instagrapi 的常量；域名也每次在 `i.instagram.com` / `b.i.instagram.com` 之间试。
 * 之所以这么"啰嗦"：R12 真机实测时四个写死的 app id 全回 404 空载荷 —— 说明写死的常量
 * 对当前 IG 版本已经不对了，与其继续猜，不如让响应告诉我们。
 */
async function resolveTwoStepByContext(profile, context, sendData, getCode, log, steps) {
  /*
   * **按 IG 给的规范调用**（这是本轮的关键修正）。
   *
   * 登录响应的 lispy 里带着下一步的调用规范：app id + server_params/client_input_params
   * 的**键与值**（含 700+ 字符的真实 two_step_verification_context）。以前我们从别处硬抓
   * 一个 13 字符的值去调，IG 回 "Payload returned is null" —— 那不是"app id 不对"，
   * 是**票据抓错了**（真票据 2234 字符）。
   */
  const sendSpecs = nextCallSpecs(sendData);
  const entrySpec = pickCallSpec(sendSpecs, ['two_step', 'two_factor']);
  const entryIds = entrySpec !== null && entrySpec.appId.length > 0 ? [entrySpec.appId]
    : [TSV_ENTRYPOINT];
  log('    两步验证 1/4：entrypoint（规范里读到 ' + sendSpecs.length + ' 条，将试 '
    + entryIds.length + ' 个 app）');
  for (const id of entryIds) {
    log('      候选：' + id);
  }
  const entryParams = {
    client_input_params: Object.assign({
      device_id: profile.androidId,
      is_whatsapp_installed: 0,
      machine_id: profile.mid
    }, entrySpec === null ? {} : entrySpec.clientParams),
    server_params: Object.assign({
      should_fallback_to_sms: 0,
      family_device_id: profile.phoneId,
      device_id: profile.androidId,
      two_step_verification_context: context,
      flow_source: TSV_FLOW_SOURCE
    }, entrySpec === null ? {} : entrySpec.serverParams)
  };
  // 规范里的值是**字符串字面量**（"false"），但字段本身是布尔/数字 —— 还原成合适类型
  entryParams.server_params = normalizeFlags(entryParams.server_params);
  log('      票据长度 ' + String(entryParams.server_params['two_step_verification_context']).length
    + '，server_params 键：' + Object.keys(entryParams.server_params).join(','));
  const entry = await firstLiveAppCall(profile, entryIds, entryParams, log, 'entrypoint');
  steps.push({ step: '2sv_entrypoint', status: entry === null ? 404 : entry.reply.status });
  if (entry === null) {
    return {
      loggedIn: false, steps,
      reason: '两步验证：entrypoint 拿不到载荷（票据或 app id 不对）'
    };
  }

  // 2) method_picker：优先用 entrypoint 响应里的规范
  const entrySpecs = nextCallSpecs(entry.reply.data);
  const pickerSpec = pickCallSpec(entrySpecs, ['method_picker']);
  const pickerIds = pickerSpec !== null && pickerSpec.appId.length > 0
    ? [pickerSpec.appId] : [TSV_METHOD_PICKER];
  log('    两步验证 2/4：method_picker（规范里读到 ' + entrySpecs.length + ' 条，将试 '
    + pickerIds.length + ' 个 app）');
  const picker = await firstLiveAppCall(profile, pickerIds, {
    client_input_params: Object.assign({ is_whatsapp_installed: 0 },
      pickerSpec === null ? {} : pickerSpec.clientParams),
    server_params: normalizeFlags(Object.assign({
      should_fallback_to_sms: 0,
      device_id: profile.androidId,
      two_step_verification_context: context,
      flow_source: TSV_FLOW_SOURCE
    }, pickerSpec === null ? {} : pickerSpec.serverParams))
  }, log, 'method_picker');
  steps.push({ step: '2sv_method_picker', status: picker === null ? 404 : picker.reply.status });

  /*
   * **到这里才问验证码**。
   *
   * 为什么不能更早问：TOTP 六位码的有效窗口通常只有 30 秒，而上面那两步是"探测"——
   * 候选 app id × 两个域名，可能要打好几次请求。先探测、后要码，才不会让用户手忙脚乱地
   * 输一个已经过期的码（R12 真机那次就是这个顺序，输完码才开始探测）。
   */
  const code = String(await getCode()).trim();
  if (code.length === 0) {
    return { loggedIn: false, reason: '两步验证：没有输入验证码', steps };
  }
  const challenge = inferChallenge(sendData, code);
  const normalized = String(code).replace(/[\s-]+/g, '');

  // 3) select_method（async action）
  const selectCandidates = picker === null ? []
    : bloksCandidateApps(picker.reply.data, ['navigation', 'select_method', 'method_picker']);
  const selectIds = selectCandidates.length > 0 ? selectCandidates : [TSV_SELECT_METHOD];
  log('    两步验证 3/4：select_method（' + challenge + '，候选 ' + selectIds.length + ' 个）');
  const selectParams = {
    client_input_params: {
      selected_method: challenge,
      cloud_trust_token: null,
      network_bssid: null
    },
    server_params: {
      should_fallback_to_sms: 0,
      device_id: profile.androidId,
      spectra_reg_login_data: null,
      two_step_verification_context: context,
      flow_source: TSV_FLOW_SOURCE
    }
  };
  const selected = await firstLiveAsyncAction(profile, selectIds, selectParams, log, 'select_method');
  steps.push({ step: '2sv_select_method', status: selected === null ? 404 : selected.reply.status });

  // 3.5) 备用码：多打一次输入页
  if (challenge === 'backup_codes') {
    const backupCandidates = selected === null ? []
      : bloksCandidateApps(selected.reply.data, ['backup']);
    const backupIds = backupCandidates.length > 0 ? backupCandidates : [TSV_ENTER_BACKUP];
    log('    两步验证 3.5/4：备用码输入页（候选 ' + backupIds.length + ' 个）');
    const backup = await firstLiveAppCall(profile, backupIds, {
      server_params: {
        device_id: profile.androidId,
        two_step_verification_context: context,
        flow_source: TSV_FLOW_SOURCE
      }
    }, log, 'enter_backup_code');
    steps.push({ step: '2sv_enter_backup_code', status: backup === null ? 404 : backup.reply.status });
  }

  // 4) 提交验证码（async action）
  const verifyCandidates = selected === null ? []
    : bloksCandidateApps(selected.reply.data, ['verify_code', 'verify']);
  const verifyIds = verifyCandidates.length > 0 ? verifyCandidates : [TSV_VERIFY];
  log('    两步验证 4/4：提交验证码（候选 ' + verifyIds.length + ' 个）');
  const submitParams = {
    client_input_params: {
      auth_secure_device_id: '',
      block_store_machine_id: '',
      code: challenge === 'backup_codes' ? normalized : code,
      should_trust_device: 1,
      family_device_id: profile.phoneId,
      device_id: profile.androidId,
      cloud_trust_token: null,
      network_bssid: null,
      machine_id: profile.mid
    },
    server_params: {
      should_fallback_to_sms: 0,
      device_id: profile.androidId,
      spectra_reg_login_data: null,
      challenge: challenge,
      two_step_verification_context: context,
      flow_source: TSV_FLOW_SOURCE
    }
  };
  const submit = await firstLiveAsyncAction(profile, verifyIds, submitParams, log, 'verify_code');
  steps.push({ step: '2sv_verify_code', status: submit === null ? 404 : submit.reply.status });
  if (submit === null) {
    return {
      loggedIn: false, steps,
      reason: '两步验证：所有 verify_code 候选都拿不到载荷（验证码没提交成功）'
    };
  }
  const parsed = extractLoginPayloadDeep(submit.reply.data);
  if (parsed === null) {
    const error = bloksErrorMessage(submit.reply.data);
    return {
      loggedIn: false,
      steps,
      raw: submit.reply.data,
      reason: '两步验证已提交（' + submit.reply.status + '），但响应里没找到登录结果：'
        + (error.length > 0 ? error : '形状可能变了')
    };
  }
  return { loggedIn: true, parsed, steps };
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
  /*
   * **429 = IG 限流**（今天的登录尝试太多）。必须单独认出来：否则会被当成"布局变了"，
   * 用户继续重跑只会把限流窗口推得更远。
   */
  if (send.status === 429) {
    return {
      loggedIn: false, aac, cookies: {}, authorization: '', twoStepContext: '',
      steps, raw: send.data, rateLimited: true,
      reason: 'IG 限流（429）：登录尝试太多了，等 10~30 分钟再试（期间别再跑）'
    };
  }

  const parsed = extractLoginPayload(send.data);
  /*
   * **"解析出载荷"不等于"登录成功"**。
   *
   * 真机踩到的形状：`headers` 有值（`IG-Set-Authorization`、`ig-set-ig-u-ds-user-id` 等都在），
   * 但 `cookies` 是空的 —— 那多半是**中间态**（IG 让客户端带着新下发的密码密钥重投一次），
   * 或者响应里还带着 `two_step_verification_context`（那才是该接着走的链）。
   * 所以：**没有 cookie 就先看有没有 2FA 票据**，有票据就往下走 2FA，别急着宣布"登录成功"。
   */
  const parsedCookies = parsed === null ? {} : parsed.cookies;
  const parsedHasCookies = Object.keys(parsedCookies).length > 0;
  const pendingTwoStep = parsed !== null && !parsedHasCookies ? twoStepContextOf(send.data) : '';
  if (parsed !== null && (parsedHasCookies || pendingTwoStep.length === 0)) {
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
      loginStatus: String((parsed.loginResponse || {}).status || ''),
      loginMessage: String((parsed.loginResponse || {}).message || ''),
      // 原始响应带回上层：会话不全时要能落盘，离线对齐（不必再登录一次）
      raw: send.data,
      twoStepContext: '',
      steps
    };
  }

  /*
   * 登录结果没直接给。按顺序判：
   *   1. **新版 2FA**：响应里带 `two_step_verification_context`（TOTP/SMS/备用码那一套）
   *      → 有 getCode 就把 context 链走完，没有就把票据交回去；
   *   2. **老版 2FA**：布局里有 `ap.two_step_verification.entrypoint_async`（profile-code 那套）；
   *   3. 账号密码错 / 账号不存在 → IG 把文案放在 UI 文本里（如 "Can't find account"）；
   *   4. 布局形状变了 → 返回原始响应供对齐。
   *
   * 注意顺序：真机上 IG 对同一个账号可能用①也可能用②，两套都必须能走。
   * 另外 `CAA_LOGIN_FALLBACK:*` 表示 IG 把这次登录**退回旧的 accounts 流程**了，
   * 看到它要说明白（旧接口我们现在拿不到会话，只能提示）。
   */
  profile.caaAac = aac;
  const twoStepContext = twoStepContextOf(send.data);
  if (twoStepContext.length > 0) {
    log('    要两步验证（context 链，票据 ' + twoStepContext.length + ' 字符）');
    if (typeof (options || {}).getCode === 'function') {
      const resolved = await resolveTwoStepByContext(profile, twoStepContext, send.data,
        options.getCode, log, steps);
      if (resolved.loggedIn === true) {
        const headers = resolved.parsed.headers || {};
        const authorization = String(headers['IG-Set-Authorization']
          || headers['ig-set-authorization'] || '');
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
        loggedIn: false, aac, cookies: {}, authorization: '', twoStepContext,
        steps, reason: resolved.reason, raw: resolved.raw,
        // 把**提交密码那一步**的原始响应也带回去：2FA 的 app id 存在里面，
        // 失败时落盘就能离线分析，不必再让用户重跑一次登录。
        sendRaw: send.data
      };
    }
    return {
      loggedIn: false, aac, cookies: {}, authorization: '', twoStepContext,
      steps, raw: send.data, sendRaw: send.data,
      reason: '需要两步验证（context 链）：重新运行并输入验证码'
    };
  }

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
  const markers = bloksFallbackMarkers(send.data);
  let reason = errorText.length > 0
    ? '登录失败：' + errorText
    : '响应里没找到登录结果（布局形状可能变了，见 LOGIN.md）';
  // 只有在"没有更具体的原因"时才补这句：`CAA_LOGIN_FALLBACK:*` 是 IG 的通用兜底标记
  // （CAA 这次没直接给会话，具体原因它放在旧的 accounts 接口里），拿它当错误原因会误导。
  if (markers.length > 0 && errorText.length === 0) {
    reason += '（IG 标记 ' + markers.join(',') + '：CAA 这次没直接给会话）';
  }
  return {
    loggedIn: false,
    aac,
    cookies: {},
    authorization: '',
    twoStepContext,
    steps,
    reason,
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
  extractLoginPayloadDeep,
  twoStepContextOf,
  nextCallSpecs,
  pickCallSpec,
  lispyPairMap,
  bloksParenthesized,
  bloksExpressionItems,
  inferChallenge,
  findValueDeep,
  bloksFallbackMarkers,
  isNullPayloadReply,
  bloksCandidateApps,
  parseCookieHeader,
  sessionHeadersOf,
  bloksExtractContextValue,
  bloksNeedsTwoStep,
  bloksErrorMessage,
  // 底层调用与域名常量（给诊断脚本用：比如"这个 2FA app 到底在哪个域名上"）
  bloksApp,
  bloksAsyncAction,
  CAA_API_DOMAIN,
  PRIVATE_API_DOMAIN
};
