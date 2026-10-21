/*
 * 评论的**移动端私有通道**（对应 instagrapi 的 `media_comments_v1_chunk`）。
 *
 * ## 它解决什么
 * 我们原来拿评论有两条路，都要先"弄到一份网页请求"：REST 那条用网页模板头
 * （`RestSession.headers()` 来自被抓下来的模板），GraphQL 那条还要 doc_id + 网页表单令牌。
 * 所以评论一直依赖"网页抓包 + 模板回放"这套机制，而那正是页面自动化痕迹的来源。
 *
 * instagrapi 里这条根本不需要模板：端点写死、用 App 身份直接发 ——
 *   `GET media/{media_id}/comments/?can_support_threading=true&permalink_enabled=false`
 *   （翻页再加 `&min_id=` 或 `&max_id=`）
 * 返回的结构与网页那条 REST **完全一致**：
 *   `{"comments":[…], "next_max_id":…, "next_min_id":…, "has_more_comments":…, "comment_count":…}`
 * 所以原生那套解析（`NativeComments.parse`）不用改一行。
 *
 * ## 怎么接
 * `NativeComments.fetch` 先走这里；拿到就返回。失败（无会话 / 非 200 / 被限流）再退回
 * 原来的 REST + GraphQL 两条老路 —— 迁移期间两条并存，等这里在真机上稳定了再删模板。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileComments';

/** 第一页要几条（不给 count 时 IG 默认约 20；这里显式要，便于后续按需调小）。 */
const PAGE_SIZE: number = 20;

export class MobileComments {
  /** 最近一次的结论（诊断用；界面不显示）。 */
  private static lastDetail: string = '-';

  static detail(): string {
    return MobileComments.lastDetail;
  }

  /**
   * 拉一页评论。
   *
   * @param mediaId 媒体 id（纯数字；调用方已剥掉 `_短码` 后缀）
   * @param cursor  上一页给的游标（空串 = 第一页）
   * @param minId   true = 游标用 `min_id`（头部加载），false = `max_id`
   * @returns 原始 JSON 文本（解析交给 NativeComments，保持"只有一份解析"）；失败给 null
   */
  static async page(mediaId: string, cursor: string = '',
                    minId: boolean = false): Promise<string | null> {
    const id: string = mediaId.trim();
    if (id.length === 0) {
      MobileComments.lastDetail = 'no-media-id';
      return null;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      MobileComments.lastDetail = 'no-session';
      return null;
    }
    // 与 instagrapi 逐字一致的两个查询串（少了会给一版不含回复的旧结构）。
    let params: string = 'can_support_threading=true&permalink_enabled=false';
    if (cursor.length > 0) {
      params += minId
        ? `&min_id=${encodeURIComponent(cursor)}`
        : `&max_id=${encodeURIComponent(cursor)}`;
    }
    const result: MobileResult = await MobileRequest.send(
      `media/${encodeURIComponent(id)}/comments/`, '', params, true, null,
      new MobileOptions(ApiThrottle.COMMENTS, ApiThrottle.interactive()));
    if (!result.ok) {
      MobileComments.lastDetail = result.summary();
      hilog.info(DOMAIN, TAG, 'comments miss id=%{public}s %{public}s', id,
        MobileComments.lastDetail);
      return null;
    }
    const n: number = MobileComments.countOf(result.body);
    MobileComments.lastDetail = `ok n=${n} bytes=${result.bytes}`;
    hilog.info(DOMAIN, TAG, 'comments ok id=%{public}s cursor=%{public}d n=%{public}d bytes=%{public}d',
      id, cursor.length, n, result.bytes);
    return result.body;
  }

  /** 响应里 `comments` 的条数（只给日志；解析仍在 NativeComments 那份）。 */
  private static countOf(body: string): number {
    try {
      const parsed: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const items: Object | undefined = parsed['comments'];
      if (items === undefined || items === null || !Array.isArray(items)) {
        return -1;
      }
      return (items as Array<Object>).length;
    } catch (error) {
      return -1;
    }
  }
}
