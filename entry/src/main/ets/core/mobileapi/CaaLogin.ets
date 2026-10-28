/*
 * **CAA（Bloks）密码登录 —— ArkTS 移植版**
 *
 * ## 这是什么
 * IG 已经停用了旧的 `accounts/login/` 接口（一律回 `needs_upgrade`），现在能登进去的
 * 唯一路子是 **CAA/Bloks 流程**。桌面端已经用 Node 移植过一份（`tools/relay/caa-login.js`，
 * 前 5 步实测打通）；这里是同一套协议在 App 内部的实现，目的是：
 *
 *   · App 自己登录 → 拿到**设备级会话**（iris 实时订阅 / FBNS 推送注册才认这种会话）；
 *   · 于是 App 内也能"消息到即弹"（本地通知，零服务器往返），不再依赖中转。
 *
 * ## 与 Node 版逐段的对应关系
 *   1. USDID：本地 P-256 密钥 + ES256 注册令牌 → `IGUSDIDRegistrationMutation`
 *   2. attestation：`attestation/create_android_keystore/` 取 `challenge_nonce`
 *      （IG 接受"keystore 不可用"状态 `errors: [-1013]`，**不需要 Play Integrity**）
 *   3. aac：`bloks/async_action/com.bloks.www.bloks.caa.login.process_client_data_and_redirect/`
 *      从布局里取 `CAA_ACCOUNT_ACCESS_CONTEXT:aac`
 *   4. `com.bloks.www.caa.login.oauth.token.fetch.async`
 *   5. `com.bloks.www.bloks.caa.login.async.send_login_request`（密码用 MobileCrypto 加密）
 *   6. 两步验证：`ap.two_step_verification` entrypoint → code_entry → 提交验证码
 *
 * ## 为什么自己发请求而不用 MobileRequest
 * `MobileRequest.absoluteUrl` 把域名写死成 `https://i.instagram.com/api…`，
 * 而 CAA 要打 **`b.i.instagram.com`**，USDID 注册还要打 `https://i.instagram.com/graphql_www`
 * （注意：**没有 `/api` 前缀**，带 /api 会回 404 + not-logged-in 的 HTML）。
 * 与其改那条被全 App 依赖的路径，不如在这里自带一个极小的 POST 工具。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { MobileCrypto, PasswordKeys } from './MobileCrypto';
// `MobileIdentity` 定义在 MobileSession（MobileRequest 只是转 import，并不导出）。
import { MobileIdentity } from './MobileSession';
import { MobileRequest } from './MobileRequest';
import { base64, base64UrlNoPad, textOf, utf8 } from './MobileSign';

const DOMAIN: number = 0xFF00;
const TAG: string = 'CaaLogin';

/** USDID 注册用的 GraphQL 文档 id（Android 428 档，instagrapi 同源）。 */
const USDID_CLIENT_DOC_ID: string = '124930351917786857261002920888';
/** CAA 专用域名（不是 i.instagram.com）。 */
const CAA_HOST: string = 'b.i.instagram.com';
const IG_APP_ID: string = '567067343352427';

/** 两步验证相关的三个 Bloks app。 */
const AP_2SV_ENTRYPOINT: string = 'com.bloks.www.ap.two_step_verification.entrypoint_async';
const AP_2SV_CODE_ENTRY: string = 'com.bloks.www.ap.two_step_verification.code_entry';
const AP_2SV_CODE_ENTRY_ASYNC: string = 'com.bloks.www.ap.two_step_verification.code_entry_async';

/** Bloks 布局里那一段 lispy：`(f4i (dkc "k1" …) (dkc "v1" …))`。 */
const LISPY_MAP_HEAD: string = '(f4i';

/** 登录结果（给 UI 用；不抛异常，全部放在字段里）。 */
export class CaaResult {
  /** 是否登录成功。 */
  ok: boolean = false;
  /** 失败原因 / 状态说明（给人看）。 */
  reason: string = '';
  /** 服务端下发的账号访问上下文（两步验证要用）。 */
  aac: string = '';
  /** 登录成功后的会话 Cookie（name=value; …）。 */
  cookie: string = '';
  /** 登录成功后的 `Bearer IGT:2:…`。 */
  authorization: string = '';
  /** 是否卡在两步验证（此时需要用户输入验证码再调 continueTwoStep）。 */
  needsCode: boolean = false;

  constructor(ok: boolean, reason: string) {
    this.ok = ok;
    this.reason = reason;
  }
}

/** 一步的现场（便于诊断：哪一步失败、HTTP 多少）。 */
export class CaaStep {
  readonly name: string;
  readonly status: number;
  readonly note: string;

  constructor(name: string, status: number, note: string) {
    this.name = name;
    this.status = status;
    this.note = note;
  }
}

/**
 * 等用户输验证码时**留住的现场**（见 `CaaLogin.login` 与 `submitCode`）。
 *
 * 为什么非要留住：两步验证是"提交密码 → 服务端要求验证码 → 再提交验证码"的**两段**对话，
 * 第二段要复用第一段拿到的 `context_data`（藏在 send_login_request 的布局里）与同一份请求头。
 * 不留现场就得把账号密码从 UI 再传回来、把整条链重跑一遍 —— 又慢，又等于多登一次。
 */
class CaaPending {
  readonly identity: MobileIdentity;
  readonly extra: Record<string, string>;
  readonly payload: ESObject;
  readonly aac: string;

  constructor(identity: MobileIdentity, extra: Record<string, string>, payload: ESObject, aac: string) {
    this.identity = identity;
    this.extra = extra;
    this.payload = payload;
    this.aac = aac;
  }
}

/* ------------------------------------------------------------- lispy 解析 */

/**
 * 取一对平衡括号内的表达式（Bloks 的 lispy 字符串会嵌套、且含转义引号）。
 *
 * 移植自 instagrapi 的 `_bloks_parenthesized_expression`：只能按字符扫，
 * 正则做不到（引号里的括号不能算层级）。
 */
export function bloksParenthesized(value: string, start: number): string {
  let depth: number = 0;
  let inString: boolean = false;
  let escaped: boolean = false;
  for (let index: number = start; index < value.length; index++) {
    const ch: string = value.charAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
    } else if (ch === '(') {
      depth++;
    } else if (ch === ')') {
      depth--;
      if (depth === 0) {
        return value.substring(start, index + 1);
      }
    }
  }
  return '';
}

/** 读表达式的直接操作数（不展开嵌套表达式）。 */
export function bloksExpressionItems(value: string): Array<string> {
  const items: Array<string> = [];
  if (!value.startsWith('(') || !value.endsWith(')')) {
    return items;
  }
  let index: number = 1;
  while (index < value.length - 1) {
    const ch: string = value.charAt(index);
    if (ch === ' ' || ch === '\n' || ch === '\t' || ch === '\r') {
      index++;
      continue;
    }
    let item: string = '';
    if (ch === '(') {
      item = bloksParenthesized(value, index);
      if (item.length === 0) {
        return [];
      }
    } else if (ch === '"') {
      let end: number = index + 1;
      let escaped: boolean = false;
      for (; end < value.length; end++) {
        const inner: string = value.charAt(end);
        if (escaped) {
          escaped = false;
          continue;
        }
        if (inner === '\\') {
          escaped = true;
          continue;
        }
        if (inner === '"') {
          break;
        }
      }
      item = value.substring(index, end + 1);
    } else {
      let end: number = index;
      while (end < value.length) {
        const inner: string = value.charAt(end);
        if (inner === '(' || inner === ')' || inner === ' ' || inner === '"') {
          break;
        }
        end++;
      }
      if (end === index) {
        return [];
      }
      item = value.substring(index, end);
    }
    items.push(item);
    index += item.length;
  }
  return items;
}

/** 收集 JSON 里所有字符串（Bloks 把上下文藏在 lispy 字符串里）。 */
export function collectStrings(value: ESObject, output: Array<string>): void {
  if (typeof value === 'string') {
    output.push(value as string);
    return;
  }
  if (Array.isArray(value)) {
    // 显式标注：`Array.isArray` 之后 ArkTS 把 value 当 any[]，`for…of` 的元素就会退化成 any。
    const items: Array<ESObject> = value as Array<ESObject>;
    for (let index: number = 0; index < items.length; index++) {
      collectStrings(items[index], output);
    }
    return;
  }
  if (value !== null && value !== undefined && typeof value === 'object') {
    const record: Record<string, ESObject> = value as Record<string, ESObject>;
    for (const key of Object.keys(record)) {
      collectStrings(record[key], output);
    }
  }
}

/**
 * 从 Bloks 布局里取"绑定在某个 app id 上的 context_data"。
 *
 * 这是两步验证链唯一的通行证：布局里那段 lispy 把键值成对放在 `(dkc …)` 里，
 * 找到目标 app id 附近的第一处 `(f4i …)`，按 key/value 对齐后取 `context_data`。
 */
export function bloksContextValue(payload: ESObject, appId: string, contextKey: string): string {
  const strings: Array<string> = [];
  collectStrings(payload, strings);
  const anchor: string = `"${appId}"`;
  for (const text of strings) {
    let from: number = 0;
    for (;;) {
      const found: number = text.indexOf(anchor, from);
      if (found < 0) {
        break;
      }
      from = found + anchor.length;
      const mapStart: number = text.indexOf(LISPY_MAP_HEAD, found);
      if (mapStart < 0) {
        continue;
      }
      let expression: string = bloksParenthesized(text, mapStart);
      while (expression.length > 0) {
        const items: Array<string> = bloksExpressionItems(expression);
        if (items.length !== 3 || items[0] !== 'f4i') {
          break;
        }
        const keys: Array<string> = bloksExpressionItems(items[1]);
        const values: Array<string> = bloksExpressionItems(items[2]);
        if (keys.length === 0 || values.length === 0
          || keys[0] !== 'dkc' || values[0] !== 'dkc' || keys.length !== values.length) {
          break;
        }
        expression = '';
        for (let index: number = 1; index < keys.length; index++) {
          const key: string = keys[index];
          const value: string = values[index];
          if (!key.startsWith('"')) {
            continue;
          }
          let name: string = '';
          try {
            name = JSON.parse(key) as string;
          } catch (error) {
            continue;
          }
          if (name === contextKey) {
            if (!value.startsWith('"')) {
              return '';
            }
            try {
              return JSON.parse(value) as string;
            } catch (error) {
              return '';
            }
          }
          if (name === 'server_params') {
            expression = value;
          }
        }
      }
    }
  }
  return '';
}

/** 布局里所有字符串拼起来（判"是否两步验证"、"错误文案"都用它）。 */
export function bloksAllText(payload: ESObject): string {
  const strings: Array<string> = [];
  collectStrings(payload, strings);
  return strings.join('\n');
}

/** 是否要求两步验证。 */
export function bloksNeedsTwoStep(payload: ESObject): boolean {
  return bloksAllText(payload).indexOf(AP_2SV_ENTRYPOINT) >= 0;
}

/** 从失败响应里挑出给人看的文案（IG 把它写在 UI 文本里）。 */
export function bloksErrorText(payload: ESObject): string {
  const text: string = bloksAllText(payload);
  const phrases: Array<string> = [
    'Can\'t find account', 'We can\'t find', 'password you entered', 'incorrect',
    'too many', 'wait a few minutes', 'suspended', 'checkpoint'
  ];
  for (const phrase of phrases) {
    const index: number = text.indexOf(phrase);
    if (index >= 0) {
      return text.substring(index, Math.min(index + 120, text.length)).replace(/\s+/g, ' ');
    }
  }
  return '';
}

/* ---------------------------------------------------------------- USDID */

/**
 * USDID：设备侧 P-256 签名身份（对应 instagrapi 的 `USDID`/`usdid_*`）。
 *
 * 产物两样：`X-Meta-Usdid` 头（`{usdid}.{expires}.{sig}`）与注册令牌
 * （IG 自定义的 `{payload, signatures:[{protected, signature}]}`）。
 * 签名是 ECDSA-SHA256，**DER 编码**（鸿蒙 `Sign` 默认就是 DER，和 instagrapi 一致）。
 */
export class CaaUsdid {
  readonly usdid: string;
  readonly kid: string;
  private privateKey: cryptoFramework.PriKey;
  private publicKeyDerBase64: string;

  constructor(usdid: string, kid: string, privateKey: cryptoFramework.PriKey, publicKeyDerBase64: string) {
    this.usdid = usdid;
    this.kid = kid;
    this.privateKey = privateKey;
    this.publicKeyDerBase64 = publicKeyDerBase64;
  }

  /** 生成一对新的 P-256 密钥（只生成，不落盘；持久化由调用方决定）。 */
  static async generate(): Promise<CaaUsdid> {
    const generator: cryptoFramework.AsyKeyGenerator =
      cryptoFramework.createAsyKeyGenerator('ECC256');
    const pair: cryptoFramework.KeyPair = await generator.generateKeyPair();
    const pubDer: Uint8Array = pair.pubKey.getEncoded().data;
    return new CaaUsdid(CaaLogin.randomUuid(), base64UrlNoPad(CaaLogin.randomBytes(32)),
      pair.priKey, base64(pubDer, false));
  }

  /** 恢复已保存的私钥（PEM/DER 都行；失败返回 null）。 */
  static async restore(usdid: string, kid: string, privateKeyText: string,
                       publicKeyDerBase64: string): Promise<CaaUsdid | null> {
    try {
      const generator: cryptoFramework.AsyKeyGenerator =
        cryptoFramework.createAsyKeyGenerator('ECC256');
      // 显式给 null 一个可空类型：直接写字面量 `null` 时重载解析会落到只收 `DataBlob` 的那两个上。
      const noPublicKey: cryptoFramework.DataBlob | null = null;
      const pair: cryptoFramework.KeyPair = await generator.convertKey(noPublicKey,
        { data: CaaLogin.pemToDer(privateKeyText) } as cryptoFramework.DataBlob);
      return new CaaUsdid(usdid, kid, pair.priKey, publicKeyDerBase64);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'usdid restore failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /**
   * 公开密钥（DER 的 base64）。JWT 的 `pub` 字段就放它，落盘时也一起存 ——
   * `restore` 不重新算公钥，所以存一份最省事。
   */
  publicKeyBase64(): string {
    return this.publicKeyDerBase64;
  }

  /**
   * 导出私钥（PKCS#8 DER 的 base64），供落盘后 `restore` 复原。
   *
   * 为什么要落盘：USDID 是**设备侧身份**。每次登录都换一对新密钥，在 IG 眼里就是
   * "一台从没见过的设备"，风控更严（可能多要一次验证码/恢复确认）。存下来之后
   * 同一台设备反复登录用的是同一个 usdid，和真实 App 一致。
   */
  exportPrivateKey(): string {
    return base64(this.privateKey.getEncoded().data, false);
  }

  /** DER 形式的 ECDSA 签名。 */
  async sign(message: string): Promise<Uint8Array> {
    // 类型名是 `cryptoFramework.Sign`（SDK 里没有 `Signer` 这个名字）。
    const signer: cryptoFramework.Sign = cryptoFramework.createSign('ECC256|SHA256');
    await signer.init(this.privateKey);
    const input: cryptoFramework.DataBlob = { data: utf8(message) };
    const blob: cryptoFramework.DataBlob = await signer.sign(input);
    return blob.data;
  }

  /** `X-Meta-Usdid: {usdid}.{expires}.{sig}` */
  async header(ttlSeconds: number = 3600): Promise<string> {
    const expires: number = Math.floor(Date.now() / 1000) + ttlSeconds;
    const signedPart: string = `${this.usdid}.${expires}`;
    return `${signedPart}.${base64UrlNoPad(await this.sign(signedPart))}`;
  }

  /** USDID 注册令牌（IG 自定义 JWT 结构）。 */
  async registrationToken(ttlSeconds: number = 3600): Promise<string> {
    const now: number = Math.floor(Date.now() / 1000);
    const payloadObject: Record<string, ESObject> = {
      'sub': this.usdid,
      'iat': now,
      'aud': IG_APP_ID,
      'exp': now + ttlSeconds,
      'pub': this.publicKeyDerBase64,
      'alg': 'ES256'
    };
    const protectedObject: Record<string, ESObject> = {
      'typ': 'JWT',
      'alg': 'ES256',
      'kid': this.kid,
      'aid': IG_APP_ID,
      'ver': '1'
    };
    const payload: string = base64UrlNoPad(utf8(JSON.stringify(payloadObject)));
    const head: string = base64UrlNoPad(utf8(JSON.stringify(protectedObject)));
    const signature: string = base64UrlNoPad(await this.sign(`${head}.${payload}`));
    const token: Record<string, ESObject> = {
      'payload': payload,
      'signatures': [{ 'protected': head, 'signature': signature }]
    };
    return base64UrlNoPad(utf8(JSON.stringify(token)));
  }
}

/* -------------------------------------------------------------- 登录主体 */

export class CaaLogin {
  /** 诊断用：每一步的现场（设置页可以把它显示出来）。 */
  private static steps: Array<CaaStep> = [];

  /** 等验证码时留住的现场（见 `CaaPending`）。 */
  private static pending: CaaPending | null = null;

  static lastSteps(): Array<CaaStep> {
    return CaaLogin.steps;
  }

  /** 现在是不是"等着用户交验证码"（UI 据此决定要不要显示输入框）。 */
  static waitingCode(): boolean {
    return CaaLogin.pending !== null;
  }

  /**
   * **解析器离线自检**（不联网、不需要账号）。
   *
   * 为什么需要：JS 侧有一份同样的解析器，用 test-caa-parse.js 验过（并因此改掉两处真 bug：
   * 转义引号截断、Cookie 属性当成 Cookie）。ArkTS 这边**跑不了单测**，而"登录成功之后解不出
   * 会话"恰恰只会在真账号上暴露 —— 一条自检能让"解析器坏了"和"IG 拒绝了"当场分开。
   *
   * @returns 一行结论（`解析自检 4/4 通过` 或指出哪一项没过）
   */
  static selfTest(): string {
    const failures: Array<string> = [];
    // ① aac
    const aacPayload: ESObject = CaaLogin.parse(
      '{"layout":{"bloks_payload":{"data":[{"data":{"key":"OTHER:x","initial":"no"}},'
        + '{"data":{"key":"CAA_ACCOUNT_ACCESS_CONTEXT:aac","initial":"AAC-TEST"}}]}}}');
    if (CaaLogin.extractAac(aacPayload) !== 'AAC-TEST') {
      failures.push('aac');
    }
    // ② 错误文案
    const errorPayload: ESObject = CaaLogin.parse(
      '{"layout":{"bloks_payload":{"ft":{"a":" We can\'t find an account with nobody. "}}}}');
    if (bloksErrorText(errorPayload).indexOf('find an account') < 0) {
      failures.push('error-text');
    }
    // ③ 成功响应（注意是**两层** JSON 字符串：action 里嵌着 JSON 文本）
    const innerFields: Record<string, string> = {};
    innerFields['login_response'] = JSON.stringify({ 'status': 'ok' } as Record<string, string>);
    const innerHeaders: Record<string, string> = { 'IG-Set-Authorization': 'Bearer IGT:2:AAA' };
    innerFields['headers'] = JSON.stringify(innerHeaders);
    innerFields['cookies'] = 'Set-Cookie: sessionid=777%3Asecret; Path=/, '
      + 'Set-Cookie: ds_user_id=777; Path=/';
    const inner: string = JSON.stringify(innerFields);
    const actionText: string = 'bloks_action({"payload": ' + JSON.stringify(inner) + '})';
    const actionHolder: Record<string, ESObject> = {};
    actionHolder['action'] = actionText;
    const loginBloks: Record<string, ESObject> = {};
    loginBloks['bloks_payload'] = actionHolder;
    const loginLayout: Record<string, ESObject> = {};
    loginLayout['layout'] = loginBloks;
    const loginPayload: ESObject = CaaLogin.parse(JSON.stringify(loginLayout));
    const parsed: CaaLoginPayload | null = CaaLogin.extractLoginPayload(loginPayload);
    if (parsed === null) {
      failures.push('login-payload');
    } else {
      if (parsed.cookie.indexOf('sessionid=777%3Asecret') < 0
        || parsed.cookie.indexOf('ds_user_id=777') < 0) {
        failures.push('cookie-parse');
      }
      if (parsed.cookie.indexOf('Path=') >= 0) {
        failures.push('cookie-attributes');
      }
      if (parsed.authorization !== 'Bearer IGT:2:AAA') {
        failures.push('authorization');
      }
    }
    // ④ 两步验证上下文
    const twoStepText: string = JSON.stringify('com.bloks.www.ap.two_step_verification.entrypoint_async')
      + ' (f4i (dkc "context_data") (dkc "CTX-TEST"))';
    const ftInner: Record<string, ESObject> = {};
    ftInner['a'] = twoStepText;
    const ftPayload: Record<string, ESObject> = {};
    ftPayload['ft'] = ftInner;
    const ftBloks: Record<string, ESObject> = {};
    ftBloks['bloks_payload'] = ftPayload;
    const ftLayout: Record<string, ESObject> = {};
    ftLayout['layout'] = ftBloks;
    const twoStepPayload: ESObject = CaaLogin.parse(JSON.stringify(ftLayout));
    if (!bloksNeedsTwoStep(twoStepPayload)) {
      failures.push('two-step-detect');
    } else if (bloksContextValue(twoStepPayload,
      'com.bloks.www.ap.two_step_verification.entrypoint_async', 'context_data') !== 'CTX-TEST') {
      failures.push('two-step-context');
    }
    return failures.length === 0 ? '解析自检 4/4 通过'
      : `解析自检未通过：${failures.join('、')}`;
  }

  /**
   * 交验证码，把两步验证这条链走完。
   *
   * 必须在 `login(..., null)` 返回 `needsCode` 之后调（现场在那一刻存下）。
   */
  static async submitCode(code: string): Promise<CaaResult> {
    const pending: CaaPending | null = CaaLogin.pending;
    if (pending === null) {
      return new CaaResult(false, '没有待提交的验证码：请重新点一次登录');
    }
    CaaLogin.pending = null;
    const trimmed: string = code.trim();
    if (trimmed.length === 0) {
      return new CaaResult(false, '验证码是空的');
    }
    return await CaaLogin.resolveTwoStep(pending.identity, pending.extra, pending.payload,
      pending.aac, trimmed);
  }

  /* -------------------------------------------------- 小工具（随机 / 编码） */

  static randomBytes(size: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(size);
    for (let index: number = 0; index < size; index++) {
      out[index] = Math.floor(Math.random() * 256);
    }
    return out;
  }

  /** 字节 → 小写十六进制。 */
  static hexOfBytes(bytes: Uint8Array): string {
    let out: string = '';
    for (let index: number = 0; index < bytes.length; index++) {
      out += bytes[index].toString(16).padStart(2, '0');
    }
    return out;
  }

  static randomUuid(): string {
    const bytes: Uint8Array = CaaLogin.randomBytes(16);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    const hex: string = Array.from(bytes).map((b: number): string =>
      b.toString(16).padStart(2, '0')).join('');
    return `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}`
      + `-${hex.substring(16, 20)}-${hex.substring(20)}`;
  }

  /** PEM（含 armour）→ DER；已经是 DER 就原样返回。 */
  static pemToDer(text: string): Uint8Array {
    const helper: util.Base64Helper = new util.Base64Helper();
    const begin: number = text.indexOf('-----BEGIN');
    if (begin < 0) {
      return helper.decodeSync(text.trim());
    }
    const body: string = text
      .replace(/-----BEGIN [^-]+-----/g, '')
      .replace(/-----END [^-]+-----/g, '')
      .replace(/\s+/g, '');
    return helper.decodeSync(body);
  }

  /**
   * 打一个 POST（表单或 JSON），返回 {status, headers, body}。
   *
   * `host` 与 `path` 分开传：CAA 要 b.i.instagram.com，USDID 要 i.instagram.com/graphql_www
   * （**没有 /api 前缀**）。
   */
  private static async post(host: string, path: string, body: string,
                            headers: Record<string, string>): Promise<CaaHttpReply> {
    const request: http.HttpRequest = http.createHttp();
    const all: Record<string, string> = {};
    for (const key of Object.keys(headers)) {
      all[key] = headers[key];
    }
    all['Content-Length'] = `${utf8(body).length}`;
    try {
      const response: http.HttpResponse = await request.request(`https://${host}${path}`, {
        method: http.RequestMethod.POST,
        header: all,
        extraData: body,
        connectTimeout: 20000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const reply: CaaHttpReply = new CaaHttpReply(response.responseCode, text);
      // 会话 cookie 有时只出现在响应头里（IG-Set-Authorization 同理），这里留一份
      reply.headerOf = (name: string): string => {
        const raw: ESObject = response.header as ESObject;
        if (raw === null || raw === undefined) {
          return '';
        }
        const record: Record<string, ESObject> = raw as Record<string, ESObject>;
        for (const key of Object.keys(record)) {
          if (key.toLowerCase() === name.toLowerCase()) {
            return `${record[key]}`;
          }
        }
        return '';
      };
      return reply;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 移动端请求头（与 MobileRequest.baseHeaders 同源，另加 CAA 需要的几条）。 */
  private static headers(identity: MobileIdentity, extra: Record<string, string>): Record<string, string> {
    const base: Record<string, string> = MobileRequest.baseHeaders(identity);
    base['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
    base['Accept'] = '*/*';
    for (const key of Object.keys(extra)) {
      base[key] = extra[key];
    }
    return base;
  }

  /* ---------------------------------------------------------------- 主流程 */

  /**
   * 用账号密码登录（CAA 流程）。
   *
   * @param codeProvider 需要两步验证码时回调（返回用户输入的验证码）；
   *                     传 null 表示"先探到需要验证码就停"，之后再用 continueTwoStep。
   */
  static async login(identity: MobileIdentity, username: string, password: string,
                     usdid: CaaUsdid,
                     codeProvider: (() => Promise<string>) | null): Promise<CaaResult> {
    CaaLogin.steps = [];
    // 新的一次登录：上一次没交的验证码现场作废（免得数字串到别的账号上）。
    CaaLogin.pending = null;
    const usdidHeader: string = await usdid.header();
    const extra: Record<string, string> = {};
    extra['X-Meta-Usdid'] = usdidHeader;
    const mid: string = identity.mid;
    if (mid.length > 0) {
      extra['X-MID'] = mid;
    }
    extra['X-Bloks-Version-Id'] = identity.app.bloksVersioningId;

    // 1. USDID 注册（失败不致命，多数情况 IG 侧已登记）
    // 注意：**嵌套的对象字面量必须一行一行搭**（ArkTS 不允许"没有声明类型的裸字面量"）。
    const token: string = await usdid.registrationToken();
    const sensitiveToken: Record<string, string> = { 'sensitive_string_value': token };
    const sensitiveFdid: Record<string, string> = { 'sensitive_string_value': identity.phoneId };
    const regInput: Record<string, ESObject> = {};
    regInput['usdid_token'] = sensitiveToken;
    regInput['fdid'] = sensitiveFdid;
    const regVariables: Record<string, ESObject> = {};
    regVariables['input'] = regInput;
    const regBody: string = CaaLogin.formEncode([
      new CaaField('client_doc_id', USDID_CLIENT_DOC_ID),
      new CaaField('variables', JSON.stringify(regVariables)),
      new CaaField('server_timestamps', 'true'),
      new CaaField('fb_api_caller_class', 'graphql'),
      new CaaField('fb_api_req_friendly_name', 'IGUSDIDRegistrationMutation')
    ]);
    const regHeaders: Record<string, string> = CaaLogin.headers(identity, extra);
    regHeaders['X-FB-Friendly-Name'] = 'IGUSDIDRegistrationMutation';
    regHeaders['X-Graphql-Client-Library'] = 'pando';
    regHeaders['X-Root-Field-Name'] = 'usdid_registration';
    const reg: CaaHttpReply = await CaaLogin.post('i.instagram.com', '/graphql_www', regBody, regHeaders);
    CaaLogin.steps.push(new CaaStep('usdid', reg.status,
      reg.status === 200 ? 'ok' : ''));
    hilog.info(DOMAIN, TAG, 'usdid registration status=%{public}d', reg.status);

    // 2. attestation（拿 challenge_nonce；keystore 不可用是可接受状态）
    const attBody: string = CaaLogin.formEncode([
      new CaaField('app_scoped_device_id', identity.uuid),
      new CaaField('key_hash', '')
    ]);
    const attHeaders: Record<string, string> = CaaLogin.headers(identity, extra);
    attHeaders['X-FB-Friendly-Name'] = 'IgApi: attestation/create_android_keystore/';
    const att: CaaHttpReply = await CaaLogin.post('i.instagram.com',
      '/api/v1/attestation/create_android_keystore/', attBody, attHeaders);
    const challengeNonce: string = CaaLogin.stringField(att.body, 'challenge_nonce');
    CaaLogin.steps.push(new CaaStep('attestation', att.status,
      challengeNonce.length > 0 ? 'nonce ok' : 'no nonce'));
    let attestParams: string = '';
    if (challengeNonce.length > 0) {
      const errors: Array<number> = [-1013];
      const attItem: Record<string, ESObject> = {
        'version': 2,
        'type': 'keystore',
        'errors': errors,
        'challenge_nonce': challengeNonce,
        'signed_nonce': '',
        'key_hash': ''
      };
      const attList: Array<Record<string, ESObject>> = [attItem];
      const attRoot: Record<string, ESObject> = {};
      attRoot['attestation'] = attList;
      attestParams = JSON.stringify(attRoot);
    }

    // 3. 取 aac（CAA 账号访问上下文）
    const waterfallId: string = CaaLogin.randomUuid();
    const processData: Record<string, ESObject> = {
      'is_from_logged_out': false,
      'logged_out_user': '',
      'qpl_join_id': null,
      'family_device_id': identity.phoneId,
      'device_id': identity.androidDeviceId,
      'offline_experiment_group': 'caa_iteration_v3_perf_ig_4',
      'waterfall_id': waterfallId,
      'logout_source': '',
      'show_internal_settings': false,
      'last_auto_login_time': 0,
      'disable_auto_login': false,
      'qe_device_id': identity.uuid,
      'use_auto_login_interstitial': true,
      'disable_recursive_auto_login_interstitial': true,
      'auto_login_interstitial_experiment_group_name': '',
      'is_from_logged_in_switcher': false,
      'switcher_logged_in_uid': '',
      'account_list': [],
      'blocked_uid': [],
      'INTERNAL_INFRA_THEME': 'THREE_NEUTRAL_GRAY',
      'layered_homepage_experiment_group': 'Deploy: Not in Experiment',
      'launched_url': '',
      'sim_phone_numbers': [],
      'is_from_registration_reminder': false
    };
    const step3: CaaHttpReply = await CaaLogin.bloks(identity, extra,
      'com.bloks.www.bloks.caa.login.process_client_data_and_redirect', processData);
    const aac: string = CaaLogin.extractAac(step3.body);
    CaaLogin.steps.push(new CaaStep('process_client_data', step3.status,
      aac.length > 0 ? `aac ${aac.length}` : 'no aac'));
    if (aac.length === 0) {
      const error: string = bloksErrorText(CaaLogin.parse(step3.body));
      const result: CaaResult = new CaaResult(false,
        error.length > 0 ? `登录失败：${error}` : '没拿到 aac（CAA 流程可能变了）');
      result.aac = '';
      return result;
    }

    // 4. oauth token 预取
    // 同样：嵌套的对象字面量逐层搭出来（ArkTS 不允许无声明类型的裸字面量）。
    const loisSettings: Record<string, string> = { 'lois_token': '' };
    const oauthClient: Record<string, ESObject> = {
      'username_input': username,
      'si_device_param_network_info': CaaLogin.networkInfo(),
      'aac': aac,
      'lois_settings': loisSettings,
      'cloud_trust_token': null,
      'zero_balance_state': '',
      'network_bssid': null
    };
    const oauthServer: Record<string, ESObject> = {
      'is_from_logged_out': 0,
      'layered_homepage_experiment_group': 'Deploy: Not in Experiment',
      'device_id': identity.androidDeviceId,
      'login_surface': 'login_home',
      'waterfall_id': waterfallId,
      'INTERNAL__latency_qpl_instance_id': Date.now(),
      'is_platform_login': 0,
      'login_entry_point': 'logged_out',
      'INTERNAL__latency_qpl_marker_id': 36707139,
      'family_device_id': identity.phoneId,
      'offline_experiment_group': 'caa_iteration_v3_perf_ig_4',
      'access_flow_version': 'pre_mt_behavior',
      'is_from_logged_in_switcher': 0,
      'qe_device_id': identity.uuid
    };
    const oauth: Record<string, ESObject> = {};
    oauth['client_input_params'] = oauthClient;
    oauth['server_params'] = oauthServer;
    const step4: CaaHttpReply = await CaaLogin.bloks(identity, extra,
      'com.bloks.www.caa.login.oauth.token.fetch.async', oauth);
    CaaLogin.steps.push(new CaaStep('oauth_token_fetch', step4.status, ''));

    // 5. 提交账号密码
    const keys: PasswordKeys | null = await CaaLogin.passwordKeys(identity);
    if (keys === null) {
      return new CaaResult(false, '拿不到密码加密公钥（qe/sync 没回头发公钥）');
    }
    const encrypted: string = await MobileCrypto.encryptPassword(password, keys);
    /*
     * 输入框 id 的形状必须和真机一致：**4 位十六进制 + `ig`**（instagrapi 3.2.2 的注释说得更狠：
     * 纯十六进制/UUID 前缀虽然能被 VM 接受，但可能回"空载荷 + 404"）。所以别用随机字节
     * 直接 toString（那会拼成 `12,34`）。
     */
    const textInputId: string = `${CaaLogin.hexOfBytes(CaaLogin.randomBytes(2))}ig`;
    const sendClient: Record<string, ESObject> =
      CaaLogin.sendClientParams(identity, username, encrypted, aac);
    const sendServer: Record<string, ESObject> =
      CaaLogin.sendServerParams(identity, waterfallId, textInputId);
    const send: Record<string, ESObject> = {};
    send['client_input_params'] = sendClient;
    send['server_params'] = sendServer;
    const sendExtra: Record<string, string> = {};
    for (const key of Object.keys(extra)) {
      sendExtra[key] = extra[key];
    }
    if (attestParams.length > 0) {
      sendExtra['X-IG-Attest-Params'] = attestParams;
    }
    const step5: CaaHttpReply = await CaaLogin.bloks(identity, sendExtra,
      'com.bloks.www.bloks.caa.login.async.send_login_request', send);
    CaaLogin.steps.push(new CaaStep('send_login_request', step5.status, ''));

    const payload: ESObject = CaaLogin.parse(step5.body);
    const login: CaaLoginPayload | null = CaaLogin.extractLoginPayload(payload);
    if (login !== null) {
      const result: CaaResult = new CaaResult(true, '登录成功');
      result.aac = aac;
      result.cookie = login.cookie;
      result.authorization = login.authorization;
      return result;
    }

    // 两步验证？
    if (bloksNeedsTwoStep(payload)) {
      const pending: CaaResult = new CaaResult(false, '需要两步验证');
      pending.aac = aac;
      pending.needsCode = true;
      if (codeProvider === null) {
        // 留住现场：UI 拿到验证码后调 `submitCode` 接着走（见 CaaPending）。
        CaaLogin.pending = new CaaPending(identity, extra, payload, aac);
        return pending;
      }
      const code: string = await codeProvider();
      return await CaaLogin.resolveTwoStep(identity, extra, payload, aac, code);
    }

    const error: string = bloksErrorText(payload);
    return new CaaResult(false,
      error.length > 0 ? `登录失败：${error}` : '响应里没找到登录结果（布局形状可能变了）');
  }

  /** 两步验证：entrypoint → code_entry → 提交验证码。 */
  private static async resolveTwoStep(identity: MobileIdentity, extra: Record<string, string>,
                                      sendPayload: ESObject, aac: string,
                                      code: string): Promise<CaaResult> {
    const entryContext: string = bloksContextValue(sendPayload, AP_2SV_ENTRYPOINT, 'context_data');
    if (entryContext.length === 0) {
      return new CaaResult(false, '两步验证：没取到 entrypoint 的 context_data');
    }
    const entryParams: Record<string, ESObject> = {
      'client_input_params': {
        'auth_secure_device_id': '',
        'accounts_list': [],
        'has_whatsapp_installed': 0,
        'family_device_id': identity.phoneId,
        'machine_id': identity.mid
      },
      'server_params': {
        'use_open_instead_of_push': 0,
        'context_data': entryContext,
        'INTERNAL__latency_qpl_marker_id': 36707139,
        'INTERNAL__latency_qpl_instance_id': Date.now(),
        'device_id': identity.uuid,
        'use_close_instead_of_back': 0
      }
    };
    const entry: CaaHttpReply = await CaaLogin.bloks(identity, extra, AP_2SV_ENTRYPOINT, entryParams);
    CaaLogin.steps.push(new CaaStep('2sv_entrypoint', entry.status, ''));
    const codeContext: string = bloksContextValue(CaaLogin.parse(entry.body), AP_2SV_CODE_ENTRY, 'context_data');
    if (codeContext.length === 0) {
      return new CaaResult(false, '两步验证：没取到 code_entry 的 context_data');
    }
    const codeEntryParams: Record<string, ESObject> = {
      'client_input_params': { 'aac': aac },
      'server_params': {
        'context_data': codeContext,
        'show_close_button': 0,
        'device_id': identity.uuid,
        'INTERNAL_INFRA_screen_id': 'generic_code_entry',
        'is_dismissable': 1
      }
    };
    const codeEntry: CaaHttpReply = await CaaLogin.bloksApp(identity, extra,
      AP_2SV_CODE_ENTRY, codeEntryParams);
    CaaLogin.steps.push(new CaaStep('2sv_code_entry', codeEntry.status, ''));
    const submitContext: string = bloksContextValue(CaaLogin.parse(codeEntry.body),
      AP_2SV_CODE_ENTRY_ASYNC, 'context_data');
    if (submitContext.length === 0) {
      return new CaaResult(false, '两步验证：没取到 code_entry_async 的 context_data');
    }
    const submitParams: Record<string, ESObject> = {
      'client_input_params': {
        'auth_secure_device_id': '',
        'aac': aac,
        'code': code,
        'family_device_id': identity.phoneId,
        'device_id': identity.androidDeviceId,
        'machine_id': identity.mid
      },
      'server_params': {
        'context_data': submitContext,
        'INTERNAL__latency_qpl_marker_id': 36707139,
        'INTERNAL__latency_qpl_instance_id': Date.now(),
        'device_id': identity.uuid
      }
    };
    const submit: CaaHttpReply = await CaaLogin.bloks(identity, extra,
      AP_2SV_CODE_ENTRY_ASYNC, submitParams);
    CaaLogin.steps.push(new CaaStep('2sv_submit', submit.status, ''));
    const login: CaaLoginPayload | null = CaaLogin.extractLoginPayload(CaaLogin.parse(submit.body));
    if (login === null) {
      const error: string = bloksErrorText(CaaLogin.parse(submit.body));
      return new CaaResult(false, error.length > 0
        ? `两步验证失败：${error}` : '两步验证已提交但没拿到会话');
    }
    const result: CaaResult = new CaaResult(true, '登录成功（两步验证）');
    result.aac = aac;
    result.cookie = login.cookie;
    result.authorization = login.authorization;
    return result;
  }

  /* ---------------------------------------------------------------- 细节 */

  private static async bloks(identity: MobileIdentity, extra: Record<string, string>,
                             action: string, params: Record<string, ESObject>): Promise<CaaHttpReply> {
    const body: string = CaaLogin.bloksBody(identity, params);
    const headers: Record<string, string> = CaaLogin.headers(identity, extra);
    headers['X-FB-Friendly-Name'] = `IgApi: bloks/async_action/${action}/`;
    return await CaaLogin.post(CAA_HOST, `/api/v1/bloks/async_action/${action}/`, body, headers);
  }

  private static async bloksApp(identity: MobileIdentity, extra: Record<string, string>,
                                app: string, params: Record<string, ESObject>): Promise<CaaHttpReply> {
    const body: string = CaaLogin.bloksBody(identity, params);
    const headers: Record<string, string> = CaaLogin.headers(identity, extra);
    return await CaaLogin.post(CAA_HOST, `/api/v1/bloks/apps/${app}/`, body, headers);
  }

  /** Bloks 请求体：`params` + `_uuid` + `bk_client_context` + `bloks_versioning_id`。 */
  private static bloksBody(identity: MobileIdentity, params: Record<string, ESObject>): string {
    const context: Record<string, ESObject> = {
      'bloks_version': identity.app.bloksVersioningId,
      'styles_id': 'instagram'
    };
    return CaaLogin.formEncode([
      new CaaField('params', JSON.stringify(params)),
      new CaaField('_uuid', identity.uuid),
      new CaaField('bk_client_context', JSON.stringify(context)),
      new CaaField('bloks_versioning_id', identity.app.bloksVersioningId)
    ]);
  }

  /** `a=b&c=d`（值做 URI 编码）。 */
  private static formEncode(fields: Array<CaaField>): string {
    const parts: Array<string> = [];
    for (const field of fields) {
      parts.push(`${encodeURIComponent(field.name)}=${encodeURIComponent(field.value)}`);
    }
    return parts.join('&');
  }

  /** 从 JSON 文本里取一个字符串字段（这里只用于 attestation 的 nonce）。 */
  private static stringField(body: string, name: string): string {
    const payload: ESObject = CaaLogin.parse(body);
    if (payload === null || payload === undefined) {
      return '';
    }
    const record: Record<string, ESObject> = payload as Record<string, ESObject>;
    const value: ESObject = record[name];
    return typeof value === 'string' ? value as string : '';
  }

  /** JSON.parse 的安全版（失败返回 null）。 */
  private static parse(text: string): ESObject {
    try {
      return JSON.parse(text) as ESObject;
    } catch (error) {
      return null;
    }
  }

  /** 从 Bloks 布局里取 aac。 */
  private static extractAac(body: string): string {
    const payload: ESObject = CaaLogin.parse(body);
    if (payload === null) {
      return '';
    }
    // ① 布局里显式的 CAA_ACCOUNT_ACCESS_CONTEXT:aac 节点
    const layout: ESObject = (payload as Record<string, ESObject>)['layout'];
    if (layout !== null && layout !== undefined) {
      const bloks: ESObject = (layout as Record<string, ESObject>)['bloks_payload'];
      if (bloks !== null && bloks !== undefined) {
        const data: ESObject = (bloks as Record<string, ESObject>)['data'];
        if (Array.isArray(data)) {
          const nodes: Array<ESObject> = data as Array<ESObject>;
          for (let nodeIndex: number = 0; nodeIndex < nodes.length; nodeIndex++) {
            const node: ESObject = nodes[nodeIndex];
            if (node === null || node === undefined) {
              continue;
            }
            const entry: ESObject = (node as Record<string, ESObject>)['data'];
            if (entry === null || entry === undefined) {
              continue;
            }
            const entryRecord: Record<string, ESObject> = entry as Record<string, ESObject>;
            if (`${entryRecord['key']}` !== 'CAA_ACCOUNT_ACCESS_CONTEXT:aac') {
              continue;
            }
            const initial: ESObject = entryRecord['initial'];
            if (typeof initial === 'string' && (initial as string).trim().length > 0) {
              return initial as string;
            }
          }
        }
      }
    }
    return '';
  }

  /**
   * 从一个 `"` 开始取**完整的 JSON 字符串字面量**（含两端引号）。
   *
   * 真实 payload 里的字符串**层层转义**（`\"login_response\"`）。直接用
   * `indexOf('"', start+1)` 找结尾会停在第一个转义引号上，截出来的东西 `JSON.parse`
   * 必然失败 —— 表现就是"登录成功却解析不出会话"。（离线自检 test-caa-parse.js 抓到的。）
   */
  private static jsonStringAt(text: string, start: number): string {
    if (text.charAt(start) !== '"') {
      return '';
    }
    let escaped: boolean = false;
    for (let index: number = start + 1; index < text.length; index++) {
      const ch: string = text.charAt(index);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        return text.substring(start, index + 1);
      }
    }
    return '';
  }

  /**
   * Cookie 串 → `name=value; …`（**对齐 Python SimpleCookie 的语义**）。
   *
   * 两种真实形状：
   *   ① `sessionid=x; Path=/; Domain=.instagram.com; HttpOnly`（后面全是属性）
   *   ② `Set-Cookie: sessionid=x; Path=/, Set-Cookie: ds_user_id=1; Path=/`（多颗、逗号分隔）
   * 只按 `;` 切会把 `Path` / `Domain` 当 Cookie 塞进罐里，而 `ds_user_id` 会因为名字带
   * `, Set-Cookie: ` 前缀**整个丢掉**（网页会话能建、账号 id 却空）。
   */
  private static parseCookieHeader(text: string): string {
    const attributes: Array<string> = ['path', 'domain', 'expires', 'max-age', 'secure',
      'httponly', 'samesite', 'priority', 'comment', 'commenturl', 'version', 'port', 'discard'];
    const parts: Array<string> = text.replace(/Set-Cookie:\s*/gi, '').split(/[;,]/);
    const pairs: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      const cut: number = one.indexOf('=');
      if (cut <= 0) {
        continue;
      }
      const name: string = one.substring(0, cut).trim();
      const value: string = one.substring(cut + 1).trim();
      if (name.length === 0 || value.length === 0) {
        continue;
      }
      if (attributes.indexOf(name.toLowerCase()) >= 0) {
        continue;
      }
      pairs.push(`${name}=${value}`);
    }
    return pairs.join('; ');
  }

  /** 从 Bloks 响应里抠出 cookie + authorization。 */
  private static extractLoginPayload(payload: ESObject): CaaLoginPayload | null {
    if (payload === null || payload === undefined) {
      return null;
    }
    const layout: ESObject = (payload as Record<string, ESObject>)['layout'];
    if (layout === null || layout === undefined) {
      return null;
    }
    const bloks: ESObject = (layout as Record<string, ESObject>)['bloks_payload'];
    if (bloks === null || bloks === undefined) {
      return null;
    }
    const action: ESObject = (bloks as Record<string, ESObject>)['action'];
    if (typeof action !== 'string') {
      return null;
    }
    const text: string = action as string;
    const marker: number = text.indexOf('login_response');
    if (marker < 0) {
      return null;
    }
    for (let start: number = marker; start >= 0; start--) {
      if (text.charAt(start) !== '"') {
        continue;
      }
      // 转义引号（`\"`）不是字符串起点。
      if (start > 0 && text.charAt(start - 1) === '\\') {
        continue;
      }
      const literal: string = CaaLogin.jsonStringAt(text, start);
      if (literal.length === 0) {
        continue;
      }
      let decoded: string = '';
      try {
        decoded = JSON.parse(literal) as string;
      } catch (error) {
        continue;
      }
      if (typeof decoded !== 'string' || decoded.indexOf('login_response') < 0) {
        continue;
      }
      try {
        const raw: Record<string, ESObject> = JSON.parse(decoded) as Record<string, ESObject>;
        const headersText: string = typeof raw['headers'] === 'string' ? raw['headers'] as string : '{}';
        const headers: Record<string, ESObject> = JSON.parse(headersText) as Record<string, ESObject>;
        let authorization: string = '';
        for (const key of Object.keys(headers)) {
          if (key.toLowerCase() === 'ig-set-authorization') {
            authorization = `${headers[key]}`;
          }
        }
        const cookieRaw: string = typeof raw['cookies'] === 'string' ? raw['cookies'] as string : '';
        const cookie: string = CaaLogin.parseCookieHeader(cookieRaw);
        return new CaaLoginPayload(cookie, authorization);
      } catch (error) {
        continue;
      }
    }
    return null;
  }

  /** 取密码加密公钥（qe/sync 的响应头）。 */
  private static async passwordKeys(identity: MobileIdentity): Promise<PasswordKeys | null> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(
        'https://i.instagram.com/api/v1/qe/sync/', {
          method: http.RequestMethod.GET,
          header: MobileRequest.baseHeaders(identity),
          connectTimeout: 15000,
          readTimeout: 15000,
          expectDataType: http.HttpDataType.STRING
        });
      const raw: ESObject = response.header as ESObject;
      if (raw === null || raw === undefined) {
        return null;
      }
      const record: Record<string, ESObject> = raw as Record<string, ESObject>;
      let keyId: number = 0;
      let publicKey: string = '';
      for (const key of Object.keys(record)) {
        const lower: string = key.toLowerCase();
        if (lower === 'ig-set-password-encryption-key-id') {
          keyId = Number.parseInt(`${record[key]}`, 10);
        } else if (lower === 'ig-set-password-encryption-pub-key') {
          publicKey = `${record[key]}`;
        }
      }
      return keyId > 0 && publicKey.length > 0 ? new PasswordKeys(keyId, publicKey) : null;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'password keys failed: %{public}s', (error as Error).message);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 设备网络信息（CAA 请求体要求的一段固定结构）。 */
  private static networkInfo(): Record<string, ESObject> {
    return {
      'active_subscriptions_info': null,
      'default_subscription_info': {
        'network_type': null,
        'is_data_roaming': 1,
        'is_esim': null,
        'is_gsm_roaming': 0,
        'is_sim_sms_capable': null,
        'is_mobile_data_enabled': 1,
        'sim_carrier_id': 1,
        'sim_carrier_id_name': null,
        'sim_state': 5,
        'sim_operator': '310260',
        'sim_operator_name': 'T-Mobile',
        'signal_strength': null,
        'group_id_level_1': null,
        'network_operator': '310260'
      },
      'is_airplane_mode': 0,
      'is_active_network_cellular': 0,
      'is_device_sms_capable': 1,
      'sim_count': 1,
      'is_wifi': 1
    };
  }

  /** 提交密码时的 client_input_params（字段照 instagrapi 逐项对齐）。 */
  private static sendClientParams(identity: MobileIdentity, username: string,
                                 encryptedPassword: string,
                                 aac: string): Record<string, ESObject> {
    return {
      'blocked_uids': [],
      'aac': aac,
      'sim_phones': [],
      'aymh_accounts': [],
      'network_bssid': null,
      'secure_family_device_id': '',
      'has_granted_read_contacts_permissions': 0,
      'auth_secure_device_id': '',
      'has_whatsapp_installed': 0,
      'si_device_param_network_info': CaaLogin.networkInfo(),
      'password': encryptedPassword,
      'sso_token_map_json_string': '',
      'block_store_machine_id': '',
      'ig_vetted_device_nonces': null,
      'cloud_trust_token': null,
      'event_flow': 'login_manual',
      'password_contains_non_ascii': 'false',
      'client_known_key_hash': '',
      'sso_accounts_auth_data': [],
      'encrypted_msisdn': '',
      'has_granted_read_phone_permissions': 0,
      'app_manager_id': '',
      'should_show_nested_nta_from_aymh': 0,
      'device_id': identity.androidDeviceId,
      'zero_balance_state': '',
      'login_attempt_count': 1,
      'machine_id': identity.mid,
      'flash_call_permission_status': {
        'READ_PHONE_STATE': 'DENIED',
        'READ_CALL_LOG': 'DENIED',
        'ANSWER_PHONE_CALLS': 'DENIED'
      },
      'accounts_list': [],
      'gms_incoming_call_retriever_eligibility': 'eligible',
      'family_device_id': identity.phoneId,
      'fb_ig_device_id': [],
      'device_emails': [],
      'try_num': 1,
      'lois_settings': { 'lois_token': '' },
      'event_step': 'home_page',
      'headers_infra_flow_id': '',
      'openid_tokens': {},
      'contact_point': username
    };
  }

  /** 提交密码时的 server_params。 */
  private static sendServerParams(identity: MobileIdentity, waterfallId: string,
                                 textInputId: string): Record<string, ESObject> {
    return {
      'should_trigger_override_login_2fa_action': 0,
      'is_from_logged_out': 0,
      'should_trigger_override_login_success_action': 0,
      'login_credential_type': 'none',
      'server_login_source': 'login',
      'waterfall_id': waterfallId,
      'two_step_login_type': 'one_step_login',
      'login_source': 'Login',
      'is_platform_login': 0,
      'login_entry_point': 'logged_out',
      'INTERNAL__latency_qpl_marker_id': 36707139,
      'is_from_aymh': 0,
      'offline_experiment_group': 'caa_iteration_v3_perf_ig_4',
      'is_from_landing_page': 0,
      'left_nav_button_action': 'NONE',
      'password_text_input_id': `${textInputId}:82`,
      'is_from_empty_password': 0,
      'is_from_msplit_fallback': 0,
      'ar_event_source': 'login_home_page',
      'qe_device_id': identity.uuid,
      'username_text_input_id': `${textInputId}:81`,
      'layered_homepage_experiment_group': 'Deploy: Not in Experiment',
      'device_id': identity.androidDeviceId,
      'login_surface': 'login_home',
      'INTERNAL__latency_qpl_instance_id': Date.now(),
      'reg_flow_source': 'login_home_native_integration_point',
      'is_caa_perf_enabled': 1,
      'credential_type': 'password',
      'is_from_password_entry_page': 0,
      'caller': 'gslr',
      'family_device_id': identity.phoneId,
      'is_from_assistive_id': 0,
      'access_flow_version': 'pre_mt_behavior',
      'is_from_logged_in_switcher': 0
    };
  }
}

/** 一个表单字段（只是为了让 formEncode 的调用点读起来清楚）。 */
class CaaField {
  readonly name: string;
  readonly value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

/** 一次 HTTP 回复（`headerOf` 用来读 IG-Set-Authorization 之类的响应头）。 */
class CaaHttpReply {
  readonly status: number;
  readonly body: string;
  headerOf: (name: string) => string = (name: string): string => '';

  constructor(status: number, body: string) {
    this.status = status;
    this.body = body;
  }
}

/** 解析出来的登录成果。 */
class CaaLoginPayload {
  readonly cookie: string;
  readonly authorization: string;

  constructor(cookie: string, authorization: string) {
    this.cookie = cookie;
    this.authorization = authorization;
  }
}
