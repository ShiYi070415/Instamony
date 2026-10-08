/*
 * 集中配置。
 *
 * Instarmony 的取数路径是「常驻 WebView + 复用网页自身会话」，所以这里只剩
 * 网页地址与 WebView 的身份标识。
 *
 * 原先的 APP_ID / APP_VERSION / LOCALE / GRAPH_BASE_URL / MEDIA_FIELDS 以及
 * clientProfile() / oauthProfile() / credentialProfile() / feedQuery() 四个工厂方法，
 * 属于未接线的 OAuth + Graph API 分层，已随该分层一起归档到 legacy/unwired/，
 * 且没有任何运行路径调用它们。重新接线时请照 legacy/unwired/README.md 补回。
 */

export class AppConfig {
  static readonly INSTAGRAM_HOME_URL: string = 'https://www.instagram.com/';
  static readonly INSTAGRAM_LOGIN_URL: string = 'https://www.instagram.com/accounts/login/';
  static readonly INSTAGRAM_SEARCH_URL: string = 'https://www.instagram.com/explore/search/';
  /**
   * 短视频流（Reels）。
   *
   * 搜索页的**推荐帖子**就是从这里来的：搜索页空态只回最近搜索（`xig_recent_searches`），
   * 而探索页 `/explore/` 实测要么服务端直出（一个请求都不发）、要么直接跳到
   * `/explore/search/` —— 只有这条短视频流既有可抓的模板、也能原生 HTTP 重放。
   * 详见 core/NativeSearch 的 CLIPS_HINTS。
   */
  static readonly INSTAGRAM_REELS_URL: string = 'https://www.instagram.com/reels/';
  /** 私信（Direct 收件箱）。 */
  static readonly INSTAGRAM_DIRECT_URL: string = 'https://www.instagram.com/direct/inbox/';
  /** 通知（活动页）：标题栏那颗爱心按钮要跳的地方。 */
  static readonly INSTAGRAM_ACTIVITY_URL: string = 'https://www.instagram.com/accounts/activity/';
  /**
   * 发布入口（网页版自己的发布器）。
   *
   * 原生不做上传：选图/选视频、压缩、发布全在 IG 的网页发布器里。发布页
   * （见 pages/CreatePost.ets）接上传那一步时会用到它：把常驻网页导航过去、再把网页揭出来。
   * 目前还没有调用方 —— 发布页只是页面骨架。
   */
  static readonly INSTAGRAM_CREATE_URL: string = 'https://www.instagram.com/create/select/';
  /**
   * Ordinary mobile browser identity. The WebView is loading Instagram's own
   * public web client, so it should look like a browser rather than claim to be
   * an official Instagram application.
   */
  static readonly WEB_USER_AGENT: string =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    + '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
}
