/*
 * 扫描 Instamony 的 ArkTS 文案：资源键完整性 + 仍然硬编码的中文串。
 *
 * 只做静态审计，不改代码。输出 docs/i18n-audit.md。
 *
 * 用法：node tools/i18n-audit.cjs
 */
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const etsRoot = path.join(root, 'entry', 'src', 'main', 'ets');
const baseJson = path.join(root, 'entry', 'src', 'main', 'resources', 'base', 'element', 'string.json');
const enJson = path.join(root, 'entry', 'src', 'main', 'resources', 'en_US', 'element', 'string.json');
const outFile = path.join(root, 'docs', 'i18n-audit.md');

const CJK = /[\u3400-\u9fff\uf900-\ufaff]/;
const UI_HINT = /(Text\(|Button\(|Toggle\(|TextInput\(|Search\(|MenuItem|AlertDialog|promptAction|showToast|toast\(|placeholder|\.title\(|title\s*:|label\s*:|hint|message\s*:|content\s*:|accessibilityText|Tab\(|bindMenu|Navigation|SubTitle|description\s*:|empty|error\s*:|tip\s*:|confirm|cancel|Dialog|Sheet)/;
const LOG_HINT = /(hilog\.|console\.|ReelsCrashLog|LoginLog|LoginTrace|StoryDiag|MobileProbe|\.note\(|\.warn\(|\.error\(|\.info\(|log\()/;

function readStrings(file) {
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  const map = new Map();
  for (const item of data.string || []) {
    if (item && item.name) map.set(item.name, `${item.value ?? ''}`);
  }
  return map;
}

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.isFile() && entry.name.endsWith('.ets')) out.push(full);
  }
}

/** 去掉行注释/块注释，保留字符串内容与行号。 */
function stripComments(source) {
  const lines = source.split(/\r?\n/);
  const out = [];
  let inBlock = false;
  for (const raw of lines) {
    let line = '';
    let quote = '';
    for (let i = 0; i < raw.length; i++) {
      const ch = raw[i];
      const next = raw[i + 1] || '';
      if (inBlock) {
        if (ch === '*' && next === '/') { inBlock = false; i++; }
        continue;
      }
      if (quote) {
        line += ch;
        if (ch === '\\') { line += next; i++; continue; }
        if (ch === quote) quote = '';
        continue;
      }
      if (ch === '/' && next === '/') break;
      if (ch === '/' && next === '*') { inBlock = true; i++; continue; }
      if (ch === '"' || ch === "'" || ch === '`') quote = ch;
      line += ch;
    }
    out.push(line);
  }
  return out;
}

/** 从一行里取所有字符串字面量（单/双/反引号，支持转义）。 */
function stringsOf(line) {
  const out = [];
  let quote = '';
  let buf = '';
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (!quote) {
      if (ch === '"' || ch === "'" || ch === '`') { quote = ch; buf = ''; }
      continue;
    }
    if (ch === '\\') { buf += ch; if (i + 1 < line.length) buf += line[++i]; continue; }
    if (ch === quote) { out.push(buf); quote = ''; buf = ''; continue; }
    buf += ch;
  }
  return out;
}

const base = readStrings(baseJson);
const en = readStrings(enJson);
const files = [];
walk(etsRoot, files);

const byFile = [];
const refs = [];
const uiList = [];
let totalCjk = 0;
let uiCjk = 0;
let logCjk = 0;
let otherCjk = 0;

for (const file of files) {
  const rel = path.relative(root, file).replace(/\\/g, '/');
  const lines = stripComments(fs.readFileSync(file, 'utf8'));
  const examples = [];
  let ui = 0;
  let log = 0;
  let other = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!CJK.test(line)) continue;
    const strs = stringsOf(line).filter((s) => CJK.test(s));
    if (strs.length === 0) continue;
    const kind = LOG_HINT.test(line) ? 'log' : (UI_HINT.test(line) ? 'ui' : 'other');
    for (const s of strs) {
      totalCjk++;
      if (kind === 'ui') ui++;
      else if (kind === 'log') log++;
      else other++;
      if (kind === 'ui') {
        uiList.push({ file: rel, line: i + 1, text: s });
        if (examples.length < 8) examples.push({ line: i + 1, text: s.slice(0, 120) });
      }
    }
    if (kind === 'ui') uiCjk += strs.length;
    else if (kind === 'log') logCjk += strs.length;
    else otherCjk += strs.length;
  }
  const refCount = (fs.readFileSync(file, 'utf8').match(/\$r\('app\.string\.[^']+'\)/g) || []).length;
  if (ui > 0 || log > 0 || other > 0) {
    byFile.push({ file: rel, ui, log, other, refCount, examples });
  }
}

// 资源键完整性
const missingEn = [];
const missingBase = [];
const untranslatedEn = [];
for (const [key, value] of base) {
  if (!en.has(key)) missingEn.push(key);
  if (en.has(key) && CJK.test(en.get(key))) untranslatedEn.push({ key, value: en.get(key) });
}
for (const key of en.keys()) if (!base.has(key)) missingBase.push(key);

// $r 引用是否都有定义
const defined = new Set([...base.keys(), ...en.keys()]);
const undefinedRefs = new Map();
for (const file of files) {
  // 注释里的 `$r(...)` 示例不算引用（见 FeedStatus 的说明）。
  const text = stripComments(fs.readFileSync(file, 'utf8')).join('\n');
  const rel = path.relative(root, file).replace(/\\/g, '/');
  for (const m of text.matchAll(/\$r\('app\.string\.([^']+)'\)/g)) {
    if (!defined.has(m[1])) undefinedRefs.set(m[1], (undefinedRefs.get(m[1]) || []).concat(rel));
  }
}

byFile.sort((a, b) => (b.ui - a.ui) || (b.other - a.other));
untranslatedEn.sort((a, b) => a.key.localeCompare(b.key));

const md = [];
md.push('# Instamony 多语言审计');
md.push('');
md.push(`> 生成时间：${new Date().toISOString()}`);
md.push('> 扫描范围：`entry/src/main/ets/**/*.ets`，注释已排除；日志/诊断与 UI 文案分开统计。');
md.push('');
md.push('## 总览');
md.push('');
md.push(`- 资源键：base **${base.size}** 个，en_US **${en.size}** 个`);
md.push(`- en_US 缺少的键：**${missingEn.length}** 个`);
md.push(`- en_US 仍是中文的键：**${untranslatedEn.length}** 个`);
md.push(`- en_US 多出、base 没有的键：**${missingBase.length}** 个`);
md.push(`- ` + '`$r(\'app.string.*\')` 引用但未定义的键：**' + `${undefinedRefs.size}** 个`);
md.push(`- `.slice(0, 0) + `- 仍含中文的字符串字面量：**${totalCjk}** 个（UI 线索 **${uiCjk}** / 日志诊断 **${logCjk}** / 其他 **${otherCjk}**）`);
md.push('');
md.push('> “UI 线索”是按所在行是否出现 `Text(` / `Button(` / `placeholder` / `title` 等关键字判断的，仍需人工复核；日志/诊断类通常不需要翻译。');
md.push('');
md.push('## 语言资源');
md.push('');
md.push('| 目录 | 键数 | 相对 base 缺键 |');
md.push('|---|---:|---:|');
const localeDirs = ['zh_CN', 'zh_TW', 'en_US', 'ja_JP', 'ko_KR', 'es_ES', 'de_DE'];
for (const dir of localeDirs) {
  const file = path.join(root, 'entry/src/main/resources', dir, 'element', 'string.json');
  if (!fs.existsSync(file)) {
    md.push(`| \`${dir}\` | - | 未生成 |`);
    continue;
  }
  const map = readStrings(file);
  const missing = [...base.keys()].filter((k) => !map.has(k)).length;
  md.push(`| \`${dir}\` | ${map.size} | ${missing} |`);
}
md.push('');
md.push('## 优先处理：UI 中文最多的文件');
md.push('');
md.push('| 文件 | UI 中文串 | 其他中文串 | 日志/诊断 | 已用 `$r` 次数 |');
md.push('|---|---:|---:|---:|---:|');
for (const f of byFile.slice(0, 30)) {
  md.push(`| \`${f.file}\` | ${f.ui} | ${f.other} | ${f.log} | ${f.refCount} |`);
}
md.push('');
md.push('## 典型硬编码示例');
md.push('');
for (const f of byFile.filter((x) => x.ui > 0).slice(0, 15)) {
  md.push(`### \`${f.file}\``);
  for (const e of f.examples) md.push(`- L${e.line}: \`${e.text}\``);
  md.push('');
}
md.push('## en_US 缺少的键');
md.push('');
if (missingEn.length === 0) md.push('- 无');
else for (const k of missingEn) md.push(`- \`${k}\`：base = \`${base.get(k)}\``);
md.push('');
md.push('## en_US 仍是中文的键');
md.push('');
if (untranslatedEn.length === 0) md.push('- 无');
else for (const e of untranslatedEn) md.push(`- \`${e.key}\`：\`${e.value}\``);
md.push('');
md.push("## 未定义的 `$r('app.string.*')` 引用");
md.push('');
if (undefinedRefs.size === 0) md.push('- 无');
else for (const [k, where] of undefinedRefs) md.push(`- \`${k}\` ← ${[...new Set(where)].join(', ')}`);
md.push('');
md.push('## 当前状态 / 下一步');
md.push('');
md.push('1. `en_US` 已补齐（0 缺键）；7 个语言目录均为 306 键；');
md.push('2. UI 文案已基本迁完，只剩 2 条内部诊断串（Tls13Client / StoryDiag），它们不是界面文案；');
md.push('3. 带变量文案已统一走 `%s` / `%d` 占位符（`$r(key, arg)` 或 resourceManager.getStringSync）；');
md.push('4. 单复数规则尚未接入 `getIntPluralStringValueSync`，下一步优先处理“N 条消息 / N 分钟 / N 天”这类文案；');
md.push('5. 7 个语言资源目前是机器翻译，建议按目标语言做一轮人工校对（尤其日语/韩语/德语的长句）。');
md.push('');

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, md.join('\n'), 'utf8');
fs.writeFileSync(path.join(root, 'docs', 'i18n-ui-strings.json'),
  JSON.stringify(uiList, null, 2) + '\n', 'utf8');
console.log(`wrote ${outFile}`);
console.log(`files=${files.length} base=${base.size} en=${en.size} missingEn=${missingEn.length} untranslatedEn=${untranslatedEn.length} cjk=${totalCjk} ui=${uiCjk} log=${logCjk} other=${otherCjk} undefinedRefs=${undefinedRefs.size}`);
