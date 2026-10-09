/*
 * 「设定」页面的内容（装在 NavDestination 里，见 pages/Index.ets 的 destinationBuilder）。
 *
 * 结构（标题栏由 HdsNavDestination 提供，正文是一个 List）：
 *   底栏
 *     · 原生隐藏动画                      —— **开关**（关 = 上滑时下沉收缩，默认；开 = 系统隐藏动画）
 *   沉浸光感
 *     · 材质等级                          —— **下拉按钮**（自适应 / 精美 / 轻柔 / 流畅）
 *   （最后一项）退出登录                    —— 大圆角按钮、红字
 *
 * 控件怎么选（本项目约定）：
 *   - **多选项单选**用下拉（Select）：选项多、占地方，点开选一个；
 *   - **二元行为切换**用开关（Toggle）：一眼看出当前是开是关。
 *   所以材质等级（四选一）是下拉，底栏行为（下沉收缩 / 系统隐藏动画）是开关。
 *
 * 下拉这里用的是**系统 Select**：按钮外观、弹出面板的位置与动效全部由系统负责。
 * 按钮的"光边 + 阴影"来自它自带的**沉浸光感材质**（官方「组件适配沉浸光感 / 下拉按钮」：
 * 应用级 ENABLE 下，下拉按钮默认 ULTRA_THIN 且默认开启交互形变与光感交互反馈，
 * 下拉菜单默认 THICK）——所以这里**不能**再给按钮设不透明底色/模糊：官方常见问题写明
 * 背景色会盖在材质层之上把光边挡掉。按钮和菜单的材质这里按组件级接口显式再写一遍。
 *
 * 菜单弹出位置：`menuAlign` 就是"下拉按钮与下拉菜单间的对齐方式"（默认 START/0,0），
 * 这里取 END 让菜单右缘与按钮右缘对齐（按钮贴着屏幕右边，这样不会把菜单顶出屏幕外）。
 *
 * 所有偏好都写进 AppSettings（AppStorage + preferences），改完立刻生效、下次启动还在。
 */

import {
  AppSettings,
  BAR_HIDE_SINK,
  BAR_HIDE_SYSTEM,
  MATERIAL_LEVEL_ADAPTIVE,
  MATERIAL_LEVEL_EXQUISITE,
  MATERIAL_LEVEL_GENTLE,
  MATERIAL_LEVEL_SMOOTH,
  MATERIAL_THICKNESS_REGULAR,
  MATERIAL_THICKNESS_THICK,
  MATERIAL_THICKNESS_THIN,
  MATERIAL_THICKNESS_ULTRA_THICK,
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_BAR_HIDE,
  SETTING_MATERIAL_LEVEL,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';
import { MATERIAL_PILL_HEIGHT, SelectSurfaceModifier, SurfaceModifier } from './MaterialSurface';
import { PlatformCap } from '../core/PlatformCap';
import { StoryDiag } from '../core/StoryDiag';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SettingsPanel';

/** 左右留白（vp）：列表行与底部按钮共用，两边才会对齐。 */
const SIDE_PADDING: number = 16;
/** 行高（vp）：和系统设置项一致，点起来不局促。 */
const ROW_HEIGHT: number = 54;
/** 列表内容的顶部内缩（vp）：让出 MINI 标题栏（和通知页同一套做法）。 */
const LIST_TOP_OFFSET: number = 94;
/** 退出登录按钮的高度（vp）与圆角（vp）：高度跟全 app 按钮统一（见 MaterialSurface）。 */
const SIGN_OUT_HEIGHT: number = MATERIAL_PILL_HEIGHT;
const SIGN_OUT_RADIUS: number = SIGN_OUT_HEIGHT / 2;
/** 下拉菜单相对按钮的垂直偏移（vp）：留一点缝，别和按钮粘在一起。 */
const MENU_OFFSET_Y: number = 6;

/**
 * 下拉里四档的**顺序**（也是下标 → 取值 的映射表）。
 *
 * 和 materialOptions() 里的资源一一对应：下拉回调只给下标，靠这张表换回设置值。
 * 顺序按"推荐的在最前、越往下越省电"排，和官方档位表的观感一致。
 */
const MATERIAL_LEVEL_ORDER: string[] = [
  MATERIAL_LEVEL_ADAPTIVE,
  MATERIAL_LEVEL_EXQUISITE,
  MATERIAL_LEVEL_GENTLE,
  MATERIAL_LEVEL_SMOOTH
];

/** 材质厚度的**顺序**（下标 → 取值）：由薄到厚，和官方 ImmersiveStyle 枚举顺序一致。 */
const MATERIAL_THICKNESS_ORDER: string[] = [
  MATERIAL_THICKNESS_ULTRA_THIN,
  MATERIAL_THICKNESS_THIN,
  MATERIAL_THICKNESS_REGULAR,
  MATERIAL_THICKNESS_THICK,
  MATERIAL_THICKNESS_ULTRA_THICK
];

@Component
export struct SettingsPanel {
  /** 点「退出登录」。 */
  onSignOut: () => void = (): void => {
  };
  /** 沉浸光感的材质等级（@StorageLink：这里改，标题栏/底栏/本页材质一起变）。 */
  @StorageLink(SETTING_MATERIAL_LEVEL) materialLevel: string = MATERIAL_LEVEL_ADAPTIVE;
  /** 材质厚度（@StorageLink：这里改，全工程 ArkUI 材质组件的厚薄一起变）。 */
  @StorageLink(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 底栏行为（@StorageLink：这里切，栏的滚动行为换一套）。 */
  @StorageLink(SETTING_BAR_HIDE) barHideMode: string = BAR_HIDE_SINK;

  /**
   * 诊断行的通用外观（左文案 + 右箭头）：和系统设置里"能点进去"的行一致。
   *
   * 为什么这两行必须有（需求："把包发给别人测试获取日志"）：测试者手上**没有 DevEco、没有 hdc**，
   * 沙箱里的文件他们根本看不到 —— 必须由 App 自己把文件送到"能被分享出去"的地方。
   */
  @Builder
  actionRow(label: ResourceStr, action: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.primary_text'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.secondary_text')])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING })
    .onClick((): void => {
      action();
    })
  }

  /** 一行提示（用系统 toast，设置页里没有状态行）。 */
  private toast(text: ResourceStr): void {
    try {
      promptAction.showToast({ message: text, duration: 2000 });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * **导出诊断日志**：让用户自己挑一个位置保存（落在「文件」里），再用微信/邮件发出来。
   *
   * 用 `DocumentViewPicker.save()` 而不是直接写公共目录：**不需要任何存储权限**
   * （本 app 只申请了 INTERNET / GET_NETWORK_INFO），保存位置由系统文件选择器负责 ——
   * 这也是官方推荐的"把应用文件交给用户"的方式。
   */
  private async exportDiag(): Promise<void> {
    const text: string = StoryDiag.exportFull();
    const name: string = StoryDiag.exportFileName();
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.save(options);
      if (uris.length === 0) {
        // 用户取消了：不弹错，什么都不做。
        return;
      }
      const file: fileIo.File = fileIo.openSync(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'diag exported %{public}s len=%{public}d', name, text.length);
      this.toast($r('app.string.diag_exported', name));
    } catch (error) {
      const message: string = (error as BusinessError).message ?? 'export-failed';
      hilog.warn(DOMAIN, TAG, 'diag export failed: %{public}s', message);
      this.toast($r('app.string.diag_export_failed', message));
    }
  }

  /**
   * **复制诊断摘要**：一行都存不了时的兜底（剪贴板不需要任何权限）。
   *
   * 只复制**精简版**（见 StoryDiag.exportBrief）：整份带 142 条托盘形状 + 80 条原始条目，
   * 几十 KB 粘进聊天窗口谁都读不下去。
   */
  private copyDiag(): void {
    const text: string = StoryDiag.exportBrief();
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data, (err: BusinessError | undefined) => {
        if (err !== undefined && err !== null) {
          hilog.warn(DOMAIN, TAG, 'diag copy failed: %{public}s', err.message);
          this.toast($r('app.string.diag_export_failed', err.message));
          return;
        }
        this.toast($r('app.string.diag_copied'));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'diag copy threw: %{public}s', (error as Error).message);
      this.toast($r('app.string.diag_export_failed', (error as Error).message));
    }
  }

  /** 分组标题。 */
  @Builder
  groupHeader(text: ResourceStr) {
    Text(text)
      .fontSize(13)
      .fontColor($r('app.color.secondary_text'))
      .width('100%')
      .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 18, bottom: 6 })
  }

  /** 分组脚注（说明文案）。 */
  @Builder
  groupHint(text: ResourceStr) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.secondary_text'))
      .width('100%')
      .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 8, bottom: 4 })
  }

  /**
   * 开关行：左边文案、右边系统开关。
   *
   * 颜色：**开启是白色轨道 + 深色滑块**（需求），关闭走系统默认的灰轨道 —— 系统在拖动过程中会在
   * 两个颜色之间逐帧插值，所以手指往哪拖、颜色就变到哪，不是松手才跳一下。
   *
   * 浅色模式适配：这两个颜色不能写死。浅色模式下页面底色是白的，白轨道 + 白滑块会整颗看不见，
   * 所以用带明暗两套变体的资源（switch_track_on / switch_knob）：
   *   深色：白轨道 + 黑滑块（需求里的观感）；浅色：黑轨道 + 白滑块（同一套关系的反向），两边都看得清。
   *
   * **状态在 Builder 内部读**（`this.barHideMode`）：@Builder 的按值参数不参与状态观察，
   * 传 `on: this.barHideMode === ...` 进来的话，切完开关这一行不会重绘。
   */
  @Builder
  nativeAnimationRow() {
    Row({ space: 12 }) {
      Text($r('app.string.settings_bar_native_animation'))
        .fontSize(15)
        .fontColor($r('app.color.primary_text'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.barHideMode === BAR_HIDE_SYSTEM })
        .selectedColor($r('app.color.switch_track_on'))
        .switchPointColor($r('app.color.switch_knob'))
        .onChange((value: boolean): void => {
          AppSettings.setBarHideMode(value ? BAR_HIDE_SYSTEM : BAR_HIDE_SINK);
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING })
  }

  /**
   * 「材质」下拉行：选**材质厚度**（全局）。
   *
   * 厚度是 ArkUI 侧唯一能设的材质轴（`ImmersiveStyle`），所以这一项直接喂给所有 ArkUI
   * 材质组件的 `style`（见 materialStyleFrom / materialRow / signOutButton）。
   * 同样是 Select：`selected` 决定展开时的高亮，`value` 是收起时显示的文字。
   */
  @Builder
  thicknessRow() {
    Row({ space: 12 }) {
      Text($r('app.string.settings_material_thickness'))
        .fontSize(15)
        .fontColor($r('app.color.primary_text'))
        .layoutWeight(1)
      Select(this.thicknessOptions())
        .selected(this.thicknessIndex())
        .value(this.thicknessDisplay())
        .font({ size: 15 })
        .fontColor($r('app.color.primary_text'))
        // 按钮/菜单材质的厚薄都取本行选的厚度；颜色统一**透明**（需求：
        // 各材质等级的颜色一致，等级不再改颜色，见 materialRow 的说明）。
        // 走 SelectSurfaceModifier：API < 26 的设备上没有系统材质，它会自动退化成纯色底。
        .attributeModifier(new SelectSurfaceModifier(this.materialThickness))
        .menuAlign(MenuAlignType.END, { dx: 0, dy: MENU_OFFSET_Y })
        .selectedOptionBgColor($r('app.color.dropdown_selected_bg'))
        .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
        .selectedOptionFontColor($r('app.color.dropdown_selected_text'))
        .onSelect((index: number, value?: string): void => {
          if (index >= 0 && index < MATERIAL_THICKNESS_ORDER.length) {
            AppSettings.setMaterialThickness(MATERIAL_THICKNESS_ORDER[index]);
          }
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING })
  }

  /**
   * 「材质等级」下拉行：选**材质等级**（全局）。
   *
   * 等级的作用范围：HDS 组件（标题栏、底部页签）直接吃 `hdsMaterial.MaterialLevel`（四档一一对应）；
   * ArkUI 材质组件这边**颜色统一透明**（需求），所以等级不改变它们的外观 —— 它们的外观由上面
   * 「材质」（厚度）那一行决定。之所以不给 ArkUI 材质赋色：官方只有"厚度"是可设轴，等级是设备
   * 算力档、不可设；用赋色去模拟等级会引入额外的颜色，与"颜色统一透明"冲突。
   *
   * Select 要给两样东西：`selected`（选中第几项，决定展开时的高亮）和 `value`（收起时
   * 显示的文字）。两者都由当前设置值算出来（见 materialIndex / materialDisplay）。
   *
   * 材质/位置/选中样式（官方文档依据见文件头）：
   *   - **不设 backgroundColor**：实色底会盖在材质层之上，把按钮自带的光边材质挡掉
   *     （官方常见问题"背景色或背景模糊遮挡材质效果"）；
   *   - `systemMaterial` / `menuSystemMaterial`：厚薄取「材质」那行，颜色透明；
   *   - `menuAlign(END, {dy})`：菜单贴着按钮右缘往下弹（默认 START 会把菜单往右顶出屏幕）；
   *   - `selectedOptionBgColor` / `selectedOptionFont` / `selectedOptionFontColor`：
   *     选中项低透明度底 + 粗体高对比字。
   */
  @Builder
  materialRow() {
    Row({ space: 12 }) {
      Text($r('app.string.settings_material_level'))
        .fontSize(15)
        .fontColor($r('app.color.primary_text'))
        .layoutWeight(1)
      Select(this.materialOptions())
        .selected(this.materialIndex())
        .value(this.materialDisplay())
        .font({ size: 15 })
        .fontColor($r('app.color.primary_text'))
        // 按钮的光边来自这层材质（别加 backgroundColor，会把它盖住）。
        // 厚薄 = 「材质」那行选的厚度；颜色透明（各等级统一）。
        // 下拉菜单自己的材质（与按钮相互独立）：同样厚度 + 透明色；**点光源不开**（需求）。
        // 两者都交给 SelectSurfaceModifier：不支持系统材质时退化成纯色底（API < 26）。
        .attributeModifier(new SelectSurfaceModifier(this.materialThickness))
        .menuAlign(MenuAlignType.END, { dx: 0, dy: MENU_OFFSET_Y })
        // 选中项：低透明度底 + 粗体高对比文字。**颜色走明暗两套资源**（浅色模式适配）：
        //   深色：白 16% 底 + 白字（需求里的观感）；浅色：黑 8% 底 + 近黑字，否则白底白字看不见。
        .selectedOptionBgColor($r('app.color.dropdown_selected_bg'))
        .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
        .selectedOptionFontColor($r('app.color.dropdown_selected_text'))
        .onSelect((index: number, value?: string): void => {
          if (index >= 0 && index < MATERIAL_LEVEL_ORDER.length) {
            AppSettings.setMaterialLevel(MATERIAL_LEVEL_ORDER[index]);
          }
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING })
  }

  /** 厚度下拉里的五项（顺序必须与 MATERIAL_THICKNESS_ORDER 一致）。 */
  private thicknessOptions(): SelectOption[] {
    return [
      { value: $r('app.string.settings_thickness_ultra_thin') },
      { value: $r('app.string.settings_thickness_thin') },
      { value: $r('app.string.settings_thickness_regular') },
      { value: $r('app.string.settings_thickness_thick') },
      { value: $r('app.string.settings_thickness_ultra_thick') }
    ];
  }

  /** 当前厚度在下拉里的下标（读到没见过的值时退回第一项）。 */
  private thicknessIndex(): number {
    for (let i: number = 0; i < MATERIAL_THICKNESS_ORDER.length; i++) {
      if (MATERIAL_THICKNESS_ORDER[i] === this.materialThickness) {
        return i;
      }
    }
    return 0;
  }

  /** 当前厚度的显示文案（下拉按钮上显示的就是它）。 */
  private thicknessDisplay(): ResourceStr {
    return this.thicknessLabelAt(this.thicknessIndex());
  }

  /** 第 index 档厚度的文案（顺序与 MATERIAL_THICKNESS_ORDER 一一对应）。 */
  private thicknessLabelAt(index: number): ResourceStr {
    if (index === 1) {
      return $r('app.string.settings_thickness_thin');
    }
    if (index === 2) {
      return $r('app.string.settings_thickness_regular');
    }
    if (index === 3) {
      return $r('app.string.settings_thickness_thick');
    }
    if (index === 4) {
      return $r('app.string.settings_thickness_ultra_thick');
    }
    return $r('app.string.settings_thickness_ultra_thin');
  }

  /** 下拉里的四项（顺序必须与 MATERIAL_LEVEL_ORDER 一致）。 */
  private materialOptions(): SelectOption[] {
    return [
      { value: $r('app.string.settings_material_adaptive') },
      { value: $r('app.string.settings_material_exquisite') },
      { value: $r('app.string.settings_material_gentle') },
      { value: $r('app.string.settings_material_smooth') }
    ];
  }

  /** 当前档位在下拉里的下标（读到没见过的值时退回第一项）。 */
  private materialIndex(): number {
    for (let i: number = 0; i < MATERIAL_LEVEL_ORDER.length; i++) {
      if (MATERIAL_LEVEL_ORDER[i] === this.materialLevel) {
        return i;
      }
    }
    return 0;
  }

  /** 当前档位的显示文案（下拉按钮上显示的就是它）。 */
  private materialDisplay(): ResourceStr {
    return this.materialLabelAt(this.materialIndex());
  }

  /** 第 index 档的文案（顺序与 MATERIAL_LEVEL_ORDER 一一对应）。 */
  private materialLabelAt(index: number): ResourceStr {
    if (index === 1) {
      return $r('app.string.settings_material_exquisite');
    }
    if (index === 2) {
      return $r('app.string.settings_material_gentle');
    }
    if (index === 3) {
      return $r('app.string.settings_material_smooth');
    }
    return $r('app.string.settings_material_adaptive');
  }

  /**
   * 「底栏」那一组（原生隐藏动画 / 悬浮页签）能不能用。
   *
   * 它整套都建立在 HDS 的 `barFloatingStyle` 上（6.1.0(23) 起）：低版本设备上栏是普通页签栏，
   * 这个开关改了没有效果，所以整组隐藏（见 core/PlatformCap）。
   */
  private barOptionsSupported(): boolean {
    return PlatformCap.hasHdsMaterial();
  }

  /**
   * 「外观」那一组（材质厚度 / 材质等级）能不能用。
   *
   * 两个开关都只喂给沉浸光感材质：厚度给 ArkUI 材质（26 起），等级给 HDS 材质（23 起）。
   * 任一不支持，这一组就都没有意义 —— 隐藏。
   */
  private materialOptionsSupported(): boolean {
    return PlatformCap.hasHdsMaterial() && PlatformCap.hasArkMaterial();
  }

  build() {
    // 和主页/通知/私信/搜索/我的统一成同一套结构：
    //   顶上垫一层**透明 Stack**（高度 = 标题栏那一段 LIST_TOP_OFFSET）→ 内容整体下移、
    //   避让 HdsNavigation；下面紧接着是列表。
    //   `contentStartOffset` 不再用（那是"只缩内容起点、列表顶边仍贴屏幕顶"的另一套做法，
    //   两者不能叠加）。
    //
    // **整页背景画在根容器上**（见下面 Column 的 linearGradient）：以前渐变只挂在 List 上，
    // 于是标题栏那一段（以及避让用的透明 Stack）背后还是 NavDestination 的默认黑底 ——
    // 页面顶部看着像被裁掉一块（用户报的"设置页面顶部被裁剪"）。通知页也是同一个思路
    // （根容器 background 铺满整页），所以它没有这个问题。
    Column() {
      Stack()
        .width('100%')
        .height(LIST_TOP_OFFSET)

      List() {
      // **两组的入口按设备能力显示**（需求：不支持时隐藏）：
      //   · 「底栏」那组（原生隐藏动画）依赖 HDS 的 `barFloatingStyle`（6.1.0(23) 起）；
      //   · 「外观」那组（材质厚度 / 材质等级）依赖沉浸光感材质（HDS 23 起、ArkUI 26 起）。
      // 低版本设备上这些开关改了也没有任何效果，留着只会让用户以为"坏了"。
      if (this.barOptionsSupported()) {
        ListItem() {
          this.groupHeader($r('app.string.settings_group_bar'))
        }
        ListItem() {
          this.nativeAnimationRow()
        }
        ListItem() {
          this.groupHint($r('app.string.settings_bar_native_animation_hint'))
        }
      }

      if (this.materialOptionsSupported()) {
        ListItem() {
          this.groupHeader($r('app.string.settings_group_appearance'))
        }
        ListItem() {
          this.thicknessRow()
        }
        ListItem() {
          this.materialRow()
        }
        ListItem() {
          this.groupHint($r('app.string.settings_material_hint'))
        }
      }

      if (!this.barOptionsSupported() || !this.materialOptionsSupported()) {
        // 两组都被隐藏时给一句说明，免得页面看着"缺了一块"却不知道为什么。
        ListItem() {
          this.groupHint($r('app.string.settings_unsupported_hint'))
        }
      }

      /*
       * **诊断**（需求："把包发给别人测试获取日志"）。
       *
       * 给测试者的唯一一条路：他们手上没有 DevEco / hdc，沙箱里的文件看不到，
       * 所以这里把文件**交给系统文件选择器**（不需要任何权限）保存到「文件」里，
       * 或者退一步——把精简摘要放进剪贴板，粘到聊天窗口发回来。
       * 内容见 core/StoryDiag：最近 8 次失败的 `detail`/`shape`/逐发轨迹 + 整条托盘的形状与原始条目。
       */
      ListItem() {
        this.groupHeader($r('app.string.settings_group_diag'))
      }
      ListItem() {
        this.actionRow($r('app.string.settings_export_diag'), (): void => {
          this.exportDiag();
        })
      }
      ListItem() {
        this.actionRow($r('app.string.settings_copy_diag'), (): void => {
          this.copyDiag();
        })
      }
      ListItem() {
        this.groupHint($r('app.string.settings_diag_hint'))
      }

      // 退出登录：设置列表的最后一项（跟着列表一起滚），宽度和上面几行对齐（左右各留 SIDE_PADDING）。
      //
      // 沉浸光感按官方「示例4（设置组件材质的光感交互反馈效果）」的写法开：
      //   `style: ULTRA_THIN` + `interactive: true` + `lightEffect: {}`
      //   （示例4 就是这三个参数，挂在标题栏里的几个 Column 上）。
      // 材质颜色给 `$r('sys.color.comp_background_secondary')`：文档「特殊资源值」表里它是
      // 低透明度的中性色（浅色 #19000000 / 深色 #19FFFFFF），既不盖住材质，也不会像"不设颜色"
      // 那样继承出主题蓝（官方："未设置…且未设置材质颜色时，默认生效 Button 主题色的材质样式"）。
      // 应用级开关同样就位：module.json5 的 ohos.arkui.UIMaterial.state=enable，
      // 运行时日志 `material state=1 type=2` = MaterialState.ENABLE + MaterialType.IMMERSIVE。
      //
      // 说明（实测结论）：正文里的 **Button** 只拿到材质的底色，交互形变与光感反馈在该区域
      // 不生效 —— 官方「生效范围」那条限制里，全页面只有弹窗类组件/接口与 Slider、Toggle、Select；
      // 所以这颗按钮改成 **Toggle 承载材质**（`ToggleType.Button` 可以带子组件），
      // 交互形变与光源效果随之在设置页也能用上，和全 app 其它按钮一致（见 MaterialSurface）。
      ListItem() {
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text($r('app.string.sign_out'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.like_active'))
        }
        .width('100%')
        .height(SIGN_OUT_HEIGHT)
        .padding(0)
        .borderRadius(SIGN_OUT_RADIUS)
        // 材质（API < 26 自动退化成纯色底，见 SurfaceModifier）。
        .attributeModifier(new SurfaceModifier(this.materialThickness, true))
        // 半透明中性底写在**材质之后**（官方示例9 的顺序）：两者叠加、背景层级更高。
        // 少了这一句，材质会继承 Button 默认的品牌色底，整颗按钮变成主题蓝
        // （官方 Button 说明："未主动设置背景色…设置系统材质后会自动继承默认的背景色参数"）。
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .onChange((): void => {
          this.onSignOut();
        })
      }
      .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 28, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // **别裁内容**：列表可视区在顶部那层透明 Stack 下面，关掉裁剪后滚动的行才会画到标题栏
      // 底下去（和 FeedList 同一套结构：透明 Stack 避让 + 内容可穿过标题栏）。
      .clip(false)
    }
    .width('100%')
    .height('100%')
    // 背景 = **整页**的纵向渐变（颜色见资源里的 settings_gradient_*）：
    //   深色：#0C0E18（墨黑）→ #1E1633（暗紫），跟红字/品牌蓝都压得住；
    //   浅色：#FFFFFF（白）→ #E8EDF8（冷灰蓝）。
    // 两个端值都是明暗两套资源，系统切深浅色会自动换一套。
    // 挂在根容器（而不是 List）上：标题栏那一段和状态栏那一段也要吃到这个底色，
    // 页面顶部才不会被"裁"成一块黑（见 build 开头的说明）。
    .linearGradient({
      angle: 180,
      colors: [
        [$r('app.color.settings_gradient_top'), 0.0],
        [$r('app.color.settings_gradient_bottom'), 1.0]
      ]
    })
  }
}
