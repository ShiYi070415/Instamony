/*
 * 私信收件箱的**落盘快照**（冷启动/切到私信页时先铺一屏，网络回来再换）。
 *
 * ## 为什么需要
 * 收件箱只有一条来源：移动端 `direct_v2/inbox/`（30KB 起，还要在全局闸门排队）。
 * 没有本地快照时，每次进私信页（以及冷启动第一次进）都要**干等一次网络往返** ——
 * 用户报的"私信列表加载很久"就是这个。有了快照：读盘几十毫秒先铺上，网络那一发
 * 回来整份替换（和搜索页推荐流、Reels 首屏同一套做法）。
 *
 * ## 存什么
 *   · 纯数据 DTO（`DirectThread` 是类实例，直接 JSON 化会把方法/只读字段一起卷进去）；
 *   · 只存**首页那一批**（默认最多 40 条会话，一两百 KB）；
 *   · 按账号分区（见 core/AccountScope）：换账号不可能读到上一个人的私信。
 *
 * ## 有效期
 * 10 分钟。私信是要"看到新消息"的地方，旧快照只用来**先出画面**，
 * 网络那一发无论新旧都会跑（DirectPage.aboutToAppear → load），所以不用存很久。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AccountScope } from './AccountScope';
import { DirectInboxPage, DirectThread } from '../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectCache';

/** preferences 文件名与键。 */
const STORE: string = 'instarmony_direct_cache';
const KEY: string = 'inbox_v1';
/** 缓存格式版本：改了结构就 +1，旧的一律当没有。 */
const FORMAT: number = 1;
/** 有效期（毫秒）。 */
const MAX_AGE_MS: number = 10 * 60 * 1000;
/** 最多存多少条会话。 */
const SAVE_MAX_ITEMS: number = 40;
/** 单份上限（字符）。 */
const MAX_CHARS: number = 512 * 1024;

/** 落盘的一条会话（`DirectThread` 的纯数据版；字段名短一点省体积）。 */
class DirectThreadDto {
  id: string = '';
  key: string = '';
  t: string = '';
  av: string = '';
  g: boolean = false;
  u: boolean = false;
  m: boolean = false;
  p: boolean = false;
  ts: number = 0;
  tx: string = '';
  k: string = '';
  un: string = '';
  uc: number = 0;
}

/** 落盘的整体结构。 */
class StoredInbox {
  v: number = FORMAT;
  at: number = 0;
  endCursor: string = '';
  hasMore: boolean = false;
  items: Array<DirectThreadDto> = [];
}

/** 读回来的一页。 */
export class CachedInbox {
  readonly page: DirectInboxPage;
  readonly ageMs: number;

  constructor(page: DirectInboxPage, ageMs: number) {
    this.page = page;
    this.ageMs = ageMs;
  }
}

export class DirectCache {
  private static store: preferences.Preferences | null = null;

  /** 打开缓存文件（EntryAbility.onCreate 里调一次；幂等）。 */
  static init(context: common.Context): void {
    if (DirectCache.store !== null) {
      return;
    }
    try {
      DirectCache.store = preferences.getPreferencesSync(context, { name: STORE });
      // 按账号分区（见 core/AccountScope）。
      AccountScope.register(DirectCache.store, [KEY]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  /** 存一份首页（同步写 + flush，同 ReelsCache/FeedCache）。 */
  static save(page: DirectInboxPage): void {
    const store: preferences.Preferences | null = DirectCache.store;
    if (store === null || page.threads.length === 0) {
      return;
    }
    try {
      const items: Array<DirectThreadDto> = [];
      const total: number = page.threads.length < SAVE_MAX_ITEMS
        ? page.threads.length : SAVE_MAX_ITEMS;
      for (let index: number = 0; index < total; index++) {
        const one: DirectThread = page.threads[index];
        const dto: DirectThreadDto = new DirectThreadDto();
        dto.id = one.id;
        dto.key = one.key;
        dto.t = one.title;
        dto.av = one.avatarUrl;
        dto.g = one.isGroup;
        dto.u = one.unread;
        dto.m = one.muted;
        dto.p = one.pinned;
        dto.ts = one.tsMs;
        dto.tx = one.text;
        dto.k = one.kind;
        dto.un = one.username;
        dto.uc = one.unreadCount;
        items.push(dto);
      }
      const payload: StoredInbox = new StoredInbox();
      payload.at = Date.now();
      payload.endCursor = page.endCursor;
      payload.hasMore = page.hasMore;
      payload.items = items;
      const text: string = JSON.stringify(payload);
      if (text.length > MAX_CHARS) {
        hilog.warn(DOMAIN, TAG, 'inbox too big to cache: %{public}d chars', text.length);
        return;
      }
      store.putSync(AccountScope.slot(KEY), text);
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'saved n=%{public}d chars=%{public}d', total, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save failed: %{public}s', (error as Error).message);
    }
  }

  /** 读首页快照（太旧就当没有）。 */
  static load(maxAgeMs: number = MAX_AGE_MS): CachedInbox | null {
    const store: preferences.Preferences | null = DirectCache.store;
    if (store === null) {
      return null;
    }
    try {
      const text: string = store.getSync(AccountScope.slot(KEY), '') as string;
      if (text.length === 0) {
        return null;
      }
      const dto: StoredInbox = JSON.parse(text) as StoredInbox;
      if ((dto.v ?? 0) !== FORMAT) {
        return null;
      }
      const age: number = Date.now() - (dto.at ?? 0);
      if (age < 0 || age > maxAgeMs) {
        hilog.info(DOMAIN, TAG, 'cache stale age=%{public}dms', age);
        return null;
      }
      const items: Array<DirectThreadDto> = dto.items ?? [];
      const threads: Array<DirectThread> = [];
      for (let index: number = 0; index < items.length; index++) {
        const one: DirectThreadDto = items[index];
        if ((one.id ?? '').length === 0) {
          continue;
        }
        threads.push(new DirectThread(one.id, one.key ?? '', one.t ?? '', one.av ?? '',
          one.g === true, one.u === true, one.m === true, one.p === true, one.ts ?? 0,
          one.tx ?? '', one.k ?? '', one.un ?? '', one.uc ?? 0));
      }
      if (threads.length === 0) {
        return null;
      }
      hilog.info(DOMAIN, TAG, 'hit n=%{public}d age=%{public}dms', threads.length, age);
      return new CachedInbox(new DirectInboxPage(threads, dto.endCursor ?? '',
        dto.hasMore === true), age);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', (error as Error).message);
      return null;
    }
  }
}
