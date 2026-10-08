/*
 * 快拍**预加载 / 预缓存**（按"独立用户的 story"分页，队列形式）。
 *
 * 需求："stories 预加载和预缓存页做一下，缓存页按照独立用户 story 来分类，大概缓存五个用户的
 * story 就够了，采用队列形式，缓存页抽出一页就补新一页。"
 *
 * 所以这里就是一条**定长队列**，一页 = 一个用户的 StoryReel：
 *   · 托盘顺序到了、或者用户点开某一位时 `reset(items, from)`：以那一位为起点开始预取；
 *   · 队列最多 `DEPTH = 5` 页，**抽走一页**（`take`，用户真的翻到他了）立刻从托盘顺序里取
 *     下一位补到队尾 —— "抽出一页就补新一页"；
 *   · 每一页到手顺手把它的头几条媒体交给 `MediaPrefetch`（系统缓存下载）：播放页里那几张图
 *     于是直接命中缓存，不用现拉。
 *
 * 命中缓存时 `take()` 是**同步返回**的，播放页零等待 —— 这就是"点开不转圈"的来源；
 * 没命中才走 `fetch()`（网络，见 core/NativeStories.reel）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeStories } from './NativeStories';
import { MediaPrefetch } from './MediaPrefetch';
import { StoryItem, StoryReel, StoryTrayItem } from '../model/Story';

const DOMAIN: number = 0xFF00;
const TAG: string = 'StoryCache';
/** 缓存几个用户的 story（需求："大概缓存五个用户的 story 就够了"）。 */
const DEPTH: number = 5;
/** 每一页预下载头几条媒体（再多就是替用户白下了，反正他会停在第一条）。 */
const PREFETCH_ITEMS: number = 3;

export class StoryCache {
  /** 已缓存的页（队头 = 最先被用到的那个用户）。 */
  private static pages: Array<StoryReel> = [];
  /** 托盘那一整条顺序（"下一位是谁"从这里取）。 */
  private static tray: Array<StoryTrayItem> = [];
  /** 下一位要从托盘顺序的哪个下标开始预取。 */
  private static cursor: number = 0;
  /** 正在取数的页数（避免重复并发同一个用户）。 */
  private static loading: number = 0;

  /**
   * 保证"从第 `from` 位开始"的若干页都在队列里（托盘**可见范围**变化时调它）。
   *
   * 和 `reset` 的区别：已经在队列里、而且起点还在可见范围附近时**什么都不做**（不白扔已取好的
   * 页、也不重复打接口）；只有起点跑远了（用户横向滚了托盘）才重新以新起点预取。
   * 这就是"显示在屏幕中的用户 stories 提前加载"的入口。
   */
  static ensure(items: Array<StoryTrayItem>, from: number): void {
    const start: number = from >= 0 ? from : 0;
    if (StoryCache.pages.length > 0) {
      const first: number = StoryCache.indexOf(items, StoryCache.pages[0].userId);
      // 已有队列的起点落在 [start, start+3] 里 → 可见的那几位都盖住了，不用动。
      if (first >= start && first <= start + 3) {
        return;
      }
    }
    StoryCache.reset(items, start);
  }

  /** 某位用户在托盘顺序里的下标（找不到给 -1）。 */
  private static indexOf(items: Array<StoryTrayItem>, userId: string): number {
    for (let index: number = 0; index < items.length; index++) {
      if (items[index].userId === userId) {
        return index;
      }
    }
    return -1;
  }

  /** 现在缓存了几页 / 正在取几页（日志用）。 */
  static size(): number {
    return StoryCache.pages.length;
  }

  static pending(): number {
    return StoryCache.loading;
  }

  /**
   * 重置队列：以托盘顺序里的第 `from` 位为起点开始预取。
   *
   * 什么时候调：
   *   · 托盘刚拉到（`from = 0`）→ 先把前五个用户热起来；
   *   · 用户点开某一位（`from = 他点的下标`）→ 队列对齐到他，保证"下一位"就在缓存里。
   */
  static reset(items: Array<StoryTrayItem>, from: number): void {
    StoryCache.tray = items;
    StoryCache.pages = [];
    StoryCache.cursor = from >= 0 ? from : 0;
    hilog.info(DOMAIN, TAG, 'reset from=%{public}d of=%{public}d', StoryCache.cursor, items.length);
    StoryCache.fill();
  }

  /** 某一位在不在队列里（宿主点开之前先问一下：已在队列里就不要 reset，否则白扔一次预取）。 */
  static has(userId: string): boolean {
    for (let index: number = 0; index < StoryCache.pages.length; index++) {
      if (StoryCache.pages[index].userId === userId) {
        return true;
      }
    }
    return false;
  }

  private static inQueue(userId: string): boolean {
    return StoryCache.has(userId);
  }

  /**
   * 抽走某一位的缓存页（命中即从队列里拿走，并立刻补新的一页）。
   *
   * @returns 命中的 StoryReel；没缓存过给 null（调用方走网络）。
   */
  static take(userId: string): StoryReel | null {
    for (let index: number = 0; index < StoryCache.pages.length; index++) {
      if (StoryCache.pages[index].userId === userId) {
        const page: StoryReel = StoryCache.pages[index];
        StoryCache.pages.splice(index, 1);
        hilog.info(DOMAIN, TAG, 'take hit uid=%{public}s n=%{public}d left=%{public}d',
          userId, page.items.length, StoryCache.pages.length);
        StoryCache.fill();
        return page;
      }
    }
    hilog.info(DOMAIN, TAG, 'take miss uid=%{public}s cached=%{public}d',
      userId, StoryCache.pages.length);
    return null;
  }

  /**
   * 没有缓存时的兜底取数（走网络），回来顺手把队列补满。
   *
   * 注意：这一页是"立刻要用"的，所以**不进队列**（进了就重复占一个位置）。
   */
  static async fetch(userId: string): Promise<StoryReel | null> {
    const reel: StoryReel | null = await NativeStories.reel(userId);
    if (reel !== null) {
      StoryCache.warmMedia(reel);
    }
    StoryCache.fill();
    return reel;
  }

  /** 把"还缺几页"补齐（火并忘，失败就跳过那一位，不阻塞任何人）。 */
  private static fill(): void {
    while (StoryCache.pages.length + StoryCache.loading < DEPTH
      && StoryCache.cursor < StoryCache.tray.length) {
      const item: StoryTrayItem = StoryCache.tray[StoryCache.cursor];
      StoryCache.cursor = StoryCache.cursor + 1;
      // 已经在队列里的（同一个人可能被点到两次）不重复取。
      if (StoryCache.inQueue(item.userId)) {
        continue;
      }
      StoryCache.loading = StoryCache.loading + 1;
      StoryCache.loadOne(item.userId);
    }
  }

  private static loadOne(userId: string): void {
    NativeStories.reel(userId).then((reel: StoryReel | null): void => {
      StoryCache.loading = StoryCache.loading - 1;
      if (reel !== null && reel.items.length > 0) {
        StoryCache.pages.push(reel);
        StoryCache.warmMedia(reel);
        hilog.info(DOMAIN, TAG, 'cached uid=%{public}s n=%{public}d pages=%{public}d',
          userId, reel.items.length, StoryCache.pages.length);
      } else {
        hilog.info(DOMAIN, TAG, 'skip uid=%{public}s why=%{public}s',
          userId, NativeStories.lastDetail());
      }
      // 补下一页（成功失败都继续，别让一次失败把队列饿住）。
      StoryCache.fill();
    }).catch((): void => {
      StoryCache.loading = StoryCache.loading - 1;
      StoryCache.fill();
    });
  }

  /** 预下载这一页的头几条媒体（系统缓存下载，Image 组件会命中）。 */
  private static warmMedia(reel: StoryReel): void {
    const urls: Array<string> = [];
    for (let index: number = 0; index < reel.items.length && index < PREFETCH_ITEMS; index++) {
      const item: StoryItem = reel.items[index];
      if (item.imageUrl.length > 0) {
        urls.push(item.imageUrl);
      }
    }
    if (urls.length > 0) {
      MediaPrefetch.prefetch(urls);
    }
  }
}
