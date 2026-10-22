/*
 * Reels 的**移动端私有通道**（对应 instagrapi 的 `reels` / `explore_reels`）。
 *
 * ## 端点与实测结论（真机 2026-10-22 逐页复验）
 *
 * | 端点 | 形状 | 翻页 | 用不用 |
 * | --- | --- | --- | --- |
 * | `POST clips/connected/` | `items[5]`（关注流） | 换不动 | **首屏快通道**（281KB / 1~3 秒） |
 * | `POST clips/discover/` | `items_with_ads[4]`（探索 Reels） | 换不动 | **首屏快通道**（203KB / 1~2 秒） |
 * | `POST clips/discover/social/` | `items[6]`（Friends，instagrapi 的 `friends_reels`） | 换不动 | **首屏快通道**（324KB / 1~2 秒） |
 * | `GET discover/topical_explore/` | `sectional_items[]`（见 MobileDiscover） | **`max_id` 真能换页** | 翻页兜底 / 补作者池 |
 *
 * 三条 `clips/*` 全是**清一色视频**，但**每页都回同一批条目**（逐页验过：`clips/discover/`
 * 连续 4 页短码完全一样、字节数只差在顺序；`social`(6 条) 与 `connected`(5 条) 同理）。
 * 所以它们只负责"首屏 2~4 秒铺满十几条"，**翻页交给作者页与探索流**（见 NativeReels.fetchPage）。
 *
 * ### `clips/discover/` 为什么不能当主路（这条是本节的重点）
 *
 * 现场：连续要了 4 页，每页都回**同样那 4 条**（`DetYzMxzSoK` / `DetdvCnyNuE` /
 * `DeCcpBuvset` / `Detog77hNnG`），字节数一分不差（204892），只有顺序被倒过来。
 * `paging_info.max_id` 虽然每页都变，但它的"已看窗口"token 是同一批 —— 服务端**没认**我们的游标，
 * 只是把我们上次报的那几条又还回来（这就是用户说的"reels 无法获取新的视频"）。
 *
 * 逐个排除过（一次性实验，结论拿到后已删）：
 *   · 游标放签名体里（`max_id=…`） → 同样那 4 条（顺序还原）
 *   · 换个参数名（`cursor=…`） → 同样那 4 条
 *   · 查询串 + 体里带 instagrapi 的 `_uid`/`_uuid` → 同样那 4 条
 *   · 加 `count`/`page_size` → 同样那 4 条
 *
 * 同一时刻另外两条源都正常：`clips/connected/` 回 5 条关注流；
 * `discover/topical_explore/` 第一页和它的 `max_id` 第二页**短码完全不重合**。
 * 所以 Reels 的主路改成探索流，`clips/discover/` 只留作"两条都挂了"时的兜底（它至少给 4 条能播的）。
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
   * 关注流那一发（`clips/connected/`）：**首屏暖场**用。
   *
   * 小、快（5 条、几十 KB），但**没有 `paging_info`** —— 所以它只负责让用户一进视频页就有内容，
   * 真正翻页由探索流接管（见 core/NativeReels 的 fetchPage）。
   */
  static async connected(cursor: string = ''): Promise<string | null> {
    return MobileClips.post(CLIPS_CONNECTED, cursor);
  }

  /**
   * 探索流兜底那一发（`clips/discover/`）。
   *
   * **不要拿它当主路**：真机上它每页都回同样 4 条（见文件头）。
   * 留着是因为"探索流 + 关注流都挂了"时它至少还能给 4 条能播的视频。
   */
  static async discover(cursor: string = ''): Promise<string | null> {
    return MobileClips.post(CLIPS_DISCOVER, cursor);
  }

  /** `clips/discover/social/`（instagrapi 的 `friends_reels`：Friends 那个 tab）。 */
  static async friends(cursor: string = ''): Promise<string | null> {
    return MobileClips.post('clips/discover/social/', cursor);
  }

  /**
   * 发一发 `clips/*`（拿不到给 null）。
   *
   * @param endpoint `clips/connected/` 或 `clips/discover/`
   * @param cursor 上一页 `paging_info.max_id`（空串 = 第一页）
   */
  private static async post(endpoint: string, cursor: string): Promise<string | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      MobileClips.lastDetail = 'no-session';
      return null;
    }
    let params: string = '';
    if (cursor.length > 0) {
      params = `max_id=${encodeURIComponent(cursor)}`;
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
    const counts: string = MobileClips.countsOf(result.body);
    MobileClips.lastDetail = `ok ${counts} bytes=${result.bytes}`;
    hilog.info(DOMAIN, TAG, 'clips ok %{public}s cursor=%{public}d %{public}s bytes=%{public}d',
      endpoint, cursor.length, counts, result.bytes);
    return result.body;
  }

  /** `items` / `items_with_ads` 各几条（只给日志；解析仍在 core/NativeReels）。 */
  private static countsOf(body: string): string {
    try {
      const parsed: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      return `items=${MobileClips.lenOf(parsed, 'items')}`
        + ` ads=${MobileClips.lenOf(parsed, 'items_with_ads')}`;
    } catch (error) {
      return 'not-json';
    }
  }

  private static lenOf(root: Record<string, Object>, key: string): number {
    const list: Object | undefined = root[key];
    if (list === undefined || list === null || !Array.isArray(list)) {
      return -1;
    }
    return (list as Array<Object>).length;
  }
}
