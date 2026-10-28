#!/usr/bin/env node
/*
 * **离线自检**（不需要账号、不需要网络）：`node tools/relay/test-caa-parse.js`
 *
 * 为什么要有它：CAA 登录里"成功"那半条路径 —— 从 Bloks 布局里抠出 `login_response`
 * （cookie + `IG-Set-Authorization`）→ 变成 settings.json 形状 → 再被 `--import-session`
 * 的解析器读回来 —— **在真账号登录成功之前一次都没被执行过**。密码加密同理：
 * 假账号回"Can't find account"只证明请求形状对，**不证明 IG 能解开我们的密码**。
 *
 * 这些都能在本地验：用合成的 Bloks 布局验解析，用本地生成的 RSA 密钥把加密解开再比对。
 * 真机那条路（网络 + 风控）仍然只能由真账号验，但"我们的代码有没有写错"在这里就能定。
 */

'use strict';

const crypto = require('crypto');
const path = require('path');

const caa = require('./caa-login.js');
const format = require('./session-format.js');

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

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error((message || '断言失败') + '：期望 ' + JSON.stringify(expected)
      + '，实际 ' + JSON.stringify(actual));
  }
}

/* ------------------------------------------------ ① 密码加密（可逆性） */

/**
 * 按 IG 的格式把 `#PWD_INSTAGRAM:4:…` 解开（扮演服务端）：
 * `0x01 | keyId | iv(12) | u16le(rsaLen) | RSA(sessionKey) | tag(16) | AES 密文`
 * AES 用 AAD = 时间戳。
 */
function decryptPassword(encrypted, privateKey) {
  const parts = String(encrypted).split(':');
  assertEqual(parts[0], '#PWD_INSTAGRAM', '前缀不对');
  assertEqual(parts[1], '4', '版本不是 4');
  const timestamp = parts[2];
  const payload = Buffer.from(parts.slice(3).join(':'), 'base64');
  assertEqual(payload[0], 0x01, '首字节不是 0x01');
  const keyId = payload[1];
  const iv = payload.subarray(2, 14);
  const rsaLen = payload.readUInt16LE(14);
  const rsaBlock = payload.subarray(16, 16 + rsaLen);
  const tag = payload.subarray(16 + rsaLen, 16 + rsaLen + 16);
  const cipherText = payload.subarray(16 + rsaLen + 16);
  const sessionKey = crypto.privateDecrypt({
    key: privateKey,
    padding: crypto.constants.RSA_PKCS1_PADDING
  }, rsaBlock);
  assertEqual(sessionKey.length, 32, '会话密钥不是 32 字节');
  const decipher = crypto.createDecipheriv('aes-256-gcm', sessionKey, iv);
  decipher.setAAD(Buffer.from(timestamp, 'utf8'));
  decipher.setAuthTag(tag);
  const plain = Buffer.concat([decipher.update(cipherText), decipher.final()]).toString('utf8');
  return { password: plain, keyId, timestamp };
}

console.log('① 密码加密（#PWD_INSTAGRAM:4，RSA + AES-256-GCM）');
check('2048 位 RSA：加密后能被服务端格式解开、明文一致（含非 ASCII）', () => {
  const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const publicDerBase64 = pair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const original = 'p@ss wörd 密码 🔐';
  const encrypted = caa.encryptPasswordWithKey(original, publicDerBase64, 12);
  const opened = decryptPassword(encrypted, pair.privateKey);
  assertEqual(opened.password, original, '解出来的密码不一致');
  assertEqual(opened.keyId, 12, 'keyId 没带进去');
  assert(/^\d{10}$/.test(opened.timestamp), '时间戳形状不对：' + opened.timestamp);
});

check('PEM 公钥也能用（qe/sync 的头是 base64(PEM)，但别被格式绊住）', () => {
  const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const pem = pair.publicKey.export({ type: 'spki', format: 'pem' });
  const encrypted = caa.encryptPasswordWithKey('abc', pem, 255);
  assertEqual(decryptPassword(encrypted, pair.privateKey).password, 'abc', 'PEM 输入解不开');
});

check('base64(DER) 公钥也能用（内部会包成 PEM）', () => {
  const pair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const derBase64 = pair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const encrypted = caa.encryptPasswordWithKey('abc', derBase64, 7);
  assert(caa.publicKeyPemOf(derBase64).indexOf('-----BEGIN PUBLIC KEY-----') === 0,
    'DER 没被包成 PEM');
  assertEqual(decryptPassword(encrypted, pair.privateKey).password, 'abc', 'DER 输入解不开');
});

/* ------------------------------------------------ ② Bloks 布局解析 */

/** 造一段 Bloks lispy：`(f4i (dkc "k1" "k2") (dkc "v1" "v2"))`。 */
function f4i(pairs) {
  const keys = pairs.map((pair) => JSON.stringify(pair[0])).join(' ');
  const values = pairs.map((pair) => JSON.stringify(pair[1])).join(' ');
  return `(f4i (dkc ${keys}) (dkc ${values}))`;
}

console.log('② Bloks 布局解析');

check('aac：data[].data.initial 取值', () => {
  const layout = {
    layout: {
      bloks_payload: {
        data: [
          { data: { key: 'OTHER:thing', initial: 'nope' } },
          { data: { key: 'CAA_ACCOUNT_ACCESS_CONTEXT:aac', initial: 'AAC-FROM-INITIAL' } }
        ]
      }
    }
  };
  assertEqual(caa.extractAac(layout), 'AAC-FROM-INITIAL', 'aac 没取到');
});

check('aac：只有 initial_lispy 时也能取', () => {
  const layout = {
    layout: {
      bloks_payload: {
        data: [{ data: { key: 'CAA_ACCOUNT_ACCESS_CONTEXT:aac', initial_lispy: '  "AAC-LISPY" ' } }]
      }
    }
  };
  assertEqual(caa.extractAac(layout), 'AAC-LISPY', 'initial_lispy 分支没取到');
});

check('成功响应：从 action 里抠出 cookies + IG-Set-Authorization', () => {
  // 真实形状：layout.bloks_payload.action 是一段**字符串**，里面嵌着 JSON 字符串。
  const inner = {
    login_response: JSON.stringify({ status: 'ok', user_id: '1234' }),
    headers: JSON.stringify({
      'IG-Set-Authorization': 'Bearer IGT:2:eyJkc191c2VyX2lkIjoiMTIzNCJ9',
      'ig-set-x-mid': 'MID-XYZ'
    }),
    cookies: 'Set-Cookie: sessionid=1234%3Aabc; Path=/, Set-Cookie: ds_user_id=1234; Path=/'
  };
  const action = 'bloks_action({\n  "payload": ' + JSON.stringify(JSON.stringify(inner)) + '\n})';
  const data = { layout: { bloks_payload: { action } } };
  const parsed = caa.extractLoginPayload(data);
  assert(parsed !== null, '没解析出登录结果');
  assertEqual(parsed.headers['IG-Set-Authorization'], 'Bearer IGT:2:eyJkc191c2VyX2lkIjoiMTIzNCJ9',
    'authorization 头丢���');
  assertEqual(parsed.cookies.sessionid, '1234%3Aabc', 'sessionid cookie 丢��');
  assertEqual(parsed.cookies.ds_user_id, '1234', 'ds_user_id cookie 丢了');
  assertEqual(parsed.loginResponse.status, 'ok', 'login_response 没解出来');
});

check('失败响应：error 文案能取出来（假账号回的就是这句）', () => {
  const layouts = [
    { layout: { bloks_payload: { ft: { a: '  "We can\'t find an account with nobody. Try another."' } } } },
    { layout: { bloks_payload: { data: [{ data: { initial: "The password you entered isn't correct." } }] } } }
  ];
  assert(caa.bloksErrorMessage(layouts[0]).indexOf("can't find an account") > 0, 'can\'t find 没取到');
  assert(caa.bloksErrorMessage(layouts[1]).indexOf('password you entered') >= 0, '密码错误文案没取到');
  assertEqual(caa.bloksErrorMessage({ layout: null }), '', '空响应不该给出文案');
});

check('Cookie 串解析：对齐 Python SimpleCookie（属性不算 Cookie、逗号分隔也认）', () => {
  // 这几条是拿 Python 的 http.cookies.SimpleCookie 实测出来的行为，直接照抄成断言。
  const cases = [
    ['sessionid=x; Path=/; Domain=.instagram.com; HttpOnly', { sessionid: 'x' }],
    ['sessionid=x; ds_user_id=1; csrftoken=c',
      { sessionid: 'x', ds_user_id: '1', csrftoken: 'c' }],
    ['Set-Cookie: sessionid=x; Path=/, Set-Cookie: ds_user_id=1; Path=/',
      { sessionid: 'x', ds_user_id: '1' }],
    ['sessionid=x+abc; Path=/', { sessionid: 'x+abc' }]
  ];
  for (const [input, expected] of cases) {
    const actual = caa.parseCookieHeader(input);
    assertEqual(JSON.stringify(actual), JSON.stringify(expected), '解析结果不一致：' + input);
  }
});

check('两步验证：能判定走 2SV，并取出 entrypoint_async 的 context_data', () => {
  const context = 'CONTEXT-FROM-SEND';
  // 真实布局里：app id 字符串之后紧跟 `(f4i …)`；context_data 可能在顶层，也可能嵌在
  // server_params 的值里（值本身又是一个 f4i 表达式）。
  const lispyTop = `${JSON.stringify('com.bloks.www.ap.two_step_verification.entrypoint_async')} `
    + f4i([['context_data', context], ['other', 'x']]);
  // 嵌套形状（和 instagrapi 的解析语义一致）：`(f4i (dkc "server_params") (dkc (f4i ...)))`
  // —— 值列表本身是 `(dkc <表达式>)`，注意不是 `(f4i (dkc k) <表达式>)`。
  const nestedLispy = `${JSON.stringify('com.bloks.www.ap.two_step_verification.code_entry')} `
    + `(f4i (dkc "server_params") (dkc ${f4i([['context_data', 'NESTED-CONTEXT']])}))`;
  const data = { layout: { bloks_payload: { ft: { a: lispyTop, b: nestedLispy } } } };

  assert(caa.bloksNeedsTwoStep(data), '没判定成需要两步验证');
  assertEqual(caa.bloksExtractContextValue(data, 'com.bloks.www.ap.two_step_verification.entrypoint_async',
    'context_data'), context, '顶层 context_data 没取到');
  assertEqual(caa.bloksExtractContextValue(data, 'com.bloks.www.ap.two_step_verification.code_entry',
    'context_data'), 'NESTED-CONTEXT', 'server_params 里的 context_data 没取到');
});

check('两步验证：老写法的 app id（不带 _async）不会再被当成目标', () => {
  const data = {
    layout: {
      bloks_payload: {
        ft: { a: `${JSON.stringify('com.bloks.www.ap.two_step_verification.other')} `
          + f4i([['context_data', 'WRONG-APP']]) }
      }
    }
  };
  assertEqual(caa.bloksExtractContextValue(data, 'com.bloks.www.ap.two_step_verification.entrypoint_async',
    'context_data'), '', '取到了别的 app 的 context_data');
});

check('two_step_verification_context 能取出来（备用握手用）', () => {
  const data = {
    layout: {
      bloks_payload: { ft: { a: '{"two_step_verification_context":"TSV-CTX","x":1}' } }
    }
  };
  assertEqual(caa.extractTwoStepContext(data), 'TSV-CTX', 'TSV context 没取到');
});

/* ------------------------------------------------ ③ 会话等价性 */

console.log('③ 会话等价性（CAA 结果 ⇄ instagrapi settings.json）');

const profile = {
  phoneId: 'phone-0001',
  uuid: 'uuid-0002',
  androidId: 'androidid-0003',
  mid: 'MID-0004',
  appVersion: '449.0.0.52.84',
  versionCode: '1079242191',
  userAgent: 'UA/1.0'
};

const authorizationData = { ds_user_id: '777', sessionid: '777%3Asecret' };
const authorization = 'Bearer IGT:2:' + Buffer.from(JSON.stringify(authorizationData)).toString('base64');
const caaResult = {
  cookies: {
    sessionid: '777%3Asecret',
    ds_user_id: '777',
    csrftoken: 'csrf-xyz',
    rur: 'rur-1'
  },
  authorization
};

check('settingsShapeOf：authorization 被正确解码成 authorization_data', () => {
  const shape = format.settingsShapeOf(caaResult, profile);
  assertEqual(shape.authorization_data.ds_user_id, '777', 'ds_user_id 没解出来');
  assertEqual(shape.uuids.android_device_id, 'android-androidid-0003', 'android_device_id 前缀不对');
  assertEqual(shape.device_settings.app_version, profile.appVersion, 'app_version 丢了');
  assertEqual(shape.mid, profile.mid, 'mid 丢了');
});

check('登录响应头：捡回 mid / rur / claim（大小写混着也能认）', () => {
  const captured = caa.sessionHeadersOf({
    'IG-Set-Authorization': 'Bearer IGT:2:AAA',
    'ig-set-x-mid': 'MID-ABC',
    'IG-Set-IG-U-RUR': 'RUR-XYZ',
    'x-ig-set-www-claim': '29'
  });
  assertEqual(captured.mid, 'MID-ABC', 'mid 没捡到');
  assertEqual(captured.rur, 'RUR-XYZ', 'rur 没捡到');
  assertEqual(captured.claim, '29', 'claim 没捡到');
  const empty = caa.sessionHeadersOf({ 'IG-Set-Authorization': 'Bearer IGT:2:AAA' });
  assertEqual(empty.mid + empty.rur + empty.claim, '', '没有的头不该编出值');
});

check('settingsShapeOf：mid 优先用登录响应带回的那份（全新设备才退回档案）', () => {
  const fromLogin = format.settingsShapeOf({
    cookies: caaResult.cookies, authorization, mid: 'MID-FROM-LOGIN'
  }, profile);
  assertEqual(fromLogin.mid, 'MID-FROM-LOGIN', 'mid 没优先用响应里那份');
  const fromProfile = format.settingsShapeOf({ cookies: caaResult.cookies, authorization }, profile);
  assertEqual(fromProfile.mid, profile.mid, '没有响应 mid 时没退回设备档案');
});

check('往返：settings.json → session 与原会话逐字段一致（这就是"等价"）', () => {
  const shape = format.settingsShapeOf(caaResult, profile);
  const parsed = format.sessionFromSettings(shape);
  assertEqual(parsed.session.sessionid, caaResult.cookies.sessionid, 'sessionid 不一致');
  assertEqual(parsed.session.userId, '777', 'userId 不一致');
  assertEqual(parsed.session.csrf, 'csrf-xyz', 'csrf 不一致');
  assertEqual(parsed.session.authorization, authorization, 'authorization 不一致');
  assertEqual(parsed.session.mid, profile.mid, 'mid 不一致');
  assertEqual(parsed.session.appVersion, profile.appVersion, 'appVersion 不一致');
  assertEqual(parsed.device.phoneId, profile.phoneId, 'phoneId 不一致');
  assertEqual(parsed.device.uuid, profile.uuid, 'uuid 不一致');
  assertEqual(parsed.device.androidId, profile.androidId, 'androidId 不一致');
});

check('sessionFromSettings：缺 sessionid / uuids 时要抛（而不是产出一份假会话）', () => {
  let threw = false;
  try {
    format.sessionFromSettings({ cookies: { ds_user_id: '1' }, uuids: {} });
  } catch (error) {
    threw = true;
  }
  assert(threw, '缺 sessionid 时没有抛');
  threw = false;
  try {
    format.sessionFromSettings({ cookies: { sessionid: 'x' }, uuids: { phone_id: 'p' } });
  } catch (error) {
    threw = true;
  }
  assert(threw, 'uuids 不全时没有抛');
});

check('sessionProblemOf：不完整的会话要被拦住（宁可什么都不写，也别覆盖好会话）', () => {
  assertEqual(format.sessionProblemOf(null), '会话不是对象', 'null 没被拦');
  assertEqual(format.sessionProblemOf({ cookie: 'sessionid=x' }), '没有 sessionid', '缺 sessionid 没被拦');
  assertEqual(format.sessionProblemOf({ sessionid: '777%3Asecret' }),
    '没有 ds_user_id（账号 id）', '缺 userId 没被拦');
  assertEqual(format.sessionProblemOf({ sessionid: '777%3Asecret', userId: '777' }), '',
    '完整会话不该被判成有问题');
});

check('authorizationDataOf：非法串回空对象（不炸）', () => {
  assertEqual(Object.keys(format.authorizationDataOf('Bearer IGT:2:not-base64!!')).length, 0, '不该给出键');
  assertEqual(Object.keys(format.authorizationDataOf('')).length, 0, '空串不该给出键');
});

/* ------------------------------------------------ ④ USBID / JWT 形状 */

console.log('④ USDID（设备签名身份）')

check('USDID JWT 的段数与字段（真机第一次登录才会生成）', () => {
  const usdid = new caa.Usdid({
    phoneId: 'p', uuid: 'u', androidId: 'a', mid: '', appVersion: profile.appVersion,
    versionCode: profile.versionCode, bloksVersionId: 'b', userAgent: profile.userAgent
  }, path.join(__dirname, '.tmp-usdid-test.json'));
  const token = usdid.registrationToken();
  const decoded = JSON.parse(Buffer.from(token, 'base64url').toString('utf8'));
  assert(Array.isArray(decoded.signatures) && decoded.signatures.length === 1, 'signatures 形状不对');
  const box = decoded.signatures[0];
  assert(typeof box.protected === 'string' && box.protected.length > 0, 'protected 缺失');
  assert(typeof box.signature === 'string' && box.signature.length > 0, 'signature 缺失');
  const payload = JSON.parse(Buffer.from(decoded.payload, 'base64url').toString('utf8'));
  assertEqual(payload.alg, 'ES256', 'alg 不是 ES256');
  assertEqual(payload.sub, usdid.state.usdid, 'sub 不是 usdid');
  assert(typeof payload.pub === 'string' && payload.pub.length > 0, 'pub 缺失');
  const header = usdid.header();
  assertEqual(header.split('.').length, 3, 'X-Meta-Usdid 头不是三段');
  try {
    require('fs').unlinkSync(path.join(__dirname, '.tmp-usdid-test.json'));
  } catch (error) {
    // 没有就算了
  }
});

/* ------------------------------------------------ ⑤ App 自检镜像 */

/*
 * **App 的「解析自检」用的是什么断言？**
 *
 * `CaaLogin.selfTest()`（ArkTS）在真机上跑四项：aac / 错误文案 / login_response / 2SV 上下文。
 * 它跑不了单测，但它的**每一项都能在这里用同样的 fixture 复现** —— 万一自检在手机上误报失败，
 * 就会把整个真机测试带偏，所以这段"镜像"是必测的。
 *
 * 这里的 fixture 必须与 CaaLogin.ets 的 selfTest 逐字一致；改一边就要改另一边。
 */
console.log('⑤ App 自检镜像（CaaLogin.selfTest 的四项）');

check('自检①：aac（OTHER + CAA 两个节点，取后者）', () => {
  const payload = JSON.parse('{"layout":{"bloks_payload":{"data":[{"data":{"key":"OTHER:x",'
    + '"initial":"no"}},{"data":{"key":"CAA_ACCOUNT_ACCESS_CONTEXT:aac","initial":"AAC-TEST"}}]}}}');
  assertEqual(caa.extractAac(payload), 'AAC-TEST', '自检①会误报失败');
});

check('自检②：错误文案（We can\'t find an account …）', () => {
  const payload = JSON.parse('{"layout":{"bloks_payload":{"ft":{"a":'
    + '" We can\'t find an account with nobody. "}}}}');
  assert(caa.bloksErrorMessage(payload).indexOf('find an account') >= 0, '自检②会误报失败');
});

check('自检③：login_response 两层编码 → cookie 无属性、authorization 正确', () => {
  const inner = JSON.stringify({
    login_response: JSON.stringify({ status: 'ok' }),
    headers: JSON.stringify({ 'IG-Set-Authorization': 'Bearer IGT:2:AAA' }),
    cookies: 'Set-Cookie: sessionid=777%3Asecret; Path=/, Set-Cookie: ds_user_id=777; Path=/'
  });
  const actionText = 'bloks_action({"payload": ' + JSON.stringify(inner) + '})';
  const payload = { layout: { bloks_payload: { action: actionText } } };
  const parsed = caa.extractLoginPayload(payload);
  assert(parsed !== null, '自检③会误报失败（没解析出结果）');
  assert(parsed.cookie.indexOf('sessionid=777%3Asecret') >= 0, 'sessionid 丢了');
  assert(parsed.cookie.indexOf('ds_user_id=777') >= 0, 'ds_user_id 丢了');
  assertEqual(parsed.cookie.indexOf('Path='), -1, 'Cookie 里混进了 Path 属性');
  assertEqual(parsed.headers['IG-Set-Authorization'], 'Bearer IGT:2:AAA', 'authorization 不对');
});

check('自检④：2SV 上下文（entrypoint_async + f4i）', () => {
  const twoStepText = JSON.stringify('com.bloks.www.ap.two_step_verification.entrypoint_async')
    + ' (f4i (dkc "context_data") (dkc "CTX-TEST"))';
  const payload = { layout: { bloks_payload: { ft: { a: twoStepText } } } };
  assert(caa.bloksNeedsTwoStep(payload), '自检④会误报失败（没判定成 2SV）');
  assertEqual(caa.bloksExtractContextValue(payload,
    'com.bloks.www.ap.two_step_verification.entrypoint_async', 'context_data'),
  'CTX-TEST', '自检④会误报失败（上下文没取到）');
});

/* ------------------------------------------------ 汇总 */

console.log('');
console.log('通过 ' + passed + '，失败 ' + failed);
if (failed > 0) {
  process.exit(1);
}
