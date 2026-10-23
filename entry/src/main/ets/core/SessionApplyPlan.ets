/*
 * **"这次登录态变化该做什么"的纯计算**（`applySession` 的第一段，见 pages/Index）。
 *
 * ## 为什么单独拎出来
 * `applySession` 是全 App **唯一的登录态出口**：启动核对、网页信号、退出登录、换账号
 * 四条路最后都汇到它。它前半段是一串**判断**（登的是谁？换了人吗？要搬分区吗？），
 * 后半段才是**副作用**（清内存、清导航栈、回主页、重新取数）。
 *
 * 两段混在一个 300 行的页面方法里，最直接的后遗症是**判据被写过好几次都不一致**：
 * 一开始只看"登录态 true/false 变没变"，于是"同一登录态下换账号"整块被跳过
 * （页签停在原页、导航栈没清、隐藏网页还挂在旧会话上 → 罐里的 ds_user_id 在两个人之间跳）。
 *
 * 现在把判断收在这里：**一个只读的结果对象**，页面照着执行。判据只有一份、可单独读。
 *
 * ## 它确实有一处副作用（写明了）
 * `AccountScope.adoptFrom(cookie)` 会把"当前账号槽位"落到 `AccountScope` 里 ——
 * 那是"判定当前是谁"的必要一步（后续所有分区键都依赖它），没法做成纯函数。
 * 除它之外，这里**不碰任何内存/界面状态**；搬分区（stash/restore）仍由页面执行，
 * 那样"搬分区"这件事在调用点仍然看得见。
 */

import { AccountChange, AccountScope } from './AccountScope';

export class SessionApplyPlan {
  /** 账号判定结果（变更前后；`previous === current` 表示没换人）。 */
  readonly account: AccountChange;
  /** 登录态（true/false）变了吗。 */
  readonly signedInChanged: boolean;
  /** 换人了吗（含"从无到有"与"从有到无"）。 */
  readonly accountChanged: boolean;
  /** 要不要把**上一个账号**的活跃分区搬去它的备份位。 */
  readonly stashPrevious: boolean;
  /** 要不要把**这个账号**的备份分区搬回活跃位。 */
  readonly restoreCurrent: boolean;
  /** 要不要走整套复位（清内存 / 清栈 / 回主页 / 重新取数）。 */
  readonly needsFullReset: boolean;

  private constructor(account: AccountChange, signedInChanged: boolean, accountChanged: boolean) {
    this.account = account;
    this.signedInChanged = signedInChanged;
    this.accountChanged = accountChanged;
    this.stashPrevious = accountChanged && account.previous.length > 0;
    this.restoreCurrent = accountChanged && account.current.length > 0;
    this.needsFullReset = signedInChanged || accountChanged;
  }

  /**
   * 判定这一次登录态更新。
   *
   * @param cookie          Cookie 罐里的整串（空串 = 这一路没有会话可依据）
   * @param sessionChecked  启动时的"会话核对"跑过了吗。**没跑完之前不判换人**：
   *                        否则冷启动那一下会把 `(none) → u123` 当成"换账号"，
   *                        白清一遍内存、还把用户刚暖好的首页重置掉。
   * @param signedInChanged 登录态变没变（由调用方比对自己上一份 `signedIn`）
   */
  static make(cookie: string, sessionChecked: boolean, signedInChanged: boolean): SessionApplyPlan {
    const account: AccountChange = cookie.length > 0
      ? AccountScope.adoptFrom(cookie)
      : new AccountChange(AccountScope.current(), AccountScope.current());
    const accountChanged: boolean = account.changed() && sessionChecked;
    return new SessionApplyPlan(account, signedInChanged, accountChanged);
  }

  /** 一行摘要（日志用；不含会话内容）。 */
  describe(): string {
    return `prev=${this.account.previous.length > 0 ? 'y' : 'n'}`
      + ` cur=${this.account.current.length > 0 ? 'y' : 'n'}`
      + ` changed=${this.accountChanged ? 'y' : 'n'}`
      + ` signedInChanged=${this.signedInChanged ? 'y' : 'n'}`;
  }
}