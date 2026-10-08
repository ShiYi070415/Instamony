/*
 * 通知页的**原生取数**（不经过隐藏网页）。
 *
 * ## 端点
 * IG 的网页/客户端拿通知用的是 REST 那两条（和 WebScripts.notificationsScript 里打的完全一样）：
 *   ① GET/POST https://www.instagram.com/api/v1/news/inbox/?timezone_offset=-<分钟>
 *        返回 { new_stories: [...], old_stories: [...], continuation_token, counts }
 *   ② GET/POST https://www.instagram.com/api/v1/discover/ayml/?timezone_offset=-<分钟>
 *        返回 { suggested_users: [...] }（"为你推荐"里那些人）
 *
 * ## 鉴权
 * 和 GraphQL/关注接口同一套：Cookie + `x-csrftoken` + `x-ig-app-id`（+ UA / sec-fetch 等）。
 * 所以直接复用 `NativeFeed.sessionHeaders()` —— 那份头是**真机从网页抓到的模板头**，
 * 不需要为通知再抓一次模板；万一 IG 对这条要额外头（例如 `x-ig-www-claim`），
 * 用探针在网页里打开一次通知页抓到这条请求，把它的头补进 NativeFeed.buildHeaders 即可。
 *
 * ## 输出
 * 直接产出和网页脚本**完全相同形状**的 `NotificationsPayload`（items: NotifyPayloadItem[]），
 * 这样页面上那条 `mapNotifications()` 一行都不用改。
 *
 * ArkTS 注意：所有"看起来像对象类型"的地方都要**具名 interface**，
 * 对象字面量必须赋给显式声明了类型的变量（不能字面量 + as 断言）。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeFeed, NativeFetchResult } from './NativeFeed';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { WebTokens } from './WebTokens';
import { EngageSkeleton } from './EngageSkeleton';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { NotificationsPayload, NotifyPayloadItem } from '../model/Notification';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeNotify';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 10000;
/**
 * show_many 的"跑道"：超过这个时间就先出列表（见 fetch 里的 Promise.race）。
 *
 * 这条接口偶尔很慢，拖住它会让用户一直看到"正在刷新"。
 */
const SHOW_MANY_CAP_MS: number = 4000;
/**
 * 「为你推荐」（ayml）模板在模板表里的名字片段。
 *
 * 页面侧给 REST 请求起的名字是 `rest_/api/v1/discover/ayml/`（见 WebScripts 的 restPath），
 * 这里按片段查，名字改了也还找得到。
 */
const AYML_OP: string = 'ayml';
/** friendships/show_many 的模板名片段（关注状态；同样是 REST，可能要 claim）。 */
const SHOW_MANY_OP: string = 'show_many';

/** inline_follow（有些条目带了"回关"状态）。 */
interface NewsInlineFollow {
  following?: boolean | null;
  username?: string | null;
}

/** 文案里的一段标注（用户名等），见 NewsStoryArgs.links。 */
interface NewsLink {
  type?: string | null;
  username?: string | null;
  id?: string | null;
}

/** news/inbox 里一条故事的字段（都可能缺）。 */
interface NewsStoryArgs {
  profile_image?: string | null;
  /** 有的版本头像字段叫这个名。 */
  profile_pic_url?: string | null;
  profile_id?: string | null;
  profile_name?: string | null;
  /**
   * "A 和 B 赞了你的快拍"里**第二个人**的头像用户 id。
   *
   * 聚合通知（两个人一起点赞）只有第一个人的 `profile_image`，第二个人单独放在
   * `second_profile_image` 里 —— 不读它，行首就只画得出一张头像（用户报的
   * "两个人点赞却只显示一个头像"）。
   */
  second_profile_id?: string | null;
  second_profile_image?: string | null;
  username?: string | null;
  text?: string | null;
  timestamp?: number | null;
  following?: boolean | null;
  rich_text?: string | null;
  /**
   * 目的地（形如 `user?id=12345678901&username=alice`）。
   *
   * **关注类通知的账号名就藏在这里**：那类条目的 args 里既没有 username，也没有单独的
   * 用户名字段（见 storyToItem）。
   */
  destination?: string | null;
  /**
   * 文案里被 IG 标出来的片段（用户名 / 话题…）。
   *
   * 用户名要**单独加粗**渲染，靠的就是这里：每条 `{start,end,type:"user",username}` 指出了
   * 文案里的哪一段是账号名（"carol 和 bob 赞了你的快拍。" 里的两个名字）。
   */
  links?: Array<NewsLink> | null;
  inline_follow?: NewsInlineFollow | null;
  /** 分享媒体的通知（"某人发了新帖"）把图放在这里，形状各版本不同，见 findMediaUrl。 */
  media?: Object | null;
}

interface NewsMediaCandidate {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

interface NewsImageVersions {
  candidates?: Array<NewsMediaCandidate> | null;
}

interface NewsStoryMedia {
  image_versions2?: NewsImageVersions | null;
}

interface NewsStory {
  pk?: string | null;
  story_type?: number | null;
  /** IG 自己的动作名（`user_followed` 就是"某人开始关注你"）。 */
  notif_name?: string | null;
  args?: NewsStoryArgs | null;
  media?: NewsStoryMedia | null;
}

interface NewsInbox {
  new_stories?: Array<NewsStory> | null;
  old_stories?: Array<NewsStory> | null;
}

interface AymlFriendship {
  following?: boolean | null;
}

interface AymlUser {
  pk?: string | number | null;
  username?: string | null;
  full_name?: string | null;
  profile_pic_url?: string | null;
  social_context?: string | null;
  friendship_status?: AymlFriendship | null;
}

/**
 * ayml 里的一条推荐。
 *
 * **注意 user 是嵌套的**：真机返回的形状是
 *   `{"suggested_users":{"suggestions":[{"user":{pk,username,full_name,profile_pic_url,…},
 *     "algorithm":"…","social_context":"…"}]}}`
 * 不是扁平的 `{"username":…}`，而且外层是**对象**不是数组（第一版按扁平数组解析 →
 * 一条都读不出来 → 整段"为你推荐"空掉）。扁平的旧形状也留着兼容。
 */
interface AymlEntry {
  user?: AymlUser | null;
  algorithm?: string | null;
  social_context?: string | null;
}

/** `suggested_users` 的对象形状（现代版本）：里面才是 suggestions 数组。 */
interface AymlSuggestions {
  suggestions?: Array<AymlEntry> | null;
}

interface AymlPayload {
  suggested_users?: AymlSuggestions | Array<AymlEntry> | null;
}

/** friendships/show_many 里一个人的状态。 */
interface ShowManyStatus {
  following?: boolean | null;
  outgoing_request?: boolean | null;
}

/** friendships/show_many 的响应。 */
interface ShowManyResponse {
  friendship_statuses?: Record<string, ShowManyStatus> | null;
}

export class NativeNotifications {
  /**
   * 拉一次通知：news/inbox（必）+ discover/ayml（推荐位，失败不影响主列表）。
   *
   * @param asOfMs 保留参数（分组基准由页面那边算，这里只负责产出条目）。
   */
  static async fetch(asOfMs: number = Date.now()): Promise<NotificationsPayload> {
    const headers: Record<string, string> = await NativeFeed.sessionOrBrowserHeaders();
    if (Object.keys(headers).length === 0) {
      // 没模板/没登录：直接回空载荷，页面会走"读不到通知"的提示。
      const noSession: NotificationsPayload = {
        state: 'error',
        message: 'no-session',
        diag: 'no-session',
        items: []
      };
      return noSession;
    }
    const tz: number = NativeNotifications.timezoneOffsetMinutes();
    // **inbox 与 ayml 并发**（原来是串行，三条请求加起来十几秒，用户看到的是"一直在刷新"）。
    const inboxUrl: string = `https://www.instagram.com/api/v1/news/inbox/?timezone_offset=${-tz}`;
    const aymlUrl: string = `https://www.instagram.com/api/v1/discover/ayml/?timezone_offset=${-tz}`;
    // ayml 优先走**网页抓来的 REST 模板**（见 AYML_OP 的说明）：这条接口 GET 回 405，
    // 裸 POST 回一整个 HTML 外壳 —— 它要的是网页专有的 `x-ig-www-claim`（会话级 hmac）
    // 加上 `fb_dtsg`/`jazoest` 这一对表单令牌，这些只有"页面自己发过的那条请求"里才有。
    // 模板没有（还没抓过）时才退回裸 POST 试一次。
    const aymlTpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(AYML_OP);
    let aymlCall: Promise<NativeFetchResult>;
    if (aymlTpl !== null) {
      // ① 有网页抓来的模板：和页面刚发的那条一模一样，最稳。
      const tplHeaders: Record<string, string> = await NativeFeed.headersFor(AYML_OP);
      if (Object.keys(tplHeaders).length > 0) {
        aymlCall = NativeNotifications.post(NativeNotifications.absolute(aymlTpl.url),
          aymlTpl.body, tplHeaders);
      } else {
        aymlCall = NativeNotifications.skeletonAyml(aymlUrl, headers);
      }
    } else {
      // ② **没有模板也能发**：包内骨架（URL/短表单）+ 现场从页面读到的 fb_dtsg/jazoest
      // 与 Cookie 罐里的 csrf（见 core/EngageSkeleton 与 core/WebTokens）。
      aymlCall = NativeNotifications.skeletonAyml(aymlUrl, headers);
    }
    const both: Array<NativeFetchResult> = await Promise.all([
      NativeNotifications.get(inboxUrl, headers),
      aymlCall
    ]);
    const inbox: NativeFetchResult = both[0];
    const ayml: NativeFetchResult = both[1];
    if (!inbox.ok) {
      hilog.warn(DOMAIN, TAG, 'inbox failed: %{public}s code=%{public}d len=%{public}d',
        inbox.error, inbox.code, inbox.body.length);
      hilog.warn(DOMAIN, TAG, 'inbox body: %{public}s',
        inbox.body.substring(0, 160).replace(/[\r\n]+/g, ' '));
      const failed: NotificationsPayload = {
        state: 'error',
        message: inbox.error,
        diag: inbox.error,
        items: []
      };
      return failed;
    }
    const items: Array<NotifyPayloadItem> = NativeNotifications.parseInbox(inbox.body);
    // **关注状态也用原生补**（网页那套 DOM 扫描的替代）：friendships/show_many 一次问一批人。
    // 但它**不许拖住列表**：这条接口偶尔很慢（真机实测有卡到读超时的时候），
    // 所以给它一个 4 秒的"跑道"，超时就先按接口里已有的 following 出列表（返回后它算完也就算了）。
    let resolved: number = 0;
    try {
      resolved = await Promise.race([
        NativeNotifications.applyFollowStates(items, headers),
        NativeNotifications.delayValue(SHOW_MANY_CAP_MS)
      ]);
    } catch (error) {
      resolved = 0;
    }
    if (ayml.ok) {
      try {
        const suggested: Array<NotifyPayloadItem> = await NativeNotifications.parseAyml(ayml.body, headers);
        for (let i: number = 0; i < suggested.length; i++) {
          items.push(suggested[i]);
        }
      } catch (error) {
        // 推荐位解析失败**不能影响**主列表（整条链会因为一个异常全丢）。
        hilog.warn(DOMAIN, TAG, 'ayml parse failed: %{public}s', (error as Error).message);
      }
    } else {
      hilog.warn(DOMAIN, TAG, 'ayml failed: %{public}s', ayml.error);
    }
    hilog.info(DOMAIN, TAG, 'native notify items=%{public}d followResolved=%{public}d inboxLen=%{public}d aymlLen=%{public}d',
      items.length, resolved, inbox.body.length, ayml.body.length);
    const ok: NotificationsPayload = {
      state: 'ok',
      // rows 用"这次真正读到关注状态的人数"：页面据此判断 following 是"读到了"还是"没读到"
      // （见 model/Notification.rows 的说明）。
      rows: resolved,
      items: items
    };
    return ok;
  }

  /**
   * 一次问一批人的关注状态，写回 items[i].following。
   *
   * 端点：`POST https://www.instagram.com/api/v1/friendships/show_many/`，body
   * `user_ids=1,2,3`（form-urlencoded）；响应 `{ friendship_statuses: { "<id>": { following } } }`。
   * 返回**成功问到的条数**（页面用 rows 判断"关注状态读到了没有"）。
   */
  private static async applyFollowStates(items: Array<NotifyPayloadItem>,
                                         headers: Record<string, string>): Promise<number> {
    const ids: Array<string> = [];
    for (let i: number = 0; i < items.length; i++) {
      const id: string = (items[i].userId ?? '').trim();
      if (id.length > 0 && ids.indexOf(id) < 0) {
        ids.push(id);
      }
    }
    if (ids.length === 0) {
      return 0;
    }
    const body: string = `user_ids=${encodeURIComponent(ids.join(','))}`;
    // **先试 GET**：真机实测 `/api/v1/` 的 POST 在原生侧会被 IG 当成页面导航（回一整页 HTML），
    // 而 GET 那条路是通的（news/inbox、friendships/pending 都是 GET + JSON）。
    const getUrl: string =
      `https://www.instagram.com/api/v1/friendships/show_many/?user_ids=${encodeURIComponent(ids.join(','))}`;
    let response: NativeFetchResult = await NativeNotifications.get(getUrl, headers);
    if (!response.ok) {
      response = await NativeNotifications.post(
        'https://www.instagram.com/api/v1/friendships/show_many/', body,
        await NativeNotifications.restHeaders(SHOW_MANY_OP, headers));
    }
    if (!response.ok) {
      hilog.warn(DOMAIN, TAG, 'show_many failed: %{public}s ids=%{public}d', response.error, ids.length);
      hilog.warn(DOMAIN, TAG, 'show_many body: %{public}s',
        response.body.substring(0, 160).replace(/[\r\n]+/g, ' '));
      return 0;
    }
    let data: ShowManyResponse | null = null;
    try {
      data = JSON.parse(response.body) as ShowManyResponse;
    } catch (error) {
      return 0;
    }
    const statuses: Record<string, ShowManyStatus> = (data ?? {}).friendship_statuses ?? {};
    let resolved: number = 0;
    for (let i: number = 0; i < items.length; i++) {
      const id: string = (items[i].userId ?? '').trim();
      if (id.length === 0) {
        continue;
      }
      const one: ShowManyStatus | undefined = statuses[id];
      if (one === undefined) {
        continue;
      }
      items[i].following = one.following === true;
      resolved = resolved + 1;
    }
    hilog.info(DOMAIN, TAG, 'show_many asked=%{public}d resolved=%{public}d', ids.length, resolved);
    return resolved;
  }

  /**
   * 骨架 + 页面令牌拼一条 ayml（没有网页抓来的模板时用，见 core/EngageSkeleton）。
   *
   * 真机样本里这条 POST 只带 `jazoest` + `fb_dtsg` 两个表单字段，头上有 csrf / ajax(rev) /
   * app-id / asbd / claim / web-session-id。我们手上没有会话级的 claim 与 web-session-id，
   * 先按"能拿到多少发多少"来：服务端不认就返回失败，调用方照旧走"去活动页抓模板"那条路。
   */
  private static async skeletonAyml(url: string,
                                    fallback: Record<string, string>): Promise<NativeFetchResult> {
    if (!await WebTokens.ensure()) {
      return new NativeFetchResult(false, 'no-tokens', 0, 0, 0, false, 0, '');
    }
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    if (!jar.signedIn) {
      return new NativeFetchResult(false, 'no-session', 0, 0, 0, false, 0, '');
    }
    const cookie: string = jar.cookie ?? '';
    const csrf: string = NativeNotifications.cookieValue(cookie, 'csrftoken');
    const headers: Record<string, string> = EngageSkeleton.aymlHeaders(await NativeFeed.sessionOrBrowserHeaders(), csrf, cookie);
    if (Object.keys(headers).length === 0) {
      return NativeNotifications.post(url, `timezone_offset=0`, fallback);
    }
    return NativeNotifications.post(url, EngageSkeleton.aymlBody(''), headers);
  }


  /** Cookie 串里取一个值（csrf 用）。 */
  private static cookieValue(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const one: string = parts[i].trim();
      if (one.indexOf(`${name}=`) === 0) {
        return one.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  /** 一次 form-urlencoded POST（关注状态批量查询 / ayml 用）。 */
  private static async post(url: string, body: string,
                            headers: Record<string, string>): Promise<NativeFetchResult> {
    const started: number = Date.now();
    const request: http.HttpRequest = http.createHttp();
    // **显式声明表单类型**：IG 的写类私有接口按 Content-Type 分流，
    // 不带这个头时 POST 可能掉进"页面路由"里回一整个 HTML 而不是 JSON。
    const form: Record<string, string> = {};
    const keys: Array<string> = Object.keys(headers);
    for (let i: number = 0; i < keys.length; i++) {
      form[keys[i]] = headers[keys[i]];
    }
    form['content-type'] = 'application/x-www-form-urlencoded';
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: form,
        extraData: body,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const looksJson: boolean = text.length > 0 && text.charAt(0) === '{';
      const okCode: boolean = response.responseCode === 200 && looksJson;
      const detail: string = looksJson ? `http-${response.responseCode}`
        : `http-${response.responseCode}/non-json`;
      return new NativeFetchResult(okCode, detail, response.responseCode,
        Date.now() - started, text.length, looksJson, 0, text);
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'post failed: %{public}s', message);
      return new NativeFetchResult(false, `throw:${message}`.substring(0, 60), 0,
        Date.now() - started, 0, false, 0, '');
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * REST 写请求要用的头：优先用**同名模板**那份（里面带网页专有的 `x-ig-www-claim` /
   * `x-instagram-ajax` / `x-asbd-id`），没有才退回信息流模板那套会话头。
   *
   * 为什么必须这样：裸会话头打 `/api/v1/` 的 POST，IG 会用**整页 HTML** 回（真机实测），
   * 表现是"接口在、数据就是拿不到"。
   */
  private static async restHeaders(op: string, fallback: Record<string, string>):
    Promise<Record<string, string>> {
    const fromTemplate: Record<string, string> = await NativeFeed.headersFor(op);
    if (Object.keys(fromTemplate).length > 0) {
      return fromTemplate;
    }
    // 退一步：用 ayml 那条模板的头（同一批网页专有头，只是路径不同）。
    const generic: Record<string, string> = await NativeFeed.headersFor(AYML_OP);
    return Object.keys(generic).length > 0 ? generic : fallback;
  }

  /** 模板里的 URL 可能是相对路径（页面用 `open('/api/v1/...')`）：补成绝对地址。 */
  private static absolute(url: string): string {
    const one: string = url.trim();
    if (one.indexOf('http') === 0) {
      return one;
    }
    return one.charAt(0) === '/' ? `https://www.instagram.com${one}`
      : `https://www.instagram.com/${one}`;
  }

  /** 设备时区相对 UTC 的分钟偏移（东八区 = +480）。 */
  private static timezoneOffsetMinutes(): number {
    return -new Date().getTimezoneOffset();
  }

  /** 等 ms 毫秒后回 0（只给 Promise.race 当"跑道"用，见 applyFollowStates 的说明）。 */
  private static delayValue(ms: number): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void): void => {
      setTimeout((): void => {
        resolve(0);
      }, ms);
    });
  }

  /** 一次 GET（头由调用方给；结果用 NativeFetchResult 表达，不抛异常）。 */
  private static async get(url: string, headers: Record<string, string>): Promise<NativeFetchResult> {
    const started: number = Date.now();
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      // 判据和 feeds 一样严：必须是 JSON（IG 对不认识的请求会回 200 + 一整页 HTML）。
      const looksJson: boolean = text.length > 0 && text.charAt(0) === '{';
      const okCode: boolean = response.responseCode === 200 && looksJson;
      const detail: string = looksJson ? `http-${response.responseCode}`
        : `http-${response.responseCode}/non-json`;
      return new NativeFetchResult(okCode, detail, response.responseCode,
        Date.now() - started, text.length, looksJson, 0, text);
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'request failed: %{public}s', message);
      return new NativeFetchResult(false, `throw:${message}`.substring(0, 60), 0,
        Date.now() - started, 0, false, 0, '');
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** news/inbox → 页面用的条目（字段形状与网页脚本一致）。 */
  private static parseInbox(text: string): Array<NotifyPayloadItem> {
    const out: Array<NotifyPayloadItem> = [];
    let data: NewsInbox | null = null;
    try {
      data = JSON.parse(text) as NewsInbox;
    } catch (error) {
      return out;
    }
    if (data === null) {
      return out;
    }
    const news: Array<NewsStory> = data.new_stories ?? [];
    const old: Array<NewsStory> = data.old_stories ?? [];
    for (let i: number = 0; i < news.length; i++) {
      const one: NotifyPayloadItem | null = NativeNotifications.storyToItem(news[i]);
      if (one !== null) {
        out.push(one);
      }
    }
    for (let i: number = 0; i < old.length; i++) {
      const one: NotifyPayloadItem | null = NativeNotifications.storyToItem(old[i]);
      if (one !== null) {
        out.push(one);
      }
    }
    return out;
  }

  /** 一条故事 → 条目；没有文案也没有头像的（未知类型）直接丢掉。 */
  private static storyToItem(story: NewsStory): NotifyPayloadItem | null {
    const args: NewsStoryArgs = story.args ?? {};
    const text: string = (args.text ?? args.rich_text ?? '').trim();
    // 头像：字段名各版本不同（profile_image / profile_pic_url），再兜一层"在 args 里找图片 URL"。
    let avatar: string = (args.profile_image ?? args.profile_pic_url ?? '').trim();
    if (avatar.length === 0) {
      avatar = NativeNotifications.findImageUrl(args, 0, false);
    }
    if (text.length === 0 && avatar.length === 0) {
      return null;
    }
    // **账号名**：关注类通知的 args 里**没有** username 字段，名字只出现在两个地方 ——
    // `destination="user?id=12345678901&username=alice"` 与文案开头。
    // 不把它挖出来，`NotifyItem.accountName()` 就是空串 → 面板的「回关」点了直接静默返回
    // （用户报的"回关按钮点了没反应"就是这个）。
    let username: string = (args.username ?? '').trim();
    if (username.length === 0) {
      const match: RegExpMatchArray | null = (args.destination ?? '').match(/[?&]username=([^&]+)/);
      if (match !== null && match.length > 1) {
        username = decodeURIComponent(match[1]);
      }
    }
    const inline: NewsInlineFollow | null = args.inline_follow ?? null;
    const following: boolean = args.following === true
      || (inline !== null && inline.following === true);
    const avatars: Array<string> = [];
    if (avatar.length > 0) {
      avatars.push(avatar);
    }
    // 聚合通知的第二张头像（"A 和 B 赞了…"）：面板会把它和第一张按左上/右下叠起来。
    const second: string = (args.second_profile_image ?? '').trim();
    if (second.length > 0 && second !== avatar) {
      avatars.push(second);
    }
    // **名字要从文案开头削掉**（面板会把 usernames 里的名字自己画成一段加粗，再接 text：
    // 不削就会变成"alice alice 开始关注你了。"——重复一遍）。
    //
    // 名字的来源按可靠度排：`links` 里 IG 自己标出来的用户名（"A 和 B 赞了…"两个都在里面）
    // → 从 destination 挖出来的那一个（关注类通知只有它）。
    const names: Array<string> = [];
    const links: Array<NewsLink> = args.links ?? [];
    for (let i: number = 0; i < links.length; i++) {
      const one: NewsLink = links[i];
      if ((one.type ?? '') !== 'user') {
        continue;
      }
      const name: string = (one.username ?? '').trim();
      if (name.length > 0 && names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    if (names.length === 0 && username.length > 0) {
      names.push(username);
    }
    // 从头往后依次吃掉"名字 +（和/、/, + 下一个名字）"，剩下的就是动作文案。
    const usernames: Array<string> = [];
    let body: string = text;
    let moved: boolean = true;
    while (moved && body.length > 0) {
      moved = false;
      for (let i: number = 0; i < names.length; i++) {
        const name: string = names[i];
        if (body.indexOf(name) === 0) {
          usernames.push(name);
          body = body.substring(name.length).replace(/^\s*(和|、|,|，|and)\s*/, '').trim();
          moved = true;
          break;
        }
      }
    }
    // **缩略图只给"带媒体的通知"**（点赞快拍 / 新帖子那类）。
    // 关注类通知（"某人开始关注你了"）没有媒体，硬给它一张就会把头像当缩略图显示在右边
    // （需求：关注通知无需显示图片，只有点赞快拍通知才需要）。
    const hasMedia: boolean = (story.media !== undefined && story.media !== null)
      || (args.media !== undefined && args.media !== null);
    // **只有"关注类通知"才配一颗按钮**（需求：不是关注通知就不显示回关/发消息）。
    //
    // 判据两条（真机 dump 出来的字段）：`story_type=101`、`notif_name=user_followed`，
    // 而且这类条目的 args 里一定有 `inline_follow`（就是 IG 自己那颗"回关"）。
    // 点赞快拍那类是 `story_type=651`，Meta 账户那类系统通告两者都没有 —— 它们原来会被
    // 默认成 'follow' 画出一颗点不动的"回关"（既没用户名也没用户 id，点了必然失败）。
    const isFollow: boolean = story.story_type === 101
      || (story.notif_name ?? '') === 'user_followed'
      || (args.inline_follow !== null && args.inline_follow !== undefined);
    const item: NotifyPayloadItem = {
      group: 'news',
      avatars: avatars,
      usernames: usernames,
      text: body,
      ts: (args.timestamp ?? 0) * 1000,
      date: '',
      thumb: hasMedia ? NativeNotifications.thumbUrl(story) : '',
      // 关注类：未关注给"回关"、已关注给"following"（面板据此换成「发消息」）；
      // 其余通知留空 = 面板不画按钮。
      button: isFollow ? (following ? 'following' : 'follow') : '',
      following: following,
      // 用户 id 留给后面的 show_many（见 applyFollowStates）。
      userId: (args.profile_id ?? '').trim(),
      username: username,
      displayName: (args.profile_name ?? '').trim(),
      social: ''
    };
    return item;
  }

  /**
   * 缩略图。
   *
   * 先按已知形状取（`story.media.image_versions2.candidates` 里最大的一张），取不到再
   * **整棵子树递归找第一个图片 URL** —— 分享媒体的通知（"某人发了新帖"）各版本字段名不一样
   * （`args.media` / `args.image` / `args.preview`…），硬编码很容易整批丢图。
   */
  private static thumbUrl(story: NewsStory): string {
    const direct: string = NativeNotifications.bestCandidate(story);
    if (direct.length > 0) {
      return direct;
    }
    // skipProfile=true：跳过 profile 头像字段，否则会把头像当缩略图。
    return NativeNotifications.findImageUrl(story, 0, true);
  }

  /** 已知形状：story.media.image_versions2.candidates 里面积最大的一张。 */
  private static bestCandidate(story: NewsStory): string {
    const media: NewsStoryMedia = story.media ?? {};
    const versions: NewsImageVersions = media.image_versions2 ?? {};
    const candidates: Array<NewsMediaCandidate> = versions.candidates ?? [];
    let best: string = '';
    let bestArea: number = -1;
    for (let i: number = 0; i < candidates.length; i++) {
      const one: NewsMediaCandidate = candidates[i];
      const url: string = (one.url ?? '').trim();
      if (url.length === 0) {
        continue;
      }
      const area: number = (one.width ?? 0) * (one.height ?? 0);
      if (area > bestArea) {
        bestArea = area;
        best = url;
      }
    }
    return best;
  }

  /**
   * 在对象/数组里递归找第一个"像图片"的 URL（深度上限 5，只认 http + 常见图片特征）。
   *
   * @param skipProfile 跳过键名里带 profile 的（找缩略图时要跳过头像）。数组元素按 index 递归。
   */
  private static findImageUrl(node: Object | null, depth: number, skipProfile: boolean): string {
    if (node === null || depth > 5) {
      return '';
    }
    let map: Record<string, Object> | null = null;
    try {
      map = node as Record<string, Object>;
    } catch (error) {
      return '';
    }
    if (map === null) {
      return '';
    }
    const keys: Array<string> = Object.keys(map);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const value: Object = map[key];
      if (value === null || value === undefined) {
        continue;
      }
      if (typeof value === 'string') {
        const text: string = value as string;
        if (NativeNotifications.looksLikeImage(text)) {
          if (skipProfile && key.toLowerCase().indexOf('profile') >= 0) {
            continue;
          }
          return text;
        }
        continue;
      }
      const nested: string = NativeNotifications.findImageUrl(value, depth + 1, skipProfile);
      if (nested.length > 0) {
        return nested;
      }
    }
    return '';
  }

  /** 像不像图片地址（http + 常见后缀/CDN 特征）。 */
  private static looksLikeImage(text: string): boolean {
    if (text.length < 12 || text.indexOf('http') !== 0) {
      return false;
    }
    const lower: string = text.toLowerCase();
    return lower.indexOf('.jpg') >= 0 || lower.indexOf('.jpeg') >= 0
      || lower.indexOf('.webp') >= 0 || lower.indexOf('.png') >= 0
      || lower.indexOf('.heic') >= 0
      // IG 的图片 CDN 好几个域名：有的带 scontent/cdninstagram，有的直接是 fna.fbcdn.net，
      // 而且不一定带后缀 —— 漏一个就会"整批没图"（快拍点赞那类通知就是这种）。
      || lower.indexOf('scontent') >= 0 || lower.indexOf('cdninstagram') >= 0
      || lower.indexOf('fbcdn') >= 0
      || (lower.indexOf('instagram.') >= 0 && lower.indexOf('/v/t') >= 0);
  }

  /** discover/ayml → 推荐条目（group = suggested，和网页脚本一致）。 */
  private static async parseAyml(text: string, headers: Record<string, string>): Promise<Array<NotifyPayloadItem>> {
    const out: Array<NotifyPayloadItem> = [];
    let data: AymlPayload | null = null;
    try {
      data = JSON.parse(text) as AymlPayload;
    } catch (error) {
      return out;
    }
    if (data === null) {
      return out;
    }
    // 两种形状都吃：对象（`{suggestions:[…]}`，现代版本）与数组（老版本）。
    const raw: AymlSuggestions | Array<AymlEntry> | null = data.suggested_users ?? null;
    let entries: Array<AymlEntry> = [];
    if (raw !== null) {
      if (Array.isArray(raw)) {
        entries = raw as Array<AymlEntry>;
      } else {
        entries = (raw as AymlSuggestions).suggestions ?? [];
      }
    }
    // 统一成"用户 + 社交文案"两条平行数组：嵌套形状取 entry.user，扁平形状就把 entry 当用户。
    const users: Array<AymlUser> = [];
    const socials: Array<string> = [];
    for (let i: number = 0; i < entries.length; i++) {
      const entry: AymlEntry = entries[i];
      const nested: AymlUser | null = entry.user ?? null;
      const flat: AymlUser = entry as AymlUser;
      const name: string = ((nested ?? flat).username ?? '').trim();
      if (name.length === 0) {
        continue;
      }
      users.push(nested ?? flat);
      socials.push((entry.social_context ?? (nested ?? flat).social_context ?? '').trim());
    }
    const ids: Array<string> = [];
    for (let i: number = 0; i < users.length; i++) {
      const id: string = `${users[i].pk ?? ''}`.trim();
      if (id.length > 0 && id !== 'null' && ids.indexOf(id) < 0) {
        ids.push(id);
      }
    }
    // 推荐位也把关注状态带出来（和主列表同一份 show_many 逻辑）。失败就算了，不影响推荐列表。
    const states: Record<string, ShowManyStatus> = {};
    if (ids.length > 0) {
      try {
        const response: NativeFetchResult = await NativeNotifications.post(
          'https://www.instagram.com/api/v1/friendships/show_many/',
          `user_ids=${encodeURIComponent(ids.join(','))}`,
          await NativeNotifications.restHeaders(SHOW_MANY_OP, headers));
        if (response.ok) {
          const parsed: ShowManyResponse = JSON.parse(response.body) as ShowManyResponse;
          const got: Record<string, ShowManyStatus> = parsed.friendship_statuses ?? {};
          const keys: Array<string> = Object.keys(got);
          for (let i: number = 0; i < keys.length; i++) {
            states[keys[i]] = got[keys[i]];
          }
        }
      } catch (error) {
      }
    }
    for (let i: number = 0; i < users.length; i++) {
      const user: AymlUser = users[i];
      const name: string = (user.username ?? '').trim();
      if (name.length === 0) {
        continue;
      }
      const avatar: string = (user.profile_pic_url ?? '').trim();
      const id: string = `${user.pk ?? ''}`.trim();
      const friend: AymlFriendship | null = user.friendship_status ?? null;
      const fromApi: ShowManyStatus | undefined = states[id];
      const following: boolean = (fromApi !== undefined && fromApi.following === true)
        || (friend !== null && friend.following === true);
      const one: NotifyPayloadItem = {
        group: 'suggested',
        avatars: avatar.length > 0 ? [avatar] : [],
        usernames: [name],
        text: '',
        ts: 0,
        date: '',
        thumb: '',
        following: following,
        userId: id,
        username: name,
        displayName: (user.full_name ?? '').trim(),
        social: socials[i]
      };
      out.push(one);
    }
    return out;
  }
}
