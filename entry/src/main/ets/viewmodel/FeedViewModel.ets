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
  FEED_SCRIPT
} from '../bridge/WebScripts';
import { FeedItemDto, FeedPayloadDto, PayloadState } from '../model/FeedDto';
import { FeedStatus } from '../model/FeedStatus';
import { FeedMapper, MergeResult } from '../model/FeedMapper';
import { MediaPost } from '../model/MediaPost';
import { NativeFeed, NativeFeedPage, NativeFetchResult } from '../core/NativeFeed';
import { CachedFeedPage, FeedCache } from '../core/FeedCache';
import { PosterCache } from '../core/PosterCache';

const DOMAIN: number = 0xFF00;
const TAG: string = 'FeedViewModel';

/**
 * 一页「为你推荐」（页面注入的探索流那一发的结果）。
 *
 * 为什么要带游标：首页的列表是**两段**拼起来的——关注流（时间线）在前、探索流在后，
 * 两段各自翻页。探索流这一段以前只有一个"返回帖子数组"的注入接口，因此**永远只可能有一页**
 * （用户报的"探索流翻不出更多帖子"就是这个）。带上 `cursor` / `hasMore` 之后，
 * 触底就能接着要下一页（见 FeedViewModel.loadExplore / loadNextPage）。
 */
export class FeedRecommendedPage {
  readonly posts: Array<MediaPost>;
  /** 下一页游标（空串 = 这一页之后没有了）。 */
  readonly cursor: string;
  /** 服务端说还有没有下一页（`more_available`）。 */
  readonly hasMore: boolean;

  constructor(posts: Array<MediaPost>, cursor: string, hasMore: boolean) {
    this.posts = posts;
    this.cursor = cursor;
    this.hasMore = hasMore;
  }
}

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


const DOM_SCRIPT_MS: number = 15000;
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
  /**
   * 现在这份列表是**信息流**还是**为你推荐**。
   *
   * 新注册的账号还没有关注任何人，IG 的首页时间线会回**空**（`feed_items: []`），
   * 而官方 App 这时展示的是「为你推荐」（探索那套内容）。这里照同一个逻辑：
   * 第一页读出来是 0 条 → 用 `loadRecommended`（页面注入，走探索流）补一份，
   * `mode` 切成 `recommended`；一旦时间线真的有内容了（关注了人 / 下拉刷新）就切回 `feed`。
   *
   * **判据只看服务端数据**（第一页条目数），不猜：这样"空时间线"和"读失败"不会混为一谈
   * —— 读失败会走 `FeedStatus.Failed`，仍然报错，不会被推荐内容盖掉。
   */
  private mode: string = 'feed';
  /**
   * **关注流那一段**（`feed/timeline/` 给的帖子）。
   *
   * 首页列表现在是两段拼起来的，顺序就是用户要的：
   *   关注流 → 提示卡片 → 探索流
   * 关注流一条都没有（这个账号"关注的人的最新帖子已看完"，见 core/NativeFeed.markCaughtUp）时，
   * 提示卡片就落在**列表最顶上**，后面直接是探索流 —— 同一套规则，不用两个分支。
   */
  private following: Array<MediaPost> = [];
  /** **探索流那一段**（`discover/topical_explore/`，见 NativeSearch.recommendedPage）。 */
  private explore: Array<MediaPost> = [];
  /** 探索流的下一页游标（空串 = 还没拉过 / 到底了）。 */
  private exploreCursor: string = '';
  /** 探索流还有没有下一页（服务端 `more_available`）。 */
  private exploreHasMore: boolean = false;
  /** 服务端说"探索流到底了"的时刻（见 END_RECHECK_MS：这个判断有时效）。 */
  private exploreEndAtMs: number = 0;
  /** 提示卡片在合并列表里的下标（-1 = 不显示，见 composePosts）。 */
  private hintIndex: number = -1;
  /**
   * 这一轮取数要去翻**探索流**（见 requestMore）。
   *
   * 用标志位而不是直接 await：翻页必须走 `loadFeed` 那条排队/空闲判断，
   * 否则触底连点会并发发请求（`busy`/`pending` 就是为这个存在的）。
   */
  private wantExploreNext: boolean = false;
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
  /**
   * 列表性质变了：`feed` = 信息流，`recommended` = 为你推荐（见 mode 的说明）。
   *
   * 页面据此显示"为你推荐"那行提示；列表本身照旧走 onPosts。
   */
  onMode: (mode: string) => void = (mode: string): void => {
  };
  /**
   * 取一页「为你推荐」（页面注入：走探索流，见 core/NativeSearch.recommendedPage）。
   *
   * @param cursor 空串 = 第一页；否则是上一页给的游标（两段的游标互不通用，别混）。
   * 默认返回空页 —— 没注入时行为与以前完全一致（关注流空着就空着）。
   */
  loadRecommended: (cursor: string) => Promise<FeedRecommendedPage> =
    (cursor: string): Promise<FeedRecommendedPage> => {
      return Promise.resolve(new FeedRecommendedPage([], '', false));
    };
  /** 提示卡片该画在第几条之前（-1 = 不画，见 composePosts）。 */
  onHint: (index: number) => void = (index: number): void => {
  };

  list(): MediaPost[] {
    return this.posts;
  }

  /** 现在这份列表是信息流还是为你推荐（见 mode 的说明）。 */
  feedMode(): string {
    return this.mode;
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
    // 换账号后两段内容都是上一个人的，一起作废（见 mode 与 following/explore 的说明）。
    this.mode = 'feed';
    this.following = [];
    this.explore = [];
    this.exploreCursor = '';
    this.exploreHasMore = false;
    this.exploreEndAtMs = 0;
    this.hintIndex = -1;
    // 转发状态是本机记的，换了账号就完全不可信了。
    this.repostedKeys.clear();
    this.setPosts([]);
    this.onHint(-1);
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
    /*
     * **不再等网页就绪**：刷新走的是原生 `feed/timeline/`（core/NativeFeed），
     * 一个字节都不经过隐藏网页。以前这里先 `awaitPageReady(6000)` —— 网页正在水合 /
     * 被别的功能导航 / 后台挂起时白白多等最多 6 秒，用户看到的就是"下拉之后半天不刷新"。
     */
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
    /*
     * **不再等网页就绪**（这是"刷新/翻页慢"的主因之一）。
     *
     * 首屏与翻页都走原生 `feed/timeline/`，只有最后的 DOM 兜底才需要网页 ——
     * 而那条路自己会快速失败（读不到就报 Unparsable），不该让整条链先陪网页等
     * 最多 30 秒（`waitPageReady` 的老实现）。
     */
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
        /*
         * 第一页到手之后：**时间为空就补「为你推荐」**（见 mode 的说明）。
         * 新注册的账号还没关注任何人，IG 的时间线会回空 —— 官方 App 这时展示的也是推荐内容，
         * 否则用户看到的就是一屏空白。关注了人 / 下拉刷新拿到真内容后会自动切回信息流。
         */
        await this.maybeLoadRecommended();
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
   * 第一页到手之后：决定这一屏是"关注流为主"还是"关注流已看完、全是推荐"，
   * 并**重新要一页探索流**（见 loadExplore）。
   *
   * 为什么每次都要重新要探索流：用户说的"feeds 现在没办法刷新新的帖子"——关注流对这个账号
   * 是空的（`end_of_feed_demarcator`，见 core/NativeFeed.markCaughtUp），屏幕上那屏内容**全部**
   * 来自探索流；不重取它，下拉刷新就什么都变不出来（以前就是这样）。
   *
   * 判据只看"关注流这一段是几条"，不猜：
   *   · 0 条（看完了）→ 提示卡片落**列表最顶上**，后面全是探索流，`mode='recommended'`；
   *   · 有内容 → 关注流在前，提示卡片夹在它后面，探索流接在后面，`mode='feed'`。
   */
  private async maybeLoadRecommended(): Promise<void> {
    const caughtUp: boolean = this.following.length === 0;
    const nextMode: string = caughtUp ? 'recommended' : 'feed';
    if (this.mode !== nextMode) {
      this.mode = nextMode;
      this.onMode(nextMode);
      hilog.info(DOMAIN, TAG, 'feed mode → %{public}s (following=%{public}d)',
        nextMode, this.following.length);
    }
    // 刷新/首屏都重新要探索流第一页：这一发才是"新帖子"的来源（见上面那段说明）。
    await this.loadExplore(true);
    if (this.explore.length === 0 && this.following.length === 0) {
      hilog.info(DOMAIN, TAG, 'timeline empty and no recommended content');
      this.setStatus(FeedStatus.NoneVisible);
    }
  }

  /**
   * 拉一页探索流（`forReset = true` 时重新要第一页，整体替换探索那一段）。
   *
   * 失败不清屏：屏幕上已经有的那几段照旧，只把状态行留给上一次的语义。
   */
  private async loadExplore(forReset: boolean): Promise<void> {
    const cursor: string = forReset ? '' : this.exploreCursor;
    if (!forReset && cursor.length === 0) {
      return;
    }
    let page: FeedRecommendedPage;
    try {
      page = await this.loadRecommended(cursor);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'explore load failed: %{public}s', (error as Error).message);
      return;
    }
    if (page.posts.length === 0) {
      // 服务端这一页没东西：到底了。别把屏幕上的探索流清掉（下次刷新会重取）。
      this.exploreHasMore = false;
      this.exploreEndAtMs = Date.now();
      hilog.info(DOMAIN, TAG, 'explore page empty reset=%{public}s', `${forReset}`);
      return;
    }
    if (forReset) {
      this.explore = page.posts;
      this.exploreCursor = page.cursor;
    } else {
      const merged: MergeResult = FeedMapper.merge(this.explore, page.posts);
      this.explore = merged.posts;
      if (page.cursor.length > 0) {
        this.exploreCursor = page.cursor;
      }
    }
    const hasNext: boolean = page.hasMore && this.exploreCursor.length > 0;
    this.exploreHasMore = hasNext;
    if (!hasNext) {
      this.exploreEndAtMs = Date.now();
    }
    this.composePosts();
    this.setStatus(FeedStatus.Idle);
    hilog.info(DOMAIN, TAG,
      'explore page n=%{public}d reset=%{public}s total=%{public}d more=%{public}s cursor=%{public}d',
      page.posts.length, `${forReset}`, this.explore.length, `${hasNext}`, this.exploreCursor.length);
  }

  /**
   * **把两段拼成列表**（关注流 → 提示卡片 → 探索流），并算出卡片该画在第几条之前。
   *
   * 卡片位置就是"关注流这几条之后"：
   *   · 关注流有 N 条 → 卡片画在第 N 条（也就是第一条探索流）之前；
   *   · 关注流 0 条 → 卡片画在第 0 条之前，也就是**列表最顶上**（用户要的那个"刷新后已看完"形态）。
   * 只有探索流这一段**确实有内容**时才画卡片：否则会出现"卡片下面什么都没有"的空档。
   *
   * 两段之间按 key 去重（探索流里完全可能夹着关注流已经有了的帖子）。
   */
  private composePosts(): void {
    const seen: Set<string> = new Set<string>();
    const list: Array<MediaPost> = [];
    for (let index: number = 0; index < this.following.length; index++) {
      const post: MediaPost = this.following[index];
      seen.add(FeedMapper.keyOf(post));
      list.push(post);
    }
    for (let index: number = 0; index < this.explore.length; index++) {
      const post: MediaPost = this.explore[index];
      const key: string = FeedMapper.keyOf(post);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      list.push(post);
    }
    this.hintIndex = this.explore.length > 0 ? this.following.length : -1;
    this.setPosts(list);
    this.onHint(this.hintIndex);
  }

  /** 关注流这一段还有没有下一页（有就继续翻关注流，翻完才轮到探索流）。 */
  private followingHasMore(): boolean {
    if (this.sawEnd) {
      return false;
    }
    return this.nativeCursor.length > 0 && this.nativeHasMore;
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
    this.following = mapped;
    this.composePosts();
    // 游标/翻页状态也先用缓存里的：万一网络那份迟迟不回，上滑照样能接着翻（新的一页会覆盖它）。
    this.nativeCursor = cached.cursor;
    this.nativeHasMore = cached.hasMore;
    this.hasMore = true;
    this.sawEnd = false;
    this.wantFirstPage = true;
    this.setStatus(FeedStatus.Idle);
    this.noteDebug(`cache=${mapped.length}(${Math.round(cached.ageMs / 1000)}s)`, true);
    // 缓存这批也把封面小图解出来（见 core/PosterCache）：一进来首屏就是"小图先到、真图补上"。
    PosterCache.warm(mapped);
    hilog.info(DOMAIN, TAG, 'hydrated from cache n=%{public}d age=%{public}dms',
      mapped.length, cached.ageMs);
  }

  /**
   * 触底 / 接近底部时的「取更多」入口。
   *
   * 列表滚动过程中这个入口会被反复调用；`busy` + `pending` 已经保证不会并发。
   *
   * **顺序跟着列表走**（列表是"关注流 → 提示卡片 → 探索流"）：
   *   ① 关注流还有下一页 → 先翻关注流（新的一页接在关注流末尾，卡片随之往后挪）；
   *   ② 关注流翻完了 → 翻探索流那一段（这才是用户说的"探索流无法获取更多帖子"要修的地方）；
   *   ③ 两段都到底 → 报"没有更多"，并且这个判断**有时效**（见 END_RECHECK_MS）。
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
    if (this.followingHasMore()) {
      // 还有关注流的页：照旧交给 loadFeed → loadNextPage。
    } else if (this.exploreHasMore || this.exploreRecheckDue()) {
      this.wantExploreNext = true;
    } else {
      // 两段都到底了。
      if (this.sawEnd && !this.endRecheckDue()) {
        this.setStatus(FeedStatus.NoMore);
        return;
      }
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
   * 「探索流到底了」这个判断是不是过了有效期（同 END_RECHECK_MS）。
   *
   * 到点后允许拿**第一页**再试一次：探索流的游标过期时，继续用旧游标只会一直空，
   * 重新要第一页才能接上（而且第一页本身就是新内容）。
   */
  private exploreRecheckDue(): boolean {
    if (this.exploreEndAtMs === 0) {
      return true;
    }
    const due: boolean = Date.now() - this.exploreEndAtMs >= END_RECHECK_MS;
    if (due) {
      hilog.info(DOMAIN, TAG, 'explore end recheck: retry after %{public}dms',
        Date.now() - this.exploreEndAtMs);
    }
    return due;
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
      // 预热没赶上（或没登录）：自己发一发，仍然是原生、仍然不碰网页。
      first = await NativeFeed.fetchPage(NATIVE_FIRST_COUNT, '');
      hilog.info(DOMAIN, TAG, 'native first fetched n=%{public}d ms=%{public}d',
        first === null ? 0 : first.items.length, Date.now() - startedMs);
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
      return;
    }
    /*
     * 原生也没拿到（没登录 / 被限流 / 形状变了）：退回 **DOM 抽取**这条最老的兜底
     * —— 它读的是网页上已经画出来的那一屏，不需要任何模板。
     * 原先"触发页面重发请求 → 等信号 → 回放模板"那几轮已随模板机制删除。
     */
    const dom: FeedPayloadDto | null = await this.tryDom();
    if (dom !== null) {
      await this.applyPayload(dom, asFirstLoad, true, prepend);
      return;
    }
    this.setStatus(FeedStatus.Unparsable);
  }

  /** 翻下一页：先吃原生缓存，再走原生现抓，最后退到滚动。 */
  private async loadNextPage(): Promise<void> {
    // ---- 0) 关注流翻完了：这一轮要的是**探索流**那一段（见 requestMore 的顺序）----
    if (this.wantExploreNext || !this.followingHasMore()) {
      const want: boolean = this.wantExploreNext;
      this.wantExploreNext = false;
      /*
       * 还能不能要探索流：`want` = 用户刚触底要的；`exploreHasMore` = 上一页说还有；
       * `exploreRecheckDue()` = 上次那个"到底了"已经过期（见 END_RECHECK_MS）。
       * 三者都不成立就是**两段都到底**，如实报出来，别在这儿空转。
       */
      if (want || this.exploreHasMore || this.exploreRecheckDue()) {
        this.setStatus(FeedStatus.LoadingMore);
        const beforeExplore: number = this.explore.length;
        // 游标还在就接着翻；游标没了（到底/过期）就重新要第一页，那一页本身就是新内容。
        await this.loadExplore(!this.exploreHasMore);
        if (this.explore.length > beforeExplore || this.exploreHasMore) {
          this.pagingStuck = false;
          return;
        }
        this.setStatus(FeedStatus.NoMore);
        return;
      }
      this.setStatus(FeedStatus.NoMore);
      return;
    }
    if (this.sawEnd) {
      // 服务端已经明确说过没有下一页，不必再发请求 —— 除非这个判断已经过期（见 END_RECHECK_MS）。
      if (!this.endRecheckDue()) {
        this.setStatus(FeedStatus.NoMore);
        return;
      }
    }
    this.setStatus(FeedStatus.LoadingMore);
    // 比较基准是**关注流那一段**的长度：合并列表里还夹着探索流，用总长度比会算错"新增了几条"。
    const before: number = this.following.length;

    // ---- 1) 原生缓存：上滑时**零等待**（那些页是上一屏显示完就抓好放在内存里的）----
    const cached: NativeFeedPage | null = this.takeNativePage();
    if (cached !== null) {
      await this.applyPayload(this.pagePayload(cached), false, false);
      this.nativeCursor = cached.nextCursor;
      this.nativeHasMore = cached.hasMore;
      hilog.info(DOMAIN, TAG, 'native page from cache n=%{public}d added=%{public}d queued=%{public}d',
        cached.items.length, this.following.length - before, this.nativeQueue.length);
      // 铺完立刻把队列补满 —— 这样"上滑加载"永远是在吃已经取好的那几页。
      this.prefetchNativePage();
      if (this.following.length > before) {
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
          live.items.length, live.ms, this.following.length - before);
        this.prefetchNativePage();
        if (this.posts.length > before) {
          this.pagingStuck = false;
          return;
        }
      }
    }
    /*
     * 两条路都没换来新内容：**把这个游标丢掉**（游标失效时拿它反复请求只会拿到同一页）。
     * 原先这里还有"滚页面 → 等页面自己发下一页 → 回放它的模板"那条兜底，已随模板机制删除。
     */
    if (this.following.length === before) {
      this.pagingStuck = true;
      if (this.nextCursor.length > 0) {
        hilog.info(DOMAIN, TAG, 'cursor yielded nothing → dropped (posts=%{public}d)',
          this.following.length);
        this.nextCursor = '';
      }
      this.setStatus(this.sawEnd ? FeedStatus.NoMore : FeedStatus.Idle);
    } else {
      this.pagingStuck = false;
    }
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
    // 注意合并的对象是**关注流那一段**（`this.following`），不是屏幕上那份合并列表 ——
    // 否则探索流的内容会被并进关注流、下次翻页还会被当成"关注流"重复去重。
    let merged: MergeResult;
    if (replace) {
      merged = new MergeResult(mapped, mapped.length);
    } else if (prepend) {
      merged = FeedMapper.mergePrepend(mapped, this.following);
    } else {
      merged = FeedMapper.merge(this.following, mapped);
    }
    this.following = merged.posts;
    this.composePosts();
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

    // DOM 兜底那份的 videoUrl / images / counts 已经在脚本里读齐了，不需要再补一次。
    if (usedDom && this.posts.length > 0) {
      this.noteDebug('dom');
    }
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
      this.noteDebug(`dom=${(payload.items ?? []).length} ${payload.debug ?? ''}`, true);
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
  private noteDebug(text: string, step: boolean = false): void {
    this.debug = text;
    /*
     * **中间那几步降到 debug**（审计 E14）：`cache=` / `api=` / `dom=` 每次取数都会各打一行，
     * 真机上滚一屏下来就是几十行，把别的现场（收藏/翻页/限流那些）冲掉。
     * **合成后的那一行仍然留在 info**：它带着信息流脚本回传的字段名清单，
     * `hilog | grep "feed debug"` 一次取数只出一行，排查"某个计数不显示"靠的还是它。
     */
    if (step) {
      hilog.debug(DOMAIN, TAG, 'feed debug(step): %{public}s', text);
      return;
    }
    hilog.info(DOMAIN, TAG, 'feed debug: %{public}s', text);
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
