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
// 触摸探针（排查为什么手势收不到事件，见 core/TouchProbe）。
import { TouchProbe } from '../core/TouchProbe';
import { Reel, ReelStreamVm } from '../model/Reel';
import { ReelsViewModel } from '../viewmodel/ReelsViewModel';
import { VideoSurface } from './VideoSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS, SETTING_VIDEO_MUTED } from '../core/AppSettings';
import { ReelsAction } from '../core/ReelsAction';
import {
  MaterialIconButton, MaterialLabelButton, SurfaceModifier
} from './MaterialSurface';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { SaveState } from '../core/SaveState';
import { NativeFollow } from '../core/NativeFollow';
import { ReelSeenTime } from '../core/ReelSeenTime';
import { LikeBurst, LikeBurstState, playLikeBurst } from './AnimatedIcons';
import {
  CAPTION_TAIL_SAFETY_VP, CaptionFit
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
/**
 * **Reels 正文折叠成一行**（需求："正文限制到一行，'… 展开'也要在这一行里"）。
 *
 * 为什么不直接把 core/CaptionFit 里的 `CAPTION_COLLAPSED_MAX_LINES` 改成 1：那是信息流卡片
 * 和这一页**共用**的判据（同一个人的同一段正文在两处折行要一致），信息流那边仍然是两行。
 * 所以"这次只有 Reels 收成一行"这件事用参数传下去（见 captionPrefix / prefixOfText）。
 */
const CAPTION_MAX_LINES: number = 1;
/**
 * 折叠态正文**结尾那颗省略号**（需求："折叠态正文 = 第一行内容裁掉尾部空白，然后接 ' ...'"）。
 *
 * 它**不再是"展开"的入口**（展开/收起那一套已经整块删掉）：Reels 正文没有展开态，
 * 点它和点正文一样 —— 打开这一条的评论面板（面板里带那张帖子卡片，见 PostCardPanel）。
 * 为什么连短正文也画：它表达的是"这里还有一张帖子卡片可以看"，不是"字被截断了"。
 */
const CAPTION_TAIL: string = ' ...';
/**
 * **压在画面上的文字阴影**（正文 / 动作区计数共用）。
 *
 * 为什么用阴影而不是反色：反色要靠采样画面亮度（`componentSnapshot` 拍不到视频表面，
 * 结论永远是「暗底」，实测无效果，那段代码已删）；阴影是纯渲染属性，
 * 白字在亮画面上靠它压出边界，暗画面上又几乎看不见 —— 一种实现同时兼顾两种底。
 * 半径 6 / 下移 1 / 60% 黑：够托住字，又不至于糊成一圈光晕。
 */
const OVERLAY_TEXT_SHADOW: ShadowOptions = {
  radius: 6, color: '#99000000', offsetX: 0, offsetY: 1
};
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
 * 所以留得比它高一些，两者不打架。
 *
 * **右侧动作区读的是同一个值**（见 ReelOverlay.build）：两块都是钉在底部的浮层，底白一致，
 * 底边才会落在同一条线上（需求："正文区底边高度与动作区底边高度统一"）。
 */
const INFO_BOTTOM: number = 112;

/**
 * **全局控件（chrome）现在藏起来了没有** —— 整个 app 共用一个 AppStorage 键。
 *
 * 需求："单击画面之外（左右留白 / 上下模糊带 / HDS 标题栏）隐藏全局控件，再点恢复"，并且
 * "隐藏后是**所有视频**的信息层一起消失，标题栏与底栏也一起藏"。
 *
 * 为什么要跨组件用一个键、而不是各层自己记一份：
 *   · 信息层是**每条一个**的组件（ReelOverlay，在 ForEach 里）—— 键没变的项不会重跑 item
 *     builder，父组件的 @Prop 传不到已经建好的那几条（本项目反复踩过），只有
 *     `@StorageLink/@StorageProp` 这种**组件级订阅**能让**所有**已建好的信息层一起动；
 *   · 标题栏（HdsNavigation）与底栏（HdsTabs）根本不在 ReelsPage 里，它们的宿主是 pages/Index
 *     —— 一个 AppStorage 键是把"这一层按了什么"告诉外壳最省事的通道（见 Index 里的订阅）。
 *
 * 命名/取值和 `reels_frozen_all` / `reels_active_segment` 同一套（那两个也是 AppStorage 键，
 * 见 VideoSurface 的说明）：字符串常量写在一处，别的地方 import 它，避免打错字导致"点了没反应"。
 */
export const REELS_CHROME_HIDDEN: string = 'reels_chrome_hidden';

/**
 * 控件淡出/淡入时长（毫秒）。
 *
 * 180ms：比翻页动画（480ms）短、比系统按压反馈（~100ms）长 —— 感觉得到"收起来了"，
 * 又不会让隐藏这个动作本身变成一次等待。两条位移（CHROME_SHIFT_VP）纯粹是"顺手一起缩"。
 */
const CHROME_FADE_MS: number = 180;
/** 控件隐藏时整块往下缩的距离（vp，轻微位移，见 CHROME_FADE_MS）。 */
const CHROME_SHIFT_VP: number = 14;

/** 置中那颗"暂停/继续"按钮的直径与图标尺寸（vp，需求：约 64vp）。 */
const PAUSE_BUTTON_SIZE: number = 64;
const PAUSE_ICON_SIZE: number = 26;
/** 暂停按钮淡入淡出时长（毫秒，需求：约 150ms）。 */
const PAUSE_FADE_MS: number = 150;

/**
 * 卡片内那条**进度条**的几何与配色（需求："画在视频卡片内部顶部，一条粗直线，不可拖动"）。
 *
 * 位置在卡片内顶部再留 GAP：贴边会跟着卡片圆角被裁掉两头，看着像"断了一截"；
 * 左右也各留 PAD，理由相同（圆角把内宽吃掉了）。高度 3vp 是"看得出来、又不喧宾夺主"的一档。
 */
const PROGRESS_TOP_GAP: number = 10;
const PROGRESS_HEIGHT: number = 5;
const PROGRESS_SIDE_PAD: number = 14;
/** 轨道底色（半透明白）与已播放色（实白）—— 压在任意画面上都读得出来。 */
const PROGRESS_TRACK_COLOR: string = '#4DFFFFFF';
const PROGRESS_FILL_COLOR: string = '#FFFFFFFF';

/** 2 倍速胶囊：离进度条下方多远、高度、宽度、字号（vp）。 */
const SPEED_PILL_GAP: number = 8;
const SPEED_PILL_HEIGHT: number = 26;
const SPEED_PILL_WIDTH: number = 58;
const SPEED_PILL_FONT: number = 13;
/** 胶囊上的文案（需求："显示胶囊「2.0x」"）。 */
const SPEED_PILL_TEXT: string = '2.0x';
/** 2 倍速的倍率（见 VideoSurface.speed）。 */
const SPEED_2X: number = 2;

/**
 * 单击视频画面（暂停/播放）允许的手指位移（vp）。
 *
 * 和双击点赞同一个口径（DOUBLE_TAP_DISTANCE_VP 的两倍不到）：手指稍微动一下仍然算"点"，
 * 但一旦超过它就不再算点击 —— 那是在滑页（竖向）或者拖进度条（横向）。
 */
const VIDEO_TAP_DISTANCE_VP: number = 10;
/** 横向拖动要走出这么远才算"拖进度条"（vp）：太小会和"点击"抢，太大又会觉得拖不动。 */
const SEEK_PAN_DISTANCE_VP: number = 12;
/**
 * 单击"暂停/继续"的**生效延迟**（毫秒）。
 *
 * 为什么不是点下去立刻生效：这一页上还有"双击点赞"（ReelsPage 根节点的 parallelGesture）。
 * 单击若立刻切播放状态，双击点赞会顺手把视频暂停（第一下暂停、第二下又恢复，中间一卡；
 * 慢一点的双击就干脆停在暂停上）。所以第一下先挂一个短定时器，等到这段时间内没有第二下
 * 才真的切 —— 有第二下就当作双击，这一下不动播放状态（见 onVideoTap）。
 * 240ms：接近系统双击判定窗口，手感上"点了就响应"，又不会把两次独立的快速点击吃掉太多。
 */
const SINGLE_TAP_DELAY_MS: number = 240;

/**
 * 长按的两个时长（毫秒）：中间 = 暂停 + 隐藏控件；两侧 = 2 倍速。
 *
 * 为什么中间给 400、两侧给 300：两侧的 2 倍速是"持续按住"的临时状态（松手就还原），
 * 越灵敏越好；中间那条要停播 + 藏控件，是"有副作用"的动作，长一点更不容易误触。
 * 两者**靠热区区分**（见 SPEED_ZONE_RATIO），不靠时长区分。
 */
const LONG_PRESS_CENTER_MS: number = 400;
/** 原生触摸判"长按"的门槛（毫秒）与"划走就不算长按"的门槛（见 onRawTouch）。 */
const RAW_LONG_PRESS_MS: number = 400;
const RAW_MOVE_CANCEL_MS: number = 260;
const LONG_PRESS_SIDE_MS: number = 300;
/**
 * 两侧长按热区各占屏宽的比例（需求："左右两侧各占屏宽约 30%，中间 40% 仍归第 5 条"）。
 */
const SPEED_ZONE_RATIO: number = 0.3;

/**
 * **信息层护栏**：手指落在这两条带子里时，我们不再处理"单击暂停/长按"。
 *
 * 为什么需要：信息层（作者行 / 正文 / 动作栏）是 `HitTestMode.Transparent` 盖在画面上的
 * （不加 Transparent 竖向翻页就没了，见 ReelOverlay 类头第 2 条），于是"点个赞"这一次点击
 * **画面这层也会收到**。不挡掉的话点个赞顺手把视频暂停了（StoryViewer 里同一类问题的注释
 * 就是"加了 Transparent，点关注会同时翻一条"）。
 * 判据只能按**几何**来（两层是兄弟，拿不到"谁吃掉了这次点击"），所以把这两块的位置写死：
 * 右侧动作栏一条（宽 = 栏宽 + 右边距 + 一点余量）、底部资讯区一条（高 = 底部留白 + 两行文字）。
 * 控件已经藏起来时这两块不存在，所以那时也不护栏（见 overOverlay 的第一行）。
 */
const OVERLAY_GUARD_RIGHT_VP: number = ACTION_COLUMN_WIDTH + ACTION_RIGHT_PADDING + 12;
const OVERLAY_GUARD_EXTRA_VP: number = 96;


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
  /**
   * 现在是这一条在播吗。
   *
   * 父组件给的是"这一页是不是当前页"，**不含**本组件自己的暂停/长按态（那两个是下面的
   * userPaused / holdPaused）—— 这样"用户手动暂停"不会把播放器从树上摘掉（摘掉就黑一下，
   * 见 VideoSurface 类头）。
   */
  @Prop @Watch('onPlayingChanged') playing: boolean = false;
  /** 本页所属分段（0 = 探索 / 1 = 关注 / -1 = 独立页），原样转给播放器做全局播放闸门。 */
  segment: number = -1;
  /** 提前 prepare 下一条。 */
  @Prop preload: boolean = false;
  /** 静音（全局开关）。 */
  @Prop muted: boolean = false;
  /**
   * 屏幕宽 / 高（vp）：**只**用来算"这一下手势落在画面的左中右哪一档、有没有压在信息层上"
   * （见 overOverlay 与 onHoldStart）。画面本身不用它 —— 宽度来自布局（100%）。
   *
   * 为什么本组件自己量、而不让 ReelsPage 传下来（原来是 @Prop）：ReelSlide 在 ForEach 里，
   * 而"@Prop 的变化穿不过 ForEach"是本项目反复踩到的坑（见类头）；ReelsPage 的
   * `screenWidthVp` 是 `aboutToAppear` 里才写进去的，@Prop 传下来有可能永远停在兜底值上，
   * 于是"中间 40% / 两侧 30%"会按错的屏宽算。自己量一次就没有这个问题（display 是同步接口）。
   */
  @State private screenW: number = FALLBACK_WIDTH_VP;
  @State private screenH: number = 780;
  /** 画面自己在布局里的实际宽度（vp），拖动进度按它换算比例（见 cardWidthVp）。 */
  @State private measuredWidthVp: number = 0;
  /** 信息层底部留白 + 护栏余量（vp，见 OVERLAY_GUARD_EXTRA_VP 与 overOverlay）。 */
  @Prop overlayGuardBottomVp: number = INFO_BOTTOM + OVERLAY_GUARD_EXTRA_VP;
  /**
   * **全局控件藏起来了没有**（见 REELS_CHROME_HIDDEN）。
   *
   * 本组件只用它一件事：控件藏着的时候信息层不存在，于是"压在信息层上"的护栏要一起失效
   * （否则藏起来之后点屏幕底部那一条会什么都不发生，见 overOverlay）。
   */
  @StorageProp(REELS_CHROME_HIDDEN) chromeHidden: boolean = false;
  /** 首帧上屏时通知父组件（父组件拿它决定整页的封面叠层，见 ReelsPage.videoReady）。 */
  onFirstFrame: () => void = (): void => {
  };
  /** 这一条的首帧出来了没有（没出来时封面压在上面，避免黑闪）。 */
  @State private ready: boolean = false;
  /**
   * **播放器量到的真实视频比例**（宽/高；0 = 还没量到）。
   *
   * 为什么需要：接口给的宽高不一定是**视频**的 —— 搜索推荐流那批 `SearchPost` 的宽高是
   * **封面图**的（见 model/Search 的头注释）。16:9 的视频配上 4:5 的封面尺寸，外层盒子就是竖的，
   * 视频于是被竖向拉伸（用户报的就是这个）。播放器 prepared 时会回调真实尺寸
   * （见 VideoSurface.onVideoSize），这里据此把画面盒子改回视频自己的比例。
   */
  @State private measuredAspect: number = 0;

  // ==========================================================================
  // 视频手势与控制条（这一次新增）的状态
  //
  // 为什么这些状态放在**画面**这个组件里，而不是放在 ReelsPage：
  //   · 它们全是"这一条视频自己的"（播到哪儿、用户暂停了没有、是不是在 2 倍速）；
  //   · 它们由**画面上**的手势驱动，而画面就是本组件（卡片内部），放这里手势、状态、
  //     控制条三者同一个节点树，不用跨组件传；
  //   · 进度只能由播放器报上来（VideoSurface.onProgress），播放器也在这里 —— 少一层转发
  //     就少一次"@Prop 穿不过 ForEach"的机会（参见类头对本项目那个坑的说明）。
  // ==========================================================================

  /** 播放进度 0..1（播放器报的，见 VideoSurface.onProgress）。 */
  @State private progress: number = 0;
  /** 正在拖进度条（拖动期间进度条显示 dragProgress，且**不改**播放位置）。 */
  @State private dragging: boolean = false;
  /** 拖动中的预览进度 0..1（松手才真的 seek，见 onSeekEnd）。 */
  @State private dragProgress: number = 0;
  /** 用户单击画面把这一条暂停了（再点一下继续）。 */
  @State private userPaused: boolean = false;
  /** 长按左右两侧：临时 2 倍速（松手回 1 倍速）。 */
  @State private speedBoost: boolean = false;
  /** 长按中间：临时暂停（松手恢复原状态），同时全局控件被藏起来。 */
  @State private holdPaused: boolean = false;
  /** 拖动开始那一刻的进度（seek 的基线，见 onSeekMove）。 */
  private baseProgress: number = 0;
  /** 播放器报上来的总时长（毫秒；0 = 还不知道，此时拖动不生效）。 */
  private durationMs: number = 0;
  /** 最近一次请求的跳转位置（毫秒；-1 = 还没请求过）—— 写进 VideoSurface.seekMs。 */
  private seekMs: number = -1;
  /**
   * 这一下触摸已经被哪条长按占用了（'' = 没有 / 'pause' / 'speed'）。
   *
   * 为什么需要：两条长按（中间 400ms、两侧 300ms）在一个 `GestureGroup(Parallel)` 里，
   * 在两侧按住够久时**两条都会成立** —— 不挡的话 300ms 开始 2 倍速、400ms 又顺手把它暂停
   * 并藏了控件（同一根手指触发两个动作）。这里用"先到先得"排他。
   */
  private longPressMode: string = '';
  /** 这一下触摸里已经有长按成立过 → 抬手时那一次单击要吞掉（见 onVideoTap）。 */
  private longPressFired: boolean = false;
  /** 原生触摸：按下时刻（毫秒）、长按是否已成立、长按定时器句柄（见 onRawTouch）。 */
  private rawDownMs: number = 0;
  private rawHoldFired: boolean = false;
  private rawHoldTimer: number = -1;
  /** 长按中间之前，全局控件本来就是藏着的吗（松手要恢复成"原来那样"，见 onHoldEnd）。 */
  private chromeHiddenBefore: boolean = false;
  /**
   * 单击"暂停/继续"那个延迟窗口的定时器句柄（-1 = 没有在等）。
   *
   * 存句柄而不是裸 `setTimeout`：组件被销毁时（翻页/切标签）定时器还会去写 `@State`，
   * 而且"双击"要靠这个句柄把第一下撤掉（见 onVideoTap / SINGLE_TAP_DELAY_MS）。
   */
  private tapTimer: number = -1;

  /** 画面盒子该用的比例：**实测优先** > 接口给的 > 9:16 兜底。 */
  private aspect(): number {
    if (this.measuredAspect > 0) {
      return this.measuredAspect;
    }
    const w: number = this.reel.width;
    const h: number = this.reel.height;
    return (w > 0 && h > 0) ? w / h : 9 / 16;
  }

  /** 画面（= 卡片内宽）的宽度（vp）：拖动进度时按它把位移换算成比例。 */
  private cardWidthVp(): number {
    if (this.measuredWidthVp > 0) {
      return this.measuredWidthVp;
    }
    // 量不到时按"卡片宽度 = 屏宽 − 32vp"兜底（见 ReelsPage.reelPage 的圆角卡片）。
    const width: number = this.screenW - 32;
    return width > 0 ? width : FALLBACK_WIDTH_VP;
  }

  aboutToAppear(): void {
    // 只量一次：屏幕宽高在翻页过程中不会变，量到就够用了（见 screenW 的说明）。
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      this.screenW = this.getUIContext().px2vp(dsp.width);
      this.screenH = this.getUIContext().px2vp(dsp.height);
    } catch (error) {
      this.screenW = FALLBACK_WIDTH_VP;
    }
  }

  /**
   * 组件销毁：把单击的延迟定时器撤掉。
   *
   * 它 240ms 后会写 `this.userPaused`（见 onVideoTap）—— 翻页/切标签正好落在这个窗口里时，
   * 定时器会去写一个已经卸载的组件（本项目 Audit A3 那批问题里最常见的一种）。
   */
  aboutToDisappear(): void {
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  /** 画面此刻该不该真的在播（父组件说"是当前页" && 用户没暂停 && 不在长按暂停中）。 */
  private wantsPlayNow(): boolean {
    return this.playing && !this.userPaused && !this.holdPaused;
  }

  /** 换条 / 变成当前页：进度归零、临时态清干净（需求："切到下一条视频时进度归零"）。 */
  private onPlayingChanged(): void {
    if (this.playing) {
      this.progress = 0;
      this.dragging = false;
      this.dragProgress = 0;
    }
    /*
     * 长按途中被打断（翻页 / 切段会让 `playing` 变化，此时 onActionEnd 不一定会来）：
     * **先把全局控件恢复回去**，再清临时态 —— 不然"长按藏了控件"就永远藏着了。
     */
    if (this.longPressMode === 'pause') {
      AppStorage.setOrCreate(REELS_CHROME_HIDDEN, this.chromeHiddenBefore);
    }
    // 不再当前 / 刚成为当前：暂停、2 倍速、长按这些临时态都不该跨条保留。
    this.userPaused = false;
    this.speedBoost = false;
    this.holdPaused = false;
    this.longPressMode = '';
  }

  /**
   * 这一下手势的落点是不是压在**信息层**上（作者行 / 正文 / 右侧动作栏）。
   *
   * 见 OVERLAY_GUARD_RIGHT_VP 的说明：那一层是 Transparent，同一次点击会同时传到画面这一层，
   * 所以按几何挡掉两块区域。用**应用窗口坐标**（`globalX/globalY`，FingerInfo 里就是这一档）
   * 而不是组件内坐标：那两块是钉在
   * **屏幕**右边的浮层，用组件坐标还要再加卡片偏移，多一处可能算错的地方。
   * 拿不到坐标时返回 false（宁可响应，也不要"点了没反应"）。
   */
  private overOverlay(fingers: Array<FingerInfo>): boolean {
    if (this.chromeHidden || fingers.length === 0) {
      return false;
    }
    const x: number = fingers[0].globalX;
    const y: number = fingers[0].globalY;
    if (x >= this.screenW - OVERLAY_GUARD_RIGHT_VP) {
      return true;
    }
    return y >= this.screenH - this.overlayGuardBottomVp;
  }

  /** 手势落点相对屏幕宽度的位置（0..1，拿不到坐标按正中算）。 */
  private pointRatioX(fingers: Array<FingerInfo>): number {
    const width: number = this.screenW > 0 ? this.screenW : FALLBACK_WIDTH_VP;
    if (fingers.length === 0) {
      return 0.5;
    }
    const ratio: number = fingers[0].globalX / width;
    return ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
  }

  /**
   * 单击视频画面 → 暂停 / 继续（需求第 3 条）。
   *
   * 为什么用 `GestureGroup(Parallel)` 同时挂 Tap 与两条 LongPress（需求第 5、6 条也在这个区域）：
   *   · 串行（Sequence）不行：长按要求"按住不动 400ms"，串行会把单击排在它后面，单击要等 400ms；
   *   · 互斥（Exclusive）也不行：三条手势里先成立的那条会把别的踢掉，而"单击"和"长按"在
   *     手指抬起那一刻才分得出胜负 —— Exclusive 下长按成立后单击就收不到，看着很正常，
   *     但**长按结束的回调顺序**会变得不可靠（onActionEnd 有时不来），按 StoryViewer 的经验
   *     那样会导致状态卡住；
   *   · Parallel 下三条都会走完自己的判定，于是**必须自己排他**：长按成立时打 `longPressFired`，
   *     抬手时那一次单击据此吞掉（见下）。
   *
   * 另外**单击是延迟生效的**（SINGLE_TAP_DELAY_MS）：这一页还有双击点赞，立刻切播放状态的话
   * 双击会顺手把视频暂停。延迟窗口里来了第二下 = 双击 → 撤掉，不切。
   */
  private onVideoTap(event: GestureEvent): void {
    if (this.longPressFired) {
      // 长按抬手时系统还会补一次单击：吞掉（否则"长按暂停"松手后会立刻又切一次播放态）。
      this.longPressFired = false;
      return;
    }
    // 这一下即使被判定成"双击的第一下"，也要把延迟窗口撤掉（见下面第二下的分支）。
    if (!this.playing || !this.reel.playable() || this.overOverlay(event.fingerList)) {
      if (this.tapTimer >= 0 && !this.playing) {
        clearTimeout(this.tapTimer);
        this.tapTimer = -1;
      }
      return;
    }
    if (this.tapTimer >= 0) {
      /*
       * 第二下到了 → 这一下是**双击**（点赞由 ReelsPage 根节点那个 parallelGesture 负责），
       * 于是把第一下挂起来的定时器撤掉：双击不改变播放状态（见 SINGLE_TAP_DELAY_MS）。
       */
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
      return;
    }
    // 第一下：挂一个短定时器，等到窗口过去还没有第二下才真的切（期间被取消 = 双击）。
    this.tapTimer = setTimeout((): void => {
      this.tapTimer = -1;
      this.userPaused = !this.userPaused;
    }, SINGLE_TAP_DELAY_MS);
  }

  /**
   * 长按开始（`side` = 是不是"两侧"那一条）。
   *
   * 中间 40%：暂停 + 隐藏全局控件；两侧各 30%：2 倍速。热区按**屏宽比例**分（需求）。
   * 已经有一条长按占住这一下触摸就直接返回（见 longPressMode）。
   */
  private onHoldStart(event: GestureEvent, side: boolean): void {
    if (this.longPressMode.length > 0 || !this.playing || !this.reel.playable()) {
      return;
    }
    const fingers: Array<FingerInfo> = event.fingerList;
    if (this.overOverlay(fingers)) {
      return;
    }
    const ratio: number = this.pointRatioX(fingers);
    const inMiddle: boolean = ratio > SPEED_ZONE_RATIO && ratio < 1 - SPEED_ZONE_RATIO;
    if (side) {
      if (inMiddle) {
        // 中间那 40% 归"暂停 + 隐藏控件"（见下面的 else 分支）。
        return;
      }
      this.longPressMode = 'speed';
      this.longPressFired = true;
      this.speedBoost = true;
      hilog.info(DOMAIN, TAG, 'hold side → 2.0x code=%{public}s', this.reel.shortcode);
      return;
    }
    if (!inMiddle) {
      // 两侧归 2 倍速（上面那一条）。
      return;
    }
    this.longPressMode = 'pause';
    this.longPressFired = true;
    const before: boolean | undefined = AppStorage.get<boolean>(REELS_CHROME_HIDDEN);
    this.chromeHiddenBefore = before === undefined ? false : before;
    this.holdPaused = true;
    AppStorage.setOrCreate(REELS_CHROME_HIDDEN, true);
    hilog.info(DOMAIN, TAG, 'hold center → pause + hide chrome code=%{public}s',
      this.reel.shortcode);
  }

  /**
   * 长按结束（抬手 / 被别的手势抢走都走这里）→ **恢复到长按之前的状态**。
   *
   * 两条长按共用这一个收尾：先到先得的那条记在 `longPressMode` 里，第二条进来时它是空串，
   * 什么都不做（幂等，连点两次也不会把状态翻回去）。
   */
  private onHoldEnd(): void {
    const mode: string = this.longPressMode;
    this.longPressMode = '';
    if (mode === 'speed') {
      this.speedBoost = false;
      hilog.info(DOMAIN, TAG, 'hold side released → 1.0x code=%{public}s', this.reel.shortcode);
      return;
    }
    if (mode === 'pause') {
      this.holdPaused = false;
      AppStorage.setOrCreate(REELS_CHROME_HIDDEN, this.chromeHiddenBefore);
      hilog.info(DOMAIN, TAG, 'hold center released → restore code=%{public}s',
        this.reel.shortcode);
    }
  }

  /** 开始横向拖动：记下基线（**此刻**的进度），拖动中只改显示（见 onSeekMove）。 */
  private onSeekStart(): void {
    if (!this.playing || !this.reel.playable() || this.durationMs <= 0) {
      return;
    }
    this.dragging = true;
    this.baseProgress = this.progress;
    this.dragProgress = this.progress;
  }

  /** 拖动中：按位移换算预览进度。**这里不 seek**（需求："松手才生效"）。 */
  private onSeekMove(event: GestureEvent): void {
    if (!this.dragging) {
      return;
    }
    const width: number = this.cardWidthVp();
    const next: number = this.baseProgress + event.offsetX / width;
    this.dragProgress = next < 0 ? 0 : (next > 1 ? 1 : next);
  }

  /**
   * 松手：把预览进度落到播放器上（唯一的 seek 时机）。
   *
   * 时长还拿不到（0）时什么都不做 —— 按比例算不出毫秒，硬算会跳到 0。
   */
  private onSeekEnd(): void {
    if (!this.dragging) {
      return;
    }
    this.dragging = false;
    // 时长还拿不到：按比例算不出毫秒，硬算会跳到 0（见上面的说明）。
    if (this.durationMs <= 0) {
      return;
    }
    const target: number = Math.round(this.dragProgress * this.durationMs);
    // 进度条立刻停在松手的位置（等播放器下一次 timeUpdate 再对齐到真实位置）。
    this.progress = this.dragProgress;
    // 同一个毫秒值重复写不会触发 @Watch，所以这里保证每次都是"新值"：
    // 目标没变时加减 1ms（人眼完全看不出来，但能保证这次拖动一定落到播放器上）。
    this.seekMs = target === this.seekMs ? target + 1 : target;
    hilog.info(DOMAIN, TAG, 'seek %{public}d/%{public}d code=%{public}s',
      target, this.durationMs, this.reel.shortcode);
  }

  /** 拖动被打断（被翻页手势抢走 / 手指出界）：放弃这次拖动，不改播放位置。 */
  /**
   * **原生触摸状态机**（见命中层上的 onTouch 说明）。
   *
   * 只判两件事：单击（暂停/播放）与长按（暂停 + 隐藏全局控件，松手恢复）。
   * 拖动进度的判定仍留给原来的横向手势 —— 两套不冲突：onTouch 只在"没怎么移动"时下结论。
   */
  private onRawTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.rawDownMs = Date.now();
      this.rawHoldFired = false;
      if (this.rawHoldTimer >= 0) {
        clearTimeout(this.rawHoldTimer);
        this.rawHoldTimer = -1;
      }
      this.rawHoldTimer = setTimeout((): void => {
        this.rawHoldTimer = -1;
        this.rawHoldFired = true;
        // 长按：暂停 + 隐藏全局控件（松手在 Up 里恢复）。
        this.holdPaused = true;
        AppStorage.setOrCreate(REELS_CHROME_HIDDEN, true);
      }, RAW_LONG_PRESS_MS);
      return;
    }
    if (event.type === TouchType.Move) {
      // 手指划走了 = 不是长按：撤掉定时器（翻页/拖进度照常走各自的手势）。
      if (this.rawHoldTimer >= 0 && Date.now() - this.rawDownMs > RAW_MOVE_CANCEL_MS) {
        clearTimeout(this.rawHoldTimer);
        this.rawHoldTimer = -1;
      }
      return;
    }
    if (event.type !== TouchType.Up && event.type !== TouchType.Cancel) {
      return;
    }
    if (this.rawHoldTimer >= 0) {
      clearTimeout(this.rawHoldTimer);
      this.rawHoldTimer = -1;
    }
    if (this.rawHoldFired) {
      // 长按松手：恢复成"按之前那样"（这里只做恢复，不额外切播放）。
      this.rawHoldFired = false;
      this.holdPaused = false;
      AppStorage.setOrCreate(REELS_CHROME_HIDDEN, false);
      return;
    }
    if (Date.now() - this.rawDownMs <= RAW_LONG_PRESS_MS) {
      // 单击：暂停 / 继续（暂停时正中那颗按钮由 userPaused 驱动，见 pauseButton）。
      this.userPaused = !this.userPaused;
    }
  }

  private onSeekCancel(): void {
    if (!this.dragging) {
      return;
    }
    this.dragging = false;
    this.dragProgress = this.progress;
  }

  /**
   * 播放器报上来的进度（见 VideoSurface.onProgress）。
   *
   * 拖动中不覆盖显示：那一段是"预览位置"，等松手 seek 之后播放器会自己报回来。
   */
  private onPlayProgress(positionMs: number, durationMs: number): void {
    if (durationMs > 0) {
      this.durationMs = durationMs;
    }
    if (this.dragging || this.durationMs <= 0) {
      return;
    }
    const ratio: number = positionMs / this.durationMs;
    this.progress = ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
  }

  /** 进度条当前该画到哪儿（拖动中画预览位置，否则画真实进度）。 */
  private progressNow(): number {
    const value: number = this.dragging ? this.dragProgress : this.progress;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /**
   * 卡片顶部那条**进度条**（需求："画在视频卡片内部顶部，一条粗直线，不可拖动"）。
   *
   * 为什么整条都挂 `hitTestBehavior(HitTestMode.None)`：需求明确"不可拖动" —— 它只是指示器，
   * 手指落在它上面要照常当成"点画面/拖进度"，不该被它吃掉（横滑 seek 的 PanGesture 挂在
   * 外层画面上，这里一旦吃触摸，从进度条上开始拖就没有反应了）。
   */
  @Builder
  progressBar() {
    Stack({ alignContent: Alignment.Start }) {
      // 轨道：半透明白（压在亮画面上也读得出来）。
      Row()
        .width('100%')
        .height(PROGRESS_HEIGHT)
        .borderRadius(PROGRESS_HEIGHT / 2)
        .backgroundColor(PROGRESS_TRACK_COLOR)
      // 已播放：实白。宽度按比例给字符串百分比（0..1 → '0%'..'100%'）。
      Row()
        .width(`${this.progressNow() * 100}%`)
        .height(PROGRESS_HEIGHT)
        .borderRadius(PROGRESS_HEIGHT / 2)
        .backgroundColor(PROGRESS_FILL_COLOR)
    }
    .width('100%')
    .height(PROGRESS_HEIGHT)
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 2 倍速胶囊（需求："播放期间在卡片顶部（进度条下方适当距离）显示胶囊「2.0x」"）。
   *
   * 复用全 app 的材质文字按钮（MaterialLabelButton），所以材质厚度跟着设定页走、和作者行/
   * 关注按钮是同一层玻璃；`lockMaterial: false` 让它不参与 4-way lock（手指落在它上面照样能
   * 上下翻页 —— 它只是个指示器）。点击照样落到外层画面（整颗挂 HitTestMode.None）。
   */
  @Builder
  speedPill() {
    MaterialLabelButton({
      labelText: SPEED_PILL_TEXT,
      fontSize: SPEED_PILL_FONT,
      pillWidth: SPEED_PILL_WIDTH,
      pillHeight: SPEED_PILL_HEIGHT,
      // 视频上一律不反色（和作者行、动作区那几颗一致，见它们的 autoInvert: false）。
      autoInvert: false,
      tint: '#FFFFFF',
      lockMaterial: false,
      onTap: (): void => {
      }
    })
      .hitTestBehavior(HitTestMode.None)
      // 出现/消失淡一下（和暂停按钮同一档观感；需求的"松手消失"不要求动画，这里只是别太生硬）。
      .transition(TransitionEffect.OPACITY.animation({ duration: PAUSE_FADE_MS, curve: Curve.EaseOut }))
  }

  /**
   * 置中的"继续播放"按钮（需求："暂停时置中显示沉浸光感暂停按钮…点击它 = 继续播放"）。
   *
   * **它自己不吃触摸**（`HitTestMode.None`）：点它和点画面走的是同一条路（外层画面的单击 →
   * 暂停/继续），这样就不存在"按钮和画面各处理一次、暂停被翻回去"的问题（本项目的
   * MaterialIconButton 内部是 Toggle，真机上点一下可能回调两次，见 MaterialSurface.fire）。
   */
  @Builder
  pauseButton() {
    MaterialIconButton({
      symbol: $r('sys.symbol.play_fill'),
      isOn: false,
      // 视频上一律不反色（需求："autoInvert: false"）。
      autoInvert: false,
      tint: '#FFFFFF',
      buttonSize: PAUSE_BUTTON_SIZE,
      iconSize: PAUSE_ICON_SIZE,
      onTap: (on: boolean): void => {
      }
    })
      .hitTestBehavior(HitTestMode.None)
      // 画面正中（外层 Stack 是 Center，`align` 是"我这个子节点摆在哪儿"）。
      .align(Alignment.Center)
      // 出现/消失淡入淡出（需求：约 150ms）。transition 要挂在**被插入/移除的那个节点**上，
      // 所以写在 Builder 内部而不是 `if` 里的调用处（@Builder 调用本身不能链属性）。
      .transition(TransitionEffect.OPACITY
        .animation({ duration: PAUSE_FADE_MS, curve: Curve.EaseOut }))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      /*
       * **高模糊封面背景**（需求：reels 及类 reels 页的背景都用视频封面的高模糊版本）。
       *
       * 为什么放最外层：画面盒子是按视频比例算出来的，竖屏视频上下会有留白 ——
       * 以前那里是纯黑，观感像"视频掉在黑底上"。现在用**同一张封面**放大 + 高模糊铺满整屏，
       * 留白处就有了颜色延续（和 IG 自己的做法一致），而且不需要额外拉图：
       * 封面地址本来就来自解析结果（`reel.coverUrl`），`PosterCache` 也会命中同一张。
       *
       * 几个参数的理由：
       *   · `ImageFit.Cover` + `scale(1.15)`：模糊会把边缘算成半透明，放大一点避免露出黑边；
       *   · `blur(48)`：够糊到看不出细节，又不至于变成一块纯色；
       *   · `opacity(0.55)`：压暗一档，保证前景文字（作者行/操作栏）的对比度不受影响。
       */
      Image(this.reel.coverUrl.length > 0 ? this.reel.coverUrl : $r('app.media.startIcon'))
        .draggable(false)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Fill)
        .blur(48)
        .scale({ x: 1.15, y: 1.15 })
        .opacity(0.55)
      /*
       * **画面盒子**：宽度永远铺满屏幕，高度按**视频自己的比例**（实测优先，见 aspect()）。
       *
       * 需求："视频填充逻辑用视频宽度按比例填满" —— 所以既不能靠整屏 Cover 裁（16:9 会切掉左右），
       * 也不能让播放器撑满一个比例不对的盒子（那就是"竖向拉伸"）。盒子比例对上之后，
       * Cover 与 Contain 等价：画面既不变形也不被裁。
       */
      Stack({ alignContent: Alignment.Center }) {
        // 封面先铺底：视频起播前不会黑屏，滑过去也立刻有画面。**和播放器同一个盒子**，
        // 所以撤封面时不会有任何错位。
        Image(this.reel.coverUrl.length > 0 ? this.reel.coverUrl : $r('app.media.startIcon'))
          .draggable(false)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
        if (this.reel.playable() && (this.playing || this.preload)) {
          // 播放器换成 AVPlayer + XComponent 的共用组件，理由见 VideoSurface 的说明：
          // 它能在 prepare 阶段就把首帧送到表面上（showFirstFrameOnPrepare），
          // 所以下面那层封面是在"首帧真的上屏"之后才撤的，不再有黑闪。
          VideoSurface({
            url: this.reel.videoUrl,
            // `wantsPlayNow()` 而不是 `playing`：用户单击暂停 / 长按暂停都只影响"播不播"，
            // **不影响播放器挂不挂**（挂载条件还是上面那句 `playing || preload`）。
            playing: this.wantsPlayNow(),
            segment: this.segment,
            preload: this.preload,
            muted: this.muted,
            // 长按左右两侧时 2 倍速，松手回 1 倍速（见 VideoSurface.speed，失败静默降级）。
            speed: this.speedBoost ? SPEED_2X : 1,
            // 拖动进度条松手那一下写进来（见 onSeekEnd）。
            seekMs: this.seekMs,
            // 盒子比例已经等于视频比例，所以用 FIT（完整显示）就正好铺满这个盒子；
            // 再开 FIT_CROP 反而会二次裁切（把本该看到的画面切掉）。
            cover: false,
            onFirstFrame: (): void => {
              this.ready = true;
              this.onFirstFrame();
            },
            onError: (): void => {
              // 放不出来也要撤封面：不然用户看到的是一张永远不动的图，不知道发生了什么。
              this.ready = true;
            },
            // 真实尺寸一到就纠正盒子比例（见 measuredAspect 的说明）。
            onVideoSize: (w: number, h: number): void => {
              if (w > 0 && h > 0) {
                const ratio: number = w / h;
                if (Math.abs(ratio - this.measuredAspect) > 0.01) {
                  this.measuredAspect = ratio;
                }
              }
            },
            // 进度条唯一的来源（见 onPlayProgress）—— 播放器自己报的 position/duration。
            onProgress: (positionMs: number, durationMs: number): void => {
              this.onPlayProgress(positionMs, durationMs);
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
            .objectFit(ImageFit.Contain)
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .aspectRatio(this.aspect())
      // 竖屏视频（高 > 屏高）超出的部分在**外层**被裁掉，而不是把画面压扁。
      .clip(true)

      /*
       * **卡片顶部：进度条 + 2 倍速胶囊**（需求第 2、6 条）。
       *
       * 放这一层（画面之后、也就是画在画面上方）而不是放进 ReelOverlay 的原因：
       *   · 需求明确"画在视频卡片内部顶部" —— 卡片就是本组件所在的这个盒子，跟着卡片一起
       *     被圆角裁、跟着卡片一起随翻页移动；
       *   · ReelOverlay 会在"隐藏全局控件"时整层淡出，而进度条**不该**跟着消失
       *     （它不是控件，是播放状态的指示，和 IG 一致）。
       * 整层 `HitTestMode.None`：它只显示，不能吃掉"点画面暂停"和"横滑 seek"。
       */
      Column({ space: SPEED_PILL_GAP }) {
        Column() {
          this.progressBar()
        }
        .width('100%')
        .padding({ left: PROGRESS_SIDE_PAD, right: PROGRESS_SIDE_PAD })

        // 2 倍速胶囊：只在长按侧边期间出现（出现/消失淡入淡出 ~150ms）。
        if (this.speedBoost) {
          this.speedPill()
        }
      }
      .width('100%')
      // **撑满卡片高度 + 从顶部开始排**：外面是 Stack，`.align(Alignment.Top)` 在 Stack 子节点上
      // 不可靠（真机上进度条会跑到画面正中）。用"整高 Column + FlexAlign.Start"摆位才稳。
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Start)
      // 距卡片顶部留一点：贴边会被圆角裁掉两头（见 PROGRESS_TOP_GAP）。
      .padding({ top: PROGRESS_TOP_GAP })
      .hitTestBehavior(HitTestMode.None)

      /*
       * **置中的暂停/继续按钮**：只在"这一条是当前页 且 用户手动暂停或长按暂停"时出现。
       *
       * 用 `if` + `.transition` 而不是常驻改透明度：插入/移除自带淡入淡出（需求：约 150ms），
       * 而且节点不在树上时**不占触摸**（常驻改 opacity 的话它虽然看不见，照样要小心命中区域）。
       * 它自己不吃触摸（见 pauseButton 的说明），点它 = 点画面 = 继续播放。
       */
      if (this.playing && this.reel.playable() && (this.userPaused || this.holdPaused)) {
        this.pauseButton()
      }

      /*
       * **触摸命中层**（最后一张牌，也是唯一正确的位置）。
       *
       * 为什么必须在这里：画面本体是 `XComponent`（原生视频表面），它会**消费整条触摸流** ——
       * 挂在它的祖先节点上的 `.gesture()` / `.parallelGesture()` 都收不到事件
       * （真机实测：单击、长按、横滑全部无反应）。唯一稳定生效的位置是"压在它上面的一层节点"：
       * 透明、默认命中模式，只有它收到手势后再转给下面那些方法。
       *
       * 为什么不会挡住下面的东西：这层只覆盖**卡片区域**，而且卡片里除了画面没有别的可点控件
       * （暂停按钮自己挂了 `HitTestMode.None`、进度条同理），信息层/作者行/动作区都在
       * 卡片之外的 `ReelOverlay` 里，层级更高、不受影响。
       */
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        /*
         * **原生 onTouch**（不再是手势识别器）。
         *
         * 为什么换成它：单击 / 长按 / 横滑用手势识别器连改几版都没反应 —— 识别器要经过
         * "命中 → 协商 → 成立"三步，任何一步出问题都表现为"毫无反应"，而且无法判断卡在哪。
         * onTouch 是触摸事件本身：**节点被命中就一定回调**，所以我们自己按时间/位移判单击与长按。
         * 判据（都在 onRawTouch 里）：位移 < 10vp 且时长 < 400ms → 单击；不动且时长 ≥ 400ms → 长按。
         */
        .onTouch((event: TouchEvent): void => {
          this.onRawTouch(event);
        })
        .parallelGesture(
      GestureGroup(GestureMode.Parallel,
        // ① 单击 → 暂停 / 继续（需求第 3 条）。
        TapGesture({ count: 1, distanceThreshold: VIDEO_TAP_DISTANCE_VP })
          .onAction((event: GestureEvent): void => {
            this.onVideoTap(event);
          }),
        // ② 长按中间 40% → 暂停 + 隐藏全局控件，松手恢复（需求第 5 条）。
        LongPressGesture({ repeat: false, duration: LONG_PRESS_CENTER_MS })
          .onAction((event: GestureEvent): void => {
            this.onHoldStart(event, false);
          })
          .onActionEnd((): void => {
            this.onHoldEnd();
          })
          .onActionCancel((): void => {
            this.onHoldEnd();
          }),
        // ③ 长按左右两侧各 30% → 2 倍速，松手回 1 倍速（需求第 6 条）。
        LongPressGesture({ repeat: false, duration: LONG_PRESS_SIDE_MS })
          .onAction((event: GestureEvent): void => {
            this.onHoldStart(event, true);
          })
          .onActionEnd((): void => {
            this.onHoldEnd();
          })
          .onActionCancel((): void => {
            this.onHoldEnd();
          }),
        // ④ 横滑 → 拖进度条（需求第 1 条）：拖动中只改显示，松手才 seek。
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: SEEK_PAN_DISTANCE_VP })
          .onActionStart((): void => {
            this.onSeekStart();
          })
          .onActionUpdate((event: GestureEvent): void => {
            this.onSeekMove(event);
          })
          .onActionEnd((): void => {
            this.onSeekEnd();
          })
          .onActionCancel((): void => {
            this.onSeekCancel();
          })
      )
    )
    }
    .width('100%')
    .height('100%')
    /*
     * 按下那一刻把"长按吞单击"的记号清掉。
     *
     * 为什么需要：`longPressFired` 是给"长按抬手时系统还会补一次单击"用的。如果这一下长按
     * 之后手指是**划走**的（长按成立后继续拖，tap 不会成立），那个记号就没人清 —— 于是
     * 下一次真正的单击会被误吞（用户会报"点一下没反应，要再点一下"）。Down 一定是每一次
     * 新手势的第一个事件，在这里清最稳。
     */
    .onTouch((event: TouchEvent): void => {
      TouchProbe.log('slide-root', event.type);
      if (event.type === TouchType.Down) {
        this.longPressFired = false;
      }
    })
    // 量一次画面自己的宽度：拖动进度按"位移 ÷ 画面宽"换算比例（见 cardWidthVp）。
    // 用布局量出来的值而不是"屏宽 − 32"：卡片宽度写的是 `calc(100% - 32vp)`，两者本该相同，
    // 但真机上卡片还可能被 maxHeight 那一条约束反推窄一点，量到的才是真的。
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const width: number = typeof newArea.width === 'number' ? newArea.width as number : 0;
      if (width > 0 && Math.abs(width - this.measuredWidthVp) > 0.5) {
        this.measuredWidthVp = width;
      }
    })
    /*
     * 手势全挂在**画面这一层**（= 卡片内部，见类头）：需求第 1 条要求"起点落在视频画面内的
     * 左右滑动 = 拖进度"，所以横滑手势必须只覆盖画面，不能覆盖左右 16vp 留白 ——
     * 那里要留给外面 Tabs 的"左右滑切段"。
     *
     * 用 `GestureGroup(GestureMode.Parallel)` 装四条手势（单击 / 两条长按 / 横滑），原因见
     * onVideoTap 的注释（串行会把单击排在长按后面，互斥又不保证 onActionEnd 一定来）。
     *
     * 为什么这里**不该**影响上下翻页：Swiper 的内建 PAN 是本组件的**祖先**，方向也限定在竖向；
     * 这里的横滑用 `PanDirection.Horizontal`，竖向滑动根本不会让这条手势成立。
     */
    /*
     * **用 parallelGesture 而不是 gesture**：画面是 `XComponent`（视频表面），它自己会消费
     * 触摸事件；普通 `.gesture()` 挂在祖先节点上会被它截断 —— 真机表现就是"手势完全无效"。
     * `parallelGesture` 允许与子节点的手势并行识别，单击/长按/横滑才收得到。
     */
    // 手势**不挂在根节点上**：画面是 XComponent，它会把触摸流吃掉，祖先上的
    // 手势识别器收不到事件（真机实测：单击/长按/横滑全部无反应）。手势改挂到
    // "画面最上层的一层透明命中层"上，见下面 overlayHitLayer()。
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
 *   2) **手势**。浮层挂在 Swiper 外面时，它和 Swiper 是**兄弟**关系；动作区那几颗是 Toggle
 *      带着自己的 PanGesture（材质按钮的 4-way-lock，见 MaterialSurface.consumePan），兄弟关系下
 *      它们会把竖向滑动赢走 —— 手指落在按钮上就怎么划都翻不了页。放进页内之后
 *      Swiper 的内建 PAN 是祖先，滑动照常翻页（和信息流 List 里按在按钮上也能滚是同一个道理）。
 *      另外**作者行与关注按钮这一轮彻底退出了 4-way lock**（需求："lock 只作用于评论面板里那张
 *      卡片"）：作者行那颗胶囊不再记"按住"，关注按钮传 `lockMaterial: false`（见 MaterialLabelButton）。
 *
 *   3) 关注 / 点赞 / 转发这些状态本来就属于"这一条"，改 `reel` 上的字段即可就地重绘
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
  /**
   * 信息层（作者行 / 关注按钮 / 正文）的**底部留白**（vp；0 = 用默认 INFO_BOTTOM）。
   *
   * 为什么要能从外面给：默认的 112 是"只避开底栏胶囊"算出来的，而这两页底部还压着一条
   * 评论输入框（44 + 28），于是正文和输入框之间空出一大截（用户："留白太多，正文要和输入框
   * 保持适当距离"）。宿主按输入框实际高度算一个值传进来即可。
   */
  @Prop infoBottomVp: number = 0;
  /** 材质厚度（和全 app 的材质组件同一份设定）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * **全局控件藏起来了没有**（见 REELS_CHROME_HIDDEN）。
   *
   * 用 `@StorageLink`（不是 @Prop）：信息层是**每条一个**、都在 ForEach 里，键没变的项不会
   * 重跑 item builder —— 父组件的 @Prop 到不了已经建好的那几条，只有组件级订阅能让
   * "所有视频一起隐藏"（需求原话："隐藏后是所有视频隐藏"）。
   */
  @StorageLink(REELS_CHROME_HIDDEN) @Watch('onChromeHiddenChanged') chromeHidden: boolean = false;
  /**
   * 信息层的实际透明度（0 = 藏起来）。
   *
   * 为什么不直接用 `opacity(this.chromeHidden ? 0 : 1)` + 通用 `.animation()`：那个属性动画
   * 会把**同一节点上别的属性变化**也一起吃掉 —— 这里同一层还挂着 `overlaySink` 的下沉位移
   * （底栏那条弹簧曲线，见 overlaySink），时序会被改写。所以用 `animateTo` 只补间这一个 `@State`。
   */
  @State private chromeAlpha: number = 1;

  /** 关注状态是会话级覆盖表说了算（别处点过也要跟着变，见 core/FollowState）。 */
  @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
  /** 这一条的作者我关注了没有。 */
  @State private following: boolean = false;
  /** 按**文本**缓存的折叠前缀（见 prefixOfText）。 */
  private textFits: Map<string, string> = new Map<string, string>();
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
  /**
   * 点**正文**（含结尾的省略号）：打开评论面板，并且**带上那张置顶帖子卡片**
   * （需求："点 Reels 正文 → 打开评论面板带卡片"；卡片本体见 components/PostCardPanel）。
   *
   * 和 `onComments` **分流成两个回调**：这颗走"带卡片"，动作区那颗气泡走"不带卡片"。
   * 宿主那边是同一个打开函数 + 一个开关（见 pages/Index.openReelComments / openReelPostCard）。
   */
  onOpenPostCard: (reel: Reel) => void = (reel: Reel): void => {
  };
  /** 转发给好友 / 更多：这一版宿主只弹一句"还没接入"。 */
  onShare: (reel: Reel) => void = (reel: Reel): void => {
  };
  onMore: (reel: Reel) => void = (reel: Reel): void => {
  };

  aboutToAppear(): void {
    this.syncFollow();
    this.syncSaved();
    /*
     * 组件**在"控件已经藏起来"的状态下被创建**时（比如翻到这一条、Swiper 新建了一页），
     * @Watch 不一定补一次，所以这里按当前值先把透明度摆到位 —— 否则新那一页的信息层会
     * 明着出现在一个"全隐藏"的界面上。
     */
    this.chromeAlpha = this.chromeHidden ? 0 : 1;
  }

  /**
   * 收藏状态以**会话覆盖表**为准（见 core/SaveState 与上面的 `saved` 说明）。
   *
   * 载荷给了 `has_saved` 就用它当兜底值，没给就是 false（真机上基本都没给）。
   */
  /**
   * 信息层（作者行 / 关注按钮 / 正文）的**底部留白**：宿主给了就用它，没给用默认值。
   *
   * 资讯层与动作区**共用这一个值**，底边才会齐（见 build 里那两处 padding 的说明）。
   */
  private infoPadding(): number {
    return this.infoBottomVp > 0 ? this.infoBottomVp : INFO_BOTTOM;
  }

  private syncSaved(): void {
    this.saved = SaveState.resolve(this.reel.mediaId, this.reel.saved);
  }

  /** 别处改过关注状态：重新算一次（见 core/FollowState 的"全局刷新"）。 */
  private onFollowVersion(): void {
    this.syncFollow();
  }

  /**
   * 全局控件被藏起来 / 恢复了：整层淡出、淡入（需求：约 180ms，可带轻微位移）。
   *
   * 位移写在 build 里那两层的 `translate` 上（和 `overlaySink` 同一个属性、相加），这里只管透明度
   * —— 透明度是 `@State`，`animateTo` 会给它补间；位移那边跟着同一个 `chromeHidden` 变，属于
   * "布局属性瞬间变"，但只差 CHROME_SHIFT_VP 十几 vp，眼睛看着就是跟着淡出一起往下缩了一点。
   */
  private onChromeHiddenChanged(): void {
    this.getUIContext().animateTo({ duration: CHROME_FADE_MS, curve: Curve.EaseOut }, (): void => {
      this.chromeAlpha = this.chromeHidden ? 0 : 1;
    });
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

  /**
   * 折叠态的**第一行内容**（需求："折叠态正文 = 第一行内容裁掉尾部空白，然后接 ' ...'"）。
   *
   * 两步：
   *   ① 按"一行 + 结尾的 `CAPTION_TAIL`"量出最长前缀（见 core/CaptionFit 的 `more` 参数）——
   *      量的时候就把省略号的宽度算进去了，所以接上去之后仍然是一行；
   *   ② 裁掉尾部空白（免得出现"正文␣ ..."这种双空格），末尾那颗省略号由调用方单独画（要灰色）。
   *
   * 前缀**按文本缓存**（见 prefixOfText）：切条来回不重复量（`measureTextSize` 是同步 IPC）。
   */
  private captionLine(): string {
    return this.prefixOfText(this.reel.caption).replace(/[\s\u3000]+$/, '');
  }

  /**
   * 正文折叠时**正文那一行真正能占的宽度**（vp），量行数用它。
   *
   * 左边只有 `SIDE_PADDING` 一处留白，右边还要给动作栏让出整栏宽度（见 ReelOverlay.build 里
   * 资讯层的 `padding.right`）—— 量的时候不扣这一截，量出来的前缀就比实际能放的长，
   * 一行正文会被 `maxLines` 再切一道省略号，和结尾的" ..."接不上。
   * 末尾再减 `CAPTION_TAIL_SAFETY_VP`，免得省略号正好卡在行尾被裁。
   */
  private captionAvailVp(): number {
    return this.screenWidthVp - SIDE_PADDING - ACTION_COLUMN_WIDTH - CAPTION_TAIL_SAFETY_VP;
  }

  /**
   * **任意文本**的折叠前缀（按文本本身缓存）。
   *
   * 参数里带 `CAPTION_MAX_LINES`（= 1，这一页收成一行，见那个常量的说明）与 `CAPTION_TAIL`
   * （量的时候把结尾省略号算进宽度）；宽度用 `captionAvailVp()`，和真正渲染出来的那一行等宽。
   */
  private prefixOfText(text: string): string {
    if (text.length === 0) {
      return '';
    }
    const cached: string | undefined = this.textFits.get(text);
    if (cached !== undefined) {
      return cached;
    }
    const availVp: number = this.captionAvailVp();
    const prefix: string = availVp > 0
      ? CaptionFit.prefix(this.getUIContext(), text, availVp, CAPTION_FONT_SIZE, CAPTION_MAX_LINES,
        CAPTION_TAIL)
      : text;
    this.textFits.set(text, prefix);
    return prefix;
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
      /*
       * **这里没有 4-way lock**（需求："lock 只作用于评论面板里那张卡片"）。
       *
       * 上一轮在这颗作者行胶囊上挂了 `onTouch(trackMaterialTouch)`，这一轮拿掉了：视频页的
       * 作者行/关注按钮就是"压在画面上的普通按钮"，手指落在它上面照样应该能上下翻视频。
       * 材质本身的观感不受影响（那份材质在 `.attributeModifier` 上，和手势是两件事）。
       */

      // 关注按钮（需求："组件右边显示关注按钮（沉浸光感），需要展示关注状态，点击关注或者取消关注"）。
      //
      // **只要知道账号名就画**：拿不到数字 id 时宿主那边会退回"网页驱动"那条路
      // （打开对方主页点它自己的关注按钮，见 pages/Index.followUser），照样能关注上 ——
      // 比"因为少一个 id 就整颗按钮不出现"好得多（用户报的"没看到关注按钮"就是这个）。
      // 例外：**作者就是我自己**时不画（关注自己没有意义，见 ownAuthor）。
      if (this.reel.author.length > 0 && !this.isOwnAuthor()) {
        MaterialLabelButton({ autoInvert: false,
          // 视频页这颗**不接 4-way lock**（见作者行上面的说明与 MaterialLabelButton.lockMaterial）。
          lockMaterial: false,
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
   * **限制到一行**"）。
   *
   * 不叠任何材质/底色：直接白字压在画面上（和 IG 一致）；折叠判据与信息流那份**同一套**
   * （见 core/CaptionFit），只有折叠行数这一页收成一行（见 CAPTION_MAX_LINES）。
   *
   * 版式（自上而下）**只有一行**：正文 + 结尾那颗 " ..."。视频页**不提供翻译**
   * （需求："视频页正文区去掉查看翻译，译文也不再在视频页展开"）：译文只在评论面板里那张
   * 帖子卡片上（见 components/PostCardPanel）。上一轮挂在正文下面的 `TranslateLabel`、
   * 它的 `captionTranslated` 状态、译文文本与那段线性 `animateTo` 都整块删掉了。
   *
   * ## 点击归属：点哪里都开面板
   * 正文与省略号在**同一颗 Text** 里（省略号是它的 Span）。Span 没有自己的命中区域，
   * 所以整颗 Text 就是那一片命中区 —— 点正文、点省略号走的都是同一个 `.onClick`
   * （打开评论面板，面板里带那张卡片，见 openPostCard）。
   *
   * ## 手势
   * 正文那颗 Text 只吃"点"（Click），竖向滑动仍由外层 Swiper 的 Pan 手势裁决 ——
   * 手指一移动，Click 自动作废，翻页照旧（信息层整体 `hitTestBehavior(Transparent)`，见 build）。
   */
  @Builder
  captionBlock() {
    if (this.reel.caption.length > 0 && this.captionLine().length > 0) {
      /*
       * 一个 Text 装两段：正文（白）+ 结尾省略号（灰）。
       *
       * **Span 没有自己的 onClick**（挂在 Text 上整段只有一个回调），所以整颗 Text 才是那颗
       * 命中区域 —— 点正文、点省略号走的都是同一个 `.onClick`（都开面板）。
       * 早就量好的前缀保证这两段加起来正好一行（见 captionLine）。
       * Span 支持 `textShadow` 且会从父 Text 继承（官方文档：API 10 起 Span 继承
       * fontColor/fontSize/fontStyle/fontWeight/decoration/letterSpacing/textCase/fontFamily/
       * textShadow），所以阴影只需要在 Text 上写一次。
       */
      Text() {
        Span(this.captionLine())
          .fontColor(Color.White)
        Span(CAPTION_TAIL)
          .fontColor('#BFBFBF')
      }
      .fontSize(CAPTION_FONT_SIZE)
      .lineHeight(CAPTION_LINE_HEIGHT)
      .textShadow(OVERLAY_TEXT_SHADOW)
      .maxLines(CAPTION_MAX_LINES)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .textAlign(TextAlign.Start)
      .onClick((): void => {
        this.openPostCard();
      })
    }
  }

  /**
   * 点正文（含结尾的省略号）→ 打开**评论面板，并且带那张置顶卡片**
   * （需求："点 Reels 正文 → 打开评论面板，并且带那张卡片"）。
   *
   * 注意这里**不是** `onComments`：动作区那颗气泡走的才是"只开评论、不带卡片"。
   * 两条路都落到宿主的同一个打开函数上，只差一个开关（见 pages/Index.openReelPostCard
   * 与 openReelComments 的说明）。
   */
  private openPostCard(): void {
    this.onOpenPostCard(this.reel);
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
   *   - 转发给好友：`share`（系统那朵分享图标，与 FeedList 动作区那颗**同一个**；
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
        MaterialIconButton({ autoInvert: false,
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
            .textShadow(OVERLAY_TEXT_SHADOW)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 评论：图标 + 计数。
      Column({ space: 2 }) {
        MaterialIconButton({ autoInvert: false,
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
            .textShadow(OVERLAY_TEXT_SHADOW)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 转发：图标（已转发时正中叠对勾）+ 计数。
      // 图标自带两个动画：外层循环箭头转 360° 镜像旋转、内层对勾一笔画出来（见 AnimatedIcons.RepostIcon）。
      Column({ space: 2 }) {
        MaterialIconButton({ autoInvert: false,
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
            .textShadow(OVERLAY_TEXT_SHADOW)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 转发给好友（分享）：图标 + 分享数。
      // 计数的样式与上面三颗**完全一致**（11sp 白字 + OVERLAY_TEXT_SHADOW、单行、千分位/万缩写
      // 走同一个 countText）；**为 0 时整颗不画** —— 载荷不给这个数时那一栏就只有图标，
      // 不会挂一个 "0"（见 model/Reel.shareCount）。
      // 图标用 `sys.symbol.share`（和 FeedList 动作区那颗分享**同一个符号**）：纸飞机在系统
      // 语义里是"发送/私信"，而这一颗是"把这条分享出去"，两者不能混用。
      Column({ space: 2 }) {
        MaterialIconButton({ autoInvert: false,
          symbol: $r('sys.symbol.share'),
          isOn: false,
          tint: '',
          buttonSize: ACTION_BUTTON_SIZE,
          iconSize: ACTION_ICON_SIZE,
          onTap: (on: boolean): void => {
            this.onShare(this.reel);
          }
        })
        if (this.reel.shareCount > 0) {
          Text(this.countText(this.reel.shareCount))
            .fontSize(11)
            .fontColor(Color.White)
            .textShadow(OVERLAY_TEXT_SHADOW)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      /*
       * 收藏（书签）—— **放在「更多」上面**（需求："显示在更多按钮上方"）。
       *
       * 图标是系统那两颗 `bookmark` / `bookmark_fill`（和「我的」页"收藏"分段一致），
       * 收藏那一刻由小到大弹一下（见 AnimatedIcons.SaveIcon）。
       *
       * 收藏数：IG 基本**不公开**这个数字（clips 载荷里通常连字段都没有，见
       * model/Reel.saveCount），所以绝大多数情况下这里只有图标；真给到了才画那个数字，
       * 样式与其它几颗一致，为 0 时整颗不画。
       */
      Column({ space: 2 }) {
        MaterialIconButton({ autoInvert: false,
          symbol: $r('sys.symbol.bookmark'),
          isOn: this.saved,
          animated: 'save',
          buttonSize: ACTION_BUTTON_SIZE,
          iconSize: ACTION_ICON_SIZE,
          onTap: (on: boolean): void => {
            this.tapSave(on);
          }
        })
        if (this.reel.saveCount > 0) {
          Text(this.countText(this.reel.saveCount))
            .fontSize(11)
            .fontColor(Color.White)
            .textShadow(OVERLAY_TEXT_SHADOW)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Center)

      // 更多。
      MaterialIconButton({ autoInvert: false,
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
      // 底边留白：和右边动作区**用同一个值**（见 infoPadding 的说明）。
      .padding({ left: SIDE_PADDING, right: ACTION_COLUMN_WIDTH, bottom: this.infoPadding() })
      // 跟着底栏下沉（需求："动作区和资讯区跟随 tabbar 下沉"）：整块往下挪，和栏同一条曲线。
      // 全局控件隐藏时再多挪 CHROME_SHIFT_VP（"淡出 + 轻微位移"，见 onChromeHiddenChanged）。
      .translate({ y: this.overlaySink + (this.chromeHidden ? CHROME_SHIFT_VP : 0) })
      // 隐藏全局控件：整块淡出（透明度由 @State + animateTo 补间）。
      .opacity(this.chromeAlpha)
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
      /*
       * 底边留白**必须和左边资讯层同一个值**（需求："正文区底边高度与动作区底边高度统一"）。
       *
       * 两块都是"钉在屏幕底部、再各留一段底白"的浮层：只要底白相同，右边最下面那颗按钮的底边
       * 就落在左边正文最后一行的底边上。原来这里写的是常量 `INFO_BOTTOM`，而左边读的是
       * `infoPadding()`（宿主会按底部评论输入框的实际高度传一个值进来，见 infoBottomVp）——
       * 一旦宿主传了非 0 的值，两块就错开一截，正是用户看到的那条"底边不齐"。
       */
      .padding({ right: ACTION_RIGHT_PADDING, bottom: this.infoPadding() })
      // 和左边那块同一个位移：一起沉、一起回来（见 overlaySink）；隐藏控件时一起下缩一点。
      .translate({ y: this.overlaySink + (this.chromeHidden ? CHROME_SHIFT_VP : 0) })
      // 隐藏全局控件：整块淡出（和左边资讯区同一条曲线，见 onChromeHiddenChanged）。
      .opacity(this.chromeAlpha)
      // 不吃手势（按钮自己要能点，见 actionColumn 里的材质按钮）。
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    // 这一层整体也不吃手势：竖向滑动要落到下面的 Swiper 上（见类头第 2 条）。
    .hitTestBehavior(HitTestMode.Transparent)
    /*
     * **藏起来之后整层停用**：透明度 0 的节点照样吃点击（点到的是一颗看不见的赞/关注），
     * 所以淡出之后还要把这一层的事件关掉 —— 否则"隐藏控件后点画面外恢复"这一下会被
     * 那颗看不见的按钮接走（它自己还有个 600ms 去重，更显得"点了没反应"）。
     */
    .enabled(!this.chromeHidden)
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
  /** 信息层底部留白（vp；0 = 用 ReelOverlay 的默认值 INFO_BOTTOM，见那里的说明）。 */
  @Prop infoBottomVp: number = 0;
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
  /**
   * 屏幕高度（vp）：交给每条画面判断"这一下手势有没有落在屏幕底部那块信息层上"
   * （见 ReelSlide.overOverlay）。只做一次粗判，所以不需要精确到避让区。
   */
  @State private screenHeightVp: number = 780;
  /**
   * **全局控件藏起来了没有**（见 REELS_CHROME_HIDDEN）。
   *
   * 这一页是"谁来切换"的入口（单击画面之外的留白 / 模糊带），信息层和外壳各自订阅同一个键。
   */
  @StorageLink(REELS_CHROME_HIDDEN) chromeHidden: boolean = false;
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
  /** 点正文 → 帖子卡片面板（和 onComments 分流，见 ReelOverlay.onOpenPostCard）。 */
  onOpenPostCard: (reel: Reel) => void = (reel: Reel): void => {
  };
  onShare: (reel: Reel) => void = (reel: Reel): void => {
  };
  onMore: (reel: Reel) => void = (reel: Reel): void => {
  };
  private readonly swiperController: SwiperController = new SwiperController();
  /*
   * ## 关于"滑动切换动画不连贯"（2026-10-22 定位并修掉）
   *
   * 这里原来有一个 `@State swiperIndex` 绑在 Swiper 的 `.index(...)` 上（受控绑定），
   * 并在 `onAnimationStart` 里把它写成目标页。看着是"同步"，实际是**自己掐自己的动画**：
   * `.index()` 是构建期属性，`switchTo` 在动画一开始就改了若干 `@State`（activeIndex /
   * videoReady / burst），重绘立刻把 `.index(目标页)` 应用下去 —— Swiper 被"直接摆"到目标页，
   * 转场动画当场结束。真机日志里量到的就是这一个：
   *
   *     switch animation 12ms / 15ms / 25ms   ← 每次上滑都只有十几毫秒（等于瞬移）
   *     switch animation 487ms / 605ms        ← 只有"到底了那一弹"才是真的动画
   *
   * 现在**不再绑 `.index()`**：位置只由用户手势和 `swiperController.changeIndex()` 决定，
   * 重建后靠 `onAppear` 里的 `changeIndex(activeIndex, false)` 摆回上次那一条。
   * 翻页动画于是真的跑满（实测回到 300~500ms 的弹簧）。
   */
  /** 本次翻页动画的开始时刻（onAnimationStart 记下，onAnimationEnd 算时长，见 SWITCH_ANIM_MS）。 */
  private animationStartedMs: number = 0;
  /**
   * **手指一开始划**就通知页面（底栏下沉收缩用，见 pages/Index 的 onReelsSink）。
   *
   * 为什么不是"翻页了再报"：Reels 要的是**灵敏**（需求："手指开始滑动时就收缩"），所以挂在
   * Swiper 的 `onTouch` 上 —— 第一次 Move 一到就报（那一下一定早于翻页动画），
   * 而且**同一次触摸只报一次**（`swipeReported`）。
   */
  /**
   * **冻结播放**（分段页面滑动中为 true）。
   *
   * 需求："页面左右移动时暂停，移动完成后只播放当前页面的视频"。
   * 由外壳在 Tabs 的动画开始/结束时置位（见 pages/Index.reelsTab）。冻结期间
   * `playing` 一律 false，但**不销毁播放器**（表面还在，松开就立刻续播）。
   */
  /**
   * **这一段现在是不是可见的那一段**（探索 / 关注 只有一个为 true）。
   *
   * 为什么需要：两段现在都常驻在 `TabContent` 里，各自的 `activeIndex` 都会指向"当前条"，
   * 于是两页会**各播各的**。加上这个开关后：不可见的那一段一律不播（表面留着，切回来就续播）。
   */
  /**
   * 这一段是第几段（0 = 探索 / 1 = 关注）。由外壳传入，创建后不变。
   */
  segment: number = -1;
  /**
   * **全局播放开关**（AppStorage，不走 @Prop）。
   *
   * 为什么不用 @Prop：两段内容都在 ForEach 里，键值没变时 item builder 不重跑，
   * 父组件传下来的 @Prop 更新不到已建好的节点 —— 上一版就是因此"仍然听得见另一页的声音"。
   * @StorageLink 是组件级订阅：值一变本组件 build 一定重跑，playing 才会真的变。
   *   · reels_frozen_all     = 全局急停阀（当前没人置 true：滑动中间**不再**冻结播放，
   *                           见 pages/Index 的 reelsTab 说明；留着是为了以后需要时能一键静音）；
   *   · reels_active_segment = 当前可见段（**落定后**才更新；另一段一律不播）。
   */
  @StorageLink('reels_frozen_all') frozenAll: boolean = false;
  @StorageLink('reels_active_segment') activeSegment: number = 0;
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
      // 高度只给"手势热区"用（信息层护栏 / 左右两侧的长按热区），拿不到就留兜底值。
      this.screenHeightVp = this.getUIContext().px2vp(dsp.height);
    } catch (error) {
      this.screenWidthVp = FALLBACK_WIDTH_VP;
    }
    this.vm.onReels = (reels: Array<Reel>, hasMore: boolean): void => {
      this.reels = reels;
      // 记一份"这几条第一次进入列表的时刻"：载荷没给 `taken_at` 时，评论面板里那张卡片
      // 用它当兜底的发布时间（见 core/ReelSeenTime 与 pages/Index.reelTakenAtMs）。
      ReelSeenTime.note(reels.map((reel: Reel): string => reel.shortcode));
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
      // 回填这条路径也要记一次（可能来自落盘缓存，见 core/ReelsCache）：见 core/ReelSeenTime。
      ReelSeenTime.note(cached.map((reel: Reel): string => reel.shortcode));
      // 连"看到第几条"一起恢复：切 tab 会重建这个组件，@State 会归零，
      // 不恢复的话每次切回来都从第一条重新开始（视图模型记着它，见 ReelsViewModel.activeIndex）。
      const resume: number = this.vm.activeIndex();
      this.activeIndex = resume < cached.length ? resume : 0;
      // 恢复位置时"落定页"就是它（见 settledIndex，审计 B1）。
      this.settledIndex = this.activeIndex;
      // 位置本身不靠 `.index()` 摆（见类里那段"滑动切换动画不连贯"的说明），
      // 由 Swiper 的 onAppear 调 `swiperController.changeIndex(activeIndex, false)` 摆回来。
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
    /*
     * 空列表（首屏要现拉）：**先把标题栏那两颗按钮收掉**。
     *
     * Reels 这页现在有两份数据源（探索 / 关注，见 pages/Index 的 reelsSegment），切过去时新那页
     * 可能还是空的；不主动报一次，标题栏会一直挂着**上一页那条视频**的"下载"地址 ——
     * 用户点下载会下到另一条（真机上就是这么发现的同类问题，见 core/ReelsAction 的说明）。
     */
    ReelsAction.publish(this.source, false, '', '');
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
    /*
     * **离开这一页时把控件恢复出来**。
     *
     * 控件是"整页沉浸"状态，忘了复位的话：从隐藏状态切走再切回来，标题栏/底栏一开始就是
     * 藏着的，用户会以为"页面坏了"（外壳那边也有一道复位，见 Index 的 selectTab，
     * 这里是本组件的兜底）。
     */
    if (this.chromeHidden) {
      AppStorage.setOrCreate(REELS_CHROME_HIDDEN, false);
    }
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
    if (index < 0 || index >= this.reels.length) {
      return;
    }
    /*
     * **"到底了还想往下"要能补货** —— 这一段必须放在下面的去重 `return` 之前。
     *
     * 滑到最后一条再往上划，Swiper 会弹一下（`onAnimationStart` 报的还是同一个 index），
     * 放在后面的话 `index === this.activeIndex` 一命中就直接 return，`requestMore` 一次都不发，
     * 表现就是"到最底怎么划都没反应"（用户报的那条）。视图模型那边有 `busy` 兜着，
     * 重复调用不会并发发请求。
     */
    if (index >= this.reels.length - PREFETCH_DISTANCE) {
      this.vm.requestMore();
    }
    if (index === this.activeIndex) {
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
  }

  /**
   * 单击**画面之外**（左右 16vp 留白 / 上下模糊带）→ 隐藏或恢复全局控件（需求第 4 条）。
   *
   * 只写一个 AppStorage 键：信息层（ReelOverlay，@StorageLink）、每条画面（ReelSlide，
   * @StorageProp）、外壳的标题栏与底栏（pages/Index，@StorageLink）各自订阅同一个值，
   * 于是"所有视频的信息层 + 标题栏 + 底栏"一起动 —— 需求要的就是"隐藏后是所有视频隐藏"。
   *
   * 为什么在这里而不是每条画面自己记：这个手势落在**画面之外**，属于"页面级"的命中区域；
   * 而受影响的层里有三个根本不在本组件里（标题栏 / 底栏 / 别的条目的信息层）。
   */
  private toggleChrome(): void {
    const next: boolean = !this.chromeHidden;
    hilog.info(DOMAIN, TAG, 'chrome hidden=%{public}s', `${next}`);
    AppStorage.setOrCreate(REELS_CHROME_HIDDEN, next);
  }

  /** 从视图模型回读（不依赖回调时序，见 ProfilePage 里同一个坑）。 */
  private syncFromVm(): void {    const list: Array<Reel> = this.vm.list();
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
    hilog.info(DOMAIN, TAG, 'active cover idx=%{public}d len=%{public}d reels=%{public}d',
      this.activeIndex, this.activeCoverUrl().length, this.reels.length);
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
   * 当前活动那条视频的封面地址（整页背景用它，见页面根 Stack 的说明）。
   *
   * 为什么从"活动下标"取、而不是从每页 builder 的参数取：背景一旦做进每一页，就会
   * **跟着 Swiper 一起横向滑动** —— 用户看到的就是"还在看当前这条，背景已经变成下一条了"。
   * 放在页面级、只取当前活动那条，背景就不会跟着手指跑。
   */
  private activeCoverUrl(): string {
    const index: number = this.activeIndex;
    if (this.reels.length === 0) {
      return '';
    }
    if (index >= 0 && index < this.reels.length) {
      const reel: Reel = this.reels[index];
      if (reel.coverUrl.length > 0) {
        return reel.coverUrl;
      }
    }
    /*
     * 兜底：活动下标越界 / 那一条没封面时，退到**列表里第一个有封面的**。
     * 不这么做的话，背景层会因为 URL 为空**整层不渲染**（用户报的"背景模糊直接消失了"）。
     */
    for (let at: number = 0; at < this.reels.length; at++) {
      if (this.reels[at].coverUrl.length > 0) {
        return this.reels[at].coverUrl;
      }
    }
    return '';
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
      /*
       * **每条视频自己的整屏模糊背景**（用户要求：背景与屏幕等高、逐条独立、滑动时跟着视频动）。
       *
       * 放在 `reelPage` 里的意义就在"跟手"：它是 Swiper 的**一页**，所以手指滑动时，
       * 背景和画面一起横向移动；翻过去之后自然就是下一条的封面。
       * 尺寸给 `100% × 100%`：铺满整页高度（不是跟着视频比例，也不理会封面原图比例）。
       *
       * 之前这一层"看不见"，根因不是位置、不是比例，而是**信息层 `ReelOverlay` 有一块不透明的黑底**
       * （已在本轮改透明），所以现在能看到它了。
       */
      Image(reel.coverUrl.length > 0 ? reel.coverUrl : $r('app.media.startIcon'))
        .draggable(false)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Fill)
        /*
         * 用户反馈："亮度很高" → 去掉之前的 `brightness(1.35)`（那是为了让暗场景不像黑边，
         * 代价就是亮场景发白）；"模糊程度调最高" → blur 拉到 120，再压一档透明度让它沉下去。
         */
        .blur(120)
        .opacity(0.75)
        .hitTestBehavior(HitTestMode.None)
      /*
       * **"画面之外"那一层：单击 = 隐藏 / 恢复全局控件**（需求第 4 条）。
       *
       * 为什么放在画面**下面**（先画 = 层级更低）：
       *   · 需求把左右滑分成两域 —— 起点在画面内，横滑是拖进度；起点在留白里，横滑还是切段。
       *     命中关系天然满足：手指落在画面上时这一层被卡片挡住（默认 HitTestMode 会阻塞兄弟），
       *     落在留白/模糊带里时卡片没被命中，于是这一层收下这一下（只挂 onClick，不挂横滑手势，
       *     所以留白上的左右滑照旧交给外层 Tabs）；
       *   · 千万不要给它加 `HitTestMode.Transparent`：那样画面上的点击会**同时**落到这层，
       *     点一下画面就既暂停又切控件（StoryViewer 里那条注释讲的就是这个坑）。
       *
       * 注意它盖不到 HDS 标题栏那一条（标题栏在外壳那层、压在本页上面），标题栏区域的单击
       * 由 pages/Index 里那层"标题栏热区"接（见那里的说明）。
       */
      // **已删除**：这层整屏透明 Column（点它 = 隐藏/恢复全局控件）会和画面里的
// `XComponent` 抢触摸，导致画面上的单击/长按/横滑全部失效。隐藏控件改由长按承担
// （需求第 5 条本来就是"长按 → 暂停 + 隐藏控件"）。
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
          segment: this.segment,
          playing: index === this.activeIndex && !this.frozenAll,
          // 预加载下一条：一直开着（原先按网络开关过，实测会影响切换观感；
          // 播放器的预下载缓冲已经收到 2 秒，这一项的开销有界）。
          preload: index === this.activeIndex + 1,
          // 静音开关是全局的（媒体区那颗喇叭键），见 AppSettings.SETTING_VIDEO_MUTED。
          muted: this.videoMuted,
          /*
           * 信息层护栏高度：手势要判断"这一下有没有压在信息层上"（见 ReelSlide.overOverlay）。
           * 宿主给了底部留白就用它，没给用默认值（和 ReelOverlay.infoPadding 同一个口径）。
           * 这个值整页固定，不会在翻页过程中变。
           */
          overlayGuardBottomVp:
          (this.infoBottomVp > 0 ? this.infoBottomVp : INFO_BOTTOM) + OVERLAY_GUARD_EXTRA_VP,
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
      /*
       * **圆角卡片**（需求：视频做成圆角卡片、左右各留 16vp；其它组件不动）。
       *
       * 宽度用 `calc(100% - 32vp)` 而不是 `width('100%') + margin` ——
       * 后者在 ArkUI 里会溢出父容器、把右侧裁掉一截（本项目踩过）。
       * 圆角靠 `.borderRadius` + 已有的 `.clip(true)` 一起生效，
       * 于是里面的封面/播放器/首帧叠层都会跟着被裁成圆角。
       */
      .width('calc(100% - 32vp)')
      .borderRadius(16)
      /*
       * **边缘阴影**（需求：视频卡片要有一圈外阴影 —— 卡片浮在模糊背景上，边界才立得住）。
       *
       * 参数理由：半径 24 / 下移 10 是"看得出投影但不脏"的一档（再大就在模糊背景上糊成一片黑边）；
       * 颜色用 40% 黑，深色夜景视频上不会显出一条灰边。
       * 顺序上放在 `.clip(true)` **之前**没影响：clip 裁的是内容，阴影画在盒子之外。
       */
      .shadow({ radius: 24, color: '#66000000', offsetX: 0, offsetY: 10 })
      .aspectRatio(this.videoAspect(reel))
      /*
       * **画面高度上限 90%**：让背景在上下各露出约 5%（留出来的是高模糊封面，不是黑边）。
       */
      .constraintSize({ maxHeight: '90%' })
      .align(Alignment.Center)
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
        infoBottomVp: this.infoBottomVp,
        // 当前这条才去单独问关注状态（见 ReelOverlay.ensureFollowState）。
        active: index === this.activeIndex,
        onLike: this.onLike,
        onRepost: this.onRepost,
        onSave: this.onSave,
        onFollow: this.onFollow,
        onOpenUser: this.onOpenUser,
        onComments: this.onComments,
        onOpenPostCard: this.onOpenPostCard,
        onShare: this.onShare,
        onMore: this.onMore
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    /*
     * **这里原来是不透明的黑**（`Color.Black`）—— 就是用户怀疑的那层"蒙版"。
     *
     * 这是信息层（作者行 / 右侧动作栏 / 文案），铺满整页、且画在**画面与背景之后**，
     * 一块纯黑把下面的高模糊背景整块盖住：所以无论背景做得多亮、多糊都看不到。
     * 改成透明后，只有它自己的控件会画出来，空隙处透出背景。
     */
    .backgroundColor(Color.Transparent)
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      /*
       * **页级背景：纯黑**。
       *
       * 这里原来铺的是「当前视频封面的高模糊 + 提亮」—— 和每条视频各自那层背景重复，
       * 而且分段页被拖出边界时会整块露出来（看到的就是一张糊照片）。
       * 现在只留纯黑：每条的背景由它自己的 slide 负责（见 ReelSlide），页级不再画任何图。
       */
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .hitTestBehavior(HitTestMode.None)
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
        /*
         * **整页背景：当前活动那条视频封面的高模糊版本**（需求："reels 背景用高模糊的视频封面"）。
         *
         * 关键点：它放在 **Swiper 之外**、只取 `activeIndex` 那一条。放在每一页里面的话，
         * 背景会跟着手指横向滑动 —— 用户看到的就是"当前视频还在看，背景已经换成下一条了"
         * （这正是你反馈的现象）。放在这里之后：背景不跟手，翻页完成那一刻才换成新那条。
         * 用 200ms 透明度过渡盖住这一下切换。
         */
        /*
         * 注：整页的背景层已移到 `reelPage` 里（每条视频各自一层，滑动时跟手）。
         * 这里不再画全局背景，避免两层叠在一起、也让"背景跟着视频动"成立。
         */
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
        /*
         * **不绑 `.index(...)`**（见类里那段"滑动切换动画不连贯"的说明）：位置只由手势和
         * 控制器决定，重建后靠下面 onAppear 里的 `changeIndex(activeIndex, false)` 摆回来。
         * 绑 `.index()` 的话，`switchTo` 在动画一开始写的那几个 `@State` 会触发重绘、
         * 把 `.index(目标页)` 重新应用一次 —— 动画当场"瞬移"结束（实测 12~25ms）。
         */
        .onAppear((): void => {
          // 重建后把位置摆回上次那一条（受控 `.index()` 已经去掉了，这里是唯一的位置恢复点）。
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
          // 只切"正在播哪一条"，**不动 Swiper 的位置**（位置归它自己的动画）。
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
