/*
 * Reels 视频流的视图模型。
 *
 * 取数只有一条链：core/NativeReels → 移动端 clips/discover/（失败退探索流），见那里的说明。
 * 这里原来那套「冷启动导航 /reels/ 抓模板 → 小脚本回放 → 重试」已随模板机制删除；
 * 现在首屏 = 启动预热的那一页 / 原生现抓一页，翻页只改游标（max_id）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { AppConfig } from '../config/AppConfig';
import { Reel, ReelMapper, ReelsDto, ReelsPage, ReelStreamVm } from '../model/Reel';
import {
  NativeReels,
  NativeReelsPage,
  REELS_SOURCE_EXPLORE,
  REELS_SOURCE_FOLLOWING
} from '../core/NativeReels';
import { ApiThrottle } from '../core/ApiThrottle';
import { CachedReelsPage, ReelsCache } from '../core/ReelsCache';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsViewModel';

/** 一页要多少条（接口默认给十几条）。 */
const PAGE_SIZE: number = 12;
/** 抽取脚本的单次超时与重试次数（理由见文件头）。 */
const EXTRACT_TIMEOUT_MS: number = 6000;
const EXTRACT_ATTEMPTS: number = 5;
const EXTRACT_RETRY_GAP_MS: number = 2500;
/** 冷启动那次：等页面把手上的查询发出去的时间。 */
const HYDRATE_WAIT_MS: number = 1800;
/** 导航到 reels 页的等待上限。 */
const NAV_READY_TIMEOUT_MS: number = 20000;
/**
 * 原生这条路每页要几条 / 缓存几页 / 预热那份最多放多久。
 *
 * 与首页信息流同一套思路（见 FeedViewModel）：原生直发 HTTP 拿页 → 显示完就在后台把后面
 * **两页**抓好放队列里 → 上滑切换时直接吃队列，切换本身不再等网络。
 * 预热那份超过 2 分钟就当旧了（app 可能在后台躺很久）。
 */
const NATIVE_PAGE_COUNT: number = 7;
/**
 * 内存里**排着队的页数**（上滑一次吃一页）。
 *
 * 3 页而不是 2 页：真机上作者那页要 4~7 秒、探索流那页要 5~9 秒（几百 KB 的响应），
 * 而用户上滑一次只要一两秒 —— 只排 2 页时队列说空就空，滑到就等。排 3 页大约提前
 * 15~30 条（作者页 12 条 / 探索流 5~7 条），足够把这一发的延迟盖住。
 * 代价是内存里多留一页 Reel（每页只有地址和文案，没有像素），可以忽略。
 */
const NATIVE_CACHE_PAGES: number = 3;
const NATIVE_WARM_MAX_AGE_MS: number = 120000;
/**
 * 一次翻页最多**上屏**几条（剩下的留在缓冲里，见 drainInterleaved）。
 *
 * 取 10 而不是"有多少铺多少"：缓冲里多留几条，下一次上屏才有料继续交替作者
 * （同一作者不连着出现）。10 条也够用户滑一阵，滑到需要下一页时数据已经在了。
 */
const DRAIN_PER_REQUEST: number = 10;
/** 一次上屏至少铺这么多条之后，才允许因为"缓冲里只剩一个作者"提前收手（见 drainInterleaved）。 */
const DRAIN_MIN: number = 4;
/**
 * 待上屏缓冲最多囤多少条（防呆：预取还在跑时不至于无限长大）。
 *
 * 36 = 三个作者那页的量；到这个量就不再预取，等上屏把这批吃掉。
 */
const PENDING_MAX: number = 36;

export class ReelsViewModel implements ReelStreamVm {
  /**
   * **这一份是哪条流**（需求："把关注流和探索流分开两页"）。
   *
   * 两条流各一个实例（`pages/Index` 里 `reelsVm` / `reelsFollowVm`），
   * 取数那边的状态（作者池、游标、缓存、预热）也各一份 —— 见 core/NativeReels 的 ReelsLane。
   * 这里只做转发，视图模型本身不关心两者的差别。
   */
  private readonly source: string;

  constructor(source: string = REELS_SOURCE_EXPLORE) {
    this.source = source;
  }

  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  /**
   * **清空自己**（退出登录 / 换账号时调，见 core/AccountScope 的文件头）。
   *
   * 为什么要它：这些视图模型是**长驻**的（页面切 tab 不重建），换账号后它们手里还攥着
   * 上一个人的列表 —— 界面一挂载就会把那份铺出来（用户报的"快拍还是上一个账号的"就是
   * 同一类问题，只不过那条在 StoryCache/托盘队列上）。
   */
  reset(): void {
    this.reels = [];
    this.endCursor = '';
    this.more = true;
    this.busy = false;
    this.pending = [];
    this.shown.clear();
    this.nativeQueue = [];
    this.nativeCursor = '';
  }

  private reels: Array<Reel> = [];
  private endCursor: string = '';
  private more: boolean = true;
  private busy: boolean = false;
  private diag: string = '-';
  /** 已经上屏的短码（去重只有这一份真相，见 ingestPage）。 */
  private shown: Set<string> = new Set<string>();
  /**
   * **取到手、还没上屏**的条目（见 drainInterleaved）。
   *
   * 为什么要这一层：翻页的主力是"某个作者的全部 Reels"（一次 12 条全是同一个人），
   * 整页照铺就是"连着十几条同一个作者"（用户报的）。先攒进缓冲，再按作者交替上屏。
   */
  private pending: Array<Reel> = [];
  /** 当前看到第几条（切 tab 重建页面时要恢复，见 activeIndex）。 */
  private active: number = 0;
  /** 原生已经取好、等着上滑切换时直接铺的那些页（最多 NATIVE_CACHE_PAGES 页，先进先出）。 */
  private nativeQueue: Array<NativeReelsPage> = [];
  /** 原生链路自己的游标（和网页回放那条 endCursor 分开，避免互相带偏）。 */
  private nativeCursor: string = '';
  private nativeHasMore: boolean = false;
  private nativeFetching: boolean = false;
  /** 上一次补队列补的是"某个作者的 Reels"吗（两条源交替，见 prefetchNativePage）。 */
  private lastFillWasAuthor: boolean = false;

  onReels: (reels: Array<Reel>, hasMore: boolean) => void =
    (reels: Array<Reel>, hasMore: boolean): void => {
    };
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
  };
  onStatus: (text: string) => void = (text: string): void => {
  };

  list(): Array<Reel> {
    return this.reels;
  }

  isBusy(): boolean {
    return this.busy;
  }

  hasMore(): boolean {
    return this.more;
  }

  /**
   * 当前看到第几条。
   *
   * **必须由视图模型记着**：切 tab 会把 ReelsPage 整个销毁重建，组件里的 @State 会归零，
   * 于是每次切回来都从第一条重新开始播（用户报的就是这个）。放在这里，重建时能原样恢复。
   */
  activeIndex(): number {
    return this.active;
  }

  /** 记下当前第几条（越界一律按 0 处理）。 */
  setActiveIndex(index: number): void {
    this.active = index > 0 ? index : 0;
  }

  /** 首屏（或重试）拉第一页。 */
  async loadFirst(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.onBusy(true);
    const startedMs: number = Date.now();
    try {
      /*
       * **被限流也不能直接认输**（见 core/ApiThrottle）：
       *   ① 先把上次落盘那一页铺出来（ReelsCache）—— 用户立刻有内容；
       *   ② **仍然试一次** `fetchPage`：它内部会走**移动端探索流**兜底
       *      （`discover/topical_explore/`，见 NativeReels.viaExplore），那条端点不受 clips 那把锁管；
       *      拿到新内容就整体替换（个性化差一点，但比"停在上次那几条"强）。
       */
      if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
        this.fromCacheOrSay(ApiThrottle.remainingMinutes(ApiThrottle.CLIPS));
        const fallback: NativeReelsPage | null = await NativeReels.fetchPage(this.source, NATIVE_PAGE_COUNT, '', true);
        if (fallback !== null) {
          this.noteCursor(fallback.nextCursor);
          this.applyFirstPage(fallback);
          hilog.info(DOMAIN, TAG, 'reels first via explore fallback n=%{public}d ms=%{public}d',
            fallback.reels.length, Date.now() - startedMs);
          this.onStatus('已加载 ' + fallback.reels.length + ' 条（视频接口受限，先用推荐流顶上）');
          this.prefetchNativePage();
        }
        return;
      }
      // ---- 1) 启动预热那一页（app 一起来就发了，见 EntryAbility / NativeReels.warmStart）----
      const warm: NativeReelsPage | null = NativeReels.takeWarm(this.source, NATIVE_WARM_MAX_AGE_MS);
      if (warm !== null) {
        this.noteCursor(warm.nextCursor);
        this.applyFirstPage(warm);
        hilog.info(DOMAIN, TAG, 'reels first from warm n=%{public}d ms=%{public}d',
          warm.reels.length, Date.now() - startedMs);
        this.prefetchNativePage();
        return;
      }
      // ---- 2) 原生直发（有落盘模板 + 登录态时可走）----
      const native: NativeReelsPage | null = await NativeReels.fetchPage(this.source, NATIVE_PAGE_COUNT, '', true);
      if (native !== null) {
        this.noteCursor(native.nextCursor);
        this.applyFirstPage(native);
        hilog.info(DOMAIN, TAG, 'reels first native n=%{public}d ms=%{public}d ms=%{public}d',
          native.reels.length, native.ms, Date.now() - startedMs);
        this.prefetchNativePage();
        return;
      }
      // ---- 3) 原生也没拿到：铺落盘缓存或如实说明（网页模板回放那条路已删除）----
      this.fromCacheOrSay(ApiThrottle.blocked(ApiThrottle.CLIPS)
        ? ApiThrottle.remainingMinutes(ApiThrottle.CLIPS) : 0);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadFirst threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      /*
       * **`busy` 一定要在这里收**（`finally`，不是每个 return 前各写一遍）。
       *
       * 这里原先只有 `catch` 里把它置回 false —— 于是**成功路径一进来 `busy` 就永远是 true**
       * （`return` 不会走 catch）。后果是 `requestMore()` 第一句 `if (this.busy) return;` 之后
       * 直接返回：滑到第 14 条（首屏最后一页）再往上划只会看到 Swiper 的弹簧回弹，
       * 一条新的都要不来 —— 用户报的"到最底无法刷新新的"就是这个。
       * 而且那个状态下预取队列里明明排着 3 页，也永远吃不到。
       */
      this.busy = false;
      this.onBusy(false);
    }
  }

  /**
   * 把原生取到的一页**收进待上屏缓冲**（不直接上屏，见 drainInterleaved）。
   *
   * 去重只有这一份真相：`shown`（已经上屏的短码）+ `pending` 里已有的短码。
   *
   * @returns 真正新增了几条（0 = 整页都是见过的）。
   */
  private ingestPage(page: NativeReelsPage): number {
    let added: number = 0;
    for (let index: number = 0; index < page.reels.length; index++) {
      const reel: Reel = page.reels[index];
      if (this.shown.has(reel.shortcode)) {
        continue;
      }
      let dup: boolean = false;
      for (let at: number = 0; at < this.pending.length; at++) {
        if (this.pending[at].shortcode === reel.shortcode) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      this.pending.push(reel);
      added++;
    }
    return added;
  }

  /** 待上屏缓冲里有几家作者（补货时用它判断"够不够打散"）。 */
  private pendingAuthors(): number {
    const seen: Set<string> = new Set<string>();
    for (let index: number = 0; index < this.pending.length; index++) {
      const id: string = this.pending[index].authorId;
      if (id.length > 0) {
        seen.add(id);
      }
    }
    return seen.size;
  }

  /**
   * **按作者打散**后上屏（这是"连着几条都是同一个人"的修法）。
   *
   * 为什么必须打散：翻页的主力是「某个作者的全部 Reels」（`clips/user/{pk}/`，一次 12 条
   * **全是同一个人的**）。整页照铺的话，用户看到的就是连续十几条同一个作者 —— 用户报的正是这个。
   *
   * 取法：优先挑"和上一条、上上条都不同作者"的，其次"和上一条不同"，实在没有就随便取。
   *
   * @param limit 这一次最多上屏几条。
   * @param stopOnSingle **缓冲里只剩一个作者时就收手**（翻页用）。
   *   不加这道闸的话，`12 条 A + 3 条别人` 这种组合铺到后面必然是一串 A（别人先被挑光了）；
   *   收手之后那 10 条 A 留在缓冲里，等下一发新页（另一个作者）回来再交替 —— 这样才不会
   *   出现"连着好几条同一个人"。首屏不能收手（它必须铺满屏），所以那条路传 false。
   * @returns 真正新增了几条。
   */
  private drainInterleaved(limit: number, stopOnSingle: boolean): number {
    if (this.pending.length === 0) {
      return 0;
    }
    const out: Array<Reel> = [];
    const size: number = this.reels.length;
    let last: string = size > 0 ? this.reels[size - 1].authorId : '';
    let prev: string = size > 1 ? this.reels[size - 2].authorId : '';
    while (out.length < limit && this.pending.length > 0) {
      if (stopOnSingle && out.length >= DRAIN_MIN && this.pendingAuthors() === 1) {
        break;
      }
      let pick: number = -1;
      // ① 和最近两条都不是同一作者
      for (let index: number = 0; index < this.pending.length; index++) {
        const id: string = this.pending[index].authorId;
        if (id.length === 0 || (id !== last && id !== prev)) {
          pick = index;
          break;
        }
      }
      // ② 退一步：只要不和上一条相同
      if (pick < 0) {
        for (let index: number = 0; index < this.pending.length; index++) {
          const id: string = this.pending[index].authorId;
          if (id.length === 0 || id !== last) {
            pick = index;
            break;
          }
        }
      }
      // ③ 缓冲里只剩同一个作者了（补货还没回来）：认了，先铺
      if (pick < 0) {
        pick = 0;
      }
      const one: Reel = this.pending[pick];
      this.pending.splice(pick, 1);
      if (this.shown.has(one.shortcode)) {
        continue;
      }
      this.shown.add(one.shortcode);
      prev = last;
      last = one.authorId;
      out.push(one);
    }
    if (out.length === 0) {
      return 0;
    }
    this.reels = this.reels.concat(out);
    this.onReels(this.reels, this.more);
    this.onStatus('已加载 ' + this.reels.length + ' 条' + (this.more ? '' : '（到底了）'));
    // 落盘一份：**首屏和翻页都存**（首页那条查询首屏有时只回 2~4 条，光存第一页太少）。
    // 被限流/没网时这几十条就是视频标签能显示的全部内容（见 core/ReelsCache）。
    ReelsCache.save(this.reels, ReelsCache.keyFor(this.source));
    return out.length;
  }

  /** 首屏那一页：整页收进来再整页上屏（同样打散，首屏里也可能连着同一个人）。 */
  private applyFirstPage(page: NativeReelsPage): number {
    // 首屏 = **整体替换**：旧列表、旧去重表、旧缓冲一起清掉。
    this.reels = [];
    this.shown.clear();
    this.pending = [];
    this.ingestPage(page);
    return this.drainInterleaved(page.reels.length + 1, false);
  }

  /**
   * **记下游标**（谁取到带游标的页，谁就调它一次）。
   *
   * 为什么不在铺页那一步顺手记：预取的那几页是**先排队、晚些才铺上屏**的，
   * 而"下一次预取用哪个游标"必须跟着**取到的页**走 —— 早先两者混用同一个字段，
   * 结果是连发两次同一个游标、拿回同一页（去重后一条都不新增，看起来就像"不加载新的了"）。
   * 作者那页（`clips/user/`）的游标是空串，调进来也什么都不改（它推进不了探索流）。
   */
  private noteCursor(cursor: string): void {
    if (cursor.length === 0) {
      return;
    }
    this.nativeCursor = cursor;
    this.endCursor = cursor;
    // 有游标就允许继续翻：IG 的 `more_available` 经常缺省或写成 false，按它拦就是"滑到底不再请求"。
    this.nativeHasMore = true;
    this.more = true;
  }

  /**
   * 被限流（或没有可用数据源）时的收尾：**先铺上次落盘那一页**，实在没有才如实说。
   *
   * @param minutes 还有几分钟解禁（只用来写提示语）。
   */
  private fromCacheOrSay(minutes: number): void {
    const cached: CachedReelsPage | null = ReelsCache.load(ReelsCache.keyFor(this.source));
    if (cached !== null && cached.reels.length > 0) {
      this.reels = cached.reels;
      // 缓存那份没有游标：当成"到底了"，免得触底哨兵一直空转要下一页。
      this.more = false;
      this.onReels(this.reels, this.more);
      this.onStatus(`Instagram 暂时限制了视频接口，先显示上次的 ${this.reels.length} 条（约 ${minutes} 分钟后自动重试）`);
      hilog.info(DOMAIN, TAG, 'rate limited → cache n=%{public}d age=%{public}dms',
        this.reels.length, cached.ageMs);
      return;
    }
    this.onStatus(`Instagram 暂时限制了视频接口，约 ${minutes} 分钟后再试`);
  }

  /** 一页 reels 补进缓存队列（队列 = 上滑切换时"已经等在内存里"的那些页）。 */
  private prefetchNativePage(): void {
    // 深度固定 2 页，理由同 FeedViewModel（上滑要有货）。缓冲里囤够了就先停手。
    if (this.nativeFetching || this.nativeQueue.length >= NATIVE_CACHE_PAGES
      || this.pending.length >= PENDING_MAX) {
      return;
    }
    /*
     * **两条源交替**（这是"视频刷不完"的关键，理由见 core/NativeReels 的补货池说明）：
     *   · 探索流：能一直往下翻，但图文混排（实测 8 条里只有 1~3 条是视频、500KB / 5 秒）；
     *   · 作者那页（`clips/user/`）：清一色视频、几十 KB、一两秒。
     *
     * **关注那条不交替**（需求："把关注流和探索流分开两页"）：它的作者池里装的全是
     * `clips/connected/` / `clips/discover/social/` 里出现过的人 —— 也就是"你关注的人"，
     * 一直从池子里取就永远是关注内容。往里掺探索流的页等于把陌生人塞进关注页，
     * 那这一页就跟探索页没区别了。只有池子真的取空（都翻到底了）才落到探索流兜底。
     */
    if (this.source === REELS_SOURCE_FOLLOWING) {
      if (NativeReels.authorPoolSize(this.source) > 0) {
        this.fillFromAuthor();
        return;
      }
      this.fillFromExplore();
      return;
    }
    const authorReady: boolean = !this.lastFillWasAuthor && NativeReels.authorPoolSize(this.source) > 0;
    if (authorReady) {
      this.fillFromAuthor();
      return;
    }
    this.fillFromExplore();
  }

  /** 补一页"某个作者的 Reels"进队列（不推进探索流游标）。 */
  private fillFromAuthor(): void {
    this.nativeFetching = true;
    NativeReels.fetchAuthorPage(this.source).then((page: NativeReelsPage | null): void => {
      this.nativeFetching = false;
      if (page === null) {
        // 池子里的作者这一轮都问不出来：别停下，退回探索流接着补。
        this.lastFillWasAuthor = false;
        hilog.info(DOMAIN, TAG, 'reels author fill miss, fall back to explore');
        this.fillFromExplore();
        return;
      }
      this.lastFillWasAuthor = true;
      this.nativeQueue.push(page);
      hilog.info(DOMAIN, TAG, 'reels author page queued n=%{public}d pool=%{public}d queued=%{public}d',
        page.reels.length, NativeReels.authorPoolSize(this.source), this.nativeQueue.length);
      this.prefetchNativePage();
    }).catch((): void => {
      this.nativeFetching = false;
    });
  }

  /** 补一页探索流进队列（真正个性化那一条，见 core/NativeReels.fetchExplorePage）。 */
  private fillFromExplore(): void {
    this.nativeFetching = true;
    /*
     * **必须走 `fetchExplorePage`**（不是 `fetchPage`）。
     *
     * `fetchPage(游标)` 的策略是"作者页优先"：拿它来"补探索流"，回来的还是作者页 ——
     * 于是补货永远是同一条路，探索流那份个性化推荐一次都进不来，整条流就是
     * "固定那批作者的最新 12 条"反复切段（用户报的"全部都是固定重复的"）。
     */
    NativeReels.fetchExplorePage(this.source)
      .then((page: NativeReelsPage | null): void => {
        this.nativeFetching = false;
        if (page === null) {
          // 探索流这一发没成（限流/抖动）：**别把 more 置死**，回到作者页接着补。
          this.lastFillWasAuthor = true;
          hilog.info(DOMAIN, TAG, 'reels explore fill miss, keep going with authors');
          this.prefetchNativePage();
          return;
        }
        this.lastFillWasAuthor = false;
        this.nativeQueue.push(page);
        this.noteCursor(page.nextCursor);
        hilog.info(DOMAIN, TAG, 'reels explore page queued n=%{public}d ms=%{public}d queued=%{public}d',
          page.reels.length, page.ms, this.nativeQueue.length);
        this.prefetchNativePage();
      }).catch((): void => {
        this.nativeFetching = false;
      });
  }

  /** 取走缓存里最前面的那一页（先进先出）。 */
  private takeNativePage(): NativeReelsPage | null {
    if (this.nativeQueue.length === 0) {
      return null;
    }
    const page: NativeReelsPage | undefined = this.nativeQueue.shift();
    return page === undefined ? null : page;
  }

  /**
   * 取下一页：**缓存队列优先，其次现拉**（限流时只吃队列，不发请求）。
   *
   * 拉的那一发内部已经是"作者页优先 → 探索流 → 首屏兜底"（见 core/NativeReels.fetchPage），
   * 这里不用再自己排一遍顺序。
   */
  private async nextPage(limited: boolean): Promise<NativeReelsPage | null> {
    const cached: NativeReelsPage | null = this.takeNativePage();
    if (cached !== null) {
      this.noteCursor(cached.nextCursor);
      hilog.info(DOMAIN, TAG, 'reels page from cache n=%{public}d queued=%{public}d',
        cached.reels.length, this.nativeQueue.length);
      return cached;
    }
    if (limited) {
      return null;
    }
    const cursor: string = this.nativeCursor.length > 0 ? this.nativeCursor : this.endCursor;
    const live: NativeReelsPage | null =
      await NativeReels.fetchPage(this.source, NATIVE_PAGE_COUNT, cursor, true);
    if (live !== null) {
      this.noteCursor(live.nextCursor);
      hilog.info(DOMAIN, TAG, 'reels page live n=%{public}d ms=%{public}d',
        live.reels.length, live.ms);
      return live;
    }
    if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
      return null;
    }
    /*
     * 游标成了死链（这一发真没拿到）：重取一次第一页。
     * IG 的服务端排序会变，用户手动"退出再进来"拿到的就是这一批 —— 这里替他做掉。
     */
    const fresh: NativeReelsPage | null =
      await NativeReels.fetchPage(this.source, NATIVE_PAGE_COUNT, '', true);
    if (fresh !== null) {
      this.noteCursor(fresh.nextCursor);
      hilog.info(DOMAIN, TAG, 'reels page restarted n=%{public}d', fresh.reels.length);
    }
    return fresh;
  }

  /**
   * 翻页：先补够"待上屏"的缓冲（至少两家作者），再**按作者打散**上屏。
   *
   * ⚠️ 这一段是"连着十几条都是同一个人"的正面修法，改动它之前先读 drainInterleaved：
   * 一次翻页的主力是某个作者的 12 条视频，直接铺就是十几条同一个人；
   * 攒两页再交替取，才能做到同一个作者不连着出现。
   *
   * 不用 `more` 提前拦：IG 的 clips 分页经常给了游标却把 `more_available` 写成 false，
   * 按它拦就是"滑到底一次都不再请求"。能不能翻由**结果**决定。
   */
  async requestMore(): Promise<void> {
    if (this.busy) {
      return;
    }
    const limited: boolean = ApiThrottle.blocked(ApiThrottle.CLIPS);
    this.busy = true;
    this.onBusy(true);
    try {
      /*
       * ① 补缓冲：一直要页，直到缓冲里**有两家以上作者**且够这一次上屏的量，最多三发。
       *
       * 缓冲本来就有货时（上一次没铺完的）这一圈直接不进，上屏是**零延迟**的。
       */
      let rounds: number = 0;
      while (rounds < 3 && (this.pendingAuthors() < 2 || this.pending.length < DRAIN_PER_REQUEST)) {
        const page: NativeReelsPage | null = await this.nextPage(limited);
        if (page === null) {
          break;
        }
        const fresh: number = this.ingestPage(page);
        rounds++;
        hilog.info(DOMAIN, TAG, 'reels fill n=%{public}d fresh=%{public}d authors=%{public}d round=%{public}d',
          page.reels.length, fresh, this.pendingAuthors(), rounds);
      }
      // ② 上屏：按作者打散（一次最多铺一页的量，剩下的留给下次）
      const added: number = this.drainInterleaved(DRAIN_PER_REQUEST, true);
      hilog.info(DOMAIN, TAG,
        'reels more added=%{public}d pending=%{public}d authors=%{public}d rounds=%{public}d queued=%{public}d limited=%{public}s',
        added, this.pending.length, this.pendingAuthors(), rounds, this.nativeQueue.length,
        `${limited}`);
      if (added > 0) {
        this.more = true;
        this.prefetchNativePage();
        return;
      }
      if (limited) {
        // 队列空了又在冷却里：如实说一句，不去发那一发注定被拒的请求。
        this.onStatus(`Instagram 暂时限制了视频接口，约 ${ApiThrottle.remainingMinutes(ApiThrottle.CLIPS)} 分钟后再试`);
        return;
      }
      // 真的拿不到新内容：收工，等用户下次上滑再试。
      this.more = false;
      this.onReels(this.reels, this.more);
      this.onStatus('已加载 ' + this.reels.length + ' 条（到底了）');
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }
}