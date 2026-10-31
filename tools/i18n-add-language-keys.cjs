/*
 * 语言切换 UI 的 5 个资源键（7 个语言目录 + base）。
 * 用法：node tools/i18n-add-language-keys.cjs
 */
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const keys = ['settings_group_language', 'settings_language', 'settings_language_search',
  'settings_language_hint', 'settings_language_changed'];

const values = {
  base: ['语言', '语言', '搜索语言', '选择应用语言；只影响本应用，不改变系统语言。', '语言已切换'],
  en_US: ['Language', 'Language', 'Search languages',
    'Choose the app language. This only affects this app, not the system language.',
    'Language changed'],
  zh_CN: ['语言', '语言', '搜索语言', '选择应用语言；只影响本应用，不改变系统语言。', '语言已切换'],
  zh_TW: ['語言', '語言', '搜尋語言', '選擇應用程式語言；只影響本應用程式，不改變系統語言。', '語言已切換'],
  ja_JP: ['言語', '言語', '言語を検索', 'アプリの言語を選択します。このアプリにのみ適用され、システム言語は変わりません。', '言語を切り替えました'],
  ko_KR: ['언어', '언어', '언어 검색', '앱 언어를 선택하세요. 이 앱에만 적용되며 시스템 언어는 변경되지 않습니다.', '언어가 변경되었습니다'],
  es_ES: ['Idioma', 'Idioma', 'Buscar idiomas',
    'Elige el idioma de la aplicación. Solo afecta a esta app, no al idioma del sistema.',
    'Idioma cambiado'],
  de_DE: ['Sprache', 'Sprache', 'Sprachen suchen',
    'Wähle die App-Sprache. Sie gilt nur für diese App, nicht für die Systemsprache.',
    'Sprache geändert']
};

for (const dir of Object.keys(values)) {
  const file = path.join(root, 'entry/src/main/resources', dir, 'element/string.json');
  if (!fs.existsSync(file)) continue;
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  const have = new Set(data.string.map((x) => x.name));
  for (let i = 0; i < keys.length; i++) {
    if (!have.has(keys[i])) data.string.push({ name: keys[i], value: values[dir][i] });
  }
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8');
  console.log(`updated ${dir}`);
}
