/*
 * **页面注册表**：路由名 → 页面元数据（是否详情页、是否覆盖层、标题 key）。
 *
 * 现在先承接 AppRoutes 的分类；下一步 `destinationBuilder` 的 if/else 会从这里取页面构造器。
 */

export class PageMeta {
  readonly name: string;
  readonly detail: boolean;
  readonly overlay: boolean;
  readonly title: string;

  constructor(name: string, detail: boolean, overlay: boolean, title: string) {
    this.name = name;
    this.detail = detail;
    this.overlay = overlay;
    this.title = title;
  }
}

export class PageRegistry {
  private static readonly entries: Array<PageMeta> = [
    new PageMeta('postPage', true, false, 'post_page_title'),
    new PageMeta('userProfile', true, false, ''),
    new PageMeta('profileReels', true, false, 'reels_page_title'),
    new PageMeta('searchReels', true, false, 'reels_page_title'),
    new PageMeta('settings', true, true, 'action_settings'),
    new PageMeta('settingsDetail', true, true, ''),
    new PageMeta('notifications', true, true, 'notifications'),
    new PageMeta('addAccount', true, false, 'account_add'),
    new PageMeta('sponsor', true, false, '')
  ];

  static of(name: string): PageMeta | null {
    for (let index: number = 0; index < PageRegistry.entries.length; index++) {
      if (PageRegistry.entries[index].name === name) {
        return PageRegistry.entries[index];
      }
    }
    return null;
  }

  static isDetail(name: string): boolean {
    const meta: PageMeta | null = PageRegistry.of(name);
    return meta !== null && meta.detail;
  }

  static isOverlay(name: string): boolean {
    const meta: PageMeta | null = PageRegistry.of(name);
    return meta !== null && meta.overlay;
  }
}
