/*
 * 移动 API 的**签名与令牌工具**（对应 instagrapi 的 `utils/auth.py` + `utils/timing.py`）。
 *
 * ## 最重要的一件事：instagrapi 的"签名"不是密码学签名
 * `generate_signature()` 全文只有一行：
 *
 *     return "signed_body=SIGNATURE." + quote_plus(data)
 *
 * `SIGNATURE` 是**写死的常量前缀**，没有 HMAC、没有密钥、没有设备参与。
 * 所以移植它不需要任何密钥学能力 —— 这一点和"IG 需要客户端签名"的常见猜测正好相反。
 *
 * 真正用到 HMAC-SHA256 的只有两处，都在这个文件里：
 *   1. `userBreadcrumb()`（评论输入行为埋点，instagrapi 的 `gen_user_breadcrumb`）；
 *   2. `wwwClaim()` 的对外形态 `hmac.<base64url>`（claim 值本身由服务端在响应头下发，
 *      这里只负责拼装/兜底，见 MobileSession）。
 * 鸿蒙侧用 `cryptoFramework.createMac({algName:'HMAC', mdName:'SHA256'})` 实现
 * （官方文档 crypto-compute-hmac）。
 *
 * ## 为什么不直接用 cryptoFramework 的 Base64
 * 这里统一走 `util.Base64Helper`（`@kit.ArkTS`）：它有明确的字母表参数
 * （`Type.BASIC` / `Type.URL_SAFE`），而 `cryptoFramework` 那边的 base64 接口是另一套，
 * 混用会让"URL-safe 到底有没有换字符"变成猜。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileSign';

/**
 * 系统密码学能力**用不了**时退到弱随机（只报一次）。
 *
 * 为什么必须有（`INSTAGRAPI_PORT.md` §3.4）：`cryptoFramework.createRandom` / `createMd`
 * **不是所有设备都支持**，而且会抛异常。这里的调用点全在"造设备身份 / 造 token"的路径上，
 * 一抛就是 MobileProbe 报 `threw` —— 看起来像"协议不对"，实际是设备能力。
 * 项目里的先例是 `core/PlatformCap` 与 `core/InstagramCookieJar`（按能力降级），
 * 所以这里同样降级，但**绝不静默**：日志里明说这次用的是弱随机。
 */
let weakRandomLogged: boolean = false;

function noteWeakRandom(where: string, error: Error): void {
  if (weakRandomLogged) {
    return;
  }
  weakRandomLogged = true;
  hilog.warn(DOMAIN, TAG, 'crypto unavailable (%{public}s) → 用弱随机兜底: %{public}s',
    where, error.message ?? '-');
}

/** 生成 uuid v4（instagrapi 用 python 的 `uuid.uuid4()`）。 */
export function uuid4(): string {
  return util.generateRandomUUID(false);
}

/**
 * Android 设备 id（instagrapi 的 `generate_android_device_id`）：
 * `"android-" + sha256(时间戳).hex[:16]`。
 *
 * 注意它**不是随机数**，而是时间戳的摘要 —— 照抄这个形状（而不是换成 uuid），
 * 因为服务端看到过的历史样本都是这个形态。
 */
export function androidDeviceId(): string {
  try {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: utf8(`${Date.now()}`) });
    return `android-${hexOf(md.digestSync().data).substring(0, 16)}`;
  } catch (error) {
    // 摘要算不了：仍要给出**这个形状**的 id（`android-` + 16 位十六进制），
    // 用弱随机拼一个 —— 服务端看到过的样本都是这个形态（见上），形状比"多强的随机"更重要。
    noteWeakRandom('androidDeviceId', error as Error);
    let hex: string = '';
    while (hex.length < 16) {
      hex += Math.floor(Math.random() * 16).toString(16);
    }
    return `android-${hex}`;
  }
}

/**
 * CSRF 令牌（instagrapi 的 `gen_token`）：字母 + 数字的随机串。
 *
 * 只有在 Cookie 罐里没有 `csrftoken` 时才用得上（见 MobileSession）——
 * 正常情况下会话自带。
 */
export function genToken(size: number = 64): string {
  const chars: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const out: Array<string> = [];
  let random: cryptoFramework.Random | null = null;
  try {
    random = cryptoFramework.createRandom();
  } catch (error) {
    // 拿不到 CSPRNG：下面每个字符退到 Math.random（同样只报一次，见 noteWeakRandom）。
    noteWeakRandom('genToken', error as Error);
    random = null;
  }
  for (let index: number = 0; index < size; index++) {
    if (random !== null) {
      try {
        const bytes: cryptoFramework.DataBlob = random.generateRandomSync(1);
        out.push(chars.charAt(bytes.data[0] % chars.length));
        continue;
      } catch (error) {
        noteWeakRandom('genToken.generate', error as Error);
        random = null;
      }
    }
    out.push(chars.charAt(Math.floor(Math.random() * chars.length)));
  }
  return out.join('');
}

/**
 * `jazoest`（instagrapi 的 `generate_jazoest`）：`"2" + 各字符码之和`。
 *
 * 本项目 `core/WebTokens.jazoestOf` 已经有同一份实现（网页那条路在用）——
 * 这里**故意再写一遍**而不是复用：那一份绑定在"页面会话令牌"上，
 * 这一份绑定在"移动 API 表单体"上，两者过期时机不同，将来要改的动机也不同。
 */
export function jazoest(text: string): string {
  let sum: number = 0;
  for (let index: number = 0; index < text.length; index++) {
    sum += text.charCodeAt(index);
  }
  return `2${sum}`;
}

/**
 * 私有 API 的 POST 体封装（instagrapi 的 `generate_signature`）。
 *
 * `signed_body=SIGNATURE.<urlencode(体)>` —— 整个表单体就这么一个键。
 * 这与项目既有的"网页模板体"完全不同形状：网页那条是 `fb_dtsg=…&variables=…`
 * 的多键表单，这里是单键包住整个 JSON。
 *
 * 编码用 `encodeURIComponent` + 手工把 `~` 转成 `%7E`：
 * python 的 `quote_plus` 基于 RFC 2396，**会**转义 `~`，而 JS 的 `encodeURIComponent`
 * 不会 —— 差这一个字符时服务端看到的是另一份"签名"（见文件头：它就是个固定前缀，
 * 所以内容必须逐字节一致才有意义）。空格两边都是 `+`（encodeURIComponent 给 `%20`，
 * 这里换回 `+`，与 quote_plus 一致）。
 */
export function signedBody(data: string): string {
  return `signed_body=SIGNATURE.${quotePlus(data)}`;
}

/**
/** HMAC-SHA256（字节数组输入）。 */
export function hmacSha256(key: string, message: string): Uint8Array {
  const keyBlob: cryptoFramework.DataBlob = { data: utf8(key) };
  const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
  const symKey: cryptoFramework.SymKey = generator.convertKeySync(keyBlob);
  const spec: cryptoFramework.HmacSpec = { algName: 'HMAC', mdName: 'SHA256' };
  const mac: cryptoFramework.Mac = cryptoFramework.createMac(spec);
  mac.initSync(symKey);
  mac.updateSync({ data: utf8(message) });
  return mac.doFinalSync().data;
}

/** Base64（`urlSafe=true` 时用 URL-safe 字母表；本 SDK 的枚举名是 `BASIC_URL_SAFE`）。 */
export function base64(bytes: Uint8Array, urlSafe: boolean): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes, urlSafe ? util.Type.BASIC_URL_SAFE : util.Type.BASIC);
}

/**
 * Base64url **无填充**（python `base64.urlsafe_b64encode(...)` 去 `=`）。
 *
 * IG 的 `Authorization: Bearer IGT:2:<base64url>` 用的是这种形态，
 * 与上面 `base64(bytes, true)`（保留填充）不同 —— 两者都要有。
 */
export function base64UrlNoPad(bytes: Uint8Array): string {
  return base64(bytes, true).replace(/=+$/, '');
}

/** 字符串 → UTF-8 字节。 */
export function utf8(text: string): Uint8Array {
  const encoded: Uint8Array = new Uint8Array(buffer.from(text, 'utf-8').buffer);
  return encoded;
}

/**
 * UTF-8 字节 → 字符串（`utf8` 的反向，实时通道解压后的 JSON 要用）。
 *
 * 用 `util.TextDecoder` 而不是手写解码：MQTT 的载荷里有中文（私信、region hint），
 * 手写多字节解码容易在"截断在半个字符"上出错。
 */
export function textOf(bytes: Uint8Array): string {
  try {
    return decodeText(bytes);
  } catch (error) {
    return '';
  }
}

function decodeText(bytes: Uint8Array): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

/** 字节 → 小写十六进制（sha256 摘要用）。 */
export function hexOf(bytes: Uint8Array): string {
  const out: Array<string> = [];
  for (let index: number = 0; index < bytes.length; index++) {
    const one: string = bytes[index].toString(16);
    out.push(one.length === 1 ? `0${one}` : one);
  }
  return out.join('');
}

/**
 * python `urllib.parse.quote_plus` 的等价物（见 signedBody 的说明）。
 *
 * 针对本例的输入（`JSON.stringify` 出来的体）做等价即可：默认 safe 字符集
 * 与 quote_plus 一致，只有 `~` 与空格两处差异。
 */
export function quotePlus(text: string): string {
  return encodeURIComponent(text).replace(/~/g, '%7E').replace(/%20/g, '+');
}

/** 用 CSPRNG 取 `[min, max]` 闭区间内的整数（instagrapi 用 `random.randint`）。 */
export function randomInt(min: number, max: number): number {
  if (max <= min) {
    return min;
  }
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const bytes: cryptoFramework.DataBlob = random.generateRandomSync(4);
    const value: number = ((bytes.data[0] << 24) | (bytes.data[1] << 16)
      | (bytes.data[2] << 8) | bytes.data[3]) >>> 0;
    return min + (value % (max - min + 1));
  } catch (error) {
    noteWeakRandom('randomInt', error as Error);
    return min + Math.floor(Math.random() * (max - min + 1));
  }
}
