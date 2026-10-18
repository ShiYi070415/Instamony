/*
 * 「私信」原生页面：收件箱（会话列表）。
 *
 * 排版与配色跟首页信息流 / 「我的」是同一套（page_background / primary_text / secondary_text /
 * field_background、圆角与间距对得上），不引新的视觉语言。
 *
 * 数据由 DirectViewModel 给（回放接口，见它的说明）；这里只管画与手势：
 *   - 一行一条会话：头像 + 名字 + 最近一条消息预览 + 时间；未读给一个小圆点；
 *   - 顶部让出标题栏、底部让出悬浮 tab 栏（和「我的」同样的两个常量）；
 *   - 下拉刷新走 Refresh（**空态也包在 Refresh 里**，否则没消息时拉不动）；
 *   - 触底自动翻页。
 *
 * **不做发送**：点一条会话交给网页打开（原生不构造写请求，和"点帖子交给网页"同一条路）。
 */

import { display } from '@kit.ArkUI';
import { DirectThread } from '../model/Direct';
import { DirectViewModel } from '../viewmodel/DirectViewModel';
import { ScrollDelta } from '../core/ScrollReport';

/** 顶部让出标题栏、底部让出悬浮 tab 栏（与首页/我的同一个数）。 */
const DIRECT_TOP_OFFSET: number = 94;
const DIRECT_BOTTOM_OFFSET: number = 96;
/** 头像直径、左右内边距（vp）。 */
const AVATAR_SIZE: number = 52;
const SIDE_PADDING: number = 16;
/** 量不到屏幕宽度时的兜底（vp）。 */
const FALLBACK_WIDTH_VP: number = 360;
/** 时间分档（毫秒）。 */
const MINUTE_MS: number = 60 * 1000;
/**
 * 收件箱"还算新鲜"的窗口（毫秒）：在这个窗口内，进私信页**不再重新拉一次**。
 *
 * 见 `DirectViewModel.isFresh` 与 `aboutToAppear` 的说明：feeds 页会提前预热收件箱，
 * 这个窗口决定"预热来的数据能用多久"。取 2 分钟 —— 盖得住"打开 app → 看一会儿 → 点私信"
 * 这个真实节奏，又不至于让用户看到明显过期的列表。
 */
const PREFETCH_FRESH_MS: number = 2 * MINUTE_MS;
const HOUR_MS: number = 60 * MINUTE_MS;
const DAY_MS: number = 24 * HOUR_MS;
const WEEK_MS: number = 7 * DAY_MS;
/** 未读条目在列表右侧那顆**深蓝色**圆点的颜色。 */
const UNREAD_DOT_COLOR: string = '#1D4ED8';
/** "n 条新消息"里 n 的上限（需求：n 最大等于 4）。 */
const UNREAD_MAX: number = 4;

@Component
export struct DirectPage {
  /** 视图模型：**普通属性**，不用 @ObjectLink（页面自己用 @State 存显示用的数据）。 */
  vm: DirectViewModel = new DirectViewModel();
  /** 点一条会话：交给页面用网页打开。 */
  onOpen: (thread: DirectThread) => void = (thread: DirectThread): void => {
  };
  @State private threads: Array<DirectThread> = [];
  @State private busy: boolean = false;
  @State private status: string = '';
  @State private refreshing: boolean = false;
  @State private hasMore: boolean = false;
  @State private screenWidthVp: number = FALLBACK_WIDTH_VP;
  private readonly listScroller: Scroller = new Scroller();
  /** 滚动增量记账（底栏下沉/隐藏用，见 core/ScrollReport）。 */
  private readonly scrollDelta: ScrollDelta = new ScrollDelta();
  /**
   * 滚动中：把这一帧的滚动增量报给页面（底栏那两套动画的判据，和 FeedList 同一个约定）。
   *
   * 只报事实、不下判断：多小的增量算"真的在滑"、要不要下沉，都由页面定。
   */
  onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
    };
  /** 上一次触发翻页的时刻（限流：列表滚动会反复触发）。 */
  private lastAskMs: number = 0;

  aboutToAppear(): void {
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(dsp.width);
    } catch (error) {
      this.screenWidthVp = FALLBACK_WIDTH_VP;
    }
    this.vm.onThreads = (threads: Array<DirectThread>, hasMore: boolean): void => {
      this.threads = threads;
      this.hasMore = hasMore;
    };
    this.vm.onBusy = (busy: boolean): void => {
      this.busy = busy;
    };
    this.vm.onStatus = (text: string): void => {
      this.status = text;
    };
    // 先回填视图模型里已有的数据（切 tab 会重建这个组件，取数结果留在视图模型里）。
    this.syncFromVm();
    /*
     * **数据新鲜就别再拉一次**（用户报的"私信列表加载慢"）。
     *
     * feeds 页现在会提前把收件箱预热好（`Index.warmOtherTabs` 的 direct 那一步，同一个 vm 实例），
     * 切过来时 `syncFromVm()` 已经把列表铺上了 —— 这时再 `load(true)` 等于让用户白等一次网络往返
     * （而且强制刷新会把游标清掉，用户刚滚出来的"更多"也就没了）。
     * 判断窗口取 2 分钟：足够盖住"打开 app → 看一会儿 → 点私信"这个真实节奏，
     * 又不会让用户看到太旧的列表（更旧的情况会照常重新拉）。
     */
    if (this.vm.isFresh(PREFETCH_FRESH_MS)) {
      // 文案与 vm 里那两句（'已加载' / '已加载（首次走网页抓接口）'）同一风格：状态行是诊断性的。
      this.status = '已加载（feeds 页已预热）';
      return;
    }
    // 再拉一次（有模板时是毫秒级回放）；完成后回读一次，避免回调落在已被销毁的实例上。
    this.vm.load(true)
      .then((): void => {
        this.syncFromVm();
      })
      .catch((): void => {
      });
  }

  /** 从视图模型回读当前数据（唯一的数据出口）。 */
  private syncFromVm(): void {
    this.threads = this.vm.list();
    this.hasMore = this.vm.hasMore();
    this.busy = this.vm.isBusy();
  }

  private refresh(): void {
    this.refreshing = true;
    this.vm.load(true)
      .then((): void => {
        this.syncFromVm();
        this.refreshing = false;
      })
      .catch((): void => {
        this.refreshing = false;
      });
  }

  /** 滚到底附近时请求更多（限流一次）。 */
  private askMore(): void {
    if (this.threads.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAskMs < 1200) {
      return;
    }
    this.lastAskMs = now;
    this.vm.requestMore();
  }

  /**
   * 消息预览文字（**纯字符串**：这一行要和相对时间拼在一起，`ResourceStr` 拼不了）。
   *
   * 占位文本和资源里那三句保持一致（direct_kind_voice / media / other）。
   */
  private previewText(thread: DirectThread): string {
    if (thread.text.length > 0) {
      return thread.text;
    }
    const kind: string = thread.kind.toLowerCase();
    if (kind.indexOf('voice') >= 0 || kind.indexOf('audio') >= 0) {
      return '[语音]';
    }
    if (kind.indexOf('media') >= 0 || kind.indexOf('raven') >= 0 || kind.indexOf('clip') >= 0) {
      return '[照片/视频]';
    }
    return '[消息]';
  }

  /**
   * 列表第二行：**"内容 · 相对时间"**（需求："消息内容展示为『消息内容 · 现在/n分钟/n小时/n天/n周』"）。
   *
   * 未读超过一条时，内容位换成 **"n 条新消息"**（n 封顶 4，见 DirectThread.unreadCount）。
   */
  private previewLine(thread: DirectThread): string {
    const when: string = this.agoText(thread.tsMs);
    let head: string = '';
    if (thread.unreadCount > 1) {
      const n: number = thread.unreadCount > UNREAD_MAX ? UNREAD_MAX : thread.unreadCount;
      head = `${n}条新消息`;
    } else {
      head = this.previewText(thread);
    }
    return when.length > 0 ? `${head} · ${when}` : head;
  }

  /** 相对时间（现在 / N分钟 / N小时 / N天 / N周）。 */
  private agoText(tsMs: number): string {
    if (tsMs <= 0) {
      return '';
    }
    const diff: number = Date.now() - tsMs;
    if (diff < MINUTE_MS) {
      return '现在';
    }
    if (diff < HOUR_MS) {
      return `${Math.floor(diff / MINUTE_MS)}分钟`;
    }
    if (diff < DAY_MS) {
      return `${Math.floor(diff / HOUR_MS)}小时`;
    }
    if (diff < WEEK_MS) {
      return `${Math.floor(diff / DAY_MS)}天`;
    }
    // 超过一周按周记（需求列到"周"为止；再久给具体日期更直观）。
    if (diff < WEEK_MS * 5) {
      return `${Math.floor(diff / WEEK_MS)}周`;
    }
    const date: Date = new Date(tsMs);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  /** 一行会话。 */
  @Builder
  threadRow(thread: DirectThread) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (thread.avatarUrl.length > 0) {
          Image(thread.avatarUrl)
            .draggable(false)
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .borderRadius(AVATAR_SIZE / 2)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.field_background'))
        } else if (thread.isGroup) {
          /*
           * **群聊没有群图**：画一个中性的群图标，不要退回某个成员的头像 ——
           * 那会让列表里出现两行"同一个人 + 同一个头像"（群那一行看着就是那个人，用户报的就是它）。
           */
          Column() {
            SymbolGlyph($r('sys.symbol.person_2_fill'))
              .fontSize(22)
              .fontColor([$r('app.color.secondary_text')])
          }
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.field_background'))
        } else {
          Image($r('app.media.startIcon'))
            .draggable(false)
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .borderRadius(AVATAR_SIZE / 2)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.field_background'))
        }
        /*
         * 未读不再在头像上点小圆点：需求要的是"在私信 item **右侧**显示深蓝色圆点"，
         * 见下面那一行最后那颗点。
         */
      }
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(thread.title.length > 0 ? thread.title : 'instagram')
            .fontSize(14)
            .fontWeight(thread.unread ? FontWeight.Bold : FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        /*
         * 第二行 = "内容 · 相对时间"；未读多条的显示"n 条新消息"（见 previewLine）。
         * 未读整行加粗（需求："如果是未读消息则粗体显示"）。
         */
        Text(this.previewLine(thread))
          .fontSize(13)
          .fontWeight(thread.unread ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(thread.unread ? $r('app.color.primary_text') : $r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      /*
       * 未读：**右侧一颗深蓝色圆点**（需求）。用容器画（圆角 + 底色），API 20 起可用；
       * 不用 Circle().fill()/stroke()（26 起，本包 compatibleSdk 是 20）。
       */
      if (thread.unread) {
        Column()
          .width(10)
          .height(10)
          .borderRadius(5)
          .backgroundColor(UNREAD_DOT_COLOR)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 10, bottom: 10 })
    .onClick((): void => {
      this.onOpen(thread);
    })
  }

  build() {
    // 顶部那层透明占位与首页/「我的」同一套做法：把原生下拉刷新的图标挪到标题栏下面。
    Column() {
      Stack()
        .width('100%')
        .height(DIRECT_TOP_OFFSET)

      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 0, scroller: this.listScroller }) {
          if (this.status.length > 0) {
            // 状态行：取数进度 / 失败原因（正常加载成功后是一句"已加载"）。
            // 它同时是**排查通道** —— 这里的日志常被系统刷掉，界面上的这行字一定读得到。
            ListItem() {
              Text(this.status)
                .fontSize(12)
                .fontColor($r('app.color.secondary_text'))
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 6, bottom: 6 })
            }
          }

          ForEach(this.threads, (thread: DirectThread): void => {
            ListItem() {
              this.threadRow(thread)
            }
          }, (thread: DirectThread): string => thread.id)

          if (this.threads.length > 0) {
            // 触底哨兵：进到可见范围就翻页；到底了给一句"没有更多了"。
            ListItem() {
              Row({ space: 8 }) {
                if (this.busy && this.hasMore) {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color($r('app.color.secondary_text'))
                }
                Text(this.hasMore ? $r('app.string.profile_loading_more')
                  : $r('app.string.profile_end'))
                  .fontSize(12)
                  .fontColor($r('app.color.secondary_text'))
              }
              .width('100%')
              .height(56)
              .justifyContent(FlexAlign.Center)
              .onAppear((): void => {
                this.askMore();
              })
            }
          } else if (!this.busy) {
            ListItem() {
              Column({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.paperplane'))
                  .fontSize(34)
                  .fontColor([$r('app.color.secondary_text')])
                Text($r('app.string.direct_empty'))
                  .fontSize(14)
                  .fontColor($r('app.color.secondary_text'))
              }
              .width('100%')
              .height(220)
              .justifyContent(FlexAlign.Center)
            }
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentEndOffset(DIRECT_BOTTOM_OFFSET)
        // 滚动 → 底栏下沉/隐藏（判据与去重都在 pages/Index，见 onFeedScroll）。
        .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
          this.scrollDelta.report(this.listScroller.currentOffset().yOffset, scrollState,
            this.onFeedScroll);
        })
        /*
         * **触底翻页**（需求）：滑到最下面就要下一页会话。
         *
         * 原来只有末尾哨兵 `onAppear` 一个触发点 —— 它只报一次：第一屏会话少的时候哨兵
         * 一开始就在可见范围里、触发过一次之后再也不来，于是"怎么滑都不加载"。
         * `onReachEnd` 会反复触发，配合 `askMore` 自己的节流 + VM 里的 busy/more 闸门就够。
         */
        .onReachEnd((): void => {
          this.askMore();
        })
        // **别裁内容**：列表可视区在顶部那层透明占位下面，关掉裁剪后滚动的行才会画到标题栏
        // 底下去（和 FeedList 同一套结构：透明 Stack 避让 + 内容可穿过标题栏）。
        .clip(false)
      }
      .width('100%')
      .layoutWeight(1)
      // Refresh 也别裁：内容要能从它顶边越出去。
      .clip(false)
      .onRefreshing((): void => {
        this.refresh();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
