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

  /** 由 Web 宿主组件在 aboutToAppear 时注册。 */
  static onVisibilityChanged(handler: VisibilityHandler): void {
    AppLifecycle.handler = handler;
    AppLifecycle.registered = true;
  }

  /** 是否已有组件接管；没有时能力层不必通知（避免冷启动早期空转）。 */
  static isRegistered(): boolean {
    return AppLifecycle.registered;
  }

  static notifyForeground(): void {
    AppLifecycle.handler(true);
  }

  static notifyBackground(): void {
    AppLifecycle.handler(false);
  }
}
