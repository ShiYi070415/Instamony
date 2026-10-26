/*
 * 原生直接要首页信息流 —— 数据来自移动端 `feed/timeline/`
 * （见 core/mobileapi/MobileFeedTimeline，与 instagrapi 同源的 App 私有接口）。
 *
 * 模板相关的一切（页面抓包、模板表、模板头）都已删除：这里只保留"要一页 + 解析"两件事。
 *
 * 失败一律**不抛**，返回 null，调用方据此提示重试。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { taskpool } from '@kit.ArkTS';
import { FeedItemDto } from '../model/FeedDto';
import { NativeTimeline, NativeTimelineParser } from './NativeTimelineParser';
// 首页时间线的移动端通道（实测 POST feed/timeline/ → 200；见那个文件的文件头）。
import { MobileFeedPage, MobileFeedTimeline } from './mobileapi/MobileFeedTimeline';
// "关注流已看完"这个状态要落盘（见 markCaughtUp）。
import { FeedCache } from './FeedCache';
// 分享数取证（落盘 `files/Instamony_share_probe.txt`，见那个文件的头注释）。
import { ShareProbe } from './ShareProbe';
import { QualityProfile } from './MediaQuality';
import { parseFeedTask } from '../workers/FeedParseTask';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeFeed';

/**
 * 原生取好的一页（解析好的条目 + 游标）。
 *
 * 两个用途：① 分页缓存里"备好的下一页"；② 冷启动**预热**（见 warmStart/takeWarm）。
 */
export class NativeFeedPage {
  readonly items: Array<FeedItemDto>;
  readonly nextCursor: string;
  readonly hasMore: boolean;
  /** 这一发花了多久（毫秒，日志用）。 */
  readonly ms: number;
  /** 这一页是什么时候取到的（判断预热的那份还新不新鲜）。 */
  readonly at: number;

  constructor(items: Array<FeedItemDto>, nextCursor: string, hasMore: boolean, ms: number) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    this.ms = ms;
    this.at = Date.now();
  }
}

/** 一次原生取数的结果（不抛异常，用 error 表达失败）。 */export class NativeFetchResult {
  readonly ok: boolean;
  readonly error: string;
  readonly code: number;
  readonly ms: number;
  readonly bytes: number;
  readonly hasConn: boolean;
  /** 响应里数出来的帖子条数（粗数，只用于日志/判断有没有拿到货）。 */
  readonly codes: number;
  readonly body: string;

  constructor(ok: boolean, error: string, code: number, ms: number, bytes: number,
              hasConn: boolean, codes: number, body: string) {
    this.ok = ok;
    this.error = error;
    this.code = code;
    this.ms = ms;
    this.bytes = bytes;
    this.hasConn = hasConn;
    this.codes = codes;
    this.body = body;
  }

  /** 一行摘要（日志用）。 */
  summary(): string {
    return `ok=${this.ok ? 'y' : 'n'} err=${this.error} http=${this.code} ms=${this.ms} `
      + `bytes=${this.bytes} conn=${this.hasConn ? 'y' : 'n'} codes=${this.codes}`;
  }
}

export class NativeFeed {
  /**
   * 冷启动预热的那一页（app 一起来就发，见 warmStart）。
   *
   * 为什么要有它：现在首屏数据是"页面问才要"（1.2~2.4 秒），而 app 起来到用户看到信息流
   * 中间还有一段（启动窗口、组件构建、网页宿主创建）。把这一发**提前到 ability onCreate**
   * 发出去，等页面来要时数据多半已经躺在内存里，用户看到的就是"秒出内容"。
   */
  private static warmPage: NativeFeedPage | null = null;
  private static warming: boolean = false;
  /**
   * 预热那次请求本身（在飞的时候非空）。
   *
   * 用处：页面在预热未完成时来要第一页，就 `await` 它然后取结果 —— **不再发第二发**。
   * 真机实测：冷启动 `feed/timeline/` 会连着打两发一样的请求（各 ~300KB / 3 秒）。
   */
  private static warmTask: Promise<void> | null = null;

  /**
   * **正在飞的翻页请求**（游标 → Promise）：同一个游标只发一发。
   *
   * 为什么要它：`prefetchNativePage` 与触底翻页、缓存补页都可能同时要"同一个游标"，
   * 全局闸门那边两发就是两发（真机冷启动实测：15 秒里 `feed/timeline/` 被打了 4 发、
   * 每发 ~350KB，而且回的是**同一页**）。这里按游标合并，第二发直接搭第一发的车。
   */
  private static inflightPages: Map<string, Promise<NativeFeedPage | null>> =
    new Map<string, Promise<NativeFeedPage | null>>();
  /**
   * **刚拿回来的翻页结果**（游标 → 页），只活 `PAGE_MEMO_MS`。
   *
   * 翻页是"只追加"的语义：同一个游标在几秒内重复要，服务端回的一定是同一页 ——
   * 与其再排一次闸门、再解析一次 350KB，不如直接给回上一次那份。
   * 只对**非空游标**生效：第一页（刷新）永远要真的去问，不能拿旧的糊弄用户。
   */
  private static memoPages: Map<string, NativeFeedPage> = new Map<string, NativeFeedPage>();
  /** 每个 memo 是什么时候放进去的（毫秒）。 */
  private static memoAtMs: Map<string, number> = new Map<string, number>();
  /** memo 的有效期：够盖住"同一轮里连续几次要同一页"，又不会让用户看到过期内容。 */
  private static readonly PAGE_MEMO_MS: number = 8000;
  /** 作废代数（换账号时 +1）：作废之前发起、之后才回来的那一页不许写进 memo。 */
  private static epoch: number = 0;

  /**
   * 清空翻页缓存（换账号/退出登录时调，见 pages/Index.forgetAccountMemory）。
   *
   * 不清的话：换号后第一分钟里翻页拿到的还是**上一个人**预取的那几页（同一个缓存键）。
   */
  static clearCache(): void {
    NativeFeed.memoPages.clear();
    NativeFeed.memoAtMs.clear();
    NativeFeed.inflightPages.clear();
    NativeFeed.warmPage = null;
    NativeFeed.epoch++;
    hilog.info(DOMAIN, TAG, 'feed page cache cleared (epoch %{public}d)', NativeFeed.epoch);
  }

  /**
   * app 启动时就发一发第一页，结果留在内存里等页面来取（幂等，重复调用不会重复发）。
   *
   * 不 await、不抛：预热失败无所谓，页面那条路会照旧自己发一次。
   */
  static warmStart(first: number): void {
    if (NativeFeed.warming || NativeFeed.warmPage !== null) {
      return;
    }
    NativeFeed.warming = true;
    const started: number = Date.now();
    /*
     * **把这次预热存成"在飞的 Promise"**（见 fetchPage 的开头）：
     * 页面往往在预热还没回来时就来要第一页，以前会**再发一发一模一样的请求** ——
     * 真机日志（冷启动）里 `feed/timeline/` 连着两发、各 ~300KB / 3 秒，
     * 白等一次网络 + 白解析一次 300KB。存下来之后页面直接搭这趟车。
     */
    NativeFeed.warmTask = NativeFeed.fetchPage(first, '').then((page: NativeFeedPage | null): void => {
      NativeFeed.warming = false;
      NativeFeed.warmTask = null;
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'warmStart miss after %{public}dms', Date.now() - started);
        return;
      }
      NativeFeed.warmPage = page;
      hilog.info(DOMAIN, TAG, 'warmStart ready n=%{public}d ms=%{public}d (since launch %{public}d)',
        page.items.length, page.ms, Date.now() - started);
    }).catch((): void => {
      NativeFeed.warming = false;
      NativeFeed.warmTask = null;
    });
  }

  /**
   * 取走预热的那一页（取走即清空）。
   *
   * @param maxAgeMs 太旧的不要：app 可能在后台躺了很久，那份数据已经不新鲜。
   */
  static takeWarm(maxAgeMs: number): NativeFeedPage | null {
    const page: NativeFeedPage | null = NativeFeed.warmPage;
    if (page === null) {
      return null;
    }
    NativeFeed.warmPage = null;
    if (Date.now() - page.at > maxAgeMs) {
      hilog.info(DOMAIN, TAG, 'warm page discarded age=%{public}dms', Date.now() - page.at);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'warm page used age=%{public}dms n=%{public}d',
      Date.now() - page.at, page.items.length);
    return page;
  }

  /**
   * 要一页并解析好（预热、首屏、翻页都走这里，保证解析规则只有一份）。
   *
   * **只走移动端 `feed/timeline/`**（见 core/mobileapi/MobileFeedTimeline）。
   * 模板回放那条兜底已经删了：四批迁移（评论 / Reels / 搜索 / 首页）之后，
   * 页面里不再注入抓包钩子（`NETWORK_WATCHER` 已退役），模板既抓不到，
   * 也不该再当数据源 —— 失败就让用户重试，而不是悄悄换一条自动化痕迹更重的路。
   *
   * 失败一律返回 null（无会话 / 非 200 / 形状变了 / 解析不出条目）。
   */
  static async fetchPage(first: number, cursor: string): Promise<NativeFeedPage | null> {
    /*
     * **预热那一发还在飞 → 搭车，不再发第二发**（冷启动最常见的一次浪费，见 warmTask）。
     *
     * 只在"要第一页"时这么干；翻页（cursor 非空）各页本来就不同，不能合并。
     */
    if (cursor.length === 0 && NativeFeed.warmTask !== null) {
      const waited: number = Date.now();
      try {
        await NativeFeed.warmTask;
      } catch (error) {
        // 预热失败：往下自己发一发（下面才是真正的请求）。
      }
      const warm: NativeFeedPage | null = NativeFeed.takeWarm(NativeFeed.REUSE_WARM_MS);
      if (warm !== null) {
        hilog.info(DOMAIN, TAG, 'feed page reused warm result (waited %{public}dms)',
          Date.now() - waited);
        return warm;
      }
    }
    /*
     * **同一个游标的翻页：合并 + 短缓存**（见 inflightPages / memoPages）。
     *
     * 三件事一起做，全是"不发多余请求"：
     *   1. 8 秒内已经拿过这一页 → 直接给回，一发都不发；
     *   2. 正在飞 → 搭车等它，不再排队（两发会占满闸门，反而更慢）；
     *   3. 都没有 → 真发一发，结果存进两处。
     */
    if (cursor.length > 0) {
      const memo: NativeFeedPage | undefined = NativeFeed.memoPages.get(cursor);
      const at: number | undefined = NativeFeed.memoAtMs.get(cursor);
      if (memo !== undefined && at !== undefined
        && Date.now() - at <= NativeFeed.PAGE_MEMO_MS) {
        hilog.info(DOMAIN, TAG, 'feed page memo hit cursor=%{public}dms age=%{public}dms',
          cursor.length, Date.now() - at);
        return memo;
      }
      const joined: Promise<NativeFeedPage | null> | undefined = NativeFeed.inflightPages.get(cursor);
      if (joined !== undefined) {
        hilog.info(DOMAIN, TAG, 'feed page joined inflight cursor=%{public}d', cursor.length);
        return joined;
      }
    }
    /*
     * **"关注的人看完了"就短暂别问了**（见 markCaughtUp 的说明）。
     *
     * 真机现场：那个状态的时间线响应是 230~380KB、耗时 3~6 秒，但 `feed_items` 里只有
     * 一条 `end_of_feed_demarcator`（不是媒体），解析必然 0 条 —— 首页照样只能退回"推荐网格"。
     * 于是每一次进首页/下拉刷新都白花 4~10 秒，这正是用户说的"帖子刷新很慢"。
     * 记住这个状态（默认 10 分钟）之后，这段时间直接跳过这一发，刷新立刻出内容。
     */
    if (Date.now() - NativeFeed.caughtUpAt() < NativeFeed.caughtUpTtl()
      && NativeFeed.caughtUpAt() > 0) {
      hilog.info(DOMAIN, TAG, 'feed timeline skipped: caught up %{public}dms ago (not asked)',
        Date.now() - NativeFeed.caughtUpAt());
      return null;
    }
    const task: Promise<NativeFeedPage | null> = NativeFeed.viaMobile(cursor);
    const epoch: number = NativeFeed.epoch;
    if (cursor.length > 0) {
      NativeFeed.inflightPages.set(cursor, task);
    }
    let viaMobile: NativeFeedPage | null = null;
    try {
      viaMobile = await task;
    } finally {
      // 只清"自己那一张"：期间可能已经被别的调用换掉了。
      if (cursor.length > 0 && NativeFeed.inflightPages.get(cursor) === task) {
        NativeFeed.inflightPages.delete(cursor);
      }
    }
    if (viaMobile !== null) {
      // 换号之后回来的那一页属于上一个人：不许写进 memo（见 clearCache 的说明）。
      if (cursor.length > 0 && NativeFeed.epoch === epoch) {
        NativeFeed.rememberPage(cursor, viaMobile);
      }
      return viaMobile;
    }
    hilog.warn(DOMAIN, TAG, 'feed mobile failed (%{public}s)', MobileFeedTimeline.detail());
    return null;
  }

  /** 把一页记进短缓存（顺手控制条数，别让内存里的旧页越攒越多）。 */
  private static rememberPage(cursor: string, page: NativeFeedPage): void {
    if (NativeFeed.memoPages.size >= 8) {
      NativeFeed.memoPages.clear();
      NativeFeed.memoAtMs.clear();
    }
    NativeFeed.memoPages.set(cursor, page);
    NativeFeed.memoAtMs.set(cursor, Date.now());
  }

  /**
   * 记下"关注的人的最新帖子已看完"这个状态（时间线只回了 `end_of_feed_demarcator`）。
   *
   * 同时**落盘**（见 core/FeedCache.saveCaughtUp）：不落盘的话每次冷启动又要先白等
   * 4~10 秒才退回推荐源。
   */
  static markCaughtUp(ttlMs: number = 0): void {
    const now: number = Date.now();
    NativeFeed.caughtUpMs = now;
    NativeFeed.caughtUpLoaded = true;
    // `0` = 用默认 TTL（字段初始化不能引用后面声明的常量，所以默认值在运行时定）。
    NativeFeed.caughtUpTtlMs = ttlMs > 0 ? ttlMs : NativeFeed.CAUGHT_UP_TTL_MS;
    FeedCache.saveCaughtUp(now);
  }

  /** 这一轮"已看完"记多久（见 markCaughtUp 的参数；0 = 默认 30 分钟）。 */
  private static caughtUpTtlMs: number = 0;

  /** 实际生效的 TTL（毫秒）。 */
  private static caughtUpTtl(): number {
    return NativeFeed.caughtUpTtlMs > 0 ? NativeFeed.caughtUpTtlMs : NativeFeed.CAUGHT_UP_TTL_MS;
  }

  /** "关注流已看完"的时刻（0 = 没记过；首次调用时从落盘读回来）。 */
  private static caughtUpAt(): number {
    if (!NativeFeed.caughtUpLoaded) {
      NativeFeed.caughtUpLoaded = true;
      NativeFeed.caughtUpMs = FeedCache.loadCaughtUp();
    }
    return NativeFeed.caughtUpMs;
  }

  /**
   * 这个账号的**关注流现在就是"已看完"**（时间线只会回那条占位）。
   *
   * 谁用：`FeedViewModel.loadFirstPage` —— 这种状态下 DOM 兜底**一定什么都取不到**
   * （网页那条时间线也是空的），而 `bridge.runBridge` 要等隐藏网页就绪，冷启动实测要
   * **8.5 秒**才超时返回。以前首页首屏就被它白等这么久，缓存（探索流那一段）明明在手上
   * 却要等它超时才画出来 —— 用户报的"快拍列表 / 内容冷启动渲染很慢"根因就在这儿。
   */
  static timelineCaughtUp(): boolean {
    const at: number = NativeFeed.caughtUpAt();
    return at > 0 && Date.now() - at < NativeFeed.caughtUpTtl();
  }

  private static caughtUpMs: number = 0;
  private static caughtUpLoaded: boolean = false;
  /**
   * 这个状态记多久（30 分钟）。
   *
   * 为什么从 10 分钟提到 30：每次重问都是一发 3~6 秒、300KB 的请求，而回答**不会变**
   * （"关注的人的最新帖子看完了"是账号级状态）。10 分钟一过，用户下一次刷新就要白等它；
   * 而真正的内容（探索流那一段）每次刷新都会重取，所以放宽这个间隔不会让用户少看到新帖子。
   * 关注了新的人之后，最多 30 分钟（或换账号 / 重装）就会重新问一次。
   */
  private static readonly CAUGHT_UP_TTL_MS: number = 1800000;
  /**
   * 搭"预热那发"的车时，允许复用的新鲜度（毫秒）。
   *
   * 15 秒：冷启动那一刻预热刚回来，一定比这新；超过说明中间隔了很久（app 被挂起过），
   * 那就别用旧数据，自己重发。
   */
  private static readonly REUSE_WARM_MS: number = 15000;

  /**
   * 移动端那一发（拿不到给 null）。
   *
   * 解析用 `NativeTimelineParser.parseMobileFeed`（v1 媒体 → 同一套卡片 DTO），
   * 所以界面模型与模板那条完全一致，不需要第二份映射。
   */
  private static async viaMobile(cursor: string): Promise<NativeFeedPage | null> {
    const page: MobileFeedPage | null = await MobileFeedTimeline.page(cursor);
    if (page === null) {
      return null;
    }
    /*
     * **分享数取证**（见 core/ShareProbe）：把这一页响应的键名与"分享类键有没有"落盘。
     *
     * 必须在这里做（而不是解析之后）：要回答的问题正是"解析之前载荷里到底有没有 share_count"，
     * 解析完之后就只剩我们自己的模型了。只取第一页一次，开销是一次字符串扫描 + 一次 JSON 解析。
     */
    ShareProbe.noteBody('feed/timeline', page.body);
    /*
     * **解析丢进 TaskPool**（见 workers/FeedParseTask）：`feed/timeline/` 一页 300~400 KB，
     * 正好压在"骨架屏换成真内容"那一帧。
     * 画质档在**主线程**算好（`QualityProfile.now()`，只有它能读设置/网络状态），
     * 只把三个纯值递进线程池 —— 解析链因此不再碰 AppStorage。
     */
    let parsed: NativeTimeline | null = null;
    try {
      const profile: QualityProfile = QualityProfile.now();
      const started: number = Date.now();
      parsed = await taskpool.execute(parseFeedTask, page.body, profile.imageTarget,
        profile.videoTarget, profile.gridMode) as NativeTimeline | null;
      hilog.info(DOMAIN, TAG, 'feed parsed in taskpool bytes=%{public}d ms=%{public}d',
        page.body.length, Date.now() - started);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'feed taskpool failed: %{public}s → main thread',
        (error as Error).message);
      parsed = NativeTimelineParser.parseMobileFeed(page.body);
    }
    if (parsed === null) {
      /*
       * **明确是"关注流已看完"**（这一页只有 `end_of_feed_demarcator` 占位，没有媒体行）时
       * 记一笔，之后一段时间不再白问（见 fetchPage 的跳过逻辑）。
       * 网络错误/形状不明（rows=0 但没有占位）不记 —— 那种要照常重试。
       */
      if (NativeTimelineParser.isCaughtUp(page.body)) {
        NativeFeed.markCaughtUp();
        hilog.info(DOMAIN, TAG, 'feed timeline says caught up → skip it for a while');
        return null;
      }
      /*
       * **解析不出东西、但服务端明明给了完整一页**（真机：`bytes=680787`、键全在、0 条媒体）。
       *
       * 这种形状与"关注流薄到没有帖"在实践中是同一件事，但它也**可能是解析层被新形状打穿**。
       * 所以记一个**短 TTL（10 分钟）**：真的坏了，10 分钟后自动重试；真没帖，10 分钟省下
       * 两三发 2~6 秒、几百 KB 的空请求。日志带上字节数，便于事后判断是哪一种。
       */
      if (cursor.length === 0 && page.body.length > 100000) {
        NativeFeed.markCaughtUp(600000);
        hilog.warn(DOMAIN, TAG,
          'feed first page unparsable but big (bytes=%{public}d) → skip timeline for 10min',
          page.body.length);
      }
      return null;
    }
    hilog.info(DOMAIN, TAG, 'feed via mobile n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      parsed.items.length, `${parsed.hasNext}`, parsed.nextCursor.length, page.ms);
    /*
     * **首屏 200、体很大、但一条媒体都没有 → 记成"关注流已看完"**（真机实测过的形态：
     * `timeline ok bytes=680787 keys=[feed_items,items,…]`，解析出 0 条，首页只能靠探索流）。
     *
     * 两种判据任一成立就记：
     *   · `isCaughtUp`：整页就是那个 `end_of_feed_demarcator` 占位（最明确的信号）；
     *   · **体够大但 0 条媒体**：说明服务端确实给了内容、只是没有关注帖（占位+推荐混合的形状），
     *     这种也必须记，否则每次进首页/下拉刷新都要再白等 2~6 秒打一发注定 0 条的请求。
     * 体太小（出错/形状变了）**不记** —— 那种要照常重试。
     */
    if (parsed.items.length === 0 && cursor.length === 0) {
      const placeholder: boolean = NativeTimelineParser.isCaughtUp(page.body);
      const big: boolean = page.body.length > 100000;
      if (placeholder || big) {
        NativeFeed.markCaughtUp();
        hilog.info(DOMAIN, TAG,
          'feed first page 0 media (placeholder=%{public}s bytes=%{public}d) → caught up for %{public}dmin',
          `${placeholder}`, page.body.length, Math.round(NativeFeed.CAUGHT_UP_TTL_MS / 60000));
      }
    }
    return new NativeFeedPage(parsed.items, parsed.nextCursor, parsed.hasNext, page.ms);
  }

  /** 分组实验只跑一次（见 groupTest）。 */
  private static groupTestDone: boolean = false;

  /**
   * **一次性实验**：时间线"看完关注的人"之后，内容在哪个分组里。
   *
   * 结论（真机 2026-10-21，四发全部 n=0）：`group_id=feed_recs` / `reason=feed_recs` /
   * `feed_pill_text=feed_recs` / `group_id=past_posts` **都给不出媒体行** ——
   * 这个账号在移动端时间线上就是"关注流已看完、推荐组不给"的状态。
   * 所以这里不再尝试换分组，改成"记住这个状态、短时间内直接走推荐网格"（见 markCaughtUp）。
   * 代码留着：以后换账号/换版本要复验时把 `groupTestDone` 置 false 就能再跑一遍。
   */
  private static async groupTest(): Promise<void> {
    const variants: Array<Array<string>> = [
      ['recs', 'group_id=feed_recs'],
      ['reason+recs', 'reason=feed_recs&group_id=feed_recs'],
      ['pill', 'feed_pill_text=feed_recs'],
      ['past', 'group_id=past_posts']
    ];
    for (let index: number = 0; index < variants.length; index++) {
      const label: string = variants[index][0];
      const extra: string = variants[index][1];
      const page: MobileFeedPage | null = await MobileFeedTimeline.page('', extra);
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'groupTest %{public}s -> miss', label);
        continue;
      }
      const parsed: NativeTimeline | null = NativeTimelineParser.parseMobileFeed(page.body);
      hilog.info(DOMAIN, TAG, 'groupTest %{public}s -> n=%{public}d bytes=%{public}d',
        label, parsed === null ? 0 : parsed.items.length, page.body.length);
    }
    hilog.info(DOMAIN, TAG, 'groupTest done');
  }

}
