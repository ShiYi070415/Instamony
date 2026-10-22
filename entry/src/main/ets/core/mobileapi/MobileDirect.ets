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
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
// 发消息要现生成两个 uuid（`client_context` / `mutation_token`）。
import { uuid4 } from './MobileSign';
import { DirectInboxPage, DirectMapper, DirectThread, DirectThreadView } from '../../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileDirect';

/** 一页会话几条（instagrapi 的 `amount`，默认 20）。 */
const INBOX_PAGE_SIZE: number = 20;
/** 每个会话先带几条最近消息（instagrapi 的 `thread_message_limit`，默认 10）。 */
const THREAD_MESSAGE_LIMIT: number = 10;
/** 打开一条会话时先取几条消息（instagrapi 的 `amount`，默认 20）。 */
const THREAD_PAGE_SIZE: number = 20;
/**
 * 翻页游标的候选键（顺序即优先级）；**只看 `inbox` 自己这一层**，别钻进 threads 里。
 *
 * 实测（`MobileProbe.inboxPageVariants`，2026-10-17）：
 *   · `oldest_cursor`（105 字符串）→ **200，且真的换了页**（回来的第一会话与第一页不同，n=20）；
 *   · `prev_cursor`（同一条 105 字符串）→ 同样 200/NEW；
 *   · `next_cursor`（180 的结构体）→ **400** `Invalid Inbox Cursor…`；
 *   · `prev_cursor_v2`（81）→ 400；表单体里带游标 → 200 但**又是第一页**（参数被忽略）。
 * 所以只认前两个（它们其实是同一串值），别的键一个都不能用。
 */
const CURSOR_KEYS: Array<string> = ['oldest_cursor', 'prev_cursor'];
/**
 * 移动端收件箱的翻页游标**是否已解出可用形态** —— 已解出（见上面实测），所以打开。
 *
 * 关掉它 = 移动端只给第一页（界面不会去点"加载更多"）；调试时想退回那个状态就改这里。
 */
const MOBILE_INBOX_CURSOR_USABLE: boolean = true;

export class MobileDirect {
  /** 已经打过"id 候选"那行的会话（见 logIdCandidates；只为去噪）。 */
  private static idLoggedFor: string = '';
  /**
   * 收件箱一页（拿不到给 null）。
   *
   * @param cursor 上一页的游标（空串 = 第一页）
   */
  static async inbox(cursor: string = ''): Promise<DirectInboxPage | null> {
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
    /*
     * 游标**只走查询串**（实测：表单体里带 `cursor` 会被忽略 —— 回 200 但又是第一页，
     * 这种"原地打转"最坑，翻页看着成功、内容一模一样）。参数名就用 `cursor`，
     * 值取响应里的 `oldest_cursor`（见 CURSOR_KEYS 的实测表）。
     */
    let query: string = 'visual_message_return_type=unseen'
      + `&thread_message_limit=${THREAD_MESSAGE_LIMIT}&persistentBadging=true&limit=${INBOX_PAGE_SIZE}`;
    if (cursor.length > 0) {
      query += `&cursor=${encodeURIComponent(cursor)}`;
    }
    const result: MobileResult = await MobileRequest.send(
      'direct_v2/inbox/', MobileRequest.formOf(data), query, true, null,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.warm()));
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'inbox failed: %{public}s', result.summary());
      return null;
    }
    // 请求带没带游标、翻页回来的第一会话是谁 —— 排查"加载更多到底动没动"就看这一行。
    hilog.info(DOMAIN, TAG, 'inbox req cursorLen=%{public}d bytes=%{public}d',
      cursor.length, result.bytes);
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
    MobileDirect.noteSyncState(result.body);
    return fixed;
  }

  /**
   * 从收件箱响应里取出**实时通道的订阅状态**（`seq_id` / `snapshot_at_ms`）。
   *
   * 为什么在这儿取：instagrapi 的 `RealtimeClient.direct_subscribe` 就是这么做的 ——
   * 先 `direct_threads(amount=1)`，再从 `last_json` 顶层读这两个值，然后 `iris_subscribe`。
   * 它们是私信实时同步的**唯一门槛**（没有它订阅不了）。取到就缓存下来，
   * 由 `pages/Index`（或私信页）在实时通道连上后转给 MobileRealtime.subscribeDirect。
   */
  private static noteSyncState(body: string): void {
    const parsed: Record<string, Object> | null = MobileDirect.parse(body);
    if (parsed === null) {
      return;
    }
    const seq: number = MobileDirect.numberOf(parsed, 'seq_id');
    const snapshot: number = MobileDirect.numberOf(parsed, 'snapshot_at_ms');
    if (seq > 0 && snapshot > 0) {
      MobileDirect.syncSeqId = seq;
      MobileDirect.syncSnapshotAtMs = snapshot;
      hilog.info(DOMAIN, TAG, 'inbox sync state seq=%{public}d snapshot=%{public}d',
        seq, snapshot);
      return;
    }
    // 没有就如实说：订阅私信实时同步要靠这两个值，缺了只能继续轮询。
    hilog.info(DOMAIN, TAG, 'inbox has no sync state keys=%{public}s',
      Object.keys(parsed).slice(0, 12).join(','));
  }

  /** 收件箱给出的实时同步状态（0 = 还没拿到；见 noteSyncState）。 */
  static syncSeqId: number = 0;
  static syncSnapshotAtMs: number = 0;

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

  /**
   * **把一条会话标成已读**（对准 instagrapi 的 `direct_send_seen` → `direct_message_seen`）。
   *
   * 端点与字段照抄：
   *   `POST direct_v2/threads/{thread_id}/items/{message_id}/seen/`
   *   `thread_id` / `action=mark_seen` / `client_context` / `_uuid` / `offline_threading_id`
   * 注意 instagrapi 这一发是 **with_signature=False**：不走 `signed_body`，直接发表单。
   *
   * 为什么需要：不告诉服务端"我看过了"，收件箱里那条会话的未读状态就会一直留着
   * （用户报的"已读私信全变成未读"除了本地判据，也有一半是这个原因）。
   *
   * @param messageId 会话里**最新**那条消息的 id（instagrapi 用 `thread.messages[0].id`）
   */
  static async markSeen(threadId: string, messageId: string): Promise<boolean> {
    const id: string = threadId.trim();
    const mid: string = messageId.trim();
    if (id.length === 0 || mid.length === 0) {
      return false;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return false;
    }
    const token: string = uuid4();
    const data: Record<string, Object> = {};
    data['thread_id'] = id;
    data['action'] = 'mark_seen';
    data['client_context'] = token;
    data['_uuid'] = identity.uuid;
    data['offline_threading_id'] = token;
    const endpoint: string = `direct_v2/threads/${encodeURIComponent(id)}/items/`
      + `${encodeURIComponent(mid)}/seen/`;
    // signed=false：instagrapi 这一发就是普通表单（见方法说明）。
    const result: MobileResult = await MobileRequest.send(endpoint, MobileRequest.formOf(data), '',
      false, null, new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.idle()));
    const ok: boolean = result.ok && result.body.indexOf('"status":"ok"') >= 0;
    hilog.info(DOMAIN, TAG, 'mark seen thread=%{public}s msg=%{public}s → %{public}s',
      id, mid, ok ? 'ok' : result.summary());
    return ok;
  }

  /**
   * **发一条文字私信**（移动端私有 API：`direct_v2/threads/broadcast/text/`）。
   *
   * ## 字段表逐条照抄 instagrapi 的 `direct_send`（这是本轮修复的核心）
   * 真机实测（2026-10-19）：我们原来那版**带签名**（`signed_body=`）只有 7 个字段，
   * IG 回 `400` + 62 字节的通用错误 `很抱歉，出错了，请重试。`；而 instagrapi 这一发是
   * **不签名**的（`with_signature=False`），并且体里有 15 个字段。差异就是拒收的原因：
   *
   *   · `with_signature=False` —— 这条写接口**不认** `signed_body`，要普通表单体；
   *   · `client_context` / `mutation_token` / `offline_threading_id` 是**同一个** token
   *     （instagrapi 里 `token = self.generate_mutation_token()` 之后三个键都填它）；
   *     我们原来给 client_context 和 mutation_token 各生成一个 uuid，服务端对不上就丢消息；
   *   · `send_attribution=message_button`（不是 `direct_thread`）；
   *   · `is_x_transport_forward` / `send_silently` / `btt_dual_send` / `is_ae_dual_send` /
   *     `nav_chain` 这几个"看起来没用"的字段也必须带 —— IG 的写接口会校验它们的**存在**。
   *
   * 失败时由调用方退回网页 REST 那条老路（见 core/NativeDirect.sendText）。
   *
   * @returns 服务端回 `{"status":"ok"}` 才算成功。
   */
  static async sendText(threadId: string, text: string): Promise<boolean> {
    const id: string = threadId.trim();
    const body: string = text;
    if (id.length === 0 || body.length === 0) {
      return false;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'send skipped: no session');
      return false;
    }
    const data: Record<string, Object> = MobileRequest.withExtraData(identity);
    // 三个键共用同一个 token（见上面的说明）。
    const token: string = uuid4();
    data['action'] = 'send_item';
    data['is_x_transport_forward'] = 'false';
    data['send_silently'] = 'false';
    data['is_shh_mode'] = '0';
    data['send_attribution'] = 'message_button';
    data['client_context'] = token;
    data['device_id'] = identity.androidDeviceId;
    data['mutation_token'] = token;
    data['_uuid'] = identity.uuid;
    data['btt_dual_send'] = 'false';
    data['nav_chain'] = '1qT:feed_timeline:1,1qT:feed_timeline:2,1qT:feed_timeline:3,'
      + '7Az:direct_inbox:4,7Az:direct_inbox:5,5rG:direct_thread:7';
    data['is_ae_dual_send'] = 'false';
    data['offline_threading_id'] = token;
    data['text'] = body;
    /*
     * `thread_ids` 照 instagrapi 的写法是**不带引号的数字数组**：`json.dumps([int(id)])` → `[123]`。
     */
    data['thread_ids'] = `[${id}]`;
    hilog.info(DOMAIN, TAG, 'send mobile entry thread=%{public}s len=%{public}d idLen=%{public}d',
      id, body.length, id.length);
    // **不签名**（instagrapi 的 with_signature=False）：第 4 个参数是 false。
    const result: MobileResult = await MobileRequest.send(
      'direct_v2/threads/broadcast/text/', MobileRequest.formOf(data), '', false, null,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.interactive()));
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'send miss thread=%{public}s %{public}s body=%{public}s',
        id, result.summary(), result.body.substring(0, 160).replace(/[\r\n]+/g, ' '));
      return false;
    }
    const ok: boolean = result.body.indexOf('"status":"ok"') >= 0
      || result.body.indexOf('"status": "ok"') >= 0;
    hilog.info(DOMAIN, TAG, 'send %{public}s thread=%{public}s len=%{public}d ack=%{public}s',
      ok ? 'ok' : 'rejected', id, body.length, result.body.substring(0, 160));
    return ok;
  }

  /**
   * 一条会话的消息页（拿不到给 null）。
   *
   * @param threadId 会话 id（19~20 位长数字，**必须**走 `JsonRead.parseWithBigIds` 那条取值路径，
   *                 普通 JSON.parse 会把它舍入成 30 位错 id —— 见 DirectMapper 的说明）
   * @param olderCursor 取更老那批的游标（空串 = 最新那批）
   * @param priority 排队优先级（默认 WARM；后台预取传 `ApiThrottle.idle()`）
   * @param limit 要几条（默认 20 = "一页"；预取只要 5，见 DirectPrefetch）
   */
  static async thread(threadId: string, olderCursor: string = '',
                      priority: number = ApiThrottle.warm(),
                      limit: number = THREAD_PAGE_SIZE): Promise<DirectThreadView | null> {
    const id: string = threadId.trim();
    if (id.length === 0) {
      return null;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return null;
    }
    let params: string = `limit=${limit}`;
    if (olderCursor.length > 0) {
      params += `&cursor=${encodeURIComponent(olderCursor)}`;
    }
    const result: MobileResult = await MobileRequest.send(
      `direct_v2/threads/${id}/`, '', params, true, null,
      new MobileOptions(ApiThrottle.DIRECT, priority));
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
    MobileDirect.logIdCandidates(id, result.body);
    return view;
  }

  /**
   * 把会话响应里**所有可能是"会话 id"的字段**打一行（诊断用，一发一次）。
   *
   * 为什么要它：`direct_v2/threads/<id>/` 这条**读**接口接受我们手上的这个 id（39 位、
   * 接近 2^128），但 `broadcast/text/` 那条**写**接口一直 400 —— 两件事要么是同一把
   * id 两边都认，要么是读用的是 `thread_v2_id`、写要的是 `thread_id`。
   * 把四个候选键一次都打出来，就不用再猜了。
   */
  private static logIdCandidates(threadId: string, body: string): void {
    // 每条会话只打一次：会话页每 10 秒轮询一次，不设闸门就是每分钟 6 行噪音。
    if (MobileDirect.idLoggedFor === threadId) {
      return;
    }
    const parsed: Record<string, Object> | null = MobileDirect.parse(body);
    if (parsed === null) {
      return;
    }
    const thread: Object | undefined = parsed['thread'];
    if (thread === undefined || thread === null || Array.isArray(thread)) {
      return;
    }
    MobileDirect.idLoggedFor = threadId;
    const box: Record<string, Object> = thread as Record<string, Object>;
    const keys: Array<string> = ['thread_id', 'thread_v2_id', 'thread_fbid', 'thread_key'];
    const parts: Array<string> = [];
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object | undefined = box[keys[index]];
      if (value === undefined || value === null) {
        parts.push(`${keys[index]}=-`);
        continue;
      }
      parts.push(`${keys[index]}=${value}`);
    }
    hilog.info(DOMAIN, TAG, 'thread ids requested=%{public}s %{public}s',
      threadId, parts.join(' '));
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
   * 用**响应里真正可用的**游标键补一个 `DirectInboxPage`。
   *
   * 实测（`MobileProbe.inboxPageVariants`，2026-10-17；判据是"回来的第一会话 id 是否与上一页不同"）：
   *   · `cursor=<oldest_cursor>`（105 字符串）→ **200 且真的换了页**（n=20，第一会话不同）✓
   *   · `cursor=<prev_cursor>`（同一串值）→ 同样 200/NEW ✓
   *   · `cursor=<next_cursor>`（180 的结构体 `{cursor_thread_v2_id,…}`）→ **400**
   *     `Invalid Inbox Cursor: The cursor parameter passed in the Inbox API is not valid.`
   *   · `cursor=<prev_cursor_v2>`（81）→ 400；表单体里带 `cursor` → 200 但**又是第一页**（被忽略）。
   *
   * 所以：只认 `oldest_cursor` / `prev_cursor`，并且**必须放在查询串里**。
   * 另外那句 400 的教训值得记着：**200 不等于翻页成功** —— IG 对不认识的游标会原样再给第一页，
   * 只看状态码会把"原地打转"当成功、把同一页塞两遍。
   */
  private static withCursor(page: DirectInboxPage, body: string): DirectInboxPage {
    if (page.endCursor.length > 0 || !page.hasMore) {
      return page;
    }
    if (!MOBILE_INBOX_CURSOR_USABLE) {
      // 调试开关关掉时（想看"只有第一页"的样子）：如实报没有更多，别让界面空转。
      return new DirectInboxPage(page.threads, '', false);
    }
    const parsed: Record<string, Object> | null = MobileDirect.parse(body);
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
      // **只认字符串**：结构体那种（`next_cursor`）实测会被 400 拒掉。
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
    // 响应里没有可用游标（只有结构体那种）：如实说"没有更多"，别把不合法游标交给界面。
    hilog.info(DOMAIN, TAG, 'inbox has no usable cursor keys=%{public}s',
      Object.keys(box).join(','));
    return new DirectInboxPage(page.threads, '', false);
  }

  private static parse(text: string): Record<string, Object> | null {
    try {
      return JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      return null;
    }
  }
}
