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
import { CaaLoginCard } from './CaaLoginCard';
import {
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';
// WEB_LOGIN_NEEDS_CODE / WEB_LOGIN_NEEDS_WEB：密码过了之后"还要再走一步"的两种情形
// （能在这里输验证码 / 只能去网页里验），见 core/WebLogin。
import { WEB_LOGIN_NEEDS_CODE, WEB_LOGIN_NEEDS_WEB } from '../core/WebLogin';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'LoginPage';
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
   * **这个账号只能去网页里验**（`showAccountRecoveryModal`，见 core/WebLogin 的
   * `WEB_LOGIN_NEEDS_WEB`）：把网页亮出来，用户在 IG 页面上走完验证。
   */
  onWebVerify: () => void = (): void => {
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
  /** 面板处于"只能去网页验"那一档（见 onWebVerify / WEB_LOGIN_NEEDS_WEB）。 */
  @State private verifyWeb: boolean = false;
  /**
   * **App 协议登录（CAA）面板**开没开（内容见 components/CaaLoginCard）。
   *
   * 为什么是一个面板而不是又一套输入框：这页的表单是"交给隐藏网页去登录"那条路，
   * 实验的 CAA 路要自己维护状态（含两步验证码），塞进同一页会互相打架。
   * 面板里的组件和设置页用的是**同一个** CaaLoginCard，流程只此一份。
   */
  @State private caaOpen: boolean = false;

  /*
   * 诊断（临时）：登录页这一整个 struct 会不会被销毁重建。
   *
   * 用户报"点登录后账号密码一起被清空"。若这两个回调成对出现，说明状态真的丢了（实例重建）；
   * 若只有下面 submit 那两行、没有这对回调，说明状态没丢 —— 是输入框把文本丢了（显示问题，
   * 已按官方文档改成 `$$` 双向绑定）。定位完就可以把这三行日志删掉。
   */
  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'DIAG login page appear');
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, TAG, 'DIAG login page disappear (state will be lost)');
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
   * **半模态两步验证面板**（需求：跳一个半模态沉浸光感组件做 2FA）。
   *
   * 组成：标题 + 一句说明 + 胶囊验证码输入框 + 错误 + 「验证」主按钮（沉浸光感材质）
   * + 「取消」。面板本身用「玻璃底 + 背景模糊」那套（和 app 其它卡片一致），
   * 主按钮是完整材质（SurfaceModifier 挂在 Toggle 上）。
   */
  @Builder
  verifySheet() {
    Column({ space: 14 }) {
      Text(this.verifyWeb ? $r('app.string.login_verify_web_title')
        : $r('app.string.login_verify_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
      Text(this.verifyWeb ? $r('app.string.login_verify_web_hint')
        : $r('app.string.login_verify_hint'))
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
      /*
       * 两种面板内容（同一层玻璃，不做第二个弹窗）：
       *   · 默认：验证码输入框 + 「验证」（IG 给了 two_factor_identifier 时走这条）；
       *   · verifyWeb：说明 + 「去网页完成验证」（只回 showAccountRecoveryModal 的账号走这条，
       *     见 core/WebLogin 的 WEB_LOGIN_NEEDS_WEB —— 那种情况输验证码必然"无效参数"）。
       */
      if (!this.verifyWeb) {
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
      }

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
          Text(this.verifyWeb ? $r('app.string.login_verify_web_action')
            : $r('app.string.login_verify_action'))
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
        if (this.verifyWeb) {
          // 去网页里完成 IG 自己的验证：收起面板，把网页亮出来。
          this.verifyOpen = false;
          this.onWebVerify();
          return;
        }
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

  /**
   * **App 协议登录（CAA）面板**：内容就是把 components/CaaLoginCard 放进玻璃底里。
   *
   * 为什么不在这页再写一套输入框：CAA 路要自己维护"密码 → 验证码"两段状态，
   * 和这页表单（交给隐藏网页登录）混在一起会互相清空。组件复用保证设置页与登录页
   * 走的是同一条流程、同一份错误文案。
   */
  @Builder
  caaSheet() {
    Column({ space: 10 }) {
      CaaLoginCard({
        onSignedIn: (): void => {
          this.caaOpen = false;
          this.onSignedIn();
        }
      })
      MaterialLabelButton({
        labelText: '取消',
        fullWidth: true,
        fontSize: 15,
        onTap: (): void => {
          this.caaOpen = false;
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
        // core 说"这个账号只能去网页验"（拿不到 two_factor_identifier）：面板切到那一档。
        if (message === WEB_LOGIN_NEEDS_WEB) {
          this.verifyWeb = true;
          this.verifyError = '';
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
          /*
           * **网页登录**（用户报："新增账号页没有网页登录选项"）。
           *
           * 之前这页只有「登录」（无头，账号密码交给隐藏网页）和「注册新账号」两颗按钮，
           * 而"网页登录"只存在于 2FA 面板的兜底档里 —— 于是新增账号这条支线在
           * "IG 要人工确认"时就无路可走。补一颗常驻入口：点它把网页亮出来，
           * 用户在 IG 自己的页面里完成登录/验证（那条路 SPA 会正常弹它的模态框）。
           */
          MaterialLabelButton({
            labelRes: $r('app.string.login_web_short'),
            fullWidth: true,
            fontSize: 15,
            onTap: (): void => {
              this.onWebVerify();
            }
          })
          /*
           * **App 协议登录（实验）**：走 IG 自己的登录协议（CAA），拿到的是**设备级会话**
           * （见 core/mobileapi/CaaSession）。和上面那颗「网页登录」互补：
           *   · 网页登录：会话来自浏览器 Cookie，IG 视作网页客户端；
           *   · 这里：USDID 设备签名 + attestation，和真机 App 同一条路。
           * 放在半模态面板里，成不成都不影响这页原有的登录表单。
           */
          MaterialLabelButton({
            labelText: 'App 协议登录（实验）',
            fullWidth: true,
            fontSize: 15,
            onTap: (): void => {
              this.caaOpen = true;
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
    // CAA 面板（实验路，同上那套半模态外观）。
    .bindSheet(this.caaOpen, this.caaSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      preferType: SheetType.BOTTOM,
      backgroundColor: Color.Transparent
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
     *
     * 注意：输入框必须直连状态（见 username 那段注释），否则 `password = ''`
     * 引起的那次刷新会把两个框的文本一起覆盖成空快照 —— "账号也被清掉"的老毛病。
     */
    const typed: string = this.password;
    // 诊断（临时）：状态里此刻到底有没有字。配合上面的 appear/disappear 判"真丢"还是"没显示"。
    hilog.info(DOMAIN, TAG, 'DIAG submit: user len=%{public}d pass len=%{public}d',
      this.username.length, this.password.length);
    this.password = '';
    this.onWebLogin(this.username, typed)
      .then((message: string): void => {
        this.busy = false;
        if (message === WEB_LOGIN_NEEDS_CODE) {
          // 账号密码过了，但 IG 要再走一步验证：弹半模态面板收验证码。
          this.verifyCode = '';
          this.verifyError = '';
          this.verifyWeb = false;
          this.verifyOpen = true;
          return;
        }
        if (message === WEB_LOGIN_NEEDS_WEB) {
          // 同一个面板、另一档内容：这个账号要去网页里完成 IG 自己的验证。
          this.verifyCode = '';
          this.verifyError = '';
          this.verifyWeb = true;
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
