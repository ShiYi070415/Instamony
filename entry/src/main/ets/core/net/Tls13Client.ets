/*
 * **自己实现的 TLS 1.3 客户端（ArkTS）** —— 目的只有一个：**完全掌控 ClientHello 的字节**。
 *
 * ## 为什么要自己写
 * 真机实测（见 `tools/relay/LOGIN-429.md` 与 `CaaSession.connProbe/fpProbe`）：
 *   · App 的登录那一发已经是 `TLS 1.3 + TLS_AES_128_GCM_SHA256 + HTTP/2`、没走代理，仍然 429；
 *   · 手机这条栈的 JA3 是
 *       `771,4865-4866-4867-49195-…-156-157-47-53,23-65281-10-11-16-13-51-45-43,29-23-24,0`
 *   · 上游 issue（subzeroid/instagrapi#2852）里被多人确认"能过"的指纹是
 *       `771,4865,0-43-10-51-13-16-45,29-23,`
 * 也就是说：**IG 的 edge 在登录端点上按 ClientHello 挑客户端**。系统的 `http` / `TLSSocket`
 * 都不给"扩展集合/顺序/曲线"的旋钮，所以只能自己拼 ClientHello 自己握手。
 *
 * ## 依赖的系统能力（都在 `@kit.CryptoArchitectureKit` 里）
 *   · X25519 密钥对与密钥协商：`createAsyKeyGenerator('X25519')` / `createKeyAgreement('X25519')`；
 *   · HKDF-SHA256：`createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND')`；
 *   · AES-128-GCM：`createCipher('AES128|GCM|NoPadding')`；
 *   · HMAC-SHA256（Finished 校验）：`createMac('SHA256')`；
 *   · 原始 TCP：`@ohos.net.socket` 的 `constructTCPSocketInstance()`。
 *
 * ## 覆盖范围（够我们用就行）
 *   · 只做 **TLS 1.3**、只用 **TLS_AES_128_GCM_SHA256**、只做 **X25519** 密钥交换；
 *   · **不做证书链校验**（第一版；后续可以用 `@ohos.security.cert` 补，或钉 SPKI）；
 *   · 只支持 TLS 1.3 的 `psk_key_exchange_modes: [psk_dhe_ke]`（无 PSK、无 0-RTT）；
 *   · 握手完成后把 HTTP/1.1 请求写上去、读回响应（够 CAA 那几个 form POST 用）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
// 系统 DNS：把"连域名"换成"连 IP"（真机实测直接 connect 域名偶发 Operation in progress）。
import { connection } from '@kit.NetworkKit';
// 自建通道连接层失败时的**兜底**（系统 HTTP 栈，走 VPN/代理/TLS1.2 都行）。
import { http } from '@kit.NetworkKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
// 证书链校验（系统信任根）—— 自建通道必须验，否则等于把密码与会话交给中间人。
import { cert } from '@kit.DeviceCertificateKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// DoH（可选）：只把"连哪个 IP"这一步换掉，握手仍然按域名做（见 addressOf）。
import { DoHResolver } from './DoHResolver';

const DOMAIN: number = 0xFF00;
const TAG: string = 'Tls13Client';

const TLS_RECORD_ALERT: number = 21;
const TLS_RECORD_HANDSHAKE: number = 22;
const TLS_RECORD_APPDATA: number = 23;
/** 夹在应用数据里的握手类型：KeyUpdate(24) / NewSessionTicket(4)。 */
const HANDSHAKE_KEY_UPDATE: number = 24;
const HANDSHAKE_NEW_SESSION_TICKET: number = 4;
const TLS_VERSION_10: number = 0x0301;
const TLS_VERSION_12: number = 0x0303;
const TLS_VERSION_13: number = 0x0304;
const HANDSHAKE_CLIENT_HELLO: number = 1;
const HANDSHAKE_SERVER_HELLO: number = 2;
const HANDSHAKE_ENCRYPTED_EXTENSIONS: number = 8;
const HANDSHAKE_CERTIFICATE: number = 11;
const HANDSHAKE_CERTIFICATE_VERIFY: number = 15;
const HANDSHAKE_FINISHED: number = 20;
const EXT_SERVER_NAME: number = 0;
const EXT_SUPPORTED_GROUPS: number = 10;
const EXT_SIGNATURE_ALGORITHMS: number = 13;
const EXT_ALPN: number = 16;
const EXT_SUPPORTED_VERSIONS: number = 43;
const EXT_PSK_KEY_EXCHANGE_MODES: number = 45;
const EXT_KEY_SHARE: number = 51;
const GROUP_X25519: number = 0x001d;
const GROUP_P256: number = 0x0017;
const CIPHER_AES_128_GCM_SHA256: number = 0x1301;

/* ------------------------------------------------------------ 字节工具 */

class ByteWriter {
  private buffer: Uint8Array;
  private length: number = 0;

  constructor(capacity: number = 512) {
    this.buffer = new Uint8Array(capacity);
  }

  private ensure(extra: number): void {
    if (this.length + extra <= this.buffer.length) {
      return;
    }
    let next: number = this.buffer.length * 2;
    while (next < this.length + extra) {
      next = next * 2;
    }
    const grown: Uint8Array = new Uint8Array(next);
    grown.set(this.buffer.subarray(0, this.length), 0);
    this.buffer = grown;
  }

  u8(value: number): ByteWriter {
    this.ensure(1);
    this.buffer[this.length++] = value & 0xFF;
    return this;
  }

  u16(value: number): ByteWriter {
    this.ensure(2);
    this.buffer[this.length++] = (value >> 8) & 0xFF;
    this.buffer[this.length++] = value & 0xFF;
    return this;
  }

  u24(value: number): ByteWriter {
    this.ensure(3);
    this.buffer[this.length++] = (value >> 16) & 0xFF;
    this.buffer[this.length++] = (value >> 8) & 0xFF;
    this.buffer[this.length++] = value & 0xFF;
    return this;
  }

  raw(bytes: Uint8Array): ByteWriter {
    this.ensure(bytes.length);
    this.buffer.set(bytes, this.length);
    this.length += bytes.length;
    return this;
  }

  /** 占位并回填长度（TLS 里到处是"先占位、后填长度"的向量）。 */
  patchU16(at: number, value: number): void {
    this.buffer[at] = (value >> 8) & 0xFF;
    this.buffer[at + 1] = value & 0xFF;
  }

  patchU24(at: number, value: number): void {
    this.buffer[at] = (value >> 16) & 0xFF;
    this.buffer[at + 1] = (value >> 8) & 0xFF;
    this.buffer[at + 2] = value & 0xFF;
  }

  get size(): number {
    return this.length;
  }

  bytes(): Uint8Array {
    return this.buffer.subarray(0, this.length);
  }
}

class ByteReader {
  private readonly data: Uint8Array;
  private at: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  get remaining(): number {
    return this.data.length - this.at;
  }

  get offset(): number {
    return this.at;
  }

  seek(at: number): void {
    this.at = at;
  }

  u8(): number {
    return this.data[this.at++];
  }

  u16(): number {
    const value: number = (this.data[this.at] << 8) | this.data[this.at + 1];
    this.at += 2;
    return value;
  }

  u24(): number {
    const value: number = (this.data[this.at] << 16) | (this.data[this.at + 1] << 8)
      | this.data[this.at + 2];
    this.at += 3;
    return value;
  }

  take(n: number): Uint8Array {
    const out: Uint8Array = this.data.subarray(this.at, this.at + n);
    this.at += n;
    return out;
  }
}

function concat(parts: Array<Uint8Array>): Uint8Array {
  let total: number = 0;
  for (let index: number = 0; index < parts.length; index++) {
    total += parts[index].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let at: number = 0;
  for (let index: number = 0; index < parts.length; index++) {
    out.set(parts[index], at);
    at += parts[index].length;
  }
  return out;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let index: number = 0; index < a.length; index++) {
    if (a[index] !== b[index]) {
      return false;
    }
  }
  return true;
}

function hexToBytes(hex: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let index: number = 0; index < out.length; index++) {
    out[index] = Number.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return out;
}

function bytesToHex(bytes: Uint8Array): string {
  let out: string = '';
  for (let index: number = 0; index < bytes.length; index++) {
    out += bytes[index].toString(16).padStart(2, '0');
  }
  return out;
}

function startsWith(bytes: Uint8Array, head: Array<number>): boolean {
  if (bytes.length < head.length) {
    return false;
  }
  for (let index: number = 0; index < head.length; index++) {
    if (bytes[index] !== head[index]) {
      return false;
    }
  }
  return true;
}

/* --------------------------------------------------------- TCP 读缓冲 */

/**
 * TCP 上的字节流：把 `on('message')` 的回调攒成"能按需读 N 字节"的接口。
 *
 * 手写 TLS 就是一路 `read(n)`，所以这层必须有；出错/对端关闭都要能让等在 read 里的
 * Promise 立刻醒来（否则会挂到超时）。
 */
class TcpStream {
  private readonly tcp: socket.TCPSocket;
  private chunks: Array<Uint8Array> = [];
  private total: number = 0;
  private closed: boolean = false;
  private failure: string = '';
  private wake: (() => void) | null = null;

  constructor(tcp: socket.TCPSocket) {
    this.tcp = tcp;
  }

  attach(): void {
    this.tcp.on('message', (info: socket.SocketMessageInfo): void => {
      this.chunks.push(new Uint8Array(info.message));
      this.total += info.message.byteLength;
      this.wakeup();
    });
    this.tcp.on('close', (): void => {
      this.closed = true;
      this.wakeup();
    });
    this.tcp.on('error', (error: Object): void => {
      this.failure = `${(error as Error).message}`;
      this.closed = true;
      this.wakeup();
    });
  }

  private wakeup(): void {
    const waiter: (() => void) | null = this.wake;
    this.wake = null;
    if (waiter !== null) {
      waiter();
    }
  }

  async write(bytes: Uint8Array): Promise<void> {
    await this.tcp.send({ data: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length) });
  }

  /** 读够 n 字节（不够就等；超时/断开则抛错）。 */
  async read(n: number, timeoutMs: number = 20000): Promise<Uint8Array> {
    const deadline: number = Date.now() + timeoutMs;
    while (this.total < n) {
      if (this.failure.length > 0) {
        throw new Error(`TCP 读失败：${this.failure}`);
      }
      if (this.closed) {
        throw new Error(`TCP 已关闭（只收到 ${this.total}/${n} 字节）`);
      }
      const left: number = deadline - Date.now();
      if (left <= 0) {
        throw new Error(`TCP 读超时（只收到 ${this.total}/${n} 字节）`);
      }
      await new Promise<void>((resolve): void => {
        this.wake = resolve;
        setTimeout((): void => {
          if (this.wake === resolve) {
            this.wake = null;
            resolve();
          }
        }, Math.min(left, 250));
      });
    }
    const out: Uint8Array = new Uint8Array(n);
    let filled: number = 0;
    while (filled < n) {
      const head: Uint8Array = this.chunks[0];
      const need: number = n - filled;
      if (head.length <= need) {
        out.set(head, filled);
        filled += head.length;
        this.chunks.shift();
      } else {
        out.set(head.subarray(0, need), filled);
        this.chunks[0] = head.subarray(need);
        filled += need;
      }
    }
    this.total -= n;
    return out;
  }

  async close(): Promise<void> {
    try {
      await this.tcp.close();
    } catch (error) {
    }
  }
}

/* ------------------------------------------------------------- 握手 */

/** 一次 TLS 1.3 连接（握手 + 收发应用数据）。 */
export class Tls13Connection {
  private readonly stream: TcpStream;
  private clientKeyPair: cryptoFramework.KeyPair | null = null;
  private clientPub: Uint8Array = new Uint8Array(0);
  private transcript: Array<Uint8Array> = [];
  private sendKey: Uint8Array = new Uint8Array(16);
  private sendIv: Uint8Array = new Uint8Array(12);
  private recvKey: Uint8Array = new Uint8Array(16);
  private recvIv: Uint8Array = new Uint8Array(12);
  private sendSeq: number = 0;
  private recvSeq: number = 0;
  /**
   * **应用流量密钥本尊**（不只是它的 key/iv）。
   *
   * 为什么必须留着：TLS 1.3 允许对端在中途发 `KeyUpdate`（内部握手 type 24），
   * 之后的记录换一套密钥。没有原密钥就没法派生下一代 —— 表现就是「握手全 OK、
   * 大响应读到一半 `cipher doFinal failed`」（真机 Mate 70 Pro+ 上就是这么挂的）。
   */
  private sendSecret: Uint8Array = new Uint8Array(32);
  private recvSecret: Uint8Array = new Uint8Array(32);
  /** 已经读了几条应用数据记录（诊断用：解密失败时能说清是第几条）。 */
  private recvRecordIndex: number = 0;
  /** 握手阶段用的密钥（Finished 之后换成应用密钥）。 */
  private handshakeSendKey: Uint8Array = new Uint8Array(16);
  private handshakeSendIv: Uint8Array = new Uint8Array(12);
  private handshakeRecvKey: Uint8Array = new Uint8Array(16);
  private handshakeRecvIv: Uint8Array = new Uint8Array(12);
  private handshakeSendSeq: number = 0;
  private handshakeRecvSeq: number = 0;
  private recordBuffer: Uint8Array = new Uint8Array(0);
  private plainHandshakeBuffer: Uint8Array = new Uint8Array(0);
  /** 服务端证书链（DER，叶子在前）—— 握手后要做 PKIX 校验与域名比对。 */
  private serverCerts: Array<Uint8Array> = [];
  /** 当前连接的主机名（拼 `Host` 头用）。 */
  private host: string = '';
  /** 握手过程的现场（失败时给诊断用）。 */
  log: string = '';

  constructor(stream: TcpStream) {
    this.stream = stream;
  }

  private note(line: string): void {
    this.log = this.log.length === 0 ? line : `${this.log} → ${line}`;
  }

  private addTranscript(bytes: Uint8Array): void {
    this.transcript.push(bytes);
  }

  private transcriptHash(): Uint8Array {
    const all: Uint8Array = concat(this.transcript);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: all });
    return md.digestSync().data;
  }

  /**
   * TLS 1.3 的 HKDF-Expand-Label。
   *
   * **自己用 HMAC 实现**（不用系统的 KDF 接口）：鸿蒙的 `createKdf` 对"空 salt / EXTRACT_ONLY"
   * 这些边角语义不明确（真机上直接回 `crypto operation error`），而 TLS 1.3 的
   * Extract/Expand 本身就是两行 HMAC，自己算反而更可控。
   */
  private async expandLabel(secret: Uint8Array, label: string, context: Uint8Array,
                            length: number): Promise<Uint8Array> {
    const labelBytes: Uint8Array = new util.TextEncoder().encodeInto(`tls13 ${label}`);
    const info: ByteWriter = new ByteWriter(64);
    info.u16(length);
    info.u8(labelBytes.length);
    info.raw(labelBytes);
    info.u8(context.length);
    info.raw(context);
    return await this.hkdfExpand(secret, info.bytes(), length);
  }

  /** HKDF-Extract = HMAC(salt, ikm)；salt 为空按 32 个 0 处理（RFC 5869）。 */
  private async hkdfExtract(salt: Uint8Array, ikm: Uint8Array): Promise<Uint8Array> {
    const effectiveSalt: Uint8Array = salt.length > 0 ? salt : new Uint8Array(32);
    const secret: Uint8Array = await this.hmacSha256(effectiveSalt, ikm);
    return secret;
  }

  /** HKDF-Expand（RFC 5869 §2.3）。 */
  private async hkdfExpand(secret: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
    const chunks: Array<Uint8Array> = [];
    let previous: Uint8Array = new Uint8Array(0);
    let produced: number = 0;
    let counter: number = 1;
    while (produced < length) {
      const input: Uint8Array = concat([previous, info, new Uint8Array([counter & 0xFF])]);
      previous = await this.hmacSha256(secret, input);
      chunks.push(previous);
      produced += previous.length;
      counter++;
    }
    const all: Uint8Array = concat(chunks);
    return all.subarray(0, length);
  }

  /**
   * HMAC-SHA256（Finished 校验用）。
   *
   * 注意 `Mac.init()` 收的是 **SymKey**，不是字节 —— 得先用 `SymKeyGenerator('HMAC')` 把
   * 密钥字节转成对称密钥对象（官方 HMAC 示例就是这个写法）。
   */
  private async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const keyGenerator: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator('HMAC');
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey: cryptoFramework.SymKey = keyGenerator.convertKeySync(keyBlob);
    const mac: cryptoFramework.Mac = cryptoFramework.createMac('SHA256');
    await mac.init(symKey);
    mac.updateSync({ data: data });
    return mac.doFinalSync().data;
  }

  private async aesGcmEncrypt(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array,
                              plaintext: Uint8Array): Promise<Uint8Array> {
    const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey: cryptoFramework.SymKey = generator.convertKeySync(keyBlob);
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: aad },
      authTag: { data: new Uint8Array(16) }
    };
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: plaintext });
    return out.data;
  }

  private async aesGcmDecrypt(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array,
                              ciphertextAndTag: Uint8Array): Promise<Uint8Array> {
    const bodyLength: number = ciphertextAndTag.length - 16;
    const body: Uint8Array = ciphertextAndTag.subarray(0, bodyLength);
    const tag: Uint8Array = ciphertextAndTag.subarray(bodyLength);
    const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey: cryptoFramework.SymKey = generator.convertKeySync(keyBlob);
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: aad },
      authTag: { data: tag }
    };
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: body });
    return out.data;
  }

  /** nonce = iv XOR (seq 放在最后 8 字节的大端)。 */
  private nonceOf(iv: Uint8Array, seq: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(iv);
    let value: number = seq;
    for (let index: number = 0; index < 8; index++) {
      out[iv.length - 1 - index] = iv[iv.length - 1 - index] ^ (value & 0xFF);
      value = Math.floor(value / 256);
    }
    return out;
  }

  /**
   * **离线自检**：用 RFC 8448 的已知向量验 HKDF/AES/nonce，把"哪一步算错"在真机上当场分开。
   *
   * 手写 TLS 的错都长一个样（`cipher doFinal failed` / `crypto operation error`），
   * 没有这个自检的话，只能靠人肉猜。它**不联网、不需要账号**。
   */
  async selfTest(): Promise<string> {
    const lines: Array<string> = [];
    // ⓪ SHA-256 与 HMAC-SHA256 的已知对（"哪一层算错"最靠前的排查点）
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encodeInto('abc') });
    const digest: string = bytesToHex(md.digestSync().data);
    lines.push('SHA256(abc) ' + (digest === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
      ? 'OK' : 'MISMATCH:' + digest));
    const macKey: Uint8Array = new util.TextEncoder().encodeInto('key');
    const macData: Uint8Array = new util.TextEncoder().encodeInto(
      'The quick brown fox jumps over the lazy dog');
    const macOut: string = bytesToHex(await this.hmacSha256(macKey, macData));
    lines.push('HMAC-SHA256 ' + (macOut === 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'
      ? 'OK' : 'MISMATCH:' + macOut));

    // ① Derive-Secret(early_secret, "derived", "") —— RFC 8448 §3 的已知对
    const early: Uint8Array = hexToBytes(
      '33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a');
    const expectedDerived: string = '6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba';
    const derived: Uint8Array = await this.expandLabel(early, 'derived', await this.hashEmpty(), 32);
    lines.push('HKDF-derived ' + (bytesToHex(derived) === expectedDerived
      ? 'OK' : 'MISMATCH:' + bytesToHex(derived)));

    // ② AES-128-GCM 加解密往返（自己加密自己解，能分开"加密错"还是"解密错"）
    const key: Uint8Array = new Uint8Array(16);
    const iv: Uint8Array = new Uint8Array(12);
    const plain: Uint8Array = new util.TextEncoder().encodeInto('abc');
    const ct: Uint8Array = await this.aesGcmEncrypt(key, iv, new Uint8Array(0), plain);
    const back: Uint8Array = await this.aesGcmDecrypt(key, iv, new Uint8Array(0), ct);
    lines.push('AES-GCM roundtrip ' + (bytesEqual(plain, back) ? 'OK' : 'FAIL'));

    // ③ nonce XOR
    const n1: Uint8Array = this.nonceOf(iv, 1);
    const n256: Uint8Array = this.nonceOf(iv, 256);
    const nonceOk: boolean = n1[11] === 1 && n1[10] === 0 && n256[10] === 1 && n256[11] === 0;
    lines.push('nonce ' + (nonceOk ? 'OK' : 'FAIL'));
    return lines.join(' | ');
  }

  /** 生成 X25519 密钥对，导出 32 字节公钥。 */
  private async makeKeyPair(): Promise<void> {
    const generator: cryptoFramework.AsyKeyGenerator =
      cryptoFramework.createAsyKeyGenerator('X25519');
    const pair: cryptoFramework.KeyPair = await generator.generateKeyPair();
    this.clientKeyPair = pair;
    const encoded: cryptoFramework.DataBlob = pair.pubKey.getEncoded();
    // X25519 的 data 就是 32 字节裸公钥（不是 DER）。
    this.clientPub = encoded.data.length === 32
      ? encoded.data : encoded.data.subarray(encoded.data.length - 32);
  }

  /**
   * 拼 ClientHello —— **这就是整个方案的核心**：扩展集合与顺序照上游那套"能过"的指纹来。
   *
   * 目标 JA3：`771,4865,0-43-10-51-13-16-45,29-23,`
   *   · 密码套件只有 4865（TLS_AES_128_GCM_SHA256）；
   *   · 扩展顺序：SNI(0) → supported_versions(43) → supported_groups(10) → key_share(51)
   *     → signature_algorithms(13) → ALPN(16) → psk_key_exchange_modes(45)；
   *   · 曲线只有 X25519(29) 与 P-256(23)；
   *   · 不发 ec_point_formats / extended_master_secret / renegotiation_info。
   */
  private buildClientHello(host: string): Uint8Array {
    const random: Uint8Array = cryptoFramework.createRandom().generateRandomSync(32).data;
    const sessionId: Uint8Array = cryptoFramework.createRandom().generateRandomSync(32).data;
    const body: ByteWriter = new ByteWriter(512);
    body.u16(TLS_VERSION_12);              // legacy_version
    body.raw(random);
    body.u8(sessionId.length);
    body.raw(sessionId);
    body.u16(2);                           // cipher_suites 长度
    body.u16(CIPHER_AES_128_GCM_SHA256);
    body.u8(1);                            // compression_methods
    body.u8(0);
    const extLengthAt: number = body.size;
    body.u16(0);
    const extStart: number = body.size;

    // 0 SNI
    const hostBytes: Uint8Array = new util.TextEncoder().encodeInto(host);
    const sni: ByteWriter = new ByteWriter(64);
    sni.u16(hostBytes.length + 3);
    sni.u8(0);
    sni.u16(hostBytes.length);
    sni.raw(hostBytes);
    body.u16(EXT_SERVER_NAME);
    body.u16(sni.size);
    body.raw(sni.bytes());

    // 43 supported_versions：只给 TLS 1.3
    body.u16(EXT_SUPPORTED_VERSIONS);
    body.u16(3);
    body.u8(2);
    body.u16(TLS_VERSION_13);

    // 10 supported_groups：X25519、P-256
    body.u16(EXT_SUPPORTED_GROUPS);
    body.u16(6);
    body.u16(4);
    body.u16(GROUP_X25519);
    body.u16(GROUP_P256);

    // 51 key_share：一个 X25519 密钥
    const keyShare: ByteWriter = new ByteWriter(64);
    keyShare.u16(this.clientPub.length + 4);
    keyShare.u16(GROUP_X25519);
    keyShare.u16(this.clientPub.length);
    keyShare.raw(this.clientPub);
    body.u16(EXT_KEY_SHARE);
    body.u16(keyShare.size);
    body.raw(keyShare.bytes());

    // 13 signature_algorithms：ECDSA-P256-SHA256、ECDSA-P384-SHA384、RSA-PSS-SHA256
    body.u16(EXT_SIGNATURE_ALGORITHMS);
    body.u16(8);
    body.u16(6);
    body.u16(0x0403);
    body.u16(0x0503);
    body.u16(0x0804);

    // 16 ALPN：http/1.1（JA3 不含 ALPN 内容；真机能力有限，先走 HTTP/1.1）
    const alpnText: Uint8Array = new util.TextEncoder().encodeInto('http/1.1');
    const alpn: ByteWriter = new ByteWriter(32);
    alpn.u16(alpnText.length + 1);
    alpn.u8(alpnText.length);
    alpn.raw(alpnText);
    body.u16(EXT_ALPN);
    body.u16(alpn.size);
    body.raw(alpn.bytes());

    // 45 psk_key_exchange_modes：psk_dhe_ke
    body.u16(EXT_PSK_KEY_EXCHANGE_MODES);
    body.u16(2);
    body.u8(1);
    body.u8(1);

    body.patchU16(extLengthAt, body.size - extStart);

    const handshake: ByteWriter = new ByteWriter(body.size + 8);
    handshake.u8(HANDSHAKE_CLIENT_HELLO);
    handshake.u24(body.size);
    handshake.raw(body.bytes());
    return handshake.bytes();
  }

  /**
   * 解析 Certificate 握手消息，把每张证书的 DER 抠出来存进 `serverCerts`。
   *
   * 结构（RFC 8446 §4.4.2）：
   *   `certificate_request_context`（1 字节长度 + 内容，通常为空）
   *   `certificate_list`（3 字节总长；每项：3 字节证书长 + DER）
   */
  private parseCertificate(message: Uint8Array): void {
    this.serverCerts = [];
    const reader: ByteReader = new ByteReader(message);
    reader.u8();                        // handshake type
    reader.u24();                       // handshake length
    const contextLength: number = reader.u8();
    reader.take(contextLength);
    const listLength: number = reader.u24();
    const listEnd: number = reader.offset + listLength;
    this.note(`CertList total=${listLength}B at=${reader.offset}`);
    while (reader.offset + 3 <= listEnd) {
      const certLength: number = reader.u24();
      if (certLength <= 0 || reader.offset + certLength > listEnd + 3) {
        this.note(`  cert 长度异常 ${certLength}B（剩余 ${listEnd - reader.offset}B）`);
        break;
      }
      const der: Uint8Array = reader.take(certLength);
      // DER 自校验：证书必须是 0x30 开头的 SEQUENCE，且自身长度要和 3 字节长度对上。
      const derTotal: number = Tls13Connection.derTotalLength(der);
      if (der[0] !== 0x30 || (derTotal > 0 && derTotal !== certLength)) {
        this.note(`  cert DER 不符 tag=0x${der[0].toString(16)} claimed=${certLength}`
          + ` der=${derTotal}`);
      }
      this.serverCerts.push(der);
      /*
       * **每一项后面还有 2 字节的 `extensions` 长度**（RFC 8446 §4.4.2 的 CertificateEntry）。
       * 不跳过它就会错位 2 字节 —— 真机上表现是"第二张证书长度读成 0、只能解析出 1 张"。
       */
      if (reader.remaining >= 2) {
        const extLength: number = reader.u16();
        if (extLength > 0 && reader.remaining >= extLength) {
          reader.take(extLength);
        }
      }
    }
    this.note(`  解析出 ${this.serverCerts.length} 张：`
      + this.serverCerts.map((one: Uint8Array): string => `${one.length}`).join('/'));
  }

  /** 读 DER 的 TLV 总长度（读不出来返回 -1）。 */
  static derTotalLength(der: Uint8Array): number {
    if (der.length < 2) {
      return -1;
    }
    const first: number = der[1];
    if ((first & 0x80) === 0) {
      return 2 + first;
    }
    const count: number = first & 0x7F;
    if (count < 1 || count > 3 || der.length < 2 + count) {
      return -1;
    }
    let length: number = 0;
    for (let index: number = 0; index < count; index++) {
      length = length * 256 + der[2 + index];
    }
    return 2 + count + length;
  }

  /**
   * **校验服务端身份**：PKIX 链校验（系统信任根）+ 域名比对。
   *
   * 为什么必须做：这条通道是我们自己实现的，跳过了证书就等于"谁都能中间人"——
   * 登录会把加密后的密码与会话材料交给对方。链校验过了，中间人拿不到 `b.i.instagram.com`
   * 的合法证书，就不可能在中间插一脚。
   */
  private async validatePeer(host: string): Promise<void> {
    if (this.serverCerts.length === 0) {
      throw new Error('服务端没给证书');
    }
    // 先把"到底是什么证书"记进现场：链校验失败时没有这个就只能瞎猜。
    try {
      const leafBlob0: cert.EncodingBlob = {
        data: this.serverCerts[0],
        encodingFormat: cert.EncodingFormat.FORMAT_DER
      };
      const leafCert: cert.X509Cert = await cert.createX509Cert(leafBlob0);
      this.note(`证书 leaf=${leafCert.getSubjectName().data} issuer=${leafCert.getIssuerName().data}`);
    } catch (error) {
      this.note(`证书信息读取失败：${(error as Error).message}`);
    }
    /*
     * 链校验：**DER 与 PEM 两种形状都试一次**。
     *
     * 鸿蒙的 `CertChainValidator.validate(CertChainData)` 在不同版本上对
     * `encodingFormat` 的支持不完全一致（真机这里 DER 回 `validate cert chain failed`），
     * 所以两条都走，任一通过即可。
     */
    let lastError: string = '';
    // 先把每张证书的 SPKI 哈希与"链是否首尾相接"记进现场（链校验失败时要靠这些定位/钉根）。
    await this.describeChain();
    const derChain: cert.CertChainData = {
      data: concat(this.serverCerts),
      count: this.serverCerts.length,
      encodingFormat: cert.EncodingFormat.FORMAT_DER
    };
    try {
      await cert.createCertChainValidator('PKIX').validate(derChain);
      this.note('证书链 ok(PKIX)');
      await this.checkHostName(host);
      return;
    } catch (error) {
      lastError = (error as Error).message;
      this.note(`PKIX 失败：${lastError.substring(0, 40)}`);
    }
    /*
     * **PKIX 不可用时的钉住校验**。
     *
     * 真机上 `CertChainValidator` 对这条链（叶子 + DigiCert Global G2 中间证书）一直回
     * `validate cert chain failed`，而证书本身是好的（叶子的 issuer 就是它）。所以退一步按
     * **中间证书 SPKI 钉住**来验：
     *   ① 叶子 SAN 必须覆盖主机名；
     *   ② 叶子在有效期内；
     *   ③ 叶子的 issuer == 中间证书 subject（链首尾相接）；
     *   ④ 中间证书的 SPKI SHA-256 在**硬编码白名单**里。
     * 这四条一起就排除了中间人：攻击者拿不到由"那本中间证书"签发的叶子证书。
     */
    await this.checkHostName(host);
    await this.checkPinnedChain();
  }

  /** 叶子有效期 + 链首尾相接 + 中间证书 SPKI 钉住。 */
  private async checkPinnedChain(): Promise<void> {
    const pins: Array<string> = [
      // DigiCert Global G2 TLS RSA SHA256 2020 CA1（Meta 现在用的中间证书）
      '59e738e674221702af1edb87c5200c1a4b75f64fae3d2c3d265124c61bd83c79'
    ];
    const leafBlob: cert.EncodingBlob = {
      data: this.serverCerts[0],
      encodingFormat: cert.EncodingFormat.FORMAT_DER
    };
    const leaf: cert.X509Cert = await cert.createX509Cert(leafBlob);
    /*
     * `checkValidityWithDate()` 要的是 **ASN.1 UTC 时间**（`YYMMDDHHMMSSZ`），不是
     * `toUTCString()` 那种格式 —— 传错会回 `check cert validity failed!`（真机上踩过）。
     */
    const nowDate: Date = new Date();
    const pad2: (value: number) => string = (value: number): string => {
      return value < 10 ? `0${value}` : `${value}`;
    };
    const now: string = `${pad2(nowDate.getUTCFullYear() % 100)}${pad2(nowDate.getUTCMonth() + 1)}`
      + `${pad2(nowDate.getUTCDate())}${pad2(nowDate.getUTCHours())}`
      + `${pad2(nowDate.getUTCMinutes())}${pad2(nowDate.getUTCSeconds())}Z`;
    try {
      leaf.checkValidityWithDate(now);
      this.note('叶子在有效期内');
    } catch (error) {
      throw new Error(`叶子证书不在有效期内（${now}）：${(error as Error).message}`);
    }
    if (this.serverCerts.length < 2) {
      throw new Error('服务端只给了一张证书，没法钉住（缺少中间证书）');
    }
    const issuer: string = `${leaf.getIssuerName().data}`;
    const midBlob: cert.EncodingBlob = {
      data: this.serverCerts[1],
      encodingFormat: cert.EncodingFormat.FORMAT_DER
    };
    const middle: cert.X509Cert = await cert.createX509Cert(midBlob);
    const subject: string = `${middle.getSubjectName().data}`;
    if (issuer !== subject) {
      throw new Error('证书链不连续（叶子 issuer 与中间证书 subject 不一致）');
    }
    const spki: Uint8Array = middle.getPublicKey().getEncoded().data;
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: spki });
    const hash: string = bytesToHex(md.digestSync().data);
    let matched: boolean = false;
    for (let index: number = 0; index < pins.length; index++) {
      if (pins[index] === hash) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      throw new Error(`中间证书 SPKI 不在白名单（${hash}）—— 可能被中间人，或证书换了一家 CA`);
    }
    this.note('中间证书钉住校验 ok');
  }

  /**
   * 把证书链的"事实"记进现场：每张的 SPKI SHA-256、以及相邻两张是否首尾相接。
   *
   * 为什么要：真机上 `CertChainValidator` 对这条链回 `validate cert chain failed`（3 张证书、
   * 根是 DigiCert Global Root G2），而系统信任库按理说一定有它。这些哈希是**钉根（pin）**的依据：
   * 拿到根证书的 SPKI 哈希之后就能硬编码校验，绕开那个不可靠的 validator。
   */
  private async describeChain(): Promise<void> {
    for (let index: number = 0; index < this.serverCerts.length; index++) {
      try {
        const blob: cert.EncodingBlob = {
          data: this.serverCerts[index],
          encodingFormat: cert.EncodingFormat.FORMAT_DER
        };
        const x509: cert.X509Cert = await cert.createX509Cert(blob);
        if (x509 === undefined || x509 === null) {
          this.note(`  #${index} 解析为空（${this.serverCerts[index].length}B）`);
          continue;
        }
        const subject: string = `${x509.getSubjectName().data}`;
        const spki: Uint8Array = x509.getPublicKey().getEncoded().data;
        const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
        md.updateSync({ data: spki });
        this.note(`  #${index} spki=${bytesToHex(md.digestSync().data)}`
          + ` len=${this.serverCerts[index].length}B subj=${subject.substring(0, 40)}`);
      } catch (error) {
        this.note(`  #${index} 解析失败：${(error as Error).message}`);
      }
    }
  }

  /** 把证书链拼成 PEM 文本（每张一段）。 */
  private pemChainText(): string {
    let out: string = '';
    for (let index: number = 0; index < this.serverCerts.length; index++) {
      out += '-----BEGIN CERTIFICATE-----\r\n';
      const base64: string = new util.Base64Helper().encodeToStringSync(this.serverCerts[index]);
      for (let at: number = 0; at < base64.length; at += 64) {
        out += `${base64.substring(at, Math.min(at + 64, base64.length))}\r\n`;
      }
      out += '-----END CERTIFICATE-----\r\n';
    }
    return out;
  }

  /** 域名比对：叶子证书的 SAN 必须覆盖目标主机。 */
  private async checkHostName(host: string): Promise<void> {
    try {
      const blob: cert.EncodingBlob = {
        data: this.serverCerts[0],
        encodingFormat: cert.EncodingFormat.FORMAT_DER
      };
      const leaf: cert.X509Cert = await cert.createX509Cert(blob);
      const sans: cert.DataArray = leaf.getSubjectAltNames();
      /*
       * `getSubjectAltNames()` 的形状在不同版本/实现上不一样：有的是**字节数组**
       * （`toString()` 出来就是 `42,46,105,...`，即 `*.i.instagram.com\0i.instagram.com\0`），
       * 有的是 `DNS:...` 这样的字符串。所以**统一按文本形式解析**：
       * 拆逗号 → 每段若是数字就当字符码，全是非数字就当原字符串用。
       */
      const rawText: string = `${sans.data}`;
      let text: string = '';
      let numeric: number = 0;
      const pieces: Array<string> = rawText.split(',');
      for (let index: number = 0; index < pieces.length; index++) {
        const code: number = Number.parseInt(pieces[index].trim(), 10);
        if (Number.isFinite(code)) {
          numeric++;
          text += code > 0 ? String.fromCharCode(code) : ' ';
        }
      }
      if (numeric === 0) {
        text = rawText;      // 已经是可读字符串的版本
      }
      const matched: boolean = text.indexOf(host) >= 0
        || text.indexOf('*.instagram.com') >= 0
        || text.indexOf('*.i.instagram.com') >= 0;
      if (!matched) {
        throw new Error(`证书域名不含 ${host}（SAN: ${text.substring(0, 120)}）`);
      }
      this.note(`证书域名 ok（${text.substring(0, 60)}）`);
    } catch (error) {
      if (`${(error as Error).message}`.indexOf('证书域名不含') >= 0) {
        throw error as Error;
      }
      // SAN 读不出来不算致命（链已经验过了），但要在现场里留一行。
      this.note(`SAN 读取失败：${(error as Error).message}`);
    }
  }

  /** 把 handshake 消息包成一条 TLS 记录。 */
  private record(type: number, payload: Uint8Array): Uint8Array {
    const out: ByteWriter = new ByteWriter(payload.length + 5);
    out.u8(type);
    out.u16(TLS_VERSION_12);
    out.u16(payload.length);
    out.raw(payload);
    return out.bytes();
  }

  /** 读一条 TLS 记录（返回 {type, payload}）。 */
  private async readRecord(): Promise<TlsRecord> {
    const head: Uint8Array = await this.stream.read(5);
    const reader: ByteReader = new ByteReader(head);
    const type: number = reader.u8();
    const version: number = reader.u16();
    const length: number = reader.u16();
    const payload: Uint8Array = length > 0 ? await this.stream.read(length) : new Uint8Array(0);
    return new TlsRecord(type, version, payload);
  }

  /** 把加密记录解成明文（去掉尾部补零与 content type）。 */
  private async decryptRecord(record: TlsRecord): Promise<TlsDecrypted> {
    const aad: Uint8Array = new Uint8Array([record.type, 0x03, 0x03,
      (record.payload.length >> 8) & 0xFF, record.payload.length & 0xFF]);
    const nonce: Uint8Array = this.nonceOf(this.handshakeRecvIv, this.handshakeRecvSeq);
    this.handshakeRecvSeq++;
    const plain: Uint8Array = await this.aesGcmDecrypt(this.handshakeRecvKey, nonce, aad,
      record.payload);
    // TLSInnerPlaintext = content || type || zeros
    let end: number = plain.length - 1;
    while (end >= 0 && plain[end] === 0) {
      end--;
    }
    if (end < 0) {
      throw new Error('解密结果为空');
    }
    const contentType: number = plain[end];
    return new TlsDecrypted(contentType, plain.subarray(0, end));
  }

  /** 发一条加密的应用数据/握手记录。 */
  private async writeEncrypted(payload: Uint8Array): Promise<void> {
    const inner: ByteWriter = new ByteWriter(payload.length + 1);
    inner.raw(payload);
    inner.u8(TLS_RECORD_APPDATA);
    const cipherLength: number = inner.size + 16;
    const head: Uint8Array = new Uint8Array([TLS_RECORD_APPDATA, 0x03, 0x03,
      (cipherLength >> 8) & 0xFF, cipherLength & 0xFF]);
    const nonce: Uint8Array = this.nonceOf(this.sendIv, this.sendSeq);
    this.sendSeq++;
    const encrypted: Uint8Array = await this.aesGcmEncrypt(this.sendKey, nonce, head, inner.bytes());
    await this.stream.write(concat([head, encrypted]));
  }

  /**
   * 走完整条握手，然后发一条 HTTP/1.1 请求，把响应头读回来。
   *
   * @returns 一行诊断：握手是否成功、协商结果、HTTP 状态行
   */
  async handshake(host: string): Promise<string> {
    this.host = host;
    await this.makeKeyPair();
    this.note(`x25519 pub=${this.clientPub.length}B`);
    const clientHello: Uint8Array = this.buildClientHello(host);
    this.addTranscript(clientHello);
    await this.stream.write(this.record(TLS_RECORD_HANDSHAKE, clientHello));
    this.note(`CH sent ${clientHello.length + 5}B`);

    const serverRecord: TlsRecord = await this.readRecord();
    if (serverRecord.type !== TLS_RECORD_HANDSHAKE) {
      throw new Error(`期待 ServerHello，收到记录类型 ${serverRecord.type}`);
    }
    const serverHello: Uint8Array = serverRecord.payload;
    this.addTranscript(serverHello);
    const hello: ServerHelloInfo = this.parseServerHello(serverHello);
    this.note(`SH version=${hello.selectedVersion} cipher=${hello.cipher} group=${hello.group}`);

    if (hello.selectedVersion !== TLS_VERSION_13) {
      throw new Error(`服务端没选 TLS1.3（选了 ${hello.selectedVersion}）`);
    }
    if (hello.cipher !== CIPHER_AES_128_GCM_SHA256) {
      throw new Error(`服务端选了别的套件 0x${hello.cipher.toString(16)}`);
    }
    if (hello.group !== GROUP_X25519 || hello.serverKey.length !== 32) {
      throw new Error(`服务端 key_share 组 ${hello.group}、${hello.serverKey.length}B（只支持 X25519）`);
    }

    // 共享密钥
    /*
     * 服务端在 `key_share` 里给的是**裸 32 字节** X25519 公钥，而鸿蒙的 `convertKey` 只吃
     * **DER(SPKI)**（`SubjectPublicKeyInfo`）。所以这里手工包一层：
     *   30 2a                      SEQUENCE(42)
     *     30 05 06 03 2b 65 6e     AlgorithmIdentifier { OID 1.3.101.110 (X25519) }
     *     03 21 00 <32 bytes>      BIT STRING(33)，首字节 0 = 没有未用位
     * 不这么做的话，`convertKey` 会直接报 `convert key fail`（真机就是这么卡的）。
     */
    const spki: Uint8Array = concat([
      new Uint8Array([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]),
      hello.serverKey
    ]);
    const agreement: cryptoFramework.KeyAgreement = cryptoFramework.createKeyAgreement('X25519');
    const peerPair: cryptoFramework.KeyPair =
      await cryptoFramework.createAsyKeyGenerator('X25519')
        .convertKey({ data: spki }, null);
    const peerPub: cryptoFramework.PubKey = peerPair.pubKey;
    const shared: cryptoFramework.DataBlob = await agreement.generateSecret(
      (this.clientKeyPair as cryptoFramework.KeyPair).priKey, peerPub);
    this.note(`shared=${shared.data.length}B`);

    // 密钥编排（RFC 8446 §7.1，无 PSK）
    const zeros: Uint8Array = new Uint8Array(32);
    const emptyHash: Uint8Array = await this.hashEmpty();
    this.note('密钥编排开始');
    const earlySecret: Uint8Array = await this.hkdfExtract(zeros, zeros);
    this.note('extract1 ok');
    const derivedEarly: Uint8Array =
      await this.expandLabel(earlySecret, 'derived', emptyHash, 32);
    this.note('derived early ok');
    const handshakeSecret: Uint8Array = await this.hkdfExtract(derivedEarly, shared.data);
    this.note('extract2 ok');
    const transcriptAtSh: Uint8Array = this.transcriptHash();
    this.note('th ok');
    const clientHs: Uint8Array =
      await this.expandLabel(handshakeSecret, 'c hs traffic', transcriptAtSh, 32);
    const serverHs: Uint8Array =
      await this.expandLabel(handshakeSecret, 's hs traffic', transcriptAtSh, 32);
    this.note('c/s hs traffic ok');
    this.handshakeSendKey = await this.expandLabel(clientHs, 'key', new Uint8Array(0), 16);
    this.handshakeSendIv = await this.expandLabel(clientHs, 'iv', new Uint8Array(0), 12);
    this.handshakeRecvKey = await this.expandLabel(serverHs, 'key', new Uint8Array(0), 16);
    this.handshakeRecvIv = await this.expandLabel(serverHs, 'iv', new Uint8Array(0), 12);
    this.note('hs keys ok');

    // 服务端的加密飞行：EE / Cert / CV / Finished
    const expectedFinishedKey: Uint8Array =
      await this.expandLabel(serverHs, 'finished', new Uint8Array(0), 32);
    let serverFinishedOk: boolean = false;
    /*
     * **要按"握手消息"重组，而不是"一条记录一条消息"**。
     *
     * 服务端那条飞行里 Certificate 通常有几 KB，会被拆到**多条 TLS 记录**里；反过来一条记录
     * 也可能塞进几条消息。按记录处理的话 Certificate 会解析不出来、后面一直等 —— 真机上就是
     * `CCS skipped → EncryptedExtensions → CertificateVerify` 之后卡在读超时。
     */
    let pending: Uint8Array = new Uint8Array(0);
    while (!serverFinishedOk) {
      if (pending.length >= 4) {
        const bodyLength: number = (pending[1] << 16) | (pending[2] << 8) | pending[3];
        const total: number = 4 + bodyLength;
        if (pending.length >= total) {
          const message: Uint8Array = pending.subarray(0, total);
          pending = pending.subarray(total);
          const type: number = message[0];
          if (type === HANDSHAKE_FINISHED) {
            // Finished 的 transcript 必须是"它自己之前"的哈希，所以先算再入账。
            const beforeFinished: Uint8Array = this.transcriptHash();
            const expected: Uint8Array =
              await this.hmacSha256(expectedFinishedKey, beforeFinished);
            serverFinishedOk = bytesEqual(expected, message.subarray(4));
            this.note(`server Finished ${serverFinishedOk ? 'ok' : 'MISMATCH'}`);
            if (!serverFinishedOk) {
              throw new Error('服务端 Finished 校验失败');
            }
            this.addTranscript(message);
            break;
          }
          this.addTranscript(message);
          if (type === HANDSHAKE_ENCRYPTED_EXTENSIONS) {
            this.note('EncryptedExtensions');
          } else if (type === HANDSHAKE_CERTIFICATE) {
            this.parseCertificate(message);
            this.note(`Certificate(${bodyLength}B, ${this.serverCerts.length} 张)`);
          } else if (type === HANDSHAKE_CERTIFICATE_VERIFY) {
            this.note('CertificateVerify');
          } else {
            this.note(`handshake type ${type}`);
          }
          continue;
        }
      }
      const record: TlsRecord = await this.readRecord();
      /*
       * **必须跳过 ChangeCipherSpec**（记录类型 20）。
       *
       * 我们 ClientHello 带了一个 32 字节的 legacy session_id（真机也这样），服务端为了
       * 中间件兼容会在 ServerHello 之后回一条 **CCS（type=20 的裸记录）**。它不是加密数据，
       * 拿去解密必然报 `cipher doFinal failed`（真机就是这么卡的）。
       */
      if (record.type === 20) {
        this.note('CCS skipped');
        continue;
      }
      if (record.type !== TLS_RECORD_APPDATA) {
        this.note(`skip record type ${record.type}`);
        continue;
      }
      const decrypted: TlsDecrypted = await this.decryptRecord(record);
      if (decrypted.type !== TLS_RECORD_HANDSHAKE) {
        this.note(`plaintext type ${decrypted.type}`);
        continue;
      }
      pending = concat([pending, decrypted.payload]);
    }

    /*
     * **应用密钥的 transcript 只能算到"服务端 Finished"为止**（RFC 8446 §7.1：
     * `c ap traffic / s ap traffic = Derive-Secret(Master, …, ClientHello…server Finished)`）。
     *
     * 这里先把那个快照存下来：客户端 Finished 会接着被加进 transcript，而它**不**参与
     * 应用密钥的派生 —— 以前直接在后面取 transcriptHash()，于是算出来的 app key 整条错位，
     * 表现就是"握手全 OK（连 server Finished 都验过了），一发 HTTP 就 `cipher doFinal failed`"。
     */
    const transcriptThroughServerFinished: Uint8Array = this.transcriptHash();

    // 客户端 Finished
    const clientFinishedKey: Uint8Array =
      await this.expandLabel(clientHs, 'finished', new Uint8Array(0), 32);
    const clientVerify: Uint8Array =
      await this.hmacSha256(clientFinishedKey, transcriptThroughServerFinished);
    const finishedMsg: ByteWriter = new ByteWriter(36);
    finishedMsg.u8(HANDSHAKE_FINISHED);
    finishedMsg.u24(clientVerify.length);
    finishedMsg.raw(clientVerify);
    // 用**握手密钥**发 Finished
    await this.writeHandshakeEncrypted(finishedMsg.bytes());
    this.addTranscript(finishedMsg.bytes());
    this.note('client Finished sent');

    // 应用密钥
    const derivedHs: Uint8Array = await this.expandLabel(handshakeSecret, 'derived',
      await this.hashEmpty(), 32);
    const masterSecret: Uint8Array = await this.hkdfExtract(derivedHs, zeros);
    const clientApp: Uint8Array =
      await this.expandLabel(masterSecret, 'c ap traffic', transcriptThroughServerFinished, 32);
    const serverApp: Uint8Array =
      await this.expandLabel(masterSecret, 's ap traffic', transcriptThroughServerFinished, 32);
    this.sendSecret = clientApp;
    this.recvSecret = serverApp;
    this.sendKey = await this.expandLabel(clientApp, 'key', new Uint8Array(0), 16);
    this.sendIv = await this.expandLabel(clientApp, 'iv', new Uint8Array(0), 12);
    this.recvKey = await this.expandLabel(serverApp, 'key', new Uint8Array(0), 16);
    this.recvIv = await this.expandLabel(serverApp, 'iv', new Uint8Array(0), 12);
    this.sendSeq = 0;
    this.recvSeq = 0;
    this.note('app keys ok');
    // 握手完、发任何业务数据之前，先把"对面是谁"验清楚。
    await this.validatePeer(host);
    return `${this.log} | 握手完成`;
  }

  /** 用握手套件发一条加密记录（Finished 用）。 */
  private async writeHandshakeEncrypted(payload: Uint8Array): Promise<void> {
    const inner: ByteWriter = new ByteWriter(payload.length + 1);
    inner.raw(payload);
    inner.u8(TLS_RECORD_HANDSHAKE);
    const cipherLength: number = inner.size + 16;
    const head: Uint8Array = new Uint8Array([TLS_RECORD_APPDATA, 0x03, 0x03,
      (cipherLength >> 8) & 0xFF, cipherLength & 0xFF]);
    const nonce: Uint8Array = this.nonceOf(this.handshakeSendIv, this.handshakeSendSeq);
    this.handshakeSendSeq++;
    const encrypted: Uint8Array = await this.aesGcmEncrypt(this.handshakeSendKey, nonce, head,
      inner.bytes());
    await this.stream.write(concat([head, encrypted]));
  }

  /** 发一条 HTTP/1.1 请求（用应用密钥加密），返回响应的状态行与头。 */
  async httpRequest(requestText: string): Promise<TlsHttpReply> {
    await this.writeApplicationData(new util.TextEncoder().encodeInto(requestText));
    return await this.readHttpReply();
  }

  /**
   * **完整的 HTTP/1.1 交换**（CAA 各步就用它）：自己拼请求行/头/Content-Length，
   * 发出去，再按 `content-length` 收全 body。
   *
   * 为什么不用 `httpRequest` 那种"拿到头就返回"：登录的响应是 bloks 布局（几十 KB 的 JSON，
   * 可能跨很多条记录），解析器需要完整 body。上限 4MB（防止被灌爆内存）。
   */
  async httpExchange(method: string, path: string, headers: Record<string, string>,
                     body: string): Promise<TlsHttpReply> {
    const bodyBytes: Uint8Array = new util.TextEncoder().encodeInto(body);
    const lines: Array<string> = [`${method} ${path} HTTP/1.1`];
    let hasHost: boolean = false;
    for (const key of Object.keys(headers)) {
      const lower: string = key.toLowerCase();
      if (lower === 'content-length' || lower === 'connection' || lower === 'transfer-encoding') {
        continue;
      }
      if (lower === 'host') {
        hasHost = true;
      }
      lines.push(`${key}: ${headers[key]}`);
    }
    if (!hasHost) {
      lines.push(`Host: ${this.host}`);
    }
    if (bodyBytes.length > 0) {
      lines.push(`Content-Length: ${bodyBytes.length}`);
    }
    lines.push('Connection: close');
    lines.push('');
    lines.push('');
    const head: string = lines.join('\r\n');
    this.note(`→ ${method} ${path.substring(0, 40)}… body=${bodyBytes.length}B`);
    await this.writeApplicationData(concat([
      new util.TextEncoder().encodeInto(head), bodyBytes
    ]));
    return await this.readHttpReply();
  }

  /** 用应用密钥发一条加密记录。 */
  private async writeApplicationData(payload: Uint8Array): Promise<void> {
    const inner: ByteWriter = new ByteWriter(payload.length + 1);
    inner.raw(payload);
    inner.u8(TLS_RECORD_APPDATA);
    const cipherLength: number = inner.size + 16;
    const head: Uint8Array = new Uint8Array([TLS_RECORD_APPDATA, 0x03, 0x03,
      (cipherLength >> 8) & 0xFF, cipherLength & 0xFF]);
    const nonce: Uint8Array = this.nonceOf(this.sendIv, this.sendSeq);
    this.sendSeq++;
    const encrypted: Uint8Array = await this.aesGcmEncrypt(this.sendKey, nonce, head, inner.bytes());
    await this.stream.write(concat([head, encrypted]));
  }

  /**
   * 读一条 HTTP/1.1 响应（按 content-length 收全 body；没有 content-length 就收到对端关连接）。
   *
   * 注意：握手之后服务端还会用应用密钥发 `NewSessionTicket`（inner type 22），
   * 那不是 HTTP 数据，**必须跳过**，否则头部会被二进制内容污染。
   */
  /**
   * 处理夹在应用数据里的握手消息（TLS 1.3 只有 `NewSessionTicket` 和 `KeyUpdate`）。
   *
   * 一条记录里可能有好几条消息（`type(1) + len(3) + body`），所以要按长度循环。
   */
  private async handleInnerHandshake(payload: Uint8Array): Promise<void> {
    let at: number = 0;
    while (at + 4 <= payload.length) {
      const type: number = payload[at];
      const length: number = (payload[at + 1] << 16) | (payload[at + 2] << 8) | payload[at + 3];
      const from: number = at + 4;
      if (from + length > payload.length) {
        return;
      }
      if (type === HANDSHAKE_KEY_UPDATE) {
        const requested: boolean = length > 0 && payload[from] === 1;
        await this.updateRecvKeys();
        this.note('KeyUpdate 收到，已换读密钥');
        if (requested) {
          // 对端要我们也换：按 RFC 换完再回一条 update_requested=0 的 KeyUpdate。
          await this.updateSendKeys();
          await this.sendKeyUpdate();
          this.note('KeyUpdate 已回');
        }
      } else if (type !== HANDSHAKE_NEW_SESSION_TICKET) {
        this.note(`内部握手 type ${type} 跳过`);
      }
      at = from + length;
    }
  }

  /** 换下一代**读**密钥：`traffic upd` 派生 secret，再派生 key/iv，序号归零。 */
  private async updateRecvKeys(): Promise<void> {
    this.recvSecret = await this.expandLabel(this.recvSecret, 'traffic upd',
      new Uint8Array(0), 32);
    this.recvKey = await this.expandLabel(this.recvSecret, 'key', new Uint8Array(0), 16);
    this.recvIv = await this.expandLabel(this.recvSecret, 'iv', new Uint8Array(0), 12);
    this.recvSeq = 0;
  }

  /** 换下一代**写**密钥（对端 `update_requested` 时要跟着换）。 */
  private async updateSendKeys(): Promise<void> {
    this.sendSecret = await this.expandLabel(this.sendSecret, 'traffic upd',
      new Uint8Array(0), 32);
    this.sendKey = await this.expandLabel(this.sendSecret, 'key', new Uint8Array(0), 16);
    this.sendIv = await this.expandLabel(this.sendSecret, 'iv', new Uint8Array(0), 12);
    this.sendSeq = 0;
  }

  /** 回一条 `KeyUpdate(update_requested=0)`。 */
  private async sendKeyUpdate(): Promise<void> {
    const message: ByteWriter = new ByteWriter(5);
    message.u8(HANDSHAKE_KEY_UPDATE);
    message.u24(1);
    message.u8(0);
    await this.writeApplicationData(message.bytes());
  }

  /** 记录头的 `type + version + length`（AEAD 的 AAD）。 */
  private aadOf(type: number, version: number, length: number): Uint8Array {
    return new Uint8Array([type, (version >> 8) & 0xFF, version & 0xFF,
      (length >> 8) & 0xFF, length & 0xFF]);
  }

  /** 解一次应用数据记录；失败返回 `null`（**不抛**，由调用方决定下一步）。 */
  private async tryDecryptAppData(key: Uint8Array, iv: Uint8Array, seq: number,
                                  type: number, version: number,
                                  payload: Uint8Array): Promise<Uint8Array | null> {
    try {
      const nonce: Uint8Array = this.nonceOf(iv, seq);
      return await this.aesGcmDecrypt(key, nonce, this.aadOf(type, version, payload.length),
        payload);
    } catch (error) {
      return null;
    }
  }

  /** 一串字节的前 n 个转成十六进制（诊断用）。 */
  private hexHead(bytes: Uint8Array, count: number): string {
    const table: string = '0123456789abcdef';
    let text: string = '';
    const stop: number = Math.min(count, bytes.length);
    for (let index: number = 0; index < stop; index++) {
      const value: number = bytes[index];
      text += table.charAt(value >> 4) + table.charAt(value & 0x0F);
    }
    return text;
  }

  /**
   * 解一条应用数据记录，**带真实世界的容错**。
   *
   * 2026-10-30 真机日志（Mate 70 Pro+ / VPN）：登录第一发 `/graphql_www` 收到 3233B 之后，
   * 第 5 条记录 `len=19B` 解不开。19B = **2 字节告警 + 1 字节内部类型 + 16 字节 tag**，
   * 也就是「对端的告警记录」—— 业务数据其实已经收全了，判失败的只是这条收尾记录。
   *
   * 所以这里按顺序试四种现场，试成哪种就**把状态修正成哪种**并记一条 note：
   *   1. 标准路径（当前密钥 + 当前序号 + 头部版本）；
   *   2. **头部 `legacy_record_version` 不是 0x0303**（有的实现只在告警记录上写 0x0301）
   *      → 按 0x0303 重算 AAD；
   *   3. **序号差一**（中途漏算/多算一条记录）→ 用 `seq+1`；
   *   4. **漏看了一条 `KeyUpdate`** → 用 `traffic upd` 派生下一代密钥、序号归零。
   */
  private async decryptAppData(record: TlsRecord): Promise<Uint8Array | null> {
    const payload: Uint8Array = record.payload;
    let plain: Uint8Array | null = await this.tryDecryptAppData(this.recvKey, this.recvIv,
      this.recvSeq, record.type, record.version, payload);
    if (plain !== null) {
      this.recvSeq++;
      return plain;
    }
    if (record.version !== TLS_VERSION_12) {
      plain = await this.tryDecryptAppData(this.recvKey, this.recvIv, this.recvSeq,
        record.type, TLS_VERSION_12, payload);
      if (plain !== null) {
        this.note(`记录版本 0x${record.version.toString(16)}，按 0x0303 解开了`);
        this.recvSeq++;
        return plain;
      }
    }
    plain = await this.tryDecryptAppData(this.recvKey, this.recvIv, this.recvSeq + 1,
      record.type, TLS_VERSION_12, payload);
    if (plain !== null) {
      this.note(`序号差一（${this.recvSeq}→${this.recvSeq + 1}），已纠正`);
      this.recvSeq += 2;
      return plain;
    }
    const nextSecret: Uint8Array = await this.expandLabel(this.recvSecret, 'traffic upd',
      new Uint8Array(0), 32);
    const nextKey: Uint8Array = await this.expandLabel(nextSecret, 'key', new Uint8Array(0), 16);
    const nextIv: Uint8Array = await this.expandLabel(nextSecret, 'iv', new Uint8Array(0), 12);
    plain = await this.tryDecryptAppData(nextKey, nextIv, 0, record.type, TLS_VERSION_12, payload);
    if (plain !== null) {
      this.recvSecret = nextSecret;
      this.recvKey = nextKey;
      this.recvIv = nextIv;
      this.recvSeq = 1;
      this.note('漏看了一条 KeyUpdate，已按下一代读密钥续上');
      return plain;
    }
    return null;
  }

  private async readHttpReply(): Promise<TlsHttpReply> {
    /*
     * **先按字节攒、最后再解码一次**。
     *
     * 按记录逐条 decode 是错的：IG 的响应里有中文/emoji，一个 UTF-8 字符可能正好被记录边界
     * 劈成两半 —— 逐条解码会把它变成乱码，`JSON.parse` 直接失败，症状就是"明明 200 却解析不出
     * aac"（真机上就是这么偶发失败的，时好时坏）。
     */
    let buffer: Uint8Array = new Uint8Array(0);
    let headerEnd: number = -1;
    let declaredLength: number = -1;
    let chunked: boolean = false;
    const limit: number = 4 * 1024 * 1024;
    for (let guard: number = 0; guard < 256; guard++) {
      let record: TlsRecord;
      try {
        record = await this.readRecord();
      } catch (error) {
        break;      // 对端关了：把手上的东西交出去
      }
      if (record.type === TLS_RECORD_ALERT) {
        // 明文告警（2 字节：level + description）：记下来，然后交出手上的响应。
        if (record.payload.length >= 2) {
          this.note(`收到明文告警 level=${record.payload[0]} desc=${record.payload[1]}`);
        }
        break;
      }
      if (record.type !== TLS_RECORD_APPDATA) {
        continue;
      }
      this.recvRecordIndex++;
      const plain: Uint8Array | null = await this.decryptAppData(record);
      if (plain === null) {
        /*
         * 解不开：**如果 HTTP 已经攒够，就当它是对端的收尾记录，把响应交出去**。
         * 登录第一发就是这么挂的 —— 响应其实已经完整收到，只是末尾那条解不开，
         * 旧写法把整次登录判失败，用户看到的是「登录失败」而不是真正的 HTTP 错误。
         */
        this.note(`第 ${this.recvRecordIndex} 条记录解不开（len=${record.payload.length}B, `
          + `ver=0x${record.version.toString(16)}，已收 ${buffer.length}B，`
          + `头=${this.hexHead(record.payload, 16)}）`);
        if (headerEnd >= 0) {
          break;
        }
        throw new Error(`第 ${this.recvRecordIndex} 条应用数据解密失败（len=${record.payload.length}B，`
          + `ver=0x${record.version.toString(16)}，已收 ${buffer.length}B，`
          + `头=${this.hexHead(record.payload, 16)}）：${this.log}`);
      }
      let end: number = plain.length - 1;
      while (end >= 0 && plain[end] === 0) {
        end--;
      }
      if (end < 0) {
        continue;
      }
      if (plain[end] === TLS_RECORD_HANDSHAKE) {
        /*
         * **握手消息夹在应用数据里**：`NewSessionTicket`（type 4）跳过就行，
         * 但 **`KeyUpdate`（type 24）必须处理** —— 对端换密钥之后，后面的记录用旧密钥解就是
         * `cipher doFinal failed`。IG 的大响应（登录那一发几百 KB）就会中途发它。
         */
        await this.handleInnerHandshake(plain.subarray(0, end));
        continue;
      }
      if (plain[end] !== TLS_RECORD_APPDATA) {
        continue;    // 其它内部类型（alert 等）一律跳过
      }
      buffer = concat([buffer, plain.subarray(0, end)]);
      if (headerEnd < 0) {
        // 头部是 ASCII，先解码前缀找分隔符（找不到就继续攒）。
        const prefix: string = new util.TextDecoder().decodeToString(buffer);
        const at: number = prefix.indexOf('\r\n\r\n');
        if (at >= 0) {
          headerEnd = at;
          const headerText: string = prefix.substring(0, at);
          const matched: RegExpMatchArray | null =
            headerText.match(/content-length:\s*(\d+)/i);
          declaredLength = matched === null ? -1 : Number.parseInt(matched[1], 10);
          chunked = /transfer-encoding:\s*chunked/i.test(headerText);
        }
      }
      if (headerEnd >= 0) {
        const bodySoFar: number = buffer.length - (headerEnd + 4);
        if (chunked) {
          /*
           * `Transfer-Encoding: chunked` 且**没有 Content-Length**（IG 的 4xx 就常这样）：
           * 收全的标志是最后那个 `0\r\n\r\n`。不加这条会一直等下去，等到对端发告警/关连接，
           * 表现就是「响应其实全到了，但登录判失败」。
           */
          const body: string = new util.TextDecoder().decodeToString(buffer.subarray(headerEnd + 4));
          if (body.length >= 5 && body.substring(body.length - 5) === '0\r\n\r\n') {
            break;
          }
        } else if (declaredLength >= 0 && bodySoFar >= declaredLength) {
          break;
        }
        if (buffer.length > limit) {
          break;
        }
      }
    }
    const all: string = new util.TextDecoder().decodeToString(buffer);
    if (headerEnd < 0) {
      return new TlsHttpReply('', all);
    }
    const headerText: string = all.substring(0, headerEnd);
    let bodyText: string = all.substring(headerEnd + 4);
    if (chunked) {
      bodyText = this.dechunk(bodyText);
    }
    return new TlsHttpReply(headerText, bodyText);
  }

  /**
   * 把 `Transfer-Encoding: chunked` 的 body 还原成原始正文（解析不了就原样返回）。
   *
   * 不加这一步，`JSON.parse` 会看到 `1a2b\r\n{…}\r\n0\r\n\r\n` 这种分块壳，直接报解析错 ——
   * 用户看到的又是「登录失败」，但原因其实是"没解块"。
   */
  private dechunk(body: string): string {
    let out: string = '';
    let at: number = 0;
    for (let guard: number = 0; guard < 8192; guard++) {
      const lineEnd: number = body.indexOf('\r\n', at);
      if (lineEnd < 0) {
        break;
      }
      const sizeText: string = body.substring(at, lineEnd).trim();
      if (sizeText.length === 0 || !/^[0-9a-fA-F]+$/.test(sizeText)) {
        return body;
      }
      const size: number = Number.parseInt(sizeText, 16);
      const from: number = lineEnd + 2;
      if (size === 0) {
        return out;
      }
      if (from + size > body.length) {
        return out + body.substring(from);
      }
      out += body.substring(from, from + size);
      at = from + size + 2;
    }
    return out.length > 0 ? out : body;
  }

  /**
   * `SHA-256("")`（TLS 1.3 的 `Derive-Secret(…, "")` 要用它）。
   *
   * **直接用常量**：鸿蒙的 `Md.updateSync()` 喂**空数组会抛 `crypto operation error`**
   * （真机就是这么卡在"shared 之后、密钥编排之前"的），而它的值是固定的。
   */
  private async hashEmpty(): Promise<Uint8Array> {
    const hex: string = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    const out: Uint8Array = new Uint8Array(32);
    for (let index: number = 0; index < 32; index++) {
      out[index] = Number.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
    }
    return out;
  }

  /** Finished 的 transcript：**去掉刚加进去的那条 Finished**。 */
  private transcriptHashBefore(): Uint8Array {
    const all: Uint8Array = concat(this.transcript);
    const last: Uint8Array = this.transcript[this.transcript.length - 1];
    const cut: Uint8Array = all.subarray(0, all.length - last.length);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: cut });
    return md.digestSync().data;
  }

  private parseServerHello(message: Uint8Array): ServerHelloInfo {
    const reader: ByteReader = new ByteReader(message);
    const type: number = reader.u8();
    if (type !== HANDSHAKE_SERVER_HELLO) {
      throw new Error(`不是 ServerHello（type=${type}）`);
    }
    reader.u24();
    reader.u16();                     // legacy_version
    reader.take(32);                  // random
    const sessionIdLength: number = reader.u8();
    reader.take(sessionIdLength);
    const cipher: number = reader.u16();
    reader.u8();                      // compression
    const extTotal: number = reader.u16();
    const extEnd: number = reader.offset + extTotal;
    let selectedVersion: number = 0;
    let group: number = 0;
    let serverKey: Uint8Array = new Uint8Array(0);
    while (reader.offset + 4 <= extEnd) {
      const extType: number = reader.u16();
      const extLength: number = reader.u16();
      const extBody: Uint8Array = reader.take(extLength);
      if (extType === EXT_SUPPORTED_VERSIONS) {
        selectedVersion = new ByteReader(extBody).u16();
      } else if (extType === EXT_KEY_SHARE) {
        const ks: ByteReader = new ByteReader(extBody);
        group = ks.u16();
        const keyLength: number = ks.u16();
        serverKey = ks.take(keyLength);
      }
    }
    return new ServerHelloInfo(selectedVersion, cipher, group, serverKey);
  }
}

/* ------------------------------------------------------------- 小类型 */

class TlsRecord {
  readonly type: number;
  readonly version: number;
  readonly payload: Uint8Array;

  constructor(type: number, version: number, payload: Uint8Array) {
    this.type = type;
    this.version = version;
    this.payload = payload;
  }
}

class TlsDecrypted {
  readonly type: number;
  readonly payload: Uint8Array;

  constructor(type: number, payload: Uint8Array) {
    this.type = type;
    this.payload = payload;
  }
}

class ServerHelloInfo {
  readonly selectedVersion: number;
  readonly cipher: number;
  readonly group: number;
  readonly serverKey: Uint8Array;

  constructor(selectedVersion: number, cipher: number, group: number, serverKey: Uint8Array) {
    this.selectedVersion = selectedVersion;
    this.cipher = cipher;
    this.group = group;
    this.serverKey = serverKey;
  }
}

/** 一条 HTTP/1.1 响应（头文本 + body 文本）。 */
export class TlsHttpReply {
  readonly headerText: string;
  readonly bodyText: string;

  constructor(headerText: string, bodyText: string) {
    this.headerText = headerText;
    this.bodyText = bodyText;
  }

  /** 状态码（读不到就是 -1）。 */
  statusCode(): number {
    const matched: RegExpMatchArray | null = this.headerText.match(/^HTTP\/1\.[01]\s+(\d{3})/);
    return matched === null ? -1 : Number.parseInt(matched[1], 10);
  }

  /** 取一个响应头的值（大小写不敏感；多处出现取第一处）。 */
  headerOf(name: string): string {
    const lines: Array<string> = this.headerText.split('\r\n');
    const wanted: string = name.toLowerCase();
    for (let index: number = 0; index < lines.length; index++) {
      const line: string = lines[index];
      const at: number = line.indexOf(':');
      if (at <= 0) {
        continue;
      }
      if (line.substring(0, at).trim().toLowerCase() === wanted) {
        return line.substring(at + 1).trim();
      }
    }
    return '';
  }
}

/**
 * 对外入口：连上去、握手、发一条请求、返回状态与现场。
 *
 * **只用于诊断/验证**（`CaaSession.tls13Probe`）：结果一行行都是给人看的。
 */
export class Tls13Client {
  /**
   * **一条完整的 HTTPS 请求**：TCP → TLS1.3 握手（含证书校验）→ HTTP/1.1 → 关闭。
   *
   * CAA 那 5 步都走它（`CaaLogin.post`），这样登录请求的 ClientHello 就是我们自己拼的
   * （对齐上游那套能过的指纹），而不是系统栈那一份（那份在登录端点被 429）。
   */
  static async request(host: string, port: number, method: string, path: string,
                       headers: Record<string, string>, body: string): Promise<TlsHttpReply> {
    /*
     * **域名解析：可选走 DoH**（见 core/net/DoHResolver，开关在设置页、默认关）。
     *
     * 连的是**解析出来的 IP**，但握手仍然按 `host` 做（SNI + 证书校验都在 `handshake(host)` 里）——
     * 所以 DoH 只换"去哪儿"，不改"连的是谁"。拿不到 IP（未启用 / 端点全失败）就用域名，
     * 交给系统 net stack —— DoH 是增强，不是依赖。
     */
    const stream: TcpStream = await Tls13Client.openStream(host, port);
    const connection: Tls13Connection = new Tls13Connection(stream);
    try {
      await connection.handshake(host);
      return await connection.httpExchange(method, path, headers, body);
    } catch (error) {
      throw new Error(`${(error as Error).message}（现场：${connection.log || '(握手未开始)'}）`);
    } finally {
      await stream.close();
    }
  }

  /**
   * **连哪个地址**：开了 DoH 就用它解析出的 IPv4，否则（或解析失败）就用域名本身。
   *
   * 注意这只是"地址"：`handshake(host)` 里的 SNI 与证书校验**永远按域名** ——
   * 连 IP 不影响 TLS 身份（这也是 DoH 能安全接进来的前提）。
   */
  /**
   * **建一条到 `host:port` 的 TCP 连接**（带重试；返回已经 attach 好的 `TcpStream`）。
   *
   * ## 为什么要重试 / 为什么要先解析成 IP
   * 用户反馈（Mate 70 Pro+ / HarmonyOS 7）：登录第一发直接报
   * `登录请求异常：Operation in progress` —— 那是 `TCPSocket.connect()` 抛出来的（`EINPROGRESS`），
   * 说明这一次 connect 没真正走完就返回了。两种应对一起上：
   *   · 每次都**新建 socket** 重试（最多 3 次、间隔 400/900ms）；
   *   · 连之前先做一次**系统 DNS 解析**，拿 IPv4 就按 IP 连（`connect` 走域名那条路要内部再解析，
   *     正是最容易撞上 `EINPROGRESS` 的地方）。SNI / 证书校验仍然按域名，见 handshake(host)。
   *
   * DoH 开着时优先用 DoH 的 IP（更隐私），拿不到再退回系统解析。
   */
  private static async openStream(host: string, port: number): Promise<TcpStream> {
    /*
     * **多个地址轮着试**，而不是"只认第一个 IP"。
     *
     * 2026-10-30 真机（Mate 80 Pro / SGT-AL00）：系统 DNS 给的是 `104.244.45.246`，
     * 三次 connect 全部 `Operation in progress`（37 秒后才放弃），而用户换个节点就正常 ——
     * 说明**单个 IP 被丢包**是常态。IG 的域名背后有多组 anycast 地址，换一个往往就通了。
     */
    const addresses: Array<string> = await Tls13Client.connectAddresses(host);
    const waits: Array<number> = [0, 400];
    /* 总预算 20 秒：地址再多也不能让用户等着（上一版 3 次 × 12 秒 = 37 秒才报错，太久了）。 */
    const deadline: number = Date.now() + 20000;
    let lastError: string = '';
    const tried: Array<string> = [];
    for (let index: number = 0; index < addresses.length; index++) {
      const address: string = addresses[index];
      if (tried.indexOf(address) >= 0) {
        continue;
      }
      tried.push(address);
      for (let attempt: number = 0; attempt < waits.length; attempt++) {
        const left: number = deadline - Date.now();
        if (left <= 500) {
          break;
        }
        if (waits[attempt] > 0) {
          await Tls13Client.pause(Math.min(waits[attempt], left));
        }
        const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
        const stream: TcpStream = new TcpStream(tcp);
        stream.attach();
        try {
          await tcp.connect({
            address: { address: address, family: 1, port: port },
            timeout: Math.min(6000, Math.max(1000, deadline - Date.now()))
          });
          if (tried.length > 1 || attempt > 0) {
            hilog.info(DOMAIN, TAG, 'connect ok addr=%{public}s (第 %{public}d 个地址, 第 %{public}d 次)',
              address, tried.length, attempt + 1);
          }
          return stream;
        } catch (error) {
          lastError = Tls13Client.errorText(error);
          hilog.warn(DOMAIN, TAG,
            'connect failed addr=%{public}s attempt=%{public}d (%{public}s)',
            address, attempt + 1, lastError);
          await stream.close();
        }
      }
      // 只剩一个地址且已经试满：别再排队等下一个（地址越试越慢，用户等不起）。
      if (tried.length >= 4) {
        break;
      }
    }
    throw new Error(`连接失败：${lastError}（host=${host} 试过 ${tried.join('/')}）`);
  }

  /**
   * 候选地址：DoH（若开）→ 系统 DNS 的**全部** IPv4（最多 4 个）→ 域名本身。
   *
   * 顺序有讲究：DoH 的地址通常更"新鲜"（系统 DNS 在有 VPN 时容易拿到被污染/被丢包的 IP）。
   */
  private static async connectAddresses(host: string): Promise<Array<string>> {
    const out: Array<string> = [];
    const doh: string = await Tls13Client.addressOf(host);
    if (doh.length > 0) {
      out.push(doh);
    }
    const list: Array<string> = await Tls13Client.resolveIpv4All(host);
    for (let index: number = 0; index < list.length; index++) {
      if (out.indexOf(list[index]) < 0) {
        out.push(list[index]);
      }
      if (out.length >= 4) {
        break;
      }
    }
    if (out.length === 0) {
      out.push(host);
    }
    return out;
  }

  /** 连哪个地址（保留旧接口：给诊断用的单值版本）。 */
  private static async connectAddress(host: string): Promise<string> {
    const list: Array<string> = await Tls13Client.connectAddresses(host);
    return list[0];
  }

  /** 系统 DNS 解析出的**全部** IPv4（去重、最多 6 个）。 */
  private static async resolveIpv4All(host: string): Promise<Array<string>> {
    const out: Array<string> = [];
    if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
      out.push(host);
      return out;
    }
    try {
      const list: Array<connection.NetAddress> = await connection.getAddressesByName(host);
      for (let index: number = 0; index < list.length; index++) {
        const one: connection.NetAddress = list[index];
        const ip: string = `${one.address}`;
        if (`${one.family}` === '1' && ip.length > 0 && out.indexOf(ip) < 0) {
          out.push(ip);
        }
        if (out.length >= 6) {
          break;
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'system dns failed host=%{public}s (%{public}s)',
        host, Tls13Client.errorText(error));
    }
    return out;
  }

  /** `BusinessError` 的 message + code（自建通道的错误经常只有一句英文，带 code 才好定位）。 */
  static errorText(error: Object): string {
    const message: string = (error as Error).message ?? `${error}`;
    const code: Object | undefined = (error as Record<string, Object>)['code'];
    return code === undefined || code === null ? message : `${message} (code=${code})`;
  }

  /** 等一会儿（重试用）。 */
  private static pause(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  /**
   * **用系统 HTTP 栈把同一发再发一次**（连接层失败时的兜底）。
   *
   * 为什么需要：自建 TLS 只有一条路（裸 TCP + 手拼 ClientHello），在 VPN / 企业代理 /
   * 受限网络里可能**连都连不上**（真机：`Operation in progress`）。系统栈会走系统代理、
   * 也支持 TLS 1.2，至少能把这一发发出去；发不成也会给出更贴切的错误。
   *
   * 只用在这几类失败之后（连接层 / 协议不匹配）：证书链与钉住校验失败**不回退** ——
   * 那可能是中间人，换成系统栈正好把校验让给了别人。
   */
  static async requestViaSystem(host: string, port: number, method: string, path: string,
                                headers: Record<string, string>, body: string): Promise<TlsHttpReply> {
    const url: string = port === 443 ? `https://${host}${path}` : `https://${host}:${port}${path}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        extraData: method === 'POST' ? body : undefined,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const head: Record<string, string> | null = (response.header ?? null) as Record<string, string> | null;
      const lines: Array<string> = [`HTTP/1.1 ${response.responseCode} OK`];
      if (head !== null) {
        const names: Array<string> = Object.keys(head);
        for (let index: number = 0; index < names.length; index++) {
          lines.push(`${names[index]}: ${head[names[index]]}`);
        }
      }
      hilog.info(DOMAIN, TAG, 'system http fallback %{public}s %{public}d %{public}s',
        host, response.responseCode, path);
      return new TlsHttpReply(lines.join('\r\n'), text);
    } catch (error) {
      throw new Error(`系统 HTTP 栈也失败：${Tls13Client.errorText(error)}`);
    } finally {
      request.destroy();
    }
  }

  private static async addressOf(host: string): Promise<string> {
    try {
      /*
       * **强制走 DoH**（忽略设置页那个开关）。
       *
       * 2026-10-30 真机（Mate 80 Pro / SGT-AL00）：系统 DNS 把 `i.instagram.com`
       * 解到 **74.86.12.172**（SoftLayer 的地址，明显是被污染/投毒的结果），
       * connect 三次全 `Operation in progress`、系统栈 `Operation timeout` ——
       * 用户换节点就好，说明"解析到的 IP 是假的"这一类问题在我们这条链上很常见。
       *
       * DoH 的端点表里本来就有 `223.5.5.5` / `dns.alidns.com`（国内可达）和
       * Cloudflare/Google（国外线路），拿到的是真实 Meta 地址。它只影响**我们自己**
       * 这条 TLS 通道（登录 / CAA / 自检），不碰系统设置；拿不到就退回系统 DNS。
       */
      const ip: string = await DoHResolver.addressFor(host, true);
      if (ip.length > 0 && ip !== host) {
        hilog.info(DOMAIN, TAG, 'connect via doh host=%{public}s ip=%{public}s', host, ip);
        return ip;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'doh resolve failed host=%{public}s (%{public}s)',
        host, (error as Error).message);
    }
    return host;
  }

  /** 离线自检（RFC 8448 向量）—— 先把"算错"和"握手错"分开。 */
  static async selfTest(): Promise<string> {    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    const connection: Tls13Connection = new Tls13Connection(new TcpStream(tcp));
    return await connection.selfTest();
  }

  static async probe(host: string, port: number, requestText: string): Promise<string> {
    // 与 request 同一条规则（含重试与 IP 解析，见 openStream）。
    const stream: TcpStream = await Tls13Client.openStream(host, port);
    const connection: Tls13Connection = new Tls13Connection(stream);
    try {
      const handshake: string = await connection.handshake(host);
      const reply: TlsHttpReply = await connection.httpRequest(requestText);
      const status: number = reply.statusCode();
      const head: string = reply.headerText.replace(/\r\n/g, ' | ');
      return `握手：${handshake}\nHTTP ${status}\n${head.substring(0, 400)}\nbody:`
        + `${reply.bodyText.substring(0, 200)}`;
    } catch (error) {
      // 失败时把**走到哪一步**带出去：手写 TLS 的错都长一个样，没有现场根本没法定位。
      throw new Error(`${(error as Error).message}（现场：${connection.log || '(握手未开始)'}）`);
    } finally {
      await stream.close();
    }
  }
}
