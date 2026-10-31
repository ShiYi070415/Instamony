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
import { InstagramCookieJar } from './InstagramCookieJar';
import { AccountEntry } from './AccountBook';
import { MobileIdentity, MobileSession } from './mobileapi/MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AccountActionService';

export class AccountActionService {
  /**
   * 把**当前 Cookie 罐里的这个账号**记进花名册（会话 + 名字 + 头像）。
   *
   * 时机：登录成功之后、切换/新增账号**之前**（保证切走以后还能回来）。
   * 会话直接从「当前身份」抓 —— 那是 App 唯一的会话来源，另存一份等于制造第二套真相。
   *
   * **为什么不再直接解析 Cookie 串**：IG 2026-10 起密码登录会下发**没有 sessionid** 的
   * 设备级会话（只有 `Authorization: Bearer IGT:2:…` + `ds_user_id`）。这种账号在
   * Cookie 串里永远凑不出一个"可用会话"，旧实现会 `remember: no usable session` 直接
   * 放弃记账 —— 真机表现就是"新增的小号在下拉选单里看得见（它是当前账号），一旦切回
   * 主号就消失（花名册里从来没它）"。`MobileSession.ensure()` 两种会话都认，从它取
   * userId / sessionId / csrf / authorization，花名册才能把设备级账号也记下来。
   *
   * @param username 界面上显示的账号名（可能为空：那时只记会话）
   * @param avatar   头像地址（同上）
   * @returns 真的记下来了吗（没有可用会话时返回 false）
   */
  static async rememberCurrent(username: string, avatar: string,
                              preferredUserId: string = ''): Promise<boolean> {
    try {
      // 这一发要紧盯罐里现在的值：先把 1.5 秒的读缓存作废（见 InstagramCookieJar.CACHE_TTL_MS）。
      InstagramCookieJar.invalidate();
      /*
       * 尽量带**当前分区的账号 id**：切号后罐里可能还躺着旧账号的 ds_user_id，
       * 不带的话 `ensure()` 可能把上一个人的会话记到新账号名下（或反过来）。
       */
      const identity: MobileIdentity | null =
        await MobileSession.getInstance().ensure(preferredUserId);
      if (identity === null || !identity.isComplete()) {
        hilog.info(DOMAIN, TAG, 'remember: no usable session in jar');
        return false;
      }
      // 设备级会话没有 sessionid，唯一凭据是 Authorization（见 core/AccountBook 的文件头）。
      const deviceLevel: boolean = identity.sessionId.length === 0;
      AccountBook.saveSession(identity.userId, identity.sessionId, identity.csrf,
        deviceLevel ? identity.authorization : '');
      /*
       * **账号资料只能写"确认属于这个人"的那份**（用户报的"切换账号后头像和用户名变成
       * 同一个人"）：调用方给的 username/avatar 来自界面状态，切号那一瞬间可能还是
       * 上一个人的。这里以花名册里已有的名字为准：名字不一致就不写，交给
       * `ensureAccountProfile` / `onHeader` 用接口返回的、按 id 核对过的头部去修。
       */
      const stored: AccountEntry | null = AccountBook.find(identity.userId);
      const storedName: string = stored === null ? '' : stored.username;
      /*
       * **新条目一律不写资料**：名字/头像必须等 `ensureAccountProfile` 按当前
       * `ds_user_id` 取回并核对过再写。这里只允许"同一个已有名字的账号"刷新头像 ——
       * 这样即使调用方把上一个人的界面状态带进来，也写不进新账号。
       */
      const nameTrusted: boolean = username.length > 0 && storedName.length > 0
        && storedName.toLowerCase() === username.toLowerCase();
      if (nameTrusted) {
        AccountBook.saveProfile(identity.userId, username, avatar);
      }
      hilog.info(DOMAIN, TAG, 'remembered %{public}s (device-level=%{public}s) (%{public}s)',
        identity.userId, deviceLevel ? 'y' : 'n', AccountBook.describe());
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'remember failed: %{public}s', (error as Error).message);
      return false;
    }
  }

  /**
   * **把花名册里某个账号的会话种回本机**（切换账号 / 冷启动恢复 / 新增账号失败回滚用）。
   *
   * 两条路（见 core/AccountBook 文件头）：
   *   · 带 sessionid 的会话：`InstagramCookieJar.adoptSession`（重种三颗 cookie）——
   *     成功后再作废上个账号残留的 `rur` / `shbid` / `shbts` / `ig-u-*`（**不碰刚写好的
   *     sessionid / ds_user_id / csrftoken**，顺序也刻意是"先写后清"，见 `adoptSession` 的说明）；
   *   · **设备级会话**（没有 sessionid）：先把它那份 Authorization 交给 `MobileSession`
   *     （唯一凭据，必须先落盘，否则后面的复位会把它抹掉），再把 `ds_user_id` / `csrftoken`
   *     种进罐；最后 `ensure()` 一次，让**内存里的身份**当场换成这个人 ——
   *     `applySession → forgetAccountMemory → MobileSession.clearSession` 的"保留 authorization"
   *     判据看的就是内存身份（设备级 + 同一账号）。
   *
   * @returns 种成功了吗（false = 会话过期 / 数据不完整，调用方提示"切换失败"）
   */
  static async adoptAccount(entry: AccountEntry): Promise<boolean> {
    if (!entry.usable()) {
      return false;
    }
    if (entry.sessionId.length > 0) {
      const adopted: boolean = await InstagramCookieJar.adoptSession(entry.sessionId,
        entry.userId, entry.csrf);
      if (!adopted) {
        return false;
      }
      // 新会话已经进罐；这时再清掉上个账号的"按人"材料（清了也不会误伤刚写好的三颗）。
      await InstagramCookieJar.expireCrossAccountCookies();
      /*
       * **当场核对"罐里现在是不是这个人、这份 sessionid"**：旧账号的 ds_user_id /
       * sessionid 可能还挂在另一个域上，不核对就去切分区，页面会按上一个人的身份取数。
       */
      const identity: MobileIdentity | null =
        await MobileSession.getInstance().ensure(entry.userId);
      if (identity === null || identity.userId !== entry.userId
        || identity.sessionId !== entry.sessionId) {
        hilog.warn(DOMAIN, TAG,
          'adopt sessionid: identity mismatch (null=%{public}s uidMatch=%{public}s sidMatch=%{public}s)',
          identity === null ? 'y' : 'n',
          identity !== null && identity.userId === entry.userId ? 'y' : 'n',
          identity !== null && identity.sessionId === entry.sessionId ? 'y' : 'n');
        return false;
      }
      return true;
    }
    try {
      MobileSession.adoptAuthorization(entry.authorization, entry.userId);
      /*
       * 紧跟着的那次登录态复位会走 `MobileSession.clearSession()`；给它一张 60 秒的
       * 免清通行证 —— 设备级会话的唯一凭据就是这份 authorization，抹掉就等于退出登录
       * （见 MobileSession.keepAuthorizationForNextReset 的说明）。
       */
      MobileSession.keepAuthorizationForNextReset();
      const adopted: boolean =
        await InstagramCookieJar.adoptDeviceSession(entry.userId, entry.csrf);
      if (!adopted) {
        return false;
      }
      /*
       * 让内存身份当场变成"这个人"：见上面 clearSession 保留判据的说明。
       * 这一步失败就别继续 —— 否则复位会把刚 adopt 的 authorization 抹掉，
       * 界面"进去了却什么都没有"（审计 P0）。
       */
      const identity: MobileIdentity | null =
        await MobileSession.getInstance().ensure(entry.userId);
      if (identity === null || identity.userId !== entry.userId
        || identity.sessionId.length > 0) {
        hilog.warn(DOMAIN, TAG,
          'adopt device-level: identity not ready (null=%{public}s uidMatch=%{public}s sid=%{public}d)',
          identity === null ? 'y' : 'n',
          identity !== null && identity.userId === entry.userId ? 'y' : 'n',
          identity === null ? -1 : identity.sessionId.length);
        return false;
      }
      hilog.info(DOMAIN, TAG, 'adopted device-level account %{public}s', entry.userId);
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'adopt device-level account failed: %{public}s',
        (error as Error).message);
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
