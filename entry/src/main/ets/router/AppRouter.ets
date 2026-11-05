/*
 * **双 Pane 路由状态**：左栏主页面栈 + 右栏详情栈。
 *
 * 目标：页面代码不再自己比较 `tabletRightName` / 手动 clear 另一个栈；
 * 所有“进右栏 / 回单栏 / 切主页面”的规则收在这里。
 */

import { AppRoutes } from './AppRoutes';
import { PageRegistry } from './PageRegistry';

export class AppRouter {
  readonly leftStack: NavPathStack = new NavPathStack();
  readonly rightStack: NavPathStack = new NavPathStack();
  /** 当前主页面（0..4，对应 Home / Reels / Direct / Search / Profile）。 */
  primary: number = 0;

  /** 右栏现在有没有页面。 */
  hasRight(): boolean {
    return this.rightStack.size() > 0;
  }

  /** 右栏当前页面名。 */
  rightName(): string {
    const names: Array<string> = this.rightStack.getAllPathName();
    return names.length > 0 ? names[names.length - 1] : '';
  }

  /** 切主页面：清空右栏，保证不会把上一个 tab 的详情带过来。 */
  switchPrimary(index: number): void {
    this.primary = index;
    this.rightStack.clear();
  }

  /** 进详情：分栏进右栏，否则压左栏。 */
  pushDetail(name: string, param: string = '', split: boolean): void {
    if (split && PageRegistry.isDetail(name)) {
      this.rightStack.pushPath({ name: name, param: param });
      return;
    }
    this.leftStack.pushPath({ name: name, param: param });
  }

  /**
   * 右栏设置页的规则：
   * - 从一级页打开二级：右栏只保留这一层；
   * - 从二级打开三级：压栈。
   */
  pushSettingsDetail(section: string, nested: boolean, split: boolean): void {
    if (!split) {
      this.leftStack.pushPath({ name: AppRoutes.SETTINGS_DETAIL, param: section });
      return;
    }
    if (!nested) {
      this.rightStack.clear();
    }
    this.rightStack.pushPath({ name: AppRoutes.SETTINGS_DETAIL, param: section });
  }

  /** 返回：先右栏，再左栏。返回 true 表示已处理。 */
  back(): boolean {
    if (this.rightStack.size() > 0) {
      this.rightStack.pop(true);
      return true;
    }
    if (this.leftStack.size() > 0) {
      this.leftStack.pop(true);
      return true;
    }
    return false;
  }

  /** 清空两个栈（退出登录 / 换账号）。 */
  clear(): void {
    this.leftStack.clear();
    this.rightStack.clear();
  }
}
