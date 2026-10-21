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
import { AccountScope } from './AccountScope';
import { common } from '@kit.AbilityKit';
import { FeedItemDto } from '../model/FeedDto';
import { SearchPost } from '../model/Search';

const DOMAIN: number = 0xFF00;
const TAG: string = 'FeedCache';

/** 落盘的 preferences 文件名与键。 */
const STORE: string = 'instarmony_feed_cache';
const KEY: string = 'page1_v1';
/**
 * "关注流已看完"这个状态落盘的键（存一个毫秒时间戳）。
 *
 * 为什么要落盘：真机上这个状态意味着 `feed/timeline/` 只会回一条占位、必然解析出 0 条
 * （见 core/NativeFeed.markCaughtUp）。不记住的话**每次冷启动**都要先白等 4~10 秒
 * 才退回推荐源 —— 这正是用户说的"帖子刷新很慢"。
 */
const KEY_STATE: string = 'timeline_state_v1';
/**
 * 探索流第一页（`discover/topical_explore/`）落盘的键。
 *
 * 为什么需要：这个账号的关注流是"已看完"状态，首页首屏**全部**来自探索流，而那一发要
 * 3~7 秒、0.5~1MB。不落盘的话每次冷启动都要对着骨架屏等它；落盘之后先铺上次那份（几十毫秒），
 * 网络那份回来再整体替换 —— 就是首页那套"先画后刷"（见 FeedViewModel.loadExplore）。
 */
const KEY_REC: string = 'rec_page1_v1';
/** 缓存格式版本：改了结构就 +1，旧的一律当没有。 */
const FORMAT: number = 2;
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

/** 落盘的一份探索流第一页（帖子本身是 `SearchPost`，见 model/Search）。 */
interface StoredRecommendedPage {
  v?: number;
  at?: number;
  cursor?: string;
  more?: boolean;
  posts?: Array<SearchPost>;
}

/** 读回来的一份探索流第一页（已通过版本与时效校验）。 */
export class CachedRecommendedPage {
  readonly posts: Array<SearchPost>;
  readonly cursor: string;
  readonly hasMore: boolean;
  readonly ageMs: number;

  constructor(posts: Array<SearchPost>, cursor: string, hasMore: boolean, ageMs: number) {
    this.posts = posts;
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
      // 按账号分区（见 core/AccountScope）：换账号绝不能读到上一个人的首页缓存。
      AccountScope.register(FeedCache.store, [KEY, KEY_STATE, KEY_REC]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  /** 存一下"关注流已看完"的时刻（见 core/NativeFeed.markCaughtUp）。 */
  static saveCaughtUp(atMs: number): void {
    const store: preferences.Preferences | null = FeedCache.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(AccountScope.slot(KEY_STATE), `${atMs}`);
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save caught-up failed: %{public}s', (error as Error).message);
    }
  }

  /** 读"关注流已看完"的时刻（0 = 没记过）。 */
  static loadCaughtUp(): number {
    const store: preferences.Preferences | null = FeedCache.store;
    if (store === null) {
      return 0;
    }
    try {
      const text: string = store.getSync(AccountScope.slot(KEY_STATE), '') as string;
      if (text.length === 0) {
        return 0;
      }
      const value: number = Number.parseInt(text, 10);
      return Number.isFinite(value) && value > 0 ? value : 0;
    } catch (error) {
      return 0;
    }
  }

  /**
   * 存一份**探索流第一页**（同上：同步写，量小）。
   *
   * 存的是 `SearchPost`（页面注入那条路的原生类型），读回来重建实例再由页面转成 `MediaPost`；
   * 游标也一起存 —— 冷启动先铺这份时，触底翻页能从上次那个游标接着走。
   */
  static saveRecommended(posts: Array<SearchPost>, cursor: string, hasMore: boolean): void {
    const store: preferences.Preferences | null = FeedCache.store;
    if (store === null || posts.length === 0) {
      return;
    }
    try {
      const payload: StoredRecommendedPage = {
        v: FORMAT,
        at: Date.now(),
        cursor: cursor,
        more: hasMore,
        posts: posts
      };
      const text: string = JSON.stringify(payload);
      if (text.length > MAX_CHARS) {
        hilog.warn(DOMAIN, TAG, 'recommended too big to cache: %{public}d chars', text.length);
        return;
      }
      store.putSync(AccountScope.slot(KEY_REC), text);
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'saved recommended n=%{public}d chars=%{public}d',
        posts.length, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save recommended failed: %{public}s', (error as Error).message);
    }
  }

  /** 读探索流第一页缓存（超过 `maxAgeMs` 就当没有）。 */
  static loadRecommended(maxAgeMs: number = MAX_AGE_MS): CachedRecommendedPage | null {
    const store: preferences.Preferences | null = FeedCache.store;
    if (store === null) {
      return null;
    }
    try {
      const text: string = store.getSync(AccountScope.slot(KEY_REC), '') as string;
      if (text.length === 0) {
        return null;
      }
      const dto: StoredRecommendedPage = JSON.parse(text) as StoredRecommendedPage;
      if ((dto.v ?? 0) !== FORMAT) {
        return null;
      }
      const at: number = dto.at ?? 0;
      const age: number = Date.now() - at;
      if (at <= 0 || age > maxAgeMs) {
        return null;
      }
      const raw: Array<SearchPost> = dto.posts ?? [];
      const posts: Array<SearchPost> = [];
      for (let index: number = 0; index < raw.length; index++) {
        // JSON 回来的是**普通对象**（没有方法），所以要按构造器重建 —— 瀑布流要用 aspect()。
        const one: SearchPost = raw[index];
        if (one === null || one === undefined || `${one.code ?? ''}`.length === 0) {
          continue;
        }
        posts.push(new SearchPost(one.code, one.coverUrl, one.width, one.height, one.isVideo,
          one.mediaId, one.videoUrl, one.originalVideoUrl, one.ownerUsername, one.ownerAvatarUrl,
          one.ownerId, one.caption, one.likeCount, one.commentCount, one.repostCount, one.liked,
          one.following, one.takenAt, one.mediaItems ?? []));
      }
      if (posts.length === 0) {
        return null;
      }
      return new CachedRecommendedPage(posts, dto.cursor ?? '', dto.more === true, age);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load recommended failed: %{public}s', (error as Error).message);
      return null;
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
      store.putSync(AccountScope.slot(KEY), text);
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
      const text: string = store.getSync(AccountScope.slot(KEY), '') as string;
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
