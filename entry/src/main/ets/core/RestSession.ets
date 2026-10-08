/*
 * `/api/v1/…` 那套 **REST 调用**共用的会话材料：头 + 表单令牌。
 *
 * ## 为什么单独一个类
 * IG 的 REST（`friendships/create`、`media/{id}/info`…）和 GraphQL 那条路不一样：它不用
 * `doc_id`，鉴权全靠 **Cookie + csrf + `x-instagram-ajax`(rollout_hash)**，外加两个表单令牌
 * `fb_dtsg` / `jazoest`（后者是前者的校验和，必须成对、必须来自同一次页面会话）。
 * 这一套原来只写在 NativeFollow 里，现在 NativeMediaInfo 也要用同一套 —— 复制一份的话，
 * 以后"少一个头就回整页 HTML"这种坑要在两处各踩一次，所以提出来共用。
 *
 * ## 头从哪来
 *   1. 网页抓来的 REST 模板（操作名片段 `ayml`，见 ApiRegistry）里有网页自己刚用过的
 *      `x-ig-www-claim` / `x-instagram-ajax` / `asbd-id` 等等；
 *   2. 模板还没抓到就退回信息流的会话头（NativeFeed.sessionOrBrowserHeaders）；
 *   3. 最后补上 `/api/v1/` 那条路**必须有**的 `x-instagram-ajax`（= 页面里的 server_revision，
 *      与 `__rev` 同值）、`x-requested-with`、`accept` —— 少了它 IG 会把请求当成页面导航、
 *      回一整页 HTML（只看 HTTP 码就会把"其实没成功"报成成功）。
 */

import { NativeFeed } from './NativeFeed';
import { WebTokens } from './WebTokens';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';

/** 网页抓来的那条 REST 模板（ayml）的名字片段：claim / instagram-ajax 都在它身上。 */
const REST_TEMPLATE_OP: string = 'ayml';

export class RestSession {
  /** 抓到的 REST 模板（没抓到给 null）。表单令牌优先从它身上取。 */
  static template(): ApiTemplate | null {
    return ApiRegistry.getInstance().storedForNative(REST_TEMPLATE_OP);
  }

  /**
   * 发 `/api/v1/…` 要用的头（空 = 连会话都没有，调用方直接放弃）。
   */
  static async headers(): Promise<Record<string, string>> {
    let out: Record<string, string> = await NativeFeed.headersFor(REST_TEMPLATE_OP);
    if (Object.keys(out).length === 0) {
      // 模板还没抓到（或没登录）：退回信息流模板那套会话头，至少值得一试。
      out = await NativeFeed.sessionOrBrowserHeaders();
    }
    if (Object.keys(out).length === 0) {
      return out;
    }
    if ((out['x-instagram-ajax'] ?? '').length === 0) {
      try {
        // 已经读过一次就直接用缓存；没读过就现读（一次页面往返，几百毫秒）。
        await WebTokens.ensure(false);
      } catch (error) {
      }
      const rev: string = WebTokens.revValue();
      if (rev.length > 0) {
        out['x-instagram-ajax'] = rev;
      }
    }
    out['x-requested-with'] = out['x-requested-with'] ?? 'XMLHttpRequest';
    out['accept'] = out['accept'] ?? '*/*';
    return out;
  }

  /**
   * 表单令牌：`jazoest=…&fb_dtsg=…(&lsd=…)`（顺序保持原样）。
   *
   * 为什么不能自己编：`jazoest` 是 `fb_dtsg` 的校验和，两者必须来自同一次页面会话。
   * 模板里的那一对正好是网页自己刚用过的，服务端认；模板没有就现从页面读
   * （`fb_dtsg` / `lsd` 从页面读，`jazoest` 由 `fb_dtsg` 算出来，见 core/WebTokens）。
   */
  static async formTokens(tpl: ApiTemplate | null = RestSession.template()): Promise<string> {
    if (tpl !== null) {
      const parts: Array<string> = (tpl.body ?? '').split('&');
      const keep: Array<string> = [];
      for (let i: number = 0; i < parts.length; i++) {
        const one: string = parts[i];
        if (one.indexOf('fb_dtsg=') === 0 || one.indexOf('jazoest=') === 0
          || one.indexOf('lsd=') === 0) {
          keep.push(one);
        }
      }
      if (keep.length > 0) {
        return keep.join('&');
      }
    }
    try {
      await WebTokens.ensure(false);
    } catch (error) {
    }
    const fresh: Array<string> = [];
    if (WebTokens.dtsgValue().length > 0) {
      fresh.push(`fb_dtsg=${encodeURIComponent(WebTokens.dtsgValue())}`);
    }
    if (WebTokens.lsdValue().length > 0) {
      fresh.push(`lsd=${encodeURIComponent(WebTokens.lsdValue())}`);
    }
    if (WebTokens.dtsgValue().length > 0) {
      fresh.push(`jazoest=${WebTokens.jazoest()}`);
    }
    return fresh.join('&');
  }
}
