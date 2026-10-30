/*
 * 移动 API 的**用户资料 / 主页网格**端点（对应 instagrapi 的 `UserMixin.user_info* / user_medias`）。
 *
 * ## 为什么要有它（用户原话）
 *   "尽量把 reels/搜索/主页的数据加载速度提升，参考 instagrapi 的协议逻辑。"
 *
 * 主页在这之前是**模板回放**（`core/NativeProfile`：先从隐藏网页抓 `PolarisProfilePageContentQuery` /
 * `PolarisProfilePostsQuery` 的模板，再照原样重发）。没有模板时还要**导航共用网页**过去等它水合
 * —— 那是"用户主页要等好几秒"的主因。instagrapi 取这两样东西各只要**一发移动端 GET**：
 *   · 头部：`GET /api/v1/users/{pk}/info/`（或按用户名 `users/{username}/usernameinfo/`）
 *   · 网格：`GET /api/v1/feed/user/{pk}/?count=N[&max_id=…]`
 *
 * ## 实测形状（2026-10-17，真机 + 已登录会话，见 `filesDir/Instamony_scout.txt`）
 *   • `GET feed/user/{pk}/?count=12` → 200、377KB、2.2s：
 *       `items[]`（与信息流同形状：`pk` / `id` / `code` / `media_type` / `carousel_media` /
 *       `image_versions2.candidates` / `original_width` / `original_height` / …）
 *       + `more_available` / `next_max_id` / `num_results` + `user{…}`。
 *   • `GET users/{pk}/info/` → 200（缩略一发，**0.5s 上下**）：
 *       `user{ pk, username, full_name, biography, external_url, profile_pic_url,
 *              hd_profile_pic_url_info.url, is_private, is_verified,
 *              follower_count, following_count, media_count, friendship_status{following} }`。
 *
 * ## 只搬运、不解析
 * 返回原始节点（`user` / `items`），字段映射留给 `core/NativeProfile`（它有现成的 `headerOf` /
 * `postOf`）。这样 mobileapi 只依赖 model，不会和 core 形成循环 import。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
// 解析丢线程池（见 parseAsync 与 workers/ProfileParseTask）。
import { taskpool } from '@kit.ArkTS';
import { parseProfileGrid } from '../../workers/ProfileParseTask';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
import { ProfileHighlight } from '../../model/Profile';
import { SUPPORTED_CAPABILITIES } from './MobileConfig';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileProfile';

/** 网格一页要几条（instagrapi 的 `user_medias(amount=…)`；IG 一页给 12 上下）。 */
const GRID_COUNT: number = 24;

/** 一发移动端 GET 的结果：只搬原始节点（见文件头）。 */
export class MobileUserBody {
  readonly user: Record<string, Object>;
  readonly ms: number;
  readonly bytes: number;

  constructor(user: Record<string, Object>, ms: number, bytes: number) {
    this.user = user;
    this.ms = ms;
    this.bytes = bytes;
  }
}

/** 主页网格一页（原始媒体节点）。 */
export class MobileGridPage {
  readonly items: Array<Object>;
  readonly nextCursor: string;
  readonly hasMore: boolean;
  readonly ms: number;
  readonly bytes: number;

  constructor(items: Array<Object>, nextCursor: string, hasMore: boolean, ms: number, bytes: number) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    this.ms = ms;
    this.bytes = bytes;
  }
}

export class MobileProfile {
  /**
   * **某个分页端点到底通不通**（按 kind 记，学到就记住）。
   *
   * 为什么要"学过"这套：`feed/user/{pk}/`（帖子）与 `usertags/{pk}/feed/`（被标注）是
   * 有据可查的私有端点，直接乐观使用；而 `clips/user/`（Reels 分页）与收藏那两条是**试出来的**
   * —— 万一这一版 IG 不给，乐观使用会让分页直接报"读取失败"（原来靠模板那条路是好用的）。
   * 所以那两条**先按原路走**，等哪次真通了再把标记立起来（见 core/NativeProfile.fetchPosts）。
   */
  private static usable: Map<string, boolean> = new Map<string, boolean>();

  /** `feed/user/{pk}/` 与 `usertags/{pk}/feed/` 是稳的（见上面的说明）。 */
  static tabOptimistic(kind: string): boolean {
    return kind === 'posts' || kind === 'tagged';
  }

  /** 这一版试出来能不能用（`tabOptimistic` 为真时恒 true）。 */
  static tabUsable(kind: string): boolean {
    if (MobileProfile.tabOptimistic(kind)) {
      return true;
    }
    return MobileProfile.usable.get(kind) === true;
  }

  private static noteUsable(kind: string, ok: boolean): void {
    if (ok) {
      MobileProfile.usable.set(kind, true);
    }
  }

  /**
   * 主页**四个分页**里的一段（"我的"页下面那四个分段按钮）。
   *
   * @param kind posts（帖子）/ clips（Reels）/ saved（收藏）/ tagged（被标注）
   * @returns 原始媒体节点那一页；认不出 kind 或端点不可用给 null（调用方退回模板那条路）
   */
  static async tab(kind: string, userId: string, maxId: string = '', count: number = GRID_COUNT,
                   priority: number = ApiThrottle.warm()): Promise<MobileGridPage | null> {
    if (kind === 'posts') {
      return await MobileProfile.medias(userId, maxId, count, priority);
    }
    if (kind === 'tagged') {
      // instagram-private-api 的 `UsertagsFeed`：`GET /api/v1/usertags/{pk}/feed/`
      const page: MobileGridPage | null = await MobileProfile.gridGet(
        `usertags/${encodeURIComponent(userId)}/feed/`, maxId, 'tagged', priority, count);
      return page;
    }
    if (kind === 'clips') {
      // instagrapi 的 `user_clips`：`POST /api/v1/clips/user/`（表单带 target_user_id）。
      const page: MobileGridPage | null = await MobileProfile.gridPost(
        'clips/user/', userId, count, maxId, 'clips', priority);
      return page;
    }
    if (kind === 'saved') {
      // 收藏：候选 `feed/saved/`（通了就记住，之后这个分页也走移动端）。
      const page: MobileGridPage | null = await MobileProfile.gridGet('feed/saved/', maxId, 'saved',
        priority, count);
      return page;
    }
    return null;
  }

  /**
   * 最近一次失败的原因（`challenge_required` / `feedback_required` / `http-…`）。
   *
   * 为什么要往上传：`NativeProfile` 与视图模型只拿得到"null"，看不出是网络问题、
   * 限流、还是**账号被要求安全验证** —— 而那几种在界面上该说的话完全不同
   * （尤其 `challenge_required`：必须让用户去网页里过验证，重试多少次都没用）。
   */
  private static last: string = '-';

  static lastDetail(): string {
    return MobileProfile.last;
  }

  /** 一发 GET 网格（被标注 / 收藏那两条用）。 */
  private static async gridGet(endpoint: string, maxId: string, kind: string,
                               priority: number, count: number = GRID_COUNT): Promise<MobileGridPage | null> {
    let params: string = `count=${count}`;
    if (maxId.length > 0) {
      params += `&max_id=${encodeURIComponent(maxId)}`;
    }
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(endpoint, '', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!result.ok) {
      MobileProfile.last = `tab[${kind}]:${result.error}`;
      hilog.info(DOMAIN, TAG, 'tab[%{public}s] miss (%{public}s): %{public}s',
        kind, endpoint, result.summary());
      return null;
    }
    const page: MobileGridPage | null = await MobileProfile.gridOf(result, kind, started);
    MobileProfile.noteUsable(kind, page !== null);
    return page;
  }

  /**
   * 一发 POST 网格（Reels 分页那条用：表单要 `target_user_id`）。
   *
   * ⚠️ 实测（2026-10-17）：把 `target_user_id` 只放进**签名体**时，IG 回
   * `400 {"message":"target_user_id is required"}` —— 说明这条端点是从**查询串**读这个参数的
   * （instagrapi 的 `user_clips` 传的也是 `params`）。所以先按查询串发，被拒再按签名体发一次
   * （两条都留着：换版本时哪条通就用哪条，失败也只是多一发）。
   */
  private static async gridPost(endpoint: string, userId: string, count: number, maxId: string,
                                kind: string, priority: number): Promise<MobileGridPage | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return null;
    }
    const data: Record<string, Object> = MobileRequest.withExtraData(identity);
    data['page_size'] = count;
    if (maxId.length > 0) {
      data['max_id'] = maxId;
    }
    data['target_user_id'] = userId;
    // instagrapi 的 `user_clips_paginated_v1` 多带这一项（官方 App 也带）：不带的话个别账号
    // 只回视频之外的条目，页里能认出多少算多少。留着对齐参考实现，代价为 0。
    data['include_feed_video'] = 'true';
    /*
     * **先发"学到的"那条，失败再换另一条**（`postUnsigned` 只记方向，不当作硬开关）。
     *
     * 背景（真机实测 2026-10-22）：这条端点只认**未签名**的表单体 ——
     * 签名体把字段包进 `signed_body=`，IG 看不到 `target_user_id`，回
     * `400 target_user_id is required`（白花 4.3 秒 + 一个错误请求，每次进程只便宜一次）。
     * 所以默认方向就是**未签名优先**；哪天真有账号只认签名体，反过来的那一发会把它纠正回来。
     * 每一发都带兜底（不是 `return postOnce(...)`）：换版本时哪条通就用哪条。
     */
    const order: Array<boolean> = MobileProfile.postUnsigned ? [false, true] : [true, false];
    for (let index: number = 0; index < order.length; index++) {
      const signed: boolean = order[index];
      const page: MobileGridPage | null = await MobileProfile.postOnce(endpoint, data, maxId, kind,
        priority, signed);
      if (page !== null) {
        const wantUnsigned: boolean = !signed;
        if (MobileProfile.postUnsigned !== wantUnsigned) {
          MobileProfile.postUnsigned = wantUnsigned;
          hilog.info(DOMAIN, TAG, 'tab[%{public}s] learned: %{public}s form body works',
            kind, signed ? 'signed' : 'unsigned');
        }
        return page;
      }
    }
    return null;
  }

  /**
   * 这条端点的表单体优先发哪种形态（学到的方向，见 gridPost）。
   *
   * **默认未签名**：`clips/user/` 实测只认它（签名体一律 400）。默认值反过来时，每次冷启动
   * 第一个作者页都要先白打一发 400 —— 实测那一下要 4.3 秒，正是"首屏之后第一页最慢"的原因。
   */
  private static postUnsigned: boolean = true;

  /** 发一次网格 POST（`signed=false` = 不包签名体）。 */
  private static async postOnce(endpoint: string, data: Record<string, Object>, maxId: string,
                                kind: string, priority: number,
                                signed: boolean): Promise<MobileGridPage | null> {
    let params: string = `target_user_id=${encodeURIComponent(`${data['target_user_id'] ?? ''}`)}`;
    if (maxId.length > 0) {
      params += `&max_id=${encodeURIComponent(maxId)}`;
    }
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(endpoint, MobileRequest.formOf(data), params,
      signed, null, new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'tab[%{public}s] form miss signed=%{public}s: %{public}s',
        kind, `${signed}`, result.summary());
      return null;
    }
    const page: MobileGridPage | null = await MobileProfile.gridOf(result, kind, started);
    MobileProfile.noteUsable(kind, page !== null);
    return page;
  }

  /** 网格响应 → 一页（`items` + 游标 + 还有没有）。 */
  /**
   * **解析走线程池**（A1 批次·个人页）：只把 `JSON.parse` 递出去，摘字段仍在主线程。
   *
   * 个人页四个分页一页 100~300KB，解析在主线程会压住"切段那一帧"。线程池失败就退回
   * 主线程解析（行为不变，只是慢）。
   */
  private static async parseAsync(body: string): Promise<Record<string, Object> | null> {
    let parsed: Record<string, Object> | null = null;
    try {
      parsed = await taskpool.execute(parseProfileGrid, body) as Record<string, Object> | null;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'profile parse taskpool failed: %{public}s → main thread',
        (error as Error).message);
    }
    return parsed === null ? MobileProfile.parse(body) : parsed;
  }

  private static async gridOf(result: MobileResult, kind: string,
                              started: number): Promise<MobileGridPage | null> {
    const parsed: Record<string, Object> | null = await MobileProfile.parseAsync(result.body);
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, 'tab[%{public}s] non-json bytes=%{public}d', kind, result.bytes);
      return null;
    }
    const items: Array<Object> = MobileProfile.objectsOf(parsed['items']);
    /*
     * 游标 —— **两条端点给的形状不一样**（真机 2026-10-22 实测，别只读顶层）：
     *   · 网格类（`feed/user/{pk}/`、`usertags/…/feed/`、`feed/saved/`）→ 顶层 `next_max_id` / `max_id`
     *   · `clips/user/`（Reels 分页）→ **`paging_info.max_id`**，顶层压根没有 `next_max_id`
     *     （instagrapi 的 `user_clips_paginated_v1` 也是从 `paging_info.max_id` 取的）
     * 只读顶层的时候，`clips/user/` 的游标永远是空串 → 每个作者只拿到最新的 12 条就被当成
     * "已经到底"从补货池里删掉 → 刷几十条之后整个视频流只剩重复内容（用户报的
     * "全部都是固定重复的、到最底无法刷新新的"就是这两个原因之一）。
     */
    const paging: Record<string, Object> | null = MobileProfile.objectOf(parsed['paging_info']);
    const top: string = MobileProfile.firstText(parsed, ['next_max_id', 'max_id']);
    const nested: string = paging === null ? ''
      : MobileProfile.firstText(paging, ['max_id', 'next_max_id']);
    const cursor: string = top.length > 0 ? top : nested;
    const more: boolean = MobileProfile.boolOf(parsed, 'more_available')
      || (paging !== null && MobileProfile.boolOf(paging, 'more_available'));
    const ms: number = Date.now() - started;
    hilog.info(DOMAIN, TAG,
      'tab[%{public}s] ok items=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d bytes=%{public}d',
      kind, items.length, `${more}`, cursor.length, ms, result.bytes);
    return new MobileGridPage(items, cursor, more, ms, result.bytes);
  }

  /**
   * 头部：优先按数字 id（`users/{pk}/info/`），没有 id 时按用户名（`users/{username}/usernameinfo/`）。
   *
   * 两条都是 instagrapi 的原样路径（见 `user_info` / `user_info_by_username`）。
   */
  static async info(userId: string, username: string,
                    priority: number = ApiThrottle.warm()): Promise<MobileUserBody | null> {
    const id: string = userId.trim();
    const name: string = username.trim();
    if (id.length === 0 && name.length === 0) {
      return null;
    }
    const endpoint: string = id.length > 0
      ? `users/${encodeURIComponent(id)}/info/`
      : `users/${encodeURIComponent(name)}/usernameinfo/`;
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(endpoint, '', '', true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'info miss (%{public}s): %{public}s', endpoint, result.summary());
      return null;
    }
    const user: Record<string, Object> | null = MobileProfile.userOf(result.body);
    if (user === null) {
      hilog.info(DOMAIN, TAG, 'info: no user object (%{public}s) bytes=%{public}d',
        endpoint, result.bytes);
      return null;
    }
    const ms: number = Date.now() - started;
    hilog.info(DOMAIN, TAG, 'info ok (%{public}s) user=%{public}s ms=%{public}d bytes=%{public}d',
      endpoint, MobileProfile.firstText(user, ['username']), ms, result.bytes);
    return new MobileUserBody(user, ms, result.bytes);
  }

  /**
   * **精选快拍**（个人页高光那排）：`GET highlights_tray/{pk}/`。
   *
   * 对应 instagrapi 的 `user_highlights`。只取卡片要用的三样：id / 标题 / 封面
   * （封面优先 `cover_media.thumbnail_url`，否则在 `cover_media.image_versions2.candidates` 里挑）。
   * 拿不到就回空数组 —— 界面上那一排只留「+ 新」那颗。
   */
  static async highlights(userId: string,
                          priority: number = ApiThrottle.warm()): Promise<Array<ProfileHighlight>> {
    const id: string = userId.trim();
    const out: Array<ProfileHighlight> = [];
    if (id.length === 0) {
      return out;
    }
    const endpoint: string = `highlights/${encodeURIComponent(id)}/highlights_tray/`;
    /*
     * 端点照 instagrapi 的 `user_highlights_v1`：`highlights/<pk>/highlights_tray/`
     * （注意是**两段**，不是 `highlights_tray/<pk>/` —— 后者回一整页 HTML 404，踩过）。
     * instagrapi 把参数挂在 query 上；这里先按签名表单 POST，不成就退回 GET + query。
     */
    const body: Record<string, Object> = {};
    body['supported_capabilities_new'] = SUPPORTED_CAPABILITIES;
    const opts: MobileOptions = new MobileOptions(ApiThrottle.MOBILE, priority);
    let result: MobileResult = await MobileRequest.send(endpoint, MobileRequest.formOf(body), '',
      true, null, opts);
    if (!result.ok) {
      const params: string =
        `supported_capabilities_new=${encodeURIComponent(SUPPORTED_CAPABILITIES)}`;
      result = await MobileRequest.send(endpoint, '', params, true, null, opts);
    }
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'highlights miss: %{public}s', result.summary());
      return out;
    }
    const parsed: Record<string, Object> | null = MobileProfile.parse(result.body);
    if (parsed === null) {
      return out;
    }
    const tray: Array<Object> = MobileProfile.objectsOf(parsed['tray']);
    for (let index: number = 0; index < tray.length; index++) {
      const one: Record<string, Object> | null = MobileProfile.objectOf(tray[index]);
      if (one === null) {
        continue;
      }
      const cover: Record<string, Object> | null = MobileProfile.objectOf(one['cover_media']);
      let coverUrl: string = '';
      if (cover !== null) {
        coverUrl = MobileProfile.firstText(cover, ['thumbnail_url', 'display_url']);
        if (coverUrl.length === 0) {
          coverUrl = MobileProfile.imageUrlOf(cover);
        }
        if (coverUrl.length === 0) {
          // 有的版本把封面放在 `cropped_image_version` 里（一个 {url,width,height} 对象）。
          const cropped: Record<string, Object> | null =
            MobileProfile.objectOf(cover['cropped_image_version']);
          if (cropped !== null) {
            coverUrl = MobileProfile.firstText(cropped, ['url']);
          }
        }
      }
      out.push(new ProfileHighlight(
        MobileProfile.firstText(one, ['id', 'strong_id__']),
        MobileProfile.firstText(one, ['title']),
        coverUrl,
        // 发布时间：`created_at` 是秒；没有就退回 `latest_reel_media`（最后一条的发布时刻）。
        MobileProfile.secondsToMs(MobileProfile.numberOf(one, 'created_at'))
          || MobileProfile.secondsToMs(MobileProfile.numberOf(one, 'latest_reel_media'))));
    }
    hilog.info(DOMAIN, TAG, 'highlights ok n=%{public}d bytes=%{public}d', out.length, result.bytes);
    return out;
  }

  /**
   * 主页网格（第一页 / 翻页）。
   *
   * @param userId 目标用户数字 id（`profile_grid_items` 之类都要它）
   * @param maxId  上一页的 `next_max_id`；空 = 第一页
   */
  static async medias(userId: string, maxId: string = '', count: number = GRID_COUNT,
                      priority: number = ApiThrottle.warm()): Promise<MobileGridPage | null> {
    const id: string = userId.trim();
    if (id.length === 0) {
      return null;
    }
    let params: string = `count=${count}`;
    if (maxId.length > 0) {
      params += `&max_id=${encodeURIComponent(maxId)}`;
    }
    const started: number = Date.now();
    const result: MobileResult = await MobileRequest.send(
      `feed/user/${encodeURIComponent(id)}/`, '', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'medias miss uid=%{public}s: %{public}s', id, result.summary());
      return null;
    }
    const parsed: Record<string, Object> | null = MobileProfile.parse(result.body);
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, 'medias non-json uid=%{public}s bytes=%{public}d', id, result.bytes);
      return null;
    }
    const items: Array<Object> = MobileProfile.objectsOf(parsed['items']);
    const cursor: string = MobileProfile.firstText(parsed, ['next_max_id']);
    const more: boolean = MobileProfile.boolOf(parsed, 'more_available');
    const ms: number = Date.now() - started;
    hilog.info(DOMAIN, TAG,
      'medias ok uid=%{public}s items=%{public}d more=%{public}s ms=%{public}d bytes=%{public}d',
      id, items.length, `${more}`, ms, result.bytes);
    // 空 items 也回一页（"这个人确实没帖子"与"读失败"是两件事，见 NativeProfile.postsOf 的说明）。
    return new MobileGridPage(items, cursor, more, ms, result.bytes);
  }

  // ------------------------------------------------------------------ 小工具

  /** `{user:{…}}` 里的那个 `user`（顶层直接是 user 也算）。 */
  private static userOf(body: string): Record<string, Object> | null {
    const parsed: Record<string, Object> | null = MobileProfile.parse(body);
    if (parsed === null) {
      return null;
    }
    const wrapped: Record<string, Object> | null = MobileProfile.objectOf(parsed['user']);
    if (wrapped !== null) {
      return wrapped;
    }
    // `usernameinfo` 那条也是 `{user:{…}, status:"ok"}`；真出现裸 user 也认。
    return MobileProfile.firstText(parsed, ['username']).length > 0 ? parsed : null;
  }

  private static parse(text: string): Record<string, Object> | null {
    try {
      return JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      return null;
    }
  }

  /** 秒级时间戳 → 毫秒（0 / 负数给 0，别造出一个 1970 年）。 */
  private static secondsToMs(seconds: number): number {
    return seconds > 0 ? Math.round(seconds * 1000) : 0;
  }

  /** 取一个数字字段（缺/非数字给 0）。 */
  private static numberOf(holder: Record<string, Object>, key: string): number {
    const value: Object | undefined = holder[key];
    if (value === undefined || value === null) {
      return 0;
    }
    if (typeof value === 'number') {
      return value as number;
    }
    const parsed: number = Number(`${value}`);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  /** 一个媒体节点里最宽的封面图（`image_versions2.candidates`）；没有给空串。 */
  private static imageUrlOf(media: Record<string, Object>): string {
    const versions: Record<string, Object> | null = MobileProfile.objectOf(media['image_versions2']);
    if (versions === null) {
      return '';
    }
    const candidates: Array<Object> = MobileProfile.objectsOf(versions['candidates']);
    let best: string = '';
    let bestWidth: number = -1;
    for (let index: number = 0; index < candidates.length; index++) {
      const one: Record<string, Object> | null = MobileProfile.objectOf(candidates[index]);
      if (one === null) {
        continue;
      }
      const url: string = MobileProfile.firstText(one, ['url']);
      if (url.length === 0) {
        continue;
      }
      const widthValue: Object | undefined = one['width'];
      const width: number = typeof widthValue === 'number' ? widthValue as number : 0;
      if (width > bestWidth) {
        bestWidth = width;
        best = url;
      }
    }
    return best;
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
