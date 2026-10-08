/*
 * 信息流状态行的语义。
 *
 * view-model 只报「现在处于什么状态」（外加动态细节），由页面负责映射成
 * `$r('app.string.*')` 文案。这样 view-model 不必依赖 ArkUI 的 Resource 类型，
 * 页面也能用一个明确的布尔量控制状态行是否显示（ResourceStr 是联合类型，
 * 没法直接取 .length 判空）。
 */
export enum FeedStatus {
  /** 无状态行：加载成功、内容已就绪。 */
  Idle = 0,
  /** 正在读首屏。 */
  Loading = 1,
  /** 正在加载更多。 */
  LoadingMore = 2,
  /** 页面桥还没就绪。 */
  PageNotReady = 3,
  /** 页面返回了无法解析的数据。 */
  Unparsable = 4,
  /** 首屏没有任何可读帖子。 */
  NoneVisible = 5,
  /** 没有更多帖子了。 */
  NoMore = 6,
  /** 没读到帖子。 */
  NoneRead = 7,
  /** 读取失败，detail 为原因。 */
  Failed = 8
}
