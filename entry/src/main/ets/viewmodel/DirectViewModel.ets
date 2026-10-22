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

export class DirectViewModel {
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
    // 未读变多时顺手弹通知（readHere / 自己发的不加未读，所以这里不会响）。
    this.noteNewUnread();
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
     * 先记账拿到"这一轮涨了几条"，再发**一条**带内容的通知。
     *
     * 标题用 `username`（`@xxx` 那个，需求）：`title` 是显示名/群名，会重名、也占行宽。
     * 正文用最新那条消息的文本；会话 id 一并带上，点通知以后能直达这条会话。
     * （以前是 noteUnread 先发一条"你有 N 条新私信"、再被这条覆盖，等于响两次，现已合并成一次。）
     */
    const added: number = PushCenter.noteUnread('direct', total);
    if (added > 0) {
      const sender: string = newest.username.length > 0 ? newest.username : newest.title;
      PushCenter.notifyDirect(sender, DirectViewModel.previewOf(newest), added, newest.id);
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
