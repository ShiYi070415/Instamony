/*
 * 视频页底部的**评论输入框**（沉浸光感）。
 *
 * 需求："底部是一个沉静光感输入框，用于添加评论"。这一次只做界面：能打字、能清空、点发送
 * 把内容交给宿主（`onSend`），**不真的发评论**（用户确认过："先只做输入框 UI，不真发"）。
 *
 * ## 光感那一层为什么是 Toggle
 * 官方《沉浸光感–功耗优化》写明生效范围：只有**弹窗类组件与 Slider / Toggle / Select**
 * 能在"全页面"生效，其他组件只在 Navigation/NavDestination **标题栏**或底部 TabBar 里生效。
 * 这个输入框落在页面内容区（屏幕底部），所以玻璃只能由 Toggle 承载 —— 和全 app 那些
 * 材质按钮同一条路（见 MaterialSurface 的文件头）。
 *
 * ## 为什么是"玻璃归玻璃、输入归输入"两层
 * 输入框必须是**真的 TextInput**（能聚焦、能出键盘），而 Toggle 承载材质时它自己是个按钮
 * （会吃点击、吃手势）。所以做成 Stack：
 *   ① 底层一颗空的 Toggle，只负责画材质，`hitTestBehavior(None)` —— 自己不参与命中测试；
 *   ② 顶层是真正的内容（TextInput + 发送），触摸全归它。
 * 这样既拿到了材质，输入又完全正常（不是把 TextInput 塞进 Toggle 当子组件那条险路）。
 *
 * ## 反色关掉
 * 材质默认会跟着背景反色（`colorInvert`），那是给"压在白画面上的按钮"用的。这里的底是
 * 视频画面（常常很亮），反色会让文字和玻璃一起飘。传 false，文字固定走系统前景色资源
 * （明暗主题各一套，见 MaterialSurface 里同一处说明）。
 */

import { SETTING_MATERIAL_THICKNESS, MATERIAL_THICKNESS_ULTRA_THIN } from '../core/AppSettings';
import { SurfaceModifier } from './MaterialSurface';
// 键盘避让：监听 + 量自己的矩形（见 alignToKeyboard）。
import { common } from '@kit.AbilityKit';
import { curves, display, window, UIContext } from '@kit.ArkUI';
import { ComponentUtils } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 玻璃条高度（vp）。 */
const BAR_HEIGHT: number = 44;
/** 胶囊左右内边距（vp）：文字从这儿开始。 */
const INNER_LEFT: number = 16;
/** 发送按钮的宽度（vp）。 */
const SEND_WIDTH: number = 52;
/** 整条相对屏幕左右的外边距（vp）。 */
const DOMAIN: number = 0xFF00;
const TAG: string = 'CommentInputBar';
const SIDE_MARGIN: number = 12;
/** 实测矩形用的组件 id（自校正键盘避让，见 alignToKeyboard）。 */
const BAR_ID: string = 'instarmonyCommentBar';
/** 输入条底边与键盘顶之间留多少（vp）。 */
const KEYBOARD_GAP_VP: number = 10;
/** 实测差额的容差（px）：小于它就不动，免得来回抖。 */
const LIFT_TOLERANCE_PX: number = 6;
/**
 * 整条离屏幕底边的高度（vp）。
 *
 * 这一页是整屏页面（底部安全区也吃进内容里，见 Index 的 ignoreLayoutSafeArea），
 * 所以底部的系统手势条要自己让开。
 *
 * 导出给宿主用：评论浮层里输入条同样带这条让位，它不算"评论详情面板 + 评论输入框"的高度，
 * 宿主算"两块 = 半屏"时要把这一条加回去（见 pages/Index 的 commentsHalfVp）。
 */
export const COMMENT_INPUT_BOTTOM_VP: number = 28;

@Component
export struct CommentInputBar {
  /** 输入框的占位文案（默认「添加评论…」，见资源）。 */
  @Prop hint: Resource = $r('app.string.comments_hint');
  /**
   * 左右留白（vp）。
   *
   * reels 页自己就是整屏页面，所以默认值由它自己留（`SIDE_MARGIN`）；评论浮层里**由外层容器
   * 统一留白**（面板和输入条要等宽，见 pages/Index 的 commentsOverlay），传 0。
   */
  @Prop sideInset: number = SIDE_MARGIN;
  /**
   * 离底边的高度（vp）。
   *
   * reels 页里底部安全区吃进内容里，所以要自己让开手势条（`COMMENT_INPUT_BOTTOM_VP`）；
   * 评论浮层的容器底边已经在窗口底边（比屏幕底边高出一条手势条），再让一次就会偏高 ——
   * 需求要求"输入框可以往下移到和 reels 类页面一样的高度"，所以那儿传 0。
   */
  @Prop bottomInset: number = COMMENT_INPUT_BOTTOM_VP;
  /** 材质厚度（跟设定页联动，和别的材质组件同一份全局设定）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 正在输入的内容（受控：发送后清空）。 */
  @State private draft: string = '';
  /**
   * **自校正**的键盘抬升量（vp）。
   *
   * 为什么不用"键盘高度"直接抬：整屏 NavDestination 底部这一条，框架自身也会抬一部分
   * （实测抬一半：用户报"被输入法盖住一半"），再按全高度加一次就会**跳得很高**。
   * 所以照 components/DirectThreadPage 的做法：量自己的真实矩形，只补**差额**。
   */
  @State private liftVp: number = 0;
  private kbWindow: window.Window | null = null;
  private kbHandler: ((height: number) => void) | null = null;
  private kbPx: number = 0;
  /** 点「发送」：内容交给宿主（这一版宿主只当"还没接"处理，见文件头）。 */
  onSend: (text: string) => void = (text: string): void => {
  };
  /**
   * 草稿变化时回报（可选）。宿主用它做两件事：评论面板打开时把已输入的内容**带过去**
   * （不然用户在页面那条输入框里写了字、点「评论」后内容就没了）。
   */
  onDraft: (text: string) => void = (text: string): void => {
  };
  /**
   * 初始草稿（只在**首次创建**时读，见 draft 的初始化）。
   * 面板打开时把页面那条的草稿传进来，用户就能接着写。
   */
  @Prop initialDraft: string = '';

  /** 有内容才让发送可点（空的按下去没有任何意义）。 */
  aboutToAppear(): void {
    this.watchKeyboard();
    // 宿主给的初始草稿（面板接手页面输入框时用，见 initialDraft）。
    if (this.initialDraft.length > 0 && this.draft.length === 0) {
      this.draft = this.initialDraft;
    }
  }

  aboutToDisappear(): void {
    const win: window.Window | null = this.kbWindow;
    const handler: ((height: number) => void) | null = this.kbHandler;
    if (win !== null && handler !== null) {
      try {
        win.off('keyboardHeightChange', handler);
      } catch (error) {
      }
    }
    this.kbWindow = null;
    this.kbHandler = null;
  }

  /** 听键盘高度：收起时归零，弹出时量一次再校正一次（两步收敛，见 alignToKeyboard）。 */
  private watchKeyboard(): void {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      window.getLastWindow(context).then((win: window.Window): void => {
        this.kbWindow = win;
        this.kbHandler = (height: number): void => {
          this.kbPx = height > 0 ? height : 0;
          if (height <= 0) {
            this.liftVp = 0;
            return;
          }
          this.alignToKeyboard();
        };
        win.on('keyboardHeightChange', this.kbHandler);
      }).catch((): void => {
      });
    } catch (error) {
    }
  }

  /**
   * 按键盘高度抬，仅此而已。
   *
   * 前两版都用实测矩形自校正，两次都出问题（一次盖住一半、一次飞到屏幕顶）—— 根因是
   * getRectangleById 的坐标系/单位与 display.getDefaultDisplaySync().height 不一致，
   * 混算出来的差额是荒谬的大数。这里退回最朴素、最不可能错的规则：
   *   liftVp = min(键盘高度, 屏高 * 0.6)
   * 上限 60% 屏高只是防呆（任何输入法都不会超过它），所以不可能再飞到屏幕顶部。
   * 用户也确认过：让框架一起多抬一点没问题，只要别盖住、别飞走。
   */
  private alignToKeyboard(): void {
    if (this.kbPx <= 0) {
      this.liftVp = 0;
      return;
    }
    try {
      let vp: number = this.getUIContext().px2vp(this.kbPx);
      if (!(vp > 0)) {
        return;
      }
      const dsp: display.Display = display.getDefaultDisplaySync();
      const screenVp: number = this.getUIContext().px2vp(dsp.height);
      const cap: number = screenVp * 0.6;
      if (vp > cap) {
        vp = cap;
      }
      this.liftVp = vp;
      hilog.info(DOMAIN, TAG,
        'keyboard lift=%{public}dvp (kb=%{public}dpx screen=%{public}dvp)',
        Math.round(vp), Math.round(this.kbPx), Math.round(screenVp));
    } catch (error) {
    }
  }

  private canSend(): boolean {
    return this.draft.trim().length > 0;
  }

  /** 发送：把内容交出去并清空输入框。 */
  private submit(): void {
    if (!this.canSend()) {
      return;
    }
    const text: string = this.draft;
    this.draft = '';
    this.onSend(text);
  }

  build() {
    // 外面这层 Column 只负责"左右留白 + 让开底部系统手势条"：宽度给 100% 的是它，
    // 内缩走 padding（给子节点写 width('100%') 再加 margin 会顶出去，这个项目里踩过）。
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        // ① 玻璃底板：不吃触摸（只画材质），见文件头的"两层"说明。
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
        }
        .width('100%')
        .height(BAR_HEIGHT)
        .padding(0)
        .borderRadius(BAR_HEIGHT / 2)
        .backgroundColor(Color.Transparent)
        // 选中态透明：Toggle 默认的选中色是主题强调色，不关掉整条会变蓝（同 MaterialSurface）。
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.thickness, false))
        .hitTestBehavior(HitTestMode.None)

        // ② 真正的内容：输入 + 发送。整体 Transparent（不阻塞、也不抢兄弟节点的手势），
        //    其中 TextInput 自己会正常接收焦点与键盘。
        Row() {
          TextInput({ placeholder: this.hint, text: this.draft })
            .fontSize(15)
            // 正文字色走**应用自己的主题资源**（浅色模式深字、深色模式浅字）：
            // `sys.color.*` 跟的是系统配色，和应用的材质/资源一旦不一致，字就飘了。
            .fontColor($r('app.color.primary_text'))
            .caretColor($r('app.color.accent'))
            /*
             * **提示（占位）文字放在最后设**：ArkUI 里 `fontColor` 会连占位文字一起影响，
             * 顺序反了占位色会被吃掉 —— 表现就是"提示文字不跟着浅色/深色模式走"。
             *
             * 颜色用 `comment_muted`（浅色模式 = 浅灰 #A8A8A8，深色模式 = #A8A8A8）。
             */
            .placeholderColor($r('app.color.comment_muted'))
            .placeholderFont({ size: 15 })
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding({ left: 0, right: 8 })
            .height(BAR_HEIGHT)
            .layoutWeight(1)
            .maxLines(1)
            .enterKeyType(EnterKeyType.Send)
            .onChange((value: string): void => {
              this.draft = value;
      this.onDraft(value);
            })
            .onSubmit((): void => {
              this.submit();
            })

          // 发送：**不再叠一层材质**（一条里两层玻璃会糊成一块），只是一颗强调色文字按钮。
          // 没内容可发时是 `comment_muted`（需求："浅色模式下……发送的文本颜色为浅灰色"）。
          Text($r('app.string.comments_send'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.canSend() ? $r('app.color.accent') : $r('app.color.comment_muted'))
            .textAlign(TextAlign.Center)
            .width(SEND_WIDTH)
            .height(BAR_HEIGHT)
            .onClick((): void => {
              this.submit();
            })
        }
        .width('100%')
        .height(BAR_HEIGHT)
        .padding({ left: INNER_LEFT, right: 4 })
        .alignItems(VerticalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height(BAR_HEIGHT)
    }
    .width('100%')
    .padding({ left: this.sideInset, right: this.sideInset, bottom: this.bottomInset })
    // 量自己矩形要用它（见 alignToKeyboard）；位移只补"被键盘挡住的那一截"。
    .id(BAR_ID)
    .translate({ y: -this.liftVp })
    .animation({ duration: 220, curve: curves.springMotion(0.4, 0.9) })
  }
}
