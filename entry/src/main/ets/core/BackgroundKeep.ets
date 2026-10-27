/*
 * **"退到后台还能再跑一会儿"**（短时任务 / suspend delay）。
 *
 * ## 为什么需要它
 * 需求："消息推送可以挂后台吗" —— 真机上的现状是：
 *   · 本地通知（core/PushCenter）只在**应用还活着**的时候发得出来；
 *   · 应用一退到后台，系统的资源调度很快就会把进程冻结，JS 定时器随之停摆，
 *     于是"退出去之后再来的私信"一条通知都不会弹。
 *
 * HarmonyOS 给普通应用的解法是**短时任务**：退到后台时向系统申请一段"还能继续跑"的
 * 时间（`backgroundTaskManager.requestSuspendDelay`）。这**不需要任何权限**，
 * 但额度很紧 —— 系统给的是**分钟级**，而且**单日有总配额**（见官方文档；超出后申请会失败，
 * 只能等第二天）。所以它的定位是"刚退出去那几分钟里的新消息还能通知到"，
 * 不是"常驻后台"。
 *
 * ## 为什么不申请长时任务（ContinuousTask）
 * 长时任务要在 `module.json5` 里声明一个 `backgroundModes` 类型（音频播放 / 定位 / 数据传输…），
 * 而且会挂一条**常驻通知**。私信检查不属于其中任何一类，硬套 dataTransfer 既过不了应用市场
 * 审核，也是在骗电池 —— 本项目不这么做。
 *
 * ## 真正的离线推送
 * 需要 **Push Kit + 服务端**：AGC 项目里发通知要靠服务端 API（或自己的中转服务去轮询 IG）。
 * 本机没有服务器，IG 也不会把别人的私信推给我们，所以"应用被杀之后仍能收到"这件事
 * 单机做不到。这一条写在 AUDIT 里，不在这里假装实现。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'BackgroundKeep';

export class BackgroundKeep {
  /** 系统批下来的那一段延时（null = 现在没持有）。 */
  private static info: backgroundTaskManager.DelaySuspendInfo | null = null;
  /** 这一段的请求号：`cancelSuspendDelay` 要的是它，不是整个 info 对象。 */
  private static requestId: number = -1;

  /**
   * 申请一段后台时间（退到后台时调；**已经持有就不重复申请**）。
   *
   * @param reason 给系统看的理由（会出现在功耗详情里，写清楚一点）。
   */
  static request(reason: string): void {
    if (BackgroundKeep.info !== null) {
      return;
    }
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay(reason, (): void => {
          /*
           * 系统提醒"这段延时快到期了"：这里必须**主动收尾**，否则应用会被直接冻结。
           * 收尾 = 停掉后台轮询（见 core/BackgroundInbox）+ 交还这一段额度。
           */
          hilog.info(DOMAIN, TAG, 'suspend delay about to expire, releasing');
          BackgroundInbox.stop();
          BackgroundKeep.cancel();
        });
      BackgroundKeep.info = info;
      BackgroundKeep.requestId = info.requestId;
      hilog.info(DOMAIN, TAG, 'suspend delay granted %{public}dms (id %{public}d)',
        info.actualDelayTime, info.requestId);
    } catch (error) {
      // 配额用完 / 系统不允许：不影响前台使用，只是后台那几分钟的通知没有了。
      hilog.warn(DOMAIN, TAG, 'suspend delay failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

  /** 交还额度（回到前台 / 延时到期时调；没持有就是空操作）。 */
  static cancel(): void {
    const info: backgroundTaskManager.DelaySuspendInfo | null = BackgroundKeep.info;
    if (info === null) {
      return;
    }
    const requestId: number = BackgroundKeep.requestId;
    BackgroundKeep.info = null;
    BackgroundKeep.requestId = -1;
    try {
      backgroundTaskManager.cancelSuspendDelay(requestId);
      hilog.info(DOMAIN, TAG, 'suspend delay released');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'cancel suspend delay failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

  /** 现在手上有后台额度吗（诊断用）。 */
  static isHeld(): boolean {
    return BackgroundKeep.info !== null;
  }
}

/**
 * **后台里的私信检查**（配合 BackgroundKeep 的那几分钟）。
 *
 * 前台时私信页自己有轮询（见 components/DirectPage 的定时器）；退到后台后没有页面在跑，
 * 这里就替它"隔一会儿看一眼收件箱"：`DirectViewModel.refreshQuietly()` 内部已经
 * 做到"内容没变就什么都不做"，并且在未读数变多时发本地通知（core/PushCenter）。
 *
 * 间隔取 45 秒：后台额度只有分钟级，太长就一次都轮不上；太密既费电也更容易被判定成脚本流量
 * （见 core/ApiThrottle 的节奏说明）。
 */
const CHECK_GAP_MS: number = 45000;

export class BackgroundInbox {
  private static timer: number = -1;
  private static running: boolean = false;
  /** 真正那次检查（由 pages/Index 在 onAppear 里绑定到 DirectViewModel）。 */
  private static check: () => void = (): void => {
  };

  /** 绑定"看一眼收件箱"这件事（pages/Index 里调一次）。 */
  static bind(check: () => void): void {
    BackgroundInbox.check = check;
  }

  /** 开始后台轮询（退到后台时调；重复调用无害）。 */
  static start(): void {
    if (BackgroundInbox.running) {
      return;
    }
    BackgroundInbox.running = true;
    hilog.info(DOMAIN, TAG, 'background inbox check started (gap %{public}dms)', CHECK_GAP_MS);
    BackgroundInbox.schedule();
  }

  /** 停下（回到前台 / 额度用完 / 退出登录时调）。 */
  static stop(): void {
    BackgroundInbox.running = false;
    if (BackgroundInbox.timer >= 0) {
      clearTimeout(BackgroundInbox.timer);
      BackgroundInbox.timer = -1;
    }
  }

  static isRunning(): boolean {
    return BackgroundInbox.running;
  }

  private static schedule(): void {
    if (!BackgroundInbox.running) {
      return;
    }
    BackgroundInbox.timer = setTimeout((): void => {
      BackgroundInbox.timer = -1;
      if (!BackgroundInbox.running) {
        return;
      }
      try {
        BackgroundInbox.check();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'background check threw: %{public}s',
          (error as Error).message ?? 'unknown');
      }
      BackgroundInbox.schedule();
    }, CHECK_GAP_MS);
  }
}
