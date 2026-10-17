/*
 * 移动 API 的**互动**端点（点赞 / 取消点赞；对应 instagrapi 的 `media_like` / `media_unlike`）。
 *
 * ## 为什么要有它
 * 点赞原来走的是 `NativeEngage` 的**网页模板回放**（`LikeMediaXIG`）—— 模板里的 `doc_id` /
 * `variables` / `x-ig-www-claim` 会随网页重载而失效。真机现象（用户报，已在模拟器复现）：
 * 界面变红、但退出重进又是未点赞 —— 服务端根本没收到。回放那几条路还会回
 * "HTTP 200 但体内带 errors"，被当成成功，于是更难发现。
 *
 * instagrapi 的点赞只是一发私有 REST，**不需要任何模板**，和本项目已经跑通的快拍 / 私信 /
 * 主页走的是同一套身份（见 core/mobileapi/MobileRequest 的文件头）：
 *
 *   POST /api/v1/media/{media_id}/like/      （点赞）
 *   POST /api/v1/media/{media_id}/unlike/    （取消）
 *   表单：media_id=<pk> + _uid / _uuid / _csrftoken / device_id / guid / phone_id
 *
 * 成功判据：HTTP 200、体内 `status` 不是 fail、且没有 `errors`。与 `MobileRequest.classify`
 * 的语义一致（它已经把这几类失败分出来了）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileEngage';

export class MobileEngage {
  /**
   * 点赞 / 取消点赞（媒体 id 必须是**纯数字的 pk**）。
   *
   * @returns 成功（服务端已接受这次变更）返回 true；任何不确定的情况都返回 false，
   *          让调用方回滚界面并如实提示 —— 绝不假装成功。
   */
  static async setLiked(mediaId: string, like: boolean,
                        priority: number = ApiThrottle.interactive()): Promise<boolean> {
    const id: string = mediaId.trim();
    if (id.length === 0) {
      return false;
    }
    for (let index: number = 0; index < id.length; index++) {
      const ch: string = id.charAt(index);
      if (ch < '0' || ch > '9') {
        hilog.warn(DOMAIN, TAG, 'like skipped: id not numeric (%{public}s)', id.substring(0, 24));
        return false;
      }
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'like skipped: no session');
      return false;
    }
    const data: Record<string, Object> = MobileRequest.withExtraData(identity);
    data['media_id'] = id;
    const endpoint: string = `media/${id}/${like ? 'like' : 'unlike'}/`;
    const result: MobileResult = await MobileRequest.send(endpoint, MobileRequest.formOf(data), '',
      true, null, new MobileOptions(ApiThrottle.MOBILE, priority));
    /*
     * `classify` 已经把 "status:fail" / errors / 限流 / 未登录 都判成 ok=false 了
     * （见 MobileRequest.classify）。所以这里只认 ok，并且**再确认体内没有 errors**
     * —— 点赞那几条路实测出现过 200 + errors 的形态，那等于没生效。
     */
    const hasErrors: boolean = result.body.indexOf('"errors"') >= 0;
    const ok: boolean = result.ok && !hasErrors;
    hilog.info(DOMAIN, TAG, 'like id=%{public}s like=%{public}s ok=%{public}s errors=%{public}s %{public}s',
      id, like ? 'y' : 'n', ok ? 'y' : 'n', hasErrors ? 'y' : 'n', result.summary());
    return ok;
  }
}
