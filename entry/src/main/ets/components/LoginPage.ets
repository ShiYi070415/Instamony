/*
 * 「未登录」整页：品牌 + 账号密码 + 两步验证 + 安全验证（原生登录，见 core/mobileapi/MobileLogin）。
 *
 * 演进过程（别改回去）：这一页原来只有一颗「登录」按钮，点了把隐藏网页亮出来、
 * 在 IG 官方网页里登录。现在主路径改成**原生密码登录**（instagrapi 的 legacy 链：
 * `launcher/sync/` → `accounts/login/` → 必要时 `accounts/two_factor_login/`），
 * 网页登录退成"兜底出口"按钮。
 *
 * 三条设计约束：
 *   1. **整页**：未登录时五个 tab 的内容层与底栏都不建（见 pages/Index），换账号不残留。
 *   2. **不保存密码**：密码只在这一次请求里用，落盘的只有会话 cookie；
 *      输入框是 `InputType.Password`，本页不留任何明文。
 *   3. **风格与本 App 一致**：卡片 = 项目降级那套玻璃底（FALLBACK_SURFACE + FALLBACK_BLUR），
 *      主按钮 = 沉浸光感（SurfaceModifier 挂在 Toggle 上），配色/圆角/间距沿用设置页那套。
 */

import { FALLBACK_BLUR, FALLBACK_SURFACE, MaterialLabelButton, SurfaceModifier } from './MaterialSurface';
import {
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';
import { LoginOutcome, LoginStage, MobileLogin } from '../core/mobileapi/MobileLogin';

const SIDE_VP: number = 28;
const CARD_RADIUS: number = 28;
const FIELD_RADIUS: number = 14;
const FIELD_H: number = 48;
const BUTTON_H: number = 50;
const BRAND_SIZE: number = 64;

@Component
export struct LoginPage {
  /** 点「用网页登录」：把网页亮出来并导航到登录页（兜底出口，见 pages/Index.openLoginWeb）。 */
  onLogin: () => void = (): void => {
  };
  /** 点「注册账号」：把网页亮出来并导航到 IG 的注册页。 */
  onRegister: () => void = (): void => {
  };
  /** 点「重新检查」：网页里已经登好了、但信号没送到时的手动兜底。 */
  onRecheck: () => void = (): void => {
  };
  /** **原生登录成功**（会话已写进 Cookie 罐）：页面据此切到主界面。 */
  onSignedIn: () => void = (): void => {
  };
  /** 材质厚度：跟随设置页那一档（@StorageLink 与其它页面同源）。 */
  @StorageLink(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;

  @State private username: string = '';
  @State private password: string = '';
  @State private code: string = '';
  /** 当前步骤（决定显示密码框还是验证码框）。 */
  @State private stage: LoginStage = LoginStage.Failed;
  @State private busy: boolean = false;
  @State private error: string = '';
  /** 两步验证要用的 id / 安全验证要用的 api_path（下一步带上）。 */
  private twoFactorId: string = '';
  private challengePath: string = '';
  private challengeType: string = '';

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

  /** 输入框（玻璃底，与应用其它输入框同一套观感）。 */
  @Builder
  field(hint: Resource, value: string, isPassword: boolean,
        onEdit: (text: string) => void) {
    TextInput({ placeholder: hint, text: value })
      .type(isPassword ? InputType.Password : InputType.Normal)
      .height(FIELD_H)
      .width('100%')
      .padding({ left: 14, right: 14 })
      .borderRadius(FIELD_RADIUS)
      .backgroundColor(FALLBACK_SURFACE)
      .backgroundBlurStyle(FALLBACK_BLUR)
      .fontSize(15)
      .fontColor($r('app.color.primary_text'))
      .placeholderColor($r('app.color.secondary_text'))
      .caretColor($r('app.color.accent'))
      .enabled(!this.busy)
      .onChange((text: string): void => {
        onEdit(text);
      })
  }

  /** 主按钮（沉浸光感承载在 Toggle 上，见 MaterialSurface 的文件头）。 */
  @Builder
  mainButton(label: ResourceStr, action: () => void) {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      if (this.busy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('app.color.on_accent'))
      } else {
        Text(label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent'))
      }
    }
    .width('100%')
    .height(BUTTON_H)
    .padding(0)
    .borderRadius(BUTTON_H / 2)
    .attributeModifier(new SurfaceModifier(this.materialThickness, true))
    .backgroundColor($r('app.color.accent'))
    .enabled(!this.busy)
    .onChange((): void => {
      if (!this.busy) {
        action();
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 背景渐变（材质要采样背后的画面，见 LoginPage 的文件头说明）。
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

        // ---- 账号密码卡片 ----
        Column({ space: 10 }) {
          this.field($r('app.string.login_username_hint'), this.username, false,
            (text: string): void => {
              this.username = text;
            })
          this.field($r('app.string.login_password_hint'), this.password, true,
            (text: string): void => {
              this.password = text;
            })
          if (this.stage === LoginStage.TwoFactor) {
            this.field($r('app.string.login_code_hint'), this.code, false,
              (text: string): void => {
                this.code = text;
              })
          }
          if (this.stage === LoginStage.Challenge && this.challengePath.length > 0) {
            // 只有"验证码类"的安全验证能在原生侧提交；其余引导去网页（见下面那块说明）。
            this.field($r('app.string.login_challenge_code_hint'), this.code, false,
              (text: string): void => {
                this.code = text;
              })
          }
          if (this.error.length > 0) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
                .fontSize(14)
                .fontColor([$r('app.color.accent')])
              Text(this.error)
                .fontSize(12)
                .lineHeight(18)
                .fontColor($r('app.color.accent'))
                .layoutWeight(1)
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(14)
        .borderRadius(CARD_RADIUS)
        .backgroundColor(FALLBACK_SURFACE)
        .backgroundBlurStyle(FALLBACK_BLUR)
        .margin({ top: 22 })

        // ---- 主按钮：登录 / 提交验证码 ----
        if (this.stage === LoginStage.TwoFactor) {
          this.mainButton($r('app.string.login_submit_code'), (): void => {
            this.submit();
          })
        } else if (this.stage === LoginStage.Challenge && this.challengePath.length > 0) {
          this.mainButton($r('app.string.login_submit_code'), (): void => {
            this.submitChallenge();
          })
        } else {
          this.mainButton($r('app.string.login_page_action'), (): void => {
            this.submit();
          })
        }

        // ---- 安全验证的说明（原生做不了完整流程时引导去网页）----
        if (this.stage === LoginStage.Challenge) {
          Column({ space: 12 }) {
            this.hintRow($r('sys.symbol.lock_shield'), $r('app.string.login_challenge_hint'))
            MaterialLabelButton({
              labelRes: $r('app.string.login_challenge_web'),
              fullWidth: true,
              fontSize: 15,
              onTap: (): void => {
                this.onLogin();
              }
            })
          }
          .width('100%')
          .padding(16)
          .borderRadius(CARD_RADIUS)
          .backgroundColor(FALLBACK_SURFACE)
          .backgroundBlurStyle(FALLBACK_BLUR)
          .margin({ top: 12 })
        } else {
          // ---- 兜底：网页登录 / 注册（原来那两颗按钮，位置不变）----
          MaterialLabelButton({
            labelRes: $r('app.string.login_web_fallback'),
            fullWidth: true,
            fontSize: 15,
            onTap: (): void => {
              this.onLogin();
            }
          })
            .margin({ top: 12 })

          Row({ space: 12 }) {
            MaterialLabelButton({
              labelRes: $r('app.string.login_register'),
              fullWidth: true,
              fontSize: 15,
              onTap: (): void => {
                this.onRegister();
              }
            })
              .layoutWeight(1)
            MaterialLabelButton({
              labelRes: $r('app.string.login_recheck'),
              fullWidth: true,
              fontSize: 15,
              onTap: (): void => {
                this.onRecheck();
              }
            })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 12 })
        }

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

  /**
   * 提交：第一次是"账号 + 密码"，第二步是验证码。
   *
   * 两个入口共用同一个函数：`stage` 决定发什么（见 core/mobileapi/MobileLogin）。
   */
  private submit(): void {
    if (this.busy) {
      return;
    }
    if (this.username.trim().length === 0 || this.password.length === 0) {
      this.error = '请输入账号和密码';
      return;
    }
    this.error = '';
    this.busy = true;
    MobileLogin.login(this.username, this.password, this.code)
      .then((outcome: LoginOutcome): void => {
        this.busy = false;
        this.apply(outcome);
      })
      .catch((error: Error): void => {
        this.busy = false;
        this.error = `登录出错：${error.message}`;
      });
  }

  /** 把 core 的结果翻译成界面状态（该显示验证码框、还是错误、还是进主界面）。 */
  private apply(outcome: LoginOutcome): void {
    if (outcome.isOk()) {
      this.error = '';
      this.stage = LoginStage.Ok;
      // 密码不留在内存里。
      this.password = '';
      this.code = '';
      this.onSignedIn();
      return;
    }
    this.stage = outcome.stage;
    this.twoFactorId = outcome.twoFactorIdentifier;
    this.challengePath = outcome.challengePath;
    this.challengeType = outcome.challengeType;
    this.error = outcome.message;
  }

  /** 安全验证：提交收到的验证码（见 core/mobileapi/MobileLogin.challengeVerify）。 */
  private submitChallenge(): void {
    if (this.busy) {
      return;
    }
    this.error = '';
    this.busy = true;
    MobileLogin.challengeVerify(this.challengePath, this.code)
      .then((outcome: LoginOutcome): void => {
        this.busy = false;
        this.apply(outcome);
      })
      .catch((error: Error): void => {
        this.busy = false;
        this.error = `验证出错：${error.message}`;
      });
  }
}
