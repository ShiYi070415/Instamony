/*
 * 把 WebScripts.ets 里**注入网页的 JS 片段**逐个拼出来做语法检查。
 *
 * 为什么必须做：这些脚本是"TS 字符串拼出来的 JS"，TS 编译器只检查字符串本身 ——
 * 里面少一个引号、多一个加号照样编得过，但注入网页后是**语法错误**：脚本永远不返回，
 * 桥那侧只能干等到超时（state=timeout）。评论读取"一直超时"的真凶就是一个多余的 `+`
 * （拼成 `wait++"`），在近两千行里肉眼根本翻不出来。
 *
 * 用法：node tools/check-injected-js.js
 *   - 逐个 `const XXX: string = '...' + ...;` 片段：求值 + JS 语法检查（这是主力）；
 *   - `export const XXX: string = ...` 同样处理；
 *   - 函数里 `return '...' + ...;` 的脚本因为依赖局部变量，这里只求值不了就跳过（不算错）。
 */
const fs = require('fs');

const path = 'entry/src/main/ets/bridge/WebScripts.ets';
const src = fs.readFileSync(path, 'utf8');

/** 取从 from 开始、到第一个"顶层"分号为止的表达式文本（跳过字符串与括号内部）。 */
function takeExpression(text, from) {
  let depth = 0;
  let quote = '';
  for (let i = from; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === '\\') { i++; continue; }
      if (c === quote) { quote = ''; }
      continue;
    }
    if (c === "'" || c === '"' || c === '`') { quote = c; continue; }
    if (c === '(' || c === '[' || c === '{') { depth++; continue; }
    if (c === ')' || c === ']' || c === '}') { depth--; continue; }
    if (c === ';' && depth === 0) { return text.slice(from, i); }
  }
  return '';
}

/** 去掉开头的注释与空白（片段常先写一段 // 说明再拼字符串）。 */
function stripLeading(text) {
  return text.replace(/^\s*(\/\/[^\n]*\n\s*)*/, '');
}

/** 模块级字符串常量：先求值，供后面的片段拼接时当桩。 */
const scope = {
  PROXY: 'ogNative',
  codeLiteral: '"stub"',
  nameLiteral: '"stub"',
  opLiteral: '"stub"',
  filterLiteral: '"stub"',
  cfgLiteral: '{}',
  cursorLiteral: '""',
  varsLiteral: '{}',
  mediaLiteral: '"stub"',
  items: 1, cap: 1, count: 1, maxItems: 1, maxBody: 1, maxBytes: 1, inboxOnly: true
};

const problems = [];
let checked = 0;
let skipped = 0;

function check(name, js) {
  if (typeof js !== 'string' || !/(function|=>)/.test(js)) { skipped++; return; }
  checked++;
  try {
    new Function(js);
  } catch (e) {
    let where = '';
    const mm = /(\d+)/.exec(e.message);
    if (mm) {
      const at = Number(mm[1]);
      where = '\n      @' + at + ' … ' + js.slice(Math.max(0, at - 80), at + 60);
    }
    problems.push(`${name} [JS-SYNTAX-ERROR] ${e.message}${where}`);
  }
}

// ---- 1) 所有 `const NAME: string = ...`（含 export）----
const constRe = /(?:^|\n)(?:export )?const (\w+): string =[ \t]*/g;
let cm;
while ((cm = constRe.exec(src)) !== null) {
  const name = cm[1];
  const raw = stripLeading(takeExpression(src, cm.index + cm[0].length)).trim();
  if (raw.length === 0 || raw.indexOf("'") !== 0) { skipped++; continue; }
  let js = '';
  try {
    js = eval(raw);
  } catch (e) {
    // 依赖其它常量（顺序问题）或依赖局部变量时跳过，不当作错误。
    skipped++;
    continue;
  }
  scope[name] = js;
  check(name, js);
}

// ---- 2) 函数里 `return '...' + ...;` 的脚本（用桩求值，能求出来就检查）----
const fnRe = /export function (\w+)/g;
const marks = [];
let fm;
while ((fm = fnRe.exec(src)) !== null) { marks.push({ name: fm[1], at: fm.index }); }
for (let i = 0; i < marks.length; i++) {
  const mark = marks[i];
  const end = i + 1 < marks.length ? marks[i + 1].at : src.length;
  const block = src.slice(mark.at, end);
  const ret = block.indexOf('return ');
  if (ret < 0) { continue; }
  const raw = stripLeading(takeExpression(src, mark.at + ret + 7)).trim();
  if (raw.length === 0 || raw.indexOf("'") !== 0) { skipped++; continue; }
  const keys = Object.keys(scope);
  let js = '';
  try {
    // eslint-disable-next-line no-new-func
    const fn = new Function(...keys, 'return (' + raw + ');');
    js = fn(...keys.map((k) => scope[k]));
  } catch (e) {
    skipped++;
    continue;
  }
  check(mark.name, js);
}

if (problems.length === 0) {
  console.log(`OK — 检查 ${checked} 个注入脚本片段，JS 语法全部通过（跳过 ${skipped} 个需要桩的）`);
} else {
  console.log(`发现 ${problems.length} 个问题（检查了 ${checked} 个片段）：`);
  for (const p of problems) { console.log('  ' + p); }
  process.exitCode = 1;
}
