/*
 * **私信会话详情解析任务**（跑在 TaskPool 线程里）。
 *
 * ## 为什么挪它
 * `direct_v2/threads/<id>/` 是**点开会话时你在等的那一发**：一页 20 条消息，
 * 响应几十到上百 KB，`DirectMapper.threadFromJson` 要在主线程上
 * "JSON.parse + 逐条消息取字段 + 找图片候选"，正好压在转场动画那一瞬间。
 *
 * ## 为什么能直接跨线程调
 * `DirectMapper.threadFromJson()` 是**纯函数**（只做 JSON.parse 与字段提取，不碰 AppStorage /
 * 单例 / UI）；它返回的 `DirectThreadView` / `DirectMessage` 也**只有字段、没有任何方法** ——
 * TaskPool 传对象时不带方法，这一点必须成立才能这么用（带方法的模型见 `DirectThread`，
 * 那个只能在主线程拼，收件箱那条就是这样处理的）。
 *
 * ⚠️ ArkTS 限制：`@Concurrent` 函数只能引用**导入的符号**或局部变量。
 */

import { DirectMapper, DirectThreadView } from '../model/Direct';

/** 会话详情响应 → 视图对象（TaskPool 里跑的就是这个）。 */
@Concurrent
export function parseThreadTask(raw: string, ownId: string): DirectThreadView | null {
  return DirectMapper.threadFromJson(raw, ownId);
}
