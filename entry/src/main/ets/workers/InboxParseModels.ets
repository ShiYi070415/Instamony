/*
 * 收件箱解析的**数据与工具**（供 workers/InboxParseTask 的 `@Concurrent` 函数使用）。
 *
 * 为什么要单独一个文件：ArkTS 规定 `@Concurrent` 函数**只能引用"导入的符号"或局部变量** ——
 * 同一个文件里定义的类/函数不算，编译直接报
 * "Concurrent function should only use import variable or local variable"。
 * 所以模型（InboxRow / InboxParseResult）和两个纯工具函数都放这里，任务那边只 import。
 *
 * 这里的东西必须**完全无副作用**：不碰单例、不碰 AppStorage、不写日志（跨线程写日志只会更慢）。
 */

import { JsonRead } from '../core/JsonRead';

/** 一组"还能往下翻"的游标键（REST 收件箱给的是 `oldest_cursor`）。 */
export const INBOX_CURSOR_KEYS: Array<string> = ['oldest_cursor', 'prev_cursor'];

/** 一条会话的**纯字段**形态（跨线程传的就是它，不带方法）。 */
export class InboxRow {
  id: string = '';
  key: string = '';
  title: string = '';
  avatar: string = '';
  username: string = '';
  isGroup: boolean = false;
  unread: boolean = false;
  unreadCount: number = 0;
  muted: boolean = false;
  pinned: boolean = false;
  tsMs: number = 0;
  text: string = '';
  kind: string = '';
}

/** 一整页解析结果：会话行 + 游标（`cursor` 空 = 没有更多）。 */
export class InboxParseResult {
  rows: Array<InboxRow> = [];
  /** `next_max_id`（有的版本用它翻页）。 */
  nextMaxId: string = '';
  /** 可用的翻页游标（从 `oldest_cursor` / `prev_cursor` 里挑，只认字符串）。 */
  cursor: string = '';
  /** 后面还有没有（`has_older` 或给了游标）。 */
  hasOlder: boolean = false;
  /**
   * 实时通道的订阅位点（顶层 `seq_id` / `snapshot_at_ms`）。
   *
   * 一起解析出来的原因：主线程以前为了这两个值**又 parse 一遍整页**（800 KB 级的响应，
   * 见 noteSyncState）—— 顺手带走，主线程就不必再碰这坨 JSON 了。
   */
  seqId: number = 0;
  snapshotAtMs: number = 0;
  /** 解析失败的原文（诊断用；空 = 成功）。 */
  error: string = '';
}

/** 头像：`profile_pic_url` 优先，退回 `profile_pic_url_hd`（和主线程那版同规则）。 */
export function inboxPictureOf(user: Record<string, Object>): string {
  const normal: string = JsonRead.strOf(user, 'profile_pic_url');
  if (normal.length > 0) {
    return normal;
  }
  return JsonRead.strOf(user, 'profile_pic_url_hd');
}

/**
 * 我还没看的消息有几条（**封顶 4**）。这是**唯一实现**：主线程回退路径
 * (`DirectMapper.unreadCountOf`) 直接调它，保证"走线程池"和"退回主线程"算出同一个数。
 *
 * 判据（真机校准过，别改）：
 *   · `items` 为空 → 0（这一条会话最近没有消息，谈不上未读）；
 *   · 不知道我是谁（`me` 为空）→ -1（算不出来，交给调用方按 `read_state` 兜底）；
 *   · 没有 `last_seen_at` → -1（同上）；
 *   · 有 `last_seen_at` 但没有我这一项 → 当作"从没读过"（seenMicros = 0），于是**全部算未读**；
 *   · 比较用**微秒原值**（时间戳都是微秒，别先除 1000，边界上会差一条）。
 */
export function inboxUnreadCountOf(thread: Record<string, Object>, me: string,
                                   items: Array<Object>): number {
  if (items.length === 0) {
    return 0;
  }
  if (me.length === 0) {
    return -1;
  }
  const lastSeen: Record<string, Object> | null = JsonRead.recordOf(thread, 'last_seen_at');
  if (lastSeen === null) {
    return -1;
  }
  const mine: Record<string, Object> | null = JsonRead.recordOf(lastSeen, me);
  const seenMicros: number = mine === null ? 0 : JsonRead.numOf(mine, 'timestamp');
  let count: number = 0;
  for (let index: number = 0; index < items.length && count < 4; index++) {
    const item: Record<string, Object> | null = JsonRead.asRecord(items[index]);
    if (item === null) {
      continue;
    }
    const sender: string = JsonRead.strOf(item, 'user_id');
    if (sender.length > 0 && sender === me) {
      continue;
    }
    const at: number = JsonRead.numOf(item, 'timestamp');
    if (at > seenMicros) {
      count++;
    }
  }
  return count;
}
