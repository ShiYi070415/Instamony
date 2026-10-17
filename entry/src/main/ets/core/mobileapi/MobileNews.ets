/*
 * 通知页的**移动端私有 API**（instagrapi 协议）—— 对应 `UserMixin.news_inbox` /
 * `discover_ayml` 与 `friendships/show_many`。
 *
 * ## 为什么要有这一层
 * 原来通知页走的是 `core/NativeNotifications`：`www.instagram.com/api/v1/news/inbox/`
 * + `discover/ayml/` + `friendships/show_many/`，**用网页身份**（模板里那份 Cookie /
 * csrf / `x-ig-www-claim`）。这条路有两个毛病：
 *   1. 「为你推荐」那条 ayml 要网页专有令牌（`x-ig-www-claim` / `fb_dtsg` / `jazoest`），
 *      拿不到就得**先把隐藏网页导航到活动页抓一次模板**（秒级，用户看到的是"一直在刷新"）；
 *   2. 网页身份的指纹（Cookie 集合 / UA / 头顺序）和本项目其它端口（快拍、私信、主页、
 *      点赞、翻译…）用的**移动端身份**不是一套，而 IG 恰恰会因为这种"半网页半 App"露馅
 *      （见 FINGERPRINT_ANALYSIS.md）。
 * 换成移动端私有 REST 之后，这三个端点和别的端口共用同一套身份与限速闸门，
 * 既不需要任何模板，也不需要网页令牌。
 *
 * ## 三条端点
 *   · 通知主列表  `POST news/inbox/`         （表单：会话公共字段）
 *   · 推荐位      `POST discover/ayml/`      （表单：会话公共字段）
 *   · 关注状态    `POST friendships/show_many/`（表单：`user_ids=1,2,3`）
 *
 * ## 签名
 * `news/inbox/` 与 `discover/ayml/` 先按**签名**表单发（instagrapi 的 `private_request`
 * 默认带 `signed_body`）；万一这一版服务端只认不签名表单（`clips/user/` 就踩过），
 * 再退回**不签名**发一次。两条路都失败才算失败，日志里会写明是哪一条。
 *
 * 解析不在这一层：形状与网页那条基本一样（`new_stories` / `old_stories` / `ayml` /
 * `friendship_statuses`），统一交给 `core/NativeNotifications` 现有的容错解析器，
 * 这样"移动端优先、网页兜底"两条路出来的条目**完全同构**，界面一个字都不用改。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileNews';

export class MobileNews {
  /**
   * 通知主列表（instagrapi 的 `news_inbox`）。
   *
   * 失败时**不抛异常**：调用方（NativeNotifications）看到 `ok=false` 就退回网页那条路，
   * 页面行为不变（只是少了"移动端"这个优先项）。
   */
  static async inbox(priority: number = ApiThrottle.warm()): Promise<MobileResult> {
    return await MobileNews.write('news/inbox/', '', 'inbox', priority);
  }

  /**
   * 「为你推荐」（instagrapi 的 `discover_ayml`）。
   *
   * 真机上这条 **POST 会被拒**（`http=400 status:fail`，签名与不签名都一样），
   * 所以这里先 POST、再退 **GET + `timezone_offset` 查询参数** ——
   * 它对方法比 `news/inbox/` 挑（后者两种方法都通）。
   * 两条都失败就只是没有推荐位，不影响通知主列表（见 NativeNotifications.fetchMobile）。
   */
  static async ayml(priority: number = ApiThrottle.idle()): Promise<MobileResult> {
    const posted: MobileResult = await MobileNews.write('discover/ayml/', '', 'ayml', priority);
    if (posted.ok) {
      return posted;
    }
    const offset: number = -new Date().getTimezoneOffset();
    const got: MobileResult = await MobileRequest.send('discover/ayml/', '',
      `timezone_offset=${offset}`, true, null, new MobileOptions(ApiThrottle.MOBILE, priority));
    if (got.ok) {
      hilog.info(DOMAIN, TAG, 'ayml ok via GET');
    } else {
      hilog.info(DOMAIN, TAG, 'ayml failed post=%{public}s get=%{public}s',
        posted.summary(), got.summary());
    }
    return got;
  }

  /**
   * 批量问关注状态（instagrapi 的 `friendships/show_many`，移动端同样是 REST）。
   *
   * 响应 `{"status":"ok","friendship_statuses":{"<id>":{"following":true,…}}}`。
   */
  static async showMany(ids: Array<string>,
                        priority: number = ApiThrottle.warm()): Promise<MobileResult> {
    const wanted: Array<string> = [];
    for (let index: number = 0; index < ids.length; index++) {
      const one: string = (ids[index] ?? '').trim();
      if (one.length > 0 && wanted.indexOf(one) < 0) {
        wanted.push(one);
      }
    }
    if (wanted.length === 0) {
      return new MobileResult(false, 'no-ids', 0, 0, 0, '', 'no-ids');
    }
    return await MobileNews.write('friendships/show_many/', `user_ids=${encodeURIComponent(wanted.join(','))}`,
      'show_many', priority);
  }

  // ------------------------------------------------------------------ 内部

  /**
   * 发一发（会话公共字段 + 业务字段），**签名优先、不签名兜底**（见文件头）。
   *
   * 只在这一层做一次重试：两次都失败就如实返回最后一次的结果，不再拖长（限速闸门那边
   * 已经把"同一时刻只发一发"管住了）。
   */
  private static async write(endpoint: string, extra: string, label: string,
                             priority: number): Promise<MobileResult> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || !identity.isComplete()) {
      hilog.info(DOMAIN, TAG, '%{public}s skipped: no session', label);
      return new MobileResult(false, 'no-session', 0, 0, 0, '', 'no-usable-session');
    }
    /*
     * 设备/会话字段（`_uid` / `_uuid` / `_csrftoken` / `device_id` / `guid` / `phone_id` …）：
     * 官方 App 每一发都带。业务字段接在后面。
     */
    const base: string = MobileRequest.formOf(MobileRequest.withExtraData(identity));
    const payload: string = extra.length > 0 ? `${base}&${extra}` : base;
    const opts: MobileOptions = new MobileOptions(ApiThrottle.MOBILE, priority);
    let result: MobileResult = await MobileRequest.send(endpoint, payload, '', true, null, opts);
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, '%{public}s signed failed (%{public}s) → unsigned',
        label, result.summary());
      const unsigned: MobileResult = await MobileRequest.send(endpoint, payload, '', false, null, opts);
      if (unsigned.ok) {
        hilog.info(DOMAIN, TAG, '%{public}s ok via unsigned %{public}s', label, unsigned.summary());
      } else {
        hilog.warn(DOMAIN, TAG, '%{public}s failed signed=%{public}s unsigned=%{public}s body=%{public}s',
          label, result.summary(), unsigned.summary(), unsigned.body.substring(0, 200));
      }
      result = unsigned;
    }
    return result;
  }
}
