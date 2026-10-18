/*
 * 一条私信会话（会话详情）的视图模型。
 *
 * ## 和 DirectViewModel 的分工
 *   DirectViewModel  = 收件箱（会话列表，回放存下来的 GraphQL 模板，见 core/NativeDirect）；
 *   这个              = **一条会话的消息**，走私有 REST `GET /api/v1/direct_v2/threads/{id}/`，
 *                       外加**发送**（`POST …/broadcast/text/`）。
 *
 * ## 为什么详情走 REST 而不是回放 GraphQL
 * 会话详情那条 GraphQL 查询在原生侧**不一定有模板**（要先让隐藏网页打开一次会话才能抓到），
 * 而 REST 这条路一条请求就能读、形状也固定（`thread.items[]`）—— 少一次"必须让网页活着"的
 * 依赖，正好是这次要把私信整体搬到 HTTP 上的原因。
 *
 * ## 取数顺序（和收件箱对齐，见 DirectViewModel）
 *   ① 原生 REST `GET /api/v1/direct_v2/threads/{id}/`（安卓身份）；
 *   ② REST 被 IG 挡了（真机实测 404 + `not-logged-in`）→ 原生回放**会话模板**
 *      （`NativeDirect.threadViaTemplate`，模板 body 里的会话 id 换成目标 id）；
 *   ③ 连模板都没有 → 冷启动：让常驻网页真打开一次 `/direct/t/{id}/`，页面自己会发那条
 *      `PolarisDirect*Thread*` 查询，网络钩子把模板交给原生存住（capture），**再回到 ②**。
 *
 * ## 状态
 * 只留一条会话的状态：进哪条就读哪条（`open()`），读到的消息**按时间正序**（老的在前），
 * 界面往下排。发送用**乐观**策略：先把气泡画出来（sending），成功了用服务端那条替换，
 * 失败就标红并允许重发 —— 不这么做的话，网络抖一下用户看到的就是"点了发送没反应"。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { ApiRegistry } from '../bridge/ApiRegistry';
import { directThreadProbeScript } from '../bridge/WebScripts';
import { AppConfig } from '../config/AppConfig';
import { directScrollUpScript } from '../bridge/WebScripts';
import { NativeDirect } from '../core/NativeDirect';
import { DirectCache } from '../core/DirectCache';
// 进会话就把它标成已读（见 markThreadSeen）。
import { MobileDirect } from '../core/mobileapi/MobileDirect';
import { DirectMessage, DirectThreadView } from '../model/Direct';
import { AppLifecycle } from '../core/AppLifecycle';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectThreadViewModel';
/**
 * 会话页**可见时**的轮询间隔（毫秒）。
 *
 * 为什么是 2.5 秒：IG 的真正实时通道是 MQTT（MQTToT），但真机实测当前运行时的
 * `TLSSocket` **收不到任何数据**（同样代码走明文 TCP 收得到，见 core/mobileapi/NetProbe
 * 的 ①②③ 三组对照），所以 MQTT 这条路暂时不可用。退一步用"够快的轮询"做**近实时**：
 * 2.5 秒一轮 ≈ 对方发完就能看到；而这条 REST 一次往返只有几十 KB、几百毫秒，
 * 只在**会话页开着**时才跑（进后台就停，见 hookVisibility），代价可控。
 */
const THREAD_POLL_MS: number = 2500;
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
 * 翻页"卡住"（去重后没多出任何一条）之后的冷却：这段时间内不再翻，过了允许再试一次。
 *
 * 为什么要它：这条查询的分页参数在真机上本来就不认（详见 NativeDirect 里的说明），一次卡住就把
 * `hasOlder` 永久置 false 的话，用户再也翻不动、也没有重试入口（审计 C3）。给个 30 秒的冷却，
 * 服务端一旦恢复可用，用户继续上拉就能自己接上。
 */
const LOAD_OLDER_RETRY_GAP_MS: number = 30000;
/**
 * 冷启动抓模板用的片段：**空串 = 全抓**。
 *
 * 收件箱那边能用 `'Direct'` 过滤，是因为那条查询的名字已知（`PolarisDirectInboxMobileQuery`）。
 * 会话详情这条的名字不知道（试过 `PolarisDirect…Thread…`、`useIGD…` 都不对，见
 * NativeDirect.threadOps），所以干脆全抓，再按"像会话的候选名"逐个回放 —— 全抓的代价只是
 * 多存几份模板（预置那份本来就是 30 份）。
 */
const CAPTURE_FILTER: string = '';
/** 冷启动那次：先等页面水合多久再抓第一次。 */
const HYDRATE_WAIT_MS: number = 1800;
/** 抓模板的轮询次数与间隔（页面水合慢时那条查询发得晚，抓一次往往抓不到）。 */
const CAPTURE_POLLS: number = 8;
const CAPTURE_POLL_GAP_MS: number = 1500;
/** 导航到会话页的等待上限。 */
const NAV_READY_TIMEOUT_MS: number = 20000;

export class DirectThreadViewModel {
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private readonly registry: ApiRegistry = ApiRegistry.getInstance();
  /** 这一轮是不是走了"网页抓会话模板"那条冷路（界面据此提示，见 load）。 */
  private usedColdPath: boolean = false;
  /** 当前会话 id（空 = 还没选会话）。 */
  private threadId: string = '';
  /** 收件箱里那一行的标题（读消息之前先拿它当标题，读到了再用真名覆盖）。 */
  private fallbackTitle: string = '';
  /** 清空自己（退出登录 / 换账号时调）：会话内容与待发消息一起丢掉。 */
  reset(): void {
    this.view = null;
    this.pending = [];
    this.busy = false;
    this.threadId = '';
    this.onView(null);
    this.onPending(this.pending);
  }

  private view: DirectThreadView | null = null;
  /** 已经报过"已读"的那条（`threadId:messageId`，见 markThreadSeen）。 */
  private seenSentFor: string = '';
  /** "这条会话已在服务端标成已读" → 收件箱列表把它的未读标记清掉（见 pages/Index 的接线）。 */
  onSeen: (threadId: string) => void = (threadId: string): void => {
  };
  private busy: boolean = false;
  private sending: boolean = false;
  private diag: string = '-';
  /** 乐观发送的临时消息（本地 id → 文本），成功/失败后清掉。 */
  private pending: Array<DirectMessage> = [];
  /** 实时接收的计时器（见 startPolling / stopPolling）。 */
  private pollTimer: number = -1;
  /** 一轮轮询正在跑（防重入）。 */
  private polling: boolean = false;
  /** 应用是否在前台（后台时暂停轮询，见 hookVisibility）。 */
  private foreground: boolean = true;
  /** 前后台监听是否已挂（幂等）。 */
  private visibilityHooked: boolean = false;
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
   */
  open(threadId: string, title: string, avatar: string = '', isGroup: boolean = false,
       userId: string = '', username: string = ''): void {
    this.threadId = threadId;
    this.fallbackTitle = title;
    this.fallbackAvatar = avatar;
    this.fallbackGroup = isGroup;
    this.fallbackUserId = userId;
    this.fallbackUsername = username;
    this.view = null;
    /*
     * **先用预取的文本快照把这一屏铺上**（用户："点进去覆盖并触发刷新获取一页历史消息"）。
     *
     * 为什么放在这里（而不是等 `load()`）：`open()` 是点开的那一刻，页面第一帧就用这份数据画 ——
     * 预取读回来的 5 条文本立刻就位（媒体位置画占位），随后 `load()` 那一发刷新再补齐媒体、
     * 并在"没有新消息"时**保持画面不跳**（见 DirectCache.mergeMedia）。
     * 快照里不存头像（见 DirectCache 文件头），所以头像用收件箱那一行带过来的。
     */
    const cached: DirectThreadView | null = DirectCache.viewOf(threadId, avatar);
    if (cached !== null) {
      this.view = cached;
      this.onView(cached);
      hilog.info(DOMAIN, TAG, 'first paint from cache id=%{public}s msgs=%{public}d',
        threadId, cached.messages.length);
    }
    this.onView(this.view);
    this.diag = '-';
    this.usedColdPath = false;
    this.pending = [];
    this.onPending(this.pending);
  }

  viewNow(): DirectThreadView | null {
    return this.view;
  }

  pendingNow(): Array<DirectMessage> {
    return this.pending;
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

  /** 读这一条会话的最新一屏消息。 */
  async load(): Promise<void> {
    if (this.busy || this.threadId.length === 0) {
      return;
    }
    this.busy = true;
    this.onBusy(true);
    try {
      let view: DirectThreadView | null =
        await NativeDirect.thread(this.threadId, '', this.fallbackUserId);
      if (view === null) {
        /*
         * 原生那两条都不通（REST 被 IG 回 404 not-logged-in、原生侧又没有**会话模板**）→
         * 让常驻网页真开一次这条会话，页面自己会发那条 `PolarisDirect*Thread*` 查询，
         * 网络钩子把模板交给原生存住，然后再走一次原生（见 ensureTemplate）。
         *
         * 这就是用户报的"打开会话显示 404 / 加载错误"的那条兜底：模板一旦抓下来，
         * 之后每次进会话都是原生直发，不再依赖网页。
         */
        this.diag = NativeDirect.lastDetail();
        hilog.info(DOMAIN, TAG, 'load cold path: native failed (%{public}s), capture template',
          this.diag);
        const captured: boolean = await this.ensureTemplate(true);
        if (captured) {
          view = await NativeDirect.thread(this.threadId, '', this.fallbackUserId);
        }
      }
      if (view === null) {
        this.diag = NativeDirect.lastDetail();
        // 网络那一发没成：**手里有快照就继续用**（总比把预取好的内容换成"读取失败"强）。
        if (this.view !== null && this.view.messages.length > 0) {
          hilog.info(DOMAIN, TAG, 'load failed but cache shown id=%{public}s why=%{public}s',
            this.threadId, this.diag);
          this.onStatus('已加载（离线快照）');
          return;
        }
        this.onStatus('读取失败：' + this.diag);
        return;
      }
      /*
       * **"无新消息就直接覆盖会话消息"**（用户要求）+ 媒体补齐。
       *
       * 判据是"最新一条的 id 有没有变"：
       *   · 没变 → 画面**保持快照的样子**（不跳），只把这一页里同 id 消息的媒体地址填进去
       *     （占位换成真图/封面）；这就是"没有新消息时以快照为准"。
       *   · 变了 → 直接显示新读到的那一页（新消息必须在场）。
       * 无论哪一支，都把这一页**写回快照**（下一轮预取/下次点开就有更新的文本了）。
       */
      const cached: DirectThreadView | null = DirectCache.viewOf(this.threadId, this.fallbackAvatar);
      let shown: DirectThreadView = view;
      if (cached !== null && cached.messages.length > 0) {
        const cachedNewest: DirectMessage = cached.messages[cached.messages.length - 1];
        const freshNewest: DirectMessage = view.messages[view.messages.length - 1];
        const same: boolean = cachedNewest.id.length > 0 && cachedNewest.id === freshNewest.id;
        if (same) {
          shown = new DirectThreadView(view.id, view.title, view.withUsername, view.withAvatar,
            view.withId, DirectCache.mergeMedia(cached, view), view.hasOlder, view.oldestCursor,
            view.isGroup, view.withFullName);
          hilog.info(DOMAIN, TAG, 'no new message → keep cache paint msgs=%{public}d',
            shown.messages.length);
        } else {
          hilog.info(DOMAIN, TAG, 'new messages cached=%{public}s fresh=%{public}s',
            cachedNewest.id, freshNewest.id);
        }
      }
      DirectCache.save(shown.messages.length > 0 ? shown : view);
      this.view = shown;
      this.onView(shown);
      this.onStatus(shown.messages.length > 0
        ? (this.usedColdPath ? '已加载（首次走网页抓接口）' : '已加载') : '');
      /*
       * **进会话就算看过了**：照 instagrapi 的 `direct_send_seen` 把这条会话标成已读
       * （`direct_v2/threads/{id}/items/{最新消息id}/seen/`，见 MobileDirect.markSeen）。
       *
       * 不标的话 IG 那边一直记着"没看"，下次刷收件箱又会把这条画成未读
       * —— 用户报的"已读私信全变成未读"有一半是这个原因。
       * 发完就刷新收件箱（列表里的粗体/蓝点跟着消失）。
       */
      this.markThreadSeen(shown);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
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
      if (ok) {
        this.onSeen(view.id);
      }
    }).catch((): void => {
    });
  }

  /**
   * 确保**会话（消息）那条模板**在原生侧；没有就让常驻网页打开一次这条会话。
   *
   * 和 DirectViewModel.ensureTemplate 是同一套路数（收件箱那条就是这么救回来的），
   * 区别只在要抓的是**会话详情**那条查询、导航的是 `/direct/t/{id}/`。
   *
   * @param force true = 即使原生模板还在也去网页抓一次（这里用不上，留给以后诊断）。
   */
  private async ensureTemplate(force: boolean = false): Promise<boolean> {
    this.usedColdPath = false;
    if (!force && NativeDirect.hasThreadTemplate()) {
      return true;
    }
    this.onStatus('首次加载：正在读取网页');
    this.bridge.loadUrl(this.webUrl());
    // 标记立刻立起来：无论抓没抓到模板，收尾都要把网页送回首页（这个网页全 App 共用）。
    this.usedColdPath = true;
    await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    await DirectThreadViewModel.sleep(HYDRATE_WAIT_MS);
    // 诊断：页面自己能不能读到这条会话（见 directThreadProbeScript 的说明）。
    try {
      const probe: string = await this.bridge.runBridge(
        directThreadProbeScript(this.threadId), 15000, 'dm-thread-probe');
      hilog.info(DOMAIN, TAG, 'thread probe %{public}s', probe.substring(0, 600));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'thread probe threw: %{public}s', (error as Error).message);
    }
    for (let attempt: number = 1; attempt <= CAPTURE_POLLS; attempt++) {
      await this.registry.capture(CAPTURE_FILTER);
      /*
       * 诊断：把**刚刚更新过**的模板名列出来。
       *
       * 会话页到底发的是哪条查询，光看"有没有名字带 thread 的模板"判断不出来（IG 这版会话页
       * 是 Bloks 渲染的，可能压根不发单独的消息查询）。这里按更新时间筛，一眼就能看到页面
       * 实际发了什么 —— 真机排查时就是靠它定方向的。
       */
      hilog.info(DOMAIN, TAG, 'cold path recent try=%{public}d %{public}s',
        attempt, this.registry.recentNames(30000).join('|'));
      if (NativeDirect.hasThreadTemplate()) {
        hilog.info(DOMAIN, TAG, 'cold path thread template ready try=%{public}d op=%{public}s',
          attempt, NativeDirect.threadOp());
        this.returnToFeed();
        return true;
      }
      if (attempt < CAPTURE_POLLS) {
        await DirectThreadViewModel.sleep(CAPTURE_POLL_GAP_MS);
      }
    }
    hilog.info(DOMAIN, TAG, 'cold path no thread template %{public}s',
      this.registry.storedSummary());
    this.returnToFeed();
    return false;
  }

  /** 冷启动那条路读完，把网页送回首页信息流（理由同 DirectViewModel.returnToFeed）。 */
  private returnToFeed(): void {
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      hilog.info(DOMAIN, TAG, 'cold path done → back to feed');
    } catch (error) {
    }
  }

  /**
   * **翻页游标探针**（诊断用）：让隐藏网页自己把会话往上滚一屏，再抓一次模板。
   *
   * 为什么必须让页面自己翻：`min_uq_seq_id` 该填什么，只有页面翻页时发出的那条请求能说清
   * （我们的 `end_cursor` / `mid.$…` 都被 IG 忽略，回同一页 —— 真机日志 `loadOlder: +0`）。
   * 流程：导航到这条会话 → 抓一次（打一份变量基线）→ 注入"往上滚一屏" → 等它自己发请求
   * → 再抓一次 → 打变量。两步的 `min_uq_seq_id` 一对比就知道该填什么。
   */
  async probePagingCursor(): Promise<void> {
    if (this.threadId.length === 0) {
      return;
    }
    try {
      this.bridge.loadUrl(this.webUrl());
      await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
      await DirectThreadViewModel.sleep(HYDRATE_WAIT_MS);
      await this.registry.capture('');
      NativeDirect.logThreadVars('before-scroll');
      const scrolled: string = await this.bridge.runBridge(directScrollUpScript(), 10000, 'dm-scroll');
      hilog.info(DOMAIN, TAG, 'paging probe scroll=%{public}s', scrolled.substring(0, 200));
      await DirectThreadViewModel.sleep(2500);
      await this.registry.capture('');
      NativeDirect.logThreadVars('after-scroll');
      /*
       * **关键证据**：刚被页面更新过的那几条模板名。
       *
       * 会话历史是靠哪条请求翻的，看这一行就知道 —— 如果新出现的不是 IGDThreadDetailQuery，
       * 那就说明网页翻历史走的是另一条查询，我们一直往 min_uq_seq_id 里塞游标自然无效。
       */
      hilog.info(DOMAIN, TAG, 'paging probe recent=%{public}s',
        this.registry.recentNames(20000).join('|'));
      this.returnToFeed();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'paging probe threw: %{public}s', (error as Error).message);
    }
  }

  /** 翻页"卡住"之后的冷却截止时刻（见 loadOlder 里 stuck 那段）。 */
  private stuckUntilMs: number = 0;

  /** 这条会话的网页地址（冷启动抓模板导航用；读不出来时界面拿它回落网页，见 DirectThreadPage）。 */
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
    hilog.info(DOMAIN, TAG, 'send ui entry len=%{public}d thread=%{public}s busy=%{public}s',
      body.length, this.threadId, `${this.sending}`);
    if (body.length === 0 || this.threadId.length === 0 || this.sending) {
      hilog.warn(DOMAIN, TAG, 'send ui blocked: len=%{public}d thread=%{public}d busy=%{public}s',
        body.length, this.threadId.length, `${this.sending}`);
      return false;
    }
    this.sending = true;
    this.onBusy(true);
    const temp: DirectMessage = new DirectMessage(`local-${Date.now()}`, '', true, Date.now(),
      'text', body);
    this.pending = this.pending.concat([temp]);
    this.onPending(this.pending);
    try {
      const ok: boolean = await NativeDirect.sendText(this.threadId, body);
      if (!ok) {
        /*
         * 失败原因分两类说清楚：
         *   · `challenge_required`：账号被要求**安全验证**（写接口全被拒，重试无用）——
         *     让用户去首页横幅点「去验证」；真机实测发消息失败正是这个
         *     （响应体 `{"message":"challenge_required", … "lock":true}`）。
         *   · 其它：原样带上 detail（如 `send-1545023:…`），便于定位。
         */
        const why: string = NativeDirect.lastDetail();
        this.onStatus(why === 'challenge_required'
          ? '账号被要求安全验证：去首页点「去验证」之后再试'
          : '发送失败：' + why);
        return false;
      }
      this.onStatus('');
      /*
       * **先拉一次把服务端那条拿到手，再撤掉乐观气泡。**
       *
       * 早先是"先 `pending = []` 再 `load()`"：中间那 1~3 秒里刚发出去的那条会**凭空消失**，
       * 等刷新回来又出现 —— 用户报的"发出后消失再出现"就是这个闪烁。
       * 现在反过来：气泡一直留着，直到新视图里真的出现"我发的、同一条文本"才撤掉，
       * 视觉上是同一个气泡从"本地那条"无缝换成"服务端那条"。
       */
      await this.load();
      this.dropConfirmedPending();
      // 一次没对上（服务端还没返回）就过一会儿再看；这期间气泡继续留着，不会消失。
      setTimeout((): void => {
        this.dropConfirmedPending();
      }, PENDING_RECHECK_MS);
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'send threw: %{public}s', (error as Error).message);
      this.onStatus('发送出错');
      return false;
    } finally {
      this.sending = false;
      this.onBusy(false);
    }
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
      const hitId: string = DirectThreadViewModel.serverCopyOf(this.view, one, used);
      if (hitId.length > 0) {
        used.add(hitId);
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
    this.onBusy(true);
    try {
      const older: DirectThreadView | null =
        await NativeDirect.thread(this.threadId, this.view.oldestCursor, this.fallbackUserId);
      if (older === null) {
        // 翻页请求失败也要留痕：没有这行日志时，"没触发"和"请求了但被拒"分不清。
        hilog.warn(DOMAIN, TAG, 'loadOlder failed detail=%{public}s cursor=%{public}d',
          NativeDirect.lastDetail(), this.view.oldestCursor.length);
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
      this.busy = false;
      this.onBusy(false);
    }
  }

  // ==========================================================================
  // 实时接收（轮询那条会话）
  // ==========================================================================

  /**
   * 开始**实时接收**：每 `THREAD_POLL_MS` 静默拉一次这条会话，有新消息就回调。
   *
   * 为什么用轮询而不是长连接：IG 的实时通道是 MQTT（`edge-mqtt`），要在 App 里再实现一套
   * 连接/心跳/重连，代价远大于收益；而这条 REST 一次往返只有几十 KB、实测几百毫秒，
   * 4 秒一轮对"聊天"这个场景完全够（对方发来的消息最迟 4 秒上屏）。
   *
   * 三个讲究：
   *   1. **静默**：不碰 `busy` / 不写状态行 / 不发 `onBusy`，免得把界面刷成"正在加载"；
   *   2. **只认新 id**：把拉到的消息与现有那份按 id 合并，`onNew` 只在**真的有新消息**时回调
   *      （界面据此决定要不要贴到底部）；
   *   3. **幂等**：重复调用只保留一个计时器。
   */
  startPolling(onNew: () => void): void {
    this.onNew = onNew;
    this.hookVisibility();
    if (this.pollTimer >= 0) {
      return;
    }
    this.armTimer();
  }

  /** 按当前间隔重新挂定时器（见 THREAD_POLL_MS 的说明）。 */
  private armTimer(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
    }
    this.pollTimer = setInterval((): void => {
      this.pollOnce();
    }, THREAD_POLL_MS);
  }

  /**
   * 进后台就停、回前台立刻补一发。
   *
   * 后台里继续每 2.5 秒发一发请求，除了耗电与白白消耗 IG 的读写配额，什么也换不到
   * （界面根本看不见）；而回前台那一眼最需要的是"马上就是最新的"。
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
          clearInterval(this.pollTimer);
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
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
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
    this.polling = true;
    NativeDirect.thread(this.threadId, '', this.fallbackUserId)
      .then((fresh: DirectThreadView | null): void => {
      this.polling = false;
      if (fresh === null || this.view === null) {
        return;
      }
      const known: Array<string> = [];
      for (let index: number = 0; index < this.view.messages.length; index++) {
        known.push(this.view.messages[index].id);
      }
      let added: number = 0;
      for (let index: number = 0; index < fresh.messages.length; index++) {
        if (known.indexOf(fresh.messages[index].id) < 0) {
          added++;
        }
      }
      /*
       * **只追加没见过的新消息，绝不整份替换。**
       *
       * 这里原来是 `this.view = fresh`（觉得"新那份是权威的"）—— 但 REST 那条只回**最新一页**，
       * 于是下拉刷新取回来的历史会被整段丢掉：用户继续上滑就看到"页面被重置、历史消息消失"。
       * 同时**保留旧的 hasOlder / oldestCursor**：那个游标对应"我们手上最老那条"，
       * 换成最新页的游标会让下一次下拉把已经有的消息再取一遍（下拉看着没反应）。
       */
      if (added === 0) {
        return;
      }
      const merged: Array<DirectMessage> = this.view.messages.slice(0);
      for (let index: number = 0; index < fresh.messages.length; index++) {
        const one: DirectMessage = fresh.messages[index];
        if (known.indexOf(one.id) < 0) {
          merged.push(one);
        }
      }
      merged.sort((a: DirectMessage, b: DirectMessage): number => a.tsMs - b.tsMs);
      this.view = new DirectThreadView(this.view.id, this.view.title, this.view.withUsername,
        this.view.withAvatar, this.view.withId, merged, this.view.hasOlder,
        this.view.oldestCursor, this.view.isGroup, this.view.withFullName);
      hilog.info(DOMAIN, TAG, 'poll: +%{public}d messages (total=%{public}d)',
        added, merged.length);
      this.onView(this.view);
      /*
       * 轮询也顺手做一次"确认撤销"：自己发出去的那条，服务端回来后由这里换成真身
       * （见 dropConfirmedPending 与 send 里的说明）。放在 onNew 之前，
       * 这样界面一次性拿到的是"气泡已撤、真身已到"的最终状态，不会多闪一帧。
       */
      this.dropConfirmedPending();
      if (this.onNew !== undefined) {
        this.onNew();
      }
    }).catch((): void => {
      this.polling = false;
    });
  }
}
