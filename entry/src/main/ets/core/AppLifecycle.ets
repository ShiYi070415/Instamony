/*
 * 应用前后台信号的中转。
 *
 * UIAbility 只能拿到 ability 级生命周期（onForeground / onBackground），拿不到页面里
 * 那个 WebView 控制器；Web 宿主组件又只能拿到组件级生命周期，不知道整个应用是否进了
 * 后台。这里做一个最小中转：能力层负责 emit，Web 宿主组件负责注册处理函数。
 *
 * 只做一件事，所以不引入 EventHub / AppStorage：那两者都要 context 或 UI 上下文，
 * 而这个信号在冷启动早期（Web 组件还没建立）就可能到达，纯静态类最稳。
 */

/** 前后台变化处理函数；foreground 为 true 表示回到前台。 */
export type VisibilityHandler = (foreground: boolean) => void;

export class AppLifecycle {
  private static handler: VisibilityHandler = (foreground: boolean): void => {
  };
  private static registered: boolean = false;
  /**
   * **额外的监听者**（除了 Web 宿主那个主处理器）。
   *
   * 为什么单开一个数组：主处理器是"单槽"的（见 onVisibilityChanged），直接再加一个订阅会把它
   * 顶掉、让 Web 宿主的暂停/恢复失效。这里让别的模块（私信页的前台刷新，见 DirectPage）
   * 追加进来，互不影响。
   */
  private static extra: Array<VisibilityHandler> = [];

  /** 由 Web 宿主组件在 aboutToAppear 时注册。 */
  static onVisibilityChanged(handler: VisibilityHandler): void {
    AppLifecycle.handler = handler;
    AppLifecycle.registered = true;
  }

  /** 追加一个监听者（幂等：同一个函数只加一次）。 */
  static addVisibilityListener(handler: VisibilityHandler): void {
    if (AppLifecycle.extra.indexOf(handler) >= 0) {
      return;
    }
    AppLifecycle.extra.push(handler);
  }

  /** 是否已有组件接管；没有时能力层不必通知（避免冷启动早期空转）。 */
  static isRegistered(): boolean {
    return AppLifecycle.registered;
  }

  static notifyForeground(): void {
    AppLifecycle.handler(true);
    for (let index: number = 0; index < AppLifecycle.extra.length; index++) {
      AppLifecycle.extra[index](true);
    }
  }

  static notifyBackground(): void {
    AppLifecycle.handler(false);
    for (let index: number = 0; index < AppLifecycle.extra.length; index++) {
      AppLifecycle.extra[index](false);
    }
  }
}
