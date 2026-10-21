/*
 * 「收藏 / 取消收藏」一条媒体（IG 的 Save，落到账号的收藏夹里）。
 *
 * ## 端点：**移动端私有接口**（instagrapi 的 `media_save` / `media_unsave`）
 *   POST i.instagram.com/api/v1/media/{pk}/save/    收藏
 *   POST i.instagram.com/api/v1/media/{pk}/unsave/  取消收藏
 * 成功响应形如 `{"status":"ok"}`。
 *
 * 请求由 core/mobileapi/MobileEngage 统一发出（App 身份 + `_uuid` / `_csrftoken` /
 * `device_id` / 签名体），**不需要网页模板，也不需要 fb_dtsg / x-ig-www-claim**。
 *
 * ## 历史
 * 这里原来还有两条兜底：
 *   · 回放探针抓到的收藏模板（模板里那份会话令牌早就过期，回 `200 + errors` 被当成成功）；
 *   · `www.instagram.com` 网页主机 + REST 会话头（实测这条路**根本不存在**：
 *     404 + 一整页 `not-logged-in` 的 HTML）。
 * 页面注入退役之后两条都删了 —— 现在只有移动端这一条，失败就如实回报。
 *
 * ## 媒体 id
 * 调用方给的 id 常常不完整（个人页那几个分页会给 `profile-<code>` 占位串、
 * 或者超过 f64 精度变成指数形式），所以第一步是 `MobileEngage.mediaIdOf`：
 * 纯数字 pk 直接用，否则拿短码去 oembed 换一次真 pk。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from './ApiThrottle';
import { MobileEngage } from './mobileapi/MobileEngage';
import { MobileRequest } from './mobileapi/MobileRequest';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeSave';

/** 结果（`saved` 是**请求的目标状态**，失败时调用方据此回滚界面）。 */
export class SaveResult {
  readonly ok: boolean;
  readonly saved: boolean;
  readonly detail: string;

  constructor(ok: boolean, saved: boolean, detail: string) {
    this.ok = ok;
    this.saved = saved;
    this.detail = detail;
  }
}

export class NativeSave {
  /** 上一次走通的是哪条路（诊断：`mobile:save` / `mobile:unsave`）。 */
  private static via: string = '-';

  static lastVia(): string {
    return NativeSave.via;
  }

  /**
   * 收藏 / 取消收藏。
   *
   * @param mediaId 媒体数字 id（`Reel.mediaId` / `MediaPost.id` 的那一段数字）。
   * @param save    true = 收藏，false = 取消收藏。
   * @param shortcode 这条的短码（**个人页那几个分页必须给**：那些载荷里的 id 常常是
   *                占位串 / 丢精度的 number / 干脆缺失，只有短码一定在 ——
   *                见 MobileEngage.mediaIdOf）。
   */
  static async setSaved(mediaId: string, save: boolean, shortcode: string = ''): Promise<SaveResult> {
    const action: string = save ? 'save' : 'unsave';
    // 冷却期内不发（见 core/ApiThrottle）：写接口被限流时再打只会把窗口拉长。
    const cooled: string = NativeSave.cooling();
    if (cooled.length > 0) {
      hilog.info(DOMAIN, TAG, 'setSaved skipped: save family throttled %{public}dmin left',
        ApiThrottle.remainingMinutes(ApiThrottle.SAVE));
      return new SaveResult(false, save, cooled);
    }
    // ① 先把 id 换成一个真 pk（拿不到就如实失败，绝不拿别人的 id 去发）。
    let resolved: string = '';
    try {
      resolved = await MobileEngage.mediaIdOf(mediaId, shortcode);
    } catch (error) {
      resolved = '';
    }
    if (resolved.length === 0) {
      hilog.info(DOMAIN, TAG, 'setSaved no media id raw=%{public}s code=%{public}s',
        mediaId.substring(0, 24), shortcode);
      return new SaveResult(false, save, 'no-media-id');
    }
    // ② 发（人速间隔见 core/ApiThrottle.writeSlot：几次连点不会挤在一秒里）。
    await ApiThrottle.writeSlot();
    let ok: boolean = false;
    try {
      ok = await MobileEngage.setSaved(resolved, save);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setSaved threw: %{public}s', (error as Error).message);
      ok = false;
    }
    NativeSave.via = `mobile:${action}`;
    if (!ok) {
      const detail: string = MobileRequest.detail().length > 0
        ? MobileRequest.detail() : 'mobile-failed';
      hilog.info(DOMAIN, TAG, 'setSaved failed id=%{public}s save=%{public}s detail=%{public}s',
        resolved, `${save}`, detail);
      return new SaveResult(false, save, detail);
    }
    hilog.info(DOMAIN, TAG, 'setSaved ok id=%{public}s save=%{public}s', resolved, `${save}`);
    return new SaveResult(true, save, '');
  }

  /** 这个家族还在限流冷却里吗（见 core/ApiThrottle）。空串 = 可以发。 */
  private static cooling(): string {
    if (!ApiThrottle.blocked(ApiThrottle.SAVE)) {
      return '';
    }
    return `throttled-${ApiThrottle.remainingMinutes(ApiThrottle.SAVE)}min`;
  }
}
