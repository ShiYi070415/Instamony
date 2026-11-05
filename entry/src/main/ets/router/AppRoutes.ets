/*
 * **路由名与页面分类的唯一来源**。
 *
 * 现状：`Index.ets` 里散落着一批字符串常量（settings / postPage / userProfile…），
 * `pushPage`、`destinationBuilder`、tab 缓存都直接比字符串。先把“名字”和“分类”收在这里，
 * 下一步再把 push/pop 规则收进 AppRouter。
 */

/** 主页面（左侧/底栏那一层）。 */
export enum PrimaryRoute {
  HOME = 0,
  REELS = 1,
  DIRECT = 2,
  SEARCH = 3,
  PROFILE = 4
}

/** 页面名（NavPathStack 里的 name）。 */
export class AppRoutes {
  static readonly NOTIFICATIONS: string = 'notifications';
  static readonly SETTINGS: string = 'settings';
  static readonly SETTINGS_DETAIL: string = 'settingsDetail';
  static readonly SPONSOR: string = 'sponsor';
  static readonly ADD_ACCOUNT: string = 'addAccount';
  static readonly USER_PROFILE: string = 'userProfile';
  static readonly POST: string = 'postPage';
  static readonly PROFILE_REELS: string = 'profileReels';
  static readonly SEARCH_REELS: string = 'searchReels';

  /** 详情页：进右栏（Expanded）或整页压栈（Compact）。 */
  static isDetail(name: string): boolean {
    return name === AppRoutes.POST
      || name === AppRoutes.USER_PROFILE
      || name === AppRoutes.PROFILE_REELS
      || name === AppRoutes.SEARCH_REELS
      || name === AppRoutes.SETTINGS
      || name === AppRoutes.SETTINGS_DETAIL
      || name === AppRoutes.NOTIFICATIONS
      || name === AppRoutes.ADD_ACCOUNT
      || name === AppRoutes.SPONSOR;
  }

  /** 设置/通知这类“覆盖层页面”：它们关闭时要清 tab 缓存。 */
  static isOverlay(name: string): boolean {
    return name === AppRoutes.SETTINGS
      || name === AppRoutes.SETTINGS_DETAIL
      || name === AppRoutes.NOTIFICATIONS;
  }
}
