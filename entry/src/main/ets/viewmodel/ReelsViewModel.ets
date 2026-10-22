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
        const fallback: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, '', true);
        if (fallback !== null) {
          this.noteCursor(fallback.nextCursor);
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
        this.noteCursor(warm.nextCursor);
        this.applyNativePage(warm, false);
        hilog.info(DOMAIN, TAG, 'reels first from warm n=%{public}d ms=%{public}d',
          warm.reels.length, Date.now() - startedMs);
        this.prefetchNativePage();
        return;
      }
      // ---- 2) 原生直发（有落盘模板 + 登录态时可走）----
      const native: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, '', true);
      if (native !== null) {
        this.noteCursor(native.nextCursor);
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
    this.onReels(this.reels, this.more);
    this.onStatus('已加载 ' + this.reels.length + ' 条' + (this.more ? '' : '（到底了）'));
    // 落盘一份：**首屏和翻页都存**（首页那条查询首屏有时只回 2~4 条，光存第一页太少）。
    // 被限流/没网时这几十条就是视频标签能显示的全部内容（见 core/ReelsCache）。
    ReelsCache.save(this.reels);
    return fresh.length;
  }

  /**
   * **记下游标**（谁取到带游标的页，谁就调它一次）。
   *
   * 为什么不在 `applyNativePage` 里顺手记：预取的那几页是**先排队、晚些才铺上屏**的，
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
    /*
     * **两条源交替**（这是"视频刷不完"的关键，理由见 core/NativeReels 的补货池说明）：
     *   · 探索流：能一直往下翻，但图文混排（实测 8 条里只有 1~3 条是视频、500KB / 5 秒）；
     *   · 作者那页（`clips/user/`）：清一色视频、几十 KB、一两秒。
     * 上一次补的是探索流，这次就补一个作者；反过来也一样。没有作者可补时才连续走探索流。
     */
    const authorReady: boolean = !this.lastFillWasAuthor && NativeReels.authorPoolSize() > 0;
    if (authorReady) {
      this.fillFromAuthor();
      return;
    }
    this.fillFromExplore();
  }

  /** 补一页"某个作者的 Reels"进队列（不推进探索流游标）。 */
  private fillFromAuthor(): void {
    this.nativeFetching = true;
    NativeReels.fetchAuthorPage().then((page: NativeReelsPage | null): void => {
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
        page.reels.length, NativeReels.authorPoolSize(), this.nativeQueue.length);
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
    NativeReels.fetchExplorePage()
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

  /** 翻页：先吃原生缓存，再走原生现抓（用户驱动，允许探索流兜底）。 */
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
        this.noteCursor(cached.nextCursor);
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
    /*
     * **不再用 `more` 提前拦**：IG 的 clips 分页经常把游标给了却把 `more_available` 写成 false，
     * 按它拦就是"滑到底一次都不再请求"（用户报的"reels 无法获取新的视频"）。
     * 能不能翻由**结果**决定：真的拿不到新内容才把 `more` 置 false。
     */
    this.busy = true;
    this.onBusy(true);
    try {
      /*
       * ① 继续按游标翻（用户驱动，允许探索流兜底）。
       *
       * `allowExplore = true` 是必须的：首屏在 clips 被限流时是由**探索流**顶上的（见 loadFirst），
       * 两条路的游标互不通用 —— 拿探索流的 `max_id` 去问 clips 必然是空。
       */
      let attempt: number = 0;
      while (attempt < 2) {
        const cursor: string = this.nativeCursor.length > 0 ? this.nativeCursor : this.endCursor;
        if (cursor.length === 0) {
          break;
        }
        const live: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, cursor, true);
        attempt++;
        if (live !== null) {
          this.noteCursor(live.nextCursor);
          const added: number = this.applyNativePage(live, true);
          hilog.info(DOMAIN, TAG, 'reels page live n=%{public}d ms=%{public}d added=%{public}d attempt=%{public}d',
            live.reels.length, live.ms, added, attempt);
          this.prefetchNativePage();
          if (added > 0) {
            return;
          }
          // 整页都是已经有的（IG 的分页游标常把上一条/上几条又带回来）：拿新游标再试一次。
          continue;
        }
        // 这一发没拿到（限流 / 端点抖动）：被限流时保留 more，等冷却结束还能接着翻。
        if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
          this.onStatus(`Instagram 暂时限制了视频接口，约 ${ApiThrottle.remainingMinutes(ApiThrottle.CLIPS)} 分钟后再试`);
          return;
        }
        break;
      }
      /*
       * ② **游标翻不动时，直接从探索流拿一页**。
       *
       * 为什么不是"重取第一页"：第一页就是开头那三条 `clips/*`，它们是**固定的一批**
       * （每次冷启动都回同一组）—— 重取只会整页重复，一条都新增不了，等于白花一发。
       * 探索流是唯一"每次都能给新条目"的源（它的 `max_id` 真的往后走），所以这里先问它。
       */
      const explore: NativeReelsPage | null = await NativeReels.fetchExplorePage();
      if (explore !== null) {
        const added: number = this.applyNativePage(explore, true);
        hilog.info(DOMAIN, TAG, 'reels page explore n=%{public}d ms=%{public}d added=%{public}d',
          explore.reels.length, explore.ms, added);
        if (added > 0) {
          this.prefetchNativePage();
          return;
        }
      }
      /*
       * ③ 探索流也没新增：重取一次第一页（IG 的服务端排序会变，偶尔能带回没见过的条目）。
       * 这就是用户手动做的事（退出再进来）—— 这里替他在"滑到底"这一刻自动做掉。
       */
      const fresh: NativeReelsPage | null = await NativeReels.fetchPage(NATIVE_PAGE_COUNT, '', true);
      if (fresh !== null) {
        this.noteCursor(fresh.nextCursor);
        const added: number = this.applyNativePage(fresh, true);
        hilog.info(DOMAIN, TAG, 'reels page restarted n=%{public}d added=%{public}d',
          fresh.reels.length, added);
        if (added > 0) {
          this.prefetchNativePage();
          return;
        }
        if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
          return;
        }
      }
      // 真的拿不到新内容：收工，等用户下次上滑再试（下次仍会先试游标）。
      this.more = false;
      this.onReels(this.reels, this.more);
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }
}
