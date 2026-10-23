/*
 * **有序复位序列**（`pages/Index.forgetAccountMemory` 用的执行器）。
 *
 * ## 为什么需要"有序 + 单步隔离"
 * 换账号 / 退出登录要把十几处状态清干净，而这些清理**一步失败会把后面全跳过**：
 * 现在它们是同一段顺排语句，只要其中任何一句抛异常（例如某个视图模型 `reset()` 里
 * 碰了已释放的资源、或网页宿主已经卸载导致 `controller.removeCache` 抛错），
 * 后面的"清头像 / 清托盘队列 / 重读花名册"就都不会执行 —— 结果正是我们反复修过的
 * 那类"换号后还残留上一个人的东西"。
 *
 * 所以把序列交给这个执行器：**每一步一个名字、各自 try/catch**，谁失败只记一行日志，
 * 其余照常执行，最后打一行"哪些步骤失败"。这样"漏清"不再由某一句的异常决定。
 *
 * ## 它不拥有任何状态
 * 步骤由调用方（页面）提供闭包 —— 视图模型实例、`@State`、网页宿主句柄都在页面手上，
 * 这里只负责**顺序**与**失败隔离**。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SessionReset';

/** 一步复位：名字（日志用）+ 真正要做的事。 */
export class ResetStep {
  readonly name: string;
  readonly run: () => void;

  constructor(name: string, run: () => void) {
    this.name = name;
    this.run = run;
  }
}

export class SessionReset {
  /**
   * 依次执行复位步骤。
   *
   * @returns 失败的步骤名（空数组 = 全部成功）
   */
  static run(label: string, steps: Array<ResetStep>): Array<string> {
    const failed: Array<string> = [];
    const started: number = Date.now();
    for (let index: number = 0; index < steps.length; index++) {
      const step: ResetStep = steps[index];
      try {
        step.run();
      } catch (error) {
        failed.push(step.name);
        hilog.warn(DOMAIN, TAG, 'reset step "%{public}s" failed: %{public}s',
          step.name, (error as Error).message);
      }
    }
    if (failed.length > 0) {
      hilog.warn(DOMAIN, TAG, 'reset %{public}s done with %{public}d failure(s): %{public}s'
        + ' (%{public}dms)',
        label, failed.length, failed.join(','), Date.now() - started);
    } else {
      hilog.info(DOMAIN, TAG, 'reset %{public}s clean: %{public}d steps (%{public}dms)',
        label, steps.length, Date.now() - started);
    }
    return failed;
  }
}
