/*
 * 限时快拍托盘的**落盘缓存**（冷启动第一帧就画出那一排头像/圆环）。
 *
 * ## 为什么需要（用户原话）
 *   "快拍列表冷启动渲染的很慢，浏览内容加载的慢。"
 *
 * 真机上的原因很具体：托盘只有两个数据来源——
 *   ① 页面里那份 `storyQueue`（内存，切 tab 时不丢，但**进程一重启就没了**）；
 *   ② `feed/reels_tray/` 那一发（实测 213 条 / 425KB / 3~6 秒）。
 * 冷启动时 ① 是空的，于是首页顶部先画一排灰色骨架，等 ② 回来才长出真实头像 ——
 * 而 ② 还要排在信息流那一发之后（同一套启动预热链），所以看到的就是"要等十几秒"。
 *
 * 有了这份缓存：冷启动**同步读盘**（几十毫秒）先铺一排真头像，网络那份回来再整体替换，
 * 和信息流 / 探索流是同一套"先画后刷"。
 *
 * ## 口径
 *   · 按账号分区（`core/AccountScope`）：换账号绝不能读到上一个人的快拍；
 *   · 有效期 `MAX_AGE_MS`（6 小时）：快拍 24 小时过期、托盘顺序也一直在变，太久的不值得再画；
 *   · 只存**列表本身**（id / 用户名 / 头像 / 有没有看过 / 关注状态这些），不存任何快拍媒体地址
 *     —— 那些地址带签名、几小时就失效（见 core/StoryCache 的说明），存了反而会画出一堆裂图。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AccountScope } from './AccountScope';
import { StoryTrayItem } from '../model/Story';

const DOMAIN: number = 0xFF00;
const TAG: string = 'TrayCache';

const STORE: string = 'instarmony_story_tray';
const KEY: string = 'items_v1';
/** 缓存格式版本：改了结构就 +1，旧的一律当没有。 */
const FORMAT: number = 1;
/** 有效期：6 小时（快拍本身 24 小时过期，托盘顺序变得更快）。 */
const MAX_AGE_MS: number = 6 * 60 * 60 * 1000;
/** 单份上限（字符）：213 条大约几万字符，这个上限只是防呆。 */
const MAX_CHARS: number = 512 * 1024;

/** 落盘的一条（字段名压短：这条缓存每次托盘刷新都要重写）。 */
interface StoredTrayItem {
  i?: string;
  u?: string;
  a?: string;
  s?: boolean;
  c?: number;
  alt?: Array<string>;
  f?: boolean;
  fk?: boolean;
  sug?: boolean;
  self?: boolean;
}

interface StoredTray {
  v?: number;
  at?: number;
  items?: Array<StoredTrayItem>;
}

/** 读回来的一份托盘（已通过版本与时效校验）。 */
export class CachedTray {
  readonly items: Array<StoryTrayItem>;
  readonly ageMs: number;

  constructor(items: Array<StoryTrayItem>, ageMs: number) {
    this.items = items;
    this.ageMs = ageMs;
  }
}

export class TrayCache {
  private static store: preferences.Preferences | null = null;

  /** 打开缓存文件（EntryAbility.onCreate 里调一次即可；幂等）。 */
  static init(context: common.Context): void {
    if (TrayCache.store !== null) {
      return;
    }
    try {
      TrayCache.store = preferences.getPreferencesSync(context, { name: STORE });
      AccountScope.register(TrayCache.store, [KEY]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  /** 存一份托盘（同步写；托盘刷新时调用，量级几万字符）。 */
  static save(items: Array<StoryTrayItem>): void {
    const store: preferences.Preferences | null = TrayCache.store;
    if (store === null || items.length === 0) {
      return;
    }
    try {
      const stored: Array<StoredTrayItem> = [];
      for (let index: number = 0; index < items.length; index++) {
        const one: StoryTrayItem = items[index];
        if (one.userId.length === 0) {
          continue;
        }
        stored.push({
          i: one.userId,
          u: one.username,
          a: one.avatarUrl,
          s: one.seen,
          c: one.count,
          alt: one.altIds,
          f: one.following,
          fk: one.followKnown,
          sug: one.suggested,
          self: one.selfReel
        });
      }
      if (stored.length === 0) {
        return;
      }
      const payload: StoredTray = { v: FORMAT, at: Date.now(), items: stored };
      const text: string = JSON.stringify(payload);
      if (text.length > MAX_CHARS) {
        hilog.warn(DOMAIN, TAG, 'tray too big to cache: %{public}d chars', text.length);
        return;
      }
      store.putSync(AccountScope.slot(KEY), text);
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'saved n=%{public}d chars=%{public}d', stored.length, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 读上次那份托盘（同步，几十毫秒）。
   *
   * @param maxAgeMs 超过这个年龄就当没有（默认 6 小时，见 MAX_AGE_MS）。
   */
  static load(maxAgeMs: number = MAX_AGE_MS): CachedTray | null {
    const store: preferences.Preferences | null = TrayCache.store;
    if (store === null) {
      return null;
    }
    try {
      const text: string = store.getSync(AccountScope.slot(KEY), '') as string;
      if (text.length === 0) {
        return null;
      }
      const dto: StoredTray = JSON.parse(text) as StoredTray;
      if ((dto.v ?? 0) !== FORMAT) {
        return null;
      }
      const at: number = dto.at ?? 0;
      const age: number = Date.now() - at;
      if (at <= 0 || age > maxAgeMs) {
        hilog.info(DOMAIN, TAG, 'tray cache stale age=%{public}dms', age);
        return null;
      }
      const raw: Array<StoredTrayItem> = dto.items ?? [];
      const out: Array<StoryTrayItem> = [];
      for (let index: number = 0; index < raw.length; index++) {
        const one: StoredTrayItem = raw[index];
        const id: string = `${one.i ?? ''}`.trim();
        if (id.length === 0) {
          continue;
        }
        // JSON 回来的是普通对象，按构造器重建实例（界面读的是 readonly 字段，方法没用）。
        out.push(new StoryTrayItem(id, one.u ?? '', one.a ?? '', one.s === true,
          one.c ?? 0, one.alt ?? [], one.f === true, one.fk === true, one.sug === true,
          one.self === true));
      }
      if (out.length === 0) {
        return null;
      }
      return new CachedTray(out, age);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /** 换账号 / 退出登录：清掉（键已按账号分区，这里再抹一次内容）。 */
  static clear(): void {
    const store: preferences.Preferences | null = TrayCache.store;
    if (store === null) {
      return;
    }
    try {
      store.deleteSync(AccountScope.slot(KEY));
    } catch (error) {
    }
  }
}
