/*
 * **内置网页只允许去这些域**（合规 + 安全）。
 *
 * 为什么需要它：应用里有一个常驻的内嵌网页（Web 登录、以及"网页那条路"的兜底）。
 * 它**握着用户的 Instagram 会话 Cookie** —— 如果允许它导航到任意地址，等于把一个
 * 带着登录态的浏览器交给任何一条外链（站外链接卡片、页面里的跳转都可能把用户带到别处）。
 *
 * 更直接的原因：AppGallery 上架时会问一句
 *   "Does the app provide unrestricted Internet access, such as a built-in browser that
 *    can access any web page, web page access, or search engine?"
 * 只有把内置网页**限定在这几个域**，这一问才能如实回答 "No"：应用没有通用浏览器，
 * 站外链接一律交给**系统浏览器**（见 pages/Index 的 openExternal）。
 *
 * 允许列表按"根域后缀"匹配：`www.instagram.com`、`i.instagram.com`、
 * `scontent.cdninstagram.com`、媒体 CDN `*.fbcdn.net` 都算在内；
 * `facebook.com` 是登录/换号的中间跳转，必须留。
 */

const ALLOWED_SUFFIXES: Array<string> = [
  'instagram.com',
  'cdninstagram.com',
  'fbcdn.net',
  'facebook.com'
];

export class WebPolicy {
  /** 这条地址能不能在**内置网页**里打开（否 = 交给系统浏览器）。 */
  static isAllowed(raw: string): boolean {
    const url: string = (raw ?? '').trim();
    if (url.length === 0) {
      return false;
    }
    let host: string = '';
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd < 0) {
      // 没有协议的相对地址（about:blank、data:、blob: 这类）不进白名单判断：
      // 只有站内页面自己产生的相对跳转才会出现，放行更安全（它们本来就在同一文档里）。
      return url.indexOf('about:') === 0 || url.indexOf('data:') === 0
        || url.indexOf('blob:') === 0 || url.indexOf('javascript:') === 0;
    }
    const rest: string = url.substring(schemeEnd + 3);
    const slash: number = rest.indexOf('/');
    const authority: string = slash >= 0 ? rest.substring(0, slash) : rest;
    const at: number = authority.lastIndexOf('@');
    const hostPart: string = at >= 0 ? authority.substring(at + 1) : authority;
    const colon: number = hostPart.indexOf(':');
    host = (colon >= 0 ? hostPart.substring(0, colon) : hostPart).toLowerCase();
    if (host.length === 0) {
      return false;
    }
    for (let index: number = 0; index < ALLOWED_SUFFIXES.length; index++) {
      const suffix: string = ALLOWED_SUFFIXES[index];
      if (host === suffix || host.endsWith('.' + suffix)) {
        return true;
      }
    }
    return false;
  }
}
