/*
 * 从 base/string.json 生成各语言资源（机器翻译，供后续人工校对）。
 *
 * 目标目录：zh_CN（复制中文）/ zh_TW / ja_JP / ko_KR / es_ES / de_DE
 * en_US 已有人工英文，不覆盖。
 *
 * 用法：node tools/i18n-gen-locales.cjs
 */
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const baseFile = path.join(root, 'entry/src/main/resources/base/element/string.json');
const base = JSON.parse(fs.readFileSync(baseFile, 'utf8'));
const rows = (base.string || []).filter((x) => x && x.name);

const locales = [
  { dir: 'zh_TW', code: 'zh-TW' },
  { dir: 'ja_JP', code: 'ja' },
  { dir: 'ko_KR', code: 'ko' },
  { dir: 'es_ES', code: 'es' },
  { dir: 'de_DE', code: 'de' }
];

const brands = ['Instamony', 'Instagram', 'Reels', 'MeoW', 'DoH', 'Wi-Fi', 'sessionid', 'API', 'JSON', 'HTTP', 'HTTPS', 'DNS', 'TLS', 'IG'];
const brandToken = (i) => `[[B${i}]]`;

function protect(text) {
  let out = text;
  const tokens = [];
  out = out.replace(/%%/g, () => {
    const t = `[[P${tokens.length}]]`;
    tokens.push('%%');
    return t;
  });
  out = out.replace(/%[sd]/g, (m) => {
    const t = `[[P${tokens.length}]]`;
    tokens.push(m);
    return t;
  });
  for (let i = 0; i < brands.length; i++) {
    const b = brands[i];
    out = out.split(b).join(brandToken(i));
  }
  out = out.split('\\n').join('[[NL]]');
  return { out, tokens };
}

function restore(text, tokens) {
  let out = text;
  for (let i = 0; i < tokens.length; i++) {
    out = out.split(`[[P${i}]]`).join(tokens[i]);
  }
  for (let i = 0; i < brands.length; i++) {
    out = out.split(brandToken(i)).join(brands[i]);
  }
  out = out.split('[[NL]]').join('\\n');
  return out;
}

async function translateBatch(values, code) {
  const joined = values.join('\n@@@\n');
  const url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl='
    + encodeURIComponent(code) + '&dt=t&q=' + encodeURIComponent(joined);
  const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  if (!res.ok) throw new Error(`http ${res.status}`);
  const data = await res.json();
  const parts = data[0] || [];
  let text = '';
  for (const part of parts) if (part && part[0]) text += part[0];
  return text.split('\n@@@\n');
}

async function translateOne(value, code) {
  const url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl='
    + encodeURIComponent(code) + '&dt=t&q=' + encodeURIComponent(value);
  const res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  if (!res.ok) throw new Error(`http ${res.status}`);
  const data = await res.json();
  const parts = data[0] || [];
  let text = '';
  for (const part of parts) if (part && part[0]) text += part[0];
  return text;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function buildLocale(locale) {
  const out = [];
  const chunk = 20;
  for (let i = 0; i < rows.length; i += chunk) {
    const slice = rows.slice(i, i + chunk);
    const protectedRows = slice.map((row) => protect(row.value));
    const values = protectedRows.map((p) => p.out);
    let translated;
    try {
      translated = await translateBatch(values, locale.code);
    } catch (error) {
      translated = [];
    }
    if (!translated || translated.length !== slice.length) {
      // 分段失败：逐条重试（慢但稳）。
      translated = [];
      for (const value of values) {
        try {
          translated.push(await translateOne(value, locale.code));
        } catch (error) {
          translated.push(value);
        }
        await sleep(120);
      }
    }
    for (let j = 0; j < slice.length; j++) {
      out.push({ name: slice[j].name, value: restore(translated[j] || values[j], protectedRows[j].tokens) });
    }
    process.stdout.write(`${locale.dir} ${Math.min(i + chunk, rows.length)}/${rows.length}\r`);
    await sleep(350);
  }
  const dir = path.join(root, 'entry/src/main/resources', locale.dir, 'element');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'string.json'), JSON.stringify({ string: out }, null, 2) + '\n', 'utf8');
  console.log(`\nwrote ${locale.dir} (${out.length})`);
}

(async () => {
  // 简体中文直接用 base 的值（显式 zh_CN 目录）。
  const zhDir = path.join(root, 'entry/src/main/resources/zh_CN/element');
  fs.mkdirSync(zhDir, { recursive: true });
  fs.writeFileSync(path.join(zhDir, 'string.json'),
    JSON.stringify({ string: rows.map((x) => ({ name: x.name, value: x.value })) }, null, 2) + '\n', 'utf8');
  console.log(`wrote zh_CN (${rows.length})`);
  for (const locale of locales) await buildLocale(locale);
})();
