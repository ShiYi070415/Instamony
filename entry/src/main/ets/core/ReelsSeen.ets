/*
 * **看过的 Reels 台账**（按账号 + 按流分开，落盘）。
 *
 * ## 为什么需要（用户报的三件事）
 *   1. "每次打开 app 不会再获取上一轮一样的视频"；
 *   2. "刷新不会看见看过的视频"；
 *   3. "整个视频流都很重复"。
 * 根因是 IG 那几条查询本身很"死"：`clips/discover/` 永远回同一批 3~4 条、作者页是
 * 某个人的 12 条、探索流的头几页也会在短时间里高度重合。App 这边原来只有一份**进程内**的
 * 去重表（`ReelsViewModel.shown`），杀掉进程就忘了 —— 于是每次冷启动、每次刷新都可能
 * 把刚看过的再拿一遍。
 * 这里把"看过哪些短码"记到盘上，冷启动/刷新时把它们过滤掉。**只存短码**（不带任何
 * 媒体地址/作者名），并且有上限（超了丢最旧的），不落任何正文。
 *
 * ## 分区
 * 键过 `AccountScope.slot` —— 换账号读不到别人的；退出登录时由
 * `AccountScope.purgeAccountsNotIn` 一起清掉。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountScope } from './AccountScope';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsSeen';
const STORE_NAME: string = 'instarmony_reels_seen';
/** 每个流最多记这么多条（约 50 屏，够躲开"最近重复"；再多的价值就没了）。 */
const MAX_CODES: number = 500;

export class ReelsSeen {
  private static store: preferences.Preferences | null = null;
  /** 进程内的镜像（避免每次判断都读盘）。 */
  private static memo: Map<string, Array<string>> = new Map<string, Array<string>>();

  /** 打开落盘仓（`EntryAbility` 里和别的缓存一起调；幂等）。 */
  static init(context: common.Context): void {
    if (ReelsSeen.store !== null) {
      return;
    }
    try {
      ReelsSeen.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      // 登记到账号分区：换号/退出登录时会跟着清（见 AccountScope）。
      AccountScope.register(ReelsSeen.store, ['seen_v1']);
      hilog.info(DOMAIN, TAG, 'reels seen store opened');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open reels seen store failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 这一条看过了没有。
   *
   * @param source 哪条流（探索 / 好友），两条流的"看过"互不影响
   */
  static has(source: string, shortcode: string): boolean {
    if (shortcode.length === 0) {
      return false;
    }
    return ReelsSeen.codesOf(source).indexOf(shortcode) >= 0;
  }

  /** 记一批"看过了"（幂等、有上限；超了丢最旧的）。 */
  static remember(source: string, shortcodes: Array<string>): void {
    if (shortcodes.length === 0) {
      return;
    }
    const list: Array<string> = ReelsSeen.codesOf(source);
    let changed: boolean = false;
    for (let index: number = 0; index < shortcodes.length; index++) {
      const code: string = shortcodes[index];
      if (code.length === 0 || list.indexOf(code) >= 0) {
        continue;
      }
      list.push(code);
      changed = true;
    }
    if (!changed) {
      return;
    }
    while (list.length > MAX_CODES) {
      list.shift();
    }
    ReelsSeen.memo.set(source, list);
    ReelsSeen.persist(source, list);
    hilog.info(DOMAIN, TAG, 'reels seen +%{public}d src=%{public}s total=%{public}d',
      shortcodes.length, source, list.length);
  }

  /** 这条流记了多少条（诊断用）。 */
  static countOf(source: string): number {
    return ReelsSeen.codesOf(source).length;
  }

  /** 清空**当前账号**两条流的台账（换账号 / 手动重置时用；退出登录走分区清理）。 */
  static clear(): void {
    ReelsSeen.memo.clear();
    const store: preferences.Preferences | null = ReelsSeen.store;
    if (store === null) {
      return;
    }
    try {
      for (const key of Object.keys(store.getAllSync())) {
        store.deleteSync(key);
      }
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'reels seen cleared');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clear reels seen failed: %{public}s', (error as Error).message);
    }
  }

  // ------------------------------------------------------------------ 内部

  /** 拿一条流的台账（先内存、再盘）。 */
  private static codesOf(source: string): Array<string> {
    const cached: Array<string> | undefined = ReelsSeen.memo.get(source);
    if (cached !== undefined) {
      return cached;
    }
    let list: Array<string> = [];
    const store: preferences.Preferences | null = ReelsSeen.store;
    if (store !== null) {
      try {
        const raw: string = `${store.getSync(ReelsSeen.keyOf(source), '')}`;
        if (raw.length > 2) {
          const parsed: Object = JSON.parse(raw) as Object;
          if (Array.isArray(parsed)) {
            const array: Array<Object> = parsed as Array<Object>;
            for (let index: number = 0; index < array.length; index++) {
              const one: string = `${array[index]}`.trim();
              if (one.length > 0) {
                list.push(one);
              }
            }
          }
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'load reels seen failed: %{public}s', (error as Error).message);
        list = [];
      }
    }
    ReelsSeen.memo.set(source, list);
    return list;
  }

  /** 分区键（见 AccountScope.slot）。 */
  private static keyOf(source: string): string {
    return AccountScope.slot(`seen_v1#${source}`);
  }

  private static persist(source: string, list: Array<string>): void {
    const store: preferences.Preferences | null = ReelsSeen.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(ReelsSeen.keyOf(source), JSON.stringify(list));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save reels seen failed: %{public}s', (error as Error).message);
    }
  }
}
