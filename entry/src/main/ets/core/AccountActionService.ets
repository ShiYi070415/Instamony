/*
 * **账号动作里"与 UI 无关"的那一半**（P1-9 第三刀）。
 *
 * ## 哪些东西搬到了这里
 * 三个动作原来都写在 `pages/Index` 里，各自混着"落盘事务"和"页面状态/导航"：
 *   · **记住当前账号**（切走之前/登录成功之后）—— 纯粹是 Cookie 罐 → 花名册的落盘；
 *   · **把某个账号从本机删掉**（退出登录）—— 花名册 + 缓存分区 + 头部快照三处落盘清理。
 * 这两件事一行 UI 都不需要，却因为写在页面里，每次改动都要在一万行的文件里找。
 *
 * ## 留在页面里的
 * 视图模型 `reset()`、`@State`（selfUsername / selfAvatarUrl / 各种旗子）、
 * 导航栈与回主页、`applySession` 那套登录态出口 —— 它们属于 UI 层，页面才是所有者。
 *
 * ## 为什么返回布尔而不是直接 throw
 * 这两步都是"尽力而为"：记住失败不该打断切换（最坏是下次要重新登录那个号），
 * 删除失败也不该让用户卡在退出流程里。所以失败只记日志、返回 false，由页面决定提示。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

import { AccountBook } from './AccountBook';
import { AccountScope } from './AccountScope';
import { AppSettings } from './AppSettings';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { AccountEntry } from './AccountBook';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AccountActionService';

export class AccountActionService {
  /**
   * 把**当前 Cookie 罐里的这个账号**记进花名册（会话 + 名字 + 头像）。
   *
   * 时机：登录成功之后、切换/新增账号**之前**（保证切走以后还能回来）。
   * 会话直接从 Cookie 罐抓 —— 那是 App 唯一的会话来源，另存一份等于制造第二套真相。
   *
   * @param username 界面上显示的账号名（可能为空：那时只记会话）
   * @param avatar   头像地址（同上）
   * @returns 真的记下来了吗（没有可用会话时返回 false）
   */
  static async rememberCurrent(username: string, avatar: string): Promise<boolean> {
    try {
      // 这一发要紧盯罐里现在的值：先把 1.5 秒的读缓存作废（见 InstagramCookieJar.CACHE_TTL_MS）。
      InstagramCookieJar.invalidate();
      const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const session: AccountEntry = AccountBook.sessionOf(snapshot.cookie);
      if (!session.usable()) {
        hilog.info(DOMAIN, TAG, 'remember: no usable session in jar');
        return false;
      }
      AccountBook.saveSession(session.userId, session.sessionId, session.csrf);
      AccountBook.saveProfile(session.userId, username, avatar);
      hilog.info(DOMAIN, TAG, 'remembered %{public}s (%{public}s)',
        session.userId, AccountBook.describe());
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'remember failed: %{public}s', (error as Error).message);
      return false;
    }
  }

  /**
   * 把这个账号**从本机彻底删掉**（「退出登录」用；同时删活跃分区与备份分区）。
   *
   * 三处落盘：
   *   1) 花名册里的会话（删掉它，账号选单里就再也切不回来 —— 这是"退出登录真的退出"的关键）；
   *   2) 缓存分区（`AccountScope.purgeAccount`，注意槽位是 `u<id>`）；
   *   3) 头部快照（`profile_header_<id>` 是按 id 存的，不是分区键，要单独删）。
   *
   * @param userId 纯数字 id
   * @returns 删成功了吗（花名册那步失败才算失败）
   */
  static forgetAccount(userId: string): boolean {
    let ok: boolean = false;
    if (userId.length > 0) {
      try {
        AccountBook.forget(userId);
        ok = true;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'book forget failed: %{public}s', (error as Error).message);
      }
    }
    /*
     * **保留名单 = 花名册里还有会话的那些人**：切换账号时新账号的缓存分区刚被搬回活跃位，
     * 不能跟着一起删；而这个账号本身已经从花名册里删掉了，所以它的分区必然落在"删"这一侧。
     */
    const keep: Array<string> = AccountActionService.slotsInBook();
    /*
     * 先按点名删（幂等），再**扫盘**把不在名单里的分区（含更早以前那些账号留下的
     * `#backup@u…`）一起清掉 —— 后者才兜得住"缓存还没 init / 账号 id 没拿到"那两种情况。
     */
    try {
      if (userId.length > 0) {
        AccountScope.purgeAccount(`u${userId}`);
      }
      const swept: number = AccountScope.purgeAccountsNotIn(keep, true);
      if (swept > 0) {
        hilog.info(DOMAIN, TAG, 'swept orphan partitions entries=%{public}d', swept);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'purge failed: %{public}s', (error as Error).message);
    }
    try {
      if (userId.length > 0) {
        AppSettings.dropProfileHeader(userId);
      }
      AppSettings.forgetAccountKeys(keep);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'forget account settings failed: %{public}s', (error as Error).message);
    }
    hilog.info(DOMAIN, TAG, 'forgot %{public}s locally (%{public}s)', userId,
      AccountBook.describe());
    return ok;
  }

  /** 花名册里还有会话的账号槽位（`u<id>`）—— 作为"别删"的保留名单。 */
  private static slotsInBook(): Array<string> {
    const out: Array<string> = [];
    try {
      const all: Array<AccountEntry> = AccountBook.all();
      for (let index: number = 0; index < all.length; index++) {
        const id: string = `${all[index].userId}`.trim();
        if (id.length > 0) {
          out.push(`u${id}`);
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read book failed: %{public}s', (error as Error).message);
    }
    return out;
  }
}
