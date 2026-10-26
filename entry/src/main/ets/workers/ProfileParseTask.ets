/*
 * **个人页网格响应解析任务**（跑在 TaskPool 线程里）。
 *
 * 只做一件事：`JSON.parse`。个人页四个分页（帖子 / Reels / 收藏 / 被标注）一页
 * 100~300KB，解析在主线程会压住"切段那一帧"。摘字段与映射留在主线程 ——
 * 那部分要读会话态（`EngageState` / 画质档），而且每条只有几百微秒。
 *
 * 线程契约：参数只传 string，回传的是 `JSON.parse` 出来的纯对象（无方法），可以跨线程。
 */

/** 响应体 → 纯 JSON 对象（解析失败给 null，调用方按"非 JSON"处理）。 */
@Concurrent
export function parseProfileGrid(body: string): Record<string, Object> | null {
  if (body.length === 0) {
    return null;
  }
  try {
    return JSON.parse(body) as Record<string, Object>;
  } catch (error) {
    return null;
  }
}
