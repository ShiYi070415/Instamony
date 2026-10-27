/*
 * **触摸反馈（震动）**：全 app 只走这里，别在各处直接调 vibrator。
 *
 * 需求："长按倍速新增手机震动" —— 长按两侧进入 2 倍速时给一下轻微的触感反馈
 * （用户不用盯着胶囊也能确认"倍速生效了"）。
 *
 * 三条约束：
 *   1. **不能崩**：设备没有马达、权限没给、系统拒绝，全都只是"没震动"，不能影响手势；
 *      所以所有调用都包 try/catch，promise 也接住（不接住会冒出 unhandled rejection）。
 *   2. **要短**：`usage: 'touch'` + 30ms 是系统"轻点"档的观感；用 100ms 会像来电。
 *   3. **可选能力**：`ohos.permission.VIBRATE` 是 system_grant（装包即授权），
 *      但个别设备没有马达 —— 用 `vibrator.startVibration` 的失败来兜底即可，不需要额外探测。
 */

import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'Haptics';

/** 长按进入 2 倍速时的触感时长（毫秒）。 */
const SPEED_HOLD_MS: number = 30;

export class Haptics {
  /** 长按倍速生效：一下轻点。 */
  static speedHold(): void {
    Haptics.tick(SPEED_HOLD_MS);
  }

  /**
   * 通用轻点。
   *
   * @param durationMs 时长（毫秒）；内部夹在 [10, 60]，别让调用方手滑写出"来电级"的长震。
   */
  static tick(durationMs: number): void {
    const duration: number = durationMs < 10 ? 10 : (durationMs > 60 ? 60 : durationMs);
    try {
      const effect: vibrator.VibrateTime = { type: 'time', duration: duration };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
      vibrator.startVibration(effect, attribute).then((): void => {
      }).catch((error: BusinessError): void => {
        // 没有马达 / 权限被拒 / 系统策略拦：静默，不打扰用户。
        hilog.debug(DOMAIN, TAG, 'vibrate skipped: %{public}d %{public}s',
          error.code, error.message ?? '-');
      });
    } catch (error) {
      hilog.debug(DOMAIN, TAG, 'vibrate threw: %{public}s', (error as Error).message ?? '-');
    }
  }
}
