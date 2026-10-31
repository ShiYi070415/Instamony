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
  /** 作废代数：每次 `invalidate()` +1，用来丢弃"作废之前发起、作废之后才回来"的读（见 inspect）。 */
  private static generation: number = 0;
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
    const gen: number = InstagramCookieJar.generation;
    const task: Promise<InstagramCookieSnapshot> = InstagramCookieJar.readSnapshot();
    InstagramCookieJar.pending = task;
    try {
      const snapshot: InstagramCookieSnapshot = await task;
      /*
       * **只有"发起这一读之后没被作废过"才写缓存**（见 invalidate）。
       *
       * 换账号/退出登录恰好撞上这一读在飞时：那一读读到的是**上一个账号**的 Cookie，
       * 写进缓存就会让接下来 1.5 秒里所有 `inspect()` 都返回旧账号（真机表现是
       * "换号后第一屏还是上一个人的内容 / 退出登录后仍认为已登录"）。
       */
      if (gen === InstagramCookieJar.generation) {
        InstagramCookieJar.cached = snapshot;
        InstagramCookieJar.cachedAt = Date.now();
      }
      return snapshot;
    } finally {
      // 只清"自己那一张"：期间被 invalidate 之后可能有新的一读顶上来。
      if (InstagramCookieJar.pending === task) {
        InstagramCookieJar.pending = null;
      }
    }
  }

  /**
   * 作废读罐缓存（登录/退出/换号/落盘前后调，见 save / clear）。
   *
   * **两样都要作废**：已完成的缓存值，以及**正在飞的那一读**。
   * 上一版只清了缓存值：飞着的那一读回来照样把旧 Cookie 写进缓存，而且后面 1.5 秒里
   * 所有调用都会搭上它（`pending` 还挂着）—— 换号瞬间读到上一个人的会话正是这么来的。
   */
  static invalidate(): void {
    InstagramCookieJar.cached = null;
    InstagramCookieJar.cachedAt = 0;
    InstagramCookieJar.pending = null;
    InstagramCookieJar.generation++;
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
   * 只删**会话类** cookie 的名字（见 `clearSessionOnly`）。
   *
   * 除了网页那几颗（sessionid / ds_user_id / csrftoken / rur / shbid / shbts），还要带上
   * **`ig-u-*`**：设备级会话登录时服务端只回 `ig-set-ig-u-ds-user-id` / `ig-set-ig-u-rur`
   * 这类头（见 core/mobileapi/CaaLogin.cookiesFromSessionHeaders），它们会被种成 `ig-u-*`
   * cookie，**也是按人/按会话的**。换号不删的话，Cookie 头里会同时出现"新 ds_user_id +
   * 上一个人的 ig-u-ds-user-id / ig-u-rur"——正是历史上修过的"两个身份"那类问题。
   */
  private static readonly SESSION_COOKIES: Array<string> = [
    'sessionid', 'ds_user_id', 'csrftoken', 'rur', 'shbid', 'shbts',
    'ig-u-sessionid', 'ig-u-ds-user-id', 'ig-u-rur', 'ig-u-shbid', 'ig-u-shbts',
    'ig-u-www-claim'
  ];

  /**
   * 换号时要作废、但**不会被 `adoptSession` 重新写回**的旧会话项。
   *
   * `rur` / `shbid` / `shbts` / `ig-u-*` 都是"按会话（有时按人）"的材料，`adoptSession`
   * 只重写 sessionid / ds_user_id / csrftoken —— 不主动作废的话，切到新账号之后
   * 请求头里还带着上一个人的 IG-U-RUR / ig-u-ds-user-id。
   */
  private static readonly CROSS_ACCOUNT_STALE_COOKIES: Array<string> = [
    'rur', 'shbid', 'shbts',
    'ig-u-sessionid', 'ig-u-ds-user-id', 'ig-u-rur', 'ig-u-shbid', 'ig-u-shbts',
    'ig-u-www-claim'
  ];

  /** 设备级会话（没有 sessionid）切过去时要清掉的会话项：sessionid 本身也算陈旧项。 */
  private static readonly DEVICE_LEVEL_STALE_COOKIES: Array<string> = [
    'sessionid', 'rur', 'shbid', 'shbts',
    'ig-u-sessionid', 'ig-u-ds-user-id', 'ig-u-rur', 'ig-u-shbid', 'ig-u-shbts',
    'ig-u-www-claim'
  ];

  /**
   * 把若干颗 cookie 置成已过期（`name=; Max-Age=0`），返回处理了几颗。
   *
   * 这个 SDK 的 `WebCookieManager` **没有** `deleteCookieSync`（编译期就报不存在），
   * 所以用"把同名 cookie 覆盖成已过期"这个标准做法来删。只改引擎里的罐，
   * 落盘交给调用方（`save()`）。
   */
  private static expire(names: Array<string>): number {
    let removed: number = 0;
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      try {
        webview.WebCookieManager.configCookieSync('https://www.instagram.com/',
          `${name}=; Max-Age=0; Path=/; Domain=.instagram.com`);
        webview.WebCookieManager.configCookieSync('https://i.instagram.com/',
          `${name}=; Max-Age=0; Path=/; Domain=.instagram.com`);
        removed++;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'expire cookie %{public}s failed: %{public}s',
          name, (error as Error).message);
      }
    }
    return removed;
  }

  /**
   * **只清会话、保留设备身份**（换号 / "新增账号"用）。
   *
   * 为什么不能整罐清：用户反馈"两个号在同一个 Meta 账户下，浏览器里已登录大号时加小号
   * **不需要 2FA**"——IG 判"可信设备"靠的是 `datr` / `ig_did` / `mid` 这类**设备** cookie
   * 以及网页存储。整罐清（`clearAllCookiesSync` + `deleteAllData`）等于把自己伪装成
   * 一台全新设备，IG 于是要求"恢复确认"，而且**不给 6 位验证码**（我们抓到过：
   * `authenticated:false` + `showAccountRecoveryModal:true`，没有 `two_factor_required`）。
   *
   * 所以这条路只删会话那几颗：登录页照样会显示（没有 sessionid 就不是登录态），
   * 但设备指纹与存储留着，IG 更可能走"同一台设备切换账号"的轻路径。
   *
   * 现在两处用它：切换账号时清上一个账号的会话 cookie（见
   * core/AccountActionService.adoptAccount），以及"新增账号"清场。
   *
   * @returns 是否至少删掉了一颗（失败时让调用方决定要不要退回整罐清）
   */
  static async clearSessionOnly(): Promise<boolean> {
    InstagramCookieJar.invalidate();
    const removed: number = InstagramCookieJar.expire(InstagramCookieJar.SESSION_COOKIES);
    await InstagramCookieJar.save();
    hilog.info(DOMAIN, TAG, 'cleared %{public}d session cookie(s), device cookies kept',
      removed);
    return removed > 0;
  }

  /**
   * 只作废**跨账号的旧会话项**（rur / shbid / shbts / ig-u-*），不碰刚种好的
   * sessionid / ds_user_id / csrftoken（见 CROSS_ACCOUNT_STALE_COOKIES 的说明）。
   *
   * 用在 `adoptSession` 成功之后：带 sessionid 的账号切过去时，罐里还留着上一个人的
   * IG-U-RUR 等材料，不删就是"两个身份"。
   */
  static async expireCrossAccountCookies(): Promise<number> {
    InstagramCookieJar.invalidate();
    const removed: number = InstagramCookieJar.expire(
      InstagramCookieJar.CROSS_ACCOUNT_STALE_COOKIES);
    if (removed > 0) {
      await InstagramCookieJar.save();
      hilog.info(DOMAIN, TAG, 'expired %{public}d cross-account cookie(s)', removed);
    }
    return removed;
  }

  /**
   * **把设备级会话（没有 sessionid）的账号身份种回 Cookie 罐**（切换账号用，
   * 见 core/AccountActionService.adoptAccount）。
   *
   * 和 `adoptSession` 的分工：带 sessionid 的会话只要重种三颗 cookie；而设备级会话
   * （IG 2026-10 起密码登录会下发，唯一凭据是 `Authorization: Bearer IGT:2:…`）没有
   * sessionid，这里只负责**账号身份**（`ds_user_id` / `csrftoken`），Authorization 由
   * 调用方交给 `MobileSession`。
   *
   * **顺序是刻意的（先写新身份、再清旧会话）**：以前写成"先 `clearSessionOnly` 再写"，
   * 任何一步失败都会把罐清空（signedIn=false、移动 API 全挂）而界面还停在上一个账号。
   * 现在先写 `ds_user_id`（写失败就原样返回，罐里还是上一个账号），成功后才作废
   * `sessionid` 等旧会话项；旧 `sessionid` 必须清掉 —— 不清的话 `MobileSession.ensure()`
   * 会把它当成"这个人的会话"（新 ds_user_id + 旧 sessionid = 两个身份），
   * MobileRequest 也会把它原样塞进 Cookie 头。
   *
   * 设备身份（datr / ig_did / mid…）**一律保留**：同一台设备换号不该被判成新设备。
   */
  static async adoptDeviceSession(userId: string, csrf: string): Promise<boolean> {
    if (userId.length === 0) {
      return false;
    }
    const attrs: string = 'Path=/; Domain=.instagram.com; Secure';
    // ① 先写目标账号的 ds_user_id：失败时罐里还是上一个账号（这一步不破坏原状态）。
    try {
      webview.WebCookieManager.configCookieSync(INSTAGRAM_URL,
        `ds_user_id=${userId}; ${attrs}`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'configCookie ds_user_id failed: %{public}s',
        (error as Error).message);
      return false;
    }
    // ② 写 csrftoken（有就写；没有的话 MobileSession 会现造一个）。
    if (csrf.length > 0) {
      try {
        webview.WebCookieManager.configCookieSync(INSTAGRAM_URL,
          `csrftoken=${csrf}; ${attrs}`);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'configCookie csrftoken failed: %{public}s',
          (error as Error).message);
      }
    }
    // ③ 作废设备级会话不该有的旧会话项（sessionid / rur / ig-u-*；不碰刚写的两颗）。
    const expired: number = InstagramCookieJar.expire(
      InstagramCookieJar.DEVICE_LEVEL_STALE_COOKIES);
    // ④ 立刻落盘：不落的话重启就要重新走一遍登录。
    await InstagramCookieJar.save();
    InstagramCookieJar.invalidate();
    // ⑤ 复核：旧 sessionid 真删掉了才算干净（删不掉只记日志，Authorization 那条路仍能跑）。
    try {
      const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const stale: boolean = snapshot.cookie.indexOf('sessionid=') >= 0;
      hilog.info(DOMAIN, TAG,
        'adopted device-level session uid=%{public}d csrf=%{public}d expired=%{public}d staleSid=%{public}s',
        userId.length, csrf.length, expired, stale ? '1' : '0');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'verify device-level session failed: %{public}s',
        (error as Error).message);
    }
    return true;
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

  /**
   * **把一整串 Cookie 原样种进罐**（见 core/mobileapi/CaaSession）。
   *
   * 和 `adoptSession` 的分工：那个只种三颗会话 Cookie（网页登录 / 切换账号够用）；
   * CAA 登录的响应里还带 `mid` / `rur` / `ig_did` / `datr` 这类**设备与会话材料**，
   * 移动 API 与推送达标都要看它们，所以这里把服务端给的每一颗都种进去。
   *
   * @param cookieText `name=value; name=value`（不含 `Set-Cookie:` 前缀与属性段）
   * @returns 成功写进去的颗数（0 = 没写成，调用方别当成功）
   */
  static async adoptCookieText(cookieText: string): Promise<number> {
    const attrs: string = 'Path=/; Domain=.instagram.com; Secure';
    // 这几颗在真实浏览器里是 HttpOnly：种进罐时也标上，免得网页脚本把它们读走。
    const HTTP_ONLY: Array<string> = ['sessionid', 'rur', 'mid', 'shbid', 'shbts'];
    let written: number = 0;
    const parts: Array<string> = cookieText.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      const cut: number = one.indexOf('=');
      if (cut <= 0) {
        continue;
      }
      const name: string = one.substring(0, cut).trim();
      const value: string = one.substring(cut + 1).trim();
      if (name.length === 0 || value.length === 0) {
        continue;
      }
      try {
        webview.WebCookieManager.configCookieSync(INSTAGRAM_URL,
          `${name}=${value}; ${attrs}${HTTP_ONLY.indexOf(name) >= 0 ? '; HttpOnly' : ''}`);
        written++;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'adopt cookie %{public}s failed: %{public}s',
          name, (error as Error).message);
      }
    }
    if (written > 0) {
      await InstagramCookieJar.save();
      InstagramCookieJar.invalidate();
      hilog.info(DOMAIN, TAG, 'adopted %{public}d cookie(s) from a native login', written);
    }
    return written;
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
