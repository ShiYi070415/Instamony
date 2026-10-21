/*
 * 原生直接要 Reels（不经过网页、也不回放模板）——与 instagrapi 的 explore_reels 同一套 App 身份。
 *
 * 历史说明：reels 原来必须"打开 /reels/ 页面 → 等它自己发 Clips 请求 → 存模板 → 回放"，
 * 现在模板机制已随页面注入一起退役（`NETWORK_WATCHER` 不再注入），
 * 数据只来自移动端 `clips/discover/`（主路）与 `discover/topical_explore/`（用户驱动时的兜底）。
 *
 * 解析结构：移动端 v1 媒体对象（`items[].media` / `paging_info`），
 * 视频 video_versions[].url、封面 image_versions2.candidates[]、作者 media.user、
 * 音乐 clips_metadata.original_sound_info —— 与 instagrapi 的 Media 字段同源。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Reel } from '../model/Reel';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { ApiThrottle } from './ApiThrottle';
import { JsonRead } from './JsonRead';
import { MobileDiscover, MobileMediaPage } from './mobileapi/MobileDiscover';
// Reels 的移动端通道（对应 instagrapi 的 reels / explore_reels，不需要网页模板）。
import { MobileClips } from './mobileapi/MobileClips';
// 主页 Reels 分页（`clips/user/{pk}/`）—— 补货池用它，见 fetchAuthorPage。
import { MobileProfile, MobileGridPage } from './mobileapi/MobileProfile';
import { EngageState } from './NativeEngage';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeReels';

/** 补货时一个作者要几条（`clips/user/` 的 `page_size`；他有多少给多少，最多这么多）。 */
const AUTHOR_PAGE_COUNT: number = 12;

/** Clips 连接键（只给历史解析函数用，数据获取已不走它）。 */
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
  /** 字符串形式的媒体 id（19 位数字的精确形式，见 mediaId 的说明）。 */
  strong_id__?: string | null;
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
   * **这一页是从哪条路来的**（`explore` / `connected` / `clips` / `author` / `-`）。
   *
   * 翻页时用得上：只有探索流的 `max_id` 真的能换页（真机实测，见 core/mobileapi/MobileClips
   * 文件头那张表），另外几条的游标换了也没新内容，所以**不能拿它们的游标去翻页**。
   */
  private static lastSource: string = '-';
  /**
   * **补货池**：流里见过的作者（按出现顺序消费）。
   *
   * 为什么需要它：能翻页的探索流是图文混排，实测 8 条里只有 1~3 条是视频（500KB / 5 秒），
   * 光靠它撑不住"一直往下刷"。而 `clips/user/{pk}/`（主页 Reels 那一发，见 MobileProfile.tab）
   * 是**该用户的全部 Reels**：100% 是视频、几十 KB、一两秒。
   * 所以每翻一页探索流，就从池子里取一个作者补一页真视频，两条交替，密度和速度都够。
   */
  private static authors: Array<string> = [];
  /** 作者 id → 该作者的下一页游标（不在表里 = 还没取过；值为空串 = 已到底，不再要）。 */
  private static authorCursors: Map<string, string> = new Map<string, string>();
  /** 已经进过池子的作者（防重复）。 */
  private static authorSeen: Set<string> = new Set<string>();
  /** 池子最多排多少人（够刷很久了，池子本身会跟着探索流一直长大）。 */
  private static readonly AUTHOR_POOL_MAX: number = 40;
  /** "作者那页解析不出 Reel"那条诊断只打一次（见 fetchAuthorPage）。 */
  private static authorDiagDone: boolean = false;

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
   * **关注流那一发**（`clips/connected/`）：首屏暖场。
   *
   * 5 条、几十 KB、很快，但**没有 `paging_info`**（游标为空），所以它只负责"一进视频页就有东西播"，
   * 翻页由探索流接管（见 fetchPage）。
   */
  private static async viaConnected(cursor: string): Promise<NativeReelsPage | null> {
    const started: number = Date.now();
    const body: string | null = await MobileClips.connected(cursor);
    if (body === null) {
      return null;
    }
    const page: NativeReelsPage | null = NativeReels.parseMobile(body, Date.now() - started);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'connected unparsable bytes=%{public}d', body.length);
      return null;
    }
    NativeReels.lastSource = 'connected';
    NativeReels.noteAuthors(page.reels);
    hilog.info(DOMAIN, TAG, 'reels via connected n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      page.reels.length, `${page.hasMore}`, page.nextCursor.length, page.ms);
    return page;
  }

  /**
   * `clips/discover/` 那一发（**只当兜底**）。
   *
   * 真机上它每页都回同样 4 条、游标换不动（见 core/mobileapi/MobileClips 文件头），
   * 所以只在"探索流 + 关注流都挂了"时用它，至少还有 4 条能播。
   */
  private static async viaClips(cursor: string): Promise<NativeReelsPage | null> {
    const started: number = Date.now();
    const body: string | null = await MobileClips.discover(cursor);
    if (body === null) {
      return null;
    }
    const page: NativeReelsPage | null = NativeReels.parseMobile(body, Date.now() - started);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'clips unparsable bytes=%{public}d diag=%{public}s',
        body.length, NativeReels.diagnose(body));
      return null;
    }
    NativeReels.lastSource = 'clips';
    NativeReels.noteAuthors(page.reels);
    hilog.info(DOMAIN, TAG, 'reels via clips n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      page.reels.length, `${page.hasMore}`, page.nextCursor.length, page.ms);
    return page;
  }

  /** 补货池里还有几个作者（视图模型用它决定"这一发要不要补货"）。 */
  static authorPoolSize(): number {
    return NativeReels.authors.length;
  }

  /**
   * **补货**：从池子里取一个作者，要他那页 Reels（`clips/user/{pk}/`）。
   *
   * 为什么是这条路：探索流实测 8 条里只有 1~3 条是视频（500KB / 5 秒），单靠它刷不动；
   * 而一个作者那页是**清一色视频**、几十 KB、一两秒（主页 Reels 分页同一条，已真机验证）。
   *
   * 返回的那一页 **`nextCursor` 是空串**：它推进不了探索流的游标，视图模型那边看到空游标
   * 就知道"这条不是分页用的，别拿它覆盖探索流游标"（见 ReelsViewModel.applyNativePage）。
   * 作者自己还有下一页时，他被重新排到队尾（游标记在 authorCursors 里）。
   *
   * 一个作者给不出东西（私密/零 Reels/被限流）就换下一个，最多试两个 —— 不在这儿死磕。
   */
  static async fetchAuthorPage(): Promise<NativeReelsPage | null> {
    let tries: number = 0;
    while (NativeReels.authors.length > 0 && tries < 2) {
      const pk: string | undefined = NativeReels.authors.shift();
      if (pk === undefined || pk.length === 0) {
        continue;
      }
      const cursor: string = NativeReels.authorCursors.get(pk) ?? '';
      const started: number = Date.now();
      const grid: MobileGridPage | null = await MobileProfile.tab('clips', pk, cursor,
        AUTHOR_PAGE_COUNT, ApiThrottle.interactive());
      tries++;
      if (grid === null) {
        // 这个作者这一发没成：不放回池子（别在一个人身上反复失败），试下一个。
        NativeReels.authorCursors.delete(pk);
        continue;
      }
      const reels: Array<Reel> = [];
      for (let index: number = 0; index < grid.items.length; index++) {
        let media: Record<string, Object> | null = JsonRead.asRecord(grid.items[index]);
        if (media === null) {
          continue;
        }
        /*
         * `clips/user/` 的条目是**包了一层**的 `{ "media": {…v1 媒体…} }`
         * （和探索流 `layout_content.medias[]` 一样），而 `parseMobile` 那些 `items[]` 是裸的。
         * 诊断现场就是 `items=12 keys=media` —— 不解包的话一条都认不出来。
         */
        const wrapped: Record<string, Object> | null = JsonRead.asRecord(media['media']);
        if (wrapped !== null) {
          media = wrapped;
        }
        const reel: Reel | null = NativeReels.toReel(media as IgClipsMedia);
        if (reel !== null) {
          reels.push(reel);
        }
      }
      if (reels.length === 0 && !NativeReels.authorDiagDone) {
        // 只打一次：这一页到底给了什么形状（`clips/user/` 的条目可能与 clips 流不同）。
        NativeReels.authorDiagDone = true;
        const first: Record<string, Object> | null = grid.items.length > 0
          ? JsonRead.asRecord(grid.items[0]) : null;
        hilog.info(DOMAIN, TAG, 'author page no reel: items=%{public}d keys=%{public}s',
          grid.items.length,
          first === null ? '-' : Object.keys(first).slice(0, 20).join(','));
      }
      if (grid.nextCursor.length > 0) {
        // 他还有更早的 Reels：记下游标，排到队尾，下次轮到他要下一页。
        NativeReels.authorCursors.set(pk, grid.nextCursor);
        NativeReels.authors.push(pk);
      } else {
        NativeReels.authorCursors.delete(pk);
      }
      if (reels.length === 0) {
        continue;
      }
      hilog.info(DOMAIN, TAG,
        'reels via author pk=%{public}s n=%{public}d items=%{public}d more=%{public}s ms=%{public}d',
        pk, reels.length, grid.items.length, grid.nextCursor.length > 0 ? 'y' : 'n',
        Date.now() - started);
      return new NativeReelsPage(reels, '', true, Date.now() - started);
    }
    return null;
  }

  /** 把一页里出现过的作者收进补货池（按出现顺序，去重，限量）。 */
  private static noteAuthors(reels: Array<Reel>): void {
    for (let index: number = 0; index < reels.length; index++) {
      const pk: string = reels[index].authorId;
      if (pk.length === 0 || NativeReels.authorSeen.has(pk)) {
        continue;
      }
      if (NativeReels.authors.length >= NativeReels.AUTHOR_POOL_MAX) {
        return;
      }
      NativeReels.authorSeen.add(pk);
      NativeReels.authors.push(pk);
    }
  }

  /**
   * 解析移动端 `clips/*` 的响应（`items[].media` + `paging_info`）。
   *
   * 与 `parse`（网页 GraphQL 那套 `data.<conn>.edges[].node.media`）是**两个形状**，
   * 所以单独一个函数，而不是硬塞进 `parse` 里判断。
   */
  static parseMobile(body: string, ms: number): NativeReelsPage | null {
    if (body.length === 0) {
      return null;
    }
    let root: Record<string, Object>;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      return null;
    }
    // `items_with_ads` 与 `items` 同形，二选一（都为空就是这一页没内容）。
    let items: Array<Object> = [];
    const plain: Object | undefined = root['items'];
    if (plain !== undefined && plain !== null && Array.isArray(plain)) {
      items = plain as Array<Object>;
    }
    if (items.length === 0) {
      const ads: Object | undefined = root['items_with_ads'];
      if (ads !== undefined && ads !== null && Array.isArray(ads)) {
        items = ads as Array<Object>;
      }
    }
    const reels: Array<Reel> = [];
    for (let index: number = 0; index < items.length; index++) {
      const item: Record<string, Object> | null = JsonRead.asRecord(items[index]);
      if (item === null) {
        continue;
      }
      const media: Record<string, Object> | null = JsonRead.asRecord(item['media']);
      if (media === null) {
        continue;
      }
      const reel: Reel | null = NativeReels.toReel(media as IgClipsMedia);
      if (reel !== null) {
        reels.push(reel);
      }
    }
    if (reels.length === 0) {
      return null;
    }
    let cursor: string = '';
    let more: boolean = false;
    const paging: Record<string, Object> | null = JsonRead.asRecord(root['paging_info']);
    if (paging !== null) {
      const maxId: string = `${paging['max_id'] ?? ''}`.trim();
      if (maxId.length > 0 && maxId !== 'null') {
        cursor = maxId;
      }
      more = paging['more_available'] === true;
    }
    return new NativeReelsPage(reels, cursor, more, ms);
  }

  /**
   * 要一页 reels 并解析好。失败一律 null（没登录 / 被限流 / HTTP 非 200 / 解析不出条目）。
   *
   * **只走移动端**（与 instagrapi 的 `explore_reels` 同一套 App 身份，不需要网页模板）。
   * 三条源的分工是**实测出来的**，不是猜的（见 core/mobileapi/MobileClips 文件头那张表）：
   *
   *   · 首屏（无游标）：探索流 `discover/topical_explore/` 为主 + `clips/connected/`（关注流）补在前面；
   *   · 翻页（有游标）：仍然只有探索流的 `max_id` 真的换页 —— 另外两条只是"再试一次"；
   *   · `clips/discover/` 从主路撤下来当兜底：它每页都回同样 4 条（用户报的
   *     "reels 无法获取新的视频"就是它）。
   *
   * @param userDriven 用户在看视频页吗（进 reels 页 / 上滑翻页 = true）。
   *
   *   · `true` = 允许拉**探索流**那一发（1MB 上下、5 秒）—— 它才是能翻页的主路；
   *   · `false`（默认）= 启动预热：只打 `clips/connected/`（几十 KB），
   *     没人看视频页时不该替用户拉一兆多（降噪，见 FINGERPRINT_ANALYSIS.md 阶段一）。
   */
  static async fetchPage(first: number, cursor: string,
                         userDriven: boolean = false): Promise<NativeReelsPage | null> {
    if (cursor.length > 0) {
      /*
       * **翻页**：只有探索流的游标真的换页。上一条源不是探索流时（关注流那 5 条、
       * `clips/discover/` 那 4 条都换不动），把这个游标丢掉，直接问探索流第一页 ——
       * 只有它能把"能翻页的游标"建起来（见文件头那张表）。
       */
      if (NativeReels.lastSource === 'explore') {
        const explorePage: NativeReelsPage | null = await NativeReels.viaExplore(cursor);
        if (explorePage !== null) {
          return explorePage;
        }
      }
      const boot: NativeReelsPage | null = await NativeReels.viaExplore('');
      if (boot !== null) {
        return boot;
      }
      const connected: NativeReelsPage | null = await NativeReels.viaConnected(cursor);
      if (connected !== null) {
        return connected;
      }
      const clips: NativeReelsPage | null = await NativeReels.viaClips(cursor);
      if (clips !== null) {
        return clips;
      }
      hilog.info(DOMAIN, TAG, 'reels miss: all sources empty cursor=%{public}d limited=%{public}s',
        cursor.length, `${ApiThrottle.blocked(ApiThrottle.CLIPS)}`);
      return null;
    }
    if (!userDriven) {
      // 启动预热：只打小那一发（关注流）。
      const warm: NativeReelsPage | null = await NativeReels.viaConnected('');
      if (warm === null) {
        hilog.info(DOMAIN, TAG, 'warm miss: connected empty (explore skipped in background)');
      }
      return warm;
    }
    /*
     * 首屏（用户在看）：探索流为主 —— 它带**真游标**，翻页才有后面；
     * 关注流那 5 条补在前面（关注的人的新视频优先，且几十 KB / 1 秒内有）。
     * 探索流挂了就只用关注流；两条都挂才落到 `clips/discover/`。
     */
    const explore: NativeReelsPage | null = await NativeReels.viaExplore('');
    const connected: NativeReelsPage | null = await NativeReels.viaConnected('');
    if (explore !== null && connected !== null) {
      const merged: NativeReelsPage = NativeReels.mergePages(connected, explore);
      hilog.info(DOMAIN, TAG, 'reels first merged connected=%{public}d explore=%{public}d → n=%{public}d',
        connected.reels.length, explore.reels.length, merged.reels.length);
      return merged;
    }
    if (explore !== null) {
      return explore;
    }
    if (connected !== null) {
      return connected;
    }
    const fallback: NativeReelsPage | null = await NativeReels.viaClips('');
    if (fallback === null) {
      hilog.info(DOMAIN, TAG, 'reels miss: explore + connected + clips all empty limited=%{public}s',
        `${ApiThrottle.blocked(ApiThrottle.CLIPS)}`);
    }
    return fallback;
  }

  /**
   * 两页合并成"首屏那一页"：`head` 在前，`tail` 里没见过的接后面（按短码去重）。
   *
   * **游标取 `tail`（探索流）的** —— 关注流那页没有游标，探索流才有能翻的 `max_id`；
   * 丢了它，首屏之后就再也翻不动了（这正是"每页都回同样几条"的老毛病）。
   */
  private static mergePages(head: NativeReelsPage, tail: NativeReelsPage): NativeReelsPage {
    const seen: Set<string> = new Set<string>();
    const reels: Array<Reel> = [];
    const parts: Array<NativeReelsPage> = [head, tail];
    for (let part: number = 0; part < parts.length; part++) {
      const list: Array<Reel> = parts[part].reels;
      for (let index: number = 0; index < list.length; index++) {
        if (seen.has(list[index].shortcode)) {
          continue;
        }
        seen.add(list[index].shortcode);
        reels.push(list[index]);
      }
    }
    return new NativeReelsPage(reels, tail.nextCursor, tail.hasMore, head.ms + tail.ms);
  }

  /**
   * **探索流**（`discover/topical_explore/`，见 core/mobileapi/MobileDiscover）是 Reels 的主路。
   *
   * 为什么是它（真机实测）：`clips/discover/` 的游标换不动内容（每页都回同样 4 条），
   * 而探索流的 `max_id` 翻页**真的换内容**（第二页短码与第一页完全不重合）。
   *
   * 代价说清楚：它是"推荐/探索"的排序，不是 Reels 标签那套个性化排序；封面/音乐字段也可能稀疏
   * （探索流不一定给 `clips_metadata`）。换来的是**能一直往下翻**，这才是视频页的底线。
   *
   * 只收有视频的（探索流里也夹着图片帖）：`toReel` 自己会剔除。
   */
  private static async viaExplore(cursor: string): Promise<NativeReelsPage | null> {
    const page: MobileMediaPage | null = await MobileDiscover.explore(cursor,
      ApiThrottle.interactive(), ApiThrottle.CLIPS);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'explore miss cursor=%{public}d', cursor.length);
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
      hilog.info(DOMAIN, TAG, 'explore: medias=%{public}d but no playable reel',
        page.medias.length);
      return null;
    }
    NativeReels.lastSource = 'explore';
    NativeReels.noteAuthors(reels);
    hilog.info(DOMAIN, TAG,
      'reels via explore n=%{public}d medias=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      reels.length, page.medias.length, `${page.hasMore}`, page.nextCursor.length, page.ms);
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
    /*
     * 媒体 id：**优先 strong_id__**（它是字符串，原样可信）。
     * IG 的 pk 是 19 位数字，超出 IEEE754 精度，JSON.parse 之后会变成 3.79e+18 这种带指数
     * 的形式 —— 点赞/收藏那边有"必须是纯数字"的校验，指数形式会被拒，表现为"点了没反应"
     * （用户报的点赞失败，根因就在这里；搜索推荐流那条已经在 readPost 里修过）。
     */
    const strongId: string = `${media.strong_id__ ?? ''}`.trim();
    const mediaId: string = strongId.length > 0
      ? strongId : `${media.pk ?? media.id ?? ''}`.trim();
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
    // 本机点过的赞以**会话台账**为准（短码优先）：clips 首页这份是缓存/翻页复用的旧载荷，
    // 不查台账的话"点赞 → 退出 → 重进"心会回到灰的（用户报的问题）。
    const liked: boolean = EngageState.likedOfByCode(code,
      media.has_liked === true || media.viewer_has_liked === true);
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
