#!/usr/bin/env node
/*
 * **ArkTS 移植一致性审计**：`node tools/relay/audit-arkts-parity.js`
 *
 * 为什么要这条：JS 版（`caa-login.js`）已跟 instagrapi 3.2.2 逐字段对齐、并有离线自检
 * （test-caa-parse.js）兜着；ArkTS 版（`CaaLogin.ets`）是真机才跑得到的移植 —— **字段少一个、
 * 名字拼错一个，IG 就会换个判据**，常见表现是"同样的密码，脚本能登、App 里登不上"。
 *
 * 做法：把两边每个请求体的**键集合**抠出来比一遍（JS 用裸键、ArkTS 用引号键，两种都抽）。
 *   · 「只在 JS 里有」= **需要处理**（ArkTS 少发了字段）；
 *   · 「只在 ArkTS 里有」= 多半是局部变量名（`entryParams` 之类），只作提示。
 * 这是启发式工具（按锚点切块），不是形式化证明 —— 输出要人看一眼。
 */

'use strict';

const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const JS_FILE = path.join(DIR, 'caa-login.js');
const ARKTS_FILE = path.join(DIR, '..', '..', 'entry', 'src', 'main', 'ets', 'core',
  'mobileapi', 'CaaLogin.ets');

/** 取 `start` 之后、`end` 之前的片段（end 为 null 时取到结尾）。 */
function slice(text, start, end) {
  const from = text.indexOf(start);
  if (from < 0) {
    return '';
  }
  if (end === null) {
    return text.slice(from);
  }
  const to = text.indexOf(end, from + start.length);
  return to < 0 ? text.slice(from) : text.slice(from, to);
}

/** 多段拼起来（ArkTS 有时把参数拆在几个方法里）。 */
function sliceAll(text, anchors) {
  return anchors.map((pair) => slice(text, pair[0], pair[1])).join('\n');
}

/** 抽块里的键名：引号键、`obj['key'] = …`（ArkTS 逐字段搭），以及抠掉字面量后的裸键。 */
function keysOf(chunk) {
  const out = new Set();
  const quoted = /['"]([A-Za-z0-9_]+)['"]\s*:/g;
  let match = quoted.exec(chunk);
  while (match !== null) {
    out.add(match[1]);
    match = quoted.exec(chunk);
  }
  // `oauth['client_input_params'] = oauthClient;` 这种逐字段赋值
  const bracketed = /\[['"]([A-Za-z0-9_]+)['"]\]/g;
  match = bracketed.exec(chunk);
  while (match !== null) {
    out.add(match[1]);
    match = bracketed.exec(chunk);
  }
  const stripped = chunk
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
  const bare = /(?:^|[^A-Za-z0-9_.'"])([A-Za-z_][A-Za-z0-9_]*)\s*:/g;
  match = bare.exec(stripped);
  while (match !== null) {
    out.add(match[1]);
    match = bare.exec(stripped);
  }
  // `ensureNulls(params, ['a','b'], ['c'])`：这些键是**按名字补 null**，也要算进键集合。
  const ensure = /ensureNulls\(([\s\S]*?)\);/g;
  let call = ensure.exec(chunk);
  while (call !== null) {
    const inner = /['"]([A-Za-z0-9_]+)['"]/g;
    let hit = inner.exec(call[1]);
    while (hit !== null) {
      out.add(hit[1]);
      hit = inner.exec(call[1]);
    }
    call = ensure.exec(chunk);
  }
  ['Record', 'Array', 'function', 'const', 'let', 'new', 'return', 'Object'].forEach((word) => {
    out.delete(word);
  });
  return out;
}

/**
 * 不是 payload 字段的键（两边都可能有，属于返回值/局部结构）。
 * 例如 JS 的 `return { loggedIn, reason, raw }` 在 ArkTS 里是 `CaaResult` 的字段。
 */
const NOT_PAYLOAD = new Set([
  'loggedIn', 'reason', 'raw', 'parsed', 'aac', 'cookies', 'authorization', 'twoStepContext',
  'steps', 'status', 'step', 'ok', 'needsCode', 'cookie', 'body', 'headerOf', 'text', 'value',
  'name', 'username', 'identity', 'extra', 'password', 'encryptedPassword', 'waterfallId',
  'textInputId',
  // 局部变量 / 候选列表（不是 payload 字段）
  'backupCandidates', 'selectCandidates', 'verifyCandidates', 'entryCandidates', 'pickerCandidates',
  'normalized', 'challenge', 'context', 'spec', 'specs', 'logger'
]);

const SECTIONS = [
  {
    name: 'device network info',
    js: [['function networkInfo() {', '\n}\n']],
    arkts: [['private static networkInfo(): Record<string, ESObject> {', '\n  }\n']]
  },
  {
    name: '取 aac（process_client_data 的入参）',
    js: [['const processData = await bloksAsyncAction(', 'const aac = extractAac(']],
    arkts: [['const processData: Record<string, ESObject> = {', 'const aac: string = CaaLogin.extractAac(']]
  },
  {
    name: 'oauth token fetch',
    js: [['const oauth = await bloksAsyncAction(', "steps.push({ step: 'oauth_token_fetch'"]],
    arkts: [['const loisSettings', 'const step4: CaaHttpReply']]
  },
  {
    name: 'send_login_request（client + server）',
    js: [['const send = await bloksAsyncAction(', "steps.push({ step: 'send_login_request'"]],
    // ArkTS 把它拆成了：登录方法里的装配（`send['client_input_params'] = …`）+ 两个独立构造函数
    arkts: [
      ['const sendClient: Record<string, ESObject> =', 'const sendExtra: Record<string, string> = {};'],
      ['private static sendClientParams(', null]
    ]
  },
  {
    name: '2SV（entrypoint / code_entry / submit_code）',
    js: [['async function resolveTwoStep(', '/* ---------------------------------------------------------------- 主流程 */']],
    arkts: [['private static async resolveTwoStep(', 'private static async bloks(']]
  },
  {
    /*
     * **新版 2FA（context 链）**：真机只在 ArkTS 上跑得到，而 JS 那份已经用真实账号验过。
     * 这一段比的是"每一跳的 client/server 参数键"，缺一个 IG 就可能换判据。
     */
    name: '新版 2FA（context 链，逐跳参数）',
    js: [['async function resolveTwoStepByContext(', 'async function resolveTwoStep(']],
    arkts: [['private static async resolveTwoStepContext(', 'private static async resolveTwoStep(']]
  },
  {
    /*
     * 请求头：两边是**两套独立实现**（JS `headersFor` / ArkTS `MobileRequest.baseHeaders`）。
     * 这一项**有意的差异**是已知的（ArkTS 不发 Accept-Encoding / Host / Connection / X-Zero-Eh，
     * 理由见 MobileRequest.baseHeaders 的注释），所以这里只把差异列出来给人看，不算失败。
     */
    name: '请求头（JS headersFor vs ArkTS baseHeaders + CAA 附加头）',
    js: [['function headersFor(profile, extra) {', '/* ------------------------------------------------------------- USDID']],
    arkts: [
      ['static baseHeaders(identity: MobileIdentity): Record<string, string> {', 'static async send('],
      ['private static headers(identity: MobileIdentity', '/* ---------------------------------------------------------------- 主流程 */']
    ],
    informational: true
  }
];

function main() {
  const jsText = fs.readFileSync(JS_FILE, 'utf8');
  const arktsText = fs.readFileSync(ARKTS_FILE, 'utf8');
  let problems = 0;

  console.log('ArkTS 移植一致性审计（CaaLogin.ets vs caa-login.js）');
  for (const section of SECTIONS) {
    const jsChunk = sliceAll(jsText, section.js);
    const arktsChunk = sliceAll(arktsText, section.arkts);
    if (jsChunk.length === 0 || arktsChunk.length === 0) {
      console.log('\n· ' + section.name + '：**锚点没找到**（JS ' + jsChunk.length
        + ' 字符 / ArkTS ' + arktsChunk.length + ' 字符）');
      problems++;
      continue;
    }
    const jsKeys = keysOf(jsChunk);
    const arktsKeys = keysOf(arktsChunk);
    const missingInArkts = [...jsKeys]
      .filter((key) => !arktsKeys.has(key) && !NOT_PAYLOAD.has(key))
      .sort();
    const extraInArkts = [...arktsKeys].filter((key) => !jsKeys.has(key)).sort();
    if (missingInArkts.length === 0) {
      console.log('\n· ' + section.name + '：字段齐全（JS ' + jsKeys.size + ' / ArkTS '
        + arktsKeys.size + '）');
      if (extraInArkts.length > 0) {
        console.log('    提示（ArkTS 多出来的，多半是局部变量）：' + extraInArkts.join(', '));
      }
      continue;
    }
    if (section.informational === true) {
      console.log('\n· ' + section.name + '：差异如下（这一项只作提示，不算失败）');
      console.log('    只在 JS 里有：' + missingInArkts.join(', '));
      if (extraInArkts.length > 0) {
        console.log('    只在 ArkTS 里有：' + extraInArkts.join(', '));
      }
      continue;
    }
    problems++;
    console.log('\n· ' + section.name + '：**ArkTS 少了字段**');
    console.log('    ' + missingInArkts.join(', '));
    if (extraInArkts.length > 0) {
      console.log('    提示（ArkTS 多出来的）：' + extraInArkts.join(', '));
    }
  }

  console.log('');
  console.log(problems === 0 ? '结论：ArkTS 侧字段齐全' : '结论：' + problems + ' 处需要处理');
  process.exit(problems === 0 ? 0 : 1);
}

main();
