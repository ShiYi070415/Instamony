/*
 * 运行设备的**能力分级**（配合 targetSdk 26 / compatibleSdk 20）。
 *
 * ## 为什么需要它
 * 本工程 `targetSdkVersion = 26`、`compatibleSdkVersion = 20`：包**能装在 API 20 起的机器上**，
 * 但里面用了一批更高版本才有的接口。若不分级，低版本设备一渲染到那些接口就会崩
 * （用户反馈的"侧载后 feeds 加载一会就闪退"，最可疑的一条）。
 *
 * 逐项核对过 SDK 声明里的 `@since`：
 *   - `@ohos.arkui.uiMaterial`（`ImmersiveMaterial` / `ImmersiveStyle` / `getMaterialInfo`）
 *     以及组件上的 `.systemMaterial()` / `.menuSystemMaterial()`：**26.0.0**；
 *   - HDS 的系统材质（`hdsMaterial.*` 枚举、`getSystemMaterialTypes()`、
 *     标题栏/悬浮栏的 `systemMaterialEffect`、`ScrollEffectType.IMMERSIVE_GRADIENT_BLUR`）：
 *     **6.1.0(23)**；
 *   - `cacheDownload` 的 `clearFileCache/clearMemoryCache`：**23**；
 *   - HDS 导航本身（HdsNavigation / HdsNavDestination）与 `ScrollEffectType.GRADIENT_BLUR`：
 *     **5.0.0(12) / 6.0.0(20)**，API 20 上可用，不必降级。
 *
 * 所以分三档：≥26 全功能、23~25 只有 HDS 材质、20~22 全部退回纯色底。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PlatformCap';

/** ArkUI 沉浸材质（uiMaterial）首次出现的 API 等级。 */
const API_ARK_MATERIAL: number = 26;
/** HDS 系统材质（hdsMaterial / systemMaterialEffect）首次出现的 API 等级。 */
const API_HDS_MATERIAL: number = 23;
/**
 * **调试开关**：强制按某个 API 等级跑（0 = 不强制，用真实设备等级）。
 *
 * 留着的理由：降级路径只有在低版本设备上才会走到，而开发机通常是新系统 ——
 * 把它改成 20 再构建，就能在新机上把降级界面（无悬浮栏 / 无材质 / 纯模糊）看一遍。
 */
const FORCE_API_LEVEL: number = 0;

export class PlatformCap {
  /** 缓存下来的设备 API 等级；-1 = 还没查过。 */
  private static level: number = -1;

  /** 设备 API 等级（拿不到时按 0 处理 → 一律走最低档）。 */
  static apiLevel(): number {
    if (PlatformCap.level < 0) {
      try {
        PlatformCap.level = FORCE_API_LEVEL > 0 ? FORCE_API_LEVEL : deviceInfo.sdkApiVersion;
      } catch (error) {
        PlatformCap.level = 0;
      }
      hilog.info(DOMAIN, TAG, 'device api=%{public}d hdsMaterial=%{public}s arkMaterial=%{public}s',
        PlatformCap.level, `${PlatformCap.level >= API_HDS_MATERIAL}`,
        `${PlatformCap.level >= API_ARK_MATERIAL}`);
    }
    return PlatformCap.level;
  }

  /**
   * 能不能用 HDS 的系统材质（`hdsMaterial` 枚举、`systemMaterialEffect`、
   * `IMMERSIVE_GRADIENT_BLUR`）。API 23 起。
   */
  static hasHdsMaterial(): boolean {
    return PlatformCap.apiLevel() >= API_HDS_MATERIAL;
  }

  /**
   * 能不能用 ArkUI 的沉浸材质（`uiMaterial.ImmersiveMaterial` / `.systemMaterial()`）。API 26 起。
   *
   * 不能用时的降级：材质层省略，改给一层低透明度中性底（见 MaterialSurface 的 SurfaceModifier），
   * 按钮照样看得见、点得着，只是没有玻璃/光感效果。
   */
  static hasArkMaterial(): boolean {
    return PlatformCap.apiLevel() >= API_ARK_MATERIAL;
  }

  /** 能不能用 `cacheDownload` 的清缓存接口（API 23 起）；下载本身 API 18 起，不必判。 */
  static hasCacheClear(): boolean {
    return PlatformCap.apiLevel() >= API_HDS_MATERIAL;
  }

  /**
   * 能不能用"逐条读 Cookie"那套（`WebCookieManager.fetchAllCookies` / `WebHttpCookie`）。API 23 起。
   *
   * 不能用时退回老接口 `fetchCookie(url)`（API 11 起，返回整条 Cookie 头字符串）——
   * 见 core/InstagramCookieJar.readAsString。这条**必须**降级：会话 Cookie 是所有原生请求
   * （信息流、关注、点赞、通知）的鉴权来源，读不到就等于整个"不走网页"的路都废了。
   */
  static hasCookieDetail(): boolean {
    return PlatformCap.apiLevel() >= API_HDS_MATERIAL;
  }

  /** 一行描述（日志 / 诊断面板用）。 */
  static describe(): string {
    return `api=${PlatformCap.apiLevel()} hdsMaterial=${PlatformCap.hasHdsMaterial()}`
      + ` arkMaterial=${PlatformCap.hasArkMaterial()}`;
  }
}
