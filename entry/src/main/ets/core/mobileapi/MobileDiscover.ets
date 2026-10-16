/*
 * 移动 API 的**探索 / 搜索**端点（对应 instagrapi 的 `ExploreMixin` + `FbSearchMixin`）。
 *
 * ## 为什么要有它（用户原话）
 *   "搜索推荐流和 reels 的 http 请求应该不是同一个，然后尽量把 reels/搜索/主页的数据加载速度提升，
 *    参考 instagrapi 的协议逻辑。"
 *
 * 在这之前，搜索页那面**推荐网格**是排在 reels 后面吃同一份模板的（`NativeSearch.RECOMMEND_HINTS`
 * 里 `clips`/`reels` 那两条就是 reels 的 `PolarisClipsTabRootPaginationQuery`）—— 结果就是
 * "搜索推荐和 reels 是同一发请求"，拿到的也确实是同一批 clips。现在推荐网格改走**它自己那条**：
 * `GET /api/v1/discover/topical_explore/`（instagrapi 的 `explore_page`，官方 App 探索页那一发）。
 *
 * ## 实测形状（2026-10-17，真机 + 已登录会话，见 `filesDir/Instarmony_scout.txt`）
 *   • `GET discover/topical_explore/`（`module=explore_popular` / `cluster_id=explore_all:0` /
 *     `use_sectional_payload=true`）→ 200、1.30MB、4.7s（首屏那一发；预热过之后就快了）：
 *       `sectional_items[]` → 每条 `{ layout_type, feed_type, explore_item_info, layout_content }`，
 *       媒体在 **`layout_content.medias[].media`**（`feed_type=clips` / `media` 都有）；
 *       游标 = `max_id`（长串，`next_max_id` 这一版是 `"0"`）+ `session_paging_token`；
 *       还有 `more_available` / `rank_token`。
 *   • `GET fbsearch/account_serp/`（`search_surface=account_serp`）→ 200、32KB、1.9s：
 *       `users[]`（`pk` / `username` / `full_name` / `profile_pic_url` / `is_verified` /
 *       `is_private` / `friendship_status.following`）+ `page_token` / `has_more`。
 *   • `GET users/search/`（`search_surface=user_search_page`、参数是 `q`）→ 200、43KB、2.0s：
 *       老 v1 那条（`users[].pk` 也齐），account_serp 不可用时兜底。
 *   • `GET fbsearch/top_serp/`（`search_surface=top_serp`）→ 200、595KB、3.8s：
 *       帖子结果在 `media_grid.sections[].layout_content.medias[].media`，
 *       游标 `media_grid.next_max_id`、`has_more` / `reels_max_id`。
 *
 * ## 只搬运、不解析
 * 这里把**原始节点**交给调用方（`Array<Object>`），字段映射留给 `core/NativeSearch`（它有现成的
 * `readPost`）。理由：映射要跟界面模型走，放这儿等于把两套字段知识分在两个文件里；
 * 而且 mobileapi 只 import model，不 import core，天然避开"core ↔ mobileapi"的循环依赖。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
import { SearchUser } from '../../model/Search';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileDiscover';

/** 探索流一次最多收几个媒体节点（1.3MB 那一发最多也就几十条，防脏数据）。 */
const MAX_MEDIAS: number = 72;
/** 账号搜索结果一次最多几条（account_serp 一次给 20，v1 给 25）。 */
const MAX_USERS: number = 40;
/** `layout_content` 里可能装着媒体的几个键（见文件头的实测形状）。 */
const LAYOUT_MEDIA_KEYS: Array<string> = ['medias', 'fill_items'];

/** 一页媒体节点（探索流 / 搜索帖子共用）。 */
export class MobileMediaPage {
  /** **原始**媒体对象（字段映射由调用方做，见文件头）。 */
  readonly medias: Array<Object>;
  readonly nextCursor: string;
  readonly hasMore: boolean;
  readonly ms: number;
  readonly at: number;

  constructor(medias: Array<Object>, nextCursor: string, hasMore: boolean, ms: number) {
    this.medias = medias;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    this.ms = ms;
    this.at = Date.now();
  }
}

/** 一页账号搜索结果。 */
export class MobileUserPage {
  readonly users: Array<SearchUser>;
  readonly pageToken: string;
  readonly hasMore: boolean;
  readonly ms: number;

  constructor(users: Array<SearchUser>, pageToken: string, hasMore: boolean, ms: number) {
    this.users = users;
    this.pageToken = pageToken;
    this.hasMore = hasMore;
    this.ms = ms;
  }
}

export class MobileDiscover {
  /** 探索流用的会话 id（`session_id` 参数；一份够用，不必每发都换）。 */
  private static sessionId: string = '';
  /** 上次探索流给的 `rank_token`（翻页与搜索帖子都要回传）。 */
  private static rankToken: string = '';

  static rankTokenNow(): string {
    return MobileDiscover.rankToken;
  }

  /**
   * 探索页（推荐网格）第一页/翻页。
   *
   * @param cursor 上一页给的游标（`max_id`）；空 = 第一页
   * @param priority 排队优先级（用户点开搜索页那一发传 interactive，预热传 warm）
   */
  static async explore(cursor: string = '', priority: number = ApiThrottle.warm())
    : Promise<MobileMediaPage | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'explore skipped: no session');
      return null;
    }
    if (MobileDiscover.sessionId.length === 0) {
      // `session_id` 只是个"这一次探索会话"的标识，用设备 uuid 就够（同一台设备 = 同一个会话）。
      MobileDiscover.sessionId = identity.uuid.length > 0 ? identity.uuid : identity.phoneId;
    }
    const params: string = 'is_prefetch=false&omit_cover_media=true'
      + `&max_id=${encodeURIComponent(cursor)}`
      + '&module=explore_popular&reels_configuration=hide_hero&use_sectional_payload=true'
      + `&timezone_offset=${encodeURIComponent(`${identity.timezoneOffset}`)}`
      + `&cluster_id=${encodeURIComponent('explore_all:0')}`
      + `&session_id=${encodeURIComponent(MobileDiscover.sessionId)}`
      + '&include_fixed_destinations=true';
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(
      'discover/topical_explore/', '', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'explore failed: %{public}s', result.summary());
      return null;
    }
    const parsed: Record<string, Object> | null = MobileDiscover.parse(result.body);
    if (parsed === null) {
      hilog.warn(DOMAIN, TAG, 'explore non-json bytes=%{public}d', result.bytes);
      return null;
    }
    const token: string = MobileDiscover.firstText(parsed, ['rank_token']);
    if (token.length > 0) {
      MobileDiscover.rankToken = token;
    }
    const sections: Array<Object> = MobileDiscover.objectsOf(parsed['sectional_items']);
    const medias: Array<Object> = [];
    for (let index: number = 0; index < sections.length; index++) {
      MobileDiscover.collectSection(sections[index], medias);
      if (medias.length >= MAX_MEDIAS) {
        break;
      }
    }
    const cursorNext: string = MobileDiscover.exploreCursor(parsed);
    const more: boolean = MobileDiscover.boolOf(parsed, 'more_available');
    hilog.info(DOMAIN, TAG,
      'explore ok sections=%{public}d medias=%{public}d more=%{public}s ms=%{public}d bytes=%{public}d',
      sections.length, medias.length, `${more}`, Date.now() - started, result.bytes);
    if (medias.length === 0) {
      return null;
    }
    return new MobileMediaPage(medias, cursorNext, more, Date.now() - started);
  }

  /**
   * 按关键词搜**帖子**（`fbsearch/top_serp/` 的 `media_grid`）。
   *
   * 与探索流的区别：这一条带 `query`，是"搜这个词出来的帖子"，而探索流是"为你推荐"。
   */
  static async mediaSearch(query: string, nextMaxId: string = '', rankToken: string = '',
                           priority: number = ApiThrottle.warm()): Promise<MobileMediaPage | null> {
    const text: string = query.trim();
    if (text.length === 0) {
      return null;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return null;
    }
    const token: string = rankToken.length > 0 ? rankToken
      : (MobileDiscover.rankToken.length > 0 ? MobileDiscover.rankToken : identity.uuid);
    let params: string = 'search_surface=top_serp'
      + `&timezone_offset=${encodeURIComponent(`${identity.timezoneOffset}`)}`
      + `&query=${encodeURIComponent(text)}&rank_token=${encodeURIComponent(token)}`;
    if (nextMaxId.length > 0) {
      params += `&next_max_id=${encodeURIComponent(nextMaxId)}`;
    }
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(
      'fbsearch/top_serp/', '', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'mediaSearch failed: %{public}s', result.summary());
      return null;
    }
    const parsed: Record<string, Object> | null = MobileDiscover.parse(result.body);
    if (parsed === null) {
      return null;
    }
    const grid: Record<string, Object> | null = MobileDiscover.objectOf(parsed['media_grid']);
    if (grid === null) {
      hilog.info(DOMAIN, TAG, 'mediaSearch: no media_grid');
      return null;
    }
    const sections: Array<Object> = MobileDiscover.objectsOf(grid['sections']);
    const medias: Array<Object> = [];
    for (let index: number = 0; index < sections.length; index++) {
      MobileDiscover.collectSection(sections[index], medias);
      if (medias.length >= MAX_MEDIAS) {
        break;
      }
    }
    const tokenNext: string = MobileDiscover.firstText(grid, ['rank_token']);
    if (tokenNext.length > 0) {
      MobileDiscover.rankToken = tokenNext;
    }
    const more: boolean = MobileDiscover.boolOf(grid, 'has_more');
    hilog.info(DOMAIN, TAG, 'mediaSearch q=%{public}s sections=%{public}d medias=%{public}d ms=%{public}d',
      text, sections.length, medias.length, Date.now() - started);
    if (medias.length === 0) {
      return null;
    }
    return new MobileMediaPage(medias, MobileDiscover.firstText(grid, ['next_max_id']), more,
      Date.now() - started);
  }

  /**
   * 搜账号。先走 v2 SERP（`fbsearch/account_serp/`：更小更快），失败退回老 v1（`users/search/`）。
   *
   * `friendship_status.following` v2 会给（v1 不一定），调用方（core/NativeSearch）用不上就忽略。
   */
  static async accounts(query: string, pageToken: string = '',
                        priority: number = ApiThrottle.warm()): Promise<MobileUserPage | null> {
    const text: string = query.trim();
    if (text.length === 0) {
      return null;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return null;
    }
    const timezone: string = encodeURIComponent(`${identity.timezoneOffset}`);
    let params: string = 'search_surface=account_serp'
      + `&timezone_offset=${timezone}&query=${encodeURIComponent(text)}`;
    if (pageToken.length > 0) {
      params += `&page_token=${encodeURIComponent(pageToken)}`;
    }
    const started: number = Date.now();
    const v2: MobileResult = await MobileRequest.send(
      'fbsearch/account_serp/', '', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (v2.ok) {
      const users: Array<SearchUser> = MobileDiscover.usersOfBody(v2.body);
      hilog.info(DOMAIN, TAG, 'accounts v2 q=%{public}s n=%{public}d ms=%{public}d bytes=%{public}d',
        text, users.length, Date.now() - started, v2.bytes);
      if (users.length > 0) {
        return MobileDiscover.userPage(v2.body, users, Date.now() - started);
      }
    } else {
      hilog.info(DOMAIN, TAG, 'accounts v2 miss: %{public}s', v2.summary());
    }
    // v1 兜底（参数名是 `q`，不是 `query`）。
    const v1: MobileResult = await MobileRequest.send(
      'users/search/', '',
      `search_surface=user_search_page&timezone_offset=${timezone}&count=30`
      + `&q=${encodeURIComponent(text)}`, true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!v1.ok) {
      hilog.warn(DOMAIN, TAG, 'accounts v1 failed: %{public}s', v1.summary());
      return null;
    }
    const users: Array<SearchUser> = MobileDiscover.usersOfBody(v1.body);
    hilog.info(DOMAIN, TAG, 'accounts v1 q=%{public}s n=%{public}d ms=%{public}d bytes=%{public}d',
      text, users.length, Date.now() - started, v1.bytes);
    if (users.length === 0) {
      return null;
    }
    return MobileDiscover.userPage(v1.body, users, Date.now() - started);
  }

  // ------------------------------------------------------------------ 解析

  /** `{users:[…]}` → 模型（`pk` 一定要带上：点一下要进原生用户主页）。 */
  private static usersOfBody(body: string): Array<SearchUser> {
    const parsed: Record<string, Object> | null = MobileDiscover.parse(body);
    if (parsed === null) {
      return [];
    }
    const raw: Array<Object> = MobileDiscover.objectsOf(parsed['users']);
    const out: Array<SearchUser> = [];
    for (let index: number = 0; index < raw.length && out.length < MAX_USERS; index++) {
      const one: Record<string, Object> | null = MobileDiscover.objectOf(raw[index]);
      if (one === null) {
        continue;
      }
      const username: string = MobileDiscover.firstText(one, ['username']);
      if (username.length === 0) {
        continue;
      }
      out.push(new SearchUser(username,
        MobileDiscover.firstText(one, ['full_name']),
        MobileDiscover.firstText(one, ['profile_pic_url', 'profile_pic_url_hd']),
        MobileDiscover.boolOf(one, 'is_verified'),
        MobileDiscover.boolOf(one, 'is_private'),
        MobileDiscover.firstText(one, ['pk', 'pk_id', 'id', 'strong_id__'])));
    }
    return out;
  }

  private static userPage(body: string, users: Array<SearchUser>, ms: number): MobileUserPage {
    const parsed: Record<string, Object> | null = MobileDiscover.parse(body);
    const token: string = parsed === null ? '' : MobileDiscover.firstText(parsed, ['page_token']);
    const more: boolean = parsed !== null && MobileDiscover.boolOf(parsed, 'has_more');
    return new MobileUserPage(users, token, more, ms);
  }

  /**
   * 从一个 `sectional_items[i]` 里收媒体节点。
   *
   * 三种包装都要认（IG 在同一份响应里混着用）：
   *   · `layout_content.medias[].media`（网格）
   *   · `layout_content.fill_items[].media`（补位）
   *   · `layout_content.one_by_two_item.media` / `.clips.items[].media`（大格 + 竖排 clips）
   * 拿不到 `media` 包装时，**把条目本身当媒体对象**（字段够用就够用，映射那边会自己剔除）。
   */
  private static collectSection(section: Object, out: Array<Object>): void {
    const one: Record<string, Object> | null = MobileDiscover.objectOf(section);
    if (one === null) {
      return;
    }
    const layout: Record<string, Object> | null = MobileDiscover.objectOf(one['layout_content']);
    if (layout === null) {
      return;
    }
    for (let index: number = 0; index < LAYOUT_MEDIA_KEYS.length; index++) {
      const list: Array<Object> = MobileDiscover.objectsOf(layout[LAYOUT_MEDIA_KEYS[index]]);
      for (let at: number = 0; at < list.length; at++) {
        MobileDiscover.pushMedia(list[at], out);
      }
    }
    const big: Record<string, Object> | null = MobileDiscover.objectOf(layout['one_by_two_item']);
    if (big !== null) {
      MobileDiscover.pushMedia(big, out);
      const clips: Record<string, Object> | null = MobileDiscover.objectOf(big['clips']);
      if (clips !== null) {
        const items: Array<Object> = MobileDiscover.objectsOf(clips['items']);
        for (let at: number = 0; at < items.length; at++) {
          MobileDiscover.pushMedia(items[at], out);
        }
      }
    }
  }

  /** 一条网格条目 → 媒体对象（有 `media` 包装就剥一层），并按 `pk` 去重。 */
  private static pushMedia(entry: Object, out: Array<Object>): void {
    if (out.length >= MAX_MEDIAS) {
      return;
    }
    const one: Record<string, Object> | null = MobileDiscover.objectOf(entry);
    if (one === null) {
      return;
    }
    const wrapped: Record<string, Object> | null = MobileDiscover.objectOf(one['media']);
    const media: Record<string, Object> = wrapped === null ? one : wrapped;
    const id: string = MobileDiscover.firstText(media, ['pk', 'id', 'strong_id__', 'code']);
    if (id.length === 0) {
      return;
    }
    // 去重：同一个媒体在 sections 里可能因为布局重复出现。
    for (let index: number = 0; index < out.length; index++) {
      const seen: Record<string, Object> | null = MobileDiscover.objectOf(out[index]);
      if (seen === null) {
        continue;
      }
      if (MobileDiscover.firstText(seen, ['pk', 'id', 'strong_id__', 'code']) === id) {
        return;
      }
    }
    out.push(media);
  }

  /**
   * 探索流的下一页游标。
   *
   * 实测这一版：`next_max_id` 是 `"0"`（没意义），真游标在 **`max_id`**（105+ 字符的长串），
   * `session_paging_token` 与它同值。所以按 `max_id` → `session_paging_token` → `next_max_id`
   * 的顺序取，并且**跳过 `"0"`**（否则第二页会退化成第一页）。
   */
  private static exploreCursor(parsed: Record<string, Object>): string {
    const names: Array<string> = ['max_id', 'session_paging_token', 'next_max_id'];
    for (let index: number = 0; index < names.length; index++) {
      const value: string = MobileDiscover.firstText(parsed, [names[index]]);
      if (value.length > 0 && value !== '0') {
        return value;
      }
    }
    return '';
  }

  // ------------------------------------------------------------------ 小工具

  private static parse(text: string): Record<string, Object> | null {
    try {
      return JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      return null;
    }
  }

  private static objectOf(value: Object | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || Array.isArray(value)) {
      return null;
    }
    if (typeof value !== 'object') {
      return null;
    }
    return value as Record<string, Object>;
  }

  private static objectsOf(value: Object | undefined): Array<Object> {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    return value as Array<Object>;
  }

  private static firstText(holder: Record<string, Object>, names: Array<string>): string {
    for (let index: number = 0; index < names.length; index++) {
      const value: Object | undefined = holder[names[index]];
      if (value === undefined || value === null) {
        continue;
      }
      const text: string = typeof value === 'string' ? value as string : `${value}`;
      if (text.length > 0 && text !== 'null' && text !== 'undefined') {
        return text;
      }
    }
    return '';
  }

  private static boolOf(holder: Record<string, Object>, name: string): boolean {
    const value: Object | undefined = holder[name];
    return value === true || `${value}` === 'true';
  }
}
