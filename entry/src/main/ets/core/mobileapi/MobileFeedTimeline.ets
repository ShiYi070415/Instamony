/*
 * 首页信息流的**移动端通道**（`POST feed/timeline/`）。
 *
 * ## 为什么值得做（这是最后一块模板依赖）
 * 本项目的信息流一直是"网页 GraphQL 模板回放"拿到的；而 instagrapi **根本没有** feed 时间线
 * （它的 `__init__.py` 只 import 了 `ReelsMixin`，没有任何 timeline mixin，`feed/timeline/`
 * 一次都没用过）—— 所以这条没有现成参考，只能实测。
 *
 * ## 实测结论（2026-10-21，模拟器；见 core/mobileapi/MobileFeedProbe）
 *   `GET  feed/timeline/` → **405 Method Not Allowed**
 *   `POST feed/timeline/` → **200 / 253 KB**（可用）
 *   `feed/timeline/stream/` → 404（不存在）
 * 也就是说：**时间线要 POST**，参数全在查询串里，体里给一个空格即可（与 clips 那条同构）。
 *
 * ## 参数
 * 照 IG App 首页那一发：`reason=pull_to_refresh`（拉最新）/ `max_id=<游标>`（翻页），
 * 外加客户端上下文（`is_prefetch` / `feed_view_info` / `phone_id` / `timezone_offset` …）。
 * 解析交给 `NativeTimelineParser.parseMobileFeed`（v1 媒体 → 卡片 DTO，只有一份映射）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileFeedTimeline';

/** 一条时间线的原始响应（解析在 NativeTimelineParser）。 */
export class MobileFeedPage {
  readonly body: string;
  readonly cursor: string;
  readonly more: boolean;
  readonly ms: number;

  constructor(body: string, cursor: string, more: boolean, ms: number) {
    this.body = body;
    this.cursor = cursor;
    this.more = more;
    this.ms = ms;
  }
}

export class MobileFeedTimeline {
  private static lastDetail: string = '-';

  static detail(): string {
    return MobileFeedTimeline.lastDetail;
  }

  /**
   * 拉一页首页时间线（拿不到给 null；调用方退回模板回放）。
   *
   * @param maxId 上一页的游标（空串 = 最新一页）
   */
  static async page(maxId: string = '', extraParams: string = ''): Promise<MobileFeedPage | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      MobileFeedTimeline.lastDetail = 'no-session';
      return null;
    }
    const started: number = Date.now();
    /*
     * 参数与 IG App 首页那一发对齐；`max_id` 只在翻页时给（空串时给空值也行，
     * 但"不出现"更接近真实客户端）。
     */
    let params: string = `reason=${maxId.length > 0 ? 'pagination' : 'pull_to_refresh'}`
      + `&is_prefetch=false`
      + `&feed_view_info=[]&seen_posts=&phone_id=${encodeURIComponent(identity.phoneId)}`
      + `&is_pull_to_refresh=false&battery_level=100&timezone_offset=${identity.timezoneOffset}`
      + `&is_charging=0&will_sound_on=0&includes_soft_bounce_stories=true`
      + `&auto_refresh=true&is_shelf_life_enabled=true`;
    if (maxId.length > 0) {
      params += `&max_id=${encodeURIComponent(maxId)}`;
    }
    if (extraParams.length > 0) {
      params += `&${extraParams}`;
    }
    // POST（GET 会 405，见文件头的实测）：体里一个空格，参数走查询串。
    const result: MobileResult = await MobileRequest.send(
      'feed/timeline/', ' ', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, ApiThrottle.interactive()));
    if (!result.ok) {
      MobileFeedTimeline.lastDetail = result.summary();
      hilog.info(DOMAIN, TAG, 'timeline miss cursor=%{public}d %{public}s',
        maxId.length, MobileFeedTimeline.lastDetail);
      return null;
    }
    const shape: string = MobileFeedTimeline.shapeOf(result.body);
    MobileFeedTimeline.lastDetail = `ok bytes=${result.bytes} ${shape}`;
    hilog.info(DOMAIN, TAG, 'timeline ok cursor=%{public}d bytes=%{public}d %{public}s',
      maxId.length, result.bytes, shape);
    return new MobileFeedPage(result.body, '', false, Date.now() - started);
  }

  /**
   * 只给日志：响应里认出来的键（`feed_items` / `items` / `next_max_id` …）。
   *
   * 为什么值得一行：这条端点的形状**没有公开文档也没有 instagrapi 可对照**，
   * 一旦 IG 换结构，这行就是"是形状变了还是网络坏了"的唯一判据。
   */
  private static shapeOf(body: string): string {
    const keys: Array<string> = ['feed_items', 'items', 'media_or_ad', 'next_max_id',
      'more_available', 'pagination_info', 'num_results'];
    const hit: Array<string> = [];
    for (let index: number = 0; index < keys.length; index++) {
      if (body.indexOf(`"${keys[index]}"`) >= 0) {
        hit.push(keys[index]);
      }
    }
    return hit.length > 0 ? `keys=[${hit.join(',')}]` : 'keys=none';
  }
}
