/*
 * 「未登录」整页：品牌 + 提示 + 一颗登录按钮。
 *
 * 需求（用户原话）："新增一个登录页面，未登录状态会一直在这个页面（开启 app / 退出登录后），
 * 显示一些提示信息和登录按钮，需要沉浸光感效果，点击登录按钮才跳转网页登录。"
 *
 * 三条设计约束，写成注释免得以后被改回去：
 *   1. **它必须是整页**，而不是塞在首页 tab 里的一个面板（原来就是后者，见 pages/Index 的
 *      nativeShellContent）。整页的好处不只是"满屏"：未登录时五个 tab 的内容层与底栏**都不建**，
 *      于是退出登录 / 换账号时它们整批销毁重建 —— 主页 / Reels / 私信 / 搜索 / 我的 不会残留
 *      上一个人的任何一条数据（用户要求的"退出登录需要清空这五个页面"就靠这一条兜住）。
 *   2. **只在点了按钮之后才跳网页登录**：登录全程在 Instagram 官方网页里做，本页不收任何账号密码。
 *   3. **沉浸光感**：卡片与按钮都走全 app 统一的材质（`SurfaceModifier` / `MaterialLabelButton`），
 *      低版本设备自动退化成纯色（见 components/MaterialSurface 的文件头）。
 */

import { FALLBACK_BLUR, FALLBACK_SURFACE, MaterialLabelButton, SurfaceModifier } from './MaterialSurface';
import {
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';

const SIDE_VP: number = 28;
const CARD_RADIUS: number = 28;
const BUTTON_H: number = 50;
const BRAND_SIZE: number = 64;

@Component
export struct LoginPage {
  /** 点「登录」：把网页亮出来并导航到登录页（见 pages/Index.openLoginWeb）。 */
  onLogin: () => void = (): void => {
  };
  /** 点「注册账号」：把网页亮出来并导航到 IG 的注册页（见 pages/Index.openSignupWeb）。 */
  onRegister: () => void = (): void => {
  };
  /** 点「重新检查」：网页里已经登好了、但信号没送到时的手动兜底。 */
  onRecheck: () => void = (): void => {
  };
  /** 材质厚度：跟随设置页那一档（@StorageLink 与其它页面同源）。 */
  @StorageLink(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;

  /** 一行提示：图标 + 文案。 */
  @Builder
  hintRow(symbol: Resource, text: ResourceStr) {
    Row({ space: 10 }) {
      SymbolGlyph(symbol)
        .fontSize(16)
        .fontColor([$r('app.color.secondary_text')])
      Text(text)
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.secondary_text'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    /*
     * 背景那一层为什么不能省：沉浸光感材质是**采样背后的画面**再染色模糊的，背后若是纯色
     * 底（`page_background` 在黑/白主题下都是纯色），玻璃卡片和材质按钮就跟贴了张半透明
     * 贴纸一样，一点"光感"都读不出来（第一版实机就是这样）。
     *
     * 所以铺一层纵向渐变：上端是强调色的低透明光晕，往下收进页面底色。两个端值都是明暗
     * 两套资源（见 color.json 的 login_glow_*），切主题自动换。
     */
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [
            [$r('app.color.login_glow_top'), 0.0],
            [$r('app.color.login_glow_bottom'), 0.72],
            [$r('app.color.login_glow_bottom'), 1.0]
          ]
        })

      Column() {
        Blank()

        // ---- 品牌 ----
        Image($r('app.media.startIcon'))
          .width(BRAND_SIZE)
          .height(BRAND_SIZE)
          .draggable(false)
          .borderRadius(16)
        Text($r('app.string.login_title'))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .margin({ top: 14 })

        /*
         * ---- 提示卡片（玻璃底）----
         *
         * 卡片这一层**不能**挂 `SurfaceModifier`：它是 `AttributeModifier<ToggleAttribute>`，
         * 只能挂在承载材质的 Toggle 上（见 MaterialSurface 的文件头）。所以卡片用项目的降级那套
         * 玻璃底（最薄的 `backgroundBlurStyle` + 半透明中性色，见 FALLBACK_BLUR/FALLBACK_SURFACE），
         * 而**主按钮**仍然走完整的沉浸光感（Toggle 承载）—— 一处满血、一处玻璃，观感统一。
         */
        Column({ space: 12 }) {
          this.hintRow($r('sys.symbol.lock_shield'), $r('app.string.login_page_hint_account'))
          this.hintRow($r('sys.symbol.house'), $r('app.string.login_page_hint_features'))
          this.hintRow($r('sys.symbol.arrow_counterclockwise'), $r('app.string.login_page_hint_stuck'))
        }
        .width('100%')
        .padding(16)
        .borderRadius(CARD_RADIUS)
        .backgroundColor(FALLBACK_SURFACE)
        .backgroundBlurStyle(FALLBACK_BLUR)
        .margin({ top: 22 })

        // ---- 主按钮：登录（材质承载在 Toggle 上，内容区只有它拿得到完整的沉浸光感）----
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text($r('app.string.login_page_action'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_accent'))
        }
        .width('100%')
        .height(BUTTON_H)
        .padding(0)
        .borderRadius(BUTTON_H / 2)
        .attributeModifier(new SurfaceModifier(this.materialThickness, true))
        .backgroundColor($r('app.color.accent'))
        .margin({ top: 22 })
        .onChange((): void => {
          this.onLogin();
        })

        // ---- 次按钮：注册账号（走 IG 网页注册，注册完回到这一页）----
        MaterialLabelButton({
          labelRes: $r('app.string.login_register'),
          fullWidth: true,
          fontSize: 15,
          onTap: (): void => {
            this.onRegister();
          }
        })
          .margin({ top: 12 })

        // ---- 次按钮：手动重新检查（网页里登好了但信号未到时用）----
        MaterialLabelButton({
          labelRes: $r('app.string.login_recheck'),
          fullWidth: true,
          fontSize: 16,
          onTap: (): void => {
            this.onRecheck();
          }
        })
          .margin({ top: 12 })

        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: SIDE_VP, right: SIDE_VP })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
