/**
 * Reels 页 → HdsNavigation 标题栏之间的"当前这条"信息桥。
 *
 * 为什么需要它：需求要求 reels 的**下载/静音两颗按钮放进 HdsNavigation 标题栏**
 * （那里正是官方支持的沉浸光感区域），而标题栏是 Index 画的、当前播的是第几条只有
 * ReelsPage 知道。两边通过 AppStorage 对接：
 *   - visible：现在是不是该显示这两颗按钮（reels 页有可播的视频时才显示）；
 *   - url / title：当前这条**原视频**地址与标题（下载用原始地址，不是降级后的展示地址）。
 *
 * ReelsPage 在每次切条（switchTo）与首屏铺数据后写，Index 的标题栏菜单在点击时读。
 * 用 AppStorage 而不是回调：标题栏的菜单项是 Index 的 @Builder，走回调要层层传，
 * 而这三个值本来就是"应用级的一小块状态"。
 *
 * ## 为什么按**来源**分开存
 * reels 类页面现在有三个：底栏「视频」标签那一页（HOME）、用户主页视频分页点进去的那页
 * （PROFILE）、搜索推荐流点进去的那页（SEARCH）。它们是**同一个组件**（ReelsPage），
 * 但各自独立存在（一个被另一个盖住时页面还在内存里）。
 * 只存一份的话，"从用户主页那页返回"会把底栏那页的下载地址覆盖掉/或反过来 ——
 * 标题栏那颗下载按钮就会下到**另一条**视频（真机上就是这么错的）。
 * 所以每个来源一份，标题栏只读**自己那一份**；版本号用来通知界面重绘
 * （`@StorageProp(REELS_ACTION_VERSION)`，值本身没用，要的是那一次通知）。
 */

/** 每个来源各自一份的三个值（key 里带来源，动态拼）。 */
const VISIBLE_PREFIX: string = 'reelsActionVisible:';
const URL_PREFIX: string = 'reelsActionUrl:';
const TITLE_PREFIX: string = 'reelsActionTitle:';
/** 版本号：任何一次 publish 都 +1，标题栏靠它重绘（值本身不用）。 */
export const REELS_ACTION_VERSION: string = 'reelsActionVersion';

export class ReelsAction {
  /** 底栏「视频」标签那一页（历史默认值，保持旧的调用点不用改）。 */
  static readonly HOME: string = 'home';
  /** 用户主页视频分页点进去的那一页（PROFILE_REELS_PAGE）。 */
  static readonly PROFILE: string = 'profile';
  /** 搜索推荐流点进去的那一页（SEARCH_REELS_PAGE）。 */
  static readonly SEARCH: string = 'search';

  /** ReelsPage 每次切条调一次（没有可播的就传 visible=false）。 */
  static publish(source: string, visible: boolean, url: string, title: string): void {
    const key: string = source.length > 0 ? source : ReelsAction.HOME;
    AppStorage.setOrCreate(`${VISIBLE_PREFIX}${key}`, visible);
    AppStorage.setOrCreate(`${URL_PREFIX}${key}`, url);
    AppStorage.setOrCreate(`${TITLE_PREFIX}${key}`, title);
    const version: number = AppStorage.get<number>(REELS_ACTION_VERSION) ?? 0;
    AppStorage.setOrCreate(REELS_ACTION_VERSION, version + 1);
  }

  /** 标题栏点击下载时读（按来源取）。 */
  static urlFor(source: string): string {
    return AppStorage.get<string>(`${URL_PREFIX}${source}`) ?? '';
  }

  static titleFor(source: string): string {
    return AppStorage.get<string>(`${TITLE_PREFIX}${source}`) ?? 'reel';
  }

  static visibleFor(source: string): boolean {
    return AppStorage.get<boolean>(`${VISIBLE_PREFIX}${source}`) ?? false;
  }

  /** 底栏那一页的快捷读法（旧调用点沿用）。 */
  static url(): string {
    return ReelsAction.urlFor(ReelsAction.HOME);
  }

  static title(): string {
    return ReelsAction.titleFor(ReelsAction.HOME);
  }

  static visible(): boolean {
    return ReelsAction.visibleFor(ReelsAction.HOME);
  }
}
