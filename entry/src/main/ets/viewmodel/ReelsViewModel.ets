/*
 * Reels 视频流的视图模型。
 *
 * 和 ProfileViewModel 完全同一套路数（见它的说明）：
 *   1) 冷启动：让隐藏网页打开一次 /reels/，页面自己会发 PolarisClipsTabRootPaginationQuery，
 *      网络钩子把模板交给原生存住（capture）；
 *   2) 之后用**小脚本回放**（reelsScript）+ 重试：刚导航完那几秒页面忙、注入脚本抢不到
 *      执行机会（桥会超时），所以短超时 + 多试几次；
 *   3) 翻页只改游标（after），不重新导航。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { ApiRegistry } from '../bridge/ApiRegistry';
import { reelsScript } from '../bridge/WebScripts';
import { AppConfig } from '../config/AppConfig';
import { Reel, ReelMapper, ReelsDto, ReelsPage, ReelStreamVm } from '../model/Reel';
import { NativeReels, NativeReelsPage } from '../core/NativeReels';
import { ApiThrottle } from '../core/ApiThrottle';
import { CachedReelsPage, ReelsCache } from '../core/ReelsCache';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsViewModel';

/** Reels 那条查询的操作名（回放时按名字取模板）。 */
const OP_REELS: string = 'PolarisClipsTabRootPaginationQuery';
/** 冷启动抓模板用的片段。 */
const CAPTURE_FILTER: string = 'ClipsTabRoot';
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
const NATIVE_CACHE_PAGES: number = 2;
const NATIVE_WARM_MAX_AGE_MS: number = 120000;

export class ReelsViewModel implements ReelStreamVm {
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private readonly registry: ApiRegistry = ApiRegistry.getInstance();
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
  }

  private reels: Array<Reel> = [];
  private endCursor: string = '';
  private more: boolean = true;
  private busy: boolean = false;
  private diag: string = '-';
  private usedColdPath: boolean = false;
  /** 当前看到第几条（切 tab 重建页面时要恢复，见 activeIndex）。 */
  private active: number = 0;
  /** 原生已经取好、等着上滑切换时直接铺的那些页（最多 NATIVE_CACHE_PAGES 页，先进先出）。 */
  private nativeQueue: Array<NativeReelsPage> = [];
  /** 原生链路自己的游标（和网页回放那条 endCursor 分开，避免互相带偏）。 */
  private nativeCursor: string = '';
  private nativeHasMore: boolean = false;
  private nativeFetching: boolean = false;

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
        const fallback: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, '', true);
        if (fallback !== null) {
          this.applyNativePage(fallback, false);
          hilog.info(DOMAIN, TAG, 'reels first via explore fallback n=%{public}d ms=%{public}d',
            fallback.reels.length, Date.now() - startedMs);
          this.onStatus('已加载 ' + fallback.reels.length + ' 条（视频接口受限，先用推荐流顶上）');
          this.prefetchNativePage();
        }
        return;
      }
      // ---- 1) 启动预热那一页（app 一起来就发了，见 EntryAbility / NativeReels.warmStart）----
      const warm: NativeReelsPage | null = NativeReels.takeWarm(NATIVE_WARM_MAX_AGE_MS);
      if (warm !== null) {
        this.applyNativePage(warm, false);
        hilog.info(DOMAIN, TAG, 'reels first from warm n=%{public}d ms=%{public}d',
          warm.reels.length, Date.now() - startedMs);
        this.prefetchNativePage();
        return;
      }
      // ---- 2) 原生直发（有落盘模板 + 登录态时可走）----
      const native: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, '', true);
      if (native !== null) {
        this.applyNativePage(native, false);
        hilog.info(DOMAIN, TAG, 'reels first native n=%{public}d ms=%{public}d ms=%{public}d',
          native.reels.length, native.ms, Date.now() - startedMs);
        this.prefetchNativePage();
        return;
      }
      // 原生这一发被**限流**了：别再走下面那条网页路（那里还要重试 5 次，见 core/ApiThrottle）。
      if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
        this.fromCacheOrSay(ApiThrottle.remainingMinutes(ApiThrottle.CLIPS));
        return;
      }
      // ---- 3) 退回原来的网页路（没有模板、或模板过期被 IG 判成无效时靠它）----
      // force=true：走到这里就说明原生没拿到东西，手里那份模板多半已过期，必须重新抓一份，
      // 顺便把新的落盘 —— 下一次冷启动的原生预热才有得用。
      const ok: boolean = await this.ensureTemplate(true);
      if (!ok) {
        this.onStatus('拿不到接口模板');
        return;
      }
      const page: ReelsPage | null = await this.fetchWithRetry('');
      if (page === null) {
        if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
          this.fromCacheOrSay(ApiThrottle.remainingMinutes(ApiThrottle.CLIPS));
          return;
        }
        this.onStatus('读取失败：' + this.diag);
        return;
      }
      this.reels = ReelsViewModel.dedupe(page.reels);
      this.endCursor = page.endCursor;
      // 没有游标就当到底了：触底哨兵只看 more，不看清游标，会让它一直空转。
      this.more = page.hasMore && page.endCursor.length > 0;
      this.onReels(this.reels, this.more);
      this.onStatus('已加载 ' + this.reels.length + ' 条'
        + (this.usedColdPath ? '（首次走网页）' : ''));
      ReelsCache.save(this.reels);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadFirst threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      // 走过冷启动就一定要把网页送回首页（理由同 ProfileViewModel.returnToFeed：
      // 隐藏网页全 App 共用，留在 /reels/ 会让首页信息流读不出帖子）。
      if (this.usedColdPath) {
        this.returnToFeed();
      }
      this.busy = false;
      this.onBusy(false);
    }
  }

  /**
   * 把原生取到的一页铺上（首屏或翻页都用它，去重规则只有一份）。
   *
   * @param append true = 追加到已有列表后面；false = 当作第一页整体替换。
   * @returns 真正新增了几条（用来判断"这一页是不是全重复"）。
   */
  private applyNativePage(page: NativeReelsPage, append: boolean): number {
    const known: Set<string> = new Set<string>();
    if (append) {
      for (let index: number = 0; index < this.reels.length; index++) {
        known.add(this.reels[index].shortcode);
      }
    }
    const fresh: Array<Reel> = [];
    for (let index: number = 0; index < page.reels.length; index++) {
      const reel: Reel = page.reels[index];
      if (known.has(reel.shortcode)) {
        continue;
      }
      known.add(reel.shortcode);
      fresh.push(reel);
    }
    this.reels = append ? this.reels.concat(fresh) : fresh;
    this.nativeCursor = page.nextCursor;
    this.nativeHasMore = page.hasMore;
    // 网页那条路的游标也一起对齐：原生这条路失败时能接着往下翻，而不是从头来过。
    this.endCursor = page.nextCursor;
    this.more = page.hasMore && page.nextCursor.length > 0;
    this.onReels(this.reels, this.more);
    this.onStatus('已加载 ' + this.reels.length + ' 条' + (this.more ? '' : '（到底了）'));
    // 落盘一份：**首屏和翻页都存**（首页那条查询首屏有时只回 2~4 条，光存第一页太少）。
    // 被限流/没网时这几十条就是视频标签能显示的全部内容（见 core/ReelsCache）。
    ReelsCache.save(this.reels);
    return fresh.length;
  }

  /**
   * 被限流（或没有可用数据源）时的收尾：**先铺上次落盘那一页**，实在没有才如实说。
   *
   * @param minutes 还有几分钟解禁（只用来写提示语）。
   */
  private fromCacheOrSay(minutes: number): void {
    const cached: CachedReelsPage | null = ReelsCache.load();
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
    // 深度固定 2 页，理由同 FeedViewModel（上滑要有货）。
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
    NativeReels.fetchPage(NATIVE_PAGE_COUNT, cursor, true).then((page: NativeReelsPage | null): void => {
      this.nativeFetching = false;
      if (page === null) {
        return;
      }
      this.nativeQueue.push(page);
      this.nativeHasMore = page.hasMore;
      hilog.info(DOMAIN, TAG, 'reels prefetch ready n=%{public}d ms=%{public}d more=%{public}s queued=%{public}d',
        page.reels.length, page.ms, page.hasMore ? 'y' : 'n', this.nativeQueue.length);
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
   * 冷启动那条路读完，把隐藏网页送回首页信息流。
   *
   * 故意不 awaitPageReady：数据已经用原生存下的模板拿到了，不必让界面陪着等整页导航；
   * 信息流那边触发时会自己等页面就绪。
   */
  private returnToFeed(): void {
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      hilog.info(DOMAIN, TAG, 'cold path done → back to feed');
    } catch (error) {
    }
  }

  /** 翻页：先吃原生缓存，再走原生现抓，最后退回模板回放。 */
  async requestMore(): Promise<void> {
    if (this.busy) {
      return;
    }
    // 被限流期间不再往下要（缓存队列里那页还是照铺，见下）。
    const limited: boolean = ApiThrottle.blocked(ApiThrottle.CLIPS);
    // 原生缓存里有页就直接铺（**即使 this.more 已经是 false 也先看一眼**：
    // more 是按上一页算的，队列里那页可能还有内容；否则会出现"缓存里明明有、却不动"）。
    const cached: NativeReelsPage | null = this.takeNativePage();
    if (cached !== null) {
      this.busy = true;
      this.onBusy(true);
      try {
        const added: number = this.applyNativePage(cached, true);
        hilog.info(DOMAIN, TAG, 'reels page from cache n=%{public}d added=%{public}d queued=%{public}d',
          cached.reels.length, added, this.nativeQueue.length);
        this.prefetchNativePage();
      } finally {
        this.busy = false;
        this.onBusy(false);
      }
      return;
    }
    if (limited) {
      // 队列空了又在冷却里：如实说一句，不去发那一发注定被拒的请求。
      hilog.info(DOMAIN, TAG, 'more skipped: rate limited');
      this.onStatus(`Instagram 暂时限制了视频接口，约 ${ApiThrottle.remainingMinutes(ApiThrottle.CLIPS)} 分钟后再试`);
      return;
    }
    if (!this.more || this.endCursor.length === 0) {
      return;
    }
    this.busy = true;
    this.onBusy(true);
    try {
      // 原生现抓一页（仍然不碰网页）：缓存被上滑抢先吃完时走这条。
      if (this.nativeHasMore && this.nativeCursor.length > 0) {
        const live: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, this.nativeCursor);
        if (live !== null) {
          const added: number = this.applyNativePage(live, true);
          hilog.info(DOMAIN, TAG, 'reels page live n=%{public}d ms=%{public}d added=%{public}d',
            live.reels.length, live.ms, added);
          this.prefetchNativePage();
          if (added > 0) {
            return;
          }
        }
      }
      const prevCursor: string = this.endCursor;
      const page: ReelsPage | null = await this.fetchWithRetry(this.endCursor);
      if (page === null || page.reels.length === 0) {
        this.more = false;
        this.onReels(this.reels, this.more);
        return;
      }
      // **按 shortcode 去重后再追加**：IG 的 clips 分页游标经常把上一条/上几条又带回来，
      // 直接 concat 就会让同一条视频在流里出现好几次（用户看到的"视频重复出现"），
      // 而且 ForEach 的键也是 shortcode，重复键会让渲染更乱。
      const known: Set<string> = new Set<string>();
      for (let index: number = 0; index < this.reels.length; index++) {
        known.add(this.reels[index].shortcode);
      }
      const fresh: Array<Reel> = [];
      for (let index: number = 0; index < page.reels.length; index++) {
        const reel: Reel = page.reels[index];
        if (known.has(reel.shortcode)) {
          continue;
        }
        known.add(reel.shortcode);
        fresh.push(reel);
      }
      if (fresh.length === 0) {
        // 这一页全是已经有的：说明游标没往前走（再拉还是同一页）——直接收工，
        // 否则会一遍遍把同样的视频追加进来。
        hilog.info(DOMAIN, TAG, 'reels page all duplicated n=%{public}d → stop',
          page.reels.length);
        this.more = false;
        this.onReels(this.reels, this.more);
        return;
      }
      this.reels = this.reels.concat(fresh);
      this.endCursor = page.endCursor;
      // 游标没变也停：再翻只会拿到同一页。
      this.more = page.hasMore && page.endCursor.length > 0 && page.endCursor !== prevCursor;
      this.onReels(this.reels, this.more);
      this.onStatus('已加载 ' + this.reels.length + ' 条' + (this.more ? '' : '（到底了）'));
      hilog.info(DOMAIN, TAG, 'reels appended fresh=%{public}d total=%{public}d more=%{public}s',
        fresh.length, this.reels.length, this.more ? 'y' : 'n');
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }

  /**
   * 确保 reels 那条模板在原生侧；没有（或强制刷新）就让隐藏网页打开一次 /reels/。
   *
   * 判断用 **storedJson**（已存模板），不是 `has()` —— 后者查的是接口索引，
   * 刚 capture 完还没同步，会误判成"没有"（这个坑在「我的」页已经踩过一次）。
   *
   * @param force 强制重新抓一次。**什么时候必须强制**：原生那条路拿到的是 HTML 而不是 JSON
   *              （实测：200 + 63KB + `<!DOCTYPE html>`）—— 那说明手里这份 Clips 模板已经过期，
   *              IG 不认它里面的 doc_id / 变量组合了。信息流那条每次都刷新（见 FeedViewModel
   *              的 saveTemplateOnce），reels 这条原来只在"没有模板"时才抓，于是一份隔天甚至
   *              更久的旧模板会被一直用下去（`storedForNative` 的 TTL 故意放到 24 小时）。
   */
  private async ensureTemplate(force: boolean = false): Promise<boolean> {
    this.usedColdPath = false;
    if (!force && this.hasTemplate()) {
      return true;
    }
    this.onStatus('首次加载：正在读取网页');
    this.bridge.loadUrl(AppConfig.INSTAGRAM_REELS_URL);
    // 标记立刻立起来：无论后面抓没抓到模板，收尾都要把网页送回首页（见 returnToFeed）。
    this.usedColdPath = true;
    await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    await ReelsViewModel.sleep(HYDRATE_WAIT_MS);
    const stored: boolean = await this.registry.capture(CAPTURE_FILTER);
    // 这里**刻意不等**页面自己那条 Clips 响应（试过 `awaitCaptureScript('reels', 2500)`）：
    // 实测（真机 4 次冷路径）页面那条请求的响应要比我们的回放晚到（回放 ~1s 就有数据，
    // 而轮询等到 2.5s 也还是 `timeout:cap=...`），而且那一刻页面正在导航/忙，注入的轮询脚本
    // 有一半概率连结果都回不来（bridge 直接 `{"state":"timeout"}`）。
    // 所以 reels 的冷路径保持"存模板 → 回放"；页面响应真被缓存时（用户就在 reels 页上时），
    // `reelsScript` 里的 __ogCap 判断会自己命中，不必额外等。
    hilog.info(DOMAIN, TAG, 'cold path stored=%{public}s %{public}s',
      stored ? 'y' : 'n', this.registry.storedSummary());
    return this.hasTemplate();
  }

  private hasTemplate(): boolean {
    return this.registry.storedJson(OP_REELS).length > 0;
  }

  private async fetchWithRetry(cursor: string): Promise<ReelsPage | null> {
    let page: ReelsPage | null = null;
    for (let attempt: number = 1; attempt <= EXTRACT_ATTEMPTS; attempt++) {
      page = await this.fetch(cursor, attempt);
      if (page !== null) {
        return page;
      }
      this.onStatus('第' + attempt + '次未成：' + this.diag);
      if (attempt < EXTRACT_ATTEMPTS) {
        await ReelsViewModel.sleep(EXTRACT_RETRY_GAP_MS);
      }
    }
    return page;
  }

  private async fetch(cursor: string, attempt: number): Promise<ReelsPage | null> {
    const cfg: string = this.registry.storedJson(OP_REELS);
    if (cfg.length === 0) {
      this.diag = 'no-template';
      return null;
    }
    // 只改游标，不碰 first（理由同 ProfileViewModel.fetchPosts：覆盖 first 会让 IG 的
    // GraphQL 回 noncoercible_variable_value，data 直接是 null）。第一页删掉 after。
    const vars: string = cursor.length > 0
      ? '{"after":' + JSON.stringify(cursor) + '}'
      : '{"after":null}';
    let raw: string = '';
    try {
      raw = await this.bridge.runBridge(reelsScript(cfg, vars), EXTRACT_TIMEOUT_MS, 'reels');
    } catch (error) {
      this.diag = 'bridge:' + (error as Error).message;
      return null;
    }
    const page: ReelsPage | null = ReelMapper.pageFromJson(raw);
    if (page === null) {
      this.diag = raw.substring(0, 80);
      hilog.info(DOMAIN, TAG, 'reels try=%{public}d failed raw=%{public}s',
        attempt, raw.substring(0, 160));
      return null;
    }
    // src 用来区分"探针抓到的页面响应（capture，零额外网络）"和"我们回放的那一发（replay）"，
    // 以及各自的耗时 —— 取数路径优化前后就靠它对比。
    let src: string = '?';
    try {
      src = (JSON.parse(raw) as ReelsDto).src ?? 'replay';
    } catch (error) {
    }
    hilog.info(DOMAIN, TAG, 'reels ok try=%{public}d src=%{public}s n=%{public}d more=%{public}s',
      attempt, src, page.reels.length, page.hasMore ? 'y' : 'n');
    return page;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  /** 一页内部自己也可能有重复（同一条被接口返回两次），按 shortcode 去一次重。 */
  private static dedupe(reels: Array<Reel>): Array<Reel> {
    const seen: Set<string> = new Set<string>();
    const out: Array<Reel> = [];
    for (let index: number = 0; index < reels.length; index++) {
      const reel: Reel = reels[index];
      if (seen.has(reel.shortcode)) {
        continue;
      }
      seen.add(reel.shortcode);
      out.push(reel);
    }
    return out;
  }
}
