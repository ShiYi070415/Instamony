/*
 * 原生信息流：空态 + 帖子卡片列表。
 *
 * 数据与业务回调都从页面传进来，这里只管画。
 *
 * 注意 @Prop posts 是「整体替换」语义：view-model 每次都会交出新的数组，
 * 所以列表能跟着刷新（逐条改字段不会触发，当前流程也不这么做）。
 */

import { display } from '@kit.ArkUI';
import { FeedMapper } from '../model/FeedMapper';
import { MediaPost } from '../model/MediaPost';
import {
  AppSettings,
  FEED_POSTER_READY,
  MATERIAL_THICKNESS_ULTRA_THIN,
  SETTING_DARK_UI,
  SETTING_MATERIAL_THICKNESS,
  SETTING_OVERLAY_BACKDROP_LIGHT,
  SETTING_VIDEO_MUTED
} from '../core/AppSettings';
import { MediaPrefetch } from '../core/MediaPrefetch';
import { BackdropTone } from '../core/BackdropTone';
import { PosterCache } from '../core/PosterCache';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { SaveState } from '../core/SaveState';
import { RepostState } from '../core/RepostState';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedSkeleton } from './FeedSkeleton';
import { TranslateLabel } from './TranslateLabel';
import { Translator } from '../core/Translator';
import { StoriesTray } from './StoriesTray';
import { StoryHeroRect, StoryTrayItem } from '../model/Story';
import { MediaCarousel, DOT_ROW_HEIGHT } from './MediaCarousel';
import { VideoSurface } from './VideoSurface';
import { MediaDownloadButton, MediaMuteButton } from './MediaActionButtons';
import {
  CAPTION_COLLAPSED_MAX_LINES, CAPTION_LESS, CAPTION_MORE, CAPTION_TAIL_SAFETY_VP,
  CaptionFit
} from '../core/CaptionFit';
import {
  holdsScroll,
  immersiveMaterial,
  MATERIAL_BUTTON_SIZE,
  MATERIAL_PILL_HEIGHT,
  MATERIAL_PILL_WIDTH,
  MaterialIconButton,
  MaterialLabelButton,
  SurfaceModifier,
  TONE_ACCENT,
  trackMaterialTouch,
  trackScrollTouch
} from './MaterialSurface';
import {
  BURST_TOTAL_MS,
  LikeBurst,
  LikeBurstState,
  LikeIcon,
  playLikeBurst,
  RepostIcon,
  SaveIcon
} from './AnimatedIcons';

/**
 * 位置还原的重试时刻（毫秒）。
 *
 * 见 restoreAnchor：切 tab 时 List 是新建的，头一两帧还没量完布局，scrollToIndex 可能静默失效。
 */
const RESTORE_TRIES_MS: number[] = [0, 140, 360];
/** 打日志用的域（和 VideoSurface 同一个域，方便一起抓）。 */
const DOMAIN: number = 0xFF00;
/** 日志 tag：`hilog -T FeedList` 单独抓这一路。 */
const TAG: string = 'FeedList';

  /** 滚动触发的「取更多」去抖窗口：同一个窗口内只放行一次。 */
const ASK_COOLDOWN_MS: number = 1200;

/**
 * 点赞 / 评论计数的紧凑写法：超过一千用「XX.X千」。
 *
 * 单位走资源（en_US 里是 K），免得把中文单位硬编码进两种语言的界面。
 * 0 当作「没解析到」不显示 —— 否则每张卡都挂着一个 0。
 */
function countText(value: number): ResourceStr {
  if (value <= 0) {
    return '';
  }
  if (value > 1000) {
    return $r('app.string.count_thousands', (value / 1000).toFixed(1));
  }
  return `${value}`;
}
/** 距列表末尾还有几条就开始预取。 */
const PREFETCH_DISTANCE: number = 3;
/** 媒体区右下角那排按钮之间的间距（vp）。 */
const MEDIA_BUTTON_GAP: number = 10;
/** 媒体区右下角那排按钮离媒体边缘的内缩（vp）。 */
const MEDIA_BUTTON_INSET: number = 10;
/** 关注按钮两个事件入口的去重窗口（毫秒），见 FeedList.tapFollow。 */
const FOLLOW_TAP_DEDUPE_MS: number = 400;
/**
 * 封面图预下载往后看几张（见 prefetchAhead）。
 *
 * 比 PREFETCH_DISTANCE（翻页预取）小：翻页是「再拿一页数据」，这里是「先把封面图抓进缓存」，
 * 一次抓太多会跟当前正在看的这张抢带宽，反而更卡，所以只多要三张。
 */
const PREFETCH_AHEAD: number = 3;
/**
 * 每条帖子预下载几张封面（需求：多图帖子下**两张**）。
 *
 * 为什么是两张：多图轮播（carousel）里第一张就是卡片上显示的那张，第二张是用户往左翻一下
 * 立刻会看到的；再往后的图等他真翻到再下，否则一条十图的帖子会把整组图都拉下来（几 MB）。
 */
const PREFETCH_IMAGES_PER_POST: number = 2;
/**
 * 预加载「往后第几条之内的视频」。
 *
 * 只预加载紧邻的下一条视频的前后这几条范围内找到的那条：视频之间常隔着几条图片帖，
 * 而 List 的 cachedCount 只多建 3 张卡片 —— 找得太远，那张卡根本没建出来（没有 XComponent），
 * 预加载也就无从谈起。往前看 3 条足够覆盖"下一条视频"。
 */
const PRELOAD_LOOKAHEAD: number = 3;
/**
 * 判定「视频在屏幕上」的可见比例阈值。
 *
 * 0 表示露出一点就开播、完全离开屏幕就停 —— 与需求一致。
 * 想让开播更保守（例如必须露出三成才播），把它调大即可。
 */
const VISIBLE_RATIO: number = 0;
/**
 * **长视频换焦点所需的占屏比例**（需求："长视频超出屏幕 50% 才聚焦下一条帖子"）。
 *
 * 当前焦点是竖版视频时，新的候选帖子必须**占据屏幕的 50% 以上**才能顶掉它 —— 不然就会出现
 * "刚往上滑一点点、长视频还没看完就被换掉"。当前焦点已经滚出可见集合时不设这道门槛。
 */
/**
 * 聚焦判据的四个比例（都以**可视区高度**为基准，这样和媒体高度无关、设备无关）。
 *
 * 见 `refreshFocus` 头部那段说明。四者是"进入 / 抢夺 / 两个滞回带"：
 *   · 进入：没有焦点时，最佳候选的可见高度至少占可视区这么多（0.25 屏）；
 *   · 抢夺：想顶掉当前焦点，自己至少得占这么多（0.50 屏）——防止"刚滑一点就换"；
 *   · 主滞回：比当前多露出这么多才允许顶掉（0.10 屏）；
 *   · 平局带：两者可见高度差在这个带内（0.10 屏）时，用"中心更近"或"完整度更高"裁决。
 *
 * 调参口诀：觉得"换得太勤"就把前三个调大；觉得"该换不换"就把主滞回调小。
 */
const FOCUS_MIN_ENTER_RATIO: number = 0.25;
const FOCUS_MIN_SWITCH_RATIO: number = 0.50;
const FOCUS_MARGIN_RATIO: number = 0.10;
/** 平局时"中心更近"要领先多少（同样是可视区高的比例）。 */
const FOCUS_MARGIN_CENTER_RATIO: number = 0.08;
/**
 * 滚动中重算焦点的**最小间隔**（毫秒）：见 `refreshFocusThrottled`。
 *
 * 120ms 这个量是"跟手"与"别浪费"之间的经验值：一次重算要给可见的每张卡片量一次矩形
 * （`getRectangleById`），按帧跑纯属浪费；而人眼在长视频滚动这个尺度上分辨不出 120ms 的差。
 */
const FOCUS_SCROLL_THROTTLE_MS: number = 120;
/** 滚动中"位移多少才算值得重算焦点"（vp）；不到这个量几何几乎没变，见 refreshFocusThrottled。 */
const FOCUS_MIN_MOVE_VP: number = 8;
/** 焦点重算的心跳（毫秒）：慢速微调攒不够位移时，也必须至少这么久收敛一次。 */
const FOCUS_HEARTBEAT_MS: number = 320;
/** 叠字行组件的 id 前缀（见 overlayRowId）。 */
const OVERLAY_ROW_ID_PREFIX: string = 'overlayRow-';
/** 滚动时叠字行位置的重测间隔（毫秒）。 */
const OVERLAY_BAND_SYNC_MS: number = 200;
/**
 * 媒体区最高占屏幕高度的比例。
 *
 * 媒体改成「宽度铺满、高度按真实宽高比」之后，4:5 的竖图和 9:16 的竖视频会长到
 * 几乎占满一屏 —— 一屏连一张卡片都放不下，往下滑还看不到下一张的开头。
 * 这里压一个上限：高过这个比例就不再长高，多出来的宽度让图片自己留白（Contain，不裁切）。
 * 想让媒体区更高/更矮，只改这一个数。
 */
const MEDIA_MAX_HEIGHT_RATIO: number = 0.62;

/**
 * 列表内容起始位置相对显示区上边界的内缩（vp）。
 *
 * 为什么用 contentStartOffset 而不是给列表加 margin —— 这两者看着像，行为完全不同：
 *   margin / padding：把**可视区域**往下推，列表边界跟着下移。往上滚时内容撞到这条
 *                     边界就被裁掉，标题栏下方会留出一条「内容消失的横带」。
 *   contentStartOffset：只把**内容的起点**内缩，列表自身仍然铺到最顶端。静止时第一张
 *                     卡片在标题栏下方，往上一滚，内容就穿过这条内缩量、从屏幕顶端
 *                     （标题栏的沉浸材质下面）穿过去 —— 也就是想要的「穿过屏幕顶端」。
 *
 * 取值 = 状态栏高度 + MINI 模式标题栏高度（38 + 56 = 94vp）。
 * 一开始只给了标题栏的 56，实机上第一张卡片仍被压住 —— 说明这套配置下 HDS 标题栏
 * 除了自身那 56，还把状态栏那一段也占住了，所以要连状态栏一起让出来。
 * 之所以要自己给：HdsNavigation 配了 ignoreLayoutSafeArea（背景铺到系统栏下方才有
 * 沉浸光感），这套配置的前提就是「安全区由你自己负责」，官方示例也是自己算留白的。
 * 换设备若仍差一点，改这一个数即可；要做到与设备无关，可以改成读窗口的 avoidArea。
 *
 * 这个值现在同时是 build 里那层**透明占位 Stack** 的高度：占位垫在 Refresh 上面，
 * 把下拉刷新的原生图标从屏幕顶端（被标题栏压住）挪到标题栏下方（见 build 的说明）。
 */
export const FEED_START_OFFSET: number = 94;
/**
 * 限时快拍托盘与下面第一张卡片之间的额外间隔（vp）。
 *
 * 需求："story 序列和 feeds 流多加 5vp 间隔"。托盘是列表里的第一个 ListItem，所以给它的
 * **下边距**加这一条就行（托盘自己那 26vp 的底部留白是给用户名的，不够松）。
 */
const TRAY_FEED_GAP_VP: number = 5;

/**
 * 列表末尾给底部**悬浮**标签栏让出的高度（vp）。
 *
 * 底部栏换成了 HDS 的悬浮 HdsTabs（barOverlap + barBottomMargin 28）：它是浮在内容
 * 之上的，最后一张卡片的正文会被压在栏下面看不见。用 contentEndOffset 而不是 margin ——
 * 和顶部一样，只内缩内容终点，列表本身仍铺到底，滚到底时能滑上来。
 * 取值 ≈ 栏高 56 + 悬浮边距 28 + 余量。
 */
const FEED_END_OFFSET: number = 96;

/** 列表本身的 id：用来量出可视区范围（判断帖子有没有「完全显示在屏幕」）。 */
const LIST_ID: string = 'feed-list';
/** 卡片根节点的 id 前缀：聚焦判据量的是整张卡片。 */
const CARD_ID_PREFIX: string = 'feedcard-';
/**
 * **媒体盒子**节点的 id 前缀（见 mediaId / mediaSpan）。
 *
 * 聚焦播放要的是"这块媒体在屏幕上露出多少"，不是"整张卡片占了多少" —— 卡片还含表头、
 * 正文、动作区，高度和媒体高度在长短文案/长视频之间差别很大（这正是"不同媒体高度下
 * 聚焦不灵"的主因之一）。
 */
const MEDIA_ID_PREFIX: string = 'feedmedia-';
/**
 * 几何记忆的有效期（毫秒）：`getRectangleById` 量不到时，用这段时间内量到的值顶上。
 *
 * 250ms 足够覆盖"卡片被回收/重建"的一个或几个刷新周期（`FOCUS_SCROLL_THROTTLE_MS` = 120ms）；
 * 再长就会把"已经滚出屏幕"的旧位置当成真的，焦点会粘在屏幕外那条上。
 */
const FOCUS_GEOM_TTL_MS: number = 250;
/**
 * 视为「竖版」的宽高比上限。
 *
 * 9:16 是 0.5625、4:5 是 0.8 —— 取 0.7 正好把 9:16 这类竖视频和 4:5 分开。
 * 竖视频特别高，一屏常常放不下整条，所以「完全显示在屏幕」的优先权给它。
 */
const TALL_MEDIA_MAX_ASPECT: number = 0.7;

/**
 * 资料行（头像 + 用户名 + 更多）的高度（vp）。
 *
 * 沉浸式视频里它要叠在视频上，所以这个值同时决定"视频被资料行盖住多少"。
 */
const PROFILE_ROW_HEIGHT: number = 52;

/**
 * 沉浸式视频的宽高比上限：**只有竖向（高 > 宽）的视频**才把资料行叠到画面上。
 *
 * 需求：竖向的（宽高比 < 1）才启用"标题资讯沉浸"，横向和方形都让资料行显示在媒体外面。
 * 宽高比 = 宽 / 高，所以判据就是 < 1：
 *   竖版 9:16 = 0.5625 → 沉浸；方形 1.0 → 不沉浸；16:9 = 1.7778 → 不沉浸。
 * 边界取严格小于：正好 1:1 的方形算"横向不小于竖向"，按需求走普通布局。
 */
const IMMERSIVE_VIDEO_MAX_ASPECT: number = 1;

/**
 * 发布时间文案的分档（见 postedAgo）。
 *
 * 用固定档位而不是 Date 的本地化格式：一是这里只需要"多久以前"，二是 ArkTS 侧
 * 走资源串更稳（en_US 也有对应文案），三是不会因为语言环境不同而突然变成别的样子。
 */
/**
 * 「为你推荐」卡片里那颗星的字号（vp）。
 *
 * 需求（原话）："星星 symbol 太小，可以放大并且垂直置中"。16 看着偏小，
 * 22 大致与两行文字（14 + 12 + 行距）齐高，卡片也不会被撑高。
 */
const HINT_STAR_SIZE: number = 22;

const AGO_MINUTE_MS: number = 60 * 1000;
const AGO_HOUR_MS: number = 60 * AGO_MINUTE_MS;
const AGO_DAY_MS: number = 24 * AGO_HOUR_MS;
const AGO_WEEK_MS: number = 7 * AGO_DAY_MS;
const AGO_MONTH_MS: number = 30 * AGO_DAY_MS;
const AGO_YEAR_MS: number = 365 * AGO_DAY_MS;

/** 正文（caption）字号：**测量和渲染必须用同一个值**，所以提成常量（见 captionPrefix）。 */
const CAPTION_FONT_SIZE: number = 14;
/** 正文左右内边距（vp）：算可用宽度时要减掉。 */
const CAPTION_SIDE_PADDING: number = 12;
/**
 * 折叠排版（最多几行、尾巴上的" ... 展开" / " 收起"、量宽度时的安全余量）统一在
 * core/CaptionFit 里 —— Reels 页那段正文用的是**同一套判据**，两处必须一致。
 */
/**
 * 展开 / 收起的过渡时长（毫秒）。
 *
 * 展开会让卡片长高很多，用匀速偏缓的曲线（EaseInOut）比弹簧稳：
 * 弹簧过冲时，卡片高度的回弹会把下面整列内容一起带着弹，看着很晃。
 */
const CAPTION_TOGGLE_MS: number = 260;

/**
 * 一段内容在窗口坐标里的竖直范围（px）。
 *
 * measurable 为 false 表示这次量不到（节点还没布局、或已被列表回收）。
 * 用一个类而不是返回两个数，是因为聚焦判据同时要用到上下边界和中心。
 */
class CardSpan {
  readonly top: number = 0;
  readonly bottom: number = 0;
  readonly measurable: boolean = false;

  constructor(top: number, bottom: number, measurable: boolean) {
    this.top = top;
    this.bottom = bottom;
    this.measurable = measurable;
  }

  center(): number {
    return (this.top + this.bottom) / 2;
  }
}

/**
 * 一条媒体**几何记忆**（见 mediaSpan / knownGeom）。
 *
 * 为什么需要：卡片被 List 回收的那一两个刷新周期里，`getRectangleById` 会抛错 ——
 * 旧实现把这种"量不到"当成了"不在屏幕上"，于是焦点跳到邻居、正在播的视频停掉
 * （日志里的 `focus: visible set empty` / `keep lost`）。有了这份缓存，
 * "卡片正被回收"和"真的滚出屏幕"就能区分开。
 */
class GeomEntry {
  readonly top: number;
  readonly bottom: number;
  /** 量到的时刻（毫秒）。 */
  readonly at: number;
  /** 这一份是怎么来的：`node`（媒体节点）/ `card`（卡片折算）。 */
  readonly source: string;

  constructor(top: number, bottom: number, at: number, source: string) {
    this.top = top;
    this.bottom = bottom;
    this.at = at;
    this.source = source;
  }
}

/**
 * 聚焦判据的一个候选（见 refreshFocus 的三把尺子）。
 *
 * · `visPx`  ：这块媒体在可视区里露出的像素（主尺子 = 占了屏幕多大一块）
 * · `full`   ：`visPx / min(媒体高, 可视区高)`，0..1（副尺子 = 被看全了没有）
 * · `centPx` ：媒体中心离可视区中心的距离（第三把尺子，用来打破高度相同的平局）
 */
class FocusCand {
  readonly index: number;
  readonly key: string;
  readonly visPx: number;
  readonly full: number;
  readonly centPx: number;
  /** 这块媒体最多能被看到多少 px（= min(媒体高, 可视区高)），只用于日志/诊断。 */
  readonly capPx: number;

  constructor(index: number, key: string, visPx: number, full: number, centPx: number,
              capPx: number) {
    this.index = index;
    this.key = key;
    this.visPx = visPx;
    this.full = full;
    this.centPx = centPx;
    this.capPx = capPx;
  }
}

/**
 * 双击点赞允许的手指位移（vp）。
 *
 * TapGesture 的 distanceThreshold 不设时默认是 2^31-1 —— 也就是「手指只要没划出这个
 * 组件的范围，就算一次点击」。多图轮播上快速滑两下，每次滑动都在图片范围内，于是被
 * 当成两次点击、凑成一次双击，直接把帖子赞了。
 * 限成 12vp 后：真正的双击手指几乎不动，照常识别；滑动一下就远超这个距离，点击直接
 * 判定失败，不会再误触发。
 */
const LIKE_TAP_DISTANCE_VP: number = 12;

/**
 * 「放大爱心」的瞬时状态。
 *
 * 为什么需要一个 @Observed 对象：爱心画在每张卡片的媒体上，而卡片是 ForEach 渲染的 ——
 * ForEach 对键值没变的项不会重跑 item builder，普通 @State 变了爱心根本不会出现。
 * 把 key 塞进卡片键值倒是能出现，但那一项会被**重建**，视频会被重启、轮播图会被重置。
 * @ObjectLink 让这个对象的属性变化直接通知到每张卡片里的爱心组件、就地更新。
 *
 * 类体在 components/AnimatedIcons（feeds / reels 共用）。
 */

/*
 * 放大爱心 / 动作图标动画的实现都在 components/AnimatedIcons（feeds 与 reels 共用一套，
 * 免得两边各写一份走样）。这里只留 PostUi / 卡片这边的接线。
 */

/**
 * 一条帖子「会就地变」的界面状态。
 *
 * 为什么需要它：点赞状态和各项计数原来是塞进 ForEach 键值的 —— 本项目里 ForEach 对
 * 键值没变的项不会重跑 item builder，所以想让心形变实、计数刷新只能那么做。但代价是
 * 键值一变**整张卡片被销毁重建**：多图轮播跳回第一张、正在播的视频从头开始、图片重新解码。
 *
 * 现在把键值缩回「稳定身份」，这几个会变的值放进 @Observed 对象、由动作区用 @ObjectLink
 * 订阅：变化就地更新，卡片本身不动。
 */
@Observed
class PostUi {
  liked: boolean = false;
  likeCount: number = 0;
  commentCount: number = 0;
  /** 本机是否转过这条：为真时转发图标中间叠一个对勾（见 PostActions）。 */
  reposted: boolean = false;
  repostCount: number = 0;
  shareCount: number = 0;
  /**
   * 作者是否已关注（「关注」按钮的标签靠它就地更新）。
   *
   * 为什么要放这儿、而不是页面状态的 Map：本项目里 ForEach 对**键值没变**的项不会重跑 item
   * builder，光改外部状态按钮标签不会刷新（和点赞同一个坑）。放进 @Observed 对象、由
   * FollowPill 用 @ObjectLink 订阅，点一下就地变成「已关注」。
   */
  following: boolean = false;
  /**
   * 本机是否**收藏**了这条（信息流动作区最右边那颗书签按它画）。
   *
   * 数据源一般不给收藏状态（见 model/Reel.saved 的同款说明），权威来源是
   * **core/SaveState 的会话覆盖表** —— 用户在 reels 页收藏过的同一条，这里也要实心。
   */
  saved: boolean = false;
}

/**
 * 「关注 / 已关注」按钮。
 *
 * ## 为什么要有这个组件（而不只是行内直接写 Toggle）
 * 状态刷新：关注状态在 `PostUi`（@Observed）里，**只有 @ObjectLink 订阅者会跟着重绘**，
 * 而卡片是 ForEach 的 item builder 产出的 —— 键值没变时它**不会重跑**，所以"行内直接读
 * `ui.following`"或者"读一个页面级 @State"都不会让按钮标签变（用户报的"关注按钮点击无反应"：
 * 请求其实发出去了，只是标签一直停在原样）。这里让**这一颗按钮自己**持有 @ObjectLink，
 * `toggleFollow` 一改 `ui.following`，它就地重绘。
 *
 * ## `isOn` 必须绑状态、回调必须带**目标值**（这一条踩过坑）
 * 上一版这里是 `Toggle({ isOn: false })`（字面量）+ 回调里"按取反切换"。点了以后先乐观切成
 * 「已关注」→ 这一颗重绘 → Toggle 的内部状态被字面量**复位**成 false → 又报一次 `onChange(false)`
 * → 于是紧接着发出第二条请求（取关）→ 服务端两个来回抵消，界面看着就是
 * **"点一下会回滚、而且没有真的关注/取关"**。
 * 现在照 MaterialSurface 那套写：`isOn` 绑 `ui.following`（内部状态与之一致，重绘不会再报事件），
 * 两个入口都交**目标状态**（`onTap(on)`），由 FeedList 那边做幂等 + 去重 + 请求中互斥。
 *
 * ## 为什么 build 里全是内置组件、尺寸也写在里面
 * 以前这里是个 `FollowPill`，内部再套 `MaterialLabelButton`（自定义组件套自定义组件）：
 * 真机实测**部分帖子的这一颗会整个消失**（量成 0 宽，前面的名字容器把空间吃光）。
 * 现在根节点就是**内置的 Toggle**（尺寸写在它自己身上，不是写在组件实例上），
 * 里面只有 Text，和资料行里那个名字容器同一种写法 —— 那条路从来没出过这个问题。
 */
@Component
struct FollowPill {
  /** 订阅这张卡片的会变状态（关注状态在 `following`）。 */
  @ObjectLink ui: PostUi;
  /** 材质厚度（跟设定页联动）。 */
  @Prop thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 点一下，带**目标状态**（true = 关注，false = 取关）。 */
  onTap: (on: boolean) => void = (on: boolean): void => {
  };

  build() {
    Toggle({ type: ToggleType.Button, isOn: this.ui.following }) {
      Text(this.ui.following
        ? $r('app.string.action_following') : $r('app.string.action_follow'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        // 文字白色（需求）：材质底是无彩色玻璃，用系统可反色资源色。
        .fontColor($r('sys.color.font_primary'))
    }
    // 尺寸写在这里（自定义组件实例上的 .width() 不生效，见本文件的说明）。
    .width(MATERIAL_PILL_WIDTH)
    .height(MATERIAL_PILL_HEIGHT)
    .padding(0)
    .borderRadius(MATERIAL_PILL_HEIGHT / 2)
    .backgroundColor(Color.Transparent)
    // 选中态透明：否则点一下整颗变蓝（同 MaterialSurface 的说明）。
    .selectedColor(Color.Transparent)
    // 材质：不反色（叠在视频/图片上时跟着主题走），阴影走**全局那套**（第三个参数 = true，
    // 材质自带阴影。需求："将这套阴影套用到所有沉浸光感组件上"）。
    //
    // 这里原来是 false —— 当初的理由是"这条胶囊比圆按钮宽得多，投影会在圆角上画出一圈明显的
    // 边界"。现在按统一观感打开；哪天觉得这一条太抢，把第三个参数写回 false 就行
    // （SurfaceModifier 留着这个开关就是为了这种局部回退）。
    .attributeModifier(new SurfaceModifier(this.thickness, false, true))
    // 两个入口都接、再自己去重：Toggle 的 onChange 在"isOn 传字面量"时不一定会来、
    // 也可能来两次（见 MaterialSurface.fire 的说明），漏了/重了都会表现为"点了没反应"。
    .onChange((value: boolean): void => {
      this.onTap(value);
    })
    .onClick((): void => {
      // 通用点击不带新值：点一下就是翻转，所以目标值 = 取反（和 onChange 给的是同一个值）。
      this.onTap(!this.ui.following);
    })
    .onTouch(trackMaterialTouch)
  }
}

/**
 * 卡片动作区。
 *
 * 单独抽成组件是为了拿到 @ObjectLink：点赞/计数一变只重绘这一行，
 * 媒体（轮播、视频）不受影响。
 */
@Component
struct PostActions {
  @ObjectLink ui: PostUi;
  onLike: () => void = (): void => {
  };
  onComments: () => void = (): void => {
  };
  /** 转发 / 分享：打开帖子页（收藏走 onSave，见下）。 */
  onOpen: () => void = (): void => {
  };
  /**
   * 收藏（书签）：**走 HTTP**（需求："feeds 流的收藏按钮也需要实现功能"）。
   *
   * 乐观翻转由 FeedList 那边做（见 toggleSaved），失败回滚。
   */
  onSave: () => void = (): void => {
  };
  /**
   * 转发：和 onOpen 分开 —— 它要驱动隐藏网页去点 Instagram 自己的转发入口，
   * 不是简单地打开帖子页（找不到入口时才退回打开）。
   */
  onRepost: () => void = (): void => {
  };

  build() {
    // 图标之间不留额外间距，靠按钮自身的内边距控制 —— 整体更紧凑。
    // 图标与计数统一用 Medium 字重，比默认更实一点。
    Row({ space: 0 }) {
      // 点赞：图标 + 计数并排（图标自带"点赞弹一下"动画，见 LikeIcon）
      Button() {
        Row({ space: 4 }) {
          LikeIcon({ liked: this.ui.liked, iconSize: ICON_HEART })
          if (this.ui.likeCount > 0) {
            Text(countText(this.ui.likeCount))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary_text'))
              .flexShrink(0)
          }
        }
        .alignItems(VerticalAlign.Center)
        .flexShrink(0)
      }
      .height(40)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onLike();
      })
      // 评论：图标 + 计数并排
      Button() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(ICON_MESSAGE)
            .fontWeight(FontWeight.Medium)
            .fontColor([$r('app.color.primary_text')])
            .flexShrink(0)
          if (this.ui.commentCount > 0) {
            Text(countText(this.ui.commentCount))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary_text'))
              .flexShrink(0)
          }
        }
        .alignItems(VerticalAlign.Center)
        .flexShrink(0)
      }
      .height(40)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onComments();
      })
      // 转发：在评论与分享之间，计数并排
      // 图标自带两个动画：外层循环箭头转 360° 镜像旋转、内层对勾一笔画出来（见 RepostIcon）。
      Button() {
        Row({ space: 4 }) {
          RepostIcon({
            reposted: this.ui.reposted,
            iconSize: ICON_TRANSFER,
            checkSize: ICON_TRANSFER_CHECK
          })
          if (this.ui.repostCount > 0) {
            Text(countText(this.ui.repostCount))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary_text'))
              .flexShrink(0)
          }
        }
        .alignItems(VerticalAlign.Center)
        .flexShrink(0)
      }
      .height(40)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onRepost();
      })
      // 分享：图标 + 计数并排
      Button() {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.paperplane'))
            .fontSize(ICON_PLANE)
            .fontWeight(FontWeight.Medium)
            .fontColor([$r('app.color.primary_text')])
            .flexShrink(0)
          if (this.ui.shareCount > 0) {
            Text(countText(this.ui.shareCount))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary_text'))
              .flexShrink(0)
          }
        }
        .alignItems(VerticalAlign.Center)
        .flexShrink(0)
      }
      .height(40)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onOpen();
      })
      Blank()
      // 收藏（书签）：实心 = 已收藏（图标自带"收藏弹一下"动画，见 AnimatedIcons.SaveIcon）。
      Button() {
        SaveIcon({ saved: this.ui.saved, iconSize: ICON_BOOKMARK })
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onSave();
      })
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }
}

/**
 * 动作区图标的字号：一个图标一个值。
 *
 * 不同符号的字形大小并不一致（排版宽度都是 1em，但可见轮廓能差一成），所以这几个值
 * 是按肉眼观感调出来的，不是同一条公式算出来的。
 *
 * 曾经想从 SDK 的 HMSymbolVF.ttf 直接量包围盒来推导，这条路走不通：
 * id_defined.json 里的 order 并不是字体里的码位 —— 拿全部 4042 个符号去比对，
 * 有 1608 个对不上（paperclip、desktop、wifi_router_fill 这些常见图标都不在）。
 * 符号名到字形的映射由系统在运行时查表，SDK 里查不到。
 * 所以别把下面的数字当实测值，它们只是手调的默认值，看着不对直接改。
 */
const ICON_HEART: number = 24;
const ICON_MESSAGE: number = 27;
const ICON_TRANSFER: number = 25;
/**
 * 叠在转发图标正中的对勾大小。
 *
 * 转发图标本身**不缩小**（和动作区其它图标一样是满尺寸，实测缩小明显看着"图标变小了"）：
 * 对勾只是叠在它中心的一个标记，外面那层 Stack 固定 ICON_TRANSFER 见方并居中，
 * 所以无论有没有对勾，图标的中心都不动。
 */
const ICON_TRANSFER_CHECK: number = 13;
const ICON_PLANE: number = 24;
const ICON_BOOKMARK: number = 27;

@Component
export struct FeedList {
  @Prop @Watch('onPostsChanged') posts: MediaPost[] = [];
  /**
   * 回到这个列表时要停在**哪一条**（用帖子 key，不是下标）。
   *
   * 为什么需要：切 tab 会把整个内容层销毁重建（见 Index 的内容层），List 是新实例、从头开始，
   * 用户切回来就"回到顶端"了。用 key 而不是下标：下拉刷新会往前面插新帖，下标会漂，key 不会。
   */
  @Prop initialKey: string = '';
  /** 可见区第一条的 key 变化时上报（页面记着它，切回来时用 initialKey 还原）。 */
  onAnchorChange: (key: string) => void = (key: string): void => {
  };
  /**
   * 是否还在等第一屏（或正在重试）。
   *
   * 列表还是空的时候：true 就铺骨架屏，false 才显示「还没有内容 + 加载按钮」。
   * 由页面算出来（在本轮加载中，或还没跑完过一轮加载）。
   */
  @Prop loading: boolean = false;
  /**
   * 是否正在加载下一页（触底分页）。
   *
   * 为 true 时在列表末尾显示一个鸿蒙圆环加载动画；加载状态不再用文字表达。
   */
  @Prop loadingMore: boolean = false;
  /**
   * 下拉刷新是否进行中。
   *
   * 用 @Link 双向绑定而不是 @Prop：Refresh 组件需要能把它置回 false 才会收起转圈，
   * 而「这一轮到底读完没有」只有页面知道（页面在刷新流程结束时置 false）。
   */
  @Link refreshing: boolean;
  onLoad: () => void = (): void => {
  };
  /** 用户下拉到底：请求重新读第一页。 */
  onRefresh: () => void = (): void => {
  };
  /**
   * 滚动中：把这一帧的滚动信息报给页面。
   *
   * deltaY > 0 = 内容往上走（用户在往上滑，想看更下面的帖子）；
   * offsetY = 列表当前的纵向偏移量，页面用它判断「是不是还在顶部」；
   * scrollState = 这一帧的滚动状态（Scroll / Fling / Idle），页面靠它判断"这一轮滚动结束没有"
   * （点击还原之后要作废掉这一轮剩下的增量，见 pages/Index.ets 的 onFeedScroll）。
   *
   * 只报事实、不下判断：多小的增量算「真的在滑」、要不要下沉，都由页面定，
   * 组件本身不认识底部栏。降级档下页面拿到这些增量什么也不做（见 onFeedScroll）。
   */
  onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
    };
  /** 接近 / 到达底部时取更多。 */
  onNearEnd: () => void = (): void => {
  };
  onOpen: (post: MediaPost) => void = (post: MediaPost): void => {
  };
  /**
   * 点了**用户资讯模块**（资料行里的头像 + 用户名那一块）→ 打开用户主页。
   *
   * 需求："从 feeds 点击用户资讯模块后进入新页面"。页面那边走 NavDestination（见
   * pages/Index 的 openUserProfile），这里只把"是谁"报出去。
   */
  onOpenUser: (post: MediaPost) => void = (post: MediaPost): void => {
  };
  /** 点赞 / 取消赞（实际由隐藏网页去点它自己的按钮）。 */
  onLike: (post: MediaPost) => void = (post: MediaPost): void => {
  };
  /**
   * 双击媒体点赞。
   *
   * 和 onLike 分开：双击的语义只有「喜欢」，不该把已赞的取消掉（见 Index.likeByDoubleTap）。
   */
  onLikeMedia: (post: MediaPost) => void = (post: MediaPost): void => {
  };
  /** 打开评论（原生面板展示网页读回来的评论）。 */
  onComments: (post: MediaPost) => void = (post: MediaPost): void => {
  };
  /**
   * 资料行里要不要显示「关注 / 已关注」那颗按钮。
   *
   * 默认 true（首页信息流照旧）。**帖子页传 false**（需求："不用在每项帖子顶栏显示关注按钮"）：
   * 那一页是同一个人的一整段帖子，每张卡片都挂一颗关注按钮既重复又抢眼；关注改到
   * **标题栏右上角**去（只有没关注时才出现，见 pages/Index 的 postPageFollowMenu）。
   */
  @Prop showFollowInRow: boolean = true;
  /**
   * 这一层**现在是不是在最前面**（默认 true = 首页那份行为不变）。
   *
   * 为什么需要：视频是"焦点落在哪条就播哪条"（见 refreshFocus），而**压上一整屏
   * NavDestination 之后本页的可见性回调并不会变**（列表还在布局里、比例也没变）——
   * 于是从首页进用户主页 / 帖子页时，底下的视频会**继续播、继续出声**（用户报的）。
   * `active = false` 时这里一律不播、也不预加载下一条（见 refreshFocus）。
   */
  @Prop @Watch('onActiveChanged') active: boolean = true;
  /** `active` 变了要重算一次焦点（否则"停"这件事不会自己发生）。 */
  private onActiveChanged(): void {
    this.refreshFocus();
  }
  /**
   * 顶部避让段的高度（vp，默认 `FEED_START_OFFSET` = 状态栏 + 标题栏那一段）。
   *
   * 首页现在把限时快拍托盘放进了列表**内部**（`showStories`，见文件头 build 的说明），
   * 所以这一页不再自己让那 94vp，走默认值即可；别的页面不传也是原来的行为。
   */
  @Prop topOffset: number = FEED_START_OFFSET;
  /**
   * 列表最上面要不要放**限时快拍托盘**（首页传 true；帖子页 / Reels 页不传 = 不放）。
   *
   * 为什么托盘放进 List 里而不是摆在 FeedList 外面（第一版是外面，实机证明两处都不对）：
   *   · 摆外面 = 托盘压在标题栏底下（内容区从屏幕顶开始，避让段是 FeedList 自己让的），
   *     而且它**不会跟着信息流滚走** —— 需求要的正是"置顶 + 跟随 feedslist 滚动"；
   *   · 放进 List 里 = 它天然在避让段之后、第一张卡片之前，往上滚时和卡片一起穿过标题栏
   *     （和 Instagram 一致），头像那一排也不会再压住标题。
   * 数据仍由托盘自己拉（StoriesTray 内部取数），这里只把回调转给页面。
   */
  @Prop showStories: boolean = false;
  /**
   * 提示卡片画在**第几条之前**（-1 = 不画）。
   *
   * 首页的列表是两段拼起来的：**关注流 → 提示卡片 → 探索流**（见 FeedViewModel.composePosts）。
   * 卡片位置就是"关注流那几条之后"，所以：
   *   · 关注流有内容 → 卡片夹在关注流末尾与第一条探索流之间；
   *   · 关注流一条都没有（"关注的人的最新帖子已看完"）→ 卡片在**列表最顶上**，下面全是探索流。
   * 用法见下面的 ForEach：卡片画在那条帖子的卡片**上面**（同一个 ListItem 里的 Column），
   * 这样不用把列表拆成两段 ForEach，也不影响卡片重建的键值规则。
   */
  @Prop hintAt: number = -1;
  /**
   * 宿主手上那份托盘数据 + 它的时间戳，原样交给 StoriesTray 当**首帧内容**。
   *
   * 为什么需要：FeedList 跟着 tab 一起被销毁重建（内容层是 `if (selectedIndex === 0)`，
   * 见 Index.nativeShellContent），托盘每次都是新的 —— 没有这份数据就会先空/先灰一块，
   * 再等网络，也就是"每次切换页面都会消失一会才加载出来"。
   * 普通字段（不是 @Prop）：它**只在构造时**用一次，之后托盘自己维护 `items`。
   */
  storySeed: Array<StoryTrayItem> = [];
  storySeedAtMs: number = 0;
  /**
   * 「你的快拍」那一项用的头像（宿主从「我的」头部那份资料顺手带过来）。
   *
   * @Prop：头像是**晚到**的（启动时「我的」头部还在路上），到了要跟着换上去。
   */
  @Prop selfAvatar: string = '';
  /** 让托盘重新拉一次的信号（每 +1 一次，见 StoriesTray.reloadSignal）。 */
  @Prop storyReload: number = 0;
  /** 点「你的快拍」/ 那颗「+」（这一版没有发布入口，宿主给一句提示），见 StoriesTray.onSelfTap。 */
  onStorySelf: () => void = (): void => {
  };
  /** 推荐快拍底部那条「+关注」：宿主负责关注并回结果，见 StoriesTray.onFollow。 */
  onStoryFollow: (item: StoryTrayItem) => Promise<boolean> =
    (item: StoryTrayItem): Promise<boolean> => Promise.resolve(false);
  /** 点开某一项（宿主拉数据 + 开播放页），见 StoriesTray.onOpen。 */
  onStoryOpen: (item: StoryTrayItem, rect: StoryHeroRect) => void =
    (item: StoryTrayItem, rect: StoryHeroRect): void => {
    };
  /** 托盘那一整条顺序交出去（"下一位是谁"要用），见 StoriesTray.onLoaded。 */
  onStoryLoaded: (items: Array<StoryTrayItem>) => void = (items: Array<StoryTrayItem>): void => {
  };
  /** 某一项头像当前的位置交出去（收起播放页时朝它收缩），见 StoriesTray.onRect。 */
  onStoryRect: (userId: string, rect: StoryHeroRect) => void =
    (userId: string, rect: StoryHeroRect): void => {
    };
  /** 托盘里可见的下标范围（首页拿它预加载那几位用户的 story），见 StoriesTray.onVisibleRange。 */
  onStoryVisible: (start: number, end: number) => void = (start: number, end: number): void => {
  };
  /** 翻译失败（宿主弹一句提示；卡片自己已经把状态退回去了）。 */
  onTranslateFailed: () => void = (): void => {
  };
  /**
   * 关注状态的**全局版本号**（见 core/FollowState 的文件头）。
   *
   * 卡片上的关注状态是构建时算一次就定住的（`PostUi.following` → FollowPill 的 @ObjectLink），
   * 所以在**别处**（用户主页那一行、帖子页标题栏、通知页）点了关注，这里不会自己变 ——
   * 用户站在首页看得见的那颗按钮就成了旧值。盯住这个版本号，一变就把每张卡片重算一遍。
   *
   * 值本身不用（读了就够），要的是 @Watch 这一次回调。
   */
  @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
  /** 别处改过关注状态：把本列表每张卡片按覆盖表重算一遍（见 onFollowVersion 的说明）。 */
  private onFollowVersion(): void {
    this.syncFollowStates();
  }
  /**
   * 关注 / 取关（页面那边发请求，见 core/NativeFollow）。
   *
   * 返回 Promise<boolean>：true = 成功。列表在点按的瞬间就把按钮切成新状态（乐观更新），
   * 只有这里回了 false 才回滚 —— 否则点了没反应会让人以为坏了。
   */
  onFollow: (post: MediaPost, follow: boolean) => Promise<boolean> =
    (post: MediaPost, follow: boolean): Promise<boolean> => Promise.resolve(false);
  /**
   * 收藏（书签）：**走 HTTP**（需求："feeds 流的收藏按钮也需要实现功能，所有收藏按钮都走
   * http 请求用探针抓模板"）。宿主那边先发原生 HTTP（探针抓到的模板 / App 主机的 route），
   * 不行再退到网页驱动；返回 true 才算成功。
   *
   * 乐观翻转在本组件里做（见 toggleSaved），失败回滚。
   */
  onSave: (post: MediaPost, save: boolean) => Promise<boolean> =
    (post: MediaPost, save: boolean): Promise<boolean> => Promise.resolve(false);
  /**
   * 转发：驱动隐藏网页去点 Instagram 自己的转发入口。
   *
   * 和 onOpen 分开：找不到入口时才由页面那边退回打开帖子页，这里不替它决定。
   */
  onRepost: (post: MediaPost) => void = (post: MediaPost): void => {
  };
  /** 内联播放失败。 */
  onPlaybackError: () => void = (): void => {
  };
  /**
   * 当前正在播放的帖子 key（见 FeedMapper.keyOf）；空串表示没有在播。
   *
   * 由「焦点落在哪条帖子上」决定（见 refreshFocus）：焦点是视频才播，是图片帖就停。
   * 任意时刻只有一个帖子被聚焦，所以同一时刻只有一张卡片真正在播。
   */
  @State activeKey: string = '';
  /**
   * 提前准备的下一条视频的 key（预加载，见 refreshFocus 的说明）。
   *
   * 和 reels 一样：播这条的时候把下一条的视频也 prepare 好（首帧都解出来），
   * 轮到它时直接 play —— 这是官方短视频方案里"切换起播 ≤230ms"的做法。
   * 空串表示不需要预加载。
   */
  @State private preloadKey: string = '';
  /**
   * 当前展开正文的那条帖子 key；空串 = 都折叠着（见 toggleCaption）。
   *
   * 用 @State 单个字符串而不是 Set：改 Set 里的元素不会触发重绘，而展开/收起必须重绘。
   * 只允许展开一条，同时展开多条会把列表撑得没法看。
   */
  @State expandedCaptionKey: string = '';
  /**
   * 当前界面是不是深色（兜底用）；叠字颜色以**实测**的背景明暗为准，见 overlayBackdropLight。
   */
  @StorageProp(SETTING_DARK_UI) isDarkUi: boolean = true;
  /**
   * 叠字背后那一块实际是不是浅色（由 core/BackdropTone 连续快照侦测后写入）。
   *
   * 需求：只有当**这段文字背后的部分确实是白/浅色**时才反色 —— 深色主题下白字遇到
   * 白底视频会糊在一起，这时才需要转成深色字；背景是深色时保持白字。
   */
  @StorageProp(SETTING_OVERLAY_BACKDROP_LIGHT) overlayBackdropLight: boolean = false;
  /** 视频静音（全局开关，媒体区右下角那颗喇叭键改它，见 MediaActionButtons）。 */
  @StorageProp(SETTING_VIDEO_MUTED) videoMuted: boolean = false;
  /** 沉浸光感材质的厚薄（设定页四档之一）：沉浸式标题区那个容器的材质读它。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * **首屏封面已解码张数**（由 core/PosterCache 写）。
   *
   * 冷启动时那几张封面走"低一档地址先解码"的路（见 PosterCache）：解出来一张这个值就 +1，
   * 列表里那几格随之重绘，把已经解好的小图垫在真图下面 —— 首屏不用对着空框等真图。
   * 值本身也参与查询（`PosterCache.has(url, posterReady)`），所以它不是一个"读了没用"的状态。
   */
  @StorageProp(FEED_POSTER_READY) posterReady: number = 0;
  /**
   * 关注状态不再存在组件里 —— 见 core/FollowState。
   *
   * 这里原来是一个"实例级 Map"，切 Reels 再切回来（组件重建）就没了，界面立刻退回接口
   * 那份旧快照（真机复现：点掉关注 → 切 Reels → 回首页 → 按钮又显示「已关注」，
   * 而且此后每次点击都在发**与真实状态相反**的请求）。现在统一问 FollowState。
   */
  /**
   * 屏幕宽度（px），正文测宽要用。
   *
   * 在 aboutToAppear 里连同其它屏幕尺寸一起量（见 minMediaAspect）；取不到就是 0，
   * 这时不做截断、也不追加"展开"，宁可交给 Text 自己省略。
   */
  private screenWidthPx: number = 0;
  /** 上一次给 BackdropTone 上报叠字行位置的时刻（节流用，见 syncOverlayBandThrottled）。 */
  private lastBandSyncMs: number = 0;
  /**
   * 正文截断结果缓存：post key → 显示用的那一行。
   *
   * 正文是不变的文本，量一次就够；卡片在滚动/状态变化时会重建，不缓存的话每次重建
   * 都要跑一轮二分测量（每条十几次 measureText）。
   */
  private captionLines: Map<string, string> = new Map<string, string>();
  /**
   * 列表的滚动控制器。
   *
   * 由页面传进来（见 pages/Index.ets 的 feedScroller）：HdsNavigation 的
   * bindToScrollable 得拿到内容的滚动容器才能接管标题栏滚动效果。
   * 页面不传时这里自己也有一个，列表本身照常工作。
   */
  listScroller: Scroller = new Scroller();
  /**
   * 上一帧的列表纵向偏移量，用来自己算滚动增量（见 reportScrollDelta）。
   *
   * 不用 onDidScroll 回调里那个 scrollOffset，是因为它的正负号约定没写在类型定义里；
   * 直接对 scroller 的实际偏移量做差最稳，也顺便得到「往哪个方向」。
   */
  private lastOffsetY: number = 0;
  /** 有没有采到过第一帧：首帧只记基准不报增量，避免把历史偏移量当成一次大滚动。 */
  private offsetSampled: boolean = false;
  /** 上一次"滚动中重算焦点"的时刻（节流用，见 refreshFocusThrottled）。 */
  private lastFocusMs: number = 0;
  /**
   * 当前焦点**最后已知的可见高度**（px；-1 = 还没量到过，0 = 上一轮就已经整条在屏幕外）。
   *
   * 只在"焦点量不到"（卡片被回收/重建）的那一轮用得上：那时若它上一轮就已经看不见了，
   * 就不该再靠"它是当前焦点"继续占着焦点（否则屏幕外的视频会接着播）。
   */
  /** 最近量到的媒体几何（key → 几何 + 时间戳），见 mediaSpan / knownGeom。 */
  private geomCache: Map<string, GeomEntry> = new Map<string, GeomEntry>();
  /** 这一轮里有几条是靠几何记忆顶上的（诊断用：>0 说明卡片正在被回收）。 */
  private geomHits: number = 0;
  /** 上一次重算焦点时的滚动位置（px）与时刻：位移/心跳闸门用（见 refreshFocusThrottled）。 */
  private lastFocusY: number = 0;
  /**
   * 当前在屏幕上的帖子：key → 列表索引。
   *
   * 收的是**所有**帖子而不是只有视频：聚焦按帖子判断，焦点落在图片帖上时不该播任何视频。
   */
  private visiblePosts: Map<string, number> = new Map<string, number>();
  /**
   * 正文"显示译文"的卡片键（有谁在里面 = 这一张现在显示译文）。
   *
   * 用 @State 数组而不是 Map：ArkUI 只认状态变量的**整体替换**，改 Map 内部不会重绘
   * （和信息流里 expandedCaptionKey / readyVideoKeys 同一套做法）。
   */
  @State private translatedCaptionKeys: Array<string> = [];
  /** 已翻好的正文译文（原文 key → 译文；普通 Map，配合上面那个 @State 数组触发重绘）。 */
  private captionTranslations: Map<string, string> = new Map<string, string>();
  /** 按**文本**缓存的折叠前缀（译文也用它，见 prefixOfText）。 */
  private textFits: Map<string, string> = new Map<string, string>();
  /** 这一张现在是不是在显示译文。 */
  private isTranslationShown(post: MediaPost): boolean {
    return this.translatedCaptionKeys.indexOf(FeedMapper.keyOf(post)) >= 0;
  }

  /** 译文（还没翻出来时先用原文占着，翻完会随 @State 换成译文）。 */
  private translatedCaption(post: MediaPost): string {
    /*
     * **读一下"译文到货"计数**：不然译文回来了界面也不会重绘。
     *
     * 原来靠 `translatedCaptionKeys = keys.concat([])` 换个新数组来触发重绘 —— 但 ArkUI 对
     * @State 数组是做**内容比较**的，内容一模一样就不重绘；于是第一次点「翻译」时状态变了、
     * 译文也到了，正文却还是原文，得再点一次（状态再变一回）才换过来 —— 用户报的
     * "第一次点没反应，点一下显示原文再点翻译才行"就是这个。
     * 这里显式读一下 `translationEpoch`，让调用它的 build 把它登记成依赖（见 toggleTranslation）。
     */
    const tick: number = this.translationEpoch;
    if (tick < 0) {
      return post.caption;
    }
    return this.captionTranslations.get(FeedMapper.keyOf(post)) ?? post.caption;
  }

  /** 译文到货的计数（每翻好一条 +1，见 toggleTranslation 与 translatedCaption）。 */
  @State private translationEpoch: number = 0;

  /**
   * 点「翻译 / 显示原文」。
   *
   * 两个方向都是**先切状态、再补数据**：这样点下去立刻有反应（文案变、正文换成原文/已有译文），
   * 译文第一次要等网络，回来再替换一次（`captionTranslations` 是普通 Map，配合 @State 数组触发重绘）。
   */
  private toggleTranslation(post: MediaPost, show: boolean): void {
    const key: string = FeedMapper.keyOf(post);
    const has: boolean = this.translatedCaptionKeys.indexOf(key) >= 0;
    if (show === has) {
      return;
    }
    this.translatedCaptionKeys = show
      ? this.translatedCaptionKeys.concat([key])
      : this.translatedCaptionKeys.filter((one: string): boolean => one !== key);
    if (!show || this.captionTranslations.has(key)) {
      return;
    }
    Translator.translate(post.caption).then((text: string | null): void => {
      if (text === null || text.length === 0) {
        hilog.warn(0xFF00, 'FeedList', 'translate failed why=%{public}s', Translator.lastDetail());
        this.onTranslateFailed();
        // 翻不出来就把状态退回去（不然正文会一直停在原文、按钮却写着"显示原文"）。
        this.translatedCaptionKeys =
          this.translatedCaptionKeys.filter((one: string): boolean => one !== key);
        return;
      }
      this.captionTranslations.set(key, text);
      // 触发重绘：把"译文到货"计数 +1（内容比较那套换引用是没用的，见 translatedCaption 的说明）。
      this.translationEpoch = this.translationEpoch + 1;
    });
  }

  /** 上一次请求更多的时刻，用来给滚动事件去抖。 */
  private lastAskMs: number = 0;
  /** 最近一次上报出去的锚点 key（只有变了才回调页面）。 */
  private lastAnchorKey: string = '';
  /**
   * 已经报过 onPrepared 的视频帖（shortcode）。
   *
   * 用 @State 数组而不是 Set：ArkUI 只认状态变量的**整体替换**，读到新数组才会重绘
   * （这一层撤掉封面就靠它触发）。
   */
  @State private readyVideoKeys: string[] = [];
  /** 位置是否已经还原过（三次重试里成功一次就够）。 */
  private anchorRestored: boolean = false;
  /**
   * 允许的最小宽高比 = 屏宽 / 允许的最大高度（见 MEDIA_MAX_HEIGHT_RATIO）。
   *
   * 用「宽高比下限」而不是给容器加 maxHeight，是因为媒体区的高由 aspectRatio 决定，
   * 直接改比例最确定，也不会和 aspectRatio 的取值打架。
   * 只在组件创建时算一次（屏幕尺寸不会中途变）；取不到就保持 0，等于不限制。
   */
  private minMediaAspect: number = 0;
  /**
   * 屏幕中心的 y 坐标（px）。
   *
   * 用来判断焦点落在哪条帖子上（见 refreshFocus）。
   * 必须是 **px**：和 getRectangleById 返回的窗口坐标同一单位，换成 vp 比较就没意义了。
   */
  private screenCenterY: number = 0;
  /** 屏幕高度（px）：列表可视区底边量不到时用它兜底。 */
  private screenBottom: number = 0;
  /**
   * 当前被聚焦的帖子 key；空串表示没有焦点。
   *
   * 与 activeKey 分开：焦点可能落在图片帖上（此时 activeKey 为空但焦点仍在），
   * 而「换手不出现空档」需要知道焦点到底是谁 —— 见 refreshFocus 的保持逻辑。
   */
  private focusKey: string = '';
  /** 放大爱心的瞬时状态（见 LikeBurstState）。 */
  @State burst: LikeBurstState = new LikeBurstState();
  /**
   * 多图帖「上次看到第几张」：帖子 key → 页号。
   *
   * 点赞状态一变，外层 ForEach 的键值就变（键值里带着 liked 和各项计数），整张卡片会被
   * **重建**，于是 MediaCarousel 里的 Swiper 也新建、默认回到第一张 —— 用户看到的就是
   * 「点个赞，翻到第三张的图跳回第一张」。
   * 这里按帖子把页号记下来，重建时通过 initialPage 传回去还原。
   * 条目很小（一个整数），不必主动清理。
   */
  private carouselPages: Map<string, number> = new Map<string, number>();

  /** 这条多图帖上次看到第几张；没记录过就是第 0 张。 */
  private carouselPage(post: MediaPost): number {
    return this.carouselPages.get(FeedMapper.keyOf(post)) ?? 0;
  }

  /**
   * 帖子 key → 可变界面状态（点赞、各项计数）。
   *
   * 同一个 key **始终复用同一个 @Observed 实例**：卡片不重建时靠它就地更新；卡片万一
   * 真的重建了，新接上的 @ObjectLink 也还是接到同一个对象上。
   */
  private uiByKey: Map<string, PostUi> = new Map<string, PostUi>();
  /** 收藏正在请求的帖子键（防连点；见 toggleSaved）。 */
  private savingKeys: Set<string> = new Set<string>();
  /** 已经打过"多图帖盒子按哪张图钉高"日志的键（诊断用，见 mediaBoxAspect）。 */
  private carouselAspectLogged: Array<string> = [];
  /** 关注按钮最近一次真正触发的时刻（按帖子 key），用于两个事件入口去重，见 tapFollow。 */
  private followTapAt: Map<string, number> = new Map<string, number>();
  /**
   * 正在请求中的关注动作（按帖子 key）。
   *
   * 一次点击可能报进来两个回调（`onChange` + 通用 `onClick`），而网络请求要几百毫秒才回来；
   * 不去重的话就成了"关注 + 取关"两个来回 —— 服务端互相抵消，界面看着就是
   * **点一下回滚、而且没真的关注上**（用户报的正是这个）。
   */
  private followBusy: Set<string> = new Set<string>();
  /**
   * 与 posts 一一对应的可变状态数组。
   *
   * 这里必须是 @State 数组，不能图省事在卡片里写 `ui: this.uiFor(post)`：
   * @ObjectLink 的来源只能是**状态变量**或**状态数组的元素**，传一个方法调用的返回值
   * 编译器会告警「regular property cannot be assigned to @ObjectLink」，链接根本建不起来
   * —— 那样点了赞心形也不会变。
   */
  @State uiList: PostUi[] = [];

  /**
   * 按 posts 重建 uiList：复用已有实例，并把最新计数对齐过去。
   *
   * 之所以要“对齐”：取数/补全（enrich）会重建 MediaPost，计数可能在没点赞的情况下也变了，
   * 而这些变化不再走卡片重建，只能在这里同步。
   */
  /**
   * 点卡片动作区最右边那颗**书签**：收藏 / 取消收藏（走 HTTP，见 onSave）。
   *
   * 乐观翻转就地做在 `PostUi.saved` 上（@Observed + PostActions 的 @ObjectLink，
   * 只有这一行重绘）；宿主回 false 再翻回来 —— 等网络那一下会像"点了没反应"。
   * 成功之后写进 **core/SaveState**：换页重进、卡片重建之后还是实心（见 syncUiList）。
   */
  private toggleSaved(post: MediaPost): void {
    const key: string = FeedMapper.keyOf(post);
    if (this.savingKeys.has(key)) {
      return;
    }
    let ui: PostUi | undefined = this.uiByKey.get(key);
    if (ui === undefined) {
      ui = new PostUi();
      this.uiByKey.set(key, ui);
    }
    const target: PostUi = ui;
    const next: boolean = !target.saved;
    target.saved = next;
    this.savingKeys.add(key);
    hilog.debug(DOMAIN, TAG, 'feed save %{public}s → %{public}s', key, `${next}`);
    this.onSave(post, next).then((ok: boolean): void => {
      this.savingKeys.delete(key);
      if (ok) {
        SaveState.remember(post.id, next);
        return;
      }
      // 失败回滚（原因由宿主说明，见 pages/Index.savePost）。
      target.saved = !next;
    }).catch((): void => {
      this.savingKeys.delete(key);
      target.saved = !next;
    });
  }

  private syncUiList(): void {    const next: PostUi[] = [];
    for (let index: number = 0; index < this.posts.length; index++) {
      const post: MediaPost = this.posts[index];
      const key: string = FeedMapper.keyOf(post);
      let ui: PostUi | undefined = this.uiByKey.get(key);
      if (ui === undefined) {
        ui = new PostUi();
        this.uiByKey.set(key, ui);
      }
      // 只在真的变了才赋值：@Observed 的属性赋值会通知所有订阅者，
      // 无脑重写会让整列表的动作区在每次翻页/刷新时全部重绘一遍。
      if (ui.liked !== post.liked) {
        ui.liked = post.liked;
      }
      if (ui.likeCount !== post.likeCount) {
        ui.likeCount = post.likeCount;
      }
      if (ui.commentCount !== post.commentCount) {
        ui.commentCount = post.commentCount;
      }
      /*
       * 转发状态：和「收藏」同一套口径 —— **以本机台账为准**（见 core/RepostState）。
       * IG 的载荷里没有这个字段，只看 `post.reposted` 的话，卡片重建/换页/重启之后
       * 对勾就会掉（用户报的"已转发状态会被刷掉"）。
       */
      const repostedNow: boolean = RepostState.resolve(post.id, post.shortcode, post.reposted);
      if (ui.reposted !== repostedNow) {
        ui.reposted = repostedNow;
      }
      if (ui.repostCount !== post.repostCount) {
        ui.repostCount = post.repostCount;
      }
      // 转过的那条至少显示 1（载荷常常不给这个数，见 FeedMapper.withReposted）。
      if (repostedNow && ui.repostCount === 0) {
        ui.repostCount = 1;
      }
      if (ui.shareCount !== post.shareCount) {
        ui.shareCount = post.shareCount;
      }
      // 关注状态：以**本地点过的**为准（见 core/FollowState）；没点过才用接口值。
      const known: boolean = FollowState.resolve(post.ownerId,
        FollowState.resolveName(post.ownerUsername, post.ownerFollowing));
      if (ui.following !== known) {
        ui.following = known;
      }
      // 收藏状态：同样以**会话覆盖表**为准（见 PostUi.saved）。
      const savedNow: boolean = SaveState.resolve(post.id, ui.saved);
      if (ui.saved !== savedNow) {
        ui.saved = savedNow;
      }
      next.push(ui);
    }
    this.uiList = next;
  }

  /**
   * 别处（用户主页那一行 / 帖子页标题栏 / 通知页）改了关注状态：把本列表每张卡片重算一遍。
   *
   * **原地改就够，不重建 uiList**：`PostUi` 是 `@Observed`、FollowPill 用 `@ObjectLink`
   * 订阅它，`following` 一改那张卡片自己就重绘；重建数组反而让整条列表白 diff 一轮。
   *
   * 判据和构建时**完全同一条**（`FollowState.resolve`，见 syncUiList）：本地点过的以本地为准，
   * 没点过的仍是接口值 —— 这样点关注之后，首页同一张卡片不会过一会儿又被旧快照顶回去。
   */
  private syncFollowStates(): void {
    let changed: number = 0;
    for (let index: number = 0; index < this.posts.length; index++) {
      const post: MediaPost = this.posts[index];
      const ui: PostUi | undefined = this.uiByKey.get(FeedMapper.keyOf(post));
      if (ui === undefined) {
        continue;
      }
      const known: boolean = FollowState.resolve(post.ownerId,
        FollowState.resolveName(post.ownerUsername, post.ownerFollowing));
      if (ui.following !== known) {
        ui.following = known;
        changed++;
      }
    }
    if (changed > 0) {
      hilog.info(DOMAIN, TAG, 'FL follow refresh %{public}d card(s)', changed);
    }
  }

  /** posts 变了：把可变状态数组跟着重建一遍。 */
  private onPostsChanged(propName: string): void {
    this.syncUiList();
    /*
     * 顺手**预热首屏那几张封面**（见 core/PosterCache）：它用低一档（`thumbUrl`，约 360px）
     * 先解出一张小图垫在真图下面，真图（1080 档）到了自然盖住 —— 没有这一步时，首屏要等
     * 那张大图下载完才有画面，用户感知就是"封面/头像那一块出来得慢"。
     *
     * 以前只有首页信息流预热（FeedViewModel 里调的），**帖子页这一份从来没预热过**：
     * 从网格点进来的帖子页，封面是 1080 那张，几百 KB 一张，一条条地下 —— 慢的感觉主要来自这里。
     * 重复调用无害（内部有 posters/warming 两道闸）。
     */
    PosterCache.warm(this.posts);
  }

  /**
   * 放一次放大爱心（跟手：落点由调用方给，见 mediaBlock 的双击手势）。
   *
   * 实现在 components/AnimatedIcons.playLikeBurst（feeds / reels 共用一套）。
   */
  private showLikeBurst(key: string, x: number, y: number): void {
    playLikeBurst(this.burst, key, x, y);
  }

  aboutToAppear(): void {
    // posts 是 @Prop，首次赋值不一定触发 @Watch，所以这里先对齐一遍可变状态数组，
    // 否则第一帧 this.uiList[index] 会越界。
    this.syncUiList();
    try {
      const dsp = display.getDefaultDisplaySync();
      // 不用 px2vp 换算：宽高比是无量纲的，只要两边同单位，px 直接相除结果完全一样
      // （换算系数会被约掉），也就避开了 px2vp 的废弃告警。
      const screenW: number = dsp.width;
      this.screenWidthPx = screenW;
      const maxHeight: number = dsp.height * MEDIA_MAX_HEIGHT_RATIO;
      this.minMediaAspect = (screenW > 0 && maxHeight > 0) ? (screenW / maxHeight) : 0;
      this.screenCenterY = dsp.height / 2;
      this.screenBottom = dsp.height;
    } catch (err) {
      // 拿不到屏幕尺寸不是致命问题：退回「不限制高度」，媒体区照旧按真实比例铺满。
      this.minMediaAspect = 0;
      // 正文档宽也做不了，那就退回"不截断"（见 screenWidthPx）。
      this.screenWidthPx = 0;
      // 中心点拿不到时 refreshFocus 退回「索引最小者胜」，也就是列表最上面那条。
      this.screenCenterY = 0;
      this.screenBottom = 0;
    }
  }

  /** 卡片根节点的 id：聚焦判据量的是整张卡片（见 cardSpan）。 */
  private cardId(post: MediaPost): string {
    return `${CARD_ID_PREFIX}${FeedMapper.keyOf(post)}`;
  }

  /**
   * **媒体盒子**根节点的 id。
   *
   * 聚焦播放真正该看的是"这块媒体在屏幕上露出多少"，而不是整张卡片 —— 卡片还含表头、
   * 正文、动作区，一张小图配长文案的卡片能有 0.7 屏高、而媒体只占 0.15 屏。
   * 见 mediaSpan / PendingGeom。
   */
  private mediaId(post: MediaPost): string {
    return `${MEDIA_ID_PREFIX}${FeedMapper.keyOf(post)}`;
  }

  /**
   * 量一条的**媒体矩形**（窗口坐标 px）；量不到返回 measurable=false。
   *
   * 兜底顺序见 mediaSpan：媒体节点 → 卡片节点按媒体占比折算 → 上次已知（TTL 内）。
   */
  private mediaSpanRaw(index: number): CardSpan {
    if (index < 0 || index >= this.posts.length) {
      return new CardSpan(0, 0, false);
    }
    try {
      const info = this.getUIContext().getComponentUtils()
        .getRectangleById(this.mediaId(this.posts[index]));
      const top: number = info.windowOffset.y;
      if (info.size.height > 0) {
        return new CardSpan(top, top + info.size.height, true);
      }
    } catch (err) {
    }
    return new CardSpan(0, 0, false);
  }

  /** 卡片宽高比（宽/高）→ 用来把卡片高度里"不属于媒体的部分"扣掉。 */
  private cardWidthPx(index: number): number {
    if (index < 0 || index >= this.posts.length) {
      return 0;
    }
    try {
      const info = this.getUIContext().getComponentUtils()
        .getRectangleById(this.cardId(this.posts[index]));
      return info.size.width;
    } catch (err) {
      return 0;
    }
  }

  /**
   * **媒体矩形（带回退）** —— 聚焦判据唯一该用的几何。
   *
   * 三级回退（每一级都带"这条是怎么量到的"日志，出问题时能直接看出是哪一级在起作用）：
   *   ① 媒体盒子节点本身（最准）；
   *   ② 卡片矩形 + 按已知宽高比折算的媒体高度（卡片在、媒体节点刚被回收）；
   *   ③ 本进程内**最近 250ms** 量到过的值（卡片正在回收/重建的那个窗口）；
   * 都不成立 → measurable=false（调用方按"未知"处理，而不是当成"在屏幕外"）。
   */
  private mediaSpan(index: number): CardSpan {
    const raw: CardSpan = this.mediaSpanRaw(index);
    if (raw.measurable) {
      this.rememberGeom(index, raw, 'node');
      return raw;
    }
    const card: CardSpan = this.cardSpan(index);
    if (card.measurable) {
      const width: number = this.cardWidthPx(index);
      const aspect: number = this.mediaBoxAspect(this.posts[index]);
      const mediaHeight: number = (width > 0 && aspect > 0) ? width / aspect : 0;
      /*
       * 卡片的媒体在最上面（表头/正文/动作区都在它下面；沉浸式视频那支表头是叠在上面的，
       * 也计入媒体高度）→ 媒体矩形 = [卡片顶, 卡片顶 + 媒体高]，再夹进卡片范围内。
       */
      if (mediaHeight > 0) {
        const bottom: number = Math.min(card.top + mediaHeight, card.bottom);
        const span: CardSpan = new CardSpan(card.top, bottom, true);
        this.rememberGeom(index, span, 'card');
        return span;
      }
      this.rememberGeom(index, card, 'card');
      return card;
    }
    const cached: CardSpan | null = this.knownGeom(index);
    if (cached !== null) {
      return cached;
    }
    return new CardSpan(0, 0, false);
  }

  /** 记下这次量到的媒体矩形（见 knownGeom 的说明）。 */
  private rememberGeom(index: number, span: CardSpan, source: string): void {
    if (index < 0 || index >= this.posts.length) {
      return;
    }
    const key: string = FeedMapper.keyOf(this.posts[index]);
    this.geomCache.set(key, new GeomEntry(span.top, span.bottom, Date.now(), source));
  }

  /** 取"250ms 内量到过的"那条几何；过期/没有返回 null。 */
  private knownGeom(index: number): CardSpan | null {
    if (index < 0 || index >= this.posts.length) {
      return null;
    }
    const key: string = FeedMapper.keyOf(this.posts[index]);
    const hit: GeomEntry | undefined = this.geomCache.get(key);
    if (hit === undefined) {
      return null;
    }
    if (Date.now() - hit.at > FOCUS_GEOM_TTL_MS) {
      return null;
    }
    this.geomHits = this.geomHits + 1;
    return new CardSpan(hit.top, hit.bottom, true);
  }

  /**
   * 量一条**卡片**在窗口坐标里的竖直范围（px）；量不到时 measurable 为 false。
   *
   * 聚焦按「卡片中心 vs 屏幕中心」比较，所以量的是整张卡片（含表头与正文），
   * 这样焦点落在「这一整条帖子」上，而不是它的某一块。
   *
   * 不用 onAreaChange：滚动不会触发它（那属于布局变化，滚动是绘制偏移），
   * 所以只能在 onScrollIndex / 可见性变化这些时机主动去量。
   * 单位是 px，和 screenCenterY 一致。
   */
  private cardSpan(index: number): CardSpan {
    if (index < 0 || index >= this.posts.length) {
      return new CardSpan(0, 0, false);
    }
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(this.cardId(this.posts[index]));
      const top: number = info.windowOffset.y;
      return new CardSpan(top, top + info.size.height, true);
    } catch (err) {
      // 节点还没布局出来、或已被列表回收：当作量不到。
      return new CardSpan(0, 0, false);
    }
  }

  /**
   * 列表可视区在窗口坐标里的竖直范围（px）；量不到就用 [0, 屏幕高度] 兜底。
   *
   * 「帖子完全显示在屏幕」就是拿卡片范围和它比：上下都落在里面才算完全显示。
   */
  private viewportSpan(): CardSpan {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(LIST_ID);
      const top: number = info.windowOffset.y;
      const bottom: number = top + info.size.height;
      if (bottom > top) {
        return new CardSpan(top, bottom, true);
      }
    } catch (err) {
    }
    return new CardSpan(0, this.screenBottom, this.screenBottom > 0);
  }

  /**
   * 媒体区实际使用的宽高比：正常就按真实比例，太高（竖图 / 竖视频）就抬到下限。
   *
   * 抬高比例 = 变矮。配合 ImageFit.Contain，多出来的横向空间会留白，画面不会被裁。
   */
  private mediaAspect(post: MediaPost): number {
    const raw: number = post.aspectRatio();
    /*
     * **视频不设高度上限**（需求："高度较高的视频媒体高度没有完全撑开，被裁剪"）。
     *
     * `minMediaAspect` 是"媒体高度不超过屏幕高 × MEDIA_MAX_HEIGHT_RATIO"折算出来的比例下限：
     * 比它更高的媒体会被**压到那个高度**，而画面是 Cover 填进去的 —— 于是竖屏视频的上下就被裁了。
     * 竖屏视频本来就该按自身比例完整铺开（高过屏幕就滚动，IG 也是这么做的），所以这里对视频
     * 直接放行真实比例；图片仍保留上限（那是版面需要，另一回事）。
     */
    if (this.isInlineVideo(post)) {
      return raw;
    }
    if (this.minMediaAspect > 0 && raw < this.minMediaAspect) {
      return this.minMediaAspect;
    }
    return raw;
  }

  /**
   * 媒体**盒子**的宽高比（给媒体盒子钉高度用，见 mediaBlock 里那条 .aspectRatio）。
   *
   * 必须**逐个分支对齐 mediaBlock 里的写法，顺序也要一致**：
   *   ① 内联视频（isInlineVideo）：视频容器自己写的就是 mediaAspect —— **这条要最先判**，
   *      否则"视频帖但没抓到封面图"（displayUrl 为空）会被下面第③条判成方块，盒子和视频
   *      对不上，按钮就偏了；
   *   ② 有封面图：多图轮播的盒子 = 图片 + 圆点行（MediaCarousel 的 DOT_ROW_HEIGHT），
   *      单图 = mediaAspect；
   *   ③ 连封面图都没有：占位方块是 aspectRatio(1)。
   * 算准了盒子高度 = 媒体真实高度，算错了盒子要么比媒体高（媒体下移、上方留空），
   * 要么比媒体矮（按钮跑到图片外面去）。注意盒子比例**不等于**图片比例，别只按图片算。
   */
  private mediaBoxAspect(post: MediaPost): number {
    const aspect: number = this.mediaAspect(post);
    if (this.isInlineVideo(post) && post.displayUrl.length === 0) {
      // 视频帖但没封面：媒体分支走的是视频容器（比例 = mediaAspect），不是方块占位。
      return aspect;
    }
    if (post.displayUrl.length === 0) {
      return 1;
    }
    if (post.isCarousel() && aspect > 0) {
      /*
       * 多图帖的盒子按**最高那张图**钉高（需求："所有 feeds 流多图片帖子媒体区高度根据
       * 高度最高的图片"）：`imageAspectMin` 是逐张子媒体量出来的最小 w/h（= 最高的那张），
       * 拿不到（0）时退回第一张的比例（老行为）。
       */
      const tallest: number = post.imageAspectMin > 0 ? post.imageAspectMin : aspect;
      const widthVp: number = px2vp(this.screenWidthPx);
      if (this.carouselAspectLogged.indexOf(FeedMapper.keyOf(post)) < 0) {
        // 只记一次（每张卡片）：多图帖的盒子到底按哪张图钉高，日志里一眼能看出来。
        this.carouselAspectLogged.push(FeedMapper.keyOf(post));
        hilog.info(DOMAIN, TAG, 'media box %{public}s first=%{public}s tallest=%{public}s imgs=%{public}d',
          FeedMapper.keyOf(post), aspect.toFixed(3), tallest.toFixed(3), post.imageUrls.length);
      }
      if (widthVp > 0) {
        return widthVp / (widthVp / tallest + DOT_ROW_HEIGHT);
      }
    }
    return aspect;
  }

  /**
   * 轮播里**图片那一段**的比例（= 媒体盒子的比例去掉圆点行）。
   *
   * 为什么要单独算：`mediaBoxAspect` 给的是"图片 + 圆点行"整块的比，而 `MediaCarousel` 内部的
   * 每张图是**按 `aspect` 属性**排的。以前这里直接传 `mediaAspect(post)`（= **第一张图**的比例），
   * 于是：盒子按第一张算、图也按第一张算 —— 多图帖里比第一张更高的那些图就被压在那个更矮的
   * 位置里（上下补黑边），而"媒体区高度按最高那张"这个要求根本没有生效
   * （用户报的"被标注帖子的媒体区显示比例问题"就是这个）。
   *
   * 现在两边同源：`mediaBoxAspect` 用最高的那张（`imageAspectMin`），这里把圆点行那段减掉，
   * 得到图片段本身的比例 → 所有图都按**最高那张**的高度来排，比它矮的上下补黑边（需求）。
   */
  private carouselAspect(post: MediaPost): number {
    const box: number = this.mediaBoxAspect(post);
    const widthVp: number = px2vp(this.screenWidthPx);
    if (widthVp <= 0 || box <= 0) {
      return box;
    }
    const imageHeight: number = widthVp / box - DOT_ROW_HEIGHT;
    return imageHeight > 0 ? widthVp / imageHeight : box;
  }

  /**
   * 这一条是不是「可以内联自动播放的视频」。
   *
   * 多图轮播里也可能带视频，但那种卡片的主体是轮播，不该被自动换成播放器，
   * 所以只认单媒体视频。
   */
  /**
   * **单视频帖**：整条帖子就是一个视频（多图帖哪怕含视频页也返回 false —— 那种帖由
   * MediaCarousel 逐页渲染，见 mediaBlock）。
   *
   * 判"这条帖子要不要按视频排版/聚焦偏好处理"用它；判"这条帖子里的东西能不能播"
   * 用 `hasVideoMedia`（下面那个）。
   */
  private isInlineVideo(post: MediaPost): boolean {
    return post.videoUrl.length > 0 && !post.isCarousel();
  }

  /**
   * **这条帖子里有没有可播的视频**（单视频帖，或多图帖里的视频页）。
   *
   * 用途是"播不播"这条链：焦点闸门（refreshFocus 里给 activeKey 赋值那一步）、
   * 正在播放判定（isPlaying）、预加载找下一条视频 —— 多图帖里的视频页也要能播，
   * 所以这几处都必须用它而不是 isInlineVideo。
   */
  private hasVideoMedia(post: MediaPost): boolean {
    return post.hasVideo();
  }

  /** 这一条是不是当前正在播放的视频（单视频帖，或含视频页的多图帖）。 */
  private isPlaying(post: MediaPost): boolean {
    return this.hasVideoMedia(post) && this.activeKey === FeedMapper.keyOf(post);
  }

  /**
   * 记录「一条帖子出现在屏幕上」。
   *
   * 注意这里收的是**所有**帖子，不只是视频 —— 聚焦是按帖子判断的：焦点落在图片帖上
   * 时，旁边哪怕有视频也不该播。
   *
   * 注意 onVisibleAreaChange 回调的第一个参数是 isExpanding（可见面积是在变大还是
   * 变小），**不是** isVisible；判断在不在屏幕上必须看 currentRatio。
   *
   * 这里只**加入**、不负责移除：移除交给 syncFromRange 按 List 的可见区间来做。
   * 因为播放状态会进 ForEach 的键值（否则切换播放时卡片不会重渲染），切换时卡片
   * 节点会被重建，而节点销毁也会报一次「不可见」—— 若在这里跟着删，就会出现
   * 「删掉 → 重算 → 又播 → 又删」的抖动。
   */
  private noteVisibility(post: MediaPost, index: number, visible: boolean): void {
    if (!visible || index < 0 || index >= this.posts.length) {
      // -1/越界 = 这条已经不在当前列表里了（刷新把那条刷掉了）：不写进去，免得后面按它算焦点。
      return;
    }
    this.visiblePosts.set(FeedMapper.keyOf(post), index);
    this.refreshFocus();
  }

  /**
   * 用 List 报上来的可见下标区间校正可见集合，并重算焦点。
   *
   * 这是「帖子离开屏幕就不再算数」的主判据：滚出区间就丢掉。
   * 同时把区间内的帖子补进来 —— onVisibleAreaChange 未必在首屏布局时先到，
   * 靠这一步保证「第一次加载时也有焦点」成立。
   */
  private syncFromRange(start: number, end: number): void {
    const stale: Array<string> = [];
    this.visiblePosts.forEach((index: number, key: string): void => {
      if (index < start || index > end) {
        stale.push(key);
      }
    });
    for (let i: number = 0; i < stale.length; i++) {
      this.visiblePosts.delete(stale[i]);
    }
    for (let index: number = start; index <= end && index < this.posts.length; index++) {
      if (index < 0) {
        continue;
      }
      this.visiblePosts.set(FeedMapper.keyOf(this.posts[index]), index);
    }
    this.refreshFocus();
  }

  /**
   * 重算「哪条帖子被聚焦」，再据此决定播不播。
   *
   * **一套公式，不分媒体类型**（详细推导见下面「焦点判据」那段）：
   * 每个候选量三把尺子 —— 可见像素 `visPx`（主）、完整度 `full`（副）、离中心距离 `centPx`（第三），
   * 然后按「进入 / 释放 / 抢占 / 保持」四种情形做决定，默认**保持**（滞回，不抖）。
   *
   * 任意时刻**只有一个**帖子被聚焦；而且**只有被聚焦的帖子是视频才播**（图片帖一律不播）。
   */
  private refreshFocus(): void {
    // 先筛掉过期条目：下标越界、或该位置已经不是同一条（列表换过内容）。
    const stale: Array<string> = [];
    const keys: Array<string> = [];
    const indexes: Array<number> = [];
    this.visiblePosts.forEach((index: number, key: string): void => {
      if (index < 0 || index >= this.posts.length || FeedMapper.keyOf(this.posts[index]) !== key) {
        stale.push(key);
        return;
      }
      keys.push(key);
      indexes.push(index);
    });
    for (let i: number = 0; i < stale.length; i++) {
      this.visiblePosts.delete(stale[i]);
    }
    if (keys.length === 0) {
      // 可见集合空了：焦点必然算不出来（视频会停）。把当时的现场记下来 ——
      // 正常滚动不该出现这个状态，出现就是"视频播着播着停了"的根因线索。
      hilog.warn(DOMAIN, TAG, 'focus: visible set empty posts=%{public}d visibleMap=%{public}d',
        this.posts.length, this.visiblePosts.size);
    }

    /*
     * ================= 焦点判据：一套公式，不分媒体类型 =================
     *
     * 每轮只回答一个问题：**哪条媒体的可见面积最大**。三把尺子，按优先级：
     *   ① `visPx`  —— 这块媒体在可视区里露出多少 px（"占了屏幕多大一块"）；
     *   ② `full`   —— `visPx / min(媒体高, 可视区高)`，这条媒体被看全了没有（0..1）；
     *   ③ `centPx` —— 媒体中心离可视区中心多远（px）。
     *
     * 为什么不再用"可见 px / 屏幕高"（旧判据）：那个分母对**短媒体**天生不公平 ——
     * 一张 0.3 屏高的短视频哪怕完整显示也永远到不了 0.5，于是往回滑时焦点回不去
     * （旧代码只好加了一条"只挡往下、不挡往上"的方向特例）。换成三把尺子后，
     * "完整显示的那条更该播"由 ② 自动表达，方向特例就不再需要。
     *
     * 决策只有四种，且**默认保持**（滞回，避免边界抖动）：
     *   进入  没有焦点          → 最佳候选可见 >= 可视区高 * 0.25
     *   释放  当前焦点可见 == 0 → 交给最佳候选（真的滚出屏幕了）
     *   抢占  最佳可见 >= 当前 + 可视区高 * 0.10，且自身 >= 0.50
     *         或 两者可见接近（差 < 0.10）且（中心更近 0.08 或 完整度高 0.25）
     *   其余  → 保持当前焦点
     */
    const viewport: CardSpan = this.viewportSpan();
    const Hv: number = viewport.measurable
      ? Math.max(viewport.bottom - viewport.top, 1)
      : Math.max(this.screenBottom, 1);
    const vTop: number = viewport.measurable ? viewport.top : 0;
    const vBottom: number = viewport.measurable ? viewport.bottom : Hv;
    const vCenter: number = (vTop + vBottom) / 2;
    const minEnter: number = Hv * FOCUS_MIN_ENTER_RATIO;
    const minSwitch: number = Hv * FOCUS_MIN_SWITCH_RATIO;
    const marginPx: number = Hv * FOCUS_MARGIN_RATIO;
    const marginCenter: number = Hv * FOCUS_MARGIN_CENTER_RATIO;
    this.geomHits = 0;
    const cands: Array<FocusCand> = [];
    /*
     * 候选集合 = 可见集合 ∪ {当前焦点}。
     *
     * 为什么要把当前焦点并进来：滚动中 `syncFromRange` 会把它从 `visiblePosts` 里删掉
     * （可见区间已经不含它），但它的卡片可能还在屏幕上、只是"这一轮没进候选"。不并进来的话
     * 它就成了 `curCand === null`，容易被误判成"滚出屏幕"而清掉焦点（真机日志里就是
     * `enter-reject(0<626)`，正在播的视频凭空停掉）。
     */
    const scanIndexes: Array<number> = [];
    for (let i: number = 0; i < indexes.length; i++) {
      scanIndexes.push(indexes[i]);
    }
    const curIndex: number = this.focusIndexOf(this.focusKey);
    if (curIndex >= 0 && scanIndexes.indexOf(curIndex) < 0) {
      scanIndexes.push(curIndex);
    }
    for (let i: number = 0; i < scanIndexes.length; i++) {
      const index: number = scanIndexes[i];
      // **媒体矩形**（不是卡片）：卡片还含表头/正文/动作区，见 mediaSpan。
      const span: CardSpan = this.mediaSpan(index);
      if (!span.measurable) {
        continue;
      }
      const top: number = Math.max(span.top, vTop);
      const bottom: number = Math.min(span.bottom, vBottom);
      const visPx: number = bottom > top ? (bottom - top) : 0;
      const height: number = Math.max(span.bottom - span.top, 1);
      const capPx: number = Math.min(height, Hv);
      const full: number = visPx / capPx;
      const centPx: number = Math.abs(span.center() - vCenter);
      const key: string = (index >= 0 && index < this.posts.length)
        ? FeedMapper.keyOf(this.posts[index]) : '';
      cands.push(new FocusCand(index, key, visPx, full, centPx, capPx));
    }
    // 排序：可见面积降序 → 完整度降序 → 离中心升序（字典序的三把尺子）。
    cands.sort((a: FocusCand, b: FocusCand): number => {
      if (Math.abs(a.visPx - b.visPx) > 0.5) {
        return b.visPx - a.visPx;
      }
      if (Math.abs(a.full - b.full) > 0.01) {
        return b.full - a.full;
      }
      return a.centPx - b.centPx;
    });
    const curCandIndex: number = curIndex;
    let curCand: FocusCand | null = null;
    for (let i: number = 0; i < cands.length; i++) {
      if (cands[i].index === curCandIndex) {
        curCand = cands[i];
        break;
      }
    }
    const candCount: number = cands.length;
    const best: FocusCand | null = candCount > 0 ? cands[0] : null;
    const bestVis: number = best === null ? 0 : best.visPx;
    let focusIndex: number = curIndex;
    let focusWhy: string = 'keep';
    if (best === null) {
      // 一条都量不到（首帧还没布局）：保持原焦点，别把正在播的停掉。
      focusWhy = 'nogeom';
    } else if (curIndex < 0) {
      // 本来就没有焦点（或那条已经不在列表里）：够门槛就进入。
      if (best.visPx >= minEnter) {
        focusIndex = best.index;
        focusWhy = `enter(${Math.round(best.visPx)})`;
      } else {
        focusIndex = -1;
        focusWhy = `enter-reject(${Math.round(best.visPx)}<${Math.round(minEnter)})`;
      }
    } else if (curCand === null) {
      /*
       * 当前焦点这一轮**量不到**（卡片正在被回收/重建，几何记忆也过期了）：
       * 这时候我们并不知道它还在不在屏幕上，所以**不主动收回焦点** ——
       * 只有当别的候选已经明确占住半屏以上（minSwitch）才让位。
       */
      if (best.index !== curIndex && best.visPx >= minSwitch) {
        focusIndex = best.index;
        focusWhy = `unmeasured->${Math.round(best.visPx)}`;
      } else {
        focusIndex = curIndex;
        focusWhy = 'unmeasured-keep';
      }
    } else if (curCand.visPx <= 0) {
      // 当前焦点**真的**滚出屏幕了（几何记忆也没能把它留住）：立刻让位。
      if (best.index !== curCand.index && best.visPx >= minEnter) {
        focusIndex = best.index;
        focusWhy = 'offscreen->next';
      } else {
        focusIndex = curCand.index;
        focusWhy = 'offscreen-keep';
      }
    } else if (best.index !== curCand.index) {
      const dominant: boolean = best.visPx >= curCand.visPx + marginPx && best.visPx >= minSwitch;
      const near: boolean = Math.abs(best.visPx - curCand.visPx) < marginPx;
      const tieBetter: boolean = near && best.visPx >= minSwitch
        && (best.centPx <= curCand.centPx - marginCenter || best.full >= curCand.full + 0.25);
      if (dominant) {
        focusIndex = best.index;
        focusWhy = `dominant(${Math.round(best.visPx)}>${Math.round(curCand.visPx)}+${Math.round(marginPx)})`;
      } else if (tieBetter) {
        focusIndex = best.index;
        focusWhy = `tie(${Math.round(best.visPx)}/${Math.round(curCand.visPx)})`;
      }
    }
    const nextFocusKey: string = (focusIndex >= 0 && focusIndex < this.posts.length)
      ? FeedMapper.keyOf(this.posts[focusIndex])
      : '';
    /*
     * **焦点换人就打一行**（不管那条是不是视频）。
     *
     * 以前只打"播哪条变了"，于是"焦点在两条图片帖之间乱跳"这种情况日志里完全看不见 ——
     * 排查几何判据时最需要的恰恰是它。带上三把尺子的原始数字：`vis/cap`（可见/容量）、
     * `full`（完整度）、`cands`（这一轮候选数）、`geomHits`（靠几何记忆顶上的条数）。
     */
    if (nextFocusKey !== this.focusKey) {
      hilog.info(DOMAIN, TAG, 'focusKey %{public}s -> %{public}s why=%{public}s vis=%{public}d/%{public}d full=%{public}s cands=%{public}d geomHits=%{public}d',
        this.focusKey.length > 0 ? this.focusKey : '(none)',
        nextFocusKey.length > 0 ? nextFocusKey : '(none)', focusWhy,
        Math.round(bestVis), best === null ? 0 : Math.round(best.capPx),
        best === null ? '-' : best.full.toFixed(2), candCount, this.geomHits);
    }
    this.focusKey = nextFocusKey;

    // 焦点换了：叠字行的采样窗口跟着换（BackdropTone 用它的位置去取"文字背后的颜色"）。
    this.syncOverlayBand();

    // 焦点落在视频上才播；落在图片帖（或没有焦点）就停。
    let nextKey: string = '';
    let focusIsVideo: boolean = false;
    if (this.focusKey.length > 0) {
      const focusedIndex: number = this.focusIndexOf(this.focusKey);
      if (focusedIndex >= 0 && this.hasVideoMedia(this.posts[focusedIndex])) {
        nextKey = this.focusKey;
        focusIsVideo = true;
      }
    }
    // **不在最前面就不播**（见 active 的说明）：从首页压上用户主页/帖子页时，
    // 底下的视频必须停下来，不能还在出声。
    if (!this.active) {
      nextKey = '';
      focusIsVideo = false;
    }

    if (nextKey !== this.activeKey) {
      const previous: string = this.activeKey;
      this.activeKey = nextKey;
      // 焦点换人（播哪条变了）是关键事件：出问题时靠它和 VideoSurface 的日志对时间线。
      // `why` 会写清是哪条规则让它换的（dominant / tie / offscreen / enter）；
      // `vis` 是最佳候选的可见像素，`cands` 是这一轮量到的候选数，
      // `geomHits` 是靠几何记忆顶上的条数（>0 说明有卡片正在被回收/重建）。
      hilog.info(DOMAIN, TAG,
        'focus %{public}s -> %{public}s why=%{public}s vis=%{public}d cands=%{public}d geomHits=%{public}d video=%{public}s focusKey=%{public}s',
        previous.length > 0 ? previous : '(none)', nextKey.length > 0 ? nextKey : '(none)',
        focusWhy, Math.round(bestVis), candCount, this.geomHits, focusIsVideo ? 'y' : 'n',
        this.focusKey.length > 0 ? this.focusKey : '(none)');
    }
    // 预加载下一条视频：不管焦点有没有变都要跟着更新（滚动时焦点这条没变，但下一条可能变了）。
    // （原先按网络类型开关过，实测会拖慢 feeds 的观感 —— 播放器的预下载缓冲已经收到 2 秒，
    //   这一项的开销是有界的，所以恢复成一直开。）
    const nextPreload: string = this.active ? this.nextVideoKey(nextKey) : '';
    if (nextPreload !== this.preloadKey) {
      this.preloadKey = nextPreload;
      hilog.info(DOMAIN, TAG, 'preload %{public}s', nextPreload.length > 0 ? nextPreload : '(none)');
    }
  }

  /**
   * "这条视频后面最近的另一条视频"的 key —— 预加载的对象。
   *
   * 只往后看 PRELOAD_LOOKAHEAD 条：太远的卡片根本没被 List 建出来（也就没有 XComponent 可用），
   * 预加载它等于凭空开一个解码器还看不见收益。找不到就返回空串（只播当前这条）。
   */
  private nextVideoKey(currentKey: string): string {
    const from: number = this.focusIndexOf(currentKey);
    if (from < 0) {
      return '';
    }
    const last: number = Math.min(this.posts.length - 1, from + PRELOAD_LOOKAHEAD);
    for (let index: number = from + 1; index <= last; index++) {
      if (this.hasVideoMedia(this.posts[index])) {
        return FeedMapper.keyOf(this.posts[index]);
      }
    }
    return '';
  }

  /** 焦点 key 对应的下标；不在列表里（或 key 为空）时返回 -1。 */
  private focusIndexOf(key: string): number {
    if (key.length === 0) {
      return -1;
    }
    for (let index: number = 0; index < this.posts.length; index++) {
      if (FeedMapper.keyOf(this.posts[index]) === key) {
        return index;
      }
    }
    return -1;
  }

  /**
   * 预下载"当前可见区间往后几张"的封面图。
   *
   * 用系统的缓存下载（见 core/MediaPrefetch）：图先落进缓存，等这几张的 Image 组件被创建时
   * 就直接命中缓存，不用等网络 —— 用户滑过去就是"已经有画面"。
   *
   * 每一条**最多两张**（需求）：多图轮播时前两张各下一张 —— 用户滑到这条、左右翻第一下
   * 就已经有图；再往后的等真翻到再说，不然一条十图的帖子会一口气把整组图拉下来。
   * 单图/视频帖就只有一张（封面），自然只下一张。
   *
   * 一次性往后看几张由 PREFETCH_AHEAD 定：预取得太远等于跟正在看的这张抢带宽，反而更卡。
   */
  private prefetchAhead(endIndex: number): void {
    const urls: Array<string> = [];
    const reach: number = endIndex + PREFETCH_AHEAD;
    for (let index: number = endIndex + 1; index < this.posts.length && index <= reach; index++) {
      const images: Array<string> = this.posts[index].imageUrls;
      let taken: number = 0;
      for (let image: number = 0; image < images.length && taken < PREFETCH_IMAGES_PER_POST; image++) {
        if (images[image].length > 0) {
          urls.push(images[image]);
          taken++;
        }
      }
      if (taken === 0) {
        const single: string = this.posts[index].displayUrl;
        if (single.length > 0) {
          urls.push(single);
        }
      }
    }
    if (urls.length > 0) {
      MediaPrefetch.prefetch(urls);
    }
  }

  /**
   * 上报"可见区第一条"的 key。
   *
   * key 取 shortcode（没有就退回 id），和列表 ForEach 的键、以及 MediaPost 的身份一致。
   */
  private reportAnchor(startIndex: number): void {
    if (startIndex < 0 || startIndex >= this.posts.length) {
      return;
    }
    const post: MediaPost = this.posts[startIndex];
    const key: string = post.shortcode.length > 0 ? post.shortcode : post.id;
    if (key.length > 0 && key !== this.lastAnchorKey) {
      this.lastAnchorKey = key;
      hilog.info(0xFF00, 'FeedList', 'anchor -> %{public}s (index=%{public}d)', key, startIndex);
      this.onAnchorChange(key);
    }
  }

  /**
   * 把列表位置还原到 initialKey 那一条（切 tab 回来时用）。
   *
   * 放在 List 的 onAppear 里、并**让出一帧**再滚：onAppear 那一刻 List 还没量完布局，
   * 直接 scrollToIndex 有可能被当成越界而不生效。滚的是"那一条贴到顶部"这个语义，
   * 和用户离开时的观感一致。
   */
  private restoreAnchor(): void {
    hilog.info(0xFF00, 'FeedList', 'restoreAnchor prop=%{public}s posts=%{public}d',
      this.initialKey.length > 0 ? this.initialKey : '-', this.posts.length);
    if (this.initialKey.length === 0 || this.posts.length === 0) {
      return;
    }
    let target: number = -1;
    for (let index: number = 0; index < this.posts.length; index++) {
      const post: MediaPost = this.posts[index];
      const key: string = post.shortcode.length > 0 ? post.shortcode : post.id;
      if (key === this.initialKey) {
        target = index;
        break;
      }
    }
    if (target <= 0) {
      // 找不到（那条被刷掉了）或本来就是第一条：不用动。
      return;
    }
    // 试三次而不是只试一次：切 tab 时内容层是**重建**的，List 起来的头一两帧可能还没量完布局，
    // 那时 scrollToIndex 会被当成越界而静默不生效（实测：只试一次时位置还原时灵时不灵）。
    // 三次都是幂等的（滚到同一个下标），成功之后就停。
    const delays: Array<number> = RESTORE_TRIES_MS;
    /*
     * 列表下标的偏移：首页那位"置顶托盘"也是一个 ListItem（见 build 里 showStories 那一支），
     * 所以帖子在小列表里要往后挪一位 —— 不补这一位，切 tab 回来会停在**上一条**。
     * 托盘有没有内容都算（ListItem 一直在），所以这里只看 showStories，不能看条数。
     */
    const listIndex: number = this.showStories ? target + 1 : target;
    // 同一时刻只留一轮还原定时器：`onAppear` 可能连着触发几次，否则会累积多轮（审计项 A1）。
    for (let old: number = 0; old < this.restoreTimers.length; old++) {
      clearTimeout(this.restoreTimers[old]);
    }
    this.restoreTimers = [];
    for (let index: number = 0; index < delays.length; index++) {
      /*
       * 句柄存进 `restoreTimers`、销毁时统一清（审计项 A1）。
       *
       * 这里原来是裸 `setTimeout`：`onAppear` 每触发一次就再注册一轮，而本组件**没有**
       * `aboutToDisappear` —— 组件销毁后回调仍会跑，并去读已经放掉的 `this.listScroller`
       * （`currentOffset()` 在销毁后可能抛，也可能读到脏值）。
       */
      this.restoreTimers.push(setTimeout((): void => {
        if (this.anchorRestored) {
          return;
        }
        try {
          this.listScroller.scrollToIndex(listIndex, false);
          const offset: number = this.listScroller.currentOffset().yOffset;
          // **只有真的滚上去了才算成功**：刚重建的那一两帧里 List 还没量完布局，scrollToIndex
          // 会被当成越界而静默不生效（实测 offset 仍是 0）。早先这里无条件置 true，
          // 于是后两次重试全被挡掉，位置就还原不了。
          if (offset > 0) {
            this.anchorRestored = true;
          }
          hilog.info(0xFF00, 'FeedList', 'restore anchor index=%{public}d offset=%{public}d%s',
            target, Math.round(offset), offset > 0 ? '' : ' (retry)');
        } catch (error) {
        }
      }, delays[index]));
    }
  }

  /**
   * 位置还原的定时器句柄（`restoreAnchor` 每次 `onAppear` 会注册 3 个）。
   *
   * 组件销毁时必须清掉：它们是裸 `setTimeout`，回调里要读 `this.listScroller`（审计项 A1）。
   */
  private restoreTimers: Array<number> = [];

  aboutToDisappear(): void {
    for (let index: number = 0; index < this.restoreTimers.length; index++) {
      clearTimeout(this.restoreTimers[index]);
    }
    this.restoreTimers = [];
  }
  /** 滚到底附近时请求更多：列表滚动会反复触发，这里限流一次。 */
  private askMore(): void {
    if (this.posts.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAskMs < ASK_COOLDOWN_MS) {
      return;
    }
    this.lastAskMs = now;
    this.onNearEnd();
  }

  /**
   * 算这一帧往下滚了多少，并报给页面（见 onFeedScroll）。
   *
   * 正数 = yOffset 变大 = 内容往上走 = 用户上滑在看更下面的帖子。
   * 首帧只记基准不报增量：列表被重建时（切 tab 回来）lastOffsetY 会归零，
   * 而真实偏移量可能已经很深，直接做差会凭空报一次几千 vp 的大滚动。
   */
  private reportScrollDelta(scrollState: ScrollState): void {
    const y: number = this.listScroller.currentOffset().yOffset;
    if (!this.offsetSampled) {
      this.offsetSampled = true;
      this.lastOffsetY = y;
      return;
    }
    const delta: number = y - this.lastOffsetY;
    this.lastOffsetY = y;
    if (delta === 0) {
      return;
    }
    // 滚动会让叠字行在屏幕上移动：顺手把它的新位置节流报一次，
    // BackdropTone 才能一直在"文字真正盖住的那块画面"上取色。
    this.syncOverlayBandThrottled();
    /*
     * **滚动中也要重算焦点**（节流，见 refreshFocusThrottled）。
     *
     * 用户报的现象正是缺了这一步：两条**长比例视频**相连时，卡片比屏幕还高，
     * 滚过一整屏才换一次可见下标 —— 这段时间里"哪条视频在屏幕上"早就变了，
     * 而焦点只在「可见区间 / 可见性变化」时才重算，于是**第一条已经滚出屏幕却还在播**，
     * 直到用户往回滑一点、触发一次下标变化才切到第二条。
     */
    this.refreshFocusThrottled();
    this.onFeedScroll(delta, y, scrollState);
  }

  /**
   * 滚动中的**节流**焦点重算（见 refreshFocusThrottled 的调用点说明）。
   *
   * 为什么节流：一次重算要给可见的每张卡片调 `getRectangleById`（3~6 次），
   * 按帧跑没必要 —— 120ms 已经足够跟手（人眼在这个尺度上看不出"晚了一帧"）。
   */
  private refreshFocusThrottled(): void {
    const now: number = Date.now();
    const elapsed: number = now - this.lastFocusMs;
    if (elapsed < FOCUS_SCROLL_THROTTLE_MS) {
      return;
    }
    /*
     * **动了才重算**：一次重算要给可见的每条量一次媒体矩形（3~6 次 `getRectangleById`）。
     * 位移不到 `FOCUS_MIN_MOVE_VP` 时几何几乎没变，结论也不会变。
     * 但要留一个"心跳"（`FOCUS_HEARTBEAT_MS`）—— 慢速微调时位移攒不够，也不能一直不收敛。
     */
    const y: number = this.listScroller.currentOffset().yOffset;
    const moved: number = Math.abs(y - this.lastFocusY);
    if (moved < FOCUS_MIN_MOVE_VP && elapsed < FOCUS_HEARTBEAT_MS) {
      return;
    }
    this.lastFocusMs = now;
    this.lastFocusY = y;
    this.refreshFocus();
  }

  /**
   * 「为你推荐」那张**提示卡片**（夹在关注流与探索流之间，或在列表最顶上）。
   *
   * 为什么不是一行小字了：列表现在是两段拼起来的（关注流 → 卡片 → 探索流），
   * 这张卡片是两段的**分界**，要让人一眼看出"上面是关注的人、下面开始是推荐"。
   * 位置由 `hintAt` 决定（见那里），这里只管画。
   *
   * 样式（需求）：**圆角灰底卡片** + 星星用 **Instagram 粉紫渐变**，星星放大并垂直居中。
   *   · 底色用 `field_background`（浅色 #F2F2F2 / 深色 #1A1A1A）：它本来就是"灰底"那一档，
   *     而且跟着主题走，别写死十六进制；
   *   · 渐变星星用**位图** `app.media.star_ig`（144×144 透明 PNG，黄→粉→紫的 LinearGradient）。
   *     为什么不用别的：
   *       - SVG：ArkUI 的 SVG 渲染**吃不到 `<linearGradient>`**，画出来是一颗纯色星（踩过）；
   *       - `SymbolGlyph` + `linearGradient` + `BlendMode.SRC_IN`：遮罩没生效，
   *         渐变方块直接盖在那儿（也踩过）。
   *     换配色就重新生成这张 PNG（GDI+ 那种几行脚本就行），别改这里的代码。
   */
  @Builder
  hintRow() {
    /*
     * ⚠️ 左右留白用**外层 padding**，不是给卡片加 margin。
     *
     * 卡片本身是 `width('100%')`；在 ArkUI 里 margin 是盒子**外面**的尺寸，
     * 100% + 左右各 16 就溢出到父容器之外、被裁掉 —— 实测「为你推荐」看着是通栏的、
     * 一点留白都没有。放进一个带 padding 的外层，宽度就是"父宽 - 32"。
     */
    Column() {
      Row({ space: 10 }) {
        Image($r('app.media.star_ig'))
          .width(HINT_STAR_SIZE)
          .height(HINT_STAR_SIZE)
          .objectFit(ImageFit.Contain)
          .flexShrink(0)
        /*
         * 注意：**不能设 fillColor**（那会把 PNG 的渐变换成单色），也不用再套 Stack/遮罩。
         */

        Column({ space: 3 }) {
          Text($r('app.string.feed_recommended_title'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
            .width('100%')
          Text($r('app.string.feed_recommended_hint'))
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // 垂直居中（需求）：星星对着**整张卡片**居中，不是贴着第一行文字。
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.field_background'))
      // 圆角再大一点（需求）：20 才有明显的"卡片"感（16 看着还是偏方）。
      .borderRadius(20)
    }
    .width('100%')
    // 留白：**左右各 16vp**（需求），上下各 10vp（需求："平衡卡片顶部和底部的空隙"）。
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  /**
   * 资料行：头像 + 用户名 + 右上角「更多」。
   *
   * **不设背景色**：沉浸式视频里这一行是叠在视频上的，底色一给就把视频挡掉了
   * （需求：用户资料背景透明）。
   *
   * 头像 + 作者名**一律**放进一个沉浸光感容器（需求：没有沉浸式标题的帖子也要加）。
   *
   * 为什么容器是 Toggle：内容区里只有 Toggle/Slider/Select 的沉浸光感生效
   * （官方《沉浸光感–功耗优化》，见 MaterialSurface.ets 的文件头）。这里的 Toggle
   * 不承载"开关"语义，只是材质的宿主，所以点它不做事，并且放开触摸测试 ——
   * 沉浸式视频里这一行盖在画面上，视频顶部这 52vp 里的双击点赞不能被它吃掉。
   */
  @Builder
  profileRow(post: MediaPost, index: number, overMedia: boolean) {
    Row({ space: 10 }) {
      // 头像 + 账号名那一块：**外面套一层 Row 吃掉多余宽度**（`layoutWeight(1)`），
      // 后面的「关注 / 更多」两个按钮自然排到右边。
      //
      // 为什么不是后面放 `Blank()`（原来是那么写的）：真机复现过 —— 同一份数据下，
      // **有些行的「关注」按钮整个不见了**（dump 里那一行的 Toggle 只剩头像容器和
      // 「更多」），临时在它前面加一个 Text 做实验它又出现了。原因是 FollowPill 是自定义
      // 组件、自己没写宽度（宽度写在它内部的 Toggle 上），`Blank()` 之后的测量结果不稳定，
      // 有时把它量成 0 宽。把"抢空间"的责任交给名字容器外层就稳定了。
      //
      // 注意里层的 Toggle 仍然**只包住内容**：它的材质底色要贴着"头像 + 名字"，
      // 不能跟着外层一起拉满。
      Row() {
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Row({ space: 10 }) {
            this.authorAvatar(post)
            this.authorName(post, overMedia)
          }
        }
        // 头像在容器里的 top / left / bottom 内缩**必须一致**（需求）：头像 34 + 上下各 3
        // = 容器高 40，正好和标准按钮高度对齐；left 也给 3，右边留给文字的多一点。
        .padding({ left: 3, right: 14, top: 3, bottom: 3 })
        .borderRadius(MATERIAL_BUTTON_SIZE / 2)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        // 沉浸式视频标题区不反色（见 rowMaterial），普通卡片也不反色：材质跟着主题走。
        .attributeModifier(new SurfaceModifier(this.materialThickness, false))
        .hitTestBehavior(HitTestMode.Transparent)
        .onChange((): void => {
          // 纯容器，不接功能（点击由下面 onClick 接）。
        })
        /*
         * 点这一块 = **打开用户主页**（需求："从 feeds 点击用户资讯模块后进入新页面"）。
         *
         * 为什么点的是这个 Toggle 而不是里面的头像/名字：这一块的可点区域就是材质容器的
         * 范围（头像 + 名字 + 内缩），点名字旁边的空白也算 —— 和 Instagram 一致，手指不会
         * 因为差几个 px 没点中。用户名拿不到（解析缺字段）时不打开，避免跳到一个空主页。
         */
        .onClick((): void => {
          if (post.ownerUsername.length > 0) {
            this.onOpenUser(post);
          }
        })
        // 这一块是材质容器：按住它时"咬住"列表滚动/翻页（判据见 MaterialSurface 的 holdsScroll）。
        .onTouch(trackMaterialTouch)
      }
      .layoutWeight(1)
      .height(PROFILE_ROW_HEIGHT)
      .alignItems(VerticalAlign.Center)
      /*
       * **这里不能裁**：材质容器（头像 + 名字那块 Toggle）的阴影是画在 Toggle 边界**之外**的，
       * 这一层 `clip(true)` 会把它切掉 —— 用户报的"用户资讯栏的背景阴影被外部容器裁剪了"就是它。
       * 名字溢出的兜底交给文本自己（`maxLines(1)` + `Ellipsis`，见 authorName / nameMaxWidth）。
       */
      .clip(false)
      // 「关注 / 已关注」按钮（挨着"更多"）。
      //
      // **不再因为"没有作者 id"就不画**：以前这里是 `if (post.ownerId.length > 0)`，
      // 于是一旦某个帖子解析不到 `user.pk`，这一行就少了整颗按钮 —— 用户报的
      // "部分帖子（多半是已关注的人）关注按钮消失"就有这一半原因。
      // 现在按钮恒定渲染：没有 id 时 `toggleFollow` 会退回**网页驱动**那条路
      // （去对方主页点它自己的关注按钮，见 pages/Index.followAuthor），照样能用。
      // 关注按钮：走 FollowPill（**自带 @ObjectLink**，点一下标签就地变 —— 这一点很关键，
      // 卡片是 ForEach 的 item builder 产出的，键值没变时不会重跑，行内读状态是刷不新的）。
      // ui 必须取自状态数组的元素，@ObjectLink 才接得上（同下面 PostActions）。
      //
      // 帖子页不显示它（`showFollowInRow=false`，需求）：那一页关注按钮在标题栏右上角。
      if (this.showFollowInRow) {
        FollowPill({
          ui: this.uiList[index],
          thickness: this.materialThickness,
          onTap: (on: boolean): void => {
            this.tapFollow(post, index, on);
          }
        })
      }
      // 「更多」：也做成按钮（需求），同样**暂不绑定功能**。
      this.iconButton($r('sys.symbol.sort'), overMedia, (): void => {
      })
    }
    .width('100%')
    .height(PROFILE_ROW_HEIGHT)
    .padding({ left: 12, right: 12 })
    // 沉浸式视频里这一行盖在视频上，而 HitTestMode 默认值会**阻塞兄弟节点**的触摸测试 ——
    // 不放开的话，视频顶部这 52vp 里的双击点赞会失效。Transparent = 自己不阻塞兄弟，
    // 子节点的点击照常能收到（两个图标按钮要能点）。
    .hitTestBehavior(HitTestMode.Transparent)
    // 给一个 id：BackdropTone 要按这一行的位置去快照里取"文字背后的颜色"，
    // 位置由 syncOverlayBand 用 componentUtils 量（滚动不会触发 onAreaChange，
    // 所以不能靠它，见 cardSpan 的说明）。
    .id(this.overlayRowId(post))
  }

  /** 资料行头像（有图用图，没图垫一块底色圆）。 */
  @Builder
  authorAvatar(post: MediaPost) {
    if (post.ownerAvatarUrl.length > 0) {
      Image(post.ownerAvatarUrl)
        .draggable(false)
        .width(34)
        .height(34)
        .borderRadius(17)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))
    } else {
      // 原实现是 Circle({...}).fill(...)：CircleAttribute.fill 的重载 @since 26.0.0，
      // 而本模块 compatibleSdkVersion 为 6.1.0(23)，在 23 的设备上不保证可用
      // （编译器会报 "The 'fill' API is supported since SDK version 26.0.0"）。
      // 用 borderRadius 画圆，只依赖早就稳定的属性。
      Column()
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor($r('app.color.field_background'))
    }
  }

  /**
   * 资料行作者名。
   *
   * 需求："取消视频沉浸式标题反色效果，包括文字" —— 叠在视频上的这一行**不再**按画面明暗
   * 反色（原来会根据 BackdropTone 侦测到的背景亮暗在深浅之间切换），统一用主题正文色。
   */
  /**
   * 账号名允许占的最大宽度（vp）—— 名字过长时靠它**截断**，而不是把右边的按钮顶出屏幕。
   *
   * 为什么必须给死宽度：`Text` 默认按内容量宽，名字很长时那一块会一直长下去；外层虽然有
   * `layoutWeight(1)` 兜着，但按钮是"排在它后面"的兄弟，测量顺序一变就会被挤出屏幕
   * （用户报的"用户名过长时右侧关注按钮跑到屏幕外"）。
   * 这里把可用的横向空间算清楚，剩下的才是名字的：屏幕宽 − 行的左右内缩 − 三处间隙
   * − 头像 − 名字容器自己的左右内缩 − 「更多」按钮 −（有的话）关注按钮。
   */
  private nameMaxWidth(post: MediaPost): number {
    const screenVp: number = this.screenWidthPx > 0 ? px2vp(this.screenWidthPx) : 360;
    const rowPadding: number = 12 + 12;
    const gaps: number = 10 + 10;
    const avatar: number = 34;
    const namePadding: number = 3 + 14;
    const more: number = MATERIAL_BUTTON_SIZE;
    const pill: number = post.ownerId.length > 0 ? MATERIAL_PILL_WIDTH : 0;
    // 留一点余量（字体度量与四舍五入），宁可早一点省略号，也不要顶出去。
    const slack: number = 8;
    const room: number = screenVp - rowPadding - gaps - avatar - namePadding - more - pill - slack;
    return room > 48 ? room : 48;
  }

  /**
   * 资料行的账号名。
   *
   * 需求："取消视频沉浸式标题反色效果，包括文字" —— 叠在视频上的这一行**不再**按画面明暗
   * 反色（原来会根据 BackdropTone 侦测到的背景亮暗在深浅之间切换），统一用主题正文色。
   */
  @Builder
  authorName(post: MediaPost, overMedia: boolean) {
    Text(post.ownerUsername.length > 0 ? post.ownerUsername : 'instagram')
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.primary_text'))
      // 单行 + 省略号：长名字不换行、不把右边的按钮顶出去（见 nameMaxWidth）。
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: this.nameMaxWidth(post) })
  }

  /**
   * 点一下关注按钮：**两个事件入口在这里去重**（见 FollowPill 的注释）。
   *
   * `Toggle` 的 `onChange` 与通用 `onClick` 可能都来（也可能只来一个），两个入口给的
   * **是同一个目标状态**（onClick 那边按取反算），所以重复一次也不会把状态切回去；
   * 这里的 400ms 窗口只是别让同一个动作发两次请求。
   */
  private tapFollow(post: MediaPost, index: number, on: boolean): void {
    const key: string = FeedMapper.keyOf(post);
    const now: number = Date.now();
    const last: number = this.followTapAt.get(key) ?? 0;
    if (now - last < FOLLOW_TAP_DEDUPE_MS) {
      return;
    }
    this.followTapAt.set(key, now);
    this.toggleFollow(post, index, on);
  }

  /**
   * 把关注状态设成 `on`：**先乐观切换**（按钮立刻变），再发请求，失败回滚。
   *
   * 需求（本轮实现）：
   *   - 显示关注状态：未关注「关注」、已关注「已关注」；
   *   - 点击关注 / 取消关注走 HTTP 直发（core/NativeFollow），不驱动隐藏网页。
   * 状态写进 `uiList[index]`（@Observed，FollowPill 用 @ObjectLink 订阅 → 就地重绘），
   * 同时记进 **FollowState**（会话级：切页/重建/刷新都不会被旧的接口值顶回去）。
   *
   * 两道闸门（都是"看着像点了没反应/点了又弹回去"的老毛病）：
   *   · **幂等**：目标状态和当前一致就直接返回（重复回调不会被当成"再切一次"）；
   *   · **请求中互斥**：同一条帖子的上一次请求还没回来时，后续回调一律吃掉
   *     （否则一次点击变成"关注 + 取关"两个来回，服务端抵消、界面回滚）。
   */
  private toggleFollow(post: MediaPost, index: number, on: boolean): void {
    // **id 为空也照样处理**：HTTP 直发需要 id，但还有网页驱动那条退路（见 Index.followAuthor），
    // 所以不能因为解析不到 pk 就让按钮"点了没反应"（按钮本身现在恒定渲染，见 profileRow）。
    /*
     * **按 key 取当前那一条的 ui，不用闭包里的 index**（审计 D3）。
     *
     * 关注按钮的 `onTap` 捕获的是**构建时**的 index，而 `ForEach` 的键值没变时 item builder 不会
     * 重跑（本文件 1866 行自述过这一点）。刷新/插帖之后，那个旧 index 指向的已经是别人 ——
     * 表现就是"点 A 关注，B 变成已关注"。`toggleSaved` 早就改成按 key 取了，这里对齐它。
     */
    const key: string = FeedMapper.keyOf(post);
    const current: PostUi | undefined = this.uiByKey.get(key);
    if (current !== undefined) {
      if (current.following === on) {
        return;
      }
    } else if (index < 0 || index >= this.uiList.length) {
      return;
    } else if (this.uiList[index].following === on) {
      return;
    }
    if (this.followBusy.has(key)) {
      return;
    }
    this.followBusy.add(key);
    // 真正要改的那一条：按 key 取（见上面 D3 的说明），拿不到就别动。
    const ui: PostUi | undefined = this.uiByKey.get(key);
    if (ui === undefined) {
      this.followBusy.delete(key);
      return;
    }
    const before: boolean = ui.following;
    ui.following = on;
    FollowState.remember(post.ownerId, post.ownerUsername, on);
    this.onFollow(post, on).then((ok: boolean): void => {
      this.followBusy.delete(key);
      if (ok) {
        return;
      }
      // 失败回滚：把按钮改回去（同时把本地覆盖也改回去，免得刷新时又把它顶回来）。
      ui.following = before;
      FollowState.remember(post.ownerId, post.ownerUsername, before);
    }).catch((): void => {
      this.followBusy.delete(key);
      ui.following = before;
      FollowState.remember(post.ownerId, post.ownerUsername, before);
    });
  }

  /**
   * 资料行右侧的小图标按钮（更多）。
   *
   * 外观走统一的沉浸光感材质（MaterialSurface.MaterialIconButton）；同 followButton，
   * 叠在视频上的这一颗不再反色。
   */
  @Builder
  iconButton(symbol: Resource, overMedia: boolean, action: () => void) {
    MaterialIconButton({
      symbol: symbol,
      buttonSize: 40,
      iconSize: 20,
      autoInvert: !overMedia
    })
  }

  /** 叠字行的组件 id（只有沉浸式视频里才有这个节点）。 */
  private overlayRowId(post: MediaPost): string {
    return `${OVERLAY_ROW_ID_PREFIX}${FeedMapper.keyOf(post)}`;
  }

  /**
   * 把"正在看的那条帖子"的叠字行位置报给 BackdropTone。
   *
   * 只报**焦点卡片**（focusKey，见 refreshFocus）的叠字行：屏幕上可能同时有两条沉浸式视频
   * 的叠字行，只按最后一次上报的算，所以必须指定是"用户正在看的那条"，否则取到的
   * 是别的画面的颜色。焦点不是沉浸式视频（图片帖、普通卡片）时报 0/0，让侦测跳过叠字那块。
   */
  private syncOverlayBand(): void {
    const index: number = this.focusIndexOf(this.focusKey);
    if (index < 0 || !this.immersiveVideo(this.posts[index])) {
      AppSettings.setOverlayBand(0, 0);
      return;
    }
    const screenHeightPx: number = this.screenBottom;
    if (screenHeightPx <= 0) {
      return;
    }
    try {
      const info = this.getUIContext().getComponentUtils()
        .getRectangleById(this.overlayRowId(this.posts[index]));
      const top: number = info.windowOffset.y / screenHeightPx;
      const bottom: number = (info.windowOffset.y + info.size.height) / screenHeightPx;
      if (bottom > top) {
        AppSettings.setOverlayBand(top, bottom);
        // 画面（焦点视频）刚换过：把叠字亮度侦测拉回密集采样（见 BackdropTone.kick）。
        BackdropTone.kick();
        return;
      }
    } catch (err) {
      // 节点还没布局出来：这一拍先不报，下一拍量到再说。
      return;
    }
    AppSettings.setOverlayBand(0, 0);
  }

  /** 这条视频帖的首帧出来没有（决定封面叠层撤不撤）。 */
  private isVideoReady(key: string): boolean {
    return this.readyVideoKeys.indexOf(key) >= 0;
  }

  /** 视频帖的键（shortcode 优先）。 */
  private videoKeyOf(post: MediaPost): string {
    return post.shortcode.length > 0 ? post.shortcode : post.id;
  }

  /**
   * 这条视频帖现在有没有挂着播放器（只有"正在播的"和"预加载的下一条"有）。
   *
   * 和 mediaBlock 里那个 if 条件**必须一致**：封面该不该撤，取决于"播放器在不在"，
   * 而不是"曾经首帧就绪过"—— 否则滑过去再回来时，播放器已经不在了（滚动时被销毁），
   * 封面又因为"曾经 ready"不再显示，那块就只剩一片黑。
   */
  private hasSurface(post: MediaPost): boolean {
    return this.isPlaying(post) || this.preloadKey === FeedMapper.keyOf(post);
  }

  /** 播放器现在能不能露出来（挂着播放器 + 首帧已经在表面上了）。 */
  private videoShown(post: MediaPost): boolean {
    return this.hasSurface(post) && this.isVideoReady(this.videoKeyOf(post));
  }

  /**
   * 播放器报首帧就绪：记下来并触发重绘（换新数组才认）。
   *
   * 和 reels 一致：**收到首帧回调就立刻撤封面**。这里不再压宽限时间 —— AVPlayer 的 `playing`
   * 是"画面真的在动"的时刻，首帧已经画在表面上了，再压反而是让视频白播一会儿。
   */
  private markVideoReady(key: string): void {
    if (key.length === 0 || this.isVideoReady(key)) {
      return;
    }
    const next: string[] = this.readyVideoKeys.slice(0);
    next.push(key);
    // 只留最近 12 条：列表很长，这个表只用来"撤封面"，不需要长期记住。
    this.readyVideoKeys = next.length > 12 ? next.slice(next.length - 12) : next;
  }

  /** 滚动过程中的节流上报（每 200ms 最多量一次，够跟得上画面）。 */
  private syncOverlayBandThrottled(): void {
    const now: number = Date.now();
    if (now - this.lastBandSyncMs < OVERLAY_BAND_SYNC_MS) {
      return;
    }
    this.lastBandSyncMs = now;
    this.syncOverlayBand();
  }

  /**
   * 沉浸式视频里，叠在视频上的文字/图标用什么颜色。
   *
   * 这一行没有底色（需求：资料背景透明），所以只能靠文字自己跟画面拉开对比。
   * 颜色不是按主题猜的，而是**实测**的：BackdropTone 每 700ms 给内容层拍一张低分辨率
   * 快照，取这一行所占的那块区域的平均亮度 —— 那块明显是浅色（白）时才把文字翻成深色，
   * 否则就用当前主题该有的那一档（深色主题 → 浅色字）。
   *
   * 只有沉浸式视频会用到它；普通卡片里这一行画在页面底色上，照旧用资源色。
   */
  private overlayTextColor(): string {
    if (this.overlayBackdropLight) {
      return '#0A0A0A';
    }
    return this.isDarkUi ? '#F1F1F1' : '#0A0A0A';
  }

  /**
   * 媒体区：视频 / 多图轮播 / 单图 / 占位，外加双击点赞与放大爱心。
   *
   * immersive = true 是给"沉浸式视频"用的（见 immersiveVideo）：这类帖子的媒体框被
   * 高度上限压得比画面本身**宽**（见 MEDIA_MAX_HEIGHT_RATIO），用 Contain 会在左右
   * 留出两条底色边；需求要"宽度填满屏幕"，所以换成 Cover —— 代价是上下各裁掉一点，
   * 这正是"填满"的必然结果（不改比例、不拉伸，只裁）。
   *
   * 外面包一层是为了给「双击点赞」一个统一的落点，同时给放大爱心一个叠加层：
   * 媒体有视频、多图轮播、单图、占位四种形态，逐个挂手势容易漏；包一层就只有一个
   * 手势目标，爱心也只需要叠这一处。
   */
  @Builder
  mediaBlock(post: MediaPost, immersive: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.isInlineVideo(post)) {
        // 视频帖：播放器 = AVPlayer + XComponent 的共用组件 VideoSurface（与 reels 完全一致，
        // 见 VideoSurface 的文件头：showFirstFrameOnPrepare + 1 秒起播缓冲才是"没有黑闪"的关键，
        // 而 ArkUI 的 Video 组件拿不到这两个旋钮）。
        //
        // 尺寸：外层 Stack 定宽高比，里面的播放器和封面都是 100%×100% —— 两层盒子**完全一致**，
        // 所以滚动时不会出现"媒体区错位闪一下"（之前是各写各的 aspectRatio，容易对不上）。
        Stack({ alignContent: Alignment.Center }) {
          // 只有"正在播的"和"提前准备的下一条"才挂播放器：缓存区里每条视频都开一个解码器
          // 会互相抢带宽（也正是预加载想避免的事）。条件与 hasSurface 共用（见那里的说明）。
          if (this.hasSurface(post)) {
            VideoSurface({
              url: post.videoUrl,
              playing: this.isPlaying(post),
              preload: this.preloadKey === FeedMapper.keyOf(post),
              // **裁切填满**（而不是完整显示）：这个盒子是按帖子的媒体比例、且被高度上限压过的，
              // 与视频自身比例往往不一致 —— 用 Contain 就会在上下留出黑边，而播放器表面那块黑
              // 在滚动/起播时会表现为"容器闪烁错位"（用户报的现象）。Cover 让画面始终填满盒子，
              // 下面的封面也用 Cover，两者盒子一致 → 撤封面时不再跳。
              cover: true,
              // 静音开关是全局的（媒体区那颗喇叭键控制的），见 AppSettings.SETTING_VIDEO_MUTED。
              muted: this.videoMuted,
              onFirstFrame: (): void => {
                // 首帧已经在表面上了：撤封面（这一下就是"封面直切画面"）。
                this.markVideoReady(this.videoKeyOf(post));
              },
              onError: (): void => {
                // 播不出来也得把封面撤掉，否则这条就永远只剩封面（用户会以为卡住了）。
                this.onPlaybackError();
                this.markVideoReady(this.videoKeyOf(post));
              }
            })
              .width('100%')
              .height('100%')
          }
          // 封面：首帧就绪前盖住播放器。没有封面图（displayUrl 为空）时垫一层底色，
          // 免得露出原生表面在首帧之前的那片黑。
          if (!this.videoShown(post)) {
            if (post.displayUrl.length > 0) {
              // 预解码的小图垫在封面上：冷启动时它几十毫秒就到，真封面加载完自然盖住
              // （见 core/PosterCache 与 posterReady）。
              Stack() {
                if (PosterCache.has(post.displayUrl, this.posterReady)) {
                  Image(PosterCache.pixel(post.displayUrl)!)
                    .draggable(false)
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                    .hitTestBehavior(HitTestMode.None)
                }
                Image(post.displayUrl)
                  .draggable(false)
                  .width('100%')
                  .height('100%')
                  // 封面也必须 Cover：播放器现在是 Cover（填满盒子），封面若用 Contain
                  // 两者画面不一致，撤封面那一瞬就会跳（用户报的"闪烁错位"）。
                  .objectFit(ImageFit.Cover)
                  // 不吃手势：双击点赞、滑动都要照常落到下面那层。
                  .hitTestBehavior(HitTestMode.None)
              }
              .width('100%')
              .height('100%')
            } else {
              Column()
                .width('100%')
                .height('100%')
                .backgroundColor($r('app.color.field_background'))
                .hitTestBehavior(HitTestMode.None)
            }
          }
        }
        .width('100%')
        .aspectRatio(this.mediaAspect(post))
        // 沉浸式视频要裁掉超出部分（FIT_CROP 只作用于播放器，封面这层自己也裁一下）。
        .clip(immersive)
      } else if (post.displayUrl.length > 0) {
        if (post.imageUrls.length > 1) {
          // 多图轮播：圆点指示器由 MediaCarousel 画在图片**下方**（Swiper 自带的
          // indicator 是压在图片上的），于是它自然落在媒体与动作区之间。
          //
          // **含视频页**：每一页各自说自己是图还是视频（见 MediaCarousel.slides 与
          // MediaPost.hasVideo），视频页由那个组件用**同一个 VideoSurface** 播 ——
          // 播放逻辑（聚焦才播、翻走就停、静音、封面直切首帧）与单视频帖完全一致。
          MediaCarousel({
            slides: post.mediaSlides,
            imageUrls: post.imageUrls,
            idPrefix: post.id,
            // **和盒子同源**：图片段的比例（= 最高那张图的比例），见 carouselAspect。
            aspect: this.carouselAspect(post),
            // 首屏封面预解码（见 PosterCache）：多图帖的第一张也垫小图。
            posterReady: this.posterReady,
            // 卡片可能会因为点赞等状态变化被重建，页号靠这两项传进传出。
            initialPage: this.carouselPage(post),
            // 这条被聚焦时，里面的视频页才播（见 MediaCarousel.pagePlaying）。
            playing: this.isPlaying(post),
            preload: this.preloadKey === FeedMapper.keyOf(post),
            muted: this.videoMuted,
            onPageChange: (index: number): void => {
              this.carouselPages.set(FeedMapper.keyOf(post), index);
            },
            onVideoReady: (page: number): void => {
              // 与单视频帖共用"已就绪"这套记账（键里带页号，互不覆盖）。
              this.markVideoReady(`${this.videoKeyOf(post)}#${page}`);
            },
            onVideoError: (page: number): void => {
              this.onPlaybackError();
              this.markVideoReady(`${this.videoKeyOf(post)}#${page}`);
            }
          })
        } else {
          // 只有封面图，不叠任何播放角标：播放完全由聚焦决定，角标会让人以为要点。
          if (PosterCache.has(post.displayUrl, this.posterReady)) {
            // 预解码的小图垫在真图下面（见 core/PosterCache）：首屏不等真图下载完就有画面。
            Stack() {
              Image(PosterCache.pixel(post.displayUrl)!)
                .draggable(false)
                .width('100%')
                .aspectRatio(this.mediaAspect(post))
                .objectFit(immersive ? ImageFit.Cover : ImageFit.Contain)
                .backgroundColor($r('app.color.field_background'))
              Image(post.displayUrl)
                .draggable(false)
                .width('100%')
                .aspectRatio(this.mediaAspect(post))
                .objectFit(immersive ? ImageFit.Cover : ImageFit.Contain)
                .backgroundColor($r('app.color.field_background'))
            }
            .width('100%')
            .aspectRatio(this.mediaAspect(post))
          } else {
            Image(post.displayUrl)
              .draggable(false)
              .width('100%')
              .aspectRatio(this.mediaAspect(post))
              .objectFit(immersive ? ImageFit.Cover : ImageFit.Contain)
              .backgroundColor($r('app.color.field_background'))
          }
        }
      } else {
        // 连封面都没有的兜底占位：这里只说明「这条是视频/图片」，不是播放按钮，
        // 所以保留（海报上那个播放角标已经去掉了）。
        Column() {
          SymbolGlyph(post.isVideo() ? $r('sys.symbol.play_square') : $r('sys.symbol.picture'))
            .fontSize(42)
            .fontColor([$r('app.color.secondary_text')])
        }
        .width('100%')
        .aspectRatio(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.field_background'))
      }

      // ---- 媒体区右下角的一排按钮：静音（左）→ 下载（右）----
      // 需求：下载在媒体区**右下角**，有静音时排在它**左边**；图片/视频帖子都要。
      //
      // **为什么直接把按钮行放进媒体盒子（而不是再叠一层"对齐壳"）**：前几版按"媒体盒子的
      // 宽高比"算一层同尺寸的壳，只要算错一点（轮播盒子 = 图片 + 圆点行、无封面占位是 1:1
      // 方块、视频是被高度上限修正过的比例）按钮就会偏上或**探出媒体区域** —— 用户反馈的
      // "部分图片帖子下载按钮下沉超出图片边界"就是它。
      // 现在把媒体盒子的 alignContent 改成 BottomEnd：媒体内容自己是"铺满盒子"的
      // （宽 100% + 各自的比例），对齐方式对它没有影响；按钮行作为**同一个 Stack 的兄弟**
      // 直接吃这个 BottomEnd，位置与媒体类型无关，永远不会算错。
      // 按钮行的内缩走它自己的 padding（壳的 alignContent 只负责把它压到底部）。
      Row({ space: MEDIA_BUTTON_GAP }) {
        if (post.isVideo()) {
          MediaMuteButton()
        }
        MediaDownloadButton({
          // 地址**点按那一刻**才解析：多图轮播当前页会变，写成 @Prop 会一直停在构建时那一页
          // （需求："下载按钮没有绑定当前显示图片"）。
          resolveUrl: (): string => this.downloadUrl(post),
          ext: post.isVideo() ? 'mp4' : 'jpg',
          title: post.shortcode.length > 0 ? post.shortcode : post.id,
          isVideo: post.isVideo()
        })
      }
      .width('100%')
      // 底边距要**躲开轮播的圆点行**：圆点画在图片下方、但仍在媒体盒子里面
      // （见 MediaCarousel 与 mediaBoxAspect），只写 MEDIA_BUTTON_INSET 的话按钮会落到
      // 圆点那一行上、看着像"掉到图片外面去了"（用户报的"部分图片帖子下载按钮还是错位"）。
      .padding({ bottom: this.mediaButtonBottom(post), right: MEDIA_BUTTON_INSET })
      .justifyContent(FlexAlign.End)
      // 这层别把媒体上的拖动/双击吃掉（按钮自己有 PanGesture 做"四象锁定"，
      // 见 MaterialSurface.consumePan）。
      .hitTestBehavior(HitTestMode.Transparent)

      // 放大爱心：叠在媒体上（跟手 —— 落点是双击的位置，见下面的手势）。
      // 媒体盒子现在是 BottomEnd 对齐，所以拿不到坐标时它才退回 `align(Center)`。
      LikeBurst({ state: this.burst, itemKey: FeedMapper.keyOf(post) })
    }
    .width('100%')
    // **把媒体盒子的高度钉死**（按媒体各分支自己的宽高比算，见 mediaBoxAspect）。
    //
    // 为什么必须钉：Stack 的高度 = 最高的子节点。按钮行本身有 40 + 10 内缩 = 50vp 高，
    // 而**很宽的图片**（比如横幅长图）媒体高度只有 40vp 出头 —— 这时盒子会被按钮行撑高，
    // 按钮就落到图片下边去了（用户报的"部分图片帖子下载按钮下沉、超出图片边界"）。
    // 钉死之后子节点再也改不了盒子高度，媒体与按钮的相对位置就固定了。
    .aspectRatio(this.mediaBoxAspect(post))
    // 媒体内容铺满盒子，所以这个对齐只对"叠在媒体上的按钮行/爱心"起作用。
    .alignContent(Alignment.BottomEnd)
    // 双击媒体点赞。用 parallelGesture 而不是 gesture：视频那一条里放的是 Video
    // 组件，它可能自己挂着点击手势，串行的 gesture 会被它吃掉、双击就没反应了。
    .parallelGesture(
      // distanceThreshold 是关键 —— 不设的话默认 2^31-1，等于「手指没划出这个组件
      // 就算一次点击」，快滑两下就被凑成双击误点赞（见 LIKE_TAP_DISTANCE_VP）。
      TapGesture({ count: 2, distanceThreshold: LIKE_TAP_DISTANCE_VP })
        .onAction((event: GestureEvent): void => {
          // **跟手**：爱心落在双击的位置（localX/localY 就是相对这个媒体盒子的 vp 坐标）。
          const fingers: Array<FingerInfo> = event.fingerList;
          const x: number = fingers.length > 0 ? fingers[0].localX : -1;
          const y: number = fingers.length > 0 ? fingers[0].localY : -1;
          // 先放心形动画：它是纯视觉反馈，不该等网页那边点完再出现。
          this.showLikeBurst(FeedMapper.keyOf(post), x, y);
          this.onLikeMedia(post);
        })
    )
    .id(this.mediaId(post))
  }

  /**
   * 媒体区按钮行离**媒体盒子底边**的距离（vp）。
   *
   * 多图轮播的圆点行画在图片下方、但仍在媒体盒子内部（盒子 = 图片 + 圆点行，
   * 见 mediaBoxAspect），所以按钮要多让出这一行的高度，才能压在**图片**的右下角。
   * 判据必须和 mediaBlock / mediaBoxAspect 的分支一致：轮播 = 多图 + 非内联视频 + 有封面。
   */
  private mediaButtonBottom(post: MediaPost): number {
    const carousel: boolean = post.isCarousel() && post.displayUrl.length > 0;
    return carousel ? DOT_ROW_HEIGHT + MEDIA_BUTTON_INSET : MEDIA_BUTTON_INSET;
  }

  /**
   * 这条帖子「下载」应该下哪个地址。
   *
   * **优先原始地址**（originalVideoUrl / originalImageUrls，见 core/MediaQuality）：
   * 展示用的那份已经降级到 1080 档省流量了，下载要的是原图/原视频。
   * 多图轮播下**当前显示的那一张**（carousel 的页号记在 carouselPages 里）——
   * 这个方法由下载按钮在**点按那一刻**调用（见 MediaDownloadButton.resolveUrl）。
   */
  private downloadUrl(post: MediaPost): string {
    if (post.isVideo()) {
      return post.originalVideoUrl.length > 0 ? post.originalVideoUrl : post.videoUrl;
    }
    const originals: Array<string> = post.originalImageUrls;
    if (originals.length === 0) {
      return post.displayUrl;
    }
    const page: number = this.carouselPage(post);
    const index: number = page >= 0 && page < originals.length ? page : 0;
    return originals[index];
  }

  /**
   * 这条帖子要不要走"沉浸式视频"排版。
   *
   * 需求：**竖向的**视频（高 > 宽）才让画面顶到卡片最上面（占用顶部的用户资料区）、
   * 宽度填满屏幕，资料行透明地叠在视频上；横向和方形的视频资料行显示在**媒体外面**。
   * 图片帖一律不受影响（永远普通布局）。
   *
   * 判据用**原始宽高比**（aspectRatio，宽/高），不是被高度上限修正过的 mediaAspect ——
   * 后者会把竖视频的框拉宽，拿它判断就把竖向当成"不竖"了。
   */
  private immersiveVideo(post: MediaPost): boolean {
    return post.isVideo() && post.aspectRatio() < IMMERSIVE_VIDEO_MAX_ASPECT;
  }

  /**
   * 网页侧到底有没有抓到发布时间。
   *
   * 抓不到时（timeline 接口没给 taken_at、页面上也没有可解析的 <time>）卡片**不显示**
   * 这一行 —— 宁可没有，也不要显示一个瞎猜的时间。判据单独一个方法，
   * 是为了让 @Builder 里能"先判断再取值"，不用在 UI 描述里声明局部变量。
   */
  private hasPostedTime(post: MediaPost): boolean {
    return post.takenAtMs > 0;
  }

  /** 这条帖子的正文是不是正展开着。 */
  private isCaptionExpanded(post: MediaPost): boolean {
    return this.expandedCaptionKey.length > 0 && this.expandedCaptionKey === FeedMapper.keyOf(post);
  }

  /**
   * 点正文：折叠 ↔ 展开。
   *
   * 只对"被截断过"的正文生效（没截断时点它没有任何变化，见 postCard 里的判断）。
   * 展开是把整段正文交回给 Text 自己排版（多行），折叠回到量好的两行。
   *
   * 状态赋值包在 animateTo 里：正文换掉的是文本内容（不做形变插值），
   * 但卡片高度的增长/收缩会走这条曲线，展开/收起才是"长出来/收回去"而不是突然一跳。
   */
  private toggleCaption(post: MediaPost): void {
    const key: string = FeedMapper.keyOf(post);
    const next: string = this.expandedCaptionKey === key ? '' : key;
    this.getUIContext().animateTo({ curve: Curve.EaseInOut, duration: CAPTION_TOGGLE_MS }, (): void => {
      this.expandedCaptionKey = next;
    });
  }

  /**
   * 正文的**折叠版前缀**：超过 CAPTION_COLLAPSED_MAX_LINES 行就截断，
   * 调用方在后面追加灰色的 CAPTION_MORE（" ... 展开"）；放得下就原样返回全文。
   *
   * 为什么要自己量：ArkUI 的 `textOverflow: Ellipsis` 会把超出部分的**所有**内容一起裁掉，
   * 放在尾巴上的"展开"提示会跟正文一起消失。所以这里用 MeasureUtils 先量出可用宽度，
   * 再二分找"加了提示仍然不超两行"的最长前缀，返回的串天生就排得下，
   * Text 上的 maxLines(2) 只是最后一道保险。
   *
   * 量不到屏幕宽度（screenWidthPx = 0）或测量接口不可用时不做截断，原样返回。
   * 结果按 post key 缓存（正文不变，量一次就够；卡片重建很频繁）。
   */
  private captionPrefix(post: MediaPost): string {
    if (post.caption.length === 0) {
      return '';
    }
    const key: string = FeedMapper.keyOf(post);
    const cached: string | undefined = this.captionLines.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const prefix: string = this.measureCaptionPrefix(post.caption);
    this.captionLines.set(key, prefix);
    return prefix;
  }

  /** 这条帖子的正文是不是被截断了（截断了才加提示、才响应点击）。 */
  private captionTruncated(post: MediaPost): boolean {
    return post.caption.length > 0 && this.captionPrefix(post) !== post.caption;
  }

  /** captionPrefix 的实际测量部分，拆出来只是为了让上面那层缓存读起来清楚。 */
  private measureCaptionPrefix(caption: string): string {
    if (this.screenWidthPx <= 0) {
      return caption;
    }
    try {
      const ui = this.getUIContext();
      // constraintWidth 默认单位是 vp，所以可用宽度换算成 vp 再减左右内边距与安全余量。
      const availVp: number = ui.px2vp(this.screenWidthPx) - CAPTION_SIDE_PADDING * 2
        - CAPTION_TAIL_SAFETY_VP;
      // 折叠判据与" ... 展开"的落点全在 core/CaptionFit（和 Reels 页那段正文同一套）。
      return CaptionFit.prefix(ui, caption, availVp, CAPTION_FONT_SIZE);
    } catch (err) {
      // 测量失败（接口不可用等）就退回不截断，界面照常显示。
      return caption;
    }
  }

  /**
   * **任意文本**的折叠前缀（译文也走它）。
   *
   * 原来的 `captionPrefix(post)` 是按 post key 缓存的；译文不是 post 自带的，所以另开一张按
   * **文本本身**缓存的表 —— 这样"点了翻译之后仍然能展开/收起"这件事，用的还是同一套量行逻辑
   * （见 postCard 里译文那两个分支）。
   */
  private prefixOfText(text: string): string {
    if (text.length === 0) {
      return '';
    }
    const cached: string | undefined = this.textFits.get(text);
    if (cached !== undefined) {
      return cached;
    }
    const prefix: string = this.measureCaptionPrefix(text);
    this.textFits.set(text, prefix);
    return prefix;
  }

  /** 这段文本放不放进两行（放不下才给" ... 展开"、才响应点击）。 */
  private textTruncated(text: string): boolean {
    return text.length > 0 && this.prefixOfText(text) !== text;
  }

  /**
   * 发布时间 → "post 了多久"。
   *
   * 分档：< 1 分钟「刚刚」→ 分钟 → 小时 → 天（< 7 天）→ 周（< 30 天）→ 月（< 365 天）→ 年。
   * 时间来自网页抓取（见 bridge/WebScripts 的 readTime 与 timeline 的 taken_at），
   * 单位与取整都在这里定，文案走 app.string.posted_ago_*。
   */
  private postedAgo(post: MediaPost): ResourceStr {
    // 未来时间（设备时钟偏差、抓到的值异常）一律按"刚刚"，不显示负数。
    const diff: number = Math.max(0, Date.now() - post.takenAtMs);
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

  @Builder
  postCard(post: MediaPost, index: number) {
    Column({ space: 0 }) {
      if (this.immersiveVideo(post)) {
        // 沉浸式视频：视频从卡片最顶上开始铺满宽度，资料行透明地叠在上面。
        // Stack 的对齐是 Top，所以视频的顶边 = 卡片顶边，资料行盖住它上面 52vp。
        Stack({ alignContent: Alignment.Top }) {
          this.mediaBlock(post, true)
          this.profileRow(post, index, true)
        }
        .width('100%')
      } else {
        this.profileRow(post, index, false)
        this.mediaBlock(post, false)
      }

      // 动作区：点赞/计数就地更新（见 PostActions / PostUi）。
      // ui 必须取自状态数组的元素，@ObjectLink 才接得上（见 uiList 的说明）。
      PostActions({
        ui: this.uiList[index],
        onLike: (): void => {
          this.onLike(post);
        },
        onComments: (): void => {
          this.onComments(post);
        },
        onRepost: (): void => {
          this.onRepost(post);
        },
        onSave: (): void => {
          this.toggleSaved(post);
        },
        onOpen: (): void => {
          this.onOpen(post);
        }
      })

      if (post.caption.length > 0) {
        if (this.isTranslationShown(post)) {
          /*
           * **译文态**：正文换成译文，但**展开/收起照旧可用**（需求："点击翻译后需要保留展开功能"）。
           *
           * 截断用的是"按文本量"的那套（`prefixOfText`）—— 译文和原文长度不同，不能拿原文的
           * 截断位置套上去；展开态同样给结尾灰色的" 收起"。
           */
          if (this.isCaptionExpanded(post)) {
            Text() {
              Span(this.translatedCaption(post))
                .fontColor($r('app.color.primary_text'))
              Span(CAPTION_LESS)
                .fontColor($r('app.color.secondary_text'))
            }
            .fontSize(CAPTION_FONT_SIZE)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: CAPTION_SIDE_PADDING, right: CAPTION_SIDE_PADDING, top: 6,
              bottom: this.hasPostedTime(post) ? 2 : 14 })
            .onClick((): void => {
              this.toggleCaption(post);
            })
          } else {
            Text() {
              Span(this.prefixOfText(this.translatedCaption(post)))
                .fontColor($r('app.color.primary_text'))
              if (this.textTruncated(this.translatedCaption(post))) {
                Span(CAPTION_MORE)
                  .fontColor($r('app.color.secondary_text'))
              }
            }
            .fontSize(CAPTION_FONT_SIZE)
            .maxLines(CAPTION_COLLAPSED_MAX_LINES)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: CAPTION_SIDE_PADDING, right: CAPTION_SIDE_PADDING, top: 6,
              bottom: this.hasPostedTime(post) ? 2 : 14 })
            .onClick((): void => {
              if (this.textTruncated(this.translatedCaption(post))) {
                this.toggleCaption(post);
              }
            })
          }
        } else if (this.isCaptionExpanded(post)) {
          // 展开态：全文 + 结尾灰色的" 收起"。行数不设限 —— 展开就是为了看全。
          Text() {
            Span(post.caption)
              .fontColor($r('app.color.primary_text'))
            Span(CAPTION_LESS)
              .fontColor($r('app.color.secondary_text'))
          }
          .fontSize(CAPTION_FONT_SIZE)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: CAPTION_SIDE_PADDING, right: CAPTION_SIDE_PADDING, top: 6,
            bottom: this.hasPostedTime(post) ? 2 : 14 })
          .onClick((): void => {
            this.toggleCaption(post);
          })
        } else {
          // 折叠态：正文（最多两行）+ 结尾灰色的" ... 展开"。
          // 截断位置是自己量出来的（见 captionPrefix），maxLines 只是保险。
          Text() {
            Span(this.captionPrefix(post))
              .fontColor($r('app.color.primary_text'))
            if (this.captionTruncated(post)) {
              Span(CAPTION_MORE)
                .fontColor($r('app.color.secondary_text'))
            }
          }
          .fontSize(CAPTION_FONT_SIZE)
          .maxLines(CAPTION_COLLAPSED_MAX_LINES)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 必须自己占满一行：卡片根 Column 的对齐是 Start，但这条 Text 没有宽度时
          // 只会占内容宽，看起来就没贴左。
          .width('100%')
          .textAlign(TextAlign.Start)
          // 下面还要跟发布时间时就把间距收窄，别让卡片底部显得松散。
          .padding({ left: CAPTION_SIDE_PADDING, right: CAPTION_SIDE_PADDING, top: 6,
            bottom: this.hasPostedTime(post) ? 2 : 14 })
          .onClick((): void => {
            // 没被截断的正文点了不该有任何变化（不然就是"点了没反应"的怪手感）。
            if (this.captionTruncated(post)) {
              this.toggleCaption(post);
            }
          })
        }
      } else if (!this.hasPostedTime(post)) {
        Blank().height(12)
      }

      // 发布时间：卡片最底下一行（正文之下），"post 了多久"。抓不到就不渲染。
      if (this.hasPostedTime(post)) {
        /*
         * 需求："显示位置应该在发布时间右侧，保持间隙" —— 所以**不给时间 layoutWeight**，
         * 让「3小时前」和「翻译」挨着排、中间留一个固定间隔；原来时间吃掉整行会把翻译顶到最右边。
         */
        Row({ space: 2 }) {
          Text(this.postedAgo(post))
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .textAlign(TextAlign.Start)
          /*
           * 「翻译」就在发布时间**旁边**（需求），点一下把正文翻成系统语言、文案变「显示原文」。
           * 只有非中文正文才会真的画出这颗（见 TranslateLabel / Translator）。
           */
          TranslateLabel({
            source: post.caption,
            showing: this.isTranslationShown(post),
            fontSize: 12,
            onToggle: (show: boolean): void => {
              this.toggleTranslation(post, show);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.Start)
        .padding({
          left: CAPTION_SIDE_PADDING,
          right: CAPTION_SIDE_PADDING,
          // 上下都留一点空隙，别让时间和正文/卡片边界粘在一起。
          top: post.caption.length > 0 ? 6 : 10,
          bottom: 16
        })
      }
    }
    .width('100%')
    // 卡片根容器显式左对齐：Column 默认是居中对齐，正文之类没占满宽度的子节点会被居中。
    .alignItems(HorizontalAlign.Start)
    // 供 cardSpan 量位置：聚焦按「卡片中心 vs 屏幕中心」比较。
    .id(this.cardId(post))
    .onVisibleAreaChange([VISIBLE_RATIO], (isExpanding: boolean, ratio: number): void => {
      // 判据是 currentRatio；isExpanding 只说明可见面积在变大还是变小，不能当可见性用。
      /*
       * **按 key 反查**当前下标，不用闭包里那个（审计 D4）。
       *
       * 这个闭包和构建时的 item builder 绑在一起，`ForEach` 键值不变时不会重跑 —— 刷新/插帖之后
       * 闭包里的 index 已经过期，写进 `visiblePosts` 就会与帖子错位：`refreshFocus` 把过期条目
       * 丢掉（它的注销日志就是为这种情况准备的），可见集合可能变空 → **正在播的视频被停掉**。
       */
      this.noteVisibility(post, this.indexOfPost(post), ratio > VISIBLE_RATIO);
    })
  }

  /**
   * 一条帖子在**当前** `posts` 里的下标（找不到给 -1）。
   *
   * 给 `onVisibleAreaChange` 那种"闭包里的 index 会过期"的回调用（见审计 D4）。
   */
  private indexOfPost(post: MediaPost): number {
    const key: string = FeedMapper.keyOf(post);
    for (let index: number = 0; index < this.posts.length; index++) {
      if (FeedMapper.keyOf(this.posts[index]) === key) {
        return index;
      }
    }
    return -1;
  }

  build() {
    // 结构（需求定的）：
    //   最顶上是一层**透明 Stack**（高度 = 标题栏那一段 FEED_START_OFFSET）→ 第一条帖子
    //   因此被往下推、避让 HdsNavigation；下面紧接着就是 FeedList。
    //   同时**帖子要能穿过 HdsNavigation**：靠 Refresh/List 的 `.clip(false)` —— 列表的
    //   可视区顶边仍在屏幕上方（它就在那层透明 Stack 下面），但**内容不再被裁掉**，滚动时
    //   卡片会画到标题栏底下去，标题栏的沉浸材质/渐变模糊才有东西可采样。
    //   下拉刷新用**系统原生**那颗图标：它画在 Refresh 的顶边，而 Refresh 的顶边正好在标题栏
    //   下沿（因为上面垫了那层 Stack），所以它天然是"避让标题栏"的，不用自绘。
    Column() {
      Stack()
        .width('100%')
        .height(this.topOffset)

      if (this.posts.length === 0) {
        // 空态也要能下拉刷新。
        //
        // 为什么单独给一份 Refresh + List：列表为空时状态行会在下面提示「请下拉刷新」，
        // 而早先这一支里根本没有可滚动子节点，**下拉刷新是拉不动的** —— 用户看到的正是
        // 「没有帖子、也刷不出来」。这里用一个撑满高度的空 ListItem 把下拉手势接住，
        // 内容还是原来那两样（加载中铺骨架屏、否则给空态 + 加载按钮）。
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0, scroller: this.listScroller }) {
            ListItem() {
              if (this.loading) {
                Column() {
                  FeedSkeleton()
                    .width('100%')
                }
                .width('100%')
                .height('100%')
              } else {
                Column({ space: 14 }) {
                  Text($r('app.string.feed_empty'))
                    .fontSize(15)
                    .fontColor($r('app.color.secondary_text'))
                  MaterialLabelButton({
                    labelRes: $r('app.string.feed_load'),
                    pillWidth: 96,
                    fontSize: 14,
                    tone: TONE_ACCENT,
                    onTap: (): void => {
                      this.onLoad();
                    }
                  })
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%')
            .height('100%')
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // **别裁内容**：列表可视区在透明 Stack 下面，关掉裁剪后滚动的卡片才会画到
          // 标题栏底下去（需求："帖子可以穿过 hdsnavigation"）。
          .clip(false)
          // 空态那条 List 也要挡：加载按钮本身就是材质按钮。
          //
          // 判据是 holdsScroll（见 MaterialSurface）：**按住之后**的拖动才咬住（长按滑动按钮
          // 不影响页面），按下去就划的**竖向**拖动放行，让列表正常滚 —— 否则手指落在按钮上
          // 页面就滑不动（用户报的"被按钮的 4-way-lock 卡手"）。
          .onTouch(trackScrollTouch)
          .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer,
                                          others: Array<GestureRecognizer>): GestureJudgeResult => {
            if (holdsScroll(event) && current.isBuiltIn()
              && current.getType() === GestureControl.GestureType.PAN_GESTURE) {
              return GestureJudgeResult.REJECT;
            }
            return GestureJudgeResult.CONTINUE;
          })
        }
        .width('100%')
        .height('100%')
        // 下拉刷新也是一条"会带着页面走"的内建 PAN：手指按在材质按钮上往下拖时，列表那条
        // PAN 被拒了，但 Refresh 自己这条还在，页面照样被拉下来（用户看到的就是"只有向上滑
        // 不影响页面"）。判据同上面 List 那条 —— 同样是 holdsScroll，所以"按住才咬"。
        .onTouch(trackScrollTouch)
        .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer,
                                        others: Array<GestureRecognizer>): GestureJudgeResult => {
          if (holdsScroll(event) && current.isBuiltIn()
            && current.getType() === GestureControl.GestureType.PAN_GESTURE) {
            return GestureJudgeResult.REJECT;
          }
          return GestureJudgeResult.CONTINUE;
        })
        .onRefreshing((): void => {
          this.onRefresh();
        })
        // Refresh 也别裁：内容要能从它顶边越出去（画到标题栏底下）。
        .clip(false)
      } else {
        // 下拉刷新：Refresh 包住 List（List 是它的可滚动子节点）。
        //
        // **不要给 Refresh 传 builder / refreshingContent**：试过（想把转圈从标题栏下面挪出来），
        // 结果是整个页面被顶成一块全屏空白、列表要下拉一次才出现，信息流的顶部避让也一起失效 ——
        // 自定义刷新内容会被当作"刷新区里常驻的一团"，它和 List 的布局是互相牵连的。
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0, scroller: this.listScroller }) {
            // **置顶的限时快拍托盘**（首页才放）：它在 List 内部，所以跟着信息流一起滚
            // （往上滚时和卡片一起穿到标题栏底下），位置天然是"标题栏下方、第一张卡片之前"。
            if (this.showStories) {
              ListItem() {
                StoriesTray({
                  // 首帧就用宿主那份数据（见 storySeed 的说明）：切回来不再空一块。
                  seed: this.storySeed,
                  seedAtMs: this.storySeedAtMs,
                  // 「你的快拍」那一项的头像（宿主从「我的」头部带过来，见 StoriesTray.selfAvatar）。
                  selfAvatar: this.selfAvatar,
                  // 宿主让托盘重新拉一次（见 StoriesTray.reloadSignal）。
                  reloadSignal: this.storyReload,
                  onSelfTap: (): void => {
                    this.onStorySelf();
                  },
                  onFollow: (item: StoryTrayItem): Promise<boolean> => {
                    return this.onStoryFollow(item);
                  },
                  onOpen: (item: StoryTrayItem, rect: StoryHeroRect): void => {
                    this.onStoryOpen(item, rect);
                  },
                  onLoaded: (items: Array<StoryTrayItem>): void => {
                    this.onStoryLoaded(items);
                  },
                  onRect: (userId: string, rect: StoryHeroRect): void => {
                    this.onStoryRect(userId, rect);
                  },
                  // 可见范围：首页据此预加载"屏幕里看得见的那几位"的 story。
                  onVisibleRange: (start: number, end: number): void => {
                    this.onStoryVisible(start, end);
                  }
                })
              }
              /*
               * 间距用 **padding 而不是 margin**（需求："序列的 margin 改为 padding，我想让它穿过
               * 屏幕左右"）：margin 会把整条 ListItem 往里收，托盘的圆环就贴不到屏幕两侧；
               * padding 只在**内部**留白，行本身仍是整屏宽，两端能穿出屏幕。
               */
              .padding({ bottom: TRAY_FEED_GAP_VP })
            }
            /*
             * **提示卡片**：画在 `hintAt` 那条帖子的上面（见 hintAt 的说明）。
             * 关注流有内容时它就夹在关注流末尾与探索流之间；关注流是空的（已看完）时
             * 它在列表最顶上，后面直接是探索流。
             */
            ForEach(this.posts, (post: MediaPost, index: number): void => {
              ListItem() {
                Column() {
                  if (index === this.hintAt) {
                    this.hintRow()
                  }
                  this.postCard(post, index)
                }
                .width('100%')
              }
            }, (post: MediaPost, index: number): string => {
              const base: string = post.shortcode.length > 0
                ? `sc:${post.shortcode}`
                : (post.id.length > 0 ? `id:${post.id}` : `ix:${index}`);
              // 键值只放「稳定身份 + 真需要重建卡片的**内容**状态」：
              //   **没有 playing** —— 切到/离开这条视频不再重建卡片：播放器是 VideoSurface，
              //   它的 playing/preload 是 @Prop，变化会自己传进去（和 reels 一样）。
              //   这一点很关键：如果靠键值重建，预加载好的下一条会在"轮到它播"的瞬间被销毁重建，
              //   预加载就白做了（prepare 出来的缓冲和首帧全丢）。
              // 点赞状态与各项计数**也不在键值里**：它们走 PostUi + @ObjectLink 就地更新。
              //
              // **视频地址有没有**要放进来：收藏 / 被标注那两段的查询只给封面，地址是打开帖子页
              // 之后按 id 后补的（见 pages/Index.loadPostPageVideos）—— 不放的话那一张卡片
              // 不会重建，播放器永远挂不上去（用户报的"只有封面"）。首页信息流一直带地址，
              // 所以这一位在那边是恒定的，不会多重建。
              //
              // **图有几张 / 有没有发布时间 / 有没有头像**同理（同一发 media info 一起补的，
              // 见 FeedMapper.withDetails）：那两段的载荷里只有一张图、没有 taken_at、user 里
              // 也没有头像，而这些卡片是进页那一刻按当时的数据建的 —— 不把这三位放进键值，
              // 补回来的轮播 / 时间 / 头像就不会出现（用户报的正是"多图片无法显示、
              // 发布时间没有显示、作者头像加载不出来"）。单图帖的 imageUrls 长度恒为 1、
              // 首页那两样（时间 / 头像）恒为"有"，所以这几位在别的页面都不会乱变。
              return `${base}|v${post.isVideo() && post.videoUrl.length > 0 ? 1 : 0}`
                + `|n${post.imageUrls.length}`
                + `|t${post.takenAtMs > 0 ? 1 : 0}`
                + `|a${post.ownerAvatarUrl.length > 0 ? 1 : 0}`
                // **这一条身上挂着提示卡片吗**：卡片是按 `hintAt` 画在某一帖上面的，而 ForEach
                // 对键值没变的项**不会重跑** item builder —— 不放这一位，关注流变长/刷新之后
                // 卡片就会停在旧位置（或者干脆不出现）。
                + `|h${index === this.hintAt ? 1 : 0}`;
            })
            if (this.loadingMore) {
              // 触底加载：列表末尾放一个圆环，跟着内容滚，不占正文位置、也不用文字。
              ListItem() {
                Row() {
                  LoadingProgress()
                    .width(30)
                    .height(30)
                    // 白色：用主题前景色（深色模式下是 #F1F1F1，看起来就是白的）。
                    // 没有写死 Color.White —— 浅色模式背景也是白底，写死会直接看不见。
                    .color($r('app.color.primary_text'))
                }
                .width('100%')
                .height(56)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 位置还原：切 tab 回来时把列表滚回离开时那一条（见 restoreAnchor）。
          .onAppear((): void => {
            this.restoreAnchor();
          })
          // 屏幕外多构建几张卡片：卡片一建起来，它的 Image 就会去取图（多半已经命中预下载的缓存），
          // 而不是等到滑进可视区才开始。
          .cachedCount(3)
          // 量出可视区范围：判断帖子有没有「完全显示在屏幕」要用（见 viewportSpan）。
          .id(LIST_ID)
          // **别裁内容**：列表可视区在顶部那层透明 Stack 下面，关掉裁剪后滚动的卡片才会画到
          // 标题栏底下去（需求："帖子可以穿过 hdsnavigation"）。
          .clip(false)
          // 只内缩末尾：底部悬浮 tab 栏是浮在内容上的，不内缩最后一条会被压住。
          .contentEndOffset(FEED_END_OFFSET)
          // 手指按在材质按钮上时（关注/更多/下载/静音/沉浸式标题容器）要不要**咬住**列表：
          // 按住了再划 → 不许列表滚，那段滑动只该让按钮做材质形变（需求："长按滑动按钮时不会
          // 影响页面"）；按下去就划 → 放行，列表照常滚（需求："滑动不要被按钮的 4-way-lock
          // 卡手"）。两句话的判据都在 holdsScroll 里（间隔 + 方向，见 MaterialSurface）。
          //
          // 判据读的是 MaterialPressState / MaterialPressState.downMs 这些**同步静态字段**
          // （不是 @StorageProp）：手势判定发生在按下的头几个 move 事件里，走状态通知+重绘那条路
          // 根本来不及 —— 官方 Web 嵌套滚动那篇给的写法就是在这个回调里否掉内建 PAN。
          .onTouch(trackScrollTouch)
          .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer,
                                          others: Array<GestureRecognizer>): GestureJudgeResult => {
            if (holdsScroll(event) && current.isBuiltIn()
              && current.getType() === GestureControl.GestureType.PAN_GESTURE) {
              return GestureJudgeResult.REJECT;
            }
            return GestureJudgeResult.CONTINUE;
          })
          // 把每帧的滚动增量报给页面，用它驱动底部栏的下沉/还原（或系统显隐）。
          .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
            this.reportScrollDelta(scrollState);
          })
          .onScrollIndex((start: number, end: number, center: number): void => {
            // 主判据：可见区间决定哪条视频在屏幕上、以及该播哪条（见 syncFromRange）。
            this.syncFromRange(start, end);
            // 把"可见区第一条"上报给页面（切 tab 回来时靠它还原位置，见 initialKey）。
            this.reportAnchor(start);
            // 顺手把"接下来几张"的封面预下载掉（见 MediaPrefetch）：滑过去时图已经在缓存里。
            this.prefetchAhead(end);
            // 离末尾还有几条就开始预取，等用户真滚到底时通常已经接上了。
            if (end >= this.posts.length - PREFETCH_DISTANCE) {
              this.askMore();
            }
          })
          .onReachEnd((): void => {
            // 列表短于一屏时根本不会滚动，onScrollIndex 不一定触发，这里兜一次。
            this.askMore();
          })
          /*
           * **滑停后权威重算一次焦点**（见 refreshFocus）。
           *
           * 滚动中的重算是节流 + 位移闸门的（可能比手指晚一拍），而"停下来那一刻"的位置
           * 才是用户要看的 —— 这里无条件重算，保证最终状态不依赖上次采样的时机。
           */
          .onScrollStop((): void => {
            this.refreshFocus();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing((): void => {
          this.onRefresh();
        })
        // 下拉刷新这条内建 PAN 同理（见上面空态那支的说明）。
        .onTouch(trackScrollTouch)
        .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer,
                                        others: Array<GestureRecognizer>): GestureJudgeResult => {
          if (holdsScroll(event) && current.isBuiltIn()
            && current.getType() === GestureControl.GestureType.PAN_GESTURE) {
            return GestureJudgeResult.REJECT;
          }
          return GestureJudgeResult.CONTINUE;
        })
        // Refresh 也别裁：内容要能从它顶边越出去（画到标题栏底下）。
        .clip(false)
      }
    }
    .width('100%')
    .height('100%')
  }
}
