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
  /**
   * 现在是不是前台。
   *
   * 谁用：`VideoSurface` —— 它要在切后台时**把解码器还回去**（以前完全不看前后台，
   * 于是 App 退到桌面之后视频还在解码，真机实测后台仍吃 69% CPU、手机发烫）。
   */
  private static foregroundNow: boolean = true;

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

  /**
   * 撤掉一个监听者（组件销毁时调）。
   *
   * 为什么必须有它：`VideoSurface` 也要跟着前后台停/起（见那里的说明），而它在列表里
   * 随滚动反复创建销毁 —— 只加不减的话监听数组会无限长大，每次前后台切换都要跑几百个
   * 已销毁组件留下的闭包，本身就成了新的耗电源。
   */
  static removeVisibilityListener(handler: VisibilityHandler): void {
    const at: number = AppLifecycle.extra.indexOf(handler);
    if (at >= 0) {
      AppLifecycle.extra.splice(at, 1);
    }
  }

  /** 现在是不是前台（新注册的监听者用它对齐初始状态）。 */
  static isForeground(): boolean {
    return AppLifecycle.foregroundNow;
  }

  /** 是否已有组件接管；没有时能力层不必通知（避免冷启动早期空转）。 */
  static isRegistered(): boolean {
    return AppLifecycle.registered;
  }

  static notifyForeground(): void {
    AppLifecycle.foregroundNow = true;
    AppLifecycle.handler(true);
    for (let index: number = 0; index < AppLifecycle.extra.length; index++) {
      AppLifecycle.extra[index](true);
    }
  }

  static notifyBackground(): void {
    AppLifecycle.foregroundNow = false;
    AppLifecycle.handler(false);
    for (let index: number = 0; index < AppLifecycle.extra.length; index++) {
      AppLifecycle.extra[index](false);
    }
  }
}
