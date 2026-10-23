/*
 * Instagram 会话 Cookie 罐。
 *
 * 网页登录成功后，Instagram 把账号会话种成 HttpOnly 的 `sessionid` / `ds_user_id`：
 * 页面脚本（document.cookie）读不到它们，所以「已登录」这件事只能问原生 Cookie 罐。
 * 这里照 D:\WeiboPura（同类网页壳应用，已验证可用）的做法，直接读
 * `WebCookieManager.fetchAllCookies`，以罐内是否出现会话 Cookie 作为判据。
 *
 * 读取只取 Instagram 域的 Cookie；退出登录交给 SDK 的清罐接口（见 clear）。
 */

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlatformCap } from './PlatformCap';

const DOMAIN: number = 0xFF00;
const TAG: string = 'InstagramCookieJar';
/** 老接口 `fetchCookie(url)` 要一个 url：取首页就够（会话 Cookie 挂在 .instagram.com 上）。 */
const INSTAGRAM_URL: string = 'https://www.instagram.com/';

/** 罐里的一条 Instagram Cookie。 */
class CookieEntry {
  name: string = '';
  value: string = '';
  httpOnly: boolean = false;

  constructor(name: string, value: string, httpOnly: boolean) {
    this.name = name;
    this.value = value;
    this.httpOnly = httpOnly;
  }
}

/** 一次检查的结果：会话串 + 诊断信息（只带 Cookie 名，不带值）。 */
export class InstagramCookieSnapshot {
  readonly cookie: string;
  readonly names: string;
  readonly signedIn: boolean;
  readonly count: number;

  constructor(cookie: string, names: string, signedIn: boolean, count: number) {
    this.cookie = cookie;
    this.names = names;
    this.signedIn = signedIn;
    this.count = count;
  }
}

export class InstagramCookieJar {
  private static instance: InstagramCookieJar | null = null;

  /** 会话 Cookie：Instagram 网页登录后由服务端种下，且都是 HttpOnly。 */
  private static readonly SESSION_MARKERS: Array<string> = ['sessionid=', 'ds_user_id='];

  /**
   * 读罐结果的**短缓存 + 单飞**。
   *
   * 为什么需要：`WebCookieManager` 这几个接口在引擎里是**同步 IPC**
   * （CEF 日志里就是 `CefCookieManagerImpl::VisitAllCookies is_sync: 1`）——
   * 引擎忙或还没起来时，这一发会把**主线程**按住（真机实测有过 10 秒量级）。
   * 而 `inspect()` 被调用的地方非常多：`MobileSession.ensure()` 每发一个移动 API 请求就读一次，
   * 信息流/私信/资料各自还会再读。同一个瞬间有十几处并发读罐时，串成一次就没这个风险了。
   *
   * 缓存寿命取 1.5 秒：登录/退出这类"罐变了"的时刻由 `invalidate()` 显式作废（见 save/clear），
   * 所以这里只用来合并同一阵发起的读。
   */
  private static pending: Promise<InstagramCookieSnapshot> | null = null;
  private static cached: InstagramCookieSnapshot | null = null;
  private static cachedAt: number = 0;
  private static readonly CACHE_TTL_MS: number = 1500;

  static getInstance(): InstagramCookieJar {
    if (InstagramCookieJar.instance === null) {
      InstagramCookieJar.instance = new InstagramCookieJar();
    }
    return InstagramCookieJar.instance;
  }

  /** `.instagram.com` 与 `instagram.com` 本身都算 Instagram 域。 */
  static isInstagramDomain(domain: string): boolean {
    const clean: string = domain.trim().toLowerCase();
    return clean === 'instagram.com' || clean.endsWith('.instagram.com');
  }

  /** 登录态判定：罐里出现会话 Cookie 即为已登录。 */
  static isSignedIn(cookie: string): boolean {
    for (let index: number = 0; index < InstagramCookieJar.SESSION_MARKERS.length; index++) {
      if (cookie.includes(InstagramCookieJar.SESSION_MARKERS[index])) {
        return true;
      }
    }
    return false;
  }

  /** 读整个 Cookie 罐，取出 Instagram 域的会话并判断是否已登录（带短缓存 + 单飞，见 CACHE_TTL_MS）。 */
  static async inspect(): Promise<InstagramCookieSnapshot> {
    const now: number = Date.now();
    const cached: InstagramCookieSnapshot | null = InstagramCookieJar.cached;
    if (cached !== null && now - InstagramCookieJar.cachedAt < InstagramCookieJar.CACHE_TTL_MS) {
      return cached;
    }
    // 已经有一次在读：搭它的车，别再往引擎里发第二发同步 IPC。
    const inflight: Promise<InstagramCookieSnapshot> | null = InstagramCookieJar.pending;
    if (inflight !== null) {
      return inflight;
    }
    const task: Promise<InstagramCookieSnapshot> = InstagramCookieJar.readSnapshot();
    InstagramCookieJar.pending = task;
    try {
      const snapshot: InstagramCookieSnapshot = await task;
      InstagramCookieJar.cached = snapshot;
      InstagramCookieJar.cachedAt = Date.now();
      return snapshot;
    } finally {
      InstagramCookieJar.pending = null;
    }
  }

  /** 作废读罐缓存（登录/退出/落盘前后调，见 save / clear）。 */
  static invalidate(): void {
    InstagramCookieJar.cached = null;
    InstagramCookieJar.cachedAt = 0;
  }

  private static async readSnapshot(): Promise<InstagramCookieSnapshot> {
    const entries: Array<CookieEntry> = await InstagramCookieJar.read();
    const pairs: Array<string> = [];
    const names: Array<string> = [];
    for (let index: number = 0; index < entries.length; index++) {
      const entry: CookieEntry = entries[index];
      pairs.push(`${entry.name}=${entry.value}`);
      names.push(`${entry.name}${entry.httpOnly ? '(H)' : ''}`);
    }
    const cookie: string = pairs.join('; ');
    return new InstagramCookieSnapshot(cookie, names.join(','), InstagramCookieJar.isSignedIn(cookie),
      entries.length);
  }

  /** 登录成功后强制落盘：不能等 30 秒的周期保存，否则重启就要重新登录。 */
  static async save(): Promise<void> {
    try {
      await webview.WebCookieManager.saveCookieAsync();
      // 刚落过盘 = 罐这一阵子可能刚被网页改过，下一次读罐别用旧缓存。
      InstagramCookieJar.invalidate();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save cookie jar failed');
    }
  }

  /**
   * 退出登录：走 SDK 原生清罐，**并把网页侧的存储一起清掉**。
   *
   * 曾经试过逐条拼 `name=; Domain=...; Max-Age=0` 把 Instagram 的 Cookie 置为过期，
   * 结果是同一 Web 引擎随后的初始化/渲染出问题（登录页整片空白）。这里改回
   * SDK 自己的清罐接口：字符串解析与属性校验都交给引擎，避免把无效 Cookie 写进罐里。
   *
   * 为什么还要清 WebStorage：网页版把**账号相关的东西**（比如 `ds_user_id` 之类的本地缓存、
   * 各种 blob 状态）存在 localStorage / Web SQL 里。只清 Cookie 的话，换账号后同一台设备上
   * 这些残留仍会让页面/我们的脚本读到上一个人的痕迹（用户报的"快拍还是上一个账号的"就是
   * 这一类"清了 Cookie 没清存储"）。
   */
  async clear(): Promise<void> {
    InstagramCookieJar.invalidate();
    try {
      webview.WebCookieManager.clearAllCookiesSync();
      webview.WebCookieManager.clearSessionCookieSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clear cookie jar failed');
    }
    try {
      // 清 Web SQL + HTML5 存储（localStorage / IndexedDB）；参数 = 是否连隐私模式一起清。
      webview.WebStorage.deleteAllData(true);
      hilog.info(DOMAIN, TAG, 'cleared web storage for sign out');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clear web storage failed: %{public}s', (error as Error).message);
    }
    await InstagramCookieJar.save();
    hilog.info(DOMAIN, TAG, 'cleared the cookie jar for sign out');
  }

  /**
   * **把原生登录拿到的会话写进 Cookie 罐**（见 core/mobileapi/MobileLogin）。
   *
   * 为什么写进罐而不是自己存一份：整个 App（`MobileSession.ensure`、网页兜底、
   * 退出登录清罐）都只认这一个会话来源。原生密码登录成功后如果只在我们自己内存里存
   * sessionid，就等于"App 有两套会话观"，页面刷新一次就退回登录页。
   *
   * 写法照 SDK：`configCookieSync(url, cookieString)` —— url 给 Instagram 域名即可，
   * cookie 串里的 `Domain=.instagram.com` 让它对子域也生效。
   */
  static async adoptSession(sessionId: string, userId: string, csrf: string): Promise<boolean> {
    if (sessionId.length === 0 || userId.length === 0) {
      return false;
    }
    const attrs: string = 'Path=/; Domain=.instagram.com; Secure';
    const write = (name: string, value: string, httpOnly: boolean): boolean => {
      try {
        webview.WebCookieManager.configCookieSync(INSTAGRAM_URL,
          `${name}=${value}; ${attrs}${httpOnly ? '; HttpOnly' : ''}`);
        return true;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'configCookie %{public}s failed: %{public}s',
          name, (error as Error).message);
        return false;
      }
    };
    const okSession: boolean = write('sessionid', sessionId, true);
    write('ds_user_id', userId, false);
    if (csrf.length > 0) {
      write('csrftoken', csrf, false);
    }
    if (!okSession) {
      return false;
    }
    // 立刻落盘：不落的话重启就要重新登录（同 save 的说明）。
    await InstagramCookieJar.save();
    InstagramCookieJar.invalidate();
    hilog.info(DOMAIN, TAG, 'adopted native session sid=%{public}d uid=%{public}d csrf=%{public}d',
      sessionId.length, userId.length, csrf.length);
    return true;
  }

  private static async read(): Promise<Array<CookieEntry>> {
    // **API < 23 没有 `fetchAllCookies` / `WebHttpCookie`**（它们和 name/value/isHttpOnly
    // 都是 6.1.0(23) 起）：低版本设备上退回老接口 `fetchCookie(url)` —— 它返回的是
    // 一整条 Cookie 头字符串（"a=1; b=2"），自己解析即可。判据同样是"罐里有没有会话 Cookie"。
    if (!PlatformCap.hasCookieDetail()) {
      return InstagramCookieJar.readAsString();
    }
    let cookies: Array<webview.WebHttpCookie> = [];
    try {
      cookies = await webview.WebCookieManager.fetchAllCookies(false);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read cookie jar failed');
      return [];
    }
    const entries: Array<CookieEntry> = [];
    for (let index: number = 0; index < cookies.length; index++) {
      const item: webview.WebHttpCookie = cookies[index];
      const domain: string = `${item.domain ?? ''}`.trim();
      if (!InstagramCookieJar.isInstagramDomain(domain)) {
        continue;
      }
      const name: string = `${item.name ?? ''}`.trim();
      const value: string = `${item.value ?? ''}`.trim();
      if (name.length === 0 || value.length === 0) {
        continue;
      }
      entries.push(new CookieEntry(name, value, item.isHttpOnly === true));
    }
    return entries;
  }

  /**
   * 老接口那条路（API < 23）：`fetchCookie(url)` 回一整串 Cookie 头，按 `;` 切开自己解析。
   *
   * 拿不到 `isHttpOnly`（老接口没有这个信息）—— 它只用于诊断面板里给名字加个 (H) 标记，
   * 不影响会话判定与请求头。
   */
  private static async readAsString(): Promise<Array<CookieEntry>> {
    let raw: string = '';
    try {
      raw = await webview.WebCookieManager.fetchCookie(INSTAGRAM_URL);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read cookie string failed');
      return [];
    }
    const entries: Array<CookieEntry> = [];
    const parts: Array<string> = raw.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      if (one.length === 0) {
        continue;
      }
      const cut: number = one.indexOf('=');
      if (cut <= 0) {
        continue;
      }
      const name: string = one.substring(0, cut).trim();
      const value: string = one.substring(cut + 1).trim();
      if (name.length === 0 || value.length === 0) {
        continue;
      }
      entries.push(new CookieEntry(name, value, false));
    }
    return entries;
  }
}
