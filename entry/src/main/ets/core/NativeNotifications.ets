/*
 * 通知页的**取数** —— 只走移动端私有 API（`core/mobileapi/MobileNews`，instagrapi 同源）。
 *
 * ## 端点
 *    · POST `i.instagram.com/api/v1/news/inbox/`            → `new_stories` / `old_stories` / `ayml`
 *    · POST `i.instagram.com/api/v1/friendships/show_many/` → 这批人的关注状态
 *    这一路**不需要任何网页模板或网页专有令牌**（`x-ig-www-claim` / `fb_dtsg` / `jazoest`），
 *    和快拍 / 私信 / 主页 / 点赞 / 翻译那些端口共用同一套移动端身份与限速闸门。
 *
 * ## 历史
 * 这里原来还有一条"网页 REST 兜底"（借 `NativeFeed.sessionOrBrowserHeaders` 的会话头、
 * ayml 模板与 EngageSkeleton 骨架拼请求）。页面注入退役后模板抓不到、`fb_dtsg` 也过期，
 * 那条兜底一并删除；移动端失败就如实回报，页面照旧提示"暂时读不到通知"。
 *
 * ## 输出
 * 直接产出和网页脚本**完全相同形状**的 `NotificationsPayload`（items: NotifyPayloadItem[]），
 * 这样页面上那条 `mapNotifications()` 一行都不用改。
 *
 * ArkTS 注意：所有"看起来像对象类型"的地方都要**具名 interface**，
 * 对象字面量必须赋给显式声明了类型的变量（不能字面量 + as 断言）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { NotificationsPayload, NotifyPayloadItem } from '../model/Notification';
import { MobileNews } from './mobileapi/MobileNews';
import { MobileResult } from './mobileapi/MobileRequest';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeNotify';
/**
 * show_many 的"跑道"：超过这个时间就先出列表（见 fetchMobile 里的 Promise.race）。
 *
 * 这条接口偶尔很慢，拖住它会让用户一直看到"正在刷新"。
 */
const SHOW_MANY_CAP_MS: number = 4000;

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
   * 文案里的哪一段是账号名（"bob 和 carol 赞了你的快拍。" 里的两个名字）。
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
  /** 条目类型（1 = 关注，2/3 = 评论/点赞…），移动端那条给的是数字。 */
  type?: number | null;
  /** IG 自己的动作名（`user_followed` 就是"某人开始关注你"）。 */
  notif_name?: string | null;
  /** 网页那条用 `args`，移动端个别版本用**单数** `arg`（两种都认）。 */
  args?: NewsStoryArgs | null;
  arg?: NewsStoryArgs | null;
  /** 再兜一层：少见的扁平形状把文案/头像直接挂在条目上。 */
  text?: string | null;
  profile_image?: string | null;
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

/**
 * 移动端那条（`discover/ayml/` 与 `news/inbox/` 里的 `ayml` 块）的形状。
 *
 * 真机历史版本里它见过三种写法：`{ayml:{items:[…]}}`、`{ayml:{users:[…]}}`、
 * `{ayml:{suggestions:[…]}}` —— 所以下面**三个数组键都认**；一条都读不出来时
 * 还会退回根节点上那几个同名键（见 parseAyml）。
 */
interface AymlBlock {
  items?: Array<AymlEntry> | null;
  users?: Array<AymlEntry> | null;
  suggestions?: Array<AymlEntry> | null;
}

interface AymlPayload {
  suggested_users?: AymlSuggestions | Array<AymlEntry> | null;
  ayml?: AymlBlock | Array<AymlEntry> | null;
  /** 根节点上直接给数组的版本（见 AymlBlock 的说明）。 */
  items?: Array<AymlEntry> | null;
  users?: Array<AymlEntry> | null;
  suggestions?: Array<AymlEntry> | null;
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
   * 最近一次成功走的是哪条路：`mobile`（instagrapi 协议）或 `web`（网页 REST 兜底）。
   *
   * 给页面用：如果**移动端那条成了**，"为你推荐"就不需要再去抓网页 ayml 模板了
   * （那条模板只服务网页兜底），省掉一次"把隐藏网页导航到活动页"的冷路径。
   */
  private static last: string = 'none';
  /** 形状诊断只打**一次**（见 logInboxShape）：每次刷新都刷一遍会把 hilog 环形缓冲冲掉。 */
  private static shapeLogged: boolean = false;
  /** 解析结果诊断只打一次（见 logItems）。 */
  private static itemsLogged: boolean = false;

  static lastVia(): string {
    return NativeNotifications.last;
  }

  /**
   * 拉一次通知。
   *
   * **只走移动端私有接口**（`POST i.instagram.com/api/v1/news/inbox/` + `friendships/show_many/`
   * + 可选 `discover/ayml/`）—— 与 instagrapi 同源，**不需要任何网页模板/令牌**，
   * 和快拍 / 私信 / 主页 / 点赞那些端口同一套身份与限速闸门（见 core/mobileapi/MobileNews）。
   *
   * 历史：这里原来还有一条"网页 REST"兜底（借 `NativeFeed.sessionOrBrowserHeaders` 的会话头、
   * `AYML_OP` 模板与 EngageSkeleton 骨架拼 ayml）。页面注入退役后模板抓不到、`fb_dtsg` 也过期，
   * 那条路一并删除。
   *
   * @param asOfMs 保留参数（分组基准由页面那边算，这里只负责产出条目）。
   */
  static async fetch(asOfMs: number = Date.now()): Promise<NotificationsPayload> {
    const mobile: NotificationsPayload | null = await NativeNotifications.fetchMobile();
    if (mobile !== null) {
      NativeNotifications.last = 'mobile';
      return mobile;
    }
    // 移动端没拿到：如实回报（页面据此提示"暂时读不到通知"），不再退网页那条。
    NativeNotifications.last = 'mobile-failed';
    const failed: NotificationsPayload = {
      state: 'error',
      message: 'mobile-failed',
      diag: 'mobile-failed',
      items: []
    };
    return failed;
  }

  /**
   * **移动端（instagrapi 协议）那一路**：inbox → show_many → ayml（见 core/mobileapi/MobileNews）。
   *
   * 返回 null = "这一路没拿到东西，请走网页那条"，判据有三条（任一不满足就退）：
   *   ① 请求本身失败（没会话 / 被限流 / 端点变更）；
   *   ② 体里没有 `new_stories` / `old_stories`（形状不认识 —— 硬解析只会得到空列表，
   *      而"空列表"和"今天真的没有通知"在界面上看起来一模一样，所以必须区分）；
   *   ③ 解析出来条数为 0。
   *
   * 关注状态与推荐位都是**尽力而为**：它们失败不影响主列表（同网页那条的取舍）。
   */
  private static async fetchMobile(): Promise<NotificationsPayload | null> {
    const started: number = Date.now();
    /*
     * 整段 try/catch **必须**：这条路是"新增的优先项"，它出任何异常都不许把整个通知页
     * 带崩（真机上就踩过：`undefined is not callable` 直接冒到页面，结果整页空着，
     * 连网页兜底都没跑）。`step` 记到哪一步，日志里一眼能定位。
     */
    let step: string = 'inbox';
    try {
    const inbox: MobileResult = await MobileNews.inbox();
    if (!inbox.ok) {
      hilog.info(DOMAIN, TAG, 'mobile notify skipped: %{public}s', inbox.summary());
      return null;
    }
    if (inbox.body.indexOf('"new_stories"') < 0 && inbox.body.indexOf('"old_stories"') < 0) {
      hilog.info(DOMAIN, TAG, 'mobile notify shape unknown len=%{public}d head=%{public}s',
        inbox.body.length, NativeNotifications.head(inbox.body, 160));
      return null;
    }
    step = 'diagnose';
    if (!NativeNotifications.shapeLogged) {
      NativeNotifications.shapeLogged = true;
      NativeNotifications.logInboxShape(inbox.body);
    }
    step = 'parse-inbox';
    const items: Array<NotifyPayloadItem> = NativeNotifications.parseInbox(inbox.body);
    if (!NativeNotifications.itemsLogged) {
      NativeNotifications.itemsLogged = true;
      NativeNotifications.logItems(items);
    }
    if (items.length === 0) {
      hilog.info(DOMAIN, TAG, 'mobile notify empty items len=%{public}d', inbox.body.length);
      return null;
    }
    // 关注状态：同一个 4 秒跑道（这条接口偶尔很慢，绝不许拖住列表）。
    /*
     * 「为你推荐」：**只认 inbox 自己的 `ayml` 块**（移动端经常把推荐位一起塞在通知响应里）。
     * 单独那条 `discover/ayml/` 真机上是 400，原先的网页兜底（模板 / 骨架）已随模板机制删除，
     * 所以取不到推荐位就只是这一段不显示，主列表照旧。
     */
    step = 'parse-ayml-inbox';
    let suggested: Array<NotifyPayloadItem> = await NativeNotifications.parseAyml(inbox.body, {});
    let aymlVia: string = suggested.length > 0 ? 'inbox' : '-';
    /*
     * 关注状态**一次问完**（主列表 + 推荐位合在一发里问）：`friendships/show_many/` 支持批量，
     * 分两次问只是白多一发。它同样受 4 秒跑道约束（见 SHOW_MANY_CAP_MS）。
     */
    step = 'merge';
    const all: Array<NotifyPayloadItem> = items.concat(suggested);
    let resolved: number = 0;
    try {
      step = 'follow';
      resolved = await Promise.race([
        NativeNotifications.applyMobileFollowStates(all),
        NativeNotifications.delayValue(SHOW_MANY_CAP_MS)
      ]);
    } catch (error) {
      resolved = 0;
    }
    step = 'push';
    for (let index: number = 0; index < suggested.length; index++) {
      items.push(suggested[index]);
    }
    hilog.info(DOMAIN, TAG, 'mobile notify items=%{public}d suggest=%{public}d(%{public}s) '
      + 'followResolved=%{public}d len=%{public}d ms=%{public}d',
      items.length, suggested.length, aymlVia, resolved, inbox.body.length, Date.now() - started);
    const ok: NotificationsPayload = {
      state: 'ok',
      rows: resolved,
      items: items
    };
    return ok;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'mobile notify threw step=%{public}s msg=%{public}s',
        step, (error as Error).message ?? '-');
      return null;
    }
  }

  /**
   * 移动端的 `friendships/show_many/`（见 core/mobileapi/MobileNews.showMany）。
   *
   * 和网页那条（applyFollowStates）是同一个判据、同一份写回方式，只是身份与主机不同。
   * 返回**成功写回的条数**。
   */
  private static async applyMobileFollowStates(items: Array<NotifyPayloadItem>): Promise<number> {
    const ids: Array<string> = [];
    for (let index: number = 0; index < items.length; index++) {
      const id: string = (items[index].userId ?? '').trim();
      if (id.length > 0 && ids.indexOf(id) < 0) {
        ids.push(id);
      }
    }
    if (ids.length === 0) {
      return 0;
    }
    const result: MobileResult = await MobileNews.showMany(ids);
    if (!result.ok || result.body.indexOf('"friendship_statuses"') < 0) {
      hilog.info(DOMAIN, TAG, 'mobile show_many no states %{public}s', result.summary());
      return 0;
    }
    let resolved: number = 0;
    try {
      const parsed: ShowManyResponse = JSON.parse(result.body) as ShowManyResponse;
      const got: Record<string, ShowManyStatus> = parsed.friendship_statuses ?? {};
      for (let index: number = 0; index < items.length; index++) {
        const one: NotifyPayloadItem = items[index];
        const id: string = (one.userId ?? '').trim();
        if (id.length === 0) {
          continue;
        }
        const state: ShowManyStatus | undefined = got[id];
        if (state === undefined) {
          continue;
        }
        one.following = state.following === true;
        resolved++;
      }
    } catch (error) {
      return 0;
    }
    hilog.info(DOMAIN, TAG, 'mobile show_many ids=%{public}d resolved=%{public}d',
      ids.length, resolved);
    return resolved;
  }

  /** 响应体压成一行（日志用：形状不对时第一眼看的就是它）。 */
  private static head(body: string, limit: number): string {
    const one: string = body.replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim();
    return one.length > limit ? one.substring(0, limit) : one;
  }

  /**
   * 移动端 `news/inbox/` 的**形状诊断**（一行一个结论，便于 `hdc shell hilog` 直接看）。
   *
   * 为什么需要：这条端点的响应和网页那条**字段名不完全一样**（移动端历史上用过
   * `arg` 单数、`notif_name`、`type` 数字…）。形状对不上时表现得像"今天没有通知"，
   * 光看界面分不出来 —— 把根键、第一条的键和一小段 JSON 打出来，一看就知道该认哪个字段。
   */
  private static logInboxShape(body: string): void {
    let root: Record<string, Object> | null = null;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'mobile shape: body is not json');
      return;
    }
    if (root === null) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'mobile shape: root keys=%{public}s',
      Object.keys(root).join(','));
    const storyKeys: Array<string> = ['new_stories', 'old_stories'];
    for (let index: number = 0; index < storyKeys.length; index++) {
      const value: Object | undefined = root[storyKeys[index]];
      const list: Array<Object> = Array.isArray(value) ? value as Array<Object> : [];
      hilog.info(DOMAIN, TAG, 'mobile shape: %{public}s type=%{public}s n=%{public}d',
        storyKeys[index], Array.isArray(value) ? 'array' : typeof value, list.length);
      if (list.length === 0) {
        continue;
      }
      const first: Record<string, Object> = list[0] as Record<string, Object>;
      hilog.info(DOMAIN, TAG, 'mobile shape: %{public}s[0] keys=%{public}s',
        storyKeys[index], Object.keys(first).join(','));
      hilog.info(DOMAIN, TAG, 'mobile shape: %{public}s[0] json=%{public}s',
        storyKeys[index], JSON.stringify(first).substring(0, 800));
      /*
       * 再单独打一条"带 links 的"样本：**点赞/关注类通知**的用户名与用户 id 全在
       * `args.links` 里（`{start,end,type,username,url,…}`），形状和网页那条不完全一样，
       * 第一版就是照着猜的 → 界面上把整段结构当名字画出来了。
       */
      for (let at: number = 0; at < list.length && at < 6; at++) {
        const one: Record<string, Object> = list[at] as Record<string, Object>;
        const argsBox: Record<string, Object> | null = NativeNotifications.boxOf(one['args']);
        if (argsBox === null) {
          continue;
        }
        const links: Object | undefined = argsBox['links'];
        if (!Array.isArray(links) || (links as Array<Object>).length === 0) {
          continue;
        }
        hilog.info(DOMAIN, TAG, 'mobile shape: %{public}s[%{public}d] links=%{public}s',
          storyKeys[index], at, JSON.stringify(links).substring(0, 600));
        hilog.info(DOMAIN, TAG, 'mobile shape: %{public}s[%{public}d] args=%{public}s',
          storyKeys[index], at, JSON.stringify(argsBox).substring(0, 600));
        break;
      }
      return;
    }
  }

  /** 把任意值当对象看（不是对象给 null）。 */
  private static boxOf(value: Object | null | undefined): Record<string, Object> | null {
    if (value === null || value === undefined || typeof value !== 'object') {
      return null;
    }
    return value as Record<string, Object>;
  }

  /** 打出解析后的前几条（名字 / 文案 / 用户 id / 时间戳），对形状用。 */
  private static logItems(items: Array<NotifyPayloadItem>): void {
    for (let index: number = 0; index < items.length && index < 3; index++) {
      const one: NotifyPayloadItem = items[index];
      const names: Array<string> = one.usernames ?? [];
      const text: string = one.text ?? '';
      hilog.info(DOMAIN, TAG,
        'mobile item[%{public}d] names=[%{public}s] text=%{public}s user=%{public}s id=%{public}s ts=%{public}d',
        index, names.join('|'), text.substring(0, 60), one.username ?? '', one.userId ?? '',
        one.ts ?? 0);
    }
  }

  /** 等 ms 毫秒后回 0（只给 Promise.race 当"跑道"用，见 fetchMobile 的说明）。 */
  private static delayValue(ms: number): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void): void => {
      setTimeout((): void => {
        resolve(0);
      }, ms);
    });
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
    // 数组判断要**显式**做：移动端那条给的是数组，但别的形状（对象/字符串）也见过 ——
    // 直接 `data.new_stories ?? []` 拿到非数组时，`.length` 或下标就会炸。
    const news: Array<NewsStory> = Array.isArray(data.new_stories)
      ? data.new_stories as Array<NewsStory> : [];
    const old: Array<NewsStory> = Array.isArray(data.old_stories)
      ? data.old_stories as Array<NewsStory> : [];
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

  /**
   * 从载荷里**安全**取一个字符串（不是字符串就给空串）。
   *
   * 为什么必须这么小心：移动端 `news/inbox/` 的 `args` 比网页那条**松得多** —— 同一个字段
   * 在不同 `story_type` 下可能是字符串、对象（`{"text":…}`）或者数字。直接
   * `(args.text ?? '').trim()` 在那种条目上会抛 `undefined is not callable`
   * （真机踩过：整条链在 `parse-inbox` 就断了，通知页只剩"没能读到通知"）。
   */
  private static str(value: Object | null | undefined): string {
    return typeof value === 'string' ? (value as string) : '';
  }

  /**
   * 同上，但**数字也收**（转成十进制字符串）。
   *
   * 移动端那条 ids 全是 **number**（`profile_id` / `pk` / `second_profile_id`），
   * 网页那条是字符串；只认字符串的话，移动端每条通知的 `userId` 都会是空 →
   * `friendships/show_many` 直接跳过 → 「回关」按钮拿到空 id 点了没反应。
   */
  private static idOf(value: Object | null | undefined): string {
    if (typeof value === 'string') {
      return (value as string).trim();
    }
    if (typeof value === 'number') {
      const n: number = value as number;
      // 19 位 id 超 f64 精度，但这里只当键用（show_many 的 id 串）；整数就直接转。
      return Number.isSafeInteger(n) ? `${n}` : `${Math.round(n)}`;
    }
    return '';
  }

  /**
   * 移动端 `args.text` 里的**用户名占位符**展开。
   *
   * 真机样本（`story_type=101` 的关注通知）：
   *   `"{bob|000000|1|user?id=12345678902|none} 开始关注你了。"`
   * 竖线分隔的字段是"用户名 | 起 | 止 | 链接类型 | 目标 | 其他"。网页那条**没有**这种写法
   * （它直接把用户名写进文案），所以第一版把整个 `{…}` 当名字画到了界面上 ——
   * 用户在通知页看到的就是一串 `{…|…|user?id=…}` 的乱码。
   *
   * 展开规则：把 `{…}` 换成里面那个用户名（像账号名的才换），并把名字登记进 `names`，
   * 后面"从文案开头削掉名字"的逻辑就能接着用（否则会画成"名字 名字 开始关注你了"）。
   *
   * 为什么要手动拼而不写 `replace(re, fn)`：ArkTS 里给 `replace` 传函数回调的类型签名很挑，
   * 手写这十几行更稳（而且能顺手把 `id=…` 挖出来，见 `idFromText`）。
   */
  private static expandPlaceholders(raw: string, names: Array<string>): string {
    const re: RegExp = /\{([^{}]*)\}/g;
    let out: string = '';
    let last: number = 0;
    let match: RegExpExecArray | null = re.exec(raw);
    while (match !== null) {
      const whole: string = match[0];
      const parts: Array<string> = match[1].split('|');
      const name: string = parts.length > 0 ? parts[0].trim() : '';
      let usable: boolean = name.length > 0 && name.length <= 40;
      for (let index: number = 0; usable && index < name.length; index++) {
        const ch: string = name.charAt(index);
        const ok: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
          || (ch >= '0' && ch <= '9') || ch === '_' || ch === '.';
        if (!ok) {
          usable = false;
        }
      }
      if (usable) {
        if (names.indexOf(name) < 0) {
          names.push(name);
        }
        out += raw.substring(last, match.index) + name;
        last = match.index + whole.length;
      }
      match = re.exec(raw);
    }
    return last === 0 ? raw : out + raw.substring(last);
  }

  /** 从文案里挖一个 `id=<数字>`（`args.profile_id` 缺失时的兜底，见 expandPlaceholders）。 */
  private static idFromText(text: string): string {
    const match: RegExpMatchArray | null = text.match(/[?&]id=(\d+)/);
    return match !== null && match.length > 1 ? match[1] : '';
  }

  /** 一条故事 → 条目；没有文案也没有头像的（未知类型）直接丢掉。 */
  private static storyToItem(story: NewsStory): NotifyPayloadItem | null {
    // `args`（网页）/ `arg`（移动端个别版本）两种都认；都没有就用空对象。
    const args: NewsStoryArgs = story.args ?? story.arg ?? {};
    let text: string = NativeNotifications.str(args.text).trim();
    if (text.length === 0) {
      text = NativeNotifications.str(args.rich_text).trim();
    }
    if (text.length === 0) {
      // 扁平形状：文案直接在条目上（见 NewsStory.text）。
      text = NativeNotifications.str(story.text).trim();
    }
    // 头像：字段名各版本不同（profile_image / profile_pic_url），再兜一层"在 args 里找图片 URL"。
    let avatar: string = NativeNotifications.str(args.profile_image).trim();
    if (avatar.length === 0) {
      avatar = NativeNotifications.str(args.profile_pic_url).trim();
    }
    if (avatar.length === 0) {
      avatar = NativeNotifications.str(story.profile_image).trim();
    }
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
    let username: string = NativeNotifications.str(args.username).trim();
    if (username.length === 0) {
      const match: RegExpMatchArray | null =
        NativeNotifications.str(args.destination).match(/[?&]username=([^&]+)/);
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
    const second: string = NativeNotifications.str(args.second_profile_image).trim();
    if (second.length > 0 && second !== avatar) {
      avatars.push(second);
    }
    // **名字要从文案开头削掉**（面板会把 usernames 里的名字自己画成一段加粗，再接 text：
    // 不削就会变成"alice alice 开始关注你了。"——重复一遍）。
    //
    // 名字的来源按可靠度排：`links` 里 IG 自己标出来的用户名（"A 和 B 赞了…"两个都在里面）
    // → 从 destination 挖出来的那一个（关注类通知只有它）。
    const names: Array<string> = [];
    /*
     * **先把移动端那种占位符展开**（`{用户名|…|user?id=…}`，见 expandPlaceholders）：
     * 展开出来的名字直接进 `names`，下面那段"削掉开头名字"的逻辑就对移动端同样有效。
     */
    const rawText: string = text;
    let body: string = NativeNotifications.expandPlaceholders(rawText, names);
    const links: Array<NewsLink> = Array.isArray(args.links) ? args.links as Array<NewsLink> : [];
    for (let i: number = 0; i < links.length; i++) {
      const one: NewsLink = links[i];
      if (NativeNotifications.str(one.type) !== 'user') {
        continue;
      }
      const name: string = NativeNotifications.str(one.username).trim();
      if (name.length > 0 && names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    if (names.length === 0 && username.length > 0) {
      names.push(username);
    }
    // 从头往后依次吃掉"名字 +（和/、/, + 下一个名字）"，剩下的就是动作文案。
    const usernames: Array<string> = [];
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
      || NativeNotifications.str(story.notif_name) === 'user_followed'
      || (args.inline_follow !== null && args.inline_follow !== undefined);
    /*
     * 账号名：`args.username` 没有、`destination` 里也没有时（移动端就是这样，名字只在
     * 占位符里），用展开占位符时登记下来的第一个名字 —— 否则「回关」那颗按钮
     * 拿不到用户名（`NotifyItem.accountName()` 空）点了必然静默失败。
     */
    const account: string = username.length > 0 ? username
      : (names.length > 0 ? names[0] : '');
    // 用户 id：`args.profile_id` 缺失时，从占位符的 `user?id=…` 里挖（见 idFromText）。
    let userId: string = NativeNotifications.idOf(args.profile_id);
    if (userId.length === 0) {
      userId = NativeNotifications.idFromText(rawText);
    }
    const item: NotifyPayloadItem = {
      group: 'news',
      avatars: avatars,
      usernames: usernames,
      text: body,
      ts: (typeof args.timestamp === 'number' ? args.timestamp as number : 0) * 1000,
      date: '',
      thumb: hasMedia ? NativeNotifications.thumbUrl(story) : '',
      // 关注类：未关注给"回关"、已关注给"following"（面板据此换成「发消息」）；
      // 其余通知留空 = 面板不画按钮。
      button: isFollow ? (following ? 'following' : 'follow') : '',
      following: following,
      // 用户 id 留给后面的 show_many（见 applyFollowStates）。移动端是 number，见 idOf。
      userId: userId,
      username: account,
      displayName: NativeNotifications.str(args.profile_name).trim(),
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

  /**
   * ayml 那种"可能是对象、也可能是数组、对象里还分 items/users/suggestions"的取值。
   *
   * 只用一个入口，是因为三种形状在真机上**都见过**（见 AymlBlock 的说明），
   * 各自写一遍判断只会漏掉其中一种 —— 而漏掉的表现是"为你推荐整段空掉"，
   * 和"今天确实没有推荐"在界面上分不出来。
   */
  private static aymlEntries(
    raw: AymlSuggestions | AymlBlock | Array<AymlEntry> | null | undefined): Array<AymlEntry> {
    if (raw === undefined || raw === null) {
      return [];
    }
    if (Array.isArray(raw)) {
      return raw as Array<AymlEntry>;
    }
    const box: Record<string, Object> = raw as Record<string, Object>;
    const keys: Array<string> = ['suggestions', 'items', 'users'];
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object | undefined = box[keys[index]];
      if (Array.isArray(value)) {
        return value as Array<AymlEntry>;
      }
    }
    return [];
  }

  /** discover/ayml（或 inbox 内嵌的 ayml 块）→ 推荐条目（group = suggested，和网页脚本一致）。 */
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
    // 多种形状都吃：`{suggested_users:{suggestions}}`（网页）、`{suggested_users:[…]}`（老版）、
    // `{ayml:{items|users|suggestions}}`、根节点上直接给数组（见 AymlBlock 的说明）。
    let entries: Array<AymlEntry> = NativeNotifications.aymlEntries(data.suggested_users);
    if (entries.length === 0) {
      entries = NativeNotifications.aymlEntries(data.ayml);
    }
    if (entries.length === 0) {
      entries = NativeNotifications.aymlEntries(data.items);
    }
    if (entries.length === 0) {
      entries = NativeNotifications.aymlEntries(data.users);
    }
    if (entries.length === 0) {
      entries = NativeNotifications.aymlEntries(data.suggestions);
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
    // 关注状态：推荐项的 `friendship_status` 直接读；批量那一发由调用方用
    // `MobileNews.showMany` 统一补一次（见 fetchMobile / applyMobileFollowStates）。
    const states: Record<string, ShowManyStatus> = {};
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
