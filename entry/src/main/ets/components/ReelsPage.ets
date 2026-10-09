/*
 * Reels 视频流页面：竖向翻页，只播当前那一条。
 *
 * 需求这次只到"视频流"：上下滑切换视频、当前这条自动播、滑到末尾自动续下一页。
 * 所以这里刻意不加点赞/评论/分享那些按钮。
 *
 * 播放怎么做：**每个视频页各自一个 VideoSurface**（AVPlayer + XComponent，和首页信息流共用
 * 同一个组件，见 VideoSurface.ets），只有"当前这条"和"下一条"真的挂播放器：
 *   - 当前这条 playing=true，下一条 preload=true（提前 prepare，切过去基本立刻出画面）；
 *   - 其余页只画封面图，既省内存又让"滑到哪播哪"立刻生效；
 *   - VideoSurface 放在 Swiper 的**页内**，不是浮在 Swiper 上面：浮上去会跟 Swiper 抢竖向手势。
 *
 * 信息层（作者行 + 关注按钮 + 正文 + 右侧动作栏）**同样放在页内**（每条一个 ReelOverlay），
 * 理由写在 ReelOverlay 的文件头（"数据固定在第一条"和"手指落在按钮上翻不了页"这两个坑）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { Reel, ReelStreamVm } from '../model/Reel';
import { ReelsViewModel } from '../viewmodel/ReelsViewModel';
import { VideoSurface } from './VideoSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS, SETTING_VIDEO_MUTED } from '../core/AppSettings';
import { ReelsAction } from '../core/ReelsAction';
import {
  MaterialIconButton, MaterialLabelButton, SurfaceModifier, trackMaterialTouch
} from './MaterialSurface';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { SaveState } from '../core/SaveState';
import { NativeFollow } from '../core/NativeFollow';
import { LikeBurst, LikeBurstState, playLikeBurst } from './AnimatedIcons';
import { TranslateLabel } from './TranslateLabel';
import { Translator } from '../core/Translator';
import {
  CAPTION_COLLAPSED_MAX_LINES, CAPTION_LESS, CAPTION_MORE, CAPTION_TAIL_SAFETY_VP, CaptionFit
} from '../core/CaptionFit';

/** 打日志用的域 / tag（切页动画时长这类关键数字都从这里看）。 */
const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsPage';
/** 离末尾还有几条就开始预取。 */
const PREFETCH_DISTANCE: number = 3;
/** 作者行的左右留白（vp）。 */
const SIDE_PADDING: number = 16;
/**
 * 翻页动画时长（毫秒）。
 *
 * 两个坑写在这儿：
 *   1) Swiper 的 `duration` **只在非弹簧曲线下生效**（默认是弹簧插值曲线，时长由弹簧参数决定，
 *      官方文档明确写"默认弹簧动效约 560ms"）——所以要能调快调慢，必须同时给一条非弹簧曲线；
 *   2) 调多快不靠猜：切换动画的真实时长由 `switch animation Nms` 这行日志量出来
 *      （onAnimationStart → onAnimationEnd），改这个数字后翻一次页就能看到实测值。
 *
 * 取值经过：220（无效，被弹簧曲线吃掉）→ 700（用户先要"慢一点"）→ **480**（再要"稍微加快、提升跟手性"）。
 * 480 是"看得出过渡、又不觉得在等"的折中：手指离屏后约 0.5 秒落到下一条，
 * 而新的那条在动画一开始就起播（见 onAnimationStart），所以落定那一刻画面已经在了。
 * 想再快就往 300 调（官方短视频示例是 300ms + Curve.Ease），更慢往 700~900 调。
 */
const SWITCH_ANIM_MS: number = 480;
/** 作者行高度（vp）：和全 app 的材质按钮对齐（40，见 MaterialSurface）。 */
const AUTHOR_ROW_HEIGHT: number = 40;
/** 作者行里的头像直径（vp）。 */
const AUTHOR_AVATAR_SIZE: number = 34;
/** 关注按钮宽度（vp）：两个字 + 内边距。 */
const FOLLOW_PILL_WIDTH: number = 74;
/** 作者资讯组件与关注按钮之间的间距（vp，需求："关注按钮不要贴着用户资讯组件"）。 */
const AUTHOR_FOLLOW_GAP: number = 10;
/** 正文的字号与行高（vp）。 */
const CAPTION_FONT_SIZE: number = 14;
const CAPTION_LINE_HEIGHT: number = 19;
/** 正文折叠排版要用"可用宽度"，量不出来时不截断（见 captionPrefix）。 */
const FALLBACK_WIDTH_VP: number = 360;
/** 右侧动作栏：整栏宽度、按钮直径、图标大小、按钮之间的间距（vp）。 */
const ACTION_COLUMN_WIDTH: number = 64;
const ACTION_BUTTON_SIZE: number = 40;
const ACTION_ICON_SIZE: number = 22;
const ACTION_GAP: number = 10;
/** 已转发时叠在转发图标正中的对勾大小（vp）；与信息流那颗一致（见 FeedList 的 PostActions）。 */
const ACTION_CHECK_SIZE: number = 15;
/** 已点赞的图标色（和信息流那颗心同一个色：`app.color.like_active` = #ED4956）。 */
const LIKE_ACTIVE_COLOR: string = '#ED4956';
/** 动作栏离屏幕右边的距离（vp）：按钮自己还有内边距，这里只留一点。 */
const ACTION_RIGHT_PADDING: number = 4;
/** 双击点赞允许的手指位移（vp）：同信息流，防"快滑两下被凑成双击"。 */
const DOUBLE_TAP_DISTANCE_VP: number = 12;
/** 放大爱心的 key：整页只有一个爱心节点，用一个常量即可（见 build 里的 LikeBurst）。 */
const REELS_BURST_KEY: string = 'reels';
/** 正文展开/收起的过渡时长与位移（毫秒 / vp）。 */
const CAPTION_ANIM_MS: number = 220;
const CAPTION_SLIDE_VP: number = 6;
/** 点赞/转发的"处理中"最长锁多久（毫秒）：宿主拖太久也不能让按钮一直点不动。 */
const ACTION_BUSY_MAX_MS: number = 12000;

/**
 * 给一条 reel 乐观点赞 / 取消赞（**页面双击与动作栏那颗心共用这一处**）。
 *
 * 乐观翻转：先就地改 `reel`（@Observed，订阅它的心/计数立刻重绘），宿主回了 false 再翻回来 ——
 * 等网络回结果会像"点了没反应"。
 *
 * 放在模块级函数而不是某个组件的方法里：双击手势挂在**页面**上（ReelsPage），
 * 而那颗心画在**每条自己的信息层**里（ReelOverlay）—— 两个组件都要这一套逻辑，
 * 各写一份迟早会走样（比如一边忘了回滚）。
 */
function commitReelLike(reel: Reel, next: boolean,
                        onLike: (reel: Reel, like: boolean) => Promise<boolean>): Promise<void> {
  const before: number = reel.likeCount;
  reel.liked = next;
  reel.likeCount = next ? before + 1 : (before > 0 ? before - 1 : 0);
  return onLike(reel, next).then((ok: boolean): void => {
    if (!ok) {
      // 失败回滚（原因由宿主那边说明，见 pages/Index.likeReel）。
      reel.liked = !next;
      reel.likeCount = before;
    }
  }).catch((): void => {
    reel.liked = !next;
    reel.likeCount = before;
  });
}
/**
 * 左下那一块（作者行 + 正文）离屏幕底边的高度（vp）。
 *
 * 这一页底部还压着一层评论输入框（整屏 Reels 页才有，见 pages/Index.reelsBody），
 * 所以留得比它高一些，两者不打架。动作区用同一个值，两块一起上下移动（需求："整体 ui 下移 20vp"）。
 */
const INFO_BOTTOM: number = 112;

/**
 * 一条视频的**画面**：封面铺底 + 播放器 + 首帧叠层。
 *
 * 为什么单独一个组件（而不是写在 ReelsPage 的 @Builder 里）：画面要用 `@ObjectLink` 订阅
 * `reel`，而**视频地址可能是后补的**（个人主页的视频分页那条查询只给封面，见
 * core/NativeMediaInfo 与 ProfileReelsViewModel）：补到地址时 `reel.videoUrl` 一变，
 * 这里就地重绘、把播放器挂上。写在外面的话 ForEach 对"键没变"的项不重跑 item builder，
 * 那一页就永远只有封面。
 *
 * 播放器只在"当前这条 / 下一条"上挂（预加载下一条，切过去基本立刻出画面）：
 *   - `playing` 当前页：真的播；
 *   - `preload` 下一条：提前 prepare，首帧到了先压在封面上；
 *   - 其余页只画封面，省内存也让"滑到哪播哪"立刻生效。
 */
@Component
struct ReelSlide {
  /** 这条视频（**@ObjectLink**：地址是后补的，见类头说明）。 */
  @ObjectLink reel: Reel;
  /** 现在是这一条在播吗。 */
  @Prop playing: boolean = false;
  /** 提前 prepare 下一条。 */
  @Prop preload: boolean = false;
  /** 静音（全局开关）。 */
  @Prop muted: boolean = false;
  /** 首帧上屏时通知父组件（父组件拿它决定整页的封面叠层，见 ReelsPage.videoReady）。 */
  onFirstFrame: () => void = (): void => {
  };
  /** 这一条的首帧出来了没有（没出来时封面压在上面，避免黑闪）。 */
  @State private ready: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 封面先铺底：视频起播前不会黑屏，滑过去也立刻有画面。**和播放器同一个盒子**，
      // 所以撤封面时不会有任何错位。
      Image(this.reel.coverUrl.length > 0 ? this.reel.coverUrl : $r('app.media.startIcon'))
        .draggable(false)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .backgroundColor(Color.Black)
      if (this.reel.playable() && (this.playing || this.preload)) {
        // 播放器换成 AVPlayer + XComponent 的共用组件，理由见 VideoSurface 的说明：
        // 它能在 prepare 阶段就把首帧送到表面上（showFirstFrameOnPrepare），
        // 所以下面那层封面是在"首帧真的上屏"之后才撤的，不再有黑闪。
        VideoSurface({
          url: this.reel.videoUrl,
          playing: this.playing,
          preload: this.preload,
          muted: this.muted,
          // 盒子的比例已经等于视频比例，所以用 FIT（完整显示）就正好铺满这个盒子；
          // 再开 FIT_CROP 反而会二次裁切（把本该看到的画面切掉）。
          cover: false,
          onFirstFrame: (): void => {
            this.ready = true;
            this.onFirstFrame();
          },
          onError: (): void => {
            // 放不出来也要撤封面：不然用户看到的是一张永远不动的图，不知道发生了什么。
            this.ready = true;
          }
        })
          .width('100%')
          .height('100%')
      }
      // 首帧还没上屏：再盖一层同样大小的封面（同一个盒子，不会错位），且**不吃手势**。
      if (this.playing && this.reel.playable() && !this.ready) {
        Image(this.reel.coverUrl.length > 0 ? this.reel.coverUrl : $r('app.media.startIcon'))
          .draggable(false)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 一条 reels 的**信息层**：作者行（头像 + 账号名 + 关注按钮）+ 正文 + 右侧动作栏。
 *
 * 三条硬理由（每一条都是用户报过的问题）：
 *
 *   1) **数据必须"每条自己的"**。以前信息层是画在 Swiper **外面**的一整层浮层，里面的作者名、
 *      正文都读 `this.current()`。ArkUI 是差量更新：`Text(reel.author)` 这种"只读了局部变量"的
 *      节点**没有任何可观察依赖**，翻页时不会重绘 —— 用户看到的就是"视频换了，作者/正文/计数
 *      还停在第一条"（"数据显示固定在第一条 reels"）。这里用 `@ObjectLink reel` 订阅这一条，
 *      和信息流的 PostActions 完全同一套做法（那个组件就是为这件事抽出来的）。
 *
 *   2) **手势**。浮层挂在 Swiper 外面时，它和 Swiper 是**兄弟**关系；动作区/关注按钮是 Toggle
 *      带着自己的 PanGesture（材质按钮的 4-way-lock，见 MaterialSurface.consumePan），兄弟关系下
 *      它们会把竖向滑动赢走 —— 手指落在关注按钮或右侧动作区上就怎么划都翻不了页。放进页内之后
 *      Swiper 的内建 PAN 是祖先，滑动照常翻页（和信息流 List 里按在按钮上也能滚是同一个道理）。
 *
 *   3) 关注 / 点赞 / 转发 / 正文展开这些状态本来就属于"这一条"，改 `reel` 上的字段即可就地重绘
 *      （`reel` 是 @Observed，见 model/Reel），不用再往父组件搬一份镜像状态。
 */
@Component
struct ReelOverlay {
  /** 这一条（**@ObjectLink**：点赞/转发/计数都是就地改它，见类头第 1、3 条）。 */
  @ObjectLink reel: Reel;
  /**
   * **我自己的账号名**（宿主传进来）。
   *
   * 作者就是我自己时不画关注按钮（"我的"页视频分页点进来的那页、以及首页刷到自己的视频时）。
   * 空串 = 还不知道，那就照常画。
   */
  @Prop ownAuthor: string = '';
  /**
   * 现在是不是**当前这条**（在播的那条）。
   *
   * 信息层拿它做一件事：数据源没给关注状态时，只给"当前这一条"问一次
   * （见 ensureFollowState）—— 每条都问的话，一个 Swiper 里三条就三次请求。
   */
  @Prop @Watch('onActiveChanged') active: boolean = false;
  /** 屏幕宽度（vp）：正文折叠排版要量可用宽度（见 captionPrefix）。 */
  @Prop screenWidthVp: number = FALLBACK_WIDTH_VP;
  /**
   * 这一条的信息层要**跟着底栏下沉多少**（vp，向下为正，见 ReelsPage.overlaySink）。
   *
   * 只用在一个地方：动作区那一行、资讯区那一列各套一次 `translate({ y })`。
   * 用位移而不是改 `bottom` 内边距：位移是纯图形变换，不触发布局重算，跟栏那条弹簧曲线
   * 天然同步；而且这两层本来就是"钉在屏幕底部"的浮层，挪一段最省事。
   */
  @Prop overlaySink: number = 0;
  /** 材质厚度（和全 app 的材质组件同一份设定）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 关注状态是会话级覆盖表说了算（别处点过也要跟着变，见 core/FollowState）。 */
  @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
  /** 这一条的作者我关注了没有。 */
  @State private following: boolean = false;
  /** 正文**展开着没有**（需求：超过两行折叠，展开后文末显示" 收起"）。 */
  @State private captionExpanded: boolean = false;
  /** 正文现在显示的是不是译文 / 译文本身（需求："reels 正文最后"那颗翻译）。 */
  @State private captionTranslated: boolean = false;
  @State private captionTranslation: string = '';
  /** 按**文本**缓存的折叠前缀（译文也用它，见 prefixOfText）。 */
  private textFits: Map<string, string> = new Map<string, string>();
  /** 翻译失败（宿主弹提示）。 */
  onTranslateFailed: () => void = (): void => {
  };
  /** 关注 / 点赞 / 转发正在请求中（防连点）。 */
  @State private followBusy: boolean = false;
  @State private likeBusy: boolean = false;
  @State private repostBusy: boolean = false;
  /**
   * 这一条**收藏了没有**（需求："reels 页面添加收藏按钮……收藏按钮实现一下功能，用 http 请求"）。
   *
   * 为什么是本地 @State 而不是直接读 `reel.saved`：真机上 clips 载荷**不给**收藏状态
   * （见 model/Reel.saved），权威来源是 **core/SaveState 的会话覆盖表** ——
   * 信息层每次重建（Swiper 翻页会销毁/重建相邻页）都要拿覆盖表重算一次，
   * 否则用户收藏过的视频翻回来又变成空心书签。
   */
  @State private saved: boolean = false;
  @State private saveBusy: boolean = false;
  /** 正文折叠前缀的缓存（按 shortcode；量一次就够，切条来回不重复量）。 */
  private captionLines: Map<string, string> = new Map<string, string>();
  /** 这条作者的关注状态**单独问过**没有（见 ensureFollowState）。 */
  private followAsked: boolean = false;

  /**
   * 右侧动作栏那几个按钮的动作 —— **功能由宿主实现**（HTTP 直发在 pages/Index，
   * 因为点赞/转发的令牌、模板、以及"落到别的列表上"都在那边）。
   *
   * 返回 Promise<boolean>：true = 成功；false 时本组件自己回滚乐观状态。
   */
  onLike: (reel: Reel, like: boolean) => Promise<boolean> =
    (reel: Reel, like: boolean): Promise<boolean> => Promise.resolve(false);
  onRepost: (reel: Reel, repost: boolean) => Promise<boolean> =
    (reel: Reel, repost: boolean): Promise<boolean> => Promise.resolve(false);
  /**
   * 收藏 / 取消收藏（需求："收藏按钮实现一下功能，用 http 请求"）。
   *
   * 同样交给宿主（HTTP 直发、失败原因、会话覆盖表都在 pages/Index，见 Index.saveReel）。
   */
  onSave: (reel: Reel, save: boolean) => Promise<boolean> =
    (reel: Reel, save: boolean): Promise<boolean> => Promise.resolve(false);
  onFollow: (reel: Reel, follow: boolean) => Promise<boolean> =
    (reel: Reel, follow: boolean): Promise<boolean> => Promise.resolve(false);
  /** 点作者行（头像 + 账号名）→ 打开用户主页。 */
  onOpenUser: (reel: Reel) => void = (reel: Reel): void => {
  };
  /** 点评论：打开这一条的评论（宿主实现，老路径是原生评论面板）。 */
  onComments: (reel: Reel) => void = (reel: Reel): void => {
  };
  /** 转发给好友 / 更多：这一版宿主只弹一句"还没接入"。 */
  onShare: (reel: Reel) => void = (reel: Reel): void => {
  };
  onMore: (reel: Reel) => void = (reel: Reel): void => {
  };

  aboutToAppear(): void {
    this.syncFollow();
    this.syncSaved();
  }

  /**
   * 收藏状态以**会话覆盖表**为准（见 core/SaveState 与上面的 `saved` 说明）。
   *
   * 载荷给了 `has_saved` 就用它当兜底值，没给就是 false（真机上基本都没给）。
   */
  private syncSaved(): void {
    this.saved = SaveState.resolve(this.reel.mediaId, this.reel.saved);
  }

  /** 别处改过关注状态：重新算一次（见 core/FollowState 的"全局刷新"）。 */
  private onFollowVersion(): void {
    this.syncFollow();
  }

  /** 这一条成了"当前这条"：数据源没给关注状态的话，现在问一次（见 ensureFollowState）。 */
  private onActiveChanged(): void {
    if (this.active) {
      this.ensureFollowState();
    }
  }

  /**
   * 关注状态以**会话级覆盖表**为准（本地点过的以本地为准，见 core/FollowState）：
   * 在别处（首页卡片 / 用户主页）点过关注，这里也要显示成"已关注"。
   *
   * **覆盖表里没有时用数据源给的值**（`reel.following`，来自 clips / 个人主页 / 推荐流载荷里的
   * `user.friendship_status.following`）—— 以前这里直接拿 `false` 当兜底，于是"我明明关注了
   * 却显示成关注"（用户报的"reels 关注按钮状态没有正确显示"就是这个）。
   * 数据源也没给（`followKnown` 为假）时由 ensureFollowState 单独问一次。
   */
  private syncFollow(): void {
    this.following = this.reel.author.length > 0
      && FollowState.resolve(this.reel.authorId,
        FollowState.resolveName(this.reel.author, this.reel.following));
  }

  /**
   * 数据源没给关注状态时**单独问一次**（`friendships/show_many`，见 NativeFollow.statesFor）。
   *
   * 只问"当前这一条"的作者（滑到哪条问哪条）；问到就写进会话级覆盖表 —— 首页卡片、
   * 用户主页会跟着一起对，而 `@StorageLink` 会把这一页也刷过来。
   */
  private ensureFollowState(): void {
    if (this.followAsked || this.reel.followKnown || this.isOwnAuthor()) {
      return;
    }
    if (this.reel.authorId.length === 0 || this.reel.author.length === 0) {
      return;
    }
    this.followAsked = true;
    NativeFollow.statesFor([this.reel.authorId]).then((states: Map<string, boolean>): void => {
      const known: boolean | undefined = states.get(this.reel.authorId);
      if (known === undefined) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'reel follow looked up code=%{public}s following=%{public}s',
        this.reel.shortcode, `${known}`);
      FollowState.remember(this.reel.authorId, this.reel.author, known);
    }).catch((): void => {
    });
  }

  /**
   * 关注状态以**会话级覆盖表**为准（本地点过的以本地为准，见 core/FollowState）：
   * 在别处（首页卡片 / 用户主页）点过关注，这里也要显示成"已关注"。
   * id 拿不到时按**账号名**问（覆盖表也按名字存了一份，见 FollowState.resolveName）。
   */

  /** 这一条的作者是不是**我自己**（宿主把自己的账号名传进来，见 ownAuthor）。 */  private isOwnAuthor(): boolean {
    return this.ownAuthor.length > 0
      && this.reel.author.toLowerCase() === this.ownAuthor.toLowerCase();
  }

  /** 正文的**折叠前缀**（超过两行就截断，尾巴上留出" ... 展开"的位置，见 core/CaptionFit）。 */
  private captionPrefix(): string {
    const text: string = this.reel.caption;
    if (text.length === 0) {
      return '';
    }
    const cached: string | undefined = this.captionLines.get(this.reel.shortcode);
    if (cached !== undefined) {
      return cached;
    }
    const availVp: number = this.screenWidthVp - SIDE_PADDING * 2 - CAPTION_TAIL_SAFETY_VP;
    const prefix: string = availVp > 0
      ? CaptionFit.prefix(this.getUIContext(), text, availVp, CAPTION_FONT_SIZE)
      : text;
    this.captionLines.set(this.reel.shortcode, prefix);
    return prefix;
  }

  /** 这条的正文被截断了吗（截断了才追加" ... 展开"、才响应点击）。 */
  private captionTruncated(): boolean {
    return this.reel.caption.length > 0 && this.captionPrefix() !== this.reel.caption;
  }

  /**
   * **任意文本**的折叠前缀（译文也走它）。
   *
   * 原来的 `captionPrefix()` 按 shortcode 缓存；译文不是 reel 自带的，所以按**文本本身**缓存 ——
   * "点了翻译之后仍然能展开/收起"用的就是同一套量行逻辑（见 captionBlock 的译文分支）。
   */
  private prefixOfText(text: string): string {
    if (text.length === 0) {
      return '';
    }
    const cached: string | undefined = this.textFits.get(text);
    if (cached !== undefined) {
      return cached;
    }
    const availVp: number = this.screenWidthVp - SIDE_PADDING * 2 - CAPTION_TAIL_SAFETY_VP;
    const prefix: string = availVp > 0
      ? CaptionFit.prefix(this.getUIContext(), text, availVp, CAPTION_FONT_SIZE)
      : text;
    this.textFits.set(text, prefix);
    return prefix;
  }

  /** 这段文本放不放进两行（放不下才给" ... 展开"、才响应点击）。 */
  private textTruncated(text: string): boolean {
    return text.length > 0 && this.prefixOfText(text) !== text;
  }

  /** 计数文案：上万折成"x.x万"（和「我的」页那份一致，免得两处写法不一样）。 */
  private countText(value: number): string {
    if (value >= 10000) {
      return `${(value / 10000).toFixed(1)}万`;
    }
    return value > 0 ? `${value}` : '';
  }

  /** 账号名可占的最大宽度（太长的名字不许把右边的关注按钮顶出屏幕）。 */
  private nameMaxWidth(): number {
    const total: number = this.screenWidthVp - SIDE_PADDING * 2;
    const reserved: number = FOLLOW_PILL_WIDTH + AUTHOR_AVATAR_SIZE + 60;
    const left: number = total - reserved;
    return left > 80 ? left : 80;
  }

  /**
   * 点右侧那颗心（需求：点赞走 HTTP，见宿主 pages/Index.likeReel）。
   *
   * 乐观翻转：点下去立刻变色，宿主回了 false 再翻回来 —— 等网络回结果会像"点了没反应"。
   * 状态直接写在 `reel` 上（@Observed + @ObjectLink，就地重绘，见类头第 3 条）。
   */
  private tapLike(target: boolean): void {
    if (this.likeBusy || this.reel.mediaId.length === 0) {
      // 记一行：拿不到媒体 id 时这颗心点了不会有任何变化（见 model/Reel 的 mediaId）。
      hilog.info(DOMAIN, TAG, 'reel like ignored busy=%{public}s id=%{public}d',
        `${this.likeBusy}`, this.reel.mediaId.length);
      return;
    }
    // **按按钮报的目标值来，而不是"取反"**：Toggle 这种按钮会把父组件传回来的 isOn 也报一次
    // （见 MaterialSurface.fire 的 pressPending），"取反"会让那次回声把状态翻回去、
    // 形成来回发请求的振荡（真机上就是这么转个不停的）。
    if (target === this.reel.liked) {
      return;
    }
    this.likeBusy = true;
    // 兜底解锁：宿主那发请求可能拖很久（原生那条失败会退到"驱动网页"，实测几十秒），
    // 不放开的话这颗心就再也点不动了（真机日志里就撞到过 `busy=true` 一直不放）。
    //
    // 句柄存起来（审计项 A3）：原来是裸 `setTimeout` —— 上一次的兜底会在下一次请求**中途**把
    // `busy` 放开（用户可以在请求还没回来时再点一次），组件销毁后也仍会写 `@State`。
    this.armBusyTimer();
    commitReelLike(this.reel, target, this.onLike).then((): void => {
      this.disarmBusyTimer();
      this.likeBusy = false;
    });
  }

  /**
   * 三处动作按钮（赞/转发/收藏）共用的"兜底解锁"定时器（审计项 A3）。
   *
   * `arm` 会先取消上一次：同一时刻只允许一个兜底在飞，避免它把后一次请求的 busy 提前放开。
   */
  private armBusyTimer(): void {
    this.disarmBusyTimer();
    this.busyTimer = setTimeout((): void => {
      this.busyTimer = -1;
      this.likeBusy = false;
      this.repostBusy = false;
      this.saveBusy = false;
      hilog.info(DOMAIN, TAG, 'action busy timeout, unlocked');
    }, ACTION_BUSY_MAX_MS);
  }

  private disarmBusyTimer(): void {
    if (this.busyTimer >= 0) {
      clearTimeout(this.busyTimer);
      this.busyTimer = -1;
    }
  }

  /** 三处动作按钮的兜底解锁定时器句柄（见 armBusyTimer）。 */
  private busyTimer: number = -1;

  /**
   * 组件销毁时解开兜底定时器（审计项 A3）。
   *
   * 这三颗按钮（赞/转发/收藏）的 busy 状态在 `ReelOverlay` 里，句柄也在它这儿 —— 页面退出后
   * 定时器仍会去写已卸载组件的 `@State`，所以在这里清。
   */
  aboutToDisappear(): void {
    this.disarmBusyTimer();
  }

  /** 点转发（同样走 HTTP，见宿主 pages/Index.repostReel）。 */
  private tapRepost(target: boolean): void {
    if (this.repostBusy || this.reel.mediaId.length === 0) {
      hilog.info(DOMAIN, TAG, 'reel repost ignored busy=%{public}s id=%{public}d',
        `${this.repostBusy}`, this.reel.mediaId.length);
      return;
    }
    // 同上：按按钮报的目标值来，且与当前状态一致时直接不发（防 Toggle 回声来回翻）。
    if (target === this.reel.reposted) {
      hilog.debug(DOMAIN, TAG, 'reel repost same target=%{public}s → skip', `${target}`);
      return;
    }
    hilog.debug(DOMAIN, TAG, 'reel repost target=%{public}s cur=%{public}s',
      `${target}`, `${this.reel.reposted}`);
    const next: boolean = target;
    const before: number = this.reel.repostCount;
    this.repostBusy = true;
    // 兜底解锁（同 tapLike）：宿主那发转发可能要退到网页驱动，几十秒不回来是常事。
    // 句柄与取消都交给 armBusyTimer（审计项 A3）。
    this.armBusyTimer();
    this.reel.reposted = next;
    this.reel.repostCount = next ? before + 1 : (before > 0 ? before - 1 : 0);
    this.onRepost(this.reel, next).then((ok: boolean): void => {
      this.repostBusy = false;
      if (!ok) {
        this.reel.reposted = !next;
        this.reel.repostCount = before;
      }
    }).catch((): void => {
      this.repostBusy = false;
      this.reel.reposted = !next;
      this.reel.repostCount = before;
    });
  }

  /**
   * 点书签（收藏，需求："收藏按钮实现一下功能，用 http 请求"）。
   *
   * 和点赞/转发同一套：**乐观翻转**（点下去书签立刻变实心），宿主回了 false 再翻回来 ——
   * 等网络那几百毫秒会像"点了没反应"。按按钮报的**目标值**来（不是取反）：
   * Toggle 会把父组件传回来的 isOn 再报一次，取反会让那次回声把状态翻回去（见 tapLike 的说明）。
   *
   * 成功后写进 **core/SaveState**（会话覆盖表）：这条 Reel 的信息层翻页被重建之后，
   * 那颗书签还是实心的。
   */
  private tapSave(target: boolean): void {
    if (this.saveBusy || this.reel.mediaId.length === 0) {
      hilog.info(DOMAIN, TAG, 'reel save ignored busy=%{public}s id=%{public}d',
        `${this.saveBusy}`, this.reel.mediaId.length);
      return;
    }
    if (target === this.saved) {
      return;
    }
    this.saveBusy = true;
    // 兜底解锁（同 tapLike）：宿主那发请求可能拖很久，不放开这颗按钮就再也点不动了。
    // 句柄与取消都交给 armBusyTimer（审计项 A3）。
    this.armBusyTimer();
    this.saved = target;
    this.onSave(this.reel, target).then((ok: boolean): void => {
      this.saveBusy = false;
      if (ok) {
        SaveState.remember(this.reel.mediaId, target);
        this.reel.saved = target;
        return;
      }
      // 失败回滚（原因由宿主说明，见 pages/Index.saveReel）。
      this.saved = !target;
    }).catch((): void => {
      this.saveBusy = false;
      this.saved = !target;
    });
  }

  /**
   * 点作者行右边那颗关注 / 已关注（需求：展示关注状态、可关注与取关）。
   *
   * 同样乐观翻转 + 失败回滚；成功之后**由宿主写会话级覆盖表**（见 core/FollowState），
   * 别处（首页卡片、用户主页）会跟着变。
   */
  private tapFollow(): void {
    if (this.followBusy || this.reel.author.length === 0) {
      return;
    }
    const next: boolean = !this.following;
    this.followBusy = true;
    this.following = next;
    this.onFollow(this.reel, next).then((ok: boolean): void => {
      this.followBusy = false;
      if (!ok) {
        this.following = !next;
      }
    }).catch((): void => {
      this.followBusy = false;
      this.following = !next;
    });
  }

  /**
   * **作者行**（需求："原来显示用户 id 的位置采用 feeds 流中用户资讯栏的沉浸光感组件，
   * 头像 + 用户 id 的组合。组件右边显示关注按钮（沉浸光感）"）。
   *
   * 和信息流资料行同一套做法：材质由 **Toggle** 承载（官方"全页面生效"的组件之一，
   * 见 MaterialSurface 的文件头），内容和材质同一个节点，按压/拖拽时一起动。
   * 点它 = 打开这位用户的主页（和信息流同一条路）。
   */
  @Builder
  authorRow() {
    // 作者资讯组件与关注按钮之间**留出间距**（需求："关注按钮不要贴着用户资讯组件"）。
    Row({ space: AUTHOR_FOLLOW_GAP }) {
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Row({ space: 8 }) {
          // 头像（有图用图，没图垫一块底色圆，同信息流资料行）。
          if (this.reel.avatarUrl.length > 0) {
            Image(this.reel.avatarUrl)
              .draggable(false)
              .width(AUTHOR_AVATAR_SIZE)
              .height(AUTHOR_AVATAR_SIZE)
              .borderRadius(AUTHOR_AVATAR_SIZE / 2)
              .objectFit(ImageFit.Cover)
              .backgroundColor($r('app.color.field_background'))
          } else {
            Column()
              .width(AUTHOR_AVATAR_SIZE)
              .height(AUTHOR_AVATAR_SIZE)
              .borderRadius(AUTHOR_AVATAR_SIZE / 2)
              .backgroundColor($r('app.color.field_background'))
          }
          // 账号名**不带 @**（需求："用户id不用显示@"）。
          Text(this.reel.author)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: this.nameMaxWidth() })
        }
      }
      .padding({ left: 3, right: 12, top: 3, bottom: 3 })
      .borderRadius(AUTHOR_ROW_HEIGHT / 2)
      .backgroundColor(Color.Transparent)
      .selectedColor(Color.Transparent)
      // 视频上不反色（需求："取消视频沉浸式标题反色效果"）：文字走主题色。
      .attributeModifier(new SurfaceModifier(this.materialThickness, false))
      .hitTestBehavior(HitTestMode.Transparent)
      .onChange((): void => {
      })
      .onClick((): void => {
        this.onOpenUser(this.reel);
      })
      .onTouch(trackMaterialTouch)

      // 关注按钮（需求："组件右边显示关注按钮（沉浸光感），需要展示关注状态，点击关注或者取消关注"）。
      //
      // **只要知道账号名就画**：拿不到数字 id 时宿主那边会退回"网页驱动"那条路
      // （打开对方主页点它自己的关注按钮，见 pages/Index.followUser），照样能关注上 ——
      // 比"因为少一个 id 就整颗按钮不出现"好得多（用户报的"没看到关注按钮"就是这个）。
      // 例外：**作者就是我自己**时不画（关注自己没有意义，见 ownAuthor）。
      if (this.reel.author.length > 0 && !this.isOwnAuthor()) {
        MaterialLabelButton({
          labelRes: this.following
            ? $r('app.string.action_following') : $r('app.string.action_follow'),
          // 字色**始终走主题色（深色下就是白）**：需求"已关注字体颜色保持白色" ——
          // 这里原来在已关注时压了一档灰（#737373），视频画面上看着像"禁用/没点成功"。
          tint: '',
          pillWidth: FOLLOW_PILL_WIDTH,
          pillHeight: AUTHOR_ROW_HEIGHT,
          fontSize: 13,
          onTap: (): void => {
            this.tapFollow();
          }
        })
      }
    }
    .alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * **正文**（需求："在用户资讯组件下方显示正文，不需要叠加背景，结构采用 feeds 的正文部分，
   * 超过两行以 ' ... 展开' 显示，展开后文末显示 ' 收起'"）。
   *
   * 不叠任何材质/底色：直接白字压在画面上（和 IG 一致）；折叠判据与信息流那份**同一套**
   * （见 core/CaptionFit），所以同一段正文在两处的折行位置一致。
   *
   * **展开/收起带动画**（需求："给 reels 页的文本展开添加动画"）：折行是 `maxLines` 控制的，
   * 而 `maxLines` 不可补间，所以走"两态节点 + 过渡"：切换包在 `animateTo` 里，
   * 两个分支各自挂 `.transition`（淡入 + 轻微上移），观感是"正文长出来/收回去"，
   * 而不是硬切一下。
   */
  @Builder
  captionBlock() {
    if (this.reel.caption.length > 0) {
      if (this.captionTranslated) {
        /*
         * **译文态**：正文换成译文，但**展开/收起照旧可用**（需求："点击翻译后需要保留展开功能"，
         * 并且要"也加入 reels 里"）。截断按**译文自己**量（`prefixOfText`），
         * 不能拿原文的截断位置套上去。
         */
        if (this.captionExpanded) {
          Text() {
            Span(this.captionTranslation.length > 0 ? this.captionTranslation : this.reel.caption)
              .fontColor(Color.White)
            Span(CAPTION_LESS)
              .fontColor('#BFBFBF')
          }
          .fontSize(CAPTION_FONT_SIZE)
          .lineHeight(CAPTION_LINE_HEIGHT)
          .width('100%')
          .textAlign(TextAlign.Start)
          .transition(TransitionEffect.opacity(0).combine(
            TransitionEffect.translate({ y: CAPTION_SLIDE_VP })))
          .onClick((): void => {
            this.toggleCaption();
          })
        } else {
          Text() {
            Span(this.prefixOfText(this.captionTranslation.length > 0
              ? this.captionTranslation : this.reel.caption))
              .fontColor(Color.White)
            if (this.textTruncated(this.captionTranslation.length > 0
              ? this.captionTranslation : this.reel.caption)) {
              Span(CAPTION_MORE)
                .fontColor('#BFBFBF')
            }
          }
          .fontSize(CAPTION_FONT_SIZE)
          .lineHeight(CAPTION_LINE_HEIGHT)
          .maxLines(CAPTION_COLLAPSED_MAX_LINES)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .transition(TransitionEffect.opacity(0).combine(
            TransitionEffect.translate({ y: -CAPTION_SLIDE_VP })))
          .onClick((): void => {
            if (this.textTruncated(this.captionTranslation.length > 0
              ? this.captionTranslation : this.reel.caption)) {
              this.toggleCaption();
            }
          })
        }
      } else if (this.captionExpanded) {
        // 展开态：全文 + 结尾灰色的" 收起"。行数不设限 —— 展开就是为了看全。
        Text() {
          Span(this.reel.caption)
            .fontColor(Color.White)
          Span(CAPTION_LESS)
            .fontColor('#BFBFBF')
        }
        .fontSize(CAPTION_FONT_SIZE)
        .lineHeight(CAPTION_LINE_HEIGHT)
        .width('100%')
        .textAlign(TextAlign.Start)
        .transition(TransitionEffect.opacity(0).combine(
          TransitionEffect.translate({ y: CAPTION_SLIDE_VP })))
        .onClick((): void => {
          this.toggleCaption();
        })
      } else {
        // 折叠态：正文（最多两行）+ 结尾灰色的" ... 展开"。
        Text() {
          Span(this.captionPrefix())
            .fontColor(Color.White)
          if (this.captionTruncated()) {
            Span(CAPTION_MORE)
              .fontColor('#BFBFBF')
          }
        }
        .fontSize(CAPTION_FONT_SIZE)
        .lineHeight(CAPTION_LINE_HEIGHT)
        .maxLines(CAPTION_COLLAPSED_MAX_LINES)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .transition(TransitionEffect.opacity(0).combine(
          TransitionEffect.translate({ y: -CAPTION_SLIDE_VP })))
        .onClick((): void => {
          if (this.captionTruncated()) {
            this.toggleCaption();
          }
        })
      }
      /*
       * 「翻译」**跟在正文最后**（需求："reels 正文最后"），只有非中文正文才会画出来。
       * 放在正文下面一行而不是塞进 Span：正文是折叠/展开/译文三种形态，行内塞进去会跟着变。
       */
      Row() {
        TranslateLabel({
          source: this.reel.caption,
          showing: this.captionTranslated,
          fontSize: 13,
          onToggle: (show: boolean): void => {
            this.toggleCaptionTranslation(show);
          }
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .margin({ top: 2 })
    }
  }

  /** 点「翻译 / 显示原文」：先切状态（立刻有反应），译文第一次再补网络。 */
  private toggleCaptionTranslation(show: boolean): void {
    const text: string = this.reel.caption;
    if (text.length === 0 || show === this.captionTranslated) {
      return;
    }
    this.captionTranslated = show;
    if (!show || this.captionTranslation.length > 0) {
      return;
    }
    Translator.translate(text).then((translated: string | null): void => {
      if (translated === null || translated.length === 0) {
        hilog.warn(0xFF00, 'ReelsPage', 'translate failed why=%{public}s', Translator.lastDetail());
        this.onTranslateFailed();
        // 失败退回原文态，别让按钮写着"显示原文"而正文还是原文。
        this.captionTranslated = false;
        return;
      }
      this.captionTranslation = translated;
    });
  }

  /** 切换正文的展开态（**必须在 animateTo 里改状态**，否则下面那两个 transition 不会走）。 */
  private toggleCaption(): void {
    animateTo({ duration: CAPTION_ANIM_MS, curve: Curve.EaseOut }, (): void => {
      this.captionExpanded = !this.captionExpanded;
    });
  }

  /**
   * **右侧竖排动作栏**（需求："屏幕右边垂直显示 点赞/评论/转发/转发给好友/更多 按钮，
   * 点赞和转发按钮通过 http 请求实现功能"）。
   *
   * 图标用**信息流那一套**（需求："动作区的图标使用 feeds 流那一套，需要实现点赞功能和转发功能，
   * 转发图标用 feeds 那个叠加的图标，更多图标则用 feeds 右上角那个图标"）：
   *   - 点赞：`heart` / 已赞 `heart_fill` + `like_active` 色；
   *   - 评论：`message`；
   *   - 转发：`transfer_station`，已转发时**正中叠一个对勾**（同 FeedList 的 PostActions）；
   *   - 转发给好友：`paperplane`；
   *   - 更多：`sort`（就是信息流资料行右上角那颗「更多」用的图标，见 FeedList.profileRow）。
   *
   * 计数与图标**直接读 `this.reel`**（不经过 @Builder 的值参数）：@Builder 按值传参时参数的
   * 变化不保证触发刷新，而这里要的正是"点赞/转发一改就重绘"（见类头第 1 条）。
   */
  @Builder
  actionColumn() {
    Column({ space: ACTION_GAP }) {
      // 点赞：图标 + 计数（图标自带"点赞弹一下"动画，见 AnimatedIcons.LikeIcon）。
      Column({ space: 2 }) {
        MaterialIconButton({
          symbol: this.reel.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
          isOn: this.reel.liked,
          // 带动画的图标自己管颜色（已赞红、未赞主题色），这里不需要再给 tint。
          animated: 'like',
          buttonSize: ACTION_BUTTON_SIZE,
          iconSize: ACTION_ICON_SIZE,
          onTap: (on: boolean): void => {
            this.tapLike(on);
          }
        })
        if (this.reel.likeCount > 0) {
          Text(this.countText(this.reel.likeCount))
            .fontSize(11)
            .fontColor(Color.White)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 评论：图标 + 计数。
      Column({ space: 2 }) {
        MaterialIconButton({
          symbol: $r('sys.symbol.message'),
          isOn: false,
          tint: '',
          buttonSize: ACTION_BUTTON_SIZE,
          iconSize: ACTION_ICON_SIZE,
          onTap: (on: boolean): void => {
            this.onComments(this.reel);
          }
        })
        if (this.reel.commentCount > 0) {
          Text(this.countText(this.reel.commentCount))
            .fontSize(11)
            .fontColor(Color.White)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 转发：图标（已转发时正中叠对勾）+ 计数。
      // 图标自带两个动画：外层循环箭头转 360° 镜像旋转、内层对勾一笔画出来（见 AnimatedIcons.RepostIcon）。
      Column({ space: 2 }) {
        MaterialIconButton({
          symbol: $r('sys.symbol.transfer_station'),
          isOn: this.reel.reposted,
          animated: 'repost',
          buttonSize: ACTION_BUTTON_SIZE,
          iconSize: ACTION_ICON_SIZE,
          onTap: (on: boolean): void => {
            this.tapRepost(on);
          }
        })
        if (this.reel.repostCount > 0) {
          Text(this.countText(this.reel.repostCount))
            .fontSize(11)
            .fontColor(Color.White)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 转发给好友。
      MaterialIconButton({
        symbol: $r('sys.symbol.paperplane'),
        isOn: false,
        tint: '',
        buttonSize: ACTION_BUTTON_SIZE,
        iconSize: ACTION_ICON_SIZE,
        onTap: (on: boolean): void => {
          this.onShare(this.reel);
        }
      })

      /*
       * 收藏（书签）—— **放在「更多」上面**（需求："显示在更多按钮上方"）。
       *
       * 图标是系统那两颗 `bookmark` / `bookmark_fill`（和「我的」页"收藏"分段一致），
       * 收藏那一刻由小到大弹一下（见 AnimatedIcons.SaveIcon）。
       * 没有计数：IG 的书签下面本来也不显示数字。
       */
      MaterialIconButton({
        symbol: $r('sys.symbol.bookmark'),
        isOn: this.saved,
        animated: 'save',
        buttonSize: ACTION_BUTTON_SIZE,
        iconSize: ACTION_ICON_SIZE,
        onTap: (on: boolean): void => {
          this.tapSave(on);
        }
      })

      // 更多。
      MaterialIconButton({
        symbol: $r('sys.symbol.sort'),
        isOn: false,
        tint: '',
        buttonSize: ACTION_BUTTON_SIZE,
        iconSize: ACTION_ICON_SIZE,
        onTap: (on: boolean): void => {
          this.onMore(this.reel);
        }
      })
    }
    .width(ACTION_COLUMN_WIDTH)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 左下那一块：作者行（沉浸光感：头像 + 账号名）→ 正文。
      Column({ space: 6 }) {
        this.authorRow()
        this.captionBlock()
      }
      // 右边给动作栏让出位置（两者都在底部，重叠起来会互相压住）。
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: SIDE_PADDING, right: ACTION_COLUMN_WIDTH, bottom: INFO_BOTTOM })
      // 跟着底栏下沉（需求："动作区和资讯区跟随 tabbar 下沉"）：整块往下挪，和栏同一条曲线。
      .translate({ y: this.overlaySink })
      // 文字不吃手势：竖向滑动照旧交给 Swiper。
      .hitTestBehavior(HitTestMode.Transparent)

      // 右侧竖排动作栏（点赞 / 评论 / 转发 / 转发给好友 / 更多）。
      //
      // 位置：外层的 Stack 是 `Alignment.BottomStart`，**所有子节点都会被它摆到左下** ——
      // 所以这里套一层**整屏宽度的 Row**，用 `justifyContent(End)` 把动作栏顶到右边、
      // `alignItems(Bottom)` 压到底部（用户报的"动作区显示在了屏幕左边"就是这个：
      // 直接把 Column 当 Stack 的子节点，它会被 Stack 的对齐摆到左边去）。
      Row() {
        this.actionColumn()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Bottom)
      .padding({ right: ACTION_RIGHT_PADDING, bottom: INFO_BOTTOM })
      // 和左边那块同一个位移：一起沉、一起回来（见 overlaySink）。
      .translate({ y: this.overlaySink })
      // 不吃手势（按钮自己要能点，见 actionColumn 里的材质按钮）。
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    // 这一层整体也不吃手势：竖向滑动要落到下面的 Swiper 上（见类头第 2 条）。
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

@Component
export struct ReelsPage {
  /**
   * 视图模型：**接口**（普通属性，数据由本组件的 @State 持有，见 ProfilePage 的说明）。
   *
   * 认接口而不是认 ReelsViewModel：同一套界面有两个数据来源（首页 clips 流 /
   * 某个人的视频分页），见 model/Reel 的 ReelStreamVm。默认值是首页那条流
   * （首页的用法一个字都不用改）。
   */
  vm: ReelStreamVm = new ReelsViewModel();
  /**
   * 这一页是**谁**（标题栏那两颗按钮按来源记账，见 core/ReelsAction）。
   *
   * 三个 reels 类页面用的是同一个组件，但标题栏是各自的 NavDestination/Index 画的 ——
   * 不分来源的话，"从用户主页那页返回"会让底栏那页的下载地址被覆盖（下到另一条视频）。
   */
  @Prop source: string = ReelsAction.HOME;
  /**
   * **我自己的账号名**（宿主传进来，见 ReelOverlay.ownAuthor）。
   */
  @Prop ownAuthor: string = '';
  /**
   * **动作区 / 资讯区跟着底栏下沉的距离**（vp，向下为正，0 = 原位）。
   *
   * 需求："reels 页 tabbar 下沉收缩时所有控件跟着下沉……我需要动作区和资讯区跟随 tabbar 下沉"。
   * 底栏那套下沉（Index 的 applyBarSink）动的是栏自己的布局参数，摸不到这里，所以由宿主把
   * "栏现在沉了多少"换算成一个**距离**传进来（见 Index 的 OVERLAY_SINK_DISTANCE）；本组件只把它
   * 转交给每条的信息层（ReelOverlay.overlaySink），套在那两个子层的 `translate` 上 ——
   * 纯位移、不改布局，和"信息层不吃手势"那套（hitTestBehavior）互不干扰。
   *
   * 只有外壳那页（底栏那个 reels 标签）会传；整屏的 reels 页（我的 / 搜索点进去的）没有浮动
   * 底栏，保持默认 0，一个字都不用改。
   */
  @Prop overlaySink: number = 0;
  @State private reels: Array<Reel> = [];
  @State private activeIndex: number = 0;
  /** 当前这条的首帧出来了没有（决定封面叠层撤不撤，见 reelPage）。 */
  @State private videoReady: boolean = false;
  @State private busy: boolean = false;
  @State private status: string = '';
  /** 视频静音（全局开关，媒体区右上角那颗喇叭键改它）。 */
  @StorageProp(SETTING_VIDEO_MUTED) videoMuted: boolean = false;
  /** 屏幕宽度（vp）：交给信息层做正文折叠排版（见 ReelOverlay.captionPrefix）。 */
  @State private screenWidthVp: number = FALLBACK_WIDTH_VP;
  /** 双击点赞那颗放大爱心的瞬时状态（整页一个，见 build 里的 LikeBurst）。 */
  @State private burst: LikeBurstState = new LikeBurstState();

  /**
   * 右侧动作栏 / 作者行那几个动作 —— **功能由宿主实现**（HTTP 直发在 pages/Index），
   * 这里只把宿主的实现转交给每条自己的信息层（见 ReelOverlay）。
   */
  onLike: (reel: Reel, like: boolean) => Promise<boolean> =
    (reel: Reel, like: boolean): Promise<boolean> => Promise.resolve(false);
  onRepost: (reel: Reel, repost: boolean) => Promise<boolean> =
    (reel: Reel, repost: boolean): Promise<boolean> => Promise.resolve(false);
  /** 收藏 / 取消收藏（HTTP 直发在 pages/Index.saveReel，见 ReelOverlay.onSave）。 */
  onSave: (reel: Reel, save: boolean) => Promise<boolean> =
    (reel: Reel, save: boolean): Promise<boolean> => Promise.resolve(false);
  onFollow: (reel: Reel, follow: boolean) => Promise<boolean> =
    (reel: Reel, follow: boolean): Promise<boolean> => Promise.resolve(false);
  onOpenUser: (reel: Reel) => void = (reel: Reel): void => {
  };
  onComments: (reel: Reel) => void = (reel: Reel): void => {
  };
  onShare: (reel: Reel) => void = (reel: Reel): void => {
  };
  onMore: (reel: Reel) => void = (reel: Reel): void => {
  };
  /** 正文翻译失败（宿主弹提示；见 ReelOverlay.onTranslateFailed）。 */
  onTranslateFailed: () => void = (): void => {
  };
  private readonly swiperController: SwiperController = new SwiperController();
  /**
   * Swiper 的**初始**页（只在构建时求值，见 `.index(...)` 的说明）。
   *
   * 为什么不用 `activeIndex`：#State 一改，`.index(...)` 这个属性就会被重新求值并**立刻跳页**，
   * 于是"翻页动画"被掐断 —— 实测 onAnimationStart→onAnimationEnd 只有 9~16ms（偶尔才 300~500ms），
   * 用户看到的就是"滑动秒切、没有过渡"。它还会和 onAnimationStart 里提前切索引互相打架，
   * 出现页面来回乱跳（日志里 1↔2 反复几百毫秒一次）。
   * 恢复位置继续靠 onAppear 里的 `changeIndex(index, false)`（那是显式的、不带动画的定位）。
   */
  private initialIndex: number = 0;
  /** 本次翻页动画的开始时刻（onAnimationStart 记下，onAnimationEnd 算时长，见 SWITCH_ANIM_MS）。 */
  private animationStartedMs: number = 0;
  /**
   * **手指一开始划**就通知页面（底栏下沉收缩用，见 pages/Index 的 onReelsSink）。
   *
   * 为什么不是"翻页了再报"：Reels 要的是**灵敏**（需求："手指开始滑动时就收缩"），所以挂在
   * Swiper 的 `onTouch` 上 —— 第一次 Move 一到就报（那一下一定早于翻页动画），
   * 而且**同一次触摸只报一次**（`swipeReported`）。
   */
  onReelSwipe: () => void = (): void => {
  };
  /**
   * 这一次触摸有没有已经报过"开始滑动"。
   *
   * Down 归零、Move 报一次、抬手后置真：一次触摸只报一次，拖拽过程中不会每帧都回调。
   */
  private swipeReported: boolean = false;
  /**
   * 上一次报过"滑动"的条数（`onChange` 那条兜底路径用，见 onChange）。
   *
   * 兜底的作用：万一某次翻页没走到 `onTouch` 的 Move（比如非触摸方式换页），翻页本身也应该
   * 把栏沉下去。用条数变化判断"真的翻页了"，恢复位置时也对齐，免得一进页面就被算成翻页。
   */
  private lastReportedIndex: number = 0;

  /**
   * Swiper 上的触摸：手指一动就报"开始滑动"。
   *
   * 为什么不直接用 `onContentDidScroll`：那个回调在**程序化定位**（切 tab 回来时
   * `changeIndex(activeIndex, false)`）时也会触发，会把"刚进页面"当成一次滑动、栏一进来
   * 就沉下去。挂在 `onTouch` 上就天然只有真实手指会触发。
   */
  private onSwiperTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.swipeReported = false;
      return;
    }
    if (event.type === TouchType.Move) {
      if (!this.swipeReported) {
        this.swipeReported = true;
        this.onReelSwipe();
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // 抬手：这一次触摸的额度用完（下一次 Down 会重新放开）。
      this.swipeReported = true;
    }
  }

  aboutToAppear(): void {
    // 屏幕宽度：正文折叠要按"可用宽度"量行数（见 ReelOverlay.captionPrefix），量不到就不截断。
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(dsp.width);
    } catch (error) {
      this.screenWidthVp = FALLBACK_WIDTH_VP;
    }
    this.vm.onReels = (reels: Array<Reel>, hasMore: boolean): void => {
      this.reels = reels;
      // 列表一变（首屏到位 / 又接了一页）就重报一次：标题栏那两颗按钮的状态跟着它走。
      this.publishAction();
      this.logCurrent();
    };
    this.vm.onBusy = (busy: boolean): void => {
      this.busy = busy;
    };
    this.vm.onStatus = (text: string): void => {
      this.status = text;
    };
    // 回填已有数据：**已经有内容就直接用，不重拉首屏** —— 重拉会把列表缩回第一页、
    // 把当前播放位置顶掉，用户看到的就是"同一批视频又从头来一遍"。
    // 只有空列表（首次进入 / 上次失败）才去拉。
    const cached: Array<Reel> = this.vm.list();
    if (cached.length > 0) {
      this.reels = cached;
      // 连"看到第几条"一起恢复：切 tab 会重建这个组件，@State 会归零，
      // 不恢复的话每次切回来都从第一条重新开始（视图模型记着它，见 ReelsViewModel.activeIndex）。
      const resume: number = this.vm.activeIndex();
      this.activeIndex = resume < cached.length ? resume : 0;
      // 恢复位置时"落定页"就是它（见 settledIndex，审计 B1）。
      this.settledIndex = this.activeIndex;
      this.initialIndex = this.activeIndex;
      // "上一次报过的条数"跟着恢复位置对齐：onAppear 里那次无动画定位（changeIndex）也会报
      // onChange，不对齐的话会被当成一次翻页、底栏一进页面就沉下去。
      this.lastReportedIndex = this.activeIndex;
      this.status = '';
      // **回填这条路径也必须重报一次**：切 tab 回来走的就是这里（视图模型里已经有数据了），
      // 少了这一句，标题栏那两颗按钮在"切走再切回来"之后会消失 —— 因为 publish 只在
      // loadFirst 成功后才被调用过（真机验证过这个坑）。
      this.publishAction();
      return;
    }
    this.vm.loadFirst()
      .then((): void => {
        this.syncFromVm();
      })
      .catch((): void => {
      });
  }

  aboutToDisappear(): void {
    // 离开页面要停播：不然声音会继续（视频在别处播放）。
    // 不用自己 stop 播放器了 —— 每个视频都有自己的 VideoSurface，组件销毁时它会 release
    // （arkui 的 VideoController 已经不用了，这里以前那句 this.controller.stop() 是历史遗留）。
    /*
     * **把挂在视图模型上的回调摘掉**（审计发现：这里是空实现）。
     *
     * `vm` 是宿主（`Index`）长期持有的字段，而 `aboutToAppear` 往它上面挂了三个闭包，闭包里写的
     * 都是本组件的 `@State`（`reels/busy/status`）。页面销毁后 VM 的异步回调（翻页、取数回来）
     * 仍会执行这些闭包 → 写已卸载组件的状态；`this.reels = …` 这类整体替换还可能连带触发
     * `publishAction`/`logCurrent` 去碰已经放掉的资源。销毁时换成空实现即可。
     */
    this.vm.onReels = (reels: Array<Reel>, hasMore: boolean): void => {
    };
    this.vm.onBusy = (busy: boolean): void => {
    };
    this.vm.onStatus = (text: string): void => {
    };
  }

  /**
   * 切到第 index 条（onAnimationStart 和 onChange 都走这里，重复调用会被去重）。
   *
   * 三件事：换 activeIndex（决定哪条在播，见 reelPage 的 playing 参数）、
   * 把封面重新盖上（新那条首帧还没出来）、记进视图模型（切 tab 回来能恢复位置）。
   *
   * 信息层不用在这里同步：它是**每条自己的组件**（见 ReelOverlay），Swiper 换页天然就换了
   * 那一层 —— 这正是"数据显示固定在第一条"的修法。
   */
  private switchTo(index: number): void {
    if (index < 0 || index >= this.reels.length || index === this.activeIndex) {
      return;
    }
    this.activeIndex = index;
    // 换条了：新的播放器首帧还没出来，封面叠层要重新盖上（见 reelPage）。
    this.videoReady = false;
    /*
     * **切条时把上一条的"双击爱心"清掉**（审计 B2）。
     *
     * 爱心是整页一个节点（`REELS_BURST_KEY` 常量），动画与它的清理定时器都挂在 `burst` 上：
     * 不在这里清的话，上一条的爱心会**闪在新这条上**（切页那一瞬还能看到）。
     * 清 key 就是让节点消失（见 `LikeBurstState.key` 的说明）。
     */
    this.burst.key = '';
    // 标题栏那两颗按钮（下载/静音）跟着换到当前这条的原视频地址。
    this.publishAction();
    this.logCurrent();
    // 记进视图模型：切 tab 会重建这个组件，位置要能恢复（见 ReelsViewModel.activeIndex）。
    this.vm.setActiveIndex(index);
    // 快到底了就预取下一页，等真滑到底时通常已经接上。
    if (index >= this.reels.length - PREFETCH_DISTANCE) {
      this.vm.requestMore();
    }
  }

  /** 从视图模型回读（不依赖回调时序，见 ProfilePage 里同一个坑）。 */
  private syncFromVm(): void {
    const list: Array<Reel> = this.vm.list();
    if (list.length > 0) {
      this.reels = list;
      // 首屏铺完数据也要报一次：这时 activeIndex 可能没变（switchTo 不会被触发），
      // 但"有可播的视频了"这件事变了，标题栏那两颗按钮要跟着出现。
      this.publishAction();
      this.logCurrent();
    }
    this.busy = this.vm.isBusy();
  }

  /**
   * 把"当前这条"报给 HdsNavigation 标题栏（见 core/ReelsAction）。
   *
   * 下载用的是**原视频**地址（Reel.originalVideoUrl）：展示用的那份已经降到 1080 档省流量了。
   */
  private publishAction(): void {
    const reel: Reel | null = this.current();
    if (reel === null || !reel.playable()) {
      ReelsAction.publish(this.source, false, '', '');
      return;
    }
    // 原始地址拿不到时退回展示地址：宁可能下到 1080 档，也别让按钮点了没反应。
    const original: string = reel.originalVideoUrl.length > 0 ? reel.originalVideoUrl : reel.videoUrl;
    ReelsAction.publish(this.source, true, original, reel.shortcode);
  }

  /**
   * 诊断一行：当前这条是谁、几个关键字段有没有拿到。
   *
   * "关注按钮没出现" / "点赞点了没反应" 这类问题看这行就知道是不是数据本身缺
   * （作者 id、媒体 id 拿不到时对应的按钮会降级，见 model/Reel）。
   */
  private logCurrent(): void {
    const reel: Reel | null = this.current();
    if (reel === null) {
      return;
    }
    hilog.debug(DOMAIN, TAG,
      'reel action code=%{public}s author=%{public}s uid=%{public}s mid=%{public}d liked=%{public}s cap=%{public}d',
      reel.shortcode, reel.author, reel.authorId, reel.mediaId.length, `${reel.liked}`,
      reel.caption.length);
  }

  /** 当前这条。 */
  private current(): Reel | null {
    if (this.activeIndex < 0 || this.activeIndex >= this.reels.length) {
      return null;
    }
    return this.reels[this.activeIndex];
  }

  /** 已经打过"这条视频的比例是多少"日志的键（诊断用，见 videoAspect）。 */
  private aspectLogged: Array<string> = [];

  /**
   * **Swiper 真正落定**的那一页（`onChange`/`onAnimationEnd` 里更新）。
   *
   * 和 `activeIndex` 的区别：后者在 `onAnimationStart` 就提前切了（为了让新页面在转场期间起播），
   * 转场途中它指向的是"即将到来"的那条。双击点赞要用这个"落定"的下标（见 doubleTapLike，审计 B1）。
   */
  private settledIndex: number = 0;

  /**
   * 一条视频的画面比例（宽 ÷ 高）。
   *
   * 需求："视频填充逻辑用视频宽度按比例填满" —— 也就是画面**宽度永远占满屏幕宽**，
   * 高度按视频自己的比例算。接口给了 `original_width/height`（见 model/Reel），
   * 所以这里能算准；拿不到尺寸的视频退回 9:16（短视频最常见的比例）。
   */
  private videoAspect(reel: Reel): number {
    const w: number = reel.width;
    const h: number = reel.height;
    /*
     * 诊断：**比例不对时唯一能查的就是这两个数**。
     *
     * 每条只打一次（键是 code）：如果某条视频比例明显不对，这一行会告诉我们它是
     * "接口没给尺寸（走了 9:16 兜底）"还是"给了但给反了/给的是封面图的尺寸"。
     */
    const key: string = `${w}x${h}`;
    if (this.aspectLogged.indexOf(key) < 0) {
      this.aspectLogged.push(key);
      hilog.info(DOMAIN, TAG, 'reel aspect code=%{public}s w=%{public}d h=%{public}d ratio=%{public}s',
        key, w, h, (w > 0 && h > 0 ? (w / h) : 9 / 16).toFixed(3));
    }
    if (w > 0 && h > 0) {
      return w / h;
    }
    return 9 / 16;
  }

  /**
   * 一页 = 画面 + **这一条自己的信息层**。
   *
   * 两块都在页内（不是浮在 Swiper 上）：画面那条理由见 ReelSlide 的说明，信息层那条见
   * ReelOverlay 的文件头（数据归属 + 手势）。
   */
  @Builder
  reelPage(reel: Reel, index: number) {
    Stack({ alignContent: Alignment.Center }) {
      // 画面盒子：**宽度铺满 + 高度按视频比例**，居中放在全屏背景上。
      //
      // 为什么这样做（而不是让播放器整屏 Cover）：Cover 是按"两个方向都要铺满"去裁的 ——
      // 9:16 的视频放到 19.5:9 的屏幕上，它会按**高度**放大，于是左右被裁掉一截；
      // 需求要的是按**宽度**铺满、高度按比例。所以盒子自己就按视频比例算高：
      //   高 ≤ 屏高（横屏/方形视频）→ 上下留背景，画面完整；
      //   高 >  屏高（竖屏视频）→ 上下超出屏幕，由外层裁掉（宽度仍然一丝不差地铺满）。
      Stack({ alignContent: Alignment.Center }) {
        /*
         * 画面（封面 + 播放器 + 首帧叠层）交给子组件，理由只有一个但很硬：
         * **视频地址可能是后补的**（个人主页的视频分页先给封面，进到这一页才去取，见
         * ProfileReelsViewModel）。子组件用 `@ObjectLink` 订阅这条 Reel，补到地址那一刻
         * 就地重绘、把播放器挂上；写在父组件的 @Builder 里则不行 —— ForEach 对键没变的项
         * 不会重跑 item builder，父组件这边的判断永远看到"还不能播"。
         */
        ReelSlide({
          reel: reel,
          playing: index === this.activeIndex,
          // 预加载下一条：一直开着（原先按网络开关过，实测会影响切换观感；
          // 播放器的预下载缓冲已经收到 2 秒，这一项的开销有界）。
          preload: index === this.activeIndex + 1,
          // 静音开关是全局的（媒体区那颗喇叭键），见 AppSettings.SETTING_VIDEO_MUTED。
          muted: this.videoMuted,
          onFirstFrame: (): void => {
            // 首帧已在表面上：撤封面（这一下就是"封面直切画面"）。
            this.videoReady = true;
            // 画面真的出来了 = 这一条现在**可下载**了，把标题栏那两颗按钮（静音/下载）刷出来。
            // 为什么放在这儿而不是只在 switchTo 里报：个人主页的视频分页那条查询**先只给封面**，
            // 地址是后来补上的（见 ProfileReelsViewModel / NativeMediaInfo）—— 补上之前 publish
            // 只能报 visible=false，补上之后若没人再报一次，标题栏那两颗按钮就永远不出现。
            this.publishAction();
          }
        })
      }
      .width('100%')
      .aspectRatio(this.videoAspect(reel))
      // 竖屏视频（高 > 屏高）超出的部分在这里被裁掉，而不是把它压扁。
      .clip(true)

      /*
       * 信息层（作者行 / 关注按钮 / 正文 / 动作区）：**每条一个**，整页大小。
       *
       * 需求说这一层 UI "只涵盖用户资讯组件 / 关注按钮 / 正文 / 动作区" —— 音乐名与状态行都
       * 不画（状态仍由"列表为空"那一支整屏显示，见 build 开头）。
       */
      ReelOverlay({
        reel: reel,
        ownAuthor: this.ownAuthor,
        screenWidthVp: this.screenWidthVp,
        // 动作区 / 资讯区跟着底栏下沉（外壳那页传得进来，整屏页是 0，见 overlaySink）。
        overlaySink: this.overlaySink,
        // 当前这条才去单独问关注状态（见 ReelOverlay.ensureFollowState）。
        active: index === this.activeIndex,
        onLike: this.onLike,
        onRepost: this.onRepost,
        onSave: this.onSave,
        onFollow: this.onFollow,
        onOpenUser: this.onOpenUser,
        onComments: this.onComments,
        onShare: this.onShare,
        onMore: this.onMore,
        // 正文翻译失败：交给外壳那页弹提示（见 ReelsPage.onTranslateFailed）。
        onTranslateFailed: this.onTranslateFailed
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.reels.length === 0) {
        Column({ space: 10 }) {
          if (this.busy) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color($r('app.color.secondary_text'))
          }
          Text(this.status.length > 0 ? this.status : $r('app.string.reels_loading'))
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Swiper(this.swiperController) {
          ForEach(this.reels, (reel: Reel, index: number): void => {
            this.reelPage(reel, index)
          }, (reel: Reel, index: number): string => `${index}-${reel.shortcode}`)
        }
        .width('100%')
        .height('100%')
        .vertical(true)
        .loop(false)
        .indicator(false)
        // 预加载窗口：**2 而不是 1**。VideoSurface 的预加载要先把下一条的 XComponent 布局出来
        // （表面是 XComponent onLoad 给的，没有它就 prepare 不了，见 VideoSurface 的说明），
        // cachedCount=1 时下一条常常要等页开始动才布局，预加载就白等了。
        .cachedCount(2)
        // 曲线 + 时长成对给：弹簧曲线的时长是固定的（约 560ms），只改 duration 没用（见 SWITCH_ANIM_MS）。
        // Ease（快出慢收）在"跟手"这件事上比 Linear 自然：手指离屏时速度最大，收尾平滑落定。
        .curve(Curve.Ease)
        .duration(SWITCH_ANIM_MS)
        // 起始页 = 上次看到的那一条。**必须绑一个不会变的值**（initialIndex，不是 activeIndex）：
        // #State 一变就重新求值 → Swiper 立刻跳页 → 翻页动画被掐断（详见 initialIndex 的说明）。
        .index(this.initialIndex)
        .onAppear((): void => {
          // 重建后把位置再摆正一次：`.index()` 是在构建时求值的，配合控制器更稳。
          if (this.activeIndex > 0) {
            try {
              this.swiperController.changeIndex(this.activeIndex, false);
            } catch (error) {
            }
          }
        })
        // 官方《短视频》实践：**动画开始就切索引**，而不是等动画结束。
        // 这样新那条在转场动画期间就开始准备/起播，动画结束时画面已经在了（观感就是"跟着手走"）。
        // 我们这里更值一提：新页面的 VideoSurface 是动画开始后才被布局出来的（表面此刻才 onLoad），
        // 提前切索引能让 prepare 早 200ms 左右开始。
        .onAnimationStart((index: number, targetIndex: number): void => {
          this.animationStartedMs = Date.now();
          this.switchTo(targetIndex);
        })
        // onChange 还会再报一次，switchTo 里做了去重，重复调用无害。
        // 注意它**不是**动画结束：实测 onAnimationStart → onChange 只有十几毫秒
        // （索引一改就回调），所以"动画到底多慢"必须看下面的 onAnimationEnd。
        .onChange((index: number): void => {
          const before: number = this.lastReportedIndex;
          // 落定页以 onChange 为准（见 settledIndex 的说明，审计 B1）。
          this.settledIndex = index;
          this.switchTo(index);
          // 兜底：真的翻页了也报一次"滑动"（正常路径在 onTouch 的第一次 Move 已经报过，
          // 这里重复一次是无害的 —— 页面那边"已经沉着"就直接返回）。
          if (index !== before) {
            this.lastReportedIndex = index;
            this.onReelSwipe();
          }
        })
        // 手指一动就报（需求："手指开始滑动时就收缩"，见 onSwiperTouch）。
        .onTouch((event: TouchEvent): void => {
          this.onSwiperTouch(event);
        })
        // 把一次切换动画的真实时长量出来：Swiper 的 duration 只在**非弹簧曲线**下生效
        // （默认是弹簧插值曲线，时长由弹簧参数决定），所以调快调慢要靠这个数字确认，
        // 不能只看代码里写的那个值。
        .onAnimationEnd((index: number, event: SwiperAnimationEvent): void => {
          if (this.animationStartedMs > 0) {
            hilog.info(DOMAIN, TAG, 'switch animation %{public}dms -> index=%{public}d',
              Date.now() - this.animationStartedMs, index);
            this.animationStartedMs = 0;
          }
        })
      }

      // **双击屏幕点赞**（需求："双击屏幕点赞实现一下" + "跟手动画"）：
      // 爱心就炸在双击的位置上（`localX/localY` 就是相对这个整屏 Stack 的 vp 坐标），
      // 而且点下去立刻出现（不等那发 HTTP 回来）。
      //
      // 为什么用 parallelGesture：Swiper 自己要用竖向拖动（翻页）、动作区那些材质按钮各自
      // 还有 PanGesture（四象锁定）—— 串行的 gesture 会被它们吃掉，双击就没反应了。
      LikeBurst({ state: this.burst, itemKey: REELS_BURST_KEY })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .parallelGesture(
      // distanceThreshold 同信息流：不设的话默认"手指没划出组件就算一次点击"，
      // 快速上下滑两下会被凑成一次双击、直接点赞（见 FeedList 的 LIKE_TAP_DISTANCE_VP）。
      TapGesture({ count: 2, distanceThreshold: DOUBLE_TAP_DISTANCE_VP })
        .onAction((event: GestureEvent): void => {
          const fingers: Array<FingerInfo> = event.fingerList;
          const x: number = fingers.length > 0 ? fingers[0].localX : -1;
          const y: number = fingers.length > 0 ? fingers[0].localY : -1;
          playLikeBurst(this.burst, REELS_BURST_KEY, x, y);
          this.doubleTapLike();
        })
    )
  }

  /**
   * 双击点赞：**只点赞、不取消**（IG 的行为，也是"双击"这个手势的语义）。
   *
   * 已经赞过就什么都不做（不再发请求）。点赞本身仍走 tapLike 那套乐观 + 回滚。
   */
  private doubleTapLike(): void {
    /*
     * **双击点赞以"落定那一条"为准，不用 `activeIndex`**（审计 B1）。
     *
     * `onAnimationStart` 会把 `activeIndex` **提前**切到目标条（那是为了新页面在转场期间就起播），
     * 但画面这时还停在旧页 —— 这个窗口里双击，`current()` 已经是新那条了，赞就落在**用户没在看**
     * 的视频上。`settledIndex` 只在 Swiper 的 `onChange`/`onAnimationEnd` 里更新，代表真正落定的页。
     */
    const settled: number = this.settledIndex >= 0 && this.settledIndex < this.reels.length
      ? this.settledIndex : this.activeIndex;
    const reel: Reel | null = settled >= 0 && settled < this.reels.length
      ? this.reels[settled] : null;
    if (reel === null || reel.liked) {
      return;
    }
    if (reel.mediaId.length === 0) {
      hilog.info(DOMAIN, TAG, 'double tap like ignored (no media id) code=%{public}s',
        reel.shortcode);
      return;
    }
    hilog.info(DOMAIN, TAG, 'reel double tap like code=%{public}s', reel.shortcode);
    commitReelLike(reel, true, this.onLike);
  }
}
