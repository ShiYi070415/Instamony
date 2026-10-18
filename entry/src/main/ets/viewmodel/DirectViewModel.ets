/*
 * 私信（收件箱）的视图模型。
 *
 * ⚠️ 本文件是从**编译缓存里的转译产物**重建的（磁盘上那份被一次编码错误的批处理写坏，
 *    中文变乱码且换行被吞）。内容与最后一次成功构建一致，只还原了 import 写法与缩进。
 *    以后改这个文件请只用文件工具，不要用 PowerShell 的 Get-Content/Set-Content 管道。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { ApiRegistry } from '../bridge/ApiRegistry';
import { directInboxScript } from '../bridge/WebScripts';
import { AppConfig } from '../config/AppConfig';
import { NativeDirect } from '../core/NativeDirect';
import { DirectPrefetch } from '../core/DirectPrefetch';
// 新私信的本地通知（见 core/PushCenter）。
import { PushCenter } from '../core/PushCenter';
import { DirectThreadViewModel } from './DirectThreadViewModel';
import { DirectMapper } from '../model/Direct';
import { DirectInboxPage, DirectMessage, DirectThread, DirectThreadView } from '../model/Direct';
const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectViewModel';
/** 收件箱那条查询的操作名（回放时按名字取模板）。 */
const OP_INBOX: string = 'PolarisDirectInboxMobileQuery';
/** 冷启动抓模板用的片段（把私信相关的几条一起抓下来）。 */
const CAPTURE_FILTER: string = 'Direct';
/** 冷启动那次：先等页面水合多久再抓第一次。 */
const HYDRATE_WAIT_MS: number = 1800;
/** 抓模板的轮询次数与间隔（页面水合慢时那几条查询发得晚，抓一次往往抓不到）。 */
const CAPTURE_POLLS: number = 8;
const CAPTURE_POLL_GAP_MS: number = 1500;
/** 单次回放的上限。 */
const EXTRACT_TIMEOUT_MS: number = 8000;
const EXTRACT_ATTEMPTS: number = 4;
const EXTRACT_RETRY_GAP_MS: number = 2500;
/** 导航到私信页的等待上限。 */
const NAV_READY_TIMEOUT_MS: number = 20000;
/**
 * **发送握手自检**开关（排查用，见 NativeDirect.probeSendShape）。
 *
 * 已经跑过一次、结论也拿到了（网页 UA 被拒、安卓 UA 通过，见 NativeDirect.sendText 的说明），
 * 所以这里关掉 —— 打开时每次进程都会往 IG 打 4 个"必然失败"的写请求，没必要留着。
 * 以后再需要诊断时改回 true 即可。
 */
const SEND_SELFTEST: boolean = false;
/**
 * **空文本发送探针**开关（诊断用，见 NativeDirect.probeSendEmptyText）。
 *
 * 已经跑过（结论：身份过了，IG 进到 `item_ack` 才回 403 + error_code 1545023 —— 不再有
 * `useragent mismatch`），所以关掉，别每次开 App 都打一发。再要诊断时改回 true。
 */
const SEND_EMPTY_PROBE: boolean = false;
/** 自检只跑一次（进程内）。 */
let sendSelfTestDone: boolean = false;
/**
 * **会话详情自检开关**（诊断用，见 selfTestThread）。
 *
 * 打开时每次启动会多打两条请求（收件箱一页 + 一条会话）。排查"打开会话读不出来"时用它
 * 一遍启动就能拿到结论（会话详情那条链就是这么调通的）；**平时关着**，别每次启动都去碰
 * 私信接口。
 */
const SELF_TEST_THREAD: boolean = false;
/** 会话自检只跑一次（进程内）。 */
let threadSelfTestDone: boolean = false;
/** 空文本探针只跑一次（进程内）。 */
let sendEmptyProbeDone: boolean = false;
export class DirectViewModel {
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private readonly registry: ApiRegistry = ApiRegistry.getInstance();
  /** 清空自己（退出登录 / 换账号时调，见 ReelsViewModel.reset 的说明）。 */
  reset(): void {
    this.threads = [];
    this.endCursor = '';
    this.more = false;
    this.busy = false;
    this.loadedAtMs = 0;
    this.diag = '-';
  }

  private threads: Array<DirectThread> = [];
  private endCursor: string = '';
  private more: boolean = false;
  private busy: boolean = false;
  private usedColdPath: boolean = false;
  /**
   * 上次**成功**拉到收件箱的时刻（毫秒；0 = 还没拉到过）。
   *
   * 用途：feeds 页会提前把收件箱预热好（见 Index.warmOtherTabs 的 direct 那一步），
   * 用户切到私信页时 `DirectPage.aboutToAppear` 就能靠它判断"这份数据还新鲜，别再拉一次"——
   * 否则预热白做，用户还是要等一次网络往返（用户报的"私信列表加载慢"）。
   */
  private loadedAtMs: number = 0;
  /** 最近一次失败的原样回报（截断），失败提示里带上它 —— 界面就是排查通道。 */
  private diag: string = '-';
  onThreads: (threads: Array<DirectThread>, hasMore: boolean) => void = (threads: Array<DirectThread>, hasMore: boolean): void => {
  };
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
  };
  onStatus: (text: string) => void = (text: string): void => {
  };
  list(): Array<DirectThread> {
    return this.threads;
  }
  isBusy(): boolean {
    return this.busy;
  }
  hasMore(): boolean {
    return this.more;
  }

  /**
   * 手上这份列表还"新鲜"吗（`maxAgeMs` 之内拉到的，且确实有内容）。
   *
   * 给 `DirectPage.aboutToAppear` 用：新鲜就不要立刻再拉一次（预热来的数据直接显示），
   * 用户下拉刷新那条路（`load(true)`）不受影响。
   */
  isFresh(maxAgeMs: number): boolean {
    if (this.loadedAtMs <= 0 || this.threads.length === 0) {
      return false;
    }
    return Date.now() - this.loadedAtMs <= maxAgeMs;
  }
  /** 拉一次（refresh=true 时丢掉游标从头拉）。 */
  /**
   * 这条会话已经看过了：把本地列表那一行的未读标记清掉（粗体 + 右侧蓝点跟着消失）。
   *
   * 由 `DirectThreadViewModel.onSeen` 在服务端 `mark_seen` 成功之后回调（见 pages/Index）。
   */
  markThreadRead(threadId: string): void {
    let changed: boolean = false;
    const next: Array<DirectThread> = [];
    for (let index: number = 0; index < this.threads.length; index++) {
      const one: DirectThread = this.threads[index];
      if (one.id !== threadId || (!one.unread && one.unreadCount === 0)) {
        next.push(one);
        continue;
      }
      next.push(new DirectThread(one.id, one.key, one.title, one.avatarUrl, one.isGroup,
        false, one.muted, one.pinned, one.tsMs, one.text, one.kind, one.username, 0));
      changed = true;
    }
    if (!changed) {
      return;
    }
    this.threads = next;
    this.onThreads(next, this.more);
    hilog.info(DOMAIN, TAG, 'mark read thread=%{public}s', threadId);
  }

  /**
   * 这一页上未读的总条数（列表右侧那顆蓝点 / "n 条新消息"用的是同一条计数）。
   *
   * 没有 `unreadCount`（旧解析 / GraphQL 那条路）时按"未读 = 1 条"算，至少让通知有数。
   */
  static unreadTotal(threads: Array<DirectThread>): number {
    let total: number = 0;
    for (let index: number = 0; index < threads.length; index++) {
      const one: DirectThread = threads[index];
      if (!one.unread) {
        continue;
      }
      total += one.unreadCount > 0 ? one.unreadCount : 1;
    }
    return total;
  }

  async load(refresh: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    if (refresh) {
      this.endCursor = '';
      this.more = false;
    }
    this.busy = true;
    this.onBusy(true);
    try {
      const page: DirectInboxPage | null = await this.fetchInbox('');
      if (page === null) {
        this.onStatus('读取失败：' + this.diag);
        return;
      }
      this.threads = page.threads;
      this.endCursor = page.endCursor;
      // 没有游标就当到底了：触底哨兵只看 more，不看清游标，会让它一直空转。
      this.more = page.hasMore && page.endCursor.length > 0;
      this.loadedAtMs = Date.now();
      this.onThreads(this.threads, this.more);
      /*
       * **列表到手就开始预取会话消息**（用户："切换到私信列表时预取当前私信列表的所有会话消息，
       * 每个会话 5 条"＋"私信列表刷新时预取新刷新出来的会话"）。
       *
       * `seed` 自带增量语义（跳过队列里已有的、快照还新鲜的），所以这里不用区分
       * "首次加载 / 下拉刷新 / 触底翻页"——三种情况都调它，真正发请求的只有缺快照的那几条。
       */
      DirectPrefetch.seed(this.threads);
      /*
       * **有新私信就弹一条系统通知**（需求："把消息通知接入 push kit，包括通知页和私信"）。
       *
       * 远端推送要 AGC 后台发，客户端这边能保证的是：自己拉到了新的未读 → 用
       * NotificationKit 发一条本地通知（见 core/PushCenter）。只有未读数**变多**才弹，
       * 每次刷新都弹会吵死人。
       */
      PushCenter.noteUnread('direct', DirectViewModel.unreadTotal(this.threads));
      this.onStatus(this.usedColdPath ? '已加载（首次走网页抓接口）' : '已加载');
    }
    catch (error) {
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    }
    finally {
      // 走过冷启动就一定把网页送回首页（理由见 ProfileViewModel.returnToFeed）。
      if (this.usedColdPath) {
        this.returnToFeed();
      }
      this.busy = false;
      this.onBusy(false);
    }
  }
  /**
   * **会话详情自检**（诊断用，`SELF_TEST_THREAD` 为真时在启动预热里跑一次）。
   *
   * 为什么要它：会话详情那条路（抓模板 → 回放 → 解析）每一步都只能靠日志判断，而手动点开
   * 一条私信会话每轮都要人配合。这里让 App 自己在启动后拿收件箱第一行去读一次会话，
   * 把"读到了几条 / 失败在哪一步"打进日志 —— 一遍启动就有结论。
   */
  async selfTestThread(): Promise<void> {
    if (!SELF_TEST_THREAD || threadSelfTestDone) {
      return;
    }
    threadSelfTestDone = true;
    try {
      // 用**完整那条链**取收件箱（和用户点开私信页时一模一样，必要时会走网页冷启动抓模板）。
      const page: DirectInboxPage | null = await this.fetchInbox('');
      if (page === null || page.threads.length === 0) {
        hilog.warn(DOMAIN, TAG, 'selftest: no inbox (%{public}s / %{public}s)', this.diag, NativeDirect.lastDetail());
        return;
      }
      const one: DirectThread = page.threads[0];
      hilog.info(DOMAIN, TAG, 'selftest thread id=%{public}s key=%{public}s title=%{public}s', one.id, one.key, one.title);
      /*
       * **照用户那条路走一遍**：用 DirectThreadViewModel（回放模板 → 冷启动抓模板再回放）。
       * 直接调 NativeDirect.thread 的话会跳过"抓模板"那一步，而模板里带着**当时那一发的新鲜
       * 请求头**（`x-ig-www-claim` 这类会话级 hmac）—— 旧模板正是被 IG 回 1357004 的原因。
       */
      const vm: DirectThreadViewModel = new DirectThreadViewModel();
      vm.open(one.id, one.title, one.avatarUrl, one.isGroup, one.key, one.username);
      await vm.load();
      const view: DirectThreadView | null = vm.viewNow();
      if (view === null) {
        hilog.warn(DOMAIN, TAG, 'selftest FAIL detail=%{public}s', NativeDirect.lastDetail());
        return;
      }
      // 诊断：媒体消息抠到地址没有、这条会话都有哪些类型（见 DirectMapper 里 content 的读法）。
      let media: number = 0;
      const kinds: Array<string> = [];
      for (let index: number = 0; index < view.messages.length; index++) {
        const one: DirectMessage = view.messages[index];
        if (one.mediaUrl.length > 0) {
          media++;
        }
        if (kinds.indexOf(one.kind) < 0) {
          kinds.push(one.kind);
        }
      }
      hilog.info(DOMAIN, TAG, 'selftest OK msgs=%{public}d media=%{public}d kinds=%{public}s title=%{public}s with=%{public}s', view.messages.length, media, kinds.join(','), view.title, view.withUsername);
      /*
       * 顺手把"上拉加载更老"也验一发：能翻页的话条数会变多，翻不动就是同一页回来
       * （NativeDirect 那边会打 `cursor:set` / `cursor:none`）。
       */
      if (view.hasOlder && view.oldestCursor.length > 0) {
        const before: number = view.messages.length;
        await vm.loadOlder();
        const after: DirectThreadView | null = vm.viewNow();
        hilog.info(DOMAIN, TAG, 'selftest older before=%{public}d after=%{public}d', before, after === null ? -1 : after.messages.length);
      }
      else {
        hilog.info(DOMAIN, TAG, 'selftest no older hasOlder=%{public}s cursor=%{public}d', `${view.hasOlder}`, view.oldestCursor.length);
      }
      // 翻页游标探针：让网页自己滚一屏，看它给 min_uq_seq_id 填什么（见 probePagingCursor）。
      await vm.probePagingCursor();
      /*
       * **历史游标扫描**：`min_uq_seq_id` 到底吃什么值。
       *
       * 线索来自 MQTT setup 的响应：`iris_inactive_subscription_uq_seq_id` 是个**很小的数**
       * （542073），和我们试过的 19 位 id / 132 字符游标完全不是一个量级 —— 也许这个变量要的就是
       * 这种"小的序 id"（比它更老的先给）。这里拿几个候选依次试，只看**回来的条数和最老那条的时间**：
       * 窗口真的往前挪了，就说明找对形态了。
       */
      const cursors: Array<string> = ['542073', '542000', '500000', '100000', '1'];
      for (let ci: number = 0; ci < cursors.length; ci++) {
        const swept: DirectThreadView | null =
          await NativeDirect.thread(one.id, cursors[ci], one.key);
        if (swept === null) {
          hilog.warn(DOMAIN, TAG, 'cursor sweep %{public}s → null (%{public}s)',
            cursors[ci], NativeDirect.lastDetail());
          continue;
        }
        let oldestTs: number = -1;
        let oldestId: string = '-';
        if (swept.messages.length > 0) {
          oldestTs = swept.messages[0].tsMs;
          oldestId = swept.messages[0].id;
        }
        hilog.info(DOMAIN, TAG,
          'cursor sweep %{public}s → msgs=%{public}d oldestTs=%{public}d oldestId=%{public}s',
          cursors[ci], swept.messages.length, oldestTs, oldestId);
      }
    }
    catch (error) {
      hilog.warn(DOMAIN, TAG, 'selftest threw: %{public}s', (error as Error).message);
    }
  }
  /** 触底翻页：只改游标拉一页，不导航。 */
  async requestMore(): Promise<void> {
    if (this.busy || !this.more || this.endCursor.length === 0) {
      return;
    }
    this.busy = true;
    this.onBusy(true);
    try {
      // 翻页优先走 REST（GraphQL 那条模板没有分页变量，见 NativeDirect.inboxRest）。
      let page: DirectInboxPage | null = await NativeDirect.inboxRest(this.endCursor);
      if (page === null) {
        page = await this.fetchInbox(this.endCursor);
      }
      if (page === null || page.threads.length === 0) {
        this.more = false;
        this.onThreads(this.threads, this.more);
        return;
      }
      this.threads = this.threads.concat(page.threads);
      this.endCursor = page.endCursor;
      this.more = page.hasMore && page.endCursor.length > 0;
      this.onThreads(this.threads, this.more);
      // 翻页新出来的那批也交给预取（同上：只有缺快照的才会真发请求）。
      DirectPrefetch.seed(this.threads);
    }
    finally {
      this.busy = false;
      this.onBusy(false);
    }
  }
  /**
   * 取一页：**原生 HTTP 优先 → 冷启动抓模板后再试 → 实在不行才回放**（见文件头）。
   *
   * 为什么把原生放最前面：它不需要隐藏网页活着，也不受"页面还在水合、注入抢不到执行机会"
   * 那种抖动影响 —— 私信页因此不再出现"第 1/2/3/4 次未成"的等待。
   */
  private async fetchInbox(cursor: string): Promise<DirectInboxPage | null> {
    this.usedColdPath = false;
    /*
     * **REST 优先**（顺序对调过，见下）。
     *
     * 真机实测（`dm2.log`）：GraphQL 那条被 IG 回 `error:1357004`（423 字节的非 JSON），
     * 紧接着兜底链路的**注入脚本抛了 `Stack overflow!`** —— 于是 `load()` 直接进 catch，
     * 界面就是"加载错误"，而 REST 那条（已经带上"完整安卓身份 + 活会话兜底"，也是唯一
     * 真正能读私信的一条）**根本没轮到**。
     * REST 不需要模板、不需要隐藏网页、不需要跑脚本，所以把它放到第一位：
     * 通了就万事大吉，不通才回落到原来那套 GraphQL / 抓模板 / 回放。
     */
    const restPage: DirectInboxPage | null = await NativeDirect.inboxRest(cursor);
    if (restPage !== null) {
      this.diag = '-';
      return restPage;
    }
    this.diag = 'rest:' + NativeDirect.lastDetail();
    let page: DirectInboxPage | null = await NativeDirect.inbox(cursor);
    if (page !== null) {
      this.diag = '-';
      if (SEND_SELFTEST && !sendSelfTestDone) {
        sendSelfTestDone = true;
        hilog.info(DOMAIN, TAG, 'send self-test start');
        NativeDirect.probeSendShape().then((lines: string): void => {
          hilog.info(DOMAIN, TAG, 'send self-test done:\n%{public}s', lines);
        }).catch((): void => {
        });
      }
      if (SEND_EMPTY_PROBE && !sendEmptyProbeDone && page.threads.length > 0) {
        sendEmptyProbeDone = true;
        NativeDirect.probeSendEmptyText(page.threads[0].id).catch((): void => {
        });
      }
      return page;
    }
    this.diag = this.diag + ' native:' + NativeDirect.lastDetail();
    /*
     * **REST 兜底**（模拟器上就是这条救回来的）：私有 REST `/api/v1/direct_v2/inbox/` 只吃
     * Cookie + 会话头，不依赖那条 GraphQL 模板、也不依赖隐藏网页 —— 会话详情一路就是这么读的。
     * 放在"抓模板/回放"之前：那两条都要网页活着，而模拟器的网页这边被 IG 回了一页 423 字节
     * 的 HTML（`state:"non-json", http:200`），怎么重试都出不来。
     */
    page = await NativeDirect.inboxRest(cursor);
    if (page !== null) {
      this.diag = '-';
      return page;
    }
    this.diag = this.diag + ' rest:' + NativeDirect.lastDetail();
    // 原生两条（REST / GraphQL）都不通 → **强制**让网页真开一次私信页抓模板：
    // 后面那条"网页脚本/回放"要的是页面自己抓的 JSON，只有真浏览器跑一遍才会更新它
    // （见 ensureTemplate 的 force 说明）。
    const captured: boolean = await this.ensureTemplate(true);
    if (captured) {
      page = await NativeDirect.inbox(cursor);
      if (page !== null) {
        this.diag = '-';
        return page;
      }
      this.diag = 'native:' + NativeDirect.lastDetail();
    }
    // 最后兜底：走老的"回放"（模板送回网页里发一次）。
    const replayed: DirectInboxPage | null = await this.fetchWithRetry(cursor);
    if (replayed !== null) {
      this.diag = '-';
    }
    return replayed;
  }
  /**
   * 确保收件箱那条模板在原生侧；没有就让常驻网页打开一次 /direct/inbox/。
   *
   * @param force true = **即使原生模板还在，也去网页抓一次**。
   *   为什么要它：真机上 REST 被 IG 回 404/not-logged-in、原生 GraphQL 回 `1357004` 之后，
   *   最后那条"网页脚本/回放"需要的是**页面自己抓的那份 JSON**（`storedJson`），
   *   而它可能已经过期/为空 → 整条链就以 `读取失败: no-template` 收场。
   *   这时候强制 navigate 一次网页、让真实浏览器把模板重新抓下来，那条路才跑得动。
   */
  private async ensureTemplate(force: boolean = false): Promise<boolean> {
    this.usedColdPath = false;
    // ⚠️ 判据必须按**原生那条 TTL**（storedForNative，24 小时）算，不能按页面回放那条
    // （storedJson，10 分钟）—— 否则抓完模板过 10 分钟这里就认为"没有模板"，把已经能直发的
    // 情况又拖去导航一次网页（这个坑在「我的」四个分页上踩过，见 NativeProfile.hasTemplate）。
    if (!force && NativeDirect.hasInboxTemplate()) {
      return true;
    }
    this.onStatus('首次加载：正在读取网页');
    this.bridge.loadUrl(AppConfig.INSTAGRAM_DIRECT_URL);
    // 标记立刻立起来：无论后面抓没抓到模板，收尾都要把网页送回首页。
    this.usedColdPath = true;
    await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    await DirectViewModel.sleep(HYDRATE_WAIT_MS);
    for (let attempt: number = 1; attempt <= CAPTURE_POLLS; attempt++) {
      await this.registry.capture(CAPTURE_FILTER);
      if (NativeDirect.hasInboxTemplate()) {
        hilog.info(DOMAIN, TAG, 'cold path template ready try=%{public}d %{public}s', attempt, this.registry.storedSummary());
        return true;
      }
      if (attempt < CAPTURE_POLLS) {
        await DirectViewModel.sleep(CAPTURE_POLL_GAP_MS);
      }
    }
    hilog.info(DOMAIN, TAG, 'cold path no template %{public}s', this.registry.storedSummary());
    return false;
  }
  /** 冷启动那条路读完，把网页送回首页信息流（理由同 ProfileViewModel.returnToFeed）。 */
  private returnToFeed(): void {
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      hilog.info(DOMAIN, TAG, 'cold path done → back to feed');
    }
    catch (error) {
    }
  }
  /** 拉一页，失败自动重试（理由见文件头第 2 条）。 */
  private async fetchWithRetry(cursor: string): Promise<DirectInboxPage | null> {
    let page: DirectInboxPage | null = null;
    for (let attempt: number = 1; attempt <= EXTRACT_ATTEMPTS; attempt++) {
      page = await this.fetch(cursor, attempt);
      if (page !== null) {
        return page;
      }
      this.onStatus('第' + attempt + '次未成：' + this.diag);
      if (attempt < EXTRACT_ATTEMPTS) {
        await DirectViewModel.sleep(EXTRACT_RETRY_GAP_MS);
      }
    }
    return page;
  }
  private async fetch(cursor: string, attempt: number): Promise<DirectInboxPage | null> {
    const cfg: string = this.registry.storedJson(OP_INBOX);
    if (cfg.length === 0) {
      this.diag = 'no-template';
      return null;
    }
    // 只改游标，不碰 first（覆盖 first 会让 IG 的 GraphQL 回 noncoercible_variable_value，
    // 见 ProfileViewModel 里的说明）。第一页把 after 删掉（等同页面自己的首屏请求）。
    const vars: string = cursor.length > 0
      ? '{"after":' + JSON.stringify(cursor) + '}'
      : '{"after":null}';
    let raw: string = '';
    try {
      raw = await this.bridge.runBridge(directInboxScript(cfg, vars), EXTRACT_TIMEOUT_MS, 'direct-inbox');
    }
    catch (error) {
      this.diag = 'bridge:' + (error as Error).message;
      return null;
    }
    const page: DirectInboxPage | null = DirectMapper.inboxFromJson(raw);
    if (page === null) {
      this.diag = 'raw=' + raw.substring(0, 220);
      hilog.info(DOMAIN, TAG, 'inbox try=%{public}d failed raw=%{public}s', attempt, raw.substring(0, 500));
      return null;
    }
    hilog.info(DOMAIN, TAG, 'inbox ok try=%{public}d n=%{public}d more=%{public}s', attempt, page.threads.length, page.hasMore ? 'y' : 'n');
    return page;
  }
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
