/*
 * 信息流**第一页的落盘缓存**（需求："进入 app 时先获取 feeds 流并缓存" + "首屏落盘，先画后刷"）。
 *
 * ## 为什么要有它
 * 冷启动那条路上，首屏要等三件事：会话核对 → 隐藏网页就绪 → 原生 HTTP 拿到第一页并解析。
 * 而这一页内容和我们**上一次**读到的那一页几乎一样（信息流本来就是"上次之后的新帖 + 老帖"）。
 * 落盘之后，冷启动可以先把上次那一页按原样铺出来（读盘 + 映射，几十毫秒），
 * 用户一进 app 就有画面；网络那份回来再**整体替换**（见 FeedViewModel.fromCache）。
 *
 * ## 存什么、存多久
 *   - 存的是**接口给的原始 DTO**（`FeedItemDto[]`）+ 游标 + has_next_page，不是映射后的
 *     `MediaPost`：DTO 是纯数据（可以 JSON 化），映射一次很便宜，而且这样以后 DTO 加字段
 *     也不用改缓存格式（解析时按 v 校验一次版本号）。
 *   - 只存**第一页**（一页 7~10 条，几十 KB）。翻页那些页时效性更强、体积更大，
 *     不适合当"开机就有画面"的料。
 *   - 超过 TTL 就不认（默认 30 分钟，见 MAX_AGE_MS）：信息流放太久再铺出来，用户会觉得
 *     "怎么都是旧帖子"——那种情况下宁可等网络（骨架屏照旧）。
 *
 * ## 失败一律当作"没有缓存"
 * 落盘/读盘任何一步出错都只记一行日志：它只是"让首屏更快"，不该影响任何正常路径。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { FeedItemDto } from '../model/FeedDto';

const DOMAIN: number = 0xFF00;
const TAG: string = 'FeedCache';

/** 落盘的 preferences 文件名与键。 */
const STORE: string = 'instarmony_feed_cache';
const KEY: string = 'page1_v1';
/** 缓存格式版本：改了结构就 +1，旧的一律当没有。 */
const FORMAT: number = 1;
/** 缓存有效期（毫秒）：30 分钟。 */
const MAX_AGE_MS: number = 30 * 60 * 1000;
/** 单份缓存上限（字符）：超过就不存（一页几十 KB，这个上限只是防呆）。 */
const MAX_CHARS: number = 512 * 1024;

/** 落盘的一份第一页。 */
interface StoredFeedPage {
  v?: number;
  at?: number;
  cursor?: string;
  more?: boolean;
  items?: Array<FeedItemDto>;
}

/** 读回来的一份第一页（已通过版本与时效校验）。 */
export class CachedFeedPage {
  readonly items: Array<FeedItemDto>;
  readonly cursor: string;
  readonly hasMore: boolean;
  readonly ageMs: number;

  constructor(items: Array<FeedItemDto>, cursor: string, hasMore: boolean, ageMs: number) {
    this.items = items;
    this.cursor = cursor;
    this.hasMore = hasMore;
    this.ageMs = ageMs;
  }
}

export class FeedCache {
  private static store: preferences.Preferences | null = null;

  /** 打开缓存文件（EntryAbility.onCreate 里调一次即可；幂等）。 */
  static init(context: common.Context): void {
    if (FeedCache.store !== null) {
      return;
    }
    try {
      FeedCache.store = preferences.getPreferencesSync(context, { name: STORE });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 存一份第一页（同步写 + flush）。
   *
   * 为什么同步：它发生在首屏刚铺好之后，数据量小（几十 KB），异步反而要处理"写一半退出"的
   * 状态；preferences 的 putSync/flushSync 就是给这种小对象用的（模板落盘也是这么做的）。
   */
  static save(items: Array<FeedItemDto>, cursor: string, hasMore: boolean): void {
    const store: preferences.Preferences | null = FeedCache.store;
    if (store === null || items.length === 0) {
      return;
    }
    try {
      const payload: StoredFeedPage = {
        v: FORMAT,
        at: Date.now(),
        cursor: cursor,
        more: hasMore,
        items: items
      };
      const text: string = JSON.stringify(payload);
      if (text.length > MAX_CHARS) {
        hilog.warn(DOMAIN, TAG, 'page1 too big to cache: %{public}d chars', text.length);
        return;
      }
      store.putSync(KEY, text);
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'saved n=%{public}d chars=%{public}d', items.length, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 读第一页缓存。
   *
   * @param maxAgeMs 超过这个年龄就当没有（默认 30 分钟，见 MAX_AGE_MS）。
   * @returns 有效则返回那一页，否则 null。
   */
  static load(maxAgeMs: number = MAX_AGE_MS): CachedFeedPage | null {
    const store: preferences.Preferences | null = FeedCache.store;
    if (store === null) {
      return null;
    }
    try {
      const text: string = store.getSync(KEY, '') as string;
      if (text.length === 0) {
        return null;
      }
      const dto: StoredFeedPage = JSON.parse(text) as StoredFeedPage;
      if ((dto.v ?? 0) !== FORMAT) {
        return null;
      }
      const at: number = dto.at ?? 0;
      const age: number = Date.now() - at;
      if (age < 0 || age > maxAgeMs) {
        hilog.info(DOMAIN, TAG, 'cache stale age=%{public}dms', age);
        return null;
      }
      const items: Array<FeedItemDto> = dto.items ?? [];
      if (items.length === 0) {
        return null;
      }
      hilog.info(DOMAIN, TAG, 'hit n=%{public}d age=%{public}dms', items.length, age);
      return new CachedFeedPage(items, dto.cursor ?? '', dto.more === true, age);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', (error as Error).message);
      return null;
    }
  }
}
