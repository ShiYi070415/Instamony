/*
 * **沉浸光感状态胶囊**：一颗"只显示、不交互"的材质小胶囊（图标 + 一行字）。
 *
 * ## 为什么要单独抽出来
 * Reels 页有两处"临时状态提示"，观感必须一致：
 *   · **下拉刷新**：下拉刷新 →（过阈值）松开刷新 → 正在刷新…（带箭头图标 / 转圈）；
 *   · **长按倍速**：按住左侧或右侧时的 `2.0x`。
 * 它们原来各写一遍：刷新那颗是自绘的半透明底，倍速那颗是 `MaterialLabelButton`，而且倍速那颗
 * 还画在**卡片里**（进度条下方）—— 用户要求"共用同一个组件、不要显示在卡片里"。所以抽成这个
 * 组件，宿主只决定"放哪儿"和"显示什么字"。
 *
 * ## 材质怎么来
 * 和 app 里其它控件同一套（见 MaterialSurface）：底层 `Toggle` 只承载沉浸光感材质、
 * **不吃触摸**（`hitTestBehavior(HitTestMode.None)`），图标与文字透明地压在它上面 ——
 * `Text` 自己挂不了 `systemMaterial`，只能这样叠。材质厚度跟设定页那一档（`@StorageProp`），
 * 文字用 `primary_text`（材质会自动反色，深浅主题下都读得清）。
 */

import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { SurfaceModifier } from './MaterialSurface';

/** 默认尺寸（vp）：够放下"正在刷新…"（图标 15 + 间隔 6 + 5 个字）。 */
const DEFAULT_W: number = 104;
const DEFAULT_H: number = 32;
const DEFAULT_FONT: number = 12;
const ICON_SIZE: number = 15;
const ICON_GAP: number = 6;

@Component
export struct MaterialPill {
  /** 文案（如"下拉刷新" / "2.0x"）。 */
  @Prop text: string = '';
  /**
   * 左侧画什么：
   *   · `refresh` —— 刷新箭头（下拉刷新那三态里的前两态）；
   *   · `none` —— 不画图标（倍速那颗：只有一个 `2.0x`）。
   */
  @Prop iconKind: string = 'none';
  /** 左侧换成转圈（"正在刷新…"）。优先于 `iconKind`。 */
  @Prop busy: boolean = false;
  /** 图标淡一点（下拉过阈值后提示"松开即可"）。 */
  @Prop dimIcon: boolean = false;
  /** 胶囊长宽（vp）。 */
  @Prop pillWidth: number = DEFAULT_W;
  @Prop pillHeight: number = DEFAULT_H;
  @Prop fontSize: number = DEFAULT_FONT;
  /** 材质厚度：跟随设定页那一档（与标题栏 / 底栏 / 其它材质控件同源）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 底层：材质底板（只画不吃触摸）
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Text('')
      }
      .width(this.pillWidth)
      .height(this.pillHeight)
      .padding(0)
      .borderRadius(this.pillHeight / 2)
      .backgroundColor(Color.Transparent)
      // 选中态透明：Toggle 默认选中色是主题强调色，不清掉整条会变蓝（同 MaterialSurface 的说明）。
      .selectedColor(Color.Transparent)
      .attributeModifier(new SurfaceModifier(this.materialThickness, false))
      .hitTestBehavior(HitTestMode.None)

      // 上层：图标 + 文案
      Row({ space: ICON_GAP }) {
        if (this.busy) {
          LoadingProgress()
            .width(ICON_SIZE)
            .height(ICON_SIZE)
            .color($r('app.color.primary_text'))
        } else if (this.iconKind === 'refresh') {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(ICON_SIZE)
            .fontColor([$r('app.color.primary_text')])
            .opacity(this.dimIcon ? 0.4 : 1)
        }
        if (this.text.length > 0) {
          Text(this.text)
            .fontSize(this.fontSize)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
        }
      }
      .height(this.pillHeight)
      .justifyContent(FlexAlign.Center)
    }
    .width(this.pillWidth)
    .height(this.pillHeight)
    .borderRadius(this.pillHeight / 2)
  }
}
