/*
 * 「我的」标题栏那颗**账号下拉按钮**（多账号登录的入口）。
 *
 * ## 长什么样（需求原文）
 *   · 标题栏**置中**一颗按钮：左边当前账号的头像，右边账号名（例：`xingli_415`），末尾一个小箭头；
 *   · 点它弹出选单：**有其他账号**就逐个列出（头像 + 账号名），点一个切过去；
 *     没有其他账号就只显示一栏「新增账号」（头像位是加号图标）；
 *   · 整体要**沉浸光感**。
 *
 * ## 沉浸光感怎么落
 *   · 按钮本体：`ToggleType.Button` + `SurfaceModifier`（和全 app 其它胶囊按钮同一套，
 *     见 components/MaterialSurface 的文件头：内容区里材质只有 Toggle/Slider/Select 与弹窗类生效）。
 *     它待的地方是 HDS 标题栏的 `stackBuilder`（标题那一块），实测材质在这里是生效的
 *     （Reels 那条分段按钮就在同一区域，见 pages/Index.shellTitleContent）。
 *   · 选单：**不自己铺底色**，交给系统 Menu 那一层材质（官方教材里 Menu 属于"弹窗类"，
 *     沉浸光感全页面生效）；我们只画内容，于是玻璃底下透出来的就是它背后的画面。
 *     这也顺带满足"避免材质嵌套"那条限制（见 ProfileSegmentBar.inTitleBar 的教训）。
 *
 * ## 为什么头像用 `Image`
 * 头像是网络图（IG 的 CDN 地址）；没有地址时退回应用图标（`app.media.startIcon`），
 * 不为"加载失败"再单独造一张占位图。
 */

import { SurfaceModifier } from './MaterialSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { AccountEntry } from '../core/AccountBook';

/**
 * 这颗按钮读的三份数据走 **AppStorage**（而不是构造参数）。
 *
 * 为什么：它住在 HDS 标题栏的 `stackBuilder` 里 —— 那是**原生组件**回调我们一次 builder。
 * 实测（2026-10-23）：账号名/头像是异步到手的（「我的」头部要 2~5 秒），届时 Index 的
 * `@State` 变了、`build` 也重跑了，但标题栏并不会重新回调那个 builder —— 表现就是
 * **按钮上有头像、没有名字**，而且一直不补。
 * 走 AppStorage + `@StorageLink` 之后，值一变按钮**自己**就重画，不依赖标题栏是否再回调。
 */
export const ACCOUNT_TITLE_NAME: string = 'account_title_name';
export const ACCOUNT_TITLE_AVATAR: string = 'account_title_avatar';
export const ACCOUNT_OTHERS: string = 'account_others';

/** 胶囊高度（比标题栏里其它胶囊矮一点，才不会把那一行顶满）。 */
const CHIP_H: number = 36;
/** 胶囊里的头像直径。 */
const CHIP_AVATAR: number = 24;
/** 选单里那一行的头像直径（比胶囊里大一点，方便一眼认出是谁）。 */
const ROW_AVATAR: number = 32;
/** 选单宽度。 */
const MENU_W: number = 196;
/** 选单里一行的高度。 */
const ROW_H: number = 48;

@Component
export struct AccountSwitcher {
  /** 当前账号名（空 = 还没拿到，按钮只显示头像）。 */
  @StorageLink(ACCOUNT_TITLE_NAME) username: string = '';
  /** 当前账号头像地址（空 = 用应用图标）。 */
  @StorageLink(ACCOUNT_TITLE_AVATAR) avatarUrl: string = '';
  /** **其他**账号（已排除当前这个；空 = 只显示「新增账号」）。 */
  @StorageLink(ACCOUNT_OTHERS) accounts: Array<AccountEntry> = [];
  /** 材质厚薄（跟设定页联动）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 选中了另一个账号。 */
  onSwitch: (userId: string) => void = (userId: string): void => {
  };
  /** 点了「新增账号」。 */
  onAdd: () => void = (): void => {
  };

  /** 头像：有地址就画图，没有就用应用图标兜底。 */
  @Builder
  avatar(url: string, size: number) {
    Image(url.length > 0 ? url : $r('app.media.startIcon'))
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .objectFit(ImageFit.Cover)
      .draggable(false)
      .border({ width: 0.5, color: $r('app.color.divider') })
  }

  /** 选单里的一行：头像 + 账号名。 */
  @Builder
  accountRow(entry: AccountEntry) {
    Row({ space: 10 }) {
      this.avatar(entry.avatarUrl, ROW_AVATAR)
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
      this.onSwitch(entry.userId);
    })
  }

  /** 选单最后那一行「新增账号」：头像位是加号图标（需求）。 */
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

  /** 选单内容（系统 Menu 承载，见文件头）。 */
  @Builder
  accountMenu() {
    Column({ space: 2 }) {
      ForEach(this.accounts, (one: AccountEntry): void => {
        this.accountRow(one);
      }, (one: AccountEntry): string => `acct-${one.userId}`)
      this.addRow()
    }
    .width(MENU_W)
    .padding(6)
  }

  build() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row({ space: 8 }) {
        this.avatar(this.avatarUrl, CHIP_AVATAR)
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
    // 点它弹选单：系统 Menu（弹窗类）自带那层材质，内容透明就透出它来。
    .bindMenu(this.accountMenu(), { placement: Placement.Bottom })
  }
}
