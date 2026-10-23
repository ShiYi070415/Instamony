/*
 * **账号账本**：本机登录过的账号（多账号登录用）。
 *
 * ## 为什么单独一份，不塞进 AccountScope
 * `AccountScope`（见 core/AccountScope）管的是"**当前**这个人"的缓存分区：它只知道一个 key，
 * 换人就搬备份。而多账号要的是**花名册**：
 *   · 每个账号：数字 id、账号名、头像、会话（sessionid + csrftoken）、最近使用时间；
 *   · 界面上要在标题栏列出"其他账号"并一键切过去 —— 切过去 = 把它那串会话重新种回 Cookie 罐。
 * 两者关注点不同，硬合在一起会让"分区"那套逻辑跟着长出账号列表，得不偿失。
 *
 * ## 存什么、不存什么
 *   · **存**：会话 cookie（sessionid / csrftoken）、ds_user_id、账号名、头像地址。
 *     登录本身就是要落会话的（Cookie 罐自己也会落盘），这里只是把**每个人的**一份分开存，
 *     否则切回去要重新走一遍密码 + 两步验证。
 *   · **不存**：密码。任何时候都不落盘（密码只在登录那一次请求里用，见 LoginPage）。
 *   · 退出登录（`signOut`）**不清账本**：用户要的正是"退出后还能切回来"。
 *     真要删某个账号的会话，用 `forget(userId)`（设置页将来可以接一颗按钮）。
 *
 * ## 和 AccountScope 的配合
 * 切换账号时：`InstagramCookieJar.adoptSession(...)` 把目标账号的会话种回去 →
 * `pages/Index.applySession(...)` 会按 Cookie 里的 `ds_user_id` 走账号分区（stash 上一个人、
 * restore 这一个人的备份）。所以这里的 `usedAt` 只用于排序，不作为"当前账号"的判据 ——
 * 当前账号**永远以 Cookie 罐为准**（`AccountScope.current()` / `ds_user_id`）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AccountBook';
const STORE_NAME: string = 'instarmony_accounts';
/** 整份花名册就存在这一个键里（JSON 数组文本）。 */
const KEY_LIST: string = 'list';

/** 一个登录过的账号。 */
export class AccountEntry {
  /** 数字 id（`ds_user_id` / `pk`），也是 AccountScope 的分区键来源。 */
  readonly userId: string;
  /** 账号名（头像下面那一行字；拿不到时为空串）。 */
  username: string;
  /** 头像地址（拿不到时为空串，界面退回默认图标）。 */
  avatarUrl: string;
  /** 会话 cookie：切换账号时重新种回 Cookie 罐。 */
  sessionId: string;
  /** 会话里的 csrftoken（移动端私有接口要用，见 MobileSession）。 */
  csrf: string;
  /** 最近一次使用的时间戳（毫秒）：花名册按它倒序排。 */
  usedAt: number;

  constructor(userId: string, username: string, avatarUrl: string, sessionId: string,
              csrf: string, usedAt: number) {
    this.userId = userId;
    this.username = username;
    this.avatarUrl = avatarUrl;
    this.sessionId = sessionId;
    this.csrf = csrf;
    this.usedAt = usedAt;
  }

  /** 能不能拿来切换（没有会话就只能显示，切过去也没用）。 */
  usable(): boolean {
    return this.userId.length > 0 && this.sessionId.length > 0;
  }
}

export class AccountBook {
  private static store: preferences.Preferences | null = null;
  /** 内存里这一份（读出/写入都走它，避免每次渲染都碰 preferences）。 */
  private static entries: Array<AccountEntry> = [];

  /** 打开落盘文件并读回（`EntryAbility` 启动时调一次，和 AccountScope.init 并排）。 */
  static init(context: common.Context): void {
    if (AccountBook.store !== null) {
      return;
    }
    try {
      AccountBook.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      AccountBook.reload();
      hilog.info(DOMAIN, TAG, 'book opened accounts=%{public}d', AccountBook.entries.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open book failed: %{public}s', (error as Error).message);
    }
  }

  /** 全部账号（按 `usedAt` 倒序：最近用的在前）。 */
  static all(): Array<AccountEntry> {
    const sorted: Array<AccountEntry> = AccountBook.entries.slice();
    sorted.sort((a: AccountEntry, b: AccountEntry): number => b.usedAt - a.usedAt);
    return sorted;
  }

  /**
   * **除当前账号以外**的账号（下拉选单里列的就是这些）。
   *
   * @param currentUserId 当前账号的数字 id（空串 = 未登录，那就全都是"其他账号"）
   */
  static others(currentUserId: string): Array<AccountEntry> {
    return AccountBook.all().filter((one: AccountEntry): boolean =>
      one.userId !== currentUserId);
  }

  static find(userId: string): AccountEntry | null {
    for (let index: number = 0; index < AccountBook.entries.length; index++) {
      if (AccountBook.entries[index].userId === userId) {
        return AccountBook.entries[index];
      }
    }
    return null;
  }

  /**
   * 记下（或更新）一个账号的会话。
   *
   * 已有的条目**只覆盖传进来的那几样**：切换账号时我们只拿得到会话，
   * 不该把之前存好的账号名/头像抹成空。
   */
  static saveSession(userId: string, sessionId: string, csrf: string): void {
    if (userId.length === 0) {
      return;
    }
    const existing: AccountEntry | null = AccountBook.find(userId);
    if (existing === null) {
      AccountBook.entries.push(new AccountEntry(userId, '', '', sessionId, csrf, Date.now()));
    } else {
      if (sessionId.length > 0) {
        existing.sessionId = sessionId;
      }
      if (csrf.length > 0) {
        existing.csrf = csrf;
      }
      existing.usedAt = Date.now();
    }
    AccountBook.flush();
  }

  /** 记下（或更新）账号名与头像（`/users/{pk}/info` 回来之后调，见 pages/Index）。 */
  static saveProfile(userId: string, username: string, avatarUrl: string): void {
    if (userId.length === 0) {
      return;
    }
    const existing: AccountEntry | null = AccountBook.find(userId);
    if (existing === null) {
      // 还没有会话条目：只记资料没意义（切过去也切不动），等会话那一路建条目。
      return;
    }
    let touched: boolean = false;
    if (username.length > 0 && existing.username !== username) {
      existing.username = username;
      touched = true;
    }
    if (avatarUrl.length > 0 && existing.avatarUrl !== avatarUrl) {
      existing.avatarUrl = avatarUrl;
      touched = true;
    }
    if (touched) {
      AccountBook.flush();
    }
  }

  /** 把一个账号从花名册里删掉（会话作废；缓存分区仍交给 AccountScope 那套备份机制）。 */
  static forget(userId: string): void {
    const kept: Array<AccountEntry> = AccountBook.entries.filter((one: AccountEntry): boolean =>
      one.userId !== userId);
    if (kept.length === AccountBook.entries.length) {
      return;
    }
    AccountBook.entries = kept;
    AccountBook.flush();
    hilog.info(DOMAIN, TAG, 'forgot account %{public}s', userId);
  }

  /**
   * 从一整串 Cookie 里抓出这个会话要的东西（`sessionid` / `csrftoken` / `ds_user_id`）。
   *
   * Cookie 串就是 `WebCookieManager` 拿回来的那种：`a=b; c=d; ...`。
   * 为什么不用 JSON / 不解析属性：这里只要三个值，正则最省事，也不会因为属性写法变化而失败。
   */
  static sessionOf(cookie: string): AccountEntry {
    const value = (name: string): string => {
      const found: RegExpMatchArray | null = cookie.match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
      return found !== null && found.length > 1 ? found[1].trim() : '';
    };
    const userId: string = value('ds_user_id');
    const sessionId: string = value('sessionid');
    const csrf: string = value('csrftoken');
    return new AccountEntry(userId, '', '', sessionId, csrf, Date.now());
  }

  /** 排障用：一行说清现在账本里有什么（不含会话值本身）。 */
  static describe(): string {
    return AccountBook.entries.map((one: AccountEntry): string =>
      `${one.userId}:${one.username.length > 0 ? one.username : '(no name)'}`
        + `:${one.avatarUrl.length > 0 ? 'avatar' : 'no-avatar'}`
        + `:${one.usable() ? 'session' : 'no-session'}`).join(' | ');
  }

  /** 从落盘里重读（`init` 与外部改动后调）。 */
  private static reload(): void {
    if (AccountBook.store === null) {
      AccountBook.entries = [];
      return;
    }
    const raw: string = `${AccountBook.store.getSync(KEY_LIST, '[]')}`;
    AccountBook.entries = AccountBook.parse(raw);
  }

  /** 写回落盘（异步落盘，失败只记日志 —— 账本丢了顶多要重新登录一次）。 */
  private static flush(): void {
    if (AccountBook.store === null) {
      return;
    }
    try {
      AccountBook.store.putSync(KEY_LIST, AccountBook.serialize(AccountBook.entries));
      AccountBook.store.flush().catch((error: Error): void => {
        hilog.warn(DOMAIN, TAG, 'flush book failed: %{public}s', error.message);
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'write book failed: %{public}s', (error as Error).message);
    }
  }

  /** 序列化成 JSON 数组文本（键名用短名，省点空间）。 */
  private static serialize(entries: Array<AccountEntry>): string {
    const parts: Array<string> = [];
    for (let index: number = 0; index < entries.length; index++) {
      const one: AccountEntry = entries[index];
      parts.push(`{"u":${JSON.stringify(one.userId)},"n":${JSON.stringify(one.username)},`
        + `"a":${JSON.stringify(one.avatarUrl)},"s":${JSON.stringify(one.sessionId)},`
        + `"c":${JSON.stringify(one.csrf)},"t":${one.usedAt}}`);
    }
    return `[${parts.join(',')}]`;
  }

  /**
   * 解析 JSON 数组。
   *
   * 为什么不用 `JSON.parse` 直接转成强类型：ArkTS 里它给的是 `Object`，逐个字段取还得再写一遍
   * 取值代码；而且账本内容只由我们自己写，格式可控。这里用正则按对象切，容错更好
   * （某一条坏了只丢那一条）。
   */
  private static parse(raw: string): Array<AccountEntry> {
    const result: Array<AccountEntry> = [];
    const objects: RegExpMatchArray | null = raw.match(/\{[^{}]*\}/g);
    if (objects === null) {
      return result;
    }
    const field = (text: string, name: string): string => {
      const found: RegExpMatchArray | null = text.match(new RegExp(`"${name}":"((?:[^"\\\\]|\\\\.)*)"`));
      if (found === null || found.length < 2) {
        return '';
      }
      try {
        return JSON.parse(`"${found[1]}"`);
      } catch (error) {
        return '';
      }
    };
    const numField = (text: string, name: string): number => {
      const found: RegExpMatchArray | null = text.match(new RegExp(`"${name}":(\\d+)`));
      return found !== null && found.length > 1 ? Number.parseInt(found[1], 10) : 0;
    };
    for (let index: number = 0; index < objects.length; index++) {
      const one: string = objects[index];
      const userId: string = field(one, 'u');
      if (userId.length === 0) {
        continue;
      }
      result.push(new AccountEntry(userId, field(one, 'n'), field(one, 'a'),
        field(one, 's'), field(one, 'c'), numField(one, 't')));
    }
    return result;
  }
}
