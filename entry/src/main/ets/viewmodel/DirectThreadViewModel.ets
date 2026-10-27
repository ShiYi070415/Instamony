/*
 * 一条私信会话（会话详情）的视图模型。
 *
 * ## 和 DirectViewModel 的分工
 *   DirectViewModel  = 收件箱（会话列表）；
 *   这个              = **一条会话的消息** + **发送**。
 *
 * ## 取数
 * 只有一条链：`NativeDirect.thread` → 移动端私有接口 `direct_v2/threads/{id}/`
 * （core/mobileapi/MobileDirect，instagrapi 同源）。**不需要网页模板，也不驱动隐藏网页。**
 * 历史：本文件原来还有"回放会话模板"与"冷启动抓模板"两条路，页面注入退役后一并删除。
 *
 * ## 状态
 * 只留一条会话的状态：进哪条就读哪条（`open()`），读到的消息**按时间正序**（老的在前），
 * 界面往下排。发送用**乐观**策略：先把气泡画出来（sending），成功了用服务端那条替换，
 * 失败就标红并允许重发 —— 不这么做的话，网络抖一下用户看到的就是"点了发送没反应"。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
// 点开会话那一发要用 interactive 优先级（见 load 的说明）。
import { ApiThrottle } from '../core/ApiThrottle';
import { NativeDirect } from '../core/NativeDirect';
// 进会话就把它标成已读（见 markThreadSeen）。
import { MobileDirect } from '../core/mobileapi/MobileDirect';
import { DirectMessage, DirectThreadView } from '../model/Direct';
import { AppLifecycle } from '../core/AppLifecycle';
// mark_seen 的结果写一行面包屑（导出的诊断里能看到"已读到底成没成"，见 markThreadSeen）。
import { ReelsCrashLog } from '../core/ReelsCrashLog';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectThreadViewModel';
/**
 * 会话页**可见时**的轮询间隔（毫秒）：**随机**取 `[MIN, MAX)`，不用固定值。
 *
 * 演进过程（这一段值得留着）：
 *   1. 最早 4 秒 —— 太密；
 *   2. 审计后放宽到 25 秒 —— 稳，但"发了消息要等半分钟才上屏"；
 *   3. 中间一度改成 2.5 秒"近实时" —— **这是节奏上最危险的一版**：固定 2.5 秒是标准脚本指纹，
 *      IG 的 `feedback_required` 看的正是这种单位时间密度；
 *   4. 现在这版：**12~25 秒随机**，并且"自己刚发完消息后的 30 秒"里允许 4~6 秒的突发
 *      （那时候用户确实在等回信，是人的行为，不是机器节奏）。
 *
 * 真正的实时通道（MQTT）在本机不可用（见 core/mobileapi/NetProbe 的三组对照），
 * 所以这里的前提是"宁可慢一点，也别把账号打成脚本"。
 */
const THREAD_POLL_MIN_MS: number = 12000;
const THREAD_POLL_MAX_MS: number = 25000;
/** 自己刚发完消息后的**突发窗口**（毫秒）与窗口内的间隔范围。 */
const THREAD_POLL_BURST_MS: number = 4500;
const THREAD_POLL_BURST_MIN_MS: number = 4000;
const THREAD_POLL_BURST_MAX_MS: number = 6000;
const THREAD_POLL_BURST_WINDOW_MS: number = 30000;
/**
 * **无人操作就停**（毫秒）。
 *
 * 图里那条"取消自动循环抓取、全部操作必须由真人点击触发"落到这里就是：
 * 用户在这条会话上 90 秒没有任何动作（触摸/输入/发送）→ 停掉轮询，**等下一次动作**再续。
 * 我们的轮询本来就是"替用户看有没有新消息"，人已经不看了，继续发就是纯自动化流量。
 */
const THREAD_IDLE_STOP_MS: number = 90000;
/**
 * 乐观气泡的**确认窗口**（毫秒）。
 *
 * 发送成功后要等"服务端那条"回到视图里，才把本地气泡撤掉；本地时间戳与服务端时间戳
 * 会差几百毫秒到几秒，所以给一个窗口。取得小一点是为了避免"连发两条同样文本"时
 * 第二条被第一条的服务端副本误确认（另有一条"一个副本只能用一次"的约束兜底）。
 */
const PENDING_MATCH_SLACK_MS: number = 6000;
/** 确认失败后的复查间隔（毫秒）：一次没对上就在这之后再看一眼（气泡不会消失）。 */
const PENDING_RECHECK_MS: number = 1200;
/**
 * "这条服务端消息刚顶替掉一个乐观气泡"的**记忆时长**（毫秒）。
 *
 * 只给界面用：气泡换成服务端那条时，**不要再播一次入场动画**（本地那条在按发送的
 * 那一刻已经弹过了，再弹一次就是"同一句话弹两下"）。
 */
const CONFIRMED_MEMO_MS: number = 5000;
/**
 * 一条"待发"的任务（乐观气泡已经上屏，等着写接口去发）。
 *
 * **`threadId` 必须在入队时就定下**：这个视图模型是全 App 共用的一份实例，
 * 用户在发送途中退出会话、点进另一条会话的话，`this.threadId` 就变了 ——
 * 拿它发消息会把 A 的话发到 B 那里去（"记录对不上对方账号"）。
 */
interface QueuedSend {
  threadId: string;
  localId: string;
  text: string;
}
/** 一条发送失败、等着用户点重试的消息（见 DirectThreadViewModel.failedSends）。 */
interface FailedSend {
  threadId: string;
  text: string;
}
/**
 * 翻页"卡住"（去重后没多出任何一条）之后的冷却：这段时间内不再翻，过了允许再试一次。
 *
 * 为什么要它：这条查询的分页参数在真机上本来就不认（详见 NativeDirect 里的说明），一次卡住就把
 * `hasOlder` 永久置 false 的话，用户再也翻不动、也没有重试入口（审计 C3）。给个 30 秒的冷却，
 * 服务端一旦恢复可用，用户继续上拉就能自己接上。
 */
const LOAD_OLDER_RETRY_GAP_MS: number = 30000;

export class DirectThreadViewModel {
  /** 当前会话 id（空 = 还没选会话）。 */
  private threadId: string = '';
  /**
   * **会话代数**：每换一次会话 / 每次 reset 都 +1（见 stale 相关判断）。
   *
   * 为什么要它：这个视图模型是全 App 共用的**一份实例**，而"读一条会话"是一个网络往返
   * （真机 200ms~3s）。用户在 A 的消息还在飞的时候点进 B，A 那一发回来时
   * `this.threadId` 已经是 B 了 —— 上一版直接 `this.view = view`，于是
   * **A 的消息被画进 B 的会话里**（用户报的"记录对不上对方账号"）。
   * 光比 threadId 也不够：来回切回同一条会话（A→B→A）时 id 又对上了，
   * 但那一发读的是"上一轮的 A"，还得靠代数把它作废。
   */
  private generation: number = 0;
  /** 收件箱里那一行的标题（读消息之前先拿它当标题，读到了再用真名覆盖）。 */
  private fallbackTitle: string = '';
  /** 清空自己（退出登录 / 换账号时调）：会话内容与待发消息一起丢掉。 */
  reset(): void {
    this.view = null;
    this.pending = [];
    this.confirmedIds = new Map<string, number>();
    this.sendQueue = [];
    this.failedSends = new Map<string, FailedSend>();
    this.pendingThread = new Map<string, string>();
    this.busy = false;
    this.busyFor = '';
    this.threadId = '';
    // 在飞的那几发（首屏 / 翻页 / 轮询）全部作废，见 generation 的说明。
    this.generation++;
    this.seenSentFor = '';
    this.lastLoadAtMs = 0;
    this.stuckUntilMs = 0;
    this.onView(null);
    this.onPending(this.pending);
  }

  private view: DirectThreadView | null = null;
  /** 已经报过"已读"的那条（`threadId:messageId`，见 markThreadSeen）。 */
  private seenSentFor: string = '';
  /** "这条会话已在服务端标成已读" → 收件箱列表把它的未读标记清掉（见 pages/Index 的接线）。 */
  /** 这条会话已在服务端标成已读（tsMs = 读到的那条消息时间，列表用它记本地台账）。 */
  onSeen: (threadId: string, tsMs: number) => void = (threadId: string, tsMs: number): void => {
  };
  private busy: boolean = false;
  /** 现在这一发是给哪条会话读的（见 load 里的 busyFor 判断）。 */
  private busyFor: string = '';
  /** 本地乐观气泡的序号（拼临时 id 用，保证同一毫秒连发也不撞）。 */
  private sendSeq: number = 0;
  /** 待发队列（见 QueuedSend）：**不是"忙就丢掉"**，是一条条排队发出去。 */
  private sendQueue: Array<QueuedSend> = [];
  /** 队列正在发（防重入）。 */
  private draining: boolean = false;
  /** 发送失败的乐观气泡：本地 id → 失败详情（界面标红 + 可点重试，见 isFailed / retryFailed）。 */
  private failedSends: Map<string, FailedSend> = new Map<string, FailedSend>();
  /**
   * 每个乐观气泡属于哪条会话（本地 id → threadId）。
   *
   * 视图模型是全局共用的一个实例：切会话时不能把"别的会话还没发完的气泡"画到当前会话里，
   * 但它们也**不能丢**（队列还在发）—— 回到原来那条会话时气泡原样回来（见 open）。
   */
  private pendingThread: Map<string, string> = new Map<string, string>();
  private diag: string = '-';
  /** 乐观发送的临时消息（本地 id → 文本），成功/失败后清掉。 */
  private pending: Array<DirectMessage> = [];
  /** 刚顶替掉乐观气泡的服务端消息 id → 那一刻（见 CONFIRMED_MEMO_MS / wasConfirmed）。 */
  private confirmedIds: Map<string, number> = new Map<string, number>();
  /** 实时接收的计时器（见 startPolling / stopPolling）。 */
  private pollTimer: number = -1;
  /** 一轮轮询正在跑（防重入）。 */
  private polling: boolean = false;
  /**
   * 上一次**首屏拉取**落定的时刻（毫秒；0 = 还没拉过）。
   *
   * 只给 pollOnce 用：点开会话那一发刚落定，轮询第一拍不该紧接着再发同样的请求
   * （真机实测 1.6 秒内发了两发 35KB）。
   */
  private lastLoadAtMs: number = 0;
  /** 应用是否在前台（后台时暂停轮询，见 hookVisibility）。 */
  private foreground: boolean = true;
  /** 前后台监听是否已挂（幂等）。 */
  private visibilityHooked: boolean = false;
  /** 突发窗口截止时刻：自己刚发完消息后的 30 秒里允许密一点（见 THREAD_POLL_BURST_*）。 */
  private burstUntilMs: number = 0;
  /** 用户最后一次在这条会话上动作的时刻（见 THREAD_IDLE_STOP_MS）。 */
  private lastActivityMs: number = 0;
  /** 是否"应当"在轮询（startPolling 起、stopPolling 止；空闲停下时不改它，见 touchActivity）。 */
  private isPollingWanted: boolean = false;
  /** 有新消息时的回调（界面据此贴到底部）。 */
  private onNew: (() => void) | undefined = undefined;

  onView: (view: DirectThreadView | null) => void = (view: DirectThreadView | null): void => {
  };
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
  };
  onStatus: (text: string) => void = (text: string): void => {
  };
  /** 乐观气泡变化（发送中/失败）时回调，界面据此刷新。 */
  onPending: (items: Array<DirectMessage>) => void =
    (items: Array<DirectMessage>): void => {
    };

  /** 收件箱那一行带过来的资料（标题栏在读数回来之前先用它，见 open）。 */
  private fallbackAvatar: string = '';
  private fallbackGroup: boolean = false;
  private fallbackUserId: string = '';
  /** 收件箱那一行带过来的**账号名**（标题栏第二行的首选）。 */
  private fallbackUsername: string = '';

  /**
   * 选一条会话。
   *
   * **必须把上一条的内容清掉**：视图模型是全 App 共用的一个实例，切会话时上一份
   * `view` 还在里面 —— 页面一建就把上一个人的消息/标题铺出来，等本次读完再换，
   * 用户看到的就是"信息不对 + 内容闪一下变成新的"（用户报的正是这个）。清空之后标题栏
   * 先用**收件箱那一行**的资料（用户名/头像/群标记），列表空着等本次读数。
   *
   * **这里不再读任何本地缓存**（需求："去除文本快照缓存"）：点开会话就是一次干净的网络
   * 请求（见 load 的 interactive 优先级）。所以这个函数是纯同步的，越快越好 ——
   * 页面能在同一帧里就把标题/头像画出来，只为消息留一个加载态。
   */
  open(threadId: string, title: string, avatar: string = '', isGroup: boolean = false,
       userId: string = '', username: string = ''): void {
    /*
     * **换会话时只隐藏"别的会话"的乐观气泡，队列一条都不许丢**。
     *
     * 上一版在这里把 `sendQueue` 整个清掉（还打了"丢弃待发"的日志）—— 结果就是
     * 用户连着发两三条、中途退出会话再进来，那几条**再也不会发出去**，
     * 退出重进对记录当然对不上（用户报的"一发都出不去了"）。
     * 队列里每条都自带 `threadId`（见 QueuedSend），会照旧发到它自己的会话。
     * 回到同一条会话时，气泡原样还在（`pendingThread` 记着它们属于谁）。
     */
    const kept: Array<DirectMessage> = [];
    for (let index: number = 0; index < this.pending.length; index++) {
      const one: DirectMessage = this.pending[index];
      const owner: string | undefined = this.pendingThread.get(one.id);
      if (owner === undefined || owner === threadId) {
        kept.push(one);
      }
    }
    this.threadId = threadId;
    // 换了会话：之前所有在飞的请求（首屏/翻页/轮询/发送后的刷新）一律作废。
    this.generation++;
    this.seenSentFor = '';
    this.stuckUntilMs = 0;
    this.lastLoadAtMs = 0;
    this.fallbackTitle = title;
    this.fallbackAvatar = avatar;
    this.fallbackGroup = isGroup;
    this.fallbackUserId = userId;
    this.fallbackUsername = username;
    this.view = null;
    this.onView(this.view);
    this.diag = '-';
    this.pending = kept;
    this.confirmedIds = new Map<string, number>();
    this.onPending(this.pending);
  }

  viewNow(): DirectThreadView | null {
    return this.view;
  }

  /** 现在开着的是哪条会话（实时推送要靠它判断"这条消息是不是给当前这页的"）。 */
  threadIdNow(): string {
    return this.threadId;
  }

  /**
   * **实时推来的一条新消息直接插进当前这一屏**（见 core/DirectRealtime）。
   *
   * 这是"零延迟"那一半：不请求、不缓存，推过来的就是最终结果。三条规矩：
   *   · 首屏还没读出来（`view` 为空）时不插 —— 要么 `load()` 那发会把它带回来，
   *     要么这一屏还是空的，硬插一条会变成"整个会话只有一条消息"的假象；
   *   · 同 id 已经在屏上就忽略（补丁会重发，轮询也会把同一条带回来）；
   *   · 插进去之后按时间重排一次并 `onView` 通知界面（最新一条变了下层会自动贴底，
   *     见 DirectThreadPage 的 onView）。
   *
   * @returns 是否真的插进去了（调用方据此决定还要不要再刷新列表）。
   */
  applyIncoming(message: DirectMessage): boolean {
    const view: DirectThreadView | null = this.view;
    if (view === null || message.id.length === 0) {
      return false;
    }
    for (let index: number = 0; index < view.messages.length; index++) {
      if (view.messages[index].id === message.id) {
        return false;
      }
    }
    const messages: Array<DirectMessage> = view.messages.concat([message]);
    messages.sort((a: DirectMessage, b: DirectMessage): number => a.tsMs - b.tsMs);
    this.view = new DirectThreadView(view.id, view.title, view.withUsername, view.withAvatar,
      view.withId, messages, view.hasOlder, view.oldestCursor, view.isGroup, view.withFullName);
    // 刚有推送到达：别让轮询紧接着再发一发同样的请求（见 pollOnce 的 8 秒闸）。
    this.lastLoadAtMs = Date.now();
    this.onView(this.view);
    /*
     * **自己刚发出去的那条也会被推回来**（message_sync 不分收发）。
     *
     * 不在这里顺手撤掉乐观气泡的话，服务端副本会与本地那条**同时**在屏上
     * —— 用户看到的正是"发消息会一次性弹出两条相同的，然后收回一条"。
     * 撤与插放在同一个 tick 里，界面一帧都看不到重复（见 dropConfirmedPending）。
     */
    this.dropConfirmedPending();
    hilog.info(DOMAIN, TAG, 'live append id=%{public}d msgs=%{public}d mine=%{public}s',
      message.id.length, messages.length, `${message.mine}`);
    return true;
  }

  pendingNow(): Array<DirectMessage> {
    return this.pending;
  }

  /**
   * 这条消息是不是**刚顶替掉一个乐观气泡**（见 CONFIRMED_MEMO_MS）。
   *
   * 界面据此**跳过入场动画**：本地那条在按下发送时已经弹过一次了，
   * 换成服务端那条再弹一次就成了"同一句话弹两下"。
   */
  wasConfirmed(id: string): boolean {
    const at: number | undefined = this.confirmedIds.get(id);
    if (at === undefined) {
      return false;
    }
    if (Date.now() - at > CONFIRMED_MEMO_MS) {
      this.confirmedIds.delete(id);
      return false;
    }
    return true;
  }

  busyNow(): boolean {
    return this.busy;
  }

  /** 标题：真名优先，其次收件箱那一行的标题，最后兜底"私信"。 */
  titleNow(): string {
    // 需求：第一行是**名字**（full_name），第二行才是用户名。
    if (this.view !== null && this.view.withFullName.length > 0) {
      return this.view.withFullName;
    }
    if (this.view !== null && this.view.title.length > 0) {
      return this.view.title;
    }
    return this.fallbackTitle;
  }

  /** 标题栏那颗头像（对方 / 群图；没读到就用收件箱那一行带过来的）。 */
  avatarNow(): string {
    if (this.view !== null && this.view.withAvatar.length > 0) {
      return this.view.withAvatar;
    }
    return this.fallbackAvatar;
  }

  /**
   * 标题栏第二行（灰色小字）：**1:1 会话显示对方 id**；群聊返回空串（需求："群聊只需要
   * 显示群聊名字"）。
   */
  subtitleNow(): string {
    const isGroup: boolean = this.view !== null ? this.view.isGroup : this.fallbackGroup;
    if (isGroup) {
      return '';
    }
    // 需求：标题栏两行 —— 上面是**名字**（mainTitle，2/3 字号），下面是**用户名**
    // （alice 这种 id，1/3 字号、灰色）。这里给第二行的内容：用户名优先，
    // 读不到才退回数字 id。
    if (this.view !== null && this.view.withUsername.length > 0) {
      return this.view.withUsername;
    }
    // 视图里没给就用收件箱那一行的账号名（inbox 的 GraphQL 里一定有）。
    if (this.fallbackUsername.length > 0) {
      return this.fallbackUsername;
    }
    // 读不到用户名时用 thread_title 兜底（真机上 1:1 会话的 thread_title 就是用户名）。
    if (this.view !== null && this.view.title.length > 0
      && this.view.title !== this.titleNow()) {
      return this.view.title;
    }
    const id: string = this.view !== null && this.view.withId.length > 0
      ? this.view.withId : this.fallbackUserId;
    return id;
  }

  /**
   * 读这一条会话的最新一屏消息。
   *
   * **优先级用 `interactive()`**（需求："加快进入会话获取消息的速度"）：这是用户点进来的那一刻，
   * 而全局闸门对 warm 是 1.5~3.5 秒的起发间隔、对 interactive 是 0.6~1.2 秒，而且插队到
   * 队列最前面（见 core/ApiThrottle）。以前用默认的 warm，第一屏经常要等两三秒才出来。
   */
  async load(): Promise<void> {
    if (this.threadId.length === 0) {
      return;
    }
    /*
     * **只在"同一会话已经在读"时才挡**（见 busyFor）。
     *
     * 上一版是 `if (this.busy) return`：A 的首屏还在飞时用户点进 B，B 这一发被挡掉，
     * 而 A 那一发回来又会被判成过期丢掉 —— 结果 B 一直空着、没有任何重试入口。
     */
    if (this.busy && this.busyFor === this.threadId) {
      return;
    }
    this.busy = true;
    this.busyFor = this.threadId;
    this.onBusy(true);
    /*
     * 这一发是**给这条会话**读的：把 id 与代数都先记下来，回来时核对（见 generation）。
     * 记录顺序反了就是 A 的消息落进 B —— 这正是这一批修的那个 P0。
     */
    const wantThread: string = this.threadId;
    const wantGen: number = this.generation;
    try {
      const view: DirectThreadView | null = await NativeDirect.thread(wantThread, '',
        this.fallbackUserId, ApiThrottle.urgent());
      if (this.isStale(wantGen, wantThread)) {
        hilog.info(DOMAIN, TAG, 'load dropped: thread switched (want %{public}d chars now %{public}d)',
          wantThread.length, this.threadId.length);
        return;
      }
      if (view === null) {
        this.diag = NativeDirect.lastDetail();
        // 没有本地快照兜底了（需求：去掉文本快照缓存）：失败就如实说，页面留着空态可重试。
        this.onStatus('读取失败：' + this.diag);
        return;
      }
      this.view = view;
      // 记下"刚拉过"，让轮询第一拍别紧跟着再发一发（见 pollOnce 的说明）。
      this.lastLoadAtMs = Date.now();
      this.onView(view);
      /*
       * **同一帧里把已经到位的乐观气泡撤掉**（见 applyIncoming 里那条说明）。
       *
       * 这一发多半就是"发送成功后的那次刷新"：服务端副本已经在 `view` 里了，
       * 本地那条继续留着就是两条一模一样的。放在 `onView` 紧后面、同一个 tick 里，
       * 界面一次都不会画出重复。
       */
      this.dropConfirmedPending();
      /*
       * 空态要**说清楚是哪一种空**。
       *
       * 真机抓到过一类会话：`thread ok msgs=0 raw=21`，21 条条目全是 `placeholder`
       * （IG 那边这条对话已经没有可显示的内容了，见 MobileDirect.itemTypeHistogram）。
       * 这时候不写状态行，用户看到的就是一整片空白 —— 分不清"没消息"还是"没读出来"。
       */
      this.onStatus(view.messages.length > 0 ? '已加载' : '这个会话没有可显示的消息');
      /*
       * **进会话就算看过了**：照 instagrapi 的 `direct_send_seen` 把这条会话标成已读
       * （`direct_v2/threads/{id}/items/{最新消息id}/seen/`，见 MobileDirect.markSeen）。
       *
       * 不标的话 IG 那边一直记着"没看"，下次刷收件箱又会把这条画成未读
       * —— 用户报的"已读私信全变成未读"有一半是这个原因。
       * 发完就刷新收件箱（列表里的粗体/蓝点跟着消失）。
       */
      this.markThreadSeen(view);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      // 只有"这一发还是当前那一发"才收 busy：换会话后新那一发可能正在跑。
      if (this.busyFor === wantThread) {
        this.busy = false;
        this.busyFor = '';
        this.onBusy(false);
      }
    }
  }

  /**
   * 这一发回来时，会话还开着吗（见 generation / threadId 的说明）。
   *
   * 两个条件都要看：id 变了 = 换了别人；代数变了 = 期间被 reset / 重新 open 过
   * （A→B→A 时 id 又对上了，但读的是上一轮的 A，同样作废）。
   */
  private isStale(gen: number, threadId: string): boolean {
    return gen !== this.generation || threadId !== this.threadId;
  }

  /**
   * 把这条会话在服务端标成已读（进会话即触发，见 load 里那一处调用）。
   *
   * 只发一次（`seenSentFor` 记住"这条会话的哪条消息已经报过"）：翻页/轮询回来重复报
   * 没有意义，还会白白多打写接口。
   */
  private markThreadSeen(view: DirectThreadView): void {
    if (view.messages.length === 0) {
      return;
    }
    const newest: DirectMessage = view.messages[view.messages.length - 1];
    if (newest.id.length === 0) {
      return;
    }
    const key: string = `${view.id}:${newest.id}`;
    if (this.seenSentFor === key) {
      return;
    }
    this.seenSentFor = key;
    MobileDirect.markSeen(view.id, newest.id).then((ok: boolean): void => {
      hilog.info(DOMAIN, TAG, 'seen reported id=%{public}s ok=%{public}s', view.id, `${ok}`);
      /*
       * **无论服务端成没成，本地都要记一笔已读**（见 DirectViewModel.markThreadRead 的台账）。
       * 成了当然要记；没成（限流 / 接口抖动）更要记 —— 否则用户读完退出、列表 20 秒后
       * 轮询回来又把它画成未读，看起来就是"已读没生效"。
       */
      ReelsCrashLog.note(`direct seen id=${view.id} ok=${ok} ts=${newest.tsMs}`);
      this.onSeen(view.id, newest.tsMs);
    }).catch((error: Error): void => {
      ReelsCrashLog.note(`direct seen FAILED id=${view.id} ${error.message ?? '-'}`);
      this.onSeen(view.id, newest.tsMs);
    });
  }

  /** 翻页"卡住"之后的冷却截止时刻（见 loadOlder 里 stuck 那段）。 */
  private stuckUntilMs: number = 0;

  /** 这条会话的网页地址（读不出来时界面拿它回落网页，见 DirectThreadPage）。 */
  webUrl(): string {
    return 'https://www.instagram.com/direct/t/' + encodeURIComponent(this.threadId) + '/';
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 发一条文本。
   *
   * 乐观：先把气泡放进去（`pending`），成功后再拉一次最新消息（拿服务端那条真消息，顺便确认
   * 顺序）；失败把气泡标成失败（界面提示可重发）。
   */
  async send(text: string): Promise<boolean> {
    const body: string = text.trim();
    // 入口留痕：界面气泡画出来了但网络没动静时，这一行能区分"没进 VM"与"VM 里被挡下"。
    hilog.info(DOMAIN, TAG, 'send ui entry len=%{public}d thread=%{public}d queue=%{public}d',
      body.length, this.threadId.length, this.sendQueue.length);
    if (body.length === 0 || this.threadId.length === 0) {
      hilog.warn(DOMAIN, TAG, 'send ui blocked: len=%{public}d thread=%{public}d',
        body.length, this.threadId.length);
      return false;
    }
    /*
     * **乐观气泡立刻上屏，发送排队执行**（用户报："会出现一两条消息发不出去的情况"）。
     *
     * 原来是"上一发还在飞就直接 `return false`"：输入框在 `CommentInputBar.submit` 里
     * **已经清空**了，于是那一条既没发出去、也没留在任何地方 —— 用户只看到"发不出去"。
     * 现在连点几下就排几条，按顺序一条条发（写接口本来就有人速间隔，见 ApiThrottle.writeSlot）。
     */
    this.sendSeq++;
    const temp: DirectMessage = new DirectMessage(`local-${Date.now()}-${this.sendSeq}`, '',
      true, Date.now(), 'text', body);
    this.pending = this.pending.concat([temp]);
    // 记下这条气泡属于哪条会话（切走了就藏起来、回来还在，见 open）。
    this.pendingThread.set(temp.id, this.threadId);
    this.onPending(this.pending);
    this.sendQueue.push({ threadId: this.threadId, localId: temp.id, text: body });
    this.drainSends();
    return true;
  }

  /**
   * 把队列里的消息一条条发出去（`send` 只负责入队，见那里的说明）。
   *
   * 顺序发、不并发：发消息是最容易被 IG 判成脚本的写操作，`NativeDirect.sendText`
   * 内部已经有人速间隔，这里再并发就白排了。
   * 每成功一条就增量刷新一次（`refreshAfterSend`），把本地气泡换成服务端那条。
   */
  private async drainSends(): Promise<void> {
    if (this.draining) {
      return;
    }
    this.draining = true;
    this.onBusy(true);
    try {
      while (this.sendQueue.length > 0) {
        const job: QueuedSend | undefined = this.sendQueue[0];
        if (job === undefined) {
          break;
        }
        // 会话被切走过：这一条只属于它自己那条会话（见 QueuedSend 的说明）。
        if (job.threadId.length === 0) {
          this.sendQueue.shift();
          continue;
        }
        let ok: boolean = false;
        try {
          ok = await NativeDirect.sendText(job.threadId, job.text);
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'send threw: %{public}s', (error as Error).message);
          ok = false;
        }
        this.sendQueue.shift();
        if (!ok) {
          /*
           * **不吞掉**：气泡留在屏上并标红，用户点一下重试（见 retryFailed）。
           * 失败原因分两类说清楚：
           *   · `challenge_required`：账号被要求**安全验证**（写接口全被拒，重试无用）——
           *     让用户去首页横幅点「去验证」；真机实测发消息失败正是这个
           *     （响应体 `{"message":"challenge_required", … "lock":true}`）。
           *   · 其它：原样带上 detail（如 `send-1545023:…`、`throttled-3min`），便于定位。
           */
          const why: string = NativeDirect.lastDetail();
          this.failedSends.set(job.localId, { threadId: job.threadId, text: job.text });
          hilog.warn(DOMAIN, TAG, 'send failed local=%{public}s why=%{public}s left=%{public}d',
            job.localId, why, this.sendQueue.length);
          this.onStatus(why === 'challenge_required'
            ? '账号被要求安全验证：去首页点「去验证」之后再试'
            : `发送失败：${why}（点气泡重试）`);
          this.onPending(this.pending);
          continue;
        }
        this.failedSends.delete(job.localId);
        /*
         * **只有"这条会话还开着"才刷新**：用户在发送途中点进了另一条会话的话，
         * 现在 `this.threadId` / `this.view` 都是别的会话的，合并进来会把 A 的消息塞进 B。
         */
        if (job.threadId !== this.threadId) {
          hilog.info(DOMAIN, TAG, 'send ok for closed thread → skip refresh local=%{public}s',
            job.localId);
          continue;
        }
        this.onStatus('');
        // 自己刚发完消息 → 30 秒内允许密一点的轮询（见 THREAD_POLL_BURST_*）。
        this.burstUntilMs = Date.now() + THREAD_POLL_BURST_WINDOW_MS;
        if (this.pollTimer < 0) {
          this.armTimer();
        }
        /*
         * **先拉一次把服务端那条拿到手，再撤掉乐观气泡。**
         *
         * 早先是"先 `pending = []` 再 `load()`"：中间那 1~3 秒里刚发出去的那条会**凭空消失**，
         * 等刷新回来又出现 —— 用户报的"发出后消失再出现"就是这个闪烁。
         * 现在反过来：气泡一直留着，直到新视图里真的出现"我发的、同一条文本"才撤掉。
         *
         * **这一发必须"增量合并"，不能 `load()`**（用户报："发新消息后页面会刷新导致动画又
         * 播放一遍"）：`load()` 把整份视图换掉，服务端那一页条数/窗口和屏上的可能不一样，
         * 一换就整表重建（序号一变整屏都当新条目）→ 所有气泡重播入场动画、列表还跳一下。
         */
        await this.refreshAfterSend();
        this.dropConfirmedPending();
        // 一次没对上（服务端还没返回）就过一会儿再看；这期间气泡继续留着，不会消失。
        setTimeout((): void => {
          this.dropConfirmedPending();
        }, PENDING_RECHECK_MS);
      }
    } finally {
      this.draining = false;
      this.onBusy(false);
      this.onPending(this.pending);
    }
  }

  /** 这条乐观气泡发送失败了吗（界面据此标红）。 */
  isFailed(localId: string): boolean {
    return this.failedSends.has(localId);
  }

  /** 现在失败着的本地气泡 id（只给当前这条会话的；界面进会话时同步一份）。 */
  failedIdsNow(): Array<string> {
    const ids: Array<string> = [];
    this.failedSends.forEach((one: FailedSend, id: string): void => {
      if (one.threadId === this.threadId) {
        ids.push(id);
      }
    });
    return ids;
  }

  /**
   * 重试一条发送失败的气泡（用户点气泡触发）。
   *
   * 气泡本身不重建（本地 id 不变），只是重新入队 —— 成功之后照常换成服务端那条。
   */
  retryFailed(localId: string): void {
    const one: FailedSend | undefined = this.failedSends.get(localId);
    if (one === undefined) {
      return;
    }
    this.failedSends.delete(localId);
    this.sendQueue.push({ threadId: one.threadId, localId: localId, text: one.text });
    hilog.info(DOMAIN, TAG, 'retry send local=%{public}s queue=%{public}d',
      localId, this.sendQueue.length);
    this.onPending(this.pending);
    this.drainSends();
  }

  /**
   * 发送成功后的那次刷新：**只追加，不整份替换**（见 send 里的说明）。
   *
   * 之前这里调的是 `load()` —— 它把整份视图换成"服务端最新一页"。问题有两个：
   *   · 服务端那一页的条数/窗口和屏上的不一定一样，换一次整表序号就变，
   *     `ForEach` 把每一行都当新条目重建，于是**整屏气泡重播入场动画、列表还跳一下**
   *     （用户报的"发新消息后页面会刷新导致动画又播放一遍"）；
   *   · 用户已经上滑翻出来的历史会被那一页挤掉。
   *
   * 合并逻辑与轮询共用一份（`mergeFresh`），行为完全一致。
   */
  private async refreshAfterSend(): Promise<void> {
    if (this.threadId.length === 0) {
      return;
    }
    // 这一发只为"刚发出消息的那条会话"读；回来时核对（见 generation）。
    const wantThread: string = this.threadId;
    const wantGen: number = this.generation;
    let fresh: DirectThreadView | null = null;
    try {
      fresh = await NativeDirect.thread(wantThread, '', this.fallbackUserId,
        ApiThrottle.interactive());
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'refreshAfterSend threw: %{public}s', (error as Error).message);
      return;
    }
    if (this.isStale(wantGen, wantThread)) {
      hilog.info(DOMAIN, TAG, 'refreshAfterSend dropped: thread switched');
      return;
    }
    if (fresh === null) {
      // 拉不到就靠 1200ms 后那次复查；乐观气泡继续留着，不会消失。
      hilog.info(DOMAIN, TAG, 'refreshAfterSend failed detail=%{public}s', NativeDirect.lastDetail());
      return;
    }
    this.lastLoadAtMs = Date.now();
    const added: number = this.mergeFresh(fresh);
    hilog.info(DOMAIN, TAG, 'refreshAfterSend +%{public}d total=%{public}d',
      added, this.view === null ? -1 : this.view.messages.length);
  }

  /**
   * 把"服务端最新一页"并进现有视图：**只追加没见过的 id，绝不整份替换**。
   *
   * 保留旧的 `hasOlder` / `oldestCursor`：那个游标对应"我们手上最老那条"，
   * 换成最新页的游标会让下一次上拉把已有的消息再取一遍（看着像没反应）。
   *
   * @returns 真正追加的条数（0 = 屏上已经是最新）
   */
  private mergeFresh(fresh: DirectThreadView): number {
    const view: DirectThreadView | null = this.view;
    /*
     * **不是同一条会话就一律不并**（最后一道闸，见 generation）。
     *
     * 前面几处（load / refreshAfterSend / pollOnce）都已经核对过，这里再挡一次是因为
     * 合并函数本身是"按 id 追加"的语义：一旦混进别的会话的消息，界面就是
     * "在一个人的对话里看到另一个人的话"，而且**再也清不掉**（只能退出重进）。
     */
    if (view !== null && view.id.length > 0 && fresh.id.length > 0 && fresh.id !== view.id) {
      hilog.warn(DOMAIN, TAG, 'mergeFresh rejected: view=%{public}d fresh=%{public}d',
        view.id.length, fresh.id.length);
      return 0;
    }
    // 还没有首屏（理论上不会）：那就当首屏用。
    if (view === null) {
      this.view = fresh;
      this.onView(this.view);
      this.dropConfirmedPending();
      return fresh.messages.length;
    }
    const known: Array<string> = [];
    for (let index: number = 0; index < view.messages.length; index++) {
      known.push(view.messages[index].id);
    }
    let added: number = 0;
    const merged: Array<DirectMessage> = view.messages.slice(0);
    for (let index: number = 0; index < fresh.messages.length; index++) {
      const one: DirectMessage = fresh.messages[index];
      if (known.indexOf(one.id) < 0) {
        known.push(one.id);
        merged.push(one);
        added++;
      }
    }
    if (added === 0) {
      return 0;
    }
    merged.sort((a: DirectMessage, b: DirectMessage): number => a.tsMs - b.tsMs);
    this.view = new DirectThreadView(view.id, view.title, view.withUsername, view.withAvatar,
      view.withId, merged, view.hasOlder, view.oldestCursor, view.isGroup, view.withFullName);
    this.onView(this.view);
    // 服务端副本进来 → 本地那条乐观气泡在同一个 tick 里撤掉（见 applyIncoming 的说明）。
    this.dropConfirmedPending();
    return added;
  }


  /**
   * 把**已经在服务端出现**的乐观气泡撤掉（见 send 里的说明）。
   *
   * 匹配规则：同一条文本、都是我发的、时间不早于本地那条太多。
   * 一条服务端消息**只能用一次**（`used`）：连发两条同样的文本时，第一条的
   * 服务端副本不能把第二条也"确认"掉，否则第二条会立刻消失。
   */
  private dropConfirmedPending(): void {
    if (this.pending.length === 0) {
      return;
    }
    const used: Set<string> = new Set<string>();
    const keep: Array<DirectMessage> = [];
    let dropped: number = 0;
    for (let index: number = 0; index < this.pending.length; index++) {
      const one: DirectMessage = this.pending[index];
      /*
       * 只确认"属于当前这条会话"的气泡：切会话后 `this.view` 是别人的，
       * 拿它去匹配会把另一条会话里同样文本的气泡误判成"已发送"（那样它就再也不发了）。
       */
      const owner: string | undefined = this.pendingThread.get(one.id);
      if (owner !== undefined && owner !== this.threadId) {
        keep.push(one);
        continue;
      }
      const hitId: string = DirectThreadViewModel.serverCopyOf(this.view, one, used);
      if (hitId.length > 0) {
        used.add(hitId);
        // 记一下：界面看到这条时不要再播入场动画（见 wasConfirmed）。
        this.confirmedIds.set(hitId, Date.now());
        this.pendingThread.delete(one.id);
        dropped++;
        continue;
      }
      keep.push(one);
    }
    if (dropped === 0) {
      return;
    }
    this.pending = keep;
    this.onPending(this.pending);
    hilog.info(DOMAIN, TAG, 'pending confirmed dropped=%{public}d left=%{public}d',
      dropped, keep.length);
  }

  /** 视图里有没有"这一条"的服务端副本（有就返回它的 id，没有给空串）。 */
  private static serverCopyOf(view: DirectThreadView | null, temp: DirectMessage,
                              used: Set<string>): string {
    if (view === null) {
      return '';
    }
    for (let index: number = 0; index < view.messages.length; index++) {
      const one: DirectMessage = view.messages[index];
      if (!one.mine || one.kind !== 'text' || one.text !== temp.text) {
        continue;
      }
      if (used.has(one.id)) {
        continue;
      }
      // 本地时间与服务端时间会差几百毫秒到几秒；只认"不早于本地那条太多"的。
      if (one.tsMs + PENDING_MATCH_SLACK_MS < temp.tsMs) {
        continue;
      }
      return one.id;
    }
    return '';
  }

  /** 取更老的一批消息（接到前面）。 */
  async loadOlder(): Promise<void> {    /*
     * 上一次"卡住"（去重后没多出东西）之后有个冷却期：期间直接返回，别每滑一下就发一发
     * 必然重复的请求；过了冷却允许再试（见 loadOlder 里 stuck 那段与 LOAD_OLDER_RETRY_GAP_MS）。
     */
    if (this.stuckUntilMs > Date.now()) {
      hilog.info(DOMAIN, TAG, 'loadOlder skip: cooling down %{public}dms left',
        this.stuckUntilMs - Date.now());
      return;
    }
    if (this.busy || this.view === null || !this.view.hasOlder
      || this.view.oldestCursor.length === 0) {
      // 被挡下也要留痕：不然"上拉没反应"到底是没触发还是被守卫拦了，日志里看不出来。
      // 游标开头一起打出来 —— 翻页要把它喂给 `min_uq_seq_id`，它长什么样决定了喂得对不对。
      hilog.info(DOMAIN, TAG,
        'loadOlder skip busy=%{public}s view=%{public}s older=%{public}s cursor=%{public}d head=%{public}s',
        `${this.busy}`, this.view === null ? 'null' : 'ok',
        this.view === null ? '-' : `${this.view.hasOlder}`,
        this.view === null ? -1 : this.view.oldestCursor.length,
        this.view === null ? '-' : this.view.oldestCursor.substring(0, 80));
      return;
    }
    this.busy = true;
    this.busyFor = this.threadId;
    this.onBusy(true);
    // 游标与目标会话都在**发请求前**取好：这一发回来时 this.view 可能已经换人了（见 generation）。
    const wantThread: string = this.threadId;
    const wantGen: number = this.generation;
    const cursor: string = this.view.oldestCursor;
    try {
      const older: DirectThreadView | null =
        await NativeDirect.thread(wantThread, cursor, this.fallbackUserId);
      if (this.isStale(wantGen, wantThread) || this.view === null) {
        hilog.info(DOMAIN, TAG, 'loadOlder dropped: thread switched');
        return;
      }
      if (older === null) {
        // 翻页请求失败也要留痕：没有这行日志时，"没触发"和"请求了但被拒"分不清。
        hilog.warn(DOMAIN, TAG, 'loadOlder failed detail=%{public}s cursor=%{public}d',
          NativeDirect.lastDetail(), cursor.length);
        this.onStatus('读取失败：' + NativeDirect.lastDetail());
        return;
      }
      /*
       * **按 id 去重再合并**（这条就是用户报的"上拉一直循环最新一页"）。
       *
       * 游标万一没换动（模板里那个键名不对、或者 IG 把游标忽略），服务端会把**同一页**再回一次；
       * 原来是 `older.messages.concat(this.view.messages)` —— 照单全收，于是每上拉一次就多一份
       * 同样的消息，界面看着就是"历史消息在无限循环"。
       */
      const merged: Array<DirectMessage> = [];
      const seen: Array<string> = [];
      const push = (list: Array<DirectMessage>): void => {
        for (let at: number = 0; at < list.length; at++) {
          const one: DirectMessage = list[at];
          if (seen.indexOf(one.id) < 0) {
            seen.push(one.id);
            merged.push(one);
          }
        }
      };
      push(older.messages);
      push(this.view.messages);
      merged.sort((a: DirectMessage, b: DirectMessage): number => a.tsMs - b.tsMs);
      const added: number = merged.length - this.view.messages.length;
      /*
       * **没多出来任何一条就不再往下翻 —— 但只是"这一次"停，不是永久停**（审计 C3）。
       *
       * 原来直接把 `hasOlder` 置 false：游标一旦吃错参数（这条查询的分页参数在真机上本来就不认），
       * 用户就再也翻不动了，而且**没有任何重试入口**（`loadOlder` 第一行就 return）。
       * 现在改成"停 + 冷却"：记录一次卡住的时刻，冷却过后允许再试一次（`loadOlder` 里的
       * `stuckUntilMs` 判断）。这样服务端那边的参数一旦恢复可用，用户不用重开 App 就能继续翻。
       */
      const stuck: boolean = added === 0;
      if (stuck) {
        this.stuckUntilMs = Date.now() + LOAD_OLDER_RETRY_GAP_MS;
        hilog.warn(DOMAIN, TAG, 'loadOlder stuck: cursor=%{public}d retry after %{public}dms',
          older.oldestCursor.length, LOAD_OLDER_RETRY_GAP_MS);
      }
      const canGoOlder: boolean = older.hasOlder && added > 0;
      hilog.info(DOMAIN, TAG, 'loadOlder: +%{public}d total=%{public}d older=%{public}s cursor=%{public}d',
        added, merged.length, `${canGoOlder}`, older.oldestCursor.length);
      this.view = new DirectThreadView(this.view.id, this.view.title, this.view.withUsername,
        this.view.withAvatar, this.view.withId, merged, canGoOlder, older.oldestCursor,
        this.view.isGroup, this.view.withFullName);
      this.onView(this.view);
    } finally {
      // 同 load：换会话后新那一发已经在跑时，别把它的 busy 收掉（见 load 的 busyFor 说明）。
      if (this.busyFor === wantThread) {
        this.busy = false;
        this.busyFor = '';
        this.onBusy(false);
      }
    }
  }

  // ==========================================================================
  // 实时接收（轮询那条会话）
  // ==========================================================================

  /**
   * 开始**实时接收**：按随机间隔静默拉一次这条会话，有新消息就回调。
   *
   * 间隔规则见 `THREAD_POLL_MIN_MS` 的说明：常态 12~25 秒随机；
   * 自己刚发完消息后的 30 秒内走 4~6 秒的突发（那时候人在等回信）。
   *
   * 三个讲究：
   *   1. **静默**：不碰 `busy` / 不写状态行 / 不发 `onBusy`，免得把界面刷成"正在加载"；
   *   2. **只认新 id**：把拉到的消息与现有那份按 id 合并，`onNew` 只在**真的有新消息**时回调
   *      （界面据此决定要不要贴到底部）；
   *   3. **幂等**：重复调用只保留一个计时器。
   */
  startPolling(onNew: () => void): void {
    this.onNew = onNew;
    this.lastActivityMs = Date.now();
    this.isPollingWanted = true;
    this.hookVisibility();
    if (this.pollTimer >= 0) {
      return;
    }
    this.armTimer();
  }

  /**
   * 用户在会话页上动了（触摸 / 输入 / 发送）。
   *
   * 见 `THREAD_IDLE_STOP_MS`：空闲超过阈值就停轮询，**下一次动作把它叫醒**。
   * 这样"自动循环"只在人真的在看的时候存在。
   */
  touchActivity(): void {
    this.lastActivityMs = Date.now();
    if (this.pollTimer < 0 && this.foreground && this.isPollingWanted) {
      this.armTimer();
    }
  }

  /**
   * 挂**下一拍**的定时器（每拍结束后自己重挂，间隔每拍重算）。
   *
   * 为什么不用 `setInterval`：固定周期本身就是指纹。这里每拍都按"当前是否在突发窗口"
   * 抽一个新的随机间隔，间隔序列是 `随机(12~25s)` 与 `随机(4~6s)` 的混合。
   */
  private armTimer(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
    if (!this.foreground || !this.isPollingWanted) {
      return;
    }
    // 空闲超过阈值就不排下一拍：等 touchActivity 再叫醒（见 THREAD_IDLE_STOP_MS）。
    if (Date.now() - this.lastActivityMs > THREAD_IDLE_STOP_MS) {
      hilog.info(DOMAIN, TAG, 'poll paused: idle %{public}dms',
        Date.now() - this.lastActivityMs);
      return;
    }
    const delay: number = this.nextDelay();
    this.pollTimer = setTimeout((): void => {
      this.pollTimer = -1;
      this.pollOnce();
      this.armTimer();
    }, delay);
  }

  /** 下一拍的间隔（毫秒）：突发窗口内 4~6 秒，否则 12~25 秒。 */
  private nextDelay(): number {
    const burst: boolean = this.burstUntilMs > Date.now();
    const min: number = burst ? THREAD_POLL_BURST_MIN_MS : THREAD_POLL_MIN_MS;
    const max: number = burst ? THREAD_POLL_BURST_MAX_MS : THREAD_POLL_MAX_MS;
    return min + Math.floor(Math.random() * (max - min + 1));
  }

  /**
   * 进后台就停、回前台立刻补一发。
   *
   * 后台里继续轮询，除了耗电与白白消耗 IG 的读写配额什么也换不到（界面根本看不见）；
   * 而回前台那一眼最需要的是"马上就是最新的"。
   */
  private hookVisibility(): void {
    if (this.visibilityHooked) {
      return;
    }
    this.visibilityHooked = true;
    AppLifecycle.addVisibilityListener((foreground: boolean): void => {
      this.foreground = foreground;
      if (!foreground) {
        if (this.pollTimer >= 0) {
          clearTimeout(this.pollTimer);
          this.pollTimer = -1;
        }
        return;
      }
      this.armTimer();
      this.pollOnce();
    });
  }

  /** 停止实时接收（页面销毁时调用）。 */
  stopPolling(): void {
    this.isPollingWanted = false;
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
    this.polling = false;
  }

  /** 一轮静默拉取（见 startPolling）。 */
  private pollOnce(): void {
    if (this.polling || this.threadId.length === 0) {
      return;
    }
    /*
     * **首屏都没读出来就别轮询**。
     *
     * 读失败时（IG 挡着 REST、又没有模板）每 4 秒还要发一发"必然失败"的请求，既浪费流量又
     * 让 IG 那边把这一串当成异常调用（越挡越死）。首屏失败时界面给的是「在网页中打开」，
     * 用户手动重进会重新走一遍完整的三条路。
     */
    if (this.view === null) {
      return;
    }
    /*
     * **刚拉过就别再来一发**（需求："加快进入会话获取消息的速度"）。
     *
     * 真机上看到的浪费：点开会话那一发 35KB 刚落定 1.6 秒，轮询第一拍就跟着又发了同样一发
     * （`burstUntilMs` 还在窗口里时，第一拍的间隔只有 4~6 秒）。两道闸：
     * 刚 `load()` 过 8 秒内不轮询；同一时刻只允许一发（`polling`）。
     */
    if (this.lastLoadAtMs > 0 && Date.now() - this.lastLoadAtMs < 8000) {
      return;
    }
    this.polling = true;
    // 轮询也是"给这条会话读的"：回来先核对（见 generation）。
    const wantThread: string = this.threadId;
    const wantGen: number = this.generation;
    NativeDirect.thread(wantThread, '', this.fallbackUserId)
      .then((fresh: DirectThreadView | null): void => {
      this.polling = false;
      if (this.isStale(wantGen, wantThread)) {
        // 会话已经换人了：这份是别人那一屏，丢掉（不并、不回调、不动 lastLoadAtMs）。
        hilog.info(DOMAIN, TAG, 'poll dropped: thread switched');
        return;
      }
      if (fresh === null || this.view === null) {
        return;
      }
      /*
       * **只追加没见过的新消息，绝不整份替换**（见 mergeFresh）。
       *
       * 这里原来是 `this.view = fresh`（觉得"新那份是权威的"）—— 但 REST 那条只回**最新一页**，
       * 于是上拉取回来的历史会被整段丢掉：用户继续上滑就看到"页面被重置、历史消息消失"。
       * 顺带也是那句"发新消息后页面会刷新导致动画又播放一遍"的同一个病根：
       * 整表被换掉 → 每行的 `ForEach` 键都变 → 全屏气泡重建重播。
       */
      const added: number = this.mergeFresh(fresh);
      if (added === 0) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'poll: +%{public}d messages (total=%{public}d)',
        added, this.view === null ? -1 : this.view.messages.length);
      // mergeFresh 里已经 onView + dropConfirmedPending（同帧撤乐观气泡）。
      if (this.onNew !== undefined) {
        this.onNew();
      }
    }).catch((): void => {
      this.polling = false;
    });
  }
}
