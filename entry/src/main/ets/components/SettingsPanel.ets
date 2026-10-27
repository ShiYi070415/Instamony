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
  MEDIA_QUALITY_AUTO,
  MEDIA_QUALITY_ORDER,
  SETTING_BAR_HIDE,
  SETTING_IMAGE_QUALITY,
  SETTING_MATERIAL_LEVEL,
  SETTING_MATERIAL_THICKNESS,
  SETTING_VIDEO_QUALITY
} from '../core/AppSettings';
import { MATERIAL_PILL_HEIGHT, MaterialIconButton, SelectSurfaceModifier, SurfaceModifier } from './MaterialSurface';
// 半模态的系统材质（SheetOptions.systemMaterial，API 26+）。
import { curves, LengthMetrics, uiMaterial } from '@kit.ArkUI';
// 应用级代理（设置页的数据与生效逻辑，见 core/AppProxy）。
import { AppProxy, ProxyEntry } from '../core/AppProxy';
import { PlatformCap } from '../core/PlatformCap';
import { StoryDiag } from '../core/StoryDiag';
import { StoryTray } from '../model/Story';
import { NativeStories } from '../core/NativeStories';
import { MobileProbe } from '../core/mobileapi/MobileProbe';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'SettingsPanel';

/** 左右留白（vp）：底部那颗「退出登录」用（它在卡片外面，和卡片外缘对齐）。 */
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
/*
 * **分组卡片**的外观（需求："用圆角卡片：实线 border、透明背景，分类标题在卡片外部"）。
 *
 *   PAGE_PADDING —— 卡片离屏幕左右的距离；
 *   CARD_ROW_PADDING —— 卡片**内部**每一行的左右内缩（两者相加才是文字离屏幕的距离）；
 *   CARD_RADIUS / CARD_BORDER —— 圆角与实线边框粗细。
 * 背景保持透明：本页已经是"墨黑→暗紫（浅色为白→冷灰蓝）"的整页渐变，再填一层底色会把
 * 渐变糊掉，也会让沉浸光感的下拉按钮失去通透感。
 */
const PAGE_PADDING: number = 12;
/**
 * 卡片内部每一行的左右内缩（vp）。
 *
 * 统一到 **8 的倍数**：原来是 14（既不是 8 也不是 4 的倍数），和 PAGE_PADDING=16
 * 相加是 30，视觉上比其它页面的 32 少 2vp，卡片里的文字和列表项会差一点点。
 */
const CARD_ROW_PADDING: number = 16;
/**
 * 卡片圆角（vp）。
 *
 * 统一口径（全 app）：
 *   · **胶囊 / 按钮** = 高度 ÷ 2；
 *   · **卡片** = 16；
 *   · **半模态面板** = 28（系统原生面板自带，我们不覆盖）。
 * 之前在 16/20/12 之间混用，同一屏里几种圆角并排会显得"没对齐"。
 */
const CARD_RADIUS: number = 16;
/** 代理输入框高度（vp；圆角=高/2 走胶囊那一档）。 */
const PROXY_FIELD_HEIGHT: number = 42;
const CARD_BORDER: number = 1;

/**
 * 「管理代理」半模态里的卡片尺寸（需求：圆角 + blur 模糊卡片，卡片之间留间距，单选）。
 *
 * 高度取 52：和设置页里其它可点行的观感接近，又是"卡片"而不是"按钮"那一档；
 * 圆角沿用卡片档 CARD_RADIUS（16），全页圆角只有三档，这里不新造一档。
 */
const PROXY_CARD_HEIGHT: number = 52;
const PROXY_CARD_RADIUS: number = CARD_RADIUS;
/** 卡片之间的间距（vp；需求："每个卡片之间保持距离"）。 */
const PROXY_CARD_GAP: number = 10;
/** 卡片左侧的单选图标尺寸（需求：图标显示在卡片左边）。 */
const PROXY_CARD_ICON: number = 20;
/**
 * 管理页卡片要不要**材质自带的阴影**。
 *
 * 关掉（false）的原因：材质那圈阴影是画在卡片边界**之外**的，而卡片在 List/ListItem 里，
 * 超出裁剪框的那部分会被切掉 —— 用户看到的就是"最上面和最下面的卡片被裁剪"，
 * 加 padding 能缓解但消不掉（ListItem 自己的裁剪框只到卡片矩形）。
 * 关掉之后卡片只剩本体（材质底色 + 模糊 + 圆角），边界清晰、怎么拽都不会被切。
 */
const PROXY_CARD_SHADOW: boolean = false;
/**
 * 列表区最大高度（vp）：超了就内部滚动。
 *
 * 半模态用的是 FIT_CONTENT（高度跟着内容走），代理一多会把底部按钮挤出屏幕 ——
 * 所以列表本身设一个上限，卡片再多也只是它自己滚。
 * 取 420：四到六份代理都能**整屏放下、完全不滚动**（不滚动就不会有视口裁边），
 * 再多的才进内部滚动。
 */
const PROXY_MANAGE_LIST_MAX: number = 420;
/**
 * 列表滚动边界的**渐隐长度**（vp）。
 *
 * 滚动视图的视口必然会裁掉越过边界的子节点（`clip` 是滚动容器的固有行为，padding 只能
 * 保证"静止时"不被裁）。滚动中那一下硬切就用边缘渐隐盖住 —— 观感是"淡出"，不是被切一刀。
 */
const PROXY_FADE_LENGTH: number = 12;
/**
 * 左滑露出的操作**圆形按钮**尺寸（需求："用圆形按钮 + sys.symbol 图标，图标白色"）。
 *
 * 直径 44：卡片高 52，圆形按钮留 4vp 上下余量，看起来是"浮在卡片旁边的一颗圆"；
 * 图标 20 与全 app 的图标档位一致（见 MaterialSurface 的 MATERIAL_ICON_SIZE）。
 */
const PROXY_SWIPE_SIZE: number = 44;
const PROXY_SWIPE_ICON: number = 20;
/** 两颗圆形按钮之间、以及按钮与卡片之间的间距（vp）。 */
const PROXY_SWIPE_GAP: number = 8;
/**
 * 列表上下留白（vp，需求："拽动 listitem 时会被 list 边界裁剪"）。
 *
 * 两版都不够之后取 20：**材质自带的阴影是画在卡片边界之外的**（`applyShadow`），
 * 卡片本体在 List 内部，那圈阴影会越过 List/ListItem 的裁剪框，看起来就是"卡片被切了"。
 * 所以这里两手一起下：留白加大给阴影腾地方（见 PROXY_CARD_SHADOW 的说明）。
 */
const PROXY_MANAGE_LIST_PAD: number = 20;

// ---------------- 下拉按钮的"长度弹性过渡" ----------------

/** 下拉按钮的字体大小（vp；和 Select 的 `.font({ size })` 保持一致，量文字宽度要用它）。 */
const SELECT_FONT_SIZE: number = 15;
/**
 * 下拉按钮上"文字以外"的固定占宽（vp）：右侧箭头 + 左右内边距。
 *
 * Select 是系统组件，量不到它的内部布局，所以这部分按经验值留；多留一点只是宽一点，
 * 少了会把文字裁掉，所以宁可偏大。
 */
const SELECT_CHROME_WIDTH: number = 46;
/** 再补一点余量（vp）：不同字体的字宽略有差异，避免最后一两个字被吞掉。 */
const SELECT_WIDTH_SLACK: number = 8;
/** 长度过渡的时长（毫秒）：弹性曲线配 320ms，观感是"弹一下到位"。 */
const SELECT_WIDTH_SPRING_MS: number = 320;

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
  /** 代理：总开关 / 已保存列表 / 当前选中 / 添加面板草稿。 */
  @State private proxyOn: boolean = false;
  @State private proxyNames: Array<string> = [];
  @State private proxyActive: number = -1;
  /**
   * 下拉按钮上显示的文字（**不要**直接绑 `currentProxyLabel()`）。
   *
   * 系统 Select 在用户点选项后会把按钮文字换成"点中的那一项"，如果 `.value` 传的字符串没变，
   * 它不会重排 —— 点「管理代理 / 添加代理」时按钮上就会残留那个动作词（需求：应该显示
   * "暂无代理"或当前代理名）。绑一个状态、点完再改回去就能压住（见 restoreProxyValueText）。
   */
  @State private proxyValueText: string = '';
  /** 添加 / 编辑面板（同一个半模态：`editingIndex < 0` 是添加，否则是编辑那一份）。 */
  @State private proxySheet: boolean = false;
  /** 正在编辑第几份（-1 = 新增）。 */
  @State private editingIndex: number = -1;
  /** 「管理代理」半模态（从下拉菜单最后一项进入）。 */
  @State private proxyManage: boolean = false;
  /** 管理面板里**草稿**选中的下标：点卡片只改它，点「确定」才真正切过去。 */
  @State private manageDraft: number = -1;
  /** 管理面板里点了「添加代理」：等它**关完**再开添加面板（两个半模态不能同时开）。 */
  private manageWantsAdd: boolean = false;
  /** 管理面板里点了「编辑」：同上，关完再开编辑面板（-1 = 没有）。 */
  private manageEditIndex: number = -1;
  @State private draftName: string = '';
  @State private draftHost: string = '';
  @State private draftPort: string = '';
  @State private draftUser: string = '';
  @State private draftPass: string = '';
  /**
   * 下拉按钮上量过的文字宽度缓存（vp）。
   *
   * 宽度是绑在 `.width()` 上的：换选项时文字变了 → 宽度变 → `.animation(springMotion)`
   * 把这段长度变化补间成"弹性伸缩"（需求："改成按钮长度变化的弹性过渡动画"）。
   * 量文字要走 measureText（px → vp），每帧都量没必要，按文案缓存。
   */
  private measuredWidths: Map<string, number> = new Map();
  /** 点「退出登录」。 */
  onSignOut: () => void = (): void => {
  };
  /**
   * 清晰度改完之后通知宿主（pages/Index 用它顺手刷新一次信息流）。
   *
   * 为什么需要：展示档的地址是**解析那一刻**就定死的（见 core/MediaQuality），改设置不会
   * 把已经拿到的帖子变清晰 —— 得让调用方重新取一次数才生效。用户改完马上想看到效果，
   * 所以这里主动通知一声，宿主下拉刷新一遍即可。
   */
  onQualityChanged: () => void = (): void => {
  };
  /** 沉浸光感的材质等级（@StorageLink：这里改，标题栏/底栏/本页材质一起变）。 */
  @StorageLink(SETTING_MATERIAL_LEVEL) materialLevel: string = MATERIAL_LEVEL_ADAPTIVE;
  /** 材质厚度（@StorageLink：这里改，全工程 ArkUI 材质组件的厚薄一起变）。 */
  @StorageLink(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 底栏行为（@StorageLink：这里切，栏的滚动行为换一套）。 */
  @StorageLink(SETTING_BAR_HIDE) barHideMode: string = BAR_HIDE_SINK;
  /** 图片清晰度（@StorageLink：设定页改，core/MediaQuality 下次解析就按新档位挑地址）。 */
  @StorageLink(SETTING_IMAGE_QUALITY) imageQuality: string = MEDIA_QUALITY_AUTO;
  /** 视频清晰度（同上）。 */
  @StorageLink(SETTING_VIDEO_QUALITY) videoQuality: string = MEDIA_QUALITY_AUTO;
  /**
   * 移动 API 自检的结论（见 core/mobileapi/MobileProbe）。
   *
   * 为什么要在这里显示：启动 6 秒后那次自检的结论**只进日志**，而真机上 chromium 的日志
   * 会把 hilog 冲掉（本项目在网页那条路上已经吃过这个亏）—— 测试者手上也没有 hdc。
   * 所以结论必须能**在 App 里直接看到**：进设置页读一眼，需要发回来就点一下复制。
   * 初值取 `-` 表示"还没跑过"（启动自检没跑或没登录）。
   */
  @State mobileProbeResult: string = MobileProbe.lastSummary();

  /**
   * 进设置页时把已经跑过的那次自检结论捞进来（启动自检是定时跑的，多半这时已经有结果）。
   * 只读一次、不重发请求：要看最新的点那一行。
   */
  aboutToAppear(): void {
    this.mobileProbeResult = MobileProbe.lastSummary();
    // 代理列表/选中/下拉按钮文字：进页面就读一次（不要等 proxySection 的 onAppear，
    // 否则第一帧按钮上的文字是空的）。
    this.refreshProxyNames();
  }

  /**
   * 诊断行的通用外观（左文案 + 右箭头）：和系统设置里"能点进去"的行一致。
   *
   * 为什么这两行必须有（需求："把包发给别人测试获取日志"）：测试者手上**没有 DevEco、没有 hdc**，
   * 沙箱里的文件他们根本看不到 —— 必须由 App 自己把文件送到"能被分享出去"的地方。
   */
  /**
   * **代理设置区**：
   *   · 行 1：启用代理 + 开关（没有代理时打开会先触发添加）
   *   · 行 2：已保存的代理 + 下拉（无数据 → "暂无代理"；选单最后固定「添加代理」，选项用别名）
   *   · 半模态：代理名称 / 主机 / 端口 / 用户名 / 密码 + 「添加」，右上角关闭
   *
   * 材质规范：官方材质的生效范围只有 Toggle / Slider / Select / 弹窗，所以**整行容器用
   * Toggle(Button) 承载材质**（同"退出登录"那颗），下拉用 Select；输入框自身透明、垫中性底。
   */
  @Builder
  proxySection() {
    Column({ space: 12 }) {

      Column() {
        Row() {
          Text($r('app.string.settings_proxy_enable'))
            .fontSize(16)
            .fontColor($r('app.color.primary_text'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.proxyOn })
            .onChange((on: boolean): void => {
              if (!on) {
                this.proxyOn = false;
                AppProxy.setEnabled(false);
                return;
              }
              if (this.proxyNames.length === 0) {
                /*
                 * 还没有任何代理：打开添加面板，并且**先把开关画成"开"**。
                 *
                 * 之前这里直接 return，开关被系统回弹回"关"，用户看到的是"点了又自己关掉"
                 * （像坏了）。现在：画成开 → 面板里填完点"添加"才真正 setEnabled(true)；
                 * 用户取消的话，面板关闭时在 onDisappear 里回成关。
                 */
                this.proxyOn = true;
                this.openProxySheet();
                return;
              }
              this.proxyOn = AppProxy.setEnabled(true);
            })
        }
        .width('100%')
        .height(SIGN_OUT_HEIGHT)
        .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
      }
      .width('100%')

      Column() {
        Row({ space: 12 }) {
          Text($r('app.string.settings_proxy_saved'))
            .fontSize(16)
            .fontColor($r('app.color.primary_text'))
          Blank()
          /*
           * **下拉按钮**：`Select` 的下拉菜单。
           *
           * 选单最后一项固定是"功能入口"，随状态变：
           *   · 一份代理都没有 → 「添加代理」（点了直接开添加面板）；
           *   · 已经有代理     → 「管理代理」（点了开管理面板：编辑 / 删除 / 换选中）。
           * `.selected` 必须夹在下标范围内：选中项只在"已保存的代理"里，从不落在最后那一项上。
           *
           * **`.value` 绑的是自己的一个状态**（`proxyValueText`），不是直接读当前代理：
           * 系统 Select 在用户点选项后会把按钮文字换成一个**点中的选项**，点「管理代理/添加代理」
           * 那一项时按钮上就会显示"管理代理"（需求：这种情况应显示"暂无代理"或当前代理名）。
           * 绑状态之后在 onSelect 里把它改回去即可（见 restoreProxyValueText）。
           */
          Select(this.proxyOptions())
            .selected(this.proxyActive >= 0 && this.proxyActive < this.proxyNames.length
              ? this.proxyActive
              : -1)
            .value(this.proxyValueText)
            .font({ size: SELECT_FONT_SIZE })
            // 选中项样式**必须和本页其它四个下拉完全一致**（需求）：系统默认是主题蓝底白字，
            // 这里统一成「浅白半透底 + 粗体高对比字」，颜色都走资源（明暗两套）。
            .fontColor($r('app.color.primary_text'))
            .menuAlign(MenuAlignType.END, { dx: 0, dy: MENU_OFFSET_Y })
            .selectedOptionBgColor($r('app.color.dropdown_selected_bg'))
            .selectedOptionFont({ size: SELECT_FONT_SIZE, weight: FontWeight.Bold })
            .selectedOptionFontColor($r('app.color.dropdown_selected_text'))
            // 长度弹性过渡：宽度跟着当前选项文字变，换选项时由下面的 .animation 补间（见 selectWidth）。
            .width(this.selectWidth(this.proxyValueText))
            .animation({ duration: SELECT_WIDTH_SPRING_MS, curve: curves.springMotion() })
            .onSelect((index: number, value: string): void => {
              if (index === this.proxyNames.length) {
                // 选单最后一项：没有代理就是「添加代理」，有代理就是「管理代理」。
                if (this.proxyNames.length === 0) {
                  this.openProxySheet();
                } else {
                  this.openProxyManage();
                }
                // 按钮文字立刻改回"当前代理 / 暂无代理"，不留「管理代理」这种动作文案。
                this.restoreProxyValueText();
                return;
              }
              if (AppProxy.select(index)) {
                this.proxyActive = index;
                this.proxyValueText = this.proxyValueLabel();
              }
            })
        }
        .width('100%')
        .height(SIGN_OUT_HEIGHT)
        .padding({ left: CARD_ROW_PADDING, right: 8 })
      }
      .width('100%')
      // 管理面板挂在这一行上（添加/编辑面板挂在外层 Column 上），两个半模态各有各的状态。
      .bindSheet($$this.proxyManage, this.proxyManageSheet(), this.proxyManageOptions())

      // **卡片结尾的描述**（与"诊断"分类同款）：讲清作用范围与生效方式。
      this.groupHint($r('app.string.settings_proxy_hint'))
    }
    .width('100%')
    // 整块用本页统一的卡片边框包裹（需求：和其它设置项一样用 border，不用沉浸光感）。
    .cardStyle()
        /*
     * **半模态外观**：系统原生面板 + 系统沉浸光感材质（见 proxySheetOptions）。
     *
     * 文档（半模态转场 · SheetOptions）里有两档做法：
     *   · `blurStyle`：只给面板加模糊；
     *   · `systemMaterial`（API 26 起）：`uiMaterial.ImmersiveMaterial`，**这才是沉浸光感**，
     *     而且圆角/拖拽条/遮罩/动效仍是原生的 —— 正好是"华为那种 + 光感"。
     * 低版本设备拿不到 systemMaterial，退回厚模糊（观感接近）。
     */
    .bindSheet($$this.proxySheet, this.proxyAddSheet(), this.proxySheetOptions())
    .onAppear((): void => {
      this.refreshProxyNames();
    })
  }

  /** 同上，但一定返回纯文本：Select 的 `.value` 绑状态、宽度计算也要字符串。 */
  private proxyValueLabel(): string {
    const index: number = this.proxyActive;
    if (index >= 0 && index < this.proxyNames.length) {
      return this.proxyNames[index];
    }
    return this.resText($r('app.string.settings_proxy_none'));
  }

  /**
   * 把下拉按钮的文字改回"当前代理 / 暂无代理"。
   *
   * 为什么要绕一圈：系统 Select 在用户点中某一项后，会把按钮上显示的文字换成**那一项**，
   * 而 `.value` 传的还是老字符串时它**不会**重排（属性值没变）。所以先塞一个尾巴
   * （零宽空格，肉眼无差）让属性真的变化一次、把按钮的重绘逼出来，下一帧再设回原值。
   * 于是点「管理代理 / 添加代理」之后，按钮上不会残留这两个动作词。
   */
  private restoreProxyValueText(): void {
    const label: string = this.proxyValueLabel();
    this.proxyValueText = `${label}\u200B`;
    setTimeout((): void => {
      this.proxyValueText = label;
    }, 16);
  }

  /**
   * 下拉选项：已保存代理的别名 + **末尾固定一个功能入口**。
   *
   * 功能入口随状态变（需求）：
   *   · 一份都没保存 → 「添加代理」；
   *   · 已经保存过   → 「管理代理」。
   */
  private proxyOptions(): Array<SelectOption> {
    const out: Array<SelectOption> = [];
    for (let i: number = 0; i < this.proxyNames.length; i++) {
      const one: SelectOption = { value: this.proxyNames[i] };
      out.push(one);
    }
    let trailing: ResourceStr = $r('app.string.settings_proxy_manage_title');
    if (this.proxyNames.length === 0) {
      trailing = $r('app.string.settings_proxy_add');
    }
    const action: SelectOption = { value: trailing };
    out.push(action);
    return out;
  }

  /** 打开「管理代理」面板（下拉菜单最后一项进入）。 */
  private openProxyManage(): void {
    this.refreshProxyNames();
    if (this.proxyNames.length === 0) {
      // 理论上进不来（没代理时最后一项是「添加代理」），留个兜底。
      this.openProxySheet();
      return;
    }
    this.manageDraft = this.proxyActive;
    this.proxyManage = true;
  }

  /**
   * 管理面板最底部那颗「确定」：把草稿选中落实。
   *
   * 只有**真的换了一份**才走 AppProxy.select（它会落盘，开关开着时还会立刻换隧道）；
   * 没选（manageDraft 仍是 -1）就只是关面板。
   */
  private confirmProxyManage(): void {
    const index: number = this.manageDraft;
    if (index >= 0 && index < this.proxyNames.length && index !== this.proxyActive) {
      if (AppProxy.select(index)) {
        this.proxyActive = index;
      }
    }
    this.proxyManage = false;
  }

  /** 管理面板里点了「添加代理」：关掉它，由 onDisappear 接力开添加面板。 */
  private requestAddFromManage(): void {
    this.manageWantsAdd = true;
    this.proxyManage = false;
  }

  /** 管理面板里左滑点了「编辑」：关掉它，由 onDisappear 接力开编辑面板。 */
  private requestEditFromManage(index: number): void {
    this.manageEditIndex = index;
    this.proxyManage = false;
  }

  /**
   * 管理面板里左滑点了「删除」：直接删（系统里这类左滑删除都是立即生效的）。
   *
   * 删完要把草稿下标对齐：删掉的是草稿项就置回"没选"，删在草稿前面就往前挪一位 ——
   * 否则「确定」会把用户选中的那份换成相邻的另一份。
   */
  private deleteProxy(index: number): void {
    if (!AppProxy.remove(index)) {
      return;
    }
    this.refreshProxyNames();
    if (this.manageDraft === index) {
      this.manageDraft = -1;
    } else if (this.manageDraft > index) {
      this.manageDraft -= 1;
    }
    if (this.manageDraft >= this.proxyNames.length) {
      this.manageDraft = this.proxyNames.length > 0 ? this.proxyNames.length - 1 : -1;
    }
    this.toast($r('app.string.settings_proxy_deleted'));
    // 一份都不剩就没得管理了：直接收面板（下拉最后一项也会自己变回「添加代理」）。
    if (this.proxyNames.length === 0) {
      this.proxyManage = false;
    }
  }

  /** 管理面板的外观（和添加面板同一套：系统原生面板 + 沉浸光感材质）。 */
  private proxyManageOptions(): SheetOptions {
    const options: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true
    };
    // HDS 标题（需求："要 hdstitle"）：和添加面板一样交给半模态自带的标题区。
    options.title = { title: $r('app.string.settings_proxy_manage_title') };
    options.onDisappear = (): void => {
      // 关完再接力开另一个半模态（同一页面两个半模态不能同时挂）。
      if (this.manageEditIndex >= 0) {
        const index: number = this.manageEditIndex;
        this.manageEditIndex = -1;
        this.openProxyEdit(index);
        return;
      }
      if (this.manageWantsAdd) {
        this.manageWantsAdd = false;
        this.openProxySheet();
      }
    };
    return this.applySheetLook(options);
  }

  /**
   * 半模态的统一材质外观（两个面板共用一份，别各写一遍）。
   *
   * 见 proxySheetOptions 的说明：`systemMaterial` 才是沉浸光感，低版本退回厚模糊；
   * 开了材质时背景必须透明（文档：不要和 backgroundColor/borderWidth/shadow 一起用）。
   */
  private applySheetLook(options: SheetOptions): SheetOptions {
    if (PlatformCap.hasArkMaterial()) {
      options.systemMaterial = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN
      });
      options.backgroundColor = Color.Transparent;
    } else {
      options.blurStyle = BlurStyle.COMPONENT_THICK;
    }
    return options;
  }

  /**
   * 半模态：**管理代理**（下拉菜单最后一项进入，参考添加面板的样式）。
   *
   * 需求逐条对应：
   *   · HDS 标题 → `proxyManageOptions` 里的 `options.title`；
   *   · 内容用 blur 模糊圆角卡片、卡片之间保持距离 → `proxyManageCard` + List 的 `space`；
   *   · 左滑显示「编辑」（黄底）和「删除」（红底） → `swipeAction` + `proxySwipeActions`；
   *   · 卡片是单选的、图标在卡片左边 → 左侧 `circle` / `checkmark_circle_fill` 单选图标；
   *   · 底部「确定」 → 面板最下面那颗按钮（点了才真正切换）。
   */
  @Builder
  proxyManageSheet() {
    Column({ space: 12 }) {
      // 用 List 而不是 Column：左滑操作只挂在 ListItem 上。列表设上限，FIT_CONTENT 不会把按钮顶出屏幕。
      List({ space: PROXY_CARD_GAP }) {
        ForEach(this.proxyNames, (name: string, index: number) => {
          ListItem() {
            this.proxyManageCard(name, index)
          }
          .swipeAction({
            end: {
              builder: (): void => {
                this.proxySwipeActions(index);
              },
              // 左滑露出的总宽度 = 两颗圆形按钮 + 两个间隙。
              actionAreaDistance: PROXY_SWIPE_SIZE * 2 + PROXY_SWIPE_GAP * 2
            },
            /*
             * **右滑也要有弹性**（需求："卡片右滑和恢复时新增弹性动画"）：没有 `start` 时右滑
             * 不会露出任何操作区，但 `Spring` 会让卡片跟手做一段弹性位移、松手弹回 ——
             * 手上有反馈、又不会误触发操作。
             * 顺带说明：上一版为了防止"拽动时被 List 边界裁剪"把它设成了 `None`，现在改成
             * Spring 之后靠列表上下的 padding（PROXY_MANAGE_LIST_PAD）留出回弹空间。
             */
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (name: string, index: number): string => `${index}-${name}`)

        // 末尾固定「添加代理」：有代理之后下拉最后一项变成了「管理代理」，
        // 不给一个添加入口就再也加不了第二份了。
        ListItem() {
          this.proxyManageAddCard()
        }
      }
      .width('100%')
      .constraintSize({ maxHeight: PROXY_MANAGE_LIST_MAX })
      // 上下留白：见 PROXY_MANAGE_LIST_PAD —— 静止时第一张/最后一张卡片和它们的阴影不会被切。
      .padding({ top: PROXY_MANAGE_LIST_PAD, bottom: PROXY_MANAGE_LIST_PAD })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      /*
       * 滚动中的边界用**渐隐**代替硬切（见 PROXY_FADE_LENGTH）。
       *
       * 为什么光靠 padding 不够：滚动容器的视口天然会裁掉越过边界的子节点，padding 只解决
       * "静止时"那一条；手指上下拽动让卡片滚出视口时，顶部/底部那一刀还在。渐隐把那一刀
       * 变成"淡出"，观感上是滚出去的，而不是被切掉。
       */
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(PROXY_FADE_LENGTH) })

      // 最底部：确定（和添加面板底部的「添加」同款沉浸光感文字按钮）。
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Text($r('app.string.settings_proxy_confirm'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .height(SIGN_OUT_HEIGHT)
      .padding(0)
      .borderRadius(SIGN_OUT_RADIUS)
      .margin({ top: 20 })
      .attributeModifier(new SurfaceModifier(this.materialThickness, true))
      .backgroundColor(Color.Transparent)
      // 只挂 onClick：Toggle(Button) 的 onChange 在真机上不一定来（见 MaterialSurface 的说明）。
      .onClick((): void => {
        this.confirmProxyManage();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 20 })
  }

  /**
   * 一行代理卡片：**圆角 + blur 模糊卡片**，图标在左、名称在右。
   *
   * 材质只能由 Toggle 承载（官方生效范围，见 MaterialSurface 文件头），所以卡片本体是
   * 一颗透明的 Toggle(Button)，圆角/模糊/材质都由它给；选中态靠左边的单选图标，
   * **不改底色**（材质是"透"的，再垫一层色会发灰）。
   */
  @Builder
  proxyManageCard(name: string, index: number) {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row({ space: 10 }) {
        SymbolGlyph(index === this.manageDraft
          ? $r('sys.symbol.checkmark_circle_fill')
          : $r('sys.symbol.circle'))
          .fontSize(PROXY_CARD_ICON)
          .fontColor([index === this.manageDraft ? $r('app.color.accent') : $r('app.color.secondary_text')])
        Text(name)
          .fontSize(15)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
          .layoutWeight(1)
          .fontColor($r('app.color.primary_text'))
      }
      .width('100%')
      .height(PROXY_CARD_HEIGHT)
      .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
    }
    .width('100%')
    .height(PROXY_CARD_HEIGHT)
    .padding(0)
    .borderRadius(PROXY_CARD_RADIUS)
    .backgroundColor(Color.Transparent)
    .selectedColor(Color.Transparent)
    // 材质自带阴影关掉（见 PROXY_CARD_SHADOW）：超出卡片矩形的那圈会被 List/ListItem 裁掉。
    .attributeModifier(new SurfaceModifier(this.materialThickness, true, PROXY_CARD_SHADOW))
    .onClick((): void => {
      this.manageDraft = index;
    })
  }

  /** 列表末尾的「添加代理」卡片（和条目卡片**同结构同高度**，只是文字用强调色、无单选图标）。 */
  @Builder
  proxyManageAddCard() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row() {
        Text($r('app.string.settings_proxy_add'))
          .fontSize(15)
          .fontColor($r('app.color.accent'))
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(PROXY_CARD_HEIGHT)
      // 和 proxyManageCard 一样的左右内边距，保证两边的盒子完全一致（高度不会差一截）。
      .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
    }
    .width('100%')
    .height(PROXY_CARD_HEIGHT)
    .padding(0)
    .borderRadius(PROXY_CARD_RADIUS)
    .backgroundColor(Color.Transparent)
    .selectedColor(Color.Transparent)
    // 材质自带阴影关掉（见 PROXY_CARD_SHADOW），和上面那些卡片一致。
    .attributeModifier(new SurfaceModifier(this.materialThickness, true, PROXY_CARD_SHADOW))
    .onClick((): void => {
      this.requestAddFromManage();
    })
  }

  /**
   * 左滑露出的两颗按钮：编辑（黄底黑字）+ 删除（红底白字）。
   *
   * 为什么用 `Button` 而不是材质按钮：SlidableItem 的操作区是**独立的一块**，按需求要
   * 明确的色块（黄/红），材质是"透"的、上去反而不黄不红。圆角卡片档（16）和卡片对齐。
   */
  @Builder
  proxySwipeActions(index: number) {
    Row({ space: PROXY_SWIPE_GAP }) {
      // 编辑：圆形黄底 + 白图标。
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(PROXY_SWIPE_ICON)
          .fontColor([Color.White])
      }
      .width(PROXY_SWIPE_SIZE)
      .height(PROXY_SWIPE_SIZE)
      .padding(0)
      .borderRadius(PROXY_SWIPE_SIZE / 2)
      .backgroundColor($r('app.color.proxy_action_edit'))
      // 纯图标按钮要给读屏留个名字（文案资源本来就是给这里用的）。
      .accessibilityText($r('app.string.settings_proxy_edit_action'))
      .onClick((): void => {
        this.requestEditFromManage(index);
      })

      // 删除：圆形红底 + 白图标。
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(PROXY_SWIPE_ICON)
          .fontColor([Color.White])
      }
      .width(PROXY_SWIPE_SIZE)
      .height(PROXY_SWIPE_SIZE)
      .padding(0)
      .borderRadius(PROXY_SWIPE_SIZE / 2)
      .backgroundColor($r('app.color.proxy_action_delete'))
      .accessibilityText($r('app.string.settings_proxy_delete_action'))
      .onClick((): void => {
        this.deleteProxy(index);
      })
    }
    .height(PROXY_CARD_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .padding({ left: PROXY_SWIPE_GAP })
  }

  private refreshProxyNames(): void {
    const list: Array<ProxyEntry> = AppProxy.list();
    const names: Array<string> = [];
    for (let i: number = 0; i < list.length; i++) {
      names.push(list[i].name.length > 0 ? list[i].name : list[i].summary());
    }
    this.proxyNames = names;
    this.proxyActive = AppProxy.activeIndex();
    this.proxyOn = AppProxy.enabled();
    // 下拉按钮上的文字：当前代理名（没有就是"暂无代理"），见 restoreProxyValueText 的说明。
    this.proxyValueText = this.proxyValueLabel();
  }

  /** 打开添加面板（空表单）。 */
  private openProxySheet(): void {
    this.refreshProxyNames();
    this.editingIndex = -1;
    this.draftName = '';
    this.draftHost = '';
    this.draftPort = '';
    this.draftUser = '';
    this.draftPass = '';
    this.proxySheet = true;
  }

  /**
   * 打开编辑面板：把第 index 份代理的字段灌进草稿。
   *
   * 密码是明文存的（`ProxyEntry.password`），所以编辑时能原样回填；
   * 用户不动它就直接保存，不会因为"看不到密码"被悄悄清空。
   */
  private openProxyEdit(index: number): void {
    const list: Array<ProxyEntry> = AppProxy.list();
    if (index < 0 || index >= list.length) {
      return;
    }
    const one: ProxyEntry = list[index];
    this.refreshProxyNames();
    this.editingIndex = index;
    this.draftName = one.name;
    this.draftHost = one.host;
    this.draftPort = one.port > 0 ? `${one.port}` : '';
    this.draftUser = one.username;
    this.draftPass = one.password;
    this.proxySheet = true;
  }

  /** 面板标题：编辑态「编辑代理」，新增态「添加代理」（都走半模态的 HDS 标题）。 */
  private proxySheetTitle(): ResourceStr {
    return this.editingIndex >= 0
      ? $r('app.string.settings_proxy_edit_title')
      : $r('app.string.settings_proxy_add_title');
  }

  /** 底部按钮文案：编辑态「保存」，新增态「添加」。 */
  private proxySubmitLabel(): ResourceStr {
    return this.editingIndex >= 0
      ? $r('app.string.settings_proxy_save')
      : $r('app.string.settings_proxy_add');
  }

  /**
   * 半模态的外观：**系统原生面板 + 系统沉浸光感材质**。
   *
   * 文档（半模态转场 · SheetOptions）：
   *   · `blurStyle`：面板背景模糊强度（默认无模糊）；
   *   · `systemMaterial`（API 26 起）：`uiMaterial.ImmersiveMaterial` —— **这才是"沉浸光感"**，
   *     由系统给面板本体上材质，圆角/拖拽条/遮罩/动效仍是原生的，等于"原生外观 + 光感"。
   *     低版本设备拿不到这个字段，退回 `blurStyle` 的厚模糊，观感接近。
   *
   * 注意：文档明确 systemMaterial 不要和 backgroundColor / borderWidth / shadow 一起用
   * （会被覆盖或显示不符预期），所以开了材质时背景给透明。
   */
  private proxySheetOptions(): SheetOptions {
    const options: SheetOptions = {
      // **高度刚好包住内容**（需求）：FIT_CONTENT 由内容自适应 —— 五个输入 + 添加按钮
      // 全部显示出来，又不会整页铺满（LARGE 那样留一大片空白）。
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true
    };
    /*
     * 面板关掉时把开关回正：用户点了"开"但没添加成功（或直接取消），界面不能一直显示"开"。
     * 添加成功那条路由 submitProxy 里的 setEnabled(true) 落实，这里只做兜底。
     */
    // **标题走 HDS 标题样式**（半模态自带的 title 区域），比自绘 Text 更贴规范。
    // 标题跟着模式走：编辑那一份时是「编辑代理」。
    options.title = { title: this.proxySheetTitle() };
    options.onDisappear = (): void => {
      // 关面板（取消/完成）都要清掉"编辑第几份"，否则下一次点「添加」会变成编辑。
      this.editingIndex = -1;
      this.proxyOn = AppProxy.enabled();
    };
    return this.applySheetLook(options);
  }

  /** 半模态：添加代理（标题 + 右上角关闭 + 交叉排布的文本/输入 + 添加）。 */
  @Builder
  proxyAddSheet() {
    Column({ space: 12 }) {
      // 标题交给半模态自己画（SheetOptions.title，走 HDS 标题样式），这里不再重复。

      this.proxyInput($r('app.string.settings_proxy_name'), this.draftName, 'name',
        $r('app.string.proxy_ph_name'))
      this.proxyInput($r('app.string.settings_proxy_host'), this.draftHost, 'host',
        $r('app.string.proxy_ph_host'))
      this.proxyInput($r('app.string.settings_proxy_port'), this.draftPort, 'port',
        $r('app.string.proxy_ph_port'))
      this.proxyInput($r('app.string.settings_proxy_user'), this.draftUser, 'user',
        $r('app.string.proxy_ph_optional'))
      this.proxyInput($r('app.string.settings_proxy_pass'), this.draftPass, 'pass',
        $r('app.string.proxy_ph_optional'))

      Toggle({ type: ToggleType.Button, isOn: false }) {
        // 编辑态显示「保存」，新增态显示「添加」（标题同理，见 proxySheetTitle）。
        Text(this.proxySubmitLabel())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .height(SIGN_OUT_HEIGHT)
      .padding(0)
      .borderRadius(SIGN_OUT_RADIUS)
      // **和输入区拉开距离**（需求）：最后一个输入框下沿到按钮上沿至少 20vp，
      // 否则按钮像贴着表单（半模态里紧挨着会显得拥挤）。
      .margin({ top: 20 })
      .attributeModifier(new SurfaceModifier(this.materialThickness, true))
      // 取消额外底色（需求）：材质本身就是表面，再垫一层会发灰。
      .backgroundColor(Color.Transparent)
      // 只挂 onClick：Toggle(Button) 的 onChange 在真机上不一定来（见 MaterialSurface 的说明）。
      .onClick((): void => {
        this.submitProxy();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 20 })
  }

  /** 一行输入：标题在上、输入框在下（"文本 / 输入框"交叉排布）。 */
  @Builder
  proxyInput(label: ResourceStr, value: string, which: string, hint: ResourceStr) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
        .textAlign(TextAlign.Start)
      /*
       * **看得见的胶囊**（需求回归）：材质只能由 Toggle 承载（官方生效范围），
       * 所以输入框套在 Toggle(Button) 里、自身透明，胶囊的圆角与材质由外层给；
       * 再补一层很淡的中性底，让它在深/浅色面板上都"立得起来"。
       */
      Toggle({ type: ToggleType.Button, isOn: false }) {
        TextInput({ text: value, placeholder: hint })
          .width('100%')
          .height(42)
          .fontSize(15)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Color.Transparent)
          .onChange((text: string): void => {
          if (which === 'name') {
            this.draftName = text;
          } else if (which === 'host') {
            this.draftHost = text;
          } else if (which === 'port') {
            this.draftPort = text;
          } else if (which === 'user') {
            this.draftUser = text;
            } else {
              this.draftPass = text;
            }
          })
      }
      .width('100%')
      .height(42)
      .padding(0)
      .borderRadius(21)
      .attributeModifier(new SurfaceModifier(this.materialThickness, true))
      .backgroundColor($r('sys.color.comp_background_secondary'))
      .onChange((): void => {
      })
    }
    .width('100%')
  }

  /**
   * 提交：**新增或编辑**（看 `editingIndex`）。
   *
   * 新增：入库 + 打开总开关（保存即生效，不需要重启 App）。
   * 编辑：原地替换，**不动总开关**；改的若是当前选中项且开关开着，AppProxy 会立刻重新应用。
   */
  private submitProxy(): void {
    const entry: ProxyEntry = new ProxyEntry();
    entry.name = this.draftName.trim().length > 0 ? this.draftName.trim() : this.draftHost.trim();
    entry.host = this.draftHost.trim();
    const port: number = Number.parseInt(this.draftPort.trim(), 10);
    entry.port = Number.isNaN(port) ? 0 : port;
    entry.username = this.draftUser.trim();
    entry.password = this.draftPass;
    const editing: number = this.editingIndex;
    if (editing >= 0) {
      if (!AppProxy.update(editing, entry)) {
        return;
      }
      this.editingIndex = -1;
      this.proxySheet = false;
      this.refreshProxyNames();
      return;
    }
    if (!AppProxy.add(entry)) {
      return;
    }
    this.proxySheet = false;
    this.refreshProxyNames();
    this.proxyOn = AppProxy.setEnabled(true);
  }
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
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
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
   * **自检一次快拍取数**（移动端私有接口）。
   *
   * 原来这里跑的是"抓故事页模板 / 读页面媒体"两条网页退路；模板机制退役后改为：
   * 用移动端 `feed/reels_tray/` 拉一次托盘，把条数与失败原因如实报出来。
   */
  private captureStoryTemplateForDiag(): void {
    NativeStories.tray().then((tray: StoryTray | null): void => {
      const count: number = tray === null ? 0 : tray.items.length;
      if (count > 0) {
        this.toast($r('app.string.diag_story_captured'));
        return;
      }
      this.toast($r('app.string.diag_story_capture_failed', NativeStories.lastDetail()));
    }).catch((error: Error): void => {
      this.toast($r('app.string.diag_story_capture_failed', error.message ?? '-'));
    });
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

  /**
   * **跑一次移动 API 自检**（见 core/mobileapi/MobileProbe；需求：换到 instagrapi 那条私有 API 路）。
   *
   * 三发请求：`users/{uid}/info/` → `feed/reels_tray/` → `direct_v2/inbox/`。
   * 这个入口的意义和「抓故事页模板（测试）」一样：**当场**验证"IG 认不认我们这套身份"，
   * 不用等某条业务路径自己踩坑才发现会话不可用。
   *
   * 自检只读、不改状态；异常一律吞掉只报一句，绝不影响设置页本身。
   */
  private runMobileProbe(): void {
    this.mobileProbeResult = MobileProbe.lastSummary();
    this.toast($r('app.string.diag_mobile_running'));
    MobileProbe.run(true).then((ok: number): void => {
      this.mobileProbeResult = MobileProbe.lastSummary();
      this.toast($r('app.string.diag_mobile_done', ok));
    }).catch((error: Error): void => {
      const message: string = error.message ?? '-';
      this.mobileProbeResult = `threw: ${message}`;
      hilog.warn(DOMAIN, TAG, 'mobile probe threw: %{public}s', message);
      this.toast($r('app.string.diag_mobile_failed', message));
    });
  }

  /** 把移动 API 自检结论复制走（和「复制诊断摘要」同一条路：剪贴板不需要权限）。 */
  private copyMobileProbe(): void {
    const text: string = MobileProbe.lastSummary();
    this.mobileProbeResult = text;
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data, (err: BusinessError | undefined) => {
        if (err !== undefined && err !== null) {
          hilog.warn(DOMAIN, TAG, 'mobile probe copy failed: %{public}s', err.message);
          this.toast($r('app.string.diag_export_failed', err.message));
          return;
        }
        this.toast($r('app.string.diag_copied'));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'mobile probe copy threw: %{public}s', (error as Error).message);
      this.toast($r('app.string.diag_export_failed', (error as Error).message));
    }
  }

  /**
   * **分组标题**（需求："分类标题在卡片外部"）。
   *
   * 放在卡片上方、按屏幕左内缩对齐（不跟着卡片内的行再缩一层），字号比正文小一档，
   * 让人一眼分清"这是一组的名字"而不是某一行设置。
   */
  @Builder
  groupHeader(text: ResourceStr) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.secondary_text'))
      .width('100%')
      .padding({ left: PAGE_PADDING + 4, right: PAGE_PADDING + 4, top: 20, bottom: 8 })
  }

  /**
   * 分组脚注（说明文案）：**画在卡片里面**的最后一小段，跟着它的开关走，
   * 而不是在卡片外孤零零地飘着（那是"一堆东西混在一起"的观感来源之一）。
   */
  @Builder
  groupHint(text: ResourceStr) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.secondary_text'))
      .width('100%')
      // 与上面那条分隔线之间留出间距（用户反馈：太贴分割线了）：10vp。
      .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING, top: 10, bottom: 14 })
  }

  /** 卡片内部相邻两行之间的细分隔线（左右与行文字对齐）。 */
  @Builder
  cardDivider() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.divider'))
      .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
  }

  /**
   * 卡片外观（需求："用圆角卡片：实线 border、透明背景"）。
   *
   * `@Styles` 只能写通用属性，所以边框 / 圆角 / 背景这三样放这里；
   * 每个分组的成员行由调用处包成一个 `Column() { … }.cardStyle()`。
   */
  @Styles
  cardStyle() {
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(Color.Transparent)
    .border({ width: CARD_BORDER, color: $r('app.color.divider') })
    /*
     * **不要 clip(true)**：卡片里的下拉按钮是沉浸光感材质，它的阴影/光边画在按钮边界之外，
     * 一裁就没了（信息流资料栏那一行踩过同一个坑，见 FeedList.profileRow）。
     * 卡片本身是透明底 + 实线边，成员行也都带着内缩，不会溢出到圆角外面。
     */
  }

  /**
   * 移动 API 自检结论行：标题 + 结论正文，整行可点（点一下复制）。
   *
   * 正文**从 `this.mobileProbeResult` 内部读**，不按值传参：@Builder 的按值参数不参与状态观察，
   * 传进来的话自检跑完这一行不会重绘（同 fileDeep 那条注释里的教训）。
   */
  @Builder
  mobileProbeRow() {
    Column({ space: 4 }) {
      Text($r('app.string.diag_mobile_result'))
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
      Text(this.mobileProbeResult)
        .fontSize(13)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING, top: 8, bottom: 8 })
    .onClick((): void => {
      this.copyMobileProbe();
    })
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
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
  }

  // ---------------- 下拉按钮的长度弹性过渡 ----------------

  /**
   * 下拉按钮的目标宽度（vp）。
   *
   * 做法：把"当前选项文字"的宽度量出来（精确的 `measureText` 与保守的字宽估算取**较大值**，
   * 量不到时不会把文字裁掉），加上箭头/内边距与余量，绑到 `.width()` 上；换选项时宽度变了，
   * 组件上的 `.animation({ curve: curves.springMotion() })` 就把这段长度变化补间成
   * **弹性伸缩**（需求："改成按钮长度变化的弹性过渡动画，而非重新弹出"）。
   *
   * 为什么要显式给宽度：Select 的宽度本来是跟着文字自动算的，自动算出来的值**不参与**
   * 属性动画（内容驱动的布局变化不会被 `.animation()` 补间），必须自己算出数字给它。
   */
  private selectWidth(label: ResourceStr): number {
    const text: string = this.resText(label);
    const measured: number = this.measureTextWidth(text);
    const estimated: number = this.estimateTextWidth(text, SELECT_FONT_SIZE);
    const body: number = measured > estimated ? measured : estimated;
    return Math.round(body + SELECT_CHROME_WIDTH + SELECT_WIDTH_SLACK);
  }

  /** ResourceStr → 纯文本（宽度计算要用；资源解析失败时返回空串，调用方会退回估算值）。 */
  private resText(value: ResourceStr): string {
    if (typeof value === 'string') {
      return value;
    }
    try {
      return getContext(this).resourceManager.getStringSync((value as Resource).id);
    } catch (error) {
      return '';
    }
  }

  /** 精确量一行文字的宽度（vp）；量不到就是 0，交给估算兜底。 */
  private measureTextWidth(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    const cached: number | undefined = this.measuredWidths.get(text);
    if (cached !== undefined) {
      return cached;
    }
    let width: number = 0;
    try {
      // measureText 挂在 UIContext.getMeasureUtils() 上（API 12+），返回 px；
      // 字号用数字（数字按 fp 处理），和 Select 的 .font({ size }) 对齐。
      const px: number = this.getUIContext().getMeasureUtils()
        .measureText({ textContent: text, fontSize: SELECT_FONT_SIZE });
      width = px2vp(px);
    } catch (error) {
      width = 0;
    }
    this.measuredWidths.set(text, width);
    return width;
  }

  /**
   * 字宽估算（兜底用）：CJK 按 1 个字号宽算，其它（拉丁字母/数字/符号）按 0.55 个字号。
   *
   * 只用来"保底不裁字"：真实宽度取它和 measureText 的较大值，所以偏大一点没关系。
   */
  private estimateTextWidth(text: string, fontSize: number): number {
    let units: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      units += text.charCodeAt(i) >= 0x2E80 ? 1 : 0.55;
    }
    return units * fontSize;
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
        // 长度弹性过渡：宽度跟着当前选项文字变，换选项时由下面的 .animation 补间（见 selectWidth）。
        .width(this.selectWidth(this.thicknessDisplay()))
        .animation({ duration: SELECT_WIDTH_SPRING_MS, curve: curves.springMotion() })
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
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
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
        // 长度弹性过渡：宽度跟着当前选项文字变，换选项时由下面的 .animation 补间（见 selectWidth）。
        .width(this.selectWidth(this.materialDisplay()))
        .animation({ duration: SELECT_WIDTH_SPRING_MS, curve: curves.springMotion() })
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
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
  }

  /**
   * 「图片和视频」板块的两行下拉：**图片质量** / **视频质量**。
   *
   * 需求（用户原话）："媒体分辨率有点糊，新增一个按照网络质量提供不同清晰度的媒体，
   * 在设置中可供调节：'图片和视频'板块，显示'图片质量'和'视频质量'选项，
   * 使用沉静光感下拉按钮，两个选项的下拉菜单分别都是 自适应/省流/高清/原画。"
   *
   * 选项与外观都照抄上面的「材质」那两行（同一个 `SelectSurfaceModifier` = 沉静光感下拉按钮，
   * 同一套菜单对齐与选中样式），只是取值换成 mediaQuality。改完立刻生效：
   * `core/MediaQuality` 每次解析媒体都会读 `AppSettings.imageQualityNow/videoQualityNow`，
   * 下一次取数（下拉刷新 / 切页 / 翻页）就按新档位挑地址。
   */
  @Builder
  imageQualityRow() {
    Row({ space: 12 }) {
      Text($r('app.string.settings_image_quality'))
        .fontSize(15)
        .fontColor($r('app.color.primary_text'))
        .layoutWeight(1)
      Select(this.qualityOptions())
        .selected(this.qualityIndex(this.imageQuality))
        .value(this.qualityDisplay(this.imageQuality))
        .font({ size: 15 })
        // 长度弹性过渡：宽度跟着当前选项文字变，换选项时由下面的 .animation 补间（见 selectWidth）。
        .width(this.selectWidth(this.qualityDisplay(this.imageQuality)))
        .animation({ duration: SELECT_WIDTH_SPRING_MS, curve: curves.springMotion() })
        .fontColor($r('app.color.primary_text'))
        .attributeModifier(new SelectSurfaceModifier(this.materialThickness))
        .menuAlign(MenuAlignType.END, { dx: 0, dy: MENU_OFFSET_Y })
        .selectedOptionBgColor($r('app.color.dropdown_selected_bg'))
        .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
        .selectedOptionFontColor($r('app.color.dropdown_selected_text'))
        .onSelect((index: number, value?: string): void => {
          if (index >= 0 && index < MEDIA_QUALITY_ORDER.length) {
            AppSettings.setImageQuality(MEDIA_QUALITY_ORDER[index]);
            this.onQualityChanged();
          }
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
  }

  /** 「视频质量」那一行（同上，只是写 videoQuality）。 */
  @Builder
  videoQualityRow() {
    Row({ space: 12 }) {
      Text($r('app.string.settings_video_quality'))
        .fontSize(15)
        .fontColor($r('app.color.primary_text'))
        .layoutWeight(1)
      Select(this.qualityOptions())
        .selected(this.qualityIndex(this.videoQuality))
        .value(this.qualityDisplay(this.videoQuality))
        .font({ size: 15 })
        // 长度弹性过渡：宽度跟着当前选项文字变，换选项时由下面的 .animation 补间（见 selectWidth）。
        .width(this.selectWidth(this.qualityDisplay(this.videoQuality)))
        .animation({ duration: SELECT_WIDTH_SPRING_MS, curve: curves.springMotion() })
        .fontColor($r('app.color.primary_text'))
        .attributeModifier(new SelectSurfaceModifier(this.materialThickness))
        .menuAlign(MenuAlignType.END, { dx: 0, dy: MENU_OFFSET_Y })
        .selectedOptionBgColor($r('app.color.dropdown_selected_bg'))
        .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
        .selectedOptionFontColor($r('app.color.dropdown_selected_text'))
        .onSelect((index: number, value?: string): void => {
          if (index >= 0 && index < MEDIA_QUALITY_ORDER.length) {
            AppSettings.setVideoQuality(MEDIA_QUALITY_ORDER[index]);
            this.onQualityChanged();
          }
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: CARD_ROW_PADDING, right: CARD_ROW_PADDING })
  }

  /** 清晰度下拉的四项（顺序必须与 MEDIA_QUALITY_ORDER 一致）。 */
  private qualityOptions(): SelectOption[] {
    return [
      { value: $r('app.string.settings_quality_auto') },
      { value: $r('app.string.settings_quality_saver') },
      { value: $r('app.string.settings_quality_high') },
      { value: $r('app.string.settings_quality_original') }
    ];
  }

  /** 当前档位在下拉里的下标（读到没见过的值时退回第一项 = 自适应）。 */
  private qualityIndex(quality: string): number {
    for (let i: number = 0; i < MEDIA_QUALITY_ORDER.length; i++) {
      if (MEDIA_QUALITY_ORDER[i] === quality) {
        return i;
      }
    }
    return 0;
  }

  /** 当前档位的显示文案（下拉按钮收起时显示的就是它）。 */
  private qualityDisplay(quality: string): ResourceStr {
    const index: number = this.qualityIndex(quality);
    if (index === 1) {
      return $r('app.string.settings_quality_saver');
    }
    if (index === 2) {
      return $r('app.string.settings_quality_high');
    }
    if (index === 3) {
      return $r('app.string.settings_quality_original');
    }
    return $r('app.string.settings_quality_auto');
  }

  /** 厚度下拉里的五项（顺序必须与 MATERIAL_THICKNESS_ORDER 一致）。 */  private thicknessOptions(): SelectOption[] {
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
      // **两组入口按设备能力显示**（需求：不支持时隐藏）：
      //   · 「底栏」那组（原生隐藏动画）依赖 HDS 的 `barFloatingStyle`（6.1.0(23) 起）；
      //   · 「外观」那组（材质厚度 / 材质等级）依赖沉浸光感材质（HDS 23 起、ArkUI 26 起）。
      // 低版本设备上这些开关改了也没有任何效果，留着只会让用户以为"坏了"。
      //
      // 版式（需求）：**分类标题在卡片外面** + 每组一张**圆角实线卡片、透明背景**
      // （见 cardStyle / groupHeader）。一张卡片 = 一个 ListItem，卡片内的行用细分隔线分开，
      // 这样列表不会再出现"标题、行、脚注各占一项、彼此混在一起"的观感。
      if (this.barOptionsSupported()) {
        ListItem() {
          this.groupHeader($r('app.string.settings_group_bar'))
        }
        ListItem() {
          Column({ space: 0 }) {
            this.nativeAnimationRow()
            this.cardDivider()
            this.groupHint($r('app.string.settings_bar_native_animation_hint'))
          }
          .cardStyle()
        }
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
      }

      /*
       * 「图片和视频」：清晰度两行（图片质量 / 视频质量），四档
       * 自适应 / 省流 / 高清 / 原画。这一组不依赖设备能力（纯取数策略），所以**恒定显示**。
       */
      ListItem() {
        this.groupHeader($r('app.string.settings_group_media'))
      }
      ListItem() {
        Column({ space: 0 }) {
          this.imageQualityRow()
          this.cardDivider()
          this.videoQualityRow()
          this.cardDivider()
          this.groupHint($r('app.string.settings_media_quality_hint'))
        }
        .cardStyle()
      }
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

      if (this.materialOptionsSupported()) {
        ListItem() {
          this.groupHeader($r('app.string.settings_group_appearance'))
        }
        ListItem() {
          Column({ space: 0 }) {
            this.thicknessRow()
            this.cardDivider()
            this.materialRow()
            this.cardDivider()
            this.groupHint($r('app.string.settings_material_hint'))
          }
          .cardStyle()
        }
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
      }

      if (!this.barOptionsSupported() || !this.materialOptionsSupported()) {
        // 两组都被隐藏时给一句说明，免得页面看着"缺了一块"却不知道为什么。
        ListItem() {
          Text($r('app.string.settings_unsupported_hint'))
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .width('100%')
            .padding({ left: PAGE_PADDING + CARD_ROW_PADDING, right: PAGE_PADDING + CARD_ROW_PADDING,
              top: 10, bottom: 2 })
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
        this.groupHeader($r('app.string.settings_group_proxy'))
      }
      ListItem() {
        this.proxySection()
      }
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

      ListItem() {
        this.groupHeader($r('app.string.settings_group_diag'))
      }
      ListItem() {
        Column({ space: 0 }) {
          this.actionRow($r('app.string.settings_export_diag'), (): void => {
            this.exportDiag();
          })
          this.cardDivider()
          this.actionRow($r('app.string.settings_copy_diag'), (): void => {
            this.copyDiag();
          })
          this.cardDivider()
          /*
           * **抓一次"故事页"的模板**（诊断 + 手动救急）。
           *
           * 为什么要有这个入口：`reels_media` 那条私有 REST 在部分会话上被 IG 回 500，
           * 我们改走"网页自己那条快拍查询"（见 NativeStories.storyViaTemplate）—— 而那条路
           * 只有在 REST 失败时才会自己触发。这个按钮让人**当场**试一次：抓到了就说明这条路可用
           * （之后快拍就能开），抓不到也能立刻看到失败原因，不用等复现。
           */
          this.actionRow($r('app.string.settings_capture_story'), (): void => {
            this.captureStoryTemplateForDiag();
          })
          this.cardDivider()
          /*
           * **跑一次移动 API 自检**（新路径：instagrapi 那套私有移动 API，见 core/mobileapi）。
           *
           * 和上一行同源：网页那条路被 IG 按来源拒（reels_media 回 500 / challenge）之后，
           * 我们在试"复用同一个 Cookie 罐、改用移动端私有 API"。这条链路的失败点很多
           * （会话读不到、claim 不对、challenge、限流），所以给一个当场能跑的入口：
           * 结论直接显示在下面那行，不依赖 hdc 也不依赖 hilog。
           */
          this.actionRow($r('app.string.settings_run_mobile_probe'), (): void => {
            this.runMobileProbe();
          })
          this.cardDivider()
          this.mobileProbeRow()
          this.cardDivider()
          this.groupHint($r('app.string.settings_diag_hint'))
        }
        .cardStyle()
      }
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

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
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 28, bottom: 24 })
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
