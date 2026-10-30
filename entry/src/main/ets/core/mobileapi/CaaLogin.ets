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
// 自建 TLS 1.3 传输（见 post：系统 http 栈的 ClientHello 在登录端点会被 IG 429）。
import { Tls13Client, TlsHttpReply } from '../net/Tls13Client';
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
/**
 * 私有 API 的默认域名。**新版 2FA 的那几个 Bloks app 在这个域名上**（真机实测：
 * `b.i.instagram.com` 上同一批 app 全回 404 "Payload returned is null"）。
 */
const PRIVATE_HOST: string = 'i.instagram.com';

/* 新版 2FA（context 链）用到的 app / action（真机实测后确认走 i.instagram.com）。 */
const TSV_ENTRYPOINT: string = 'com.bloks.www.two_step_verification.entrypoint';
const TSV_METHOD_PICKER: string = 'com.bloks.www.two_step_verification.method_picker';
const TSV_SELECT_METHOD: string =
  'com.bloks.www.two_step_verification.method_picker.navigation.async';
const TSV_VERIFY: string = 'com.bloks.www.two_step_verification.verify_code.async';
const TSV_ENTER_BACKUP: string = 'com.bloks.www.two_factor_login.enter_backup_code';
const TSV_FLOW_SOURCE: string = 'two_factor_login';
const IG_APP_ID: string = '567067343352427';

/** 两步验证相关的三个 Bloks app。 */
const AP_2SV_ENTRYPOINT: string = 'com.bloks.www.ap.two_step_verification.entrypoint_async';
const AP_2SV_CODE_ENTRY: string = 'com.bloks.www.ap.two_step_verification.code_entry';
const AP_2SV_CODE_ENTRY_ASYNC: string = 'com.bloks.www.ap.two_step_verification.code_entry_async';

/** 提交密码那一发的 action（要用它单独留请求头副本，见 bloks / headersDump）。 */
const SEND_LOGIN_ACTION: string = 'com.bloks.www.bloks.caa.login.async.send_login_request';

/** Bloks 布局里那一段 lispy：`(f4i (dkc "k1" …) (dkc "v1" …))`。 */
const LISPY_MAP_HEAD: string = '(f4i';

/** 登录结果（给 UI 用；不抛异常，全部放在字段里）。 */export class CaaResult {
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
  /*
   * **登录响应头里带回来的会话材料**（instagrapi 在 `_send_private_request` 里也会捡）。
   *
   * 为什么必须有：全新安装时本机 `mid` 是空的，而 `X-MID` 是移动 API 的身份头之一。
   * 只留 `authorization`、把 `ig-set-x-mid` 丢掉的话，登录成功之后的每个请求都等于
   * "没有机器 id 的客户端" —— 前面几轮的 400 已证明这类头是有判据作用的。
   */
  mid: string = '';
  rur: string = '';
  claim: string = '';
  /** 这是**前检**的结果（只跑到 aac 就停，没有提交密码）——UI 据此不当成"已登录"。 */
  preflight: boolean = false;
  /**
   * 失败时的**原始响应**（截断到 100KB，只有失败才填）。
   *
   * 真机上没有 hdc，解析类 bug 只能靠这份原始数据定位（桌面版就是这么做出来的）。
   * 失败响应里不含可用会话材料，由用户主动「复制最近响应」发出来。
   */
  raw: string = '';
  /** 被 IG 限流（429）—— UI 据此提示"等一会儿再试"，并阻止连续重试。 */
  rateLimited: boolean = false;

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
  /**
   * 新版 2FA 的票据（`two_step_verification_context`）；非空表示等验证码后要走
   * **context 链**，空则走老的 `ap.*` 链。**必须存**：不存的话 UI 交码时无从判断该走哪条
   * （真机实测：存在这里之前，手机上输完码会报"没有待提交的验证码"）。
   */
  readonly context: string;

  constructor(identity: MobileIdentity, extra: Record<string, string>, payload: ESObject,
              aac: string, context: string = '') {
    this.identity = identity;
    this.extra = extra;
    this.payload = payload;
    this.aac = aac;
    this.context = context;
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

/**
 * 把 `\u5bc6` 这类转义还原成字符。
 *
 * 为什么需要：IG 的 CAA 响应里，界面文案是**被转义过**塞进 bloks 字符串的
 * （`\u5bc6\u7801\u9519\u8bef` 就是"密码错误"）。不解开的话，任何按中文找文案的
 * 规则都命中不了 —— 上一版就是这样把 `(e25 1)) (dps (dn3 …` 当成提示语贴给了用户。
 */
function unescapeText(text: string): string {
  let out: string = '';
  let at: number = 0;
  while (at < text.length) {
    const ch: string = text.charAt(at);
    if (ch !== '\\' || at + 1 >= text.length) {
      out += ch;
      at++;
      continue;
    }
    const next: string = text.charAt(at + 1);
    if (next === 'u' && at + 6 <= text.length) {
      const hex: string = text.substring(at + 2, at + 6);
      if (/^[0-9a-fA-F]{4}$/.test(hex)) {
        out += String.fromCharCode(Number.parseInt(hex, 16));
        at += 6;
        continue;
      }
    }
    if (next === 'n' || next === 'r' || next === 't') {
      out += ' ';
      at += 2;
      continue;
    }
    if (next === '"') {
      out += '"';
      at += 2;
      continue;
    }
    if (next === '/' || next === '\\') {
      out += next;
      at += 2;
      continue;
    }
    out += next;
    at += 2;
  }
  return out;
}

/** 这条字符串**像不像一句给人看的文案**（布局树里的字段名/埋点/代码都不算）。 */
function humanSentence(body: string): boolean {
  if (body.length < 4 || body.length > 200) {
    return false;
  }
  // 代码/布局表达式里这些符号很常见，人话里基本没有。
  if (body.indexOf('(') >= 0 || body.indexOf(')') >= 0 || body.indexOf('{') >= 0
    || body.indexOf('}') >= 0 || body.indexOf('<') >= 0 || body.indexOf('>') >= 0
    || body.indexOf('"') >= 0 || body.indexOf('\\') >= 0 || body.indexOf('_') >= 0
    || body.indexOf('=') >= 0 || body.indexOf('/') >= 0 || body.indexOf('#') >= 0) {
    return false;
  }
  if (/[\u4e00-\u9fff]/.test(body)) {
    return true;
  }
  return /^[A-Za-z0-9 ,.'!?%&:;\-]+$/.test(body) && body.indexOf(' ') > 0;
}

/**
 * 从一段（响应）文本里挑出**像人话**的句子。
 *
 * 为什么要这么干：CAA 的响应是一棵 bloks 布局树，IG 的提示文案（"密码错误"、
 * "你输入的密码有误，请重新输入。"…）**没有任何标准字段**，就写在其中某一个引号串里。
 *
 * 2026-10-30 真机实测（Mate 70 Pro+）：`send_login_request` 回 200，body 7549 字，
 * 结尾是 `(fom 13799 40 "\u5bc6\u7801\u9519\u8bef" 35 "\u4f60\u8f93\u5165\u7684…")`
 * —— 也就是 IG 明说"你输入的密码有误，请重新输入。"。上一版没解开转义、也没认中文，
 * 于是把布局代码片段当成了提示语。现在：先解转义，再按"人话"规则筛，**含提示词的排前面**。
 */
export function humanHints(text: string): Array<string> {
  const keywords: Array<string> = [
    '密码', '有误', '错误', '验证', '账号', '稍后', '太多', '不存在', '限制', '封禁', '重试',
    'sorry', 'incorrect', 'wrong', 'unable', 'unfortunately', 'try again', 'verify',
    'confirm', 'blocked', 'suspicious', 'unusual', 'wait', 'code', 'help'
  ];
  const strong: Array<string> = [];
  const weak: Array<string> = [];
  const plain: string = unescapeText(text);
  const found: RegExpMatchArray | null = plain.match(/"[^"]{4,200}"/g);
  if (found === null) {
    return weak;
  }
  for (let index: number = 0; index < found.length; index++) {
    const item: string = found[index];
    const body: string = item.substring(1, item.length - 1);
    if (!humanSentence(body)) {
      continue;
    }
    const lower: string = body.toLowerCase();
    let matched: boolean = false;
    for (let key: number = 0; key < keywords.length; key++) {
      if (lower.indexOf(keywords[key]) >= 0) {
        matched = true;
        break;
      }
    }
    // 短的（标题/按钮）优先：`密码错误` 比整段弹窗正文更适合当界面提示。
    const bucket: Array<string> = matched ? strong : weak;
    let duplicate: boolean = false;
    for (let seen: number = 0; seen < bucket.length; seen++) {
      if (bucket[seen] === body) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) {
      continue;
    }
    bucket.push(body);
    if (strong.length + weak.length >= 24) {
      break;
    }
  }
  strong.sort((left: string, right: string): number => left.length - right.length);
  const out: Array<string> = strong;
  for (let index: number = 0; index < weak.length; index++) {
    out.push(weak[index]);
  }
  return out;
}

/** 从失败响应里挑出给人看的文案（IG 把它写在 UI 文本里）。 */
export function bloksErrorText(payload: ESObject): string {
  // 文案在布局里是**转义后**的（`\u5bc6\u7801…`），不先解开就连英文短语也匹配不到。
  const text: string = unescapeText(bloksAllText(payload));
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
  // 固定短语一条都没命中：退一步，把响应里挑出来的"人话"当成 IG 的说法交出去。
  // 挑出来的是「短标题 + 正文」两段（`密码错误` / `你输入的密码有误，请重新输入。`），
  // 拼成一句给用户看，比只给标题更容易照做。
  const hints: Array<string> = humanHints(text);
  if (hints.length === 0) {
    return '';
  }
  if (hints.length === 1) {
    return hints[0];
  }
  return `${hints[0]}：${hints[1]}`;
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







  /**
   * 最近一次 `send_login_request` 的**请求体脱敏副本**（`password` / `aac` 换成占位符）。
   *
   * 用来和桌面 JS 那条链路（同一份参数结构、回 200）逐键比对 —— 两边都按同样规则脱敏，
   * 才能区分"某个字段值不对"与"传输层/HTTP 栈的问题"（见 login 里生成它的那段说明）。
   */
  static lastRequestDump: string = '';
  /** 最近一次 `send_login_request` **实际发出去的请求头**（脱敏，见 headersDump）。 */
  static lastRequestHeaders: string = '';
  /**
   * 最近一次 `send_login_request` 的**原始请求体与头**（只在内存里，供"换传输重发"用）。
   *
   * 用途：把**完全相同的这一发**改用另一套 HTTP 栈（`@kit.RemoteCommunicationKit` 的 rcp）再发一次。
   * 两套栈发同一份字节、结果不同 ⇒ 差异在传输层（TLS/HTTP 实现），不在我们的参数。
   */
  static lastSendBody: string = '';
  static lastSendHeaderMap: Record<string, string> = {};
  /** 最近一次 `qe/sync`（取密码加密公钥）的现场，失败时拼进提示里。 */
  static lastPasswordKeysNote: string = '';
  /** 这一次提交的密码里有没有非 ASCII 字符（`password_contains_non_ascii` 用）。 */
  private static passwordNonAscii: string = 'false';

  /**
   * **CAA 链路的 Cookie 罐**（进程内，一次登录的一串请求共用）。
   *
   * 这是定位到的**程序缺陷**（不是 IG 限流的原因，而是它一直是 429 的原因）：
   * 鸿蒙 `http.createHttp()` **不替我们存 Cookie**（模块没有 Cookie 管理，得自己从
   * `response.cookies` 收下来、再塞进下一个请求的头里）。而 instagrapi 用的是
   * `requests.Session` —— 步骤 1~4 下发的 `csrftoken` / `mid` / `datr` 会被自动带到第 5 步，
   * 所以它登得进去。
   *
   * 我们这边一路是"裸奔"：步骤 1~4 全是 200（它们都是 logged-out 端点，不看 Cookie），
   * 到第 5 步 `send_login_request` 既没有 Cookie 也没有 `X-CSRFToken`，IG 就回 429
   * （空 body，看起来像"被限流"，其实是"这发请求不像同一个客户端"）。
   *
   * 现在补齐这两样：**每个响应都把 Set-Cookie 收进罐子**（见 absorbResponseCookies），
   * **每个请求都带上罐子和 `X-CSRFToken`**（见 headers）。
   */
  private static cookieJar: Map<string, string> = new Map<string, string>();

  /** 清空 Cookie 罐（换设备身份 / 重新开始一条链时用）。 */
  static resetCookies(): void {
    CaaLogin.cookieJar.clear();
  }

  /** Cookie 罐里现在有哪些名字（诊断用：只有名字，没有值）。 */
  static cookieNames(): string {
    return Array.from(CaaLogin.cookieJar.keys()).join(',');
  }

  /** 现在该带的 `Cookie` 头（空串 = 罐子是空的，那就不带）。 */
  private static cookieHeader(): string {
    const parts: Array<string> = [];
    for (const name of Array.from(CaaLogin.cookieJar.keys())) {
      const value: string = CaaLogin.cookieJar.get(name) ?? '';
      if (name.length > 0 && value.length > 0) {
        parts.push(`${name}=${value}`);
      }
    }
    return parts.join('; ');
  }

  /** 罐子里的 `csrftoken`（要同时作为 `X-CSRFToken` 头发出去，instagrapi 就是这么做）。 */
  private static csrfToken(): string {
    return CaaLogin.cookieJar.get('csrftoken') ?? '';
  }

  /**
   * `Set-Cookie` 里那些**是属性、不是 Cookie** 的名字（照 Python `SimpleCookie` 的语义）。
   *
   * 不排除它们的话，`Path=/` / `Secure` / `Expires=…` 会被当成三颗名叫 Path / Secure 的
   * Cookie 记进罐子 —— 那既污染请求头，也会让真正的 `sessionid` 被顶掉。
   */
  private static readonly COOKIE_ATTRS: Array<string> = ['expires', 'max-age', 'path', 'domain',
    'secure', 'httponly', 'samesite', 'priority', 'partitioned', 'version', 'comment'];

  /**
   * 把一段 `Set-Cookie` 原文吸收进罐子。
   *
   * 三种形状都要认（IG 三条都下发过）：
   *   · 一条 `name=value; Path=/; ...`；
   *   · 多条被换行拼在一起（还可能带 `Set-Cookie: ` 前缀）；
   *   · 多条被 `, ` 拼在一起（**不能盲切逗号**：`expires=02-Dec-2027 13:57:44 GMT` 里就有逗号，
   *     所以要按"逗号后面跟着 `名字=`、且这个逗号不在 expires 的日期里"来切）。
   */
  private static absorbCookieText(text: string): void {
    const raw: string = text.trim();
    if (raw.length === 0) {
      return;
    }
    const lines: Array<string> = raw.replace(/Set-Cookie:\s*/gi, '').split(/\r?\n/);
    for (let index: number = 0; index < lines.length; index++) {
      const pairs: Array<string> = CaaLogin.splitCookiePairs(lines[index]);
      for (let pair: number = 0; pair < pairs.length; pair++) {
        const item: string = pairs[pair].trim();
        const eq: number = item.indexOf('=');
        if (eq <= 0) {
          continue;
        }
        const name: string = item.substring(0, eq).trim();
        const value: string = item.substring(eq + 1).trim();
        if (name.length === 0 || value.length === 0) {
          continue;
        }
        if (CaaLogin.COOKIE_ATTRS.indexOf(name.toLowerCase()) >= 0) {
          continue;
        }
        if (value.replace(/^"(.*)"$/, '$1').length === 0) {
          continue;
        }
        CaaLogin.cookieJar.set(name, value.replace(/^"(.*)"$/, '$1'));
      }
    }
  }

  /**
   * 把一条 `Set-Cookie` 行拆成若干 `name=value` 段。
   *
   * 为什么不直接 `split(';')`：一条 Cookie 的属性也在里面，但 `split(';')` 之后**属性名**
   * 会被 COOKIE_ATTRS 过滤掉，所以那样切是安全的 —— 真正麻烦的是", "拼接的多条 Cookie，
   * 那里必须避开 `expires=Wed, 21 Oct 2026 …` 的逗号。
   */
  private static splitCookiePairs(line: string): Array<string> {
    const out: Array<string> = [];
    let start: number = 0;
    for (let index: number = 0; index < line.length; index++) {
      const ch: string = line.charAt(index);
      if (ch !== ';' && ch !== ',') {
        continue;
      }
      if (ch === ',') {
        // 逗号后面必须紧跟 `名字=`（跳掉空格），否则当成日期里的逗号，不切。
        let probe: number = index + 1;
        while (probe < line.length && line.charAt(probe) === ' ') {
          probe++;
        }
        const head: string = line.substring(probe, probe + 32);
        if (!/^[A-Za-z0-9_\-]+\s*=/.test(head)) {
          continue;
        }
      }
      out.push(line.substring(start, index));
      start = index + 1;
    }
    out.push(line.substring(start));
    return out;
  }

  /**
   * 从一个响应里把 Cookie 收进罐子。
   *
   * 两个来源都要看：`response.cookies`（鸿蒙 http 模块把 Set-Cookie 归到这里）
   * 与 `response.header` 里名字含 `set-cookie` 的那几条（个别实现只放在头里）。
   */
  private static absorbResponseCookies(response: http.HttpResponse): void {
    try {
      const fromField: ESObject = response.cookies as ESObject;
      if (typeof fromField === 'string') {
        CaaLogin.absorbCookieText(fromField as string);
      }
    } catch (error) {
    }
    try {
      const rawHeaders: ESObject = response.header as ESObject;
      if (rawHeaders === null || rawHeaders === undefined) {
        return;
      }
      const record: Record<string, ESObject> = rawHeaders as Record<string, ESObject>;
      for (const key of Object.keys(record)) {
        if (key.toLowerCase().indexOf('set-cookie') < 0) {
          continue;
        }
        const value: ESObject = record[key];
        if (typeof value === 'string') {
          CaaLogin.absorbCookieText(value as string);
        }
      }
    } catch (error) {
    }
  }

  static lastSteps(): Array<CaaStep> {
    return CaaLogin.steps;
  }

  /** 现在是不是"等着用户交验证码"（UI 据此决定要不要显示输入框）。 */
  static waitingCode(): boolean {
    return CaaLogin.pending !== null;
  }

  /* ------------------------------------------- 2FA 现场摘要（诊断） */








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

    /*
     * ⑤ **真机格式的两条**（R12 实测踩过的坑，必须能自检）：
     *   · Cookie 串是按 `\r\n` 分行、每颗后面跟属性的；
     *   · 载荷前面可能有一句日志文本（`called_handle_login_response`），
     *     旧实现"从第一个 login_response 往回扫"会永远扫不到真正的载荷。
     */
    const realCookie: string = 'Set-Cookie: csrftoken=CSRF; Domain=.instagram.com; '
      + 'expires=02-Dec-2027 13:57:44 GMT; Max-Age=31536000; Path=/; Secure\r\n'
      + 'Set-Cookie: ds_user_id=777; Domain=.instagram.com; Path=/; Secure\r\n'
      + 'Set-Cookie: sessionid=777%3Areal; Domain=.instagram.com; HttpOnly; Path=/; Secure';
    const parsedCookie: string = CaaLogin.parseCookieHeader(realCookie);
    if (parsedCookie.indexOf('sessionid=777%3Areal') < 0
      || parsedCookie.indexOf('ds_user_id=777') < 0) {
      failures.push('cookie-crlf');
    }
    if (parsedCookie.indexOf('Secure') >= 0 || parsedCookie.indexOf('Domain') >= 0) {
      failures.push('cookie-attributes');
    }
    const innerFields2: Record<string, string> = {};
    innerFields2['login_response'] = JSON.stringify({ 'logged_in_user': { 'pk': 777 } } as Record<string, ESObject>);
    const innerHeaders2: Record<string, string> = { 'IG-Set-Authorization': 'Bearer IGT:2:REAL' };
    innerFields2['headers'] = JSON.stringify(innerHeaders2);
    innerFields2['cookies'] = 'Set-Cookie: sessionid=777%3Areal; Path=/; Secure';
    const trapText: string = '(dey "MAA_LOGIN_FLOW" '
      + '"[trait:called_handle_login_response] Calling HandleLoginResponse") '
      + '(dsg (fom 15942 35 ' + JSON.stringify(JSON.stringify(innerFields2)) + '))';
    const trapInner: Record<string, ESObject> = {};
    trapInner['a'] = trapText;
    const trapPayload0: Record<string, ESObject> = {};
    trapPayload0['ft'] = trapInner;
    const trapBloks: Record<string, ESObject> = {};
    trapBloks['bloks_payload'] = trapPayload0;
    const trapLayout: Record<string, ESObject> = {};
    trapLayout['layout'] = trapBloks;
    const trapPayload: ESObject = CaaLogin.parse(JSON.stringify(trapLayout));
    if (CaaLogin.extractLoginPayload(trapPayload) === null) {
      failures.push('login-response-trap');
    }
    // ⑥ 新版 2FA：从布局里读出"调哪个 app、带什么参数"（含长票据）
    const longToken: string = 'A'.repeat(300);
    const serverExpr: string = '(f4i (dkc "two_step_verification_context" "flow_source") '
      + `(dkc "${longToken}" "two_factor_login"))`;
    const clientExpr: string = '(f4i (dkc "machine_id") (dkc "MID-1"))';
    const specText: string = '(dzw (fom 1 2) 35 "com.bloks.www.two_step_verification.entrypoint" '
      + `49 7 (f6m 6 "params" (fma (f4i (dkc "server_params" "client_input_params") `
      + `(dkc ${serverExpr} ${clientExpr})))))`;
    const specInner: Record<string, ESObject> = {};
    specInner['a'] = specText;
    const specPayload0: Record<string, ESObject> = {};
    specPayload0['ft'] = specInner;
    const specBloks: Record<string, ESObject> = {};
    specBloks['bloks_payload'] = specPayload0;
    const specLayout: Record<string, ESObject> = {};
    specLayout['layout'] = specBloks;
    const specPayload: ESObject = CaaLogin.parse(JSON.stringify(specLayout));
    if (CaaLogin.twoStepContextOf(specPayload).length < 100) {
      failures.push('2sv-spec-context');
    }
    const spec: CaaCallSpec | null = CaaLogin.pickCallSpec(
      CaaLogin.nextCallSpecs(specPayload), ['two_step']);
    if (spec === null || spec.clientParams['machine_id'] !== 'MID-1') {
      failures.push('2sv-spec-params');
    }
    /*
     * ⑦ **真机 2026-10 的形状**：`cookies` 是**空对象**，会话材料全在 `ig-set-*` 头里。
     *
     * 这一条不测的话，"登录其实成功、App 却说没拿到会话"只能靠真账号复现 —— 而真账号
     * 每次复现都要动用一次登录尝试（会被 IG 记一笔）。所以必须固定成自检项。
     */
    const deviceLevelFields: Record<string, ESObject> = {};
    deviceLevelFields['login_response'] =
      JSON.stringify({ 'logged_in_user': { 'pk': 46473815227 }, 'status': 'ok',
        'credential_type': 'password' } as Record<string, ESObject>);
    const deviceLevelHeaders: Record<string, string> = {
      'IG-Set-Authorization': 'Bearer IGT:2:DEVICE',
      'ig-set-ig-u-ds-user-id': '46473815227',
      'ig-set-ig-u-rur': 'KND',
      'x-ig-set-www-claim': 'hmac.AAAA'
    };
    deviceLevelFields['headers'] = JSON.stringify(deviceLevelHeaders);
    deviceLevelFields['cookies'] = {} as Record<string, string>;
    const deviceLevelText: string = '(dsg (fom 15942 35 '
      + JSON.stringify(JSON.stringify(deviceLevelFields)) + '))';
    const deviceLevelFt: Record<string, ESObject> = {};
    deviceLevelFt['a'] = deviceLevelText;
    const deviceLevelPayload0: Record<string, ESObject> = {};
    deviceLevelPayload0['ft'] = deviceLevelFt;
    const deviceLevelBloks: Record<string, ESObject> = {};
    deviceLevelBloks['bloks_payload'] = deviceLevelPayload0;
    const deviceLevelLayout: Record<string, ESObject> = {};
    deviceLevelLayout['layout'] = deviceLevelBloks;
    const deviceLevel: CaaLoginPayload | null =
      CaaLogin.extractLoginPayload(CaaLogin.parse(JSON.stringify(deviceLevelLayout)));
    if (deviceLevel === null) {
      failures.push('device-level-payload');
    } else {
      if (deviceLevel.cookie.indexOf('ds_user_id=46473815227') < 0) {
        failures.push('device-level-uid');
      }
      if (deviceLevel.cookie.indexOf('rur=KND') < 0) {
        failures.push('device-level-rur');
      }
      if (deviceLevel.authorization !== 'Bearer IGT:2:DEVICE') {
        failures.push('device-level-auth');
      }
    }
    return failures.length === 0 ? '解析自检 7/7 通过'
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
    // 票据非空 ⇒ 走新版 context 链；否则走老的 ap.* 链。
    if (pending.context.length > 0) {
      return await CaaLogin.resolveTwoStepContext(pending.identity, pending.extra,
        pending.payload, pending.context, trimmed);
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
   *
   * **传输层现在是自建的 TLS 1.3**（见 `core/net/Tls13Client`）。原因见
   * `tools/relay/LOGIN-429.md`：系统 `http` 模块那条 TLS 栈的 ClientHello 会在
   * `send_login_request` 上被 IG 的 edge 回 429，而同一份请求用"自己拼的 ClientHello"
   * （JA3 对齐上游 instagrapi 社区那套能过的指纹）发出去是 **200**（真机验证过）。
   */
  /**
   * 这条失败原因**能不能**换系统 HTTP 栈重发（见 post 里的说明）。
   *
   * 只有"连接/协议"这类**与环境有关**的失败才回退；证书与钉住校验失败一律不退回 ——
   * 那是身份问题，换一套栈只会把校验让给别人。
   */
  private static canFallbackToSystem(reason: string): boolean {
    const lower: string = reason.toLowerCase();
    if (lower.indexOf('证书') >= 0 || lower.indexOf('spki') >= 0
      || lower.indexOf('san') >= 0 || lower.indexOf('中间人') >= 0) {
      return false;
    }
    return reason.indexOf('连接失败') >= 0 || lower.indexOf('operation in progress') >= 0
      || lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0
      || lower.indexOf('refused') >= 0 || lower.indexOf('unreachable') >= 0
      || lower.indexOf('network') >= 0 || lower.indexOf('reset') >= 0
      || reason.indexOf('服务端没选 TLS1.3') >= 0 || reason.indexOf('别的套件') >= 0
      || reason.indexOf('key_share') >= 0 || reason.indexOf('握手') >= 0
      /*
       * 解密失败也回退：证书链已经验过、钉住也过了，是**大响应逐条解密**在真机上
       * 挂了（Mate 70 Pro+ 上就是 `第 3 条应用数据解密失败：cipher doFinal failed`）。
       * 这类失败换系统栈能过，且没有把校验让给别人。
       */
      || reason.indexOf('解密失败') >= 0 || lower.indexOf('dofinal') >= 0;
  }

  private static async post(host: string, path: string, body: string,
                            headers: Record<string, string>): Promise<CaaHttpReply> {
    const all: Record<string, string> = {};
    for (const key of Object.keys(headers)) {
      all[key] = headers[key];
    }
    all['Content-Length'] = `${utf8(body).length}`;
    /*
     * **自建通道失败时的兜底**（真机反馈：Mate 70 Pro+ / HarmonyOS 7 上第一发直接
     * `登录请求异常：Operation in progress` —— 那是 `TCPSocket.connect()` 没走完就返回）。
     *
     * 分两类处理：
     *   · **连接层 / 协议不匹配**（连不上、只给 TLS 1.2、套件/曲线不对）→ 用**系统 HTTP 栈**
     *     把这一发重发一次（系统栈会走系统代理，VPN/企业代理环境下才发得出去）；
     *   · **证书链 / 钉住校验失败** → **不回退**，原样抛出去：那可能是中间人，
     *     换系统栈等于把校验交给别人。
     */
    let reply3: TlsHttpReply;
    try {
      reply3 = await Tls13Client.request(host, 443,
        body.length > 0 ? 'POST' : 'GET', path, all, body);
    } catch (error) {
      const reason: string = Tls13Client.errorText(error);
      if (!CaaLogin.canFallbackToSystem(reason)) {
        throw new Error(reason);
      }
      hilog.warn(DOMAIN, TAG, 'tls path failed (%{public}s) → system http fallback', reason);
      CaaLogin.steps.push(new CaaStep('sysfallback', 0, host));
      reply3 = await Tls13Client.requestViaSystem(host, 443,
        body.length > 0 ? 'POST' : 'GET', path, all, body);
    }
    const text: string = reply3.bodyText;
    const reply: CaaHttpReply = new CaaHttpReply(reply3.statusCode(), text, host);
    /*
     * **响应头留一份（脱敏）**。
     *
     * 429 的 body 常常是空的，此时"为什么被拒"只能从响应头里找（IG 的 edge 会带
     * `x-ig-*` / `retry-*` 之类的线索）。名字里带 cookie / authorization / token 的
     * 一律打码 —— 这份内容是给用户复制出来的，不能夹带会话材料。
     */
    try {
      const safe: Record<string, string> = {};
      const headerLines: Array<string> = reply3.headerText.split('\r\n');
      for (let index: number = 0; index < headerLines.length; index++) {
        const line: string = headerLines[index];
        const at: number = line.indexOf(':');
        if (at <= 0) {
          continue;
        }
        const name: string = line.substring(0, at).trim();
        const value: string = line.substring(at + 1).trim();
        const lower: string = name.toLowerCase();
        const secret: boolean = lower.indexOf('cookie') >= 0 || lower.indexOf('authorization') >= 0
          || lower.indexOf('token') >= 0 || lower.indexOf('secret') >= 0;
        safe[name] = secret ? '<redacted>' : value;
      }
      reply.headersText = JSON.stringify(safe);
    } catch (headerError) {
      reply.headersText = '';
    }
    // 会话材料常常只在响应头里（`ig-set-*`），这里按名字取。
    reply.headerOf = (name: string): string => {
      return reply3.headerOf(name);
    };
    // 每个响应的 `Set-Cookie` 收进罐子（见 cookieJar）：1~4 步的 csrftoken/mid/datr
    // 必须带到第 5 步。
    CaaLogin.absorbCookieText(reply3.headerOf('set-cookie'));
    return reply;
  }

  /** 移动端请求头（与 MobileRequest.baseHeaders 同源，另加 CAA 需要的几条）。 */
  private static headers(identity: MobileIdentity, extra: Record<string, string>): Record<string, string> {
    const base: Record<string, string> = MobileRequest.baseHeaders(identity);
    base['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
    base['Accept'] = '*/*';
    /*
     * **Cookie 与 `X-CSRFToken`**（见 cookieJar 的说明）。
     *
     * instagrapi 的 `_send_private_request` 每发一发都带
     * `cookies=self.cookies.get_dict()` 和 `headers["X-CSRFToken"] = self.token`；
     * 少这两样的第 5 步会被 IG 当成"不是同一个客户端"，回 429（空 body）。
     */
    const jar: string = CaaLogin.cookieHeader();
    if (jar.length > 0) {
      base['Cookie'] = jar;
    }
    const csrf: string = CaaLogin.csrfToken();
    if (csrf.length > 0) {
      base['X-CSRFToken'] = csrf;
    }
    for (const key of Object.keys(extra)) {
      base[key] = extra[key];
    }
    return base;
  }

  /* ---------------------------------------------------------------- 主流程 */

  /**
   * 用账号密码登录（CAA 流程）。
   *
   * @param codeProvider  需要两步验证码时回调（返回用户输入的验证码）；
   *                      传 null 表示"先探到需要验证码就停"，之后再用 continueTwoStep。
   * @param preflightOnly 只跑到"取到 aac"就停（**不提交密码**，不需要账号）——
   *                      用来把"设备/网络这一侧通不通"和"账号对不对"分开。
   */
  static async login(identity: MobileIdentity, username: string, password: string,
                     usdid: CaaUsdid,
                     codeProvider: (() => Promise<string>) | null,
                     preflightOnly: boolean = false): Promise<CaaResult> {
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
    /*
     * 非 200 时**把正文头 160 字也记进步骤**：USDID 注册这一发被拒（429 / 400）时，
     * IG 的正文里通常写着是限速还是参数问题，只记一个状态码等于什么都没说。
     */
    const regDetail: string = reg.status === 200 ? 'ok'
      : `HTTP ${reg.status} ${reg.body.substring(0, 160).replace(/\s+/g, ' ')}`;
    CaaLogin.steps.push(new CaaStep('usdid', reg.status, regDetail));
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
      /*
       * **把这一步的响应正文也带回去**（截断）。"没拿到 aac" 有两种可能：IG 回的布局确实
       * 变了，或它回了错误（风控/地区/参数）。只给一句"没拿到 aac"没法判断，而真机上
       * hilog 常常抓不到（本机实测被系统关掉了），所以原始正文就是唯一现场。
       */
      try {
        result.raw = CaaLogin.snippet(step3.body, 100000);
      } catch (rawError) {
        result.raw = '';
      }
      hilog.info(DOMAIN, TAG, 'process_client_data no aac status=%{public}d bodyLen=%{public}d',
        step3.status, step3.body.length);
      return result;
    }

    /*
     * **前检就到这里**（`preflightOnly`）：前三步与账号无关，跑到 aac 已经能说明
     * "设备身份 / attestation / 设备网络"这一侧是通的。后面的 oauth 与提交密码要用户名，
     * 而且会触碰风控，不属于前检。
     */
    if (preflightOnly) {
      const preflight: CaaResult = new CaaResult(true, `前检通过（aac ${aac.length} 字符）`);
      preflight.aac = aac;
      preflight.preflight = true;
      return preflight;
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
      return new CaaResult(false,
        `拿不到密码加密公钥（qe/sync 没回头发公钥）｜${CaaLogin.lastPasswordKeysNote}`);
    }
    const encrypted: string = await MobileCrypto.encryptPassword(password, keys);
    // IG 会看这个字段：密码里有非 ASCII 字符时真实客户端会置 true（以前写死 false）。
    CaaLogin.passwordNonAscii = /[^\x00-\x7F]/.test(password) ? 'true' : 'false';
    /*
     * **加密失败就不要提交**。
     *
     * 真机反馈（2026-10-30）：用户确认密码是对的，IG 却回「你输入的密码有误」。
     * 这中间有个静默的坑：`encryptPassword` 失败时返回空串，旧代码**照样把空串当密码发出去**，
     * IG 自然判"密码错误"，而界面把 IG 的原话转给用户 —— 于是看起来像"密码没输对"。
     * 现在：空串直接判失败并说明是哪一步没做成，同时把现场记进步骤。
     */
    CaaLogin.steps.push(new CaaStep('enc_password', 0,
      `${MobileCrypto.lastEncryptNote}｜qe/sync ${CaaLogin.lastPasswordKeysNote}`));
    if (encrypted.length === 0) {
      return new CaaResult(false,
        `密码加密失败，没有提交（否则 IG 会当成密码错误）｜${MobileCrypto.lastEncryptNote}`);
    }
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
    /*
     * **留一份"这一发请求体"的脱敏副本**（`password` / `aac` 换成占位符）。
     *
     * 为什么：桌面那条链路（同一份参数结构、同一个 IP、同一份设备身份）回 200，而 App 里
     * 同一发回 429 —— 剩下的差别只可能在"发出去的那串字节"或 HTTP 栈上。把两边都按同样的
     * 规则脱敏后逐字节/逐键比对，能一次定位是"某个字段值不对"还是"传输层的问题"。
     * 只含字段名与结构，不含密码与会话。
     */
    try {
      const redactedClient: Record<string, ESObject> = {};
      for (const key of Object.keys(sendClient)) {
        const value: ESObject = sendClient[key];
        if (key === 'aac') {
          redactedClient[key] = '<AAC>';
        } else {
          redactedClient[key] = value;
        }
      }
      const redactedSend: Record<string, ESObject> = {};
      redactedSend['client_input_params'] = redactedClient;
      redactedSend['server_params'] = sendServer;
      CaaLogin.lastRequestDump = CaaLogin.bloksBody(identity, redactedSend);
    } catch (dumpError) {
      CaaLogin.lastRequestDump = '';
    }
    const sendExtra: Record<string, string> = {};
    for (const key of Object.keys(extra)) {
      sendExtra[key] = extra[key];
    }
    if (attestParams.length > 0) {
      sendExtra['X-IG-Attest-Params'] = attestParams;
    }
    const step5: CaaHttpReply = await CaaLogin.bloks(identity, sendExtra,
      'com.bloks.www.bloks.caa.login.async.send_login_request', send);
    // 这一发带了哪些 Cookie、回了哪些 Cookie 是排障关键（429 的成因曾被这里误导过，见 cookieJar 的说明）。
    CaaLogin.steps.push(new CaaStep('send_login_request', step5.status,
      `cookie=${CaaLogin.cookieNames()}; csrf=${CaaLogin.csrfToken().length > 0 ? 'yes' : 'no'}`
      + `; setcookie=${step5.headerOf('set-cookie').length > 0 ? 'yes' : 'no'}`
      + `; body=${step5.body.length}B`));
    /*
     * **429 = IG 限流**（今天登录尝试太多）。必须单独认出来：否则会被当成"布局变了"，
     * 用户反复点只会让限流时间更长。给一句能照做的提示，并把现场留下。
     *
     * 注意：`send_login_request` 的 429 **body 常常是空的**（edge 层直接挡），所以判断依据只有
     * 状态码；真实文案（如果有）会被 raw 带回来，界面上那行"429 原因"能看出是哪种。
     */
    if (step5.status === 429) {
      const limited: CaaResult = new CaaResult(false,
        'IG 限流（429）：登录尝试太多了，等 10~30 分钟再试（期间别再点）');
      limited.aac = aac;
      limited.rateLimited = true;
      /*
       * **把"这一发长什么样"和"服务端回了什么头"一起落盘**。
       *
       * 以前这里只存 body，而 429 的 body 是空的 → 用户复制出来是一行 `null`，什么也判断不了。
       * 现在存：这一发的关键参数（机器 id / aac / 请求体长度）+ 脱敏响应头 + body 片段。
       * 「machine_id=空」这一种成因（见 MobileSession.ensureMid）就是靠这一行一眼看出来的。
       */
      const machineId: string = identity.mid.length > 0 ? `${identity.mid.length}位` : '空（可疑：登录会被判成非真机）';
      const bodyLength: number = CaaLogin.bloksBody(identity, send).length;
      const head: string = `send_login_request 429\n`
        + `machine_id=${machineId}\n`
        + `aac=${aac.length}字符 attest=${attestParams.length}字符 body=${bodyLength}字符\n`
        + `ua=${identity.userAgent()}\n`
        + `cookie=${CaaLogin.cookieNames() || '(空)'}\n`
        + `headers=${CaaLogin.snippet(step5.headersText, 4000)}\n`
        + `body=${CaaLogin.snippet(step5.body, 2000)}`;
      limited.raw = head;
      hilog.info(DOMAIN, TAG, 'send_login_request 429 body=%{public}d chars cookies=%{public}s',
        step5.body.length, CaaLogin.cookieNames());
      return limited;
    }

    const payload: ESObject = CaaLogin.parse(step5.body);
    const login: CaaLoginPayload | null = CaaLogin.extractLoginPayload(payload);
    if (login !== null) {
      const result: CaaResult = new CaaResult(true, '登录成功');
      result.aac = aac;
      result.cookie = login.cookie;
      result.authorization = login.authorization;
      result.mid = login.mid;
      result.rur = login.rur;
      result.claim = login.claim;
      return result;
    }

    // 两步验证？
    /*
     * **两套 2FA 都要认**（R12 真机实测）：
     *   · 新版：响应里带 `two_step_verification_context`（TOTP/SMS/备用码），
     *     **优先走它** —— 真机上 IG 对需要验证器的账号走的就是这条；
     *   · 老版：布局里有 `ap.two_step_verification.entrypoint_async`（profile-code 链）。
     */
    const context: string = CaaLogin.twoStepContextOf(payload);
    if (context.length > 0) {
      if (codeProvider === null) {
        const pending: CaaResult = new CaaResult(false, '需要两步验证（验证器/短信）');
        pending.aac = aac;
        pending.needsCode = true;
        // 必须留住现场（含票据）：UI 交码时据此走 context 链。
        CaaLogin.pending = new CaaPending(identity, extra, payload, aac, context);
        /*
         * **不再顺手去取 entrypoint / method_picker 那两屏**（上一版会在后台各打一发，
         * 为了把"这次有哪些验证方式"记进诊断摘要）。
         *
         * 真机反馈（2026-10-30）：那样做之后，用户在 Instagram 官方客户端点"同意"会被告知
         * **"这个登录请求已失效"** —— 那两屏是 2FA 状态机的一部分（method_picker 更是
         * "换一种验证方式"那一屏），替用户提前走一遍很可能把待确认的请求顶掉。
         * 现在除"看对方同意了吗"那一发之外，**不碰 2FA 状态机**。
         */
        /*
         * **这里只留"要 2FA"这个事实，不再替用户走 2FA 状态机**：
         *   · 不打开 entrypoint（用户不需要我们"渲染"那一屏）；
         *   · 不轮询 has_been_allowed；
         *   · 不碰 method_picker（那是"换一种验证方式"，等于替用户取消）。
         *
         * 实测结论见 LoginPage 里那段表：无论做不做这些，官方客户端点同意都报"请求已失效"，
         * 这条路在第三方客户端上走不通。
         */
        return pending;
      }
      const code: string = await codeProvider();
      return await CaaLogin.resolveTwoStepContext(identity, extra, payload, context, code);
    }

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
    const failed: CaaResult = new CaaResult(false,
      error.length > 0 ? `登录失败：${error}` : '响应里没找到登录结果（布局形状可能变了）');
    /*
     * 失败时把**原始响应**带回去（截断到 100KB）。
     *
     * 桌面版就是靠保存响应才定位到"载荷被日志文本挡住""Cookie 按 \r\n 分行"这两个 bug 的。
     * 真机上没有 hdc、hilog 会被冲掉，所以这条通道要留着 —— 失败响应里没有可用会话材料，
     * 由用户主动复制发出来。
     */
    try {
      failed.raw = JSON.stringify(payload).substring(0, 100000);
    } catch (rawError) {
      failed.raw = '';
    }
    return failed;
  }

  /* ------------------------------------------- 新版 2FA（context 链） */

  /**
   * 从响应里读出**下一步该调哪个 app、带什么参数**（Bloks 布局里的调用规范）。
   *
   * 真机响应里明写着：`35 "com.bloks.www.two_step_verification.entrypoint" … (f6m 6 "params"
   * (fma (f4i (dkc "server_params" "client_input_params") (dkc <server f4i> <client f4i>))))`，
   * 其中 `two_step_verification_context` 的值有 **2000+ 字符**。以前我们从别处硬抓一个
   * 13 字符的短值去调，IG 回 "Payload returned is null" —— 那才是 404 的真因。
   */
  static nextCallSpecs(payload: ESObject): Array<CaaCallSpec> {
    const out: Array<CaaCallSpec> = [];
    const strings: Array<string> = [];
    collectStrings(payload, strings);
    for (let index: number = 0; index < strings.length; index++) {
      const text: string = strings[index];
      let from: number = 0;
      for (;;) {
        const paramsAt: number = text.indexOf('"params"', from);
        if (paramsAt < 0) {
          break;
        }
        const fmaAt: number = text.indexOf('(fma', paramsAt);
        if (fmaAt < 0) {
          break;
        }
        const expr: string = bloksParenthesized(text, fmaAt);
        if (expr.length === 0) {
          break;
        }
        // app id：在 params 之前找最近一个 `35 "com.bloks.…"`
        const head: string = text.substring(0, paramsAt);
        const re: RegExp = /35\s+"(com\.bloks\.[A-Za-z0-9_.]+)"/g;
        let appId: string = '';
        let match: RegExpExecArray | null = re.exec(head);
        while (match !== null) {
          appId = match[1];
          match = re.exec(head);
        }
        out.push(CaaLogin.paramsFromFma(appId, expr));
        from = fmaAt + expr.length;
      }
    }
    return out;
  }

  /** `(fma <map>)` 或 `(fma <server> <client>)` → 规范对象。 */
  private static paramsFromFma(appId: string, fmaExpr: string): CaaCallSpec {
    const items: Array<string> = bloksExpressionItems(fmaExpr);
    if (items.length >= 3) {
      return new CaaCallSpec(appId, CaaLogin.lispyPairMap(items[1]), CaaLogin.lispyPairMap(items[2]));
    }
    let server: Record<string, string> = {};
    let client: Record<string, string> = {};
    if (items.length >= 2) {
      const entries: Array<CaaMapEntry> = CaaLogin.lispyMapEntries(items[1]);
      for (let index: number = 0; index < entries.length; index++) {
        const entry: CaaMapEntry = entries[index];
        if (entry.key === 'server_params') {
          server = CaaLogin.lispyPairMap(entry.value);
        } else if (entry.key === 'client_input_params') {
          client = CaaLogin.lispyPairMap(entry.value);
        }
      }
    }
    return new CaaCallSpec(appId, server, client);
  }

  /** `(f4i (dkc "k1" "k2") (dkc v1 v2))` → `[{key, value}]`（value 可能是嵌套表达式）。 */
  private static lispyMapEntries(expr: string): Array<CaaMapEntry> {
    const out: Array<CaaMapEntry> = [];
    const items: Array<string> = bloksExpressionItems(expr);
    if (items.length !== 3 || items[0] !== 'f4i') {
      return out;
    }
    const keys: Array<string> = bloksExpressionItems(items[1]);
    const values: Array<string> = bloksExpressionItems(items[2]);
    if (keys.length === 0 || values.length === 0 || keys[0] !== 'dkc' || values[0] !== 'dkc'
      || keys.length !== values.length) {
      return out;
    }
    for (let index: number = 1; index < keys.length; index++) {
      const key: string = keys[index];
      if (!key.startsWith('"')) {
        continue;
      }
      let name: string = '';
      try {
        name = JSON.parse(key) as string;
      } catch (error) {
        continue;
      }
      out.push(new CaaMapEntry(name, values[index]));
    }
    return out;
  }

  /** 同上，但只取字面量值（表达式值原样保留字符串）。 */
  private static lispyPairMap(expr: string): Record<string, string> {
    const out: Record<string, string> = {};
    const entries: Array<CaaMapEntry> = CaaLogin.lispyMapEntries(expr);
    for (let index: number = 0; index < entries.length; index++) {
      const entry: CaaMapEntry = entries[index];
      if (!entry.value.startsWith('"')) {
        out[entry.key] = entry.value;
        continue;
      }
      try {
        out[entry.key] = JSON.parse(entry.value) as string;
      } catch (error) {
        out[entry.key] = '';
      }
    }
    return out;
  }

  /** 规范里挑 app id 命中关键词的第一个（没有返回 null）。 */
  static pickCallSpec(specs: Array<CaaCallSpec>, keywords: Array<string>): CaaCallSpec | null {
    for (let index: number = 0; index < specs.length; index++) {
      const spec: CaaCallSpec = specs[index];
      const lower: string = spec.appId.toLowerCase();
      for (let k: number = 0; k < keywords.length; k++) {
        if (lower.indexOf(keywords[k]) >= 0) {
          return spec;
        }
      }
    }
    return null;
  }

  /** 新版 2FA 的票据：**优先从规范里取**（真值 2000+ 字符），取不到才回退旧逻辑。 */
  static twoStepContextOf(payload: ESObject): string {
    const specs: Array<CaaCallSpec> = CaaLogin.nextCallSpecs(payload);
    for (let index: number = 0; index < specs.length; index++) {
      const value: string = specs[index].serverParams['two_step_verification_context'];
      if (value !== undefined && value.length > 0) {
        return value;
      }
    }
    const deep: ESObject = CaaLogin.findValueDeep(payload, 'two_step_verification_context', 0);
    if (typeof deep === 'string' && (deep as string).trim().length > 0) {
      return (deep as string).trim();
    }
    return '';
  }

  /**
   * 把某些字段补成 **JSON null**（IG 期望这几个是 null，不是空串也不是省略）。
   *
   * @param params    形如 `{client_input_params: …, server_params: …}`
   * @param inClient  要补进 client_input_params 的键
   * @param inServer  要补进 server_params 的键
   */
  private static ensureNulls(params: Record<string, ESObject>, inClient: Array<string>,
                             inServer: Array<string>): void {
    const client: ESObject = params['client_input_params'];
    if (client !== null && client !== undefined) {
      const record: Record<string, ESObject> = client as Record<string, ESObject>;
      for (let index: number = 0; index < inClient.length; index++) {
        const key: string = inClient[index];
        if (record[key] === undefined) {
          record[key] = null;
        }
      }
    }
    const server: ESObject = params['server_params'];
    if (server !== null && server !== undefined) {
      const record: Record<string, ESObject> = server as Record<string, ESObject>;
      for (let index: number = 0; index < inServer.length; index++) {
        const key: string = inServer[index];
        if (record[key] === undefined) {
          record[key] = null;
        }
      }
    }
  }

  /** 默认值 + 规范值 → 合并后的参数（并把 "false"/"0" 还原类型）。 */  private static mergeParams(defaults: Record<string, string>,
                             fromSpec: Record<string, string>): Record<string, ESObject> {
    const merged: Record<string, string> = {};
    for (const key of Object.keys(defaults)) {
      merged[key] = defaults[key];
    }
    for (const key of Object.keys(fromSpec)) {
      merged[key] = fromSpec[key];
    }
    return CaaLogin.normalizeFlags(merged);
  }

  /** 规范里的 `"false"` / `"0"` 还原成布尔与数字。 */
  private static normalizeFlags(params: Record<string, string>): Record<string, ESObject> {
    const out: Record<string, ESObject> = {};
    for (const key of Object.keys(params)) {
      const value: string = params[key];
      const lower: string = value.trim().toLowerCase();
      if (lower === 'true') {
        out[key] = true;
      } else if (lower === 'false') {
        out[key] = false;
      } else if (/^-?\d+$/.test(lower)) {
        out[key] = Number.parseInt(lower, 10);
      } else {
        out[key] = value;
      }
    }
    return out;
  }

  /**
   * **新版 2FA 链**：entrypoint → method_picker → select_method →（备用码才走 backup）→ verify_code，
   * 每一跳的 app id 与参数**都从上一跳的响应里读**（IG 会把规范写在布局里）。
   */
  private static async resolveTwoStepContext(identity: MobileIdentity,
                                             extra: Record<string, string>,
                                             sendPayload: ESObject, context: string,
                                             code: string): Promise<CaaResult> {
    const sendSpecs: Array<CaaCallSpec> = CaaLogin.nextCallSpecs(sendPayload);
    const entrySpec: CaaCallSpec | null =
      CaaLogin.pickCallSpec(sendSpecs, ['two_step', 'two_factor']);
    const entryApp: string = entrySpec === null ? TSV_ENTRYPOINT : entrySpec.appId;
    const entryClientDefaults: Record<string, string> = {
      'device_id': identity.androidDeviceId,
      'is_whatsapp_installed': '0',
      'machine_id': identity.mid
    };
    const entryServerDefaults: Record<string, string> = {
      'should_fallback_to_sms': '0',
      'family_device_id': identity.phoneId,
      'device_id': identity.androidDeviceId,
      'two_step_verification_context': context,
      'flow_source': TSV_FLOW_SOURCE
    };
    const entryParams: Record<string, ESObject> = {};
    entryParams['client_input_params'] = CaaLogin.mergeParams(entryClientDefaults,
      entrySpec === null ? {} : entrySpec.clientParams);
    entryParams['server_params'] = CaaLogin.mergeParams(entryServerDefaults,
      entrySpec === null ? {} : entrySpec.serverParams);
    CaaLogin.steps.push(new CaaStep('2sv_context', context.length, 'entrypoint'));
    const entry: CaaHttpReply = await CaaLogin.bloksAppBestHost(identity, extra, entryApp,
      entryParams);
    CaaLogin.steps.push(new CaaStep('2sv_entrypoint', entry.status, entry.host));

    const entryPayload: ESObject = CaaLogin.parse(entry.body);
    const entrySpecs: Array<CaaCallSpec> = CaaLogin.nextCallSpecs(entryPayload);
    const pickerSpec: CaaCallSpec | null = CaaLogin.pickCallSpec(entrySpecs, ['method_picker']);
    const pickerApp: string = pickerSpec === null ? TSV_METHOD_PICKER : pickerSpec.appId;
    const pickerClientDefaults: Record<string, string> = { 'is_whatsapp_installed': '0' };
    const pickerServerDefaults: Record<string, string> = {
      'should_fallback_to_sms': '0',
      'device_id': identity.androidDeviceId,
      'two_step_verification_context': context,
      'flow_source': TSV_FLOW_SOURCE
    };
    const pickerParams: Record<string, ESObject> = {};
    pickerParams['client_input_params'] = CaaLogin.mergeParams(pickerClientDefaults,
      pickerSpec === null ? {} : pickerSpec.clientParams);
    pickerParams['server_params'] = CaaLogin.mergeParams(pickerServerDefaults,
      pickerSpec === null ? {} : pickerSpec.serverParams);
    const picker: CaaHttpReply = await CaaLogin.bloksAppBestHost(identity, extra, pickerApp,
      pickerParams);
    CaaLogin.steps.push(new CaaStep('2sv_method_picker', picker.status, picker.host));

    const challenge: string = CaaLogin.inferChallenge(sendPayload, code);
    const pickerPayload: ESObject = CaaLogin.parse(picker.body);
    const pickerSpecs: Array<CaaCallSpec> = CaaLogin.nextCallSpecs(pickerPayload);
    const selectSpec: CaaCallSpec | null = CaaLogin.pickCallSpec(pickerSpecs, ['navigation', 'select']);
    const selectApp: string = selectSpec === null ? TSV_SELECT_METHOD : selectSpec.appId;
    const selectClientDefaults: Record<string, string> = {
      'selected_method': challenge
    };
    const selectServerDefaults: Record<string, string> = {
      'should_fallback_to_sms': '0',
      'device_id': identity.androidDeviceId,
      'two_step_verification_context': context,
      'flow_source': TSV_FLOW_SOURCE
    };
    const selectParams: Record<string, ESObject> = {};
    selectParams['client_input_params'] = CaaLogin.mergeParams(selectClientDefaults,
      selectSpec === null ? {} : selectSpec.clientParams);
    selectParams['server_params'] = CaaLogin.mergeParams(selectServerDefaults,
      selectSpec === null ? {} : selectSpec.serverParams);
    // 这三个字段 IG 期望是 JSON null（JS 那份就是这么发的），别漏。
    CaaLogin.ensureNulls(selectParams, ['cloud_trust_token', 'network_bssid'],
      ['spectra_reg_login_data']);
    const selected: CaaHttpReply = await CaaLogin.bloksBestHost(identity, extra, selectApp,
      selectParams);
    CaaLogin.steps.push(new CaaStep('2sv_select_method', selected.status,
      `${selected.host} ${challenge}`));

    /*
     * **备用码支路**：8 位备用码要先打开输入页（对齐 JS 那份，也对齐 instagrapi
     * `bloks_two_step_verification_enter_backup_code`）。用验证器/短信的用户不会走到这。
     */
    if (challenge === 'backup_codes') {
      const selectPayloadForBackup: ESObject = CaaLogin.parse(selected.body);
      const backupSpecs: Array<CaaCallSpec> = CaaLogin.nextCallSpecs(selectPayloadForBackup);
      const backupSpec: CaaCallSpec | null = CaaLogin.pickCallSpec(backupSpecs, ['backup']);
      const backupApp: string = backupSpec === null ? TSV_ENTER_BACKUP : backupSpec.appId;
      const backupParams: Record<string, ESObject> = {};
      backupParams['server_params'] = CaaLogin.mergeParams({
        'device_id': identity.androidDeviceId,
        'two_step_verification_context': context,
        'flow_source': TSV_FLOW_SOURCE
      }, backupSpec === null ? {} : backupSpec.serverParams);
      const backup: CaaHttpReply = await CaaLogin.bloksAppBestHost(identity, extra, backupApp,
        backupParams);
      CaaLogin.steps.push(new CaaStep('2sv_enter_backup_code', backup.status, backup.host));
    }

    const selectPayload: ESObject = CaaLogin.parse(selected.body);
    const selectSpecs: Array<CaaCallSpec> = CaaLogin.nextCallSpecs(selectPayload);
    const verifySpec: CaaCallSpec | null = CaaLogin.pickCallSpec(selectSpecs, ['verify_code', 'verify']);
    const verifyApp: string = verifySpec === null ? TSV_VERIFY : verifySpec.appId;
    const verifyClientDefaults: Record<string, string> = {
      'auth_secure_device_id': '',
      'block_store_machine_id': '',
      'code': challenge === 'backup_codes' ? code.replace(/[\s-]+/g, '') : code,
      'should_trust_device': '1',
      'family_device_id': identity.phoneId,
      'device_id': identity.androidDeviceId,
      'machine_id': identity.mid
    };
    const verifyServerDefaults: Record<string, string> = {
      'should_fallback_to_sms': '0',
      'device_id': identity.androidDeviceId,
      'challenge': challenge,
      'two_step_verification_context': context,
      'flow_source': TSV_FLOW_SOURCE
    };
    const verifyParams: Record<string, ESObject> = {};
    verifyParams['client_input_params'] = CaaLogin.mergeParams(verifyClientDefaults,
      verifySpec === null ? {} : verifySpec.clientParams);
    verifyParams['server_params'] = CaaLogin.mergeParams(verifyServerDefaults,
      verifySpec === null ? {} : verifySpec.serverParams);
    CaaLogin.ensureNulls(verifyParams, ['cloud_trust_token', 'network_bssid'],
      ['spectra_reg_login_data']);
    const submit: CaaHttpReply = await CaaLogin.bloksBestHost(identity, extra, verifyApp,
      verifyParams);
    CaaLogin.steps.push(new CaaStep('2sv_verify_code', submit.status, submit.host));
    const login: CaaLoginPayload | null = CaaLogin.extractLoginPayload(CaaLogin.parse(submit.body));
    if (login === null) {
      const error: string = bloksErrorText(CaaLogin.parse(submit.body));
      return new CaaResult(false, error.length > 0
        ? `两步验证失败：${error}` : '两步验证已提交但没拿到会话（形状可能变了）');
    }
    const result: CaaResult = new CaaResult(true, '登录成功（两步验证）');
    result.cookie = login.cookie;
    result.authorization = login.authorization;
    result.mid = login.mid;
    result.rur = login.rur;
    result.claim = login.claim;
    return result;
  }

  /** 两步验证（老版 ap.* 链）：entrypoint → code_entry → 提交验证码。 */
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
    result.mid = login.mid;
    result.rur = login.rur;
    result.claim = login.claim;
    return result;
  }

  /* ---------------------------------------------------------------- 细节 */

  /**
   * 这个回包是不是"app 不在这个域名上"（Bloks VM 的空载荷失败）。
   *
   * 判据取自 IG 真实响应（R12）：404 + `Payload returned is null. A server error
   * field_exception occured.`。看起来像"形状变了"，其实只是域名不对。
   */
  private static isNullPayload(reply: CaaHttpReply): boolean {
    const body: string = reply.body === null || reply.body === undefined ? '' : reply.body;
    return body.indexOf('Payload returned is null') >= 0
      || (body.toLowerCase().indexOf('field_exception') >= 0 && body.indexOf('null') >= 0);
  }

  /**
   * 打 `bloks/apps/`，**两个域名自动回退**（先 `i.instagram.com`，空载荷再试 `b.i.instagram.com`）。
   *
   * 为什么：真机实测新版 2FA 的 app 在 `i.instagram.com`，而 CAA 登录的 app 在
   * `b.i.instagram.com`；IG 改版时也可能反过来。多打一次请求的成本远小于"手机上登录失败"。
   */
  private static async bloksAppBestHost(identity: MobileIdentity, extra: Record<string, string>,
                                        app: string, params: Record<string, ESObject>):
    Promise<CaaHttpReply> {
    const first: CaaHttpReply = await CaaLogin.bloksApp(identity, extra, app, params, PRIVATE_HOST);
    if (!CaaLogin.isNullPayload(first)) {
      return first;
    }
    const second: CaaHttpReply = await CaaLogin.bloksApp(identity, extra, app, params, CAA_HOST);
    return CaaLogin.isNullPayload(second) ? first : second;
  }

  /** 同上，打 `bloks/async_action/`。 */
  private static async bloksBestHost(identity: MobileIdentity, extra: Record<string, string>,
                                     action: string, params: Record<string, ESObject>):
    Promise<CaaHttpReply> {
    const first: CaaHttpReply = await CaaLogin.bloks(identity, extra, action, params, null,
      PRIVATE_HOST);
    if (!CaaLogin.isNullPayload(first)) {
      return first;
    }
    const second: CaaHttpReply = await CaaLogin.bloks(identity, extra, action, params, null,
      CAA_HOST);
    return CaaLogin.isNullPayload(second) ? first : second;
  }

  /** 打 `bloks/async_action/`（`host` 默认 CAA 域名；**新版 2FA 要用私有域名**）。 */
  private static async bloks(identity: MobileIdentity, extra: Record<string, string>,
                             action: string, params: Record<string, ESObject>,
                             aacUnused: string | null = null,
                             host: string = CAA_HOST): Promise<CaaHttpReply> {
    const body: string = CaaLogin.bloksBody(identity, params);
    const headers: Record<string, string> = CaaLogin.headers(identity, extra);
    headers['X-FB-Friendly-Name'] = `IgApi: bloks/async_action/${action}/`;
    // 提交密码那一发把**实际发出去的头**也留一份（脱敏）：桌面同一条链路是通的，
    // 逐条比对头是最后能定位"为什么同一发在 App 里被挡"的手段。
    if (action === SEND_LOGIN_ACTION) {
      CaaLogin.lastRequestHeaders = CaaLogin.headersDump(headers);
    }
    return await CaaLogin.post(host, `/api/v1/bloks/async_action/${action}/`, body, headers);
  }

  /**
   * 请求头脱敏副本（给"逐条比对"用）。
   *
   * `X-Meta-Usdid` 是设备签名（虽然短时有效）—— 只留长度；`Cookie` 同理由只留名字。
   * 其余原样保留：它们都是"客户端宣称自己是什么"的字段，不含任何凭据。
   */
  private static headersDump(headers: Record<string, string>): string {
    const lines: Array<string> = [];
    const keys: Array<string> = Object.keys(headers).sort();
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const lower: string = key.toLowerCase();
      const value: string = headers[key];
      if (lower === 'x-meta-usdid') {
        lines.push(`${key}: <usdid ${value.length} chars>`);
      } else if (lower === 'cookie' || lower.indexOf('authorization') >= 0) {
        lines.push(`${key}: <redacted ${value.length} chars>`);
      } else {
        lines.push(`${key}: ${value}`);
      }
    }
    return lines.join('\n');
  }

  /** 打 `bloks/apps/`（`host` 同上）。 */
  private static async bloksApp(identity: MobileIdentity, extra: Record<string, string>,
                                app: string, params: Record<string, ESObject>,
                                host: string = CAA_HOST): Promise<CaaHttpReply> {
    const body: string = CaaLogin.bloksBody(identity, params);
    const headers: Record<string, string> = CaaLogin.headers(identity, extra);
    return await CaaLogin.post(host, `/api/v1/bloks/apps/${app}/`, body, headers);
  }

  /**
   * 推断 2FA 方式（照 instagrapi）：8 位数字 ⇒ 备用码；只开短信没开 TOTP ⇒ sms；其余 ⇒ totp。
   */
  private static inferChallenge(payload: ESObject, code: string): string {
    const normalized: string = String(code).replace(/[\s-]+/g, '');
    if (/^\d{8}$/.test(normalized)) {
      return 'backup_codes';
    }
    const sms: boolean = CaaLogin.loginResponseBool(payload, 'sms_two_factor_on');
    const totp: boolean = CaaLogin.loginResponseBool(payload, 'totp_two_factor_on');
    return sms && !totp ? 'sms' : 'totp';
  }

  /** 在整棵响应里找一个布尔（值可能是 "true" / 1 / true）。 */
  private static loginResponseBool(payload: ESObject, key: string): boolean {
    const value: ESObject = CaaLogin.findValueDeep(payload, key, 0);
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    if (typeof value === 'number') {
      return (value as number) !== 0;
    }
    if (typeof value === 'string') {
      const lower: string = (value as string).trim().toLowerCase();
      return lower === '1' || lower === 'true' || lower === 'yes';
    }
    return false;
  }

  /** 递归找键（值可能是再嵌一层的 JSON 文本）。 */
  private static findValueDeep(value: ESObject, key: string, depth: number): ESObject {
    if (depth > 12 || value === null || value === undefined) {
      return undefined;
    }
    if (Array.isArray(value)) {
      const list: Array<ESObject> = value as Array<ESObject>;
      for (let index: number = 0; index < list.length; index++) {
        const hit: ESObject = CaaLogin.findValueDeep(list[index], key, depth + 1);
        if (hit !== undefined) {
          return hit;
        }
      }
      return undefined;
    }
    if (typeof value === 'object') {
      const record: Record<string, ESObject> = value as Record<string, ESObject>;
      const own: ESObject = record[key];
      if (own !== undefined && own !== null && own !== '') {
        return own;
      }
      for (const childKey of Object.keys(record)) {
        const hit: ESObject = CaaLogin.findValueDeep(record[childKey], key, depth + 1);
        if (hit !== undefined) {
          return hit;
        }
      }
      return undefined;
    }
    if (typeof value === 'string') {
      const text: string = value as string;
      if (text.indexOf(key) < 0 || text.length > 400000) {
        return undefined;
      }
      try {
        return CaaLogin.findValueDeep(JSON.parse(text) as ESObject, key, depth + 1);
      } catch (error) {
        return undefined;
      }
    }
    return undefined;
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

  /**
   * 截一段响应文本（诊断用）。
   *
   * 单独一个函数是为了**在 `body` 是空串/`null` 时给出可读结果**：以前这里写的是
   * `String(body).substring(...)`，body 为 null 时得到的是四个字符 `null`，
   * 落盘的「原始响应」就成了没有信息量的 `null`（真机诊断时被它误导过）。
   */
  static snippet(text: string, limit: number): string {
    if (text === null || text === undefined) {
      return '';
    }
    const value: string = `${text}`;
    return value.length > limit ? value.substring(0, limit) : value;
  }

  /** JSON.parse 的安全版（失败返回 null）。 */
  private static parse(text: string): ESObject {
    try {
      return JSON.parse(text) as ESObject;
    } catch (error) {
      return null;
    }
  }

  /**
   * 从 Bloks 布局里取 aac。
   *
   * @param body 响应体字符串**或**已解析的对象 —— 两种都吃。
   *   为什么两种都吃：真实链路传的是响应体字符串，而「解析自检」在内存里已经 parse 过了，
   *   只收字符串的话自检会拿对象当 JSON 再解析一次 → 永远取不到 aac（真机就报了这一项）。
   */
  private static extractAac(body: ESObject): string {
    const payload: ESObject =
      typeof body === 'string' ? CaaLogin.parse(body as string) : body;
    if (payload === null || payload === undefined) {
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
            /*
             * ② **有些版本只把 aac 放在 `initial_lispy` 的 lispy 表达式里**。
             *
             * 这一条是"App 报没拿到 aac、命令行却正常"的直接原因：JS 版（已验证能取到
             * aac 303 字符）两种都试，ArkTS 版原来只看 `initial`。两边必须一致 ——
             * 取法照 JS 的 extractAac：从第一个 `"` 起取一段 JSON 字符串再解。
             */
            const lispyRaw: ESObject = entryRecord['initial_lispy'];
            const lispy: string = typeof lispyRaw === 'string' ? lispyRaw as string : '';
            const quote: number = lispy.indexOf('"');
            if (quote >= 0) {
              const end: number = lispy.indexOf('"', quote + 1);
              if (end > quote) {
                try {
                  const value: string = JSON.parse(lispy.substring(quote, end + 1)) as string;
                  if (typeof value === 'string' && value.length > 0) {
                    return value;
                  }
                } catch (error) {
                  // 解不开就继续找下一个节点
                }
              }
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
   * 真机实测（R12）的格式是按 `\r\n` 分隔、每颗后面跟一串属性：
   *   `Set-Cookie: csrftoken=…; Domain=…; expires=02-Dec-2027 13:57:44 GMT; Max-Age=…;
   *    Path=/; Secure\r\nSet-Cookie: ds_user_id=…\r\nSet-Cookie: sessionid=…; HttpOnly; …`
   *
   * 所以切分符必须包含**换行**：只按 `;` `,` 切的话，`Secure\r\nSet-Cookie: ds_user_id`
   * 会被当成一颗 Cookie 的名字 —— sessionid 明明在响应里、却解析不出来（真机就是这么丢的）。
   * 属性值里可能带空格（`expires=02-Dec-2027 13:57:44 GMT`），名字要做合法性过滤。
   */
  private static parseCookieHeader(text: string): string {
    const attributes: Array<string> = ['path', 'domain', 'expires', 'max-age', 'secure',
      'httponly', 'samesite', 'priority', 'comment', 'commenturl', 'version', 'port', 'discard'];
    const NAME_OK: RegExp = /^[A-Za-z0-9_\-%]+$/;
    const parts: Array<string> = text.replace(/Set-Cookie:\s*/gi, '').split(/[;,\r\n]+/);
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
      if (!NAME_OK.test(name)) {
        continue;
      }
      if (attributes.indexOf(name.toLowerCase()) >= 0) {
        continue;
      }
      pairs.push(`${name}=${value}`);
    }
    return pairs.join('; ');
  }

  /**
   * `ig-set-*` 响应头 → cookie 串。
   *
   * 为什么要这条：IG 有些响应**不下发 `Set-Cookie`**，而是把 cookie 的值放在 `ig-set-*` 头里
   * 让客户端自己拼（真机 2026-10 的密码登录就是这种：`cookies` 是空对象，但
   * `ig-set-ig-u-ds-user-id` / `ig-set-ig-u-rur` / `x-ig-set-www-claim` 都在）。
   * 只认 `cookies` 字段的话，登录成功也会被当成"没拿到会话"（与 relay 同一套语义）。
   */
  private static cookiesFromSessionHeaders(headers: Record<string, ESObject>): string {
    const pairs: Array<string> = [];
    const seen: Array<string> = [];
    let uid: string = '';
    let rur: string = '';
    let session: string = '';
    let claim: string = '';
    let mid: string = '';
    for (const key of Object.keys(headers)) {
      const lower: string = key.toLowerCase();
      const value: string = `${headers[key]}`.replace(/^[A-Za-z-]+:\s*/, '').trim();
      if (value.length === 0) {
        continue;
      }
      if (lower === 'ig-set-ig-u-ds-user-id') {
        uid = value;
      } else if (lower === 'ig-set-ig-u-rur') {
        rur = value;
      } else if (lower === 'ig-set-ig-u-sessionid') {
        session = value;
      } else if (lower === 'x-ig-set-www-claim') {
        claim = value;
      } else if (lower === 'ig-set-x-mid') {
        mid = value;
      }
    }
    CaaLogin.pushCookiePair(pairs, seen, 'ds_user_id', uid);
    CaaLogin.pushCookiePair(pairs, seen, 'ig-u-ds-user-id', uid);
    CaaLogin.pushCookiePair(pairs, seen, 'rur', rur);
    CaaLogin.pushCookiePair(pairs, seen, 'ig-u-rur', rur);
    CaaLogin.pushCookiePair(pairs, seen, 'sessionid', session);
    CaaLogin.pushCookiePair(pairs, seen, 'ig-u-sessionid', session);
    CaaLogin.pushCookiePair(pairs, seen, 'ig-u-www-claim', claim);
    CaaLogin.pushCookiePair(pairs, seen, 'mid', mid);
    return pairs.join('; ');
  }

  /** 往 cookie 对里加一条（同名只加一次）。 */
  private static pushCookiePair(pairs: Array<string>, seen: Array<string>,
                                name: string, value: string): void {
    if (name.length === 0 || value.length === 0 || seen.indexOf(name) >= 0) {
      return;
    }
    seen.push(name);
    pairs.push(`${name}=${value}`);
  }

  /**
   * 载荷里的 `cookies` 有三种形状（IG 三种都下发过）：
   *   · 字符串 `"sessionid=…; ds_user_id=…"`（老形状）
   *   · 对象 `{sessionid: '…'}`（R12 之后的形状）
   *   · **空对象 `{}` + 值全在 `headers` 里**（真机 2026-10 的密码登录，只看这一项会误判成失败）
   * 以及数组 `[{name, value}]` 或 `["a=b"]`。
   */
  private static cookiesFromRaw(rawCookies: ESObject): string {
    if (rawCookies === null || rawCookies === undefined) {
      return '';
    }
    if (typeof rawCookies === 'string') {
      return CaaLogin.parseCookieHeader(rawCookies as string);
    }
    const pairs: Array<string> = [];
    if (Array.isArray(rawCookies)) {
      const list: Array<ESObject> = rawCookies as Array<ESObject>;
      for (let index: number = 0; index < list.length; index++) {
        const item: ESObject = list[index];
        if (typeof item === 'string') {
          const one: string = CaaLogin.parseCookieHeader(item as string);
          if (one.length > 0) {
            pairs.push(one);
          }
        } else if (item !== null && item !== undefined && typeof item === 'object') {
          const record: Record<string, ESObject> = item as Record<string, ESObject>;
          const name: string = `${record['name'] === undefined ? '' : record['name']}`;
          const value: string = `${record['value'] === undefined ? '' : record['value']}`;
          if (name.length > 0 && value.length > 0) {
            pairs.push(`${name}=${value}`);
          }
        }
      }
      return pairs.join('; ');
    }
    if (typeof rawCookies === 'object') {
      const record: Record<string, ESObject> = rawCookies as Record<string, ESObject>;
      for (const name of Object.keys(record)) {
        const value: string = `${record[name]}`;
        if (name.length > 0 && value.length > 0 && value !== 'undefined') {
          pairs.push(`${name}=${value}`);
        }
      }
    }
    return pairs.join('; ');
  }

  /** 两个 cookie 串合并（同名以 `base` 为准）。 */
  private static mergeCookieText(base: string, extra: string): string {
    const parts: Array<string> = base.split(';');
    const more: Array<string> = extra.split(';');
    const merged: Array<string> = [];
    for (let index: number = 0; index < more.length; index++) {
      if (more[index].trim().length > 0) {
        parts.push(more[index]);
      }
    }
    for (let index: number = 0; index < parts.length; index++) {
      CaaLogin.pushCookieText(merged, parts[index].trim());
    }
    return merged.join('; ');
  }

  /** 按 `name=value` 塞进合并结果（同名只留第一条）。 */
  private static pushCookieText(merged: Array<string>, one: string): void {
    const cut: number = one.indexOf('=');
    if (cut <= 0) {
      return;
    }
    const name: string = one.substring(0, cut).trim();
    if (name.length === 0) {
      return;
    }
    for (let index: number = 0; index < merged.length; index++) {
      if (merged[index].substring(0, merged[index].indexOf('=')).trim() === name) {
        return;
      }
    }
    merged.push(one);
  }

  /**
   * 从**一段文本**里抠登录结果：**正向**遍历每个字符串字面量逐个试解。
   *
   * 为什么不能"从 `login_response` 第一次出现处往回扫"：真机响应里第一次出现的地方是一句
   * 日志文本 `"[trait:called_handle_login_response] Calling HandleLoginResponse"` ——
   * 它包含这几个字，往回扫永远只在它**前面**转，而真正的载荷在它**后面**。
   * （R12 真机：2FA 全 200、登录其实成功，却报"没找到登录结果"，就是这个原因。）
   */
  private static loginPayloadFromText(text: string): CaaLoginPayload | null {
    if (text.indexOf('login_response') < 0 && text.indexOf('ig-set-authorization') < 0) {
      return null;
    }
    // 兜底用：真正带 cookie 的那一份优先，找不到才退回"第一个能解析的对象"。
    let fallback: CaaLoginPayload | null = null;
    let index: number = 0;
    while (index < text.length) {
      if (text.charAt(index) !== '"') {
        index++;
        continue;
      }
      if (index > 0 && text.charAt(index - 1) === '\\') {
        index++;
        continue;
      }
      const literal: string = CaaLogin.jsonStringAt(text, index);
      if (literal.length === 0) {
        index++;
        continue;
      }
      index += literal.length;
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
        if (raw === null || raw === undefined) {
          continue;
        }
        // 必须是"登录结果那种对象"（有 login_response / cookies / headers 之一）
        if (raw['login_response'] === undefined && raw['cookies'] === undefined
          && raw['headers'] === undefined) {
          continue;
        }
        const headersText: string = typeof raw['headers'] === 'string' ? raw['headers'] as string : '{}';
        const headers: Record<string, ESObject> = JSON.parse(headersText) as Record<string, ESObject>;
        let authorization: string = '';
        for (const key of Object.keys(headers)) {
          if (key.toLowerCase() === 'ig-set-authorization') {
            authorization = `${headers[key]}`;
          }
        }
        /*
         * **cookie 有两个来源**，缺一不可（真机 2026-10：`cookies` 是空对象，值全在头里）：
         *   · 载荷的 `cookies` 字段（字符串 / 对象 / 数组）；
         *   · `ig-set-*` 响应头里夹带的 cookie 值。
         * 之前只认字符串 `cookies`，于是"登录其实成功"被判成"没有 sessionid"。
         */
        const cookie: string = CaaLogin.mergeCookieText(
          CaaLogin.cookiesFromRaw(raw['cookies']),
          CaaLogin.cookiesFromSessionHeaders(headers));
        // 会话材料（mid / rur / claim）也要带回去，别只留 authorization。
        let mid: string = '';
        let rur: string = '';
        let claim: string = '';
        for (const key of Object.keys(headers)) {
          const lower: string = key.toLowerCase();
          const value: string = `${headers[key]}`.replace(/^[A-Za-z-]+:\s*/, '').trim();
          if (lower === 'ig-set-x-mid' && value.length > 0) {
            mid = value;
          } else if (lower === 'ig-set-ig-u-rur' && value.length > 0) {
            rur = value;
          } else if (lower === 'x-ig-set-www-claim' && value.length > 0) {
            claim = value;
          }
        }
        const found: CaaLoginPayload = new CaaLoginPayload(cookie, authorization, mid, rur, claim);
        // 优先"带 cookie 的那一份"：同一响应里可能有好几个带 login_response 的对象
        // （布局规范、中间态、真正的结果各一份），拿到中间态就会误判。
        if (cookie.length > 0) {
          return found;
        }
        if (fallback === null) {
          fallback = found;
        }
      } catch (error) {
        continue;
      }
    }
    return fallback;
  }

  /**
   * 从 Bloks 响应里抠出 cookie + authorization：先试老位置 `layout.bloks_payload.action`，
   * 再把**所有字符串**逐个正向扫一遍（真机把载荷放在 `embedded_payloads` / 日志串后面）。
   */
  private static extractLoginPayload(payload: ESObject): CaaLoginPayload | null {
    if (payload === null || payload === undefined) {
      return null;
    }
    const layout: ESObject = (payload as Record<string, ESObject>)['layout'];
    if (layout !== null && layout !== undefined) {
      const bloks: ESObject = (layout as Record<string, ESObject>)['bloks_payload'];
      if (bloks !== null && bloks !== undefined) {
        const action: ESObject = (bloks as Record<string, ESObject>)['action'];
        if (typeof action === 'string') {
          const direct: CaaLoginPayload | null = CaaLogin.loginPayloadFromText(action as string);
          if (direct !== null) {
            return direct;
          }
        }
      }
    }
    const strings: Array<string> = [];
    collectStrings(payload, strings);
    for (let index: number = 0; index < strings.length; index++) {
      const hit: CaaLoginPayload | null = CaaLogin.loginPayloadFromText(strings[index]);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  /**
   * 取密码加密公钥（`qe/sync` 的响应头）。
   *
   * **这一发走系统 `http` 模块**，不走自建 TLS：`qe/sync` 不是登录端点，系统栈在这里是
   * 200/405 + 正常下发公钥头（真机实测），而自建通道跑这一发会抛
   * `Cannot read property length of undefined`（GET 路径在自建通道上还没调通）。
   * 真正被 IG 挡的只有 `send_login_request`，那一发走自建通道就够了。
   */
  private static async passwordKeys(identity: MobileIdentity): Promise<PasswordKeys | null> {
    const request: http.HttpRequest = http.createHttp();
    try {
      /*
       * 这一发也要走**同一套 Cookie 罐**：`qe/sync` 是最常见的 `csrftoken` / `mid` 发放点，
       * 而第 5 步提交密码必须带着它们（见 cookieJar 的说明）。
       */
      const headers: Record<string, string> = MobileRequest.baseHeaders(identity);
      const jar: string = CaaLogin.cookieHeader();
      if (jar.length > 0) {
        headers['Cookie'] = jar;
      }
      const csrf: string = CaaLogin.csrfToken();
      if (csrf.length > 0) {
        headers['X-CSRFToken'] = csrf;
      }
      const response: http.HttpResponse = await request.request(
        'https://i.instagram.com/api/v1/qe/sync/', {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: 15000,
          readTimeout: 15000,
          expectDataType: http.HttpDataType.STRING
        });
      CaaLogin.absorbResponseCookies(response);
      let keyId: number = 0;
      let publicKey: string = '';
      const raw: ESObject = response.header as ESObject;
      if (raw !== null && raw !== undefined) {
        const record: Record<string, ESObject> = raw as Record<string, ESObject>;
        for (const key of Object.keys(record)) {
          const lower: string = key.toLowerCase();
          if (lower === 'ig-set-password-encryption-key-id') {
            keyId = Number.parseInt(`${record[key]}`, 10);
          } else if (lower === 'ig-set-password-encryption-pub-key') {
            publicKey = `${record[key]}`;
          }
        }
      }
      const parsed: number = Number.isFinite(keyId) ? keyId : 0;
      CaaLogin.lastPasswordKeysNote = `qe/sync(http) status=${response.responseCode}`
        + ` keyId=${parsed} pubKeyLen=${publicKey.length}`;
      return parsed > 0 && publicKey.length > 0 ? new PasswordKeys(parsed, publicKey) : null;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'password keys failed: %{public}s', (error as Error).message);
      CaaLogin.lastPasswordKeysNote = `qe/sync(http) 异常：${(error as Error).message}`;
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
      'password_contains_non_ascii': CaaLogin.passwordNonAscii,
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
  /**
   * 这次请求打到了哪个域名（空 = 没记录）。
   *
   * 为什么记它：2FA 那几个 app 在两个域名上行为不同（一个空载荷、一个有载荷），真机失败时
   * "哪一步打到了哪个域名"就是判断依据 —— 诊断里带上它，比只有状态码有用得多。
   */
  host: string = '';
  /** 响应头（脱敏后的 JSON 文本；429 时"为什么被拒"只能从这里看）。 */
  headersText: string = '';

  constructor(status: number, body: string, host: string = '') {
    this.status = status;
    this.body = body;
    this.host = host;
  }
}

/** 解析出来的登录成果。 */
class CaaLoginPayload {
  readonly cookie: string;
  readonly authorization: string;
  /** 响应头里的会话材料（见 CaaResult 里同名字段的说明）。 */
  readonly mid: string;
  readonly rur: string;
  readonly claim: string;

  constructor(cookie: string, authorization: string, mid: string = '', rur: string = '',
              claim: string = '') {
    this.cookie = cookie;
    this.authorization = authorization;
    this.mid = mid;
    this.rur = rur;
    this.claim = claim;
  }
}

/** 布局里一对键值（值可能是字面量，也可能是嵌套表达式）。 */
export class CaaMapEntry {
  readonly key: string;
  readonly value: string;

  constructor(key: string, value: string) {
    this.key = key;
    this.value = value;
  }
}

/** IG 在布局里给出的"下一步调用规范"：调哪个 app、带什么参数。 */
export class CaaCallSpec {
  readonly appId: string;
  readonly serverParams: Record<string, string>;
  readonly clientParams: Record<string, string>;

  constructor(appId: string, serverParams: Record<string, string>,
              clientParams: Record<string, string>) {
    this.appId = appId;
    this.serverParams = serverParams;
    this.clientParams = clientParams;
  }
}
