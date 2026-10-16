/*
 * 搜索页的视图模型。
 *
 * ## 取数：原生 HTTP 优先，网页只用来"抓模板"
 * 和「我的」页同一套路数（见 core/NativeProfile、core/NativeSearch）：
 *   1) **模板在原生侧** → 直接按模板发 HTTP（几十毫秒），响应在原生解析，不经过网页；
 *   2) **模板还没有**（全新安装 / 隔太久过期）→ 走一次**冷路径**：把常驻网页导航到搜索页，
 *      让页面自己把请求发出去，网络钩子把模板存进 ApiRegistry（`capture('')` 抓该页全部），
 *      顺手在页面搜索框里打一次自己的用户名，把"结果那条"也抓下来 —— 于是之后连第一次
 *      用户搜索都是原生 HTTP。
 *
 * 为什么非得让网页真发一次：IG 的 doc_id / 变量结构 / 私有头（x-ig-www-claim 之类）只有
 * 页面自己发过的那一次才有，自己拼一个 doc_id 是行不通的。这是本 App 一贯的做法。
 *
 * ## 页面结构（需求）
 *   - 没输入关键词 → **推荐帖子**，三列瀑布流；
 *   - 输入并提交 → 账号结果列表（点一个交给网页开主页）。
 *
 * ## 模板抓完顺手落一份"结构摘要"
 * 冷路径跑完会把搜索相关模板的响应形状写进探针文件（`onDigest` → 沙箱 `probe_search_*.txt`）。
 * 这是"写解析之前先看真实结构"的工具（和探针面板的「结构摘要」同用途，但限定在搜索那几条）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { OWN_PROFILE_SCRIPT, PAGE_STATE_SCRIPT, REPLAY_NAMES_SCRIPT, searchResultsScript, searchTypeScript } from '../bridge/WebScripts';
import { AppConfig } from '../config/AppConfig';
import { SearchMapper, SearchPost, SearchResultPage, SearchUser } from '../model/Search';
import { NativeSearch, SearchPostPage, SearchTemplateHealth } from '../core/NativeSearch';
import { CachedSearchPage, SearchCache } from '../core/SearchCache';
import { ApiThrottle } from '../core/ApiThrottle';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SearchViewModel';

/** 搜索请求的操作名片段（等信号用）。 */
const SEARCH_OPS: Array<string> = ['search'];
/** 按片段抓模板时用的过滤器。 */
const CAPTURE_FILTER: string = 'search';
/** 导航到搜索页的等待上限、水合时间。 */
const NAV_READY_TIMEOUT_MS: number = 20000;
const HYDRATE_WAIT_MS: number = 1200;
/** 打完字等页面发出搜索请求的上限。 */
const SEARCH_SIGNAL_MS: number = 8000;
/** 抓模板的轮询次数与间隔。 */
const CAPTURE_POLLS: number = 4;
const CAPTURE_POLL_GAP_MS: number = 1200;
/** 回放一次的上限与重试（只在"没有原生模板"时用到的兜底路径）。 */
const REPLAY_TIMEOUT_MS: number = 8000;
const REPLAY_ATTEMPTS: number = 3;
const REPLAY_RETRY_GAP_MS: number = 1500;
/** 打字脚本自身的上限与重试。 */
const TYPE_SCRIPT_MS: number = 6000;
const TYPE_ATTEMPTS: number = 3;
const TYPE_RETRY_GAP_MS: number = 1500;
/** 抓不到自己用户名时，冷路径用它去打一次字（能搜出结果就行）。 */
const FALLBACK_PROBE_QUERY: string = 'instagram';
/** 预取队列深度（页数）：连续上滑时手上一直有存货，又不至于提前把流量花光。 */
const PREFETCH_DEPTH: number = 3;
/**
 * 首屏至少要有几条（三列瀑布流 ≈ 四行）。
 *
 * 真机实测：推荐那条查询的**首屏可能只回 4 条**（它给的是"还没看过的"那一小撮），
 * 只铺 4 格的话网格看着是空的，而且用户不滑到底就不会去拉下一页 —— 所以在首屏之后主动补
 * （见 fillGrid），补到这个数或者服务端说没有了为止。
 */
const MIN_GRID_POSTS: number = 12;
/** 网格每长这么多条就再落盘一份缓存（见 loadMore；一次写几 KB，不值得每条都写）。 */
const CACHE_RESAVE_STEP: number = 6;

export class SearchViewModel {
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private readonly registry: ApiRegistry = ApiRegistry.getInstance();
  private users: Array<SearchUser> = [];
  private posts: Array<SearchPost> = [];
  private busy: boolean = false;
  /** 当前关键词（空串 = 推荐态）。 */
  private query: string = '';
  /** 上一次搜的词：模板里那个字符串就是它，用它按值定位要改哪个变量（见 NativeSearch.bodyWith）。 */
  private prevQuery: string = '';
  /** 最近一次失败的原样回报（截断），失败提示里带上它 —— 界面就是排查通道。 */
  private diag: string = '-';
  /** 冷路径跑过了没有（抓模板只做一次，别每次进页面都导航网页）。 */
  private coldDone: boolean = false;
  /** 搜索结果模板的体检做过了没有（一轮进程一次，见 healthCheck）。 */
  private healthDone: boolean = false;
  /** 冷路径第二站最后停在哪个地址（诊断：`/reels/` 是否被重定向）。 */
  private exploreLanding: string = '-';
  /** 那一页记录到的请求名（诊断：空 = 服务端直出、根本没有可抓的请求）。 */
  private exploreReplays: string = '-';
  /** 冷路径当前走到哪一步（诊断：异常时靠它定位"死在哪一步"，见 digestText）。 */
  private stage: string = '-';
  /** 进页面时的初始化跑过了没有（推荐流只自动拉一次）。 */
  private opened: boolean = false;
  /** 推荐的取数状态：推荐流是"进页面就拉"，别和用户搜索抢状态行。 */
  private recommendLoaded: boolean = false;
  /** 推荐首屏**正在拉**（防重入，见 loadRecommended）。 */
  private recommendBusy: boolean = false;
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
  /** 下一页游标（`page_info.end_cursor`）与"还有没有更多"（瀑布流滑到底部要用）。 */
  private cursor: string = '';
  private hasMore: boolean = false;
  private loadingMore: boolean = false;
  /**
   * **下一页推荐的缓存队列**（提前拉好放在手边）。
   *
   * 需求："给每个分页做一下缓存页加载，提升加载速度，包括搜索页面"。滑到底那一刻直接贴上来
   * （毫秒级、不见"正在加载"），贴完继续把队列填满（见 prefetchMore）。
   *
   * 队列深度见 PREFETCH_DEPTH：**两页**存货就够连续上滑十几屏了，再多就是白拉流量。
   * 每页本身的条数由 NativeSearch.PAGE_SIZE 决定（那边从 12 提到 36）。
   */
  private prefetched: Array<SearchPostPage> = [];
  private prefetching: boolean = false;

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
  /** 冷路径抓完模板后的**结构摘要**（页面把它落进探针文件，见文件头）。 */
  onDigest: (text: string) => void = (text: string): void => {
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
   * 幂等：模板/推荐都齐了就直接返回，不会每次切页都打一次网络。
   */
  async open(): Promise<void> {
    if (this.opened) {
      return;
    }
    this.opened = true;
    // **先吃落盘缓存**（见 core/SearchCache）：切到搜索页立刻就有上次那面网格，
    // 网络那份回来再整体替换。放在最前面 —— 它比任何网络路径都快（读盘几十毫秒）。
    this.hydrateFromCache();
    /*
     * 只有**缺推荐来源**才走冷路径。
     *
     * 搜索结果那条不再需要它：现在有 REST 兜底（见 NativeSearch.REST_SEARCH_URLS 与
     * `searchUsers` 的顺序），为了它去导航网页要十几秒，正是"进搜索页就卡住"的来源。
     * 推荐那条现在**多半也不用**：移动端探索流（`discover/topical_explore/`）不需要模板
     * （见 NativeSearch.hasRecommendedSource）。
     */
    if (!NativeSearch.hasRecommendedSource()) {
      await this.coldTemplateCapture();
    }
    await this.loadRecommended();
  }

  /**
   * **搜索结果模板体检 + 失败就重抓**（需求："进入首页时就测试搜索请求模板，失败重新抓 http
   * 请求模板，抓到更新进模板库"）。
   *
   * 为什么必须做、而且要在**进首页时**做：
   *   · "模板在"和"模板能用"是两件事 —— 冷启动读的是落盘那份（最长 24 小时），
   *     里面的会话令牌可能早就过期了（IG 会回 `1357004`）；也可能抓成了**搜索框**那条
   *     （名字里带 search，但只回建议词、回不了账号）。
   *   · 不做的话，这个毛病**只有在用户真的搜一次时才暴露**：他要先等一整套十几秒的冷路径
   *     （导航搜索页 → 打字 → 抓模板 → 导航短视频流 → 再回首页），最后还可能"搜索失败" ——
   *     用户那边的说法就是"搜索功能无法使用了"。
   *   · 放在预热链的**最后一步**：体检是一发几百毫秒的原生请求；万一要重抓，冷路径会用
   *     共用的隐藏网页，不能和别的预热步骤抢页面（所以不给它放在中间）。
   *
   * 幂等：一次进程只做一轮（`healthDone`）。
   */
  async healthCheck(): Promise<void> {
    if (this.healthDone) {
      return;
    }
    this.healthDone = true;
    const before: SearchTemplateHealth = await NativeSearch.probeResults(FALLBACK_PROBE_QUERY);
    hilog.info(DOMAIN, TAG, 'search template check ok=%{public}s detail=%{public}s users=%{public}d op=%{public}s',
      `${before.ok}`, before.detail, before.users, before.op);
    if (before.ok) {
      return;
    }
    /*
     * 体检不过 → **重新抓一次 http 请求模板**（force：这一轮可能已经跑过冷路径，
     * 但那次抓的是空态/推荐，不是"结果那条"）。抓到的模板由 `registry.capture` 直接进模板库，
     * 再落盘（24 小时有效）—— 这就是需求里"抓到更新进模板库"那一步。
     */
    hilog.info(DOMAIN, TAG, 'search template unhealthy (%{public}s) → recapture',
      before.detail);
    await this.coldTemplateCapture(FALLBACK_PROBE_QUERY, true);
    const after: SearchTemplateHealth = await NativeSearch.probeResults(FALLBACK_PROBE_QUERY);
    hilog.info(DOMAIN, TAG, 'search template recaptured ok=%{public}s detail=%{public}s users=%{public}d op=%{public}s',
      `${after.ok}`, after.detail, after.users, after.op);
  }

  /**
   * **预热**推荐流（启动时调用，见 pages/Index 的 preloadTabs）。
   *
   * 和 `open()` 的区别：**绝不走冷路径**（冷路径要导航隐藏网页，启动时干这个会把首页信息流
   * 挤掉）。有模板就顺手把第一页拉好、并把后面几页预取上 —— 用户切到搜索页时推荐流已经在手边。
   */
  async warm(): Promise<void> {
    // 缓存先在后台铺上：这样"启动预热"和"用户切到搜索页"谁先发生都不影响首屏。
    this.hydrateFromCache();
    if (this.recommendLoaded || !NativeSearch.hasRecommendedSource()) {
      return;
    }
    await this.loadRecommended();
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
    this.hasMore = cached.hasMore;
    this.onPosts(this.posts);
    this.onMore(this.hasMore);
    this.onStatus('');
    hilog.info(DOMAIN, TAG, 'hydrated from cache n=%{public}d age=%{public}dms',
      cached.posts.length, cached.ageMs);
  }

  /**
   * 拉一次推荐帖子（三列瀑布流的数据）。
   *
   * 外面这层只管**防重入**：`open()`（切到搜索页）和 `retryRecommend()`（再试一次）都可能调用它，
   * 两下撞在一起就是两条几百 KB 的重查询。
   */
  private async loadRecommended(): Promise<void> {
    if (this.recommendBusy) {
      return;
    }
    if (this.recommendLoaded || this.query.length > 0) {
      return;
    }
    this.recommendBusy = true;
    await this.loadRecommendedOnce();
    this.recommendBusy = false;
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
      // 没有任何推荐来源：不报错（用户可能只是还没抓到），留个能看懂的状态 ——
      // 出处在探针面板那颗「存搜索页模板」（它会顺手把短视频流那条也抓下来）。
      this.onStatus('还没有推荐数据（去探针面板点「存搜索页模板」抓一次）');
      return;
    }
    /*
     * **被限流期间不发**（见 core/ApiThrottle）：模板那条推荐流用的就是 clips 那个重查询，
     * 一被 IG 限流就会一个候选一个候选地打（每条几百 KB），越打冷却越久。
     * 这段时间**先把落盘缓存那一页铺上**（hydrateFromCache）—— 上次那 18 格瀑布流
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
    const page: SearchPostPage | null = await NativeSearch.recommendedPage('');
    if (page === null) {
      // 读不出来时也争取给点内容：缓存那份至少是"上次真实拉到的瀑布流"。
      this.hydrateFromCache();
      this.onStatus(this.posts.length > 0 ? '' : '推荐没读出来：' + this.diag);
      return;
    }
    this.recommendLoaded = true;
    this.posts = page.posts;
    this.cursor = page.cursor;
    this.hasMore = page.hasMore;
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
    // 第一页**可能很短**（真机实测：clips 那条查询的首屏只回 4 条 —— 它给的是"还没看过的"
    // 那一小撮，`hasMore` 照旧为真）。只有 4 格的话网格看着就是空的，用户还得自己往下滑才
    // 触发下一页。所以这里主动把它补到铺满一屏以上（见 fillGrid）。
    this.fillGrid();
  }

  /**
   * 把网格补到**至少铺满一屏**（MIN_GRID_POSTS 条）。
   *
   * 为什么需要：首屏可能只有 4 条（见 loadRecommended 的说明），而"下一页"要用户滑到底才触发 ——
   * 表现就是"切到搜索页只有稀稀拉拉几格，等一会儿才慢慢长出来"。这里在首屏之后主动连拉，
   * 直到够一屏、或者服务端说没有了、或者试够次数（不让它一直占着网络）。
   *
   * 走的是 loadMore（先吃预取队列、没有才发请求），所以每次补完界面上就多几格
   * —— 用户看到的是"逐渐长满"，而不是"空白等 10 秒"。
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
   * 每次只发一页（`prefetching` 闸住并发），拉完自己再调一次继续填 —— 深度是 2，所以最多两层。
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
        // 空页：后面确实没有了，别再翻（也免得队列里堆一串空页）。
        this.hasMore = false;
        this.onMore(false);
        return;
      }
      this.prefetched.push(page);
      hilog.info(DOMAIN, TAG, 'prefetch recommend n=%{public}d depth=%{public}d',
        page.posts.length, this.prefetched.length);
      this.prefetchMore();
    }).catch((): void => {
      this.prefetching = false;
    });
  }

  /**
   * 瀑布流滑到底部时接着拉下一页（需求："上滑到底部时瀑布流不刷新"）。
   *
   * 三道闸：正在加载就不再发（滚动回调一秒能来几十次）、`hasMore` 为假就不再发、
   * 没有游标也不再发（有些响应只给 has_next_page 不给 end_cursor，那种翻不动）。
   * 追加时**按 code 去重**：IG 的推荐流会在页与页之间重复同一条。
   */
  async loadMore(): Promise<void> {
    // 诊断：把**四个守卫的真实值**打出来（见下面几行）—— 推荐流"滑到底不加载"到底被哪一条挡住，
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
     * ⚠️ **但移动端探索流不受这把锁管**（用户报："搜索推荐流无法触底刷新"）：`CLIPS` 记的是
     * clips 那条 GraphQL 的冷却，而现在的推荐流走的是 `discover/topical_explore/`
     * （见 core/mobileapi/MobileDiscover）。这里原来无条件按 CLIPS 拦，于是只要 reels 把
     * clips 打到冷却，搜索推荐流滑到底就**一声不响地什么都不加载**（连状态行都不变）。
     */
    if (!NativeSearch.usingMobileRecommended() && ApiThrottle.blocked(ApiThrottle.CLIPS)) {
      /*
       * **把限流写到状态行上**（审计 C1 的现场结论）。
       *
       * 原来这里只打一行日志就 return —— 用户看到的是"滑到底什么都不发生、连转圈都没有"，
       * 和"功能坏了"完全分不清（真机日志里那行是 `throttled=true`，其余守卫全正常）。
       * 限流是 IG 侧的 12 分钟冷却，界面上说清楚就能解释"为什么现在加载不出更多"。
       */
      const minutes: number = ApiThrottle.remainingMinutes(ApiThrottle.CLIPS);
      hilog.info(DOMAIN, TAG, 'loadMore skipped: rate limited %{public}dmin left', minutes);
      this.onStatus(`被 IG 限流，约 ${minutes} 分钟后自动恢复`);
      return;
    }
    if (this.cursor.length === 0) {
      hilog.info(DOMAIN, TAG, 'loadMore: no cursor, stop');
      this.hasMore = false;
      this.onMore(false);
      return;
    }
    this.loadingMore = true;
    this.onLoadingMore(true);
    try {
      // **有缓存页就直接用**（毫秒级）：没有再发请求（见 prefetchMore 的说明）。
      let cached: SearchPostPage | null = null;
      if (this.prefetched.length > 0) {
        cached = this.prefetched[0];
        this.prefetched = this.prefetched.slice(1);
      }
      const page: SearchPostPage | null = cached !== null
        ? cached : await NativeSearch.recommendedPage(this.cursor);
      if (page === null) {
        this.onStatus('加载更多失败：' + this.diag);
        return;
      }
      const seen: Array<string> = [];
      for (let index: number = 0; index < this.posts.length; index++) {
        seen.push(this.posts[index].code);
      }
      const fresh: Array<SearchPost> = [];
      for (let index: number = 0; index < page.posts.length; index++) {
        const one: SearchPost = page.posts[index];
        if (seen.indexOf(one.code) >= 0) {
          continue;
        }
        seen.push(one.code);
        fresh.push(one);
      }
      this.posts = this.posts.concat(fresh);
      this.cursor = page.cursor;
      // 拿到的新条目一条都没加进去（全是重复）时也收手，免得在"最后一页会重复"的情况下无限翻。
      this.hasMore = page.hasMore && (fresh.length > 0 || page.posts.length === 0);
      this.onPosts(this.posts);
      this.onMore(this.hasMore);
      hilog.info(DOMAIN, TAG, 'loadMore +%{public}d total=%{public}d hasMore=%{public}s cached=%{public}s',
        fresh.length, this.posts.length, `${this.hasMore}`, cached !== null ? 'y' : 'n');
      // 网格明显长起来了就**再存一份更满的缓存**（见 savedCount）：下次冷启动/切页一进来
      // 就有十几格，而不是只有第一页那 4 格（真机实测第一页常常只有 4 条）。
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
    this.prevQuery = this.query;
    this.query = text;
    this.onQuery(text);
    this.busy = true;
    this.onBusy(true);
    this.setUsers([]);
    this.onStatus('正在搜索…');
    let usedColdPath: boolean = false;
    try {
      /*
       * **先走原生**（模板 → REST 兜底，见 NativeSearch.searchUsers）：快到几百毫秒。
       *
       * 顺序反过来的代价是真机上量到的：原来"没有结果模板"就先跑冷路径（导航搜索页 →
       * 打字逼请求 → 抓模板 → 导航短视频流 → 回首页），**十几到四十秒**，而这期间用户只看到
       * "正在从网页抓搜索接口"，搜索框里打了字却什么也不出来 —— 这就是"搜索功能无法使用"。
       * 现在 REST 那条不需要模板（`/web/search/topsearch/`，和关注/收藏同一套会话材料），
       * 所以冷路径退成**最后**一手：两条原生路都不行才去驱动网页。
       */
      let page: Array<SearchUser> | null = await NativeSearch.searchUsers(text, this.prevQuery);
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'native search failed → cold capture then retry');
        usedColdPath = true;
        // force：这一轮可能已经跑过冷路径了，但那次抓的是空态/推荐；这次要真搜一次。
        await this.coldTemplateCapture(text, true);
        page = await NativeSearch.searchUsers(text, this.prevQuery);
      }
      if (page === null) {
        // 原生这条路都没成 → 退回"在网页里回放"那条老路，别让用户白点。
        hilog.info(DOMAIN, TAG, 'native search failed, fallback to web replay');
        page = await this.fetchWithRetry(text);
      }
      if (page === null) {
        this.onStatus('搜索失败：' + this.diag);
        return;
      }
      this.setUsers(page);
      /*
       * 后缀只在**真的走了网页抓模板**时才加：REST 兜底那条也算原生（用户不需要知道
       * 我们绕了哪条路），而"（首次走网页抓模板）"出现在 REST 的结果上会误导排查。
       */
      const suffix: string = usedColdPath && !NativeSearch.lastViaRest()
        ? '（首次走网页抓模板）' : '';
      this.onStatus(page.length === 0
        ? '没有找到结果'
        : `找到 ${page.length} 个账号` + suffix);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'search threw: %{public}s', (error as Error).message);
      this.onStatus('搜索出错');
    } finally {
      // 冷路径把网页导航走了：这个网页全 App 共用，必须送回首页（否则首页读不出帖子）。
      if (usedColdPath) {
        this.returnToFeed();
      }
      this.busy = false;
      this.onBusy(false);
    }
  }

  /**
   * 清空关键词，回到推荐态。
   *
   * 需求里搜索框是可清空的：清掉就**立刻**变回推荐瀑布流（不用再拉一次网络，缓存还在）。
   */
  /**
   * 当前关键词（空串 = 推荐态）。给返回键用：有结果时先回推荐流，不退出 App。
   */
  queryNow(): string {
    return this.query;
  }

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

  /** 探针面板用：强制抓一次搜索页模板 + 结构摘要（返回摘要文本，由页面落盘）。 */
  async captureTemplates(): Promise<string> {
    this.coldDone = false;
    this.recommendLoaded = false;
    this.opened = true;
    return await this.coldTemplateCapture('');
  }

  /**
   * 冷路径：导航到搜索页 → 抓该页全部模板 → 顺手把"结果那条"也抓下来 → 回首页。
   *
   * @param probeQuery 想在页面搜索框里打的词；空串时用"自己的用户名"（拿不到就用兜底词）。
   * @returns 结构摘要文本（探针文件用）。
   */
  /**
   * 冷路径：驱动隐藏网页真搜一次，把"结果那条"模板抓下来。
   *
   * @param force true = **即使这一轮已经跑过冷路径，也再跑一次**。
   *   为什么需要：进搜索页时已经跑过一次（抓的是空态 + 推荐），之后原生发搜索被 IG 回
   *   `1357004`（会话令牌过期）时，必须**重新**驱动网页搜一次才能拿到带新鲜令牌的模板 ——
   *   但原来这里第一行就是 `if (this.coldDone) return ''`，第二次调用直接被吞掉，
   *   于是"刷新模板再重试"那一步等于没做（真机日志里就是这样：retry 还在用旧模板）。
   */
  private async coldTemplateCapture(probeQuery: string = '',
                                    force: boolean = false): Promise<string> {
    if (this.coldDone && !force) {
      return '';
    }
    this.coldDone = true;
    this.onStatus('首次进入：正在从网页抓搜索接口');
    this.stage = 'start';
    let digest: string = '';
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_SEARCH_URL);
      this.stage = 'nav-search';
      await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
      await SearchViewModel.sleep(HYDRATE_WAIT_MS);
      // 空态那条（最近搜索）随页面加载自己就发了；抓它。
      this.stage = 'capture-search';
      await this.registry.capture('');
      hilog.info(DOMAIN, TAG, 'cold capture search page %{public}s',
        this.registry.storedSummary());
      // 真正的"结果那条"得页面搜过一次才有：这里替用户先搜一次（自己用户名最稳）。
      this.stage = 'type-search';
      const term: string = probeQuery.length > 0 ? probeQuery : await this.ownUsername();
      await this.typeAndCapture(term, true);
      // 推荐帖子来自**短视频流**（探索页那条实测抓不到东西，见 captureReels 的说明）。
      this.stage = 'capture-reels';
      await this.captureReels();
      // 顺手用刚抓到的模板拉一次推荐（原生 HTTP），把"数据到底从哪来"也写进摘要 ——
      // 探索页被重定向时这里会显示兜底那条（见 NativeSearch.recommendedPosts）。
      this.stage = 'load-recommend';
      await this.loadRecommended();
      // 摘要**无论如何都要落一份**：诊断行的价值就在"哪一步没成"，让摘要跟着异常一起消失
      // 正是最需要它的时候（实测踩过：冷路径一抛，文件一个都没有，只能靠猜）。
      this.stage = 'digest';
      let shape: string = '';
      try {
        shape = await NativeSearch.digest();
      } catch (error) {
        shape = 'digest failed: ' + (error as Error).message;
      }
      this.stage = 'done';
      digest = this.digestText(shape);
      this.onDigest(digest);
      return digest;
    } catch (error) {
      // 失败也要落摘要：**至少留下"死在哪一步"**（下一行就是阶段标记）。
      hilog.warn(DOMAIN, TAG, 'cold capture failed at %{public}s: %{public}s',
        this.stage, (error as Error).message);
      digest = this.digestText(`cold path failed at ${this.stage}: ${(error as Error).message}`);
      this.onDigest(digest);
      return '';
    } finally {
      this.returnToFeed();
    }
  }

  /**
   * 冷路径的摘要文本：**阶段标记 + 数据来源诊断 + 各候选源的响应形状**。
   *
   * 放在一个方法里是为了"成功/失败两条路都落同一份格式" —— 出问题时能直接对比。
   */
  private digestText(shape: string): string {
    return `stage: ${this.stage}\n`
      + `explore landing: ${this.exploreLanding}\n`
      + `explore replays: ${this.exploreReplays}\n`
      + `recommend source: ${NativeSearch.lastSource()}\n`
      + `recommend posts: ${this.posts.length}\n`
      + NativeSearch.lastDiag() + '\n'
      + shape;
  }

  /**
   * 冷路径的第二站：**短视频流**（`/reels/`）。
   *
   * 为什么是它而不是探索页：推荐网格本来该来自 `/explore/`，但实测（探针摘要里那两行
   * `explore landing` / `explore replays`）它要么**一个请求都不发**（服务端直出，`__ogReplay`
   * 里没有任何属于该页的请求），要么**直接跳到 `/explore/search/`** —— 两条都拿不到可用的接口。
   * 而短视频流是 IG 自己的推荐流（`PolarisClipsTabRootPaginationQuery`），封面铺满三列网格
   * 的观感与官方 App 搜索页下面那面网格一致，且这条请求**有模板可抓、有原生 HTTP 可发**。
   *
   * 抓完顺手记下页面的请求名（诊断），失败也不抛：推荐流是"锦上添花"，不该带崩搜索。
   */
  private async captureReels(): Promise<void> {
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_REELS_URL);
      await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
      await SearchViewModel.sleep(HYDRATE_WAIT_MS);
      this.exploreLanding = await this.pageState();
      this.exploreReplays = await this.replayNames();
      hilog.info(DOMAIN, TAG, 'reels landing %{public}s replays=%{public}s',
        this.exploreLanding, this.exploreReplays);
      await this.registry.capture('');
      hilog.info(DOMAIN, TAG, 'cold capture reels page %{public}s',
        this.registry.storedSummary());
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'reels capture failed: %{public}s', (error as Error).message);
    }
  }

  /** 当前页面的地址与就绪状态（`{title,url,ready}` 那支脚本的小包装）。 */
  private async pageState(): Promise<string> {
    try {
      const raw: string = await this.bridge.runBridge(PAGE_STATE_SCRIPT, 5000, 'page-state');
      return raw.substring(0, 200);
    } catch (error) {
      return 'page-state:' + (error as Error).message;
    }
  }

  /**
   * 当前页面**记录到的请求名**（诊断用）。
   *
   * 探索页抓不到模板时用它判断"是姿势不对还是这条页面根本不发请求"：实测结果是后者
   * （服务端直出），所以推荐网格改用短视频流那条模板兜底（见 NativeSearch.CLIPS_HINTS）。
   */
  private async replayNames(): Promise<string> {
    try {
      const raw: string = await this.bridge.runBridge(REPLAY_NAMES_SCRIPT, 5000, 'replay-names');
      return raw.substring(0, 400);
    } catch (error) {
      return 'replay-names:' + (error as Error).message;
    }
  }

  /** 在页面的搜索框里打一次字，把"结果那条"请求逼出来并存成模板。 */
  private async typeAndCapture(query: string, force: boolean = false): Promise<void> {
    /*
     * 结果那条模板已经在手就不用再逼一次（打字那一套最贵：最多三轮、每轮还要等 8 秒信号）
     * —— 但**强制刷新**时必须照打：'已经有模板' 不等于 '模板里的会话令牌还有效'，
     * 原生发出去被 IG 回 1357004 时，只有让网页自己再搜一次才能拿到带新鲜令牌的那一份
     * （真机日志里就是这里被跳过：`results template already stored, skip typing`）。
     */
    if (!force && NativeSearch.hasResultsTemplate()) {
      hilog.info(DOMAIN, TAG, 'results template already stored, skip typing');
      return;
    }
    const text: string = query.length > 0 ? query : FALLBACK_PROBE_QUERY;
    let typed: string = '';
    for (let attempt: number = 1; attempt <= TYPE_ATTEMPTS; attempt++) {
      if (!this.bridge.isReady()) {
        await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
        await SearchViewModel.sleep(HYDRATE_WAIT_MS);
      }
      // 先登记等待、再打字：打字过程中发出的请求才不会漏掉。
      const base: number = this.bridge.replaySeq();
      const arrived: Promise<string> = this.bridge.awaitNewReplay(SEARCH_OPS, base, SEARCH_SIGNAL_MS);
      try {
        typed = await this.bridge.runBridge(searchTypeScript(text), TYPE_SCRIPT_MS, 'search-type');
      } catch (error) {
        typed = 'threw';
      }
      const signal: string = await arrived;
      hilog.info(DOMAIN, TAG, 'type try=%{public}d out=%{public}s signal=%{public}s',
        attempt, typed, signal);
      if (NativeSearch.hasResultsTemplate()) {
        return;
      }
      if (typed.indexOf('typed') >= 0 && signal === 'signal') {
        break;
      }
      if (attempt < TYPE_ATTEMPTS) {
        await SearchViewModel.sleep(TYPE_RETRY_GAP_MS);
      }
    }
    for (let attempt: number = 1; attempt <= CAPTURE_POLLS; attempt++) {
      await this.registry.capture(CAPTURE_FILTER);
      if (NativeSearch.hasResultsTemplate()) {
        hilog.info(DOMAIN, TAG, 'results template ready try=%{public}d', attempt);
        return;
      }
      if (attempt < CAPTURE_POLLS) {
        await SearchViewModel.sleep(CAPTURE_POLL_GAP_MS);
      }
    }
    hilog.info(DOMAIN, TAG, 'no results template typed=%{public}s %{public}s',
      typed, this.registry.storedSummary());
  }

  /** 自己的用户名（拿不到给空串）：冷路径用它当搜索词，保证能搜出东西。 */
  private async ownUsername(): Promise<string> {
    try {
      const href: string = await this.bridge.runBridge(OWN_PROFILE_SCRIPT, 8000, 'own-profile');
      const parts: Array<string> = href.split('/').filter((one: string): boolean => one.length > 0);
      if (parts.length > 0) {
        return parts[0].split('?')[0];
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'own username failed: %{public}s', (error as Error).message);
    }
    return '';
  }

  /** 冷启动那条路读完，把网页送回首页信息流（理由同 ProfileViewModel.returnToFeed）。 */
  private returnToFeed(): void {
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      hilog.info(DOMAIN, TAG, 'cold path done → back to feed');
    } catch (error) {
    }
  }

  /** 兜底：没有原生模板时用"在网页里回放"那条老路（见 bridge/WebScripts.searchResultsScript）。 */
  private async fetchWithRetry(query: string): Promise<Array<SearchUser> | null> {
    let users: Array<SearchUser> | null = null;
    for (let attempt: number = 1; attempt <= REPLAY_ATTEMPTS; attempt++) {
      users = await this.fetch(query, attempt);
      if (users !== null) {
        return users;
      }
      if (attempt < REPLAY_ATTEMPTS) {
        await SearchViewModel.sleep(REPLAY_RETRY_GAP_MS);
      }
    }
    return users;
  }

  private async fetch(query: string, attempt: number): Promise<Array<SearchUser> | null> {
    const name: string = this.playbackTemplate();
    if (name.length === 0) {
      this.diag = 'no-template';
      return null;
    }
    let cfg: string = this.registry.storedJson(name);
    /*
     * **页面回放那份配置过期了，就用原生那份兜底**。
     *
     * 两份模板的 TTL 不一样：`storedJson` 是"给页面回放用"的（10 分钟），
     * `storedForNative` 是"原生直接发"的（24 小时）。真机日志里就是：原生那条被 IG 回
     * `1357004`（会话令牌过期），退回来做网页回放时 `storedJson` 已经空了 ——
     * 于是只剩一句 `no-cfg`，用户看到「搜索失败」。这里用 24 小时那份补上，
     * 至少让"网页里回放"这条路还能走。
     */
    if (cfg.length === 0) {
      const tpl: ApiTemplate | null = this.registry.storedForNative(name);
      if (tpl !== null) {
        cfg = tpl.json();
        hilog.info(DOMAIN, TAG, 'search replay cfg from native op=%{public}s len=%{public}d',
          name, cfg.length);
      }
    }
    /*
     * **模板配置为空就别往网页里注**。
     *
     * `storedJson` 是"给页面回放用"的那份（TTL 只有 10 分钟，见 ApiRegistry），过期后按名字还能
     * 找到模板、但这串配置会是空的。空串传进脚本就是 `JSON.parse("")` —— 页面里抛
     * **`Unexpected end of JSON input`**，回传的 `{state:"error",message:…}` 又被打成
     * 「搜索失败：raw={"state":"error","message":"Unexpected end of JSON input"}」，
     * 看着像搜索接口坏了，其实只是"这份回放配置过期了"。这里直接给出可读的原因。
     */
    if (cfg.length === 0) {
      this.diag = `no-cfg:${name}`;
      hilog.info(DOMAIN, TAG, 'search replay cfg empty op=%{public}s', name);
      return null;
    }
    const vars: string = this.queryVars(query);
    let raw: string = '';
    try {
      raw = await this.bridge.runBridge(searchResultsScript(cfg, vars), REPLAY_TIMEOUT_MS,
        'search-results');
    } catch (error) {
      this.diag = 'bridge:' + (error as Error).message;
      return null;
    }
    const page: SearchResultPage | null = SearchMapper.resultFromJson(raw);
    if (page === null) {
      this.diag = 'raw=' + raw.substring(0, 200);
      hilog.info(DOMAIN, TAG, 'web results try=%{public}d failed raw=%{public}s',
        attempt, raw.substring(0, 400));
      return null;
    }
    return page.users;
  }

  /**
   * "在网页里回放"要用的模板名。
   *
   * 排除 `PolarisSearchNullStateQuery`（空态那条只回最近搜索，拿它回放永远是 0 条）——
   * 早先按 'search' 片段匹配，第一个命中的正好是它。
   */
  private playbackTemplate(): string {
    const names: Array<string> = this.registry.storedNames();
    for (let index: number = 0; index < names.length; index++) {
      const lower: string = names[index].toLowerCase();
      if (lower.indexOf('search') < 0) {
        continue;
      }
      if (lower.indexOf('nullstate') >= 0 || lower.indexOf('recent') >= 0) {
        continue;
      }
      return names[index];
    }
    return '';
  }

  /** 查词变量：把"上一次查的词"和"这一次要查的词"交给脚本，由它按值改（键名不可靠）。 */
  private queryVars(query: string): string {
    return '{"__ogFrom":' + JSON.stringify(this.prevQuery) + ',"__ogTo":' + JSON.stringify(query) + '}';
  }

  private setUsers(users: Array<SearchUser>): void {
    this.users = users;
    this.onUsers(users);
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
