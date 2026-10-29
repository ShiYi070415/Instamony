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
  BrandSurfaceModifier,
  immersiveMaterial,
  MaterialLabelButton,
  SurfaceModifier
} from './MaterialSurface';
import {
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_MATERIAL_THICKNESS
} from '../core/AppSettings';
import { PlatformCap } from '../core/PlatformCap';
// "切回前台就重登一次"的监听（见 onAppVisibility / retryAfterApproval）。
import { AppLifecycle } from '../core/AppLifecycle';
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
 * "在另一台设备上同意"的三个数字（毫秒 / 次数）。
 *
 * `APPROVAL_RETRY_DELAY_MS`：切回前台后等一会儿再重登（界面还在恢复，用户也可能只是瞥一眼）；
 * `APPROVAL_RETRY_MAX`：重登最多几次（每次都是一发真登录，不能连发）；
 * `APPROVAL_RETRY_GAP_MS`：两次重登至少隔多久（防止来回切窗把登录打成连发）。
 */
const APPROVAL_RETRY_DELAY_MS: number = 1500;
const APPROVAL_RETRY_MAX: number = 3;
const APPROVAL_RETRY_GAP_MS: number = 6000;

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
  /** 面板上要不要显示"也可以在已登录的客户端里同意"那句提示（见 startApprovalWatch）。 */
  @State private approvalPossible: boolean = false;
  /** 切回前台后那次重登的定时器 id（见 onAppVisibility）。0 = 没有。 */
  private approvalRetryTimer: number = 0;
  /** 这一轮已经重登过几次（见 retryAfterApproval）。 */
  private approvalRetries: number = 0;
  /** 上一次重登的时刻（见 APPROVAL_RETRY_GAP_MS）。 */
  private approvalRetryAt: number = 0;

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
    // 选中态透明：Toggle 默认选中色是主题强调色，点一下会闪一块蓝（材质版必须显式清掉）。
    .selectedColor(Color.Transparent)
    /*
     * **实色按钮也走沉浸光感**（需求："实色按钮也要用沉浸光感效果，用华为官方那种蓝色"）：
     * 颜色交给材质（BrandSurfaceModifier → 品牌蓝 #0A59F7），背景保持透明，
     * 触摸那道白光才浮在蓝底之上可见 —— 以前是 `.backgroundColor(不透明 accent)` 盖在
     * 材质上面，光感全被挡住了。
     */
    .attributeModifier(new BrandSurfaceModifier(this.materialThickness))
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
   * 组成：说明 + 胶囊验证码输入框 + 错误 + 「验证并登录」主按钮（沉浸光感材质）+「取消」。
   * 面板背景由 `SheetOptions.systemMaterial` 交给系统画（见 build 里的 bindSheet），
   * 所以这里**不再铺自己的底色**；只有在不支持沉浸材质的机器上才退回"玻璃底 + 模糊"。
   *
   * **标题不在这里画**：走半模态自带的 `SheetOptions.title`（需求："2FA 面板的标题接入
   * hds title"），由系统按 HDS 标题样式画在面板顶部 —— 和设置页那两个代理面板同一套做法
   * （见 SettingsPanel.proxySheetOptions）。自绘 Text 既对不齐规范，也会和系统标题重复。
   *
   * **面板里所有材质控件都不发光**（需求："2FA 面板禁用触摸发光"）：见下面
   * `SurfaceModifier(..., lightEffect = false)` 与「取消」那颗的 `lightEffect: false`。
   */
  @Builder
  verifySheet() {
    Column({ space: 14 }) {
      Text($r('app.string.login_verify_hint'))
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
      /*
       * **"也可以在那台设备上同意"**（需求："2FA 过程中可以在官方客户端同意本次登录…
       * 可以的话需要添加提示文本"）。
       *
       * 只在**这次登录确实提供了这条路**时才显示（`approvalPossible`，来自
       * `CaaSession.approvalAvailable`）—— 不显示一句做不到的话。
       * 显示的同时 startApprovalWatch 已经在轮询，那边一同意这里就会自己继续（见 finishByApproval）。
       */
      if (this.approvalPossible) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.checkmark_shield'))
            .fontSize(13)
            .fontColor([$r('app.color.accent')])
          Text($r('app.string.login_verify_approval_hint'))
            .fontSize(12)
            .lineHeight(18)
            .fontColor($r('app.color.accent'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
      Stack({ alignContent: Alignment.Center }) {
        // 材质底板（和登录页其它输入框同一套：胶囊 + 沉浸光感），但**不发光**（见上）。
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
        }
        .width('100%')
        .height(FIELD_H)
        .padding(0)
        .borderRadius(FIELD_H / 2)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.materialThickness, false, true, false, false))
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
      .selectedColor(Color.Transparent)
      /*
       * 也和登录按钮同一套：**实色 + 沉浸光感**（品牌蓝交给材质），见 mainButton 的说明。
       * 另外这一颗按需求**关掉光感**（"2FA 面板禁用触摸发光"），所以 lightEffect 传 false。
       */
      .attributeModifier(new BrandSurfaceModifier(this.materialThickness, false))
      .enabled(!this.verifyBusy)
      .onChange((): void => {
        this.submitVerifyCode();
      })

      // 「取消」也不发光（需求："2FA 面板禁用触摸发光"，见 MaterialLabelButton.lightEffect）。
      MaterialLabelButton({
        labelRes: $r('app.string.login_verify_cancel'),
        fullWidth: true,
        fontSize: 15,
        lightEffect: false,
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
   *
   * 两处按需求定：
   *   · **标题走半模态自带的 `title`**（HDS 标题样式，和代理面板一致），不再自绘；
   *   · **面板材质不发光**：`immersiveMaterial(..., lightEffect = false)` —— 手指按在面板上
   *     不会出现那道光（需求："2FA 面板禁用触摸发光"）。
   */
  private verifySheetOptions(): SheetOptions {
    const options: SheetOptions = {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      preferType: SheetType.BOTTOM,
      // 标题交给系统画（HDS 标题样式），见上面那段说明。
      title: { title: $r('app.string.login_verify_title') },
      onDisappear: (): void => {
        this.verifyError = '';
        // 面板关了：不再盯着"切回来重登"（见 stopApprovalWatch）。
        this.stopApprovalWatch();
        /*
         * **面板关掉就把登录按钮的转圈收掉**（需求：弹面板期间登录按钮一直转）。
         *
         * 弹面板时 `busy` 是**故意不收**的（见 submit）：用户从面板上看得出"这一发还在走"。
         * 但面板一旦被关掉（取消 / 下滑 / 返回键）那一发就结束了，按钮必须回到"登录"，
         * 否则登录页会一直停在转圈上、点也点不动。
         */
        if (this.busy) {
          this.busy = false;
        }
      }
    };
    if (this.sheetMaterialOn()) {
      // 第 4 个参数 = 光感交互反馈，第 5 个 = 交互形变；这里只关光感（需求），形变保留。
      options.systemMaterial = immersiveMaterial(this.materialThickness, true, true, false);
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
    // 走"交码"这条路了：先别插"切回来重登"（见 stopApprovalWatch）。
    this.stopApprovalWatch();
    this.onCaaVerify(this.verifyCode.trim())
      .then((message: string): void => {
        this.verifyBusy = false;
        if (message.length === 0) {
          // 验证码过了、会话也进罐了：收面板 + **把登录按钮那圈 Loading 停掉**
          // （这一发到此结束，页面马上会被宿主换成主界面）。
          this.verifyOpen = false;
          this.verifyCode = '';
          this.busy = false;
          this.onSignedIn();
          return;
        }
        this.verifyError = message;
        // 码不对：提示还在（那边同意、切回来一样能继续）。
        this.approvalPossible = true;
      })
      .catch((error: Error): void => {
        this.verifyBusy = false;
        this.verifyError = `验证出错：${error.message}`;
      });
  }

  /* ------------------------------------------- 在另一台设备上同意（login approval） */

  /**
   * **"在另一台设备上同意"**（需求："2FA 过程中可以在官方客户端同意本次登录，
   * 有部分实现同意后自动登录吗"）。
   *
   * ## 为什么**不轮询**（真机实测 2026-10-30）
   * 试过照真机 App 的节奏去打 `com.bloks.www.two_step_verification.has_been_allowed.async`
   * （每 7.5 秒一发）。那一发本身是通的 —— 响应 `status: ok`、`is_loading: false`，
   * 说明端点和参数都对。**但用户在 Instagram 官方客户端点"同意"时，客户端直接说
   * "这个登录请求已失效"**，挂小窗秒开也一样。也就是说：我们一直去"看对方同意了吗"，
   * 反而把那条待确认的请求搅掉了。
   *
   * 所以现在**一条请求都不发**：
   *   · 面板上直接告诉用户可以"去已登录的客户端同意"（见 approvalPossible）；
   *   · 由"切回本应用"这个动作触发**一次重新登录**（见 retryAfterApproval）——
   *     同意之后 IG 会放行这台设备，同一份账号密码再登一次就不再要 2FA；
   *   · 重登次数封顶（APPROVAL_RETRY_MAX），不会把登录做成连发。
   */
  private startApprovalWatch(): void {
    /*
     * 这里只做界面上的事：把提示亮出来 + 记下面板是开着的。
     * 真正的"检查"在 retryAfterApproval，而它由"切回前台"触发（见 onAppVisibility）。
     */
    this.approvalPossible = true;
    this.approvalRetries = 0;
    hilog.info(DOMAIN, TAG, 'approval: waiting for the user to approve elsewhere');
  }

  /** 面板关掉 / 切走时收尾（不再需要"切回来就重登"）。 */
  private stopApprovalWatch(): void {
    this.approvalPossible = false;
    if (this.approvalRetryTimer !== 0) {
      clearTimeout(this.approvalRetryTimer);
      this.approvalRetryTimer = 0;
    }
  }

  /**
   * **切回前台了 → 重登一次看看"那边同意了吗"**。
   *
   * 为什么用"重登"代替轮询：见上面 startApprovalWatch 的实测结论（轮询会把请求搅失效）。
   * 同意之后这台设备就被放行了，同一份账号密码再登一次会直接给会话。
   *
   * 三档收尾：
   *   · 成功（空串）→ 关面板、停转圈、切主界面；
   *   · 仍然要验证码 → 面板留着（提示一句"还没检测到"），用户可以直接输码，也可以再确认一次；
   *   * 其它原因（密码错/被限流）→ 照实显示。
   *
   * @returns 真的发起了重登吗（false = 现在还不需要/不能重登）
   */
  private retryAfterApproval(): boolean {
    if (!this.verifyOpen || this.approvalRetries >= APPROVAL_RETRY_MAX) {
      return false;
    }
    if (this.verifyBusy || this.busy) {
      // 面板里正在交码 / 登录那一发还在跑：别插一发进去。
      return false;
    }
    const now: number = Date.now();
    if (now - this.approvalRetryAt < APPROVAL_RETRY_GAP_MS) {
      // 刚试过（用户来回切窗）：别把登录打成连发。
      return false;
    }
    this.approvalRetryAt = now;
    this.approvalRetries = this.approvalRetries + 1;
    hilog.info(DOMAIN, TAG, 'approval: retry login after returning (%{public}d/%{public}d)',
      this.approvalRetries, APPROVAL_RETRY_MAX);
    this.verifyError = '';
    this.busy = true;
    this.onCaaLogin(this.username.trim(), this.password)
      .then((message: string): void => {
        if (message.length === 0) {
          this.verifyOpen = false;
          this.verifyCode = '';
          this.busy = false;
          this.approvalPossible = false;
          this.onSignedIn();
          return;
        }
        this.busy = false;
        if (message === LOGIN_NEEDS_CODE) {
          // 服务器还没认（或者用户还没去同意）：面板留着，提示一句，继续等下一次切回来。
          this.verifyError = '还没检测到「已同意」。可以在 Instagram 客户端确认后再切回来，'
            + '也可以直接在这里输验证码。';
          return;
        }
        this.verifyError = message;
      })
      .catch((error: Error): void => {
        this.busy = false;
        this.verifyError = `登录出错：${error.message}`;
      });
    return true;
  }

  /**
   * 应用可见性变化（`AppLifecycle` 的监听，见 aboutToAppear）。
   *
   * 用户去官方客户端同意时我们必然退到后台；**一回来就重登一次**是最省事也最可靠的收尾
   * （后台的定时器真机根本靠不住：短时任务额度经常申请不到，进程随后就被冻结）。
   */
  private onAppVisibility: (foreground: boolean) => void = (foreground: boolean): void => {
    if (!foreground) {
      return;
    }
    if (!this.verifyOpen) {
      return;
    }
    // 稍等一下再打：切回来的那一瞬间界面还在恢复，而且用户可能只是瞥一眼。
    if (this.approvalRetryTimer !== 0) {
      clearTimeout(this.approvalRetryTimer);
    }
    this.approvalRetryTimer = setTimeout((): void => {
      this.approvalRetryTimer = 0;
      this.retryAfterApproval();
    }, APPROVAL_RETRY_DELAY_MS);
  };

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
   * 组件被销毁：**把"等同意"的轮询定时器收掉**。
   *
   * 不收拾的话，登录成功后整页被宿主换掉，那个 `setTimeout` 还会再跳一次并调
   * `onApprovalTick` —— 白打一发请求（而且那一发已经没有待验证的登录了）。
   */
  /** 注册"切回前台"的监听（见 onAppVisibility：回来就重登一次）。 */
  aboutToAppear(): void {
    AppLifecycle.addVisibilityListener(this.onAppVisibility);
  }

  aboutToDisappear(): void {
    this.stopApprovalWatch();
    AppLifecycle.removeVisibilityListener(this.onAppVisibility);
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
     * **密码不清**（需求："登录页点击登录时密码不清除"）。
     *
     * 上一版是"点下去就清空密码框"，账密对了但要走两步验证时，用户从面板退回来想重登一次
     * 就得重新敲密码 —— 而这恰恰是最常见的一步（2FA 输错、验证码过期）。
     * 密码本来就只在内存里（`@State`，不落盘），留在框里不会多存任何东西。
     */
    const typed: string = this.password;
    hilog.info(DOMAIN, TAG, 'submit: user len=%{public}d pass len=%{public}d',
      this.username.length, this.password.length);
    this.onCaaLogin(this.username.trim(), typed)
      .then((message: string): void => {
        if (message === LOGIN_NEEDS_CODE) {
          /*
           * 账号密码过了，但 IG 要两步验证：弹半模态面板收验证码。
           *
           * **`busy` 故意不收**（需求："弹出 2FA 面板登录页的登录按钮保持转圈"）：
           * 这一发还没走完（验证码没提交），登录按钮停在那圈 Loading 上才说明"在等验证码"，
           * 而不是"点完了什么都没发生"。面板一关就由 verifySheetOptions().onDisappear
           * 把它收回来。
           */
          this.verifyCode = '';
          this.verifyError = '';
          this.verifyOpen = true;
          /*
           * **告诉用户"也可以去客户端同意"**（需求见 startApprovalWatch）：
           * 不轮询（实测那样会把待确认请求搅失效），由"切回本应用"触发重登。
           */
          this.startApprovalWatch();
          return;
        }
        this.busy = false;
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
