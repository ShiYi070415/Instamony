/*
 * **时间线翻页参数探针**（一次性，诊断用；开关见 pages/Index 的 TIMELINE_PAGE_PROBE）。
 *
 * ## 为什么需要它
 * 真机现象：首页"关注"那一段永远只有 4 条，上滑翻不出更多。日志是这样的：
 *
 *     native first applied n=4 cursor=y more=y
 *     native prefetch stop: no progress cursor=760 next=104
 *
 * 也就是说：拿第一页响应里的 `next_max_id=760` 去要下一页，服务端把**第一页**原样回了一遍
 * （`next_max_id=104`）。这有三种可能，光看日志分不清：
 *   1. IG 是"每次首屏请求开一条新链"，我们那个游标已经过期（链被下一次首屏请求作废）；
 *   2. 参数形状不对（`reason` / `max_id` vs `cursor` / 缺 `ranked_content`、`session_id`…）；
 *   3. 这个账号的关注流**确实**就这么多（IG 只给这么多就 `more_available=false`）——
 *      但响应里 `more_available` 明明是 true，所以第三种基本排除。
 *
 * ## 它做什么
 * 用**同一条链**（先拉一次首屏，拿到 `next_max_id`）依次试几组参数，把每一组的
 * 「返回字节数 / 新的 next_max_id / more_available / 前几条媒体 code」打一行日志。
 * 判据很简单：**`next_max_id` 变了、且出现了首屏没有的 code** = 这组参数真的翻到第二页了。
 *
 * 试完不写任何持久状态、不改生产参数 —— 结论出来之后再去改 `MobileFeedTimeline.page`。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileFeedPage, MobileFeedTimeline } from './MobileFeedTimeline';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileOptions, MobileRequest, MobileResult } from './MobileRequest';

const DOMAIN: number = 0xFF00;
const TAG: string = 'TimelineProbe';

export class TimelineProbe {
  private static ran: boolean = false;

  /** 跑一次（幂等；任何一步失败都只记日志，绝不抛给调用方）。 */
  static async run(): Promise<void> {
    if (TimelineProbe.ran) {
      return;
    }
    TimelineProbe.ran = true;
    try {
      await TimelineProbe.probe();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'probe threw: %{public}s', (error as Error).message);
    }
  }

  private static async probe(): Promise<void> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'probe skipped: no session');
      return;
    }
    // 第一条链：先拉首屏，把它的 next_max_id 当"合法游标"。
    const first: MobileFeedPage | null = await MobileFeedTimeline.page('');
    if (first === null) {
      hilog.info(DOMAIN, TAG, 'probe: first page failed (%{public}s)',
        MobileFeedTimeline.detail());
      return;
    }
    const firstIds: Array<string> = TimelineProbe.codesOf(first.body);
    const next: string = TimelineProbe.textOf(first.body, 'next_max_id');
    hilog.info(DOMAIN, TAG, 'probe first n=%{public}d next=%{public}s ids=%{public}s',
      firstIds.length, next, TimelineProbe.head(firstIds));
    if (next.length === 0) {
      return;
    }
    /*
     * 逐组试。每一发都是 GET→POST（同生产实现：体里一个空格、参数在查询串），
     * 优先级用 idle —— 这是诊断流量，不该和首屏抢名额。
     */
    await TimelineProbe.attempt(identity, 'A:pagination+max_id', next, firstIds, true, '', false);
    await TimelineProbe.attempt(identity, 'B:pull_to_refresh+max_id', next, firstIds, true,
      '&reason=pull_to_refresh', true);
    await TimelineProbe.attempt(identity, 'C:pagination+max_id+ranked', next, firstIds, true,
      '&ranked_content=true', false);
    await TimelineProbe.attempt(identity, 'D:pagination+cursor', next, firstIds, false,
      '', false);
    await TimelineProbe.attempt(identity, 'E:pagination+max_id+session', next, firstIds, true,
      `&session_id=${encodeURIComponent(identity.uuid)}&is_prefetch=false`, false);
    hilog.info(DOMAIN, TAG, 'probe done');
  }

  /**
   * 试一组参数。
   *
   * @param withMaxId 用 `max_id=<cursor>` 还是 `cursor=<cursor>`
   * @param extra     追加的参数（`&k=v` 形状；为空表示不加）
   */
  private static async attempt(identity: MobileIdentity, label: string, cursor: string,
                               firstIds: Array<string>, withMaxId: boolean,
                               extra: string, pullToRefresh: boolean): Promise<void> {
    const reason: string = pullToRefresh ? 'pull_to_refresh' : 'pagination';
    const cursorParam: string = withMaxId ? 'max_id' : 'cursor';
    let params: string = `reason=${reason}`
      + `&is_prefetch=false`
      + `&feed_view_info=[]&seen_posts=&phone_id=${encodeURIComponent(identity.phoneId)}`
      + `&is_pull_to_refresh=false&battery_level=100&timezone_offset=${identity.timezoneOffset}`
      + `&is_charging=0&will_sound_on=0&includes_soft_bounce_stories=true`
      + `&${cursorParam}=${encodeURIComponent(cursor)}`;
    if (extra.length > 0) {
      params += extra;
    }
    let result: MobileResult = await MobileRequest.send('feed/timeline/', ' ', params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, ApiThrottle.idle()));
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'probe %{public}s miss %{public}s', label, result.summary());
      return;
    }
    const ids: Array<string> = TimelineProbe.codesOf(result.body);
    const next: string = TimelineProbe.textOf(result.body, 'next_max_id');
    const more: string = TimelineProbe.textOf(result.body, 'more_available');
    let fresh: number = 0;
    for (let index: number = 0; index < ids.length; index++) {
      if (firstIds.indexOf(ids[index]) < 0) {
        fresh++;
      }
    }
    hilog.info(DOMAIN, TAG,
      'probe %{public}s bytes=%{public}d n=%{public}d fresh=%{public}d next=%{public}s more=%{public}s head=%{public}s',
      label, result.bytes, ids.length, fresh, next, more, TimelineProbe.head(ids));
  }

  /** 响应里前几条媒体的 `code`（就是 shortcode；空的用 `pk` 占位）。 */
  private static codesOf(body: string): Array<string> {
    const out: Array<string> = [];
    try {
      const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const items: Object | undefined = root['feed_items'] ?? root['items'];
      if (items === undefined || items === null || !Array.isArray(items)) {
        return out;
      }
      const list: Array<Object> = items as Array<Object>;
      for (let index: number = 0; index < list.length && index < 40; index++) {
        const one: Object = list[index];
        if (one === null || Array.isArray(one)) {
          continue;
        }
        const item: Record<string, Object> = one as Record<string, Object>;
        const mediaRaw: Object | undefined = item['media_or_ad'];
        if (mediaRaw === undefined || mediaRaw === null || Array.isArray(mediaRaw)) {
          continue;
        }
        const media: Record<string, Object> = mediaRaw as Record<string, Object>;
        const code: Object | undefined = media['code'];
        const pk: Object | undefined = media['pk'];
        const key: string = typeof code === 'string' ? code
          : (typeof pk === 'number' || typeof pk === 'string' ? `${pk}` : '');
        if (key.length > 0) {
          out.push(key);
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'codes parse failed: %{public}s', (error as Error).message);
    }
    return out;
  }

  /** 顶层字符串/数字字段（`next_max_id` / `more_available` 都能读）。 */
  private static textOf(body: string, key: string): string {
    try {
      const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const value: Object | undefined = root[key];
      if (value === undefined || value === null) {
        return '-';
      }
      return typeof value === 'string' ? value as string : `${value}`;
    } catch (error) {
      return '-';
    }
  }

  /** 前几个 code，一行日志用。 */
  private static head(ids: Array<string>): string {
    const take: Array<string> = ids.length > 3 ? ids.slice(0, 3) : ids;
    return take.length > 0 ? take.join(',') : '-';
  }
}
