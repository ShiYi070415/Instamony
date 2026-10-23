/*
 * **会话作用域的清理事务**（换账号 / 退出登录共用，见 pages/Index.forgetAccountMemory）。
 *
 * ## 为什么搬出来（P1-9 的第二刀）
 * "换个人之前必须做的几件事"原来散在 `pages/Index` 的那一百多行里：停实时通道、清验证台账、
 * 清限流冷却、清进程内缓存、作废会话材料……**顺序是有讲究的**（实时通道必须最先停，
 * 否则它还在把上一个账号的私信帧往新界面派发），而这种"顺序 + 完整性"的约定
 * 放在一个一万多行的页面里，最容易在下次改动时被打乱或漏掉。
 *
 * 现在把**不依赖任何 UI 状态**的那几步收到这里（`core/` 层），页面只负责自己的 `@State`
 * 与视图模型实例：
 *
 *   1) 停实时通道（最先：后面所有清理都假设"没有人在往里推数据"）；
 *   2) 清验证/挑战台账（`MobileChallenge`）；
 *   3) 归零限流与熔断（`ApiThrottle.clear`，冷却按账号算）；
 *   4) 清"按人生效"的进程内缓存（`AccountCaches`）；
 *   5) 作废会话材料（`MobileSession.clearSession`：设备身份留着，claim/rur/mid/auth 清掉）。
 *
 * 留在页面里的（因为它们是 UI 状态或页面持有的实例）：
 *   · 各视图模型的 `reset()`；`@State`（storyQueue / 头像 / 用户名 / 标志位）；
 *   · 网页宿主的卸载与 HTTP 缓存清理（需要 controller 句柄）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from './ApiThrottle';
import { AccountCaches } from './AccountCaches';
import { DirectRealtime } from './DirectRealtime';
import { MobileChallenge } from './mobileapi/MobileChallenge';
import { MobileSession } from './mobileapi/MobileSession';
import { RealtimeWorkerClient } from './mobileapi/RealtimeWorkerClient';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SessionService';

export class SessionService {
  /**
   * 把"上一个账号的会话痕迹"从内存里清掉（幂等；换号与退出登录都走这里）。
   *
   * @returns 是否真的停掉了实时通道（页面据此复位自己的 `realtimeStarted` 标志）
   */
  static forgetAccountSession(): boolean {
    /*
     * 1) **实时通道必须先下线**：它拿的是上一个账号的 sessionid，不下线就会继续收那个号的
     *    私信、并把帧派发到新账号的界面上（串号）。放在最前面 —— 后面的清理都假设
     *    "没有人在往里推数据"。
     */
    let stopped: boolean = false;
    try {
      RealtimeWorkerClient.getInstance().stop();
      stopped = true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'realtime stop failed: %{public}s', (error as Error).message);
    }
    DirectRealtime.clearAccount();
    // 2) 账号安全验证台账：挑战地址是按账号记的，换人之后必须清。
    try {
      MobileChallenge.clear();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'challenge clear failed: %{public}s', (error as Error).message);
    }
    // 3) 限流冷却/整账号熔断：额度按账号算，换人之后重新开始。
    ApiThrottle.clear();
    // 4) 进程内"按人"的缓存（快拍、头像小图、预下载、译文、页级 memo…）。
    AccountCaches.clearProcessCaches();
    // 5) 设备侧会话材料：设备身份（UUID/mid）留着，会话级材料（claim/rur/authorization）作废。
    try {
      MobileSession.getInstance().clearSession();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'session clear failed: %{public}s', (error as Error).message);
    }
    hilog.info(DOMAIN, TAG, 'account session forgotten (realtime stopped=%{public}s)',
      `${stopped}`);
    return stopped;
  }
}
