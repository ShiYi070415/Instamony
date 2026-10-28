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
const dumpFile = process.argv[2] ? path.resolve(process.argv[2])
  : path.join(DIR, '.tmp', 'caa-last-response.json');

const source = fs.readFileSync(ETS, 'utf8');

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
    .replace(/:\s*CaaCallSpec/g, '')
    .replace(/:\s*CaaCallSpec\s*\|\s*null/g, '')
    .replace(/:\s*RegExpExecArray\s*\|\s*null/g, '')
    .replace(/:\s*RegExpExecArray/g, '')
    .replace(/:\s*RegExp/g, '')
    .replace(/:\s*boolean/g, '')
    .replace(/:\s*number/g, '')
    .replace(/:\s*string/g, '')
    .replace(/\s+as\s+Record<string,\s*ESObject>/g, '')
    .replace(/\s+as\s+Array<[^>]+>/g, '')
    .replace(/\s+as\s+ESObject/g, '')
    .replace(/\s+as\s+string/g, '')
    .replace(/\s+as\s+number/g, '')
    .replace(/\breadonly\s+/g, '');
}

/** 把方法拼成 `CaaLogin.name = function(params) {…}`。 */
function toFunction(name) {
  const method = extractMethod(name);
  const head = stripTypes(method.head).trim();
  // head 形如 `name(text, start)`：从 name 之后取到最后一个 `)`，**含左括号**
  const params = head.substring(name.length, head.lastIndexOf(')') + 1);
  return `CaaLogin.${name} = function${params} ${stripTypes(method.body)};`;
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
  // 类方法
  toFunction('jsonStringAt'),
  toFunction('parseCookieHeader'),
  toFunction('loginPayloadFromText'),
  toFunction('lispyMapEntries'),
  toFunction('lispyPairMap'),
  toFunction('paramsFromFma'),
  toFunction('nextCallSpecs'),
  toFunction('pickCallSpec'),
  toFunction('findValueDeep'),
  toFunction('twoStepContextOf')
].join('\n');
vm.runInContext(script, sandbox);
const Ark = sandbox.CaaLogin;

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

if (fs.existsSync(dumpFile)) {
  check('真实响应（' + path.basename(dumpFile) + '）：ArkTS 版能解析出会话', () => {
    const dump = JSON.parse(fs.readFileSync(dumpFile, 'utf8'));
    const raw = dump.raw !== undefined && dump.raw !== null ? dump.raw : dump;
    // 与 JS 版同样遍历所有字符串
    const strings = [];
    (function collect(value) {
      if (typeof value === 'string') strings.push(value);
      else if (Array.isArray(value)) value.forEach(collect);
      else if (value && typeof value === 'object') Object.values(value).forEach(collect);
    })(raw);
    let hit = null;
    for (const text of strings) {
      const parsed = Ark.loginPayloadFromText(text);
      if (parsed !== null) {
        hit = parsed;
        break;
      }
    }
    assert(hit !== null, 'ArkTS 版在真实响应里没解析出会话');
    assert(hit.cookie.indexOf('sessionid=') >= 0, 'ArkTS 版解析出的 cookie 里没有 sessionid');
    assert(hit.authorization.indexOf('Bearer IGT:2:') === 0, 'ArkTS 版解析出的 authorization 不对');
    console.log('      （cookie：' + hit.cookie.split(';').map((one) => one.split('=')[0].trim()).join(',')
      + '；authorization ' + hit.authorization.length + ' 字符）');
  });
} else {
  console.log('  · 跳过"真实响应"一项：没有 ' + dumpFile);
}

const sendDump = path.join(DIR, '.tmp', 'caa-send-response.json');
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
