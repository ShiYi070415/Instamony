/*
 * **账号分区**：本机上所有"按人抓的"落盘数据，都按当前登录账号分开放。
 *
 * ## 为什么必须分区（用户报的问题）
 * 「退出登录 → 登录另一个账号 → 快拍还是上一个人的」—— 根因是这些缓存原来都是**单一槽位**：
 * 信息流首页、reels 首页、搜索推荐、私信会话快照、网页抓来的请求模板……谁登录都读同一份。
 * 换账号后它们照样命中，于是上一个人的内容被当成"缓存命中"铺出来。
 *
 * ## 做法
 *   · 每个缓存把自己的键过一遍 `AccountScope.slot(base)` → `page1_v1@u123`；
 *     于是**不同账号天然不共享**，同账号重登还能恢复（用户要求："退出登录可以保存备份"）。
 *   · 退出登录时把当前账号的**活跃分区**搬去**备份分区**（`… #backup@u123`）：
 *     活跃位置清空（用户要求："必须清除所有相关信息"），备份留给这个人以后回来用。
 *   · 同账号再次登录时自动把备份搬回活跃位；**不同账号永远读不到**别人的分区。
 *
 * ## 账号 key 怎么来
 *   优先 `ds_user_id`（Cookie 罐里就有，最稳）；没有就退回 sessionid 的**数字前缀**
 *   （instagrapi 也是这么取 user id 的）；都没有 → `anon`。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AccountScope';
const STORE_NAME: string = 'instarmony_account';
const KEY_CURRENT: string = 'current';

/** 没有账号信息时用的槽位名（未登录 / 读不到 id）。 */
const ANON: string = 'anon';

/** 一次"账号归属"的判定结果（见 adoptFrom）。 */
export class AccountChange {
  readonly previous: string;
  readonly current: string;

  constructor(previous: string, current: string) {
    this.previous = previous;
    this.current = current;
  }

  /** 账号换了（含"从无到有"和"从有到无"）。 */
  changed(): boolean {
    return this.previous !== this.current;
  }

  /** 是不是同一个人回来了（上次登出后被清空、现在又登回来）。 */
  returning(): boolean {
    return this.current.length > 0 && this.previous !== this.current;
  }
}

/** 一个需要分区的落盘缓存：store + 它的键。 */
class ScopedStore {
  readonly store: preferences.Preferences;
  readonly keys: Array<string>;

  constructor(store: preferences.Preferences, keys: Array<string>) {
    this.store = store;
    this.keys = keys;
  }
}

export class AccountScope {
  private static store: preferences.Preferences | null = null;
  /** 当前账号槽位（'' = 还不知道 / 未登录）。 */
  private static account: string = '';
  /** 注册进来的分区缓存（各 cache 在自己 init 时登记）。 */
  private static scoped: Array<ScopedStore> = [];

  /** 打开"当前账号"的落盘文件并读回（`EntryAbility` 启动时调一次）。 */
  static init(context: common.Context): void {
    if (AccountScope.store !== null) {
      return;
    }
    try {
      AccountScope.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      AccountScope.account = `${AccountScope.store.getSync(KEY_CURRENT, '')}`;
      hilog.info(DOMAIN, TAG, 'scope opened account=%{public}s',
        AccountScope.account.length > 0 ? AccountScope.account : '(none)');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open scope failed: %{public}s', (error as Error).message);
    }
  }

  /** 当前账号槽位（'' = 未知）。 */
  static current(): string {
    return AccountScope.account;
  }

  /**
   * 登记一个需要分区的缓存（cache 在自己 init 里调）。
   *
   * 登记之后：退出登录 / 账号切换时，`stashAll` 会自动把它的活跃分区搬去备份，
   * 不需要每个调用点各写一遍（漏一个就是"上一个人的数据还留着"）。
   */
  static register(store: preferences.Preferences, keys: Array<string>): void {
    for (let index: number = 0; index < AccountScope.scoped.length; index++) {
      if (AccountScope.scoped[index].store === store) {
        return;
      }
    }
    AccountScope.scoped.push(new ScopedStore(store, keys));
    // 顺手把**没有分区的老键**删掉，见 dropLegacy 的说明。
    AccountScope.dropLegacy(store, keys);
  }

  /**
   * 删掉"分区之前"遗留的裸键（一次性迁移）。
   *
   * 为什么必须删：改分区之前所有账号共用裸键（`page1_v1`）。那份数据属于**上一台设备状态下的
   * 某个账号**，现在既没有任何账号会去读它（读的都是 `page1_v1@u…`），也不该继续留在盘上 ——
   * 用户要求"必须清除所有相关信息"，留着等于把上一个人的内容（信息流、私信快照、模板）留在
   * 设备里。删法是幂等的：没有裸键时什么都不做。
   */
  private static dropLegacy(store: preferences.Preferences, keys: Array<string>): void {
    for (let index: number = 0; index < keys.length; index++) {
      const base: string = keys[index];
      try {
        const raw: string = `${store.getSync(base, '')}`;
        if (raw.length === 0) {
          continue;
        }
        store.deleteSync(base);
        store.flushSync();
        hilog.info(DOMAIN, TAG, 'dropped legacy key %{public}s (%{public}db)', base, raw.length);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'drop legacy %{public}s failed: %{public}s',
          base, (error as Error).message);
      }
    }
  }

  /** 直接指定账号（测试 / 诊断用；正常走 adoptFrom）。 */
  static setAccount(id: string): boolean {
    const next: string = `${id}`.trim();
    if (next === AccountScope.account) {
      return false;
    }
    AccountScope.account = next;
    const store: preferences.Preferences | null = AccountScope.store;
    if (store !== null) {
      try {
        store.putSync(KEY_CURRENT, next);
        store.flushSync();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'persist account failed: %{public}s', (error as Error).message);
      }
    }
    hilog.info(DOMAIN, TAG, 'account -> %{public}s', next.length > 0 ? next : '(none)');
    return true;
  }

  /**
   * 按 Cookie 串判定账号（Cookie 罐现读的那一串）。
   *
   * @returns 变更前后（`changed()` 为真时调用方要清内存、搬分区）
   */
  static adoptFrom(cookie: string): AccountChange {
    const previous: string = AccountScope.account;
    const id: string = AccountScope.accountOfCookie(cookie);
    AccountScope.setAccount(id);
    return new AccountChange(previous, id);
  }

  /** 从 Cookie 头串里推账号槽位（`u<ds_user_id>`；退回 sessionid 数字前缀）。 */
  private static accountOfCookie(cookie: string): string {
    const uid: string = AccountScope.cookieOf(cookie, 'ds_user_id');
    if (uid.length > 0) {
      return `u${uid}`;
    }
    const session: string = AccountScope.cookieOf(cookie, 'sessionid');
    let end: number = 0;
    while (end < session.length) {
      const code: number = session.charCodeAt(end);
      if (code < 48 || code > 57) {
        break;
      }
      end++;
    }
    return end > 0 ? `u${session.substring(0, end)}` : '';
  }

  private static cookieOf(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const pair: string = parts[index].trim();
      if (pair.startsWith(`${name}=`)) {
        return pair.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  /** 分区键（缓存读写的**唯一入口**：所有 cache 的键都要过这里）。 */
  static slot(base: string): string {
    return `${base}@${AccountScope.account.length > 0 ? AccountScope.account : ANON}`;
  }

  /** 备份键（退出登录时搬到这里）。 */
  static backupSlot(base: string): string {
    return `${base}#backup@${AccountScope.account.length > 0 ? AccountScope.account : ANON}`;
  }

  /**
   * 把一个分区键按**指定账号**拼出来（不依赖"当前账号"）。
   *
   * 搬分区时用得上：搬的是"上一个账号"的东西，而那一刻当前账号已经换成新的了。
   */
  static slotFor(base: string, account: string): string {
    return `${base}@${account.length > 0 ? account : ANON}`;
  }

  /** 把某个账号的备份搬回活跃位（同账号再次登录时调）。 */
  static restoreAll(account: string): number {
    let moved: number = 0;
    for (let index: number = 0; index < AccountScope.scoped.length; index++) {
      const one: ScopedStore = AccountScope.scoped[index];
      for (let at: number = 0; at < one.keys.length; at++) {
        moved += AccountScope.move(one.store, AccountScope.backupKeyFor(one.keys[at], account),
          AccountScope.slotFor(one.keys[at], account));
      }
    }
    if (moved > 0) {
      hilog.info(DOMAIN, TAG, 'restored backup account=%{public}s entries=%{public}d', account, moved);
    }
    return moved;
  }

  /**
   * 把某个账号的**活跃分区**搬去备份位（退出登录 / 换账号时调）。
   *
   * 搬完活跃位置就是空的 —— 界面上、接口里都不会再看到这个人的痕迹；
   * 备份留着，这个人以后回来还能用（用户要求："可以保存备份，但必须清除所有相关信息"）。
   */
  static stashAll(account: string): number {
    let moved: number = 0;
    for (let index: number = 0; index < AccountScope.scoped.length; index++) {
      const one: ScopedStore = AccountScope.scoped[index];
      for (let at: number = 0; at < one.keys.length; at++) {
        moved += AccountScope.move(one.store,
          AccountScope.slotFor(one.keys[at], account),
          AccountScope.backupKeyFor(one.keys[at], account));
      }
    }
    hilog.info(DOMAIN, TAG, 'stashed account=%{public}s entries=%{public}d', account, moved);
    return moved;
  }

  /** 备份键（按指定账号）。 */
  private static backupKeyFor(base: string, account: string): string {
    return `${base}#backup@${account.length > 0 ? account : ANON}`;
  }

  /** 键值搬移（源存在才写目标、然后删源）；返回是否搬了。 */
  private static move(store: preferences.Preferences, from: string, to: string): number {
    try {
      const value: string = `${store.getSync(from, '')}`;
      if (value.length === 0) {
        return 0;
      }
      if (from === to) {
        return 0;
      }
      store.putSync(to, value);
      store.deleteSync(from);
      store.flushSync();
      return 1;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'move %{public}s failed: %{public}s', from, (error as Error).message);
      return 0;
    }
  }

  /** 一行摘要（诊断 / 日志）。 */
  static describe(): string {
    return `account=${AccountScope.account.length > 0 ? AccountScope.account : '(none)'}`
      + ` scoped=${AccountScope.scoped.length}`;
  }
}
