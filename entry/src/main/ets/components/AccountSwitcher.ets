/*
 * 「我的」标题栏那颗**账号下拉按钮**（多账号登录的入口）。
 *
 * ## 样式：照抄设定页那套下拉（需求："下拉按钮和选单用设置的那一套样式"）
 * 设定页的「材质 / 材质等级 / 图片质量 / 视频质量」用的都是 `Select` + `SelectSurfaceModifier`
 * （见 components/SettingsPanel 的 thicknessRow / materialRow）。这里一模一样：
 *   · 按钮：`Select` + `new SelectSurfaceModifier(材质厚度)` —— 沉浸光感材质，低版本设备上
 *     这个 modifier 会自动退化成「中性底 + 背景模糊」（见 MaterialSurface）；
 *   · 菜单：`menuAlign(END, { dy })` 贴着按钮右缘往下弹；`selectedOptionBgColor` /
 *     `selectedOptionFont` / `selectedOptionFontColor` 与设定页同一套（选中项低透明度底 +
 *     粗体高对比字）；菜单自己的材质由 `SelectSurfaceModifier.menuSystemMaterial` 给。
 *
 * ## 内容（需求）
 *   · 按钮上显示**当前账号名**（例：`xingli_415`）；
 *   · 下拉里：**其他账号**逐个列出（`SelectOption.icon` 给头像地址，有就显示）；
 *     **没有其他账号**时只有一栏「新增账号」（`symbolIcon` 用加号）。
 *     最后一栏永远是「新增账号」——有其他账号时它排在最后，方便继续加号。
 *
 * ## 数据为什么走 AppStorage
 * 这颗按钮住在 HDS 标题栏的 `stackBuilder` 里 —— 那是**原生组件**回调我们一次 builder。
 * 实测（2026-10-23）：账号名/头像是异步到手的（「我的」头部要 2~5 秒），届时 Index 的
 * `@State` 变了、`build` 也重跑了，但标题栏并不会重新回调那个 builder —— 表现就是
 * **按钮上一直没有名字**且不补。走 AppStorage + `@StorageLink` 之后，值一变按钮**自己**就重画。
 */

import { SelectSurfaceModifier } from './MaterialSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { AccountEntry } from '../core/AccountBook';
import { SymbolGlyphModifier } from '@kit.ArkUI';

/** 按钮/菜单读的三份数据（由 pages/Index 写，见文件头）。 */
export const ACCOUNT_TITLE_NAME: string = 'account_title_name';
export const ACCOUNT_TITLE_AVATAR: string = 'account_title_avatar';
export const ACCOUNT_OTHERS: string = 'account_others';

/** 菜单和按钮之间那一点纵向偏移（设定页是 6，这里照抄）。 */
const MENU_OFFSET_Y: number = 6;
/** 下拉菜单宽度（设定页没设，按账号名长度给个够用的固定值，菜单才不会被名字撑成一条）。 */
const OPTION_WIDTH_VP: number = 196;

@Component
export struct AccountSwitcher {
  /** 当前账号名（空 = 还没拿到）。 */
  @StorageLink(ACCOUNT_TITLE_NAME) username: string = '';
  /** 当前账号头像地址（按钮上不用；留给"没有其他账号时"的头像兜底）。 */
  @StorageLink(ACCOUNT_TITLE_AVATAR) avatarUrl: string = '';
  /** **其他**账号（已排除当前这个；空 = 下拉里只有「新增账号」）。 */
  @StorageLink(ACCOUNT_OTHERS) accounts: Array<AccountEntry> = [];
  /** 材质厚薄（跟设定页联动）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 选中了另一个账号。 */
  onSwitch: (userId: string) => void = (userId: string): void => {
  };
  /** 点了「新增账号」。 */
  onAdd: () => void = (): void => {
  };

  /**
   * 下拉选项：其他账号（有头像就给 icon）+ 最后一栏「新增账号」。
   *
   * ⚠️ 每次都新建一个数组（不是缓存字段）：`@StorageLink` 的 accounts 一变就要重新算，
   * 而 Select 只在 `build` 里取值 —— 放字段里就得自己管失效。
   */
  private options(): Array<SelectOption> {
    const list: Array<SelectOption> = [];
    for (let index: number = 0; index < this.accounts.length; index++) {
      const one: AccountEntry = this.accounts[index];
      const label: string = one.username.length > 0 ? one.username : one.userId;
      if (one.avatarUrl.length > 0) {
        list.push({ value: label, icon: one.avatarUrl });
      } else {
        list.push({ value: label });
      }
    }
    // 「新增账号」：加号图标（需求）。
    const add: SelectOption = {
      value: $r('app.string.account_add'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus'))
    };
    list.push(add);
    return list;
  }

  /** 按钮收起时显示的字：当前账号名。 */
  private buttonValue(): ResourceStr {
    return this.username.length > 0 ? this.username : $r('app.string.account_add');
  }

  build() {
    Select(this.options())
      .value(this.buttonValue())
      .font({ size: 15 })
      .fontColor($r('app.color.primary_text'))
      // 沉浸光感（按钮与菜单都靠它；低版本设备自动降级成纯色底）。
      .attributeModifier(new SelectSurfaceModifier(this.materialThickness))
      // 和设定页一致：菜单贴着按钮右缘往下弹（默认 START 会往右顶出屏幕）。
      .menuAlign(MenuAlignType.END, { dx: 0, dy: MENU_OFFSET_Y })
      // 选中项样式照抄设定页（颜色走明暗两套资源，浅色模式下也看得清）。
      .selectedOptionBgColor($r('app.color.dropdown_selected_bg'))
      .selectedOptionFont({ size: 15, weight: FontWeight.Bold })
      .selectedOptionFontColor($r('app.color.dropdown_selected_text'))
      .optionWidth(OPTION_WIDTH_VP)
      .onSelect((index: number): void => {
        if (index < 0) {
          return;
        }
        if (index < this.accounts.length) {
          this.onSwitch(this.accounts[index].userId);
          return;
        }
        // 最后一栏 = 新增账号。
        this.onAdd();
      })
  }
}
