/*
 * 关注 / 取关 + 批量问关注状态 —— **只走移动端私有接口**（instagrapi 同源）。
 *
 * ## 端点
 *   POST i.instagram.com/api/v1/friendships/create/{user_id}/
 *   POST i.instagram.com/api/v1/friendships/destroy/{user_id}/
 *   POST i.instagram.com/api/v1/friendships/show_many/   （表单 `user_ids=1,2,3`）
 * 响应形如 `{"status":"ok","friendship_status":{"following":true,…}}`，所以"到底成没成"
 * 以服务端回的 friendship_status.following 为准，不看我们自己发的是 create 还是 destroy
 * （IG 有时候对重复关注直接回 idempotent 成功）。
 *
 * 请求由 core/mobileapi 统一发出（App 身份 + 会话字段 + 签名），**不需要网页模板**。
 *
 * ## 历史
 * 这里原来还有两条基于网页会话的兜底（`www.instagram.com` + RestSession 头、
 * `friendships/show_many` 的 GET 版），它们都依赖探针抓来的模板里的 `fb_dtsg` /
 * `x-ig-www-claim` —— 页面注入退役之后那两份令牌抓不到也早已过期，一并删除。
 *
 * ## 返回什么
 * 失败一律不抛异常：`FollowResult.ok=false` + `detail` 由调用方决定是否退回"网页驱动"
 * （那条路是把隐藏网页导航到对方主页点它自己的按钮，与模板无关，仍保留在 pages/Index）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { MobileEngage } from './mobileapi/MobileEngage';
import { MobileNews } from './mobileapi/MobileNews';
import { MobileRequest, MobileResult } from './mobileapi/MobileRequest';
import { ApiThrottle } from './ApiThrottle';
import { JsonRead } from './JsonRead';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeFollow';

/** 关注请求的结果（不抛异常，失败用 ok=false + detail 表达）。 */
export class FollowResult {
  readonly ok: boolean;
  /** 服务端确认的最终状态（失败时原样回传入的期望值，调用方据此决定要不要回滚 UI）。 */
  readonly following: boolean;
  readonly detail: string;

  constructor(ok: boolean, following: boolean, detail: string) {
    this.ok = ok;
    this.following = following;
    this.detail = detail;
  }
}

export class NativeFollow {
  /**
   * 关注 / 取关。
   *
   * @param userId 作者的用户 id（信息流里解析出来的 `user.pk`）。
   * @param follow true = 关注，false = 取关。
   */
  static async setFollowing(userId: string, follow: boolean): Promise<FollowResult> {
    const id: string = userId.trim();
    if (id.length === 0) {
      return new FollowResult(false, follow, 'no-user-id');
    }
    // 关注/取关也是**写**：走人速间隔，别让几次点击挤在一秒里（见 ApiThrottle.writeSlot）。
    await ApiThrottle.writeSlot();
    let ok: boolean = false;
    try {
      ok = await MobileEngage.setFollowing(id, follow);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'follow threw: %{public}s', (error as Error).message);
      ok = false;
    }
    hilog.info(DOMAIN, TAG, 'follow action=%{public}s id=%{public}s ok=%{public}s detail=%{public}s',
      follow ? 'create' : 'destroy', id, ok ? 'y' : 'n', MobileRequest.detail());
    if (!ok) {
      const detail: string = MobileRequest.detail().length > 0
        ? MobileRequest.detail() : 'mobile-failed';
      return new FollowResult(false, follow, detail);
    }
    /*
     * 成功时状态以**意图值**为准：移动端这条写接口的响应体里也会带
     * `friendship_status.following`，但私密账号可能出现"请求成功、following 仍为 false"，
     * 那种情况由调用方按 `following` 与 `ok` 的组合处理（见 pages/Index.followUser）。
     */
    return new FollowResult(true, follow, 'mobile');
  }

  /**
   * **批量问一批用户的关注状态**（`friendships/show_many`）。
   *
   * 为什么要它：Reels 页那颗关注按钮的状态来自数据源（clips / 推荐流那条载荷里的
   * `user.friendship_status.following`），但**有的载荷没这个字段** —— 那就只能问一次。
   * 这个端点一次能问一批人（`user_ids=1,2,3`）。
   *
   * @returns id → following 的表（问不到的人不在表里）。
   */
  static async statesFor(ids: Array<string>): Promise<Map<string, boolean>> {
    const out: Map<string, boolean> = new Map<string, boolean>();
    const wanted: Array<string> = [];
    for (let index: number = 0; index < ids.length; index++) {
      const one: string = ids[index].trim();
      if (one.length > 0 && wanted.indexOf(one) < 0) {
        wanted.push(one);
      }
    }
    if (wanted.length === 0) {
      return out;
    }
    let result: MobileResult;
    try {
      result = await MobileNews.showMany(wanted, ApiThrottle.interactive());
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'show_many threw: %{public}s', (error as Error).message);
      return out;
    }
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'show_many failed ids=%{public}d (%{public}s)',
        wanted.length, result.summary());
      return out;
    }
    const dto: Record<string, Object> = JsonRead.parse(result.body);
    const statuses: Record<string, Object> | null = JsonRead.recordOf(dto, 'friendship_statuses');
    if (statuses === null) {
      hilog.info(DOMAIN, TAG, 'show_many no statuses len=%{public}d', result.body.length);
      return out;
    }
    for (let index: number = 0; index < wanted.length; index++) {
      const one: Record<string, Object> | null = JsonRead.recordOf(statuses, wanted[index]);
      if (one === null) {
        continue;
      }
      out.set(wanted[index], JsonRead.boolOf(one, 'following'));
    }
    hilog.info(DOMAIN, TAG, 'show_many asked=%{public}d got=%{public}d',
      wanted.length, out.size);
    return out;
  }
}
