/*
 * 原生壳的底部标签。
 *
 * Home 走原生信息流；其余标签直接把常驻的 Instagram 网页揭出来，
 * 这样网页的 SPA 状态与会话都不必重建。
 *
 * 枚举值**就是底部 tab 栏的显示顺序**（见 pages/Index.ets 的 TAB_ITEMS），
 * HdsTabs 的 onTabBarClick 报的就是这个下标。
 */
export enum AppTab {
  Home = 0,
  Reels = 1,
  Direct = 2,
  Search = 3,
  Profile = 4
}
