/*
 * 信息流页面的视图模型。
 *
 * 从 pages/Index.ets 抽出来：页面组件只负责画、以及把用户操作转过来；取数编排
 * （触发页面发请求、回放它那条接口、DOM 兜底、补全、去重合并）都在这里。
 *
 * 它不持有 ArkUI 状态、也不碰 @State：状态变化通过回调交回页面，由页面同步到自己的
 * @State 上。状态行只报语义（FeedStatus）而不是文案，因此这里完全不依赖 UI 资源。
 *
 * 翻页策略（按优先级）：
 *   1) 游标：用上一页响应里的 page_info.end_cursor 直接回放同一条查询，不滚页面、
 *      不等信号，正常一两秒回来。
 *   2) 兜底：拿不到游标或游标路径没新增内容时，才滚页面逼它自己发下一页请求。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import {
  FEED_SCRIPT,
  SCROLL_BOTTOM_SCRIPT,
  timelineScript,
  TRIGGER_FEED_SCRIPT
} from '../bridge/WebScripts';
import { FeedItemDto, FeedPayloadDto, PayloadState } from '../model/FeedDto';
import { FeedStatus } from '../model/FeedStatus';
import { FeedMapper, MergeResult } from '../model/FeedMapper';
import { MediaPost } from '../model/MediaPost';
import { ApiRegistry } from '../bridge/ApiRegistry';
import { NativeFeed, NativeFeedPage, NativeFetchResult } from '../core/NativeFeed';
import { CachedFeedPage, FeedCache } from '../core/FeedCache';
import { PosterCache } from '../core/PosterCache';

const DOMAIN: number = 0xFF00;
const TAG: string = 'FeedViewModel';

/**
 * 「不走网页」的第一发要几条。
 *
 * 需求就是"开 app 先给几条"，7 条差不多铺满一屏多一点：够看、又比整页更快回来。
 */
const NATIVE_FIRST_COUNT: number = 7;
/**
 * 原生分页每页要几条 + "提前备好一页"的缓存。
 *
 * 用户要的是：冷启动先给 7 条 → 显示完就**在后台把下一页也抓回来放着** →
 * 上滑时那一页是"已经在内存里"的，铺上零等待 → 铺完再抓下一页。
 * 这条路的每一步都是一次原生 HTTP（实测 1.2~3.3 秒/页），完全不碰网页、不等任何信号。
 */
const NATIVE_PAGE_COUNT: number = 7;
/**
 * 原生那一发的来源标记（FeedPayloadDto.src）。
 *
 * 和网页那两条路（capture / replay）区分开：日志里一眼能看出首屏是谁给的，
 * 探针里也能据此判断"没走网页"这条路这次有没有成。
 */
const NATIVE_SRC: string = 'native';

/**
 * 缓存里最多备几页（需求："翻页预取深度调深一档"）。
 *
 * 1 页不够：用户快速上滑时会撞上"缓存已空、现抓 2 秒"的空窗（实测）。备 2 页之后，
 * 连续两次上滑都吃的是内存里的页；第 3 次才会现抓，而那时前两页的预取早就补回来了。
 * 现在提到 **3 页**：连滑三屏都吃内存，而每页只有几十 KB（比视频小得多）。
 */
const NATIVE_CACHE_PAGES: number = 3;
/**
 * 预热那一页最多能放多久（毫秒）。
 *
 * app 可能在后台躺很久，那份数据早就不新了；超过这个年龄就当没有，老老实实再发一次。
 */
const NATIVE_WARM_MAX_AGE_MS: number = 120000;

/**
 * 首页信息流的 GraphQL 操作名片段。
 *
 * NETWORK_WATCHER 抓到带这些名字的请求后，会把请求配置存进页面的 __ogFeedCfg
 * 并回报 onReplayReady；我们等的就是这个信号。取片段而不是全名，是因为
 * Instagram 会在名字后面挂版本/变体后缀（如 PolarisFeedTimelineRootV2Query）。
 */
const TIMELINE_OPS: Array<string> = ['FeedTimeline', 'FeedRootPagination'];

/** 首屏回放一次就够用的条数：够了就不再触发页面重发，直接显示。 */
const FIRST_PAGE_ENOUGH: number = 8;
/**
 * 首屏最多试几轮去要「真的发过请求的第一页」（见 loadFirstPage）。
 *
 * 每轮 = 登记等待 + 点一次首页 + 等信号 + 回放，正常第 1 轮就成功；冷启动网页还没水合完时
 * 会多试几轮，总耗时可接受。拿到 SSR 就收工是**不行**的：那份 HTML 会被 HTTP 缓存复用，
 * 每次开 app 都显示同样几条（用户报的"固定显示那几个帖子"）。
 */
const FRESH_ROUNDS: number = 3;
/** 等「页面自己发出请求」的上限。等不到就按兜底路径走，不会比原来的固定等待更久。 */
const FIRST_SIGNAL_MS: number = 6000;
/** 屏幕上已经有内容时，再等整页的窗口就短一些，别让用户干等。 */
const REFINE_SIGNAL_MS: number = 4000;
const PAGING_SIGNAL_MS: number = 4000;
/** 注入脚本自身的执行上限。 */
const TRIGGER_SCRIPT_MS: number = 6000;
const SCROLL_SCRIPT_MS: number = 5000;
/** 回放脚本内部 fetch 自己 8 秒中止，所以这里的上限不必留太大。 */
const TIMELINE_SCRIPT_MS: number = 12000;
const ENRICH_SCRIPT_MS: number = 12000;
const DOM_SCRIPT_MS: number = 15000;
/** 滚动兜底最多滚几轮。 */
const PAGING_ROUNDS: number = 2;
/**
 * 「服务端说没有下一页了」之后，隔多久允许再试一次（毫秒）。
 *
 * 为什么要把这句话当成**有时效**的：实测 IG 在限流、游标过期或者刚好在换页时，会在某一页
 * 回一个 `has_next_page: false`，之后一切正常。早先这个标志一旦置上就**再也不会被清**——
 * 表现正是「上滑很多轮之后，往下再也刷不出新帖子」（而且界面连"没有更多"都不一定显示）。
 * 到点后允许再试一次：真是到底了，服务端会再回一句 false，界面照旧显示"没有更多帖子了"。
 */
const END_RECHECK_MS: number = 30000;
/**
 * 「翻页卡住了」之后，隔多久允许用「重读第一页」把整条链路重启一次（毫秒）。
 *
 * 游标这条路和滚页面那条路都换不来新内容时，说明这条分页链路已经不可信了（游标过期、
 * 页面自己的懒加载停了、或者网页被别的功能导航走了）。这时候唯一确定有效的做法就是
 * **重新读一次第一页**：它会给回一个新的游标，翻页从那里重新接上；已有的帖子不会被清掉
 * （走 mergePrepend，按 shortcode 去重，重复的页重新走一遍也只是不新增）。
 * 这正是用户现在手动做的事（下拉刷新）—— 这里把它自动化，并且限流（一分钟一次）。
 */
const RESTART_COOLDOWN_MS: number = 60000;
/**
 * 下拉刷新时，等"页面就绪"的上限（毫秒）。
 *
 * 网页可能正停在别处（活动页 / 帖子页）或者刚被导航过、还在水合，这时读信息流必定失败。
 * 等一小会儿再读，比"拉一下什么都没发生"好。
 */
const REFRESH_READY_MS: number = 6000;
/**
 * 「等网页就绪」的总上限与单次等待片段（毫秒）。
 *
 * 分段等而不是一次等到死：每段结束都能重新问一次 `isReady()`，网页在这期间就绪就能立刻继续
 * （常见情况是等 1~2 秒），而真的一直不就绪时也不会无限挂住这一轮取数。
 */
const READY_TOTAL_MS: number = 30000;
const READY_SLICE_MS: number = 4000;
/**
 * 等下拉刷新真正做完的上限（毫秒），以及轮询间隔。
 *
 * 见 `awaitIdle`：刷新请求可能正好撞上在跑的一轮取数，那一轮结束后才会真正重读第一页，
 * 这段等待就是用来把"转圈"撑到那时候的。
 */
const REFRESH_IDLE_TIMEOUT_MS: number = 20000;
const REFRESH_IDLE_POLL_MS: number = 150;

export class FeedViewModel {
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private posts: MediaPost[] = [];
  private busy: boolean = false;
  private statusKind: FeedStatus = FeedStatus.Idle;
  private statusDetail: string = '';
  private debug: string = '';
  /** 服务端给的下一页游标；空串表示还没有/没有下一页。 */
  private nextCursor: string = '';
  /** 服务端 page_info.has_next_page；默认乐观（没拿到 page_info 时允许继续翻）。 */
  private hasMore: boolean = true;
  /**
   * 服务端**明确**说过「没有下一页」。
   *
   * 只有这个标志才允许彻底挡住翻页。直接拿 hasMore 挡是错的：SSR 内嵌数据常常
   * 根本没有 page_info，会被误判成「到底了」，翻页随即被永久锁死 —— 表现就是
   * 「只显示两条帖子，下滑无法刷新」。
   */
  private sawEnd: boolean = false;
  /** `sawEnd` 是什么时候置上的（见 END_RECHECK_MS：这个判断有时效）。 */
  private sawEndAtMs: number = 0;
  /** 上一轮翻页一条都没新增（链路可疑，见 RESTART_COOLDOWN_MS）。 */
  private pagingStuck: boolean = false;
  /**
   * 这一轮进程里有没有把信息流模板落过盘（见 saveTemplateOnce）。
   *
   * 只在第一次拿到真实首页数据时做一次：capture 要过一次桥，没必要每次刷新都做。
   */
  private templateSaved: boolean = false;
  /**
   * 原生分页链路自己的游标（和网页那条路的 nextCursor **分开**维护）。
   *
   * 两条路的游标不能混用：原生要的是"上一页响应里的 end_cursor"，网页回放那条也是，
   * 但一旦某条路失败，混着用会把另一条也带偏（表现是"上滑没反应"）。
   */
  private nativeCursor: string = '';
  /** 原生链路还有没有下一页（服务端 page_info.has_next_page）。 */
  private nativeHasMore: boolean = false;
  /** 原生已经取好、等着上滑时直接铺的那些页（**最多 NATIVE_CACHE_PAGES 页**，先进先出）。 */
  private nativeQueue: Array<NativeFeedPage> = [];
  /** 原生预取正在飞（防止上滑连点触发多次请求）。 */
  private nativeFetching: boolean = false;
  /** 上一次「重读第一页重启翻页」是什么时候。 */
  private lastRestartMs: number = 0;
  /** 加载途中又来了取数请求（例如触底）时记下来，本轮结束再跑一次，不丢。 */
  private pending: boolean = false;
  /**
   * 下一次取数要**重新读第一页**（下拉刷新），而不是接着游标翻页。
   *
   * 用标志位而不是直接调 loadFirstPage：刷新有可能正好撞上在跑的一轮，
   * 那时只能排队（pending），排队的那一轮必须知道自己的目标是第一页。
   */
  private wantFirstPage: boolean = false;
  /**
   * 首屏是**从落盘缓存铺出来的**（见 FeedCache）。
   *
   * 它决定"网络那份第一页回来之后怎么合并"：缓存那份是同一页的旧版本，所以新的那一页要
   * **整体替换**列表（replace），而不是合并到最前面 —— 否则用户会看到"新 7 条 + 旧的 7 条"。
   */
  private fromCache: boolean = false;
  /** 试过读缓存了没有（一轮进程只读一次，别每次刷新都读盘）。 */
  private cacheTried: boolean = false;

  /**
   * 本机点过转发的帖子 key。
   *
   * 为什么要有这张表：网页侧的接口里**没有**「这条我转过没有」这个字段，DOM 也不渲染它的
   * 状态，读不到就只能自己记。记在这里而不是页面里 —— 取数（翻页 / 补全 / 下拉刷新）会整体
   * 重建 MediaPost，标记必须能被补回来（见 setPosts），否则刷一次对勾就掉了。
   */
  private repostedKeys: Set<string> = new Set<string>();

  /** 忙碌状态变化（页面据此转圈 / 禁用按钮）。 */
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
  };
  /** 状态行语义变化。 */
  onStatus: (kind: FeedStatus, detail: string) => void = (kind: FeedStatus, detail: string): void => {
  };
  /** 帖子列表变化。 */
  onPosts: (posts: MediaPost[]) => void = (posts: MediaPost[]): void => {
  };
  /** 一轮加载结束（页面据此落一次轻量探针报告）。 */
  onSettled: () => void = (): void => {
  };

  list(): MediaPost[] {
    return this.posts;
  }

  isBusy(): boolean {
    return this.busy;
  }

  status(): FeedStatus {
    return this.statusKind;
  }

  detail(): string {
    return this.statusDetail;
  }

  /** 最近一次取数的路径摘要（api=… / dom=…），供探针报告与人工排查用。 */
  debugText(): string {
    return this.debug;
  }

  /** 服务端是否还说有下一页。页面据此决定要不要在接近底部时预取。 */
  hasMorePages(): boolean {
    return this.hasMore;
  }

  /**
   * 就地更新某条帖子的点赞状态。
   *
   * 点赞本身是在隐藏网页里点的（原生不构造写请求），这里只把状态跟上；
   * 返回 false 表示列表里没有这条。
   */
  setLiked(key: string, liked: boolean): boolean {
    const next: MediaPost[] | null = FeedMapper.withLiked(this.posts, key, liked);
    if (next === null) {
      return false;
    }
    this.setPosts(next);
    return true;
  }

  /**
   * 就地更新某条帖子的转发状态（转发 / 取消转发）。
   *
   * 网页上「取消转发」就是**再点一次同一个按钮**，所以原生这边只要维护这个开关即可
   * （真正点按钮在 repostPost 里，那里先用这里做乐观翻转、再用网页回报校正）。
   * 返回 false 表示列表里没有这条、或它已经是这个状态。
   */
  setReposted(key: string, reposted: boolean): boolean {
    // 先更新台账：即使这一轮列表里没有这条（或值没变），下次取数补回来时也要是对的。
    if (reposted) {
      this.repostedKeys.add(key);
    } else {
      this.repostedKeys.delete(key);
    }
    const next: MediaPost[] | null = FeedMapper.withReposted(this.posts, key, reposted);
    if (next === null) {
      return false;
    }
    this.setPosts(next);
    return true;
  }

  /** 登录态刚变化时清空：换账号或刚登录，旧帖子与旧游标都不该留着。 */
  reset(): void {
    this.debug = '';
    this.nextCursor = '';
    this.hasMore = true;
    this.sawEnd = false;
    this.sawEndAtMs = 0;
    this.pending = false;
    this.wantFirstPage = false;
    // 转发状态是本机记的，换了账号就完全不可信了。
    this.repostedKeys.clear();
    this.setPosts([]);
    this.setStatus(FeedStatus.Idle);
  }

  /**
   * 下拉刷新：丢掉游标与「到底了」的判断，重新读第一页。
   *
   * 刻意**不清空** posts —— 清空会让列表在刷新途中闪成骨架屏。新一页回来后走
   * mergePrepend 放到最前面，原有内容接在后面，列表不会跳。
   *
   * 两个"别让用户白拉一下"的处理：
   *   1) 网页没就绪（正在别处导航 / 还在水合）时**等一会儿**再读，而不是直接失败；
   *   2) 正好撞上在跑的一轮取数时，只排队（pending）是不够的 —— 那一轮结束后才会真正重读，
   *      而调用方的转圈早就收了（实测就是"动画结束很久后才刷新"）。所以这里**等它排完并
   *      跑完**（见 awaitIdle）再返回。
   */
  async refresh(): Promise<void> {
    this.nextCursor = '';
    this.hasMore = true;
    this.sawEnd = false;
    this.sawEndAtMs = 0;
    // 页面没就绪就先等它（已经就绪时这个方法立刻返回）。
    try {
      await this.bridge.awaitPageReady(REFRESH_READY_MS);
    } catch (error) {
    }
    this.wantFirstPage = true;
    if (this.busy) {
      // 已经有一轮在跑：排队。上面这些标志会被排队的那一轮读到，目标仍是第一页。
      this.pending = true;
      return;
    }
    await this.loadFeed();
  }

  /**
   * 等取数彻底空闲（含排队待跑的那一轮）。
   *
   * 下拉刷新用它把转圈撑到"真的重读过第一页"为止：`refresh()` 撞上在跑的一轮时只是排队，
   * 直接返回会让界面以为刷新完了。返回 false 表示等到超时（调用方也该收起转圈了）。
   */
  async awaitIdle(timeoutMs: number = REFRESH_IDLE_TIMEOUT_MS): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    while (this.busy || this.pending) {
      if (Date.now() >= deadline) {
        hilog.warn(DOMAIN, TAG, 'awaitIdle timeout busy=%{public}s pending=%{public}s',
          this.busy ? 'y' : 'n', this.pending ? 'y' : 'n');
        return false;
      }
      await FeedViewModel.delay(REFRESH_IDLE_POLL_MS);
    }
    return true;
  }

  /** 原生侧短暂等待（轮询用）。 */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  /**
   * 等隐藏网页就绪，**一直等到就绪或到上限**（而不是一看到未就绪就放弃）。
   *
   * 为什么：信息流的一切都建立在"网页这一份文档是活的"上面。冷启动时网页可能还在加载、
   * 或刚被别的页面（Reels / 我的 的冷启动）导航走又回来，这个窗口里读必定失败。以前这里
   * 只等一次 6 秒就报「页面尚未就绪」并收工，用户看到的就是"骨架屏/空白一直不动，
   * 得自己再拉一下"。现在改成反复等到就绪为止（上限 READY_TOTAL_MS），
   * 于是"一直刷新到 IG 页面准备好"这件事是自动完成的。
   */
  private async waitPageReady(): Promise<boolean> {
    if (this.bridge.isReady()) {
      return true;
    }
    const deadline: number = Date.now() + READY_TOTAL_MS;
    let rounds: number = 0;
    while (Date.now() < deadline) {
      const left: number = deadline - Date.now();
      const chunk: number = left > READY_SLICE_MS ? READY_SLICE_MS : left;
      await this.bridge.awaitPageReady(chunk);
      if (this.bridge.isReady()) {
        hilog.info(DOMAIN, TAG, 'page ready after %{public}d waits', rounds + 1);
        return true;
      }
      rounds++;
    }
    hilog.warn(DOMAIN, TAG, 'page not ready after %{public}dms', READY_TOTAL_MS);
    return false;
  }

  // ==========================================================================
  // 取数主流程
  // ==========================================================================

  /**
   * 读一页信息流。列表为空时读首屏，否则翻下一页。
   *
   * 加载途中重复调用不会丢：记成 pending，本轮结束后自动再跑一次。
   * （之前是直接 return，触底信号正好撞上在跑的加载就被丢掉了，表现就是
   * 「有时候刷新不出来」。）
   */
  async loadFeed(): Promise<void> {
    if (this.busy) {
      this.pending = true;
      return;
    }
    // **首屏先吃落盘缓存**（需求："进入 app 时先获取 feeds 流并缓存" + 先画后刷）：
    // 上一次那一页（30 分钟内）先铺出来，用户一进 app 就有画面；网络那份回来再整体替换。
    // 这一步必须在下面"等网页就绪"之前：等网页可能要几百毫秒到几秒，缓存只要几十毫秒。
    this.hydrateFromCache();
    if (!this.bridge.isReady()) {
      // 网页没就绪时**先把这一轮占住再等**：等就绪是个 await，不先占位的话，等的过程里再来的
      // 调用（首页自动重试、触底、下拉）会全部通过上面的 busy 检查，于是同一条流被读两遍 ——
      // 日志成对出现、翻页翻两次、网络请求翻倍（实测踩过）。
      //
      // **首屏例外**：第一页走的是**原生 HTTP**（core/NativeFeed，落盘模板 + Cookie 罐），
      // 一个字节都不经过网页，网页没就绪照样能读；以前在这里死等网页就绪，等于让用户白等
      // 好几秒。所以首屏（列表还空着）不等网页，直接进 loadFirstPage：原生那条路先把内容
      // 铺上，网页那条路在里面自己会判"没就绪就跳过"，就绪之后再补充（见 loadFirstPage）。
      const firstScreen: boolean = this.posts.length === 0;
      if (!firstScreen) {
        this.setBusy(true);
        const ready: boolean = await this.waitPageReady();
        this.setBusy(false);
        if (!ready) {
          this.setStatus(FeedStatus.PageNotReady);
          return;
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'LF enter posts=%{public}d cursor=%{public}s more=%{public}s',
      this.posts.length, this.nextCursor.length > 0 ? 'y' : 'n', this.hasMore ? 'y' : 'n');
    this.setBusy(true);
    const firstLoad: boolean = this.posts.length === 0;
    // 下拉刷新要重新读第一页，但它在状态上不算「首屏」：列表里本来就有内容，
    // 一条没新增时不该报「读不到内容」。
    const refreshing: boolean = this.wantFirstPage;
    this.wantFirstPage = false;
    try {
      if (firstLoad || refreshing) {
        await this.loadFirstPage(firstLoad, refreshing);
      } else {
        await this.loadNextPage();
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'LF error: %{public}s', (error as Error).message);
      this.setStatus(FeedStatus.Failed, (error as Error).message);
    } finally {
      this.setBusy(false);
      this.onSettled();
      if (this.pending) {
        this.pending = false;
        this.loadFeed();
      }
    }
  }

  /**
   * 首屏从**落盘缓存**铺出来（需求："进入 app 时先获取 feeds 流并缓存"，先画后刷）。
   *
   * 只在"列表还空着 + 这一轮进程还没试过"时做一次：读盘 + 映射几十毫秒，
   * 换来的是"一进 app 就有画面"而不是对着骨架屏等网络。
   *
   * 铺上之后置 `wantFirstPage`：接下来那一轮取数要**重新读第一页**（而不是接着翻页），
   * 拿到的新一页会整体替换掉这份旧内容（见 fromCache / loadFirstPage）。
   */
  private hydrateFromCache(): void {
    if (this.cacheTried || this.posts.length > 0) {
      return;
    }
    this.cacheTried = true;
    const cached: CachedFeedPage | null = FeedCache.load();
    if (cached === null) {
      return;
    }
    const mapped: MediaPost[] = [];
    for (let index: number = 0; index < cached.items.length; index++) {
      try {
        mapped.push(FeedMapper.toPost(cached.items[index], index));
      } catch (error) {
      }
    }
    if (mapped.length === 0) {
      return;
    }
    this.fromCache = true;
    this.setPosts(mapped);
    // 游标/翻页状态也先用缓存里的：万一网络那份迟迟不回，上滑照样能接着翻（新的一页会覆盖它）。
    this.nativeCursor = cached.cursor;
    this.nativeHasMore = cached.hasMore;
    this.hasMore = true;
    this.sawEnd = false;
    this.wantFirstPage = true;
    this.setStatus(FeedStatus.Idle);
    this.noteDebug(`cache=${mapped.length}(${Math.round(cached.ageMs / 1000)}s)`);
    // 缓存这批也把封面小图解出来（见 core/PosterCache）：一进来首屏就是"小图先到、真图补上"。
    PosterCache.warm(mapped);
    hilog.info(DOMAIN, TAG, 'hydrated from cache n=%{public}d age=%{public}dms',
      mapped.length, cached.ageMs);
  }

  /**
   * 触底 / 接近底部时的「取更多」入口。
   *
   * 列表滚动过程中这个入口会被反复调用；`busy` + `pending` 已经保证不会并发，
   * 这里只在**服务端明确说过到底**时才彻底挡住，否则一律允许再试一次。
   */
  requestMore(): void {
    if (this.busy) {
      this.pending = true;
      return;
    }
    if (this.posts.length === 0) {
      this.loadFeed();
      return;
    }
    if (this.sawEnd && !this.endRecheckDue()) {
      return;
    }
    // 上一轮翻页无论走哪条路都换不来新内容：这一轮改成「重读第一页」把链路重启
    // （限流，见 RESTART_COOLDOWN_MS）。不这么做的话，用户就是对着一个已经失效的
    // 分页状态一直上滑，界面上一声不吭、也永远不出新帖子。
    if (this.pagingStuck && Date.now() - this.lastRestartMs >= RESTART_COOLDOWN_MS) {
      this.lastRestartMs = Date.now();
      this.pagingStuck = false;
      this.nextCursor = '';
      this.hasMore = true;
      this.sawEnd = false;
      this.sawEndAtMs = 0;
      this.wantFirstPage = true;
      hilog.info(DOMAIN, TAG, 'paging stuck → restart from first page');
    }
    this.loadFeed();
  }

  /**
   * 「到底了」这个判断是不是已经过了有效期（到点就该允许再试一次）。
   *
   * 见 END_RECHECK_MS：服务端那句 `has_next_page: false` 有可能是暂时的（限流 / 游标过期），
   * 不能当成永久判决 —— 否则用户上滑多少轮都没用，界面还一声不吭。
   */
  private endRecheckDue(): boolean {
    const due: boolean = Date.now() - this.sawEndAtMs >= END_RECHECK_MS;
    if (due) {
      hilog.info(DOMAIN, TAG, 'end recheck: re-open paging after %{public}dms',
        Date.now() - this.sawEndAtMs);
      // 重新打开翻页：把乐观状态放回去，这一轮按正常路径（游标 → 滚页面）再要一次。
      this.sawEnd = false;
      this.hasMore = true;
    }
    return due;
  }

  /**
   * 首屏。
   *
   * 顺序刻意做成「先拿能拿的、再补完整」：
   *   1) 零等待回放一次：页面水合时通常已经自己发过 feed 请求（配置就在页面内存里），
   *      否则还能退到 SSR 内嵌的那几条。这一步一般几百毫秒，先把帖子显示出来。
   *   2) 条数不够时才触发页面重发一条完整请求，等信号、再回放整页。
   *   3) 都不行才退到 DOM 抽取。
   */
  private async loadFirstPage(asFirstLoad: boolean, prepend: boolean): Promise<void> {
    this.setStatus(FeedStatus.Loading);
    // 计时基准：把"从开始取首屏到拿到可用数据"的毫秒数打进日志，改取数路径时靠它对比
    // （capture 快路径 vs 回放 vs DOM 兜底，见 hilog 的 first ... ms=）。
    const startedMs: number = Date.now();
    // ---- 「不走网页」的第一发 ---------------------------------------------
    // 两组来源，都走 core/NativeFeed（落盘模板 + Cookie 罐直接 POST）：
    //   1) **预热**：EntryAbility.onCreate 里已经发出去的那一发，此刻多半已经躺在内存里
    //      （见 NativeFeed.warmStart / takeWarm）—— 取到就零等待铺上；
    //   2) 没预热到就自己发一发（1.2~2.4 秒）。
    // 拿到的是一页真数据，铺上去用户立刻有画面；网页那条路只做"补充合并"（见下面 nativeOwnsFirstPage）。
    let first: NativeFeedPage | null = NativeFeed.takeWarm(NATIVE_WARM_MAX_AGE_MS);
    if (first !== null) {
      hilog.info(DOMAIN, TAG, 'native first from warm n=%{public}d ms=%{public}d',
        first.items.length, Date.now() - startedMs);
    } else {
      // 预热没赶上（或没有模板/没登录）：自己发一发，仍然是原生、仍然不碰网页。
      first = await NativeFeed.fetchPage(NATIVE_FIRST_COUNT, '');
      hilog.info(DOMAIN, TAG, 'native first fetched tpl=%{public}s n=%{public}d',
        NativeFeed.templateAge(), first === null ? 0 : first.items.length);
    }
    if (first !== null) {
      // 首屏是缓存铺的 → 网络这份要**整体替换**（否则新 7 条后面还挂着旧的 7 条，见 fromCache）。
      const replaceCached: boolean = this.fromCache;
      this.fromCache = false;
      await this.applyPayload(this.pagePayload(first), asFirstLoad, false, prepend,
        asFirstLoad || replaceCached);
      this.nativeCursor = first.nextCursor;
      this.nativeHasMore = first.hasMore;
      this.debug = `${this.debug} native(${first.items.length})`;
      hilog.info(DOMAIN, TAG, 'native first applied n=%{public}d ms=%{public}d cursor=%{public}s more=%{public}s',
        first.items.length, Date.now() - startedMs, first.nextCursor.length > 0 ? 'y' : 'n',
        first.hasMore ? 'y' : 'n');
      // 把这一页落盘：**下次冷启动**就能先画它（见 core/FeedCache），不用等网络。
      FeedCache.save(first.items, first.nextCursor, first.hasMore);
      // 首屏封面预解码：低一档的小图先解出来垫在真图下面（见 core/PosterCache）。
      PosterCache.warm(this.posts);
      // 首屏一铺上就**在后台把后面几页抓好**：用户上滑时那些页已经在内存里（见 prefetchNativePage）。
      this.prefetchNativePage();
    }
    const early: FeedPayloadDto | null = await this.replayTimeline('');
    // 原生那条路已经给了"真·第一页"时，网页这边只允许**替换**，不允许把 SSR/旧的 prepend 进来 ——
    // 那份 HTML 里的 SSR 数据是缓存的旧内容，混进新列表就成了"固定显示那几个帖子"。
    const nativeOwnsFirstPage: boolean = this.nativeCursor.length > 0;
    if (early !== null && !(nativeOwnsFirstPage && (early.src === 'ssr' || early.src === undefined))) {
      // 同上：原生已经给了第一页时，网页这一份**只合并、不替换、也不 prepend 到最前**
      // （prepend 会把缓存的 SSR 旧内容排到最新几条前面）。
      await this.applyPayload(early, asFirstLoad, false,
        nativeOwnsFirstPage ? false : prepend, false);
      const got: number = (early.items ?? []).length;
      this.debug = `${this.debug} first=${early.src}(${got})`;
      hilog.info(DOMAIN, TAG, 'first early src=%{public}s n=%{public}d ms=%{public}d',
        early.src ?? '-', got, Date.now() - startedMs);
      if (!nativeOwnsFirstPage && early.src === 'replay' && got >= FIRST_PAGE_ENOUGH) {
        // 已经是页面自己那条完整请求的结果，首屏到此就够，省掉触发 + 等信号。
        return;
      }
      if (!nativeOwnsFirstPage && early.src === 'capture' && got > 0) {
        // 快路径命中：这一份就是页面自己刚收到的响应（探针抓的 HTTP 响应体），
        // 一个字节的网络都没花，也不必再触发页面重发请求。
        // 这里不卡条数：捕获到的必然是"页面真实那一页"（一页就 3 条也是它）。
        return;
      }
      if (nativeOwnsFirstPage) {
        // 原生已经铺好 7 条了：网页那条路只是"补充"，没必要为它再触发一轮（省几秒等待）。
        hilog.info(DOMAIN, TAG, 'first web refine only (native owns page) n=%{public}d', got);
        return;
      }
    }

    // 网页还没就绪时**这一轮就到此为止**：首屏现在不等网页（见 loadFeed），原生那条路已经把
    // 第一页铺上了，而下面那几轮"触发页面重发 + 等信号"在没就绪时只会一轮轮白等（每轮几百
    // 毫秒到几秒）。页面就绪之后 handlePageReady 会再读一次，那时再补网页这一份。
    if (nativeOwnsFirstPage && !this.bridge.isReady()) {
      hilog.info(DOMAIN, TAG, 'first web refine skipped: page not ready (native owns page)');
      return;
    }

    // 首屏要**死等"真的发过请求"的那一页**，不能拿到 SSR 就收工。
    //
    // 为什么：冷启动时网页 HTML 里带的 SSR 那几条（`src=ssr`）会被 WebView 的 HTTP 缓存
    // 原样复用 —— 每次打开 app 都是同一份 HTML、同几条帖子，用户看到的就是"固定显示那几个，
    // 要往下滑（触发网页自己重新请求）才有新的"。所以这里最多试几轮：每轮重新登记等待 →
    // 点一次首页（逼页面自己重发请求）→ 等信号 → 回放；一旦回放成功（`src=replay` 且有条目）
    // 就**整体替换**列表（见 applyPayload 的 replace）并收工；那之前 SSR 那几条先顶着，
    // 用户不至于对着空白等。
    let sawFresh: boolean = false;
    for (let round: number = 1; round <= FRESH_ROUNDS; round++) {
      const budget: number = round === 1
        ? (early !== null ? REFINE_SIGNAL_MS : FIRST_SIGNAL_MS)
        : REFINE_SIGNAL_MS;
      const base: number = this.bridge.replaySeq();
      const ready: Promise<string> = this.bridge.awaitNewReplay(TIMELINE_OPS, base, budget);
      try {
        const trigger: string = await this.bridge.runBridge(TRIGGER_FEED_SCRIPT, TRIGGER_SCRIPT_MS);
        hilog.info(DOMAIN, TAG, 'first trigger round=%{public}d -> %{public}s', round, trigger);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'first trigger round=%{public}d failed: %{public}s',
          round, (error as Error).message);
      }
      const signal: string = await ready;
      const payload: FeedPayloadDto | null = await this.replayTimeline('');
      if (payload === null) {
        hilog.info(DOMAIN, TAG, 'first round=%{public}d signal=%{public}s payload=none',
          round, signal);
        continue;
      }
      // 「真·第一页」有两条来源：页面自己那条请求的原始响应（capture，探针抓的）
      // 或者我们用页面模板回放出来的那一发（replay）。两者都是**页面真实请求的结果**，
      // 不是 SSR 里那份被 HTTP 缓存复用的旧数据 —— 所以都算 fresh（要整体替换列表）。
      //
      // 注意**不要**拿 FIRST_PAGE_ENOUGH 卡这里：实测网页版一页就 3 条（游标翻页），
      // 卡 8 条的话每轮都"不够"，会白白多等两轮信号（十几秒）才收工。条数够不够由
      // 翻页去补，首屏只要求"拿到的是页面真实那一页"。
      const got: number = (payload.items ?? []).length;
      const fresh: boolean = (payload.src === 'capture' || payload.src === 'replay') && got > 0;
      hilog.info(DOMAIN, TAG, 'first round=%{public}d signal=%{public}s src=%{public}s n=%{public}d ms=%{public}d',
        round, signal, payload.src ?? '-', got, Date.now() - startedMs);
      // 真·第一页 → 整体替换；否则（SSR/空）先 prepend 顶着，下一轮接着要。
      //
      // 但**原生那条路已经给了第一页时不许替换**：网页这边给的一页往往更少（实测 3~4 条 vs
      // 原生 7 条），一替换就等于"冷启动先显示 7 条、一秒后缩回 4 条"——用户看到的是列表往回缩。
      // 这种情况下按 shortcode 合并（prepend=false + replace=false），多的留下、重的去掉。
      const keepNative: boolean = nativeOwnsFirstPage;
      const replace: boolean = asFirstLoad && fresh && !keepNative;
      await this.applyPayload(payload, asFirstLoad, false, keepNative ? false : true, replace);
      if (fresh) {
        sawFresh = true;
        // 拿到真的第一页了：顺手把信息流那条请求模板落盘一次。
        // 下次冷启动，"不走网页"的那一发（core/NativeFeed）就靠它 —— 没有落盘的话
        // 每次都还得先让网页跑起来发一条请求，快路径无从谈起。
        this.saveTemplateOnce();
        return;
      }
      if (!asFirstLoad && this.posts.length > 0) {
        // 下拉刷新那一轮不折腾：有内容就够了。
        return;
      }
    }
    if (this.posts.length > 0) {
      // 几轮都没等到"真·第一页"：SSR 那几条也算有内容，先留着（下次刷新/翻页会补上）。
      hilog.info(DOMAIN, TAG, 'first no fresh page in %{public}d rounds (ssr kept)', FRESH_ROUNDS);
      return;
    }
    if (this.posts.length > 0) {
      // 屏幕上至少还有早先 SSR 的那几条，不必再报「读不到」。
      return;
    }
    const dom: FeedPayloadDto | null = await this.tryDom();
    if (dom !== null) {
      await this.applyPayload(dom, asFirstLoad, true, prepend);
      return;
    }
    this.setStatus(FeedStatus.Unparsable);
  }

  /** 翻下一页：先吃原生缓存，再走游标回放，最后退到滚动。 */
  private async loadNextPage(): Promise<void> {
    if (this.sawEnd) {
      // 服务端已经明确说过没有下一页，不必再发请求 —— 除非这个判断已经过期（见 END_RECHECK_MS）。
      if (!this.endRecheckDue()) {
        this.setStatus(FeedStatus.NoMore);
        return;
      }
    }
    this.setStatus(FeedStatus.LoadingMore);
    const before: number = this.posts.length;

    // ---- 1) 原生缓存：上滑时**零等待**（那些页是上一屏显示完就抓好放在内存里的）----
    const cached: NativeFeedPage | null = this.takeNativePage();
    if (cached !== null) {
      await this.applyPayload(this.pagePayload(cached), false, false);
      this.nativeCursor = cached.nextCursor;
      this.nativeHasMore = cached.hasMore;
      hilog.info(DOMAIN, TAG, 'native page from cache n=%{public}d added=%{public}d queued=%{public}d',
        cached.items.length, this.posts.length - before, this.nativeQueue.length);
      // 铺完立刻把队列补满 —— 这样"上滑加载"永远是在吃已经取好的那几页。
      this.prefetchNativePage();
      if (this.posts.length > before) {
        this.pagingStuck = false;
        return;
      }
    }
    // ---- 2) 缓存还没好（用户滑得比预取快）：当场用原生要一页，仍然不碰网页 ----
    if (this.nativeHasMore && this.nativeCursor.length > 0) {
      const live: NativeFeedPage | null = await NativeFeed.fetchPage(NATIVE_PAGE_COUNT, this.nativeCursor);
      if (live !== null) {
        await this.applyPayload(this.pagePayload(live), false, false);
        this.nativeCursor = live.nextCursor;
        this.nativeHasMore = live.hasMore;
        hilog.info(DOMAIN, TAG, 'native page live n=%{public}d ms=%{public}d added=%{public}d',
          live.items.length, live.ms, this.posts.length - before);
        this.prefetchNativePage();
        if (this.posts.length > before) {
          this.pagingStuck = false;
          return;
        }
      }
    }

    if (this.nextCursor.length > 0) {
      const payload: FeedPayloadDto | null = await this.replayTimeline(this.nextCursor);
      if (payload !== null) {
        await this.applyPayload(payload, false, false);
        if (this.posts.length > before) {
          this.pagingStuck = false;
          return;
        }
        hilog.info(DOMAIN, TAG, 'cursor page added nothing, falling back to scroll');
      }
    }

    await this.scrollForNextPage();

    // 两条路都没换来新内容：**把这个游标丢掉**。
    //
    // 为什么必须丢：游标失效（过期 / 被限流 / 服务端换了分页 token）时，拿它反复回放只会
    // 一遍遍拿到同一页，而"拿不到新内容"本身不改变任何状态 —— 于是每一轮都重复同一个
    // 死游标，永远不会去看页面自己那边的新请求。这就是「上滑很多轮之后再也要不出新帖子」
    // 的直接原因。丢掉之后下一轮直接走滚动兜底：滚页面 → 页面自己发下一页 → 回放它刚发的
    // 那一条（那条带着页面自己的游标），链路就重新接上了。
    if (this.posts.length === before) {
      this.pagingStuck = true;
      if (this.nextCursor.length > 0) {
        hilog.info(DOMAIN, TAG, 'cursor yielded nothing → dropped (posts=%{public}d)',
          this.posts.length);
        this.nextCursor = '';
      }
    } else {
      this.pagingStuck = false;
    }
  }

  /**
   * 滚动兜底：滚到底 → 等页面自己发出下一页请求 → 回放它刚存下的那条配置。
   *
   * 只在游标路径不可用时才走到这里，所以轮数刻意压到 2 轮、每轮等待也压短，
   * 免得失败时把界面卡很久。
   */
  private async scrollForNextPage(): Promise<void> {
    for (let round: number = 0; round < PAGING_ROUNDS; round++) {
      const before: number = this.posts.length;
      const base: number = this.bridge.replaySeq();
      const arrived: Promise<string> =
        this.bridge.awaitNewReplay(TIMELINE_OPS, base, PAGING_SIGNAL_MS);
      const scrolled: string = await this.bridge.runBridge(SCROLL_BOTTOM_SCRIPT, SCROLL_SCRIPT_MS);
      const signal: string = await arrived;
      hilog.info(DOMAIN, TAG, 'scroll round=%{public}d scroll=%{public}s signal=%{public}s',
        round, scrolled, signal);
      const payload: FeedPayloadDto | null = await this.replayTimeline('');
      if (payload !== null) {
        await this.applyPayload(payload, false, false);
        if (this.posts.length > before) {
          return;
        }
      }
      if (signal !== 'signal') {
        // 这一轮页面压根没再发请求，再滚也不会有新页。
        break;
      }
    }
    // 没拿到新内容：服务端明确说没下一页就明说，否则保持安静，让用户再触发一次。
    this.setStatus(this.sawEnd ? FeedStatus.NoMore : FeedStatus.Idle);
  }

  /** 把一份载荷落到列表、游标与状态行上。 */
  private async applyPayload(payload: FeedPayloadDto | null, firstLoad: boolean,
                             usedDom: boolean, prepend: boolean = false,
                             replace: boolean = false): Promise<void> {
    if (payload === null) {
      this.setStatus(FeedStatus.Unparsable);
      return;
    }
    if (payload.state !== PayloadState.OK) {
      if (payload.state === PayloadState.EMPTY) {
        if (payload.hasNext === false) {
          // 服务端明确说没有了，这才是真的到底。
          this.sawEnd = true;
          this.sawEndAtMs = Date.now();
          this.hasMore = false;
          this.setStatus(this.posts.length === 0 ? FeedStatus.NoneVisible : FeedStatus.NoMore);
          return;
        }
        // 连接回来了、但里面没有可映射的媒体（整页都是被过滤掉的推荐卡片之类）：
        // 只要服务端给了新游标，就说明分页确实往前走过一页 —— 把游标收下。
        // 不收的话会拿同一个旧游标反复要同一页，每一轮都"没有新内容"，翻页就此停死。
        const emptyCursor: string = payload.nextCursor ?? '';
        if (emptyCursor.length > 0 && emptyCursor !== this.nextCursor) {
          hilog.info(DOMAIN, TAG, 'empty page advanced cursor (%{public}d chars)',
            emptyCursor.length);
          this.nextCursor = emptyCursor;
        }
        // 没有明确依据（回放失败、SSR 没带 page_info 等）：既不清空屏幕上已有的内容，
        // 也不谎报「没有更多」。
        this.setStatus(this.posts.length === 0 ? FeedStatus.NoneVisible : FeedStatus.Idle);
      } else {
        this.setStatus(FeedStatus.Failed, payload.message ?? payload.state);
      }
      return;
    }

    // 翻页状态：只有服务端**明确**给出 has_next_page 才据此改变；没有依据时保持乐观，
    // 免得把翻页锁死（旧实现就是在这里被没带 page_info 的 SSR 数据判成「到底了」）。
    const cursor: string = payload.nextCursor ?? '';
    if (cursor.length > 0) {
      this.nextCursor = cursor;
    }
    this.sawEnd = payload.hasNext === false;
    if (this.sawEnd) {
      this.sawEndAtMs = Date.now();
    }
    this.hasMore = !this.sawEnd;

    const items: FeedItemDto[] = payload.items ?? [];
    hilog.info(DOMAIN, TAG, 'LF items=%{public}d src=%{public}s more=%{public}s',
      items.length, payload.src ?? '-', this.hasMore ? 'y' : 'n');

    // 逐条映射，单条异常不影响整体。
    const mapped: MediaPost[] = [];
    for (let index: number = 0; index < items.length; index++) {
      try {
        mapped.push(FeedMapper.toPost(items[index], index));
      } catch (error) {
        hilog.error(DOMAIN, TAG, 'LF map item %{public}d failed: %{public}s',
          index, (error as Error).message);
      }
    }
    FeedMapper.logKeys('mapped', mapped);

    // 累积去重，不再整体替换。下拉刷新反过来：新一页放头部（见 mergePrepend）。
    // `replace` 是给首屏用的：**重新要来的第一页整体顶掉列表**（见 loadFirstPage 的说明）。
    let merged: MergeResult;
    if (replace) {
      merged = new MergeResult(mapped, mapped.length);
    } else if (prepend) {
      merged = FeedMapper.mergePrepend(mapped, this.posts);
    } else {
      merged = FeedMapper.merge(this.posts, mapped);
    }
    this.setPosts(merged.posts);
    FeedMapper.logKeys(prepend ? 'prepended' : 'merged', merged.posts);

    this.debug = `${this.debug} +${merged.changed}/${mapped.length}`;
    if (merged.changed > 0) {
      this.setStatus(FeedStatus.Idle);
    } else if (this.posts.length === 0) {
      // 一条都没有 —— 这才是真的"没读到"。
      //
      // 判据必须是**合并后的列表长度**，不能是"这一轮开始时列表是空的"（firstLoad）：
      // 首屏这一轮里，第一次回放通常已经把页面 SSR 的那几条读进来了，第二次回放（触发之后
      // 再读一次）拿到的还是**同一页**，于是 changed 就是 0 —— 早先这里按 firstLoad 报
      // 「没有读取到帖子。」，屏幕上明明有帖子却挂着这句话（实测每次冷启动都会出现，
      // 用户看到的就是"没有帖子"）。
      this.setStatus(FeedStatus.NoneRead);
    } else if (this.sawEnd) {
      this.setStatus(FeedStatus.NoMore);
    } else {
      // 还有下一页却一条都没新增：不谎报「没有更多」，静默等下一次触发。
      this.setStatus(FeedStatus.Idle);
    }

    // 只有 DOM 兜底才需要补全：接口路径下 videoUrl / images / counts 已经齐了，
    // 再回放一次纯属重复请求。
    if (usedDom && this.posts.length > 0) {
      await this.enrichFromApi();
    }
  }

  /**
   * 回放页面那条首页信息流查询。
   *
   * cursor 为空回放最近一次抓到的请求；非空则把 variables.after 换成该游标去要下一页。
   * 返回 null 表示这次没拿到可用结构（桥未就绪 / 脚本超时 / 解析失败 / 游标插不进去）；
   * state 为 ok 或 empty 都原样返回，由调用方决定怎么处理。
   */
  private async replayTimeline(cursor: string): Promise<FeedPayloadDto | null> {
    try {
      const raw: string = await this.bridge.runBridge(timelineScript(cursor), TIMELINE_SCRIPT_MS);
      const payload: FeedPayloadDto = JSON.parse(raw) as FeedPayloadDto;
      if (payload.state === PayloadState.OK || payload.state === PayloadState.EMPTY) {
        // 把脚本带回的字段名清单（转发/分享计数到底叫什么）也记进 debug，
        // 供 hilog 与探针查看 —— 这两个字段名不确定，靠它确认。
        const extra: string = payload.debug ?? '';
        this.noteDebug(`api=${(payload.items ?? []).length}${cursor.length > 0 ? '/cur' : ''}`
          + (extra.length > 0 ? ` ${extra}` : ''));
        return payload;
      }
      this.debug = `api:${payload.state}`;
    } catch (error) {
    }
    return null;
  }

  /**
   * 把信息流请求模板存到原生并落盘（一轮进程只做一次）。
   *
   * 不 await：这是给**下次**冷启动用的，不该拖慢当前这一屏。
   */
  private saveTemplateOnce(): void {
    if (this.templateSaved) {
      return;
    }
    this.templateSaved = true;
    ApiRegistry.getInstance().capture(TIMELINE_OPS[0]).then((ok: boolean): void => {
      hilog.info(DOMAIN, TAG, 'feed template saved=%{public}s', ok ? 'y' : 'n');
    }).catch((): void => {
    });
  }

  // ---- 原生分页（缓存两页，上滑直接吃）-------------------------------------

  /** 一页 → 回调用的载荷（两处都用它，字段别写两遍）。 */
  private pagePayload(page: NativeFeedPage): FeedPayloadDto {
    return {
      state: PayloadState.OK,
      src: NATIVE_SRC,
      items: page.items,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore
    };
  }

  /**
   * 后台把缓存**补满到 NATIVE_CACHE_PAGES 页**（不阻塞 UI，不 await）。
   *
   * 触发时机：每次铺完一页之后（首屏、缓存页、现抓的一页）。补的顺序就是游标链的顺序：
   * 队列空了就从 `nativeCursor` 接着要，队列非空就从**队尾那一页的 nextCursor** 接着要。
   * 已经在飞、服务端说没有下一页、或游标为空时直接跳过 —— 别把同一个游标重复要几遍。
   */
  private prefetchNativePage(): void {
    // 深度固定 2 页：上滑时"队列里已经有下一页"是 feeds 流畅的关键，不按网络类型缩水
    // （页面 JSON 一页 70~160KB，比视频小得多；流量的大头在播放器缓冲，已经收到 2 秒）。
    if (this.nativeFetching || this.nativeQueue.length >= NATIVE_CACHE_PAGES) {
      return;
    }
    if (!this.nativeHasMore) {
      return;
    }
    const cursor: string = this.nativeQueue.length > 0
      ? this.nativeQueue[this.nativeQueue.length - 1].nextCursor
      : this.nativeCursor;
    if (cursor.length === 0) {
      return;
    }
    this.nativeFetching = true;
    NativeFeed.fetchPage(NATIVE_PAGE_COUNT, cursor).then((page: NativeFeedPage | null): void => {
      this.nativeFetching = false;
      if (page === null) {
        return;
      }
      this.nativeQueue.push(page);
      // 服务端这一页的 has_next_page 就是整条链的最新判断。
      this.nativeHasMore = page.hasMore;
      hilog.info(DOMAIN, TAG, 'native prefetch ready n=%{public}d ms=%{public}d more=%{public}s queued=%{public}d',
        page.items.length, page.ms, page.hasMore ? 'y' : 'n', this.nativeQueue.length);
      // 还差一页就继续补（递归一层，深度由 NATIVE_CACHE_PAGES 封顶）。
      this.prefetchNativePage();
    }).catch((): void => {
      this.nativeFetching = false;
    });
  }

  /** 取走缓存里最前面的那一页（先进先出，取走即出队，避免同一页铺两遍）。 */
  private takeNativePage(): NativeFeedPage | null {
    if (this.nativeQueue.length === 0) {
      return null;
    }
    const page: NativeFeedPage | undefined = this.nativeQueue.shift();
    return page === undefined ? null : page;
  }

  /** DOM 兜底抽取。 */
  private async tryDom(): Promise<FeedPayloadDto | null> {
    try {
      const raw: string = await this.bridge.runBridge(FEED_SCRIPT, DOM_SCRIPT_MS);
      const payload: FeedPayloadDto = JSON.parse(raw) as FeedPayloadDto;
      this.noteDebug(`dom=${(payload.items ?? []).length} ${payload.debug ?? ''}`);
      return payload;
    } catch (error) {
      return null;
    }
  }

  /**
   * 记一行 debug 文本，并**同时打到 hilog**。
   *
   * 这段文本里带着信息流脚本回传的字段名清单（转发/分享计数到底叫什么，见
   * WebScripts 的 namesByRe / keyDump）—— 探针面板里有，但探针要手点；
   * 打一行日志，`hilog | grep feed debug` 当场就能看到，排查这类"某个计数不显示"最省事。
   */
  private noteDebug(text: string): void {
    this.debug = text;
    hilog.info(DOMAIN, TAG, 'feed debug: %{public}s', text);
  }

  /**
   * 用首页接口的结果按 shortcode 补齐原生卡片缺的东西：
   * 视频的真实地址 `video_versions[].url`、多图 `carousel_media[]`、精确计数。
   */
  private async enrichFromApi(): Promise<void> {
    let payload: FeedPayloadDto;
    try {
      const raw: string = await this.bridge.runBridge(timelineScript(''), ENRICH_SCRIPT_MS);
      payload = JSON.parse(raw) as FeedPayloadDto;
    } catch (error) {
      return;
    }
    if (payload.state !== PayloadState.OK) {
      this.debug = `api:${payload.state}`;
      return;
    }
    const result: MergeResult = FeedMapper.enrich(this.posts, payload.items ?? []);
    hilog.info(DOMAIN, TAG, 'enrich before=%{public}d after=%{public}d changed=%{public}d',
      this.posts.length, result.posts.length, result.changed);
    if (result.changed > 0) {
      this.setPosts(result.posts);
      this.noteDebug(`${this.debug} +api${result.changed}`);
    }
  }

  // ---- 内部状态转发 --------------------------------------------------------

  private setPosts(posts: MediaPost[]): void {
    // 所有取数路径都从这里过：重建出来的帖子是「网页告诉我们的样子」，而转发状态网页不知道，
    // 于是统一在这儿按台账补一次 —— 翻页、补全、下拉刷新之后对勾都不会掉。
    const restored: MediaPost[] = this.applyRepostedLedger(posts);
    this.posts = restored;
    this.onPosts(restored);
  }

  /** 按 repostedKeys 把「本机转过」的标记补回列表（没变就原样返回，省一次无谓的重绘）。 */
  private applyRepostedLedger(posts: MediaPost[]): MediaPost[] {
    if (this.repostedKeys.size === 0) {
      return posts;
    }
    let changed: boolean = false;
    const next: MediaPost[] = [];
    for (let index: number = 0; index < posts.length; index++) {
      const post: MediaPost = posts[index];
      if (this.repostedKeys.has(FeedMapper.keyOf(post))) {
        // 本机转过的：标记补成"已转发"，**转发数至少给 1** ——
        // 接口/网页都可能不给这个数（见 FeedMapper.withReposted 的说明），
        // 那样刚转过的帖子在刷新后又会变成没有数字。
        const count: number = Math.max(post.repostCount, 1);
        if (!post.reposted || post.repostCount !== count) {
          changed = true;
          next.push(FeedMapper.withState(post, post.liked, true, count));
          continue;
        }
      }
      next.push(post);
    }
    return changed ? next : posts;
  }

  private setBusy(busy: boolean): void {
    this.busy = busy;
    this.onBusy(busy);
  }

  private setStatus(kind: FeedStatus, detail: string = ''): void {
    this.statusKind = kind;
    this.statusDetail = detail;
    this.onStatus(kind, detail);
  }
}
