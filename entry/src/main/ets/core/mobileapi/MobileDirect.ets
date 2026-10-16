/*
 * 移动 API 的**私信**端点（对应 instagrapi 的 `DirectMixin` 的只读那两条）。
 *
 * ## 为什么这条路值得走
 * 私信收件箱那条私有 REST 在**网页身份**下被 IG 当"未登录"（回 404 + 一页 `not-logged-in` HTML），
 * 既有实现是"把头的 User-Agent / app-id 临时改成安卓"来绕（见 NativeDirect.applyAndroidIdentity）。
 * 那套是**手工拼的半套移动身份**；这里直接用移动端那一整套（App-ID / 完整 UA / `signed_body` /
 * `Authorization: Bearer IGT:2:` / `IG-U-*` / `X-MID`），实测：
 *
 *   POST /api/v1/direct_v2/inbox/            → 200，831KB，`inbox.threads=20`（带 `items` 各 11 条）
 *   GET  /api/v1/direct_v2/threads/{id}/?limit=20 → 200，65KB，`thread.items=21`、`has_older=true`
 *
 * ## 解析层**直接复用** model/Direct.ets 里现成的那两个映射
 * `DirectMapper.inboxFromRestJson` / `DirectMapper.threadFromJson` 读的正是这两条 REST 的形状，
 * 实测对移动端的响应**完全兼容**（自检报告里 `parser inbox=ok n=20`、`parser thread=ok msgs=15`），
 * 所以这里不再写第二份解析 —— 两份解析一定会分叉（本项目在 `threadViaRest` 上吃过这个亏，见审计 E4）。
 *
 * ## 只做读
 * 发送（`direct_v2/threads/broadcast/text/`）**不在这里**：写接口的握手与风控判据和读不一样
 * （既有实现为此专门有 `probeSendShape`），本次移植的目标是"看得全、翻得动"。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { MobileRequest, MobileResult } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
import { DirectInboxPage, DirectMapper, DirectThread, DirectThreadView } from '../../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileDirect';

/** 一页会话几条（instagrapi 的 `amount`，默认 20）。 */
const INBOX_PAGE_SIZE: number = 20;
/** 每个会话先带几条最近消息（instagrapi 的 `thread_message_limit`，默认 10）。 */
const THREAD_MESSAGE_LIMIT: number = 10;
/** 打开一条会话时先取几条消息（instagrapi 的 `amount`，默认 20）。 */
const THREAD_PAGE_SIZE: number = 20;
/** 翻页游标的候选键（顺序即优先级）；**只看 `inbox` 自己这一层**，别钻进 threads 里。 */
const CURSOR_KEYS: Array<string> = ['next_max_id', 'next_cursor', 'cursor', 'oldest_cursor'];

export class MobileDirect {
  /**
   * 收件箱一页（拿不到给 null）。
   *
   * @param cursor 上一页的游标（空串 = 第一页）
   */
  static async inbox(cursor: string = ''): Promise<DirectInboxPage | null> {
    /*
     * **翻页暂时不归这条路管**（`cursor` 非空时直接让位给老路径）。
     *
     * 实测：把响应里的 `inbox.next_cursor` 放进 `cursor` 参数会被 IG 回
     * `400 Invalid Inbox Cursor: The cursor parameter passed in the Inbox API must be …`
     * —— 界面"加载更多"于是连续失败 4 次再退回模板那条路（真机日志 16:12:20 起）。
     * 正确传参由 `MobileProbe.inboxPageVariants` 的三种传法实验给出（见自检报告），
     * 定下来之前**宁可少翻一页，也不要每次点"加载更多"都白打四发**。
     */
    if (cursor.length > 0) {
      return null;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'inbox skipped: no session');
      return null;
    }
    const data: Record<string, Object> = MobileRequest.withExtraData(identity);
    data['visual_message_return_type'] = 'unseen';
    data['thread_message_limit'] = THREAD_MESSAGE_LIMIT;
    data['persistentBadging'] = 'true';
    data['limit'] = INBOX_PAGE_SIZE;
    // 游标**只走查询串**：上一版查询串与表单体一起放，IG 报 Invalid Inbox Cursor
    // （自检报告里的三种传法实验就是为这件事做的）。
    const query: string = 'visual_message_return_type=unseen'
      + `&thread_message_limit=${THREAD_MESSAGE_LIMIT}&persistentBadging=true&limit=${INBOX_PAGE_SIZE}`;
    const result: MobileResult = await MobileRequest.send(
      'direct_v2/inbox/', MobileRequest.formOf(data), query, true);
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'inbox failed: %{public}s', result.summary());
      return null;
    }
    const page: DirectInboxPage | null = DirectMapper.inboxFromRestJson(result.body);
    if (page === null) {
      hilog.warn(DOMAIN, TAG, 'inbox parse failed bytes=%{public}d head=%{public}s',
        result.bytes, result.body.substring(0, 160));
      return null;
    }
    const fixed: DirectInboxPage = MobileDirect.withCursor(page, result.body);
    hilog.info(DOMAIN, TAG, 'inbox ok n=%{public}d more=%{public}s cursor=%{public}d',
      fixed.threads.length, `${fixed.hasMore}`, fixed.endCursor.length);
    if (fixed.threads.length > 0) {
      hilog.info(DOMAIN, TAG, 'inbox first title=%{public}s avatar=%{public}s',
        fixed.threads[0].title, fixed.threads[0].avatarUrl.substring(0, 90));
    }
    return fixed;
  }

  /**
   * 一条会话的消息页（拿不到给 null）。
   *
   * @param threadId 会话 id（19~20 位长数字，**必须**走 `JsonRead.parseWithBigIds` 那条取值路径，
   *                 普通 JSON.parse 会把它舍入成 30 位错 id —— 见 DirectMapper 的说明）
   * @param olderCursor 取更老那批的游标（空串 = 最新那批）
   */
  static async thread(threadId: string, olderCursor: string = ''): Promise<DirectThreadView | null> {
    const id: string = threadId.trim();
    if (id.length === 0) {
      return null;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return null;
    }
    let params: string = `limit=${THREAD_PAGE_SIZE}`;
    if (olderCursor.length > 0) {
      params += `&cursor=${encodeURIComponent(olderCursor)}`;
    }
    const result: MobileResult = await MobileRequest.send(
      `direct_v2/threads/${id}/`, '', params, true);
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'thread failed id=%{public}s %{public}s', id, result.summary());
      return null;
    }
    const view: DirectThreadView | null = DirectMapper.threadFromJson(result.body, identity.userId);
    if (view === null) {
      hilog.warn(DOMAIN, TAG, 'thread parse failed id=%{public}s bytes=%{public}d',
        id, result.bytes);
      return null;
    }
    /*
     * 诊断：**服务端给了几条**（`thread.items` 原始条数）与**解析出几条**分开记。
     *
     * 实测有一类会话：这一发 200、`bytes` 也不算小，但解析出 0 条消息 —— 那到底是
     * "服务端就没给"还是"解析层把它全丢了"，只有这一行能分清（同 DirectMapper 里
     * 那条 `graphql raw edges=` 的思路）。
     */
    hilog.info(DOMAIN, TAG, 'thread ok id=%{public}s msgs=%{public}d raw=%{public}d'
      + ' older=%{public}s with=%{public}s',
      id, view.messages.length, MobileDirect.rawItemCount(result.body),
      `${view.hasOlder}`, view.withUsername);
    return view;
  }

  /** `thread.items` 的原始条数（拿不到给 -1，用来区分"服务端没给"与"解析丢了"）。 */
  private static rawItemCount(body: string): number {
    try {
      const parsed: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const thread: Object | undefined = parsed['thread'];
      if (thread === undefined || thread === null || Array.isArray(thread)) {
        return -1;
      }
      const items: Object | undefined = (thread as Record<string, Object>)['items'];
      if (items === undefined || items === null || !Array.isArray(items)) {
        return -1;
      }
      return (items as Array<Object>).length;
    } catch (error) {
      return -1;
    }
  }

  /**
   * 用**响应里真正存在的**游标键补一个 `DirectInboxPage`。
   *
   * 实测（`MobileProbe.inboxPageVariants` 的四种传法实验，2026-10-16）：
   *   · 移动端收件箱响应里的翻页材料**不是字符串**：
   *     `inbox.next_cursor` 是 `{cursor_thread_v2_id, cursor_timestamp_seconds,
   *     cursor_relevancy_score, cursor_primary_sort_id}`，旁边还有 `prev_cursor` /
   *     `prev_cursor_v2` / `prev_cursor_type=PAGING`；
   *   · 这几种形态**都进不了 `cursor` 参数**：
   *     `cursor=<JSON>` / `cursor=<cursor_thread_v2_id>` / `cursor=<prev_cursor>` → **400**
   *     （IG 原话：`Invalid Inbox Cursor: The cursor parameter passed in the Inbox API is not valid.
   *     Please refresh your Inbox.`）；而 `cursor_v2=…` / `max_id=…` 被**忽略**——
   *     回 200 但**又是第一页**（比对首页 thread_id 完全一致）。
   *   ⇒ 在解出正确形态之前：**只认字符串游标**（老路那种 `next_max_id`），
   *     拿不到就如实报 `hasMore=false`。宁可"这次没有更多"，也不要让界面拿着一个
   *     不合法游标连打四发（真机日志 16:12:20 就是这么打的），更不要把"原地打转"
   *     当成翻页成功、把同一页塞两遍。
   */
  private static withCursor(page: DirectInboxPage, body: string): DirectInboxPage {
    if (page.endCursor.length > 0 || !page.hasMore) {
      return page;
    }
    let parsed: Record<string, Object> | null = null;
    try {
      parsed = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      parsed = null;
    }
    if (parsed === null) {
      return page;
    }
    const inbox: Object | undefined = parsed['inbox'];
    if (inbox === undefined || inbox === null || Array.isArray(inbox)) {
      return new DirectInboxPage(page.threads, '', false);
    }
    const box: Record<string, Object> = inbox as Record<string, Object>;
    for (let index: number = 0; index < CURSOR_KEYS.length; index++) {
      const value: Object | undefined = box[CURSOR_KEYS[index]];
      // **只认字符串**：对象/数组正是上面实验里被 400 拒掉的那种形态。
      if (value === undefined || value === null || typeof value !== 'string') {
        continue;
      }
      const text: string = value as string;
      if (text.length > 0) {
        hilog.info(DOMAIN, TAG, 'inbox cursor from %{public}s len=%{public}d',
          CURSOR_KEYS[index], text.length);
        return new DirectInboxPage(page.threads, text, true);
      }
    }
    /*
     * 响应里只有"结构化游标"（当前解不开）：**别把它交给界面**。
     * 这里只留一行日志说明拿不到，`hasMore=false` 让界面安安静静停下。
     */
    hilog.info(DOMAIN, TAG, 'inbox cursor unreadable (structural) keys=%{public}s',
      Object.keys(box).join(','));
    return new DirectInboxPage(page.threads, '', false);
  }
}
