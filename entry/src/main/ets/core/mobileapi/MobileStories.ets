/*
 * 移动 API 的**快拍**端点（对应 instagrapi 的 `StoryMixin`）。
 *
 * ## 为什么这条路值得走
 * 网页那条路（托盘模板 + `reels_media` 私有 REST）在部分会话上被 IG 按**来源**拒：
 * 测试者的诊断里 `reels_media` 回 500、`feed/user/<id>/story/` 回 400 challenge，
 * 而同一台设备换成移动端这套头（App-ID / UA / signed_body / Authorization）之后
 * **五发全通**（见 MobileProbe 的自检报告）。所以快拍改走这里，网页那条留作退路。
 *
 * ## 实测形状（2026-10-16，模拟器 + 已登录会话，见 `filesDir/Instarmony_mobile.txt`）
 *   • `POST /api/v1/feed/reels_tray/` → `{ tray: [ …213 条… ], status:"ok" }`，一条里：
 *       `id`（reel id，`user_reel` 时等于用户 pk）、`latest_reel_media`、`seen`、
 *       `media_count`、`media_ids`、`expiring_at`、`has_video`、`reel_type`、
 *       `user:{ pk, id, username, full_name, profile_pic_url, is_private, is_verified }`
 *     **注意：这一版 IG 的托盘不再带 `items`**（老 instagrapi 直接从 `tray[].items` 取第一张图），
 *     所以托盘只能给"环 + 头像 + 计数"，**媒体要按 id 现取**（下面两条）。
 *   • `GET /api/v1/feed/user/{pk}/story/` → `{ reel: { …, items:[media] }, status:"ok" }`
 *     （媒体在 `reel.items`，**不在顶层 `items`**；自己没发快拍时 `reel` 是 null）。
 *   • `GET /api/v1/feed/reels_media/?reel_ids=<裸 id>` → `{ reels: { "<id>": { items:[media] } } }`
 *     **JSON 数组形式（网页那条用的）回空 `{"reels":{},"status":"ok"}`** —— 只用裸 id。
 *   • media 里我们要的键：`media_type`（1 图 / 2 视频）、`image_versions2.candidates[]`（封面，
 *     实测 `2(640x1136)`）、`video_versions[]`、`original_width/original_height`、
 *     `taken_at`、`expiring_at`、`video_duration`、`pk`/`id`、`user`。
 *
 * ## 与 instagrapi 的差异
 *   只取"这两个端点的数据"，不做 story_viewers / seen 上报 / 删除这些写操作 ——
 *   本次移植的目标是**看得了快拍**，写操作留到有需求再说（也避免误触发风控）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
import { StoryItem, StoryReel, StoryTray, StoryTrayItem } from '../../model/Story';
import { SUPPORTED_CAPABILITIES } from './MobileConfig';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileStories';

/** 一层一层取对象时最多跟几层（防脏数据把解析拖死）。 */
const MAX_ALT_IDS: number = 3;

export class MobileStories {
  /**
   * 拉一次托盘（拿不到给 null）。
   *
   * 对应 instagrapi 的 `get_reels_tray_feed`：表单字段照抄（`reason` / `timezone_offset` /
   * `tray_session_id` / `request_id` / `page_size` / `_uuid` / `supported_capabilities_new`）。
   *
   * @param priority 排队优先级（见 ApiThrottle.acquire）：默认 WARM。
   */
  static async tray(priority: number = ApiThrottle.warm()): Promise<StoryTray | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'tray skipped: no session');
      return null;
    }
    const data: Record<string, Object> = {};
    data['supported_capabilities_new'] = SUPPORTED_CAPABILITIES;
    data['reason'] = 'cold_start';
    data['timezone_offset'] = `${identity.timezoneOffset}`;
    data['tray_session_id'] = identity.traySessionId;
    data['request_id'] = identity.requestId;
    data['page_size'] = MobileStories.TRAY_PAGE_SIZE;
    data['_uuid'] = identity.uuid;
    const none: Record<string, Object> = {};
    data['reel_tray_impressions'] = none;
    const result: MobileResult = await MobileRequest.send(
      'feed/reels_tray/', MobileRequest.formOf(data), '', true, null,
      new MobileOptions(ApiThrottle.STORIES, priority));
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'tray failed: %{public}s', result.summary());
      return null;
    }
    const parsed: Record<string, Object> | null = MobileStories.parse(result.body);
    if (parsed === null) {
      hilog.warn(DOMAIN, TAG, 'tray non-json len=%{public}d', result.body.length);
      return null;
    }
    const tray: Array<StoryTrayItem> = MobileStories.trayItems(parsed);
    if (tray.length === 0) {
      hilog.warn(DOMAIN, TAG, 'tray parsed empty');
      return null;
    }
    hilog.info(DOMAIN, TAG, 'tray ok n=%{public}d first=%{public}s unseen=%{public}d',
      tray.length, tray[0].username, tray[0].seen ? 0 : 1);
    return new StoryTray(tray);
  }

  /**
   * 拉某个用户当前未过期的全部快拍（拿不到给 null）。
   *
   * 两条路按"最可能成"的顺序试：
   *   ① `feed/user/{uid}/story/` —— 语义最贴（"这个人现在的快拍"），实测一发 35KB；
   *   ② `feed/reels_media/?reel_ids=<裸 id>` —— 备用 id（`altIds`，见 StoryTrayItem 的说明）
   *      与主 id 各试一发。托盘里那条 `id` 与用户 pk 不一致时（群组/精选那类），
   *      只有这一条能问到内容。
   *
   * @param altIds 托盘条目的备选 id（主 id 问不出内容时逐个再问）
   * @param username 托盘里已知的用户名（响应里拿不到时用它，别让界面显示空）
   * @param priority 排队优先级：用户点开的那一发传 `ApiThrottle.interactive()`（插到队头），
   *                 预缓存传默认的 WARM
   */
  static async reel(userId: string, altIds: Array<string> = [],
                    username: string = '',
                    priority: number = ApiThrottle.warm()): Promise<StoryReel | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || userId.length === 0) {
      return null;
    }
    const opts: MobileOptions = new MobileOptions(ApiThrottle.STORIES, priority);
    // ① 单用户那条（媒体在 `reel.items`）
    const direct: MobileResult = await MobileRequest.send(
      `feed/user/${userId}/story/`, '', '', true, null, opts);
    if (direct.ok) {
      const items: Array<StoryItem> = MobileStories.storyItemsOfBody(direct.body, 'reel');
      if (items.length > 0) {
        hilog.info(DOMAIN, TAG, 'reel via user-story uid=%{public}s n=%{public}d',
          userId, items.length);
        return MobileStories.buildReel(userId, username, direct.body, 'reel', items);
      }
      hilog.info(DOMAIN, TAG, 'reel user-story empty uid=%{public}s bytes=%{public}d',
        userId, direct.bytes);
    } else {
      hilog.info(DOMAIN, TAG, 'reel user-story miss uid=%{public}s %{public}s',
        userId, direct.summary());
    }
    // ② 备用：按 reel id 取（主 id + 备选 id，去重、封顶）
    const ids: Array<string> = MobileStories.candidateIds(userId, altIds);
    for (let index: number = 0; index < ids.length; index++) {
      const reelId: string = ids[index];
      const params: string = `reel_ids=${encodeURIComponent(reelId)}`;
      const result: MobileResult = await MobileRequest.send('feed/reels_media/', '', params, true,
        null, opts);
      if (!result.ok) {
        hilog.info(DOMAIN, TAG, 'reel reels_media miss id=%{public}s %{public}s',
          reelId, result.summary());
        continue;
      }
      const items: Array<StoryItem> = MobileStories.reelsMediaItems(result.body, reelId);
      if (items.length > 0) {
        hilog.info(DOMAIN, TAG, 'reel via reels_media id=%{public}s n=%{public}d',
          reelId, items.length);
        return MobileStories.buildReel(userId, username, result.body, `reels:${reelId}`, items);
      }
      hilog.info(DOMAIN, TAG, 'reel reels_media empty id=%{public}s bytes=%{public}d',
        reelId, result.bytes);
    }
    hilog.warn(DOMAIN, TAG, 'reel exhausted uid=%{public}s tried=%{public}d',
      userId, ids.length + 1);
    return null;
  }

  // ------------------------------------------------------------------ 解析：托盘

  /** 托盘那一发 → 界面要的条目（跳过已过期 / 形状不对的）。 */
  private static trayItems(parsed: Record<string, Object>): Array<StoryTrayItem> {
    const out: Array<StoryTrayItem> = [];
    const raw: Array<Object> = MobileStories.objectsOf(parsed['tray']);
    const nowMs: number = Date.now();
    for (let index: number = 0; index < raw.length; index++) {
      const one: Record<string, Object> = raw[index] as Record<string, Object>;
      const user: Record<string, Object> | null = MobileStories.objectOf(one['user']);
      if (user === null) {
        continue;
      }
      const userId: string = MobileStories.firstText(user, ['pk', 'id', 'pk_id']);
      const username: string = MobileStories.firstText(user, ['username']);
      if (userId.length === 0 || username.length === 0) {
        continue;
      }
      // 过期的那条不该再画成环（响应里偶尔留着已结束的 reel）。
      const expiringAt: number = MobileStories.numberOf(one, 'expiring_at');
      if (expiringAt > 0 && expiringAt * 1000 < nowMs) {
        continue;
      }
      /*
       * `seen` 的语义：IG 给的是**看过的时刻**（秒），不是布尔。
       * 所以"这个环灰不灰"要拿它跟 `latest_reel_media`（最后一条快拍的发布时刻）比：
       * 看过的时刻 ≥ 最后一条 → 全看完了（灰），否则还有新的（渐变环）。
       */
      const seenAt: number = MobileStories.numberOf(one, 'seen');
      const latest: number = MobileStories.numberOf(one, 'latest_reel_media');
      const seen: boolean = latest > 0 ? seenAt >= latest : seenAt > 0;
      const count: number = MobileStories.numberOf(one, 'media_count');
      // 备选 id：托盘那条自己的 `id`（reel id）与用户 pk 不一致时，按 reel id 才问得到内容。
      const reelId: string = MobileStories.firstText(one, ['id', 'strong_id__']);
      const altIds: Array<string> = [];
      if (reelId.length > 0 && reelId !== userId) {
        altIds.push(reelId);
      }
      out.push(new StoryTrayItem(userId, username,
        MobileStories.firstText(user, ['profile_pic_url', 'profile_pic_url_hd']),
        seen, count, altIds));
    }
    return out;
  }

  // ------------------------------------------------------------------ 解析：媒体

  /** `{reel:{items:[…]}}` 那种形状里的媒体（`feed/user/{uid}/story/`）。 */
  private static storyItemsOfBody(body: string, key: string): Array<StoryItem> {
    const parsed: Record<string, Object> | null = MobileStories.parse(body);
    if (parsed === null) {
      return [];
    }
    const holder: Record<string, Object> | null = MobileStories.objectOf(parsed[key]);
    if (holder === null) {
      return [];
    }
    return MobileStories.mediaList(holder['items']);
  }

  /** `{reels:{"<id>":{items:[…]}}}` 那种形状里的媒体。 */
  private static reelsMediaItems(body: string, reelId: string): Array<StoryItem> {
    const parsed: Record<string, Object> | null = MobileStories.parse(body);
    if (parsed === null) {
      return [];
    }
    const reels: Record<string, Object> | null = MobileStories.objectOf(parsed['reels']);
    if (reels === null) {
      return [];
    }
    const keys: Array<string> = Object.keys(reels);
    for (let index: number = 0; index < keys.length; index++) {
      const holder: Record<string, Object> | null = MobileStories.objectOf(reels[keys[index]]);
      if (holder === null) {
        continue;
      }
      const items: Array<StoryItem> = MobileStories.mediaList(holder['items']);
      if (items.length > 0) {
        return items;
      }
    }
    // 兜底：调用方给的 id 与响应里的键不一致（IG 有时回的是 `strong_id__`）——取第一个非空。
    if (keys.length > 0) {
      hilog.info(DOMAIN, TAG, 'reels_media id mismatch want=%{public}s got=%{public}s',
        reelId, keys[0]);
    }
    return [];
  }

  /** 一串 media 对象 → 界面要的 `StoryItem`。 */
  private static mediaList(value: Object | undefined): Array<StoryItem> {
    const raw: Array<Object> = MobileStories.objectsOf(value);
    const out: Array<StoryItem> = [];
    for (let index: number = 0; index < raw.length; index++) {
      const media: Record<string, Object> = raw[index] as Record<string, Object>;
      const item: StoryItem | null = MobileStories.toStoryItem(media);
      if (item !== null) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 一条 media → `StoryItem`。
   *
   * 字段取舍都按实测形状来：
   *   · 封面取 `image_versions2.candidates` 里**最宽**的那张（视频快拍也有，是它的封面）；
   *   · 视频取 `video_versions` 第一条的 `url`（IG 按质量降序给，第一条最高）；
   *   · 宽高取 `original_width` / `original_height`（播放页要按真实比例排版，见 StoryItem 的说明）。
   */
  private static toStoryItem(media: Record<string, Object>): StoryItem | null {
    const id: string = MobileStories.firstText(media, ['pk', 'id', 'strong_id__']);
    const imageUrl: string = MobileStories.bestImageUrl(media);
    const videoUrl: string = MobileStories.bestVideoUrl(media);
    if (imageUrl.length === 0 && videoUrl.length === 0) {
      return null;
    }
    const mediaType: number = MobileStories.numberOf(media, 'media_type');
    const durationSec: number = MobileStories.numberOf(media, 'video_duration');
    const durationMs: number = mediaType === 2 && durationSec > 0
      ? Math.round(durationSec * 1000) : MobileStories.IMAGE_DURATION_MS;
    return new StoryItem(id, imageUrl, videoUrl,
      MobileStories.numberOf(media, 'taken_at'), durationMs,
      MobileStories.numberOf(media, 'original_width'),
      MobileStories.numberOf(media, 'original_height'));
  }

  /** 封面：候选里挑最宽的一张。 */
  private static bestImageUrl(media: Record<string, Object>): string {
    const versions: Record<string, Object> | null = MobileStories.objectOf(media['image_versions2']);
    if (versions === null) {
      // 老字段兜底（部分形状直接给 display_url / thumbnail_url）。
      return MobileStories.firstText(media, ['display_url', 'thumbnail_url']);
    }
    const candidates: Array<Object> = MobileStories.objectsOf(versions['candidates']);
    let best: string = '';
    let bestWidth: number = -1;
    for (let index: number = 0; index < candidates.length; index++) {
      const one: Record<string, Object> = candidates[index] as Record<string, Object>;
      const url: string = MobileStories.firstText(one, ['url']);
      if (url.length === 0) {
        continue;
      }
      const width: number = MobileStories.numberOf(one, 'width');
      if (width > bestWidth) {
        bestWidth = width;
        best = url;
      }
    }
    return best.length > 0 ? best : MobileStories.firstText(media, ['display_url']);
  }

  /** 视频地址：`video_versions` 第一条（IG 按质量降序给）。 */
  private static bestVideoUrl(media: Record<string, Object>): string {
    const versions: Array<Object> = MobileStories.objectsOf(media['video_versions']);
    for (let index: number = 0; index < versions.length; index++) {
      const one: Record<string, Object> = versions[index] as Record<string, Object>;
      const url: string = MobileStories.firstText(one, ['url', 'src']);
      if (url.length > 0) {
        return url;
      }
    }
    return '';
  }

  /** 组装 `StoryReel`：用户名 / 头像优先从响应里的 `user` 取，取不到用托盘里已知的。 */
  private static buildReel(userId: string, username: string, body: string, key: string,
                           items: Array<StoryItem>): StoryReel {
    let name: string = username;
    let avatar: string = '';
    const parsed: Record<string, Object> | null = MobileStories.parse(body);
    if (parsed !== null) {
      let holder: Record<string, Object> | null = null;
      if (key === 'reel') {
        holder = MobileStories.objectOf(parsed['reel']);
      } else {
        const reels: Record<string, Object> | null = MobileStories.objectOf(parsed['reels']);
        if (reels !== null) {
          const keys: Array<string> = Object.keys(reels);
          if (keys.length > 0) {
            holder = MobileStories.objectOf(reels[keys[0]]);
          }
        }
      }
      if (holder !== null) {
        const user: Record<string, Object> | null = MobileStories.objectOf(holder['user']);
        if (user !== null) {
          const got: string = MobileStories.firstText(user, ['username']);
          if (got.length > 0) {
            name = got;
          }
          avatar = MobileStories.firstText(user, ['profile_pic_url', 'profile_pic_url_hd']);
        }
      }
    }
    return new StoryReel(userId, name, avatar, items);
  }

  // ------------------------------------------------------------------ 小工具

  /** 候选 id：主 id 在前，备选去重、封顶。 */
  private static candidateIds(userId: string, altIds: Array<string>): Array<string> {
    const out: Array<string> = [userId];
    for (let index: number = 0; index < altIds.length && out.length <= MAX_ALT_IDS; index++) {
      const one: string = `${altIds[index]}`.trim();
      if (one.length > 0 && out.indexOf(one) < 0) {
        out.push(one);
      }
    }
    return out;
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

  /** 按顺序取第一个非空的字符串字段（IG 的字段名新旧不一，容错比精确重要）。 */
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

  private static numberOf(holder: Record<string, Object>, name: string): number {
    const value: Object | undefined = holder[name];
    if (value === undefined || value === null) {
      return 0;
    }
    if (typeof value === 'number') {
      return value as number;
    }
    const parsed: number = Number(`${value}`);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  /** 托盘一次要几条（instagrapi 的 `page_size` 默认 50，实测 213 条一次全给）。 */
  private static readonly TRAY_PAGE_SIZE: number = 50;
  /** 图片快拍显示多久（毫秒）——与网页那条路的默认值一致，见 StoryViewer。 */
  private static readonly IMAGE_DURATION_MS: number = 5000;
}
