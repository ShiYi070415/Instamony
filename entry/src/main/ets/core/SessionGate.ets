/*
 * 登录闸门：**未登录时不许驱动共用网页**。
 *
 * 为什么要有它（用户报的现象）：退出登录后点「登录」，网页登录页反复刷新、用户名还被填成
 * "instagram"。真机日志（`web route` / `page begin`）里看到的是：未登录时隐藏网页被后台各种
 * "顺手导航一下"轮番推着走 —— `/` → `/reels/` → `/accounts/login/?next=…reels…` →
 * `/direct/inbox/` → `/accounts/login/?next=…direct…` → `/` …… 每几秒一轮。这些导航在
 * "原生信息流壳"上是看不见的（网页藏在 1% 透明度那一层），可一旦用户点登录把网页亮出来，
 * 屏幕上就是"登录页一直在刷新"；而 IG 的登录页会拿 `next` 里的路径去填用户名，
 * 于是又出现"用户名自动填成 instagram"。
 *
 * 判据只有一个：**登录态**。
 *   · 已登录：什么都不拦（原来怎么走还怎么走）；
 *   · 未登录：只放行 Instagram 自己的登录/验证那几条地址（`/accounts/…`、`/challenge`），
 *     其余一律丢掉并记一行日志 —— 没登录的时候，隐藏网页唯一该待的地方就是登录页。
 *
 * 默认值是**放行**：本闸门在 `Index.applySession` 里被显式设置之前不该改变任何既有行为
 * （启动那一小段里 Session 还没核对完，此时拦下来会让首屏白白读不到网页）。
 */

export class SessionGate {
  /** 现在是不是已登录。默认 true = 未核对前不拦（见文件头）。 */
  private static signedIn: boolean = true;

  static setSignedIn(value: boolean): void {
    SessionGate.signedIn = value;
  }

  static isSignedIn(): boolean {
    return SessionGate.signedIn;
  }

  /**
   * 这条地址在"未登录"状态下能不能加载。
   *
   * 放行的是 Instagram 的**登录流程本身**（登录页、注册、改密、二次验证、challenge）：
   * 用户点登录按钮、或退出登录后把网页归位，走的都是这几条，拦了就把登录路堵死了。
   */
  static allowsUnAuthenticated(url: string): boolean {
    const lower: string = url.toLowerCase();
    if (lower.indexOf('instagram.com') < 0) {
      return false;
    }
    return lower.indexOf('/accounts/') >= 0
      || lower.indexOf('/challenge') >= 0
      || lower.indexOf('/consent') >= 0;
  }

  /** 未登录时的统一判据：已登录 → 放行；未登录 → 只放行登录流程那几条。 */
  static allowsNavigation(url: string): boolean {
    if (SessionGate.signedIn) {
      return true;
    }
    return SessionGate.allowsUnAuthenticated(url);
  }
}
