/*
 * 原生解析首页信息流的 GraphQL 响应（网页那条脚本做过的同一件事，搬到原生来做）。
 *
 * 为什么要搬到原生：走 core/NativeFeed 那条路时，我们**没有网页**可以注入脚本 ——
 * 响应体就在原生手里，直接 `JSON.parse` 出结构、映射成原生卡片要的字段（FeedItemDto），
 * 是唯一的选择，也顺带省掉了"整包响应过桥"的开销（实测这一包 68KB）。
 *
 * 映射规则**刻意和页面脚本（WebScripts.timelineScript）保持一致**：同样的字段名兜底、
 * 同样的"取最大尺寸图"、同样的 original_width/height 优先。两边不一致就会出现
 * "走网页时排版对、走原生时不对"这种最难查的问题。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedItemDto, FeedMediaItemDto } from '../model/FeedDto';
import { MediaQuality, PickedMedia, QualityProfile } from './MediaQuality';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeTimelineParser';

/** 连接键：响应 `.data` 里放首页信息流的那个键。 */
const FEED_KEY: string = 'xdt_api__v1__feed__timeline__connection';
/**
 * 首屏封面预解码用的**低一档宽度**（px）。
 *
 * 网格/信息流的展示档是 1080（见 MediaQuality），一百多 KB；冷启动时先用 360 这一档
 * （几十 KB，几十毫秒就到）解出一张小图垫在下面，真图加载完自然盖住（见 core/PosterCache）。
 */
const THUMB_WIDTH: number = 360;

/** 图片候选（image_versions2.candidates）。 */
interface IgCandidate {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

interface IgImageVersions {
  candidates?: Array<IgCandidate> | null;
}

interface IgVideoVersion {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

interface IgUser {
  pk?: string | number | null;
  id?: string | null;
  username?: string | null;
  profile_pic_url?: string | null;
  friendship_status?: IgFriendship | null;
}

/**
 * 关注状态。
 *
 * 信息流那条 GraphQL 不一定带它（带就带上，不带就当作"未知"，由关注按钮自己记状态，
 * 见 viewmodel/FeedViewModel.followStates）。
 */
interface IgFriendship {
  following?: boolean | null;
  outgoing_request?: boolean | null;
}

interface IgCaption {
  text?: string | null;
}

/**
 * 一条媒体（帖子）。
 *
 * 注意每个字段都可能是 **null**（不是 undefined）：GraphQL 对"没有这个字段"就是回 null，
 * 而 `null.length` / `for (x of null)` 会直接抛 —— 实测踩过（解析整包时
 * `Cannot read property carousel_media of null`，整条首屏链路在重试里空转）。
 * 所以下面一律走 `?? []` / `?? {}`，绝不直接取属性。
 */
interface IgMedia {
  id?: string | null;
  code?: string | null;
  media_type?: number | null;
  original_width?: number | null;
  original_height?: number | null;
  image_versions2?: IgImageVersions | null;
  video_versions?: Array<IgVideoVersion> | null;
  carousel_media?: Array<IgMedia> | null;
  user?: IgUser | null;
  caption?: IgCaption | null;
  like_count?: number | null;
  comment_count?: number | null;
  view_count?: number | null;
  play_count?: number | null;
  ig_play_count?: number | null;
  has_liked?: boolean | null;
  taken_at?: number | null;
  /**
   * 转发 / 分享计数。
   *
   * IG 的字段名**不确定**（网页界面根本不渲染这两个数字，只能去节点里翻），所以这里像页面
   * 脚本那样多列几个候选名，谁先有值用谁：`repost_count` / `media_repost_count` /
   * `reposts_count` / `reshare_count` / `reshares_count`。
   * 只认这几个**明确含 repost/reshare 的整型计数**，不会误抓到别的东西。
   */
  reshare_count?: number | null;
  share_count?: number | null;
  shares_count?: number | null;
  media_share_count?: number | null;
  repost_count?: number | null;
  media_repost_count?: number | null;
  reposts_count?: number | null;
  reshares_count?: number | null;
}

interface IgNode {
  media?: IgMedia | null;
  explore_story?: IgNode | null;
}

interface IgEdge {
  node?: IgNode | null;
}

interface IgPageInfo {
  end_cursor?: string | null;
  has_next_page?: boolean | null;
}

interface IgConnection {
  edges?: Array<IgEdge> | null;
  page_info?: IgPageInfo | null;
}

interface IgResponse {
  data?: Record<string, IgConnection> | null;
}

/** 选出的一张图（url 一定非空：调用方不用再判 null）。 */
class PickedImage {
  readonly url: string;
  readonly width: number;
  readonly height: number;

  constructor(url: string, width: number, height: number) {
    this.url = url;
    this.width = width;
    this.height = height;
  }
}

/** 解析结果：条目 + 游标（游标只用于诊断/日志，翻页仍走网页那条路）。 */
export class NativeTimeline {
  readonly items: Array<FeedItemDto>;
  readonly nextCursor: string;
  readonly hasNext: boolean;

  constructor(items: Array<FeedItemDto>, nextCursor: string, hasNext: boolean) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.hasNext = hasNext;
  }
}

export class NativeTimelineParser {
  /**
   * 本次解析用的画质档（见 parseMobileFeed）：null = 读全局设置（老路径）。
   * 放静态字段的原因：pick 那几层是私有的、调用链很深，一路传参改动面太大；
   * 而解析是**同步**的，同一条线程上不会交错（TaskPool 每个线程各自一份模块实例）。
   */
  private static parsingProfile: QualityProfile | null = null;
  /**
   * **移动端 `feed/timeline/` 那条**的解析（形状与网页 GraphQL 不同）。
   *
   * 移动端响应（实测 200 / 253KB）通常是：
   *   `{"feed_items":[{"media_or_ad":{…v1 媒体…}}], "more_available":true, "next_max_id":"…"}`
   * 有的版本用 `items[]` 或把条目直接写成 `media`，所以这里**都不写死**：
   * 依次找 `feed_items` / `items`，条目里依次找 `media_or_ad` / `media`；
   * 游标依次取 `next_max_id` / `pagination_info.max_id`；`more_available` 同理。
   *
   * 字段映射**复用 `toItem`**：v1 媒体与 GraphQL 媒体的字段名基本重合
   * （`image_versions2` / `video_versions` / `carousel_media` / `user` / `caption` …）。
   */
  static parseMobileFeed(body: string, profile: QualityProfile | null = null): NativeTimeline | null {
    // 画质档由调用方给（见 MediaQuality.QualityProfile）：解析可能跑在 TaskPool 里，那里读不到设置。
    NativeTimelineParser.parsingProfile = profile;
    if (body.length === 0) {
      return null;
    }
    let root: Record<string, Object>;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      return null;
    }
    const rows: Array<Object> = NativeTimelineParser.rowsOf(root);
    const items: Array<FeedItemDto> = [];
    if (!NativeTimelineParser.rootDiagDone) {
      NativeTimelineParser.rootDiagDone = true;
      const keys: Array<string> = Object.keys(root);
      const parts: Array<string> = [];
      for (let index: number = 0; index < keys.length; index++) {
        const value: Object = root[keys[index]];
        if (value === null) {
          parts.push(`${keys[index]}:null`);
        } else if (Array.isArray(value)) {
          const first: Record<string, Object> | null = (value as Array<Object>).length > 0
            ? NativeTimelineParser.asRecord((value as Array<Object>)[0]) : null;
          parts.push(`${keys[index]}[${(value as Array<Object>).length}`
            + `|${first === null ? '-' : Object.keys(first).slice(0, 6).join('+')}]`);
        } else {
          parts.push(`${keys[index]}:${typeof value}`);
        }
      }
      hilog.info(DOMAIN, TAG, 'mobile feed root: %{public}s', parts.join(' ').substring(0, 900));
    }
    for (let index: number = 0; index < rows.length; index++) {
      const row: Record<string, Object> | null = NativeTimelineParser.asRecord(rows[index]);
      if (row === null) {
        continue;
      }
      // 条目里可能是 `media_or_ad`（时间线）或 `media`（部分版本/广告位）。
      let media: Record<string, Object> | null = NativeTimelineParser.asRecord(row['media_or_ad']);
      if (media === null) {
        media = NativeTimelineParser.asRecord(row['media']);
      }
      if (media === null) {
        continue;
      }
      /*
       * **广告一律不要**（用户报的："关注流还是混入未关注的广告用户帖子"）。
       *
       * 广告是 IG 插进时间线的付费内容（`media_or_ad` 这个键名就是"媒体**或**广告"），
       * 作者通常没被关注，但它不一定带 `friendship_status` —— 光靠"关注状态"那道筛
       * 兜不住它（unknown 只能放行或误杀）。所以在这一层就按广告标记剔掉。
       * 判据取几个这版载荷里出现过的标记，任一命中即算广告。
       */
      if (NativeTimelineParser.looksLikeAd(row, media)) {
        continue;
      }
      items.push(NativeTimelineParser.toItem(media as IgMedia));
    }
    if (items.length === 0) {
      // 解析不出来时打一行现场：拿到几行、第一行有哪些键（别又像"空数组"那样沉默）。
      const first: Record<string, Object> | null = rows.length > 0
        ? NativeTimelineParser.asRecord(rows[0]) : null;
      hilog.info(DOMAIN, TAG, 'mobile feed no item: rows=%{public}d rowKeys=%{public}s',
        rows.length, first === null ? '-' : Object.keys(first).slice(0, 12).join(','));
      return null;
    }
    const cursor: string = NativeTimelineParser.cursorOf(root);
    const hasNext: boolean = NativeTimelineParser.moreOf(root);
    return new NativeTimeline(items, cursor, hasNext);
  }

  /**
   * 移动端响应里"那一串条目"在哪。
   *
   * ⚠️ 真机踩过的两个坑（2026-10-21，`feed/timeline/` 这一版）：
   *   ① `feed_items: []` 是空数组，内容在另一个键里 —— "取第一个存在的数组"就拿到了空的那个；
   *   ② 某一个候选数组里只有一行 `{"end_of_feed_demarcator": …}`（占位），
   *      拿到它就等于"整页 0 条"，而响应其实是好的（323~383KB、HTTP 200、4~6 秒）。
   * 所以判据不再看键名顺序，而是**看哪条数组里真的有媒体行**（`media_or_ad` / `media`），
   * 取媒体行最多的那条；都投不出媒体行才算这一页没内容。
   */
  private static rowsOf(root: Record<string, Object>): Array<Object> {
    const keys: Array<string> = ['feed_items', 'items', 'media_or_ad'];
    let best: Array<Object> = [];
    let bestMedia: number = 0;
    const shape: Array<string> = [];
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object | undefined = root[keys[index]];
      if (value === undefined || value === null || !Array.isArray(value)) {
        continue;
      }
      const list: Array<Object> = value as Array<Object>;
      let media: number = 0;
      for (let at: number = 0; at < list.length; at++) {
        const row: Record<string, Object> | null = NativeTimelineParser.asRecord(list[at]);
        if (row === null) {
          continue;
        }
        if (row['media_or_ad'] !== undefined && row['media_or_ad'] !== null
          || row['media'] !== undefined && row['media'] !== null) {
          media++;
        }
      }
      shape.push(`${keys[index]}[${list.length}/${media}]`);
      if (media > bestMedia) {
        bestMedia = media;
        best = list;
      }
    }
    if (bestMedia === 0) {
      hilog.info(DOMAIN, TAG, 'mobile feed rows none: candidates=%{public}s', shape.join(' '));
    } else if (!NativeTimelineParser.rowsDiagDone) {
      NativeTimelineParser.rowsDiagDone = true;
      hilog.info(DOMAIN, TAG, 'mobile feed rows pick=%{public}d candidates=%{public}s',
        bestMedia, shape.join(' '));
    }
    return best;
  }

  /** "候选数组各几行"那条诊断只打一次（见 rowsOf）。 */
  private static rowsDiagDone: boolean = false;
  /** "顶层键长什么样"那条诊断只打一次（见 parseMobileFeed）。 */
  private static rootDiagDone: boolean = false;

  /**
   * 这一页是不是**"关注的人的最新帖子已看完"**那个占位（`end_of_feed_demarcator`）。
   *
   * 为什么要单独认它：IG 会把"你看完了关注的人的最新帖子，下面是为你推荐"做成
   * `feed_items` 里的**一条占位**（不是媒体），带着 `group_set.active_group_id=feed_recs`。
   * 它既不是内容、也不该被当成"这一页没数据"重试 —— 认清它之后，调用方可以记下这个状态、
   * 短时间内别再白问（见 core/NativeFeed.fetchPage / markCaughtUp）。
   */
  static isCaughtUp(body: string): boolean {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      return false;
    }
    /*
     * 注意**不能**用 rowsOf：它只在"有媒体行"时才返回数组（这个占位页恰好没有），
     * 所以这里自己扫原始的候选数组。
     */
    const keys: Array<string> = ['feed_items', 'items'];
    let sawPlaceholder: boolean = false;
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object | undefined = root[keys[index]];
      if (value === undefined || value === null || !Array.isArray(value)) {
        continue;
      }
      const list: Array<Object> = value as Array<Object>;
      if (list.length === 0) {
        continue;
      }
      for (let at: number = 0; at < list.length; at++) {
        const row: Record<string, Object> | null = NativeTimelineParser.asRecord(list[at]);
        if (row === null) {
          return false;
        }
        const mark: Object | undefined = row['end_of_feed_demarcator'];
        if (mark === undefined || mark === null) {
          // 只要还有一行不是那个占位，就不能当"看完了"。
          return false;
        }
        sawPlaceholder = true;
      }
    }
    return sawPlaceholder;
  }

  /**
   * 这一条是不是**广告**（付费插入的）。
   *
   * 认几个这版时间线载荷里出现过的标记，任一命中即算：
   *   · 行/媒体上的 `is_ad: true`、`ad_id`；
   *   · 媒体上的 `ad_header_style` / `ad_action` / `ad_metadata` / `injected` /
   *     `dr_ad_type` / `ad_tag`（后两个是 IG 广告回传用的字段）。
   *
   * 只认"明确是广告"的那几个键：宁可漏一条广告，也不要把正常帖子当广告删掉。
   */
  private static looksLikeAd(row: Record<string, Object>, media: Record<string, Object>): boolean {
    if (NativeTimelineParser.flagOf(row, 'is_ad') || NativeTimelineParser.flagOf(media, 'is_ad')) {
      return true;
    }
    const keys: Array<string> = ['ad_id', 'ad_header_style', 'ad_action', 'ad_metadata',
      'injected', 'dr_ad_type', 'ad_tag'];
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      if (NativeTimelineParser.hasValue(media, key) || NativeTimelineParser.hasValue(row, key)) {
        return true;
      }
    }
    return false;
  }

  /** 字段存在且不是 false / null / 空串 / 0。 */
  private static hasValue(holder: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = holder[key];
    if (value === undefined || value === null || value === false) {
      return false;
    }
    if (typeof value === 'string') {
      return (value as string).length > 0;
    }
    if (typeof value === 'number') {
      return (value as number) !== 0;
    }
    return true;
  }

  /** 布尔标记（`true` 或字符串 `'true'` 才算）。 */
  private static flagOf(holder: Record<string, Object>, key: string): boolean {
    const value: Object | undefined = holder[key];
    return value === true || `${value}` === 'true';
  }

  /** 翻页游标（`next_max_id` 优先，其次 `pagination_info.max_id`）。 */
  private static cursorOf(root: Record<string, Object>): string {
    const direct: string = `${root['next_max_id'] ?? ''}`.trim();
    if (direct.length > 0 && direct !== 'null') {
      return direct;
    }
    const paging: Record<string, Object> | null =
      NativeTimelineParser.asRecord(root['pagination_info']);
    if (paging !== null) {
      const viaPaging: string = `${paging['max_id'] ?? ''}`.trim();
      if (viaPaging.length > 0 && viaPaging !== 'null') {
        return viaPaging;
      }
    }
    return '';
  }

  /** 还有没有下一页（`more_available` 优先，其次 `pagination_info.more_available`）。 */
  private static moreOf(root: Record<string, Object>): boolean {
    if (root['more_available'] === true) {
      return true;
    }
    const paging: Record<string, Object> | null =
      NativeTimelineParser.asRecord(root['pagination_info']);
    return paging !== null && paging['more_available'] === true;
  }

  private static asRecord(value: Object | undefined | null): Record<string, Object> | null {
    if (value === undefined || value === null || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  /**
   * 把整包响应解析成卡片 DTO。
   *
   * 解析不了（不是 JSON / 没有连接 / 一条媒体都没有）返回 null，调用方直接退回网页路径。
   */
  static parse(body: string): NativeTimeline | null {
    if (body.length === 0 || body.indexOf(FEED_KEY) < 0) {
      return null;
    }
    let response: IgResponse;
    try {
      response = JSON.parse(body) as IgResponse;
    } catch (error) {
      return null;
    }
    const data: Record<string, IgConnection> | null = response.data ?? null;
    if (data === null) {
      return null;
    }
    const conn: IgConnection | null = data[FEED_KEY] ?? null;
    if (conn === null) {
      return null;
    }
    const edges: Array<IgEdge> = conn.edges ?? [];
    const items: Array<FeedItemDto> = [];
    for (let index: number = 0; index < edges.length; index++) {
      const node: IgNode | null = edges[index].node ?? null;
      if (node === null) {
        continue;
      }
      // 信息流里混着"推荐"卡片：node.media 是 null，真正的帖子挂在 node.explore_story.media。
      let media: IgMedia | null = node.media ?? null;
      if (media === null && node.explore_story !== null && node.explore_story !== undefined) {
        media = node.explore_story.media ?? null;
      }
      if (media === null) {
        continue;
      }
      items.push(NativeTimelineParser.toItem(media));
    }
    if (items.length === 0) {
      return null;
    }
    const info: IgPageInfo = conn.page_info ?? {};
    const cursor: string = (info.end_cursor ?? '').trim();
    const hasNext: boolean = info.has_next_page === true;
    return new NativeTimeline(items, cursor, hasNext);
  }

  /**
   * 逐页媒体里**最高那一页**的宽高比（w/h；拿不到给 0）。
   *
   * 需求："所有 feeds 流多图片帖子媒体区高度根据高度最高的图片" —— 现在**视频页也参与**
   * （多图帖里混着竖视频时，盒子必须放得下它，否则那一页会被裁）。
   */
  private static aspectMinOf(items: Array<FeedMediaItemDto>): number {
    let min: number = 0;
    for (let index: number = 0; index < items.length; index++) {
      const w: number = items[index].w;
      const h: number = items[index].h;
      if (w > 0 && h > 0) {
        const aspect: number = w / h;
        if (min <= 0 || aspect < min) {
          min = aspect;
        }
      }
    }
    return min;
  }

  /**
   * 媒体 → FeedItemDto（字段与页面脚本一一对应）。
   *
   * 图片/视频都取**两份**：展示用按 core/MediaQuality 降到 1080 档（省流量），
   * 下载用的原图/原视频留在 originalImages / originalVideo 里。
   */
  private static toItem(media: IgMedia): FeedItemDto {
    const images: Array<string> = [];
    const originalImages: Array<string> = [];
    let video: string = '';
    let originalVideo: string = '';
    // 首屏封面预解码用的**低一档**封面地址（见 core/PosterCache）：只取展示那张图的小档，
    // 几十 KB，冷启动时先把它解出来垫在真图下面，首屏不用对着空框等。
    let thumb: string = '';
    let imageW: number = 0;
    let imageH: number = 0;
    let videoW: number = 0;
    let videoH: number = 0;
    const carousel: Array<IgMedia> = media.carousel_media ?? [];
    /*
     * **逐页媒体**（需求："feeds 流多图片媒体可以包含视频媒体"）。
     *
     * 下面那两个循环原来只收图片地址（视频页收的是它的封面），于是多图帖里的视频页
     * 到原生侧就完全"消失"了 —— 界面把它当图片显示、也不会播。这里给每一页都记一条
     * `mediaItems`：img（图或视频封面）+ vid（视频页才有）+ **这一页自己的宽高**。
     */
    const mediaItems: Array<FeedMediaItemDto> = [];
    if (carousel.length > 0) {
      for (let index: number = 0; index < carousel.length && index < 10; index++) {
        const child: IgMedia = carousel[index];
        const picked: PickedImage = NativeTimelineParser.pickImage(child.image_versions2);
        const original: PickedImage = NativeTimelineParser.pickImage(child.image_versions2, true);
        const childVideo: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(child);
        const childBest: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(child, true);
        if (picked.url.length > 0) {
          images.push(picked.url);
          originalImages.push(original.url.length > 0 ? original.url : picked.url);
          if (imageW === 0) {
            imageW = picked.width;
            imageH = picked.height;
          }
        }
        if (video.length === 0 && childVideo !== undefined) {
          video = childVideo.url ?? '';
          videoW = childVideo.width ?? 0;
          videoH = childVideo.height ?? 0;
          originalVideo = childBest !== undefined ? (childBest.url ?? '') : '';
        }
        // 这一页的宽高：视频页用**视频自身**的尺寸（图片给的是封面尺寸，拿它排版会把视频页压扁）。
        const vidUrl: string = childVideo !== undefined ? (childVideo.url ?? '') : '';
        mediaItems.push({
          img: picked.url,
          vid: vidUrl,
          w: vidUrl.length > 0 ? (childVideo?.width ?? 0) : picked.width,
          h: vidUrl.length > 0 ? (childVideo?.height ?? 0) : picked.height,
          orig: original.url.length > 0 ? original.url : picked.url,
          origVid: childBest !== undefined ? (childBest.url ?? '') : ''
        });
      }
    } else {
      const picked: PickedImage = NativeTimelineParser.pickImage(media.image_versions2);
      const original: PickedImage = NativeTimelineParser.pickImage(media.image_versions2, true);
      if (picked.url.length > 0) {
        images.push(picked.url);
        originalImages.push(original.url.length > 0 ? original.url : picked.url);
        imageW = picked.width;
        imageH = picked.height;
        thumb = NativeTimelineParser.pickImage(media.image_versions2, false, true).url;
      }
      const version: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(media);
      if (version !== undefined) {
        video = version.url ?? '';
        videoW = version.width ?? 0;
        videoH = version.height ?? 0;
      }
      const best: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(media, true);
      if (best !== undefined) {
        originalVideo = best.url ?? '';
      }
      const singleVid: string = version !== undefined ? (version.url ?? '') : '';
      mediaItems.push({
        img: picked.url,
        vid: singleVid,
        w: singleVid.length > 0 ? (version?.width ?? 0) : picked.width,
        h: singleVid.length > 0 ? (version?.height ?? 0) : picked.height,
        orig: original.url.length > 0 ? original.url : picked.url,
        origVid: best !== undefined ? (best.url ?? '') : ''
      });
    }
    // 帖子的 original_width/height 才是这条媒体的真实比例，优先用它；没有才退回图片/视频尺寸。
    let width: number = media.original_width ?? 0;
    let height: number = media.original_height ?? 0;
    if (width <= 0 || height <= 0) {
      width = imageW;
      height = imageH;
    }
    if (width <= 0 || height <= 0) {
      width = videoW;
      height = videoH;
    }
    const code: string = (media.code ?? '').trim();
    const mediaType: number = media.media_type ?? 1;
    const kind: string = (mediaType === 2 || video.length > 0) ? 'reel' : 'p';
    const user: IgUser = media.user ?? {};
    const caption: IgCaption = media.caption ?? {};
    // 作者 id：`pk` 优先（GraphQL 都用它），退回 `id`；数字要转成字符串。
    const rawId: string | number | null | undefined = user.pk ?? user.id ?? '';
    const friend: IgFriendship = user.friendship_status ?? {};
    const item: FeedItemDto = {
      id: (media.id ?? code).trim(),
      shortcode: code,
      username: (user.username ?? '').trim(),
      avatar: (user.profile_pic_url ?? '').trim(),
      caption: caption.text ?? '',
      images: images,
      videoUrl: video,
      poster: images.length > 0 ? images[0] : '',
      permalink: code.length > 0 ? `https://www.instagram.com/${kind}/${code}/` : '',
      likes: media.like_count ?? 0,
      comments: media.comment_count ?? 0,
      views: media.view_count ?? media.play_count ?? media.ig_play_count ?? 0,
      liked: media.has_liked === true,
      takenAt: (media.taken_at ?? 0) * 1000,
      w: width,
      h: height,
      // 逐页媒体（含视频页）+ 多图帖"最高的那一页"的比例（见 FeedItemDto.mediaItems/aspectMin）。
      mediaItems: mediaItems,
      aspectMin: NativeTimelineParser.aspectMinOf(mediaItems)
    };
    if (thumb.length > 0) {
      item.thumb = thumb;
    }
    // 关注按钮要用作者 id（关注/取关接口的路径参数）；没有就不下发，按钮那侧自然不显示。
    const userId: string = `${rawId}`.trim();
    if (userId.length > 0 && userId !== 'null' && userId !== 'undefined') {
      item.userId = userId;
    }
    if (friend.following !== undefined && friend.following !== null) {
      item.following = friend.following === true;
    }
    // 下载用的原始地址（最大的一档）：展示用的那份已经降级过了。
    if (originalImages.length > 0) {
      item.originalImages = originalImages;
    }
    if (originalVideo.length > 0) {
      item.originalVideo = originalVideo;
    }
    // 转发/分享计数：网页界面不渲染它们，只能按字段名在节点里找（和页面脚本同一套判据）。
    // 字段名不确定，所以**按候选名依次取第一个有值的**（见 IgMedia 上那段说明）——
    // 只认 repost_count 一个名字的话，接口换个叫法（media_repost_count 之类）就永远读不到，
    // 表现就是"转发数量没有显示"。
    const repost: number = NativeTimelineParser.firstCount([
      media.repost_count, media.media_repost_count, media.reposts_count,
      media.reshare_count, media.reshares_count
    ]);
    const share: number = NativeTimelineParser.firstCount([
      media.share_count, media.shares_count, media.media_share_count
    ]);
    if (repost > 0) {
      item.reposts = repost;
    }
    if (share > 0) {
      item.shares = share;
    }
    return item;
  }

  /** 取第一个正的计数（字符串数字也认，字段名不定时用；都不认就 0）。 */
  private static firstCount(values: Array<number | string | null | undefined>): number {
    for (let index: number = 0; index < values.length; index++) {
      const raw: number | string | null | undefined = values[index];
      let value: number = 0;
      if (typeof raw === 'number') {
        value = raw;
      } else if (typeof raw === 'string') {
        // "1,234" / "1.2K" 这种格式化过的值也认（少见，但真出现过）。
        const text: string = raw.replace(/,/g, '').trim();
        const match: RegExpMatchArray | null = text.match(/^([0-9]+(?:\.[0-9]+)?)([KkMmBb])?$/);
        if (match !== null) {
          value = Number(match[1]);
          const unit: string = (match[2] ?? '').toLowerCase();
          if (unit === 'k') {
            value = value * 1000;
          } else if (unit === 'm') {
            value = value * 1000000;
          } else if (unit === 'b') {
            value = value * 1000000000;
          }
        }
      }
      if (value > 0) {
        return Math.round(value);
      }
    }
    return 0;
  }

  /**
   * 图片候选 → 一张图。
   *
   * @param original true = 取最大的一档（下载用）；false = 按 core/MediaQuality 降到 1080 档（展示用）。
   */
  private static pickImage(versions: IgImageVersions | null | undefined,
                           original: boolean = false,
                           thumb: boolean = false): PickedImage {
    const empty: PickedImage = new PickedImage('', 0, 0);
    if (versions === null || versions === undefined) {
      return empty;
    }
    const candidates: Array<IgCandidate> = versions.candidates ?? [];
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const url: string = (candidates[index].url ?? '').trim();
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(candidates[index].width ?? 0);
      heights.push(candidates[index].height ?? 0);
    }
    const profile: QualityProfile | null = NativeTimelineParser.parsingProfile;
    const picked: PickedMedia = original
      ? MediaQuality.originalImage(urls, widths, heights)
      : thumb
        ? (profile === null
          ? MediaQuality.displayImageAt(urls, widths, heights, THUMB_WIDTH)
          : MediaQuality.imageAtWith(profile, urls, widths, heights, THUMB_WIDTH))
        : (profile === null
          ? MediaQuality.displayImage(urls, widths, heights)
          : MediaQuality.imageWith(profile, urls, widths, heights));
    return new PickedImage(picked.url, picked.width, picked.height);
  }

  /** 视频候选 → 一档；original=true 取最大的一档（下载），false 取 1080 档（展示）。 */
  private static pickVideo(media: IgMedia, original: boolean = false): IgVideoVersion | undefined {
    const versions: Array<IgVideoVersion> = media.video_versions ?? [];
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < versions.length; index++) {
      const url: string = (versions[index].url ?? '').trim();
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(versions[index].width ?? 0);
      heights.push(versions[index].height ?? 0);
    }
    const profile: QualityProfile | null = NativeTimelineParser.parsingProfile;
    const picked: PickedMedia = original
      ? MediaQuality.originalVideo(urls, widths, heights)
      : (profile === null
        ? MediaQuality.displayVideo(urls, widths, heights)
        : MediaQuality.videoWith(profile, urls, widths, heights));
    if (picked.url.length === 0) {
      return undefined;
    }
    const hit: IgVideoVersion = { url: picked.url, width: picked.width, height: picked.height };
    return hit;
  }
}
