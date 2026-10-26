/*
 * 搜索页推荐流的**落盘缓存**（需求："搜索页推荐帖子加载刷新的有点慢，优化一下缓存和加载逻辑"）。
 *
 * **存推荐第一页**（`page1_v1`）。切到搜索页时先把它铺出来（读盘 + 映射几十毫秒），
 * 网络那份回来再整体替换 —— 和首页信息流同一套"先画后刷"（见 core/FeedCache）。
 *
 * ## 存多久
 *   - 第一页：30 分钟（推荐流本来就变得快，放太久铺出来只会让人觉得"怎么都是老内容"）。
 *
 * ## 失败一律当作"没有缓存"
 * 读写任何一步出错都只记一行日志：它只是让搜索页更快，不该影响任何正常路径。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { AccountScope } from './AccountScope';
import { common } from '@kit.AbilityKit';
import { SearchPost } from '../model/Search';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SearchCache';
/** 第一页最多存几条（首屏三列瀑布流几屏的量）。 */
const MAX_SAVED: number = 36;

/** 落盘的 preferences 文件名与键。 */
const STORE: string = 'instarmony_search_cache';
const KEY_PAGE: string = 'page1_v1';
/** 缓存格式版本：改了结构就 +1，旧的一律当没有。 */
const FORMAT: number = 2;
/** 第一页的有效期（毫秒）：30 分钟。 */
const PAGE_MAX_AGE_MS: number = 30 * 60 * 1000;
/** 单份上限（字符）：防呆（一页 36 条的小结构约 10KB）。 */
const MAX_CHARS: number = 256 * 1024;

/**
 * 落盘的一条格子（字段名短，因为它要塞进 preferences）。
 *
 * **Reels 页要用到的字段也一起存**：搜索推荐流的格子点进去就是 Reels 页
 * （见 pages/Index.openSearchReels），那一页要视频地址、作者（含 id，关注按钮用）、
 * 正文和三个计数。以前这里只存封面与尺寸，于是**从缓存铺出来的那一版**点进 Reels 页
 * 就是"没作者、没正文、三个计数全空"，关注也点不动（用户报的问题）。
 */
interface StoredPost {
  /** code */
  c?: string;
  /** cover url */
  u?: string;
  w?: number;
  h?: number;
  /** isVideo */
  m?: boolean;
  /** 媒体数字 id（补视频地址要用） */
  id?: string;
  /** video url / original video url */
  vu?: string;
  ov?: string;
  /** 作者账号名 / 头像 / 数字 id */
  au?: string;
  av?: string;
  uid?: string;
  /** 正文 */
  cap?: string;
  /** 点赞 / 评论 / 转发数 */
  lk?: number;
  cm?: number;
  rp?: number;
  /** 本机点过赞没有 */
  lkd?: boolean;
  /** 分享 / 收藏数（同 ReelsCache 的 `sc` / `sv`：缓存铺出来的那版也要有这两颗数字） */
  sc?: number;
  sv?: number;
}

/** 落盘的第一页。 */
interface StoredPage {
  v?: number;
  at?: number;
  cursor?: string;
  more?: boolean;
  posts?: Array<StoredPost>;
}

/** 读回来的一份第一页（已通过版本与时效校验）。 */
export class CachedSearchPage {
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

export class SearchCache {
  private static store: preferences.Preferences | null = null;

  /** 打开缓存文件（EntryAbility.onCreate 里调一次即可；幂等）。 */
  static init(context: common.Context): void {
    if (SearchCache.store !== null) {
      return;
    }
    try {
      SearchCache.store = preferences.getPreferencesSync(context, { name: STORE });
      // 按账号分区（见 core/AccountScope）：搜索推荐也是按人给的。
      AccountScope.register(SearchCache.store, [KEY_PAGE]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  // ---- 推荐第一页 ----------------------------------------------------------

  /** 读推荐第一页（超过 maxAgeMs 就当没有）。 */
  static loadPage(maxAgeMs: number = PAGE_MAX_AGE_MS): CachedSearchPage | null {
    const store: preferences.Preferences | null = SearchCache.store;
    if (store === null) {
      return null;
    }
    try {
      const text: string = store.getSync(AccountScope.slot(KEY_PAGE), '') as string;
      if (text.length === 0) {
        return null;
      }
      const dto: StoredPage = JSON.parse(text) as StoredPage;
      if ((dto.v ?? 0) !== FORMAT) {
        return null;
      }
      const age: number = Date.now() - (dto.at ?? 0);
      if (age < 0 || age > maxAgeMs) {
        hilog.info(DOMAIN, TAG, 'page stale age=%{public}dms', age);
        return null;
      }
      const raw: Array<StoredPost> = dto.posts ?? [];
      const posts: Array<SearchPost> = [];
      for (let index: number = 0; index < raw.length; index++) {
        const one: StoredPost = raw[index];
        const code: string = one.c ?? '';
        const url: string = one.u ?? '';
        if (code.length === 0 || url.length === 0) {
          continue;
        }
        posts.push(new SearchPost(code, url, one.w ?? 0, one.h ?? 0, one.m === true,
          one.id ?? '', one.vu ?? '', one.ov ?? '', one.au ?? '', one.av ?? '', one.uid ?? '',
          one.cap ?? '', one.lk ?? 0, one.cm ?? 0, one.rp ?? 0, one.lkd === true,
          undefined, 0, [], one.sc ?? 0, one.sv ?? 0));
      }
      if (posts.length === 0) {
        return null;
      }
      hilog.info(DOMAIN, TAG, 'page hit n=%{public}d age=%{public}dms', posts.length, age);
      return new CachedSearchPage(posts, dto.cursor ?? '', dto.more === true, age);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'page load failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /** 存推荐第一页（同步写 + flush：数据量小，几十毫秒内完成）。 */
  static savePage(posts: Array<SearchPost>, cursor: string, hasMore: boolean): void {
    const store: preferences.Preferences | null = SearchCache.store;
    if (store === null || posts.length === 0) {
      return;
    }
    try {
      const out: Array<StoredPost> = [];
      // 只存前 MAX_SAVED 条：铺首屏够用，文件也小（用户真要往下滑时网络那份早回来了）。
      for (let index: number = 0; index < posts.length && index < MAX_SAVED; index++) {
        const post: SearchPost = posts[index];
        out.push({ c: post.code, u: post.coverUrl, w: post.width, h: post.height,
          m: post.isVideo, id: post.mediaId, vu: post.videoUrl, ov: post.originalVideoUrl,
          au: post.ownerUsername, av: post.ownerAvatarUrl, uid: post.ownerId,
          cap: post.caption, lk: post.likeCount, cm: post.commentCount,
          rp: post.repostCount, lkd: post.liked, sc: post.shareCount, sv: post.saveCount });
      }
      const payload: StoredPage = {
        v: FORMAT, at: Date.now(), cursor: cursor, more: hasMore, posts: out
      };
      const text: string = JSON.stringify(payload);
      if (text.length > MAX_CHARS) {
        hilog.warn(DOMAIN, TAG, 'page too big: %{public}d chars', text.length);
        return;
      }
      store.putSync(AccountScope.slot(KEY_PAGE), text);
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'page saved n=%{public}d chars=%{public}d', out.length, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'page save failed: %{public}s', (error as Error).message);
    }
  }
}
