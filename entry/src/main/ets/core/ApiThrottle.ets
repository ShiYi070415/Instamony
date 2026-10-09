/*
 * **接口被限流时的退避**（会话级，只活在内存里）。
 *
 * ## 为什么需要它
 * IG 对私有接口有节流，真机实测撞上过（clips 那条查询，响应体里是
 * `{"data":[],"errors":[{"message":"Rate limit exceeded","severity":"CRITICAL","code":1675004}]}`）：
 *   - 页面侧表现是"视频标签一片空白"（ReelsViewModel 报 `no-conn`），
 *     搜索页的**推荐瀑布流**同样空（它用的也是 clips 那条查询）；
 *   - 而我们这边原来会**继续猛打**：reels 一条要重试 5 次（每次隔 3 秒），
 *     再加启动预热、搜索页预热、`fetchPage` 内部"原样重发"…… 越打越久。
 *
 * 所以这里做两件事：
 *   1. **认出来**：响应体里有 `Rate limit exceeded` / `code 1675004` 就是被限流
 *      （见 looksLimited）；
 *   2. **记一段冷却期**：这段时间内同一个"家族"的请求直接不发（`blocked`），
 *      界面照实说"被限流了、稍后再试"，并尽量拿**上次缓存的内容**顶上
 *      （`ReelsCache` / `SearchCache`）。
 *
 * ## 为什么按"家族"而不是按操作名
 * 被限流的是**账号在某类重查询上**的额度，而不是某一个 doc_id：clips 那条查询被限时，
 * 首页视频、搜索推荐（同一个 op）一起挂；而信息流、个人主页、评论这些照常。
 * 所以这几条共用一把锁（`CLIPS`）。
 */

/** 撞上限流之后，多久之内不再发这个家族的请求（毫秒）。 */
const BACKOFF_MS: number = 12 * 60 * 1000;

export class ApiThrottle {
  /** 视频类重查询（首页 reels + 搜索推荐用的都是 `PolarisClipsTabRootPaginationQuery`）。 */
  static readonly CLIPS: string = 'clips';
  /** 单条媒体的信息查询（`/api/v1/media/{id}/info/`，补视频地址用，见 core/NativeMediaInfo）。 */
  static readonly MEDIA_INFO: string = 'mediaInfo';
  /** 单条媒体的评论查询（`/api/v1/media/{id}/comments/`，见 core/NativeComments）。 */
  static readonly COMMENTS: string = 'comments';
  /** 收藏 / 取消收藏（`/api/v1/media/{id}/save|unsave/`，见 core/NativeSave）。 */
  static readonly SAVE: string = 'save';
  /** 私信（`/api/v1/direct_v2/…` 那条路的读与发，见 core/NativeDirect）。 */
  static readonly DIRECT: string = 'direct';
  /**
   * 快拍（`/api/v1/feed/reels_media/`、`/api/v1/feed/user/{id}/story/`，见 core/NativeStories）。
   *
   * 为什么单列一族：这两条是**按用户**拉的，托盘预缓存一上来就是 5 位用户（每位最多 4 个候选），
   * 用户再一位位点开、接续下一位 —— 请求量天然比别的接口大一个量级，也最容易撞上 IG 的节流。
   * 撞上之后的界面表现正是用户报的那一幕："点开快拍 → 这条快拍没取到 → 播放页自己收起"。
   */
  static readonly STORIES: string = 'stories';

  /** 家族 → 解禁时刻（毫秒时间戳）。 */
  private static until: Map<string, number> = new Map<string, number>();

  /**
   * 这段响应/诊断里是不是"被限流"了。
   *
   * 两个判据都留着：IG 的文案是英文的 `Rate limit exceeded`（大小写不保证），
   * 而 `1675004` 是这个错误的稳定 code —— 文案被本地化/改写时还能认出来。
   */
  static looksLimited(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    const lower: string = text.toLowerCase();
    return lower.indexOf('rate limit') >= 0 || text.indexOf('1675004') >= 0;
  }

  /** 记一次限流：这个家族在 BACKOFF_MS 之内不再发请求。 */
  static note(family: string, ms: number = BACKOFF_MS): void {
    if (family.length === 0) {
      return;
    }
    ApiThrottle.until.set(family, Date.now() + ms);
  }

  /** 现在这个家族还在冷却里吗。 */
  static blocked(family: string): boolean {
    const at: number | undefined = ApiThrottle.until.get(family);
    if (at === undefined) {
      return false;
    }
    if (Date.now() >= at) {
      ApiThrottle.until.delete(family);
      return false;
    }
    return true;
  }

  /** 还剩多少毫秒解禁（不在冷却里给 0）。 */
  static remainingMs(family: string): number {
    const at: number | undefined = ApiThrottle.until.get(family);
    if (at === undefined) {
      return 0;
    }
    const left: number = at - Date.now();
    return left > 0 ? left : 0;
  }

  /** 还剩多少分钟（界面上那句提示用；不足一分钟按 1 算）。 */
  static remainingMinutes(family: string): number {
    const left: number = ApiThrottle.remainingMs(family);
    if (left <= 0) {
      return 0;
    }
    const minutes: number = Math.ceil(left / 60000);
    return minutes > 0 ? minutes : 1;
  }

  /** 手动解禁（下拉刷新这种用户主动的动作可以试一次）。 */
  static clear(family: string = ''): void {
    if (family.length === 0) {
      ApiThrottle.until.clear();
      return;
    }
    ApiThrottle.until.delete(family);
  }
}
