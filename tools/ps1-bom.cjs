// 给 .ps1 加 UTF-8 BOM：Windows PowerShell 5.1 读无 BOM 的 .ps1 时按 ANSI(GBK) 解码，
// 中文注释会被拆成乱码、引号配对错乱，脚本直接 ParserError。
const fs = require('fs');
const files = process.argv.slice(2);
for (const f of files) {
  let buf = fs.readFileSync(f);
  if (buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    console.log('already bom:', f);
    continue;
  }
  fs.writeFileSync(f, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), buf]));
  console.log('bom added:', f, buf.length, '->', fs.statSync(f).size);
}
