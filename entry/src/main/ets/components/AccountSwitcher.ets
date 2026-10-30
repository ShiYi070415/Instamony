/*
 * 「我的」标题栏那颗**账号下拉按钮**（多账号登录的入口）+ 它的浮层选单。
 *
 * ## 两个组件，一个文件
 *   · `AccountSwitcher`：标题栏那颗**胶囊按钮**（头像 + 账号名 + 小箭头）；
 *   · `AccountMenu`：点开后盖在页面上的**选单浮层**（当前账号 / 其他账号 / 新增账号）。
 *
 * ## 为什么选单不用弹窗（bindMenu / bindPopup）
 * 需求要"选单背景透明、要评论那种沉浸光感材质"。实测两个坑：
 *   ① `bindMenu`：背景是系统菜单画的，改不动；
 *   ② `bindPopup` + 里面垫材质：弹层自己已经是一层材质/背板，内层材质属于**材质嵌套**，
 *      官方明确"同一子树只应在最外层设一次"，嵌套时内层静默失效 —— 结果就是一块不透明底板，
 *      连 `popupColor: Color.Transparent` 也压不掉。
 * 所以选单改成**页面内浮层**：放在 pages/Index 的根 Stack 里（和评论面板同一层、同一个窗口），
 * 背景那块透明 `Toggle` 挂 `SurfaceModifier` 就能真的出材质 —— 和 `components/CommentsPanel`
 * 的背板是同一套做法（内容区里材质只有 Toggle/Slider/Select 与弹窗类生效，只能这么垫）。
 *
 * ## 数据为什么走 AppStorage
 * 按钮住在 HDS 标题栏的 `stackBuilder` 里 —— 那是**原生组件**回调我们一次 builder。
 * 实测（2026-10-23）：账号名/头像是异步到手的（「我的」头部要 2~5 秒），届时 Index 的
 * `@State` 变了、`build` 也重跑了，但标题栏并不会重新回调那个 builder —— 表现就是
 * **按钮上一直没有名字**且不补。走 AppStorage + `@StorageLink` 之后，值一变组件**自己**就重画。
 */

import { SurfaceModifier } from './MaterialSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { AccountEntry } from '../core/AccountBook';
import { curves } from '@kit.ArkUI';

/** 按钮/选单读的三份数据（由 pages/Index 写，见文件头）。 */
export const ACCOUNT_TITLE_NAME: string = 'account_title_name';
export const ACCOUNT_TITLE_AVATAR: string = 'account_title_avatar';
export const ACCOUNT_OTHERS: string = 'account_others';
/**
 * 选单开没开（只给箭头做旋转用）。
 *
 * 选单本身是 Index 那一层的浮层（见下面 AccountMenu 的文件头），但"按钮上的小箭头"
 * 要跟着翻转 —— 而这颗按钮住在 HDS 标题栏里、不随 Index 的状态重画（见文件头），
 * 所以开关状态也走 AppStorage 传下来。
 */
export const ACCOUNT_MENU_OPEN: string = 'account_menu_open';

/** 胶囊高度：**和标题栏里 menus 那几颗按钮一致**（需求）。材质层的 "the" 高度就是 40，见 MaterialSurface 的 MATERIAL_BUTTON_SIZE。 */
const CHIP_H: number = 40;
/** 胶囊里的头像直径。 */
const CHIP_AVATAR: number = 24;
/** 选单里每一行的头像直径。 */
const ROW_AVATAR: number = 32;
/** 选单宽度。 */
const ACCOUNT_MENU_W: number = 208;
/** 选单里一行的高度。 */
const ROW_H: number = 48;
/** 选单的圆角（和评论面板那种卡片一个量级）。 */
const MENU_RADIUS: number = 22;
/**
 * 选单浮层距离屏幕顶端的距离（vp）：**贴着下拉按钮，间隔 10vp**（需求）。
 *
 * 实测数据（模拟器 1280x2832，3.5 px/vp）：胶囊在 `y=164..304`（40vp 高、标题栏内居中），
 * 浮层容器从 37vp 处开始 —— 要让卡片顶边落在 304px + 35px(10vp) = 339px，
 * padding 就得是 (339 - 129) / 3.5 ≈ 60。
 */
const ACCOUNT_MENU_TOP_VP: number = 58;

/** 头像：有地址就画图，没有就用应用图标兜底。 */
@Builder
function accountAvatar(url: string, size: number) {
  Image(url.length > 0 ? url : $r('app.media.startIcon'))
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .objectFit(ImageFit.Cover)
    .draggable(false)
    .border({ width: 0.5, color: $r('app.color.divider') })
}

/** 标题栏上的那颗胶囊按钮。 */
@Component
export struct AccountSwitcher {
  /** 当前账号名（空 = 还没拿到，按钮只显示头像）。 */
  @StorageLink(ACCOUNT_TITLE_NAME) username: string = '';
  /** 当前账号头像地址（空 = 用应用图标）。 */
  @StorageLink(ACCOUNT_TITLE_AVATAR) avatarUrl: string = '';
  /** 材质厚薄（跟设定页联动）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 选单开着没（决定箭头朝哪边）。 */
  @StorageProp(ACCOUNT_MENU_OPEN) menuOpen: boolean = false;
  /** 点了按钮：由 pages/Index 把选单浮层打开（浮层得在页面那一层，见文件头）。 */
  onToggle: () => void = (): void => {
  };

  build() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row({ space: 8 }) {
        accountAvatar(this.avatarUrl, CHIP_AVATAR)
        if (this.username.length > 0) {
          Text(this.username)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 132 })
        }
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([$r('sys.color.font_secondary')])
          /*
           * 展开时箭头翻转 180°（需求："下拉按钮画一下弹出收起动画"）。
           * 用隐式动画：`@StorageProp` 一变这个组件就重画，rotate 的变化按弹簧曲线补间 ——
           * 和选单那一下弹出（Index 里 animateTo 的 springMotion）是同一个手感。
           */
          .rotate({ angle: this.menuOpen ? 180 : 0 })
          .animation({ duration: 300, curve: curves.springMotion(0.5, 0.62) })
      }
      .padding({ left: 6, right: 12 })
    }
    .height(CHIP_H)
    .padding(0)
    .borderRadius(CHIP_H / 2)
    .backgroundColor(Color.Transparent)
    // 选中态透明：否则点一下整颗变蓝（同 MaterialLabelButton）。
    .selectedColor(Color.Transparent)
    // 沉浸光感材质；低版本设备自动降级成「中性底 + 背景模糊」（见 SurfaceModifier）。
    .attributeModifier(new SurfaceModifier(this.materialThickness, false))
    // Toggle 的 onChange 与 onClick 会各来一次，所以这里用 onClick 单入口（见 MaterialLabelButton.fire）。
    .onClick((): void => {
      this.onToggle();
    })
  }
}

/**
 * 选单浮层：**整屏透明遮罩 + 居中的一张玻璃卡片**。
 *
 * 层级由 pages/Index 决定（放在根 Stack 里、zIndex 高于标题栏与底栏）；
 * 这里只画内容：点遮罩空白处关闭。
 */
@Component
export struct AccountMenu {
  /** 当前账号名。 */
  @StorageLink(ACCOUNT_TITLE_NAME) username: string = '';
  /** 当前账号头像。 */
  @StorageLink(ACCOUNT_TITLE_AVATAR) avatarUrl: string = '';
  /** **其他**账号（已排除当前这个）。 */
  @StorageLink(ACCOUNT_OTHERS) accounts: Array<AccountEntry> = [];
  /** 材质厚薄（跟设定页联动）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 点了其他账号。 */
  onPick: (userId: string) => void = (userId: string): void => {
  };
  /** 点了「新增账号」。 */
  onAdd: () => void = (): void => {
  };
  /** 点了遮罩空白处。 */
  onClose: () => void = (): void => {
  };

  /** 选单高度（vp）：材质背板要"100% 高"，得先把高度算出来，100% 高的 Toggle 自己撑不出来。 */
  private menuHeight(): number {
    const rows: number = 2 + this.accounts.length;
    // 分隔线也算一项（Column 的 space 会作用在它两侧）。
    const items: number = rows + 1;
    return rows * ROW_H + (items - 1) * 2 + 6 + 12;
  }

  /** 选单第一行：**当前账号**（头像 + 账号名 + 右边实心圆勾），点了什么都不做。 */
  @Builder
  currentRow() {
    Row({ space: 10 }) {
      accountAvatar(this.avatarUrl, ROW_AVATAR)
      Text(this.username.length > 0 ? this.username : $r('app.string.account_unnamed'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      // 白色实心圆勾：颜色走语义资源（深色下就是白色；浅色下自动变黑，否则白勾压浅底看不清）。
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(18)
        .fontColor([$r('sys.color.font_primary')])
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 10, right: 12 })
    .borderRadius(ROW_H / 2)
  }

  /** 其他账号：头像 + 账号名，点一下切过去。 */
  @Builder
  accountRow(entry: AccountEntry) {
    Row({ space: 10 }) {
      accountAvatar(entry.avatarUrl, ROW_AVATAR)
      Text(entry.username.length > 0 ? entry.username
        : (entry.userId.length > 0 ? entry.userId : $r('app.string.account_unnamed')))
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 10, right: 12 })
    .borderRadius(ROW_H / 2)
    .onClick((): void => {
      this.onPick(entry.userId);
    })
  }

  /** 最后一行「新增账号」：头像位是加号图标（需求）。 */
  @Builder
  addRow() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_primary')])
      }
      .width(ROW_AVATAR)
      .height(ROW_AVATAR)
      .borderRadius(ROW_AVATAR / 2)
      .backgroundColor($r('app.color.field_background'))
      Text($r('app.string.account_add'))
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .layoutWeight(1)
    }
    .width('100%')
    .height(ROW_H)
    .padding({ left: 10, right: 12 })
    .borderRadius(ROW_H / 2)
    .onClick((): void => {
      this.onAdd();
    })
  }

  build() {
    // 整屏透明容器：点空白处关闭（不铺任何底色，底下的页面原样看得见）。
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        /*
         * **材质背板**（需求："选单背景透明、要评论那种沉浸光感"）：
         * 和 components/CommentsPanel 一样 —— 一块透明 Toggle 垫底挂材质、不吃触摸，
         * 内容画在上面。它在本页的根 Stack 里（不是弹窗），所以材质真的生效、也真的能透。
         */
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
        }
        .width('100%')
        .height('100%')
        .padding(0)
        .borderRadius(MENU_RADIUS)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.materialThickness, false))
        .hitTestBehavior(HitTestMode.None)

        Column({ space: 2 }) {
          this.currentRow()
          ForEach(this.accounts, (one: AccountEntry): void => {
            this.accountRow(one);
          }, (one: AccountEntry): string => `acct-${one.userId}`)
          Divider()
            .strokeWidth(0.5)
            .color($r('app.color.divider'))
            .margin({ left: 12, right: 12, top: 2, bottom: 2 })
          this.addRow()
        }
        .width('100%')
        .padding(6)
      }
      .width(ACCOUNT_MENU_W)
      .height(this.menuHeight())
      .borderRadius(MENU_RADIUS)
      // 圆角裁一下：材质背板和内容收进同一个圆角里。
      .clip(true)
      // 卡片自己的点击不关掉浮层（只有空白处关）。
      .onClick((): void => {
      })
    }
    .width('100%')
    .height('100%')
    // 贴着标题栏下面（不是屏幕正中）：顶部留白 = 状态栏 + 标题栏，内容从那里往下排。
    .padding({ top: ACCOUNT_MENU_TOP_VP })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Start)
    .backgroundColor(Color.Transparent)
    .onClick((): void => {
      this.onClose();
    })
    /*
     * **弹出 / 收起的弹性动画**（需求："下拉按钮画一下弹出收起动画，要有弹性动画"）。
     *
     * 做法：整块浮层（遮罩 + 卡片）跟着 `if (accountMenuOpen)` 插入/移除，
     * 由 pages/Index 的 `animateTo(springMotion)` 包住那次状态变化 —— 曲线是阻尼比 < 1 的
     * 弹簧（`curves.springMotion(0.5, 0.62)`），落定时会有一点过冲，就是"弹"的手感。
     * 形变：从**顶部中心**（按钮正下方）缩放 0.86 → 1 + 淡入，再叠一点点向上位移，
     * 看起来像从按钮下沿滑出来；收起时反向。
     */
    .transition(TransitionEffect.opacity(0)
      .combine(TransitionEffect.scale({ x: 0.86, y: 0.86, centerX: '50%', centerY: '0%' }))
      .combine(TransitionEffect.translate({ y: -10 }))
      .animation({ duration: 300, curve: curves.springMotion(0.5, 0.62) }))
  }
}
