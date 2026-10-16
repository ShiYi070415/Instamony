/*
 * 「私信会话」原生页面：消息列表 + 底部悬浮输入条。
 *
 * 版式：进入就定位到最新消息；自己靠右、对方靠左并在"时间段第一条"左侧显示头像；
 * 相邻两条同发送者间隔 ≤2 分钟算一段（段内紧、段间留白）；输入条悬浮在列表之上。
 *
 * 加载更老：**上拉到顶部后继续下拉触发 `Refresh`** 才去取（需求），取回来之后把视口
 * **锚回加载前那条消息**（`scrollToIndex`），所以页面位置不变、不闪。
 */

import { display } from '@kit.ArkUI';
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
/** 触顶自动下拉时，顶部占位往下弹多少（vp）—— 就是"下拉"那一段看得见的过程。 */
const PULL_DOWN_VP: number = 56;
const BOTTOM_OFFSET: number = 92;
const FALLBACK_WIDTH_VP: number = 411;
const SIDE_PADDING: number = 16;
const AVATAR_SIZE: number = 28;
const BUBBLE_MAX_RATIO: number = 0.72;
const BUBBLE_GAP_VP: number = 2;
const GROUP_GAP_VP: number = 12;
const GROUP_GAP_MS: number = 2 * 60 * 1000;

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
  /** 顶部下拉刷新（= 取更老那批）的状态。 */
  @State private refreshing: boolean = false;
  /** 模拟"下拉"的下沉量（vp）：触顶时把内容弹下去一点再回来，做出原生下拉的过程。 */
  @State private pullVp: number = 0;
  @State private screenWidthVp: number = FALLBACK_WIDTH_VP;
  /** 当前"最新那条"的 id（区分"来新消息"和"往前插历史"）。 */
  private newestId: string = '';
  private readonly listScroller: Scroller = new Scroller();
  private readonly scrollDelta: ScrollDelta = new ScrollDelta();

  aboutToAppear(): void {
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(dsp.width);
    } catch (error) {
      this.screenWidthVp = FALLBACK_WIDTH_VP;
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

  private scrollToNewest(): void {
    const run: () => void = (): void => {
      try {
        this.listScroller.scrollEdge(Edge.Bottom);
      } catch (error) {
      }
    };
    this.scrollTimers.push(setTimeout(run, 0));
    this.scrollTimers.push(setTimeout(run, 60));
    this.scrollTimers.push(setTimeout(run, 200));
  }

  /**
   * 这些裸 `setTimeout` 的句柄（审计项 A2：以前既没句柄、`aboutToDisappear` 也没清）。
   *
   * 组件销毁后它们仍会跑：`scrollToNewest` 那三个去读已放掉的 `listScroller`，
   * 8 秒兜底那个去写 `@State refreshing`（还可能把新一次加载的圈误收掉）。
   */
  private scrollTimers: Array<number> = [];
  /** 8 秒兜底收圈那个定时器（见 loadOlderKeepPosition）。 */
  private settleTimer: number = -1;

  /**
   * 取更老那批，并把视口**锚回加载前的那条消息**（需求："加载后页面位置保持不变"）。
   *
   * 加载前记住条数；加载后"新增的条数"就是前面插进来多少条，用 `scrollToIndex(新增条数)`
   * 把**原来的第一条**重新对齐到顶部 —— 位置看起来没动，也不会先跳到底再弹回来那种闪烁。
   */
  private loadOlderKeepPosition(showSpinner: boolean = false): void {
    const before: number = this.allMessages().length;
    // 只有**手动下拉**（原生 Refresh 的回调）才亮圈；触顶自动加载静默进行，不显示下拉动画。
    if (showSpinner) {
      this.refreshing = true;
    }
    /*
     * 兜底：取数这条路万一没回来，8 秒后也把圈收掉。句柄存起来：新一次加载开始时要**取消上一次**
     * （否则上一发的兜底会把这一发的圈提前收掉），销毁时也要清（审计项 A2）。
     */
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout((): void => {
      this.settleTimer = -1;
      this.settleRefresh();
    }, 8000);
    /*
     * **首屏还没读出来时，下拉就是"重试加载"**（审计 C3）。
     *
     * `loadOlder()` 第一行就是 `if (this.busy || this.view === null || …) return;` —— 首屏失败
     * （`view` 一直为 null）之后，下拉触顶只会立刻返回：用户看到的是"圈转一下就没了、什么也不发生"，
     * 而这一页再也没有别的入口去重试。这里把下拉接到 `load()` 上，等于给用户一个重试键。
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
            this.listScroller.scrollToIndex(added, false, ScrollAlign.START);
          } catch (error) {
          }
        }
        this.settleRefresh();
      })
      .catch((): void => {
        this.settleRefresh();
      });
  }

  /** 收起刷新圈（下拉量归零）。 */
  private settleRefresh(): void {
    this.pullVp = 0;
    this.refreshing = false;
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
         * 什么时候会走到这里：这一条来自**预取的文本快照** —— 缓存里刻意不存媒体地址
         * （签名会过期，见 core/DirectCache 的文件头），所以先按这条消息的类型画一块占位，
         * 等 `load()` 那一发刷新把媒体地址带回来，上面那个分支就把它换成真图/视频封面。
         * 占位尺寸与真媒体一致，换上去时不会跳。
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
        Stack()
          .width('100%')
          .height(PAGE_TOP_OFFSET + this.pullVp)

        if (this.status.length > 0) {
          Text(this.status)
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: SIDE_PADDING, right: SIDE_PADDING, bottom: 4 })
        }

        /*
         * **临时调试入口**：把这条会话在**可见网页**里打开。
         *
         * 用途只有一个：网页的消息容器认**真实触摸**，只有它在屏幕上、我用真手指滑动时，页面
         * 才会去加载更老的消息 —— 那时我们的网络钩子就能抓到"翻历史到底用哪条请求"。
         * （隐藏网页里试过 scrollTop / wheel / scrollIntoView / 合成 touch 事件，页面都不动。）
         * 打通之后这个入口和下面那个探针定时器一起删掉。
         */
        Row() {
          Text($r('app.string.direct_open_web'))
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .onClick((): void => {
              this.onOpenWeb();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ right: SIDE_PADDING, bottom: 4 })

        // **顶部下拉刷新 = 取更老那批**（需求："上滑触顶需要继续上滑触发 refresh 才能加载"）。
        // 「查看更多消息」那颗按钮和"触顶自动加载"都按需求删掉了，只留这一个入口。
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0, scroller: this.listScroller }) {
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
                   * 读失败时（状态行有字 = 原生三条路都断了）多给一颗出口按钮。
                   * 读成功但真的没有消息（status 为空）时不显示 —— 那种情况不该诱使用户去网页。
                   */
                  if (this.status.length > 0) {
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
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .contentEndOffset(BOTTOM_OFFSET)
          .clip(false)
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.scrollDelta.report(this.listScroller.currentOffset().yOffset, scrollState,
              this.onFeedScroll);
          })
          /*
           * **触顶自动加载**：滑到最上面就自动去取更老那批，但**不**自己去点亮刷新圈
           * —— 刷新圈交给原生 `Refresh`：手动下拉时它有原生的弹性动画、并在 `refreshing`
           * 收敛后自己收起（自己置 true 会出现"加载完了圈还在转"）。
           */
          .onReachStart((): void => {
            if (this.busy) {
              return;
            }
            if (this.view === null || !this.view.hasOlder
              || this.view.oldestCursor.length === 0) {
              return;
            }
            this.loadOlderKeepPosition();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .clip(false)
        .onRefreshing((): void => {
          this.loadOlderKeepPosition(true);
        })
      }
      .width('100%')
      .height('100%')

      this.inputOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  /** 悬浮的输入条（和评论浮层里那条完全同一个组件）。 */
  @Builder
  inputOverlay() {
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
            })
            .catch((): void => {
            });
        }
      })
    }
    .width('100%')
    .padding({ bottom: COMMENT_INPUT_BOTTOM_VP })
  }
}
