/*
 * **真机设备档案**：把"我们自称是谁"换成"这台机器真的是谁"。
 *
 * ## 为什么需要它
 * 原来的 `MobileConfig.DeviceProfile.DEFAULT` 是照 instagrapi 抄来的 Pixel 8 Pro（美国版），
 * 而 `COHERENT_FINGERPRINT` 又把时区/语言/国家改成了**跟随系统**。于是请求里出现一组矛盾：
 * 一台"Pixel 8 Pro"、系统语言中文、时区 +8、出口 IP 在国内 —— 这种"美国机型 + 中国行为"
 * 是最廉价、也最稳定的自动化判据之一（见 `FINGERPRINT_ANALYSIS.md` 根因 B）。
 *
 * 这里改成读**这台设备自己的**品牌/型号/分辨率/DPI/ABI，拼进 User-Agent，
 * 于是"设备档案"与"语言/时区/IP"自洽。**生成一次、终身不变**（不做轮换）：
 * 轮换等于"同一账号天天换手机"，比不换可疑得多。
 *
 * ## 只读、可降级
 * - 任何一项读不到就退回 `DeviceProfile.DEFAULT` 的对应值，不会因为设备信息缺失而崩；
 * - 只读公开的机型/分辨率，不碰任何账号或隐私字段；
 * - `androidVersion` / `androidRelease` 是唯一"编"的字段：HarmonyOS 设备本身没有 Android 版本号，
 *   按品牌给一个**合理且固定**的值（华为/荣耀系取 12/12 —— 它们的 HarmonyOS 4 就是 Android 12 底），
 *   其它品牌沿用 instagrapi 的 34/14。IG 侧只看合理性与稳定性，这两项不随请求变。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DeviceProfile } from './MobileConfig';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DeviceTruth';

/** 华为/荣耀系的 Android 底版本（HarmonyOS 4 基于 Android 12）。 */
const HUAWEI_ANDROID_VERSION: string = '12';
const HUAWEI_ANDROID_RELEASE: string = '12';
/** 其它品牌的默认（与 instagrapi 的 DEVICE_SETTINGS 一致）。 */
const DEFAULT_ANDROID_VERSION: string = '34';
const DEFAULT_ANDROID_RELEASE: string = '14';

export class DeviceTruth {
  /** 已经算好的档案（读一次就够；设备信息不会变）。 */
  private static cached: DeviceProfile | null = null;

  /**
   * 这台机器的档案（首次调用时读取并缓存）。
   *
   * 读不到任何字段时退回 `DeviceProfile.DEFAULT` —— 那仍然是"一台固定的设备"，
   * 不会退化成"每次请求都不同"。
   */
  static profile(): DeviceProfile {
    const hit: DeviceProfile | null = DeviceTruth.cached;
    if (hit !== null) {
      return hit;
    }
    let brand: string = '';
    let model: string = '';
    let series: string = '';
    let abi: string = '';
    try {
      brand = `${deviceInfo.brand ?? ''}`.trim();
      model = `${deviceInfo.productModel ?? ''}`.trim();
      series = `${deviceInfo.productSeries ?? ''}`.trim();
      abi = `${deviceInfo.abiList ?? ''}`.trim();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'deviceInfo read failed: %{public}s',
        (error as Error).message ?? '-');
    }
    // 分辨率 / DPI：用窗口所在屏幕的真实值（IG 的 UA 里这两项要与机型对得上）。
    let resolution: string = DeviceProfile.DEFAULT.resolution;
    let dpi: string = DeviceProfile.DEFAULT.dpi;
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      const width: number = screen.width;
      const height: number = screen.height;
      if (width > 0 && height > 0) {
        // 与 Android UA 的习惯一致：**短边在前**（1344x2992 那种写法）。
        resolution = width <= height ? `${width}x${height}` : `${height}x${width}`;
      }
      const density: number = screen.densityDPI;
      if (density > 0) {
        dpi = `${density}dpi`;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'display read failed: %{public}s', (error as Error).message ?? '-');
    }
    const upperBrand: string = brand.toUpperCase();
    const huawei: boolean = upperBrand.indexOf('HUAWEI') >= 0
      || upperBrand.indexOf('HONOR') >= 0 || upperBrand.indexOf('华为') >= 0;
    /*
     * 厂商名照 Android UA 的写法：IG 的 `USER_AGENT_BASE` 里 manufacturer 一项
     * 真实 App 会写成 `Google/google` 这种"厂商/子厂商"。这里给 `品牌/品牌`。
     */
    const manufacturer: string = brand.length > 0
      ? `${brand}/${brand}` : DeviceProfile.DEFAULT.manufacturer;
    const deviceCode: string = series.length > 0 ? series
      : (model.length > 0 ? model : DeviceProfile.DEFAULT.device);
    const cpu: string = abi.length > 0 ? abi.split(',')[0].trim() : DeviceProfile.DEFAULT.cpu;
    const profile: DeviceProfile = new DeviceProfile(
      huawei ? HUAWEI_ANDROID_VERSION : DEFAULT_ANDROID_VERSION,
      huawei ? HUAWEI_ANDROID_RELEASE : DEFAULT_ANDROID_RELEASE,
      dpi,
      resolution,
      manufacturer,
      model.length > 0 ? model : DeviceProfile.DEFAULT.model,
      deviceCode,
      cpu.length > 0 ? cpu : DeviceProfile.DEFAULT.cpu);
    DeviceTruth.cached = profile;
    hilog.info(DOMAIN, TAG,
      'device truth brand=%{public}s model=%{public}s device=%{public}s res=%{public}s dpi=%{public}s cpu=%{public}s',
      brand, profile.model, profile.device, profile.resolution, profile.dpi, profile.cpu);
    return profile;
  }
}
