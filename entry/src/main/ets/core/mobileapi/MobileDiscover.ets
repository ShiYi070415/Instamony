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
 * ## 实测形状（2026-10-17，真机 + 已登录会话，见 `filesDir/Instamony_scout.txt`）
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
import { util } from '@kit.ArkTS';
import { ApiThrottle } from '../ApiThrottle';
import { ExploreLanes, EXPLORE_LANE_SEARCH } from './ExploreLanes';
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

export class MobileMediaPage {  /** **原始**媒体对象（字段映射由调用方做，见文件头）。 */
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
  /**
   * 每条探索入口（首页为你推荐 / Reels / 搜索）各自的一条 `session_id`。
   *
   * 之前是一个字段、三条入口共用 —— IG 于是把它们当成同一个探索会话，section 组合与排序
   * 完全一样（"三个探索流内容重复"的一半原因）。现在按入口分开生成，见 laneSession。
   */
  private static laneSessions: Map<string, string> = new Map();
  /** 上次探索流给的 `rank_token`（翻页与搜索帖子都要回传）。 */
  private static rankToken: string = '';
  /**
   * 正在飞的探索流请求（`游标 → Promise`，见 explore）：同一游标只发一发。
   *
   * 首页推荐段、Reels 探索流、搜索推荐网格都要这条接口，冷启动时它们几乎同时要第一页。
   */
  private static inflightPages: Map<string, Promise<MobileMediaPage | null>> =
    new Map<string, Promise<MobileMediaPage | null>>();
  /** 刚拿回来的探索页（`游标 → 页`，只活 `EXPLORE_MEMO_MS`）。 */
  private static memoPages: Map<string, MobileMediaPage> = new Map<string, MobileMediaPage>();
  private static memoAtMs: Map<string, number> = new Map<string, number>();
  /**
   * 探索页缓存的存活时间（毫秒）。
   *
   * 20 秒：够让"首页/Reels/搜索三处几乎同时要第一页"共用一发，又短到不会让用户
   * 看到明显过期内容（下拉刷新那条路会绕过缓存重新要）。
   */
  private static readonly EXPLORE_MEMO_MS: number = 20000;
  /**
   * 作废代数（换账号时 +1）：作废之前发起、之后才回来的那一发**不许写进缓存**。
   *
   * 不这么做的话，换号瞬间在飞的那一发（上一个人的探索流）会被存进 memo，
   * 接下来 20 秒里新账号的首页/搜索都会读到别人的内容。
   */
  private static epoch: number = 0;

  /** 清空探索流缓存（换账号/退出登录时调，见 pages/Index.forgetAccountMemory）。 */
  static clearCache(): void {
    MobileDiscover.memoPages.clear();
    MobileDiscover.memoAtMs.clear();
    MobileDiscover.inflightPages.clear();
    MobileDiscover.rankToken = '';
    // 三条入口的 session_id 与跨入口去重台账都属于"上一个账号的探索状态"，一起清。
    MobileDiscover.laneSessions.clear();
    ExploreLanes.clear();
    MobileDiscover.epoch++;
    hilog.info(DOMAIN, TAG, 'explore cache cleared (epoch %{public}d)', MobileDiscover.epoch);
  }

  static rankTokenNow(): string {
    return MobileDiscover.rankToken;
  }

  /**
   * 探索页（推荐网格）第一页/翻页。
   *
   * @param cursor 上一页给的游标（`max_id`）；空 = 第一页
   * @param priority 排队优先级（用户点开搜索页那一发传 interactive，预热传 warm）
   * @param family 走哪条限速家族（见 core/ApiThrottle）。默认 `MOBILE`（搜索推荐网格用）；
   *               **Reels 传 `CLIPS`** —— 它和搜索推荐共用这一发请求，但"视频频道"和"搜索频道"
   *               被限流的概率不同，混在一条家族里会互相拖死。
   * @param lane 哪条入口在要（见 ExploreLanes 的 EXPLORE_LANE_*）：
   *             首页为你推荐 / Reels 探索流 / 搜索推荐网格。**它决定两件事**：
   *             ① 每个入口用自己的一条 `session_id`（IG 会把它们当不同探索会话，排序分叉）；
   *             ② 跨入口去重（同一张帖子在 10 分钟内只发给一个入口）。
   *             这就是"三个探索流内容重复"的修法（详见 ExploreLanes 的文件头）。
   */
  static async explore(cursor: string = '', priority: number = ApiThrottle.warm(),
                      family: string = ApiThrottle.MOBILE,
                      lane: string = EXPLORE_LANE_SEARCH): Promise<MobileMediaPage | null> {
    /*
     * **同一个探索游标只发一发**（单飞 + 短缓存，见 inflightPages / memoPages）。
     *
     * 真机冷启动现场：`discover/topical_explore/` 在 20 秒里被打了 **5 发、约 5MB**
     * —— 因为有三条互不知情的路都在用它，而且要的往往是**同一页**：
     *   · 首页「为你推荐」那一段（`FeedViewModel` → `NativeSearch.recommendedPage`）；
     *   · Reels 探索流（`NativeReels.viaExplore`）；
     *   · 搜索页推荐网格（`SearchViewModel` → 同一条 `recommendedPage`）。
     * 每一发 1MB 起、还要在全局闸门排队（并发只有 2），等于首屏在跟它抢通道。
     * 合并之后：同时在飞 → 后来者搭车；刚拿回来过（`EXPLORE_MEMO_MS` 内）→ 直接给回那份。
     *
     * **合并只在同一条入口内**（key 带 lane）：三条入口要的是"同一页但各自去重后的结果"，
     * 跨入口共享缓存会让它们拿回一模一样的列表 —— 那正是要修的重复问题。
     */
    const key: string = `explore|${lane}|${cursor}`;
    const memo: MobileMediaPage | undefined = MobileDiscover.memoPages.get(key);
    const memoAt: number | undefined = MobileDiscover.memoAtMs.get(key);
    if (memo !== undefined && memoAt !== undefined
      && Date.now() - memoAt <= MobileDiscover.EXPLORE_MEMO_MS) {
      hilog.info(DOMAIN, TAG, 'explore memo hit cursor=%{public}d age=%{public}dms',
        cursor.length, Date.now() - memoAt);
      return memo;
    }
    const joined: Promise<MobileMediaPage | null> | undefined =
      MobileDiscover.inflightPages.get(key);
    if (joined !== undefined) {
      hilog.info(DOMAIN, TAG, 'explore joined inflight cursor=%{public}d', cursor.length);
      return joined;
    }
    const task: Promise<MobileMediaPage | null> =
      MobileDiscover.exploreOnce(cursor, priority, family, lane);
    const epoch: number = MobileDiscover.epoch;
    MobileDiscover.inflightPages.set(key, task);
    try {
      const page: MobileMediaPage | null = await task;
      if (page !== null && MobileDiscover.epoch === epoch) {
        MobileDiscover.remember(key, page);
      }
      return page;
    } finally {
      if (MobileDiscover.inflightPages.get(key) === task) {
        MobileDiscover.inflightPages.delete(key);
      }
    }
  }

  /** 记一页（顺手控制条数，别让内存里攒一堆旧页）。 */
  private static remember(key: string, page: MobileMediaPage): void {
    if (MobileDiscover.memoPages.size >= 6) {
      MobileDiscover.memoPages.clear();
      MobileDiscover.memoAtMs.clear();
    }
    MobileDiscover.memoPages.set(key, page);
    MobileDiscover.memoAtMs.set(key, Date.now());
  }

  /** 真正发这一发探索请求（合并/缓存见 explore）。 */
  private static async exploreOnce(cursor: string, priority: number,
                                   family: string, lane: string): Promise<MobileMediaPage | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'explore skipped: no session');
      return null;
    }
    const sessionId: string = MobileDiscover.laneSession(lane, identity);
    const params: string = 'is_prefetch=false&omit_cover_media=true'
      + `&max_id=${encodeURIComponent(cursor)}`
      + '&module=explore_popular&reels_configuration=hide_hero&use_sectional_payload=true'
      + `&timezone_offset=${encodeURIComponent(`${identity.timezoneOffset}`)}`
      + `&cluster_id=${encodeURIComponent('explore_all:0')}`
      + `&session_id=${encodeURIComponent(sessionId)}`
      + '&include_fixed_destinations=true';
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(
      'discover/topical_explore/', '', params, true, null,
      new MobileOptions(family, priority));
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
    /*
     * **有游标就算「还有更多」**（IG 的 `more_available` 会瞎写）：
     * 探索流实测经常「给了 max_id 却把 more_available 写成 false」，按它拦就是
     * 用户报的「探索流拉到底显示没有更多了」—— 明明还能继续翻。
     * 真正的「到底」由**游标是否为空**表达（下一页取不到游标 = 到头）。
     */
    const more: boolean = MobileDiscover.boolOf(parsed, 'more_available') || cursorNext.length > 0;
    /*
     * **跨入口去重**（见 ExploreLanes）：这一页里已经被**别的**入口拿走的帖子剔掉，
     * 剩下的记到本入口名下。全被占住时 claim 会原样放行（宁可重复一次也别空屏）。
     */
    const kept: Array<Object> = MobileDiscover.claimForLane(lane, medias);
    hilog.info(DOMAIN, TAG,
      'explore ok lane=%{public}s sections=%{public}d medias=%{public}d kept=%{public}d'
      + ' more=%{public}s ms=%{public}d bytes=%{public}d',
      lane, sections.length, medias.length, kept.length, `${more}`,
      Date.now() - started, result.bytes);
    if (kept.length === 0) {
      return null;
    }
    return new MobileMediaPage(kept, cursorNext, more, Date.now() - started);
  }

  /**
   * 这一页里能发给定入口的那些媒体（按 ExploreLanes 的规则跨入口去重）。
   *
   * id 取法和 pushMedia 一致（`pk` → `id` → `strong_id__` → `code`）；
   * 取不到 id 的条目**一律保留**（不要因为认不出就丢内容）。
   */
  private static claimForLane(lane: string, medias: Array<Object>): Array<Object> {
    const ids: Array<string> = [];
    for (let index: number = 0; index < medias.length; index++) {
      const one: Record<string, Object> | null = MobileDiscover.objectOf(medias[index]);
      ids.push(one === null ? '' : MobileDiscover.firstText(one, ['pk', 'id', 'strong_id__', 'code']));
    }
    const allowed: Array<string> = ExploreLanes.claim(lane, ids);
    // 没有 id 的条目在 claim 里是空串，可能被误伤 —— 单独放行一次。
    const keep: Array<Object> = [];
    for (let index: number = 0; index < medias.length; index++) {
      const id: string = ids[index];
      if (id.length === 0 || allowed.indexOf(id) >= 0) {
        keep.push(medias[index]);
      }
    }
    return keep;
  }

  /**
   * 每条入口一个 `session_id`（第一次要的时候生成，之后固定）。
   *
   * 为什么要分：三条入口打的是同一个 `discover/topical_explore/`，`session_id` 是 IG 用来
   * 串"这一次探索会话"的；三条共用一个值时，section 组合与排序完全一样 —— 这就是
   * "三个探索流内容基本重复"的另一半原因（另一半是缓存/去重，见 explore 与 ExploreLanes）。
   * 用标准 UUID（不用 `uuid:lane` 这种拼接）：IG 可能校验格式，格式不对整发会被拒。
   */
  private static laneSession(lane: string, identity: MobileIdentity): string {
    const cached: string | undefined = MobileDiscover.laneSessions.get(lane);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    let created: string = '';
    try {
      created = util.generateRandomUUID(false);
    } catch (error) {
      created = '';
    }
    if (created.length === 0) {
      // 兜底：设备 uuid（至少保证同一台设备内稳定，不会崩）。
      created = identity.uuid.length > 0 ? identity.uuid : identity.phoneId;
    }
    MobileDiscover.laneSessions.set(lane, created);
    hilog.info(DOMAIN, TAG, 'explore lane=%{public}s session=%{public}s',
      lane, created.substring(0, 8));
    return created;
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
