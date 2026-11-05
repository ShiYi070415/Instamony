/*
 * **账号切换：页面侧 UI 复位**。
 *
 * 具体字段仍在 pages/Index（@State、视图模型句柄都在那儿），
 * 这里只固定"先导航、再标志位、再视图模型、最后缓存"的顺序。
 */

export class AccountUiReset {
  static run(clearNavigation: () => void, clearAccountFlags: () => void,
             resetAccountViewModels: () => void, clearAccountCaches: () => void): void {
    clearNavigation();
    clearAccountFlags();
    resetAccountViewModels();
    clearAccountCaches();
  }
}
