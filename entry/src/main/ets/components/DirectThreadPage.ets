/*
 * 「私信会话」原生页面：消息列表 + 底部悬浮输入条。
 *
 * 版式：进入就定位到最新消息；自己靠右、对方靠左并在"时间段第一条"左侧显示头像；
 * 相邻两条同发送者间隔 ≤2 分钟算一段（段内紧、段间留白）；输入条悬浮在列表之上。
 *
 * 视口：列表**从屏幕最顶端开始**（y=0），顶部给标题栏让出的那 96vp 由 `contentStartOffset`
 * 表达（属于内容、跟着滚动走）—— 停在最上面时第一条消息在栏下方，往后滑时消息从半透明的
 * 标题栏**底下穿过去**，不再被一条硬边界裁掉。
 *
 * 加载更老：**触顶就自动取**（`onReachStart`）；原生 `Refresh` 组件按需求移除
 * （它自带的下拉指示器无法关掉），"刷新动画"由列表顶部那一行加载圈负责（高度 0→36 带补间）。
 * 取回来之后把视口**锚回加载前那条消息**（`scrollToIndex` + 回退标题栏高度），所以位置不变、不闪。
 */

import { display, window, componentUtils } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DirectMessage, DirectThreadView } from '../model/Direct';
import { DirectThreadViewModel } from '../viewmodel/DirectThreadViewModel';
import { CommentInputBar, COMMENT_INPUT_BOTTOM_VP } from './CommentInputBar';
import { ScrollDelta } from '../core/ScrollReport';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectThreadPage';

/**
 * 顶部留白（vp）：把列表推到 HDS 标题栏**毛玻璃蒙层**下面。
 *
 * 不能只按标题栏高度（MINI 约 56vp）留 —— 蒙版比栏本身高（项目里实测标题栏那层毛玻璃约 94vp，
 * 见 pages/Index 里 bottomBuilder 那段注释），留 56vp 时最上面一条消息会被蒙版压住。
 */
const PAGE_TOP_OFFSET: number = 96;
const BOTTOM_OFFSET: number = 92;
const FALLBACK_WIDTH_VP: number = 411;
const SIDE_PADDING: number = 16;
/**
 * 发送成功后"再贴一次底"的延迟（毫秒）。
 *
 * 键盘收起 + 输入条下移是个动画，列表可视高度在这期间一直在变；只在动画开始时贴底会落到
 * 半路（新气泡贴着屏幕顶端），等布局稳定再贴一次才落到底（见 inputOverlay 的 onSend）。
 */
const SEND_SCROLL_SETTLE_MS: number = 260;
const AVATAR_SIZE: number = 28;
const BUBBLE_MAX_RATIO: number = 0.72;
const BUBBLE_GAP_VP: number = 2;
const GROUP_GAP_VP: number = 12;
const GROUP_GAP_MS: number = 2 * 60 * 1000;
/**
 * 顶部那行"加载中"动画的高度（vp）—— **始终占位**，不加载时高度为 0。
 *
 * 为什么要始终占一个 ListItem（而不是 `if (busy)` 才插进去）：列表用
 * `scrollToIndex(added)` 锚回加载前那条消息，条数一变下标就全错位一格
 * （"加载更老以后位置跳一条"）。留一个恒定下标就永远不会错。
 */
const LOADING_ROW_VP: number = 36;
/**
 * 触顶刷新的最小间隔（毫秒）：onReachStart 会在回弹里重复上报，
 * 不加这道闸一次下拉会连发好几页（真机实测连发三发）。
 */
const REACH_COOLDOWN_MS: number = 1200;
/**
 * 贴底后再补几次"仍然贴底"的检查（毫秒）。
 *
 * 为什么需要：气泡里有图片/贴纸，它们是**异步解码**的 —— 解码完高度才变，
 * 而那一刻列表不会自己重新贴底，于是"最新那条"被顶到输入框下面去（用户报的现象）。
 * 这几次延迟检查覆盖"媒体在这段时间内落地"的常见情况；用户手动往上翻时不会抢（见 pinnedToBottom）。
 */
const REPIN_DELAYS_MS: Array<number> = [600, 1500, 3000];
/**
 * 输入条要落在**键盘顶边上方**多少 vp（自校正的目标间隙）。
 *
 * 取 12：比常规的 `COMMENT_INPUT_BOTTOM_VP`（28）小一点 —— 键盘弹起时屏幕已经很挤，
 * 只要不贴着键盘、留一点呼吸就够了。
 */
const KEYBOARD_GAP_VP: number = 12;
/** 自校正最多迭代几次（每次 130ms；近目标处 1:1，通常两三次就收敛）。 */
const ALIGN_MAX_ATTEMPTS: number = 6;
/** 自校正的容差（px）：差距在这个范围内就认为到位了。 */
const ALIGN_TOLERANCE_PX: number = 8;
/** 输入条的节点 id（自校正要靠它量实际位置）。 */
const INPUT_BAR_ID: string = 'dm-thread-input-bar';

@Component
export struct DirectThreadPage {
  vm: DirectThreadViewModel = new DirectThreadViewModel();
  /**
   * **在网页里打开这条会话**（兜底出口）。
   *
   * 三条原生的路都断了（REST 被 IG 挡、没有会话模板、网页抓模板也抓不到）时，页面上给一颗
   * 按钮，把用户送回网页版会话 —— 总比让他盯着一片空白强（这就是接入原生之前的老行为）。
   */
  onOpenWeb: () => void = (): void => {
  };
  onOpenUser: (username: string, userId: string) => void =
    (username: string, userId: string): void => {
    };
  onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
    };
  @State private view: DirectThreadView | null = null;
  @State private pending: Array<DirectMessage> = [];
  @State private status: string = '';
  @State private busy: boolean = false;
  @State private screenWidthVp: number = FALLBACK_WIDTH_VP;
  /** 屏幕高度（vp）——只为诊断日志（对齐输入法坐标系用）。 */
  private windowHeightVp: number = 0;
  /** 屏幕高度（px）：与 `getRectangleById` 的窗口坐标同单位，自校正要用。 */
  private screenHeightPx: number = 0;
  /** 当前键盘高度（px，0 = 收起）——自校正用（避让区/回调给的都是 px）。 */
  private keyboardPx: number = 0;
  /** 自校正当前施加的抬升（px）。 */
  private alignLiftPx: number = 0;
  /**
   * 输入法高度（vp，0 = 没弹起）。
   *
   * 为什么自己听这个：这一页是 `HdsNavDestination` 里的整屏内容，输入法弹起时
   * **窗口那一层的避让没有作用到它**（真机实测：输入条被键盘整条盖住，见修复前的截图）。
   * 所以这里自己听 `keyboardHeightChange`，把**输入条**和**列表**一起抬起来（见 build 里那两处）。
   */
  @State private keyboardVp: number = 0;
  /** 输入法高度回调（销毁时要注销，否则组件没了还在写 @State）。 */
  private keyboardHandler: ((height: number) => void) | null = null;
  private keyboardWindow: window.Window | null = null;
  /** 当前"最新那条"的 id（区分"来新消息"和"往前插历史"）。 */
  private newestId: string = '';
  /**
   * 视图现在是不是贴着底部（用户在读最新的消息）。
   *
   * 用途：媒体晚一步解码、高度变化后要**再贴一次底**；但用户已经往上翻历史时**绝不能抢**
   * （那会把他正在读的位置拽走）。判据放在 onDidScroll 里：向上滚过一小段就不再贴底，
   * 下次"最新那条变了"时重新置回贴底。
   */
  private pinnedToBottom: boolean = true;
  private lastOffsetY: number = 0;
  private readonly listScroller: Scroller = new Scroller();
  private readonly scrollDelta: ScrollDelta = new ScrollDelta();

  aboutToAppear(): void {
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(dsp.width);
      this.windowHeightVp = this.getUIContext().px2vp(dsp.height);
      this.screenHeightPx = dsp.height;
    } catch (error) {
      this.screenWidthVp = FALLBACK_WIDTH_VP;
    }
    // 输入法高度（见 keyboardVp 的说明）：弹起/收起时把输入条与列表一起抬/放。
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      window.getLastWindow(context).then((win: window.Window): void => {
        this.keyboardWindow = win;
        this.keyboardHandler = (height: number): void => {
          this.keyboardPx = height > 0 ? height : 0;
          if (height <= 0) {
            // 键盘收起：抬升清零，输入条回到底部常规位置。
            this.keyboardVp = 0;
            return;
          }
          /*
           * **从"不抬"开始**，让下面那次实测决定要抬多少。
           *
           * 为什么不直接按键盘高度抬：窗口层自己也可能已经避让（实测两种行为都见过），
           * 直接抬就会叠成"输入条飘到屏幕中间"。从 0 起、只补实测差额，两种情况下都对。
           */
          this.keyboardVp = 0;
          this.alignLiftPx = 0;
          // 键盘顶起来以后可视区变了：贴底的那一屏要重新贴一次。
          this.scrollToNewest(false);
          this.alignInputBarToKeyboard(0);
        };
        win.on('keyboardHeightChange', this.keyboardHandler);
      }).catch((): void => {
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'keyboard listener failed: %{public}s', (error as Error).message);
    }
    this.vm.onView = (view: DirectThreadView | null): void => {
      const before: string = this.newestId;
      this.view = view;
      const after: string = view !== null && view.messages.length > 0
        ? view.messages[view.messages.length - 1].id : '';
      this.newestId = after;
      // 只有"最新那条变了"（首屏 / 实时新消息 / 自己发出去）才贴底；
      // 加载更老是往前插，贴底会让页面跳到底部（用户报的闪烁错位就是这个）。
      if (view !== null && after !== before) {
        this.scrollToNewest();
      }
    };
    this.vm.onPending = (items: Array<DirectMessage>): void => {
      this.pending = items;
    };
    this.vm.onStatus = (text: string): void => {
      this.status = text;
    };
    this.vm.onBusy = (busy: boolean): void => {
      this.busy = busy;
    };
    this.syncFromVm();
    this.vm.load()
      .then((): void => {
        this.syncFromVm();
        this.scrollToNewest();
      })
      .catch((): void => {
      });
    this.vm.startPolling((): void => {
      this.scrollToNewest();
    });
  }

  aboutToDisappear(): void {
    this.vm.stopPolling();
    // 注销输入法监听（不注销的话组件没了回调还在跑，去写已释放的 @State）。
    if (this.keyboardWindow !== null && this.keyboardHandler !== null) {
      try {
        this.keyboardWindow.off('keyboardHeightChange', this.keyboardHandler);
      } catch (error) {
      }
      this.keyboardHandler = null;
      this.keyboardWindow = null;
    }
    // 滚动/收圈那几个 setTimeout（审计项 A2）：销毁后不能再碰 listScroller 与 @State。
    for (let index: number = 0; index < this.scrollTimers.length; index++) {
      clearTimeout(this.scrollTimers[index]);
    }
    this.scrollTimers = [];
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  /**
   * 把输入条校正到"键盘顶边上方 `KEYBOARD_GAP_VP`"的位置（反馈式自校正，最多 `ALIGN_MAX_ATTEMPTS` 次）。
   *
   * ## 为什么不是"按键盘高度一次算准"
   * 实测（本机 1280×2832px / 365.7×809.1vp）：输入条被键盘盖住 1043px 时按 1:1 补 1043px，
   * 它会**跑到键盘上方 903px** —— "我补多少"和"它实际抬多少"在**大偏移**下约 1:1.87
   * （窗口那层自己也避让，两者叠加），但在**目标附近是 1:1**（试过：559px→399px 这一段，
   * 每减 160px 过冲就少 161px）。
   *
   * 所以这里用最简单的反馈：`抬升 += 还差多少`，量一次补一次。近目标处一步到位，
   * 第一发的大过冲（130ms）用户看不见。**不用两点解直线**：那条线在大偏移处并不直
   * （实测按它解出来的 559px 反而把过冲留在 -419px）。
   */
  private alignInputBarToKeyboard(attempt: number): void {
    if (this.keyboardPx <= 0 || attempt > ALIGN_MAX_ATTEMPTS) {
      return;
    }
    const need: number = this.measureAlignNeedPx();
    if (Number.isNaN(need)) {
      // 量不到（还没布局出来）：等下一次事件。
      return;
    }
    hilog.info(DOMAIN, TAG, 'input bar align try=%{public}d need=%{public}dpx lift=%{public}dpx',
      attempt, Math.round(need), Math.round(this.alignLiftPx));
    if (Math.abs(need) <= ALIGN_TOLERANCE_PX) {
      return;
    }
    const next: number = this.alignLiftPx + need;
    this.alignLiftPx = next > 0 ? next : 0;
    this.keyboardVp = this.getUIContext().px2vp(this.alignLiftPx);
    const again: number = attempt + 1;
    this.scrollTimers.push(setTimeout((): void => {
      this.alignInputBarToKeyboard(again);
    }, 130));
  }

  /**
   * 还差多少 px 才到位（>0 = 被键盘盖住、要往上抬；<0 = 抬过头了）。
   *
   * 量不到（节点还没布局）给 NaN。单位统一成 **px**（`getRectangleById` 的窗口坐标就是 px）。
   */
  private measureAlignNeedPx(): number {
    try {
      const info: componentUtils.ComponentInfo =
        this.getUIContext().getComponentUtils().getRectangleById(INPUT_BAR_ID);
      const barBottomPx: number = info.windowOffset.y + info.size.height;
      const keyboardTopPx: number = this.screenHeightPx - this.keyboardPx;
      const density: number =
        this.windowHeightVp > 0 ? this.screenHeightPx / this.windowHeightVp : 3.5;
      return KEYBOARD_GAP_VP * density - (keyboardTopPx - barBottomPx);
    } catch (error) {
      return Number.NaN;
    }
  }

  private syncFromVm(): void {
    this.view = this.vm.viewNow();
    this.pending = this.vm.pendingNow();
    this.busy = this.vm.busyNow();
  }

  private allMessages(): Array<DirectMessage> {
    if (this.view === null) {
      return this.pending;
    }
    return this.view.messages.concat(this.pending);
  }

  /**
   * 贴到最新那条（"最新消息显示在输入框上方"）。
   *
   * @param force true = 不管用户在哪都贴底（首屏 / 来了新消息 / 自己发出去时用）；
   *              false = **只在用户本来就贴着底部时**才贴（媒体晚到、键盘顶起这类"顺带重排"用，
   *              免得把正在翻历史的用户拽走）。
   */
  private scrollToNewest(force: boolean = true): void {
    if (force) {
      this.pinnedToBottom = true;
    }
    const run: () => void = (): void => {
      if (!this.pinnedToBottom) {
        return;
      }
      try {
        this.listScroller.scrollEdge(Edge.Bottom);
      } catch (error) {
      }
    };
    this.scrollTimers.push(setTimeout(run, 0));
    this.scrollTimers.push(setTimeout(run, 60));
    this.scrollTimers.push(setTimeout(run, 200));
    /*
     * 再补几次"仍然贴底"的检查：气泡里的图片/贴纸是异步解码的，解码完高度才变，
     * 那一刻列表不会自己重新贴底 —— 不补的话最新那条会被顶到输入框下面（用户报的现象）。
     */
    for (let index: number = 0; index < REPIN_DELAYS_MS.length; index++) {
      this.scrollTimers.push(setTimeout(run, REPIN_DELAYS_MS[index]));
    }
  }

  /**
   * 这些裸 `setTimeout` 的句柄（审计项 A2：以前既没句柄、`aboutToDisappear` 也没清）。
   *
   * 组件销毁后它们仍会跑：`scrollToNewest` 那三个去读已放掉的 `listScroller`，
   * 8 秒兜底那个会把新一次加载的兜底定时器提前清掉。
   */
  private scrollTimers: Array<number> = [];
  /** 8 秒兜底那个定时器（见 loadOlderKeepPosition / settleRefresh）。 */
  private settleTimer: number = -1;
  /** 上一次触顶刷新的时刻（毫秒；见 REACH_COOLDOWN_MS）。 */
  private lastReachAtMs: number = 0;

  /**
   * 取更老那批，并把视口**锚回加载前的那条消息**（需求："加载后页面位置保持不变"）。
   *
   * 加载前记住条数；加载后"新增的条数"就是前面插进来多少条，用 `scrollToIndex(新增条数 + 1)`
   * 把**原来的第一条**重新对齐到顶部 —— 位置看起来没动，也不会先跳到底再弹回来那种闪烁。
   *
   * 但列表现在**从屏幕最顶端开始**（消息从标题栏底下穿过去，见 build 的说明），
   * 而对齐到 `START` 等于把那条消息顶到 y=0（标题栏背后）。所以对齐之后再往回滚
   * `PAGE_TOP_OFFSET`（内容整体下移 96vp），它才刚好落在标题栏下方 —— 和以前列表自带
   * 那 96vp 顶部留白时的落点完全一致。
   */
  private loadOlderKeepPosition(): void {
    const before: number = this.allMessages().length;
    /*
     * 兜底：取数这条路万一没回来，8 秒后也把状态收掉。句柄存起来：新一次加载开始时要**取消上一次**
     * （否则上一发的兜底会把这一发的状态提前收掉），销毁时也要清（审计项 A2）。
     */
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout((): void => {
      this.settleTimer = -1;
      this.settleRefresh();
    }, 8000);
    /*
     * **首屏还没读出来时，触顶就是"重试加载"**（审计 C3）。
     *
     * `loadOlder()` 第一行就是 `if (this.busy || this.view === null || …) return;` —— 首屏失败
     * （`view` 一直为 null）之后，触顶只会立刻返回：用户看到的是"圈转一下就没了、什么也不发生"，
     * 而这一页再也没有别的入口去重试。这里把触顶接到 `load()` 上，等于给用户一个重试键。
     */
    if (this.vm.viewNow() === null) {
      this.vm.load()
        .then((): void => {
          this.syncFromVm();
          this.scrollToNewest();
          this.settleRefresh();
        })
        .catch((): void => {
          this.settleRefresh();
        });
      return;
    }
    this.vm.loadOlder()
      .then((): void => {
        const added: number = this.allMessages().length - before;
        if (added > 0) {
          try {
            // **+1**：列表第 0 格是那行"加载中"占位（见 LOADING_ROW_VP），消息从下标 1 开始。
            this.listScroller.scrollToIndex(added + 1, false, ScrollAlign.START);
            // 再退回标题栏那一条的高度，让它停在栏下方而不是藏在栏背后（见方法头）。
            this.listScroller.scrollBy(0, -PAGE_TOP_OFFSET);
          } catch (error) {
          }
        }
        this.settleRefresh();
      })
      .catch((): void => {
        this.settleRefresh();
      });
  }

  /**
   * 一次"触顶刷新"的收尾：**只清掉兜底定时器**。
   *
   * 界面上的加载圈由 `busy`（视图模型回调）驱动，不再有原生 `Refresh` 那种需要手动收敛的
   * 独立状态（组件已按需求移除，见 build）。
   */
  private settleRefresh(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  private bubbleMaxVp(): number {
    const width: number = this.screenWidthVp > 0 ? this.screenWidthVp : FALLBACK_WIDTH_VP;
    return width * BUBBLE_MAX_RATIO;
  }

  private bubbleMediaWidth(): number {
    const width: number = this.screenWidthVp > 0 ? this.screenWidthVp : FALLBACK_WIDTH_VP;
    return Math.min(200, width * 0.52);
  }

  private showsAvatar(index: number): boolean {
    const list: Array<DirectMessage> = this.allMessages();
    if (index <= 0) {
      return true;
    }
    const prev: DirectMessage = list[index - 1];
    const cur: DirectMessage = list[index];
    if (prev.mine !== cur.mine) {
      return true;
    }
    return cur.tsMs - prev.tsMs > GROUP_GAP_MS;
  }

  private isNewGroup(index: number): boolean {
    const list: Array<DirectMessage> = this.allMessages();
    if (index <= 0) {
      return false;
    }
    const prev: DirectMessage = list[index - 1];
    const cur: DirectMessage = list[index];
    if (prev.mine !== cur.mine) {
      return true;
    }
    return cur.tsMs - prev.tsMs > GROUP_GAP_MS;
  }

  /** 一条消息（自己的靠右、对方的靠左；对方的按时间段在左侧带头像）。 */
  @Builder
  bubble(message: DirectMessage, index: number) {
    Row({ space: 8 }) {
      if (message.mine) {
        Blank()
        this.bubbleContent(message)
      } else {
        if (this.showsAvatar(index)) {
          Image(this.view !== null && this.view.withAvatar.length > 0
            ? this.view.withAvatar : $r('app.media.startIcon'))
            .draggable(false)
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .borderRadius(AVATAR_SIZE / 2)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.field_background'))
        } else {
          Column().width(AVATAR_SIZE).height(AVATAR_SIZE)
        }
        this.bubbleContent(message)
        Blank()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({
      left: SIDE_PADDING,
      right: SIDE_PADDING,
      top: this.isNewGroup(index) ? GROUP_GAP_VP : BUBBLE_GAP_VP,
      bottom: 0
    })
  }

  /** 气泡内容：有图先画图，文字跟在图下面。 */
  @Builder
  bubbleContent(message: DirectMessage) {
    Column({ space: 6 }) {
      if (message.mediaUrl.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Image(message.mediaUrl)
            .draggable(false)
            .width(this.bubbleMediaWidth())
            .height(this.bubbleMediaWidth() * 1.25)
            .objectFit(ImageFit.Cover)
            .borderRadius(14)
            .backgroundColor($r('app.color.field_background'))
            .alt($r('app.media.grid_placeholder'))
            /*
             * 图解码完 = 这一条的高度真正定下来了：如果用户还贴在底部，就再贴一次 ——
             * 否则晚到的图会把"最新那条"顶到输入框下面去（用户报的正是这个）。
             * 用户已经往上翻历史时 `pinnedToBottom` 是 false，这里不会抢他的位置。
             */
            .onComplete((): void => {
              if (this.pinnedToBottom) {
                this.scrollToNewest(false);
              }
            })
          if (message.isVideo) {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(18)
              .fontColor([Color.White])
          }
        }
      } else if (DirectThreadPage.isMediaKind(message.kind)) {
        /*
         * **媒体占位**（用户："图片/视频媒体用占位加载表示，加载成功后显示"）。
         *
         * 什么时候会走到这里：这条消息**没有可用的媒体地址**（服务端这一版没给 `image_versions2` /
         * `video_versions`，或只给了已过期的签名 URL）。所以先按这条消息的类型画一块占位，
         * 等下一发 `load()` 把媒体地址带回来，上面那个分支就把它换成真图/视频封面。
         * 占位尺寸与真媒体一致，换上去时不会跳。
         *
         * （以前这条分支还兼着"文本快照缓存里没有媒体地址"的情况 —— 那个缓存已按需求删除，
         *   见 core 里 DirectPrefetch 的删除记录。占位逻辑本身对稀疏载荷仍然需要，保留。）
         */
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(this.bubbleMediaWidth())
            .height(this.bubbleMediaWidth() * 1.25)
            .borderRadius(14)
            .backgroundColor($r('app.color.field_background'))
          SymbolGlyph($r(message.isVideo ? 'sys.symbol.play_fill' : 'sys.symbol.photo'))
            .fontSize(22)
            .fontColor([$r('app.color.secondary_text')])
        }
      }
      if (message.text.length > 0) {
        Text(message.text)
          .fontSize(15)
          .fontColor(message.mine ? $r('app.color.on_accent') : $r('app.color.primary_text'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(message.mine ? $r('app.color.accent') : $r('app.color.field_background'))
          .borderRadius(18)
          .constraintSize({ maxWidth: this.bubbleMaxVp() })
      } else if (message.mediaUrl.length === 0 && !DirectThreadPage.isMediaKind(message.kind)) {
        Text($r('app.string.direct_kind_other'))
          .fontSize(15)
          .fontColor(message.mine ? $r('app.color.on_accent') : $r('app.color.primary_text'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(message.mine ? $r('app.color.accent') : $r('app.color.field_background'))
          .borderRadius(18)
      }
    }
    .alignItems(message.mine ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  /**
   * 这条消息**是不是媒体类**（判据与列表占位同一套：见 DirectPage.messagePlaceholder）。
   *
   * `item_type` 的取值很多（`media` / `raven_media` / `clip` / `xma_clip` / `xma_media_share` …），
   * 所以按片段认而不是枚举；文字/系统类走到这里会给 false，仍然显示文字或"其他"占位。
   */
  private static isMediaKind(kind: string): boolean {
    const lower: string = kind.toLowerCase();
    return lower.indexOf('media') >= 0 || lower.indexOf('clip') >= 0
      || lower.indexOf('raven') >= 0 || lower.indexOf('xma') >= 0
      || lower.indexOf('photo') >= 0 || lower.indexOf('video') >= 0;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        /*
         * **列表直接铺到屏幕最上面（y=0），消息从 HDS 标题栏底下穿过去**（需求）。
         *
         * 以前这里上面压着一块 `PAGE_TOP_OFFSET` 的占位 —— 于是列表的**视口**从 96vp 才开始，
         * 往上一滑，消息到那一条线就被裁掉，看起来像被标题栏"切断"。
         * 现在改成：列表占满整屏，顶部让位改由 `contentStartOffset` 表达（它是**内容的一部分**，
         * 会跟着滚动走）—— 停在最上面时第一条消息正好在标题栏下方，滚动时消息则从半透明的
         * 标题栏底下穿过去。
         */
        List({ space: 0, scroller: this.listScroller }) {
          /*
           * **顶部"加载中"动画（始终占位、置中）**（用户："加载时在最顶部消息上方显示刷新动画，
           * 置中显示"）。
           *
           * 为什么固定占一格（高度 0/36 切换）而不是 `if (busy)` 才插：见 LOADING_ROW_VP 的说明
           * ——列表靠 `scrollToIndex(added + 1)` 锚位置，下标必须是恒定的。
           *
           * **现在它就是"触顶刷新"唯一的动画**：原生 `Refresh` 已按需求去掉（见下面 build 的说明），
           * 高度切换挂 `.animation`，于是触顶加载时这一圈是**顺着滑下来**的，不是一个百分点地跳。
           */
          ListItem() {
            Row() {
              if (this.busy) {
                LoadingProgress()
                  .width(24)
                  .height(24)
                  .color($r('app.color.secondary_text'))
              }
            }
            .width('100%')
            .height(this.busy ? LOADING_ROW_VP : 0)
            .justifyContent(FlexAlign.Center)
            .animation({ duration: 160, curve: Curve.EaseOut })
          }

          ForEach(this.allMessages(), (message: DirectMessage, index: number): void => {
            ListItem() {
              this.bubble(message, index)
            }
          }, (message: DirectMessage, index: number): string => `${index}-${message.id}`)

          if (this.allMessages().length === 0 && !this.busy) {
            ListItem() {
              Column({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.paperplane'))
                  .fontSize(30)
                  .fontColor([$r('app.color.secondary_text')])
                Text($r('app.string.direct_thread_empty'))
                  .fontSize(14)
                  .fontColor($r('app.color.secondary_text'))
                /*
                 * **读失败的原因放在空态里**（它只在这一屏真没内容时才有意义）。
                 *
                 * 以前它是一条常驻在列表上方的文字行 —— 现在列表铺满整屏（消息从标题栏底下穿过），
                 * 那行字要么占掉列表高度、要么浮在消息上面挡一条（两种都试过，都难看）。
                 * 有消息时不显示任何状态字：用户看的就是消息本身。
                 */
                if (this.status.length > 0) {
                  Text(this.status)
                    .fontSize(12)
                    .fontColor($r('app.color.secondary_text'))
                    .maxLines(3)
                    .textAlign(TextAlign.Center)
                    .padding({ left: SIDE_PADDING, right: SIDE_PADDING })
                  Text($r('app.string.direct_open_web'))
                    .fontSize(14)
                    .fontColor($r('app.color.accent'))
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .borderRadius(16)
                    .backgroundColor($r('app.color.field_background'))
                    .onClick((): void => {
                      this.onOpenWeb();
                    })
                }
              }
              .width('100%')
              .height(200)
              .justifyContent(FlexAlign.Center)
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        /*
         * 顶部让位（vp）：标题栏那块（含它下面那层毛玻璃）的高度。它属于**内容**，
         * 滚动时会跟着走 —— 这正是"停在最上面时第一条不被压住、滑动时消息从栏下穿过"的实现。
         */
        .contentStartOffset(PAGE_TOP_OFFSET)
        .contentEndOffset(BOTTOM_OFFSET)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .clip(false)
        .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
          const y: number = this.listScroller.currentOffset().yOffset;
          /*
           * 用户**往上翻**了（偏移在减小）：记成"不在贴底状态"，后面那几次延迟补贴底就不再抢位置
           * （见 scrollToNewest(false) 与 pinnedToBottom 的说明）。往回滚到底部时照旧贴底。
           */
          if (y < this.lastOffsetY - 12) {
            this.pinnedToBottom = false;
          }
          this.lastOffsetY = y;
          this.scrollDelta.report(y, scrollState, this.onFeedScroll);
        })
        /*
         * **触顶刷新**（需求："保留触顶刷新和动画"）：滑到最上面就自动去取更老那批。
         *
         * 原生 `Refresh` 组件已按需求移除（它自带的下拉指示器/回弹都在组件内部，关不掉），
         * 所以"动画"改由上面那一行加载圈负责（高度 0→36 带 `.animation`），
         * 这里只保留"到顶就加载"这条触发。
         */
        .onReachStart((): void => {
          if (this.busy) {
            return;
          }
          if (this.view === null || !this.view.hasOlder
            || this.view.oldestCursor.length === 0) {
            return;
          }
          /*
           * **同一次"拉到底"只触发一发**：`onReachStart` 在弹性的每次回弹都会再报一次，
           * 不加这道闸的话，一次下拉连弹三下就会连发三页（真机实测 +20、+20、+20）。
           */
          const now: number = Date.now();
          if (now - this.lastReachAtMs < REACH_COOLDOWN_MS) {
            return;
          }
          this.lastReachAtMs = now;
          this.loadOlderKeepPosition();
        })
      }
      .width('100%')
      .height('100%')
      /*
       * **输入法避让（列表这一侧）**：键盘弹起时把整个内容区抬起来 `keyboardVp`，
       * 这样列表的可视底边就是键盘顶边，最后几条消息不会被键盘压住。
       * 输入条自己要再抬一次（它在下面那个 Stack 层里，见 inputOverlay）。
       */
      .padding({ bottom: this.keyboardVp })

      // 悬浮输入条（在 Stack 的 Bottom 对齐层里，自己再抬一次输入法高度）。
      this.inputOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    /*
     * **任何触摸都算"人还在看"**：这直接决定要不要继续轮询
     * （空闲 90 秒就停，见 DirectThreadViewModel.THREAD_IDLE_STOP_MS）。
     * 一开始那次也算动作，所以进页面立刻恢复。
     */
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.vm.touchActivity();
      }
    })
  }

  /** 悬浮的输入条（和评论浮层里那条完全同一个组件）。 */
  @Builder
  inputOverlay() {
    Column() {
      /*
       * 里面再包一层：**id 必须挂在"不含底部留白"的那一层上**。
       *
       * 踩过的坑：id 与 `padding` 挂在同一个节点上时，`getRectangleById` 量到的是**含 padding 的外框**
       * ——外框底部被 Stack 钉在页面底部、不会随 padding 变，于是自校正读到的永远是同一个位置
       * （日志里 `need` 一直 238px 不动就是这么来的）。
       */
      Column() {
        CommentInputBar({
          hint: $r('app.string.direct_thread_hint'),
          sideInset: 12,
          bottomInset: 0,
          onSend: (text: string): void => {
            this.vm.send(text)
              .then((): void => {
                this.syncFromVm();
                this.scrollToNewest();
                /*
                 * **再贴一次底**：发送后键盘收起、输入条下移，列表可视高度在动画里
                 * 一直变；`scrollEdge(Bottom)` 只按**当时**的高度算，于是会停在
                 * "新气泡贴着屏幕顶端"那种错位（一帧后再自己回正，看起来就是跳一下）。
                 * 等布局稳定后再贴一次，落点就对了。
                 */
                setTimeout((): void => {
                  this.scrollToNewest();
                }, SEND_SCROLL_SETTLE_MS);
              })
              .catch((): void => {
              });
          }
        })
      }
      .width('100%')
      .id(INPUT_BAR_ID)
    }
    .width('100%')
    // 常规留白 + **输入法抬升**：键盘弹起时输入条抬到键盘上方（抬多少由自校正量出来）。
    .padding({ bottom: COMMENT_INPUT_BOTTOM_VP + this.keyboardVp })
  }
}
