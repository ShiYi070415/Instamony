/*
 * **账号安全验证（challenge_required）的会话级台账**。
 *
 * 背景：新注册的账号（或者短时间请求过密的账号）打私有接口时，IG 会回
 *
 *   {"message":"challenge_required",
 *    "challenge":{"url":"https://i.instagram.com/challenge/<uid>/<nonce>/",
 *                 "api_path":"/challenge/<uid>/<nonce>/",
 *                 "challenge_context":"…","challenge_step":…,"native_flow":true}}
 *
 * 这不是限流、也不是登录失效 —— **重试多少次都没用**，必须让用户过人机/设备验证。
 *
 * ## 为什么走网页，而不是照着 instagrapi 做一遍
 * 查过 instagrapi 的 `ChallengeResolveMixin`：它只自动处理**验证码型**的挑战
 * （`verify_email|verify_phone|verify_sms` + `security_code`、`delta_login_review` 的"是我本人"、
 * 生日表单等）；而对下面这些它自己也是**直接抛"请人工完成"**：
 *   · `native_flow: true` 的挑战（新版 App 的 Bloks 原生流程）；
 *   · `/auth_platform/…` 的登录验证平台流程；
 *   · `RecaptchaChallengeForm`（要 reCAPTCHA token，只能在网页里解）；
 *   · `selfie_captcha`（自拍验证）；
 *   · `ufac_www_bloks`。
 * 新注册账号最常撞上的恰恰是后几种。所以这里不硬啃协议：**把 challenge 的地址记下来，
 * 让用户在我们的隐藏网页里完成验证**（网页就是我们登录用的那个会话，验证完 Cookie 罐自动更新），
 * 之后清掉台账、重新取数。
 *
 * 这一层只做"记账"：谁检测到、什么时候打开网页，由 `core/mobileapi/MobileRequest`（检测）
 * 与 `pages/Index`（界面横幅 + 打开网页）决定。
 */

// 被要求验证时顺手把"可选流量"整账号停掉（见 note 末尾的 suspendAll）。
import { ApiThrottle } from '../ApiThrottle';

const CHALLENGE_KEY: string = 'challenge_required';

export class MobileChallenge {
  /** 网页上要打开的地址（空 = 现在没有待处理的验证）。 */
  private static url: string = '';
  /** 记下来的时间（给日志/界面用）。 */
  private static atMs: number = 0;
  /** 原始 `challenge` 片段的摘要（诊断用，最多 200 字）。 */
  private static detail: string = '';

  /**
   * 从一发响应体里认挑战并把地址记下来（不是挑战体就什么都不做）。
   *
   * 地址优先取 `challenge.api_path`（它是 `/challenge/<uid>/<nonce>/` 这一段），
   * 拼成 `https://www.instagram.com/...` —— 我们的隐藏网页会话就在 www 上，直接打开即可；
   * 没有 `api_path` 时退回 `challenge.url`（i.instagram.com 那个），把主机换成 www。
   */
  static note(body: string): void {
    if (body.length === 0 || body.indexOf(CHALLENGE_KEY) < 0) {
      return;
    }
    const path: string = MobileChallenge.fieldOf(body, 'api_path');
    const raw: string = MobileChallenge.fieldOf(body, 'url');
    let web: string = MobileChallenge.webUrl(path, raw);
    if (web.length === 0) {
      // 认不出具体地址也别丢信号：至少让界面提示"需要验证"，按钮退回挑战首页。
      web = 'https://www.instagram.com/challenge/';
    }
    if (web === MobileChallenge.url) {
      return;
    }
    MobileChallenge.url = web;
    MobileChallenge.atMs = Date.now();
    MobileChallenge.detail = body.substring(0, 200);
    /*
     * **整账号熔断**：被要求过安全验证之后继续发请求，只会让 IG 把账号盯得更紧
     * （审计文档里"越打越久"的那一类）。这里停 1 小时的可选流量，等用户去网页里验完
     * 再恢复（界面上的验证弹窗就是入口，见 pages/Index 的 showChallengeDialog）。
     */
    ApiThrottle.suspendAll(60, 'challenge_required');
  }

  /** 现在有没有待处理的验证。 */
  static pending(): boolean {
    return MobileChallenge.url.length > 0;
  }

  /** 要打开的网页地址（没有就给空串）。 */
  static urlNow(): string {
    return MobileChallenge.url;
  }

  /** 记下来的时间（毫秒；0 = 没记过）。 */
  static notedAtMs(): number {
    return MobileChallenge.atMs;
  }

  /** 诊断摘要（日志里一行看完：有没有、什么时候、从什么响应里认出来的）。 */
  static summary(): string {
    return MobileChallenge.url.length === 0
      ? '-'
      : `${MobileChallenge.url} @${MobileChallenge.atMs} :: ${MobileChallenge.detail.substring(0, 80)}`;
  }

  /** 用户完成验证 / 换账号 / 退出登录时清掉。 */
  static clear(): void {
    MobileChallenge.url = '';
    MobileChallenge.atMs = 0;
    MobileChallenge.detail = '';
  }

  // ------------------------------------------------------------------ 内部

  /**
   * 从 JSON 文本里取一个字符串字段（不解析整棵 JSON：挑战体里的 `challenge_context`
   * 本身是转义过的字符串，`JSON.parse` 之后还要再解一层，这里正则更省事也更稳）。
   */
  private static fieldOf(body: string, key: string): string {
    const re: RegExp = new RegExp(`"${key}"\\s*:\\s*"([^"]{1,300})"`);
    const match: RegExpMatchArray | null = body.match(re);
    return match !== null && match.length > 1 ? match[1] : '';
  }

  /** `api_path` / `url` → 能在我们网页里打开的 www 地址。 */
  private static webUrl(path: string, raw: string): string {
    const base: string = 'https://www.instagram.com';
    const candidate: string = path.length > 0 ? path : raw;
    if (candidate.length === 0) {
      return '';
    }
    const at: number = candidate.indexOf('/challenge');
    if (at < 0) {
      return '';
    }
    let rest: string = candidate.substring(at);
    rest = rest.split('?')[0];
    if (rest.charAt(rest.length - 1) !== '/') {
      rest += '/';
    }
    return base + rest;
  }
}
