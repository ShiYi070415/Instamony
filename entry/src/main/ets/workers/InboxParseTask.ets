/*
 * **收件箱解析任务**（跑在 TaskPool 线程里）。
 *
 * ## 为什么把这一步挪走
 * `direct_v2/inbox/` 一页 20 条会话，响应体常在 100~300 KB，而且我们**解析两次**：
 *   ① `DirectMapper.inboxFromRestJson(body)` —— 建模型；
 *   ② `MobileDirect.withCursor(page, body)` —— 只为了再捞一次游标。
 * `JsonRead.parseWithBigIds` 是"正则预处理 + JSON.parse"，这两遍全在 UI 线程上跑。
 *
 * ## 线程契约（ArkTS 的硬限制）
 * `@Concurrent` 函数**只能引用"导入的符号"或局部变量** —— 同文件里定义的类/函数都不行
 * （编译报 "Concurrent function should only use import variable or local variable"）。
 * 所以模型与两个纯工具函数在 `workers/InboxParseModels`，这里只 import 使用。
 * 回传的 `InboxParseResult` 是**纯字段类**（不带方法）：TaskPool 传对象时不带方法。
 * `DirectThread` 这类带方法的模型仍然在主线程按行拼（见 `DirectMapper.inboxFromParsed`）。
 *
 * ## 为什么不用 Worker
 * 这是一来一回的短任务（解析一页就结束），Worker 适合常驻连接；TaskPool 自动复用线程，
 * 几页并发解析也不会互相顶。
 */

import { JsonRead } from '../core/JsonRead';
import {
  INBOX_CURSOR_KEYS,
  InboxParseResult,
  InboxRow,
  inboxPictureOf,
  inboxUnreadCountOf
} from './InboxParseModels';

/**
 * **收件箱响应 → 会话行 + 游标**（TaskPool 里跑的就是这个）。
 *
 * 用 `parseWithBigIds`：`thread_id` 是 19~20 位数字，普通 `JSON.parse` 会先舍入成 double，
 * 转回字符串就是一串错 id（点开会话直接 404，见 core/JsonRead 的说明）。
 */
@Concurrent
export function parseInboxTask(raw: string): InboxParseResult {
  const out: InboxParseResult = new InboxParseResult();
  let root: Record<string, Object>;
  try {
    root = JsonRead.parseWithBigIds(raw);
  } catch (error) {
    out.error = `parse: ${(error as Error).message ?? 'unknown'}`;
    return out;
  }
  if (Object.keys(root).length === 0) {
    out.error = 'empty';
    return out;
  }
  const box: Record<string, Object> | null = JsonRead.recordOf(root, 'inbox');
  if (box === null) {
    out.error = 'no-inbox';
    return out;
  }
  const list: Array<Object> = JsonRead.arrayOf(box, 'threads');
  for (let index: number = 0; index < list.length; index++) {
    const th: Record<string, Object> | null = JsonRead.asRecord(list[index]);
    if (th === null) {
      continue;
    }
    const id: string = JsonRead.strOf(th, 'thread_id');
    if (id.length === 0) {
      continue;
    }
    const users: Array<Object> = JsonRead.arrayOf(th, 'users');
    let username: string = '';
    let fullName: string = '';
    let avatar: string = '';
    for (let at: number = 0; at < users.length; at++) {
      const u: Record<string, Object> | null = JsonRead.asRecord(users[at]);
      if (u === null) {
        continue;
      }
      const pic: string = inboxPictureOf(u);
      if (username.length === 0) {
        username = JsonRead.strOf(u, 'username');
      }
      if (fullName.length === 0) {
        fullName = JsonRead.strOf(u, 'full_name');
      }
      if (avatar.length === 0 && pic.length > 0) {
        avatar = pic;
      }
    }
    const groupTitle: string = JsonRead.strOf(th, 'thread_title');
    const isGroup: boolean = JsonRead.boolOf(th, 'is_group');
    let title: string = isGroup
      ? (groupTitle.length > 0 ? groupTitle : (fullName.length > 0 ? fullName : username))
      : (fullName.length > 0 ? fullName : (username.length > 0 ? username : groupTitle));
    if (title === 'Empty' && username.length > 0) {
      title = username;
    }
    const items: Array<Object> = JsonRead.arrayOf(th, 'items');
    let text: string = '';
    let kind: string = '';
    if (items.length > 0) {
      const first: Record<string, Object> | null = JsonRead.asRecord(items[0]);
      if (first !== null) {
        text = JsonRead.strOf(first, 'text');
        kind = JsonRead.strOf(first, 'item_type');
      }
    }
    const micros: number = JsonRead.numOf(th, 'last_activity_at');
    const me: string = JsonRead.strOf(th, 'viewer_id');
    const count: number = inboxUnreadCountOf(th, me, items);
    const readState: string = JsonRead.strOf(th, 'read_state').toLowerCase();
    const row: InboxRow = new InboxRow();
    row.id = id;
    row.title = title;
    row.avatar = isGroup ? '' : avatar;
    row.username = username;
    row.isGroup = isGroup;
    row.unreadCount = count > 0 ? count : 0;
    row.unread = count >= 0
      ? count > 0
      : (readState === '1' || readState === 'true' || readState === 'unread');
    row.muted = JsonRead.boolOf(th, 'muted');
    row.pinned = JsonRead.boolOf(th, 'is_pin');
    row.tsMs = micros > 0 ? Math.round(micros / 1000) : 0;
    row.text = text;
    row.kind = kind;
    out.rows.push(row);
  }
  out.nextMaxId = JsonRead.strOf(box, 'next_max_id');
  // 只认字符串游标：结构体那种（`next_cursor`）实测会被 400 拒掉。
  for (let index: number = 0; index < INBOX_CURSOR_KEYS.length; index++) {
    const value: Object | undefined = box[INBOX_CURSOR_KEYS[index]];
    if (value === undefined || value === null || typeof value !== 'string') {
      continue;
    }
    const text: string = `${value}`.trim();
    if (text.length > 0) {
      out.cursor = text;
      break;
    }
  }
  out.hasOlder = JsonRead.boolOf(box, 'has_older') || out.nextMaxId.length > 0
    || out.cursor.length > 0;
  // 实时通道订阅位点（顺带带走，省主线程再 parse 一遍整页）。
  out.seqId = JsonRead.numOf(root, 'seq_id');
  out.snapshotAtMs = JsonRead.numOf(root, 'snapshot_at_ms');
  return out;
}
