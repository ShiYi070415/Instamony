#!/usr/bin/env node
/*
 * **FBNS 移植的离线对拍**：`node tools/relay/test-fbns-arkts.js`
 *
 * 做法与 `test-arkts-parsers.js` 同一套：把 `MobileFbns.ets` 里的方法源码摘出来、
 * 剥掉类型注解，在 Node 的 vm 里跑，然后：
 *   1. **CONNECT 报文逐字节**与 `fbns.js`（已验证可用）对比 —— Thrift 编码差一个字节，
 *      服务端就会回 rc=4/rc=5，而且真机上根本看不出原因；
 *   2. **inflate** 与 Node 的 `zlib.deflateSync` / `deflateRawSync` 对拍（stored / 固定 /
 *      动态 Huffman 三种块都要覆盖）；
 *   3. **帧解析 / 载荷解析**用人工构造的帧与"长度前缀 + JSON"验证。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const zlib = require('zlib');

const DIR = __dirname;
const ETS = path.join(DIR, '..', '..', 'entry', 'src', 'main', 'ets', 'core', 'mobileapi',
  'MobileFbns.ets');
const source = fs.readFileSync(ETS, 'utf8');

let passed = 0;
let failed = 0;

function check(name, fn) {
  try {
    fn();
    passed++;
    console.log('  ✓ ' + name);
  } catch (error) {
    failed++;
    console.log('  ✗ ' + name);
    console.log('      ' + (error && error.message ? error.message : error));
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertEqual(actual, expected, message) {
  if (String(actual) !== String(expected)) {
    throw new Error((message || '值不相等') + '：期望 ' + expected + '，实际 ' + actual);
  }
}

/** 摘出一个方法体（支持 `static name(`、`export function name(`）。 */
function extract(name) {
  const markers = ['static ' + name + '(', 'export function ' + name + '(', 'function ' + name + '('];
  let at = -1;
  for (const marker of markers) {
    at = source.indexOf(marker);
    if (at >= 0) {
      break;
    }
  }
  if (at < 0) {
    throw new Error('找不到 ' + name);
  }
  const bodyStart = source.indexOf('{', at);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index++) {
    const ch = source.charAt(index);
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        const head = source.substring(at, bodyStart);
        return { head, body: source.substring(bodyStart, index + 1) };
      }
    }
  }
  throw new Error(name + ' 括号不配对');
}

function stripTypes(text) {
  return text
    // 嵌套泛型要先处理（`Array<Array<number>>`）：否则外层规则只吃掉前半截，留下一个 `>`
    .replace(/:\s*Array<Array<number>>/g, '')
    .replace(/:\s*Uint8Array/g, '')
    .replace(/:\s*Array<[^>]+>/g, '')
    .replace(/:\s*Record<[^>]+>/g, '')
    .replace(/:\s*FbnsPacket/g, '')
    .replace(/:\s*FbnsAuth/g, '')
    .replace(/:\s*ESObject/g, '')
    .replace(/:\s*boolean/g, '')
    .replace(/:\s*number/g, '')
    .replace(/:\s*string/g, '')
    .replace(/\s+as\s+number/g, '')
    .replace(/\s+as\s+Array<[^>]+>/g, '')
    .replace(/\s+as\s+ESObject/g, '')
    .replace(/\s+as\s+string/g, '');
}

const sandbox = { JSON, Math, Array, Object, String, Number, Uint8Array, console };
sandbox.FbnsThrift = {};
sandbox.FbnsWire = {};
sandbox.MobileFbns = {};
sandbox.FbnsInflate = {};
sandbox.FbnsPacket = class FbnsPacket {
  constructor(kind) {
    this.kind = kind;
    this.returnCode = -1;
    this.topic = '';
    this.packetId = -1;
    this.payload = new Uint8Array(0);
    this.code = 0;
  }
};
vm.createContext(sandbox);

/** 把这些方法挂到指定对象上。 */
function bind(target, name) {
  const one = extract(name);
  const head = stripTypes(one.head).trim();
  // head 形如 `static name(out, cur, field, type)`：第一个 `(` 起才是参数表
  const open = head.indexOf('(');
  const params = head.substring(open, head.lastIndexOf(')') + 1);
  return `${target}.${name} = function${params} ${stripTypes(one.body)};`;
}

/** 模块级常量（值必须与 .ets 一致）。 */
function bindConst(name, value) {
  return 'const ' + name + ' = ' + JSON.stringify(value) + ';';
}

const script = [
  bindConst('T_STOP', 0),
  bindConst('T_TRUE', 1),
  bindConst('T_FALSE', 2),
  bindConst('T_BYTE', 3),
  bindConst('T_I32', 5),
  bindConst('T_I64', 6),
  bindConst('T_BINARY', 8),
  bindConst('T_LIST', 9),
  bindConst('T_STRUCT', 12),
  bindConst('FBNS_UA',
    'Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; o1s; '
      + 'exynos2100; en_US; 1079242191)'),
  bindConst('FBNS_APP_ID', 567310203415052),
  // Thrift
  bind('FbnsThrift', 'varint'),
  bind('FbnsThrift', 'zigzag'),
  bind('FbnsThrift', 'field'),
  bind('FbnsThrift', 'pushStruct'),
  bind('FbnsThrift', 'stop'),
  bind('FbnsThrift', 'strDirect'),
  bind('FbnsThrift', 'str'),
  bind('FbnsThrift', 'bool'),
  bind('FbnsThrift', 'int'),
  bind('FbnsThrift', 'intList'),
  bind('FbnsThrift', 'utf8'),
  bind('FbnsThrift', 'textOf'),
  // 报文字节
  bind('FbnsWire', 'pushRemaining'),
  bind('FbnsWire', 'zlibStored'),
  bind('FbnsWire', 'adler32'),
  bind('MobileFbns', 'buildConnectThrift'),
  bind('MobileFbns', 'buildConnect'),
  bind('MobileFbns', 'buildPublish'),
  bind('MobileFbns', 'buildSubscribe'),
  bind('MobileFbns', 'buildPuback'),
  bind('MobileFbns', 'buildPingreq'),
  bind('MobileFbns', 'decodePacket'),
  bind('MobileFbns', 'parsePayload'),
  bind('MobileFbns', 'inflate'),
  // inflate
  bind('FbnsInflate', 'bits'),
  bind('FbnsInflate', 'buildDecoder'),
  bind('FbnsInflate', 'decodeSymbol'),
  bind('FbnsInflate', 'build')
].join('\n');
vm.runInContext(script, sandbox);

const Ark = sandbox.MobileFbns;
const Inflate = sandbox.FbnsInflate;

function toArray(bytes) {
  return Array.from(bytes);
}

function equalBytes(actual, expected) {
  const a = toArray(actual);
  const b = toArray(expected);
  if (a.length !== b.length) {
    return '长度不同：' + a.length + ' vs ' + b.length;
  }
  for (let index = 0; index < a.length; index++) {
    if (a[index] !== b[index]) {
      return '第 ' + index + ' 字节不同：' + a[index] + ' vs ' + b[index];
    }
  }
  return '';
}

console.log('FBNS 移植对拍（源码来自 MobileFbns.ets）');

/* ① 与 fbns.js 的 CONNECT 逐字节对比（比的是压缩前的 Thrift 段） */
check('CONNECT-Thrift（空身份引导阶段）与 fbns.js 逐字节一致', () => {
  const bridge = require('./fbns-bridge.js');
  const now = 1700000000000;
  const expected = bridge.buildConnectThrift(
    { clientId: 'android-1a2b3c4d', userId: 0, password: '', deviceId: '', deviceSecret: '' }, now);
  const actual = Ark.buildConnectThrift(
    { clientId: 'android-1a2b3c4d', userId: 0, password: '', deviceId: '', deviceSecret: '' }, now);
  const diff = equalBytes(actual, expected);
  assert(diff === '', 'CONNECT-Thrift 不同：' + diff);
});

check('CONNECT-Thrift（带设备凭据）与 fbns.js 逐字节一致', () => {
  const bridge = require('./fbns-bridge.js');
  const now = 1700000000000;
  const jsAuth = { clientId: 'dev-123456789012345', userId: 46473815227,
    password: 'SECRET-CS', deviceId: 'dev-123456789012345', deviceSecret: 'SECRET-DS' };
  const expected = bridge.buildConnectThrift(jsAuth, now);
  const actual = Ark.buildConnectThrift(jsAuth, now);
  const diff = equalBytes(actual, expected);
  assert(diff === '', 'CONNECT-Thrift 不同：' + diff);
});

check('CONNECT 报文：我们的 zlib（stored 块）能被标准 inflate 解开，且等于 Thrift 段', () => {
  const bridge = require('./fbns-bridge.js');
  const now = 1700000000000;
  const auth = { clientId: 'android-1a2b3c4d', userId: 0, password: '', deviceId: '', deviceSecret: '' };
  const packet = Buffer.from(Ark.buildConnect(auth, 60, now));
  // 报文结构：[0x10][剩余长度 varint][00 06 M Q T T o T][03][C2][keepAlive hi lo][zlib payload]
  assert(packet[0] === 0x10, '固定头不对：' + packet[0]);
  const prologue = Buffer.from([0x00, 0x06, 0x4D, 0x51, 0x54, 0x54, 0x6F, 0x54, 0x03, 0xC2, 0x00, 60]);
  const prologueAt = packet.indexOf(prologue);
  assert(prologueAt > 0, '没找到 MQTToT 前导');
  const compressed = packet.subarray(prologueAt + prologue.length);
  const inflated = zlib.inflateSync(compressed);
  const expected = bridge.buildConnectThrift(auth, now);
  assert(equalBytes(new Uint8Array(inflated), expected) === '',
    '解压后与 fbns.js 的 Thrift 段不一致');
});

check('SUBSCRIBE / PUBLISH / PUBACK / PINGREQ 与 fbns.js 逐字节一致', () => {
  const bridge = require('./fbns-bridge.js');
  const payload = new Uint8Array([1, 2, 3, 4, 5]);
  assert(equalBytes(Ark.buildSubscribe('76', 7), bridge.buildSubscribe('76', 7)) === '',
    'SUBSCRIBE 不同');
  assert(equalBytes(Ark.buildPublish('79', payload, 9),
    bridge.buildPublish('79', Buffer.from(payload), 9)) === '', 'PUBLISH 不同');
  assert(equalBytes(Ark.buildPuback(11), bridge.buildPuback(11)) === '', 'PUBACK 不同');
  assert(equalBytes(Ark.buildPingreq(), bridge.buildPingreq()) === '', 'PINGREQ 不同');
});

/* ② inflate 与 Node zlib 对拍 */
check('inflate：小 JSON（动态 Huffman）与 Node 一致', () => {
  const text = JSON.stringify({ ck: 46473815227, cs: 'abc', di: 'DEV-uuid', ds: 'SECRET' });
  const raw = Buffer.from(text, 'utf8');
  const compressed = new Uint8Array(zlib.deflateSync(raw));
  const got = Inflate.build(compressed);
  assert(Buffer.from(got).toString('utf8') === text, '解出来的文本不一致');
});

check('inflate：大 JSON（> 4KB，含长重复，触发距离码/长度码）', () => {
  const items = [];
  for (let index = 0; index < 200; index++) {
    items.push({ index, text: 'private message #' + index + ' 中文内容', flag: index % 2 === 0 });
  }
  const text = JSON.stringify({ fbpushnotif: items });
  const compressed = new Uint8Array(zlib.deflateSync(Buffer.from(text, 'utf8')));
  const got = Inflate.build(compressed);
  assert(Buffer.from(got).toString('utf8') === text,
    '解出来的文本不一致（长度 ' + got.length + ' vs ' + Buffer.from(text).length + '）');
});

check('inflate：高熵随机数据（不可压缩 → stored / 固定块）', () => {
  const raw = Buffer.alloc(900);
  for (let index = 0; index < raw.length; index++) {
    raw[index] = (index * 37 + 11) % 251;
  }
  const compressed = new Uint8Array(zlib.deflateSync(raw));
  const got = Inflate.build(compressed);
  assert(equalBytes(got, raw) === '', '随机数据解出来不一致：' + equalBytes(got, raw));
});

check('inflate：全零数据（长距离重复）', () => {
  const raw = Buffer.alloc(5000, 0);
  const compressed = new Uint8Array(zlib.deflateSync(raw));
  const got = Inflate.build(compressed);
  assert(equalBytes(got, raw) === '', '全零数据解出来不一致');
});

/* ③ 帧与载荷 */
check('decodePacket：CONNACK（rc + 载荷）', () => {
  const payload = Buffer.from(JSON.stringify({ ck: 1, di: 'D' }), 'utf8');
  const body = Buffer.concat([Buffer.from([0x00, 0x00]), payload]);
  const frame = new Uint8Array(Buffer.concat([Buffer.from([0x20, body.length]), body]));
  const packet = Ark.decodePacket(frame);
  assertEqual(packet.kind, 'connack', '不是 CONNACK');
  assertEqual(packet.returnCode, 0, 'returnCode 不对');
  assert(Buffer.from(packet.payload).toString('utf8') === payload.toString('utf8'), '载荷不对');
});

check('decodePacket：PUBLISH（topic 76 + packetId + 载荷）', () => {
  const topic = Buffer.from('76', 'utf8');
  // topic 长度是大端：高字节在前
  const body = Buffer.concat([Buffer.from([0x00, topic.length]), topic,
    Buffer.from([0x00, 0x05]), Buffer.from('hello', 'utf8')]);
  const frame = new Uint8Array(Buffer.concat([Buffer.from([0x32, body.length]), body]));
  const packet = Ark.decodePacket(frame);
  assertEqual(packet.kind, 'publish', '不是 PUBLISH');
  assertEqual(packet.topic, '76', 'topic 不对');
  assertEqual(packet.packetId, 5, 'packetId 不对');
  assert(Buffer.from(packet.payload).toString('utf8') === 'hello', '载荷不对');
});

check('parsePayload：zlib 压缩 + 2 字节长度前缀 + JSON', () => {
  const text = JSON.stringify({ fbpushnotif: { m: 'hi', t_id: '1', s: '2', n: '3' } });
  const prefixed = Buffer.concat([Buffer.from([(text.length >> 8) & 0xFF, text.length & 0xFF]),
    Buffer.from(text, 'utf8')]);
  const compressed = new Uint8Array(zlib.deflateSync(prefixed));
  const parsed = Ark.parsePayload(compressed);
  assert(parsed !== null && typeof parsed === 'object', '没解析成对象');
  assert(parsed.fbpushnotif.m === 'hi', '正文不对');
});

check('parsePayload：未压缩的裸 JSON 也能吃', () => {
  const text = JSON.stringify({ token: 'abc' });
  const parsed = Ark.parsePayload(new Uint8Array(Buffer.from(text, 'utf8')));
  assert(parsed.token === 'abc', '裸 JSON 没解析对');
});

console.log('');
console.log('通过 ' + passed + '，失败 ' + failed);
if (failed > 0) {
  process.exit(1);
}
