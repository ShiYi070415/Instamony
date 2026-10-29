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
import { ReelsCrashLog } from '../core/ReelsCrashLog';
// 落盘的"看过的短码"台账：冷启动 / 刷新时据此跳过上一轮看过的视频（见 core/ReelsSeen）。
import { ReelsSeen } from '../core/ReelsSeen';

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
/**
 * 缓冲里**够几条就先上屏**（见 requestMore 的"提前收手"）。
 *
 * 取 3：正好一屏多一点。等"两家作者"往往要多花 5~8 秒（下一发是现拉探索流），
 * 用户报的"下滑等好久才出现新的视频"就是这段等待。
 */
const REELS_READY_MIN: number = 3;
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
 * 冷启动时最多等预热那一发多久（毫秒）。
 *
 * 预热是 EntryAbility 一起发出去的（`clips/discover/` 实测 4~6 秒），用户点进视频页时常常
 * 还在飞。等它比自己再发一发快得多（那一发还要排限速闸门）；但也不能无限等 ——
 * 6 秒还没回来就自己发。
 */
const WARM_WAIT_MS: number = 6000;
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
/**
 * **下拉刷新**一次上屏多少条，以及补货要攒到多少条才肯上屏（见 refreshBatch）。
 *
 * `REFRESH_SHOW = 12` 与一页的量一致：刷一次就该有一屏多可看。
 * `REFRESH_MIN_PENDING = 12`：和"至少两家作者"一起当循环条件 —— 一页作者是 12 条同一个人，
 * 攒到 12 条时才可能凑出两家，凑不出就再要一页。
 */
const REFRESH_SHOW: number = 12;
const REFRESH_MIN_PENDING: number = 12;
/**
 * 触底那一发**最多先探一下**正在跑的预取多久（毫秒）。
 *
 * 只探这么一小会儿：正好快写完的那发能白捡，没写完就不等了 ——
 * 流的下一页实测 10 秒上下，死等它就是"前几条要等很久才能继续滑"。
 * 探不到就自己直接要一发**作者页**（2~4 秒），比等流快得多（见 nextPage）。
 */
const QUEUE_QUICK_WAIT_MS: number = 1200;

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
    this.shownAuthors.clear();
    this.nativeQueue = [];
    this.nativeCursor = '';
    /*
     * **原生那条链剩下的状态也要清**（否则换账号后"还剩下一个人的 Reels"）。
     *
     * `nativeHasMore` 是上一个人的游标还有没有下一页、`nativeFetching` 可能是真的在飞
     * （那一发回来会把上一个人的页塞进 `nativeQueue`）、`lastFillWasAuthor` 决定下一发
     * 往哪条源补、`active` 是上一个人看到第几条（新账号直接跳到那个位置就是"莫名从中间开始"）。
     */
    this.nativeHasMore = false;
    this.nativeFetching = false;
    this.lastFillWasAuthor = false;
    this.active = 0;
    this.diag = '-';
    // 换代：在飞的那几发（翻页 / 作者页 / 探索流）回来之后一律不许写进这一份新列表。
    this.epoch = this.epoch + 1;
  }

  private reels: Array<Reel> = [];
  private endCursor: string = '';
  private more: boolean = true;
  private busy: boolean = false;
  private diag: string = '-';
  /** 已经上屏的短码（去重只有这一份真相，见 ingestPage）。 */
  private shown: Set<string> = new Set<string>();
  /**
   * **已经上过屏的作者**：同一个作者整份列表最多出现一条。
   *
   * 需求（按 Instagram 客户端的行为）：reels 不会连着推同一个人的视频。
   * 现有的"按作者打散"只在**缓冲里还有别人**时才有用 —— 缓冲里只剩一个作者时它会"认了"直接铺
   * （见 drainInterleaved 的第 ③ 步），于是翻几页之后仍然是一串同一个人。
   * 这里改成硬规则：作者出现过就不再上屏，那几条直接被丢弃（不是延后），
   * 然后继续补货 —— 宁可这一页少几条，也不破坏"一人一条"。
   * 注：作者的 id 拿不到（空串）时不做限制，否则会误杀整页。
   */
  private shownAuthors: Set<string> = new Set<string>();
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
  /**
   * 正在补的这一页是**哪种源**：`author`（快，2~4 秒，一页一个人）/
   * `stream`（慢，10 秒上下，一页十几个作者）/ `explore`（更慢且图文混排）。
   *
   * 触底时用它决定"值不值得等"：等作者页很划算；等流那页不值得 —— 直接要一发作者页更快
   * （见 nextPage）。用户报的"前几条要等很久才能继续滑"就是触底时在死等流那一发。
   */
  private nativeFillKind: string = '';
  /** 上次补队列补的是"某个作者的 Reels"吗（两条源交替，见 prefetchNativePage）。 */
  private lastFillWasAuthor: boolean = false;
  /**
   * **这一份列表是第几代**（`reset()` 时 +1）。
   *
   * 为什么要它（用户报的"刷新后视频流队列也对不上"）：补页是**异步**的 —— 用户拉下刷新那一刻，
   * 可能正有一发"下一页/作者页"在飞。`reset()` 清空了队列，可那一发回来之后照样会
   * `nativeQueue.push(page)` / `ingestPage(page)`，把**上一份列表的页**塞进刷新后的队列里，
   * 于是刷完之后往下滑会冒出刷新前那批视频（顺序、内容都对不上）。
   * 每次异步结果落地前比一下代数，变了就丢掉。
   */
  private epoch: number = 0;

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

  /**
   * **换代**（下拉刷新开始那一刻调）：把"上一次列表还在飞"的那些结果作废。
   *
   * 为什么不直接 `reset()`：刷新要能"一条新的都没有时把原列表还回去"（见 refreshBatch），
   * 也希望能吃掉已经预取好、但还没上屏的那几页（它们也是没看过的）。`reset()` 会把列表、
   * 队列、去重表全清掉 —— 那是"换账号"要的，不是"刷新"要的。
   */
  bumpEpoch(): void {
    this.epoch = this.epoch + 1;
  }

  /**
   * 首屏（或重试）拉第一页。
   *
   * @param forceFresh **下拉刷新**专用：不吃启动预热那一页。
   *   预热是 app 一起来就发的那一发（`NativeReels.takeWarm`，最长算 2 分钟），拿它当
   *   "刷新结果"就是原样换回同一批视频 —— 用户看到的现象正是"下拉了，转圈转完，一条没变"。
   *   所以用户主动拉的那一下必须**真发一发**（`fetchPage` 自己会走 clips / 探索流那两发）。
   */
  async loadFirst(forceFresh: boolean = false): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.onBusy(true);
    const startedMs: number = Date.now();
    try {
      /*
       * **下拉刷新 = 换一批，而不是"重读首屏"**（用户报的"刷新后前四条视频还是固定的，
       * 只有顺序不一样"）。
       *
       * 根因当时是：首屏那条链是 `clips/discover/`，它的游标被错误地放在查询串里，
       * 服务端无视游标、每次把同一批重排一遍（见 core/mobileapi/MobileClips 的说明）。
       * 游标改放 body 之后那条流能真翻页了，但"重读第一页"仍然是**同一批最新视频** ——
       * 所以刷新照旧走"下一批 + 按作者打散"（见 refreshBatch）：它推进真游标，才是真的换内容。
       */
      if (forceFresh) {
        const shown: number = await this.refreshBatch();
        if (shown > 0) {
          hilog.info(DOMAIN, TAG, 'reels refresh batch shown=%{public}d ms=%{public}d',
            shown, Date.now() - startedMs);
          this.prefetchNativePage();
          return;
        }
        /*
         * **一条新的都没有：保留现有列表**（别 reset 完留一个空屏），只给一句说明。
         * 用户要的是"刷新不会看见看过的视频"，那就不该为了"看起来刷新过"把老视频再铺一遍。
         */
        this.onStatus('暂时没有新视频了（看过的都记着，过会儿再拉）');
        return;
      }
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
      /*
       * **等它，而不是再发一发**（见 NativeReels.takeWarmOrWait 的说明）：
       * 冷启动时那一发常常还在飞，以前拿不到就自己重发，等于同一个请求发两次、第二发还要
       * 排进限速闸门 —— 首屏白等好几秒。
       */
      const warm: NativeReelsPage | null = forceFresh ? null
        : await NativeReels.takeWarmOrWait(this.source, NATIVE_WARM_MAX_AGE_MS, WARM_WAIT_MS);
      if (warm !== null) {
        this.noteCursor(warm.nextCursor);
        let applied: number = this.applyFirstPage(warm);
        hilog.info(DOMAIN, TAG, 'reels first from warm n=%{public}d applied=%{public}d ms=%{public}d',
          warm.reels.length, applied, Date.now() - startedMs);
        if (applied === 0) {
          /*
           * **冷启动兜底：允许重复**。这一页全是"看过的"（IG 那几条源本身就很固定），
           * 与其让用户对着空屏等下一批，不如先把这几条铺上 —— 刷新那条路仍然严格不给看过的。
           */
          applied = this.applyFirstPage(warm, true);
          hilog.info(DOMAIN, TAG, 'reels first warm all seen → lenient n=%{public}d ms=%{public}d',
            applied, Date.now() - startedMs);
        }
        if (applied > 0) {
          this.prefetchNativePage();
          // 先出画面，再在后台补几条**没看过的**（requestMore 是追加，不动正在播的那条）。
          if (this.reels.length < REFRESH_SHOW / 2) {
            this.requestMore().catch((): void => {
            });
          }
          return;
        }
        // 连"允许重复"都铺不出来（这一页一条视频都没有）：换一批新的。
        // 冷启动只给两发（用户要的是"快点出画面"，不是"凑齐一屏"；刷新的那条路才是 4 发）。
        if (await this.refreshBatch(2) > 0) {
          hilog.info(DOMAIN, TAG, 'reels first warm empty → fresh batch ms=%{public}d',
            Date.now() - startedMs);
          this.prefetchNativePage();
          return;
        }
      }
      // ---- 2) 原生直发（有落盘模板 + 登录态时可走）----
      const native: NativeReelsPage | null = await NativeReels.fetchPage(this.source, NATIVE_PAGE_COUNT, '', true);
      if (native !== null) {
        this.noteCursor(native.nextCursor);
        let applied: number = this.applyFirstPage(native);
        hilog.info(DOMAIN, TAG, 'reels first native n=%{public}d applied=%{public}d ms=%{public}d',
          native.reels.length, applied, Date.now() - startedMs);
        if (applied === 0) {
          // 冷启动兜底：允许重复，先出画面（刷新那条路仍严格，见 ingestPage 的说明）。
          applied = this.applyFirstPage(native, true);
          hilog.info(DOMAIN, TAG, 'reels first native all seen → lenient n=%{public}d ms=%{public}d',
            applied, Date.now() - startedMs);
        }
        if (applied > 0) {
          this.prefetchNativePage();
          // 同上：先出画面，后台补几条没看过的。
          if (this.reels.length < REFRESH_SHOW / 2) {
            this.requestMore().catch((): void => {
            });
          }
          return;
        }
        // 同上：这一页一条视频都没有 → 换一批（冷启动同样只给两发，见上一条注释）。
        if (await this.refreshBatch(2) > 0) {
          hilog.info(DOMAIN, TAG, 'reels first page all seen → fresh batch ms=%{public}d',
            Date.now() - startedMs);
          this.prefetchNativePage();
          return;
        }
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
   * 去重有三层真相：
   *   · `shown`：**这一次**已经上过屏的短码；
   *   · `pending`：取到手、还没上屏的；
   *   · **`ReelsSeen`（落盘）**：以前（冷启动前 / 上一次刷新前）看过的 —— 用户要的是
   *     "每次打开 app 不会再获取上一轮一样的视频、刷新不会看见看过的视频"，
   *     光靠进程内那张表做不到（杀进程就忘了，见 core/ReelsSeen）。
   *
   * @returns 真正新增了几条（0 = 整页都是见过的）。
   */
  private ingestPage(page: NativeReelsPage, allowSeen: boolean = false): number {
    let added: number = 0;
    for (let index: number = 0; index < page.reels.length; index++) {
      const reel: Reel = page.reels[index];
      if (this.shown.has(reel.shortcode)) {
        continue;
      }
      /*
       * **「看过的不再给」是刷新的规则**；冷启动实在没新货时由调用方传 `allowSeen = true` ——
       * 宁可重复几条，也不能让用户打开视频页看到一屏空白（IG 那几条源本身就很固定）。
       */
      if (!allowSeen && ReelsSeen.has(this.source, reel.shortcode)) {
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
    /*
     * **一人一条**（硬规则，见 shownAuthors 的说明）：
     * 先把"作者已经上过屏"的条目从缓冲里剔掉，后面的打散逻辑就只在"新作者"之间挑。
     * 剔完缓冲空了就返回 0 —— 调用方（补货那条路）会继续取下一页，不会就此停住。
     */
    for (let index: number = this.pending.length - 1; index >= 0; index--) {
      const authorId: string = this.pending[index].authorId;
      if (authorId.length > 0 && this.shownAuthors.has(authorId)) {
        this.pending.splice(index, 1);
      }
    }
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
      /*
       * ③ 缓冲里只剩同一个作者了：**不取**（用户要求"避免出现同一个用户的多条视频"）。
       *
       * 以前这里 `pick = 0` 直接把同一个人接着铺 —— 一页 12 条都来自同一个作者，
       * 于是列表里就是连续十几条同一个人（用户报的现象）。现在收手：
       * 那些条目留在缓冲里，下一次 drain 时因为作者已经进 `shownAuthors` 会被整批剔掉，
       * 补货那条路自然会去要别的作者。
       */
      if (pick < 0) {
        break;
      }
      const one: Reel = this.pending[pick];
      this.pending.splice(pick, 1);
      if (this.shown.has(one.shortcode)) {
        continue;
      }
      this.shown.add(one.shortcode);
      if (one.authorId.length > 0) {
        this.shownAuthors.add(one.authorId);
      }
      prev = last;
      last = one.authorId;
      out.push(one);
    }
    if (out.length === 0) {
      return 0;
    }
    this.reels = this.reels.concat(out);
    // 上过屏的记进落盘台账：下次冷启动 / 下拉刷新不会再拿这一条（见 core/ReelsSeen）。
    ReelsSeen.remember(this.source, out.map((reel: Reel): string => reel.shortcode));
    this.onReels(this.reels, this.more);
    this.onStatus('已加载 ' + this.reels.length + ' 条' + (this.more ? '' : '（到底了）'));
    // 落盘一份：**首屏和翻页都存**（首页那条查询首屏有时只回 2~4 条，光存第一页太少）。
    // 被限流/没网时这几十条就是视频标签能显示的全部内容（见 core/ReelsCache）。
    ReelsCache.save(this.reels, ReelsCache.keyFor(this.source));
    return out.length;
  }

  /**
   * **下拉刷新 / 冷启动换新：收集一批"没看过、且一人一条"的视频**。
   *
   * 三个用户要求在这里一起满足：
   *   1. **刷新不会看见看过的**：`ingestPage` 会过滤 `ReelsSeen` 里记着的短码；
   *   2. **避免同一个用户的多条**：`drainInterleaved` 现在**不再**用"只剩一个作者就认了"
   *      的兜底（见那里的 ③），所以这里要**多补几页**才凑得够人；
   *   3. **整体替换**：先把旧列表换下来再铺新的；一条都没换到就把旧列表**还回去**，
   *      而不是留一个空屏（以前是 reset 之后什么都不剩）。
   *
   * 代价：一页作者是"某个人的 12 条"，按一人一条只剩 1 条可用，所以要 4 发左右才能凑出
   * 一屏。这已经比"一屏同一个人 + 全是看过的"好，而且刷新/冷启动各只有一次。
   *
   * @returns 上屏了几条（0 = 没换到东西）
   */
  private async refreshBatch(maxRounds: number = 4, allowSeen: boolean = false): Promise<number> {
    const limited: boolean = ApiThrottle.blocked(ApiThrottle.CLIPS);
    let rounds: number = 0;
    /*
     * 补到"够上屏"为止：目标条数的一半作者 + 至少两家（一家时 drain 只会出一条）。
     * 最多四发 —— 再要多就是十几秒的转圈了。
     */
    const wantAuthors: number = Math.max(2, Math.ceil(REFRESH_SHOW / 2));
    while (rounds < maxRounds && this.pendingAuthors() < wantAuthors) {
      const page: NativeReelsPage | null = await this.nextPage(limited);
      if (page === null) {
        break;
      }
      const fresh: number = this.ingestPage(page, allowSeen);
      rounds++;
      hilog.info(DOMAIN, TAG,
        'reels refresh fill n=%{public}d fresh=%{public}d authors=%{public}d round=%{public}d',
        page.reels.length, fresh, this.pendingAuthors(), rounds);
      if (fresh === 0) {
        // 整页都是看过的（`clips/discover/` 那四条就是这种）：这一发没意义，换下一条源。
        break;
      }
    }
    if (this.pending.length === 0) {
      hilog.info(DOMAIN, TAG, 'reels refresh: nothing new (seen=%{public}d)',
        ReelsSeen.countOf(this.source));
      return 0;
    }
    /*
     * **先把旧列表换下来**（drain 是往 `this.reels` 里加 = 整体替换的语义），
     * 一条都没换到再还回去 —— 不能因为"这次没新货"就把用户的列表清空。
     */
    const keepReels: Array<Reel> = this.reels;
    const keepShown: Set<string> = this.shown;
    const keepAuthors: Set<string> = this.shownAuthors;
    this.reels = [];
    this.shown = new Set<string>();
    this.shownAuthors = new Set<string>();
    const added: number = this.drainInterleaved(REFRESH_SHOW, true);
    if (added === 0) {
      this.reels = keepReels;
      this.shown = keepShown;
      this.shownAuthors = keepAuthors;
      return 0;
    }
    this.active = 0;
    hilog.info(DOMAIN, TAG, 'reels refresh batch added=%{public}d authors=%{public}d',
      added, this.shownAuthors.size);
    return added;
  }

  /** 首屏那一页：整页收进来再整页上屏（同样打散，首屏里也可能连着同一个人）。 */
  private applyFirstPage(page: NativeReelsPage, allowSeen: boolean = false): number {
    /*
     * **整页替换时把"看到第几条"复位**：列表被换成新的那一批之后，旧的 active 可能
     * 越过新长度 —— Swiper 停在越界索引上就是闪退的典型现场。
     */
    this.active = 0;
    ReelsCrashLog.note(`first page src=${this.source} n=${page.reels.length}`);
    // 首屏 = **整体替换**：旧列表、旧去重表、旧缓冲一起清掉。
    this.reels = [];
    this.shown.clear();
    this.shownAuthors.clear();
    this.pending = [];
    this.ingestPage(page, allowSeen);
    const added: number = this.drainInterleaved(page.reels.length + 1, false);
    /*
     * **记下"服务端给的顺序"与"真正上屏的顺序"前三条**。
     *
     * 用户报的"刷新后前两条视频轮着换位置"要分清是哪一侧的问题：
     *   · 两条日志的 head 都不一样 ⇒ 服务端（`clips/discover/` 是探索位，本来就会轮换）；
     *   · 服务端一样、上屏不一样 ⇒ 我们这边的打散/复位出了问题。
     */
    hilog.info(DOMAIN, TAG, 'reels first order page=[%{public}s] shown=[%{public}s]',
      ReelsViewModel.headOf(page.reels), ReelsViewModel.headOf(this.reels));
    return added;
  }

  /** 列表前三条的短码（日志用）。 */
  private static headOf(list: Array<Reel>): string {
    const parts: Array<string> = [];
    const limit: number = Math.min(3, list.length);
    for (let index: number = 0; index < limit; index++) {
      parts.push(list[index].shortcode);
    }
    return parts.join(',');
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
      // 关注页：好友那条流（`clips/discover/social/`）能一直翻、每页 9~10 个作者，优先要它；
      // 作者页（快、2~4 秒）作为交替，保证"第一发补货"不会因为流那发 10 秒而空手。
      if (this.nativeQueue.length === 0 && !this.lastFillWasAuthor
        && NativeReels.authorPoolSize(this.source) > 0) {
        this.fillFromAuthor();
        return;
      }
      if (NativeReels.hasStreamCursor(this.source)) {
        this.fillFromStream();
        return;
      }
      if (NativeReels.authorPoolSize(this.source) > 0) {
        this.fillFromAuthor();
        return;
      }
      this.fillFromExplore();
      return;
    }
    /*
     * **队列空时先要一发作者页**（哪怕上一发也是作者页）。
     *
     * 交替是为了"内容有新的"，但交替到"队列空着、下一发是 10 秒的流"时，
     * 用户滑到下一条就得等 —— 作者页 2~4 秒能立刻兜住，流那发随后再用。
     */
    const authorReady: boolean = NativeReels.authorPoolSize(this.source) > 0
      && (!this.lastFillWasAuthor || this.nativeQueue.length === 0);
    if (authorReady) {
      this.fillFromAuthor();
      return;
    }
    /*
     * **探索页：作者页之后接着同一条流翻**（`clips/discover/` 的真游标）。
     *
     * 为什么不继续只补作者页：一页作者是"某个人的 12 条"，补两页就是两个人的两屏；
     * 而这条流一页 10~16 条、十几个作者、和上一页 0 重合 —— 这才是用户要的"一直有新的"。
     * 代价是它慢（600KB / 实测 10 秒上下），所以放在后台预取、不挡当前播放。
     */
    if (NativeReels.hasStreamCursor(this.source)) {
      this.fillFromStream();
      return;
    }
    this.fillFromExplore();
  }

  /** 补一页"某个作者的 Reels"进队列（不推进探索流游标）。 */
  private fillFromAuthor(): void {
    const epoch: number = this.epoch;
    this.nativeFetching = true;
    this.nativeFillKind = 'author';
    NativeReels.fetchAuthorPage(this.source).then((page: NativeReelsPage | null): void => {
      if (epoch !== this.epoch) {
        /*
         * 这一发属于上一份列表（中途刷新过）：丢掉，别污染新的队列（见 epoch 的说明）。
         *
         * ⚠️ **在飞标记必须收掉**：早先这里直接 `return`，`nativeFetching` 就永远停在 true，
         * `prefetchNativePage` 之后一次都不再跑 —— 用户看到的就是"看完一页要等很久才能继续滑"
         * （每一页都退化成现拉，而现拉要 3~10 秒）。
         */
        this.nativeFetching = false;
        hilog.info(DOMAIN, TAG, 'reels author fill dropped (epoch %{public}d->%{public}d)',
          epoch, this.epoch);
        return;
      }
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

  /**
   * 补一页"**这一条流的下一页**"进队列（探索 = `clips/discover/`，好友 = `clips/discover/social/`）。
   *
   * 为什么单独一条：作者页快但一页只有一个人；这条流慢（600KB / 实测 10 秒上下）却一页
   * 10~16 条、十几个作者、和上一页 0 重合。放后台预取刚好 —— 用户看 4~10 条视频的时间够它跑完。
   */
  private fillFromStream(): void {
    const epoch: number = this.epoch;
    this.nativeFetching = true;
    this.nativeFillKind = 'stream';
    NativeReels.fetchStreamPage(this.source).then((page: NativeReelsPage | null): void => {
      if (epoch !== this.epoch) {
        // 同 fillFromAuthor：这一发已作废，但**在飞标记一定要收**，否则预取从此停摆。
        this.nativeFetching = false;
        hilog.info(DOMAIN, TAG, 'reels stream fill dropped (epoch %{public}d->%{public}d)',
          epoch, this.epoch);
        return;
      }
      this.nativeFetching = false;
      if (page === null) {
        // 流这一发没成：退回作者页 / 探索流接着补。
        this.lastFillWasAuthor = true;
        hilog.info(DOMAIN, TAG, 'reels stream fill miss, fall back');
        this.prefetchNativePage();
        return;
      }
      this.lastFillWasAuthor = false;
      this.nativeQueue.push(page);
      this.noteCursor(page.nextCursor);
      hilog.info(DOMAIN, TAG, 'reels stream page queued n=%{public}d ms=%{public}d queued=%{public}d',
        page.reels.length, page.ms, this.nativeQueue.length);
      this.prefetchNativePage();
    }).catch((): void => {
      this.nativeFetching = false;
    });
  }

  /** 补一页探索流进队列（真正个性化那一条，见 core/NativeReels.fetchExplorePage）。 */
  private fillFromExplore(): void {
    this.nativeFetching = true;
    this.nativeFillKind = 'explore';
    /*
     * **必须走 `fetchExplorePage`**（不是 `fetchPage`）。
     *
     * `fetchPage(游标)` 的策略是"作者页优先"：拿它来"补探索流"，回来的还是作者页 ——
     * 于是补货永远是同一条路，探索流那份个性化推荐一次都进不来，整条流就是
     * "固定那批作者的最新 12 条"反复切段（用户报的"全部都是固定重复的"）。
     */
    const epoch: number = this.epoch;
    NativeReels.fetchExplorePage(this.source)
      .then((page: NativeReelsPage | null): void => {
        if (epoch !== this.epoch) {
          // 同 fillFromAuthor：中途刷新过，这一发属于上一份列表；**在飞标记也要收**。
          this.nativeFetching = false;
          hilog.info(DOMAIN, TAG, 'reels explore fill dropped (epoch %{public}d->%{public}d)',
            epoch, this.epoch);
          return;
        }
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
   * **等预取把一页放进队列**（最多 `maxWaitMs`；预取没在跑就立刻返回 null）。
   *
   * 见 nextPage 里的说明：触底那一刻如果预取正在飞，等它比自己再发一发快整整一个请求。
   */
  private async waitForQueue(maxWaitMs: number): Promise<NativeReelsPage | null> {
    if (!this.nativeFetching) {
      return null;
    }
    const deadline: number = Date.now() + maxWaitMs;
    while (Date.now() < deadline) {
      await ReelsViewModel.sleep(120);
      const page: NativeReelsPage | null = this.takeNativePage();
      if (page !== null) {
        return page;
      }
      if (!this.nativeFetching) {
        return null;
      }
    }
    return this.takeNativePage();
  }

  /** 短睡（等预取用）。 */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  /**
   * 取下一页：**缓存队列优先，其次现拉**（限流时只吃队列，不发请求）。
   *
   * 现拉那一条**不交给 `NativeReels.fetchPage` 的默认顺序**（它会先去翻流那页，慢），
   * 而是自己按"最快能出画面"排：短探预取 → 作者页（2~4 秒）→ 才轮到通用的 fetchPage。
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
    /*
     * **队列空但预取还在飞：按"值不值得等"决定**（用户报的"前几条要等很久才能继续滑"）。
     *
     * 预取可能是作者页（2~4 秒，值得等一等）也可能是**流那页**（实测 10 秒上下）——
     * 后者绝不能死等：等它 10 秒与"现在就要一发作者页（2~4 秒）"相比毫无意义。
     * 所以：
     *   ① 在飞的是**流**（`nativeFillKind === 'stream'`）：一眼都不等，直接走 ②；
     *   ② 先短探一下（`QUEUE_QUICK_WAIT_MS`）—— 快写完的那发能白捡；
     *   ③ 还没有就**自己直接要一发作者页**（最快的那条源），不等流；
     *   ④ 作者页也失败才走通用的 fetchPage（它会退到流/探索流）。
     */
    if (this.nativeFillKind !== 'stream') {
      const quick: NativeReelsPage | null = await this.waitForQueue(QUEUE_QUICK_WAIT_MS);
      if (quick !== null) {
        this.noteCursor(quick.nextCursor);
        hilog.info(DOMAIN, TAG, 'reels page from prefetch (waited) n=%{public}d queued=%{public}d',
          quick.reels.length, this.nativeQueue.length);
        return quick;
      }
    } else {
      hilog.info(DOMAIN, TAG, 'reels next: stream fill in flight, take author page instead');
    }
    if (NativeReels.authorPoolSize(this.source) > 0) {
      const author: NativeReelsPage | null =
        await NativeReels.fetchAuthorPage(this.source);
      if (author !== null && author.reels.length > 0) {
        // 这一发也算"作者页"，交替关系照记（否则下一发又是作者页，流一直不推进）。
        this.lastFillWasAuthor = true;
        hilog.info(DOMAIN, TAG, 'reels page live author (fast path) n=%{public}d ms=%{public}d',
          author.reels.length, author.ms);
        return author;
      }
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
        /*
         * **别为了"够两家作者"把用户晾在那儿**（用户报："下滑等好久才出现新的视频"）。
         *
         * 缓冲里已经有几条、而队列里没有现成的页（下一发要去现拉探索流，5~8 秒）时，
         * 直接把现有的铺出去 —— 打散仍然由 drainInterleaved 负责，只是不再强求攒两页。
         */
        if (this.pending.length >= REELS_READY_MIN && this.nativeQueue.length === 0) {
          hilog.info(DOMAIN, TAG, 'reels fill stop: pending=%{public}d queue=0 (skip live wait)',
            this.pending.length);
          break;
        }
        const page: NativeReelsPage | null = await this.nextPage(limited);
        if (page === null) {
          break;
        }
        let fresh: number = this.ingestPage(page);
        if (fresh === 0) {
          /*
           * 这一页全看过：**允许重复**再收一遍（不额外发请求）。
           *
           * 为什么不干脆空着：IG 这几条源本身就很固定，台账攒到一定量之后"每页都看过"，
           * 严格下去的结果是滑到底再也出不来新视频（用户会觉得"卡住了"）。翻页允许重复、
           * **下拉刷新保持严格**（用户的要求是"刷新不看见看过的"）。
           */
          fresh = this.ingestPage(page, true);
        }
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
      ReelsCrashLog.note(`more added=${added} total=${this.reels.length} pending=${this.pending.length}` + ` queue=${this.nativeQueue.length} limited=${limited}`);
      ReelsCrashLog.flush();
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