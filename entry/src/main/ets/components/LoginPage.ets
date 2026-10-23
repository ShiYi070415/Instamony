/*
 * 「未登录」整页：品牌 + 表单（标题 + 输入框）+ 按钮列（登录 / 注册新账号）。
 *
 * 布局（用户指定）：
 *   ┌ 品牌图标 + 标题
 *   │ 用户名            ← 标题
 *   │ [ 输入框 ]
 *   │ 密码              ← 标题
 *   │ [ 输入框 ]
 *   └ Column {
 *       登录
 *       注册新账号
 *     }
 *
 * 两步验证不占页面：账号密码过了之后从底部升起一个半模态面板收验证码（见 verifySheet）。
 *
 * 登录本身走**隐藏网页**（见 core/WebLogin：IG 已不给第三方客户端走原生密码登录，
 * 但它自己的网页就是账号密码登录），注册走网页里的 IG 注册页。
 * 三条设计约束：
 *   1. **整页**：未登录时五个 tab 的内容层与底栏都不建（见 pages/Index），换账号不残留。
 *   2. **不保存密码**：密码只在这一次请求里用，成功后清空输入；落盘的只有会话 cookie。
 *   3. **风格与本 App 一致**：输入框是"材质底 + 透明输入框"叠出来的**椭圆胶囊**，
 *      按钮是沉浸光感（SurfaceModifier 挂在 Toggle 上），配色/圆角/间距沿用设置页那套。
 */

import { FALLBACK_BLUR, FALLBACK_SURFACE, MaterialLabelButton, SurfaceModifier } from './MaterialSurface';
import {
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';
// WEB_LOGIN_NEEDS_CODE：账号密码过了、但 IG 要再走一步验证（见 core/WebLogin）。
import { WEB_LOGIN_NEEDS_CODE } from '../core/WebLogin';

const SIDE_VP: number = 28;
const CARD_RADIUS: number = 28;
const FIELD_H: number = 48;
const BUTTON_H: number = 50;
const BRAND_SIZE: number = 64;
const LABEL_SIZE: number = 13;

@Component
export struct LoginPage {
  /** 点「注册新账号」：把网页亮出来并导航到 IG 的注册页。 */
  onRegister: () => void = (): void => {
  };
  /** **登录成功**（会话已写进 Cookie 罐）：页面据此切到主界面。 */
  onSignedIn: () => void = (): void => {
  };
  /**
   * 提交**两步验证码**（半模态面板里那个输入框）。
   *
   * @returns 空串 = 通过（会话已进罐）；否则是面板上显示的原因
   */
  onVerifyCode: (username: string, code: string) => Promise<string> =
    (username: string, code: string): Promise<string> => {
      return Promise.resolve('未接入验证码提交');
    };
  /**
   * **把账号密码交给隐藏网页去登录**（见 core/WebLogin）。
   *
   * 这是本页主按钮真正干的事：IG 已经不放第三方客户端走原生密码登录（`needs_upgrade`），
   * 而它自己的网页里就是账号密码登录 —— 所以在隐藏网页里静默完成，用户只面对本 App。
   *
   * @returns 空串 = 成功；否则是给用户看的失败原因
   */
  onWebLogin: (username: string, password: string) => Promise<string> =
    (username: string, password: string): Promise<string> => {
      return Promise.resolve('网页登录未接入');
    };
  /** 材质厚度：跟随设置页那一档（@StorageLink 与其它页面同源）。 */
  @StorageLink(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;

  /*
   * 账号 / 密码就是普通 `@State`。
   *
   * 上一版用 `@StorageLink` 是为了"点登录后页面被重建、输入不丢"——那是**治标**：
   * 根因是点登录会把隐藏网页亮出来（`webVisible = true`），根 Stack 一换，登录页就重建了。
   * 现在点登录**不再显示网页**（无头登录），页面不会重建，`@State` 就够了。
   */
  @State private username: string = '';
  @State private password: string = '';
  @State private busy: boolean = false;
  @State private error: string = '';
  /** 两步验证的半模态面板：开没开、里面的验证码、错误、忙。 */
  @State private verifyOpen: boolean = false;
  @State private verifyCode: string = '';
  @State private verifyError: string = '';
  @State private verifyBusy: boolean = false;

  /**
   * 一组"标题 + 输入框"：标题在上（灰小字），输入框在下。
   *
   * 输入框是**椭圆胶囊 + 沉浸光感**（需求）。为什么做成两层 Stack 而不是给 TextInput 直接挂材质：
   *   · 沉浸光感的材质接口（`systemMaterial` / `uiMaterial.ImmersiveMaterial`）只有
   *     `Toggle / Slider / Select` 与弹窗类能写在内容区里（见 MaterialSurface 的文件头）；
   *     `TextInput` 不在这个范围，直接挂不生效。
   *   · 所以照 `CommentInputBar` 那套已验证的写法：**底层 Toggle 只画材质、不吃触摸**
   *     （`hitTestBehavior(HitTestMode.None)`），输入框本体透明地压在它上面。
   *   · 胶囊 = `borderRadius(FIELD_H / 2)`；文字用左右 18 的 padding 让开两端的圆角。
   */
  @Builder
  labeledField(label: ResourceStr, hint: ResourceStr, value: string, isPassword: boolean,
               onEdit: (text: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(LABEL_SIZE)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ left: 6 })
      Stack({ alignContent: Alignment.Center }) {
        // ① 材质底板：只画沉浸光感，不参与触摸（触摸要给上面的输入框）
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
        }
        .width('100%')
        .height(FIELD_H)
        .padding(0)
        .borderRadius(FIELD_H / 2)
        .backgroundColor(Color.Transparent)
        // 选中态透明：Toggle 默认选中色是主题强调色，不清掉整条会变蓝。
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.materialThickness, false))
        .hitTestBehavior(HitTestMode.None)

        // ② 输入框本体：透明底，压在材质上（胶囊同半径，文字两端留出圆角）
        TextInput({ placeholder: hint, text: value })
          .type(isPassword ? InputType.Password : InputType.Normal)
          .height(FIELD_H)
          .width('100%')
          .padding({ left: 18, right: 18 })
          .borderRadius(FIELD_H / 2)
          .backgroundColor(Color.Transparent)
          .fontSize(15)
          .fontColor($r('app.color.primary_text'))
          .placeholderColor($r('app.color.secondary_text'))
          .caretColor($r('app.color.accent'))
          .enabled(!this.busy)
          .onChange((text: string): void => {
            onEdit(text);
          })
      }
      .width('100%')
      .height(FIELD_H)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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

  /**
   * **半模态两步验证面板**（需求：跳一个半模态沉浸光感组件做 2FA）。
   *
   * 组成：标题 + 一句说明 + 胶囊验证码输入框 + 错误 + 「验证」主按钮（沉浸光感材质）
   * + 「取消」。面板本身用「玻璃底 + 背景模糊」那套（和 app 其它卡片一致），
   * 主按钮是完整材质（SurfaceModifier 挂在 Toggle 上）。
   */
  @Builder
  verifySheet() {
    Column({ space: 14 }) {
      Text($r('app.string.login_verify_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
      Text($r('app.string.login_verify_hint'))
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
      Stack({ alignContent: Alignment.Center }) {
        // 材质底板（和登录页其它输入框同一套：胶囊 + 沉浸光感）
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
        }
        .width('100%')
        .height(FIELD_H)
        .padding(0)
        .borderRadius(FIELD_H / 2)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.materialThickness, false))
        .hitTestBehavior(HitTestMode.None)
        TextInput({ placeholder: $r('app.string.login_code_hint'), text: this.verifyCode })
          .type(InputType.Number)
          .height(FIELD_H)
          .width('100%')
          .padding({ left: 18, right: 18 })
          .borderRadius(FIELD_H / 2)
          .backgroundColor(Color.Transparent)
          .fontSize(16)
          .fontColor($r('app.color.primary_text'))
          .placeholderColor($r('app.color.secondary_text'))
          .caretColor($r('app.color.accent'))
          .enabled(!this.verifyBusy)
          .onChange((text: string): void => {
            this.verifyCode = text;
          })
      }
      .width('100%')
      .height(FIELD_H)

      if (this.verifyError.length > 0) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(14)
            .fontColor([$r('app.color.accent')])
          Text(this.verifyError)
            .fontSize(12)
            .lineHeight(18)
            .fontColor($r('app.color.accent'))
            .layoutWeight(1)
        }
        .width('100%')
      }

      Toggle({ type: ToggleType.Button, isOn: false }) {
        if (this.verifyBusy) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color($r('app.color.on_accent'))
        } else {
          Text($r('app.string.login_verify_action'))
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
      .enabled(!this.verifyBusy)
      .onChange((): void => {
        this.submitVerifyCode();
      })

      MaterialLabelButton({
        labelRes: $r('app.string.login_verify_cancel'),
        fullWidth: true,
        fontSize: 15,
        onTap: (): void => {
          this.verifyOpen = false;
          this.verifyError = '';
        }
      })
    }
    .width('100%')
    .padding({ left: SIDE_VP, right: SIDE_VP, top: 10, bottom: 24 })
    .backgroundColor(FALLBACK_SURFACE)
    .backgroundBlurStyle(FALLBACK_BLUR)
  }

  /** 面板里点「验证」：交给 Index → core（见 onVerifyCode）。 */
  private submitVerifyCode(): void {
    if (this.verifyBusy) {
      return;
    }
    if (this.verifyCode.trim().length === 0) {
      this.verifyError = '请输入验证码';
      return;
    }
    this.verifyError = '';
    this.verifyBusy = true;
    this.onVerifyCode(this.username, this.verifyCode)
      .then((message: string): void => {
        this.verifyBusy = false;
        if (message.length === 0) {
          this.verifyOpen = false;
          this.verifyCode = '';
          this.onSignedIn();
          return;
        }
        this.verifyError = message;
      })
      .catch((error: Error): void => {
        this.verifyBusy = false;
        this.verifyError = `验证出错：${error.message}`;
      });
  }

  /** 主按钮此刻该干什么：一直是"拿账号密码去隐藏网页里登录"（见 submit）。 */
  private primaryAction(): void {
    this.submit();
  }

  /** 主按钮文案。 */
  private primaryLabel(): ResourceStr {
    return $r('app.string.login_page_action');
  }

  /** 密码框之上那段错误提示（有错才画）。 */
  @Builder
  errorRow() {
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
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 背景渐变（材质要采样背后的画面，见文件头的说明）。
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
          .margin({ top: 14, bottom: 22 })

        // ---- 表单：标题 + 输入框 ----
        Column({ space: 14 }) {
          this.labeledField($r('app.string.login_label_username'),
            $r('app.string.login_username_hint'), this.username, false,
            (text: string): void => {
              this.username = text;
            })
          this.labeledField($r('app.string.login_label_password'),
            $r('app.string.login_password_hint'), this.password, true,
            (text: string): void => {
              this.password = text;
            })
          if (this.error.length > 0) {
            this.errorRow()
          } else {
            /*
             * 常驻一行说明。
             *
             * 依据官方文档（instagrapi Login Migration）：3.x 的 `login()` 走 CAA（Bloks 编排），
             * `login_legacy()` 的 needs_upgrade 也会转 CAA —— 也就是**第三方客户端的密码登录
             * 已经被政策收口**。提前讲清楚，别让用户反复试密码（失败登录本身也是风控信号）。
             */
            Text($r('app.string.login_password_note'))
              .fontSize(11)
              .lineHeight(16)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
              .padding({ left: 6 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ---- 按钮列：登录 / 注册新账号 ----
        Column({ space: 12 }) {
          this.mainButton(this.primaryLabel(), (): void => {
            this.primaryAction();
          })
          MaterialLabelButton({
            labelRes: $r('app.string.login_register'),
            fullWidth: true,
            fontSize: 15,
            onTap: (): void => {
              this.onRegister();
            }
          })
        }
        .width('100%')
        .margin({ top: 22 })

        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: SIDE_VP, right: SIDE_VP })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    /*
     * **两步验证的半模态面板**（需求："跳一个半模态沉浸光感组件做 2FA"）。
     * `FIT_CONTENT` + 底部圆角，内容见 verifySheet；点登录时若 IG 回
     * `showAccountRecoveryModal`，Index 会返回 `WEB_LOGIN_NEEDS_CODE`，这里就把面板打开。
     */
    .bindSheet(this.verifyOpen, this.verifySheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      preferType: SheetType.BOTTOM,
      backgroundColor: Color.Transparent,
      onDisappear: (): void => {
        this.verifyError = '';
      }
    })
  }

  /**
   * 提交：主按钮 = "拿账号密码去隐藏网页里登录"（见 onWebLogin）。
   *
   * 因为原生 `accounts/login/` 已被 IG 的版本政策挡住（`needs_upgrade`），
   * 详见 core/mobileapi/MobileLogin 与 core/WebLogin 的文件头。
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
    /*
     * **点下去就清密码、账号留着**（需求：只清密码框里的内容）。
     *
     * 点登录不再显示网页（无头登录），所以登录页不会被重建 —— 普通 `@State` 足够，
     * 账号在本次运行里一直留着（重启后不保留，需求明确不需要 StorageLink 那套）。
     */
    const typed: string = this.password;
    this.password = '';
    this.onWebLogin(this.username, typed)
      .then((message: string): void => {
        this.busy = false;
        if (message === WEB_LOGIN_NEEDS_CODE) {
          // 账号密码过了，但 IG 要再走一步验证：弹半模态面板收验证码。
          this.verifyCode = '';
          this.verifyError = '';
          this.verifyOpen = true;
          return;
        }
        if (message.length === 0) {
          // 真的登录成功了：会话已进 Cookie 罐，Index 那边会重读登录态。
          this.onSignedIn();
          return;
        }
        this.error = message;
      })
      .catch((error: Error): void => {
        this.busy = false;
        this.error = `登录出错：${error.message}`;
      });
  }
}
