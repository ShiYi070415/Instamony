/*
 * 点私信通知 → **直接进那条会话**（而不是只把 App 打开）。
 *
 * ## 为什么单独一个模块
 * 深链（core/DeepLink）那条路是给"外部 URL"用的：冷启动要先铺落地页 pages/LinkIn、
 * 热启动要等 Index 回到前台再执行。而通知点击是**本 App 自己发起的意图**，
 * 又带着"哪条会话"这种结构化参数（放在 want.parameters 里，不是 uri），
 * 走深链那套会被落地页拦一下、还得把 id 编码进 uri —— 不划算，也没必要。
 *
 * 所以这里只做一件极小的事：**把通知里带过来的会话 id 暂存下来，等页面来取**。
 *   · 冷启动：EntryAbility.onCreate 读到 → stash → pages/Index 起来后 take；
 *   · 热启动：EntryAbility.onNewWant 读到 → stash → Index.onPageShow 里 take。
 * 取一次就清（`take`），避免用户手动返回时被同一条通知反复拽回会话。
 */

/** 通知 want 里带会话 id 的参数名（PushCenter 发通知时写进去的）。 */
export const NOTIFY_THREAD_KEY: string = 'threadId';

export class NotifyRoute {
  /** 待打开的会话 id（空串 = 没有）。 */
  private static pending: string = '';
  /** 收到新意图时的回调（Index 挂上，见 onPending）。 */
  private static listener: (() => void) | undefined = undefined;

  /**
   * 挂"有新意图"的回调（页面在 `aboutToAppear` 里挂一次）。
   *
   * 为什么需要它：`onPageShow` 只在页面重新显示时触发，而 App 就在前台时点通知
   * （下拉通知栏再点）**不一定**会让页面重新显示 —— 只靠 onPageShow 会漏掉这一种。
   * 挂了回调之后，`stash()` 当场就把页面叫起来（同一进程同一线程，见 EntryAbility）。
   */
  static onPending(handler: () => void): void {
    NotifyRoute.listener = handler;
  }

  /** 记下"点通知要进哪条会话"，并立刻通知页面（如果有回调）。 */
  static stash(threadId: string): void {
    const id: string = (threadId ?? '').trim();
    NotifyRoute.pending = id;
    const handler: (() => void) | undefined = NotifyRoute.listener;
    if (handler !== undefined && id.length > 0) {
      handler();
    }
  }

  /** 现在有没有等着打开的会话（UI 判空用，不清）。 */
  static hasPending(): boolean {
    return NotifyRoute.pending.length > 0;
  }

  /** 取走并清空（取一次就清，见文件头）。 */
  static take(): string {
    const id: string = NotifyRoute.pending;
    NotifyRoute.pending = '';
    return id;
  }

  /**
   * 从 Want 的参数里读会话 id（读不到给空串）。
   *
   * `Want.parameters` 的类型是 `Record<string, Object>`，值可能是 string 也可能是别的盒装类型，
   * 所以统一 `${value}` 再判空 —— 在真机上见过 string 与 String 两种。
   */
  static threadIdOf(parameters: Record<string, Object> | undefined): string {
    if (parameters === undefined || parameters === null) {
      return '';
    }
    const value: Object | undefined = parameters[NOTIFY_THREAD_KEY];
    if (value === undefined || value === null) {
      return '';
    }
    const text: string = `${value}`.trim();
    // 挡掉"没写这个参数"时被塞进来的字面量 undefined / null。
    if (text.length === 0 || text === 'undefined' || text === 'null') {
      return '';
    }
    return text;
  }
}
