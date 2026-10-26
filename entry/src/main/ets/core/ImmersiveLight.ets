/*
 * 沉浸光感（沉浸式系统材质）的**等级换算**：把设定页里存的档位字符串，换成 HDS 的枚举。
 *
 * 为什么单独一个文件：
 *   首页（标题栏 + 底部页签）和发布页的标题栏用的是同一套配置，档位来自同一份设置；
 *   换算里还夹着一条**设备能力降级**的判断（见 immersiveLevel），集中放一处，
 *   免得每个页面各抄一遍、抄漏一处就出现"某一页材质特别重"。
 *
 * 官方依据：
 *   - 「沉浸光感」（HDS 组件材质）：材质等级通过 systemMaterialEffect 的 materialLevel 下发；
 *   - 「自定义沉浸光感效果」：先 getSystemMaterialTypes() 查设备能力 ——
 *     支持 IMMERSIVE 才用 EXQUISITE/GENTLE，不支持就用 SMOOTH（省电、防卡顿发热）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial, HdsTabsAttribute, HdsTabsFloatingStyle, ScrollEffectType } from '@kit.UIDesignKit';
import { PlatformCap } from './PlatformCap';
import {
  MATERIAL_LEVEL_EXQUISITE,
  MATERIAL_LEVEL_GENTLE,
  MATERIAL_LEVEL_SMOOTH,
  MATERIAL_THICKNESS_REGULAR,
  MATERIAL_THICKNESS_THICK,
  MATERIAL_THICKNESS_THIN,
  MATERIAL_THICKNESS_ULTRA_THICK
} from './AppSettings';

const DOMAIN = 0xFF00;
const TAG = 'InstamonyMaterial';

/**
 * 设备是否支持 IMMERSIVE 材质类型：`undefined` = 还没查过。
 *
 * 查一次就缓存：这个接口的结果不会随运行时变化，而 immersiveLevel 是**每次 build 都会调**的
 * （ArkUI 的属性重新求值），每次都去问系统没有必要。
 */
let immersiveSupported: boolean | undefined = undefined;

/** 设备是否支持 IMMERSIVE 材质（查不到时按"支持"处理，交给系统自己去降级）。 */
function deviceSupportsImmersive(): boolean {
  if (immersiveSupported !== undefined) {
    return immersiveSupported;
  }
  // **设备 API 低于 23 时 `hdsMaterial` 整个模块都不存在**（6.1.0(23) 起），
  // 这时候连枚举都不能碰（碰了就是 undefined，传下去轻则没效果、重则抛异常）。
  if (!PlatformCap.hasHdsMaterial()) {
    immersiveSupported = false;
    hilog.info(DOMAIN, TAG, 'hds material unsupported (api<23) → plain surface');
    return false;
  }
  let supported: boolean = true;
  try {
    const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    supported = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
  } catch (error) {
    // 接口不可用：不断言"不支持"（那会把高档位一律压成流畅，白白损失效果），
    // 照用户选的档位下发，系统拿到不支持的等级会自己回退。
    supported = true;
  }
  immersiveSupported = supported;
  hilog.info(DOMAIN, TAG, 'immersive supported=%{public}s', supported ? 'true' : 'false');
  return supported;
}

/**
 * 底部页签栏的**能力分档参数**，一个 modifier 里二选一（只有一支会跑）。
 *
 *   悬浮档（API ≥ 23）—— 只下发 `barFloatingStyle`：胶囊几何 + 沉浸光感材质。
 *     **不碰栏高**：悬浮档的栏高写在调用处的 `.barHeight(...)` 直接属性上 ——
 *     下沉收缩要让它跟着滚动量变，包在 `animateTo` 里的直接属性才走得动补间。
 *   降级档（API < 23）—— 没有悬浮样式，栏是 HDS 的普通页签栏、贴着承载层底边。
 *     这一支的栏高里**多加**了 `degradedHeight` 里让给系统导航条的那一段（见 pages/Index 的
 *     degradedBarHeight）：栏自己的背板跟着变高、一直铺到屏幕底边，也就是需求里的
 *     「通过增加容器底部高度来避让，不要直接悬浮」—— 底部让出来的那一条属于栏，
 *     不属于内容，所以看不出"浮"在内容上。栏里图标的落点由 tabBarItem 的下内边距顶回去。
 *     模糊档位取最薄（和 ArkUI 那套降级底同档，见 components/MaterialSurface 的 FALLBACK_BLUR）。
 *
 * `barFloatingStyle` 是 6.1.0(23) 起才有的；本包 compatibleSdk 是 20，低版本设备上这个属性
 * 不存在 —— 直接链式写就等于调用不存在的接口。所以走 AttributeModifier：按能力分档下发。
 * `barHeight`（6.0.0(20) 起）与 `barBackgroundBlurStyle`（6.0.0(20) 起）低版本也都在。
 */
/**
 * 调 HDS 的属性方法，**容错**：方法不存在/抛异常都只记一行日志，绝不让它把界面带崩。
 *
 * 为什么必须有：这套 HDS 属性是"声明里有、运行时未必有"的 —— 真机上 API ≥ 23 一切正常，
 * 但**模拟器**（Build 7.0.0.107）上的 HDS 运行库没有 `withTheme`，而 `PlatformCap` 从
 * `deviceInfo.sdkApiVersion` 读到的是 26（够新），于是 AttributeModifier 的 apply 里一句
 * `instance.withTheme(...)` 就是 `TypeError: undefined is not callable` —— 整个应用点开就闪退
 * （真机崩溃日志：`applyNormalAttribute entry (core/ImmersiveLight.ets:160)`）。
 * 声明版本能防"编译不过"，防不了"运行库没有"，所以运行期再兜一层。
 */
export function safeCall(what: string, run: () => void): void {
  try {
    run();
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'hds call skipped (%{public}s): %{public}s', what,
      (error as Error).message ?? 'unknown');
  }
}

export class BarChromeModifier implements AttributeModifier<HdsTabsAttribute> {
  private readonly style: HdsTabsFloatingStyle;
  private readonly degradedHeight: number;

  /**
   * @param style 悬浮档的胶囊样式（含下沉收缩的实时参数，见 Index.floatingStyle）。
   * @param degradedHeight 降级档的栏高 = 普通栏高 + 让给系统条的那一段（悬浮档用不到）。
   */
  constructor(style: HdsTabsFloatingStyle, degradedHeight: number) {
    this.style = style;
    this.degradedHeight = degradedHeight;
  }

  applyNormalAttribute(instance: HdsTabsAttribute): void {
    if (PlatformCap.hasHdsMaterial()) {
      safeCall('barFloatingStyle', (): void => {
        instance.barFloatingStyle(this.style);
      });
      return;
    }
    safeCall('barHeight', (): void => {
      instance.barHeight(this.degradedHeight);
    });
    // 降级档没有材质，栏背后只剩一层背景模糊 —— 档位取**最薄**那一档，和 ArkUI 那套降级底
    // 同一个选择（见 components/MaterialSurface 的 FALLBACK_BLUR）：全工程降级后的模糊统一
    // ultra thin（需求），不然底栏这块会比按钮那块厚一档。
    safeCall('barBackgroundBlurStyle', (): void => {
      instance.barBackgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN);
    });
  }
}

/**
 * 标题栏的滚动效果类型（首页那套"内容划过标题栏时渐显背板"）。
 *
 * 三条约束叠在一起：
 *   1. `IMMERSIVE_GRADIENT_BLUR` 是 **6.1.0(23)** 起；API 20~22 上没有这个枚举成员，
 *      传下去等于 undefined，动态背景直接没有 —— 低版本必须退回 `GRADIENT_BLUR`
 *      （6.0.0(20) 起）。
 *   2. `IMMERSIVE_GRADIENT_BLUR` 的官方说明是"**标题文字和图标样式从白色到黑色线性过渡**"，
 *      它是给**深色**沉浸式图文场景设计的：浅色模式下页面底色是白的，滚动位置还在最顶上时
 *      标题就是**白字压白底**（用户报的"浅色模式下最顶部标题栏文字反色"）。所以浅色模式
 *      也退回 `GRADIENT_BLUR` —— 背板照样是渐变模糊，只是文字/图标走主题色、不做白→黑过渡。
 *   3. 深色模式保持原来的 `IMMERSIVE_GRADIENT_BLUR`（这台机器上逐版调过、观感已确认）。
 *
 * @param dark 当前界面是不是深色（`SETTING_DARK_UI`）。
 */
export function titleScrollEffectType(dark: boolean): ScrollEffectType {
  if (!PlatformCap.hasHdsMaterial() || !dark) {
    return ScrollEffectType.GRADIENT_BLUR;
  }
  return ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
}

/**
 * HDS 的**材质类型**。
 *
 * 原来三处都硬写 `MaterialType.ADAPTIVE`。真机上看到的现象是：标题栏背板是一块不透明的黑底
 * —— HDS 的材质模型日志里 `MaterialModel::UpdateMaterial ... transparency_: 0`，也就是
 * ADAPTIVE 在这台设备上落成了"不透明底"，没有玻璃的通透/模糊。
 * 官方示例（HdsNavigation「设置标题栏沉浸式样式」）用的正是 `MaterialType.IMMERSIVE`，
 * 并且建议先用 getSystemMaterialTypes() 查设备支持哪种：支持 IMMERSIVE 就用它，
 * 不支持再退回 ADAPTIVE（让系统自己决定）。
 */
export function immersiveMaterialType(): hdsMaterial.MaterialType {
  return deviceSupportsImmersive()
    ? hdsMaterial.MaterialType.IMMERSIVE
    : hdsMaterial.MaterialType.ADAPTIVE;
}

/**
 * 把设定页里存的档位换成 HDS 的材质等级。
 *
 * 降级规则只针对"重材质"两档：设备不支持 IMMERSIVE 时，EXQUISITE/GENTLE 落到 SMOOTH
 * （官方给的正是这条建议）；ADAPTIVE 原样下发 —— 它就是"让系统按算力自己决定"，
 * 我们再插一手反而违背了它的语义；SMOOTH 本来就是最省的一档。
 */
export function immersiveLevel(setting: string): hdsMaterial.MaterialLevel {
  if (setting === MATERIAL_LEVEL_EXQUISITE) {
    return deviceSupportsImmersive()
      ? hdsMaterial.MaterialLevel.EXQUISITE
      : hdsMaterial.MaterialLevel.SMOOTH;
  }
  if (setting === MATERIAL_LEVEL_GENTLE) {
    return deviceSupportsImmersive()
      ? hdsMaterial.MaterialLevel.GENTLE
      : hdsMaterial.MaterialLevel.SMOOTH;
  }
  if (setting === MATERIAL_LEVEL_SMOOTH) {
    return hdsMaterial.MaterialLevel.SMOOTH;
  }
  // 默认（含读到没见过的值）：自适应。
  return hdsMaterial.MaterialLevel.ADAPTIVE;
}

/**
 * 材质厚度（设定页第二个下拉）→ ArkUI 的 `ImmersiveStyle`。
 *
 * 这是 ArkUI 侧唯一能设的材质轴，官方枚举正好五档，一一对应即可：
 *   ultra_thin 超薄（最通透）→ ultra_thick 超厚（模糊最强）。
 * 传入没见过的值时退回超薄（下拉里的默认档）。
 */
export function materialStyleFrom(thickness: string): uiMaterial.ImmersiveStyle {
  if (thickness === MATERIAL_THICKNESS_THIN) {
    return uiMaterial.ImmersiveStyle.THIN;
  }
  if (thickness === MATERIAL_THICKNESS_REGULAR) {
    return uiMaterial.ImmersiveStyle.REGULAR;
  }
  if (thickness === MATERIAL_THICKNESS_THICK) {
    return uiMaterial.ImmersiveStyle.THICK;
  }
  if (thickness === MATERIAL_THICKNESS_ULTRA_THICK) {
    return uiMaterial.ImmersiveStyle.ULTRA_THICK;
  }
  return uiMaterial.ImmersiveStyle.ULTRA_THIN;
}

/**
 * ArkUI 材质的颜色统一为**透明**（需求："各材质等级颜色统一透明"）。
 *
 * 官方 `ImmersiveMaterial` 的 `materialColor` 缺省即透明（不为材质滤镜额外混色），所以直接给
 * `Color.Transparent`：ArkUI 材质组件的外观只由**厚度**（上面那张下拉）决定，等级不参与着色。
 * 需要显式给一个值，是因为"不设材质颜色"时 Button 会去继承自己的主题色底（官方 Button 说明）。
 */
export const ARKUI_MATERIAL_COLOR: ResourceColor = Color.Transparent;
