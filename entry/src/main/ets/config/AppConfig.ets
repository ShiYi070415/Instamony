/*
 * 集中配置。
 *
 * Instarmony 的取数路径是「常驻 WebView + 复用网页自身会话」，所以这里只剩
 * 网页地址与 WebView 的身份标识。
 *
 * 原先的 APP_ID / APP_VERSION / LOCALE / GRAPH_BASE_URL / MEDIA_FIELDS 以及
 * clientProfile() / oauthProfile() / credentialProfile() / feedQuery() 四个工厂方法，
 * 属于未接线的 OAuth + Graph API 分层，**已从仓库移除**（那套路线已被
 * `core/mobileapi/` 的私有 API 取代），没有任何运行路径引用它们。
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
   * 某个用户的**快拍页**（`/stories/<用户名>/`，页面自己会跳到第一条 media）。
   *
   * 为什么要它：`/api/v1/feed/reels_media/` 那条私有 REST 在部分会话上被 IG 直接回 **500**
   * （用户回传的诊断文件：头与 cookie 都齐、claim/instagram-ajax 都在，仍然 500；
   * 同一账号用安卓身份还回 `challenge_required`）。而**网页那条路是通的**——托盘数据就是
   * 从网页抓的 `PolarisStoriesV3TrayContainerQuery`。所以取不到时改成"让网页打开一次这个人的
   * 快拍页，把它自己发的那条查询抓下来、之后原生照着回放"（和私信/搜索/个人页同一套路）。
   */
  static instagramStoriesUrl(username: string): string {
    return `https://www.instagram.com/stories/${encodeURIComponent(username)}/`;
  }
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
