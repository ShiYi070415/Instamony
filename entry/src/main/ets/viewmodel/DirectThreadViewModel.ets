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
import { DirectMessage, DirectThreadView } from '../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectThreadViewModel';
/** 实时接收的轮询间隔（毫秒，见 startPolling 里为什么用轮询）。 */
const THREAD_POLL_MS: number = 4000;
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
  private view: DirectThreadView | null = null;
  private busy: boolean = false;
  private sending: boolean = false;
  private diag: string = '-';
  /** 乐观发送的临时消息（本地 id → 文本），成功/失败后清掉。 */
  private pending: Array<DirectMessage> = [];
  /** 实时接收的计时器（见 startPolling / stopPolling）。 */
  private pollTimer: number = -1;
  /** 一轮轮询正在跑（防重入）。 */
  private polling: boolean = false;
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
    this.onView(null);
    this.diag = '-';
    this.usedColdPath = false;
    this.pending = [];
    this.onPending(this.pending);
  }

  currentThreadId(): string {
    return this.threadId;
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

  sendingNow(): boolean {
    return this.sending;
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
        this.onStatus('读取失败：' + this.diag);
        return;
      }
      this.view = view;
      this.onView(view);
      this.onStatus(view.messages.length > 0
        ? (this.usedColdPath ? '已加载（首次走网页抓接口）' : '已加载') : '');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
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
    if (body.length === 0 || this.threadId.length === 0 || this.sending) {
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
        this.onStatus('发送失败：' + NativeDirect.lastDetail());
        return false;
      }
      // 成功：把这条乐观气泡去掉，再拉一次（服务端那条就有真 id 与时间了）。
      this.pending = [];
      this.onPending(this.pending);
      this.onStatus('');
      await this.load();
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

  /** 取更老的一批消息（接到前面）。 */
  async loadOlder(): Promise<void> {
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
       * **没多出来任何一条就不再往下翻**：游标换不动时继续翻只会无限重复同一页。
       * 这样即使游标这条路暂时没打通，界面也只是"到头了"，不会再循环。
       */
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
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval((): void => {
      this.pollOnce();
    }, THREAD_POLL_MS);
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
      if (this.onNew !== undefined) {
        this.onNew();
      }
    }).catch((): void => {
      this.polling = false;
    });
  }
}
