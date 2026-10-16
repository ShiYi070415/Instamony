/*
 * **接口被限流时的退避**（会话级，只活在内存里）。
 *
 * ## 为什么需要它
 * IG 对私有接口有节流，真机实测撞上过（clips 那条查询，响应体里是
 * `{"data":[],"errors":[{"message":"Rate limit exceeded","severity":"CRITICAL","code":1675004}]}`）：
 *   - 页面侧表现是"视频标签一片空白"（ReelsViewModel 报 `no-conn`），
 *     搜索页的**推荐瀑布流**同样空（它用的也是 clips 那条查询）；
 *   - 而我们这边原来会**继续猛打**：reels 一条要重试 5 次（每次隔 3 秒），
 *     再加启动预热、搜索页预热、`fetchPage` 内部"原样重发"…… 越打越久。
 *
 * 所以这里做两件事：
 *   1. **认出来**：响应体里有 `Rate limit exceeded` / `code 1675004` 就是被限流
 *      （见 looksLimited）；
 *   2. **记一段冷却期**：这段时间内同一个"家族"的请求直接不发（`blocked`），
 *      界面照实说"被限流了、稍后再试"，并尽量拿**上次缓存的内容**顶上
 *      （`ReelsCache` / `SearchCache`）。
 *
 * ## 为什么按"家族"而不是按操作名
 * 被限流的是**账号在某类重查询上**的额度，而不是某一个 doc_id：clips 那条查询被限时，
 * 首页视频、搜索推荐（同一个 op）一起挂；而信息流、个人主页、评论这些照常。
 * 所以这几条共用一把锁（`CLIPS`）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ApiThrottle';

/** 撞上限流之后，多久之内不再发这个家族的请求（毫秒）。 */
const BACKOFF_MS: number = 12 * 60 * 1000;

/**
 * **两次请求之间至少隔多久**（毫秒）。见 `ApiThrottle.acquire` 的说明。
 *
 * 取 900ms 的依据：本项目自己的调用形态就是"一发接一发"——
 *   · 快拍预缓存一上来 5 位用户（每位 1~2 发），点开再续下一位；
 *   · 启动自检一次 9 发，实测**一秒内全打出去**（真机日志 16:00:24 那一段）；
 *   · 会话页每 4 秒轮询一发。
 * 这些都不是"用户手速"，而是我们代码自己排出来的连发。IG 的节流看的正是**单位时间内的
 * 请求密度**，所以这里给一个下限；代价是预取变慢（5 页 ≈ 4.5 秒铺满），
 * 而用户真正点开的那一发走**交互优先级**，会插到队头（见 PRIORITY_*）。
 */
const PACE_MIN_MS: number = 900;
/** 间隔的随机抖动上限（毫秒）：**固定间隔本身就是一种指纹**，加抖动更像人。 */
const PACE_JITTER_MS: number = 400;
/**
 * **交互请求**（用户此刻点开的）用的最小间隔（毫秒）。
 *
 * 为什么给它一个明显更小的值：900ms 那道闸是防"我们代码自己排出来的连发"（预取/自检），
 * 而用户点开某一发快拍时，真实 App 就是"立刻发" —— 让这一发也等满 900ms 只是白白让界面慢。
 * 250ms 仍然保证它不会和上一发挤在同一个瞬间（真正的风险是密集连发，不是单发）。
 */
const PACE_MIN_INTERACTIVE_MS: number = 250;
/**
 * 一次"持闸"最长多久（毫秒）——**防呆用**。
 *
 * 拿到闸门的一方发完请求必须 `release()`。万一路径上抛了异常、或者忘了 release，
 * 整条链就会永久卡死（所有后续请求都不再发出去，而且现象是"App 卡住不动"、极难定位）。
 * 所以超时后强制放闸并打一行 warn：宁可多发一发，也不要整条链静默死掉。
 */
const PACE_HOLD_MAX_MS: number = 30000;

/** 交互优先级：用户**此刻**点的东西（点开快拍/会话），插到队头。 */
const PRIORITY_INTERACTIVE: number = 0;
/** 预热优先级：界面马上要用、但不是用户此刻点的（首屏、预缓存）。 */
const PRIORITY_WARM: number = 1;
/** 空闲优先级：诊断、自检、后台补缓存 —— 排最后，别抢用户的请求。 */
const PRIORITY_IDLE: number = 2;

/** 排队等闸门的一个请求。 */
class PaceWaiter {
  readonly priority: number;
  readonly resolve: () => void;

  constructor(priority: number, resolve: () => void) {
    this.priority = priority;
    this.resolve = resolve;
  }
}

export class ApiThrottle {
  /** 视频类重查询（首页 reels + 搜索推荐用的都是 `PolarisClipsTabRootPaginationQuery`）。 */
  static readonly CLIPS: string = 'clips';
  /** 单条媒体的信息查询（`/api/v1/media/{id}/info/`，补视频地址用，见 core/NativeMediaInfo）。 */
  static readonly MEDIA_INFO: string = 'mediaInfo';
  /** 单条媒体的评论查询（`/api/v1/media/{id}/comments/`，见 core/NativeComments）。 */
  static readonly COMMENTS: string = 'comments';
  /** 收藏 / 取消收藏（`/api/v1/media/{id}/save|unsave/`，见 core/NativeSave）。 */
  static readonly SAVE: string = 'save';
  /** 私信（`/api/v1/direct_v2/…` 那条路的读与发，见 core/NativeDirect）。 */
  static readonly DIRECT: string = 'direct';
  /**
   * 快拍（`/api/v1/feed/reels_media/`、`/api/v1/feed/user/{id}/story/`，见 core/NativeStories）。
   *
   * 为什么单列一族：这两条是**按用户**拉的，托盘预缓存一上来就是 5 位用户（每位最多 4 个候选），
   * 用户再一位位点开、接续下一位 —— 请求量天然比别的接口大一个量级，也最容易撞上 IG 的节流。
   * 撞上之后的界面表现正是用户报的那一幕："点开快拍 → 这条快拍没取到 → 播放页自己收起"。
   */
  static readonly STORIES: string = 'stories';
  /**
   * **移动端私有 API 一族**（`i.instagram.com/api/v1/…`，见 core/mobileapi）。
   *
   * 单独一族而不是并进上面几条：它的身份/主机/网关都不同（App 那套），IG 的额度也未必与
   * 网页那条共享。诊断日志里分得开，才知道"到底是哪条路被限了"。
   * 快拍、私信两条各自**同时**用自己那族（`STORIES` / `DIRECT`）—— 它们语义一样、额度很可能同源，
   * 所以被限流时的退避要一起生效。
   */
  static readonly MOBILE: string = 'mobile';

  /** 家族 → 解禁时刻（毫秒时间戳）。 */
  private static until: Map<string, number> = new Map<string, number>();

  // ---------------------------------------------------------------- 主动限速（闸门）

  /** 排队等闸门的请求（优先级小的先走，同级 FIFO）。 */
  private static waiters: Array<PaceWaiter> = [];
  /** 现在有没有人持闸（= 有一发在路上，或正在等间隔）。 */
  private static holding: boolean = false;
  /** 上一次请求**结束**的时刻（间隔从它开始算）。 */
  private static lastDoneAt: number = 0;
  /** 拿闸后的防呆定时器 id（-1 = 没在计时）。 */
  private static holdTimer: number = -1;
  /** 这辈子因为间隔而等过几次（诊断用）。 */
  private static pacedCount: number = 0;

  /**
   * 申请一个"发请求的名额"：**同一时刻只允许一发在路上**，且两发之间至少隔 `PACE_MIN_MS`
   * （含抖动）。拿到之后**必须**在请求结束时调 `release()`（用 try/finally 包住）。
   *
   * @param priority 见 `ApiThrottle.interactive()/warm()/idle()`；数小者优先。
   */
  static acquire(priority: number = PRIORITY_WARM): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      ApiThrottle.waiters.push(new PaceWaiter(priority, resolve));
      ApiThrottle.pump();
    });
  }

  /** 放闸（请求结束了，无论成败都要调；见 acquire 的说明）。 */
  static release(): void {
    if (ApiThrottle.holdTimer >= 0) {
      clearTimeout(ApiThrottle.holdTimer);
      ApiThrottle.holdTimer = -1;
    }
    ApiThrottle.holding = false;
    ApiThrottle.lastDoneAt = Date.now();
    ApiThrottle.pump();
  }

  /** 优先级：用户此刻点的东西。 */
  static interactive(): number {
    return PRIORITY_INTERACTIVE;
  }

  /** 优先级：界面马上要用（首屏、预缓存）。 */
  static warm(): number {
    return PRIORITY_WARM;
  }

  /** 优先级：诊断 / 自检 / 后台补数据。 */
  static idle(): number {
    return PRIORITY_IDLE;
  }

  /** 还在排队等闸门的请求数（诊断用）。 */
  static waiting(): number {
    return ApiThrottle.waiters.length;
  }

  /** 限速状态一行摘要（诊断面板/日志用）。 */
  static paceDescribe(): string {
    return `pace gap=${PACE_MIN_MS}+${PACE_JITTER_MS}ms waiting=${ApiThrottle.waiters.length}`
      + ` holding=${ApiThrottle.holding ? 'y' : 'n'} paced=${ApiThrottle.pacedCount}`;
  }

  /** 放一发（内部）：挑优先级最高的那个，按间隔延迟后唤醒它，并上防呆。 */
  private static pump(): void {
    if (ApiThrottle.holding || ApiThrottle.waiters.length === 0) {
      return;
    }
    let best: number = 0;
    for (let index: number = 1; index < ApiThrottle.waiters.length; index++) {
      if (ApiThrottle.waiters[index].priority < ApiThrottle.waiters[best].priority) {
        best = index;
      }
    }
    const next: PaceWaiter = ApiThrottle.waiters[best];
    ApiThrottle.waiters.splice(best, 1);
    ApiThrottle.holding = true;
    // 防呆：万一调用方没有 release，30 秒后强制放闸（见 PACE_HOLD_MAX_MS）。
    ApiThrottle.holdTimer = setTimeout((): void => {
      hilog.warn(DOMAIN, TAG, 'pace hold timeout %{public}dms — force release',
        PACE_HOLD_MAX_MS);
      ApiThrottle.holdTimer = -1;
      ApiThrottle.release();
    }, PACE_HOLD_MAX_MS);
    const wait: number = ApiThrottle.gapMs(next.priority);
    if (wait <= 0) {
      next.resolve();
      return;
    }
    ApiThrottle.pacedCount = ApiThrottle.pacedCount + 1;
    setTimeout((): void => {
      next.resolve();
    }, wait);
  }

  /** 距离"可以发下一发"还差多少毫秒（已经够了给 0）；交互请求用更短的那道闸。 */
  private static gapMs(priority: number): number {
    const interactive: boolean = priority <= PRIORITY_INTERACTIVE;
    const min: number = interactive ? PACE_MIN_INTERACTIVE_MS : PACE_MIN_MS;
    const jitter: number = interactive ? 0 : Math.floor(Math.random() * (PACE_JITTER_MS + 1));
    const since: number = ApiThrottle.lastDoneAt === 0 ? min : Date.now() - ApiThrottle.lastDoneAt;
    const left: number = min + jitter - since;
    return left > 0 ? left : 0;
  }

  /**
   * 这段响应/诊断里是不是"被限流"了。
   *
   * 判据要**稳**，因为误判的代价是 12 分钟冷却（reels / 搜索推荐整条路一起哑掉）：
   *   · `1675004` 是 IG 那条错误的稳定 code（文案被本地化/改写时还能认出来）；
   *   · `rate_limit_error` 是 `error_type` 的取值；
   *   · 光看 `"rate limit"` 字面**不够** —— 整页 HTML、无关文案里都可能出现（真机日志里
   *     reels 预热就是这么被打上冷却的：响应其实是一份别的东西）。所以只有它出现在 IG 的
   *     错误结构里（`"message"` / `"error_type"` / `"errors"` / `"severity"` 附近）才算。
   */
  static looksLimited(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    if (text.indexOf('1675004') >= 0) {
      return true;
    }
    const lower: string = text.toLowerCase();
    if (lower.indexOf('rate_limit_error') >= 0) {
      return true;
    }
    const hit: number = lower.indexOf('rate limit');
    if (hit < 0) {
      return false;
    }
    const from: number = hit > 80 ? hit - 80 : 0;
    const around: string = lower.substring(from, hit + 60);
    return around.indexOf('"message"') >= 0 || around.indexOf('"error_type"') >= 0
      || around.indexOf('"errors"') >= 0 || around.indexOf('"severity"') >= 0;
  }

  /** 记一次限流：这个家族在 BACKOFF_MS 之内不再发请求。 */
  static note(family: string, ms: number = BACKOFF_MS): void {
    if (family.length === 0) {
      return;
    }
    ApiThrottle.until.set(family, Date.now() + ms);
  }

  /** 现在这个家族还在冷却里吗。 */
  static blocked(family: string): boolean {
    const at: number | undefined = ApiThrottle.until.get(family);
    if (at === undefined) {
      return false;
    }
    if (Date.now() >= at) {
      ApiThrottle.until.delete(family);
      return false;
    }
    return true;
  }

  /** 还剩多少毫秒解禁（不在冷却里给 0）。 */
  static remainingMs(family: string): number {
    const at: number | undefined = ApiThrottle.until.get(family);
    if (at === undefined) {
      return 0;
    }
    const left: number = at - Date.now();
    return left > 0 ? left : 0;
  }

  /** 还剩多少分钟（界面上那句提示用；不足一分钟按 1 算）。 */
  static remainingMinutes(family: string): number {
    const left: number = ApiThrottle.remainingMs(family);
    if (left <= 0) {
      return 0;
    }
    const minutes: number = Math.ceil(left / 60000);
    return minutes > 0 ? minutes : 1;
  }

  /** 手动解禁（下拉刷新这种用户主动的动作可以试一次）。 */
  static clear(family: string = ''): void {
    if (family.length === 0) {
      ApiThrottle.until.clear();
      return;
    }
    ApiThrottle.until.delete(family);
  }
}
