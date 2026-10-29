/*
 * 沉浸光感的**按钮**与**容器**（全 app 共用这一份，别再各写各的）。
 *
 * ## 为什么按钮是 Toggle 而不是 Button
 * 官方《沉浸光感–功耗优化》写明生效范围：
 *   - 弹窗类组件（Dialog/Menu/Popup/Toast/半模态）与 **Slider、Toggle、Select** 的沉浸光感
 *     **可在全页面生效**；
 *   - "其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中 barPosition 为
 *     BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感效果**不生效**"。
 * 信息流、通知页这些**内容区**里的按钮只能靠 Toggle 承载材质（`ToggleType.Button` 的子组件
 * 会显示在按钮内，官方文档明确"仅当 ToggleType 设置为 Button 时，可包含子组件"）。
 *
 * ## 为什么图标放在 Toggle **里面**（而不是叠在材质上面）
 * 上一版是一个 Stack：底层半透明圆 + 中层材质 Toggle + 顶层图标，看着是三层。真机反馈
 * "按钮分层了，拖拽按钮时只有按钮在动，内容没动" —— 材质层开了 interaction 形变（拖拽变形），
 * 形变只作用于材质那一层，叠在同一 Stack 里的底衬和图标不跟着动，于是看起来像两张皮。
 * 现在把图标当**按钮内容**塞进 Toggle，材质和内容同一个节点，按压/拖拽时一起动；
 * 兜底底色也去掉了（材质本身会画背板，另外铺一层又会分家）。
 *
 * ## 材质参数
 * 厚薄跟设定页联动（`SETTING_MATERIAL_THICKNESS`）；开启交互形变（interactive）与
 * 光源效果（lightEffect）；自动反色（colorInvert）默认开 —— 材质是"透"的，压在白画面上的
 * 那颗按钮圆底会变浅，白图标就糊了，所以图标色一律走**资源接口**（硬编码颜色不参与反色）。
 * 沉浸式视频标题区例外（需求要取消那里的反色），见 immersiveMaterial 的 invert 参数。
 */

import { curves, uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { ARKUI_MATERIAL_COLOR, materialStyleFrom } from '../core/ImmersiveLight';
import { PlatformCap } from '../core/PlatformCap';

import { LikeIcon, RepostIcon, SaveIcon } from './AnimatedIcons';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MaterialSurface';
/** 已赞心形的颜色（和信息流那颗心同一个色：`app.color.like_active` = #ED4956）。 */
const LIKE_ACTIVE_HEX: string = '#ED4956';

/**
 * 系统材质**用不了**时的兜底底色（API < 26）。
 *
 * 用系统资源而不是写死颜色：`sys.color.comp_background_secondary` 是"低透明度中性色"
 * （浅色 #19000000 / 深色 #19FFFFFF），明暗主题各一套，压在图片/纯色底上都还能看清。
 */
export const FALLBACK_SURFACE: Resource = $r('sys.color.comp_background_secondary');

/**
 * 兜底那层再叠一层**背景模糊**（需求："为所有按钮添加 blur 效果"）。
 *
 * 系统材质给的是"玻璃 + 光源 + 交互形变"，低版本设备拿不到 —— 但 `backgroundBlurStyle`
 * 是 API 10 起就有的通用属性，能把按钮背后的画面糊一层，观感上最接近材质。
 * 用 COMPONENT_* 这一组（组件级模糊，官方为"卡片/按钮这类组件"给的档位）。
 *
 * 档位取**最薄**那一档（需求："全局 blur 材质用 ultra thin"）：降级底本身只是一层纯色
 * （见 FALLBACK_SURFACE），模糊再厚就成一块糊死的灰板，压在媒体图上比不糊还难看；
 * ULTRA_THIN 只把背后画面轻轻晕开，透出来的还是原来的明暗关系。所以全工程降级后的模糊
 * 统一是这一档。
 */
export const FALLBACK_BLUR: BlurStyle = BlurStyle.COMPONENT_ULTRA_THIN;

/**
 * 把"沉浸光感材质"这一层挂到 Toggle 上，**并在系统不支持时自动降级**。
 *
 * 为什么用 `AttributeModifier` 而不是直接链式写 `.systemMaterial(...)`：
 *   `.systemMaterial()` 与 `uiMaterial.ImmersiveMaterial` 都是 **API 26 起**的接口，
 *   而这个包 compatibleSdk 是 20 —— 直接写在 build() 里，低版本设备一渲染就崩
 *   （用户反馈的"侧载后 feeds 加载一会就闪退"）。AttributeModifier 的 apply 是运行时调用的，
 *   在这里判一次能力，够新才碰那些接口，不够新就走纯色底。
 */
export class SurfaceModifier implements AttributeModifier<ToggleAttribute> {
  private readonly thickness: string;
  private readonly invert: boolean;
  private readonly applyShadow: boolean;
  /** 光感交互反馈（按下时表面那道光）开不开，见 immersiveMaterial 的 @param lightEffect。 */
  private readonly lightEffect: boolean;
  /** 交互形变（按下/拖动时材质跟着形变）开不开，见 @param interactive。 */
  private readonly interactive: boolean;
  /**
   * **强制用降级观感**（不碰 `systemMaterial`），即使设备支持材质。
   *
   * 为什么需要这个开关（真机实测 2026-10-22）：把分段按钮挂到 HDS 标题栏的 `bottomBuilder`
   * 里之后，胶囊的玻璃底**整块消失**，只剩那颗灰底药丸孤零零地悬着 —— 官方《沉浸光感–功耗优化》
   * 说得很清楚："避免材质嵌套（同一子树里只应在最外层设一次）"。标题栏自己已经是一层材质，
   * 内层再设一次就不生效（而且不报错，就是看不见）。
   *
   * 这种情况退回「低透明度中性底 + 背景模糊」那套老接口凑同一层观感（同下面的降级分支）。
   */
  private readonly forceFallback: boolean;

  /**
   * @param thickness 材质厚度档位。
   * @param invert 是否跟着背景反色。
   * @param applyShadow 要不要**材质自带的阴影**。默认 true，这就是**全局策略**：
   *   所有沉浸光感组件都带这圈阴影（需求："将这套阴影套用到所有沉浸光感组件上"）。
   *   全工程没有调用点传 false 了，保留这个参数只是留一个"某处太抢就单独关掉"的开关。
   *   **两处例外不归这里管**：悬浮页签、HDS 导航栏的菜单按钮走的是 HDS 的材质
   *   （`systemMaterialEffect`，见 pages/Index 的 floatingStyle / pageTitleStyle），
   *   hdsMaterial 里压根没有 applyShadow 字段 —— 它们的阴影由 HDS 自己决定。
   * @param forceFallback 见字段说明（标题栏里那条分段按钮传 true）。
   * @param lightEffect 要不要**光感交互反馈**（默认 true = 全 app 的老观感）。
   *   评论面板里那张帖子卡片传 false（需求："取消卡片的 light 效果"）——
   *   卡片是"贴在那儿的一块静态玻璃"，不应该一碰就自己发光。
   * @param interactive 要不要**交互形变**（默认 true）。同一个调用点也传 false：
   *   需求"卡片是静态玻璃，不跟着手指动"。
   *   两个默认值都保持原行为，**不影响全 app 其它调用点**。
   */
  constructor(thickness: string, invert: boolean = true, applyShadow: boolean = true,
              forceFallback: boolean = false, lightEffect: boolean = true,
              interactive: boolean = true) {
    this.thickness = thickness;
    this.invert = invert;
    this.applyShadow = applyShadow;
    this.forceFallback = forceFallback;
    this.lightEffect = lightEffect;
    this.interactive = interactive;
  }

  applyNormalAttribute(instance: ToggleAttribute): void {
    if (PlatformCap.hasArkMaterial() && !this.forceFallback) {
      // 材质接口是 26 起的：声明里有、**运行时未必有**（模拟器上 `withTheme` 就是这么炸的，
      // 见 core/ImmersiveLight 的 safeCall）。这里同样兜一层，最坏退化成没有材质的按钮，
      // 而不是把整个界面带崩。
      let applied: boolean = false;
      try {
        instance.systemMaterial(immersiveMaterial(this.thickness, this.invert, this.applyShadow,
          this.lightEffect, this.interactive));
        applied = true;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'systemMaterial skipped: %{public}s',
          (error as Error).message ?? 'unknown');
      }
      if (applied) {
        return;
      }
    }
    // 降级：没有系统材质，改用「低透明度中性底 + 背景模糊」凑出最接近的玻璃观感
    // （需求：为所有按钮加 blur）。两者都是老接口，API 20 起就有。
    instance.backgroundColor(FALLBACK_SURFACE);
    instance.backgroundBlurStyle(FALLBACK_BLUR);
  }
}

/**
 * 把沉浸光感材质挂到 **Search**（搜索框）上，并在系统不支持时降级。
 *
 * 为什么单独一个类：`Search` 不是 Toggle，而 `SurfaceModifier` 是给 `ToggleAttribute` 写的
 * （AttributeModifier 按组件类型泛型，传错类型编译不过）。官方《沉浸光感典型场景》里
 * "搜索框标题栏效果"那份示例就是 `Search(...).systemMaterial(new uiMaterial.ImmersiveMaterial({}))`，
 * 这里只是把"能力判断 + 降级"包一层（低版本设备上 `systemMaterial` 不存在，直接写会崩）。
 *
 * **生效范围**：`Search` 不在"全页面生效"那几个组件里（官方功耗优化那条：只有 Slider / Toggle /
 * Select 与弹窗类可以在任意位置生效），所以搜索框必须待在 **Navigation/NavDestination 标题栏区域**
 * （见 pages/Index 的 titleBar.bottomBuilder）——摆在内容区里是不会有材质效果的。
 *
 * 反色（colorInvert）传 false：框里的文字/图标本来就用主题色资源（黑白主题），
 * 不需要材质再算一遍反色（和分段按钮同一个理由）。
 */
export class SearchSurfaceModifier implements AttributeModifier<SearchAttribute> {
  private readonly thickness: string;

  constructor(thickness: string) {
    this.thickness = thickness;
  }

  applyNormalAttribute(instance: SearchAttribute): void {
    if (PlatformCap.hasArkMaterial()) {
      // 同 SurfaceModifier：材质接口声明里有、运行时未必有，兜一层。
      try {
        instance.systemMaterial(immersiveMaterial(this.thickness, false));
        return;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'search systemMaterial skipped: %{public}s',
          (error as Error).message ?? 'unknown');
      }
    }
    // 降级：没有系统材质就退回"低透明度中性底 + 背景模糊"（和按钮同一套兜底）。
    instance.backgroundColor(FALLBACK_SURFACE);
    instance.backgroundBlurStyle(FALLBACK_BLUR);
  }
}

/**
 * 按钮的统一尺寸（vp）。
 *
 * 需求："按钮高度需要保持一致性，按照现在沉浸式标题那个按钮的高度" —— 沉浸式标题那一行里
 * 「更多」是 40，所以圆按钮直径、文字按钮高度全部统一到 **40**；图标 20 与之配套。
 * 以后要整体调高度只改这两个数（以及 MATERIAL_PILL_HEIGHT）。
 */
export const MATERIAL_BUTTON_SIZE: number = 40;
export const MATERIAL_ICON_SIZE: number = 20;
/** 文字按钮的统一高度（同 MATERIAL_BUTTON_SIZE，单独留一个名字方便阅读）。 */
export const MATERIAL_PILL_HEIGHT: number = 40;
/** 文字按钮的默认宽度（只有 2 个字的「关注」这类）。 */
export const MATERIAL_PILL_WIDTH: number = 72;

/** 文字按钮的语义色档位（见 MaterialLabelButton.tone）。 */
export const TONE_DEFAULT: string = 'default';
export const TONE_ACCENT: string = 'accent';
export const TONE_DANGER: string = 'danger';

/**
 * 「手指正按在材质按钮上」的同步标记 + **这一下触摸的起点**。
 *
 * 需求："长按滑动按钮时不会影响页面"、"我需要四象锁定" —— 材质按钮上开始的**按住后拖动**，
 * 上下左右都不该带着页面/照片走：
 *   - 上下：外层 List / Refresh 的内建 PAN；
 *   - 左右：多图轮播（Swiper）的内建 PAN —— 它是按钮的**兄弟**节点，而对齐壳为了不挡媒体上的
 *     双击点赞用的是 HitTestMode.Transparent（不阻塞兄弟），所以横向拖动会被它接走，
 *     表现就是"照片跟着滑"。
 *
 * 但**按下就划**（用户其实是在滑页面）不能也被锁住 —— 那会变成"手指落在按钮上页面就滑不动"，
 * 也就是用户报的"滑动被按钮的 4-way-lock 卡手"。所以这里除了"按着没有"，还记下**触摸起点与
 * 时刻**，由 holdsScroll 分辨"滑页面"和"按按钮"（判据见那里的说明）。
 *
 * **为什么是普通静态字段，而不是 AppStorage / @State**：外层可滚动容器要在
 * `onGestureRecognizerJudgeBegin` 里"一票否决"内建滑动手势，而这个回调是在**手势识别那一刻**
 * （按下去的头几个 move 事件）同步调用的。AppStorage + @StorageProp 那条路要等一次状态通知
 * 和一次重绘，真机上（尤其注入的快速滑动）列表早就滚起来了 —— 实测那样做页面照样滚掉 547px。
 * 静态字段在 TouchType.Down 的处理里当场生效，紧接着的 move 事件就能读到。
 */
export class MaterialPressState {
  /** 手指现在按在某个材质按钮/材质容器上。 */
  static pressed: boolean = false;
  /** 这一下触摸按下的时刻（毫秒时间戳，0 = 当前没有触摸）。 */
  static downMs: number = 0;
  /** 这一下触摸**第一次移动**的时刻（毫秒时间戳，0 = 按下后还没动过）。 */
  static moveMs: number = 0;
  /** 这一下触摸按下的位置（px，windowX/windowY 坐标系，见 trackScrollTouch）。 */
  static downX: number = 0;
  static downY: number = 0;
}

/**
 * 按下之后**停多久才开始划**算"用户是按按钮，不是在滑页面"（毫秒）。
 *
 * 判据用的是"按下 → 第一次移动"的间隔，而不是"按下 → 手势成立"的间隔：
 *   一次滑动的手感是"指头落下去就开始走"，30~120ms 内就动了；
 *   而"按按钮"是先用指头按住（材质要出来、光感要给反馈），停一会儿才决定拖。
 * 用"手势成立"那个时刻不行 —— 慢慢滑的时候手指走了好几帧才够到手势阈值，看着也像"停了一会儿"，
 * 于是慢速滑动反而会被锁住（正是"卡手"的另一种形态）。
 *
 * 取 180ms：偏向"多放行滑动"的那一侧（宁可偶尔把一次慢按当成滑动，也别再卡手）。
 */
const MATERIAL_HOLD_MS: number = 180;

/** 按钮按下/抬起时调用（见 MaterialPressState）。 */
export function setMaterialPressLock(down: boolean): void {
  MaterialPressState.pressed = down;
}

/**
 * 可滚动容器（List / Refresh）挂在 `onTouch` 上：记下触摸起点与"第一次移动"的时刻，
 * 并在抬手时**兜底解锁**。
 *
 * 三点用途：
 *   1. 这几个时刻/坐标是 holdsScroll 分辨"滑页面 / 按按钮"的依据；
 *   2. 抬手时无条件解锁：按钮那一路的 Up/Cancel 有可能被上层手势吃掉（手势被接走时子节点
 *      不一定收得到抬手），残留的"按住"标记会把**后面每一次滑动**都卡住 —— 这是"卡手"
 *      最讨厌的一种形态；可滚动容器一定在触摸链路上，在这里兜底最稳；
 *   3. onTouch 只观察、不消费事件，不影响容器自己的滚动。
 */
export function trackScrollTouch(event: TouchEvent): void {
  if (event.type === TouchType.Down) {
    markTouchDown(event);
    return;
  }
  if (event.type === TouchType.Move) {
    markFirstMove();
    return;
  }
  if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
    MaterialPressState.downMs = 0;
    MaterialPressState.moveMs = 0;
    setMaterialPressLock(false);
  }
}

/**
 * 记下"这一下触摸从哪儿开始、什么时候按下"。
 *
 * 可滚动容器和材质按钮**两路都调**，谁先到算谁的：按钮在链路上更靠内，通常先收到；容器那条
 * 兜住"触摸落在非按钮区域"的情况。两次记的是同一下触摸的同一个起点，重复调用无害。
 */
function markTouchDown(event: TouchEvent): void {
  MaterialPressState.downMs = Date.now();
  MaterialPressState.moveMs = 0;
  const point: TouchObject | undefined = event.touches.length > 0 ? event.touches[0] : undefined;
  MaterialPressState.downX = point === undefined ? 0 : point.windowX;
  MaterialPressState.downY = point === undefined ? 0 : point.windowY;
}

/**
 * 记下"这一下触摸第一次移动"的时刻（只记第一次）。
 *
 * 可滚动容器和材质按钮两路都会调它：哪一路先看到移动就算哪一路的 —— 手指一动，整条触摸链路上
 * 的 onTouch 都会收到 Move，谁先到都行。
 */
function markFirstMove(): void {
  if (MaterialPressState.moveMs === 0) {
    MaterialPressState.moveMs = Date.now();
  }
}

/**
 * 现在这一下触摸要不要**咬住**外层滚动/翻页（= 材质按钮的 4-way-lock）。
 *
 * 按需求分三种情况：
 *   1. 没按在材质按钮上 → 不咬（`pressed` 为假，和以前一样）；
 *   2. 按住**停了一会儿**（≥ MATERIAL_HOLD_MS）才开始划 → 咬住。这是原来的行为：
 *      长按材质按钮再拖动只做材质形变，页面/照片都不动（4-way-lock 原样保留）；
 *   3. 按下去**马上**就划（< MATERIAL_HOLD_MS）→ 用户是在滑页面，**放行**：
 *      · 竖向为主 → 交给列表滚（用户报的"滑动被按钮卡手"正是这一条）；
 *      · 横向为主 → 仍然咬住（那是轮播的翻页手势，按钮的横向锁不该被这次改动打开）。
 *
 * 判方向用**手势事件里的当前坐标**减去按下坐标（都是 window 坐标系，px）：此刻手指只走了一个
 * 手势阈值（几 vp），够用来分辨主方向；拿不到坐标时按"竖向"处理 —— 宁可放行滑动。
 *
 * 记账不全（没记到按下时刻或第一次移动）时一律返回 false：这一支同时兜住了"按住标记里残留了
 * 上一次触摸"的情况，锁不会因为残留而把后面的滑动卡死。
 */
export function holdsScroll(event: BaseGestureEvent): boolean {
  if (!MaterialPressState.pressed) {
    return false;
  }
  const downMs: number = MaterialPressState.downMs;
  const moveMs: number = MaterialPressState.moveMs;
  if (downMs === 0 || moveMs === 0) {
    return false;
  }
  if (moveMs - downMs >= MATERIAL_HOLD_MS) {
    return true;
  }
  return !isVerticalDrag(event);
}

/** 这一下拖动是不是**竖向为主**（见 holdsScroll 的第 3 条）。 */
function isVerticalDrag(event: BaseGestureEvent): boolean {
  const fingers: Array<FingerInfo> = event.fingerList;
  if (fingers === undefined || fingers.length === 0) {
    return true;
  }
  const dx: number = Math.abs(fingers[0].globalX - MaterialPressState.downX);
  const dy: number = Math.abs(fingers[0].globalY - MaterialPressState.downY);
  return dy >= dx;
}

/**
 * 吞掉落在按钮上的滑动手势（四象通用）。
 *
 * 手势命中是**最内层优先**，所以给按钮挂一条自己的 PanGesture（默认 5vp 才成立），竞争时
 * 按钮赢：这段滑动只做材质形变。空实现是**故意的** —— 我们只要"占有"这个手势；
 * distance 保持默认（不设 0），否则按下瞬间就成立、点击会被吃掉。
 *
 * 注意：**它是按钮 4-way-lock 的一半**（另一半是外层容器上面的 holdsScroll 否决），
 * 所以不管 holdsScroll 怎么判，这条手势都原样留着 —— 4-way-lock 本身不受影响。
 *
 * 导出给"自绘的材质容器"用（目前是 PostCardPanel 里那条用户资讯栏胶囊）：它和这里几颗按钮
 * 是同一套内容（透明 Toggle + 材质），4-way lock 也得是同一套，不能再各写一份。
 */
export function consumePan(): void {
}

/**
 * 触摸事件 → 更新按住标记（Down 置真，抬起/取消置假），并记下"第一次移动"的时刻。
 *
 * 第一次移动两路都记（这里 + trackScrollTouch）：手势判定发生在 Move 事件处理的**同一次**
 * 分发里，谁先看到都算 —— 只挂一路的话有可能在手势判定之后才轮到它，那一刻读到的还是"没动过"。
 *
 * **所有"材质按钮/材质容器"都挂它**（MaterialIconButton / MaterialLabelButton / 页面里那几个
 * 自绘的材质容器，见 FeedList 的资料行与关注按钮）：只要有一处漏挂，那一处的"按住"就记不全，
 * holdsScroll 会当成滑页面放行。
 */
export function trackMaterialTouch(event: TouchEvent): void {
  if (event.type === TouchType.Down) {
    setMaterialPressLock(true);
    markTouchDown(event);
    return;
  }
  if (event.type === TouchType.Move) {
    markFirstMove();
    return;
  }
  if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
    setMaterialPressLock(false);
  }
}

/**
 * 共享的材质构造：厚度跟设定绑定 + 交互形变 + 光源效果（+ 可选的自动反色）。
 *
 * invert 默认 true（内容区的普通按钮都要它：材质是"透"的，压在白画面上的按钮圆底会变浅，
 * 白图标会糊）。**沉浸式视频的标题区例外** —— 需求要"取消视频沉浸式标题反色效果，包括文字和
 * 沉浸光感"，那里传 false：材质不再跟着背景反色，文字也按主题色走。
 *
 * **只在 `PlatformCap.hasArkMaterial()` 为真时调用**（API ≥ 26）：`uiMaterial` 整个模块都是
 * 26 起才有。挂材质走 SurfaceModifier，那里已经判过能力，不需要各个调用点自己再判。
 *
 * @param thickness 材质厚度档位（设定页里的字符串，见 AppSettings 的 MATERIAL_THICKNESS_*）。
 * @param invert 材质是否跟着背景反色（见上）。
 * @param applyShadow 要不要**材质自带的阴影**（`applyShadow`，默认 true = 全局统一带上）。
 *   官方原文："当该参数为 true 时，材质中的阴影效果固定生效，优先于 shadow 通用属性；
 *   当该参数为 false 时，shadow 通用属性生效，材质的阴影效果不生效。**该参数对支持沉浸式
 *   材质的所有档位的算力设备的显示效果生效**。" —— 所以这一圈阴影是"材质给的"，不随算力档位变。
 *   注意它同时也是"轮廓"的来源：材质底色很透（浅色下实测轨道只有 #FBFBFB），没有这圈阴影时
 *   组件和背景几乎融成一片。
 * @param lightEffect 要不要**光感交互反馈**（触摸时表面那道光）。默认 true；评论面板里那张
 *   帖子卡片传 false —— 官方文档：`lightEffect` 设成 **null** 就是"关闭光感交互反馈"，
 *   所以这里用 null 而不是空对象。
 * @param interactive 要不要**交互形变**（按下/拖动时材质跟着形变）。默认 true（全 app 老观感）；
 *   卡片传 false：需求要"静态玻璃"，贴在那儿不跟着手指动。
 *   两个开关都**默认保持原行为**，只有显式传 false 的调用点（那张卡片）会变。
 */
/**
 * 光感交互反馈的两种取值（见 immersiveMaterial 的 @param lightEffect）。
 *
 * 为什么提成两个常量而不是在函数里写三元：ArkTS 严格模式下 `{}` 这种**无类型对象字面量**
 * 只能放在"有明确目标类型"的位置（构造函数实参就算），塞进三元表达式容易推不出类型。
 * 提出来之后再包一层显式类型，两边都稳。
 */
const LIGHT_EFFECT_ON: uiMaterial.LightEffectOptions = {};
/** 官方文档："If this parameter is set to null, the light sensing feedback effect is disabled"。 */
const LIGHT_EFFECT_OFF: uiMaterial.LightEffectOptions | null = null;

export function immersiveMaterial(thickness: string, invert: boolean = true,
                                  applyShadow: boolean = true,
                                  lightEffect: boolean = true,
                                  interactive: boolean = true): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({
    style: materialStyleFrom(thickness),
    materialColor: ARKUI_MATERIAL_COLOR,
    // 交互形变（按下/拖动时材质跟着形变）；卡片关掉，见 @param interactive。
    interactive: interactive,
    // 光感交互反馈（触摸时表面出现光源流动效果）；null = 关掉（见 @param lightEffect）。
    lightEffect: lightEffect ? LIGHT_EFFECT_ON : LIGHT_EFFECT_OFF,
    // 自动反色：颜色必须走资源接口（见文件头），硬编码颜色不参与。
    colorInvert: invert,
    // 材质自带的投影（默认 true）：见 @param applyShadow 的说明。
    applyShadow: applyShadow
  });
}

/**
 * 把沉浸光感材质挂到 **Select**（设置页那两个下拉）上，并在系统不支持时降级。
 *
 * Select 要同时挂两层材质：按钮自己一层（`systemMaterial`）、展开的菜单一层
 * （`menuSystemMaterial`）——两者是独立的，官方文档里也是分开给的。
 * 两层都显式写 `applyShadow: true`（也就是默认值）：跟全局那套阴影一致（见 SurfaceModifier）。
 * 注意这里的"菜单"是**下拉选项面板**，和需求里例外的"HDS 导航栏菜单按钮"不是一回事。
 * 不支持（API < 26）时给按钮一层低透明度中性底；菜单就用系统默认样式（可见性由系统保证）。
 */
export class SelectSurfaceModifier implements AttributeModifier<SelectAttribute> {
  private readonly thickness: string;
  /**
   * 目标宽度（vp）；**<= 0 表示不设宽度**，保持系统自适应。
   *
   * 为什么要"不设"这一档：想给"换选项时按钮长度变化"做补间就只能自己给 `.width()`，
   * 但 Select 把「文字 + 箭头」靠左排，宽度比内容宽时多出来的空白全堆在右侧（左右留白不一致）。
   * 所以调用方先用一次**不设宽度**的渲染量出系统的占宽，再用"文字宽 + 占宽"算宽度 ——
   * 这样设出来的宽度和系统自适应完全相等，留白不变，同时换选项时宽度有变化、可以被补间。
   */
  private readonly width: number;
  /** 宽度变化的补间时长（毫秒）；<= 0 不补间。 */
  private readonly widthAnimationMs: number;

  constructor(thickness: string, width: number = 0, widthAnimationMs: number = 0) {
    this.thickness = thickness;
    this.width = width;
    this.widthAnimationMs = widthAnimationMs;
  }

  applyNormalAttribute(instance: SelectAttribute): void {
    // 宽度与它的补间**必须写在其它属性之前**：`.animation()` 只覆盖在它之前设置的属性。
    // 整个包一层 try：这段是"锦上添花"的宽度过渡，出问题也不该把页面带崩。
    if (this.width > 0 && Number.isFinite(this.width)) {
      try {
        instance.width(this.width);
        if (this.widthAnimationMs > 0) {
          instance.animation({ duration: this.widthAnimationMs, curve: curves.springMotion() });
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'select width skipped: %{public}s',
          (error as Error).message ?? 'unknown');
      }
    }
    if (PlatformCap.hasArkMaterial()) {
      // 同 SurfaceModifier：材质接口声明有、运行时未必有，兜一层（失败就退成纯色底）。
      try {
        instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: materialStyleFrom(this.thickness),
          materialColor: ARKUI_MATERIAL_COLOR,
          interactive: true,
          lightEffect: {},
          // 全局那套阴影（默认值也是 true，写出来是为了让策略在代码里可见）。
          applyShadow: true
        }));
        instance.menuSystemMaterial(new uiMaterial.ImmersiveMaterial({
          style: materialStyleFrom(this.thickness),
          materialColor: ARKUI_MATERIAL_COLOR,
          interactive: true,
          applyShadow: true
        }));
        return;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'select systemMaterial skipped: %{public}s',
          (error as Error).message ?? 'unknown');
      }
    }
    instance.backgroundColor(FALLBACK_SURFACE);
    instance.backgroundBlurStyle(FALLBACK_BLUR);
  }
}

/** 圆形图标按钮（下载 / 静音 / 更多…）。 */
@Component
export struct MaterialIconButton {
  @Prop symbol: Resource = $r('sys.symbol.more');
  @Prop isOn: boolean = false;
  /**
   * 直径。
   *
   * 名字不叫 size：`size` 与自定义组件基类（CustomComponent）上的同名属性冲突，
   * 编译期会报 "Property 'size' ... is not assignable to the same property in base type"。
   */
  @Prop buttonSize: number = MATERIAL_BUTTON_SIZE;
  @Prop iconSize: number = MATERIAL_ICON_SIZE;
  /**
   * 图标颜色（十六进制字符串）。
   *
   * 空串 = 用系统可反色资源色（跟着材质底色自动反色，推荐）；
   * 需要指定颜色时传具体值进来。
   */
  @Prop tint: string = '';
  /**
   * 是否启用材质的自动反色。
   *
   * 名字不叫 invert：`invert` 同样和自定义组件基类成员冲突（编译期报 not assignable）。
   * 沉浸式视频标题区传 false（需求：取消那里的反色）。
   */
  /**
   * **是否吞掉长按**（默认 false，全 app 行为不变）。
   *
   * 为什么需要：这些按钮是 Toggle + PanGesture，没有长按识别器，长按会继续冒泡到
   * 页面根节点那条长按（Reels 的长按暂停 / 2 倍速），于是按在按钮上也会触发画面手势。
   * 打开后给按钮**自己**挂一个空长按，子节点优先，父节点那条就不会成立。
   *
   * 只能挂在按钮自己这一小块：挂到外层容器会连画面一起吞掉（踩过一次）。
   */
  @Prop swallowLongPress: boolean = false;
  @Prop autoInvert: boolean = true;
  /**
   * 图标要不要带动画。空串 = 静态图标（默认，行为与以前完全一样）。
   *
   *   - `'like'`：心形（变了会弹一下，见 AnimatedIcons.LikeIcon）；
   *   - `'repost'`：循环箭头 + 对勾（转一圈 + 勾一笔画出来，见 AnimatedIcons.RepostIcon）；
   *   - `'save'`：书签（收藏那一刻由小到大弹一下，见 AnimatedIcons.SaveIcon）。
   *
   * 为什么长在材质按钮里：动作区这两颗的**材质底就是按钮自己**，图标只是它里面的内容 ——
   * 在外面再套一层动画组件会把材质和内容拆开（材质跟着 Toggle 的按压走，两者必须在同一个节点里）。
   */
  @Prop animated: string = '';
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 点击回调：**参数是这次点击想要的目标状态**（true = 选中）。 */
  onTap: (on: boolean) => void = (on: boolean): void => {
  };

  /** 上一次真正触发动作的时刻（毫秒）—— 去重用，见 fire()。 */
  private lastFireMs: number = 0;
  /**
   * 这一次触摸**还没被消费**的回调额度（Down 时立起来，第一个回调用掉，见 fire）。
   *
   * 为什么必须有它：父组件把新的 `isOn` 传回来时，Toggle 也会回调 `onChange` ——
   * 那不是用户操作。原来只靠"值相同就忽略 + 600ms 内只算一次"，而**父组件的 prop 更新
   * 可能晚于回调**（此刻 `this.isOn` 还是旧值），于是那次"回声"被当成一次新的点击，
   * 又发一次反向请求 → 状态再变 → 再回声 …… 真机上就是 reels 转发按钮**每 1~3 秒自己
   * 来回转一遍**（日志里 create/delete 交替、停不下来）。
   */
  private pressPending: boolean = false;

  /**
   * 真正把点击转出去（**同一个 Toggle 上挂了 onChange 与 onClick 两个入口**）。
   *
   * 为什么两个都挂：真机实测这种 `Toggle` 点一下**可能回调两次**（内部状态翻转一次、
   * 父组件把新的 isOn 传回来再一次），也可能一次不来。
   * 对"静音"这种动作，回调两次 = 把自己翻回去 —— 用户看到的就是"静音按钮按了没反应 /
   * 偶尔切不动"；一次不来则是"点了完全没反应"。
   *
   * 去重两道：
   *   ① 目标值和当前 `isOn` 相同 → 同一次点击的重入，直接忽略；
   *   ② 600ms 内只算一次（回调晚一帧到的那种也挡住）。
   *
   * @param on 这次点击的目标状态（onClick 那条用 `!isOn` 推出来：点一下就是翻转）。
   */
  private fire(on: boolean): void {
    // **一次按下只认一次回调**：没有新的按下就说明这是父组件更新 isOn 的副作用（见 pressPending）。
    if (!this.pressPending) {
      hilog.debug(DOMAIN, TAG, 'icon echo ignored on=%{public}s isOn=%{public}s',
        `${on}`, `${this.isOn}`);
      return;
    }
    if (on === this.isOn) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastFireMs < 600) {
      return;
    }
    hilog.debug(DOMAIN, TAG, 'icon fire on=%{public}s isOn=%{public}s', `${on}`, `${this.isOn}`);
    this.pressPending = false;
    this.lastFireMs = now;
    this.onTap(on);
  }

  build() {
    Toggle({ type: ToggleType.Button, isOn: this.isOn }) {
      if (this.animated === 'like') {
        // 心形：变了弹一下（颜色自己管：已赞红、未赞走主题色）。
        LikeIcon({
          liked: this.isOn,
          iconSize: this.iconSize,
          activeColor: this.tint.length > 0 ? this.tint : LIKE_ACTIVE_HEX
        })
      } else if (this.animated === 'repost') {
        // 循环箭头转一圈（镜像）+ 对勾一笔画出来。
        RepostIcon({
          reposted: this.isOn,
          iconSize: this.iconSize,
          tint: this.tint
        })
      } else if (this.animated === 'save') {
        // 书签：收藏那一刻由小到大弹一下（reels 页右侧那颗，见 AnimatedIcons.SaveIcon）。
        SaveIcon({
          saved: this.isOn,
          iconSize: this.iconSize,
          tint: this.tint
        })
      } else {
        SymbolGlyph(this.symbol)
          .fontSize(this.iconSize)
          .fontColor([this.tint.length > 0 ? this.tint : $r('sys.color.font_primary')])
      }
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .borderRadius(this.buttonSize / 2)
    .padding(0)
    .backgroundColor(Color.Transparent)
    // 选中态也必须是透明的：Toggle 默认的 selectedColor 是主题强调色，
    // 点一下按钮就整颗变蓝、再点一下才还原（用户报的正是这个）。材质自己会给底色。
    .selectedColor(Color.Transparent)
    // 沉浸光感材质（必须放在其他样式属性**之后**，官方 FAQ：放前面会导致优先级不符预期）。
    // 走 AttributeModifier：低版本设备（API < 26）自动退化成纯色底，见 SurfaceModifier。
    .attributeModifier(new SurfaceModifier(this.thickness, this.autoInvert))
    // 开启时吞掉长按（见 swallowLongPress 的说明）。
    .gesture(this.swallowLongPress ? LongPressGesture({ repeat: false, duration: 300 }) : null)
    .onChange((value: boolean): void => {
      this.fire(value);
    })
    .onClick((): void => {
      // 通用点击不带"新值"，但点一下就是翻转，所以目标值 = 取反（见 fire 的说明）。
      this.fire(!this.isOn);
    })
    // 按住期间把外层滚动/翻页也挡住（见 MaterialPressState 与 consumePan）。
    // 顺带记下"这一次按下"：只有按过才认接下来的回调（见 pressPending / fire）。
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressPending = true;
      }
      trackMaterialTouch(event);
    })
    .gesture(PanGesture().onActionStart(consumePan).onActionUpdate(consumePan))
  }
}

/** 胶囊/圆角文字按钮（关注 / 发消息 / 退出登录…）。 */
@Component
export struct MaterialLabelButton {
  /**
   * 文字：**资源**（多语言）与**纯文本**二选一。
   *
   * 为什么不合成一个 `ResourceStr`：@Prop 对联合类型的支持不稳，所以拆成两个字段，
   * 用哪个由调用方决定（`labelText` 非空时优先）。
   */
  @Prop labelRes: Resource = $r('app.string.action_follow');
  @Prop labelText: string = '';
  @Prop fontSize: number = 13;
  /** 固定宽度：自定义组件实例上写 `.width()` 是不生效的，宽高只能在组件内部定。 */
  @Prop pillWidth: number = MATERIAL_PILL_WIDTH;
  /** 满宽（整行按钮，如登录页/退出登录）。为真时忽略 pillWidth。 */
  @Prop fullWidth: boolean = false;
  /**
   * 按钮高度。
   *
   * 名字不叫 height：struct 成员叫 height 会和通用属性 `.height()` 混在一起读代码时分不清。
   */
  @Prop pillHeight: number = MATERIAL_PILL_HEIGHT;
  /** 圆角；<=0 时按胶囊处理（高度的一半）。 */
  @Prop cornerRadius: number = 0;
  /**
   * 文字的语义色。
   *
   * 材质底是"无彩色玻璃"，按钮的主次只能靠文字颜色区分，所以这里保留强调色/危险色两档。
   */
  @Prop tone: string = TONE_DEFAULT;
  /** 文字颜色（十六进制），非空时覆盖 tone。 */
  @Prop tint: string = '';
  /** 是否启用材质的自动反色（语义同 MaterialIconButton.autoInvert）。 */
  /** 是否吞掉长按（见 MaterialSurface 里 swallowLongPress 的说明）。 */
  @Prop swallowLongPress: boolean = false;
  @Prop autoInvert: boolean = true;
  /**
   * 要不要接 **4-way lock**（`trackMaterialTouch` + `consumePan`，见文件里那两个函数）。
   *
   * 默认 true = 全 app 这颗按钮一直以来的行为（信息流资料行 / 个人页 / 评论面板里那张卡片
   * 的关注按钮都靠它）：手指按在按钮上再拖，页面/照片都不跟着走。
   * **Reels 视频页那颗传 false**（需求："4-way lock 只作用于评论面板里的那张卡片"）——
   * 视频页要恢复成"作者行那颗关注按钮就只是个按钮"：手指落在它上面照样能上下翻视频。
   */
  @Prop lockMaterial: boolean = true;
  /**
   * 要不要**光感交互反馈**（按下/触摸时表面那道光）。
   *
   * 默认 true = 全 app 一直以来的观感。**两步验证那半模态面板里这颗「取消」传 false**
   * （需求："2FA 面板禁用触摸发光"）：面板本身就是系统材质，里面再有点按闪光会很吵，
   * 而且那颗按钮在这一档只是"退出面板"，不需要吸引注意。
   */
  @Prop lightEffect: boolean = true;
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  onTap: () => void = (): void => {
  };

  /** 文字色：tint（自定义） > tone（语义） > 系统可反色资源色。 */
  private labelColor(): ResourceColor {
    if (this.tint.length > 0) {
      return this.tint;
    }
    if (this.tone === TONE_ACCENT) {
      return $r('app.color.accent');
    }
    if (this.tone === TONE_DANGER) {
      return $r('app.color.like_active');
    }
    return $r('sys.color.font_primary');
  }

  /**
   * 上一次真正触发动作的时刻（毫秒）—— 去重用，见 fire()。
   */
  private lastFireMs: number = 0;

  /**
   * 真正把点击转出去（**同一个 Toggle 上挂了 onChange 与 onClick 两个入口**）。
   *
   * 为什么两个都挂：`Toggle({isOn: false})` 传的是**字面量**（这颗按钮不需要选中态，
   * 见 selectedColor 的说明），真机实测这种写法下点一下**不一定会回调 onChange**
   * （点击能被 Toggle 的识别器收下、日志里是 `CLK RACC, T: Toggle`，但回调不来）——
   * 表现就是"回关/关注按钮点了没反应"。onClick 是通用事件，一定会来；
   * 400ms 去重保证两者都来时只算一次。
   */
  private fire(): void {
    const now: number = Date.now();
    if (now - this.lastFireMs < 400) {
      return;
    }
    this.lastFireMs = now;
    this.onTap();
  }

  build() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Text(this.labelText.length > 0 ? this.labelText : this.labelRes)
        .fontSize(this.fontSize)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .fontColor(this.labelColor())
    }
    .width(this.fullWidth ? '100%' : this.pillWidth)
    .height(this.pillHeight)
    .padding(0)
    .borderRadius(this.cornerRadius > 0 ? this.cornerRadius : this.pillHeight / 2)
    .backgroundColor(Color.Transparent)
    // 选中态透明（同 MaterialIconButton：否则点一下整颗变蓝）。
    .selectedColor(Color.Transparent)
    // 沉浸光感材质；低版本设备自动退化成纯色底（见 SurfaceModifier）。
    // 第 5 个参数是光感交互反馈（见 lightEffect 字段的说明）。
    .attributeModifier(new SurfaceModifier(this.thickness, this.autoInvert, true, false,
      this.lightEffect))
    // 开启时吞掉长按（见 swallowLongPress 的说明）。
    .gesture(this.swallowLongPress ? LongPressGesture({ repeat: false, duration: 300 }) : null)
    .onChange((): void => {
      this.fire();
    })
    .onClick((): void => {
      this.fire();
    })
    // 按住期间把外层滚动/翻页也挡住（见 MaterialPressState 与 consumePan）。
    // `lockMaterial` 为假（Reels 视频页那颗关注按钮）时**连"按住"都不记**：那个标记是给
    // 外层滚动容器的 holdsScroll 用的，记了反而会让别处误以为手指按在材质按钮上。
    .onTouch((event: TouchEvent): void => {
      if (this.lockMaterial) {
        trackMaterialTouch(event);
      }
    })
    // 4-way lock 的另一半：占住落在它上面的滑动（见 consumePan）。
    // 关掉时把方向设成 `None` —— 手势**根本不成立**，也就不会和翻页/列表滚动竞争
    // （不能只把回调写成空实现：手势一成立就赢走这一下拖动，照样卡翻页）。
    .gesture(PanGesture(new PanGestureOptions({
      fingers: 1,
      direction: this.lockMaterial ? PanDirection.All : PanDirection.None
    })).onActionStart(consumePan).onActionUpdate(consumePan))
  }
}

/**
 * **沉浸光感的信息胶囊**：一行「图标 + 文字 +（可选）尾部图标」，用于个人页的横幅区
 * （`@ 账号` / 音乐 / 添加 那三个 chips，见 components/ProfilePage）。
 *
 * 为什么不用 MaterialLabelButton 凑：那个只能放文字，而 chips 都是"图标 + 文字"，
 * 音乐那颗右边还要再挂一个播放/暂停图标。材质那一层和别的按钮完全一样
 * （透明 Toggle 承载沉浸光感，见文件头）。
 */
@Component
export struct MaterialChipButton {
  /** 左侧图标（空 = 不画）。 */
  @Prop symbol: Resource = $r('sys.symbol.at');
  /** 文字（资源与纯文本二选一，`labelText` 非空时优先）。 */
  @Prop labelRes: Resource = $r('app.string.story_message_hint');
  @Prop labelText: string = '';
  /** 右侧图标（例如播放 / 暂停；空 = 不画）。 */
  @Prop trailing: Resource | null = null;
  @Prop fontSize: number = 12;
  @Prop chipHeight: number = 28;
  @Prop iconSize: number = 12;
  @Prop tint: string = '';
  /** 是否吞掉长按（见 MaterialSurface 里 swallowLongPress 的说明）。 */
  @Prop swallowLongPress: boolean = false;
  @Prop autoInvert: boolean = true;
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  onTap: () => void = (): void => {
  };

  private lastFireMs: number = 0;

  /** 同 MaterialLabelButton：`onChange` 可能不来，`onClick` 兜底 + 400ms 去重。 */
  private fire(): void {
    const now: number = Date.now();
    if (now - this.lastFireMs < 400) {
      return;
    }
    this.lastFireMs = now;
    this.onTap();
  }

  private inkColor(): ResourceColor {
    return this.tint.length > 0 ? this.tint : $r('sys.color.font_primary');
  }

  build() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row({ space: 6 }) {
        if (this.symbol !== null) {
          SymbolGlyph(this.symbol)
            .fontSize(this.iconSize)
            .fontColor([this.inkColor()])
        }
        Text(this.labelText.length > 0 ? this.labelText : this.labelRes)
          .fontSize(this.fontSize)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.inkColor())
          .constraintSize({ maxWidth: 160 })
        if (this.trailing !== null) {
          SymbolGlyph(this.trailing)
            .fontSize(this.iconSize)
            .fontColor([this.inkColor()])
        }
      }
      .padding({ left: 10, right: 10 })
    }
    .height(this.chipHeight)
    .padding(0)
    .borderRadius(this.chipHeight / 2)
    .backgroundColor(Color.Transparent)
    .selectedColor(Color.Transparent)
    .attributeModifier(new SurfaceModifier(this.thickness, this.autoInvert))
    // 开启时吞掉长按（见 swallowLongPress 的说明）。
    .gesture(this.swallowLongPress ? LongPressGesture({ repeat: false, duration: 300 }) : null)
    .onChange((): void => {
      this.fire();
    })
    .onClick((): void => {
      this.fire();
    })
    .onTouch(trackMaterialTouch)
    .gesture(PanGesture().onActionStart(consumePan).onActionUpdate(consumePan))
  }
}

/**
 * **椭圆图标胶囊**（快拍托盘里那颗「+关注」）。
 *
 * 为什么不能拿 MaterialIconButton 凑：那个的宽高是同一个 `buttonSize`（正方形 → 圆形），
 * 而需求要的是"椭圆形加号按钮"（参考图里是一条横向的小胶囊）—— 宽高必须能分开给。
 * 材质那一层和别的按钮**完全一样**：内容区只有 Toggle/Slider/Select 拿得到沉浸光感
 * （官方《沉浸光感–功耗优化》，见文件头），所以这里仍然是一颗透明 Toggle 垫材质、
 * 图标当它的内容。
 */
@Component
export struct MaterialPillIcon {
  @Prop symbol: Resource = $r('sys.symbol.plus');
  /** 胶囊宽（vp）。 */
  @Prop pillWidth: number = 44;
  /** 胶囊高（vp）；圆角按它的一半算，于是永远是一条完整的胶囊。 */
  @Prop pillHeight: number = 26;
  @Prop iconSize: number = 16;
  /** 图标色；空串 = 系统可反色资源色（跟着材质底色自动反色）。 */
  @Prop tint: string = '';
  /** 是否吞掉长按（见 MaterialSurface 里 swallowLongPress 的说明）。 */
  @Prop swallowLongPress: boolean = false;
  @Prop autoInvert: boolean = true;
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  onTap: () => void = (): void => {
  };

  /** 上一次真正触发动作的时刻（毫秒）—— 去重用，见 fire()。 */
  private lastFireMs: number = 0;

  /**
   * 真正把点击转出去。
   *
   * 和 MaterialLabelButton 同一套理由与参数：`isOn` 是字面量（这颗按钮没有选中态），
   * 真机上 `onChange` 可能不来，所以 `onClick` 也挂上，400ms 去重保证只算一次。
   */
  private fire(): void {
    const now: number = Date.now();
    if (now - this.lastFireMs < 400) {
      return;
    }
    this.lastFireMs = now;
    this.onTap();
  }

  build() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      SymbolGlyph(this.symbol)
        .fontSize(this.iconSize)
        .fontColor([this.tint.length > 0 ? this.tint : $r('sys.color.font_primary')])
    }
    .width(this.pillWidth)
    .height(this.pillHeight)
    .padding(0)
    .borderRadius(this.pillHeight / 2)
    .backgroundColor(Color.Transparent)
    // 选中态透明（同 MaterialIconButton：否则点一下整颗变蓝）。
    .selectedColor(Color.Transparent)
    // 沉浸光感材质；低版本设备自动退化成纯色底（见 SurfaceModifier）。
    .attributeModifier(new SurfaceModifier(this.thickness, this.autoInvert))
    // 开启时吞掉长按（见 swallowLongPress 的说明）。
    .gesture(this.swallowLongPress ? LongPressGesture({ repeat: false, duration: 300 }) : null)
    .onChange((): void => {
      this.fire();
    })
    .onClick((): void => {
      this.fire();
    })
    // 按住期间把外层滚动也挡住（这颗在横向托盘里，见 MaterialPressState 与 consumePan）。
    .onTouch(trackMaterialTouch)
    .gesture(PanGesture().onActionStart(consumePan).onActionUpdate(consumePan))
  }
}
