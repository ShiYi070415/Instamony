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

import { curves, display, window, componentUtils } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DirectMessage, DirectThreadView } from '../model/Direct';
import { DirectThreadViewModel } from '../viewmodel/DirectThreadViewModel';
import { CommentInputBar, COMMENT_INPUT_BOTTOM_VP } from './CommentInputBar';
import { ScrollDelta } from '../core/ScrollReport';
// 分享卡片里的"用户资讯栏"用沉浸光感承载（只能挂在 Toggle 上，见 MaterialSurface）。
import { FALLBACK_SURFACE, SurfaceModifier } from './MaterialSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';

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
/** 分享卡片的圆角（帖子卡片与视频卡片共用一套，别各写一个数）。 */
const CARD_RADIUS: number = 16;
const SIDE_PADDING: number = 16;
/**
 * **输入框那一侧的内缩**（= CommentInputBar 的 sideInset，见 build 里那一处）。
 *
 * 需求："自己发的图片媒体右侧对齐输入框" —— 所以自己那一侧的行留白用这个值，
 * 图片右边缘才和输入框右边缘在同一条竖线上（原来是 SIDE_PADDING=16，差 4）。
 */
const INPUT_SIDE_INSET: number = 12;
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
/** 气泡的四角基准圆角。 */
const BUBBLE_RADIUS: number = 22;
/**
 * **贴在一起的两颗气泡**，接触那一侧用的小圆角（需求："贴着另一个消息气泡的左侧接触角用小圆角"）。
 * 左边（对方）收左角，右边（自己）收右角，见 bubbleCorners。
 */
const BUBBLE_RADIUS_JOIN: number = 6;
/** 群聊里"发送人名字"那一行的字号（需求：比正文小一点但要看得清，之前 11 太小）。 */
const SENDER_NAME_SIZE: number = 12;
/** 那一行相对头像左侧再多留的空白（需求：padding left 需要增加）。 */
const SENDER_NAME_LEFT_PAD: number = 24;
/** 有发送人名字的组，和上一段之间额外加的距离（需求：顶部 margin 要和其他消息段拉开）。 */
/** 名字行与它下面那颗气泡的距离（需求：分组 margin top 缩小到和它一样）。 */
const SENDER_NAME_BOTTOM_GAP: number = 10;
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
 * 滚动偏移超过这么多 vp 就算"离开了顶部"，重新武装触顶刷新（见 onReachStart 的三道闸）。
 *
 * 取得比标题栏让位（96vp）小一点：用户只要真的往下滚了一段，就说明他愿意再拉一次。
 */
const REACH_REARM_OFFSET_VP: number = 80;

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

/**
 * 气泡"弹出"的起始缩放（0.86 = 从 86% 长到 100%）。
 *
 * 配合 `centerY: '100%'`（贴底边缩放）与 +16vp 的上升位移，观感就是"从下往上、由小至大"。
 */
const BUBBLE_POP_FROM: number = 0.86;
/** 气泡弹出时从下方多远升上来（vp）。 */
const BUBBLE_POP_RISE_VP: number = 16;
/** 弹簧的初速度（`curves.springMotion` 第一个参数；0.5~0.8 之间手感最像"弹出来"）。 */
const BUBBLE_SPRING_VELOCITY: number = 0.65;
/**
 * 弹簧的阻尼比（第二个参数）。
 *
 * 1 = 临界阻尼（不回落）；0.56 会**过冲一点再回正** —— 需求要的"非线性弹性"就是这个过冲。
 * 想要更"橡皮"就往下调（0.4 上下），想要更稳就往 0.8 调。
 */
const BUBBLE_SPRING_DAMPING: number = 0.56;
/**
 * 级联入场时每条气泡之间的间隔（毫秒）。
 *
 * 需求："进入会话时动画要从最新消息一个个播放到最上面的消息，要迅速一点" —— 22ms 一档，
 * 一整屏（10 条左右）也就 220ms 走完，眼睛跟得上、又不拖沓。
 */
const POP_STEP_MS: number = 22;
/**
 * 级联最多数这么多档（再往上一起播）。
 *
 * 会话可能有一百多条：一条条排下去要两三秒，那是"卡"不是"弹"。封顶 16 档 ≈ 350ms，
 * 更老的虽然同时入场，但那时它们大多在视口之外，看不见。
 */
const POP_MAX_STEPS: number = 16;
/**
 * 没有任何延迟时也至少等这么久再"就位"。
 *
 * 隐式动画要求属性**真的变化过**：同一帧里把 `shown` 设成 true，首帧已经是终态，
 * 就没有"从 0.86 弹到 1"这个过程了。等一帧（16ms）就有了。
 */
const POP_MIN_DELAY_MS: number = 16;
/** 一批气泡播完之后，排名表再多留一会儿（毫秒）再清，见 noteMessages。 */
const POP_RANK_KEEP_MS: number = 500;
/**
 * `delayMs` 取这个值 = **一个气泡都不播**，直接落到终态。
 *
 * 用在"乐观气泡换成服务端那条"的那一帧：键变了、`ForEach` 会当新条目重建，
 * 那条消息其实已经弹过了（见 popDelayFor 与 DirectThreadViewModel.wasConfirmed）。
 */
const POP_NONE: number = -1;

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
  /** 点开"转发的帖子 / Reel / 链接卡片"（见 bubbleContent 的说明）。 */
  onOpenShare: (message: DirectMessage) => void = (message: DirectMessage): void => {
  };
  onOpenUser: (username: string, userId: string) => void =
    (username: string, userId: string): void => {
    };
  onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
    };
  @State private view: DirectThreadView | null = null;
  @State private pending: Array<DirectMessage> = [];
  /**
   * 发送失败的那几个乐观气泡的本地 id（见 DirectThreadViewModel.isFailed）。
   *
   * 为什么镜像一份到 `@State`：气泡里要根据它画"未发送 · 点击重试"，
   * 而 `vm` 上的 Map 变了 ArkUI 不会知道（它不是响应式对象）。
   */
  @State private failedIds: Array<string> = [];
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
      const grew: boolean = items.length > this.pending.length;
      this.pending = items;
      // 失败标记跟着一起同步（气泡里要画"未发送 · 点击重试"）。
      this.failedIds = this.vm.failedIdsNow();
      /*
       * **新加的乐观气泡要立刻可见**（用户报："发送消息会有延迟，一开始不会"）。
       *
       * 列表只把新条目追加在末尾，滚动位置不动 —— 底部那条就被输入条/键盘挡住，
       * 用户看到的是"点了发送没反应"，一直等到刷新那一下才跳出来。
       * 这里在"发出去的那条刚进列表"时立刻贴底（贴底由 pinnedToBottom 把关，
       * 用户翻历史时不会被拽走）。
       */
      if (grew && this.pinnedToBottom) {
        this.scrollToNewest(false);
      }
      // 发出去的那条乐观气泡也要吃到入场动画（见 noteMessages / popDelayFor）。
      this.noteMessages();
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
    if (this.rankClearTimer >= 0) {
      clearTimeout(this.rankClearTimer);
      this.rankClearTimer = -1;
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
    this.noteMessages();

  }

  /**
   * **记下"这一批新出现的是哪几条"**，给气泡的级联入场动画算延迟（见 popDelayFor）。
   *
   * 需求（2026-10-23 修正过两轮，最终态）：
   *   · 进会话、刷新出来的消息、**上滑时逐条进入视口的消息** —— 全都要播动画；
   *   · 顺序一律**从最下面（最新）到最上面（最老）**：同一帧里一起出现的那一批按
   *     "从最新往回数"排延迟；上滑时逐条出现的那些，创建顺序本来就是自下而上，
   *     所以拿到延迟 0、立刻各自弹一下。
   *
   * 排名表只活一小会儿（`POP_MAX_STEPS * POP_STEP_MS + 500ms`）：清掉之后，
   * 滚动过程中才创建的气泡一律即时入场，不会排队排到"卡"。
   */
  private noteMessages(): void {
    const list: Array<DirectMessage> = this.allMessages();
    /*
     * 只有"上一轮没见过"的才算这一批的新条目。整表替换（进会话/换会话）时 knownIds 很小，
     * 于是全部算新 —— 正是我们要的：进会话就从最后一条开始一路往上弹。
     */
    const fresh: Set<string> = new Set<string>();
    const seen: Set<string> = new Set<string>();
    for (let index: number = 0; index < list.length; index++) {
      const id: string = list[index].id;
      if (id.length === 0) {
        continue;
      }
      seen.add(id);
      if (!this.knownIds.has(id)) {
        fresh.add(id);
      }
    }
    this.knownIds = seen;
    if (fresh.size === 0) {
      return;
    }
    /*
     * 排名**从最下面往回数**（最新 = 0）：界面是老的在上、新的在下，所以延迟要从后往前发。
     */
    this.freshRank = new Map<string, number>();
    let rank: number = 0;
    for (let index: number = list.length - 1; index >= 0; index--) {
      const id: string = list[index].id;
      if (fresh.has(id) && !this.freshRank.has(id)) {
        this.freshRank.set(id, rank);
        rank++;
      }
    }
    if (this.rankClearTimer >= 0) {
      clearTimeout(this.rankClearTimer);
    }
    this.rankClearTimer = setTimeout((): void => {
      this.rankClearTimer = -1;
      this.freshRank = new Map<string, number>();
    }, POP_MAX_STEPS * POP_STEP_MS + POP_RANK_KEEP_MS);
  }

  /**
   * 这一条气泡的入场延迟（毫秒）。
   *
   * @returns `POP_NONE`(-1) = **不播**（见下）；
   *          0 = 立刻播（上滑时逐条进入视口的那种）；
   *          其余 = "这一批里从最下面往回数"的档位 × 22ms，越靠下越先、越靠上越后，整体封顶。
   */
  private popDelayFor(id: string): number {
    /*
     * **刚顶替掉乐观气泡的那条不播**：自己发出去的消息在按下发送的那一刻，
     * 本地气泡已经弹过一次了；等它换成服务端那条时再弹，就是"同一句话弹两下"。
     * 而且这一对气泡的**键不同**（`local-…` vs 服务端 id），`ForEach` 会当成新条目重建，
     * 不拦的话必然重播。
     */
    if (this.vm.wasConfirmed(id)) {
      return POP_NONE;
    }
    const rank: number | undefined = this.freshRank.get(id);
    if (rank === undefined) {
      return 0;
    }
    const steps: number = rank < POP_MAX_STEPS ? rank : POP_MAX_STEPS;
    return steps * POP_STEP_MS;
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
  /** 有一发"加载更老"在飞（防重入，见 onReachStart）。 */
  private olderInFlight: boolean = false;
  /**
   * 触顶刷新是否**已武装**。
   *
   * 一次加载之后必须"**真实手指**离开过顶部再回来"才重新武装（见 onDidScroll）：
   * 程序化的锚位滚动不算。只靠冷却时间的话，列表贴着顶部会"加载 → 锚回 → 又被当成离开
   * 顶部 → 再加载"，一直往下捞（真机报的"触顶刷新一直回到最底部"就是这条）。
   */
  private reachArmed: boolean = true;
  /** 手指现在压在屏幕上没有（只有真实手指能重新武装触顶刷新，见 onDidScroll）。 */
  private userTouching: boolean = false;

  /**
   * 上一轮列表里**已经出现过**的消息 id（见 noteMessages）。
   *
   * 只用来判断"哪几条是这一批新冒出来的"（它们要按从下往上的顺序排队弹）。
   * **不**用它拦动画：上滑时列表回收后再创建的气泡本来就要再弹一次（需求）。
   */
  private knownIds: Set<string> = new Set<string>();
  /** 这一批新消息的入场排名（id → 从最新往回数的序号；见 popDelayFor）。 */
  private freshRank: Map<string, number> = new Map<string, number>();
  /** 清空排名表的定时器（见 noteMessages）。 */
  private rankClearTimer: number = -1;


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
    this.olderInFlight = true;
    this.vm.loadOlder()
      .then((): void => {
        this.olderInFlight = false;
        const added: number = this.allMessages().length - before;
        if (added > 0) {
          // 立即锚（改动画之前那套）：`ForEach` 下条目首帧就在，`scrollToIndex` 落到的是新布局。
          this.anchorToLoaded(added);
        }
        this.settleRefresh();
      })
      .catch((): void => {
        this.olderInFlight = false;
        this.settleRefresh();
      });
  }

  /**
   * 把视口锚回"加载前那条消息"（见 loadOlderKeepPosition 的说明）。
   *
   * @param added 这一发在前面插进来多少条
   */
  private anchorToLoaded(added: number): void {
    try {
      // **+1**：列表第 0 格是那行"加载中"占位（见 LOADING_ROW_VP），消息从下标 1 开始。
      this.listScroller.scrollToIndex(added + 1, false, ScrollAlign.START);
      // 再退回标题栏那一条的高度，让它停在栏下方而不是藏在栏背后（见方法头）。
      this.listScroller.scrollBy(0, -PAGE_TOP_OFFSET);
    } catch (error) {
    }
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

  /** 分享卡片里材质容器的厚度（跟设定页联动）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) cardThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;

  /**
   * 卡片宽度（需求）：帖子卡片占屏幕 2/3，**视频卡片是帖子卡片的三分之二**（= 屏幕 4/9）。
   *
   * 用屏幕宽度而不是气泡宽度：这两种卡片是"内容卡片"，和左右气泡的宽度口径不同。
   */
  private shareCardWidth(message: DirectMessage): number {
    const width: number = this.screenWidthVp > 0 ? this.screenWidthVp : FALLBACK_WIDTH_VP;
    const postWidth: number = width * 2 / 3;
    return message.shareKind === 'video' ? postWidth * 2 / 3 : postWidth;
  }

  /** 卡片封面高度：按"视频 16:9 竖屏 / 帖子方图略竖"给一个稳定比例（不做裁剪跳变）。 */
  private shareCardHeight(message: DirectMessage): number {
    const width: number = this.shareCardWidth(message);
    return width * (message.shareKind === 'video' ? 1.78 : 1.25);
  }

  private bubbleMaxVp(): number {
    const width: number = this.screenWidthVp > 0 ? this.screenWidthVp : FALLBACK_WIDTH_VP;
    return width * BUBBLE_MAX_RATIO;
  }

  /**
   * 图片在气泡里的**显示比例**（高 / 宽）。
   *
   * 需求："横图 16:9（自适应，非强制）、方形保持 1:1、长图最大 4:3" ——
   * 所以只做**上限裁剪**，不做强制：原图什么比例就什么比例，超出的才夹住。
   * 与「应用内拍摄 vs 图库上传」无关：那一层等以后有 `is_camera` 之类的字段再区分。
   */
  /** 原图的原始比例（高 / 宽；拿不到给 0）。分档与裁剪都用它。 */
  private static rawAspect(message: DirectMessage): number {
    const w: number = message.mediaWidth;
    const h: number = message.mediaHeight;
    return w > 0 && h > 0 ? h / w : 0;
  }

  /**
   * **贴图 / 动图**（透明 PNG / GIF）：小尺寸、Contain、**不铺底色**。
   *
   * 单独一个构造器而不是塞进图片分支：一是要做"透明底"，二是贴图不该有圆角与占位底色，
   * 三是它要在卡片分支之前判断（见 bubbleContent）。
   */
  @Builder
  stickerBubble(message: DirectMessage) {
    Image(message.mediaUrl.length > 0 ? message.mediaUrl : $r('app.media.grid_placeholder'))
      .draggable(false)
      .width(this.mediaBoxWidth(message))
      .height(this.mediaBoxHeight(message))
      .objectFit(ImageFit.Contain)
      .backgroundColor(Color.Transparent)
      // 动图（GIF / 动态 WebP）交给系统解码器播；失败就停在首帧，不影响布局。
      .onComplete((): void => {
        if (this.pinnedToBottom) {
          this.scrollToNewest(false);
        }
      })
  }

  private static mediaAspect(message: DirectMessage): number {
    const w: number = message.mediaWidth;
    const h: number = message.mediaHeight;
    if (w <= 0 || h <= 0) {
      // 拿不到尺寸：贴图按方形，普通图片沿用老的 4:5。
      return message.mediaSticker ? 1 : 1.25;
    }
    const ratio: number = h / w;
    if (ratio >= 1) {
      // 方形 / 长图：最多 4:3（即 高 ≤ 宽 × 4/3）。
      return Math.min(ratio, 4 / 3);
    }
    // 横图：最多 16:9（即 高 ≥ 宽 × 9/16），比 16:9 更扁的才被夹住。
    return Math.max(ratio, 9 / 16);
  }

  /**
   * 气泡里图片的宽度，**按屏幕宽度分档**（需求）：
   *   · 贴图：1/3 屏；
   *   · 方形图（≈1:1）：4/7 屏；
   *   · 长图（竖图）：1/2 屏；
   *   · 横图：4/6 屏。
   *
   * 比例取自原图尺寸（见 mediaAspect），拿不到尺寸时按横图那一档算。
   */
  private mediaBoxWidth(message: DirectMessage): number {
    const screen: number = this.screenWidthVp > 0 ? this.screenWidthVp : FALLBACK_WIDTH_VP;
    /*
     * **两侧气泡内边距要扣掉**（需求："图片宽度需要减去右侧消息气泡的 padding/margin right * 2"）。
     *
     * 气泡所在那一行有 SIDE_PADDING 的留白；按屏幕比例算出来的宽度如果不扣这一侧，
     * 图片就会顶到屏幕边缘（右侧消息尤其明显）。这里按"档位宽度 − SIDE_PADDING"给，
     * 再和"这一行真正能用的宽度"取小值兜底（左侧消息还要让出头像的位置）。
     */
    // 边缘距离：自己那一侧与输入框对齐（INPUT_SIDE_INSET），对方那一侧是 SIDE_PADDING。
    const edge: number = message.mine ? INPUT_SIDE_INSET : SIDE_PADDING;
    const usable: number = message.mine
      ? screen - SIDE_PADDING - edge
      : screen - SIDE_PADDING * 2 - AVATAR_SIZE - 8;
    let wanted: number = 0;
    if (message.mediaSticker) {
      wanted = screen / 3;
    } else {
      const ratio: number = DirectThreadPage.rawAspect(message);
      if (ratio > 0 && Math.abs(ratio - 1) <= 0.02) {
        // 方形：4/7
        wanted = screen * 4 / 7;
      } else if (ratio > 1.02) {
        // 长图（高 > 宽）：1/2
        wanted = screen / 2;
      } else {
        // 横图（含未知尺寸）：4/6
        wanted = screen * 4 / 6;
      }
    }
    /*
     * 需求："图片宽度减去边缘距离，不是增加边缘距离" —— 所以是
     * `档位宽度 − 边缘距离`（边缘距离取这一侧的留白），而不是在已经缩过的宽度上再加留白。
     */
    const target: number = wanted - edge;
    return Math.round(target > 0 ? Math.min(usable, target) : wanted);
  }

  /** 气泡里图片的高度：宽度 × 比例（见 mediaAspect）。 */
  private mediaBoxHeight(message: DirectMessage): number {
    return Math.round(this.mediaBoxWidth(message) * DirectThreadPage.mediaAspect(message));
  }

  private bubbleMediaWidth(): number {
    const width: number = this.screenWidthVp > 0 ? this.screenWidthVp : FALLBACK_WIDTH_VP;
    return Math.min(200, width * 0.52);
  }

  /**
   * 取 `index` 那条消息的上一条。
   *
   * **必须容错**：`ForEach` 的 `index` 是**建表那一刻**的序号，而气泡的 `updateFunc` 会在之后的
   * 状态变化里再跑一遍 —— 那时 `allMessages()` 可能已经不一样了（实时消息插了一条、
   * 待发消息列表清空、整表替换……），直接 `list[index]` 就是
   * `TypeError: Cannot read property mine of undefined` 然后整个应用闪退（真机日志实录）。
   *
   * 索引对不上时按 `message.id` 反查自己的位置，再取它前面那条；实在找不到就当"没有上一条"。
   */
  private prevOf(index: number, message: DirectMessage): DirectMessage | undefined {
    const list: Array<DirectMessage> = this.allMessages();
    if (index > 0 && index < list.length) {
      return list[index - 1];
    }
    for (let at: number = 0; at < list.length; at++) {
      if (list[at].id === message.id) {
        return at > 0 ? list[at - 1] : undefined;
      }
    }
    return undefined;
  }

  /** 下一条消息（没有给 undefined；索引对不上时按 id 反查，理由同 prevOf）。 */
  private nextOf(index: number, message: DirectMessage): DirectMessage | undefined {
    const list: Array<DirectMessage> = this.allMessages();
    if (index >= 0 && index + 1 < list.length && list[index].id === message.id) {
      return list[index + 1];
    }
    for (let at: number = 0; at < list.length; at++) {
      if (list[at].id === message.id) {
        return at + 1 < list.length ? list[at + 1] : undefined;
      }
    }
    return undefined;
  }

  /**
   * **时间段**：这一条和上一条间隔不超过两分钟就算同一个时间段的。
   *
   * 需求："最新消息和上一条消息超过两分钟就开新组" —— 只看时间，不看是谁发的。
   */
  private sameTimeSegmentAsPrev(index: number, message: DirectMessage): boolean {
    const prev: DirectMessage | undefined = this.prevOf(index, message);
    if (prev === undefined) {
      return false;
    }
    return message.tsMs - prev.tsMs <= GROUP_GAP_MS;
  }

  /** **同一个用户**：方向一致（都是收/发）、发送人相同。 */
  private sameSenderAsPrev(index: number, message: DirectMessage): boolean {
    const prev: DirectMessage | undefined = this.prevOf(index, message);
    if (prev === undefined) {
      return false;
    }
    if (prev.mine !== message.mine) {
      return false;
    }
    return DirectThreadPage.senderKeyOf(prev) === DirectThreadPage.senderKeyOf(message);
  }

  /**
   * 这一条和上一条算不算"同一组"：**先按用户分组，再按时间段分组**（需求）。
   *
   * 也就是说两个条件都要满足：同一个人**并且**和上一条的间隔不超过两分钟；
   * 任意一条不满足就开新组（新组才会写发送人名字、才会在组尾画头像）。
   */
  private sameGroupAsPrev(index: number, message: DirectMessage): boolean {
    return this.sameSenderAsPrev(index, message) && this.sameTimeSegmentAsPrev(index, message);
  }

  /**
   * **头像画在"这一组最新那条"的左侧**（需求："头像要显示在消息时间段分组最新消息的左侧"）。
   *
   * 判据是"下一条不跟它同组"：换人、换方向、或者隔得超过 GROUP_GAP_MS。
   */
  private showsAvatar(index: number, message: DirectMessage): boolean {
    if (message.mine) {
      return false;
    }
    const next: DirectMessage | undefined = this.nextOf(index, message);
    if (next === undefined) {
      return true;
    }
    if (next.mine) {
      return true;
    }
    if (DirectThreadPage.senderKeyOf(next) !== DirectThreadPage.senderKeyOf(message)) {
      return true;
    }
    return next.tsMs - message.tsMs > GROUP_GAP_MS;
  }

  /**
   * **这一组要不要在顶部写发送人名字**（需求："消息时间段分组的顶部需要显示用户名"）。
   *
   * 判据就是"这一条开了新组"（见 sameGroupAsPrev）。
   *
   * 这里**不再看 `is_group` 标记**：真机上群聊条目偶尔没带这个字段，之前一漏就整屏都不写名字。
   * 现在的规则是：只要这位发送人和"当前会话的对方资料"不一样就当群聊处理；1:1 会话里名字和
   * 资料相同，就自然不重复写（顶栏已经有人名了）。
   */
  private showsSenderName(index: number, message: DirectMessage): boolean {
    if (message.mine) {
      return false;
    }
    const label: string = this.senderLabel(message);
    if (label.length === 0) {
      return false;
    }
    const group: boolean = this.view !== null && this.view.isGroup;
    if (!group) {
      const sameAsPeer: boolean = this.view !== null
        && (label === this.view.withUsername || label === this.view.withFullName);
      if (sameAsPeer) {
        return false;
      }
    }
    return !this.sameGroupAsPrev(index, message);
  }

  /** 下一条算不算"同一组的下一颗"（同一个人、同方向、间隔不超过 GROUP_GAP_MS）。 */
  private sameGroupAsNext(index: number, message: DirectMessage): boolean {
    const next: DirectMessage | undefined = this.nextOf(index, message);
    if (next === undefined) {
      return false;
    }
    if (next.mine !== message.mine) {
      return false;
    }
    if (DirectThreadPage.senderKeyOf(next) !== DirectThreadPage.senderKeyOf(message)) {
      return false;
    }
    return next.tsMs - message.tsMs <= GROUP_GAP_MS;
  }

  /** 这一条相对上一段要留多少顶部间距（带发送人名字的组再 +SENDER_NAME_TOP_GAP）。 */
  private topGapOf(index: number, message: DirectMessage): number {
    return this.sameGroupAsPrev(index, message) ? BUBBLE_GAP_VP : GROUP_GAP_VP;
  }

  /**
   * 四角圆角：**同一组里贴着的那一侧收小**（左侧消息收左角、右侧消息收右角），
   * 另一侧仍是 18 的大圆角 —— 这样连续几颗气泡看起来是一条，最外面那颗仍是完整的胶囊。
   */
  private bubbleCorners(index: number, message: DirectMessage): BorderRadiuses {
    const joinedPrev: boolean = this.sameGroupAsPrev(index, message);
    const joinedNext: boolean = this.sameGroupAsNext(index, message);
    const corners: BorderRadiuses = {
      topLeft: message.mine ? BUBBLE_RADIUS : (joinedPrev ? BUBBLE_RADIUS_JOIN : BUBBLE_RADIUS),
      topRight: message.mine ? (joinedPrev ? BUBBLE_RADIUS_JOIN : BUBBLE_RADIUS) : BUBBLE_RADIUS,
      bottomLeft: message.mine ? BUBBLE_RADIUS : (joinedNext ? BUBBLE_RADIUS_JOIN : BUBBLE_RADIUS),
      bottomRight: message.mine ? (joinedNext ? BUBBLE_RADIUS_JOIN : BUBBLE_RADIUS) : BUBBLE_RADIUS
    };
    return corners;
  }

  /** 这条消息的发送人在界面上的名字（拿不到就给空串，界面上就不画那一行）。 */
  private senderLabel(message: DirectMessage): string {
    if (message.senderName.length > 0) {
      return message.senderName;
    }
    return this.view !== null ? this.view.withUsername : '';
  }

  /** 分组建模用的"人"（同一人多条连续消息算一组）；空名时退回 user_id。 */
  private static senderKeyOf(message: DirectMessage): string {
    if (message.senderName.length > 0) {
      return message.senderName;
    }
    return message.userId.length > 0 ? message.userId : (message.mine ? 'me' : 'other');
  }

  private isNewGroup(index: number, message: DirectMessage): boolean {
    const prev: DirectMessage | undefined = this.prevOf(index, message);
    if (prev === undefined) {
      return false;
    }
    if (prev.mine !== message.mine) {
      return true;
    }
    return message.tsMs - prev.tsMs > GROUP_GAP_MS;
  }

  /**
   * 这条气泡还在"发送中"吗（本地乐观气泡、且没失败）。
   *
   * 收件箱/服务端来的消息 id 不是 `local-` 前缀（见 DirectThreadViewModel.send）。
   */
  private isSending(id: string): boolean {
    if (id.indexOf('local-') !== 0) {
      return false;
    }
    for (let index: number = 0; index < this.pending.length; index++) {
      if (this.pending[index].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 一条消息（自己的靠右、对方的靠左；对方的按时间段在左侧带头像）。 */
  @Builder
  bubble(message: DirectMessage, index: number) {
    Row({ space: 8 }) {
      if (message.mine) {
        Blank()
        Column({ space: 4 }) {
          this.bubbleContent(message, index)
          /*
           * **发送失败的标记**（用户报："会出现一两条消息发不出去的情况"）。
           *
           * 以前发送被挡下（上一发还在飞 / 写接口被拒）时，输入框已经清空、气泡也不再有任何提示，
           * 用户以为发出去了；退出重进一对记录就发现"对方那边没有"。
           * 现在失败的那条留在屏上、下面标红，点一下原样重发（气泡不重建，id 不变）。
           */
          if (this.failedIds.indexOf(message.id) >= 0) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
                .fontSize(12)
                .fontColor([$r('app.color.accent')])
              Text($r('app.string.direct_send_failed'))
                .fontSize(11)
                .fontColor($r('app.color.accent'))
            }
            .padding({ right: 4, top: 2 })
            .onClick((): void => {
              this.vm.retryFailed(message.id);
            })
          } else if (this.isSending(message.id)) {
            /*
             * **"发送中…"**：发消息要过 3~6 秒的人速间隔（见 ApiThrottle.writeSlot），
             * 没有这行字的话用户看到的就是"点了发送没反应"（用户报过两次）。
             */
            Text($r('app.string.direct_sending'))
              .fontSize(11)
              .fontColor($r('app.color.secondary_text'))
              .padding({ right: 4, top: 2 })
          }
        }
        .alignItems(HorizontalAlign.End)
      } else {
        Column({ space: 0 }) {
          // 群聊：这一组顶部写发送人（带文字阴影，压在深色背景上不糊）。
          if (this.showsSenderName(index, message) && this.senderLabel(message).length > 0) {
            Text(this.senderLabel(message))
              // 需求：白色文本、字号大一点、左侧留白加宽（对齐气泡文字而不是头像边缘）。
              .fontSize(SENDER_NAME_SIZE)
              .fontColor($r('app.color.primary_text'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textShadow({ radius: 4, color: '#A0000000', offsetX: 0, offsetY: 1 })
              .padding({ left: AVATAR_SIZE + SENDER_NAME_LEFT_PAD })
              .margin({ bottom: SENDER_NAME_BOTTOM_GAP })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          Row({ space: 8 }) {
            if (this.showsAvatar(index, message)) {
              Image(message.senderAvatar.length > 0
                ? message.senderAvatar
                : (this.view !== null && this.view.withAvatar.length > 0
                  ? this.view.withAvatar : $r('app.media.startIcon')))
                .draggable(false)
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                .borderRadius(AVATAR_SIZE / 2)
                .objectFit(ImageFit.Cover)
                .backgroundColor($r('app.color.field_background'))
            } else {
              Column().width(AVATAR_SIZE).height(AVATAR_SIZE)
            }
            this.bubbleContent(message, index)
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({
      left: SIDE_PADDING,
      // 自己发的那一侧和输入框对齐（见 INPUT_SIDE_INSET）。
      right: message.mine ? INPUT_SIDE_INSET : SIDE_PADDING,
      // 需求：带发送人名字的那一组，和上一段之间留出更明显的距离（见 topGapOf）。
      top: this.topGapOf(index, message),
      bottom: 0
    })
  }

  /** 这条消息有没有"可打开的分享目标"（帖子短码或外部链接）。 */
  private static hasShareTarget(message: DirectMessage): boolean {
    return message.shareCode.length > 0 || message.shareUrl.length > 0;
  }


  // ---------------- 分享卡片（转发的帖子 / Reels） ----------------

  /**
   * 作者行（头像 + 名字）。
   *
   * 头像**必须有**时才插 Image：ArkTS 里 `Image(undefined)` 画不出来（上一版就是这么"没绘制好"的）。
   */
  /**
   * 作者行（头像 + 名字）。
   *
   * 头像**必须有**时才插 Image：ArkTS 里 `Image(undefined)` 画不出来（上一版就是这么"没绘制好"的）。
   *
   * `maxWidth` 是**上限**而不是固定宽度（需求："用户资讯栏的容器宽度跟随文本宽度自适应"）——
   * 所以这里用 `constraintSize`，外面的材质胶囊因此会自动收紧到"头像 + 名字"的宽度。
   */
  @Builder
  shareUserRow(message: DirectMessage, fontSize: number, avatarSize: number, maxWidth: number) {
    Row({ space: 6 }) {
      if (message.shareAvatar.length > 0) {
        Image(message.shareAvatar)
          .width(avatarSize)
          .height(avatarSize)
          .borderRadius(avatarSize / 2)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .backgroundColor(FALLBACK_SURFACE)
      } else {
        // 没有头像就画一个同尺寸的圆点：作者行的高度不会因为它而塌。
        Column()
          .width(avatarSize)
          .height(avatarSize)
          .borderRadius(avatarSize / 2)
          .backgroundColor(FALLBACK_SURFACE)
      }
      /*
       * 作者名**一定是非空的**（调用方判断过）。不要再退回 `[消息]` 那种占位字 ——
       * 上一版这一行总是画出来，卡片看起来就是"一张封面 + 一个 [消息] 气泡"（用户报的正是这个）。
       */
      Text(message.shareUser)
        .fontSize(fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: Math.max(24, maxWidth - avatarSize - 6) })
    }
    .constraintSize({ maxWidth: maxWidth })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 帖子卡片的正文（需求："正文部分文本颜色改成白色，正文中用户名需要粗体"）。
   *
   * 用户名的处理：正文前面加一段**粗体**的作者名（IG 自己也是这么排的：`username 正文…`），
   * 后面是正文本身。两段拼在同一个 Text 里，所以"两行 + 省略号"是对整段生效的。
   */
  @Builder
  shareCaptionText(message: DirectMessage) {
    Text() {
      if (message.shareUser.length > 0) {
        Span(message.shareUser + ' ')
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      Span(message.shareCaption)
        .fontColor(Color.White)
    }
    .fontSize(12)
    .maxLines(2)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
    .textAlign(TextAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 10 })
  }

  /** 封面：有地址就画图，没有就画一块带图标的占位（尺寸永远固定，不会塌成 0）。 */
  @Builder
  shareCover(message: DirectMessage, width: number, height: number) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(FALLBACK_SURFACE)
      if (message.shareCover.length > 0) {
        Image(message.shareCover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .alt($r('app.media.grid_placeholder'))
      } else {
        SymbolGlyph($r(message.shareKind === 'video' ? 'sys.symbol.play_fill' : 'sys.symbol.photo'))
          .fontSize(26)
          .fontColor([$r('app.color.secondary_text')])
      }
    }
    .width(width)
    .height(height)
  }

  /**
   * **帖子卡片**（需求）：宽 2/3 屏。
   *
   * 三段顺序按需求（用户原话）：**"帖子卡片封面应该在用户资讯栏和正文之间"** ——
   * ```
   * 卡片（圆角 + 裁剪 + 沉浸光感底）
   *   ├─ 用户资讯栏（顶部；不需要自己的光感底）
   *   ├─ 封面      （中间；占满卡片宽度，高度按 4:5 给死）
   *   └─ 正文      （底部；两行，超出显示省略号）
   * ```
   * 整张卡是**一个**节点：圆角与裁剪只在外层做一次 —— 上一版是"封面 + 下面另一个材质块"
   * 两块各自圆角，看起来就是封面悬在卡片外面。
   */
  @Builder
  sharePostCard(message: DirectMessage) {
    Column() {
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Column() {
          if (message.shareUser.length > 0 || message.shareAvatar.length > 0) {
            Column() {
              // 需求："帖子卡片的用户资讯栏内容大小增加"（头像 26、名字 15）。
              this.shareUserRow(message, 15, 26, this.shareCardWidth(message) - 20)
            }
            .width(this.shareCardWidth(message))
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
          }
          this.shareCover(message, this.shareCardWidth(message), this.shareCardHeight(message))
          if (message.shareCaption.length > 0) {
            this.shareCaptionText(message)
          }
        }
        .width(this.shareCardWidth(message))
      }
      .width(this.shareCardWidth(message))
      .padding(0)
      .borderRadius(CARD_RADIUS)
      .clip(true)
      // 底色交给材质：材质自己画背板；不支持材质时 SurfaceModifier 退回低透明度中性底。
      .backgroundColor(Color.Transparent)
      .selectedColor(Color.Transparent)
      .attributeModifier(new SurfaceModifier(this.cardThickness, true))
      // 不吃触摸：点击统一落在最外层卡片上。
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.shareCardWidth(message))
    .borderRadius(CARD_RADIUS)
    .clip(true)
    .backgroundColor($r('app.color.field_background'))
    .onClick((): void => {
      this.onOpenShare(message);
    })
  }

  /**
   * **视频卡片**（需求）：宽 1/3 屏，形状照参考图 ——
   *
   * ```
   * Stack {
   *   底层：封面，铺满卡片的完整宽度与高度
   *   左上角：用户资讯栏 —— **悬浮**在封面左上角（不是排在封面上方的那一行）
   *   正中：暂停图标（只是一个图标，不是按钮）
   * }
   * ```
   *
   * 资讯栏用 `.position()` 直接压在封面上（并留一点内边距），层叠关系与"悬浮"这件事
   * 在代码里就是一句话；外层 `clip(true)` 保证它不会画到卡片圆角外面去。
   * 三层都**不接触摸**（`hitTestBehavior(None)`），点击统一落在最外层卡片上 → 进 Reels 类页面。
   */
  @Builder
  shareVideoCard(message: DirectMessage) {
    Stack({ alignContent: Alignment.Center }) {
      // 底层封面：宽高都给死，铺满整张卡片。
      this.shareCover(message, this.shareCardWidth(message), this.shareCardHeight(message))
      // 悬浮在封面左上角的用户资讯栏（带沉浸光感底；宽度跟着文本自适应，见 shareUserRow）。
      if (message.shareUser.length > 0 || message.shareAvatar.length > 0) {
        Toggle({ type: ToggleType.Button, isOn: false }) {
          // 需求："视频卡片的用户资讯栏内容大小增加" —— 头像 20、名字 12，胶囊随之放大。
          this.shareUserRow(message, 12, 20, this.shareCardWidth(message) - 30)
        }
        .padding({ left: 6, right: 9, top: 4, bottom: 4 })
        .borderRadius(13)
        // 底色交给材质（同帖子卡片那条说明）。
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.cardThickness, true))
        .position({ x: 8, y: 8 })
        .hitTestBehavior(HitTestMode.None)
      }
      // 垂直横向置中：播放三角（系统符号；纯图标、无按钮、不吃触摸）。
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(28)
        .fontColor([Color.White])
        .hitTestBehavior(HitTestMode.None)
    }
    .width(this.shareCardWidth(message))
    .height(this.shareCardHeight(message))
    .borderRadius(CARD_RADIUS)
    .clip(true)
    .backgroundColor($r('app.color.field_background'))
    .onClick((): void => {
      this.onOpenShare(message);
    })
  }

  /** 分享卡片入口：按形态分发（外链卡片也按帖子卡片画）。 */
  @Builder
  shareCard(message: DirectMessage) {
    if (message.shareKind === 'video') {
      this.shareVideoCard(message)
    } else {
      this.sharePostCard(message)
    }
  }

  /** 气泡内容：有图先画图，文字跟在图下面。 */
  @Builder
  bubbleContent(message: DirectMessage, index: number) {
    Column({ space: 6 }) {
      if (message.mediaSticker) {
        /*
         * **贴图 / 动图最先判断**（用户报："贴图被识别成卡片了"）。
         *
         * 以前这里先看 `shareKind`：某些贴图条目同时带了分享类字段，于是被画成了大卡片。
         * 贴图就是一张小图，不该走卡片那条路 —— 所以把它提到最前面。
         */
        this.stickerBubble(message)
      } else if (message.shareKind.length > 0) {
        // 分享的帖子/视频：画成卡片（见 sharePostCard / shareVideoCard）。
        this.shareCard(message)
      } else if (message.mediaUrl.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          Image(message.mediaUrl)
            .draggable(false)
            // 尺寸：贴图按屏幕 1/3 画、图片按原图比例（横 16:9 / 方 1:1 / 长最多 4:3）。
            .width(this.mediaBoxWidth(message))
            .height(this.mediaBoxHeight(message))
            // 贴图（透明 PNG / GIF）用 Contain 完整显示，普通图片用 Cover 填满。
            .objectFit(message.mediaSticker ? ImageFit.Contain : ImageFit.Cover)
            .borderRadius(message.mediaSticker ? 0 : 16)
            // 贴图不能有底色：透明贴图压在深色气泡底上就成一块黑块了（需求）。
            .backgroundColor(message.mediaSticker ? Color.Transparent
              : $r('app.color.field_background'))
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
          /*
           * **分享卡片可点**（需求："会话里的转发帖子/Reels 现在只能看封面，点不进去"）：
           * 有帖子短码或外部链接时，整块封面就是入口（气泡里的文字仍然可复制，不受影响）。
           */
          .onClick((): void => {
            if (DirectThreadPage.hasShareTarget(message)) {
              this.onOpenShare(message);
            }
          })
          if (message.isVideo || message.shareIsVideo) {
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
            .width(this.mediaBoxWidth(message))
            .height(this.mediaBoxHeight(message))
            .borderRadius(message.mediaSticker ? 0 : 16)
            .backgroundColor(message.mediaSticker ? Color.Transparent
              : $r('app.color.field_background'))
          SymbolGlyph($r(message.isVideo ? 'sys.symbol.play_fill' : 'sys.symbol.photo'))
            .fontSize(22)
            .fontColor([$r('app.color.secondary_text')])
        }
          // 占位块也接同一个入口：分享的帖子这一版没给预览图时，用户仍然点得进去。
          .onClick((): void => {
            if (DirectThreadPage.hasShareTarget(message)) {
              this.onOpenShare(message);
            }
          })
      }
      if (message.text.length > 0) {
        Text(message.text)
          // 需求：气泡再大一点（字号 15→16、内边距 12/8→14/10）。
          .fontSize(16)
          .fontColor(message.mine ? $r('app.color.on_accent') : $r('app.color.primary_text'))
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(message.mine ? $r('app.color.accent') : $r('app.color.field_background'))
          // 贴着同组下一条的那一侧角收小（见 bubbleCorners）。
          .borderRadius(this.bubbleCorners(index, message))
          .constraintSize({ maxWidth: this.bubbleMaxVp() })
      } else if (message.mediaUrl.length === 0 && !DirectThreadPage.isMediaKind(message.kind)) {
        // 没有封面也没有 media 类型：有分享目标时这一块就是入口（点了能查看）。
        Text($r('app.string.direct_kind_other'))
          .fontSize(16)
          .fontColor(message.mine ? $r('app.color.on_accent') : $r('app.color.primary_text'))
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(message.mine ? $r('app.color.accent') : $r('app.color.field_background'))
          .borderRadius(this.bubbleCorners(index, message))
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

          /*
           * **回到 `ForEach`**（撤掉 LazyForEach）。
           *
           * 上一版为了"上滑时逐条播动画"换成了 LazyForEach + 增量通知，结果把**触顶刷新的锚位**
           * 弄坏了：整表/头部插入会让 List 自己挪动滚动位置，加载一页就被拽回底部，然后再触顶、
           * 再加载（用户报的死循环）。`ForEach` 的条目是首帧建好的、滚动不重建，
           * 位置完全由 `scrollToIndex` 说了算 —— 这是"改动画之前没问题"的那套行为，先恢复它。
           */
          ForEach(this.allMessages(), (message: DirectMessage, index: number): void => {
            ListItem() {
              /*
               * **气泡入场**：外面这层只负责动画（见 PopInBubble），内容还是宿主画。
               *
               * 每一批**新冒出来**的气泡弹一次：进会话（整屏从最下面往上）、刷新出来的新消息、
               * 自己刚发出去的那条。同一批里按"从最下面到最上面"排队（`delayMs` 由 popDelayFor 给）。
               */
              PopInBubble({ delayMs: this.popDelayFor(message.id) }) {
                this.bubble(message, index)
              }
            }
            // 退场只淡出：气泡被删掉（撤回/消息替换）时不该有弹跳。
            .transition(TransitionEffect.OPACITY.animation({ duration: 120, curve: Curve.EaseOut }))
            /*
             * **键只认消息 id，不带序号**。
             *
             * 以前是 `${index}-${id}`：只要列表前面多/少一条（实时补 insert、待发那条撤掉、
             * 刷新换了窗口），**后面每一行的序号都变**，`ForEach` 把它们全当新条目重建 ——
             * 用户看到的就是"刷新一下，整屏气泡又弹一遍"。
             * 消息 id 是稳定的，序号变化不该影响条目身份（`bubble` 里的序号只是排间距用，
             * 真取数据已经改成按 id 反查，见 prevOf）。
             */
          }, (message: DirectMessage, index: number): string =>
            message.id.length > 0 ? message.id : `row-${index}`)

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
          /*
           * **离开过顶部才重新武装触顶刷新**（见 onReachStart 里那三道闸）。
           *
           * 阈值取得比标题栏让位小一点：滚下去半屏就足够说明"用户真的离开了顶部"。
           */
          if (this.userTouching && y > REACH_REARM_OFFSET_VP) {
            this.reachArmed = true;
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
           * **同一次"拉到底"只触发一发**。
           *
           * 两道闸（都在"改动画"那一轮踩过坑）：
           *   ① 一发在飞时不再发（`olderInFlight`）；
           *   ② 触发一次就**解除武装**，只有**真实手指**离开过顶部（>80vp）才重新武装
           *      （见 onDidScroll）—— 程序化的锚位滚动不算，否则
           *      "加载 → 锚回 → 又被当成离开顶部 → 再加载"就是那个死循环；
           *   ③ 冷却时间（同一次下拉的弹性回弹会连报好几次）。
           */
          if (this.olderInFlight || !this.reachArmed) {
            return;
          }
          const now: number = Date.now();
          if (now - this.lastReachAtMs < REACH_COOLDOWN_MS) {
            return;
          }
          this.lastReachAtMs = now;
          this.reachArmed = false;
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
     *
     * 顺带记"手指在不在屏幕上"：**只有真实手指**才重新武装触顶刷新
     * （见 onDidScroll 里那条），程序化的锚位滚动不许武装 —— 否则
     * "加载 → 锚回 → 又被当成离开顶部 → 再加载"就是那个死循环。
     */
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.userTouching = true;
        this.vm.touchActivity();
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.userTouching = false;
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

/**
 * **气泡的入场外壳**：只负责"弹出"动画，内容由宿主通过 `@BuilderParam` 传进来。
 *
 * ## 为什么要单独一个组件
 * 动画状态必须是**每条气泡自己的** `@State`。写在宿主里的话，开关一变要靠宿主重绘 ——
 * 而 `ForEach` 对"键没变"的条目**不会重跑 item builder**（本项目踩过这个坑，见
 * pages/Index 里分段按钮的说明），气泡就永远停在初始状态。
 * 独立组件各自持有 `shown`，翻一次自己就重绘自己，与宿主、与别的气泡互不牵连。
 *
 * ## 动画本身（需求："从下往上，由小至大渐显弹出，非线性弹性"）
 *   · `translate` y:+16 → 从下方升上来；
 *   · `scale` 0.86、缩放中心 `centerY: 100%` → **贴着底边长起来**（不是从中心涨开）；
 *   · `opacity` 0 → 渐显；
 *   · 曲线 `curves.springMotion(0.65, 0.56)`：阻尼比 < 1，落定时带一点过冲，这才是弹性。
 *
 * ## 级联
 * `delayMs` 由宿主按"从最新一条往回数"的顺序给出（见 DirectThreadPage.popDelayFor），
 * 于是进会话时整屏气泡是**从下往上一格格弹出来**的。
 */
@Component
struct PopInBubble {
  /**
   * 入场延迟（毫秒）：0 = 立刻，>0 = 级联档位（由宿主按"从最下面到最上面"排好），
   * **负值（`POP_NONE`）= 不播**、直接落到终态。
   */
  @Prop delayMs: number = 0;
  /** 气泡本体（宿主画：方向、头像、内容都在里面）。 */
  @BuilderParam content: () => void;
  /** 已经"就位"了没有（false = 还停在起点：小、低、透明）。 */
  @State private shown: boolean = false;
  /** 延迟用的定时器句柄（组件销毁要清，否则会去写已卸载的状态）。 */
  private delayTimer: number = -1;

  aboutToAppear(): void {
    // POP_NONE = 不播：首帧就设成终态，隐式动画没有"属性变化"就不会播（见 PopInBubble 的说明）。
    if (this.delayMs < 0) {
      this.shown = true;
      return;
    }
    /*
     * **一定要至少等一帧**再把 `shown` 打开：同一帧里设成 true 的话，
     * 首帧就已经是终态、压根没有"从 0.86 弹到 1"这个过程（隐式动画要求属性真的变化过）。
     */
    const delay: number = this.delayMs > 0 ? this.delayMs : POP_MIN_DELAY_MS;
    this.delayTimer = setTimeout((): void => {
      this.delayTimer = -1;
      this.shown = true;
    }, delay);
  }

  aboutToDisappear(): void {
    if (this.delayTimer >= 0) {
      clearTimeout(this.delayTimer);
      this.delayTimer = -1;
    }
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .opacity(this.shown ? 1 : 0)
    .scale({
      x: this.shown ? 1 : BUBBLE_POP_FROM,
      y: this.shown ? 1 : BUBBLE_POP_FROM,
      centerX: '50%',
      centerY: '100%'
    })
    .translate({ y: this.shown ? 0 : BUBBLE_POP_RISE_VP })
    // 隐式动画：上面三个属性一变就按这条弹簧补出来。
    .animation({ curve: curves.springMotion(BUBBLE_SPRING_VELOCITY, BUBBLE_SPRING_DAMPING) })
  }
}
