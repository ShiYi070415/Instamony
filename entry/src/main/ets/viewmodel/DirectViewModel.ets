/*
 * 私信（收件箱）的视图模型。
 *
 * 取数只有一条链：`NativeDirect.inbox` → 移动端 `direct_v2/inbox/`（core/mobileapi/MobileDirect）。
 * 这里原来那条"冷启动抓模板 → 回放 → 网页脚本"的兜底已经删除（页面注入退役、模板也过期）。
 *
 * ⚠️ 本文件曾经被一次编码错误的批处理写坏过（中文变乱码、换行被吞），
 *    以后改这个文件请只用文件工具，不要用 PowerShell 的 Get-Content/Set-Content 管道。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeDirect } from '../core/NativeDirect';
// 新私信的本地通知（见 core/PushCenter）。
import { PushCenter } from '../core/PushCenter';
import { DirectMessage, DirectThread } from '../model/Direct';
import { DirectInboxPage } from '../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectViewModel';
/**
 * 只为"这么多毫秒以内"的消息弹通知（见 applyRealtimeMessage 的 fresh 闸）。
 *
 * 为什么需要：冷启动用落盘位点先订阅时，对端会把离线期间的补丁重放一遍；
 * 那些几分钟前的消息不该在启动瞬间"叮"一下。
 */
const NOTIFY_MAX_AGE_MS: number = 120000;

export class DirectViewModel {
  /** 清空自己（退出登录 / 换账号时调，见 ReelsViewModel.reset 的说明）。 */
  reset(): void {
    this.threads = [];
    this.endCursor = '';
    this.more = false;
    this.busy = false;
    // 排队中的刷新也要作废：它属于上一个账号。
    this.pendingLoad = false;
    this.loadedAtMs = 0;
    this.diag = '-';
    this.notifiedTs = new Map<string, number>();
  }

  private threads: Array<DirectThread> = [];
  private endCursor: string = '';
  private more: boolean = false;
  private busy: boolean = false;
  /**
   * 有一发"刷新"在飞的时候又来了刷新请求（见 load 的 busy 分支）。
   *
   * 只排一次：排队期间再来几下也只补跑一轮（连点下拉不该变成连发）。
   */
  private pendingLoad: boolean = false;
  /**
   * 每条会话"上次为它弹过通知"的那条消息的时间戳（会话 id → tsMs）。
   *
   * 见 applyRealtimeMessage / markNotified：未读条数封顶 4，只看总条数会漏判
   * "同一条会话继续来新消息"，于是出现"突然不弹通知"。
   */
  private notifiedTs: Map<string, number> = new Map<string, number>();
  /**
   * 上次**成功**拉到收件箱的时刻（毫秒；0 = 还没拉到过）。
   *
   * 用途：feeds 页会提前把收件箱预热好（见 Index.warmOtherTabs 的 direct 那一步），
   * 用户切到私信页时 `DirectPage.aboutToAppear` 就能靠它判断"这份数据还新鲜，别再拉一次"——
   * 否则预热白做，用户还是要等一次网络往返。
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

  /** 最近一次失败的原因（诊断）。 */
  diagNow(): string {
    return this.diag;
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

  /**
   * **静默刷新**（私信页轮询用，见 components/DirectPage 的轮询定时器）。
   *
   * 和 `load()` 的区别：不动状态行、不动骨架屏、不清游标 —— 只把"变了的那份列表"换上去。
   * 判"有没有变"用 `sameThreads`（id / 未读 / 条数 / 预览文字 / 时间），
   * 一样就直接返回，避免每 20 秒让整张列表重绘一次。
   *
   * @returns 这次有没有真的换过列表（只用于日志）
   */
  async refreshQuietly(): Promise<boolean> {
    if (this.busy || this.polling) {
      return false;
    }
    this.polling = true;
    try {
      const page: DirectInboxPage | null = await this.fetchInbox('');
      if (page === null) {
        return false;
      }
      if (DirectViewModel.sameThreads(this.threads, page.threads)) {
        return false;
      }
      this.threads = page.threads;
      this.endCursor = page.endCursor;
      this.more = page.hasMore && page.endCursor.length > 0;
      this.loadedAtMs = Date.now();
      this.onThreads(this.threads, this.more);
      hilog.info(DOMAIN, TAG, 'poll refresh n=%{public}d', this.threads.length);
      this.noteNewUnread();
      return true;
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'poll failed: %{public}s', (error as Error).message);
      return false;
    } finally {
      this.polling = false;
    }
  }

  /**
   * **把实时推来的一条私信直接落到列表那一行**（需求："私信列表接一下 MQTT 实时更新"）。
   *
   * 以前实时补丁只做一件事：触发一次收件箱 HTTP 刷新（30KB 起、还要排队）。
   * 现在能就地改：那一行的**摘要文字/时间/未读**按这条消息更新、并把该会话**置顶**，
   * 一次请求都不发。列表因此和会话页一样是"推过来的"。
   *
   * @param threadId 会话 id
   * @param message  推来的那条消息
   * @param readHere 这条消息此刻正在被读（会话页开着、并且已经插进去了）：
   *                 那就别加未读、别弹通知（否则用户正看着，通知栏还"叮"一下）。
   * @returns true = 这一行已经就地更新好；false = 列表里没有这条会话（新会话/还没加载到），
   *          调用方该退回"刷一次收件箱"。
   */
  applyRealtimeMessage(threadId: string, message: DirectMessage, readHere: boolean): boolean {
    if (threadId.length === 0) {
      return false;
    }
    let at: number = -1;
    for (let index: number = 0; index < this.threads.length; index++) {
      if (this.threads[index].id === threadId) {
        at = index;
        break;
      }
    }
    if (at < 0) {
      hilog.info(DOMAIN, TAG, 'realtime thread not in list id=%{public}d → 需要刷收件箱',
        threadId.length);
      return false;
    }
    const old: DirectThread = this.threads[at];
    /*
     * 补丁会重发、轮询也可能把同一条带回来：比这一行还旧的消息直接忽略
     * （但**算已处理**，不然调用方还要白刷一次收件箱）。
     */
    if (message.tsMs > 0 && old.tsMs > 0 && message.tsMs < old.tsMs) {
      hilog.info(DOMAIN, TAG, 'realtime stale message ts=%{public}d old=%{public}d',
        message.tsMs, old.tsMs);
      return true;
    }
    const unread: boolean = readHere || message.mine ? false : true;
    const unreadCount: number = readHere || message.mine
      ? 0 : Math.min(4, Math.max(1, old.unreadCount + 1));
    const updated: DirectThread = new DirectThread(old.id, old.key, old.title, old.avatarUrl,
      old.isGroup, unread, old.muted, old.pinned,
      message.tsMs > 0 ? message.tsMs : old.tsMs,
      message.text.length > 0 ? message.text : old.text,
      message.text.length > 0 ? message.kind : old.kind,
      old.username, unreadCount);
    const next: Array<DirectThread> = [updated];
    for (let index: number = 0; index < this.threads.length; index++) {
      if (index !== at) {
        next.push(this.threads[index]);
      }
    }
    this.threads = next;
    this.loadedAtMs = Date.now();
    this.onThreads(this.threads, this.more);
    hilog.info(DOMAIN, TAG, 'realtime row updated id=%{public}d at=0 unread=%{public}s mine=%{public}s',
      threadId.length, `${unread}`, `${message.mine}`);
    /*
     * **通知按"这条会话真的来了新消息"判，不按未读总数判**（用户报："突然不弹通知"）。
     *
     * 以前的判据是"未读总数比上次多"（见 PushCenter.noteUnread），而每行的未读**封顶 4**
     * —— 同一条会话从 4 条涨到 5 条时总数没变，于是再也不弹，直到用户进去读掉。
     * 现在看这条会话的最新消息时间有没有比"上次通知过的那条"更新（markNotified）。
     */
    const total: number = DirectViewModel.unreadTotal(this.threads);
    /*
     * 还有一道"新鲜度"闸：用落盘位点先订阅时（见 MobileDirect.primeSyncStateFromDisk），
     * 对端会把**离线期间**的补丁重放一遍 —— 那些消息可能是几分钟前的，不该再"叮"一次。
     * 只给 2 分钟内的消息弹通知。
     */
    const fresh: boolean = message.tsMs <= 0
      || Date.now() - message.tsMs < NOTIFY_MAX_AGE_MS;
    if (unread && fresh && this.markNotified(updated, true)) {
      PushCenter.noteUnread('direct', total);
      const sender: string = updated.title.length > 0 ? updated.title : updated.username;
      PushCenter.notifyDirect(sender, DirectViewModel.previewOf(updated), 1, updated.id);
    } else {
      // 正在看这条会话（readHere）/ 自己发的 / 没有更新：只记账，不响。
      this.noteNewUnread();
    }
    return true;
  }

  /**
   * 这条会话的最新消息是不是**比上次通知过的还新**（是就记账并返回 true）。
   *
   * 见 applyRealtimeMessage 里那段：未读条数封顶 4，光看总数会漏掉"同一条会话继续来消息"。
   *
   * @param allowFirstSight 第一次见到这条会话时要不要也响。
   *        实时通道传 true（那条消息确实是刚推来的）；轮询传 false
   *        （第一次见到只是"拉到了旧消息"，否则一启动就"叮"一条）。
   */
  private markNotified(thread: DirectThread, allowFirstSight: boolean): boolean {
    const prev: number | undefined = this.notifiedTs.get(thread.id);
    if (prev === undefined) {
      this.notifiedTs.set(thread.id, thread.tsMs);
      return allowFirstSight;
    }
    if (thread.tsMs <= prev) {
      return false;
    }
    this.notifiedTs.set(thread.id, thread.tsMs);
    return true;
  }

  /** 两份列表"看着一样"吗（轮询用它决定要不要重绘）。 */
  private static sameThreads(older: Array<DirectThread>,
                             newer: Array<DirectThread>): boolean {
    if (older.length !== newer.length) {
      return false;
    }
    for (let index: number = 0; index < older.length; index++) {
      const a: DirectThread = older[index];
      const b: DirectThread = newer[index];
      if (a.id !== b.id || a.unread !== b.unread || a.unreadCount !== b.unreadCount
        || a.text !== b.text || a.tsMs !== b.tsMs) {
        return false;
      }
    }
    return true;
  }

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
   * 没有 `unreadCount` 时按"未读 = 1 条"算，至少让通知有数。
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

  /** 轮询那一发在不在飞（和 `busy` 分开：轮询不该让页面显示"加载中"）。 */
  private polling: boolean = false;

  /**
   * **发现新的未读时发一条带内容的系统通知**（标题=发信人、正文=消息）。
   *
   * 计数口径仍是 `unreadTotal`：只有比上次多才发（`PushCenter` 里记账），避免重复"叮"。
   * 内容取**最近的、未读的那条会话**：私信列表本来就按时间倒序，第一条未读就是"最新来信"。
   */
  private noteNewUnread(): void {
    const total: number = DirectViewModel.unreadTotal(this.threads);
    if (total <= 0) {
      // 清空时也要走一遍：让 PushCenter 把计数降下去，否则"读完之后又收到一条"不会响。
      PushCenter.noteUnread('direct', 0);
      return;
    }
    let newest: DirectThread | null = null;
    for (let index: number = 0; index < this.threads.length; index++) {
      if (this.threads[index].unread) {
        newest = this.threads[index];
        break;
      }
    }
    if (newest === null) {
      PushCenter.noteUnread('direct', total);
      return;
    }
    /*
     * 先记账（让"读完之后又收到一条"能重新响），再发**一条**带内容的通知。
     *
     * 标题用**显示名**（`title`，比如 `XingLi`），没有显示名才退回 `username`（`xingli_415`）。
     * 需求（用户第二次明确）：「通知标题要 XingLi 这个用户名，而不是 xingli_415 这个用户名称」
     * —— 也就是说用户想要的是人看得懂的那个名字，不是 `@` 后面的句柄；群聊的 `title` 就是群名。
     * 正文用最新那条消息的文本；会话 id 一并带上，点通知以后能直达这条会话。
     * （以前是 noteUnread 先发一条"你有 N 条新私信"、再被这条覆盖，等于响两次，现已合并成一次。）
     *
     * **要不要响看 markNotified（按这条会话的消息时间），不看未读总数**：
     * 总数会被"每行未读封顶 4"卡住，同一条会话继续来消息时就再也不弹了（用户报的"突然不弹通知"）。
     * 轮询这条路上第一次见到某条会话**不响**（那些是拉到的旧消息，否则一启动就叮一条）。
     */
    const added: number = PushCenter.noteUnread('direct', total);
    if (this.markNotified(newest, false)) {
      const sender: string = newest.title.length > 0 ? newest.title : newest.username;
      const count: number = added > 0 ? added : 1;
      PushCenter.notifyDirect(sender, DirectViewModel.previewOf(newest), count, newest.id);
    }
  }

  /**
   * 通知正文用的"消息内容"。
   *
   * 纯文本消息直接给文字；**没有文字**的（图片/视频/语音/赞）给一个方括号占位 ——
   * 否则通知栏就是一条空正文，用户根本不知道对方发了什么（需求："内容需要显示消息内容"）。
   */
  private static previewOf(thread: DirectThread): string {
    const text: string = thread.text.trim();
    if (text.length > 0) {
      return text;
    }
    const kind: string = thread.kind.toLowerCase();
    if (kind.indexOf('raven') >= 0) {
      return '[闪照]';
    }
    if (kind.indexOf('voice') >= 0 || kind.indexOf('audio') >= 0) {
      return '[语音]';
    }
    if (kind.indexOf('clip') >= 0 || kind.indexOf('video') >= 0) {
      return '[视频]';
    }
    if (kind.indexOf('media') >= 0 || kind.indexOf('photo') >= 0) {
      return '[图片]';
    }
    if (kind.indexOf('like') >= 0 || kind.indexOf('reaction') >= 0) {
      return '[回应了你的消息]';
    }
    if (kind.indexOf('placeholder') >= 0 || kind.indexOf('action_log') >= 0) {
      return '[一条新消息]';
    }
    return '新消息';
  }

  /** 拉一次（refresh=true 时丢掉游标从头拉）。 */
  async load(refresh: boolean): Promise<void> {
    if (this.busy) {
      /*
       * **下拉刷新不能被"正在飞的那一发"静默吞掉**（用户报："下拉没反应"）。
       *
       * 原来这里只有一句 `return`：那一发可能是后台预热、也可能是轮询触发的增量
       * （`requestMore`），它回来的是**旧游标那一页**，用户的刷新请求却已经消失 ——
       * 界面停在旧列表上，转圈也早收了。现在记下来，本轮结束后补跑一次真刷新。
       */
      if (refresh) {
        this.pendingLoad = true;
        hilog.info(DOMAIN, TAG, 'load(refresh) queued behind in-flight round');
      }
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
      // 会话消息的**后台预取已移除**（用户要求）：列表只拿元数据与前一条预览，
      // 某条会话的消息等点开它时再拉（见 DirectThreadPage / DirectThreadViewModel）。
      /*
       * **有新私信就弹一条系统通知**。
       *
       * 远端推送要 AGC 后台发，客户端这边能保证的是：自己拉到了新的未读 → 用
       * NotificationKit 发一条本地通知（见 core/PushCenter）。只有未读数**变多**才弹。
       */
      PushCenter.noteUnread('direct', DirectViewModel.unreadTotal(this.threads));
      this.onStatus('已加载');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      this.busy = false;
      this.onBusy(false);
      // 排队的那次刷新在这里补跑（见上面 busy 分支）。
      if (this.pendingLoad) {
        this.pendingLoad = false;
        this.load(true);
      }
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
      const page: DirectInboxPage | null = await NativeDirect.inboxRest(this.endCursor);
      if (page === null || page.threads.length === 0) {
        this.more = false;
        this.onThreads(this.threads, this.more);
        return;
      }
      this.threads = this.threads.concat(page.threads);
      this.endCursor = page.endCursor;
      this.more = page.hasMore && page.endCursor.length > 0;
      this.onThreads(this.threads, this.more);

    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }

  /** 取一页（只有移动端这一条路；拿不到就把原因记在 `diag` 里）。 */
  private async fetchInbox(cursor: string): Promise<DirectInboxPage | null> {
    const page: DirectInboxPage | null = await NativeDirect.inbox(cursor);
    this.diag = page === null ? NativeDirect.lastDetail() : '-';
    return page;
  }
}
