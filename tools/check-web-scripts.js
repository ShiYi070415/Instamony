/*
 * 语法自检：把 WebScripts.ets 里注入网页的那几段脚本在 Node 里生成出来，用 new Function 过一遍。
 *
 * 为什么值得单独一个脚本：这些脚本是"用字符串拼出来的 JS"，编译期完全查不出里面的语法错误
 * （括号多一个、引号漏转义都只在真机上表现为 runBridge 超时/解析失败）。这个坑踩过一次
 * （搜索输入脚本花括号算错，真机上整个注入超时），所以改完注入脚本先跑这里。
 *
 * 用法： node tools/check-web-scripts.js
 */
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'bridge', 'WebScripts.ets');
const text = fs.readFileSync(SRC, 'utf8');

/** 版本无关的"模块级常量"占位：语法检查不关心内容，但里面若有语法错也是错，
 *  所以尽量把真实的字符串常量取出来（取不到再用占位）。 */
function constString(name) {
  const re = new RegExp(`const ${name}: string = ([\\s\\S]*?);\\n`, 'm');
  const m = text.match(re);
  if (!m) {
    return "''";
  }
  return m[1];
}

function stripTypes(code) {
  return code
    .replace(/:\s*string\[\]/g, '')
    .replace(/:\s*Array<[^>]*>/g, '')
    .replace(/:\s*(string|number|boolean)\b/g, '')
    .replace(/export\s+function/g, 'function')
    .replace(/export\s+const/g, 'const');
}

/** 按大括号匹配截出函数声明体；**跳过字符串字面量里的括号**（脚本里全是 `{` `}` 字符串）。 */
function sliceDecl(name, kind) {
  const start = text.indexOf(`${kind} ${name}`);
  if (start < 0) {
    return null;
  }
  const brace = text.indexOf('{', start);
  let depth = 0;
  let quote = '';
  for (let i = brace; i < text.length; i++) {
    const ch = text[i];
    if (quote !== '') {
      if (ch === '\\') {
        i++;
      } else if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') {
      quote = ch;
      continue;
    }
    if (ch === '{') {
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0) {
        return text.slice(start, i + 1);
      }
    }
  }
  return null;
}

/** 提取 `const NAME: 类型 = ... ;` 这种声明（到行尾分号为止，够用）。 */
function sliceConstString(name) {
  const start = text.search(new RegExp(`const ${name}\\s*:\\s*\\w+\\s*=`));
  if (start < 0) {
    return null;
  }
  const end = text.indexOf(';\n', start);
  return text.slice(start, end + 1);
}

const prelude = [
  sliceConstString('PROXY'),
  sliceConstString('SLEEP_JS'),
  sliceConstString('GRAPHQL_VARS_JS'),
  sliceConstString('TARGET_MEDIA_WIDTH'),
  sliceConstString('MEDIA_PICK_JS')
].filter(Boolean).map(stripTypes).join('\n');

const decls = [
  sliceConstString('NETWORK_WATCHER'),
  sliceDecl('timelineScript', 'function'),
  sliceDecl('reelsScript', 'function'),
  sliceDecl('capturePreviewScript', 'function')
].filter(Boolean).map(stripTypes);

let failures = 0;
const context = new Function(`${prelude}
${decls.join('\n')}
return {
  watcher: (typeof NETWORK_WATCHER === 'string' ? NETWORK_WATCHER : ''),
  timeline: timelineScript(''),
  timelineCursor: timelineScript('CURSOR123'),
  reels: reelsScript('{}', '{"after":null}'),
  preview: (typeof capturePreviewScript === 'function' ? capturePreviewScript() : '')
};`)();

function check(label, code) {
  if (!code || code.length === 0) {
    console.log(`- ${label}: 跳过（没取到）`);
    return;
  }
  try {
    new Function(code);
    console.log(`✓ ${label} 语法通过（${code.length} 字符）`);
  } catch (error) {
    failures++;
    console.log(`✗ ${label} 语法错误：${error.message}`);
  }
}

check('NETWORK_WATCHER', context.watcher);
check('timelineScript("")', context.timeline);
check('timelineScript(cursor)', context.timelineCursor);
check('reelsScript(...)', context.reels);
check('capturePreviewScript()', context.preview);

// 标记检查：确认真的把"响应缓存快路径"编进了生成的脚本里（切错片段/漏拼都会在这里露出来）。
function expect(label, code, marker) {
  if (!code || code.indexOf(marker) < 0) {
    failures++;
    console.log(`✗ ${label} 里没有 ${marker}（拼接可能没生效）`);
    return;
  }
  console.log(`✓ ${label} 含 ${marker}`);
}

expect('NETWORK_WATCHER', context.watcher, 'window.__ogCap');
expect('timelineScript', context.timeline, '__ogCap');
expect('timelineScript', context.timeline, 'src="capture"');
expect('reelsScript', context.reels, '__ogCap');
expect('reelsScript', context.reels, 'src="capture"');

if (failures > 0) {
  process.exit(1);
}
