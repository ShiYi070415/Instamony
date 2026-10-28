/*
 * **App 内密码登录卡片**（CAA 路，见 core/mobileapi/CaaSession）。
 *
 * 为什么单独一个组件：它要出现在**两处** —— 未登录时的整页登录页（LoginPage 的底栏入口，
 * 走半模态面板）和已登录后的设置页。两处共用同一份输入框、同一条流程、同一串步骤显示，
 * 否则"实验登录在登录页能用、在设置页又坏了"这种不一致几乎必然发生。
 *
 * 交互要点：
 *   · 服务端要求两步验证时，**同一个组件里**多出「验证码」一行（`needsCode`），
 *     不需要跳到别的地方 —— 现场（context_data）由 `CaaLogin` 留在内存里；
 *   · 每一步的 HTTP 状态都显示出来（`usdid 200 → attestation 200 → …`）：
 *     真机上 hilog 常被冲掉、测试者也没有 hdc，界面是唯一的诊断通道；
 *   · 成功后**清空密码与验证码**，只通过 `onSignedIn` 通知宿主。
 */

import { CaaOutcome, CaaSession } from '../core/mobileapi/CaaSession';
import { CaaLogin } from '../core/mobileapi/CaaLogin';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 输入框高度（跟着登录页的 42 走，两处观感一致）。 */
const FIELD_HEIGHT: number = 42;
const FIELD_RADIUS: number = 14;
const DOMAIN: number = 0xFF00;
const TAG: string = 'CaaLoginCard';

@Component
export struct CaaLoginCard {
  /** 登录成功（会话已经在 Cookie 罐里）。宿主用它重读登录态 / 关掉面板。 */
  onSignedIn: () => void = (): void => {
  };

  @State private user: string = '';
  @State private pass: string = '';
  @State private code: string = '';
  @State private busy: boolean = false;
  @State private status: string = '';
  @State private steps: string = '';
  /** 服务端要求两步验证：验证码输入框与按钮文案随之变化。 */
  @State private needsCode: boolean = false;
  /** 粘贴会话导入（备用路）的折叠状态与内容。 */
  @State private pasteOpen: boolean = false;
  @State private pasteText: string = '';

  build() {
    Column({ space: 10 }) {
      Text('用账号密码直接登录（实验）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
      Text('走 IG 自己的 App 登录协议，成功后直接进已登录状态。密码只在本机内存里加密后才出网，'
        + '不会被保存。要验证码时会多出「验证码」一行。')
        .fontSize(11)
        .lineHeight(16)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')

      this.userField()
      this.passField()
      if (this.needsCode) {
        this.codeField()
      }

      Button(this.needsCode ? '提交验证码' : '登录')
        .width('100%')
        .height(FIELD_HEIGHT)
        .fontSize(15)
        .enabled(!this.busy)
        .backgroundColor($r('app.color.accent'))
        .fontColor(Color.White)
        .borderRadius(FIELD_HEIGHT / 2)
        .onClick((): void => {
          if (this.needsCode) {
            this.verify();
          } else {
            this.submit();
          }
        })

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(12)
          .fontColor(this.needsCode ? $r('app.color.accent') : $r('app.color.secondary_text'))
          .width('100%')
      }
      if (this.steps.length > 0) {
        Text(this.steps)
          .fontSize(11)
          .fontColor($r('app.color.secondary_text'))
          .width('100%')
      }
      /*
       * **解析器自检**（不联网、不用账号）。
       *
       * 真机上跑不了单测，而"登录成功之后解不出会话"只会在真账号上暴露。点一下就能确认
       * 解析器本身没问题（aac / 错误文案 / login_response / 两步验证上下文四项）。
       */
      Text('先跑解析自检（不联网）')
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .width('100%')
        .onClick((): void => {
          this.status = CaaLogin.selfTest();
          this.steps = '';
        })

      /*
       * **设备/网络前检**（不填密码）：只跑 USDID → attestation → aac 三步。
       * 它把"设备/网络这侧不通"和"账号不对"分开 —— 前检绿而登录挂，就不用再怀疑协议。
       */
      Text('设备/网络前检（不填密码）')
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .width('100%')
        .onClick((): void => {
          if (this.busy) {
            return;
          }
          this.busy = true;
          this.status = '正在前检…（不提交密码）';
          this.steps = '';
          CaaSession.preflight().then((outcome: CaaOutcome): void => {
            this.busy = false;
            this.status = outcome.reason;
            this.steps = outcome.steps;
          }).catch((error: Error): void => {
            this.busy = false;
            this.status = `前检失败：${error.message}`;
          });
        })

      /*
       * **粘贴会话导入**（备用路）：把电脑上跑出来的 `settings.caa.json` / `session.json`
       * 整份粘进来，直接把**设备级会话**搬进 App。
       *
       * 为什么要留这条：CAA 登录要账号密码、还可能撞验证码；而实时私信/本地通知靠的是
       * **设备级会话本身**。有了这条，即使密码登录那条路还没调通，实时这条线也能单独验。
       */
      /*
       * **复制诊断**：把最近一次的结论 + 逐步现场 + 名字（不含任何密钥）复制出去。
       *
       * 真机上既没有 hdc、hilog 也常被冲掉，失败原因只能靠这段文字带出来。
       */
      Text('复制登录诊断')
        .fontSize(12)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
        .onClick((): void => {
          this.copyDiag();
        })
      Text(this.pasteOpen ? '收起「粘贴会话导入」' : '用已有会话导入（备用，粘贴 settings.caa.json）')
        .fontSize(12)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
        .onClick((): void => {
          this.pasteOpen = !this.pasteOpen;
        })
      if (this.pasteOpen) {
        TextArea({ text: this.pasteText, placeholder: '整份粘贴 JSON（settings.caa.json 或 session.json）' })
          .width('100%')
          .height(96)
          .fontSize(11)
          .padding(10)
          .borderRadius(12)
          .backgroundColor($r('sys.color.comp_background_secondary'))
          .fontColor($r('app.color.primary_text'))
          .placeholderColor($r('app.color.secondary_text'))
          .enabled(!this.busy)
          .onChange((text: string): void => {
            this.pasteText = text;
          })
        Button('导入这份会话')
          .width('100%')
          .height(FIELD_HEIGHT)
          .fontSize(15)
          .enabled(!this.busy)
          .backgroundColor($r('sys.color.comp_background_secondary'))
          .fontColor($r('app.color.primary_text'))
          .borderRadius(FIELD_HEIGHT / 2)
          .onClick((): void => {
            this.importPasted();
          })
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(18)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  userField() {
    Column({ space: 4 }) {
      Text('Instagram 用户名')
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
      TextInput({ text: this.user, placeholder: '用户名（不带 @）' })
        .type(InputType.Normal)
        .height(FIELD_HEIGHT)
        .width('100%')
        .fontSize(15)
        .padding({ left: 14, right: 14 })
        .borderRadius(FIELD_RADIUS)
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .fontColor($r('app.color.primary_text'))
        .placeholderColor($r('app.color.secondary_text'))
        .caretColor($r('app.color.accent'))
        .enabled(!this.busy)
        .onChange((text: string): void => {
          this.user = text;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  passField() {
    Column({ space: 4 }) {
      Text('密码')
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
      TextInput({ text: this.pass, placeholder: '账号密码' })
        .type(InputType.Password)
        .height(FIELD_HEIGHT)
        .width('100%')
        .fontSize(15)
        .padding({ left: 14, right: 14 })
        .borderRadius(FIELD_RADIUS)
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .fontColor($r('app.color.primary_text'))
        .placeholderColor($r('app.color.secondary_text'))
        .caretColor($r('app.color.accent'))
        .enabled(!this.busy)
        .onChange((text: string): void => {
          this.pass = text;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  codeField() {
    Column({ space: 4 }) {
      Text('两步验证码')
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
      TextInput({ text: this.code, placeholder: '短信 / 验证器 App 里的验证码' })
        .type(InputType.Number)
        .height(FIELD_HEIGHT)
        .width('100%')
        .fontSize(15)
        .padding({ left: 14, right: 14 })
        .borderRadius(FIELD_RADIUS)
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .fontColor($r('app.color.primary_text'))
        .placeholderColor($r('app.color.secondary_text'))
        .caretColor($r('app.color.accent'))
        .enabled(!this.busy)
        .onChange((text: string): void => {
          this.code = text;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 点「登录」：用户名密码 → CAA 登录（成功即把会话种进 Cookie 罐）。 */
  private submit(): void {
    if (this.busy) {
      return;
    }
    const user: string = this.user.trim();
    if (user.length === 0 || this.pass.length === 0) {
      this.status = '用户名和密码都要填';
      return;
    }
    this.busy = true;
    this.status = '正在登录…（一般 5~15 秒）';
    this.steps = '';
    CaaSession.login(user, this.pass).then((outcome: CaaOutcome): void => {
      this.busy = false;
      this.applyOutcome(outcome);
    }).catch((error: Error): void => {
      this.busy = false;
      this.status = `登录失败：${error.message}`;
    });
  }

  /** 点「提交验证码」：把两步验证那条链走完。 */
  private verify(): void {
    if (this.busy) {
      return;
    }
    const code: string = this.code.trim();
    if (code.length === 0) {
      this.status = '先填验证码';
      return;
    }
    this.busy = true;
    this.status = '正在提交验证码…';
    CaaSession.submitCode(code).then((outcome: CaaOutcome): void => {
      this.busy = false;
      this.applyOutcome(outcome);
    }).catch((error: Error): void => {
      this.busy = false;
      this.status = `提交验证码失败：${error.message}`;
    });
  }

  /** 点「导入这份会话」：把粘贴的 JSON 交给 CaaSession（两种形状都收）。 */
  private importPasted(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = '正在导入会话…';
    this.steps = '';
    CaaSession.adoptPasted(this.pasteText).then((outcome: CaaOutcome): void => {
      this.busy = false;
      if (outcome.ok) {
        // 导入成功：把粘贴框清掉（里面是等同密码的东西，别留）。
        this.pasteText = '';
        this.pasteOpen = false;
      }
      this.applyOutcome(outcome);
    }).catch((error: Error): void => {
      this.busy = false;
      this.status = `导入失败：${error.message}`;
    });
  }

  /** 复制登录诊断（只含结论 / 步骤 / 名字，不含 cookie 与 authorization）。 */
  private copyDiag(): void {
    const text: string = CaaSession.diagText();
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data, (err: BusinessError | undefined) => {
        if (err !== undefined && err !== null) {
          hilog.warn(DOMAIN, TAG, 'caa diag copy failed: %{public}s', err.message);
          this.status = `复制失败：${err.message}`;
          return;
        }
        this.status = '诊断已复制，粘给我就行（里面没有密码/会话值）';
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'caa diag copy threw: %{public}s', (error as Error).message);
      this.status = '复制失败（剪贴板不可用）';
    }
  }

  private applyOutcome(outcome: CaaOutcome): void {
    this.status = outcome.reason;
    this.steps = outcome.steps;
    this.needsCode = outcome.needsCode;
    if (outcome.ok) {
      // 成功后不再留密码/验证码（内存里也不留）。
      this.pass = '';
      this.code = '';
      this.onSignedIn();
    }
  }
}
