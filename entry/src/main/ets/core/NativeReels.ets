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

/**
 * **两条流**（需求："把关注流和探索流分开两页"）。
 *
 * 语义按 instagrapi 的端点分工来分，不是随便挑的：
 *   · `explore`   = 探索 —— `clips/discover/`（探索 Reels，清一色视频）+ 探索流
 *     （`discover/topical_explore/`，真正个性化的推荐，也是唯一能一直往下翻的那条）；
 *   · `following` = 关注 —— `clips/connected/`（你关注的人的 Reels）+
 *     `clips/discover/social/`（好友/亲密关系那批，instagrapi 叫 friends_reels），
 *     翻页用**这些人的作品页**（`clips/user/{pk}/`）—— 一句话：这一页只出现你关注的人。
 *
 * 两条流的状态（作者池 / 游标 / 缓存 / 预热）**必须各一份**：
 * 混用的话，关注页里会冒出探索流里那些陌生人（语义就错了），而且两页会互相把对方的
 * 游标带偏（正是"翻页翻出重复内容"的老根子）。
 */
export const REELS_SOURCE_EXPLORE: string = 'explore';
export const REELS_SOURCE_FOLLOWING: string = 'following';

/** 一条流自己的可变状态（探索 / 关注 各一个实例，见 NativeReels.laneOf）。 */
class ReelsLane {
  /** 首屏预热好的那一页（见 warmStart）。 */
  warm: NativeReelsPage | null = null;
  /** 预热是否在进行中（防重复）。 */
  warming: boolean = false;
  /** 补货池：流里见过的作者（见 noteAuthors）。 */
  authors: Array<string> = [];
  /** 作者 id → 该作者的下一页游标（不在表里 = 还没取过；空串 = 已到底）。 */
  cursors: Map<string, string> = new Map<string, string>();
  /** 已经进过池子的作者（防重复）。 */
  seen: Set<string> = new Set<string>();
  /** 探索流的游标（首屏后台预取拿到，翻页直接用；空 = 还没拿到）。 */
  exploreCursor: string = '';
  /** 后台预取探索流那一发是否在进行中。 */
  exploring: boolean = false;
  /**
   * 后台预取到、**还没被消费**的那一页探索流。
   *
   * 为什么留内容而不只留游标：探索流第一页要 5~9 秒、几百 KB，只留游标等于把这一页白扔掉，
   * 之后翻页还得再花一次同样的时间；留着的话首屏之后第一发翻页直接吃它（已经等在那里了）。
   */
  exploreWarm: NativeReelsPage | null = null;
  /** 最近几十秒内拉过的快通道页（key → 页），避免同一时刻重复请求同一发。 */
  recent: Map<string, NativeReelsPage> = new Map<string, NativeReelsPage>();
  /** 这一页是从哪条路来的（`explore` / `connected` / `friends` / `clips` / `author` / `-`），诊断用。 */
  lastSource: string = '-';
}

export class NativeReels {
  /** "作者对象里没有 id"那条诊断只打一次（见 toReel）。 */
  private static uidDiagDone: boolean = false;
  /** "载荷里有没有关注状态"那条诊断只打一次（见 toReel）。 */
  private static followDiagDone: boolean = false;
  /** "载荷里有没有收藏状态"那条诊断只打一次（见 toReel）。 */
  private static saveDiagDone: boolean = false;

  /**
   * 首屏那些 `clips/*` 换不动游标（每页都回同一批），所以首屏交付一个**占位游标**，
   * 让视图模型认为"还有下一页"；翻页时由作者页 / 探索流接手（见 fetchNextPage）。
   */
  private static readonly CURSOR_SENTINEL: string = '#clips';
  /** 关注流首屏至少要凑够几条才算"够数"（不够就退回探索流兜底）。 */
  private static readonly FIRST_MIN_REELS: number = 6;
  /** 探索流首屏至少要有几条才接受（`clips/discover/` 一般给 3~4 条视频）。 */
  private static readonly EXPLORE_MIN_REELS: number = 3;
  /** 快通道页的重用窗口（毫秒）：真机上见过同一时刻重复拉 `connected`、白花 6.6 秒。 */
  private static readonly RECENT_REUSE_MS: number = 90 * 1000;
  /** 两条流的全部状态（键 = REELS_SOURCE_*）。 */
  private static readonly lanes: Map<string, ReelsLane> = new Map<string, ReelsLane>();
  /** 池子最多排多少人（够刷很久了，池子本身会跟着探索流一直长大）。 */
  private static readonly AUTHOR_POOL_MAX: number = 40;
  /** "作者那页解析不出 Reel"那条诊断只打一次（见 fetchAuthorPage）。 */
  private static authorDiagDone: boolean = false;

  /** 取某条流的状态（没有就建一个）。 */
  private static laneOf(source: string): ReelsLane {
    let lane: ReelsLane | undefined = NativeReels.lanes.get(source);
    if (lane === undefined) {
      lane = new ReelsLane();
      NativeReels.lanes.set(source, lane);
    }
    return lane;
  }

  /** 上一页用的是哪条源（诊断用）。 */
  static source(): string {
    const lane: ReelsLane | undefined = NativeReels.lanes.get(REELS_SOURCE_EXPLORE);
    return lane === undefined ? '-' : lane.lastSource;
  }

  /**
   * app 启动时就发一发某条流的第一页，结果留在内存里等 Reels 页来取（幂等）。
   *
   * 和信息流那条一样的道理：切到 Reels 时多半已经有数据，用户看到的是"秒出"。
   * 只给**探索**那条预热（它是默认落点）；关注那条等用户第一次点过去再拉
   * （两页都预热会在启动时多打两个请求，把信息流的预热往后挤）。
   */
  static warmStart(source: string, first: number): void {
    const lane: ReelsLane = NativeReels.laneOf(source);
    if (lane.warming || lane.warm !== null) {
      return;
    }
    lane.warming = true;
    const started: number = Date.now();
    NativeReels.fetchPage(source, first, '').then((page: NativeReelsPage | null): void => {
      lane.warming = false;
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'warmStart[%{public}s] miss after %{public}dms',
          source, Date.now() - started);
        return;
      }
      lane.warm = page;
      hilog.info(DOMAIN, TAG, 'warmStart[%{public}s] ready n=%{public}d ms=%{public}d (since launch %{public}d)',
        source, page.reels.length, page.ms, Date.now() - started);
    }).catch((): void => {
      lane.warming = false;
    });
  }

  /** 取走预热的那一页（取走即清空；太旧的不要）。 */
  static takeWarm(source: string, maxAgeMs: number): NativeReelsPage | null {
    const lane: ReelsLane = NativeReels.laneOf(source);
    const page: NativeReelsPage | null = lane.warm;
    if (page === null) {
      return null;
    }
    lane.warm = null;
    if (Date.now() - page.at > maxAgeMs) {
      hilog.info(DOMAIN, TAG, 'warm page discarded source=%{public}s age=%{public}dms',
        source, Date.now() - page.at);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'warm page used source=%{public}s age=%{public}dms n=%{public}d',
      source, Date.now() - page.at, page.reels.length);
    return page;
  }

  /**
   * `clips/discover/social/` 那一发（instagrapi 的 `friends_reels`：Friends 那个 tab）。
   *
   * 也是清一色视频、6 条 / 324KB / 1~2 秒；同样换不动游标，只用来把首屏铺满。
   * 归**关注**那条流：这一批是"好友/亲密关系"，不是推荐。
   */
  private static async viaFriends(lane: ReelsLane, cursor: string): Promise<NativeReelsPage | null> {
    const started: number = Date.now();
    const cached: NativeReelsPage | null = NativeReels.recent(lane, 'friends');
    if (cached !== null && cursor.length === 0) {
      return cached;
    }
    const body: string | null = await MobileClips.friends(cursor);
    if (body === null) {
      return null;
    }
    const page: NativeReelsPage | null = NativeReels.parseMobile(body, Date.now() - started);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'friends unparsable bytes=%{public}d', body.length);
      return null;
    }
    lane.lastSource = 'friends';
    NativeReels.noteAuthors(lane, page.reels);
    hilog.info(DOMAIN, TAG, 'reels via friends n=%{public}d more=%{public}s ms=%{public}d',
      page.reels.length, `${page.hasMore}`, page.ms);
    return NativeReels.remember(lane, 'friends', page);
  }

  /** 取"最近拉过"的那一页（超时/没有给 null）。 */
  private static recent(lane: ReelsLane, key: string): NativeReelsPage | null {
    const page: NativeReelsPage | undefined = lane.recent.get(key);
    if (page === undefined) {
      return null;
    }
    if (Date.now() - page.at > NativeReels.RECENT_REUSE_MS) {
      lane.recent.delete(key);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'reuse recent %{public}s age=%{public}dms n=%{public}d', key,
      Date.now() - page.at, page.reels.length);
    return page;
  }

  /** 记下这一页，供 `recent` 复用。 */
  private static remember(lane: ReelsLane, key: string,
                          page: NativeReelsPage): NativeReelsPage {
    lane.recent.set(key, page);
    return page;
  }

  /**
   * 把若干页合成一页（按短码去重，跳过 null）。
   *
   * 游标取**最后一个非空游标**：首屏那三发都没有真游标（空），所以合成结果也没有游标，
   * 由调用方决定给占位游标还是探索流游标。
   */
  private static mergeList(parts: Array<NativeReelsPage | null>, started: number): NativeReelsPage | null {
    const seen: Set<string> = new Set<string>();
    const reels: Array<Reel> = [];
    let cursor: string = '';
    let more: boolean = false;
    for (let part: number = 0; part < parts.length; part++) {
      const page: NativeReelsPage | null = parts[part];
      if (page === null) {
        continue;
      }
      if (page.nextCursor.length > 0) {
        cursor = page.nextCursor;
      }
      if (page.hasMore) {
        more = true;
      }
      for (let index: number = 0; index < page.reels.length; index++) {
        const one: Reel = page.reels[index];
        if (seen.has(one.shortcode)) {
          continue;
        }
        seen.add(one.shortcode);
        reels.push(one);
      }
    }
    if (reels.length === 0) {
      return null;
    }
    return new NativeReelsPage(reels, cursor, more, Date.now() - started);
  }

  /**
   * **关注流那一发**（`clips/connected/`）：关注页首屏就是它。
   *
   * 5 条、几十 KB、很快，但**没有 `paging_info`**（游标为空），所以它只负责"一进视频页就有东西播"，
   * 翻页由**这些人的作品页**接管（见 fetchAuthorPage）。
   */
  private static async viaConnected(lane: ReelsLane, cursor: string): Promise<NativeReelsPage | null> {
    const started: number = Date.now();
    const cached: NativeReelsPage | null = NativeReels.recent(lane, 'connected');
    if (cached !== null && cursor.length === 0) {
      return cached;
    }
    const body: string | null = await MobileClips.connected(cursor);
    if (body === null) {
      return null;
    }
    const page: NativeReelsPage | null = NativeReels.parseMobile(body, Date.now() - started);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'connected unparsable bytes=%{public}d', body.length);
      return null;
    }
    lane.lastSource = 'connected';
    NativeReels.noteAuthors(lane, page.reels);
    hilog.info(DOMAIN, TAG, 'reels via connected n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      page.reels.length, `${page.hasMore}`, page.nextCursor.length, page.ms);
    return NativeReels.remember(lane, 'connected', page);
  }

  /**
   * `clips/discover/` 那一发 = **探索流的首屏**。
   *
   * 真机上它每页都回同样 3~4 条、游标换不动（见 core/mobileapi/MobileClips 文件头），
   * 所以只当"一进探索页就有东西播"的第一屏，翻页交给探索流 + 作者页。
   */
  private static async viaClips(lane: ReelsLane, cursor: string): Promise<NativeReelsPage | null> {
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
    lane.lastSource = 'clips';
    NativeReels.noteAuthors(lane, page.reels);
    hilog.info(DOMAIN, TAG, 'reels via clips n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      page.reels.length, `${page.hasMore}`, page.nextCursor.length, page.ms);
    return page;
  }

  /** 补货池里还有几个作者（视图模型用它决定"这一发要不要补货"）。 */
  static authorPoolSize(source: string): number {
    return NativeReels.laneOf(source).authors.length;
  }

  /**
   * **补货**：从池子里取一个作者，要他那页 Reels（`clips/user/{pk}/`）。
   *
   * 为什么是这条路：探索流实测 8 条里只有 1~3 条是视频（500KB / 5 秒），单靠它刷不动；
   * 而一个作者那页是**清一色视频**、几十 KB、一两秒（主页 Reels 分页同一条，已真机验证）。
   *
   * 池子是**每条流自己**的（见 ReelsLane）：
   *   · 关注页的池子只装 `clips/connected/` + `clips/discover/social/` 里出现的人
   *     —— 所以关注页往下翻永远是"你关注的人的其他视频"，不会冒出陌生人；
   *   · 探索页的池子装探索里出现的人。
   *
   * 返回的那一页 **`nextCursor` 是占位哨兵**（它推进不了探索流的游标，见 fetchExplorePage）。
   * 作者自己还有下一页时，他被重新排到队尾（游标记在 lane.cursors 里）。
   *
   * 一个作者给不出东西（私密/零 Reels/被限流）就换下一个，最多试两个 —— 不在这儿死磕。
   */
  static async fetchAuthorPage(source: string): Promise<NativeReelsPage | null> {
    const lane: ReelsLane = NativeReels.laneOf(source);
    let tries: number = 0;
    while (lane.authors.length > 0 && tries < 2) {
      const pk: string | undefined = lane.authors.shift();
      if (pk === undefined || pk.length === 0) {
        continue;
      }
      const cursor: string = lane.cursors.get(pk) ?? '';
      const started: number = Date.now();
      const grid: MobileGridPage | null = await MobileProfile.tab('clips', pk, cursor,
        AUTHOR_PAGE_COUNT, ApiThrottle.interactive());
      tries++;
      if (grid === null) {
        // 这个作者这一发没成：不放回池子（别在一个人身上反复失败），试下一个。
        lane.cursors.delete(pk);
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
        lane.cursors.set(pk, grid.nextCursor);
        lane.authors.push(pk);
      } else {
        lane.cursors.delete(pk);
      }
      if (reels.length === 0) {
        continue;
      }
      hilog.info(DOMAIN, TAG,
        'reels via author src=%{public}s pk=%{public}s n=%{public}d items=%{public}d more=%{public}s ms=%{public}d',
        source, pk, reels.length, grid.items.length, grid.nextCursor.length > 0 ? 'y' : 'n',
        Date.now() - started);
      return new NativeReelsPage(reels, NativeReels.CURSOR_SENTINEL, true, Date.now() - started);
    }
    return null;
  }

  /**
   * **只要探索流那一页**（不看补货池）。
   *
   * 为什么要单独开一个入口：视图模型那边是"作者页 / 探索流**交替**"补货的（作者页全是视频、
   * 探索流是真正个性化的推荐）。而 `fetchPage(游标)` 的策略是"作者优先"，拿它去要探索流
   * 永远只会回作者页 —— 于是同一批作者的作品会被反复切成一段一段，整个视频流就成了
   * 一份固定的播放表（用户报的"全部都是固定重复的"）。
   *
   * 游标用这条流自己的 `exploreCursor`（首屏预热时拿到，见 warmExplorePage）；另外首屏预热
   * 那一页的内容**留着直接给**（`lane.exploreWarm`），不白扔一次 5~9 秒的请求。
   * 返回的 `nextCursor` 是**占位哨兵**：探索流的 `max_id` 由本类自己管，不交给视图模型。
   */
  static async fetchExplorePage(source: string): Promise<NativeReelsPage | null> {
    const lane: ReelsLane = NativeReels.laneOf(source);
    const warm: NativeReelsPage | null = lane.exploreWarm;
    if (warm !== null) {
      lane.exploreWarm = null;
      hilog.info(DOMAIN, TAG, 'reels explore from warm src=%{public}s n=%{public}d',
        source, warm.reels.length);
      return new NativeReelsPage(warm.reels, NativeReels.CURSOR_SENTINEL, true, warm.ms);
    }
    const started: number = Date.now();
    const page: NativeReelsPage | null = await NativeReels.viaExplore(lane, lane.exploreCursor);
    if (page === null) {
      return null;
    }
    lane.exploreCursor = page.nextCursor;
    return new NativeReelsPage(page.reels, NativeReels.CURSOR_SENTINEL, true,
      Date.now() - started);
  }

  /** 把一页里出现过的作者收进这条流的补货池（去重，限量，**插在随机位置**）。 */
  private static noteAuthors(lane: ReelsLane, reels: Array<Reel>): void {
    for (let index: number = 0; index < reels.length; index++) {
      const pk: string = reels[index].authorId;
      if (pk.length === 0 || lane.seen.has(pk)) {
        continue;
      }
      if (lane.authors.length >= NativeReels.AUTHOR_POOL_MAX) {
        return;
      }
      lane.seen.add(pk);
      /*
       * **随机位置插入**（不是一律排到队尾）。
       *
       * 首屏那些 `clips/*` 是**固定的一批**（真机实测每次都回同一组），于是它们的作者顺序
       * 也是固定的 —— 一律排队尾的话，每次冷启动看到的作者顺序一模一样，整条视频流就成了
       * 一份可以背下来的播放表。随机插入让"下一个是哪个作者"每次都不同，代价为零。
       */
      const at: number = Math.floor(Math.random() * (lane.authors.length + 1));
      lane.authors.splice(at, 0, pk);
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
   * ## 取数策略（按 instagrapi 的三个 Reels 通道重排；真机数字见下）
   *
   * instagrapi 的 ReelsMixin 只有三条源：
   *   `clips/connected/`（关注）· `clips/discover/`（探索 Reels）· `clips/discover/social/`（Friends）
   * 它们**清一色是视频**、每发只要 200~330KB / 1~3 秒，但每页都回同一批条目（游标换不动内容）。
   * 而原来当主路的 `discover/topical_explore/` 是**图文混排**，真机实测：
   *
   *   21:40:01  connected n=5  ms=3081
   *   21:40:23  explore   n=1  medias=12  ms=6993   ← 12 条里只有 1 条是视频
   *   21:40:30  connected n=5  ms=6605（重复请求了一次）
   *   首屏合计 **13.6 秒只拿到 6 条**
   *   翻页：explore 每页 5.7~9.2 秒，视频 1~7 条
   *
   * 这就是用户报的"切过去加载很慢、加载后只有固定不变的几条"。所以：
   *   · **首屏**：三条 `clips/*` 快通道一起打（各 1~3 秒、全是视频），**不等探索流**；
   *     凑够 `FIRST_MIN_REELS` 就直接交付，同时在后台预取探索流只为拿到它的游标（不阻塞）。
   *   · **翻页**：探索流（唯一真能翻页的源）**+ 一个作者的 `clips/user/`（12 条清一色视频）**
   *     合并着给 —— 单靠探索流每页只有 1~7 条视频，撑不住"一直往下刷"。
   *   · 三条快通道的游标换不动，所以首屏给 `CURSOR_SENTINEL` 占位，翻页时由探索流接手。
   *
   * @param userDriven 预留（现在不再区分：快通道本身就很轻，预热也用同一套）
   */
  static async fetchPage(source: string, first: number, cursor: string,
                         userDriven: boolean = false): Promise<NativeReelsPage | null> {
    if (cursor.length === 0) {
      return await NativeReels.fetchFirstPage(source);
    }
    // 有游标（含首屏的占位哨兵）= 翻页。
    return await NativeReels.fetchNextPage(source, cursor);
  }

  /** **首屏**：按流分派（关注 = 关注/好友那两发，探索 = 探索 Reels 那一发）。 */
  private static async fetchFirstPage(source: string): Promise<NativeReelsPage | null> {
    const lane: ReelsLane = NativeReels.laneOf(source);
    if (source === REELS_SOURCE_FOLLOWING) {
      return await NativeReels.firstFollowing(lane);
    }
    return await NativeReels.firstExplore(lane);
  }

  /**
   * **好友流首屏**（这一页在界面上叫「好友」，内部键仍是 `REELS_SOURCE_FOLLOWING`）：
   * `clips/discover/social/`（好友）+ `clips/connected/`（你关注的人）并发。
   *
   * 顺序是"好友在前"：按钮叫好友，第一屏就该先出现好友那批（`social` 是亲密关系那一条，
   * 见 core/mobileapi/MobileClips 的端点表）。两批其实都是"你认识的人"，混着看才对。
   *
   * 两发都挂（被限流 / 新号没关注人）才退回探索流 —— 那时语义差一点，总比空屏强。
   */
  private static async firstFollowing(lane: ReelsLane): Promise<NativeReelsPage | null> {
    const started: number = Date.now();
    const parts: Array<NativeReelsPage | null> = await Promise.all([
      NativeReels.viaFriends(lane, ''),
      NativeReels.viaConnected(lane, '')
    ]);
    const merged: NativeReelsPage | null = NativeReels.mergeList(parts, started);
    if (merged !== null && merged.reels.length >= NativeReels.FIRST_MIN_REELS) {
      hilog.info(DOMAIN, TAG, 'reels[following] first n=%{public}d ms=%{public}d',
        merged.reels.length, Date.now() - started);
      return new NativeReelsPage(merged.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    const explore: NativeReelsPage | null = await NativeReels.viaExplore(lane, '');
    if (explore !== null) {
      lane.exploreCursor = explore.nextCursor;
      if (merged !== null) {
        const head: NativeReelsPage = NativeReels.mergePages(merged, explore);
        hilog.info(DOMAIN, TAG, 'reels[following] first+explore n=%{public}d ms=%{public}d',
          head.reels.length, Date.now() - started);
        return new NativeReelsPage(head.reels, NativeReels.CURSOR_SENTINEL, true,
          Date.now() - started);
      }
      hilog.info(DOMAIN, TAG, 'reels[following] first explore only n=%{public}d',
        explore.reels.length);
      return new NativeReelsPage(explore.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    if (merged !== null) {
      return new NativeReelsPage(merged.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    hilog.info(DOMAIN, TAG, 'reels[following] first miss: connected + friends + explore empty');
    return null;
  }

  /**
   * **探索流首屏**：`clips/discover/`（3~4 条、1~3 秒、全是视频）+ 后台预热探索流第一页。
   *
   * 探索流第一页要 5~9 秒 —— **不等它**，让它在后台跑；拿到的内容留在 `lane.exploreWarm`，
   * 首屏之后第一发翻页直接吃（不白扔一次请求，也不让用户盯着转圈）。
   */
  private static async firstExplore(lane: ReelsLane): Promise<NativeReelsPage | null> {
    const started: number = Date.now();
    const clips: NativeReelsPage | null = await NativeReels.viaClips(lane, '');
    NativeReels.warmExplorePage(lane);
    if (clips !== null && clips.reels.length >= NativeReels.EXPLORE_MIN_REELS) {
      hilog.info(DOMAIN, TAG, 'reels[explore] first n=%{public}d ms=%{public}d',
        clips.reels.length, Date.now() - started);
      return new NativeReelsPage(clips.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    // `clips/discover/` 太薄或被限流：退回探索流第一页（慢，但至少满屏）。
    const explore: NativeReelsPage | null = await NativeReels.viaExplore(lane, '');
    if (explore !== null) {
      lane.exploreCursor = explore.nextCursor;
      if (clips === null) {
        return explore;
      }
      const merged: NativeReelsPage = NativeReels.mergePages(clips, explore);
      hilog.info(DOMAIN, TAG, 'reels[explore] first clips+explore n=%{public}d ms=%{public}d',
        merged.reels.length, Date.now() - started);
      return new NativeReelsPage(merged.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    if (clips !== null) {
      return new NativeReelsPage(clips.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    hilog.info(DOMAIN, TAG, 'reels[explore] first miss: clips + explore both empty');
    return null;
  }

  /**
   * **翻页**：优先**一个作者的全部 Reels**（`clips/user/{pk}/`，清一色视频、12 条、2~4 秒）。
   *
   * 为什么改成"作者优先、探索流补池"（真机 21:44 实测）：
   *   探索流每页要 **6~8 秒**、12 条里只有 1~2 条视频；再叠一个作者页，一页要 11~19 秒。
   *   而作者页本身 12 条全是视频、两三秒。所以：
   *     · 池子里还有作者 → **只打作者页**（2~4 秒、12 条视频）；
   *     · 池子空了（或作者页都失败）→ 打探索流：既补视频，也把**新作者**收进池子。
   *   代价是排序会变成"按作者成段"而不是个性化混排 —— 视频页的"能一直往下刷、每页都有货"
   *   比排序更重要（这正是用户报的两件事）。
   */
  private static async fetchNextPage(source: string, cursor: string): Promise<NativeReelsPage | null> {
    const lane: ReelsLane = NativeReels.laneOf(source);
    const started: number = Date.now();
    const author: NativeReelsPage | null = await NativeReels.fetchAuthorPage(source);
    if (author !== null && author.reels.length > 0) {
      hilog.info(DOMAIN, TAG, 'reels next author src=%{public}s n=%{public}d ms=%{public}d pool=%{public}d',
        source, author.reels.length, Date.now() - started, lane.authors.length);
      // 游标继续给哨兵：下一次翻页仍然"作者优先"，池子空了才会去打探索流。
      return new NativeReelsPage(author.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    const exploreCursor: string = (cursor === NativeReels.CURSOR_SENTINEL)
      ? lane.exploreCursor : cursor;
    const explore: NativeReelsPage | null = await NativeReels.viaExplore(lane, exploreCursor);
    if (explore !== null) {
      lane.exploreCursor = explore.nextCursor;
      hilog.info(DOMAIN, TAG, 'reels next explore src=%{public}s n=%{public}d ms=%{public}d pool=%{public}d',
        source, explore.reels.length, Date.now() - started, lane.authors.length);
      return new NativeReelsPage(explore.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    let quick: NativeReelsPage | null = null;
    if (source === REELS_SOURCE_FOLLOWING) {
      const parts: Array<NativeReelsPage | null> = [
        await NativeReels.viaConnected(lane, ''),
        await NativeReels.viaFriends(lane, '')
      ];
      quick = NativeReels.mergeList(parts, Date.now());
    } else {
      quick = await NativeReels.viaClips(lane, '');
    }
    if (quick !== null) {
      hilog.info(DOMAIN, TAG, 'reels next fallback src=%{public}s n=%{public}d',
        source, quick.reels.length);
      return new NativeReelsPage(quick.reels, NativeReels.CURSOR_SENTINEL, true,
        Date.now() - started);
    }
    hilog.info(DOMAIN, TAG, 'reels miss src=%{public}s cursor=%{public}d limited=%{public}s',
      source, cursor.length, `${ApiThrottle.blocked(ApiThrottle.CLIPS)}`);
    return null;
  }

  /**
   * 后台把**探索流第一页**打下来：既拿它的 `max_id`，也把内容留着给首屏之后那一发翻页。
   *
   * 为什么不只留游标：那一页值 5~9 秒 / 几百 KB，只留游标等于白扔一次请求，
   * 之后翻页还得再等一次同样长的时间（见 ReelsLane.exploreWarm）。
   */
  private static warmExplorePage(lane: ReelsLane): void {
    if (lane.exploreCursor.length > 0 || lane.exploring || lane.exploreWarm !== null) {
      return;
    }
    lane.exploring = true;
    NativeReels.viaExplore(lane, '').then((page: NativeReelsPage | null): void => {
      lane.exploring = false;
      if (page !== null) {
        lane.exploreCursor = page.nextCursor;
        lane.exploreWarm = page;
        hilog.info(DOMAIN, TAG, 'explore page warmed n=%{public}d cursor=%{public}d',
          page.reels.length, lane.exploreCursor.length);
      }
    }).catch((): void => {
      lane.exploring = false;
    });
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
  private static async viaExplore(lane: ReelsLane, cursor: string): Promise<NativeReelsPage | null> {
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
    lane.lastSource = 'explore';
    NativeReels.noteAuthors(lane, reels);
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
