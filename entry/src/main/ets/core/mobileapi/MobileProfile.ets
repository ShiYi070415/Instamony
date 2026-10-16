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
 * ## 实测形状（2026-10-17，真机 + 已登录会话，见 `filesDir/Instarmony_scout.txt`）
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
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';

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
