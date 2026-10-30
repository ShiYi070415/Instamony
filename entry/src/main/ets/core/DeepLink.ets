/*
 * Instamony 深链（deep link）核心。
 *
 * ## 为什么要有它
 * 需求/课程目标：让"外部世界"（系统浏览器、其他 App、二维码、分享链接）能直接进到本 App 的
 * 某个界面，而不是只能从桌面图标冷启到首页。这是 HarmonyOS **Stage 模型的标准能力**：
 *   1. module.json5 里给 ability 声明 skills.uris（scheme/host）；
 *   2. 系统把命中的 URI 通过 Want 送给 EntryAbility（冷启走 onCreate、热启走 onNewWant）；
 *   3. 本 App 从 want.uri 里解析出"要去哪"，转成内部动作。
 *
 * 这一条链路的意义在于：**URI 是一段跨进程的 RPC 载荷**，而 App 侧把它当成普通函数参数用。
 *
 * ## 支持的形态
 *   instarmony://open?route=home
 *   instarmony://open?route=reels
 *   instarmony://open?route=search
 *   instarmony://open?route=direct
 *   instarmony://open?route=profile&id=<username>
 *   instarmony://open?route=post&id=<shortcode>
 * 也接受把 route 直接写在 host 上的简写（instarmony://reels）。
 *
 * ## 两条落地路径（都写在这里，调用方不必关心）
 *   · 冷启动：EntryAbility.onWindowStageCreate 先把 pages/DeepLink 铺出来（可见地"拆开"这个链接），
 *     用户点"打开"再进 pages/Index —— 这样答辩时能一眼看到 Want 真的到了原生侧。
 *   · 热启动：App 已经在 Index 上，intent 存进 pending，由 Index 的 onForeground 取走执行。
 *
 * 任何一步失败都只是"这次链接没用"，绝不抛异常。
 */

/** 深链的 scheme 与 host：**必须**和 module.json5 里 skills.uris 保持一致。 */
const DEEPLINK_SCHEME: string = 'instarmony';
const DEEPLINK_HOST: string = 'open';
/** 完整前缀，用来快速判断一个 Want.uri 是不是我们的深链。 */
export const DEEPLINK_PREFIX: string = `${DEEPLINK_SCHEME}://${DEEPLINK_HOST}`;

/** 可深链的目标。 */
export enum DeepLinkRoute {
  Home = 'home',
  Reels = 'reels',
  Search = 'search',
  Direct = 'direct',
  Profile = 'profile',
  Post = 'post'
}

/** 解析结果（不可变）。 */
export class DeepLinkIntent {
  readonly route: string;
  readonly id: string;
  readonly raw: string;
  /**
   * `from` 参数（`instarmony://open?...&from=notify`）。
   *
   * 用它把"**本 App 自己发的通知点击**"和"外部 App/浏览器的深链"分开：
   * 前者要直接进会话（不经过落地页），后者仍按课程要求先铺 pages/LinkIn。
   */
  readonly from: string;

  constructor(route: string, id: string, raw: string, from: string = '') {
    this.route = route;
    this.id = id;
    this.raw = raw;
    this.from = from;
  }

  /** 这是不是"点通知"带来的意图（见 from）。 */
  isFromNotify(): boolean {
    return this.from === 'notify';
  }

  /** 这个链接是不是一个"认识"的目标（不认识就只提示、不乱跳）。 */
  isKnown(): boolean {
    const all: Array<string> = [
      DeepLinkRoute.Home, DeepLinkRoute.Reels, DeepLinkRoute.Search,
      DeepLinkRoute.Direct, DeepLinkRoute.Profile, DeepLinkRoute.Post
    ];
    return all.indexOf(this.route) >= 0;
  }

  /** route=profile / post 时 id 是必填的（用户名 / shortcode）。 */
  isComplete(): boolean {
    if (this.route === DeepLinkRoute.Profile || this.route === DeepLinkRoute.Post) {
      return this.id.length > 0;
    }
    return this.isKnown();
  }

  /** 给日志和 UI 用的一行摘要，例如 `profile → nasa`。 */
  describe(): string {
    return this.id.length > 0 ? `${this.route} → ${this.id}` : this.route;
  }
}

export class DeepLink {
  /**
   * 热启动待执行的 intent。
   *
   * 为什么需要"待"：onNewWant 到 Index 的 onForeground 之间隔着系统的一次前后台切换，
   * 那时页面还没准备好接收动作；先存下来、等页面来取，比在 ability 里硬推页面稳。
   */
  private static pending: DeepLinkIntent | null = null;

  /**
   * 从 Want.uri 解析。不是我们的深链（或空串）返回 null。
   *
   * 只看前缀就够：scheme+host 已在 module.json5 里由系统做过精确匹配。
   */
  static parse(uri: string): DeepLinkIntent | null {
    const text: string = (uri ?? '').trim();
    if (text.length === 0) {
      return null;
    }
    const lower: string = text.toLowerCase();
    if (lower.indexOf(`${DEEPLINK_SCHEME}://`) !== 0) {
      return null;
    }
    // host 和 query 都可能是 route 的来源：instarmony://reels 与 instarmony://open?route=reels 等价。
    const afterScheme: string = text.substring(`${DEEPLINK_SCHEME}://`.length);
    const queryStart: number = afterScheme.indexOf('?');
    const host: string = (queryStart >= 0 ? afterScheme.substring(0, queryStart) : afterScheme).trim();
    const query: string = queryStart >= 0 ? afterScheme.substring(queryStart + 1) : '';

    let route: string = DeepLink.paramOf(query, 'route').toLowerCase();
    if (route.length === 0 && host.length > 0 && host.toLowerCase() !== DEEPLINK_HOST) {
      // 简写形态：host 本身就是路由（instarmony://profile?id=nasa）。
      route = host.toLowerCase();
    }
    if (route.length === 0) {
      route = DeepLinkRoute.Home;
    }
    const id: string = DeepLink.paramOf(query, 'id');
    return new DeepLinkIntent(route, id, text, DeepLink.paramOf(query, 'from'));
  }

  /** 存下待执行的 intent（热启动路径）。 */
  static stash(intent: DeepLinkIntent | null): void {
    DeepLink.pending = intent;
  }

  /**
   * 取走待执行的 intent（取一次就清）。
   *
   * "取走即清"是关键：不然用户手动返回首页时会被同一条链接反复拽走。
   */
  static take(): DeepLinkIntent | null {
    const one: DeepLinkIntent | null = DeepLink.pending;
    DeepLink.pending = null;
    return one;
  }

  /** 现在有没有等着执行的链接（UI 判断用，不清）。 */
  static hasPending(): boolean {
    return DeepLink.pending !== null;
  }

  /**
   * 把 intent 翻成 Instagram 网页地址（route=post 用得到）。
   *
   * 为什么帖子只能走网页：`openPostStream`（Index）要的是一整份分页列表 + 翻页回调，
   * 而一个深链只有 shortcode，凑不出那份上下文。让隐藏网页导航到该帖页面是现成的、
   * 行为正确的一条路（见 Index 的 openWeb / navigateToPost）。
   */
  static toInstagramUrl(intent: DeepLinkIntent): string {
    switch (intent.route) {
      case DeepLinkRoute.Reels:
        return 'https://www.instagram.com/reels/';
      case DeepLinkRoute.Search:
        return 'https://www.instagram.com/explore/';
      case DeepLinkRoute.Direct:
        return 'https://www.instagram.com/direct/inbox/';
      case DeepLinkRoute.Profile:
        return `https://www.instagram.com/${encodeURIComponent(intent.id)}/`;
      case DeepLinkRoute.Post:
        return `https://www.instagram.com/p/${encodeURIComponent(intent.id)}/`;
      default:
        return 'https://www.instagram.com/';
    }
  }

  /**
   * 取 query 串里的一个参数（已解码）。
   *
   * 不用 URL 解析器：Want 送进来的 uri 不一定被百分号编码过（`route=profile&id=nasa` 就是原文），
   * 手拆 + 容错解码在所有设备上行为一致。
   */
  private static paramOf(query: string, name: string): string {
    if (query.length === 0) {
      return '';
    }
    const parts: Array<string> = query.split('&');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index];
      const eq: number = one.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      if (one.substring(0, eq) !== name) {
        continue;
      }
      const raw: string = one.substring(eq + 1);
      try {
        return decodeURIComponent(raw);
      } catch (error) {
        return raw;
      }
    }
    return '';
  }
}
