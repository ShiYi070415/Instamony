/*
 * 搜索页的视图模型。
 *
 * ## 取数：全部走移动端私有接口（core/mobileapi），不再驱动网页
 *   · 账号搜索 → `fbsearch/account_serp/`，失败退 `/web/search/topsearch/`（见 core/NativeSearch）；
 *   · 推荐网格 → `discover/topical_explore/`，失败退信息流里的推荐卡片（同一份 NativeSearch）。
 *
 * 历史：这里原来有一条**冷路径**（导航隐藏网页 → 打字逼请求 → 抓 GraphQL 模板 → 回首页），
 * 模板机制退役后它已经没有用处 —— 抓不到新鲜令牌，还要占着共用网页十几秒
 * （正是"进搜索页就卡住"的来源）。冷路径、模板体检、结构摘要一并删除。
 *
 * ## 页面结构（需求）
 *   - 没输入关键词 → **推荐帖子**，三列瀑布流；
 *   - 输入并提交 → 账号结果列表（点一个进原生用户主页）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
// 加载闸门（见 core/LoadGate；推荐首屏用它防重入，异常路径也不会卡死）。
import { LoadGate } from '../core/LoadGate';
import { SearchPost, SearchUser } from '../model/Search';
import { NativeSearch, SearchPostPage } from '../core/NativeSearch';
import { EXPLORE_LANE_SEARCH } from '../core/mobileapi/ExploreLanes';
import { CachedSearchPage, SearchCache } from '../core/SearchCache';
import { ApiThrottle } from '../core/ApiThrottle';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SearchViewModel';

/**
 * 预取队列深度（页数）：**1 页**。
 *
 * 降噪（见 `FINGERPRINT_ANALYSIS.md` 阶段一）：原来是 3 页 —— 而探索流一页 0.8~1.3MB，
 * "进搜索页就预取三页"约等于 4MB / 3 发连打，是账号被判"太吵"的主要来源之一。
 * 留 1 页仍能保证滑到底立刻有内容，代价只是滑得更深时偶尔等一下。
 */
const PREFETCH_DEPTH: number = 1;
/**
 * 首屏至少要有几条（三列瀑布流 ≈ 四行）。
 *
 * 真机实测：探索流**首屏可能只回 4 条**（它给的是"还没看过的"那一小撮），
 * 只铺 4 格的话网格看着是空的，而且用户不滑到底就不会去拉下一页 —— 所以在首屏之后主动补
 * （见 fillGrid），补到这个数或者服务端说没有了为止。
 */
const MIN_GRID_POSTS: number = 12;
/** 网格每长这么多条就再落盘一份缓存（见 loadMore；一次写几 KB，不值得每条都写）。 */
const CACHE_RESAVE_STEP: number = 6;
/**
 * 一整页都是重复时，最多再连要几页（见 loadMore）。
 *
 * 3 页足够穿过 IG 常见的"游标回带"；再多就说明服务端确实在原地打转，收手更省流量。
 */
const SKIP_DUP_PAGES: number = 3;
/**
 * 没有游标时"重取第一页"最多试几次（见 loadMore）。
 *
 * IG 探索流第一页有时根本不给 `max_id`；重取一次往往能捞出新的几条（排序会变）。
 * 2 次都不出新内容就认为真的到底了 —— 再多就是白打请求。
 */
const RESTART_MAX: number = 2;

export class SearchViewModel {
  private users: Array<SearchUser> = [];
  private posts: Array<SearchPost> = [];
  private busy: boolean = false;
  /** 当前关键词（空串 = 推荐态）。 */
  private query: string = '';
  /** 最近一次失败的原样回报（截断），失败提示里带上它 —— 界面就是排查通道。 */
  private diag: string = '-';
  /** 进页面时的初始化跑过了没有（推荐流只自动拉一次）。 */
  private opened: boolean = false;
  /** 推荐的取数状态：推荐流是"进页面就拉"，别和用户搜索抢状态行。 */
  private recommendLoaded: boolean = false;
  /**
   * 推荐首屏的**加载闸门**（见 core/LoadGate）。
   *
   * `queueWhenBusy=false`：这是个幂等入口（`open()` 与 `retryRecommend()` 都会调），
   * 忙的时候**忽略**就好，不需要排队补跑 —— 但要保证异常路径也复位（上一版没有
   * try/finally，一次异常就让 `recommendBusy` 永久 true，搜索页再也不加载）。
   */
  private readonly recommendGate: LoadGate = new LoadGate(false);
  /** 试过读推荐第一页的落盘缓存了没有（一轮进程只读一次，见 hydrateFromCache）。 */
  private cacheTried: boolean = false;
  /** 正在"把网格补满一屏"（见 fillGrid：避免两处同时连拉）。 */
  private gridFilling: boolean = false;
  /** 上次落盘时的条数（见 loadMore：网格长起来之后再存一份更满的缓存）。 */
  private savedCount: number = 0;
  /**
   * 「搜索」页**当前是不是真的显示着**（由 pages/Index 在切页时设置，见 setActive）。
   *
   * 为什么必须有这个闸：Tabs 会把五个分页都建出来，搜索页那个瀑布流在**看不见**的时候也会报
   * `onScrollIndex`（视口是 0，最后一条永远"贴着底"），"接近底部就加载下一页"于是变成一台
   * 永动机 —— 真机实测：没人打开搜索页，启动后它自己一路拉到 148 条（每页 1.5~3.5 秒的网络
   * 全被它占了，首屏、预热、翻页全在跟它抢）。所以**滚动触发的翻页只在页面可见时生效**；
   * 首屏补满（fillGrid）不受影响，它有自己的上限。
   */
  private active: boolean = false;
  /** 下一页游标与"还有没有更多"（瀑布流滑到底部要用）。 */
  private cursor: string = '';
  private hasMore: boolean = false;
  private loadingMore: boolean = false;
  /**
   * **下一页推荐的缓存队列**（提前拉好放在手边）。
   *
   * 需求："给每个分页做一下缓存页加载，提升加载速度，包括搜索页面"。滑到底那一刻直接贴上来
   * （毫秒级、不见"正在加载"），贴完继续把队列填满（见 prefetchMore）。
   */
  private prefetched: Array<SearchPostPage> = [];
  private prefetching: boolean = false;
  /**
   * 后台**预加载**到的推荐第一页（见 prefetch）。
   *
   * 需求："搜索页探索流的预加载做一下"：启动时（app 起来、用户还在首页）就把第一页拉回来
   * 放在这儿，用户切到搜索页的那一刻直接铺上（`open()` → `loadRecommendedOnce` 先吃它），
   * 不用再等一次 1MB / 1~3 秒的网络。
   *
   * 只存**一页**：第一页之外的页仍由 prefetchMore 排队，别把内存和请求密度一起放大。
   */
  private prefetchedFirst: SearchPostPage | null = null;
  /** 刷新进行中（下拉刷新的重入闸，见 refresh）。 */
  private refreshingRecommend: boolean = false;
  /** 预取连续遇到"空页 / 回带页"的次数（见 prefetchMore）。 */
  private prefetchSkips: number = 0;

  onUsers: (users: Array<SearchUser>) => void = (users: Array<SearchUser>): void => {
  };
  onPosts: (posts: Array<SearchPost>) => void = (posts: Array<SearchPost>): void => {
  };
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
  };
  onStatus: (text: string) => void = (text: string): void => {
  };
  /** 关键词变了（界面据此在"推荐瀑布流"和"账号结果"之间切）。 */
  onQuery: (query: string) => void = (query: string): void => {
  };
  /** "还有没有下一页"变了（界面据此显示尾部提示 / 决定要不要继续加载）。 */
  onMore: (hasMore: boolean) => void = (hasMore: boolean): void => {
  };
  /** 正在加载下一页（尾部转圈）。 */
  onLoadingMore: (busy: boolean) => void = (busy: boolean): void => {
  };

  list(): Array<SearchUser> {
    return this.users;
  }

  postList(): Array<SearchPost> {
    return this.posts;
  }

  isBusy(): boolean {
    return this.busy;
  }

  /** 还有没有下一页（界面尾部提示用）。 */
  hasMorePosts(): boolean {
    return this.hasMore;
  }

  /** 正在加载下一页。 */
  isLoadingMore(): boolean {
    return this.loadingMore;
  }

  lastQuery(): string {
    return this.query;
  }

  /**
   * 进搜索页时调用（页面在切到这个 tab 时调）。
   *
   * 幂等：推荐流已经拉过就直接返回，不会每次切页都打一次网络。
   */
  async open(): Promise<void> {
    if (this.opened) {
      return;
    }
    this.opened = true;
    // **先吃落盘缓存**（见 core/SearchCache）：切到搜索页立刻就有上次那面网格，
    // 网络那份回来再整体替换。放在最前面 —— 它比任何网络路径都快（读盘几十毫秒）。
    this.hydrateFromCache();
    await this.loadRecommended();
  }

  /**
   * **预热**推荐流（启动时调用，见 pages/Index 的 preloadTabs）。
   *
   * 启动时**绝不发网络**：只把落盘缓存铺上，真正的第一页等用户切到搜索页时再拉（见 open）。
   */
  async warm(): Promise<void> {
    // 缓存先在后台铺上：这样"启动预热"和"用户切到搜索页"谁先发生都不影响首屏。
    this.hydrateFromCache();
    /*
     * **启动预热不再发推荐流那一发**（降噪，见 `FINGERPRINT_ANALYSIS.md` 阶段一）。
     *
     * 探索流一页 0.8~1.3MB，而"进首页就预取"意味着用户还没看搜索页就先花掉一兆多 ——
     * 加上后面的连发，这是最像爬虫的一段。现在启动只吃落盘缓存（读盘几十毫秒），
     * 真正的第一页等用户**切到搜索页**时再拉（`open()` → `loadRecommended()`）。
     */
    hilog.info(DOMAIN, TAG, 'warm: cache only (%{public}d cached post(s))', this.posts.length);
  }

  /**
   * **后台预加载推荐第一页**（需求："搜索页探索流的预加载做一下"）。
   *
   * 与 `warm()` 的区别：`warm()` 只读盘、不发网络（那一版是为了降噪）；这个会真的发一发，
   * 但要等**首屏画完、用户手停下**之后（调用点在 `Index.warmOtherTabs` 的预热链里），
   * 所以不会和首屏抢通道。拿到之后放在 `prefetchedFirst`，`open()` 直接消费。
   *
   * 已经加载过 / 正在加载 / 有搜索词 / 没有会话时都直接返回（幂等）。
   */
  async prefetch(): Promise<void> {
    if (this.prefetchedFirst !== null || this.recommendLoaded || this.query.length > 0) {
      return;
    }
    if (!NativeSearch.hasRecommendedSource()) {
      return;
    }
    // 限流期间别硬发（移动端探索流不受 CLIPS 那把锁管，判据和 loadRecommendedOnce 一致）。
    if (!NativeSearch.mobileRecommendedUsable() && ApiThrottle.blocked(ApiThrottle.CLIPS)) {
      hilog.info(DOMAIN, TAG, 'prefetch skipped: rate limited');
      return;
    }
    const started: number = Date.now();
    try {
      const page: SearchPostPage | null = await NativeSearch.recommendedPage('', EXPLORE_LANE_SEARCH);
      if (page === null || page.posts.length === 0) {
        hilog.info(DOMAIN, TAG, 'prefetch miss (%{public}s)', NativeSearch.lastDiag());
        return;
      }
      this.prefetchedFirst = page;
      hilog.info(DOMAIN, TAG, 'prefetch ready n=%{public}d hasMore=%{public}s ms=%{public}d',
        page.posts.length, `${page.hasMore}`, Date.now() - started);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'prefetch threw: %{public}s', (error as Error).message);
    }
  }

  /**
   * **刷新推荐流**（搜索页下拉刷新；需求："触发刷新时直接覆盖数据流"）。
   *
   * 和 `retryRecommend()` 的区别：那个只是"没加载出来时再试一次"，加载过就是空操作；
   * 这个会**先清空整条流**（列表、游标、hasMore、预取队列、首屏预加载），再拉第一页，
   * 回来时整页替换 —— 不会出现"新旧混排 / 旧内容还挂在下面"。
   */
  async refresh(): Promise<void> {
    if (this.refreshingRecommend) {
      return;
    }
    this.refreshingRecommend = true;
    this.onStatus('正在刷新推荐…');
    try {
      /*
       * **保留当前内容，成功之后再覆盖**（需求："下拉刷新做成保留当前探索流，等成功刷新再覆盖新的"）。
       *
       * 所以这里**不先清空** anything：直接发第一页，回来了才整体替换；失败/超时就保持原样，
       * 只在状态行留一句原因。用户下拉时看到的是"转圈 + 原来的瀑布流"，不会先白屏。
       */
      const page: SearchPostPage | null = await NativeSearch.recommendedPage('', EXPLORE_LANE_SEARCH);
      if (page === null || page.posts.length === 0) {
        this.onStatus('刷新失败：' + NativeSearch.lastDiag());
        hilog.info(DOMAIN, TAG, 'refresh miss, keep %{public}d post(s)', this.posts.length);
        return;
      }
      // ---- 成功：整页覆盖（游标/预取队列/首屏预加载都换成新的这一份）----
      this.posts = page.posts;
      this.cursor = page.cursor;
      this.hasMore = page.posts.length > 0;
      this.prefetched = [];
      this.prefetchedFirst = null;
      this.recommendLoaded = true;
      this.savedCount = this.posts.length;
      this.onPosts(this.posts);
      this.onMore(this.hasMore);
      this.onStatus('');
      if (page.source.indexOf('feed:') !== 0) {
        SearchCache.savePage(this.posts, this.cursor, this.hasMore);
      }
      hilog.info(DOMAIN, TAG, 'refresh replaced n=%{public}d hasMore=%{public}s cursor=%{public}d',
        this.posts.length, `${this.hasMore}`, this.cursor.length);
      /*
       * 只预取下一页，**不再紧跟 fillGrid 追加**：刷新这一下已经整面换成新数据，
       * 立刻再追加一批会让 LazyForEach 连着重载两次（观感就是"刷新时画面闪一下"）。
       * 下一批交给用户滑到底时的 loadMore。
       */
      this.prefetchMore();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'refresh threw: %{public}s', (error as Error).message);
      this.onStatus('刷新出错');
    } finally {
      this.refreshingRecommend = false;
    }
  }

  /**
   * 「搜索」页可见性（pages/Index 在切页时调）。
   *
   * 见 `active` 的说明：不可见时**不接受滚动触发的翻页**，否则隐藏的瀑布流会把整条推荐流
   * 一路拉到底。
   */
  setActive(active: boolean): void {
    this.active = active;
  }

  /** 瀑布流滚到接近底部（只有页面可见时才会真的去翻页，见 active）。 */
  requestMoreFromScroll(): void {
    if (!this.active) {
      return;
    }
    this.loadMore();
  }

  /**
   * 首屏从**落盘缓存**铺出来（需求："搜索页推荐帖子加载刷新的有点慢，优化一下缓存和加载逻辑"）。
   *
   * 只在"还没有内容 + 这一轮进程还没试过"时做一次。铺上之后 `recommendLoaded` **保持 false**：
   * 网络那一轮照样会跑，回来之后整体替换（`this.posts = page.posts`），所以不会出现新旧混排。
   */
  private hydrateFromCache(): void {
    if (this.cacheTried || this.posts.length > 0) {
      return;
    }
    this.cacheTried = true;
    const cached: CachedSearchPage | null = SearchCache.loadPage();
    if (cached === null) {
      return;
    }
    this.posts = cached.posts;
    this.cursor = cached.cursor;
    /*
     * 缓存里那个 `hasMore` **不可信**（很可能是上次被错判成 false 时存下来的），
     * 这里只按游标判断：有游标就允许继续翻（见 loadMore 的说明）。
     * 否则一进搜索页 footer 就写着「没有更多了」，而后面其实还有几十页。
     */
    this.hasMore = cached.posts.length > 0;
    this.onPosts(this.posts);
    this.onMore(this.hasMore);
    this.onStatus('');
    hilog.info(DOMAIN, TAG, 'hydrated from cache n=%{public}d more=%{public}s age=%{public}dms',
      cached.posts.length, `${this.hasMore}`, cached.ageMs);
  }

  /**
   * 拉一次推荐帖子（三列瀑布流的数据）。
   *
   * 外面这层只管**防重入**：`open()`（切到搜索页）和 `retryRecommend()`（再试一次）都可能调用它，
   * 两下撞在一起就是两条几百 KB 的重查询。
   */
  private async loadRecommended(): Promise<void> {
    if (this.recommendLoaded || this.query.length > 0) {
      return;
    }
    const ticket: number = this.recommendGate.begin(false);
    if (ticket < 0) {
      return;
    }
    /*
     * **必须 try/finally**：`loadRecommendedOnce` 里面是网络往返，任何一处抛异常
     * （解析出错、被上层 cancel、NativeSearch 内部 throw）都会让闸门永久留在"忙"，
     * 之后 `retryRecommend()`（切到搜索页、点"再试一次"）全部被挡掉，
     * 表现就是"搜索页永远空着，除非重启 App"。
     */
    try {
      await this.loadRecommendedOnce();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'recommend threw: %{public}s', (error as Error).message);
      this.onStatus('推荐读取出错');
    } finally {
      this.recommendGate.settle(ticket);
    }
  }

  /**
   * 再试一次推荐首屏（切到搜索页时由 pages/Index 调）。
   *
   * 为什么需要这个入口：`open()` 在 `SearchViewModel` 里是**一次进程只跑一遍**的幂等入口，
   * 而它很可能正撞上接口限流（见 core/ApiThrottle）—— 那一轮 `recommendLoaded` 留在 false、
   * 网格只有落盘缓存那份（甚至空的）。没有这个钩子的话冷却过去了也不会自己再拉，
   * 用户看到的就是"搜索页一直空着（或一直是老内容），除非重启 app"。
   * 限流还在时它自己会当场返回（判据在 loadRecommendedOnce 里）。
   */
  retryRecommend(): void {
    this.loadRecommended();
  }

  /**
   * 真正的那一发（拆出来只为了给 loadRecommended 套一层"正在拉"的闸门，见那里）。
   *
   * 拉的是**第一页**；后续页由 loadMore（瀑布流滑到底部时调用）接上。
   */
  private async loadRecommendedOnce(): Promise<void> {
    if (this.recommendLoaded || this.query.length > 0) {
      return;
    }
    if (!NativeSearch.hasRecommendedSource()) {
      // 没有会话：不报错，留个能看懂的状态。
      this.onStatus('还没有推荐数据（请先在网页里登录 Instagram）');
      return;
    }
    /*
     * **被限流期间不发**（见 core/ApiThrottle）。
     *
     * 这段时间**先把落盘缓存那一页铺上**（hydrateFromCache）—— 上次那十几格瀑布流
     * 比"空白+错误提示"有用得多（用户报的"推荐流无法正确显示"）。
     *
     * 但**移动端探索流不受这把锁管**：它是另一条端点（`discover/topical_explore/`），
     * clips 那条被限不等于探索页也被限 —— 所以只在"没有移动端这条路"时才整体跳过。
     */
    if (!NativeSearch.mobileRecommendedUsable() && ApiThrottle.blocked(ApiThrottle.CLIPS)) {
      const minutes: number = ApiThrottle.remainingMinutes(ApiThrottle.CLIPS);
      this.hydrateFromCache();
      this.onStatus(this.posts.length > 0
        ? `Instagram 暂时限制了推荐接口，先显示上次的 ${this.posts.length} 条（约 ${minutes} 分钟后自动重试）`
        : `Instagram 暂时限制了推荐接口，约 ${minutes} 分钟后再试`);
      hilog.info(DOMAIN, TAG, 'recommend skipped: rate limited, %{public}d post(s) from cache',
        this.posts.length);
      return;
    }
    this.onStatus('正在读取推荐…');
    /*
     * **优先吃后台预加载的那一页**（见 prefetch）：切到搜索页时它多半已经在手里，
     * 直接铺上就是"零等待"。取走即清空，避免同一页被用两次。
     */
    const warmed: SearchPostPage | null = this.prefetchedFirst;
    this.prefetchedFirst = null;
    const page: SearchPostPage | null = warmed !== null
      ? warmed : await NativeSearch.recommendedPage('', EXPLORE_LANE_SEARCH);
    if (page === null) {
      // 读不出来时也争取给点内容：缓存那份至少是"上次真实拉到的瀑布流"。
      this.hydrateFromCache();
      this.onStatus(this.posts.length > 0 ? '' : '推荐没读出来：' + NativeSearch.lastDiag());
      return;
    }
    this.recommendLoaded = true;
    this.posts = page.posts;
    this.cursor = page.cursor;
    this.hasMore = page.posts.length > 0;
    this.onPosts(this.posts);
    this.onMore(this.hasMore);
    this.onStatus(page.posts.length === 0 ? '没有推荐内容' : '');
    hilog.info(DOMAIN, TAG, 'recommend page1 n=%{public}d hasMore=%{public}s cursor=%{public}d',
      page.posts.length, `${page.hasMore}`, page.cursor.length);
    // 落盘一份给下次冷启动/切页用（见 core/SearchCache）：下次一进来就有画面。
    // 注意这里存的是**第一页**（真机实测常常只有 4 条），网格长起来之后会再存一份更满的
    // （见 loadMore 的 savedCount 判断）。
    //
    // **兜底那一份不存**：走的是"信息流里的推荐卡片"（`source=feed:…`）时真机实测常常只有
    // 1~2 条 —— 存下去会把上次那份完整的瀑布流顶掉，用户下次看到的推荐流就只剩一格
    // （"推荐流无法正确显示"的一种形态）。宁可不更新，也别把好数据盖掉。
    if (page.posts.length > 0 && page.source.indexOf('feed:') !== 0) {
      SearchCache.savePage(page.posts, page.cursor, page.hasMore);
    }
    this.savedCount = this.posts.length;
    // 第一页到手就顺手预取后面几页（需求："包括搜索页面"的缓存页加载）。
    this.prefetchMore();
    // 第一页**可能很短**（真机实测：探索流首屏只回 4 条）。只有 4 格的话网格看着就是空的，
    // 用户还得自己往下滑才触发下一页。所以这里主动把它补到铺满一屏以上（见 fillGrid）。
    this.fillGrid();
  }

  /**
   * 把网格补到**至少铺满一屏**（MIN_GRID_POSTS 条）。
   *
   * 为什么需要：首屏可能只有 4 条（见 loadRecommendedOnce 的说明），而"下一页"要用户滑到底
   * 才触发 —— 表现就是"切到搜索页只有稀稀拉拉几格，等一会儿才慢慢长出来"。这里在首屏之后
   * 主动连拉，直到够一屏、或者服务端说没有了、或者试够次数（不让它一直占着网络）。
   */
  private fillGrid(): void {
    if (this.gridFilling || this.query.length > 0) {
      return;
    }
    this.gridFilling = true;
    const pump: () => void = (): void => {
      if (this.posts.length >= MIN_GRID_POSTS || !this.hasMore || this.cursor.length === 0) {
        this.gridFilling = false;
        return;
      }
      const before: number = this.posts.length;
      this.loadMore().then((): void => {
        // 这一轮一条都没进来（重复/空页）：收手，别再空转（loadMore 那边已经把 hasMore 收敛了）。
        if (this.posts.length === before) {
          this.gridFilling = false;
          return;
        }
        pump();
      }).catch((): void => {
        this.gridFilling = false;
      });
    };
    pump();
  }

  /**
   * 后台预取**后面的推荐页，把队列填到 PREFETCH_DEPTH 页**（需求："缓存页加载……包括搜索页面"）。
   *
   * 瀑布流滑到底那一刻是"贴上去"而不是"发请求"，所以不会看到"正在加载"那一下。
   * 每次只发一页（`prefetching` 闸住并发），拉完自己再调一次继续填。
   */
  private prefetchMore(): void {
    if (this.prefetching || this.prefetched.length >= PREFETCH_DEPTH) {
      return;
    }
    // 接着队尾翻；队列空时接着"已显示内容"的游标翻。
    const tail: SearchPostPage | null = this.prefetched.length > 0
      ? this.prefetched[this.prefetched.length - 1] : null;
    const cursor: string = tail === null ? this.cursor : tail.cursor;
    const more: boolean = tail === null ? this.hasMore : tail.hasMore;
    if (!more || cursor.length === 0) {
      return;
    }
    this.prefetching = true;
    NativeSearch.recommendedPage(cursor).then((page: SearchPostPage | null): void => {
      this.prefetching = false;
      if (page === null) {
        return;
      }
      if (page.posts.length === 0) {
        /*
         * **空页不等于到底**（用户报："搜索探索流还是出现没有更多了"）。
         *
         * IG 会给"有游标但这一页没内容"的回带页；三条入口做了跨入口去重之后，
         * 也可能出现"这页剩下的都给别人拿走了"。所以这里只在**游标没前进**（或连跳够了）
         * 时才真的收手，否则顺着新游标继续预取。
         */
        const advanced: boolean = page.cursor.length > 0 && page.cursor !== cursor;
        if (!advanced || this.prefetchSkips >= SKIP_DUP_PAGES) {
          this.prefetchSkips = 0;
          this.hasMore = false;
          this.onMore(false);
          return;
        }
        this.prefetchSkips++;
        this.cursor = page.cursor;
        hilog.info(DOMAIN, TAG, 'prefetch empty page, skip (cursor advanced, skip=%{public}d)',
          this.prefetchSkips);
        this.prefetchMore();
        return;
      }
      this.prefetchSkips = 0;
      this.prefetched.push(page);
      hilog.info(DOMAIN, TAG, 'prefetch recommend n=%{public}d depth=%{public}d',
        page.posts.length, this.prefetched.length);
      this.prefetchMore();
    }).catch((): void => {
      this.prefetching = false;
    });
  }

  /** 这一页里**还没显示过**的条目（按 code 去重，见 loadMore）。 */
  private freshOf(posts: Array<SearchPost>): Array<SearchPost> {
    const seen: Array<string> = [];
    for (let index: number = 0; index < this.posts.length; index++) {
      seen.push(this.posts[index].code);
    }
    const fresh: Array<SearchPost> = [];
    for (let index: number = 0; index < posts.length; index++) {
      const one: SearchPost = posts[index];
      if (seen.indexOf(one.code) >= 0) {
        continue;
      }
      seen.push(one.code);
      fresh.push(one);
    }
    return fresh;
  }

  /**
   * 瀑布流滑到底部时接着拉下一页（需求："上滑到底部时瀑布流不刷新"）。
   *
   * 三道闸：正在加载就不再发（滚动回调一秒能来几十次）、`hasMore` 为假就不再发、
   * 没有游标也不再发。追加时**按 code 去重**：IG 的推荐流会在页与页之间重复同一条。
   */
  async loadMore(): Promise<void> {
    // 诊断：把**四个守卫的真实值**打出来 —— 推荐流"滑到底不加载"到底被哪一条挡住，
    // 只有运行期的这些值能说清（`loadingMore` 卡住 / `hasMore` 被翻成 false / 限流 / 没游标）。
    hilog.info(DOMAIN, TAG,
      'loadMore enter loading=%{public}s hasMore=%{public}s query=%{public}d cursor=%{public}d posts=%{public}d throttled=%{public}s',
      `${this.loadingMore}`, `${this.hasMore}`, this.query.length, this.cursor.length,
      this.posts.length, `${ApiThrottle.blocked(ApiThrottle.CLIPS)}`);
    if (this.loadingMore || !this.hasMore || this.query.length > 0) {
      return;
    }
    /*
     * 被限流期间不再往下要（发了也是白挨一发，见 core/ApiThrottle）。
     *
     * ⚠️ **但移动端探索流不受这把锁管**（用户报："搜索推荐流无法触底刷新"）：这里原来无条件
     * 按 CLIPS 拦，于是只要 reels 把 clips 打到冷却，搜索推荐流滑到底就**一声不响地什么都不加载**。
     */
    if (!NativeSearch.usingMobileRecommended() && ApiThrottle.blocked(ApiThrottle.CLIPS)) {
      /*
       * **把限流写到状态行上**（审计 C1 的现场结论）。
       *
       * 原来这里只打一行日志就 return —— 用户看到的是"滑到底什么都不发生、连转圈都没有"，
       * 和"功能坏了"完全分不清。
       */
      const minutes: number = ApiThrottle.remainingMinutes(ApiThrottle.CLIPS);
      hilog.info(DOMAIN, TAG, 'loadMore skipped: rate limited %{public}dmin left', minutes);
      this.onStatus(`被 IG 限流，约 ${minutes} 分钟后自动恢复`);
      return;
    }
    /*
     * **没有游标不等于到底**（用户报："搜索探索流只加载一页就显示没有更多了"）。
     *
     * 探索流第一页有可能**根本不给 `max_id`**（只有真的往下翻才有），这时按游标判就是
     * "一页到底"。所以这里不再直接收手：没有游标就走下面的"重取第一页 + 去重续命"，
     * 一条新内容都拿不到时才置 hasMore=false。
     */
    this.loadingMore = true;
    this.onLoadingMore(true);
    try {
      const startCursor: string = this.cursor;
      let cursor: string = startCursor;
      let page: SearchPostPage | null = null;
      let fresh: Array<SearchPost> = [];
      let cachedUsed: boolean = false;
      let attempts: number = 0;
      let restarts: number = 0;
      /*
       * **整页都是重复时继续往下翻**（用户报："搜索页推荐流会出现没有更多了"）。
       *
       * IG 探索流的游标会回带：下一页常常整页都是已经显示过的那几条。原先的判据是
       * `fresh.length > 0`，于是只要撞上这种回带页，`hasMore` 立刻被拍成 false ——
       * 用户滑到底就永久停在"没有更多了"，哪怕后面还有几十页。而且我们给三条入口做了
       * 跨入口去重（ExploreLanes），去重后也可能出现"这页剩的都被别人拿走了"。
       *
       * 现在：拿到新条目就停；一页全重复时只要**游标前进了**就再要一页（最多连跳
       * SKIP_DUP_PAGES 页）；**连游标都没有**时重取第一页再按 code 去重（IG 排序会变，
       * 重取常能捞出新的几条），连续 RESTART_MAX 次都没新内容才真的收手。
       */
      while (attempts <= SKIP_DUP_PAGES + RESTART_MAX) {
        attempts++;
        // 没有游标时只能重取第一页；有游标就顺着游标翻。
        const target: string = cursor;
        // **有缓存页就直接用**（毫秒级）：没有再发请求（见 prefetchMore 的说明）。
        let cached: SearchPostPage | null = null;
        if (this.prefetched.length > 0 && target.length > 0) {
          cached = this.prefetched[0];
          this.prefetched = this.prefetched.slice(1);
        }
        cachedUsed = cached !== null;
        const fetched: SearchPostPage | null = cached !== null
          ? cached : await NativeSearch.recommendedPage(target, EXPLORE_LANE_SEARCH);
        if (fetched === null) {
          break;
        }
        page = fetched;
        fresh = this.freshOf(fetched.posts);
        this.posts = this.posts.concat(fresh);
        if (fetched.cursor.length > 0) {
          cursor = fetched.cursor;
        }
        if (fresh.length > 0) {
          break;
        }
        if (cursor.length === 0) {
          restarts++;
          if (restarts >= RESTART_MAX) {
            break;
          }
          hilog.info(DOMAIN, TAG, 'loadMore cursorless restart %{public}d (no new items)', restarts);
          continue;
        }
        const moved: boolean = cursor !== startCursor;
        if (!moved) {
          break;
        }
        hilog.info(DOMAIN, TAG, 'loadMore all-duplicate page, skip (attempt %{public}d cursor=%{public}d)',
          attempts, cursor.length);
      }
      if (page === null) {
        this.onStatus('加载更多失败：' + NativeSearch.lastDiag());
        return;
      }
      this.cursor = cursor;
      /*
       * **收手条件**：这一轮一条新内容都没拿到、而且没有可继续的游标。
       * 有游标就说明还能翻（交给下一次触底再试）；拿到新内容就当然还能继续。
       */
      this.hasMore = fresh.length > 0 || cursor.length > 0;
      this.onPosts(this.posts);
      this.onMore(this.hasMore);
      hilog.info(DOMAIN, TAG,
        'loadMore +%{public}d total=%{public}d hasMore=%{public}s reason=%{public}s'
        + ' cursor=%{public}d restarts=%{public}d cached=%{public}s tries=%{public}d',
        fresh.length, this.posts.length, `${this.hasMore}`,
        fresh.length > 0 ? 'got-new' : (cursor.length === 0 ? 'no-cursor-no-new' : 'dup-but-cursor'),
        cursor.length, restarts, cachedUsed ? 'y' : 'n', attempts);
      // 网格明显长起来了就**再存一份更满的缓存**（见 savedCount）：下次冷启动/切页一进来
      // 就有十几格，而不是只有第一页那 4 格。
      if (this.posts.length - this.savedCount >= CACHE_RESAVE_STEP) {
        SearchCache.savePage(this.posts, this.cursor, this.hasMore);
        this.savedCount = this.posts.length;
      }
      // 贴完这一页，顺手把再下一页预取上（连续下滑就一直有存货）。
      this.prefetchMore();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadMore threw: %{public}s', (error as Error).message);
      this.onStatus('加载更多出错');
    } finally {
      this.loadingMore = false;
      this.onLoadingMore(false);
    }
  }

  /** 搜一次（关键词为空时回到推荐态）。 */
  async search(query: string): Promise<void> {
    const text: string = query.trim();
    if (text.length === 0) {
      this.clear();
      return;
    }
    if (this.busy) {
      return;
    }
    this.query = text;
    this.onQuery(text);
    this.busy = true;
    this.onBusy(true);
    this.setUsers([]);
    this.onStatus('正在搜索…');
    try {
      // 账号搜索只有一条链路：移动端 `fbsearch/account_serp/` → REST 兜底（见 NativeSearch.searchUsers）。
      const page: Array<SearchUser> | null = await NativeSearch.searchUsers(text);
      if (page === null) {
        this.diag = NativeSearch.lastDiag();
        hilog.info(DOMAIN, TAG, 'search failed on both paths (%{public}s)', this.diag);
        this.onStatus('搜索失败：' + this.diag);
        return;
      }
      this.setUsers(page);
      this.onStatus(page.length === 0 ? '没有找到结果' : `找到 ${page.length} 个账号`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'search threw: %{public}s', (error as Error).message);
      this.onStatus('搜索出错');
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }

  /**
   * 探针面板用：用**移动端接口**自检一次搜索页那两路（账号搜索 + 推荐网格），
   * 把来源与条数摘要返回（页面落进探针文件）。
   *
   * 模板机制退役后，这个按钮的用途从"抓模板"变成"验通道"。
   */
  async captureTemplates(): Promise<string> {
    const users: Array<SearchUser> | null = await NativeSearch.searchUsers('instagram');
    const page: SearchPostPage | null = await NativeSearch.recommendedPage('');
    const digest: string = `account_serp: users=${users === null ? 0 : users.length}`
      + ` recommend: posts=${page === null ? 0 : page.posts.length}`
      + ` source=${NativeSearch.lastSource()}`;
    hilog.info(DOMAIN, TAG, 'probe search %{public}s | %{public}s',
      digest, NativeSearch.lastDiag().replace(/[\r\n]+/g, ' | '));
    return `${digest}\n${NativeSearch.lastDiag()}`;
  }

  /**
   * 当前关键词（空串 = 推荐态）。给返回键用：有结果时先回推荐流，不退出 App。
   */
  queryNow(): string {
    return this.query;
  }

  /**
   * 清空关键词，回到推荐态。
   *
   * 需求里搜索框是可清空的：清掉就**立刻**变回推荐瀑布流（不用再拉一次网络，缓存还在）。
   */
  clear(): void {
    this.query = '';
    this.onQuery('');
    this.setUsers([]);
    this.onStatus('');
    if (!this.recommendLoaded && NativeSearch.hasRecommendedSource()) {
      this.loadRecommended();
    }
  }

  /**
   * **换账号：搜索页的一切作废**（用户报的"切换账号后搜索推荐流没有清空重新获取"）。
   *
   * 和 `clear()` 的区别：`clear()` 只是"清掉关键词、回到推荐态"，**推荐流本身留着**（缓存还在，
   * 不用再拉网络）；而换账号之后那份推荐流是**上一个人的**，必须整份丢掉：
   *   · 列表、账号结果、游标、翻页状态、预取队列全部清空；
   *   · `recommendLoaded` / `opened` / `cacheTried` 复位 —— 下次切到搜索页时 `open()` 会
   *     重新读**这个账号**的落盘缓存、再拉一遍新的推荐流；
   *   · 所有变化都通过 `on*` 回调推给页面，页面的 @State 与 LazyForEach 数据源随之刷新
   *     （界面不重建也能立刻空掉）。
   */
  forgetAccount(): void {
    this.query = '';
    this.onQuery('');
    this.users = [];
    this.onUsers([]);
    this.posts = [];
    this.onPosts([]);
    this.onStatus('');
    this.busy = false;
    this.onBusy(false);
    this.cursor = '';
    this.hasMore = false;
    this.onMore(false);
    this.loadingMore = false;
    this.onLoadingMore(false);
    // 取数闸门全部复位：下次进搜索页 = 第一次进（重新吃缓存 + 重新拉推荐）。
    this.opened = false;
    this.recommendLoaded = false;
    this.recommendGate.invalidate();
    this.cacheTried = false;
    this.gridFilling = false;
    this.prefetched = [];
    this.prefetching = false;
    this.savedCount = 0;
    this.active = false;
    hilog.info(DOMAIN, TAG, 'search forgot account (lists cleared, will reload)');
  }

  /**
   * 当前这份**推荐列表**（给"推荐流 → Reels 页"用，见 pages/Index.openSearchReels）。
   *
   * 直接给内部那份：Reels 页只读它、拼自己的播放列表，不改它。
   */
  recommendPosts(): Array<SearchPost> {
    return this.posts;
  }

  /** 推荐流还有没有下一页（同上）。 */
  recommendHasMore(): boolean {
    return this.hasMore;
  }

  /**
   * 推荐流"再要一页"（Reels 页上滑到底时调）。
   *
   * 复用 loadMore 那一套闸门（可见性/游标/限流都在里面），返回"要不要继续"，调用方拿
   * `recommendPosts()` 取最新的整份列表。
   */
  async requestMoreForReels(): Promise<boolean> {
    const before: number = this.posts.length;
    await this.loadMore();
    return this.hasMore || this.posts.length > before;
  }

  private setUsers(users: Array<SearchUser>): void {
    this.users = users;
    this.onUsers(users);
  }
}
