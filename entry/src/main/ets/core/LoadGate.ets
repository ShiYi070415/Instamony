/*
 * **加载闸门**（视图模型共用的那一套：代数 + 在飞 + 排队 + 可重试）。
 *
 * ## 为什么要有这个文件
 * 项目里每个视图模型都各自手写了一遍同样的东西，写法与漏洞各不相同：
 *   · `DirectThreadViewModel`：`busy` + `busyFor` + `generation` + `isStale()`；
 *   · `DirectViewModel`：`busy` + 手写的 `pendingLoad` 补跑；
 *   · `FeedViewModel`：`busy` + `pending` + `wantFirstPage` + `awaitIdle` 的轮询等待；
 *   · `SearchViewModel`：`recommendBusy`（**连 try/finally 都没有**，一次异常就永久卡死）。
 * 这些重复实现里踩过的坑是同一组：
 *   1. 在飞时来了新请求 —— 直接 return（用户的下拉刷新被静默吞掉）；
 *   2. 请求回来时目标已经换人 —— 结果照样写进去（A 的数据落进 B）；
 *   3. 抛异常时没有复位 —— 闸门永久 true，之后再也不加载。
 * 把它们收进一个类，坑就只需要修一次。
 *
 * ## 用法（三步，顺序不能乱）
 * ```ts
 * const ticket: number = this.gate.begin(true);   // true = 忙时排队，false = 忙时直接丢
 * if (ticket < 0) { return; }                     // 被挡下（已经在跑）
 * try {
 *   const data = await fetchPage();
 *   if (this.gate.stale(ticket)) { return; }      // 期间换人/重置过：**丢弃结果**
 *   this.apply(data);
 * } finally {
 *   if (this.gate.settle(ticket)) { this.load(true); }   // 有人排队：本轮结束后补跑
 * }
 * ```
 *
 * **`stale()` 必须紧跟在 await 之后、写任何字段之前调用** —— 这是"串号"唯一的
 * 防线：`begin()` 记下当时的代数，`invalidate()`（换账号 / 换会话 / 关闭页面）把它 +1，
 * 于是"作废之前发起、作废之后才回来"的请求一律作废。
 */
export class LoadGate {
  /** 期望的并发语义：忙的时候新来的请求是排队，还是直接丢弃。 */
  private readonly queueWhenBusy: boolean;
  /** 代数：每次 `invalidate()` +1（见 `stale`）。 */
  private generation: number = 0;
  /** 现在有没有一轮在跑。 */
  private readonlyTicket: number = -1;
  /** 有一轮在跑的时候又来了请求（只排一次，见 settle）。 */
  private queued: boolean = false;

  /**
   * @param queueWhenBusy true = 忙归忙，新请求排队（下拉刷新该补跑），
   *                      false = 忙就忽略（"正在拉推荐"这种幂等入口）。
   */
  constructor(queueWhenBusy: boolean = true) {
    this.queueWhenBusy = queueWhenBusy;
  }

  /**
   * 申请开始一轮。返回**本轮的门票**（settle / stale 都要带上它），<0 = 被挡下。
   *
   * @param queue 本次请求在忙的时候要不要排队（默认按构造参数）。
   */
  begin(queue: boolean = this.queueWhenBusy): number {
    if (this.readonlyBusy()) {
      if (queue) {
        this.queued = true;
      }
      return -1;
    }
    this.generation++;
    this.readonlyTicket = this.generation;
    return this.readonlyTicket;
  }

  /** 这一轮还在跑吗。 */
  busy(): boolean {
    return this.readonlyTicket >= 0;
  }

  /** 有没有排队的请求（诊断用）。 */
  hasQueued(): boolean {
    return this.queued;
  }

  /**
   * 这一轮的结果还有效吗。
   *
   * `ticket !== generation` 说明期间被 `invalidate()` 过：换账号、换会话、页面重建 ——
   * 那份结果属于"上一个人/上一条"，**一个字都不能写**。
   */
  stale(ticket: number): boolean {
    return ticket !== this.generation;
  }

  /**
   * 收尾（放在 `finally` 里，异常路径也要走到）。
   *
   * @returns 是否有人在排队等你这一轮结束（true = 调用方应该立刻再跑一轮）。
   */
  settle(ticket: number): boolean {
    // 只认"自己那一轮"：作废之后跑起来的新一轮不该被旧的一轮收掉门票。
    if (this.readonlyTicket !== ticket) {
      return false;
    }
    this.readonlyTicket = -1;
    if (this.queued) {
      this.queued = false;
      return true;
    }
    return false;
  }

  /**
   * 作废（换账号 / 换会话 / 页面销毁 / 清空数据时调）：
   * 代数 +1、丢掉"在飞"与排队的标记。
   *
   * 注意**不会**取消底层请求（ArkTS 这边没有通用取消），所以 `stale()` 那道判断是必需的。
   */
  invalidate(): void {
    this.generation++;
    this.readonlyTicket = -1;
    this.queued = false;
  }

  /** 一行摘要（日志/诊断）。 */
  describe(): string {
    return `gen=${this.generation} busy=${this.readonlyTicket >= 0 ? 'y' : 'n'}`
      + ` queued=${this.queued ? 'y' : 'n'}`;
  }

  private readonlyBusy(): boolean {
    return this.readonlyTicket >= 0;
  }
}
