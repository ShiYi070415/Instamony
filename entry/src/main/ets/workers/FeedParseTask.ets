/*
 * **信息流首页解析任务**（跑在 TaskPool 线程里）。
 *
 * ## 为什么之前搬不动、现在能了
 * `NativeTimelineParser.parseMobileFeed` 的解析链里会调 `MediaQuality` 挑清晰度，
 * 而 `MediaQuality` 要读 `AppSettings` / `NetworkState` —— 那些在 **AppStorage** 上，
 * 线程池里没有这个 API（第一次尝试真机报 `ReferenceError: AppStorage is not defined`）。
 *
 * 现在改成：主线程先 `QualityProfile.now()` 把"该用多大"算成**三个纯值**，
 * 连 body 一起递进来；解析里只做纯计算（见 `MediaQuality.imageWith/videoWith/imageAtWith`）。
 *
 * ## 线程契约
 * `@Concurrent` 只能引用导入的符号或局部变量；参数只传 **string / number**，
 * 不传带方法的对象。回传的 `NativeTimeline` 里装的是 `FeedItemDto`（纯字段接口），可以跨线程。
 */

import { QualityProfile } from '../core/MediaQuality';
import { NativeTimeline, NativeTimelineParser } from '../core/NativeTimelineParser';

/** 信息流 timeline 响应 → 纯数据行（TaskPool 里跑的就是这个）。 */
@Concurrent
export function parseFeedTask(body: string, imageTarget: number, videoTarget: number,
                              gridMode: string): NativeTimeline | null {
  return NativeTimelineParser.parseMobileFeed(body,
    new QualityProfile(imageTarget, videoTarget, gridMode));
}
