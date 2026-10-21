/*
 * Reels 的**移动端私有通道**（对应 instagrapi 的 `reels` / `explore_reels`）。
 *
 * ## 端点（与 instagrapi 逐字一致）
 *   POST `clips/discover/`           ← instagrapi 的 `explore_reels`
 *   POST `clips/connected/`          ← `reels`
 *   body: 一个**空格**（instagrapi 里就是 `data=" "`），query: `max_id=<游标>`
 *
 * ## 返回结构（注意与网页 GraphQL 不同）
 *   `{"items":[{"media":{…v1 媒体…}}], "items_with_ads":[…],
 *     "paging_info":{"more_available":true, "max_id":"…"}}`
 * 而网页 GraphQL 那条是
 *   `{"data":{"xdt_api__v1__clips__home__connection_v2":{"edges":[{"node":{"media":…}}],
 *     "page_info":{"has_next_page":…,"end_cursor":"…"}}}}`
 *
 * **v1 媒体与 GraphQL 媒体的字段名高度重合**（`code` / `video_versions[].url` /
 * `image_versions2.candidates[]` / `user` / `like_count` / `clips_metadata`），
 * 所以解析不需要第二套映射：把 `items[].media` 取出来交给 `NativeReels.toReel` 即可。
 *
 * ## 为什么值得走这条
 * 网页 GraphQL 那条依赖"抓模板 + 回放"，而这条**不需要任何网页模板**：
 * 端点是写死的（instagrapi 那张表里就这么写），身份用 App 那套。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileClips';

/** 端点（与 instagrapi `reels_timeline_media` 的表一致）。 */
export const CLIPS_DISCOVER: string = 'clips/discover/';
export const CLIPS_CONNECTED: string = 'clips/connected/';

export class MobileClips {
  private static lastDetail: string = '-';

  static detail(): string {
    return MobileClips.lastDetail;
  }

  /**
   * 拉一页 Reels（拿不到给 null，调用方自己决定要不要退回模板回放）。
   *
   * @param maxId 上一页 `paging_info.max_id`（空串 = 第一页）
   * @param endpoint `clips/discover/`（默认，探索流）或 `clips/connected/`（关注流）
   */
  static async page(maxId: string = '', endpoint: string = CLIPS_DISCOVER): Promise<string | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      MobileClips.lastDetail = 'no-session';
      return null;
    }
    let params: string = '';
    if (maxId.length > 0) {
      params = `max_id=${encodeURIComponent(maxId)}`;
    }
    /*
     * `data=" "`（一个空格）不是笔误：instagrapi 就是这么发的 —— 这条要 POST，
     * 但参数全在查询串里，体里给个空格让签名有一个非空输入。照抄最稳。
     */
    const result: MobileResult = await MobileRequest.send(
      endpoint, ' ', params, true, null,
      new MobileOptions(ApiThrottle.CLIPS, ApiThrottle.interactive()));
    if (!result.ok) {
      MobileClips.lastDetail = result.summary();
      hilog.info(DOMAIN, TAG, 'clips miss %{public}s %{public}s', endpoint, MobileClips.lastDetail);
      return null;
    }
    const items: number = MobileClips.countOf(result.body);
    MobileClips.lastDetail = `ok items=${items} bytes=${result.bytes}`;
    hilog.info(DOMAIN, TAG, 'clips ok %{public}s cursor=%{public}d items=%{public}d bytes=%{public}d',
      endpoint, maxId.length, items, result.bytes);
    return result.body;
  }

  /** `items` / `items_with_ads` 的条数（只给日志；解析仍在 NativeReels）。 */
  private static countOf(body: string): number {
    try {
      const parsed: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const items: Object | undefined = parsed['items'];
      if (items !== undefined && items !== null && Array.isArray(items)) {
        return (items as Array<Object>).length;
      }
      const ads: Object | undefined = parsed['items_with_ads'];
      if (ads !== undefined && ads !== null && Array.isArray(ads)) {
        return (ads as Array<Object>).length;
      }
      return -1;
    } catch (error) {
      return -1;
    }
  }
}
