/*
 * 原生直接发 GraphQL（**不经过网页**）——"冷启动第一屏不等网页"那条路的执行者。
 *
 * 为什么能做：首页信息流那条请求的一切要素，我们都已经有了 ——
 *   1) 请求模板（方法 / URL / 请求头 / 请求体，带 doc_id 与 variables）：
 *      由 ApiRegistry 从网页里抓下来并**落盘**（见 ApiRegistry.persistTemplates）；
 *   2) 会话：Cookie 罐是持久的（登录一次就一直在），用 WebCookieManager 就能读出 Cookie 串，
 *      `csrftoken` 就在里面（IG 的 GraphQL 要求请求头 `x-csrftoken` 与它对得上）；
 *   3) 网络：ArkTS 的 http 模块不受浏览器同源/CORS 限制，Cookie 也能自己带头里发。
 *
 * 于是冷启动时可以先发这一发（几百毫秒拿到 5 条），网页那条路继续在后台跑：
 * 网页准备好之后照旧抓响应/回放并覆盖列表 —— 快的那条先出画面，慢的那条负责"最新最全"。
 *
 * 失败一律**不抛**，返回带 error 字段的结果，调用方直接退回网页路径。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { FeedItemDto } from '../model/FeedDto';
import { NativeTimeline, NativeTimelineParser } from './NativeTimelineParser';
// 首页时间线的移动端通道（实测 POST feed/timeline/ → 200；见那个文件的文件头）。
import { MobileFeedPage, MobileFeedTimeline } from './mobileapi/MobileFeedTimeline';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeFeed';
/** 首页信息流那条操作的名字片段（模板按它找）。 */
const FEED_OP: string = 'FeedTimeline';
/**
 * **迁移期对照开关**：true = 只走移动端 `feed/timeline/`，不走模板回放。
 *
 * 用来验证"**没有网页模板也能出信息流**"。平时 false（移动端失败自动退回模板）。
 */
const MOBILE_ONLY: boolean = false;
/** 连接键：响应里出现它就说明这一发真的拿到了信息流。 */
const FEED_KEY: string = 'xdt_api__v1__feed__timeline__connection';
/**
 * 原生请求里**必须丢掉**的请求头。
 *
 * 和页面内回放那份过滤表不一样：这边是"我们自己就是客户端"，所以要留 User-Agent / Origin /
 * Referer（Instagram 认这几个）；要丢的是长度/连接类（由 http 模块自己算）和编码类
 * （模块自己会处理 gzip，手写 accept-encoding 反而可能拿到压缩体解不开）。
 */
const HEADER_DROP: Array<string> = ['content-length', 'host', 'connection', 'accept-encoding',
  'transfer-encoding', 'upgrade', 'te', 'trailer'];
/**
 * 默认超时与要几条。 */
const CONNECT_TIMEOUT_MS: number = 6000;
const READ_TIMEOUT_MS: number = 8000;
/**
 * 网页版 Instagram 的 app id（`x-ig-app-id`）。
 *
 * 它是**公开的网页常量**（真机抓到的每个网页请求都带它），不是账号凭据。
 * 模板里带了就用模板的，没模板（全新安装）时用这个默认值。
 */
const WEB_APP_ID: string = '1217981644879628';
/**
 * 浏览器会替页面补上、但**抓不到**（fetch 的 init.headers 里没有）的那几个头。
 *
 * 为什么必须自己补：实测 Clips（reels）那条接口对我们的原生请求回的是 **HTML 整页**
 * （200 + 63KB `<!DOCTYPE html> … no_js`），也就是服务端把它当成"页面导航"而不是 XHR ——
 * 判据正是 `sec-fetch-*` / `accept` / `user-agent` 这几个头。信息流那条恰好不挑，所以
 * 一开始没暴露；补上之后两条都按 XHR 对待。
 */
const UA_DEFAULT: string = 'Mozilla/5.0 (Linux; Android 14; HarmonyOS) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/**
 * 原生取好的一页（解析好的条目 + 游标）。
 *
 * 两个用途：① 分页缓存里"备好的下一页"；② 冷启动**预热**（见 warmStart/takeWarm）。
 */
export class NativeFeedPage {
  readonly items: Array<FeedItemDto>;
  readonly nextCursor: string;
  readonly hasMore: boolean;
  /** 这一发花了多久（毫秒，日志用）。 */
  readonly ms: number;
  /** 这一页是什么时候取到的（判断预热的那份还新不新鲜）。 */
  readonly at: number;

  constructor(items: Array<FeedItemDto>, nextCursor: string, hasMore: boolean, ms: number) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    this.ms = ms;
    this.at = Date.now();
  }
}

/** 一次原生取数的结果（不抛异常，用 error 表达失败）。 */export class NativeFetchResult {
  readonly ok: boolean;
  readonly error: string;
  readonly code: number;
  readonly ms: number;
  readonly bytes: number;
  readonly hasConn: boolean;
  /** 响应里数出来的帖子条数（粗数，只用于日志/判断有没有拿到货）。 */
  readonly codes: number;
  readonly body: string;

  constructor(ok: boolean, error: string, code: number, ms: number, bytes: number,
              hasConn: boolean, codes: number, body: string) {
    this.ok = ok;
    this.error = error;
    this.code = code;
    this.ms = ms;
    this.bytes = bytes;
    this.hasConn = hasConn;
    this.codes = codes;
    this.body = body;
  }

  /** 一行摘要（日志用）。 */
  summary(): string {
    return `ok=${this.ok ? 'y' : 'n'} err=${this.error} http=${this.code} ms=${this.ms} `
      + `bytes=${this.bytes} conn=${this.hasConn ? 'y' : 'n'} codes=${this.codes}`;
  }
}

export class NativeFeed {
  /**
   * 冷启动预热的那一页（app 一起来就发，见 warmStart）。
   *
   * 为什么要有它：现在首屏数据是"页面问才要"（1.2~2.4 秒），而 app 起来到用户看到信息流
   * 中间还有一段（启动窗口、组件构建、网页宿主创建）。把这一发**提前到 ability onCreate**
   * 发出去，等页面来要时数据多半已经躺在内存里，用户看到的就是"秒出内容"。
   */
  private static warmPage: NativeFeedPage | null = null;
  private static warming: boolean = false;

  /**
   * app 启动时就发一发第一页，结果留在内存里等页面来取（幂等，重复调用不会重复发）。
   *
   * 不 await、不抛：预热失败无所谓，页面那条路会照旧自己发一次。
   */
  static warmStart(first: number): void {
    if (NativeFeed.warming || NativeFeed.warmPage !== null) {
      return;
    }
    NativeFeed.warming = true;
    const started: number = Date.now();
    NativeFeed.fetchPage(first, '').then((page: NativeFeedPage | null): void => {
      NativeFeed.warming = false;
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'warmStart miss after %{public}dms', Date.now() - started);
        return;
      }
      NativeFeed.warmPage = page;
      hilog.info(DOMAIN, TAG, 'warmStart ready n=%{public}d ms=%{public}d (since launch %{public}d)',
        page.items.length, page.ms, Date.now() - started);
    }).catch((): void => {
      NativeFeed.warming = false;
    });
  }

  /**
   * 取走预热的那一页（取走即清空）。
   *
   * @param maxAgeMs 太旧的不要：app 可能在后台躺了很久，那份数据已经不新鲜。
   */
  static takeWarm(maxAgeMs: number): NativeFeedPage | null {
    const page: NativeFeedPage | null = NativeFeed.warmPage;
    if (page === null) {
      return null;
    }
    NativeFeed.warmPage = null;
    if (Date.now() - page.at > maxAgeMs) {
      hilog.info(DOMAIN, TAG, 'warm page discarded age=%{public}dms', Date.now() - page.at);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'warm page used age=%{public}dms n=%{public}d',
      Date.now() - page.at, page.items.length);
    return page;
  }

  /**
   * 要一页并解析好（预热、首屏、翻页都走这里，保证解析规则只有一份）。
   *
   * 失败一律返回 null（HTTP 非 200 / 没有模板 / 没登录 / 解析不出条目）。
   */
  static async fetchPage(first: number, cursor: string): Promise<NativeFeedPage | null> {
    /*
     * **先走移动端 `feed/timeline/`**（见 core/mobileapi/MobileFeedTimeline）：
     * 实测 `POST feed/timeline/` → 200 / 253KB，参数走查询串。
     * 这是**最后一块模板依赖** —— 走通了，模板回放就只剩兜底作用。
     * 失败（无会话 / 非 200 / 形状变了 / 解析不出）再走下面老的模板回放。
     */
    const viaMobile: NativeFeedPage | null = await NativeFeed.viaMobile(cursor);
    if (viaMobile !== null) {
      return viaMobile;
    }
    // 对照开关：只走移动端（验证用，见文件顶部的 MOBILE_ONLY 常量）。
    if (MOBILE_ONLY) {
      hilog.info(DOMAIN, TAG, 'feed mobile-only: no page (%{public}s)',
        MobileFeedTimeline.detail());
      return null;
    }
    const result: NativeFetchResult = await NativeFeed.firstPage(first, cursor);
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'native page failed %{public}s', result.summary());
      return null;
    }
    const parsed: NativeTimeline | null = NativeTimelineParser.parse(result.body);
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, 'native page unparsable bytes=%{public}d', result.bytes);
      return null;
    }
    return new NativeFeedPage(parsed.items, parsed.nextCursor, parsed.hasNext, result.ms);
  }

  /**
   * 移动端那一发（拿不到给 null）。
   *
   * 解析用 `NativeTimelineParser.parseMobileFeed`（v1 媒体 → 同一套卡片 DTO），
   * 所以界面模型与模板那条完全一致，不需要第二份映射。
   */
  private static async viaMobile(cursor: string): Promise<NativeFeedPage | null> {
    const page: MobileFeedPage | null = await MobileFeedTimeline.page(cursor);
    if (page === null) {
      return null;
    }
    const parsed: NativeTimeline | null = NativeTimelineParser.parseMobileFeed(page.body);
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, 'feed mobile unparsable bytes=%{public}d (%{public}s)',
        page.body.length, MobileFeedTimeline.detail());
      return null;
    }
    hilog.info(DOMAIN, TAG, 'feed via mobile n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      parsed.items.length, `${parsed.hasNext}`, parsed.nextCursor.length, page.ms);
    return new NativeFeedPage(parsed.items, parsed.nextCursor, parsed.hasNext, page.ms);
  }

  /**
   * 原生要一页（`first` 条）。
   *
   * @param first  要几条（接口的 variables.first）。
   * @param cursor 翻页游标：空串 = 第一页；非空 = `variables.after = cursor`（上一页的 end_cursor）。
   * @param op     操作名片段（默认首页信息流；reels 传 ClipsTabRoot，见 core/NativeReels）。
   * @param expectKey 响应里**必须出现**的连接键（默认信息流那条；reels 传 clips 那条）——
   *                  它只是"这一发是不是拿到了我们要的那页"的判据，解析仍然交给各自的 parser。
   * @param first  传 0 表示**不要动模板的 variables**（原样发出）。有的接口（实测 Clips）
   *               我们对 variables 的改写会让服务端回 HTML 而不是 JSON，那就原样发一次。
   */
  static async firstPage(first: number, cursor: string = '', op: string = FEED_OP,
                         expectKey: string = FEED_KEY): Promise<NativeFetchResult> {
    const started: number = Date.now();
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl === null) {
      return NativeFeed.fail('no-template', started);
    }
    let jar: InstagramCookieSnapshot;
    try {
      jar = await InstagramCookieJar.inspect();
    } catch (error) {
      return NativeFeed.fail('cookie-read-failed', started);
    }
    if (!jar.signedIn) {
      return NativeFeed.fail('not-signed-in', started);
    }
    const headers: Record<string, string> = NativeFeed.buildHeaders(tpl, jar.cookie);
    // first <= 0 = 原样发模板（只换 __req）：见 firstPage 的参数说明。
    const body: string = first > 0
      ? NativeFeed.patchBody(tpl.body, first, cursor)
      : NativeFeed.randomizeReq(tpl.body);
    // 模板里的 URL 可能是**相对路径**（页面里 fetch('/graphql/query') 是合法的，同源自动补全），
    // 原生这边必须自己补成绝对地址 —— 否则 http 模块直接回 "Invalid URL format or missing URL"。
    const url: string = NativeFeed.absoluteUrl(tpl.url);
    const method: http.RequestMethod = tpl.method.trim().toUpperCase() === 'GET'
      ? http.RequestMethod.GET : http.RequestMethod.POST;
    hilog.info(DOMAIN, TAG, 'native POST op=%{public}s m=%{public}s url=%{public}s hdr=[%{public}s] body=%{public}d %{public}s',
      op, tpl.method, url, Object.keys(headers).join(','), body.length, NativeFeed.describeBody(body));
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: method,
        header: headers,
        extraData: body,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const hasConn: boolean = text.indexOf(expectKey) >= 0;
      const codes: number = NativeFeed.countCodes(text);
      const ok: boolean = response.responseCode === 200 && hasConn;
      return new NativeFetchResult(ok, ok ? '' : `http-${response.responseCode}`,
        response.responseCode, Date.now() - started, text.length, hasConn, codes, text);
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'native feed request failed: %{public}s', message);
      return NativeFeed.fail(`throw:${message}`.substring(0, 60), started);
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  private static fail(reason: string, started: number): NativeFetchResult {
    return new NativeFetchResult(false, reason, 0, Date.now() - started, 0, false, 0, '');
  }

  /**
   * 请求体摘要：操作名 + doc_id + variables（用于对比"信息流那发"和"reels 那发"差在哪）。
   *
   * 为什么要它：实测 reels 那一发 HTTP 200 但回的是 HTML（不是 JSON），而**同一个模板**用页面
   * 里的回放却是好的 —— 差别只可能在"我们原生这一发到底发了什么"，所以把关键字段摊开看。
   */
  private static describeBody(body: string): string {
    const name: string = NativeFeed.fieldOf(body, 'fb_api_req_friendly_name');
    const doc: string = NativeFeed.fieldOf(body, 'doc_id');
    const vars: string = NativeFeed.fieldOf(body, 'variables');
    const shown: string = vars.length > 160 ? vars.substring(0, 160) : vars;
    return `name=${name} doc=${doc} vars=${shown}`;
  }

  /** 取表单串里某个键的值（不解码，够看就行）。 */
  private static fieldOf(body: string, key: string): string {
    const parts: Array<string> = body.split('&');
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].indexOf(`${key}=`) === 0) {
        return parts[index].substring(key.length + 1);
      }
    }
    return '';
  }

  /**
   * 把模板里的 URL 补成绝对地址。
   *
   * 页面里 `fetch("/graphql/query")` 是合法的（同源会自己补），原生 http 模块不行。
   * 只补 instagram.com 这一种相对形式：模板都是从 IG 页面抓的，不存在别的来源。
   */
  private static absoluteUrl(url: string): string {
    const text: string = url.trim();
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return text;
    }
    if (text.startsWith('//')) {
      return `https:${text}`;
    }
    if (text.startsWith('/')) {
      return `https://www.instagram.com${text}`;
    }
    return `https://www.instagram.com/${text}`;
  }

  /**
   * 落盘那份模板的年龄（秒），没有就回 "none"。
   *
   * 只用于日志：这条快路径靠的是"上次抓到的模板还能不能用"，出问题时第一眼要能看出
   * 是"压根没有模板"还是"模板太旧被丢弃了"。
   */
  static templateAge(): string {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(FEED_OP);
    if (tpl === null) {
      return 'none';
    }
    return `${Math.round((Date.now() - tpl.at) / 1000)}s/${tpl.body.length}b`;
  }

  /**
   * 用**指定模板**（信息流那条以外的，例如网页抓来的 REST 模板 `/api/v1/discover/ayml/`）
   * 构造原生请求头。
   *
   * 为什么需要：IG 的写类私有接口（POST /api/v1/...）除了 Cookie/csrf，还要网页专有的
   * `x-ig-www-claim`（一个会话级的 hmac）、`x-instagram-ajax`(rollout_hash)、`x-asbd-id`
   * —— 这些只在**页面自己发过的那条请求**里才有，信息流模板（GraphQL）里未必带。
   * 抓到那条 REST 模板就等于把这些头一起拿到了（见 bridge/WebScripts 的 restPath）。
   */
  static async headersFor(op: string): Promise<Record<string, string>> {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl === null) {
      return {};
    }
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    if (!jar.signedIn) {
      return {};
    }
    const headers: Record<string, string> = NativeFeed.buildHeaders(tpl, jar.cookie);
    headers['x-requested-with'] = headers['x-requested-with'] ?? 'XMLHttpRequest';
    return headers;
  }

  /**
   * 先要模板里的会话头，没有（全新安装，模板表还空着）就退回**不依赖模板**的那一套。
   *
   * 骨架路径（点赞/转发/通知）用这个：它保证了"第一次装好、信息流还没抓到模板"时也能发请求。
   */
  static async sessionOrBrowserHeaders(): Promise<Record<string, string>> {
    const fromTemplate: Record<string, string> = await NativeFeed.sessionHeaders();
    if (Object.keys(fromTemplate).length > 0) {
      return fromTemplate;
    }
    return NativeFeed.browserHeaders();
  }

  /**
   * **不依赖任何模板**的"浏览器样子"的请求头（Cookie / csrftoken 现从 Cookie 罐取）。
   *
   * 为什么要它：`sessionHeaders()` 是拿信息流模板里的原始头拼的 —— 全新安装（模板表还空着）
   * 时那份头还不存在，于是点赞/转发/通知那条"骨架"路径会以 `no-session` 收场。
   * 这里把模板里真正要紧的那几样（UA、`sec-fetch-*`、`accept-language`、origin/referer、
   * app id）按 `buildHeaders` 里同一套默认值直接写出来，**没有模板也能发**。
   * （缺了这几个头 IG 会把请求当页面导航、回一整个 HTML —— 见 buildHeaders 的注释。）
   */
  static async browserHeaders(): Promise<Record<string, string>> {
    let jar: InstagramCookieSnapshot;
    try {
      jar = await InstagramCookieJar.inspect();
    } catch (error) {
      return {};
    }
    if (!jar.signedIn) {
      return {};
    }
    const out: Record<string, string> = {};
    out['cookie'] = jar.cookie;
    const csrf: string = NativeFeed.cookieValue(jar.cookie, 'csrftoken');
    if (csrf.length > 0) {
      out['x-csrftoken'] = csrf;
    }
    out['content-type'] = 'application/x-www-form-urlencoded';
    out['origin'] = 'https://www.instagram.com';
    out['referer'] = 'https://www.instagram.com/';
    out['x-ig-app-id'] = WEB_APP_ID;
    out['user-agent'] = UA_DEFAULT;
    out['accept'] = '*/*';
    out['accept-language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    out['sec-fetch-dest'] = 'empty';
    out['sec-fetch-mode'] = 'cors';
    out['sec-fetch-site'] = 'same-origin';
    out['x-requested-with'] = 'XMLHttpRequest';
    return out;
  }

  /**
   * 会话头（给"顺手发的写请求"用，比如关注/取关，见 core/NativeFollow）。
   *
   * 复用信息流模板里真机抓到的那份头 + Cookie/csrftoken：IG 的 REST 写接口（
   * `/api/v1/friendships/...`）和 GraphQL 走的是同一套鉴权。拿不到模板或没登录时回空对象，
   * 调用方据此直接判失败。
   */
  static async sessionHeaders(): Promise<Record<string, string>> {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(FEED_OP);
    if (tpl === null) {
      return {};
    }
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    if (!jar.signedIn) {
      return {};
    }
    const headers: Record<string, string> = NativeFeed.buildHeaders(tpl, jar.cookie);
    // 写请求补两个浏览器一定会带的头（抓模板时它们可能被过滤掉了，见 HEADER_DROP）。
    headers['x-requested-with'] = headers['x-requested-with'] ?? 'XMLHttpRequest';
    return headers;
  }

  /**
   * 请求头：模板里的原样头（去掉长度/连接/编码类）+ 我们自己的 Cookie 与 csrftoken。
   *
   * `x-csrftoken` 必须与 Cookie 里的 `csrftoken` 一致，否则 IG 直接 403；
   * `content-type` 用表单编码（GraphQL 的请求体就是 URLSearchParams 形式）。
   */
  private static buildHeaders(tpl: ApiTemplate, cookie: string): Record<string, string> {
    const out: Record<string, string> = {};
    const raw: Array<Array<string>> = tpl.rawHeaders;
    for (let index: number = 0; index < raw.length; index++) {
      const pair: Array<string> = raw[index];
      const name: string = (pair[0] ?? '').trim().toLowerCase();
      if (name.length === 0 || HEADER_DROP.indexOf(name) >= 0) {
        continue;
      }
      out[name] = pair[1] ?? '';
    }
    out['cookie'] = cookie;
    const csrf: string = NativeFeed.cookieValue(cookie, 'csrftoken');
    if (csrf.length > 0) {
      out['x-csrftoken'] = csrf;
    }
    if (out['content-type'] === undefined) {
      out['content-type'] = 'application/x-www-form-urlencoded';
    }
    if (out['origin'] === undefined) {
      out['origin'] = 'https://www.instagram.com';
    }
    if (out['referer'] === undefined) {
      out['referer'] = 'https://www.instagram.com/';
    }
    out['x-ig-app-id'] = out['x-ig-app-id'] ?? WEB_APP_ID;
    // 补齐"浏览器本来会补、但我们抓不到"的那几个头（见 UA_DEFAULT 的说明）。
    out['user-agent'] = out['user-agent'] ?? UA_DEFAULT;
    out['accept'] = out['accept'] ?? '*/*';
    out['accept-language'] = out['accept-language'] ?? 'zh-CN,zh;q=0.9,en;q=0.8';
    out['sec-fetch-dest'] = out['sec-fetch-dest'] ?? 'empty';
    out['sec-fetch-mode'] = out['sec-fetch-mode'] ?? 'cors';
    out['sec-fetch-site'] = out['sec-fetch-site'] ?? 'same-origin';
    return out;
  }

  /** 只把 `__req` 换个随机值（原样发送模板时用，避免与页面正在进行的请求撞号）。 */
  private static randomizeReq(body: string): string {
    return body.replace(/__req=[^&]*/, `__req=${Math.random().toString(36).substring(2, 4)}`);
  }

  /**
   * 请求体：只动三个字段 —— `variables.first`（要几条）、`variables.after`（翻页游标）、
   * `__req`（换个随机值）。
   *
   * 别的一律照抄模板（doc_id / __d / __a / __hs / jazoest / lsd 都在里面）。
   * `variables` 必须 `JSON.parse` 之后再改：直接字符串拼会变成 `{"0":"{",...}`，
   * 服务端回一句 noncoercible_variable_value（这个坑在「我的」上踩过）。
   *
   * 翻页只改 `after`，和网页那条回放路径（timelineScript 里的 setCursor）保持一致 ——
   * 多动 `last`/`before` 反而容易踩 Relay 的参数校验。
   */
  private static patchBody(body: string, first: number, cursor: string = ''): string {
    const parts: Array<string> = body.split('&');
    const out: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const part: string = parts[index];
      if (part.indexOf('__req=') === 0) {
        out.push(`__req=${Math.random().toString(36).substring(2, 4)}`);
        continue;
      }
      if (part.indexOf('variables=') !== 0) {
        out.push(part);
        continue;
      }
      try {
        const src: Record<string, Object> =
          JSON.parse(decodeURIComponent(part.substring('variables='.length))) as Record<string, Object>;
        // 重建一份 variables：把 after 剔掉再按游标决定加不加（不能写 null ——
        // Record<string, Object> 不收 null，而 `after: null` 本来就是"第一页"的语义：
        // 键不存在就是第一页，和网页那条回放路径一致）。
        const vars: Record<string, Object> = {};
        const keys: Array<string> = Object.keys(src);
        for (let k: number = 0; k < keys.length; k++) {
          if (keys[k] === 'after') {
            continue;
          }
          vars[keys[k]] = src[keys[k]];
        }
        vars['first'] = first;
        if (cursor.length > 0) {
          vars['after'] = cursor;
        }
        out.push(`variables=${encodeURIComponent(JSON.stringify(vars))}`);
      } catch (error) {
        out.push(part);
      }
    }
    return out.join('&');
  }

  private static cookieValue(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const pair: string = parts[index].trim();
      if (pair.startsWith(`${name}=`)) {
        return pair.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  /** 粗数响应里有几条帖子（`"code":"xxx"` 的出现次数）——只用于日志。 */
  private static countCodes(text: string): number {
    let count: number = 0;
    let at: number = text.indexOf('"code":"');
    while (at >= 0 && count < 999) {
      count++;
      at = text.indexOf('"code":"', at + 8);
    }
    return count;
  }
}
