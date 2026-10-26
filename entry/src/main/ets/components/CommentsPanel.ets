/*
 * 评论面板：**评论详情面板**（自绘浮层的上半块，不再用系统半模态 bindSheet）。
 *
 * 版式（需求）：
 *   顶部一条**可以拖的小横条** + 它下方**置中的「评论」字样**
 *   → 评论列表（每条 = 头像 + 左对齐的「粗体用户 id / 正文 / 贴图 / 灰色"回复"」+ 右侧点赞）。
 *
 * 形状：**四个角都是圆角**，宽度由外层容器给（和底部输入条等宽，见 pages/Index）。
 *
 * ## 拖动（需求给的状态机，`panOptions` 是唯一开关）
 *   · **置中档**：面板全局 PanGesture **覆盖列表**（方向 All），上滑展开、下滑收起；
 *     列表此时**不接收滚动**（宿主传下来的 `panelAtTop=false` → `enableScrollInteraction(false)`）。
 *   · **置顶档 + 列表在顶部**：只启用**下滑**方向（`PanDirection.Down`）——
 *     下滑回到置中档；**上滑不归面板**，落到 List 上滚列表。
 *   · **置顶档 + 列表不在顶部**：方向设为 **`PanDirection.None`（完全禁用）**，
 *     列表自由滚；此时**只有面板顶部那条（小横条 + 标题）**还有自己的手势。
 *
 * 方向用 `PanGestureOptions.setDirection()` 动态改（官方说明：这样改不会触发 UI 刷新），
 * 并且只在**手势边界**（档位变化、滚动起停）改，不会在拖动中途把手势打断。
 */

import { CommentItem } from '../model/Comment';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { SurfaceModifier } from './MaterialSurface';
import { PostCardPanel } from './PostCardPanel';
import { TranslateLabel } from './TranslateLabel';
import { Translator } from '../core/Translator';

const DOMAIN = 0xFF00;
const TAG = 'InstarmonyCommentsPanel';

/** 头像大小（vp）：评论行用小一号，作者行大一点。 */
const COMMENT_AVATAR_SIZE: number = 32;
/** 左右统一留白。 */
const SIDE_PADDING: number = 16;
/**
 * 面板圆角（vp）：**四个角都是圆的**（需求）。
 *
 * 材质层和内容层用同一个半径，并且根节点 `clip(true)` —— 不然内容会溢出到圆角外面。
 */
const PANEL_RADIUS_VP: number = 22;
/**
 * **正文列**距离面板左边的距离（vp）= 左右留白 + 头像 + 行内间距。
 *
 * 父评论的 id/正文/回复、下挂回复的 id/正文/回复、以及那条灰色实线，都从这条线开始 ——
 * 需求："下挂回复左侧对齐头部评论的用户id、正文、回复字样" + "灰色实线对齐头部评论的用户id"。
 */
const TEXT_COLUMN_VP: number = SIDE_PADDING + 32 + 10;
/** 下挂回复的头像大小（vp）：比父评论小一号（父评论 32），占位仍在中缝里。 */
const REPLY_AVATAR_SIZE: number = 24;
/** 回复头像与正文列之间的补白（vp）：`SIDE_PADDING + REPLY_AVATAR_SIZE + 这个` = TEXT_COLUMN_VP。 */
const REPLY_AVATAR_GAP_VP: number = TEXT_COLUMN_VP - SIDE_PADDING - REPLY_AVATAR_SIZE;
/** 相对时间分档（毫秒）——和信息流/帖子页那套 `posted_ago_*` 文案一致（见 FeedList.postedAgo）。 */
const AGO_MINUTE_MS: number = 60 * 1000;
const AGO_HOUR_MS: number = 60 * AGO_MINUTE_MS;
const AGO_DAY_MS: number = 24 * AGO_HOUR_MS;
const AGO_WEEK_MS: number = 7 * AGO_DAY_MS;
const AGO_MONTH_MS: number = 30 * AGO_DAY_MS;
const AGO_YEAR_MS: number = 365 * AGO_DAY_MS;
/** 展开/收起回复的过渡时长（ms）与进场位移（vp）。 */
const REPLY_ANIM_MS: number = 220;
const REPLY_SLIDE_VP: number = 8;
/**
 * 顶部那条"可以拖的小横条"所占的高度（vp）：热区高度，横条本体只有 4vp。
 *
 * 导出给宿主用：评论浮层"上滑加高"的上界要把这一条减掉，否则拖到顶时它正好被状态栏盖住
 * （见 pages/Index 的 commentsMaxVp）。
 */
export const COMMENTS_DRAG_ZONE_VP: number = 22;

/**
 * **评论列表的控制器**：宿主靠它读列表位置 / 兜底替列表滚。
 *
 * 列表本身是**原生滚动**的（手指的位移先经过宿主的优先级裁决，宿主不吃才放行给列表自己滚）——
 * 这样滚动走的是 ArkUI 自己的滚动管线，和手写 `scrollBy` 一帧一帧推相比**不卡**。
 * 里面的 `scrollBy` 只在"拖的是标题这种非列表区域、但这一段该滚列表"时用。
 */
export class CommentsListController {
  /** 列表当前偏移（vp，0 = 已经在顶部）。 */
  offset: () => number = (): number => 0;
  /** 兜底：替列表滚 `deltaVp`（vp，**>0 = 内容向上滚**）。 */
  scrollBy: (deltaVp: number) => void = (deltaVp: number): void => {
  };
}

/**
 * **评论头像**（加载失败就退回占位图标）。
 *
 * 为什么不用 @Builder：失败状态要**存在组件里**（`Image` 加载失败时自己会画一个破图，
 * 用户报的"一个无法显示该贴图的组件"就是它）。这里用 `onError` 记下来，换成占位图标 ——
 * 贴图/头像的 CDN 直链过一阵会失效，摆一个破图比什么都不画更难看。
 */
@Component
struct CommentAvatar {
  /*
   * url 变了要把"失败过"的标记清掉（审计 B4）。
   *
   * CDN 直链会失效：一次失败之后 `failed=true` 会**永久**停在这个占位图上 —— 即使外面换了一条
   * 新的直链、`url` 已经变了，组件也不会再试（`@State` 只在组件重建时复位，而外层键未必把它重建）。
   */
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop boxSize: number = 32;
  @State private failed: boolean = false;

  private onUrlChanged(): void {
    this.failed = false;
  }

  build() {
    if (this.url.length > 0 && !this.failed) {
      Image(this.url)
        .draggable(false)
        .width(this.boxSize)
        .height(this.boxSize)
        .borderRadius(this.boxSize / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))
        .onError((): void => {
          this.failed = true;
        })
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(this.boxSize * 0.56)
          .fontColor([$r('app.color.secondary_text')])
      }
      .width(this.boxSize)
      .height(this.boxSize)
      .borderRadius(this.boxSize / 2)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.field_background'))
    }
  }
}

/**
 * **评论里的贴图**（图片/动图评论）。
 *
 * 需求："评论里所有动图和图片不需要添加黑边" —— 所以盒子**永远按图自己的比例**算：
 * 宽图铺满正文区宽度、竖图按上限高度反推宽度，两种都不会出现上下/左右的黑边
 * （盒子比例 == 图比例时 Contain 与 Cover 是一回事：既不裁也不留边）。
 *
 *   - 宽 ≥ 高：宽 = 正文区可用宽度，高 = 宽 ÷ 比例；
 *   - 竖图：高 = min(可用宽度 ÷ 比例, 上限)，宽 = 高 × 比例（所以不会占掉半屏，
 *     但也不会有黑边 —— 只是比正文区窄一点）；
 *   - 拿不到尺寸（少数直链贴图）：按正方形铺满宽度（贴纸基本都是方的）。
 *
 * 加载失败要**整块不画**：IG 的贴图地址是 CDN 直链，过一阵会失效，而 `Image` 加载失败时
 * 自己会画一个"破图"占位 —— 用户看到的就是"一个无法显示该贴图的组件"（用户报的原话）。
 */
@Component
struct CommentMedia {
  /** url 变了要清掉失败标记（审计 B4，理由同 CommentAvatar）。 */
  @Prop @Watch('onUrlChanged') url: string = '';
  /** 贴图自己的宽高（接口给了才有；0 = 不知道）。 */
  @Prop mediaW: number = 0;
  @Prop mediaH: number = 0;
  /** 正文区可用宽度（vp）：由面板按屏幕宽度算好传进来。 */
  @Prop maxW: number = 240;
  @State private failed: boolean = false;

  private onUrlChanged(): void {
    this.failed = false;
  }
  /** 竖图的高度上限（vp）：不限的话 9:16 会把整个评论面板占掉。 */
  private readonly maxH: number = 220;

  /** 图片比例（宽 ÷ 高）；尺寸未知时按 1（方图）。 */
  private ratio(): number {
    if (this.mediaW <= 0 || this.mediaH <= 0) {
      return 1;
    }
    return this.mediaW / this.mediaH;
  }

  /** 盒子宽度：铺满可用宽度，除非是竖图被高度上限压住。 */
  private boxW(): number {
    const ratio: number = this.ratio();
    if (ratio >= 1) {
      return this.maxW;
    }
    const byHeight: number = this.maxH * ratio;
    return byHeight < this.maxW ? byHeight : this.maxW;
  }

  /** 盒子高度：按同一个比例反推（所以不会有黑边）。 */
  private boxH(): number {
    return this.boxW() / this.ratio();
  }

  build() {
    if (!this.failed) {
      Image(this.url)
        .draggable(false)
        .width(this.boxW())
        .height(this.boxH())
        // 盒子比例 == 图比例：Cover 在这里等于"原样铺满"，不裁也不留边。
        .objectFit(ImageFit.Cover)
        .borderRadius(12)
        .margin({ top: 6 })
        .onError((): void => {
          this.failed = true;
        })
    }
  }
}

@Component
export struct CommentsPanel {
  @Prop comments: CommentItem[] = [];
  /** 正在等网页把评论读回来。 */
  @Prop loading: boolean = false;
  /** 触底正在加载下一页。 */
  @Prop loadingMore: boolean = false;
  /** 还有没有下一页（false 时列表底部显示"没有更多了"）。 */
  @Prop hasMore: boolean = false;
  /**
   * 读不到评论时的原因（由页面给出语义，文案在这里落到资源上）：
   * ''（对方确实没有评论）/ 'not-found'（网页没渲染这条帖子）/ 'failed'（其它失败）。
   */
  @Prop state: string = '';
  /**
   * 帖子作者、配文与作者头像（宿主一直在传）。
   *
   * 上一版这里有一张"置顶帖子卡片"（作者 + 配文 + 发布时间 + 查看翻译），后来需求把它抽成
   * 独立组件（components/PostCardPanel），本面板回到"标题 + 评论列表"的原样；
   * 现在需求又要求**卡片回到评论面板里**，靠 `showPostCard` 决定画不画 ——
   * 于是这三个字段重新参与渲染（作为卡片的入参，见 build 里插入的那一块）。
   */
  @Prop ownerUsername: string = '';
  @Prop caption: string = '';
  @Prop ownerAvatar: string = '';
  /**
   * **要不要在标题下方画那张置顶帖子卡片**（需求："点 Reels 正文 → 带卡片；
   * 点动作栏评论图标 → 不带卡片，与以前完全一致"）。
   *
   * 开关由宿主给（见 pages/Index 的 `commentsWithCard`），面板自己不判断来源 ——
   * 面板是"同一张嘴、两种内容"，来源分流放在宿主那一层。
   */
  @Prop showPostCard: boolean = false;
  /** 卡片上那条帖子的**作者数字 id**（关注按钮要用）与**发布时刻**（毫秒；0 = 不画时间那截）。 */
  @Prop ownerId: string = '';
  @Prop createdAtMs: number = 0;
  /** **我自己的账号名**：卡片据此不画"关注自己"那颗按钮（同 ReelsPage 的判据）。 */
  @Prop ownAuthor: string = '';
  /**
   * 卡片里的关注按钮（宿主实现，HTTP 直发 + 网页兜底都在 pages/Index.followUser）。
   *
   * 参数里带上 `userId`：卡片自己只知道当前这条的作者，而关注接口要的是 id + 账号名。
   */
  onFollow: (userId: string, username: string, follow: boolean) => Promise<boolean> =
    (userId: string, username: string, follow: boolean): Promise<boolean> => Promise.resolve(false);
  /**
   * 网页侧的结构摘要。
   *
   * 只在读不到评论时以小字显示：它记录了回放用的是哪条请求、HTTP 状态、以及拿到了几条，
   * 一眼就能看出是「没等到请求」还是「拿到了但结构不认」。
   */
  @Prop diag: string = '';
  /**
   * **从页面那条输入框带过来的草稿**（reels 页底部那条）。面板里的输入框用它初始化，
   * 用户在页面里写了字点「评论」，内容不会丢（见 CommentInputBar.initialDraft）。
   */
  @Prop initialDraft: string = '';
  /**
   * "图片评论"那句提示文案。
   *
   * 为什么要先在 aboutToAppear 里取成**字符串**：句子里那个 `Span` 只吃字符串，
   * 直接塞 `$r(...)` 会被拼成 `[object Object]`（真机截图里就是这么冒出来的）。
   */
  @State private photoHint: string = '';
  /**
   * 贴图能用的最大宽度（vp）：正文区那一栏的宽度。
   *
   * 面板宽度 - 左右留白 - 头像 - 行间距 - 右侧点赞列 - 列间距。贴图按这个宽度铺满
   * （竖图再被高度上限压一下），所以不会有黑边（见 CommentMedia）。
   */
  @State private mediaMaxW: number = 240;
  /**
   * 材质厚度（跟设定页联动；材质由底层那颗 Toggle 承载，见 build 的说明）。
   */
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * **列表控制器**（宿主创建、宿主调；面板把实现接到自己的 Scroller 上，见文件里的类说明）。
   */
  listCtl: CommentsListController = new CommentsListController();
  /**
   * 面板现在停在**置顶档**吗（宿主的状态：置中=false / 置顶=true）。
   *
   * 它决定两件事（见文件头的状态机）：
   *   · 列表能不能滚（`enableScrollInteraction`）—— 只有置顶档才让用户滚列表；
   *   · 面板那个全局手势的方向（置中=All / 置顶+列表在顶=Down / 置顶+列表不在顶=None）。
   *
   * `@Watch` 是为了在档位变化时（手势边界）同步一次方向 —— 只在边界改，不会打断拖动。
   */
  @Prop @Watch('onPanelAtTopChanged') panelAtTop: boolean = false;
  /**
   * 拖动方向（**动态开关**）：官方说明用 `PanGestureOptions.setDirection()` 改方向
   * 不会触发 UI 刷新，也不会重建手势，正好用来表达上面那三种状态。
   */
  private panOptions: PanGestureOptions =
    new PanGestureOptions({ fingers: 1, direction: PanDirection.None, distance: 1 });
  /**
   * **列表那一份**同样的拖动选项（面板上挂两份手势，见 `syncPanDirection` 与列表上的
   * `parallelGesture`）。
   *
   * 为什么要两份：列表是 scrollable，触摸落在列表上时手势会被它自己吃掉 —— 面板容器上那份
   * `.gesture` 根本收不到，"列表在顶部时下滑收起面板"因此失效。列表自己再挂一份同样的
   * 手势（`parallelGesture`，与列表滚动并行识别）就补上了；方向仍由同一台状态机控制，
   * 不在顶部时它是 `None`，这一份也不会激活。
   */
  private panOptionsList: PanGestureOptions =
    new PanGestureOptions({ fingers: 1, direction: PanDirection.None, distance: 1 });
  /**
   * 列表现在是不是在顶部（滚动的起停时更新，用来算手势方向）。
   *
   * **必须是 `@State`**（审计 B3）：它同时被 `build()` 里的 `.edgeEffect(… listAtTopState …)` 读取，
   * 而写入它的 `onScrollStart/Stop` 不会触发重绘 —— 普通字段的话，回弹/滚动交互会一直停在旧档位。
   */
  @State private listAtTopState: boolean = true;
  /** 面板自己的滚动控制器（列表程序化滚动只有这一条路，手指不直接滚它）。 */
  private listScroller: Scroller = new Scroller();
  /** 列表当前的滚动位置（vp，0 = 在顶部）：宿主优先级的兜底判据。 */
  private listOffset: number = 0;
  /**
   * 顶部那条（横条 + 「评论」标题）上的拖拽手势（宿主据此调整整个浮层的高度）。
   *
   * `deltaY` = 手指相对按下位置的位移（**向上为负**）。三个回调都在宿主里实现
   * （见 pages/Index 的评论浮层）：起始时记下当前高度，更新时按位移加高/压低，抬手时吸附到
   * 「半屏」或「状态栏下方」两档之一。
   *
   * 名字里带 `Handle`：`onDragStart` / `onDragEnd` 是 `CustomComponent` 自己的通用拖拽事件
   * （不能叫这两个名字，编译器会报 "not assignable to the same property in base type"）。
   */
  /**
   * **面板拖动**（需求："滑动面板手势用 pengesture"）：三个回调都由宿主实现
   * （见 pages/Index 的评论浮层），整块面板——包括列表区域——都在这个手势里。
   *
   * `offsetY` = 手指相对按下位置的**累计**位移（向上为负）；`velocityUp` = 离手速度
   * （vp/s，向上为正）。宿主自己转成"每帧增量"并按优先级决定：加高面板 / 滚列表 / 收起。
   *
   * 名字里带 `Panel`：`onDragStart` / `onDragEnd` 是 `CustomComponent` 自己的通用拖拽事件
   * （不能叫这两个名字）。
   */
  onPanelDragStart: () => void = (): void => {
  };
  onPanelDragUpdate: (offsetY: number) => void = (offsetY: number): void => {
  };
  onPanelDragEnd: (velocityUp: number) => void = (velocityUp: number): void => {
  };

  aboutToAppear(): void {
    /*
     * 把宿主的列表控制器接到自己的 Scroller 上（见文件里的 CommentsListController）：
     * 列表**原生滚动**，宿主只读它的位置；只有"拖非列表区域却该滚列表"时才反过来替它滚。
     */
    this.listCtl.offset = (): number => {
      try {
        return this.listScroller.currentOffset().yOffset;
      } catch (error) {
        return this.listOffset;
      }
    };
    // 兜底：只有"拖的是标题这种非列表区域、但这一段该滚列表"时才走到这儿。
    this.listCtl.scrollBy = (deltaVp: number): void => {
      try {
        this.listScroller.scrollBy(0, deltaVp);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'list scrollBy failed: %{public}s', (error as Error).message);
      }
    };
    try {
      const ctx: Context | undefined = this.getUIContext().getHostContext();
      if (ctx !== undefined) {
        this.photoHint = ctx.resourceManager.getStringByNameSync('comments_photo');
      }
    } catch (error) {
      this.photoHint = '';
    }
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      const screenVp: number = this.getUIContext().px2vp(dsp.width);
      const avail: number = screenVp - SIDE_PADDING * 2 - COMMENT_AVATAR_SIZE - 10 - 34 - 10;
      this.mediaMaxW = avail > 140 ? avail : 240;
    } catch (error) {
      this.mediaMaxW = 240;
    }
    // 初始方向按当前档位算一次（置中档=All）。
    this.syncPanDirection();
  }
  /**
   * 点某一条右侧那颗心（参数是它在列表里的下标）。
   *
   * 由宿主发 HTTP 并**乐观翻转**（见 pages/Index.likeComment）——面板只负责画，
   * 所以这里不自己改数据（`comments` 是 @Prop，改了也不会重绘）。
   */
  onLikeComment: (index: number) => void = (index: number): void => {
  };
  /** 列表滚到底了：去要下一页（宿主实现，见 pages/Index.loadMoreComments）。 */
  onLoadMore: () => void = (): void => {
  };
  /**
   * 用户**碰过**这个列表（手指按下）。
   *
   * 为什么要这个：`onReachEnd` 在"内容还没铺满一屏"时也会立刻触发，而且是**连着触发**——
   * 实测一次打开评论会在 8 秒里连要 10 页（把接口当刷新按了）。宿主靠这个信号区分
   * "用户真的滑到底"和"刚打开、内容还没填满"，见 pages/Index.canLoadCommentsMore。
   */
  onUserTouch: () => void = (): void => {
  };
  /**
   * 点头像 / 用户名 → 打开 TA 的主页（宿主实现，见 pages/Index.openUserProfile）。
   *
   * 参数是用户名（数字 id 宿主自己从 `comments` 里取不到，所以两个都报出去）。
   */
  onUserTap: (username: string, userId: string) => void = (username: string, userId: string): void => {
  };
  /**
   * 展开某条评论的回复时，去要**全部回复**（宿主实现，见 pages/Index.loadCommentReplies）。
   *
   * 参数是父评论在 `comments` 里的下标 —— 面板里的回复数据是宿主塞回 `CommentItem.replies` 的
   * （面板只管画，不改数据）。
   */
  onLoadReplies: (parentIndex: number) => void = (parentIndex: number): void => {
  };
  /**
   * 点赞数的显示（需求："评论面板的点赞数量超过 1 千后以千为单位"）。
   *
   * 1 000 → `1k`；1 200 → `1.2k`；12 345 → `12k`（四舍五入到整数千，去掉没意义的 `.0`）。
   * 不到 1 千就原样显示。
   */
  private static formatLikes(value: number): string {
    if (value < 1000) {
      return `${value}`;
    }
    const thousands: number = Math.round(value / 100) / 10;
    const text: string = thousands >= 10
      ? `${Math.round(thousands)}`
      : `${thousands}`;
    return `${text}k`;
  }

  /** 给**某条回复**点赞（宿主实现，见 pages/Index.likeReply）。 */
  onLikeReply: (parentIndex: number, replyIndex: number) => void =
    (parentIndex: number, replyIndex: number): void => {
    };
  /**
   * 哪些评论的回复**展开着**（按评论 pk 记）。
   *
   * 为什么记在面板里：展开/收起纯粹是界面状态，宿主不需要知道；用 pk 而不是下标，
   * 因为列表翻页会把下标顶掉（pk 不会）。
   */
  @State private expandedReplies: Array<string> = [];
  /** 翻译失败（宿主弹提示用）。 */
  onTranslateFailed: () => void = (): void => {
  };

  /**
   * 哪些评论/回复现在显示的是**译文**（键 = 原文本身）。
   *
   * 用原文当键而不是评论 pk：翻译按钮是挂在"那一段文字"上的（见 ④ 那一行），
   * 同一条评论的主评论与回复各有各的正文，用文字做键最直接；重复正文共用一份译文也不算错。
   */
  @State private translatedBodies: Array<string> = [];
  /** 已翻好的译文（原文 → 译文；普通 Map，配合上面那个 @State 数组触发重绘）。 */
  private translations: Map<string, string> = new Map<string, string>();

  /** 这段文字现在是不是在显示译文。 */
  private isTranslationShown(text: string): boolean {
    return text.length > 0 && this.translatedBodies.indexOf(text) >= 0;
  }

  /** 译文（还没翻出来先用原文占着）。 */
  private translatedBody(text: string): string {
    // 读一下"译文到货"计数，让调用它的 build 登记成依赖（理由同 FeedList.translatedCaption）。
    const tick: number = this.translationEpoch;
    if (tick < 0) {
      return text;
    }
    return this.translations.get(text) ?? text;
  }

  /** 译文到货计数（每翻好一条 +1，见 translatedBody / toggleTranslation）。 */
  @State private translationEpoch: number = 0;

  /** 点「翻译 / 显示原文」：先切状态（立刻有反应），译文第一次再补网络。 */
  private toggleTranslation(text: string, show: boolean): void {
    if (text.length === 0) {
      return;
    }
    const has: boolean = this.translatedBodies.indexOf(text) >= 0;
    if (show === has) {
      return;
    }
    this.translatedBodies = show
      ? this.translatedBodies.concat([text])
      : this.translatedBodies.filter((one: string): boolean => one !== text);
    if (!show || this.translations.has(text)) {
      return;
    }
    Translator.translate(text).then((translated: string | null): void => {
      if (translated === null || translated.length === 0) {
        hilog.warn(0xFF00, 'CommentsPanel', 'translate failed why=%{public}s',
          Translator.lastDetail());
        // 失败就把状态退回去，别让按钮写着"显示原文"而正文还是原文。
        this.translatedBodies = this.translatedBodies.filter((one: string): boolean => one !== text);
        this.onTranslateFailed();
        return;
      }
      this.translations.set(text, translated);
      this.translatedBodies = this.translatedBodies.concat([]);
      // 同样要防"内容比较不重绘"：见 FeedList.translatedCaption 的说明（@State 数组换引用没用）。
      this.translationEpoch = this.translationEpoch + 1;
    });
  }

  /**
   * 发布时间（Unix 秒）→ "多久之前"（灰色小字，需求："每个用户id旁需要显示灰色文本的发布时间"）。
   *
   * 分档文案直接复用信息流那套 `posted_ago_*`（见 FeedList.postedAgo），单位与取整也一致；
   * 没有时间（0）就返回空串 —— 面板据此不画那截小字（不猜、也不显示 "0"）。
   */
  private agoText(createdAtSec: number): ResourceStr {
    if (createdAtSec <= 0) {
      return '';
    }
    const diff: number = Math.max(0, Date.now() - createdAtSec * 1000);
    if (diff < AGO_MINUTE_MS) {
      return $r('app.string.posted_ago_now');
    }
    if (diff < AGO_HOUR_MS) {
      return $r('app.string.posted_ago_minutes', Math.floor(diff / AGO_MINUTE_MS));
    }
    if (diff < AGO_DAY_MS) {
      return $r('app.string.posted_ago_hours', Math.floor(diff / AGO_HOUR_MS));
    }
    if (diff < AGO_WEEK_MS) {
      return $r('app.string.posted_ago_days', Math.floor(diff / AGO_DAY_MS));
    }
    if (diff < AGO_MONTH_MS) {
      return $r('app.string.posted_ago_weeks', Math.floor(diff / AGO_WEEK_MS));
    }
    if (diff < AGO_YEAR_MS) {
      return $r('app.string.posted_ago_months', Math.floor(diff / AGO_MONTH_MS));
    }
    return $r('app.string.posted_ago_years', Math.floor(diff / AGO_YEAR_MS));
  }

  /**
   * **用户 id + 灰色发布时间**那一行（父评论与下挂回复共用）。
   *
   * id 是粗体、可点（开主页）；发布时间是**灰色、非粗体**的小字，紧跟其后（需求）。
   */
  @Builder
  nameRow(username: string, userId: string, createdAtSec: number, fontSize: number) {
    Row({ space: 6 }) {
      Text(username.length > 0 ? username : 'instagram')
        .fontSize(fontSize)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
        .textAlign(TextAlign.Start)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 200 })
        .onClick((): void => {
          this.onUserTap(username, userId);
        })

      if (this.agoText(createdAtSec).toString().length > 0 && createdAtSec > 0) {
        Text(this.agoText(createdAtSec))
          .fontSize(12)
          .fontWeight(FontWeight.Normal)
          .fontColor($r('app.color.comment_muted'))
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 圆形头像：加载失败/没地址都落到占位图标（见 CommentAvatar）。 */
  @Builder
  avatar(url: string, size: number) {
    CommentAvatar({ url: url, boxSize: size })
  }

  /*
   * **拖动手势**（面板上除列表以外的区域：小横条、标题、加载中/空列表那块）。
   *
   * 为什么不挂在面板根节点上（那样整块都能拖）：**挂在根节点会赢过列表自己的滚动手势** ——
   * 于是列表的滚动变成"我们每帧 `scrollBy` 推"，松手就停、没有惯性，用户报的"滚动卡顿、
   * 手指松开就停"就是这么来的。现在列表区域完全交给 List 自己滚（原生，有惯性），
   * 面板要变高时由宿主在 `onScrollFrameBegin` 里**否决**那几帧（返回 `offsetRemain: 0`）——
   * 也就是说"列表区域往上拖照样能把面板顶高"，但滚动手感是原生的。
   *
   * 说明：ArkTS 里 `PanGesture` 是值不是类型，没法抽成一个返回手势的方法，
   * 所以标题 / 加载中 / 空列表三处各写一份同样的手势（回调都指向同一组方法）。
   */

  /**
   * 档位变了（手势边界）：重新算一次拖动方向（见文件头的状态机）。
   */
  private onPanelAtTopChanged(): void {
    // 先按 Scroller 的真实偏移刷一次"列表在不在顶部"，再同步方向：换档时列表可能刚被
    // 程序化滚到顶（或刚展开回复），只 sync 不刷新会留着上一次的 `None`（下滑失效）。
    this.refreshListAtTop();
    this.syncPanDirection();
  }

  /**
   * 把全局拖动方向同步成当前状态该有的那一种：
   *
   *   · 置中档            → `All`：整块面板都能拖（覆盖列表），上滑展开、下滑收起；
   *   · 置顶档 + 列表在顶  → `Down`：只认下滑（回置中档），上滑交给列表滚；
   *   · 置顶档 + 列表不在顶 → `None`：**完全禁用**，列表自由滚（只剩标题那条自己的手势）。
   */
  private syncPanDirection(): void {
    let dir: PanDirection = PanDirection.All;
    if (this.panelAtTop) {
      dir = this.listAtTopState ? PanDirection.Down : PanDirection.None;
    }
    try {
      this.panOptions.setDirection(dir);
      // 列表那一份跟着一起改（见 panOptionsList 的说明）。
      this.panOptionsList.setDirection(dir);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setDirection failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 刷新"列表在不在顶部"，变了就同步一次拖动方向（见文件头的状态机）。
   */
  private refreshListAtTop(): void {
    const atTop: boolean = this.listAtTop();
    if (atTop !== this.listAtTopState) {
      this.listAtTopState = atTop;
      this.syncPanDirection();
    }
  }

  /**
   * 列表是不是已经在顶部（vp 级别判断）。
   *
   * **以 Scroller 为准**：`onDidScroll` 那个记账在真机上不可靠（值会一直是 0），
   * 拿它当判据会让"下滑优先滚列表"整个失效。拿不到 Scroller 时才退回记账值。
   */
  private listAtTop(): boolean {
    try {
      return this.listScroller.currentOffset().yOffset <= 0.5;
    } catch (error) {
      return this.listOffset <= 0.5;
    }
  }

  /**
   * 一条评论（需求："评论的 item 格式为左边用户头像，用户头像旁边是用户 id，用户 id 下方为正文，
   * 再下方显示灰字'回复'，最右侧则是点赞按钮，用户 id、正文和回复字样左侧对齐"）。
   *
   * 版式：`[头像] [左对齐的一列：粗体 id / 正文 / (贴图) / 灰色"回复"] [点赞]`。
   *
   * 头像和 id **可以点**（需求："点击头像或id进入用户详情页"）：两处都报 `onUserTap`。
   * id 那颗 `Text` 故意不给 `width('100%')` —— 让它贴着文字，点到右边空白不会误开主页。
   *
   * @param index 评论在列表里的下标（-1 = 不给点赞，只有面板内部的行才会用 -1）。
   * @param liked 本机点过赞没有（那颗心按它填色）。
   */
  @Builder
  entryRow(name: string, body: string, avatarUrl: string, likes: number, size: number,
           index: number, liked: boolean, imageUrl: string, mediaW: number, mediaH: number,
           userId: string, createdAtSec: number) {
    Row({ space: 10 }) {
      // 头像：点它开主页。
      Column() {
        this.avatar(avatarUrl, size)
      }
      .onClick((): void => {
        this.onUserTap(name, userId);
      })

      // 头像右边那一列：**全部左对齐** —— 用户 id（+ 发布时间）、正文、贴图、"回复"。
      Column({ space: 2 }) {
        // ① 用户 id（粗体）+ 灰色发布时间（需求）。
        this.nameRow(name, userId, createdAtSec, 14)

        // ② 正文（没有正文又没贴图的图片评论给一句灰字交代，见 photoHint）。
        //    「翻译」跟在正文后面（需求：评论"回复"文本旁那颗，见下面 ④）；显示了译文就用译文。
        if (body.length > 0) {
          Text(this.isTranslationShown(body) ? this.translatedBody(body) : body)
            .fontSize(14)
            .lineHeight(19)
            .fontColor($r('app.color.primary_text'))
            .textAlign(TextAlign.Start)
            .width('100%')
        } else if (imageUrl.length === 0 && this.photoHint.length > 0) {
          Text(this.photoHint)
            .fontSize(14)
            .lineHeight(19)
            .fontColor($r('app.color.secondary_text'))
            .textAlign(TextAlign.Start)
            .width('100%')
        }

        // ③ 图片 / GIF 贴图（跟在正文下面，同 IG）。
        if (imageUrl.length > 0) {
          CommentMedia({
            url: imageUrl,
            mediaW: mediaW,
            mediaH: mediaH,
            maxW: this.mediaMaxW
          })
        }

        // ④ "回复"（需求：**粗体**；浅色模式下是浅灰 —— 见 comment_muted）。
        //    「翻译」就在"回复"**旁边**（需求）；只有非中文正文才会真的画出来。
        Row({ space: 8 }) {
          Text($r('app.string.comments_reply'))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .lineHeight(18)
            .fontColor($r('app.color.comment_muted'))
            .textAlign(TextAlign.Start)
          TranslateLabel({
            source: body,
            showing: this.isTranslationShown(body),
            fontSize: 13,
            onToggle: (show: boolean): void => {
              this.toggleTranslation(body, show);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 最右侧：点赞按钮（**总有**，用户报过"有部分评论点赞按钮消失"）。
      // 心形图标与赞数都按需求走了**粗体 + comment_muted**（点赞过则是强调红，不灰）。
      if (index >= 0) {
        Column({ space: 2 }) {
          SymbolGlyph(liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor([liked ? $r('app.color.like_active') : $r('app.color.comment_muted')])
          if (likes > 0) {
            Text(CommentsPanel.formatLikes(likes))
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.comment_muted'))
          }
        }
        .width(34)
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.onLikeComment(index);
        })
      }
    }
    .width('100%')
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 9, bottom: 9 })
    .alignItems(VerticalAlign.Top)
  }

  /**
   * **一条回复**（下挂回复里的一行）。
   *
   * 需求（最新一版）：
   *   · "下挂回复的用户头像**对齐头部评论的用户 id**" —— 整行缩进到 `TEXT_COLUMN_VP`
   *     （= 父评论 id 的起始 x），头像从那里开始；
   *   · "下挂评论需要显示用户头像" —— 小一号的头像（`REPLY_AVATAR_SIZE`）；
   *   · id 旁是灰色非粗体的发布时间（见 nameRow）；
   *   · 右侧还是那颗心（点它给这条回复点赞）。
   */
  @Builder
  replyRow(reply: CommentItem, parentIndex: number, replyIndex: number) {
    Row({ space: 0 }) {
      // ① 头像：和父评论的 **id** 左对齐（需求）。
      Column() {
        this.avatar(reply.avatar ?? '', REPLY_AVATAR_SIZE)
      }
      .onClick((): void => {
        this.onUserTap(reply.username, reply.userId ?? '');
      })

      // ② 头像与正文之间的间距。
      Column().width(10)

      // ③ 正文列（id + 发布时间 / 正文 / 贴图 / "回复"）。
      Column({ space: 2 }) {
        this.nameRow(reply.username, reply.userId ?? '', reply.createdAt ?? 0, 14)

        if (reply.text.length > 0) {
          Text(this.isTranslationShown(reply.text) ? this.translatedBody(reply.text) : reply.text)
            .fontSize(14)
            .lineHeight(19)
            .fontColor($r('app.color.primary_text'))
            .textAlign(TextAlign.Start)
            .width('100%')
        }

        if ((reply.imageUrl ?? '').length > 0) {
          CommentMedia({
            url: reply.imageUrl ?? '',
            mediaW: reply.mediaW ?? 0,
            mediaH: reply.mediaH ?? 0,
            maxW: this.mediaMaxW
          })
        }

        // 「翻译」在"回复"旁边（需求），回复那一行也一样给。
        Row({ space: 8 }) {
          Text($r('app.string.comments_reply'))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .lineHeight(18)
            .fontColor($r('app.color.comment_muted'))
            .textAlign(TextAlign.Start)
          TranslateLabel({
            source: reply.text,
            showing: this.isTranslationShown(reply.text),
            fontSize: 13,
            onToggle: (show: boolean): void => {
              this.toggleTranslation(reply.text, show);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // ④ 点赞。
      Column({ space: 2 }) {
        SymbolGlyph(reply.liked === true ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor([reply.liked === true
            ? $r('app.color.like_active') : $r('app.color.comment_muted')])
        if ((reply.likes ?? 0) > 0) {
          Text(`${reply.likes ?? 0}`)
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.comment_muted'))
        }
      }
      .width(34)
      .justifyContent(FlexAlign.Center)
      .margin({ left: 10 })
      .onClick((): void => {
        this.onLikeReply(parentIndex, replyIndex);
      })
    }
    .width('100%')
    // 整行缩进到父评论 **id** 的位置（需求："下挂回复的用户头像对齐头部评论的用户id"）。
    .padding({ left: TEXT_COLUMN_VP, right: SIDE_PADDING, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Top)
  }

  /**
   * "查看另外 n 条回复" / "隐藏回复"那一行（需求）。
   *
   * 结构：左边一条**灰色实线**（宽度 = 评论头像的宽度，`COMMENT_AVATAR_SIZE`），
   * 右边是文字。整行缩进到 `TEXT_COLUMN_VP` —— 需求："灰色实线**对齐头部评论的用户id**"。
   */
  @Builder
  repliesToggleRow(label: ResourceStr, expanded: boolean, parentIndex: number, pk: string) {
    Row({ space: 8 }) {
      // 灰色实线：宽度 = 头像宽度（需求）。
      Column()
        .width(COMMENT_AVATAR_SIZE)
        .height(1)
        .backgroundColor($r('app.color.comment_muted'))

      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.comment_muted'))
        .textAlign(TextAlign.Start)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: TEXT_COLUMN_VP, right: SIDE_PADDING, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.toggleReplies(pk, expanded, parentIndex);
    })
  }

  /**
   * 一条评论下面的**回复区**（需求："下挂回复"）。
   *
   * 折叠时：灰色实线 + "查看另外 n 条回复"（n = 回复总数；n = 0 时整块不画）。
   * 展开后：先把已经取到的回复画出来（预览 / 取回的全部），最后再画灰色实线 + "隐藏回复"。
   */
  @Builder
  repliesBlock(comment: CommentItem, index: number) {
    if ((comment.repliesCount ?? 0) > 0) {
      if (this.repliesExpanded(comment.pk ?? '')) {
        /*
         * 展开出来的这一整块带**过渡动画**（需求："展开隐藏回复需要添加动画"）：
         * 淡入 + 轻微下移进场；收起时反过来淡出。
         * 外面那层 `animateTo`（见 toggleReplies）同时把列表项的高度变化也补成动画。
         */
        Column() {
          ForEach(comment.replies ?? [], (reply: CommentItem, replyIndex: number): void => {
            this.replyRow(reply, index, replyIndex)
          }, (reply: CommentItem, replyIndex: number): string =>
          `r-${replyIndex}-${reply.username}-${reply.text.length}`
            + `-${reply.liked === true ? 'l' : 'n'}-${reply.likes ?? 0}`)
          // 还没取全（预览不够）时给一句加载中的交代。
          if (comment.repliesLoaded !== true
            && (comment.replies?.length ?? 0) < (comment.repliesCount ?? 0)) {
            Row() {
              LoadingProgress()
                .width(18)
                .height(18)
                .color($r('app.color.comment_muted'))
              Text($r('app.string.comments_replies_loading'))
                .fontSize(13)
                .fontColor($r('app.color.comment_muted'))
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: TEXT_COLUMN_VP, top: 4, bottom: 4 })
          }
          this.repliesToggleRow($r('app.string.comments_hide_replies'), true, index,
            comment.pk ?? '')
        }
        .width('100%')
        .transition(TransitionEffect.OPACITY
          .animation({ curve: Curve.FastOutSlowIn, duration: REPLY_ANIM_MS })
          .combine(TransitionEffect.translate({ y: -REPLY_SLIDE_VP })
            .animation({ curve: Curve.FastOutSlowIn, duration: REPLY_ANIM_MS })))
      } else {
        this.repliesToggleRow($r('app.string.comments_view_replies',
          comment.repliesCount ?? 0), false, index, comment.pk ?? '')
      }
    }
  }

  /** 这条评论的回复展开着吗（展开状态存在面板里，按评论 pk 记）。 */
  private repliesExpanded(pk: string): boolean {
    return pk.length > 0 && this.expandedReplies.indexOf(pk) >= 0;
  }

  /**
   * 回复们的**点赞摘要**（条数 + 赞数和 + 点过赞的条数），拼进外层 ForEach 的键里。
   *
   * 为什么需要：给**某条回复**点赞时，变的只是回复自己的 `liked/likes` —— 外层那条评论的键
   * 要是不跟着变，ForEach 就不会重建这一项，于是"点了没反应"（数据其实已经改了，
   * 只是界面没重画）。用户报的"子评论无法点赞"就是这个。
   */
  private repliesKey(comment: CommentItem): string {
    const list: Array<CommentItem> = comment.replies ?? [];
    let likes: number = 0;
    let liked: number = 0;
    for (let index: number = 0; index < list.length; index++) {
      likes += list[index].likes ?? 0;
      liked += list[index].liked === true ? 1 : 0;
    }
    return `${list.length}.${likes}.${liked}`;
  }

  /**
   * 点"查看另外 n 条回复" / "隐藏回复"：切换展开状态；**展开时**若回复还没取全，
   * 顺便让宿主去要全部（见 pages/Index.loadCommentReplies）。
   */
  private toggleReplies(pk: string, expanded: boolean, parentIndex: number): void {
    if (pk.length === 0) {
      return;
    }
    /*
     * 展开/收起都包在 `animateTo` 里（需求："展开隐藏回复需要添加动画"）：
     * 列表项的高度变化（多出/少掉几行回复）才会补成动画，而不是"啪"地跳一下；
     * 展开出来那一块自己的淡入淡出见 repliesBlock 的 transition。
     */
    this.getUIContext().animateTo({ curve: Curve.FastOutSlowIn, duration: REPLY_ANIM_MS },
      (): void => {
        if (expanded) {
          const at: number = this.expandedReplies.indexOf(pk);
          if (at >= 0) {
            this.expandedReplies.splice(at, 1);
          }
          return;
        }
        this.expandedReplies.push(pk);
      });
    if (expanded) {
      return;
    }
    const item: CommentItem | null = parentIndex >= 0 && parentIndex < this.comments.length
      ? this.comments[parentIndex] : null;
    if (item !== null && item.repliesLoaded !== true) {
      this.onLoadReplies(parentIndex);
    }
  }

  /** 列表底部那一行：加载中转圈 / 到底了给个交代。 */
  @Builder
  footerRow() {
    Row() {
      if (this.loadingMore) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color($r('app.color.secondary_text'))
      } else if (!this.hasMore) {
        Text($r('app.string.comments_end'))
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 6 })
  }

  /** 读不到评论时的占位：文案 + 结构摘要。 */
  @Builder
  emptyRow() {
    Column({ space: 8 }) {
      if (this.state === 'not-found') {
        Text($r('app.string.engage_not_rendered'))
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
      } else if (this.state === 'failed') {
        Text($r('app.string.comments_failed'))
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
      } else {
        Text($r('app.string.comments_empty'))
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
      }
      if (this.diag.length > 0) {
        Text(this.diag)
          .fontSize(10)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 30, bottom: 30 })
  }

  build() {
    /*
     * **背景 = 沉浸光感材质**（需求："背景采用沉浸光感组件"）。
     *
     * 上一版把材质直接挂在 Column 上，真机上**什么都没画出来**（评论区背景是空的）——
     * 官方的生效范围写明：只有**弹窗类与 Slider / Toggle / Select** 能"全页面"生效，
     * 普通容器不算。所以这里和 CommentInputBar（reels 页那个输入条）用同一条稳的路：
     *   ① 底层一颗空 Toggle 只负责画材质，`hitTestBehavior(None)` 自己不吃触摸；
     *   ② 上层才是内容（小横条 + 标题 + 列表），触摸全归它。
     *
     * **四个角都是圆的**（需求）：材质层和内容层同一个半径，根节点再 `clip(true)`
     * 把内容裁进圆角里（不然列表会溢出到圆角外面）。
     */
    Stack({ alignContent: Alignment.TopStart }) {
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Text('')
      }
      .width('100%')
      .height('100%')
      .padding(0)
      .borderRadius(PANEL_RADIUS_VP)
      .backgroundColor(Color.Transparent)
      .selectedColor(Color.Transparent)
      .attributeModifier(new SurfaceModifier(this.thickness, false))
      .hitTestBehavior(HitTestMode.None)

      Column() {
        /*
         * 顶部：**可以拖的小横条** + 它下方**置中的「评论」**（需求）。
         *
         * 这一整条是**拖动手势的热区之一**（见 panelDragGesture）—— 列表区域不用挂手势，
         * 它自己滚（原生、有惯性），要顶高面板时由宿主否决那几帧。
         *
         * 横条颜色走 `sheet_handle` 这个资源：**深色模式下浅灰、浅色模式下深灰**（需求），
         * 两套值分别在 resources/base 与 resources/dark 里。
         */
        Column() {
          Column()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.sheet_handle'))

          Text($r('app.string.comments_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({ top: 8, bottom: 6 })
        // 标题这一条也能拖（列表之外唯一常驻的区域）。
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
            .onActionStart((): void => {
              this.onPanelDragStart();
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.onPanelDragUpdate(event.offsetY);
            })
            .onActionEnd((event: GestureEvent): void => {
              this.onPanelDragEnd(-event.velocityY);
            })
            .onActionCancel((): void => {
              this.onPanelDragEnd(0);
            })
        )

        // 「帖子的作者/配文」整块**只在这里画**（需求："点正文 → 评论面板里带那张置顶卡片"）：
        // 位置就是「评论」标题下方、第一条评论上方；卡片本体是现成组件（components/PostCardPanel），
        // 这里只负责摆位置 —— 左右白和评论行一致（SIDE_PADDING），卡片边缘才和评论头像/正文对得上。
        //
        // 为什么不给它挂面板的拖动手势：卡片里有一条自己的 Scroll（长正文）和两颗材质按钮，
        // 再叠一层 PAN 会把手势抢乱；从卡片上开始拖不调档，代价可以接受。
        if (this.showPostCard) {
          Column() {
            PostCardPanel({
              ownerUsername: this.ownerUsername,
              ownerAvatar: this.ownerAvatar,
              caption: this.caption,
              ownerId: this.ownerId,
              createdAtMs: this.createdAtMs,
              ownAuthor: this.ownAuthor,
              // 关注走宿主那条路（HTTP 优先 / 网页兜底，见 pages/Index.followUser）。
              onFollow: (follow: boolean): Promise<boolean> => {
                return this.onFollow(this.ownerId, this.ownerUsername, follow);
              },
              // 点头像 / 账号名 → TA 的主页（和评论行同一个回调，见 openUserFromComments）。
              onUserTap: (username: string, userId: string): void => {
                this.onUserTap(username, userId);
              },
              // 翻译失败：卡片自己已经把状态退回原文了，这里只转给宿主弹一句。
              onTranslateFailed: (): void => {
                this.onTranslateFailed();
              }
            })
          }
          .width('100%')
          .padding({ left: SIDE_PADDING, right: SIDE_PADDING, bottom: 8 })
        }

        if (this.loading) {
        Row() {
          LoadingProgress()
            .width(30)
            .height(30)
            .color($r('app.color.secondary_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        // 没有列表的时候，这一块也得能拖着调高度（否则加载中也拖不动）。
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
            .onActionStart((): void => {
              this.onPanelDragStart();
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.onPanelDragUpdate(event.offsetY);
            })
            .onActionEnd((event: GestureEvent): void => {
              this.onPanelDragEnd(-event.velocityY);
            })
            .onActionCancel((): void => {
              this.onPanelDragEnd(0);
            })
        )
      } else if (this.comments.length === 0) {
        Column() {
          this.emptyRow()
        }
        .width('100%')
        .layoutWeight(1)
        .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
            .onActionStart((): void => {
              this.onPanelDragStart();
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.onPanelDragUpdate(event.offsetY);
            })
            .onActionEnd((event: GestureEvent): void => {
              this.onPanelDragEnd(-event.velocityY);
            })
            .onActionCancel((): void => {
              this.onPanelDragEnd(0);
            })
        )
      } else {
        List({ scroller: this.listScroller }) {
          ForEach(this.comments, (comment: CommentItem, index: number): void => {
            ListItem() {
              // 一条评论 = 评论行 + 它下面的回复区（"查看另外 n 条回复" / 展开后的回复）。
              Column() {
                this.entryRow(comment.username, comment.text, comment.avatar ?? '',
                  comment.likes ?? 0, COMMENT_AVATAR_SIZE, index, comment.liked === true,
                  comment.imageUrl ?? '', comment.mediaW ?? 0, comment.mediaH ?? 0,
                  comment.userId ?? '', comment.createdAt ?? 0)
                this.repliesBlock(comment, index)
              }
              .width('100%')
            }
          }, (comment: CommentItem, index: number): string =>
          // 键里带上"点过赞没有 + 赞数 + 回复展开状态 + 已取回回复数 + **回复们的点赞摘要**"：
          // 这些都会就地变化，键不变的话 ForEach 不会重跑这一项（同信息流/Reels 动作区那套键的处理）。
          // 最后那段是"给某条回复点赞后界面不刷新"的修复（见 repliesKey）。
          //
          // ⚠️ 文本/图片用**内容本身**而不是长度（审计 D7）：`text.length` 相同但内容不同的两条
          // 评论会共用同一个键 → ArkUI 复用旧节点，译文/失败占位串味；位置变动时还会错配。
          // 内容可能很长，这里截断到 48 字符 + 带上 `pk`，唯一性够用又不至于让键爆长。
          `${index}-${comment.pk ?? ''}-${comment.username}`
            + `-${comment.text.slice(0, 48)}`
            + `-${comment.liked === true ? 'l' : 'n'}-${comment.likes ?? 0}`
            + `-${(comment.imageUrl ?? '').slice(-32)}`
            + `-${this.repliesExpanded(comment.pk ?? '') ? 'e' : 'c'}`
            + `-${this.repliesKey(comment)}`)

          // 列表底部：还有下一页时显示一个转圈（触底自动要），到底了显示"没有更多了"。
          // 需求："没有加载全部评论，做一个触底加载功能"。
          ListItem() {
            this.footerRow()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        /*
         * 边缘回弹 + `alwaysEnabled`：内容比组件矮时也要能拖（官方《边缘滑动效果》那条），
         * 否则评论只有一两条时列表连手势都不收、也没有回弹。
         *
         * **但"列表在顶部 + 置顶档"这一种要关掉回弹**：那时列表已经没法再滚了，回弹会把
         * 下滑手势整段吃掉、还会和面板自己的位移打架（列表往上弹一下、面板往下走一段）。
         * 关成 `None` 之后，同一段下滑由下面那份 `parallelGesture` 交给面板（见 panOptionsList）。
         */
        .edgeEffect(this.panelAtTop && this.listAtTopState ? EdgeEffect.None : EdgeEffect.Spring,
          { alwaysEnabled: true })
        /*
         * **列表能不能滚，由档位决定**（需求）：只有置顶档才让用户滚列表；
         * 置中档时列表不接收滚动 —— 那一段手势归面板（展开/收起）。
         */
        .enableScrollInteraction(this.panelAtTop)
        .onDidScroll((offset: number, state: ScrollState): void => {
          this.listOffset = offset;
        })
        // 滚动起停时刷新"列表在不在顶部"，并同步一次拖动方向（见文件头的状态机）。
        .onScrollStart((): void => {
          this.refreshListAtTop();
          // 用户开始滚列表了：宿主据此放开自动补页的上限（见 canLoadCommentsMore）。
          this.onUserTouch();
        })
        .onScrollStop((): void => {
          this.refreshListAtTop();
        })
        .onReachStart((): void => {
          this.listAtTopState = true;
          this.syncPanDirection();
        })
        // 触底加载：滑到（或接近）底部就要下一页。它在快速滑动时会连着触发几次，
        // 所以宿主那边必须自己防重入（见 pages/Index.loadMoreComments 的闸门）。
        .onReachEnd((): void => {
          this.onLoadMore();
        })
        /*
         * **列表自己也挂一份面板拖动**（和列表滚动并行识别，见 panOptionsList 的说明）。
         *
         * 补的就是"列表在顶部时下滑收起面板"：那段手势现在能收到，规则和面板那层完全一样
         * （置中档 `All` = 整块可拖；置顶 + 在顶 `Down` = 只认下滑；置顶 + 不在顶 `None` =
         * 这里也不激活、列表自由滚）。
         */
        .parallelGesture(
          PanGesture(this.panOptionsList)
            .onActionStart((): void => {
              this.onPanelDragStart();
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.onPanelDragUpdate(event.offsetY);
            })
            .onActionEnd((event: GestureEvent): void => {
              this.onPanelDragEnd(-event.velocityY);
            })
            .onActionCancel((): void => {
              this.onPanelDragEnd(0);
            })
        )
      }
        // 内容那一列：占满面板（输入框已经搬出去了，见下面注释）。
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // **四个角都是圆的**（需求）：内容裁进圆角里（材质那一层自己也有同一个半径）。
    .borderRadius(PANEL_RADIUS_VP)
    .clip(true)
    /*
     * **面板全局拖动**：方向由状态机决定（见文件头 + `syncPanDirection`）。
     *
     *   · 置中档 → `All`：整块面板（**包括列表**）都是热区，列表此时不滚；
     *   · 置顶档 + 列表在顶 → `Down`：只吃下滑（回置中档），上滑落到列表滚；
     *   · 置顶档 + 列表不在顶 → `None`：这里完全不吃手势，列表自由滚
     *     （标题那条自己的手势仍在，见上面的 PanGesture）。
     */
    .gesture(
      PanGesture(this.panOptions)
        .onActionStart((): void => {
          this.onPanelDragStart();
        })
        .onActionUpdate((event: GestureEvent): void => {
          this.onPanelDragUpdate(event.offsetY);
        })
        .onActionEnd((event: GestureEvent): void => {
          this.onPanelDragEnd(-event.velocityY);
        })
        .onActionCancel((): void => {
          this.onPanelDragEnd(0);
        })
    )
    // 输入框**不在这个面板里**了（需求："两者分离，不要将评论输入框嵌入面板中"）：
    // 它由宿主放在面板**下方**，用 reels 页那条沉浸光感输入条（CommentInputBar）。
  }
}
