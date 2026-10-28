#!/usr/bin/env node
/*
 * **把 App 里的 ArkTS 解析源码摘出来跑一遍**：`node test-arkts-parsers.js [dump.json]`
 *
 * 为什么要这么干：App 那份解析器只能在真机上跑，而它恰恰是两次真机失败的现场
 * （Cookie 按 `\r\n` 分行、载荷被日志文本挡住）。这轮把 `CaaLogin.ets` 里**三个纯函数**
 * 原样摘出来（去掉类型注解即可在 Node 里跑），喂**真实响应**，再与已验证的 JS 版比对结果。
 *
 * 这不是"另写一份测试"——代码文本直接来自 .ets 文件，所以它验证的是 App 里那段源码本身。
 * 局限：只摘纯函数（不碰 HarmonyOS kit 的调用）；类型注解靠正则剥，函数签名变化时这里要跟着改。
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const DIR = __dirname;
const ETS = path.join(DIR, '..', '..', 'entry', 'src', 'main', 'ets', 'core', 'mobileapi',
  'CaaLogin.ets');
const ETS_SESSION = path.join(DIR, '..', '..', 'entry', 'src', 'main', 'ets', 'core', 'mobileapi',
  'CaaSession.ets');
const dumpFile = process.argv[2] ? path.resolve(process.argv[2])
  : path.join(DIR, '.tmp', 'caa-last-response.json');

let source = fs.readFileSync(ETS, 'utf8');

/** 从 .ets 里摘出一个方法/函数体（括号平衡）。`private static` 与模块级 `function` 都支持。 */
function extractMethod(name) {
  const markers = [`private static ${name}(`, `public static ${name}(`, `static ${name}(`,
    `export function ${name}(`, `function ${name}(`];
  let at = -1;
  let prefix = '';
  for (const marker of markers) {
    at = source.indexOf(marker);
    if (at >= 0) {
      prefix = marker.substring(0, marker.length - name.length - 1);
      break;
    }
  }
  if (at < 0) {
    throw new Error('找不到 ' + name + '（签名改了？）');
  }
  const bodyStart = source.indexOf('{', at);
  if (bodyStart < 0) {
    throw new Error(name + ' 没有函数体');
  }
  let depth = 0;
  let inString = false;
  let quote = '';
  let escaped = false;
  for (let index = bodyStart; index < source.length; index++) {
    const ch = source.charAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === quote) {
        inString = false;
      }
      continue;
    }
    // 注释必须先跳过：源码注释里就写着 `\"`，不识别注释会被那句"转义引号"带进字符串态。
    if (ch === '/' && source.charAt(index + 1) === '/') {
      const lineEnd = source.indexOf('\n', index);
      index = lineEnd < 0 ? source.length : lineEnd;
      continue;
    }
    if (ch === '/' && source.charAt(index + 1) === '*') {
      const blockEnd = source.indexOf('*/', index + 2);
      index = blockEnd < 0 ? source.length : blockEnd + 1;
      continue;
    }
    if (ch === '"' || ch === '\'') {
      inString = true;
      quote = ch;
      continue;
    }
    if (ch === '{') {
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0) {
        const head = source.substring(at, bodyStart);
        return {
          // 去掉 `private static ` / `export function ` 之类前缀，让 head 以 `name(` 开头
          head: head.substring(prefix.length),
          // 注释一起带上（不影响运行，且便于对照）
          body: source.substring(bodyStart, index + 1)
        };
      }
    }
  }
  throw new Error(name + ' 的大括号不配对');
}

/** 剥掉 ArkTS 的类型注解（只处理这套代码里用到的几种）。 */
function stripTypes(text) {
  return text
    .replace(/:\s*Record<[^>]+>/g, '')
    .replace(/:\s*Array<[^>]+>/g, '')
    .replace(/:\s*ESObject/g, '')
    .replace(/:\s*CaaMapEntry/g, '')
    .replace(/:\s*CaaCallSpec\s*\|\s*null/g, '')
    .replace(/:\s*CaaCallSpec/g, '')
    .replace(/:\s*CaaLoginPayload\s*\|\s*null/g, '')
    .replace(/:\s*CaaLoginPayload/g, '')
    .replace(/:\s*RegExpExecArray\s*\|\s*null/g, '')
    .replace(/:\s*RegExpExecArray/g, '')
    .replace(/:\s*RegExp/g, '')
    .replace(/:\s*boolean/g, '')
    .replace(/:\s*number/g, '')
    .replace(/:\s*string/g, '')
    .replace(/\s+as\s+Record<[^>]+>/g, '')
    .replace(/\s+as\s+boolean/g, '')
    .replace(/\s+as\s+number/g, '')
    .replace(/\s+as\s+Array<[^>]+>/g, '')
    .replace(/\s+as\s+ESObject/g, '')
    .replace(/\s+as\s+string/g, '')
    .replace(/\s+as\s+number/g, '')
    .replace(/\breadonly\s+/g, '');
}

/** 把方法拼成 `CaaLogin.name = function(params) {…}`。 */
function toFunction(name) {
  return toFunctionAs('CaaLogin', name);
}

/** 同上，但挂到指定对象上（CaaSession.ets 里的函数用）。 */
function toFunctionAs(target, name) {
  const method = extractMethod(name);
  const head = stripTypes(method.head).trim();
  // head 形如 `name(text, start)`：从 name 之后取到最后一个 `)`，**含左括号**
  const params = head.substring(name.length, head.lastIndexOf(')') + 1);
  return `${target}.${name} = function${params} ${stripTypes(method.body)};`;
}

/** 模块级函数（`bloksParenthesized` / `collectStrings` 这类）挂到沙盒全局上。 */
function toGlobalFunction(name) {
  const method = extractMethod(name);
  const head = stripTypes(method.head).trim();
  const params = head.substring(name.length, head.lastIndexOf(')') + 1);
  return `globalThis.${name} = function${params} ${stripTypes(method.body)};`;
}

const sandbox = { CaaLogin: {}, JSON, RegExp, Set, Array, Object, String };
/*
 * 模块级常量（被摘出来的函数直接用）。值必须与 CaaLogin.ets 里的一致 ——
 * 抄错的后果是"离线全绿、装上才发现没识别"，所以这几行改动时要和 .ets 一起看。
 */
sandbox.AP_2SV_ENTRYPOINT = 'com.bloks.www.ap.two_step_verification.entrypoint_async';
sandbox.AP_2SV_CODE_ENTRY = 'com.bloks.www.ap.two_step_verification.code_entry';
sandbox.AP_2SV_CODE_ENTRY_ASYNC = 'com.bloks.www.ap.two_step_verification.code_entry_async';
sandbox.TSV_ENTRYPOINT = 'com.bloks.www.two_step_verification.entrypoint';
sandbox.LISPY_MAP_HEAD = '(f4i';
sandbox.IG_APP_ID = '567067343352427';
/*
 * 被摘出来的 `loginPayloadFromText` 会 `new CaaLoginPayload(...)`。这个类在 .ets 里是
 * 顺手写在文件末尾的小类，这里按同名字段补一个 —— 少了它构造会抛错，而那个错会被
 * 函数自己的 `catch` 吞掉，于是表现成"解析不出来"（调试了半轮才想到）。
 */
sandbox.CaaLoginPayload = class CaaLoginPayload {
  constructor(cookie, authorization, mid, rur, claim) {
    this.cookie = cookie;
    this.authorization = authorization;
    this.mid = mid === undefined ? '' : mid;
    this.rur = rur === undefined ? '' : rur;
    this.claim = claim === undefined ? '' : claim;
  }
};
// 2FA 规范解析用到的小类，同样按字段补上
sandbox.CaaMapEntry = class CaaMapEntry {
  constructor(key, value) {
    this.key = key;
    this.value = value;
  }
};
sandbox.CaaCallSpec = class CaaCallSpec {
  constructor(appId, serverParams, clientParams) {
    this.appId = appId;
    this.serverParams = serverParams;
    this.clientParams = clientParams;
  }
};
vm.createContext(sandbox);
const script = [
  // 模块级函数（lispy 与字符串收集）
  toGlobalFunction('bloksParenthesized'),
  toGlobalFunction('bloksExpressionItems'),
  toGlobalFunction('collectStrings'),
  toGlobalFunction('bloksAllText'),
  toGlobalFunction('bloksErrorText'),
  toGlobalFunction('bloksNeedsTwoStep'),
  toGlobalFunction('bloksContextValue'),
  // 类方法
  toFunction('parse'),
  toFunction('jsonStringAt'),
  toFunction('parseCookieHeader'),
  // 真机 2026-10：cookie 三形状 + ig-set-* 头还原（loginPayloadFromText 依赖这几个）
  toFunction('cookiesFromRaw'),
  toFunction('cookiesFromSessionHeaders'),
  toFunction('pushCookiePair'),
  toFunction('mergeCookieText'),
  toFunction('pushCookieText'),
  toFunction('loginPayloadFromText'),
  toFunction('lispyMapEntries'),
  toFunction('lispyPairMap'),
  toFunction('paramsFromFma'),
  toFunction('nextCallSpecs'),
  toFunction('pickCallSpec'),
  toFunction('findValueDeep'),
  toFunction('twoStepContextOf'),
  toFunction('normalizeFlags'),
  toFunction('mergeParams'),
  toFunction('ensureNulls'),
  toFunction('loginResponseBool'),
  toFunction('inferChallenge'),
  toFunction('extractAac'),
  toFunction('extractLoginPayload'),
  // App 里那张卡片上的「解析自检」（selfTest）本身也在这里复算 —— 它的结论会显示给用户，
  // 离线先跑一遍就不会出现"装到手机上才知道哪项没过"。
  toFunction('selfTest')
].join('\n');
vm.runInContext(script, sandbox);
const Ark = sandbox.CaaLogin;

/*
 * **第二个文件：CaaSession.ets** —— 负责"把响应变成会话"的那几个纯函数
 * （`cookieValue` / `cookieTextOf` / `authorizationOf` / `textFieldOf`）。
 * 它们依赖 MobileSign 的 `base64` / `utf8`，这里按同样语义补两个桩函数。
 */
sandbox.base64 = (bytes, urlSafe) => Buffer.from(bytes).toString(urlSafe ? 'base64url' : 'base64');
sandbox.utf8 = (text) => Buffer.from(String(text), 'utf8');
sandbox.CaaSession = {};
sandbox.CaaLogin.parse = (text) => {
  try {
    return JSON.parse(text);
  } catch (error) {
    return null;
  }
};
source = fs.readFileSync(ETS_SESSION, 'utf8');
const sessionScript = [
  toFunctionAs('CaaSession', 'textFieldOf'),
  toFunctionAs('CaaSession', 'cookieTextOf'),
  toFunctionAs('CaaSession', 'authorizationOf'),
  toFunctionAs('CaaSession', 'cookieValue')
].join('\n');
vm.runInContext(sessionScript, sandbox);
const Session = sandbox.CaaSession;

let passed = 0;
let failed = 0;
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log('  ✓ ' + name);
  } catch (error) {
    failed++;
    console.log('  ✗ ' + name + '\n      ' + (error && error.message ? error.message : error));
  }
}
function assert(condition, message) {
  if (!condition) {
    throw new Error(message || '断言失败');
  }
}

console.log('ArkTS 解析器直跑（源码来自 CaaLogin.ets）');

check('Cookie：真机格式（\\r\\n + 属性）只取三颗会话 Cookie', () => {
  const raw = 'Set-Cookie: csrftoken=CSRF; Domain=.instagram.com; '
    + 'expires=02-Dec-2027 13:57:44 GMT; Max-Age=31536000; Path=/; Secure\r\n'
    + 'Set-Cookie: ds_user_id=777; Domain=.instagram.com; Path=/; Secure\r\n'
    + 'Set-Cookie: sessionid=777%3Areal; Domain=.instagram.com; HttpOnly; Path=/; Secure';
  const got = Ark.parseCookieHeader(raw);
  assert(got.indexOf('sessionid=777%3Areal') >= 0, 'ArkTS 版丢了 sessionid：' + got);
  assert(got.indexOf('ds_user_id=777') >= 0, 'ArkTS 版丢了 ds_user_id：' + got);
  assert(got.indexOf('Secure') < 0 && got.indexOf('Domain') < 0, 'ArkTS 版把属性当 Cookie：' + got);
});

check('载荷：日志文本挡在前面时仍能解析', () => {
  const inner = JSON.stringify({
    login_response: JSON.stringify({ logged_in_user: { pk: 777 } }),
    headers: JSON.stringify({ 'IG-Set-Authorization': 'Bearer IGT:2:REAL' }),
    cookies: 'Set-Cookie: sessionid=777%3Areal; Path=/; Secure'
  });
  const trap = '(dey "MAA_LOGIN_FLOW" "[trait:called_handle_login_response] Calling") '
    + '(dsg (fom 15942 35 ' + JSON.stringify(inner) + '))';
  const parsed = Ark.loginPayloadFromText(trap);
  assert(parsed !== null, 'ArkTS 版被日志文本挡住');
  assert(parsed.cookie.indexOf('sessionid=777%3Areal') >= 0, 'ArkTS 版 cookie 不对：' + parsed.cookie);
  assert(parsed.authorization === 'Bearer IGT:2:REAL', 'ArkTS 版 authorization 不对');
});

check('真机形状（与 App 自检⑦同一条）：cookies 是空对象、材料全在 ig-set-* 头里', () => {
  const inner = JSON.stringify({
    login_response: JSON.stringify({ logged_in_user: { pk: 46473815227 }, status: 'ok' }),
    headers: JSON.stringify({
      'IG-Set-Authorization': 'Bearer IGT:2:DEVICE',
      'ig-set-ig-u-ds-user-id': '46473815227',
      'ig-set-ig-u-rur': 'KND',
      'x-ig-set-www-claim': 'hmac.AAAA'
    }),
    cookies: {}
  });
  const text = '(dsg (fom 15942 35 ' + JSON.stringify(inner) + '))';
  const parsed = Ark.loginPayloadFromText(text);
  assert(parsed !== null, 'ArkTS 版把"cookies 空对象"判成没登录结果');
  assert(parsed.cookie.indexOf('ds_user_id=46473815227') >= 0, '账号 id 没从头里还原：' + parsed.cookie);
  assert(parsed.cookie.indexOf('rur=KND') >= 0, 'rur 没从头里还原：' + parsed.cookie);
  assert(parsed.authorization === 'Bearer IGT:2:DEVICE', 'authorization 不对');
});

check('cookies 是对象 / 数组时也能取（ArkTS 与 JS 同形状）', () => {
  const asObject = JSON.stringify({
    login_response: JSON.stringify({ status: 'ok' }),
    headers: '{}',
    cookies: { sessionid: '777%3Aabc', ds_user_id: '777' }
  });
  const one = Ark.loginPayloadFromText('(x ' + JSON.stringify(asObject) + ')');
  assert(one !== null && one.cookie.indexOf('sessionid=777%3Aabc') >= 0, '对象形状没认');

  const asArray = JSON.stringify({
    login_response: JSON.stringify({ status: 'ok' }),
    headers: '{}',
    cookies: [{ name: 'ds_user_id', value: '777' }, 'csrftoken=xyz']
  });
  const two = Ark.loginPayloadFromText('(x ' + JSON.stringify(asArray) + ')');
  assert(two !== null, '数组形状没认');
  assert(two.cookie.indexOf('ds_user_id=777') >= 0 && two.cookie.indexOf('csrftoken=xyz') >= 0,
    '数组元素没解出来：' + two.cookie);
});

/** 从 dump 里解析出来的成功载荷（没有就是 null；后面"两个文件接力"那项要用）。 */
let dumpPayload = null;

if (fs.existsSync(dumpFile)) {
  /*
   * 注意：`caa-last-response.json` 是**易变的**（每次登录失败都会覆盖；我用假账号跑回归时
   * 也会覆盖它）。所以这份响应里没有会话时**跳过**而不是判失败 —— 否则测试会因为
   * "上一次跑的是假账号"而红。
   */
  const dump = JSON.parse(fs.readFileSync(dumpFile, 'utf8'));
  const rawDump = dump.raw !== undefined && dump.raw !== null ? dump.raw : dump;
  const dumpStrings = [];
  (function collect(value) {
    if (typeof value === 'string') dumpStrings.push(value);
    else if (Array.isArray(value)) value.forEach(collect);
    else if (value && typeof value === 'object') Object.values(value).forEach(collect);
  })(rawDump);
  let hitPayload = null;
  for (const text of dumpStrings) {
    const parsed = Ark.loginPayloadFromText(text);
    if (parsed !== null) {
      hitPayload = parsed;
      break;
    }
  }
  dumpPayload = hitPayload;
  if (dumpPayload === null) {
    console.log('  · 跳过"真实响应"两项：' + path.basename(dumpFile)
      + ' 里没有成功会话（可能上次跑的是假账号 / 失败响应）');
  } else {
    check('真实响应（' + path.basename(dumpFile) + '）：ArkTS 版能解析出会话', () => {
      // 真机 2026-10：载荷 `cookies` 是空对象，会话材料全在 `ig-set-*` 头里 →
      // cookie 里可能**没有** sessionid（设备级会话），但必须有 ds_user_id 与 rur。
      const hasUid = dumpPayload.cookie.indexOf('ds_user_id=') >= 0;
      assert(hasUid, 'ArkTS 版解析出的 cookie 里没有账号 id：' + dumpPayload.cookie);
      assert(dumpPayload.authorization.indexOf('Bearer IGT:2:') === 0, 'authorization 形状不对');
      console.log('      （cookie：'
        + dumpPayload.cookie.split(';').map((one) => one.split('=')[0].trim()).join(',')
        + '；authorization ' + dumpPayload.authorization.length + ' 字符）');
    });
  }
} else {
  console.log('  · 跳过"真实响应"一项：没有 ' + dumpFile);
}

check('2FA 参数拼装：normalizeFlags 把规范里的字符串还原成正确类型', () => {
  const out = Ark.normalizeFlags({
    'should_fallback_to_sms': 'false',
    'is_whatsapp_installed': '0',
    'device_id': 'ANDROID-1',
    'INTERNAL_INFRA_screen_id': '6d6cez:3',
    'two_step_verification_context': 'A'.repeat(2000)
  });
  assert(out['should_fallback_to_sms'] === false, 'false 没还原成布尔');
  assert(out['is_whatsapp_installed'] === 0, '0 没还原成数字');
  assert(out['device_id'] === 'ANDROID-1', '设备 id 被改了');
  assert(out['INTERNAL_INFRA_screen_id'] === '6d6cez:3', 'screen_id 被改了');
  assert(String(out['two_step_verification_context']).length === 2000, '长票据被截断');
});

check('2FA 参数拼装：mergeParams 用规范覆盖默认值，缺的保留默认', () => {
  const merged = Ark.mergeParams(
    { 'should_fallback_to_sms': '0', 'device_id': 'DEFAULT-DEV', 'flow_source': 'two_factor_login' },
    { 'should_fallback_to_sms': 'false', 'family_device_id': 'PHONE-1' });
  assert(merged['should_fallback_to_sms'] === false, '规范里的值没覆盖默认');
  assert(merged['device_id'] === 'DEFAULT-DEV', '默认值被丢了');
  assert(merged['family_device_id'] === 'PHONE-1', '规范里多出来的键没合并进来');
});

check('2FA 参数拼装：ensureNulls 把 IG 要 null 的三个字段补成 null', () => {
  const params = {};
  params['client_input_params'] = { 'selected_method': 'totp' };
  params['server_params'] = { 'device_id': 'D' };
  Ark.ensureNulls(params, ['cloud_trust_token', 'network_bssid'], ['spectra_reg_login_data']);
  assert(params['client_input_params']['cloud_trust_token'] === null, 'client 的 null 没补上');
  assert(params['client_input_params']['network_bssid'] === null, 'client 的 null 没补上');
  assert(params['server_params']['spectra_reg_login_data'] === null, 'server 的 null 没补上');
  assert(params['client_input_params']['selected_method'] === 'totp', '已有字段被动了');
});

check('2FA 方式推断：8 位→备用码；只开短信→sms；其余→totp', () => {
  /*
   * 注意：**真机的 send 响应里没有** `sms_two_factor_on` / `totp_two_factor_on` 这两个键
   * （R12 实测，整份响应里都找不到）——所以实际走的就是默认 `totp`，而那次是成功的。
   * 这里用 findValueDeep 支持的形状（键直接挂在对象/JSON 文本上）覆盖这些分支。
   */
  const smsOnly = { login_response: JSON.stringify({ sms_two_factor_on: true, totp_two_factor_on: false }) };
  const both = { login_response: JSON.stringify({ sms_two_factor_on: true, totp_two_factor_on: true }) };
  assert(Ark.inferChallenge({}, '12345678') === 'backup_codes', '8 位数字应判成备用码');
  assert(Ark.inferChallenge(smsOnly, '123456') === 'sms', '只开短信应判成 sms');
  assert(Ark.inferChallenge(both, '123456') === 'totp', '两个都开应判成 totp');
  assert(Ark.inferChallenge({}, '123456') === 'totp', '默认应为 totp');
});

check('会话落地（CaaSession.ets）：cookieValue / cookieTextOf / authorizationOf', () => {
  // cookieValue：从 `name=value; …` 里取一颗
  const cookie = 'csrftoken=CSRF; ds_user_id=46473815227; sessionid=46473815227%3Aabc';
  assert(Session.cookieValue(cookie, 'sessionid') === '46473815227%3Aabc', 'sessionid 取值不对');
  assert(Session.cookieValue(cookie, 'ds_user_id') === '46473815227', 'ds_user_id 取值不对');
  assert(Session.cookieValue(cookie, 'nope') === '', '取不到的键应回空串');
  // cookieTextOf：两种输入形状
  assert(Session.cookieTextOf({ cookie }) === cookie, 'cookie 串形状没原样返回');
  assert(Session.cookieTextOf({ cookies: { a: '1', b: '2' } }) === 'a=1; b=2', 'cookies 映射没拼成串');
  // authorizationOf：直接给串 vs 给 authorization_data
  const auth = 'Bearer IGT:2:' + Buffer.from(JSON.stringify({ ds_user_id: '1' })).toString('base64');
  assert(Session.authorizationOf({ authorization: auth }) === auth, 'authorization 串没原样返回');
  const rebuilt = Session.authorizationOf({ authorization_data: { ds_user_id: '1' } });
  assert(rebuilt === auth, 'authorization_data 拼回的串与原始不一致：' + rebuilt);
});

check('取 aac：initial 与 initial_lispy 两种形状都要能取（与 JS 版对齐）', () => {
  const withInitial = JSON.stringify({ layout: { bloks_payload: { data: [
    { data: { key: 'CAA_ACCOUNT_ACCESS_CONTEXT:aac', initial: 'AAC-INITIAL' } }
  ] } } });
  assert(Ark.extractAac(withInitial) === 'AAC-INITIAL', 'initial 形状没取到');
  const withLispy = JSON.stringify({ layout: { bloks_payload: { data: [
    { data: { key: 'CAA_ACCOUNT_ACCESS_CONTEXT:aac',
      initial_lispy: '\t(e1z (ii9) "AAC-FROM-LISPY")' } }
  ] } } });
  assert(Ark.extractAac(withLispy) === 'AAC-FROM-LISPY',
    'initial_lispy 形状没取到（这就是 App 报"没拿到 aac"的原因）：' + JSON.stringify(Ark.extractAac(withLispy)));
  const none = JSON.stringify({ layout: { bloks_payload: { data: [] } } });
  assert(Ark.extractAac(none) === '', '空布局不该给出 aac');
});

/*
 * **App 卡片上那个「解析自检」的离线复算**。
 *
 * 为什么值得一条：它是用户唯一能看懂的结论（自检通过/未通过哪项），而它只能在手机上点。
 * 装包前先在这跑一遍，就不会出现"装上去才发现哪项没过"，也不用为了看失误项再发一次登录。
 */
check('App 自检（selfTest）离线复算：应报 7/7 通过', () => {
  const verdict = Ark.selfTest();
  assert(verdict.indexOf('7/7 通过') >= 0, '自检结论：' + verdict);
});

/*
 * **导入那条路**：密码登录被限流（429）时，用户靠「用已有会话导入」把电脑上的
 * `settings.caa.json` 粘进来救场 —— 那份是**设备级会话**（没有 sessionid）。
 * 这里用 App 自己的三个纯函数验证它认得这种文件。
 */
check('导入设备级 settings.caa.json：cookieTextOf / authorizationOf / cookieValue 都认', () => {
  const settings = {
    cookies: { ds_user_id: '46473815227', 'ig-u-ds-user-id': '46473815227',
      rur: 'KND', 'ig-u-rur': 'KND', 'ig-u-www-claim': 'hmac.AAAA' },
    uuids: { phone_id: 'p', uuid: 'u', android_device_id: 'android-a' },
    authorization_data: { ds_user_id: '46473815227', sessionid: '' },
    mid: 'MID-1'
  };
  const cookie = Session.cookieTextOf(settings);
  assert(cookie.indexOf('ds_user_id=46473815227') >= 0, 'cookieTextOf 没拼出 Cookies：' + cookie);
  const authorization = Session.authorizationOf(settings);
  assert(authorization.indexOf('Bearer IGT:2:') === 0, 'authorizationOf 没从 authorization_data 重建');
  assert(Session.cookieValue(cookie, 'ds_user_id') === '46473815227', 'cookieValue 取不到账号');
  assert(Session.cookieValue(cookie, 'sessionid') === '',
    '设备级会话不该凭空有 sessionid');
});

const sendDump = path.join(DIR, '.tmp', 'caa-send-response.json');
if (dumpPayload !== null) {
  check('真实响应 → 会话字段（两个文件的源码接力）：ds_user_id / authorization /（有就）sessionid',
    () => {
      const payload = dumpPayload;
      const sessionid = Session.cookieValue(payload.cookie, 'sessionid');
      const userId = Session.cookieValue(payload.cookie, 'ds_user_id');
      assert(userId.length > 0, 'ds_user_id 空');
      // 设备级会话允许没有 sessionid（IG 2026-10 起下发这种），但 authorization 必须有。
      assert(sessionid.length > 0 || payload.authorization.length > 0,
        '既没有 sessionid 也没有 authorization');
      assert(Session.cookieTextOf({ cookie: payload.cookie }) === payload.cookie,
        'cookieTextOf 没原样返回载荷里的 cookie');
      assert(payload.authorization.indexOf('Bearer IGT:2:') === 0, 'authorization 形状不对');
      console.log('      （sessionid ' + sessionid.length + ' 字符，uid ' + userId
        + '，authorization ' + payload.authorization.length + ' 字符）');
    });
}
if (fs.existsSync(sendDump)) {
  check('真实 send 响应：ArkTS 版读出的 2FA 规范与 JS 版一致（长票据 + app id）', () => {
    const dump = JSON.parse(fs.readFileSync(sendDump, 'utf8'));
    const raw = dump.raw !== undefined && dump.raw !== null ? dump.raw : dump;
    const specs = Ark.nextCallSpecs(raw);
    assert(specs.length > 0, 'ArkTS 版没读到任何调用规范');
    let arkCtx = '';
    for (const spec of specs) {
      const value = spec.serverParams['two_step_verification_context'];
      if (typeof value === 'string' && value.length > arkCtx.length) {
        arkCtx = value;
      }
    }
    assert(arkCtx.length > 100, 'ArkTS 版票据太短：' + arkCtx.length);
    const spec = Ark.pickCallSpec(specs, ['two_step', 'two_factor']);
    assert(spec !== null && spec.appId.indexOf('two_step_verification') >= 0,
      'ArkTS 版没挑出 2FA app：' + (spec === null ? 'null' : spec.appId));

    // 与已验证的 JS 实现比对（同一份数据、两套源码，结果必须一致）
    const js = require('./caa-login.js');
    const jsCtx = js.twoStepContextOf(raw);
    assert(arkCtx === jsCtx, 'ArkTS 与 JS 的票据不一致（Ark ' + arkCtx.length
      + ' / JS ' + jsCtx.length + '）');
    const jsSpec = js.pickCallSpec(js.nextCallSpecs(raw), ['two_step', 'two_factor']);
    assert(jsSpec !== null && jsSpec.appId === spec.appId, 'ArkTS 与 JS 选出的 app 不一致');
    console.log('      （票据 ' + arkCtx.length + ' 字符，app=' + spec.appId
      + '，与 JS 版完全一致）');
  });
} else {
  console.log('  · 跳过"2FA 规范"一项：没有 ' + sendDump);
}

console.log('');
console.log('通过 ' + passed + '，失败 ' + failed);
if (failed > 0) {
  process.exit(1);
}
