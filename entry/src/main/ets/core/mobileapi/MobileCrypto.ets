/*
 * 密码加密（`enc_password`）—— 逐字节对齐 instagrapi 的 `mixins/password.py`。
 *
 * ## instagrapi 那边的做法（原样搬过来）
 * ```python
 * publickeyid, publickey = self.password_publickeys()   # GET /api/v1/qe/sync/ 的响应头
 * session_key = os.urandom(32); iv = os.urandom(12); ts = str(int(time.time()))
 * rsa_encrypted = PKCS1_v1_5(RSA.import_key(b64decode(publickey))).encrypt(session_key)
 * aes = AES.new(session_key, AES.MODE_GCM, iv); aes.update(ts.encode())
 * aes_encrypted, tag = aes.encrypt_and_digest(password.encode())
 * payload = base64( b"\x01" + bytes([publickeyid]) + iv + len(rsa_encrypted).to_bytes(2,"little")
 *                  + rsa_encrypted + tag + aes_encrypted )
 * return f"#PWD_INSTAGRAM:4:{ts}:{payload}"
 * ```
 * 两个公钥材料（`ig-set-password-encryption-key-id` / `-pub-key`）由 `qe/sync/` 的
 * **响应头**下发，见 `MobileLogin.publicKeys()`。
 *
 * ## 为什么用系统 CryptoFramework 而不是自己写一遍
 * RSA PKCS#1 v1.5 + AES-GCM 都是"实现差一位就全错"的东西；鸿蒙的
 * `@kit.CryptoArchitectureKit` 两样都现成（`RSA1024|PKCS1` / `AES256|GCM|NoPadding`），
 * 而且 AEAD 的 authTag 语义在文档里写得很清楚（加密时输出末尾 16 字节就是 tag）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileCrypto';

/** `qe/sync/` 响应头里那两样东西。 */
export class PasswordKeys {
  readonly keyId: number;
  readonly publicKeyBase64: string;

  constructor(keyId: number, publicKeyBase64: string) {
    this.keyId = keyId;
    this.publicKeyBase64 = publicKeyBase64;
  }

  isUsable(): boolean {
    return this.keyId > 0 && this.publicKeyBase64.length > 0;
  }
}

export class MobileCrypto {
  private static readonly IV_BYTES: number = 12;
  private static readonly KEY_BYTES: number = 32;
  private static readonly TAG_BYTES: number = 16;

  /**
   * 生成 `enc_password`（`#PWD_INSTAGRAM:4:<ts>:<base64>`）。
   *
   * @returns 空串 = 这一步失败（调用方据此提示"密码加密失败"，不要退回明文发密码）
   */
  static async encryptPassword(password: string, keys: PasswordKeys): Promise<string> {
    if (password.length === 0 || !keys.isUsable()) {
      return '';
    }
    try {
      const sessionKey: Uint8Array = MobileCrypto.randomBytes(MobileCrypto.KEY_BYTES);
      const iv: Uint8Array = MobileCrypto.randomBytes(MobileCrypto.IV_BYTES);
      const timestamp: string = `${Math.floor(Date.now() / 1000)}`;
      const rsaEncrypted: Uint8Array | null =
        await MobileCrypto.rsaEncrypt(sessionKey, keys.publicKeyBase64);
      if (rsaEncrypted === null) {
        return '';
      }
      const aes: CryptoBox | null =
        await MobileCrypto.aesGcmEncrypt(password, sessionKey, iv, timestamp);
      if (aes === null) {
        return '';
      }
      // 拼包：0x01 | keyId(1B BE) | iv(12) | len(rsa)(2B LE) | rsa | tag(16) | cipher
      const total: number = 1 + 1 + MobileCrypto.IV_BYTES + 2 + rsaEncrypted.length
        + aes.tag.length + aes.cipher.length;
      const out: Uint8Array = new Uint8Array(total);
      let at: number = 0;
      out[at++] = 0x01;
      out[at++] = keys.keyId & 0xFF;
      out.set(iv, at);
      at += iv.length;
      out[at++] = rsaEncrypted.length & 0xFF;             // little-endian 低字节
      out[at++] = (rsaEncrypted.length >> 8) & 0xFF;      // 高字节
      out.set(rsaEncrypted, at);
      at += rsaEncrypted.length;
      out.set(aes.tag, at);
      at += aes.tag.length;
      out.set(aes.cipher, at);
      const base64: string = new util.Base64Helper().encodeToStringSync(out);
      hilog.info(DOMAIN, TAG, 'enc_password ok keyId=%{public}d rsa=%{public}d total=%{public}d',
        keys.keyId, rsaEncrypted.length, total);
      return `#PWD_INSTAGRAM:4:${timestamp}:${base64}`;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'encryptPassword threw: %{public}s', (error as Error).message);
      return '';
    }
  }

  /**
   * RSA PKCS#1 v1.5 加密。
   *
   * 公钥的形状有个坑（线上实测）：`ig-set-password-encryption-pub-key` 是
   * **"PEM 文本"再做 base64** —— 解开后是 `-----BEGIN PUBLIC KEY-----\nMIIBIj…`，
   * 不是裸 DER。instagrapi 直接把这段文本喂给 `RSA.import_key()`（它能吃 PEM），
   * 而鸿蒙的 `convertKey` 只认 DER，所以这里要把 PEM 盔甲剥掉再解一次 base64。
   */
  private static async rsaEncrypt(data: Uint8Array, publicKeyBase64: string): Promise<Uint8Array | null> {
    const der: Uint8Array | null = MobileCrypto.derFromPublicKey(publicKeyBase64);
    if (der === null) {
      hilog.warn(DOMAIN, TAG, 'public key decode failed');
      return null;
    }
    // IG 现在的密钥是 **2048 位**（key id 176），旧版本见过 1024。两档都试，别因为换密钥就整条登录挂掉。
    const algs: Array<string> = ['RSA2048|PKCS1', 'RSA1024|PKCS1'];
    const generators: Array<string> = ['RSA2048', 'RSA1024'];
    for (let index: number = 0; index < algs.length; index++) {
      try {
        const generator: cryptoFramework.AsyKeyGenerator =
          cryptoFramework.createAsyKeyGenerator(generators[index]);
        const pair: cryptoFramework.KeyPair =
          await generator.convertKey({ data: der }, null);
        const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(algs[index]);
        await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, pair.pubKey, null);
        const encrypted: cryptoFramework.DataBlob = await cipher.doFinal({ data: data });
        hilog.info(DOMAIN, TAG, 'rsa %{public}s ok %{public}d→%{public}d',
          algs[index], data.length, encrypted.data.length);
        return encrypted.data;
      } catch (error) {
        hilog.info(DOMAIN, TAG, 'rsa with %{public}s failed: %{public}s',
          algs[index], (error as Error).message);
      }
    }
    return null;
  }

  /**
   * 公钥 base64 → DER 字节。
   *
   * 两种形状都认：① 裸 DER（base64 后第一段是 `MII…`）；② **PEM 文本**再 base64
   * （解开以 `-----BEGIN` 开头）。网上那份公钥现在是第 ② 种。
   */
  private static derFromPublicKey(publicKeyBase64: string): Uint8Array | null {
    const helper: util.Base64Helper = new util.Base64Helper();
    let raw: Uint8Array;
    try {
      raw = helper.decodeSync(publicKeyBase64.trim());
    } catch (error) {
      return null;
    }
    if (raw.length === 0) {
      return null;
    }
    const pemText: string = new util.TextDecoder().decodeToString(raw);
    const head: string = pemText.substring(0, 32);
    if (head.indexOf('-----BEGIN') < 0) {
      // 已经是 DER（裸二进制）。
      return raw;
    }
    // PEM：去掉盔甲行，剩下的 base64 再解一次。
    const lines: Array<string> = pemText.split('\n');
    let body: string = '';
    for (let index: number = 0; index < lines.length; index++) {
      const line: string = lines[index].trim();
      if (line.length === 0 || line.startsWith('-----')) {
        continue;
      }
      body += line;
    }
    if (body.length === 0) {
      return null;
    }
    try {
      return helper.decodeSync(body);
    } catch (error) {
      return null;
    }
  }

  /** AES-256-GCM 加密；返回密文与 16 字节 tag（GCM 契约：doFinal 输出末尾 16 字节是 tag）。 */
  private static async aesGcmEncrypt(text: string, key: Uint8Array, iv: Uint8Array,
                                     aad: string): Promise<CryptoBox | null> {
    try {
      const generator: cryptoFramework.SymKeyGenerator =
        cryptoFramework.createSymKeyGenerator('AES256');
      const symKey: cryptoFramework.SymKey = await generator.convertKey({ data: key });
      const params: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec',
        iv: { data: iv },
        aad: { data: new util.TextEncoder().encodeInto(aad) },
        authTag: { data: new Uint8Array(MobileCrypto.TAG_BYTES) }
      };
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
      const out: cryptoFramework.DataBlob =
        await cipher.doFinal({ data: new util.TextEncoder().encodeInto(text) });
      if (out.data.length < MobileCrypto.TAG_BYTES) {
        hilog.warn(DOMAIN, TAG, 'aes output too short: %{public}d', out.data.length);
        return null;
      }
      const cipherLength: number = out.data.length - MobileCrypto.TAG_BYTES;
      const body: Uint8Array = out.data.slice(0, cipherLength);
      const tag: Uint8Array = out.data.slice(cipherLength);
      return new CryptoBox(body, tag);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'aes gcm failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /** 随机字节（`cryptoFramework.Random`）。 */
  private static randomBytes(length: number): Uint8Array {
    try {
      const random: cryptoFramework.Random = cryptoFramework.createRandom();
      const blob: cryptoFramework.DataBlob = random.generateRandomSync(length);
      return blob.data;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'random failed: %{public}s', (error as Error).message);
      // 兜底：用 Math.random 凑（只在系统随机不可用时走到这里；质量差但不至于整条链断）。
      const out: Uint8Array = new Uint8Array(length);
      for (let index: number = 0; index < length; index++) {
        out[index] = Math.floor(Math.random() * 256);
      }
      return out;
    }
  }
}

/** 一次 AES-GCM 加密的产物（密文与认证标签分开）。 */
class CryptoBox {
  readonly cipher: Uint8Array;
  readonly tag: Uint8Array;

  constructor(cipher: Uint8Array, tag: Uint8Array) {
    this.cipher = cipher;
    this.tag = tag;
  }
}
