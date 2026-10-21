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
import { NativeReels, NativeReelsPage } from '../core/NativeReels';
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
const NATIVE_CACHE_PAGES: number = 2;
const NATIVE_WARM_MAX_AGE_MS: number = 120000;

export class ReelsViewModel implements ReelStreamVm {
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
  }

  private reels: Array<Reel> = [];
  private endCursor: string = '';
  private more: boolean = true;
  private busy: boolean = false;
  private diag: string = '-';
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
      // ---- 3) 原生也没拿到：铺落盘缓存或如实说明（网页模板回放那条路已删除）----
      this.fromCacheOrSay(ApiThrottle.blocked(ApiThrottle.CLIPS)
        ? ApiThrottle.remainingMinutes(ApiThrottle.CLIPS) : 0);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadFirst threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
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
      // 原生也没拿到（缓存吃完 + 现抓失败）：收工，等用户下次上滑再试。
      this.more = false;
      this.onReels(this.reels, this.more);
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }
}
