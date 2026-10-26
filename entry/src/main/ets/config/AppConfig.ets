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

import { DeviceTruth } from '../core/mobileapi/DeviceTruth';
import { DeviceProfile } from '../core/mobileapi/MobileConfig';

export class AppConfig {
  static readonly INSTAGRAM_HOME_URL: string = 'https://www.instagram.com/';
  static readonly INSTAGRAM_LOGIN_URL: string = 'https://www.instagram.com/accounts/login/';
  /**
   * 注册页（登录页那颗「注册账号」按钮跳这里）。
   *
   * 走 IG 自己的网页注册流程：全程在隐藏网页里做，本 App 不收任何邮箱 / 密码。
   * 注册完成后点网页 chrome 上的「关闭」就回到登录页（见 pages/Index.closeWeb）；
   * 已经注册并自动登录的，会话检测会直接把 App 接进去。
   */
  static readonly INSTAGRAM_SIGNUP_URL: string = 'https://www.instagram.com/accounts/emailsignup/';
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
   * 网页身份（UA）：**这台机器自己的型号**，不再是写死的 Pixel 8。
   *
   * 为什么必须改：这个 UA 是 WebView（以及跟着它走的网页登录请求）的唯一身份，
   * IG 的「登录设备 / 新登录邮件」就是拿它解析出来的 —— 写死 Pixel 8 的后果是
   * 一封封邮件都在说"你的 Google Pixel 8 登录了"，跟手里这台机器毫无关系，
   * 而且"美国机型 + 中文 + 国内 IP"本身就是最廉价的风控判据（见 DeviceTruth 的头注释）。
   *
   * 取值全部来自「DeviceTruth」（读一次缓存一生）：型号 = 系统里的型号名称
   * （marketName 优先，退化到 productModel），Android 版本按品牌给一个固定值。
   * 于是 UA 和人设（语言/时区/IP）、以及私有 API 那条身份的型号**是同一份**。
   *
   * 为什么是方法不是常量：常量在类加载时就定了，那时设备信息还没读；而且全局只该有
   * 一份型号来源，写成方法等于把"唯一来源"这件事落到代码结构上。
   */
  static webUserAgent(): string {
    const device: DeviceProfile = DeviceTruth.profile();
    // 型号用 `DeviceTruth.webModel()`（机型代号，不含空格），理由见它的注释 —— 这一栏
    // 换成带空格的系统型号名会被 IG 归并成"品牌 + 系列"甚至直接不显示。
    return `Mozilla/5.0 (Linux; Android ${device.androidRelease}; ${DeviceTruth.webModel()}) `
      + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
  }

  /**
   * **系统市场名**（如 `HUAWEI Mate 80`）：给 UA Client Hints 用（见 InstagramWebHost 的补丁）。
   *
   * 和 `webUserAgent()` 里那个型号**故意不是一个值**：
   *   · UA 里的型号必须是"无空格机型 token"，否则 IG 的解析会截断/丢弃（实测两次）；
   *   · Client Hints 的 `model` 是 JSON 字符串，允许带空格和品牌 —— 官方客户端显示的
   *     `Huawei Mate 80` 就是从这里来的。
   */
  static deviceModelName(): string {
    return DeviceTruth.profile().model;
  }
}
