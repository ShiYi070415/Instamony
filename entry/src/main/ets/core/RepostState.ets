/*
 * 「我转过这条没有」的**本机台账**（内存 + 落盘）。
 *
 * ## 为什么需要它（用户反馈）
 *   "已转发的状态会被刷掉。"
 *
 * IG 的载荷里**根本没有**这个字段：信息流 / 探索流 / 个人页那几条查询都不告诉你
 * "当前账号转过这条没有"（真机把媒体详情的键全打出来过，只有 `media_repost_count` 和
 * `media_notes`，没有 viewer 侧的标记）。所以它只能由**我们自己记**。
 *
 * 以前记在 `FeedViewModel.repostedKeys` 里 —— 那是**纯内存**的，有两个漏法：
 *   1. 进程一重启（或系统回收）就没了；
 *   2. 只认"信息流的 shortcode → key"这一种键，从帖子页 / 个人页进来的那条
 *      （键是媒体 id）对不上，刷新一轮就被载荷里的 false 顶回去。
 *
 * 这里跟「收藏」那套（core/SaveState）保持同一个思路，但多做两件事：
 *   · **同时按媒体 id（归一化成纯 pk）和 shortcode 两个键记**，哪个来源都能命中；
 *   · **落盘**（preferences，按账号分区），重启后还在。
 *
 * ## 口径
 *   · 只记 `true`：取消转发就把记录删掉（载荷/默认值本来就是 false，不需要反向记）；
 *   · TTL `TTL_MS`（30 天）：IG 的转发本身长期有效，这里只是防"在别处早就取消了、
 *     我们却一直显示已转发"；
 *   · 按账号分区（`core/AccountScope`）：换账号绝不能继承上一个人的转发状态。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AccountScope } from './AccountScope';

const DOMAIN: number = 0xFF00;
const TAG: string = 'RepostState';

const STORE: string = 'instarmony_repost';
const KEY: string = 'state_v1';
/** 格式版本：改了结构就 +1，旧的一律当没有（v2：加入落盘，之前那份只是联调时写的测试数据）。 */
const FORMAT: number = 2;
/** 一条记录的有效期（毫秒）：30 天。 */
const TTL_MS: number = 30 * 24 * 60 * 60 * 1000;
/** 最多记多少条（每条只是 key + 时间戳，500 条 ≈ 十几 KB）。 */
const MAX_ENTRIES: number = 500;

/** 落盘的一条：`k` = 键，`t` = 记下来的时刻。 */
interface StoredEntry {
  k?: string;
  t?: number;
}

interface StoredState {
  v?: number;
  on?: Array<StoredEntry>;
}

export class RepostState {
  private static store: preferences.Preferences | null = null;
  /** 键 → 记录时刻。键有两种：`<纯媒体pk>` 和 `c:<shortcode>`（见 remember）。 */
  private static readonly on: Map<string, number> = new Map<string, number>();
  private static loaded: boolean = false;

  /** 打开档案（EntryAbility.onCreate 里调一次；幂等）。 */
  static init(context: common.Context): void {
    if (RepostState.store !== null) {
      return;
    }
    try {
      RepostState.store = preferences.getPreferencesSync(context, { name: STORE });
      AccountScope.register(RepostState.store, [KEY]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 记一条（`reposted=false` 就是删掉它）。
   *
   * @param mediaId  媒体 id：`<pk>_<作者pk>` 或纯 pk 都行（内部归一化）
   * @param shortcode 短码（没有就给空串）
   */
  static remember(mediaId: string, shortcode: string, reposted: boolean): void {
    const keys: Array<string> = RepostState.keysOf(mediaId, shortcode);
    if (keys.length === 0) {
      return;
    }
    RepostState.ensureLoaded();
    const now: number = Date.now();
    for (let index: number = 0; index < keys.length; index++) {
      if (reposted) {
        RepostState.on.set(keys[index], now);
      } else {
        RepostState.on.delete(keys[index]);
      }
    }
    hilog.info(DOMAIN, TAG, 'remember reposted=%{public}s keys=%{public}d total=%{public}d',
      reposted ? 'y' : 'n', keys.length, RepostState.on.size);
    RepostState.save();
  }

  /**
   * 问一句"这条我转过没有"。
   *
   * @param fallback 载荷给的值（IG 一般给 false；有这个台账时以台账为准）
   */
  static resolve(mediaId: string, shortcode: string, fallback: boolean): boolean {
    const keys: Array<string> = RepostState.keysOf(mediaId, shortcode);
    if (keys.length === 0) {
      return fallback;
    }
    RepostState.ensureLoaded();
    if (RepostState.on.size === 0) {
      return fallback;
    }
    const now: number = Date.now();
    for (let index: number = 0; index < keys.length; index++) {
      const at: number | undefined = RepostState.on.get(keys[index]);
      if (at !== undefined) {
        if (now - at < TTL_MS) {
          return true;
        }
        RepostState.on.delete(keys[index]);
      }
    }
    return fallback;
  }

  /** 台账里有没有任何记录（给"要不要逐条解析"这种快速判空用）。 */
  static hasAny(): boolean {
    RepostState.ensureLoaded();
    return RepostState.on.size > 0;
  }

  /** 退出登录 / 换账号时清空（台账跟账号绑定）。 */
  static clear(): void {
    if (RepostState.on.size === 0) {
      return;
    }
    RepostState.on.clear();
    RepostState.save();
    hilog.info(DOMAIN, TAG, 'cleared');
  }

  // ---------------------------------------------------------------- 内部

  /** 这条媒体的两种键（纯 pk / `c:shortcode`）；都给不出就给空。 */
  private static keysOf(mediaId: string, shortcode: string): Array<string> {
    const keys: Array<string> = [];
    const text: string = `${mediaId}`.trim();
    if (text.length > 0) {
      const cut: number = text.indexOf('_');
      const pk: string = cut > 0 ? text.substring(0, cut) : text;
      if (pk.length > 0) {
        keys.push(pk);
      }
    }
    const code: string = `${shortcode}`.trim();
    if (code.length > 0) {
      keys.push(`c:${code}`);
    }
    return keys;
  }

  /** 读盘（进程内只读一次；失败就当空）。 */
  private static ensureLoaded(): void {
    if (RepostState.loaded) {
      return;
    }
    RepostState.loaded = true;
    const store: preferences.Preferences | null = RepostState.store;
    if (store === null) {
      return;
    }
    try {
      const raw: string = store.getSync(AccountScope.slot(KEY), '') as string;
      if (raw.length === 0) {
        return;
      }
      const parsed: StoredState = JSON.parse(raw) as StoredState;
      if ((parsed.v ?? 0) !== FORMAT) {
        return;
      }
      const list: Array<StoredEntry> | undefined = parsed.on;
      if (list === undefined) {
        return;
      }
      const now: number = Date.now();
      for (let index: number = 0; index < list.length; index++) {
        const one: StoredEntry = list[index];
        const key: string = `${one.k ?? ''}`;
        const at: number = one.t ?? 0;
        if (key.length > 0 && at > 0 && now - at < TTL_MS) {
          RepostState.on.set(key, at);
        }
      }
      hilog.info(DOMAIN, TAG, 'loaded n=%{public}d', RepostState.on.size);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', (error as Error).message);
    }
  }

  /** 落盘（超过上限就丢最旧的）。 */
  private static save(): void {
    const store: preferences.Preferences | null = RepostState.store;
    if (store === null) {
      return;
    }
    try {
      // 超上限：按时间排序后只留最新的那批。
      if (RepostState.on.size > MAX_ENTRIES) {
        const entries: Array<StoredEntry> = [];
        RepostState.on.forEach((at: number, key: string): void => {
          entries.push({ k: key, t: at });
        });
        entries.sort((a: StoredEntry, b: StoredEntry): number => (b.t ?? 0) - (a.t ?? 0));
        RepostState.on.clear();
        for (let index: number = 0; index < MAX_ENTRIES; index++) {
          const one: StoredEntry = entries[index];
          if (one.k !== undefined) {
            RepostState.on.set(one.k, one.t ?? 0);
          }
        }
      }
      const list: Array<StoredEntry> = [];
      RepostState.on.forEach((at: number, key: string): void => {
        list.push({ k: key, t: at });
      });
      const payload: StoredState = { v: FORMAT, on: list };
      store.putSync(AccountScope.slot(KEY), JSON.stringify(payload));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save failed: %{public}s', (error as Error).message);
    }
  }
}
