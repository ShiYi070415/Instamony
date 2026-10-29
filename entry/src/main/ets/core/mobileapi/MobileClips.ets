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
   * ## 游标必须放 **form body**（2026-10-30 用同一份会话实测）
   *   · 放查询串（`?max_id=…`）→ 服务端**无视**它，把同一页原样再回一遍（字节数都一样，
   *     只是顺序被重排）—— 这就是"前四条视频固定、只有顺序变"的根因；
   *   · 放 body（`max_id=…`）→ 真的翻页：`clips/discover/` 第二页 **16 条 / 15 个作者 /
   *     与第一页 0 重合**，第三页同样全新。`clips/discover/social/`、`clips/connected/` 同理。
   *
   * 为什么带游标时**先不发签名**：签名会把表单包装成 `signed_body=SIG.<…>`，而这条端点
   * 在签名体里读不到 `max_id`（同一类问题在 `friendships/show_many` 上已经踩过，见
   * MobileNews.showMany）。先未签名、失败再退回签名。
   *
   * @param endpoint `clips/connected/` / `clips/discover/` / `clips/discover/social/`
   * @param cursor 上一页的 `next_max_id`（或 `paging_info.max_id`；空串 = 第一页）
   */
  private static async post(endpoint: string, cursor: string): Promise<string | null> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      MobileClips.lastDetail = 'no-session';
      return null;
    }
    const opts: MobileOptions = new MobileOptions(ApiThrottle.CLIPS, ApiThrottle.interactive());
    let result: MobileResult;
    if (cursor.length > 0) {
      // 翻页：游标进 body，先未签名（见上面那段实测说明）。
      const payload: string = `max_id=${encodeURIComponent(cursor)}`;
      result = await MobileRequest.send(endpoint, payload, '', false, null, opts);
      if (!result.ok) {
        hilog.info(DOMAIN, TAG, 'clips cursor(unsigned) failed %{public}s (%{public}s) → signed',
          endpoint, result.summary());
        result = await MobileRequest.send(endpoint, payload, '', true, null, opts);
      }
    } else {
      /*
       * 第一页：沿用 instagrapi 那条形状（体里一个空格、参数全在查询串，签名照发）。
       * `data=" "` 不是笔误：这条要 POST，但第一页没有参数，给个空格让签名有非空输入。
       */
      result = await MobileRequest.send(endpoint, ' ', '', true, null, opts);
    }
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
