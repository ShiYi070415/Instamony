/*
 * **用 IG 网页接口给"账号密码到底对不对"下一个结论**。
 *
 * ## 为什么需要它
 *
 * App 协议登录（CAA）失败时，界面只会显示 IG 的原话。2026-10-30 这个案例里 IG 一直回
 * 「你输入的密码有误」，但用户坚持密码是对的，而**我们这边能查的都查过了**：
 *   · TLS / 证书钉住 / 自检全通；
 *   · 五发 CAA 全 200，`enc_password` 的载荷长度、keyId 与 IG 当前公钥逐字节对得上。
 *
 * 也就是说剩下的可能性只有两类：**账号侧**（密码不对 / 被锁 / 要验证）和
 * **IG 对这条 CAA 链路的风控**。这两类在 CAA 的响应里长得一模一样，看不出来。
 *
 * 网页登录接口（`/api/v1/web/accounts/login/ajax/`）是**另一个面**，回答很干脆：
 *   · `{"authenticated":true,...}` → 账号密码没问题，问题在我们这条链路；
 *   · `{"message":"bad_password"}` / 只有 `authenticated:false` → IG 认定密码不对；
 *   · `{"two_factor_required":true}` / `checkpoint_required` → **密码对**，只是要验证。
 *
 * 所以它只做一件事：把"是谁的锅"分开。密码只在内存里用一次，不落盘、不进日志。
 */

import { http } from '@kit.NetworkKit';

const DOMAIN_APP_ID: string = '936619743392459';
const BROWSER_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    + 'Chrome/141.0.0.0 Safari/537.36';

/** 网页接口的结论（给界面直接显示）。 */
export class WebProbeResult {
  /** 一句话结论（界面显示）。 */
  readonly text: string;
  /** 账号密码是否**被 IG 认可**（true = 密码没问题）。 */
  readonly credentialsOk: boolean;
  /**
   * IG 这次要求的验证是哪一种（`challengeType`），例如 `VerifyEmailCodeForm` /
   * `SelectContactPointRecoveryForm` / `RecaptchaChallengeForm`；空串 = 没读到。
   */
  readonly challengeType: string;
  /**
   * **原生流程**（`challenge.native_flow = true`）：这种 checkpoint 只暴露给官方 App / 受信设备，
   * 第三方客户端拿不到可提交的步骤（见 instagrapi 的处理：直接抛 ChallengeRequired 让人工处理）。
   */
  readonly nativeFlow: boolean;
  /** `/challenge/<uid>/<nonce>/` 这类 api_path（有的话）。 */
  readonly apiPath: string;
  /** 脱敏后的现场摘要（进登录日志）。 */
  readonly detailNote: string;

  constructor(text: string, credentialsOk: boolean, challengeType: string = '',
              nativeFlow: boolean = false, apiPath: string = '', detailNote: string = '') {
    this.text = text;
    this.credentialsOk = credentialsOk;
    this.challengeType = challengeType;
    this.nativeFlow = nativeFlow;
    this.apiPath = apiPath;
    this.detailNote = detailNote;
  }
}

export class WebLoginProbe {
  /**
   * 用网页接口核对账号密码。
   *
   * @returns {@link WebProbeResult}：`credentialsOk` 为真表示"IG 认这组账号密码"
   */
  static async probe(username: string, password: string): Promise<WebProbeResult> {
    const name: string = username.trim();
    if (name.length === 0 || password.length === 0) {
      return new WebProbeResult('先填账号和密码再核对', false);
    }
    const csrf: string = await WebLoginProbe.csrfToken();
    if (csrf.length === 0) {
      return new WebProbeResult('拿不到 IG 网页的 csrftoken（网络不通？）', false);
    }
    const timestamp: string = `${Math.floor(Date.now() / 1000)}`;
    // 网页端的加密串是**明文密码**套 `#PWD_INSTAGRAM_BROWSER:0:<ts>:`（没有 RSA 那一层）。
    const encPassword: string = `#PWD_INSTAGRAM_BROWSER:0:${timestamp}:${password}`;
    const body: string = 'username=' + encodeURIComponent(name)
      + '&enc_password=' + encodeURIComponent(encPassword)
      + '&queryParams=' + encodeURIComponent('{}')
      + '&optIntoOneTap=false'
      + '&stopDeletionNonce='
      + '&trustedDeviceRecords=' + encodeURIComponent('{}');
    const headers: Record<string, string> = {
      'User-Agent': BROWSER_UA,
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Content-Type': 'application/x-www-form-urlencoded',
      'X-CSRFToken': csrf,
      'X-IG-App-ID': DOMAIN_APP_ID,
      'X-Requested-With': 'XMLHttpRequest',
      'Referer': 'https://www.instagram.com/',
      'Origin': 'https://www.instagram.com',
      'Cookie': `csrftoken=${csrf}`
    };
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(
        'https://www.instagram.com/api/v1/web/accounts/login/ajax/', {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: body,
          connectTimeout: 15000,
          readTimeout: 20000,
          expectDataType: http.HttpDataType.STRING
        });
      const text: string = `${response.result}`;
      return WebLoginProbe.verdict(text, response.responseCode);
    } catch (error) {
      return new WebProbeResult(`网页接口请求失败：${(error as Error).message}`, false);
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 把网页接口的 JSON 翻成结论。
   *
   * 字段按 IG 实际返回处理（2026-10-30 实测：随便一个不存在的用户名回
   * `{"user":true,"authenticated":false,"status":"ok"}`，HTTP 200）。
   *
   * 除了"密码对不对"，这里还要把**是哪一种验证**捞出来 —— 这决定我们能不能自己走完：
   *   · `challenge.native_flow = true` + `/challenge/...` → **只能在官方 App / 受信设备完成**
   *     （instagrapi 也是直接抛 ChallengeRequired 让人工处理）；
   *   · 老的 contact-form（Email/SMS 验证码）→ 第三方客户端有办法自己提交验证码。
   */
  private static verdict(json: string, status: number): WebProbeResult {
    const lower: string = json.toLowerCase();
    const nativeFlow: boolean = lower.indexOf('"native_flow":true') >= 0
      || lower.indexOf('"native_flow": true') >= 0;
    const apiPath: string = WebLoginProbe.fieldOf(json, 'api_path');
    const challengeType: string = WebLoginProbe.fieldOf(json, 'challengeType');
    const detail: string = `native_flow=${nativeFlow ? 'true' : 'false'}`
      + ` api_path=${apiPath.length > 0 ? apiPath : '(无)'}`
      + ` challengeType=${challengeType.length > 0 ? challengeType : '(无)'}`
      + ` raw=${json.length > 900 ? json.substring(0, 900) + '…' : json}`;
    if (lower.indexOf('"authenticated":true') >= 0) {
      return new WebProbeResult('IG 认可这组账号密码（网页接口直接给了会话）→ 问题在本机 CAA 链路',
        true, challengeType, nativeFlow, apiPath, detail);
    }
    if (lower.indexOf('two_factor_required') >= 0 || lower.indexOf('two_factor') >= 0) {
      return new WebProbeResult('密码是对的，IG 要两步验证（网页接口也这么要求）',
        true, challengeType, nativeFlow, apiPath, detail);
    }
    if (lower.indexOf('challenge') >= 0 || lower.indexOf('checkpoint') >= 0
      || lower.indexOf('consent') >= 0) {
      const how: string = nativeFlow
        ? '（这是 native_flow：只能在官方 App / 受信设备上完成，第三方客户端拿不到可提交的步骤）'
        : (challengeType.length > 0 ? `（类型 ${challengeType}）` : '');
      return new WebProbeResult(`密码是对的，IG 要求安全验证（checkpoint）${how}`,
        true, challengeType, nativeFlow, apiPath, detail);
    }
    if (lower.indexOf('bad_password') >= 0 || lower.indexOf('"authenticated":false') >= 0) {
      return new WebProbeResult('网页接口也不认这组账号密码（IG 两个面结论一致）',
        false, challengeType, nativeFlow, apiPath, detail);
    }
    if (lower.indexOf('wait') >= 0 || lower.indexOf('too many') >= 0
      || lower.indexOf('rate') >= 0 || status === 429) {
      return new WebProbeResult('被 IG 限流了（先等 30 分钟再试）', false, challengeType,
        nativeFlow, apiPath, detail);
    }
    const snippet: string = json.length > 160 ? `${json.substring(0, 160)}…` : json;
    return new WebProbeResult(`网页接口回了意料之外的东西（HTTP ${status}）：${snippet}`,
      false, challengeType, nativeFlow, apiPath, detail);
  }

  /** 从 JSON 文本里取一个字符串字段（值里不能再有引号，够用且不依赖解析器）。 */
  private static fieldOf(json: string, name: string): string {
    const marker: string = `"${name}":"`;
    const at: number = json.indexOf(marker);
    if (at < 0) {
      return '';
    }
    const from: number = at + marker.length;
    const end: number = json.indexOf('"', from);
    if (end < 0) {
      return '';
    }
    return json.substring(from, end);
  }

  /** 取一个 `csrftoken`（IG 主页的 set-cookie）。 */
  private static async csrfToken(): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request('https://www.instagram.com/', {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': BROWSER_UA,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'en-US,en;q=0.9'
        },
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING
      });
      const raw: ESObject = response.header as ESObject;
      if (raw === null || raw === undefined) {
        return '';
      }
      const record: Record<string, ESObject> = raw as Record<string, ESObject>;
      for (const key of Object.keys(record)) {
        if (key.toLowerCase() !== 'set-cookie') {
          continue;
        }
        const value: ESObject = record[key];
        const joined: string = Array.isArray(value) ? (value as Array<string>).join('\n') : `${value}`;
        const lines: Array<string> = joined.split('\n');
        for (let index: number = 0; index < lines.length; index++) {
          const at: number = lines[index].indexOf('csrftoken=');
          if (at < 0) {
            continue;
          }
          const rest: string = lines[index].substring(at + 'csrftoken='.length);
          const end: number = rest.indexOf(';');
          const token: string = end < 0 ? rest : rest.substring(0, end);
          if (token.length > 0) {
            return token.trim();
          }
        }
      }
      return '';
    } catch (error) {
      return '';
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }
}
