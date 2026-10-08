/*
 * 检查/补全所有 `Image(...)` 上的 `.draggable(false)`。
 *
 * 为什么需要它：官方文档写明 **Image 的 draggable 默认为 true** —— 长按图片会"浮起"并进入系统
 * 拖拽（长按拖拽 / 拖拽分享）。在信息流里这意味着手指按在图片上稍微久一点，滚动就被拖拽接管：
 * 用户端表现为"滑不动了/卡住了"，实测直接把自动化滑动卡死在一次拖拽会话里。
 * 本 app 没有任何需要把图片拖出去的场景，所以统一关掉；新加 Image 时用这个脚本兜一遍，
 * 免得又漏一处。
 *
 * 用法（仓库根目录）：
 *   node tools/disable-image-drag.js          # 只检查，列出缺失的（有缺失时退出码 1）
 *   node tools/disable-image-drag.js --fix    # 就地补上 .draggable(false)
 *
 * 实现上按平衡括号定位 `Image(...)` 的结尾，避免正则误伤嵌套括号（如三元表达式里嵌套的调用）。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');
const FIX = process.argv.indexOf('--fix') >= 0;

function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    if (fs.statSync(full).isDirectory()) {
      walk(full, out);
    } else if (name.endsWith('.ets')) {
      out.push(full);
    }
  }
  return out;
}

/** 从 '(' 开始找匹配的 ')'，跳过字符串字面量里的括号。 */
function matchParen(text, openIndex) {
  let depth = 0;
  let quote = '';
  for (let i = openIndex; i < text.length; i++) {
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
    if (ch === '(') {
      depth++;
    } else if (ch === ')') {
      depth--;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

let missing = 0;
let fixed = 0;
for (const file of walk(ROOT, [])) {
  const original = fs.readFileSync(file, 'utf8');
  let text = original;
  let index = 0;
  const holes = [];
  while (true) {
    const hit = text.indexOf('Image(', index);
    if (hit < 0) {
      break;
    }
    // 只处理组件调用：前面不能是标识符字符（排除 matchedImage( 这类）。
    const before = hit === 0 ? ' ' : text[hit - 1];
    if (/[A-Za-z0-9_$.]/.test(before)) {
      index = hit + 6;
      continue;
    }
    const close = matchParen(text, hit + 5);
    if (close < 0) {
      index = hit + 6;
      continue;
    }
    const line = text.slice(0, hit).split('\n').length;
    // 允许 .draggable(false) 写在下一行（本仓库就是换行 + 缩进写的），中间可以有空白。
    if (/^\s*\.draggable\(/.test(text.slice(close + 1, close + 40))) {
      index = close + 1;
      continue;
    }
    missing++;
    holes.push(close + 1);
    if (FIX) {
      const indent = (text.slice(0, hit).match(/\n([ \t]*)[^\n]*$/) || ['', ''])[1];
      text = text.slice(0, close + 1) + '\n' + indent + '  .draggable(false)' + text.slice(close + 1);
      fixed++;
      index = close + 1 + '\n'.length + indent.length + 2 + '.draggable(false)'.length;
    } else {
      index = close + 1;
      console.log(`${path.relative(ROOT, file)}:${line}  Image 缺少 .draggable(false)`);
    }
  }
  if (FIX && text !== original) {
    fs.writeFileSync(file, text, 'utf8');
    console.log(`patched ${path.relative(ROOT, file)}`);
  }
}

if (FIX) {
  console.log(`补了 ${fixed} 处`);
} else if (missing > 0) {
  console.log(`共 ${missing} 处缺失（用 --fix 自动补）`);
  process.exit(1);
} else {
  console.log('所有 Image 都已禁用拖拽 ✓');
}
