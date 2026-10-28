#!/usr/bin/env node
/*
 * 自测：不碰真凭据，验证 agc.js 生成的服务账号 JWT 是否符合官方文档。
 *
 * 官方文档（push-jwt-token）要求：
 *   Header  : { kid: key_id, typ: "JWT", alg: "PS256" }
 *   Payload : { aud: "https://oauth-login.cloud.huawei.com/oauth2/v3/token",
 *               iss: sub_account, iat, exp(iat+3600) }
 *   签名    : SHA256withRSA/PSS（PS256），PSS 盐长 = 摘要长度
 *
 * 这里用一本临时生成的 RSA 密钥当"服务账号"，把签名结果拿公钥验一遍，
 * 只有算法/填充/盐长全对才会通过。跑法：node self-test.js
 */

'use strict';

const crypto = require('crypto');
const { serviceJwt } = require('./agc.js');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
});

// 故意用文档样例里的"带 \n 转义"的形态，验证我们做了还原。
const sa = {
  project_id: '315888200000052863',
  key_id: 'test-kid-1234',
  sub_account: 'test-sub-account-5678',
  private_key: privateKey.replace(/\n/g, '\\n')
};

const jwt = serviceJwt(sa);
const parts = jwt.split('.');
const fail = (msg) => {
  console.error('✗ ' + msg);
  process.exit(1);
};
if (parts.length !== 3) fail('JWT 不是三段，实际 ' + parts.length + ' 段');

const header = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));

if (header.alg !== 'PS256') fail('header.alg 应为 PS256，实际 ' + header.alg);
if (header.typ !== 'JWT') fail('header.typ 应为 JWT，实际 ' + header.typ);
if (header.kid !== sa.key_id) fail('header.kid 应为 key_id，实际 ' + header.kid);
if (payload.iss !== sa.sub_account) fail('payload.iss 应为 sub_account，实际 ' + payload.iss);
if (payload.aud !== 'https://oauth-login.cloud.huawei.com/oauth2/v3/token') {
  fail('payload.aud 不对：' + payload.aud);
}
if (payload.exp - payload.iat !== 3600) fail('exp 应比 iat 晚 3600 秒，实际 ' + (payload.exp - payload.iat));

const ok = crypto.verify(
  'sha256',
  Buffer.from(parts[0] + '.' + parts[1]),
  {
    key: publicKey,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST
  },
  Buffer.from(parts[2], 'base64url')
);
if (!ok) fail('PS256 签名验不过（算法/填充/盐长有问题）');

console.log('✓ JWT 三段齐全，长度 ' + jwt.length);
console.log('✓ header = ' + JSON.stringify(header));
console.log('✓ payload.iss/aud/exp 符合文档，exp-iat = 3600');
console.log('✓ PS256 签名用公钥验签通过（含 private_key 里的 \\n 还原）');
