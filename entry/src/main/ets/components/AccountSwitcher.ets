/*
 * 「我的」标题栏那颗**账号下拉按钮**（多账号登录的入口）。
 *
 * ## 按钮：自绘胶囊（头像 + 账号名 + 小箭头）—— 需求"改回上一版"
 * 为什么不用设定页那个 `Select`：`Select` 的收起态只能显示**文字**，带不出头像，
 * 而需求要的是"按钮上显示当前用户的头像和账号名"（例：`xingli_415`）。
 * 所以按钮仍走自绘：`ToggleType.Button` + `SurfaceModifier`（沉浸光感，和全 app 其它胶囊
 * 同一套；内容区里材质只有 Toggle/Slider/Select 与弹窗类生效，见 components/MaterialSurface）。
 * 它待在 HDS 标题栏的 `stackBuilder`（标题那一块），材质在这块是生效的（Reels 分段按钮同区）。
 *
 * ## 选单：系统 Menu 承载，内容自己画
 *   · **第一行永远是当前账号**：头像 + 账号名 + 右边一颗**实心圆勾**（表示"就在这个号上"），
 *     点它**不做任何事**（需求："点击无反应就行"）；
 *   · 之后是其他账号（头像 + 账号名），点一个切过去；
 *   · 最后一行「新增账号」（头像位是加号图标）。
 * 菜单的玻璃底交给系统 Menu 那一层材质（官方把 Menu 归为"弹窗类"，沉浸光感全页面生效），
 * 内容不铺底色就透出它来 —— 也满足"避免材质嵌套"那条限制。
 *
 * ## 数据为什么走 AppStorage
 * 这颗按钮住在 HDS 标题栏的 `stackBuilder` 里 —— 那是**原生组件**回调我们一次 builder。
 * 实测（2026-10-23）：账号名/头像是异步到手的（「我的」头部要 2~5 秒），届时 Index 的
 * `@State` 变了、`build` 也重跑了，但标题栏并不会重新回调那个 builder —— 表现就是
 * **按钮上一直没有名字**且不补。走 AppStorage + `@StorageLink` 之后，值一变按钮**自己**就重画。
 */

import { SurfaceModifier } from './MaterialSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { AccountEntry } from '../core/AccountBook';

/** 按钮/选单读的三份数据（由 pages/Index 写，见文件头）。 */
export const ACCOUNT_TITLE_NAME: string = 'account_title_name';
export const ACCOUNT_TITLE_AVATAR: string = 'account_title_avatar';
export const ACCOUNT_OTHERS: string = 'account_others';

/** 胶囊高度（比标题栏里其它胶囊矮一点，才不会把那一行顶满）。 */
const CHIP_H: number = 36;
/** 胶囊里的头像直径。 */
const CHIP_AVATAR: number = 24;
/** 选单里每一行的头像直径。 */
const ROW_AVATAR: number = 32;
/** 选单宽度。 */
const MENU_W: number = 208;
/** 选单里一行的高度。 */
const ROW_H: number = 48;

@Component
export struct AccountSwitcher {
  /** 当前账号名（空 = 还没拿到，按钮只显示头像）。 */
  @StorageLink(ACCOUNT_TITLE_NAME) username: string = '';
  /** 当前账号头像地址（空 = 用应用图标）。 */
  @StorageLink(ACCOUNT_TITLE_AVATAR) avatarUrl: string = '';
  /** **其他**账号（已排除当前这个）。 */
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

  /**
   * 选单第一行：**当前账号**（头像 + 账号名 + 右边实心圆勾）。
   *
   * 点它什么都不做 —— 需求原话："点击无反应就行"。所以这一行**不挂 onClick**，
   * 也就不会切账号（菜单会不会自己收起由系统 Menu 决定，我们不管）。
   */
  @Builder
  currentRow() {
    Row({ space: 10 }) {
      this.avatar(this.avatarUrl, ROW_AVATAR)
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

  /** 其他账号那一行：头像 + 账号名，点一下切过去。 */
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

  /** 选单内容：当前账号 → 其他账号 → 新增账号（见文件头）。 */
  @Builder
  accountMenu() {
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
