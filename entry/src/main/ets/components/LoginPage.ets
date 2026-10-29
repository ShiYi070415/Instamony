/*
 * 「未登录」整页：品牌 + 表单（用户名 / 密码）+ 按钮列（登录 / 注册新账号）。
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
 * ## 登录走什么
 * 走 **App 协议登录（CAA）**（见 core/mobileapi/CaaSession）：和真机 App 同一条路
 * （USDID 设备签名 + attestation + Bloks 编排），拿到的会话是**设备级**的 —— 后台推送、
 * 私信这些只有设备级会话才工作得正常。**不再有"网页登录"那条路**（用户要求：
 * "把网页登录功能去除，页面登录功能替换为 APP 协议登录"）。
 *
 * ## 两步验证
 * 不占页面：账号密码过了之后，从底部升起一个**系统沉浸光感的半模态面板**收验证码
 * （见 verifySheet + build 里的 bindSheet）。面板自己不带背景色 —— 材质由
 * `SheetOptions.systemMaterial` 交给系统画（不支持沉浸材质的机器才退回玻璃底）。
 *
 * ## 设置入口
 * 本组件**不画**标题栏：未登录时右上角那颗「设置」由宿主画（`pages/Index` 的
 * `loginSettingsMenu` + `shellTitleContent` 的 loginPageShown 分支）。设置页在这一档
 * 不显示「退出登录」（见 components/SettingsPanel 的 `signedIn`），改显示
 * 「清除设备认证（2FA 测试）」—— 不然这台设备在 IG 那边一直算"验过了"，2FA 那条分支
 * 永远走不到，也就没法测（用户原话）。
 *
 * ## 设计约束
 *   1. **整页**：未登录时五个 tab 的内容层与底栏都不建（见 pages/Index），换账号不残留。
 *   2. **不保存密码**：密码只在这一次请求里用，点下去就清空；落盘的只有会话 cookie。
 *   3. **风格与本 App 一致**：输入框是"材质底 + 透明输入框"叠出来的**椭圆胶囊**，
 *      按钮/面板是沉浸光感（SurfaceModifier 挂在 Toggle 上、面板走 systemMaterial），
 *      配色/圆角/间距沿用设置页那套。
 */

import {
  FALLBACK_BLUR,
  FALLBACK_SURFACE,
  immersiveMaterial,
  MaterialLabelButton,
  SurfaceModifier
} from './MaterialSurface';
import {
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';
import { PlatformCap } from '../core/PlatformCap';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'LoginPage';
const SIDE_VP: number = 28;
const CARD_RADIUS: number = 28;
const FIELD_H: number = 48;
const BUTTON_H: number = 50;
const BRAND_SIZE: number = 64;
const LABEL_SIZE: number = 13;

/**
 * 登录结果的哨兵值：**账号密码过了，但 IG 要求两步验证**（要走验证码那一发）。
 *
 * 为什么用字符串而不是再来一个结果类：这条路的返回值本来就只有"成功 / 要验证码 / 失败原因"
 * 三种，宿主（pages/Index）只需把它原样传回界面；多一个类型反而要在两处各解释一遍。
 */
export const LOGIN_NEEDS_CODE: string = 'login-needs-code';

@Component
export struct LoginPage {
  /** 点「注册新账号」：把网页亮出来并导航到 IG 的注册页（注册仍走网页，登录不走）。 */
  onRegister: () => void = (): void => {
  };
  /** **登录成功**（会话已写进 Cookie 罐）：页面据此切到主界面。 */
  onSignedIn: () => void = (): void => {
  };
  /**
   * 用账号密码走 **App 协议登录（CAA）**（见 core/mobileapi/CaaSession.login）。
   *
   * @returns 空串 = 成功（会话已进罐）；{@link LOGIN_NEEDS_CODE} = 要两步验证；
   *          其他 = 给用户看的失败原因
   */
  onCaaLogin: (username: string, password: string) => Promise<string> =
    (username: string, password: string): Promise<string> => {
      return Promise.resolve('登录功能未接入');
    };
  /**
   * 提交**两步验证码**（半模态面板里那个输入框，见 CaaSession.submitCode）。
   *
   * @returns 空串 = 通过（会话已进罐）；否则是面板上显示的原因
   */
  onCaaVerify: (code: string) => Promise<string> =
    (code: string): Promise<string> => {
      return Promise.resolve('验证码提交未接入');
    };
  /** 材质厚度：跟随设置页那一档（@StorageLink 与其它页面同源）。 */
  @StorageLink(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;

  /*
   * 账号 / 密码就是普通 `@State`（纯内存，不落盘 —— 需求明确不要"记住用户名"）。
   *
   * ⚠️ 但输入框**必须直连状态**：`text: this.username` + `onChange` 写回（官方推荐写法），
   * 且**不能**再走"带参数的 @Builder（按值传参）+ `TextInput({ text: value })`"那套：
   * `text` 是**构造参数**，按值传给 @Builder 之后它永远是建组件那一刻的快照。点登录时
   * `busy` 翻转会让输入框的 `.enabled()` 更新、组件刷新，`text` 就被那个空快照覆盖 ——
   * 表现正是用户报的"点登录，账号和密码一起被清空"（而 `this.username` 其实还在，
   * 登录也照常用它）。
   * 官方文档：TextInput 的 `text` "建议通过 onChange 将状态变量与文本实时绑定，避免组件
   * 刷新时 TextInput 中的文本内容异常"（API 10 起支持 `$$`）；@Builder "按值传递参数时…
   * 状态变量的改变不会引起 @Builder 函数内的 UI 刷新"。
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
   * 面板要不要用**系统沉浸光感材质**（API 26 起；不支持的机器退回玻璃底）。
   *
   * 提到一个方法里：bindSheet 的选项与面板内容的背景必须**同源判断**，否则会出现
   * "系统材质画了一层 + 内容又铺一层不透明底"（材质白设）或者"两边都不画"（面板透明）。
   */
  private sheetMaterialOn(): boolean {
    return PlatformCap.hasArkMaterial();
  }

  /**
   * 输入框的**材质底板**（椭圆胶囊 + 沉浸光感，只画不吃触摸）。
   *
   * 为什么做成"底板 + 透明输入框"两层，而不是给 TextInput 直接挂材质：
   *   · 沉浸光感的材质接口（`systemMaterial` / `uiMaterial.ImmersiveMaterial`）只有
   *     `Toggle / Slider / Select` 与弹窗类能写在内容区里（见 MaterialSurface 的文件头）；
   *     `TextInput` 不在这个范围，直接挂不生效。
   *   · 所以照 `CommentInputBar` 那套已验证的写法：**底层 Toggle 只画材质、不吃触摸**
   *     （`hitTestBehavior(HitTestMode.None)`），输入框本体透明地压在它上面。
   *   · 胶囊 = `borderRadius(FIELD_H / 2)`；文字用左右 18 的 padding 让开两端的圆角。
   *
   * 不带参数：带参数的 @Builder 是按值传参的（状态变了不会刷新），只能装"永远不变"的东西。
   */
  @Builder
  fieldShell() {
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
  }

  /** 输入框上方的标题（灰小字；标题是常量，不走状态，所以按值传参没问题）。 */
  @Builder
  fieldLabel(label: ResourceStr) {
    Text(label)
      .fontSize(LABEL_SIZE)
      .fontColor($r('app.color.secondary_text'))
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 6 })
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
   * **半模态两步验证面板**（需求：点登录若要求 2FA，就弹系统沉浸光感半模态面板收验证码）。
   *
   * 组成：标题 + 一句说明 + 胶囊验证码输入框 + 错误 + 「验证并登录」主按钮（沉浸光感材质）
   * + 「取消」。面板背景由 `SheetOptions.systemMaterial` 交给系统画（见 build 里的 bindSheet），
   * 所以这里**不再铺自己的底色**；只有在不支持沉浸材质的机器上才退回"玻璃底 + 模糊"。
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
    // 面板的底色由 bindSheet 那一侧画（系统沉浸材质 / 玻璃底，见 verifySheetOptions），
    // 内容层保持透明，别再铺第二层不透明底。
    .backgroundColor(Color.Transparent)
  }

  /**
   * 两步验证面板的外观（**系统沉浸光感半模态**，需求原话）。
   *
   * 和设置页那两个代理面板**同一套做法**（见 SettingsPanel.applySheetLook）：
   *   · API 26+：`SheetOptions.systemMaterial` 才是真正的沉浸光感 —— 面板的底色/边框/阴影
   *     全交给系统按 `ImmersiveMaterial` 画，这时 `backgroundColor` 必须透明
   *     （官方文档：不要和 backgroundColor/borderWidth/shadow 一起用）；
   *   · 老机器：退回"玻璃底 + 背景模糊"那一档，观感和 app 其它卡片一致。
   */
  private verifySheetOptions(): SheetOptions {
    const options: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      preferType: SheetType.BOTTOM,
      onDisappear: (): void => {
        this.verifyError = '';
      }
    };
    if (this.sheetMaterialOn()) {
      options.systemMaterial = immersiveMaterial(this.materialThickness);
      options.backgroundColor = Color.Transparent;
    } else {
      options.backgroundColor = FALLBACK_SURFACE;
      options.blurStyle = FALLBACK_BLUR;
    }
    return options;
  }

  /** 面板里点「验证并登录」：交给宿主 → core（见 onCaaVerify）。 */
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
    this.onCaaVerify(this.verifyCode.trim())
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

  /** 主按钮此刻该干什么：一直是"拿账号密码走 App 协议登录"（见 submit）。 */
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

        // ---- 表单：标题 + 输入框（双向绑定，见 username 那段注释）----
        Column({ space: 14 }) {
          Column({ space: 6 }) {
            this.fieldLabel($r('app.string.login_label_username'))
            Stack({ alignContent: Alignment.Center }) {
              this.fieldShell()
              TextInput({
                placeholder: $r('app.string.login_username_hint'),
                text: this.username
              })
                .type(InputType.Normal)
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
                  this.username = text;
                })
            }
            .width('100%')
            .height(FIELD_H)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 6 }) {
            this.fieldLabel($r('app.string.login_label_password'))
            Stack({ alignContent: Alignment.Center }) {
              this.fieldShell()
              TextInput({
                placeholder: $r('app.string.login_password_hint'),
                text: this.password
              })
                .type(InputType.Password)
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
                  this.password = text;
                })
            }
            .width('100%')
            .height(FIELD_H)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          if (this.error.length > 0) {
            this.errorRow()
          } else {
            /*
             * 常驻一行说明：登录全程不显示网页，走的是 App 自己的登录协议；
             * 开了两步验证的账号会再弹一个验证码面板。
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
     * **两步验证的半模态面板**（需求："点登录若要求 2FA，就弹系统沉浸光感半模态面板"）。
     *
     * 外观见 verifySheetOptions：API 26+ 走 `SheetOptions.systemMaterial`（系统按
     * ImmersiveMaterial 画面板的底色/边框/阴影），老机器退回玻璃底 + 模糊。
     */
    .bindSheet(this.verifyOpen, this.verifySheet(), this.verifySheetOptions())
  }

  /**
   * 提交：主按钮 = 拿账号密码走 **App 协议登录（CAA）**（见 onCaaLogin / core/mobileapi/CaaSession）。
   *
   * 返回值三态：空串 = 成功；{@link LOGIN_NEEDS_CODE} = 要两步验证（弹面板）；
   * 其他 = 失败原因（画在密码框下面）。
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
     * 注意：输入框必须直连状态（见 username 那段注释），否则 `password = ''`
     * 引起的那次刷新会把两个框的文本一起覆盖成空快照 —— "账号也被清掉"的老毛病。
     */
    const typed: string = this.password;
    hilog.info(DOMAIN, TAG, 'submit: user len=%{public}d pass len=%{public}d',
      this.username.length, this.password.length);
    this.password = '';
    this.onCaaLogin(this.username.trim(), typed)
      .then((message: string): void => {
        this.busy = false;
        if (message === LOGIN_NEEDS_CODE) {
          // 账号密码过了，但 IG 要两步验证：弹半模态面板收验证码。
          this.verifyCode = '';
          this.verifyError = '';
          this.verifyOpen = true;
          return;
        }
        if (message.length === 0) {
          // 真的登录成功了：会话已进 Cookie 罐，宿主那边会重读登录态。
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
