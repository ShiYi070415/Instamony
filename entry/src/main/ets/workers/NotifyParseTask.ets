/*
 * **通知列表解析任务**（跑在 TaskPool 线程里）。
 *
 * ## 为什么挪它
 * 通知页那一发（`news/inbox/`）一次也有几百 KB，`parseInbox` 里是"JSON.parse + 逐条取字段 +
 * 占位符展开"，全在 UI 线程；而它还紧跟着一次 `parseAyml`（同一个响应再解析一遍推荐位）。
 * 用户点通知页时这一下是能感觉到的。
 *
 * ## 为什么能直接复用原生解析代码
 * `NativeNotifications.parseInboxItems()` 是**纯函数**（只做 JSON.parse 与字符串处理，
 * 不碰 AppStorage / 单例 / UI），所以 `@Concurrent` 函数里可以直接调用它 ——
 * 比把两百行解析逻辑再抄一份到这里安全（抄一份就必然和主线程那版跑偏）。
 *
 * ⚠️ ArkTS 限制：`@Concurrent` 函数只能引用**导入的符号**或局部变量 ——
 * 所以这里所有东西都是 import 进来的（模型类型 + 那个静态方法）。
 */

import { NativeNotifications } from '../core/NativeNotifications';
import { NotifyPayloadItem } from '../model/Notification';

/** 通知响应 → 条目数组（TaskPool 里跑的就是这个）。 */
@Concurrent
export function parseNotificationsTask(text: string): Array<NotifyPayloadItem> {
  return NativeNotifications.parseInboxItems(text);
}
