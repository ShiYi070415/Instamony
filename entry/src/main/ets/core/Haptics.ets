/*
 * **触摸反馈（震动）**：全 app 只走这里，别在各处直接调 vibrator。
 *
 * 需求："长按倍速新增手机震动" —— 长按左右两侧进入 2 倍速时给一下轻触感。
 *
 * ## 为什么要"两条策略"
 * `vibrator.startVibration({ type: 'time' })` 是最直接的写法，但真机上它可能被拒：
 * 没有马达、系统触摸反馈被关掉、或者厂商策略只放行"预置效果"（preset effectId）。
 * 所以这里按顺序试：
 *   ① `{ type: 'time', duration: 30 }` + `usage: 'touch'`；
 *   ② 失败再试预置效果 `haptic.clock.timer`（系统里最通用的"轻点"档）。
 * 两次都失败就是"这台机器不给震"，静默收场 —— 但会**写进 Reels 崩溃日志**，
 * 用户导出诊断时就能看到失败码（不然永远是"我这边没震动"这种口头反馈）。
 *
 * ## 约束
 *   · 所有调用包 try/catch，promise 也接住（不接会冒出 unhandled rejection）；
 *   · 时长夹在 [10, 60]ms，别让调用方手滑写出"来电级"长震；
 *   · 不探测能力、不申请新权限：`ohos.permission.VIBRATE` 是 system_grant，装包即生效。
 */

import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReelsCrashLog } from './ReelsCrashLog';

const DOMAIN: number = 0xFF00;
const TAG: string = 'Haptics';

/** 长按进入 2 倍速时的触感时长（毫秒）。 */
const SPEED_HOLD_MS: number = 30;
/** 兜底用的预置效果 id：系统里最通用的短促"轻点"。 */
const FALLBACK_EFFECT_ID: string = 'haptic.clock.timer';

export class Haptics {
  /** 上一次真正震动的时刻：短时间去重（两条长按路径可能同时进来，不能震两下）。 */
  private static lastFireMs: number = 0;

  /** 长按倍速生效：一下轻点（见文件头的两条策略）。 */
  static speedHold(): void {
    Haptics.fire(SPEED_HOLD_MS, 'speed-hold');
  }

  /**
   * 通用轻点。
   *
   * @param durationMs 时长（毫秒）；内部夹在 [10, 60]。
   * @param tag 写日志用的标记（哪个交互震的）。
   */
  static tick(durationMs: number, tag: string = 'tick'): void {
    Haptics.fire(durationMs, tag);
  }

  private static fire(durationMs: number, tag: string): void {
    // 150ms 内只震一次（页面级 / slide 级两条长按都可能调进来）。
    const now: number = Date.now();
    if (now - Haptics.lastFireMs < 150) {
      return;
    }
    Haptics.lastFireMs = now;
    const duration: number = durationMs < 10 ? 10 : (durationMs > 60 ? 60 : durationMs);
    try {
      const effect: vibrator.VibrateTime = { type: 'time', duration: duration };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
      vibrator.startVibration(effect, attribute)
        .then((): void => {
          hilog.debug(DOMAIN, TAG, 'vibrate ok tag=%{public}s %{public}dms', tag, duration);
          ReelsCrashLog.note(`haptic ok tag=${tag} ${duration}ms`);
        })
        .catch((error: BusinessError): void => {
          hilog.info(DOMAIN, TAG, 'vibrate time rejected tag=%{public}s code=%{public}d msg=%{public}s',
            tag, error.code, error.message ?? '-');
          Haptics.firePreset(tag, error.code, error.message ?? '-');
        });
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'vibrate threw tag=%{public}s %{public}s',
        tag, (error as Error).message ?? '-');
      Haptics.firePreset(tag, -1, (error as Error).message ?? '-');
    }
  }

  /** 第二条策略：预置效果（部分机型只放行这一种）。 */
  private static firePreset(tag: string, firstCode: number, firstMessage: string): void {
    try {
      const effect: vibrator.VibratePreset = { type: 'preset', effectId: FALLBACK_EFFECT_ID };
      const attribute: vibrator.VibrateAttribute = { id: 0, usage: 'touch' };
      vibrator.startVibration(effect, attribute)
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'vibrate preset ok tag=%{public}s', tag);
          ReelsCrashLog.note(`haptic preset-ok tag=${tag} (time-first-failed ${firstCode})`);
        })
        .catch((error: BusinessError): void => {
          // 两条都不行：记一行现场，导出诊断时能看到到底是被什么挡的。
          hilog.warn(DOMAIN, TAG, 'vibrate all failed tag=%{public}s time=%{public}d/%{public}s preset=%{public}d/%{public}s',
            tag, firstCode, firstMessage, error.code, error.message ?? '-');
          ReelsCrashLog.note(`haptic FAILED tag=${tag} time=${firstCode} preset=${error.code}`
            + ` ${firstMessage} | ${error.message ?? '-'}`);
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'vibrate preset threw tag=%{public}s %{public}s',
        tag, (error as Error).message ?? '-');
      ReelsCrashLog.note(`haptic FAILED tag=${tag} time=${firstCode} preset=throw`);
    }
  }
}
