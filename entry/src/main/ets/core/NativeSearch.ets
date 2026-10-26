/*
 * 搜索页的**取数**（账号搜索 + 推荐网格）—— **只走移动端私有接口**，不依赖任何网页模板。
 *
 * ## 两条路
 *   1) 账号搜索：`fbsearch/account_serp/`（见 core/mobileapi/MobileDiscover.accounts，
 *      对应 instagrapi 的 `fbsearch_accounts_v2`）；失败再退 `web/search/topsearch/` 那几条 REST；
 *   2) 推荐网格：`discover/topical_explore/`（`MobileDiscover.explore`）；失败再退
 *      "信息流里的推荐卡片"（`explore_story`，同样走移动端时间线）。
 *
 * ## 为什么不写死响应路径
 * 和页面脚本同一个判据：**按形状扫**。
 *   用户 = 有 username，并且带 profile_pic_url 或 full_name 的对象；
 *   帖子 = 有 code，并且带 image_versions2 / video_versions / carousel_media 的对象。
 * 这样 IG 换一层包装（`items[]` 变成别的键）也不会一片空白。
 *
 * ## 历史
 * 这里原来还有第三条路：把页面里抓下来的 GraphQL 模板（bridge/ApiRegistry）回放一遍。
 * 页面注入退役之后模板既抓不到也没有新鲜令牌，这条已经删除 —— 与数据来源保持一致
 * （`FINGERPRINT_ANALYSIS.md` 阶段一：少一条自动化痕迹更重的路）。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { JsonRead } from './JsonRead';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { SearchCache } from './SearchCache';
import { ApiThrottle } from './ApiThrottle';
import { SessionGate } from './SessionGate';
import { MobileDiscover, MobileMediaPage, MobileUserPage } from './mobileapi/MobileDiscover';
import { MobileFeedPage, MobileFeedTimeline } from './mobileapi/MobileFeedTimeline';
import { SearchPost, SearchUser } from '../model/Search';
// 轮播帖的逐页媒体（与时间线那份 DTO 同形，见 readPost / carouselPage）。
import { FeedMediaItemDto } from '../model/FeedDto';
// 分享数取证（落盘 `files/Instarmony_share_probe.txt`，见那个文件的头注释）。
import { ShareProbe } from './ShareProbe';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeSearch';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 15000;

/** 扫响应时的上限：一次取数够用就行，别把整包几万节点都扫一遍。 */
const MAX_USERS: number = 40;
const MAX_POSTS: number = 60;

/**
 * 封面请求的目标宽度（px）。
 *
 * 网格格子实测约 141vp（≈470px），原来按全 app 的展示档 1080 取 —— 三列铺下来是白给带宽，
 * 解码和上屏都慢。降到 **1080 的三分之一 = 360**，格子尺寸下肉眼看不出差别。
 */
const COVER_WIDTH: number = 360;
/** 递归深度上限：IG 的响应一般四五层，超过就当包装层不看了。 */
const MAX_DEPTH: number = 8;

/**
 * **账号搜索的 REST 兜底**（不依赖任何"抓来的模板"，也不需要 App 私有签名）。
 *
 * 为什么留着：移动端 `fbsearch/account_serp/` 偶尔会被限流或回 `challenge_required`，
 * 这时候网页那套 `/web/search/topsearch/` 还能出账号 —— 它和关注 / 收藏 / 评论点赞
 * 走的是**同一套会话材料**（core/RestSession），成本极低，失败也只是多发一发。
 */
const REST_SEARCH_URLS: Array<string> = [
  'https://www.instagram.com/web/search/topsearch/?context=blended&query=',
  'https://www.instagram.com/api/v1/fbsearch/topsearch/?context=blended&query=',
  'https://i.instagram.com/api/v1/fbsearch/topsearch/?context=blended&query='
];
/**
 * 安卓 App 的 User-Agent 与 app id（最后那条 `i.instagram.com` 要这套身份才认；
 * 和 core/NativeSave、core/NativeStories 里那两处保持一致，改的时候一起改）。
 */
const ANDROID_UA: string = 'Instagram 448.0.0.52.84 Android (34/14; 480dpi; 1080x2340; '
  + 'samsung; SM-G988N; ko_KR; 483385731; 480)';
const ANDROID_APP_ID: string = '567067343352427';

/**
 * 一页推荐帖子。
 *
 * `cursor` / `hasMore` 来自游标与 `more_available`：瀑布流上滑到底部要接着加载，
 * 靠的就是这两个字段（见 SearchViewModel.loadMore）。
 */
export class SearchPostPage {
  readonly posts: Array<SearchPost>;
  readonly cursor: string;
  readonly hasMore: boolean;
  /** 这一页是谁给的（`mobile:topical_explore` / `feed:explore_story`）。 */
  readonly source: string;

  constructor(posts: Array<SearchPost>, cursor: string, hasMore: boolean, source: string) {
    this.posts = posts;
    this.cursor = cursor;
    this.hasMore = hasMore;
    this.source = source;
  }
}

export class NativeSearch {
  /**
   * 上一次取数是从哪儿来的（诊断用：`mobile:account_serp` / `mobile:topical_explore` /
   * `rest:0` / `feed:explore_story`）。界面上"推荐流很少""搜不出账号"时得能一眼看出走的是哪条。
   */
  private static source: string = '-';
  /** 每一发的结果（诊断用，写进日志）。 */
  private static diag: Array<string> = [];
  /**
   * 推荐网格**第一页是不是移动端探索流给的**（见 recommendedViaMobile）。
   *
   * 为什么记：移动端探索流的游标与"信息流里推荐卡片"那条不通用。翻页时要照着
   * **给游标的那条路**回去，否则第二页必空。
   */
  private static mobileUsable: boolean = false;
  /** "探索流给不给 taken_at"那条诊断只打一次（见 recommendedViaMobile）。 */
  private static dateDiagDone: boolean = false;
  /** 上一次搜账号是不是**REST 兜底**给的（日志与界面后缀据此区分，见 searchUsers）。 */
  private static viaRest: boolean = false;

  static lastSource(): string {
    return NativeSearch.source;
  }

  /** 每一发的逐条结果（诊断）。 */
  static lastDiag(): string {
    return NativeSearch.diag.join('\n');
  }

  static lastViaRest(): boolean {
    return NativeSearch.viaRest;
  }

  /**
   * 打开推荐流的落盘缓存（EntryAbility.onCreate 里调一次；幂等）。
   *
   * 只用于**页面缓存**（上次那面瀑布流），不再有"记住哪条模板"那件事 ——
   * 移动端那条路不需要挑模板。
   */
  static init(context: common.Context): void {
    SearchCache.init(context);
  }

  /** 推荐流现在能不能试：要登录（没会话时发出去只会拿到 no-session）。 */
  static mobileRecommendedUsable(): boolean {
    return SessionGate.isSignedIn();
  }

  /** 推荐流现在**有没有可用的来源**（= 会话在不在，见 mobileRecommendedUsable）。 */
  static hasRecommendedSource(): boolean {
    return NativeSearch.mobileRecommendedUsable();
  }

  /**
   * **当前这份推荐流是不是移动端探索流给的**。
   *
   * 调用方拿它决定"要不要按 clips 那把限流锁停手"：探索流是**另一个端点**，clips 被限流
   * 不代表它也被限流（用户报的"搜索推荐流无法触底刷新"就是被这把锁误拦的）。
   */
  static usingMobileRecommended(): boolean {
    return NativeSearch.mobileUsable;
  }

  /**
   * 搜账号：**只走移动端**（`fbsearch/account_serp/`，见 core/mobileapi/MobileDiscover）。
   *
   * 原先那条 `/web/search/topsearch/` 的 REST 兜底要借网页会话头（RestSession 的模板头），
   * 已随模板机制删除；失败就如实回报。
   *
   * @returns 扫到的账号；没成给 null（调用方据此报错）。
   */
  static async searchUsers(query: string): Promise<Array<SearchUser> | null> {
    NativeSearch.viaRest = false;
    return await NativeSearch.searchUsersViaMobile(query);
  }

  /**
   * 推荐帖子 —— **第一页**（`cursor` 传空串）。
   *
   * 两条路，按顺序试：
   *   1) **移动端探索流**（`discover/topical_explore/`）—— 官方 App 里推荐网格就是它；
   *   2) **信息流里的推荐卡片**（`explore_story`）：IG 自己会在首页信息流里插"推荐"帖子
   *      （结构见 core/NativeTimelineParser 的 `explore_story.media`）。上一条拿不到时用它兜底
   *      —— 同样走移动端时间线，不需要新接口。
   */
  static async recommendedPage(cursor: string): Promise<SearchPostPage | null> {
    const viaMobile: SearchPostPage | null = await NativeSearch.recommendedViaMobile(cursor);
    if (viaMobile !== null) {
      return viaMobile;
    }
    if (cursor.length > 0) {
      // 翻页：游标是"给它的那条路"给的，两条路不通用 —— 这里只能空手而归。
      NativeSearch.diag.push('more skipped: first page was not from mobile explore');
      return null;
    }
    const fromFeed: Array<SearchPost> = await NativeSearch.recommendedFromFeed();
    if (fromFeed.length > 0) {
      NativeSearch.mobileUsable = false;
      NativeSearch.source = 'feed:explore_story';
      // 信息流那条没有"下一页游标"这一说（首页就是一条时间线，翻页另有一套），
      // 所以这一路的推荐是**一页到底**：hasMore=false，界面显示"没有更多了"。
      return new SearchPostPage(fromFeed, '', false, NativeSearch.source);
    }
    return null;
  }

  /**
   * 信息流里的推荐卡片 → 瀑布流条目。
   *
   * 只看 `explore_story.media` 那一种包装（IG 自己标的"推荐"），**不是**把整条信息流端上来 ——
   * 那会把关注列表里的帖子也混进"推荐"。
   */
  private static async recommendedFromFeed(): Promise<Array<SearchPost>> {
    const page: MobileFeedPage | null = await MobileFeedTimeline.page('');
    if (page === null) {
      NativeSearch.diag.push('source feed(timeline) -> miss');
      return [];
    }
    const root: Record<string, Object> = JsonRead.parse(page.body);
    const seen: Array<string> = [];
    const posts: Array<SearchPost> = [];
    let cards: number = 0;
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (!JsonRead.has(node, 'explore_story')) {
        return;
      }
      cards++;
      if (posts.length >= MAX_POSTS) {
        return;
      }
      const story: Record<string, Object> | null = JsonRead.recordOf(node, 'explore_story');
      if (story === null) {
        return;
      }
      const media: Record<string, Object> | null = JsonRead.recordOf(story, 'media');
      if (media === null) {
        return;
      }
      const mapped: SearchPost | null = NativeSearch.postOf(media);
      if (mapped === null || seen.indexOf(mapped.code) >= 0) {
        return;
      }
      seen.push(mapped.code);
      posts.push(mapped);
    });
    NativeSearch.diag.push(`source feed(timeline) -> len=${page.body.length}`
      + ` exploreCards=${cards} posts=${posts.length}`);
    hilog.info(DOMAIN, TAG, 'recommend from feed cards=%{public}d n=%{public}d',
      cards, posts.length);
    return posts;
  }

  /**
   * 移动端探索流那一发（推荐网格的**首选**路，见 recommendedPage）。
   *
   * 翻页规则：只有当**第一页确实来自移动端**（`mobileUsable`）时，才承认调用方给的游标是
   * 移动端的游标 —— 两条路的游标互不通用，拿错只会白打一发并报"读取失败"。
   */
  private static async recommendedViaMobile(cursor: string): Promise<SearchPostPage | null> {
    if (cursor.length > 0 && !NativeSearch.mobileUsable) {
      return null;
    }
    const page: MobileMediaPage | null = await MobileDiscover.explore(cursor, ApiThrottle.interactive());
    if (page === null) {
      if (cursor.length === 0) {
        NativeSearch.mobileUsable = false;
        NativeSearch.diag.push('mobile explore -> miss');
      }
      return null;
    }
    const posts: Array<SearchPost> = NativeSearch.postsFromMedias(page.medias);
    // 发布时刻命中率只打一次：这一位决定首页卡片底部那行（日期 + 翻译）画不画，
    // 摸清"探索流到底给不给 taken_at"比事后猜省事（见 NativeSearch.readPost）。
    if (!NativeSearch.dateDiagDone) {
      NativeSearch.dateDiagDone = true;
      let withDate: number = 0;
      for (let index: number = 0; index < posts.length; index++) {
        if (posts[index].takenAt > 0) {
          withDate++;
        }
      }
      hilog.info(DOMAIN, TAG, 'recommend dates with=%{public}d/%{public}d',
        withDate, posts.length);
    }
    NativeSearch.diag.push(`mobile explore -> medias=${page.medias.length} posts=${posts.length}`
      + ` more=${page.hasMore} ms=${page.ms}`);
    hilog.info(DOMAIN, TAG, 'recommend mobile medias=%{public}d posts=%{public}d more=%{public}s ms=%{public}d',
      page.medias.length, posts.length, `${page.hasMore}`, page.ms);
    if (posts.length === 0) {
      return null;
    }
    NativeSearch.mobileUsable = true;
    NativeSearch.source = 'mobile:topical_explore';
    return new SearchPostPage(posts, page.nextCursor, page.hasMore, NativeSearch.source);
  }

  /** 移动端账号搜索那一发（见 searchUsers）。 */
  private static async searchUsersViaMobile(query: string): Promise<Array<SearchUser> | null> {
    const page: MobileUserPage | null = await MobileDiscover.accounts(query, '',
      ApiThrottle.interactive());
    if (page === null || page.users.length === 0) {
      return null;
    }
    NativeSearch.source = 'mobile:account_serp';
    hilog.info(DOMAIN, TAG, 'search mobile q=%{public}s users=%{public}d ms=%{public}d',
      query, page.users.length, page.ms);
    return page.users;
  }

  /**
   * **原始媒体节点**（移动端探索流 / 搜索帖子那两条路给的）→ 界面要的 `SearchPost`。
   *
   * 复用 `postOf`（它已经处理多图兜底与展示档封面），所以两条路的字段语义完全一致 ——
   * 以后改映射只改一处。
   */
  static postsFromMedias(medias: Array<Object>): Array<SearchPost> {
    const posts: Array<SearchPost> = [];
    const seen: Array<string> = [];
    for (let index: number = 0; index < medias.length && posts.length < MAX_POSTS; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(medias[index]);
      if (node === null) {
        continue;
      }
      const mapped: SearchPost | null = NativeSearch.postOf(node);
      if (mapped === null || seen.indexOf(mapped.code) >= 0) {
        continue;
      }
      seen.push(mapped.code);
      posts.push(mapped);
    }
    return posts;
  }

  /** 一个媒体节点 → 瀑布流要的字段；不是帖子给 null。 */
  private static postOf(node: Record<string, Object>): SearchPost | null {
    const inner: SearchPost | null = NativeSearch.readPost(node);
    if (inner !== null) {
      return inner;
    }
    // 多图帖：外层没有封面时取第一张子媒体（和 NativeProfile.postOf 同一套兜底）。
    const carousel: Array<Object> = JsonRead.arrayOf(node, 'carousel_media');
    if (carousel.length === 0) {
      return null;
    }
    const first: Record<string, Object> | null = JsonRead.asRecord(carousel[0]);
    return first === null ? null : NativeSearch.readPost(first);
  }

  /**
   * 单个节点的直读（不递归子媒体）。
   *
   * 封面走 `MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH)` —— 和全 app 的展示档
   * 挑选**同一套判据**（只是把目标宽度压到网格够用的 360，见 COVER_WIDTH），它返回的
   * `url / width / height` 是**同一张图**的三个字段。这一点是瀑布流的关键：
   * 格子高度按"这张图自己的比例"算，`ImageFit.Cover` 才不会裁到画面。
   * （踩过的坑：拿帖子的 `original_width/height` 去套封面 —— 视频帖那是视频帧的尺寸，
   *  和封面不是一张图；尺寸还常常缺，缺了就整批退化成同一个比例，看着就是"等高网格 + 图被裁"。）
   */
  private static readPost(node: Record<string, Object>): SearchPost | null {
    const code: string = JsonRead.strOf(node, 'code');
    if (code.length === 0) {
      return null;
    }
    // 分享数取证（见 core/ShareProbe）：只记第一条媒体节点的键名与分享类键的命中情况。
    ShareProbe.noteMedia('explore', node);
    const images: Record<string, Object> | null = JsonRead.recordOf(node, 'image_versions2');
    const candidates: Array<Object> = images === null ? [] : JsonRead.arrayOf(images, 'candidates');
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(candidates[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(JsonRead.numOf(one, 'width'));
      heights.push(JsonRead.numOf(one, 'height'));
    }
    const picked: PickedMedia = MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH);
    if (picked.url.length === 0) {
      // 没有可显示的静态封面（少数纯视频节点不给 image_versions2）：**不拿 .mp4 顶替**，
      // 那种地址喂给 Image() 只会得到一块空白，不如不放这一格。
      return null;
    }
    const videos: Array<Object> = JsonRead.arrayOf(node, 'video_versions');
    // 推荐流点开要进 **Reels 页**（需求）：所以除了封面，顺手把"播放要用的那几样"也带上 ——
    // 媒体 id（缺地址时按它去补）、视频地址（这条查询通常直接给）、作者名（页面左下角要显示）。
    const videoUrls: Array<string> = [];
    const videoWidths: Array<number> = [];
    const videoHeights: Array<number> = [];
    for (let index: number = 0; index < videos.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(videos[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      videoUrls.push(url);
      videoWidths.push(JsonRead.numOf(one, 'width'));
      videoHeights.push(JsonRead.numOf(one, 'height'));
    }
    const display: PickedMedia = MediaQuality.displayVideo(videoUrls, videoWidths, videoHeights);
    const original: PickedMedia = MediaQuality.originalVideo(videoUrls, videoWidths, videoHeights);
    /*
     * 媒体数字 id：**优先 `strong_id__`**（它是**字符串**，原样可信）。
     *
     * 为什么不能直接用 `pk` / `id`：IG 的 pk 是 19 位的（1234567890123456789），超过 IEEE754 的
     * 精确整数范围，`JSON.parse` 之后会变成 `1.2345678901234568e+18` 这种带指数的数；
     * 而 `ProfileReelsViewModel.mediaIdOf` 有一道"必须全是数字"的校验，指数形式过不了 →
     * 返回空 id → 推荐流那页的**点赞直接判为不可用**（用户报的"推荐流的 reels 页面无法点赞"，
     * 其它页面正常是因为它们的 id 来自 GraphQL 的字符串字段或 `pk_id`）。
     * `strong_id__` 在这几份载荷里一直是字符串，取它最稳；没有才退回 `pk` / `id`。
     */
    const strongId: string = JsonRead.strOf(node, 'strong_id__');
    const rawId: Object = strongId.length > 0 ? strongId : (node['pk'] ?? node['id'] ?? '');
    const user: Record<string, Object> | null = JsonRead.recordOf(node, 'user');
    const username: string = user === null ? '' : JsonRead.strOf(user, 'username');
    const avatar: string = user === null ? '' : JsonRead.strOf(user, 'profile_pic_url');
    // 作者 pk：Reels 页那颗关注按钮要用（见 model/Reel 的 authorId）。
    const authorId: string = user === null ? ''
      : `${user['pk'] ?? user['id'] ?? ''}`.trim();
    const captionNode: Record<string, Object> | null = JsonRead.recordOf(node, 'caption');
    const caption: string = captionNode === null ? '' : JsonRead.strOf(captionNode, 'text');
    // 三个计数 + "本机点过赞没有"：推荐流那条和首页 clips 是同形状的响应
    // （见 core/NativeReels 里同一组字段），Reels 页右侧动作栏要用（用户报的"没有显示
    // 点赞评论转发数量"就是这里没接）。
    const liked: boolean = JsonRead.boolOf(node, 'has_liked')
      || JsonRead.boolOf(node, 'viewer_has_liked');
    // 关注状态（Reels 页那颗按钮）：挂在他/她的 `friendship_status.following` 上；
    // 没有这个字段就留 undefined，让界面自己问一次（见 model/Search 的 following）。
    let following: boolean | undefined = undefined;
    if (user !== null) {
      const friend: Record<string, Object> | null = JsonRead.recordOf(user, 'friendship_status');
      if (friend !== null) {
        if (JsonRead.has(friend, 'following')) {
          following = JsonRead.boolOf(friend, 'following');
        } else if (JsonRead.has(friend, 'followed_by_viewer')) {
          following = JsonRead.boolOf(friend, 'followed_by_viewer');
        }
      }
    }
    /*
     * 发布时刻：`taken_at` 是 **Unix 秒**。首页那些卡片底部要显示"3小时前"+「翻译」，
     * 而那一行整体挂在"有没有发布时间"上（见 FeedList.postCard / hasPostedTime），
     * 所以这个字段不接 = 探索流那一段**日期和翻译按钮一起消失**（用户报的问题）。
     * 个别节点是毫秒（13 位），那样直接除 1000 —— 别让"1970 年"这种文案冒出来。
     */
    let takenAt: number = JsonRead.numOf(node, 'taken_at');
    if (takenAt > 100000000000) {
      takenAt = Math.floor(takenAt / 1000);
    }
    /*
     * **多图 / 图文视频混排（轮播）**：探索流里同样有 `carousel_media`，字段形状与时间线那份一致。
     * 以前这条路只取第一张封面，于是探索流的多图帖在 feeds 里永远只显示一张
     * （用户报的"多图片/视频媒体帖子是不是没适配"）。
     * 这里逐页挑"展示档"的图和视频（同一套 MediaQuality 判据），交给
     * `FeedMapper.slidesFromItems` 转成 MediaSlide[]。
     */
    const carousel: Array<Object> = JsonRead.arrayOf(node, 'carousel_media');
    const mediaItems: Array<FeedMediaItemDto> = [];
    if (carousel.length > 1) {
      for (let index: number = 0; index < carousel.length; index++) {
        const page: Record<string, Object> | null = JsonRead.asRecord(carousel[index]);
        if (page === null) {
          continue;
        }
        const one: FeedMediaItemDto = NativeSearch.carouselPage(page);
        if (one.img.length === 0 && one.vid.length === 0) {
          continue;
        }
        mediaItems.push(one);
      }
    }
    /*
     * 分享 / 收藏数：**和转发数一样"有就收"**。
     *
     * 这两颗数字以前在探索流这条路上压根没读，于是"搜索推荐流点进 Reels 页 / 首页为你推荐
     * 那一段"永远显示不出分享数 —— 即使载荷里给了（用户报的"feeds 与 reels 看不到分享数量"，
     * 这一条是**映射层**的断点，不是数据源的）。
     * 候选名与 core/NativeTimelineParser / core/NativeReels 保持同一套（IG 会改名）；
     * 一个都没命中就是 0，界面按 0 把那颗数字整颗不画（见 model/MediaPost.shareCount）。
     */
    const shareCount: number = NativeSearch.firstCount(node, ['share_count', 'shares_count',
      'media_share_count']);
    const saveCount: number = NativeSearch.firstCount(node, ['save_count', 'saves_count',
      'media_save_count']);
    return new SearchPost(code, picked.url, picked.width, picked.height, videos.length > 0,
      `${rawId}`.trim(), display.url, original.url, username, avatar, authorId, caption,
      JsonRead.numOf(node, 'like_count'), JsonRead.numOf(node, 'comment_count'),
      JsonRead.numOf(node, 'media_repost_count'), liked, following, takenAt, mediaItems,
      shareCount, saveCount);
  }

  /**
   * 按候选键名取第一个**正**的计数（字段名不定时用；都取不到就是 0）。
   *
   * 判据与 `NativeTimelineParser.firstCount` / `NativeReels.firstCount` 一致：
   * 数字直接认，`JsonRead.numOf` 顺带把 "1234" 这种字符串数字也转过来。
   * 只认 > 0 的值 —— 0 的语义是"载荷没说"，不能拿它覆盖掉别的候选名。
   */
  private static firstCount(node: Record<string, Object>, names: Array<string>): number {
    for (let index: number = 0; index < names.length; index++) {
      const value: number = JsonRead.numOf(node, names[index]);
      if (value > 0) {
        return Math.round(value);
      }
    }
    return 0;
  }

  /**
   * 轮播里的一页 → 逐页媒体（图和视频都按"展示档"挑，口径同单图/单视频帖）。
   *
   * 视频页的 `img` 用它的**封面**（`image_versions2`），与 `MediaSlide` 的约定一致
   * （见 model/MediaPost 的 MediaSlide 注释）。
   */
  private static carouselPage(page: Record<string, Object>): FeedMediaItemDto {
    const images: Record<string, Object> | null = JsonRead.recordOf(page, 'image_versions2');
    const candidates: Array<Object> = images === null ? [] : JsonRead.arrayOf(images, 'candidates');
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(candidates[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(JsonRead.numOf(one, 'width'));
      heights.push(JsonRead.numOf(one, 'height'));
    }
    const picked: PickedMedia = MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH);
    const versions: Array<Object> = JsonRead.arrayOf(page, 'video_versions');
    const vidUrls: Array<string> = [];
    const vidWidths: Array<number> = [];
    const vidHeights: Array<number> = [];
    for (let index: number = 0; index < versions.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(versions[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      vidUrls.push(url);
      vidWidths.push(JsonRead.numOf(one, 'width'));
      vidHeights.push(JsonRead.numOf(one, 'height'));
    }
    const video: PickedMedia = MediaQuality.displayVideo(vidUrls, vidWidths, vidHeights);
    // 宽高优先用视频自己的（视频页要按视频比例排版），图片页用封面自己的。
    const w: number = video.url.length > 0 ? video.width : picked.width;
    const h: number = video.url.length > 0 ? video.height : picked.height;
    return {
      img: picked.url,
      vid: video.url,
      w: w,
      h: h
    } as FeedMediaItemDto;
  }

  /** 整包里所有"像用户"的对象（去重、限量）。 */
  private static usersOf(text: string): Array<SearchUser> {
    const root: Record<string, Object> = JsonRead.parse(text);
    const seen: Array<string> = [];
    const users: Array<SearchUser> = [];
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (users.length >= MAX_USERS) {
        return;
      }
      const username: string = JsonRead.strOf(node, 'username');
      if (username.length === 0 || seen.indexOf(username) >= 0) {
        return;
      }
      const hasPic: boolean = JsonRead.has(node, 'profile_pic_url');
      const hasName: boolean = JsonRead.has(node, 'full_name');
      if (!hasPic && !hasName) {
        return;
      }
      seen.push(username);
      const hd: Record<string, Object> | null = JsonRead.recordOf(node, 'hd_profile_pic_url_info');
      const hdUrl: string = hd === null ? '' : JsonRead.strOf(hd, 'url');
      const avatar: string = hdUrl.length > 0 ? hdUrl : JsonRead.strOf(node, 'profile_pic_url');
      // 数字 id（`pk`，退回 `id`）：点一下要进**原生用户主页**，那一页按 id 取数与定位
      // （见 model/Search 的 SearchUser.userId 与 pages/Index.openUserProfile）。
      const rawId: Object = node['pk'] ?? node['id'] ?? '';
      users.push(new SearchUser(username, JsonRead.strOf(node, 'full_name'), avatar,
        JsonRead.boolOf(node, 'is_verified'), JsonRead.boolOf(node, 'is_private'),
        `${rawId}`.trim()));
    });
    return users;
  }

  /** 深度优先遍历整包 JSON，把每个"对象节点"交给回调。 */
  private static walk(node: Object, depth: number,
                      visit: (found: Record<string, Object>) => void,
                      stop: () => boolean = (): boolean => false): void {
    if (depth > MAX_DEPTH || node === null || typeof node !== 'object' || stop()) {
      return;
    }
    if (Array.isArray(node)) {
      const list: Array<Object> = node as Array<Object>;
      for (let index: number = 0; index < list.length; index++) {
        if (stop()) {
          return;
        }
        NativeSearch.walk(list[index], depth + 1, visit, stop);
      }
      return;
    }
    const record: Record<string, Object> | null = JsonRead.asRecord(node);
    if (record === null) {
      return;
    }
    visit(record);
    const keys: Array<string> = Object.keys(record);
    for (let index: number = 0; index < keys.length; index++) {
      const child: Object = record[keys[index]];
      if (child !== null && typeof child === 'object') {
        NativeSearch.walk(child, depth + 1, visit, stop);
      }
    }
  }
}
