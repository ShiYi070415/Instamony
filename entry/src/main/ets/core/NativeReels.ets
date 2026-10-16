/*
 * 原生直接要 Reels（不经过网页）——和首页信息流那套（core/NativeFeed）同一条路数。
 *
 * 为什么值得做：reels 原来必须"打开 /reels/ 页面 → 等它自己发 Clips 请求 → 存模板 → 回放"，
 * 换页时也是回放发请求；现在有了落盘模板 + Cookie 罐，可以直接 POST，于是：
 *   1) 冷启动预热（app 一起来就发，见 warmStart）→ 切到 Reels 时已有数据；
 *   2) 翻页提前缓存（见 ReelsViewModel 的队列）→ 上滑切换不再等网络。
 *
 * 解析结构与页面脚本 reelsScript 保持一致：
 *   `.data.xdt_api__v1__clips__home__connection_v2.edges[].node.media`
 *   （视频 video_versions[].url、封面 image_versions2.candidates[]、作者 media.user、
 *    音乐 clips_metadata.original_sound_info）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Reel } from '../model/Reel';
import { NativeFeed, NativeFetchResult } from './NativeFeed';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { ApiThrottle } from './ApiThrottle';
import { JsonRead } from './JsonRead';
import { MobileDiscover, MobileMediaPage } from './mobileapi/MobileDiscover';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeReels';
/** 模板按这个名字片段找（ApiRegistry 里存的就是它）。 */
const REELS_OP: string = 'ClipsTabRoot';
/** Clips 连接键。 */
const CLIPS_KEY: string = 'xdt_api__v1__clips__home__connection_v2';

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

/** 作者的关注状态（Reels 页那颗按钮按 `following` 画）。 */
interface IgFriendship {
  following?: boolean | null;
  followed_by_viewer?: boolean | null;
}

interface IgUser {
  username?: string | null;
  profile_pic_url?: string | null;
  is_verified?: boolean | null;
  /** 作者的数字 id（Reels 页那颗关注按钮要用，见 Reel.authorId）。 */
  pk?: string | number | null;
  id?: string | number | null;
  /** 本机关注他/她了没有（真机上挂在 user 上，见 NativeTimelineParser 同名结构）。 */
  friendship_status?: IgFriendship | null;
}

interface IgCaption {
  text?: string | null;
}

interface IgSoundInfo {
  original_audio_title?: string | null;
}

interface IgClipsMetadata {
  original_sound_info?: IgSoundInfo | null;
}

interface IgClipsMedia {
  code?: string | null;
  /** 媒体数字 id（cliploader 与点赞/转发都要它，见 Reel.mediaId）。 */
  pk?: string | number | null;
  id?: string | number | null;
  original_width?: number | null;
  original_height?: number | null;
  video_versions?: Array<IgVideoVersion> | null;
  image_versions2?: IgImageVersions | null;
  user?: IgUser | null;
  caption?: IgCaption | null;
  clips_metadata?: IgClipsMetadata | null;
  like_count?: number | null;
  comment_count?: number | null;
  play_count?: number | null;
  ig_play_count?: number | null;
  /** 转发数（右侧动作区那颗转发下面的数字）。 */
  media_repost_count?: number | null;
  /** 本机点过赞没有（Reels 页右侧那颗心按它画）。 */
  has_liked?: boolean | null;
  viewer_has_liked?: boolean | null;
  /** 本机收藏了没有（真机上这条 clips 查询一般不给，见 Reel.saved / core/SaveState）。 */
  has_saved?: boolean | null;
  viewer_has_saved?: boolean | null;
}

interface IgClipsNode {
  media?: IgClipsMedia | null;
}

interface IgClipsEdge {
  node?: IgClipsNode | null;
}

interface IgClipsPageInfo {
  end_cursor?: string | null;
  has_next_page?: boolean | null;
}

interface IgClipsConnection {
  edges?: Array<IgClipsEdge> | null;
  page_info?: IgClipsPageInfo | null;
}

interface IgClipsResponse {
  data?: Record<string, IgClipsConnection> | null;
}

/** 原生取好的一页 reels。 */
export class NativeReelsPage {
  readonly reels: Array<Reel>;
  readonly nextCursor: string;
  readonly hasMore: boolean;
  readonly ms: number;
  readonly at: number;

  constructor(reels: Array<Reel>, nextCursor: string, hasMore: boolean, ms: number) {
    this.reels = reels;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    this.ms = ms;
    this.at = Date.now();
  }
}

export class NativeReels {
  /** 启动预热的那一页（见 warmStart）。 */
  private static warmPage: NativeReelsPage | null = null;
  private static warming: boolean = false;
  /** "作者对象里没有 id"那条诊断只打一次（见 toReel）。 */
  private static uidDiagDone: boolean = false;
  /** "载荷里有没有关注状态"那条诊断只打一次（见 toReel）。 */
  private static followDiagDone: boolean = false;
  /** "载荷里有没有收藏状态"那条诊断只打一次（见 toReel）。 */
  private static saveDiagDone: boolean = false;
  /**
   * 这一轮的 reels 是不是**移动端探索流**给的（见 viaExplore）。
   *
   * 记它的唯一原因：两种路的游标互不通用，翻页必须回到"给游标的那条路"，
   * 否则第二页要么空、要么被当成第一页反复请求。
   */
  private static exploreUsable: boolean = false;

  /**
   * app 启动时就发一发 reels 第一页，结果留在内存里等 Reels 页来取（幂等）。
   *
   * 和信息流那条一样的道理：切到 Reels 时多半已经有数据，用户看到的是"秒出"。
   */
  static warmStart(first: number): void {
    if (NativeReels.warming || NativeReels.warmPage !== null) {
      return;
    }
    NativeReels.warming = true;
    const started: number = Date.now();
    NativeReels.fetchPage(first, '').then((page: NativeReelsPage | null): void => {
      NativeReels.warming = false;
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'warmStart miss after %{public}dms', Date.now() - started);
        return;
      }
      NativeReels.warmPage = page;
      hilog.info(DOMAIN, TAG, 'warmStart ready n=%{public}d ms=%{public}d (since launch %{public}d)',
        page.reels.length, page.ms, Date.now() - started);
    }).catch((): void => {
      NativeReels.warming = false;
    });
  }

  /** 取走预热的那一页（取走即清空；太旧的不要）。 */
  static takeWarm(maxAgeMs: number): NativeReelsPage | null {
    const page: NativeReelsPage | null = NativeReels.warmPage;
    if (page === null) {
      return null;
    }
    NativeReels.warmPage = null;
    if (Date.now() - page.at > maxAgeMs) {
      hilog.info(DOMAIN, TAG, 'warm page discarded age=%{public}dms', Date.now() - page.at);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'warm page used age=%{public}dms n=%{public}d',
      Date.now() - page.at, page.reels.length);
    return page;
  }

  /**
   * 要一页 reels 并解析好。失败一律 null（没模板 / 没登录 / HTTP 非 200 / 解析不出条目）。
   */
  static async fetchPage(first: number, cursor: string): Promise<NativeReelsPage | null> {
    /*
     * **被限流期间**（见 core/ApiThrottle）：GraphQL 那条一发都不打，但**移动端探索流还能顶**
     * （`discover/topical_explore/` 给的也是 clips 媒体，带 `video_versions`，可直接播）。
     *
     * 为什么要这条兜底：真机日志里 clips 那条被 IG 直接回
     * `{"errors":[{"message":"Rate limit exceeded","code":1675004}]}`（12 分钟冷却）——
     * 这段时间用户点进视频标签原来是"什么都没有"。换一条端点虽然个性化差一点，
     * 但**有内容**远好过空着。
     */
    if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
      const viaExplore: NativeReelsPage | null = await NativeReels.viaExplore(cursor);
      if (viaExplore !== null) {
        return viaExplore;
      }
      hilog.info(DOMAIN, TAG, 'reels skipped: rate limited, %{public}dmin left (no explore fallback)',
        ApiThrottle.remainingMinutes(ApiThrottle.CLIPS));
      return null;
    }
    let result: NativeFetchResult = await NativeFeed.firstPage(first, cursor, REELS_OP, CLIPS_KEY);
    // 限流要**当场认出来并记账**：不认的话下面会"原样重发一次"，等于又打一发。
    if (ApiThrottle.looksLimited(result.body)) {
      ApiThrottle.note(ApiThrottle.CLIPS);
      /*
       * 把**响应的开头**打出来。为什么必须打：这条判定会直接封掉 reels + 搜索推荐 12 分钟，
       * 而真机上曾经因为"响应里恰好出现了 rate limit 几个字"（其实是别的东西）误判过一次
       * —— 没有 body 就只能靠猜（见 core/ApiThrottle.looksLimited 收紧后的判据）。
       */
      hilog.warn(DOMAIN, TAG, 'reels rate limited → back off %{public}dmin body=%{public}s',
        ApiThrottle.remainingMinutes(ApiThrottle.CLIPS),
        result.body.substring(0, 160).replace(/[\r\n]+/g, ' '));
      const viaExplore: NativeReelsPage | null = await NativeReels.viaExplore(cursor);
      return viaExplore;
    }
    let parsed: NativeReelsPage | null = result.ok ? NativeReels.parse(result.body, result.ms) : null;
    if (parsed === null && cursor.length === 0) {
      // **原样重发一次**：实测 Clips 这条接口对我们改写过的 variables 会回 HTML（200 + 63KB
      // 的整页文档），而页面里用同一份模板回放却是好的 —— 差别就在"我们动了 variables"。
      // 首屏不挑条数（下面按服务端给多少算多少），所以这里退回"原样发模板"最稳；
      // 翻页（cursor 非空）必须带 after，没法原样发，就只走上面那一次。
      hilog.info(DOMAIN, TAG, 'native reels retry with raw template (first attempt body=%{public}s)',
        result.body.substring(0, 120).replace(/[\r\n]+/g, ' '));
      result = await NativeFeed.firstPage(0, '', REELS_OP, CLIPS_KEY);
      if (ApiThrottle.looksLimited(result.body)) {
        ApiThrottle.note(ApiThrottle.CLIPS);
        hilog.warn(DOMAIN, TAG, 'reels rate limited on retry → back off %{public}dmin body=%{public}s',
          ApiThrottle.remainingMinutes(ApiThrottle.CLIPS),
          result.body.substring(0, 160).replace(/[\r\n]+/g, ' '));
        return await NativeReels.viaExplore(cursor);
      }
      parsed = result.ok ? NativeReels.parse(result.body, result.ms) : null;
    }
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, 'native reels unparsable ok=%{public}s bytes=%{public}d diag=%{public}s',
        result.ok ? 'y' : 'n', result.bytes, NativeReels.diagnose(result.body));
    }
    return parsed;
  }

  /**
   * **移动端探索流兜底**：clips 那条 GraphQL 被 IG 限流 / 不可用时，用
   * `discover/topical_explore/`（见 core/mobileapi/MobileDiscover）里的 clips 媒体顶上。
   *
   * 为什么行得通：探索流那份 `sectional_items[].layout_content.medias[].media` 就是**媒体对象**
   * （`code` / `pk` / `video_versions` / `image_versions2` / `user` / `like_count`…），
   * 与 clips 那条同形状，所以直接喂给 `toReel` 即可（它本来就只认这几个键）。
   *
   * 代价说清楚：那是"推荐/探索"的排序，不是 Reels 标签那套个性化排序；封面/音乐字段也可能稀疏
   * （探索流不一定给 `clips_metadata`）。所以这条路**只在主路不可用时**走，
   * 而且游标与主路不通用 —— 第一页从哪条来的，翻页就继续走哪条（见 exploreUsable）。
   */
  private static async viaExplore(cursor: string): Promise<NativeReelsPage | null> {
    if (cursor.length > 0 && !NativeReels.exploreUsable) {
      return null;
    }
    const page: MobileMediaPage | null = await MobileDiscover.explore(cursor, ApiThrottle.interactive());
    if (page === null) {
      if (cursor.length === 0) {
        NativeReels.exploreUsable = false;
      }
      hilog.info(DOMAIN, TAG, 'explore fallback miss cursor=%{public}d', cursor.length);
      return null;
    }
    const reels: Array<Reel> = [];
    for (let index: number = 0; index < page.medias.length; index++) {
      const media: Record<string, Object> | null = JsonRead.asRecord(page.medias[index]);
      if (media === null) {
        continue;
      }
      // 只收有视频的（探索流里也夹着图片帖）：`toReel` 自己会剔除，这里不用重复判。
      const reel: Reel | null = NativeReels.toReel(media as IgClipsMedia);
      if (reel !== null) {
        reels.push(reel);
      }
    }
    if (reels.length === 0) {
      hilog.info(DOMAIN, TAG, 'explore fallback: medias=%{public}d but no playable reel',
        page.medias.length);
      return null;
    }
    NativeReels.exploreUsable = true;
    hilog.info(DOMAIN, TAG,
      'reels via mobile explore n=%{public}d medias=%{public}d more=%{public}s ms=%{public}d',
      reels.length, page.medias.length, `${page.hasMore}`, page.ms);
    return new NativeReelsPage(reels, page.nextCursor, page.hasMore, page.ms);
  }

  /**
   * 解析不出来时打一行现场：`data` 里到底有哪几个连接键、有没有 errors。
   *
   * 为什么需要：HTTP 200 + 几十 KB 但拿不到 clips 连接的情况，"是哪一页的数据"光看状态码
   * 完全看不出来（实测就是这样：200、63KB、conn=n）—— 必须看键名才知道模板是不是抓错了。
   */
  static diagnose(body: string): string {
    try {
      const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const data: Object | undefined = root['data'] as Object | undefined;
      const keys: Array<string> = data === undefined || data === null
        ? [] : Object.keys(data as Record<string, Object>);
      let err: string = '';
      const errors: Object | undefined = root['errors'] as Object | undefined;
      if (errors !== undefined && errors !== null) {
        err = JSON.stringify(errors).substring(0, 120);
      }
      return `data=[${keys.slice(0, 6).join('|')}] err=${err}`;
    } catch (error) {
      return `not-json head=${body.substring(0, 80)}`;
    }
  }

  /** 整包响应 → 一页 Reels（字段映射与页面脚本 reelsScript 一致）。 */
  static parse(body: string, ms: number): NativeReelsPage | null {
    if (body.length === 0 || body.indexOf(CLIPS_KEY) < 0) {
      return null;
    }
    let response: IgClipsResponse;
    try {
      response = JSON.parse(body) as IgClipsResponse;
    } catch (error) {
      return null;
    }
    const data: Record<string, IgClipsConnection> | null = response.data ?? null;
    if (data === null) {
      return null;
    }
    const conn: IgClipsConnection | null = data[CLIPS_KEY] ?? null;
    if (conn === null) {
      return null;
    }
    const edges: Array<IgClipsEdge> = conn.edges ?? [];
    const reels: Array<Reel> = [];
    for (let index: number = 0; index < edges.length; index++) {
      const node: IgClipsNode | null = edges[index].node ?? null;
      if (node === null) {
        continue;
      }
      const media: IgClipsMedia | null = node.media ?? null;
      if (media === null) {
        continue;
      }
      const reel: Reel | null = NativeReels.toReel(media);
      if (reel !== null) {
        reels.push(reel);
      }
    }
    if (reels.length === 0) {
      return null;
    }
    const info: IgClipsPageInfo = conn.page_info ?? {};
    const cursor: string = (info.end_cursor ?? '').trim();
    return new NativeReelsPage(reels, cursor, info.has_next_page === true, ms);
  }

  private static toReel(media: IgClipsMedia): Reel | null {
    const code: string = (media.code ?? '').trim();
    if (code.length === 0) {
      return null;
    }
    // 视频/封面各取两份：展示用按 core/MediaQuality 降到 1080 档（省流量），
    // 下载用的原视频取最大的一档（见 Reel.originalVideoUrl）。
    const picked: PickedMedia = NativeReels.pickVideo(media, false);
    const original: PickedMedia = NativeReels.pickVideo(media, true);
    const video: string = picked.url;
    // 只收有视频地址的：reels 流的本职就是播视频。
    if (video.length === 0) {
      return null;
    }
    const cover: string = NativeReels.pickCover(media, false);
    const user: IgUser = media.user ?? {};
    const metadata: IgClipsMetadata = media.clips_metadata ?? {};
    const sound: IgSoundInfo = metadata.original_sound_info ?? {};
    const mediaId: string = `${media.pk ?? media.id ?? ''}`.trim();
    let authorId: string = `${user.pk ?? user.id ?? ''}`.trim();
    if (authorId.length === 0) {
      // 二次来源：媒体 id 常是 `<媒体id>_<作者id>` 的组合（信息流那条就是，见 NativeEngage.mediaIdOf）——
      // 作者对象里没有 pk 时，从这儿把作者 id 拆出来（Reels 页那颗关注按钮要用）。
      const cut: number = mediaId.indexOf('_');
      if (cut > 0 && cut < mediaId.length - 1) {
        authorId = mediaId.substring(cut + 1);
      }
    }
    if (authorId.length === 0 && !NativeReels.uidDiagDone) {
      // 只打一次：这条 clips 响应的 user 对象里到底有没有作者 id，看这行的键名就知道
      // （没有的话只能靠 mediaId 的组合串，或者干脆不显示关注按钮）。
      NativeReels.uidDiagDone = true;
      hilog.info(DOMAIN, TAG, 'clips user has no id keys=%{public}s mediaId=%{public}s',
        Object.keys(user).slice(0, 14).join(','), mediaId);
    }
    const caption: string = (media.caption ?? {}).text ?? '';
    const liked: boolean = media.has_liked === true || media.viewer_has_liked === true;
    /*
     * 收藏状态：载荷给了就带上（`has_saved` / `viewer_has_saved`）。
     *
     * 真机上这条 clips 查询**大概率不给**（和"不给作者头像"同一类稀疏，见 core/NativeProfile）——
     * 所以这里只做"有就收"，没有就默认 false，之后以 core/SaveState 的会话覆盖表为准
     * （见 components/ReelsPage 的信息层）。诊断只打一次，方便以后确认 IG 到底给没给。
     */
    const savedKnown: boolean = media.has_saved !== undefined && media.has_saved !== null
      || media.viewer_has_saved !== undefined && media.viewer_has_saved !== null;
    const saved: boolean = media.has_saved === true || media.viewer_has_saved === true;
    if (!NativeReels.saveDiagDone) {
      NativeReels.saveDiagDone = true;
      hilog.info(DOMAIN, TAG, 'clips save known=%{public}s saved=%{public}s mediaKeys=%{public}s',
        `${savedKnown}`, `${saved}`,
        Object.keys(media as Record<string, Object>).slice(0, 18).join(','));
    }
    /*
     * 关注状态：载荷里给了就带上（`user.friendship_status.following`，真机上和信息流那份
     * 同名同形）。**没给**时 `followKnown` 留 false，界面会自己用
     * `friendships/show_many` 问一次（见 NativeFollow.statesFor）—— 用户报的
     * "reels 关注按钮状态没正确显示"就是这里以前压根没带状态、只信本地覆盖表。
     */
    const friend: IgFriendship | null = user.friendship_status ?? null;
    const followKnown: boolean = friend !== null
      && (friend.following !== undefined && friend.following !== null
        || friend.followed_by_viewer !== undefined && friend.followed_by_viewer !== null);
    const following: boolean = friend !== null
      && (friend.following === true || friend.followed_by_viewer === true);
    if (!NativeReels.followDiagDone) {
      NativeReels.followDiagDone = true;
      hilog.info(DOMAIN, TAG, 'clips follow known=%{public}s following=%{public}s userKeys=%{public}s',
        `${followKnown}`, `${following}`, Object.keys(user).slice(0, 16).join(','));
    }
    return new Reel(code, video, cover,
      media.original_width ?? 0, media.original_height ?? 0,
      (user.username ?? '').trim(), (user.profile_pic_url ?? '').trim(),
      user.is_verified === true, (sound.original_audio_title ?? '').trim(),
      media.like_count ?? 0, media.comment_count ?? 0, original.url,
      mediaId, authorId, caption, liked, false, media.media_repost_count ?? 0,
      following, followKnown, saved);
  }

  /** 视频候选 → 一档（original=false 取 1080 档给播放，true 取最大档给下载）。 */
  private static pickVideo(media: IgClipsMedia, original: boolean): PickedMedia {
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
    return original
      ? MediaQuality.originalVideo(urls, widths, heights)
      : MediaQuality.displayVideo(urls, widths, heights);
  }

  /** 封面候选 → 一张（展示用的那张会降到 1080 档）。 */
  private static pickCover(media: IgClipsMedia, original: boolean): string {
    const candidates: Array<IgCandidate> = (media.image_versions2 ?? {}).candidates ?? [];
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
    const picked: PickedMedia = original
      ? MediaQuality.originalImage(urls, widths, heights)
      : MediaQuality.displayImage(urls, widths, heights);
    return picked.url;
  }
}
