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
export const BACKOFF_MS: number = 12 * 60 * 1000;
/**
 * 撞上 **`feedback_required`** 之后要停多久（毫秒，45 分钟）。
 *
 * 为什么比普通限流长得多：`429` / `rate_limit_error` 多是"这一条打太密了"，
 * 而 `feedback_required`（"We limit how often you can do certain things…"）是 IG 对**整类行为**
 * 的判定 —— 12 分钟就再去试只会把窗口重新拉长。
 */
export const FEEDBACK_BACKOFF_MS: number = 45 * 60 * 1000;

/**
 * **两次请求之间至少隔多久**（毫秒）。见 `ApiThrottle.acquire` 的说明。
 *
 * 取 1500ms 的依据（2026-10-19 加强）：900ms 那版仍然是"同一台机器一发接一发"的密度，
 * 而 IG 的节流看的就是单位时间请求密度。放到 1.5 秒后：
 *   · 首屏那几发仍然来得急（它们是 `interactive` / 首屏 `warm`，见下面的小闸）；
 *   · 预热和预取被自然拉开，冷启动 40 秒内的请求数从十几发压到个位数。
 * 代价是"要连发 5 页"时慢了几秒 —— 这些本来就不是用户此刻要看的东西。
 */
const PACE_MIN_MS: number = 1500;
/**
 * 间隔的随机抖动量（毫秒）：实际间隔 = `PACE_MIN_MS` + `[0, JITTER)`。
 *
 * **固定间隔本身就是指纹**（审计文档里的实测：每次冷启动都停在 900±400ms 这个带子上）。
 * 抖动幅值取和下限同量级（1.5~3.5 秒），间隔分布才不像机器。
 */
const PACE_JITTER_MS: number = 2000;
/**
 * **交互请求**（用户此刻点开的）用的最小间隔（毫秒）。
 *
 * 为什么给它一个明显更小的值：1.5 秒那道闸是防"我们代码自己排出来的连发"（预取/预热），
 * 而用户点开某一发快拍时，真实 App 就是"立刻发" —— 让这一发也等满 1.5 秒只是白白让界面慢。
 * 600ms 仍然保证它不会和上一发挤在同一个瞬间（真正的风险是密集连发，不是单发）。
 */
const PACE_MIN_INTERACTIVE_MS: number = 600;
/** 交互请求的抖动量（毫秒）：0~600，别让"点开就发"也变成固定节奏。 */
const PACE_JITTER_INTERACTIVE_MS: number = 600;
/**
 * **同一时刻最多几发在路上**（原来写死 1）。
 *
 * 为什么从 1 放到 2：真机上首页冷启动慢的根因不是"请求太慢"，而是**一条一条排队**——
 * 托盘一发 3~6 秒、探索流一发 4~9 秒、时间线再一发，串起来就是十几秒（日志里能直接对上）。
 * 而这些时间绝大部分是**在等服务端回包**，我们这边空转。
 *
 * 放到 2 之后：
 *   · **开始的密度一点没变**（见 `gapMs`：间隔仍按"上一发开始"算 1.5~3.5 秒），
 *     IG 看到的是同样的请求到达节奏 —— 限流看的是密度，不是并发数；
 *   · 慢接口那 4~9 秒的空等被第二发利用起来，两段等待重叠，冷启动直接省掉一段。
 *
 * 为什么不再往上放：并发越高，"同一瞬间打进去两发以上"的概率越接近真实用户的上限，
 * 而 2 已经是"人能同时干两件事"的量级；收益也递减（第三发之后排队里已经没有必争的了）。
 */
const MAX_IN_FLIGHT: number = 2;
/**
 * 一次"持闸"最长多久（毫秒）——**防呆用**。
 *
 * 拿到闸门的一方发完请求必须 `release()`。万一路径上抛了异常、或者忘了 release，
 * 整条链就会永久卡死（所有后续请求都不再发出去，而且现象是"App 卡住不动"、极难定位）。
 * 所以超时后强制放闸并打一行 warn：宁可多发一发，也不要整条链静默死掉。
 */
const PACE_HOLD_MAX_MS: number = 30000;

/** 紧急优先级：用户**当场在等**的那一发（点开私信会话），排队最前、**不加人为间隔**。 */
const PRIORITY_URGENT: number = -1;
/** 交互优先级：用户**此刻**点的东西（点开快拍/会话），插到队头。 */
const PRIORITY_INTERACTIVE: number = 0;
/** 预热优先级：界面马上要用、但不是用户此刻点的（首屏、预缓存）。 */
const PRIORITY_WARM: number = 1;
/** 空闲优先级：诊断、自检、后台补缓存 —— 排最后，别抢用户的请求。 */
const PRIORITY_IDLE: number = 2;
/**
 * 排队**防饿死**的时长（毫秒，见 effective）。
 *
 * 等超过它就把这一发提到 `warm` 档（**绝不超过交互档**）：低优先级（`idle` 的预取/封面回填）
 * 不会因为队列里一直有 warm 请求而永远轮不到。
 */
const PACE_STARVE_MS: number = 15000;
/**
 * 写操作之间的人速间隔（毫秒）：3 秒 + 0~3 秒随机。
 *
 * 原来是 0~5 秒（3~8 秒）。用户反复报"发送有延迟"，而连发两三条时的等待就是它累加出来的：
 * 3~8 秒 → 3~6 秒后，两条之间的最坏等待从 16 秒降到 12 秒，密度仍然远低于"脚本"。
 */
const WRITE_GAP_MIN_MS: number = 3000;
const WRITE_GAP_JITTER_MS: number = 3000;

/** 排队等闸门的一个请求。 */
class PaceWaiter {
  readonly priority: number;
  readonly resolve: () => void;
  /**
   * 它是什么时候开始排队的（见 pump 里的**老化**：等太久要提权，否则低优先级会饿死）。
   */
  readonly atMs: number;

  constructor(priority: number, resolve: () => void) {
    this.priority = priority;
    this.resolve = resolve;
    this.atMs = Date.now();
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

  /** 整账号熔断的截止时刻（0 = 没熔断，见 suspendAll）。 */
  private static suspendUntil: number = 0;
  /** 熔断原因（日志/界面用）。 */
  private static suspendReason: string = '';
  /** 上一次**写操作**放行的时刻（人速间隔从它算，见 writeSlot）。 */
  private static lastWriteAt: number = 0;
  /** 因为人速间隔等过几次（诊断用）。 */
  private static writeWaits: number = 0;

  // ---------------------------------------------------------------- 主动限速（闸门）

  /** 排队等闸门的请求（优先级小的先走，同级 FIFO）。 */
  private static waiters: Array<PaceWaiter> = [];
  /** 现在有多少发在路上（拿到名额还没 release 的）。 */
  private static inFlight: number = 0;
  /** 在路上的那几发的防呆定时器 id（每个名额一个，见 PACE_HOLD_MAX_MS）。 */
  private static holds: Array<number> = [];
  /** 上一次请求**开始**的时刻（间隔从它开始算，见 gapMs）。 */
  private static lastStartAt: number = 0;
  /** 这辈子因为间隔而等过几次（诊断用）。 */
  private static pacedCount: number = 0;

  /**
   * 申请一个"发请求的名额"：**最多 `MAX_IN_FLIGHT` 发同时在路上**，且**两次开始的间隔**
   * 至少 `PACE_MIN_MS`（含抖动）。拿到之后**必须**在请求结束时调 `release()`
   * （用 try/finally 包住）。
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
    ApiThrottle.dropHold(-1);
    ApiThrottle.freeSlot();
  }

  /** 优先级：**用户当场在等**的那一发（点开私信会话）：队头 + 不加人为间隔。 */
  static urgent(): number {
    return PRIORITY_URGENT;
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
      + ` inflight=${ApiThrottle.inFlight}/${MAX_IN_FLIGHT} paced=${ApiThrottle.pacedCount}`
      + ` writes=${ApiThrottle.writeWaits}`
      + (ApiThrottle.suspended()
        ? ` SUSPENDED ${ApiThrottle.suspendMinutesLeft()}min(${ApiThrottle.suspendReason})` : '');
  }

  /**
   * 放名额（内部）：有空位就按优先级往外发，直到发满 `MAX_IN_FLIGHT`。
   *
   * 用 `while` 而不是 `if`：上一个版本一次只放一发，所以 `if` 够用；现在有空位时
   * 可能一次就能放两发出去（这也是整个改动的目的 —— 让第二发不用等第一发的回包）。
   */
  private static pump(): void {
    while (ApiThrottle.waiters.length > 0) {
      let best: number = 0;
      for (let index: number = 1; index < ApiThrottle.waiters.length; index++) {
        if (ApiThrottle.effective(ApiThrottle.waiters[index])
          < ApiThrottle.effective(ApiThrottle.waiters[best])) {
          best = index;
        }
      }
      const next: PaceWaiter = ApiThrottle.waiters[best];
      /*
       * **urgent 允许比并发上限多一个名额**（需求："加快进入会话获取消息的速度"）。
       *
       * 真机实测：点开私信会话的那一发，前面常常堵着两发后台大请求（快拍的
       * `feed/user/{id}/story/`、探索流），轻则等 1.8 秒、重则 2.9 秒。urgent 是"人当场点了一下"
       * 的直接后果，让它插一个临时名额出去：**单位时间内的请求到达数不变**（它只是提前，
       * 不会多出请求），并发上限也只是这一刻从 2 变成 3。
       * 普通请求仍然严格受 `MAX_IN_FLIGHT` 限制。
       */
      const urgent: boolean = next.priority <= PRIORITY_URGENT;
      const limit: number = urgent ? MAX_IN_FLIGHT + 1 : MAX_IN_FLIGHT;
      if (ApiThrottle.inFlight >= limit) {
        return;
      }
      ApiThrottle.waiters.splice(best, 1);
      ApiThrottle.startOne(next);
    }
  }

  /**
   * 排队中的请求的**有效优先级**（越小越先发）。
   *
   * ## 为什么要有"老化"
   * `pump()` 原来是**严格按优先级**挑的：只要队列里一直有 warm 请求，`idle`（预取、封面回填、
   * 预加载下一页……）就永远轮不到 —— 真机上表现是"预取一直没跑，滑到底才开始抓"。
   *
   * ## 为什么只提一档、而且封顶在 warm
   * 真机实测的队列长这样：`waiting=5~6 inflight=2/2`，排在后面的请求等 7~10 秒是常态。
   * 如果让它按等待时间一路提权到交互档，就会出现**用户刚点的一下排在十几秒前的预取后面** ——
   * 那是拿"交互快"去换"预取不被饿死"，不划算。所以：等够 `PACE_STARVE_MS` 只把它提到
   * `warm` 那一档（保底能排上），`interactive` / `urgent`（用户当场在等的）永远在它前面。
   */
  private static effective(one: PaceWaiter): number {
    const waited: number = Date.now() - one.atMs;
    if (waited < PACE_STARVE_MS) {
      return one.priority;
    }
    return Math.min(one.priority, PRIORITY_WARM);
  }

  /**
   * 真发一个名额出去（内部）。
   *
   * 名额**当场**就算"在路上"（而不是等间隔到了才算）：否则并发那一路会被 `pump` 的 while
   * 在同一次循环里重复发出去，实际在路上的会比 `MAX_IN_FLIGHT` 多。
   */
  private static startOne(next: PaceWaiter): void {
    ApiThrottle.inFlight = ApiThrottle.inFlight + 1;
    /*
     * 防呆：万一调用方没有 release，30 秒后强制放闸（见 PACE_HOLD_MAX_MS）。
     * 每个名额一个定时器，`holds` 按发放顺序排队 —— 谁先结束就摘掉最早那个，
     * 数量始终和 `inFlight` 对得上（极端乱序下无非是"少等一会儿"，不会漏放）。
     */
    let timer: number = -1;
    timer = setTimeout((): void => {
      hilog.warn(DOMAIN, TAG, 'pace hold timeout %{public}dms — force release',
        PACE_HOLD_MAX_MS);
      ApiThrottle.dropHold(timer);
      ApiThrottle.freeSlot();
    }, PACE_HOLD_MAX_MS);
    ApiThrottle.holds.push(timer);
    const wait: number = ApiThrottle.gapMs(next.priority);
    /*
     * 记下它**将要**发出去的时刻（不是现在）：并发那一发的间隔要从这一刻起算，
     * 否则两个名额会被算成"现在发"，间隔形同失效。
     */
    ApiThrottle.lastStartAt = Date.now() + wait;
    if (wait <= 0) {
      next.resolve();
      return;
    }
    ApiThrottle.pacedCount = ApiThrottle.pacedCount + 1;
    setTimeout((): void => {
      next.resolve();
    }, wait);
  }

  /** 还一个名额（内部）：名额减一，然后看还有没有人在排队。 */
  private static freeSlot(): void {
    if (ApiThrottle.inFlight > 0) {
      ApiThrottle.inFlight = ApiThrottle.inFlight - 1;
    }
    ApiThrottle.pump();
  }

  /** 摘掉一个防呆定时器（`timer < 0` = 摘最早那个，见 release/freeSlot）。 */
  private static dropHold(timer: number): void {
    if (ApiThrottle.holds.length === 0) {
      return;
    }
    if (timer < 0) {
      const earliest: number | undefined = ApiThrottle.holds.shift();
      if (earliest !== undefined) {
        clearTimeout(earliest);
      }
      return;
    }
    const at: number = ApiThrottle.holds.indexOf(timer);
    if (at >= 0) {
      ApiThrottle.holds.splice(at, 1);
    }
    clearTimeout(timer);
  }

  /**
   * 距离"可以发下一发"还差多少毫秒（已经够了给 0）；交互请求用更短的那道闸。
   *
   * 间隔按 **上一发开始** 到这一发开始算（start-to-start），不是"上一发结束之后"。
   * 为什么改：并发 2 之后如果还按结束算，慢接口那 4~9 秒会让第二个名额也一起干等，
   * 等于白开一个并发；按开始算则"单位时间内的请求到达数"完全不变（这才是 IG 看的那个量），
   * 只是把等回包的时间叠起来了。
   */
  private static gapMs(priority: number): number {
    if (ApiThrottle.lastStartAt === 0) {
      // 这一次启动以来的第一发：直接放，不给自己加戏。
      return 0;
    }
    /*
     * **urgent（用户当场在等的那一发）不排队、也不加间隔**。
     *
     * 什么时候用它：点开某条私信会话（见 DirectThreadViewModel.load）。这一发是"人点了一下"
     * 的直接后果，真机实测：交互优先级仍然要等 1.7 秒（前面两发后台任务占着名额 + 0.6~1.2 秒间隔），
     * 而人类在 IM 里点开会话的期待是"立刻"。
     *
     * 代价与边界说清楚：它**仍然受 `MAX_IN_FLIGHT` 限制**（最多等一个名额空出来），
     * 所以不会把并发数顶上去；只是不再人为地空等那 0.6~1.2 秒。调用点只有一个（开会话），
     * 且那一路有 `busy` 防重入 —— 连点不会变成连发。
     */
    if (priority <= PRIORITY_URGENT) {
      return 0;
    }
    const interactive: boolean = priority <= PRIORITY_INTERACTIVE;
    const min: number = interactive ? PACE_MIN_INTERACTIVE_MS : PACE_MIN_MS;
    const jitterRange: number = interactive ? PACE_JITTER_INTERACTIVE_MS : PACE_JITTER_MS;
    const jitter: number = Math.floor(Math.random() * (jitterRange + 1));
    const since: number = Date.now() - ApiThrottle.lastStartAt;
    const left: number = min + jitter - since;
    return left > 0 ? left : 0;
  }

  /**
   * **写操作的人速间隔**（点赞 / 关注 / 发消息 / 评论…）。
   *
   * 读可以靠缓存摊薄，写不能：每一次写都是一次"这个账号在动"的信号，连着来最像脚本。
   * 这里给一个 3~8 秒的随机间隔，且**全局串行**（同一时刻只允许一个写操作在等人速窗口）。
   */
  static async writeSlot(): Promise<void> {
    const now: number = Date.now();
    const wait: number = ApiThrottle.lastWriteAt === 0
      ? 0 : ApiThrottle.lastWriteAt + WRITE_GAP_MIN_MS
        + Math.floor(Math.random() * (WRITE_GAP_JITTER_MS + 1)) - now;
    ApiThrottle.lastWriteAt = Math.max(now, now + (wait > 0 ? wait : 0));
    if (wait <= 0) {
      return;
    }
    ApiThrottle.writeWaits = ApiThrottle.writeWaits + 1;
    await new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, wait);
    });
  }

  /**
   * **整账号熔断**：出现 `429` / `feedback_required` / `challenge_required` 时调。
   *
   * 为什么不是只停"出事那个家族"：IG 的判定是**账号级**的。读到限流还继续打别的端点，
   * 只会把窗口越拉越长（审计文档里实测过）。熔断期间 `blocked()` 对所有家族都返回 true，
   * 已有的"每个调用点先查 blocked"就自动把可选流量全停了。
   *
   * @param minutes 停多久（默认 45 分钟）
   * @param reason  原因（日志/界面提示用）
   */
  static suspendAll(minutes: number = 45, reason: string = '-'): void {
    const until: number = Date.now() + minutes * 60000;
    if (until > ApiThrottle.suspendUntil) {
      ApiThrottle.suspendUntil = until;
      ApiThrottle.suspendReason = reason;
      hilog.warn(DOMAIN, TAG, 'suspend all traffic %{public}dmin reason=%{public}s',
        minutes, reason);
    }
  }

  /** 现在是不是处于整账号熔断中。 */
  static suspended(): boolean {
    if (ApiThrottle.suspendUntil <= 0) {
      return false;
    }
    if (Date.now() >= ApiThrottle.suspendUntil) {
      ApiThrottle.suspendUntil = 0;
      ApiThrottle.suspendReason = '';
      return false;
    }
    return true;
  }

  /** 熔断还剩几分钟（不在熔断里给 0）；界面/日志用。 */
  static suspendMinutesLeft(): number {
    if (!ApiThrottle.suspended()) {
      return 0;
    }
    const left: number = ApiThrottle.suspendUntil - Date.now();
    return left > 0 ? Math.ceil(left / 60000) : 0;
  }

  /** 熔断原因（没在熔断里给空串）。 */
  static suspendWhy(): string {
    return ApiThrottle.suspended() ? ApiThrottle.suspendReason : '';
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

  /**
   * 现在这个家族还在冷却里吗（含**整账号熔断**，见 suspendAll）。
   *
   * 熔断期间一切可选流量都会被这条挡住 —— 各调用点本来就是"先查 blocked 再决定发不发"，
   * 所以这里返回 true 就够了，不需要每个调用点再单独判一次。
   */
  static blocked(family: string): boolean {
    if (ApiThrottle.suspended()) {
      return true;
    }
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

  /**
   * 手动解禁（下拉刷新、换账号这种用户主动的动作可以试一次）。
   *
   * **换账号必须把所有闸门一起归零**（这是本函数的第二个用途，见 core/AccountScope）：
   * 上一个人的冷却/熔断/写间隔记的都是**那个账号**的状态，带过来就会让新账号
   * 一上来就"被限流 45 分钟"或者"发消息要等 8 秒"。
   *
   * 上一版只清了 `until`（家族冷却），`suspendUntil` 那条整账号熔断还挂着 ——
   * 换号后所有可选流量**继续被挡 45 分钟**，界面表现正是"换个账号什么都刷不出来"。
   */
  static clear(family: string = ''): void {
    if (family.length === 0) {
      ApiThrottle.until.clear();
      ApiThrottle.suspendUntil = 0;
      ApiThrottle.suspendReason = '';
      ApiThrottle.lastWriteAt = 0;
      // 队里等着的请求不能就这么悬着：全部放行（它们各自那一发照样受 MAX_IN_FLIGHT 限制）。
      const waiting: Array<PaceWaiter> = ApiThrottle.waiters;
      ApiThrottle.waiters = [];
      for (let index: number = 0; index < waiting.length; index++) {
        waiting[index].resolve();
      }
      // 间隔从"现在"重新开始算，别让上一个人最后那一发的时刻压着新账号。
      ApiThrottle.lastStartAt = 0;
      hilog.info(DOMAIN, TAG, 'throttle cleared (all gates) waiting=%{public}d',
        waiting.length);
      return;
    }
    ApiThrottle.until.delete(family);
  }
}
