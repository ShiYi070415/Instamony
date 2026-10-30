/*
 * **登录日志**（给"登录失败"的用户一键带出现场）。
 *
 * ## 为什么需要它
 * 登录这条路（App 协议 CAA + 自建 TLS 1.3）失败时，原因可能差很远：
 *   · 网络连不上（VPN / 代理 / 网络受限）；
 *   · TLS 握手被中间盒挡（只给 TLS 1.2、换套件/曲线）；
 *   · 证书链校验不过（VPN 在解密 HTTPS，或 CA 换了）；
 *   · IG 侧限流 / 要验证码 / 账号问题。
 * 这些在别人的手机上，我们既没有 hdc 也没有日志。所以做一份**用户自己就能带走**的
 * 纯文本：设备与版本 + 网络与解析 + 登录态 + 最近一次登录结果 + CAA 每一步 +
 * 最近一次请求/响应（脱敏）+ 一次"登录通道自检"（TCP → TLS → 一行 HTTP）。
 *
 * ## 隐私边界
 *   · **不含密码**、不含 Authorization / Cookie 的值（只给条数与 Cookie 名）；
 *   · 请求体沿用 `CaaLogin` 那份**已脱敏**的副本（`password` 等已换占位符）；
 *   · 响应体只留前 1200 字（IG 的报错文案在这里）。
 * 所以用户可以把整份粘到聊天窗口里。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Tls13Client } from './net/Tls13Client';
import { DoHResolver } from './net/DoHResolver';
import { CaaSession } from './mobileapi/CaaSession';
import { humanHints } from './mobileapi/CaaLogin';
import { ApiThrottle } from './ApiThrottle';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { PlatformCap } from './PlatformCap';

const DOMAIN: number = 0xFF00;
const TAG: string = 'LoginLog';

/** 自检打到哪：登录那几发都是这个域名（CAA 走 i.instagram.com / b.i.instagram.com）。 */
const PROBE_HOST: string = 'i.instagram.com';
const PROBE_PORT: number = 443;
/** 自检只要求"握手 + 一行 HTTP"，用最轻的 GET。 */
const PROBE_REQUEST: string = 'GET / HTTP/1.1\r\n'
  + `Host: ${PROBE_HOST}\r\n`
  + 'User-Agent: Instagram 449.0.0.52.84 Android (31/12; 560dpi; 1280x2832; HUAWEI/HUAWEI; '
  + 'HUAWEI Mate 80; VYG; arm64-v8a; zh_Hans; 1079242191)\r\n'
  + 'Accept: */*\r\n'
  + 'Connection: close\r\n\r\n';
/** 自检结果多久之内算"新鲜"（超过就在日志里标注时间，别让人误以为是这一次）。 */
const PROBE_FRESH_MS: number = 10 * 60 * 1000;

export class LoginLog {
  /** 最近一次登录/验证的结果（界面显示的那句话，原文）。 */
  private static lastReason: string = '';
  /** 上面那条的时间戳（0 = 还没有）。 */
  private static lastAtMs: number = 0;
  /** 最近一次"登录通道自检"的结论（成功是"握手：… / HTTP 200"，失败是原因 + 现场）。 */
  private static probeText: string = '';
  private static probeAtMs: number = 0;

  /**
   * 记一条登录结果（界面显示什么就记什么）。
   *
   * 调用点：pages/Index 的 `caaLogin` / `caaVerify` / `addAccountCaaLogin`。
   * 这样用户复现之后点"复制登录日志"，我们能看到他最外层看到的**那一句话**——
   * 它往往就是判断"是网络、是 TLS、还是要验证码"的第一手证据。
   */
  static remember(reason: string): void {
    const text: string = reason.length > 0 ? reason : '(空)';
    LoginLog.lastReason = text;
    LoginLog.lastAtMs = Date.now();
    hilog.info(DOMAIN, TAG, 'login result: %{public}s', text.substring(0, 120));
  }

  /** 最近一次登录结果（诊断面板/日志里用）。 */
  static lastReasonNow(): string {
    return LoginLog.lastReason;
  }

  /** 有没有自检结果（且不算太旧）。 */
  static probeReady(): boolean {
    return LoginLog.probeText.length > 0
      && Date.now() - LoginLog.probeAtMs < PROBE_FRESH_MS;
  }

  /**
   * **跑一次登录通道自检**：TCP 连接 → TLS 1.3 握手（含证书链校验）→ 发一行 GET。
   *
   * 这一步是**最能区分"VPN/代理的问题"和"账号的问题"**的：握手成功说明网络与 TLS 都通，
   * 失败的话 `Tls13Client` 会把"卡在哪一步"的现场一起带出来（证书链哈希、ServerHello 细节）。
   *
   * @returns 一行给人看的结论（也会存进日志）
   */
  static async runProbe(): Promise<string> {
    const started: number = Date.now();
    let text: string = '';
    try {
      const result: string = await Tls13Client.probe(PROBE_HOST, PROBE_PORT, PROBE_REQUEST);
      const status: string = LoginLog.firstLine(result);
      text = `通（${Date.now() - started}ms）：${status}`;
    } catch (error) {
      text = `失败（${Date.now() - started}ms）：${(error as Error).message}`;
    }
    LoginLog.probeText = text;
    LoginLog.probeAtMs = Date.now();
    hilog.info(DOMAIN, TAG, 'probe %{public}s', text.substring(0, 200));
    return text;
  }

  /** 自检结果的单行摘要（面板上显示用）。 */
  static probeSummary(): string {
    if (LoginLog.probeText.length === 0) {
      return '还没跑过自检';
    }
    const age: number = Math.floor((Date.now() - LoginLog.probeAtMs) / 1000);
    return `${LoginLog.probeText.length > 72 ? LoginLog.probeText.substring(0, 72) + '…'
      : LoginLog.probeText}（${age} 秒前）`;
  }

  /**
   * **生成可复制的登录日志**（纯文本，粘到聊天窗口就能发）。
   *
   * @param version 界面传进来的版本号（`versionName (versionCode)`），core 这边不查 Bundle。
   */
  static async compose(version: string): Promise<string> {
    const lines: Array<string> = [];
    lines.push('==== Instamony 登录日志 ====');
    lines.push(`生成时间：${LoginLog.stamp(Date.now())}`);
    lines.push(`版本：${version}`);
    lines.push(`系统：HarmonyOS API ${PlatformCap.apiLevel()} / ${deviceInfo.displayVersion ?? '-'}`);
    lines.push(`机型：${deviceInfo.brand ?? '-'} ${deviceInfo.productModel ?? '-'}`
      + `（${deviceInfo.marketName ?? '-'} / ${deviceInfo.productSeries ?? '-'}）`);
    lines.push(`ABI：${deviceInfo.abiList ?? '-'}`);
    lines.push('');
    // ---- 网络 / 解析 ----
    lines.push('[网络与解析]');
    lines.push(`DoH：${DoHResolver.describe()}`);
    lines.push(`限速闸门：${ApiThrottle.paceDescribe()}`);
    const clipsLeft: number = ApiThrottle.remainingMinutes(ApiThrottle.CLIPS);
    lines.push(`clips 冷却：${clipsLeft > 0 ? `${clipsLeft} 分钟` : '无'}`
      + ` / 整账号熔断：${ApiThrottle.suspended() ? `${ApiThrottle.suspendMinutesLeft()} 分钟(${ApiThrottle.suspendWhy()})` : '无'}`);
    lines.push('');
    // ---- 登录态 ----
    lines.push('[登录态]');
    try {
      const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      lines.push(`会话：${snapshot.signedIn ? '已登录' : '未登录'} / Cookie ${snapshot.count} 条`
        + `（${snapshot.names}）`);
    } catch (error) {
      lines.push(`会话：读取失败（${(error as Error).message}）`);
    }
    lines.push(`CAA 设备身份（USDID）：${CaaSession.hasDevice() ? '有' : '无'}`);
    const wait: number = CaaSession.rateLimitWaitMinutes();
    if (wait > 0) {
      lines.push(`密码登录限流冷却：还有约 ${wait} 分钟`);
    }
    lines.push('');
    // ---- 最近一次登录结果 ----
    lines.push('[最近一次登录结果]');
    if (LoginLog.lastAtMs > 0) {
      lines.push(`${LoginLog.stamp(LoginLog.lastAtMs)}：${LoginLog.lastReason}`);
    } else {
      lines.push('（本进程内还没点过登录）');
    }
    lines.push('');
    // ---- CAA 每一步 ----
    const steps: string = CaaSession.stepsText();
    lines.push('[CAA 登录链路（每一发的域名与状态）]');
    lines.push(steps.length > 0 ? steps : '（没有记录）');
    lines.push('');
    // ---- 通道自检 ----
    lines.push('[登录通道自检：TCP → TLS 1.3 → 一行 GET]');
    lines.push(LoginLog.probeText.length > 0
      ? `${LoginLog.stamp(LoginLog.probeAtMs)}：${LoginLog.probeText}` : '（还没跑过：设置 → 诊断 → 登录通道自检）');
    lines.push('');
    // ---- 原始现场（脱敏 + 截断）----
    const request: string = CaaSession.lastRequestText();
    if (request.length > 0) {
      lines.push('[最近一次登录请求（已脱敏，前 800 字）]');
      lines.push(request.substring(0, 800));
      lines.push('');
    }
    const response: string = CaaSession.lastResponseText();
    if (response.length > 0) {
      /*
       * **别再只贴开头 1200 字**。
       *
       * 2026-10-30 真机：`send_login_request` 回了 200，但响应是一大棵 bloks 布局树，
       * 开头全是事件埋点（`caa_login_client_events_ig`），真正的结果在**后半段/结尾**，
       * 只贴开头等于什么都没看到。现在：开头 500 + **挑出来的人话** + 结尾 1800。
       */
      lines.push(`[最近一次登录响应（共 ${response.length} 字）]`);
      lines.push('-- 开头 500 字 --');
      lines.push(response.substring(0, 500));
      const hints: Array<string> = LoginLog.textHints(response);
      if (hints.length > 0) {
        lines.push('-- 响应里像"人话"的句子（IG 的提示通常在里头）--');
        for (let index: number = 0; index < hints.length; index++) {
          lines.push(`· ${hints[index]}`);
        }
      }
      const apps: Array<string> = LoginLog.bloksApps(response);
      if (apps.length > 0) {
        lines.push('-- 响应里点名的 bloks 应用（IG 想让 App 接着走哪条流程）--');
        for (let index: number = 0; index < apps.length; index++) {
          lines.push(`· ${apps[index]}`);
        }
      }
      if (response.length > 500) {
        lines.push('-- 结尾 1800 字 --');
        lines.push(response.substring(Math.max(500, response.length - 1800)));
      }
      lines.push('');
    }
    lines.push('==== 到此为止 ====');
    return lines.join('\n');
  }

  /**
   * 从响应里挑出**人话**（实现见 `CaaLogin.humanHints`：日志与"登录失败"提示共用同一套规则，
   * 免得界面上说一套、日志里挑另一套）。
   */
  private static textHints(text: string): Array<string> {
    return humanHints(text);
  }

  /**
   * 响应里被点名的 bloks 应用（`com.bloks.www.xxx`）。
   *
   * 这是"IG 到底想让 App 接着走哪条流程"的**最直接证据**：登录成功时不会有；
   * 要验证码会点 `two_step_verification.*`，要人机验证（captcha）会点 `*.machine_test*` /
   * `*.challenge*`，要用户确认会点 `*.consent*`。上一次排查 2FA 时就是靠它认对了入口。
   */
  private static bloksApps(text: string): Array<string> {
    const out: Array<string> = [];
    const found: RegExpMatchArray | null = text.match(/com\.bloks\.www\.[A-Za-z0-9_.]+/g);
    if (found === null) {
      return out;
    }
    for (let index: number = 0; index < found.length; index++) {
      const item: string = found[index];
      let duplicate: boolean = false;
      for (let seen: number = 0; seen < out.length; seen++) {
        if (out[seen] === item) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) {
        out.push(item);
      }
      if (out.length >= 12) {
        break;
      }
    }
    return out;
  }

  /** 导出用文件名（带时间，用户手上可能有好几份）。 */
  static fileName(): string {
    const now: Date = new Date();
    const pad: (value: number) => string = (value: number): string => {
      return value < 10 ? `0${value}` : `${value}`;
    };
    return `Instamony-login-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}`
      + `-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}.txt`;
  }

  /** `yyyy-MM-dd HH:mm:ss`（日志里所有时间都用这个格式）。 */
  private static stamp(ms: number): string {
    const at: Date = new Date(ms);
    const pad: (value: number) => string = (value: number): string => {
      return value < 10 ? `0${value}` : `${value}`;
    };
    return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())} `
      + `${pad(at.getHours())}:${pad(at.getMinutes())}:${pad(at.getSeconds())}`;
  }

  /** 取多行文本的第一行（自检结果摘要用）。 */
  private static firstLine(text: string): string {
    const at: number = text.indexOf('\n');
    const head: string = at < 0 ? text : text.substring(0, at);
    return head.length > 120 ? head.substring(0, 120) : head;
  }
}
