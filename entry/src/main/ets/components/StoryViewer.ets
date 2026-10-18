/*
 * 限时快拍**播放页**（点主页托盘里的头像进来）。
 *
 * 需求里的转场："点击头像时加载添加圆圈转圈动画，加载成功跳进新页面，从头像位置放大页面
 * 占满全屏，头像则从原位置位移到左上角。"
 *
 * 这一页就是那个"新页面"，转场**自己做**（没用 geometryTransition）：
 *   ① 页面层（黑底那一块）第一帧画在**被点头像的矩形**里（矩形由托盘量好传进来，见
 *      model/Story.StoryHeroRect），`animateTo` 把 x/y/宽/高推到全屏；
 *   ② 头像单独一层，第一帧和被点头像**完全重合**，同一时间飞到左上角（缩小 + 位移）。
 * 两个一起动，观感就是"页面从头像里长出来、头像自己飞到左上角"。为什么不用
 * geometryTransition：那套要"源节点消失 / 目标节点出现"配对，而这一层是浮在首页之上的
 * 浮层，托盘的源节点并没有消失，配对不可靠（也不好在真机上排查）；自己算矩形是确定的。
 *
 * 播放：
 *   · 图片 —— 按 `durationMs`（默认 5 秒）走进度条；
 *   · 视频 —— `Video` 组件**自动播放**，进度条由同一个时钟推（时长老老实实取
 *     `video_duration`），`onFinish` 直接进下一条。
 * 手势：**左半屏 = 上一条，右半屏 = 下一条**；最后一条的右半屏 → 交给宿主接**下一位用户**
 * （见 onNextUser）；第一条的左半屏 → 交回宿主回上一位（见 onPrevUser）；长按暂停；
 * **下滑收起**。
 *
 * 版面（需求）：媒体区**顶到最上面**，进度条 + 用户资讯（头像 / 用户名）**浮在媒体区顶部**，
 * 底部留一条黑边放评论式输入框（`CommentInputBar`，这一版只做样式，见 onSend）。
 * 右上角那颗 ✕ 已经删掉（需求），收起靠下滑 / 系统返回键。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { curves, display } from '@kit.ArkUI';
import { CommentInputBar } from './CommentInputBar';
import { MaterialIconButton, MaterialLabelButton, SurfaceModifier } from './MaterialSurface';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import {
  EMPTY_REEL,
  STORY_CARD_ID,
  STORY_FLYING_AVATAR_ID,
  STORY_MEDIA_ID,
  STORY_ROOT_ID,
  storyAvatarNodeId,
  StoryItem,
  StoryReel
} from '../model/Story';

const DOMAIN: number = 0xFF00;
const TAG: string = 'StoryViewer';
/** 放大/收回的时长（毫秒）。 */
const HERO_MS: number = 300;
/** 内容（进度条/用户名/图）淡入的时长（毫秒）—— 先让它长满屏，再显内容。 */
const CONTENT_MS: number = 140;
/** 进度条更新间隔（毫秒）。 */
const TICK_MS: number = 80;
/** 进度条粗细 / 段间距（vp）。 */
const SEG_H: number = 2.5;
const SEG_GAP: number = 3;

// ---------------------------------------------------------------- 悬浮卡片的版面
/*
 * 这一页现在的形态（需求）：**悬浮式卡片** —— 屏幕中间一张竖版卡片，
 *   ① 主体是**圆角媒体区**（卡片本身没有别的底，媒体就是卡片的底）；
 *   ② 媒体区顶部 5vp 处一条进度条；
 *   ③ 进度条下面一行"用户资讯栏"（沉浸光感胶囊：头像 + 用户名）靠左，「更多」按钮靠右；
 *   ④ 媒体区**外面**、卡片内部的下方是功能区：输入框（"发消息"）+ 点赞 / 评论 / 转发；
 *   ⑤ 媒体区与功能区**同宽**（都等于卡片宽）。
 * 卡片四周留出空白（点空白处收起），底下透出首页 = "悬浮"。
 */
/** 卡片两侧离屏幕边缘（vp）。 */
const CARD_SIDE_VP: number = 16;
/** 卡片圆角（vp）。 */
const CARD_RADIUS_VP: number = 18;
/**
 * 媒体区高宽比（w/h）：**9:16 竖版**，也就是"宽 / 高"。
 *
 * ⚠️ 这里原来是 `16 / 9`（横版）—— 和它自己的注释（"竖版 story"）正好相反，
 * 于是**打开动画的那一段**（reel 还没到、`currentItem()` 拿不到宽高，见 mediaAspect 的兜底分支）
 * 卡片先按横版画：`mediaH = cardW / 1.78` ≈ 188vp 的一个"矮宽块"；
 * 数据一到，真实宽高是竖版 720×1280 → `mediaH` 变成 594vp —— 用户看到的就是
 * "点开先显示 16:9，然后变成 9:16"（需求：**打开动画就该是 9:16**）。
 *
 * 竖版 story 占绝大多数，所以兜底用它：真数据到了（也是 9:16）**尺寸一模一样，不会跳**；
 * 少数本来就是横版/方形的 story，仍旧按各自的真实比例画（见 mediaAspect）。
 */
const MEDIA_RATIO: number = 9 / 16;
/** 进度条离媒体区顶（vp）—— 需求："和媒体顶部保持 5vp 距离"。 */
const PROGRESS_TOP_VP: number = 5;
/** 进度条左右内缩（vp）。 */
const PROGRESS_SIDE_VP: number = 10;
/** 进度条 → 用户资讯栏的间隔（vp）。 */
const INFO_GAP_VP: number = 8;
/** 用户资讯栏离媒体区左右边（vp）。 */
const INFO_SIDE_VP: number = 8;
/** 资讯栏里那颗头像的直径（vp）—— 和 feeds 资料行那颗一致。 */
const INFO_AVATAR_VP: number = 34;
/** 资讯栏胶囊的高度（vp，和 feeds 的材质容器 40 对齐）。 */
const INFO_PILL_H: number = 40;
/**
 * 资讯旁那颗「关注」的宽高（vp）。
 *
 * 需求："快拍内容的关注按钮放大，高度要和用户资讯一样" —— 高度直接取 `INFO_PILL_H`（40），
 * 和左边那颗"头像 + 用户名"的胶囊齐平；宽度也给足，字才不至于挤。
 */
const STORY_FOLLOW_W_VP: number = 76;
const STORY_FOLLOW_H_VP: number = INFO_PILL_H;
/** 功能区的统一间隔（vp）：输入框与三颗按钮之间都是这个数。 */
const ACTION_GAP_VP: number = 10;
/** 媒体区 → 功能区（vp）。 */
const ACTION_TOP_VP: number = 12;
/** 功能区高度（vp，= 输入胶囊高度）。 */
const ACTION_H: number = 44;
/** 量不到被点头像时用的兜底起始矩形（一个头像大小，靠左上）。 */
const FALLBACK_W: number = 62;
/**
 * 收起时那张黑卡最后缩到"头像的百分之多少"。
 *
 * **不能收到 100%**：黑卡和飞行头像一样大时，卡片边缘会露在头像外面一圈（就是"外层黑边"），
 * 而浮层撤掉的那一瞬间这圈黑边消失 —— 看起来就是头像"瞬间归位"（用户报的）。
 * 收到 70% 就完全藏进头像后面了：最后一眼看到的是头像本身，没有黑边。
 */
const CARD_END_SCALE: number = 0.7;
/**
 * 托盘那头像的**描边宽度**（vp），要和 `StoriesTray` 里 `Image.border({width: 2})` 对得上。
 *
 * 为什么要在这里再写一遍：那个边框是画在 80vp 的盒子**里面**的，所以托盘上真正看得见的
 * 照片只有 76vp；而飞行头像是一张没有描边的图，按 80vp 落下去就比托盘照片**大一圈**，
 * 浮层撤掉那一刻就看得出"多了一圈边"（用户报的"回弹最后的头像比序列头像大一圈黑边"）。
 * 所以飞行头像的大小与位置都要按这个内缩量收进去，落点才和托盘照片严丝合缝。
 */
const AVATAR_PHOTO_INSET: number = 2;
/** 下滑收起：拉过这么多 vp 就收（或者甩得够快，见 DRAG_FLING_VP）。 */
const DRAG_CLOSE_VP: number = 110;
/** 下滑收起：离手速度超过这么多 vp/s 也算"甩下去"（不用拉满距离）。 */
const DRAG_FLING_VP: number = 900;
/** 下滑过程中整层淡到最暗不低于这个值（不能全透明，不然看着像闪一下）。 */
const DRAG_MIN_ALPHA: number = 0.35;
/** 收起时黑卡"最后这一段"用来淡出的时长（毫秒），见 StoryViewer.collapseAndClose。 */
const FADE_MS: number = 130;
/**
 * 收起开始时过多久把内容摘掉（毫秒）。
 *
 * 前面这 160ms 还看得见 story 画面在缩（缩进那块圆形蒙版里），之后这层里只剩黑圆，
 * 后面半程的重排与合成代价几乎为零。
 */
const CONTENT_KEEP_MS: number = 160;
/**
 * 头像"弹性收缩回序列"的时长（毫秒）。
 *
 * 比页面那 300ms 长一点：页面先缩成圆形蒙版落到序列位置，头像**后到**、还带一点回弹
 * （springMotion 的 dampingFraction < 1，见 collapseAndClose），所以观感是"弹进去"而不是
 * 和页面一起硬邦邦地落定。浮层也是等它落定才撤（onClose 挂在这一条上）。
 */
const AVATAR_CLOSE_MS: number = 420;
/** 开始展开动画前先等一帧（量坐标系偏移用，见 build 的 onAppear）。 */
const MEASURE_DELAY_MS: number = 16;
// ---------------------------------------------------------------- 换用户时的翻卡片
/** "翻出去"的时长（毫秒）；也是**最短**可见时长（命中缓存时也要看满它，见 flipIn）。 */
const FLIP_OUT_MS: number = 210;
/** "翻回来"的时长（毫秒，springMotion）。 */
const FLIP_IN_MS: number = 360;
/**
 * 翻到最陡的角度（度）。
 *
 * 不用 90：那样卡片会完全侧对屏幕看不见 —— 命中不了缓存时要等网络（半秒上下），
 * 中间那段就是全黑。45 是"看得出在翻面、但不夸张"的量（用户反馈 75 太猛）。
 */
const FLIP_MAX_ANGLE: number = 45;
/** 左右滑切换用户的最小位移（vp）。 */
const SWIPE_SWITCH_VP: number = 60;
// ---------------------------------------------------------------- 头像不在屏幕时的收起
/**
 * "头像不在屏幕上"时的收起：**先向上收缩、再快速下沉**（需求）。
 *
 * ① 收缩段：原地缩到 `SLIDE_OUT_SCALE` 的同时**往上抬** `LIFT_VP`（"先向上收缩"）；
 * ② 下沉段：抬起来之后**快速**沉下去滑出屏幕（时长短、曲线陡）。
 * 两段各用一条 springMotion（非线性 + 轻微过冲），所以收缩是"弹一下定住"、下沉是"甩下去"。
 */
const SHRINK_MS: number = 190;
const SINK_MS: number = 190;
/** 收缩时往上抬多少（vp，正数 = 往上）。 */
const LIFT_VP: number = 38;
/** 收缩到多少（1 = 不缩）。 */
const SLIDE_OUT_SCALE: number = 0.55;
/**
 * 底部 tab 栏的高度（vp）—— 和 pages/Index 的 `BAR_HEIGHT` 对齐。
 *
 * "口袋"就是这条栏：卡片沉到**栏顶边**以下就被裁掉（掉进袋口），所以浮层里要按它算一个裁切线。
 * 栏在卡片经过时只是**弹一下**（不改大小），所以这个高度是恒定的。
 */
const BAR_H: number = 60;
/** 栏弹一下时的"轻微缩放"与"下压"（vp）—— 和 pages/Index 的 `BAR_POCKET_GROW_H` / `_DIP` 对齐。 */
const BAR_POCKET_GROW: number = 4;
const BAR_POCKET_DIP: number = 7;
/** 沉到口袋底部需要走多远（vp）：卡片整个滑到栏顶边以下还多一截，保证看不到它。 */
const POCKET_EXTRA_VP: number = 40;
/** 掉进口袋时再缩到多少（比收缩段更小，看着像被口袋吞掉）。 */
const POCKET_SINK_SCALE: number = 0.42;
/** "卡片已穿过袋口"的提前量（1 = 正好在那一刻让栏回位；小一点 = 再早一点恢复）。 */
const POCKET_PASS_TRIM: number = 0.9;
/** 动作区"融入"时往上走多少（vp）—— 一边上移一边淡出缩小，像一滴水融进卡片。 */
const ACTION_MELT_VP: number = 26;
/** 资讯栏 + 更多按钮"缓慢隐藏"的时长（毫秒，跨过两段动画）。 */
const INFO_FADE_MS: number = 380;

@Component
export struct StoryViewer {
  /**
   * 要播的这一份。
   *
   * @Prop + @Watch：换下一位用户时宿主会塞一份**新的** StoryReel 进来，这里收到就
   * 从第一条重新开始（见 onReelChanged）。
   */
  @Prop @Watch('onReelChanged') reel: StoryReel = EMPTY_REEL;
  /** 用户名（托盘里那份：reel 里没有就用它）。 */
  @Prop username: string = '';
  /** 头像（同上；转场飞的就是这张图）。 */
  @Prop avatarUrl: string = '';
  /** 后面还有没有下一位用户（最后一条的右半屏据此决定"接续"还是"收页"）。 */
  @Prop hasNextUser: boolean = false;
  /** 前面还有没有上一位用户（第一条的左半屏据此决定"回上一位"还是"重播这一条"）。 */
  @Prop hasPrevUser: boolean = false;
  /**
   * 现在播的这位，头像**是否还在主页那条托盘上**（也就是"能不能飞回它那儿"）。
   *
   * 宿主算好传进来：只有"用户点开的那一位"才算 —— 顺着右半屏接下去之后，或者从托盘点开
   * 的顺序变了，当前这位的头像就不在主页那份位置上了（需求："如果 story 页用户头像不在主页
   * 显示就向下收起 story 页就可以，不用位移到主页头像上"）。
   */
  @Prop heroValid: boolean = false;
  /**
   * 被点头像在屏幕上的**当前**位置与大小（vp，见 StoryHeroRect）。
   *
   * @Prop：不是只在开头用一次 —— 顺着右半屏接了下一位之后宿主会把它换成**当前这一位**在托盘里
   * 的矩形，收起时页面就朝那个头像收缩、头像横移过去落上（需求）；那位不在托盘里（滚走了 /
   * 找不到）时宿主把 heroValid 置假，收起改成向下滑。
   */
  @Prop heroX: number = 0;
  @Prop heroY: number = 0;
  @Prop heroW: number = 0;
  @Prop heroH: number = 0;
  /** 现在播的这位的 userId（宿主传进来，只为"按 id 量那颗头像到底在哪"，见 logRects）。 */
  @Prop heroUserId: string = '';
  /** 收起（自己播完 / 点关闭 / 收完动画后由这一页自己叫）。 */
  onClose: () => void = (): void => {
  };
  /**
   * 系统返回键的"请收起"信号（宿主每按一次返回就 +1）。
   *
   * 为什么不直接让宿主把浮层删掉：**返回键也要播完收起动画**（朝头像收缩 / 整页向下滑走，
   * 见 requestClose）。所以返回键只发一个信号过来，动画结束再由本页叫 onClose 把浮层删掉
   * —— 和下滑手势、播完自动收走的是同一条路。
   */
  @Prop @Watch('closeSignalChanged') closeSignal: number = 0;
  /**
   * 宿主请求**掉头展开**（每请求一次 +1）。
   *
   * 两处会用到：收起途中点了空白（= 撤销收起）、以及收起途中点到了**别的用户**的头像
   * （需求："收起 stories 时点击用户头像必须切换到该用户的 story"）—— 后者宿主会先把这一位的
   * 状态（名字 / 头像 / 矩形 / reel）换好，再发这个信号，于是观感是"卡片掉头弹回、并且换人了"。
   */
  @Prop @Watch('reopenSignalChanged') reopenSignal: number = 0;
  /**
   * 收起途中点了一下（窗口坐标 vp）→ 交宿主判断。
   *
   * 宿主看这个点上有没有托盘里某位用户的头像：有 → 换到那一位的 story；没有 → 撤销收起。
   */
  onTapPoint: (x: number, y: number) => void = (x: number, y: number): void => {
  };
  /** 最后一条又点了右半屏 → 请宿主接**下一位用户**（见 Index.advanceStory）。 */
  onNextUser: () => void = (): void => {
  };
  /** 第一条又点了左半屏 → 请宿主回**上一位用户**（见 Index.backStory）。 */
  onPrevUser: () => void = (): void => {
  };
  /**
   * 收起动画被**打断**了（点头像/卡片又展开了）→ 通知宿主把"正在收起"的记账清掉。
   *
   * 不通知的话宿主那边 `storyClosing` 会一直立着，**之后返回手势就再也发不出收起信号了**
   * —— 用户报的"连续打断会导致返回手势失效"就是这个。
   */
  onReopen: () => void = (): void => {
  };
  /** 底部输入框点发送（这一版只做样式，宿主弹一句"还没接上"，见 Index.storySend）。 */
  onSend: (text: string) => void = (text: string): void => {
  };
  /**
   * 右下角那三颗互动按钮（点赞 / 评论 / 转发给朋友）。
   *
   * 这一版**只做样式**（和输入框一样先不接功能），点一下交给宿主记一行日志 + 弹一句提示。
   *
   * @param kind `'like'` / `'comment'` / `'share'`（日志与后续接功能时按它分派）。
   */
  onAction: (kind: string) => void = (kind: string): void => {
  };

  /**
   * 这一层是不是在放**精选快拍（高光）**：是的话**不画底部动作区**（输入框 + 点赞/评论/转发）。
   *
   * 需求："highlight… 按照快拍的动画逻辑和卡片样式，不需要动作区"。
   */
  @Prop hideActions: boolean = false;
  /** 资讯栏里跟在标题后面的小字（高光用发布日期；普通快拍为空）。 */
  @Prop dateText: string = '';

  /**
   * **正在看的这一位关注了没有**（宿主算好传进来）。
   *
   * 需求："查阅快拍内容但未关注该用户就在用户资讯旁显示一个关注按钮"。
   * 所以为假才画按钮；自己看自己的快拍、已经关注过的人都不画。
   * 数据源可能是"托盘条目的 friendship_status"，也可能是本地覆盖表（见 core/FollowState）；
   * 完全不知道时宿主按"没关注"传 false —— 宁可我多一颗按钮，也不能让用户对着关注过的
   * 人看不见"已关注"的分寸感。
   */
  @Prop following: boolean = true;
  /**
   * 点资讯旁那颗「关注」：宿主去关注（HTTP 优先、网页兜底），成功回 true。
   *
   * 回真之后宿主把 `following` 改成 true，按钮自己就消失了（见 Index.onFollowStoryAuthor）。
   * 失败则原样留着，用户还能再点一次。
   */
  onFollowAuthor: () => Promise<boolean> = (): Promise<boolean> => Promise.resolve(false);

  /** false = 停在头像矩形里（第一帧）；true = 全屏。 */
  @State private open: boolean = false;
  /** 内容淡入（免得小矩形里先挤一坨字）。 */
  @State private contentAlpha: number = 0;
  /**
   * 内容（媒体 / 进度条 / 输入条）挂没挂上树。
   *
   * **动画期间不挂**：展开时等黑色圆长满全屏了才挂（见 expand 的 onFinish），收起时 100ms 后
   * 就摘掉（见 collapseAndClose）。这一条是"又准又顺"的关键 —— 几何改的是布局属性
   * （width/height/position，落点精确），而动画期这一层里只有黑底，重排几乎不花时间。
   */
  @State private contentMounted: boolean = false;
  /**
   * 头像那一层停稳了没有（和页面层**分开记账**）。
   *
   * 为什么要分开：收起时两者要走**不同的曲线** —— 页面是"缩成圆形蒙版"（Friction，300ms），
   * 头像是"**弹性**收缩回序列"（springMotion，420ms，带一点回弹）。一个 animateTo 只能给一条
   * 曲线，所以拆成两个状态、两次 animateTo（见 collapseAndClose）。
   */
  @State private avatarOpen: boolean = false;
  /** 当前第几条。 */
  @State private index: number = 0;
  /** 当前这条已经播了多少毫秒（进度条读它）。 */
  @State private elapsed: number = 0;
  /** 长按暂停。 */
  @State private paused: boolean = false;
  /** 正在下滑（手指按着往下拉）：整层跟着手指走，松手要么回弹要么收起。 */
  @State private dragY: number = 0;
  /** 拖动期间不要推进度（手指按着的时候不该往下走）。 */
  private dragPaused: boolean = false;
  /** 换下一位用户时的取数等待（进度条停在满格，别再往下走）。 */
  @State private waiting: boolean = false;
  /**
   * 页面层（那张黑卡）的透明度。
   *
   * 收起时**和缩放错开**：黑卡先缩到头像位置，最后 130ms 再淡掉（见 collapseAndClose）——
   * 不淡的话动画最后一帧是一块**盖住头像的黑方块**，浮层一撤才露出真头像，
   * 看着就是"一大圈黑边 + 头像归位时跳一下"（用户报的正在修的就是这个）。
   */
  @State private pageAlpha: number = 1;
  /** 遮罩（卡片四周那一圈空白）的透明度：和卡片一起淡入淡出，点它收起。 */
  @State private scrimAlpha: number = 0;
  /** 用户资讯栏的材质厚度（跟设定页联动，和全 app 那些材质组件同一份全局设定）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /** 屏幕尺寸（vp）：全屏矩形与进度条分段宽度都按它算。 */
  @State private screenW: number = 360;
  @State private screenH: number = 780;
  /**
   * 交替的布尔值：每换一条就翻一次，于是媒体那两个分支**整体重建**。
   *
   * 为什么需要：连着两条都是视频时，`Video` 节点会被复用、只换 `src`，`autoPlay` 不一定
   * 重新起播（实机上表现就是"第二条不播"）。翻一下这个值让分支换边，节点就一定是新的。
   */
  @State private seqEven: boolean = true;
  /** 正在关注（防连点：一颗按钮点两下会发两次 friendship/create）。 */
  @State private followBusy: boolean = false;

  /**
   * 点资讯旁那颗「关注」（需求："查阅快拍内容但未关注该用户就在用户资讯旁显示一个关注按钮"）。
   *
   * 按钮的显隐**只听宿主**（`following` 是 @Prop）：这里只负责把动作交出去，
   * 成功了宿主把 following 改成 true，这颗按钮就自己消失了（不在这里乐观改状态 ——
   * 关注失败要能留在原地让用户重试）。
   */
  private async tapFollow(): Promise<void> {
    if (this.followBusy) {
      return;
    }
    this.followBusy = true;
    hilog.info(DOMAIN, TAG, 'story follow tap user=%{public}s', this.username);
    try {
      const ok: boolean = await this.onFollowAuthor();
      hilog.info(DOMAIN, TAG, 'story follow result user=%{public}s ok=%{public}s',
        this.username, `${ok}`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'story follow threw: %{public}s', (error as Error).message);
    } finally {
      this.followBusy = false;
    }
  }

  private timerId: number = -1;
  /** 当前这条的起播时刻（毫秒时间戳）。 */
  private startedAt: number = 0;
  /**
   * 浮层坐标 → 窗口坐标的偏移（vp）。
   *
   * 托盘量到的是**窗口坐标**，浮层里 `.position()` 用的是**浮层坐标**（原点在状态栏下面），
   * 差了这一个偏移。实机量出来 x≈0、y≈39（状态栏高度），不换算掉的话"头像落回序列"就低 39vp。
   * 值在 `measureSpace()` 里量（见那里的说明），不写死。
   */
  /*
   * **必须是 `@State`**（审计 B5，和下面 overlayW 是同一类坑）：它们被 `startX()/startY()` 读去
   * 算"头像飞回去"的落点，而 `measureSpace()` 写入它们 —— 普通字段的话那次写入不触发重绘，
   * 首帧算出来的落点会带着默认偏移（0）去用，等于**偏移没生效**。
   */
  @State private spaceOffsetX: number = 0;
  @State private spaceOffsetY: number = 0;
  /**
   * 浮层自己的尺寸（vp，`measureSpace` 里量）。
   *
   * 卡片的宽高/位置全按它算 —— 注意**不能用 display 的屏幕尺寸**：浮层的布局原点在状态栏
   * 下面（就是上面那个 spaceOffsetY），用屏幕高度算出来的卡片会偏下、还会被底部避让区顶住。
   *
   * **必须是 @State**：它一变，卡片和媒体区的 `mediaH()` 要**同一帧一起**跟着变。原来写成普通
   * 字段，`measureSpace` 更新之后只有部分节点重算 —— 实机量出来"卡片 593、媒体区 583"，
   * 差的那 10vp 就是卡片底部那条黑边（用户报的）。
   */
  @State private overlayW: number = 360;
  @State private overlayH: number = 780;
  /** 已经在收起了（防重复触发，见 requestClose）。 */
  private closing: boolean = false;
  /**
   * 动画**代次**：每开始一段动画就 +1，动画回调里比对。
   *
   * 为什么需要：`animateTo` 的 `onFinish` 不会被后来的动画取消 —— 收起途中被点击掉头重新展开
   * 时（见 reopen），上一条收起的 onFinish 还会来，不比对就会把浮层删掉（表现是"展开到一半
   * 页面忽然没了"）。代次对不上就直接 return。
   */
  private gen: number = 0;
  /** 收起时那个"过一会儿把内容摘掉"的定时器（掉头重新展开要能取消它）。 */
  private unmountTimer: number = -1;
  /** "卡片穿过袋口"那一记定时器（提前让 tab 栏回位，见 pocketPassMs）。 */
  private pocketExitTimer: number = -1;
  /**
   * **翻卡片**的角度（度，绕竖直轴）。
   *
   * 换用户时卡片**留在原地左旋/右旋翻面**（需求），不做位移也不做缩放；
   * 翻到最陡时把内容换成新用户，再翻回来 —— 就是"换了一张卡"的观感。
   * 它是叠在**几何**上的额外变换：静止时是 0，所以完全不影响卡片/头像的落点。
   */
  @State private flipAngle: number = 0;
  /** 这一次翻的方向（+1 = 接下一位，-1 = 回上一位），翻回来时用它的反方向。 */
  private flipDir: number = 1;
  /** 正在翻卡片（翻出去的动画已经起了，等新数据回来翻回来）。 */
  private switching: boolean = false;
  /**
   * "下沉滑出"时的收缩比例（1 = 原大小）。
   *
   * 只有"头像不在屏幕上"那一路收起会改它（见 slideDownAndClose）；其它时候恒为 1，
   * 所以对卡片/头像的落点几何没有任何影响。
   */
  @State private exitScale: number = 1;
  /**
   * 卡片裁剪区的高度（vp）：卡片沉进"口袋"（底部 tab 栏）时，用它在**栏顶边**把卡片切掉。
   *
   * 平时 = 浮层高度（等于不裁）；只有掉进口袋那一路会缩到 `overlayH - BAR_H`。
   */
  @State private clipH: number = 0;
  /** 动作区"融入"的进度（0 = 原样，1 = 已经上移+淡出+缩小到看不见）。 */
  @State private actionsMelt: number = 0;
  /** 用户资讯栏 / 更多按钮的透明度（收起时缓慢降到 0，需求："缓慢隐藏"）。 */
  @State private infoAlpha: number = 1;
  /** 掉进口袋的两个回调：进袋口时让 tab 栏鼓一下，穿完再让它弹性回原状（见 Index）。 */
  onPocketEnter: () => void = (): void => {
  };
  onPocketExit: () => void = (): void => {
  };
  /** 这一次"翻出去"是什么时候开始的（保证翻出去那一下看得见，见 onReelChanged）。 */
  private flipAt: number = 0;
  /** 新数据提前到了的话，用它把"翻回来"推迟到翻出去播完之后。 */
  private flipInTimer: number = -1;
  /** 视频控制器（长按暂停 / 恢复要用）。 */
  private videoController: VideoController = new VideoController();

  aboutToAppear(): void {
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      this.screenW = px2vp(screen.width);
      this.screenH = px2vp(screen.height);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'screen size failed: %{public}s', (error as Error).message ?? '-');
    }
    this.restartItem();
    /*
     * **预构建**的那一步挪到 `onAppear` 的定时器里（量完浮层尺寸之后，见那里的 setTimeout）：
     * 这里先不挂内容 —— 挂早了会用"默认浮层尺寸"排版，等 measureSpace 更新尺寸时卡片和媒体区
     * 差出一截（底部黑边就是这么来的，见 overlayW 的说明）。数据在手时仍然**在展开动画之前**
     * 就挂好，所以"点开时已经构建好"这件事不受影响。
     */
    this.timerId = setInterval((): void => {
      this.tick();
    }, TICK_MS);
    hilog.info(DOMAIN, TAG, 'open uid=%{public}s n=%{public}d hero=%{public}s,%{public}s %{public}dx%{public}s',
      this.reel.userId, this.reel.items.length, `${Math.round(this.heroX)}`, `${Math.round(this.heroY)}`,
      `${Math.round(this.heroW)}`, `${Math.round(this.heroH)}`);
  }

  aboutToDisappear(): void {
    /*
     * **销毁时把"还在飞的东西"全部作废**（审计发现：原来只 `stopTimer()`）。
     *
     * 留下没清的有：`unmountTimer`（收起动画后卸载内容的兜底）、`flipInTimer`（切用户的翻面）、
     * `pocketExitTimer`（口袋动画回弹）、以及两处裸 `setTimeout`。它们在组件销毁后仍会回调 ——
     * 写 `@State`、甚至调 `onClose()`（宿主那边页面已经走了）。`gen+1` 让所有动画的 `onFinish`
     * 代次比对失败、自己作废（这是本文件既有的防竞态机制，见 gen 的说明）。
     */
    this.stopTimer();
    this.gen = this.gen + 1;
    if (this.unmountTimer >= 0) {
      clearTimeout(this.unmountTimer);
      this.unmountTimer = -1;
    }
    if (this.flipInTimer >= 0) {
      clearTimeout(this.flipInTimer);
      this.flipInTimer = -1;
    }
    if (this.pocketExitTimer >= 0) {
      clearTimeout(this.pocketExitTimer);
      this.pocketExitTimer = -1;
    }
  }

  /** 下一位用户的 reel 到了：回第一条重新播（见 reel 的 @Watch）。 */
  private onReelChanged(): void {
    hilog.info(DOMAIN, TAG, 'next user uid=%{public}s n=%{public}d',
      this.reel.userId, this.reel.items.length);
    this.waiting = false;
    this.paused = false;
    this.index = 0;
    this.restartItem();
    // 数据到了就立刻把内容建好（预构建，见 aboutToAppear 的说明）：不用等展开动画结束。
    this.contentMounted = true;
    /*
     * 数据是"卡片已经开着"的时候才到的（宿主先弹卡片后取数）：
     * 这时媒体节点是新建的，`autoPlay(this.open && this.contentMounted)` 已经能起播，
     * 这里再补一记 start()，免得 Video 的 autoPlay 属性变更在某些版本上不触发播放。
     */
    if (this.open && this.contentMounted && this.currentIsVideo()) {
      this.videoController.start();
    }
    // 正在翻卡片：新数据到了就弹回来（见 beginUserSwitch）。
    this.flipIn();
  }

  // ---------------------------------------------------------------- 换用户时的翻卡片

  /**
   * 换用户：卡片**原地翻出去**（绕竖直轴转到最陡的角度）。
   *
   * @param dir -1 = 回上一位（往右翻），+1 = 接下一位（往左翻）。
   */
  private beginUserSwitch(dir: number): void {
    if (this.switching) {
      return;
    }
    this.switching = true;
    this.flipDir = dir;
    this.flipAt = Date.now();
    // 角度取**反方向**：接下一位是往左翻、回上一位往右翻（用户反馈原来的方向是反的）。
    // 从**当前角度**接着转（跟手拖到一半松手时就是从这里继续），不是从 0 重来。
    animateTo({ duration: FLIP_OUT_MS, curve: Curve.Friction }, (): void => {
      this.applyFlip(-dir * FLIP_MAX_ANGLE);
    });
  }

  /**
   * 新用户的 reel 到了 → 卡片**从另一面翻回来**（弹性），内容就是在最陡那一刻换掉的。
   *
   * "翻出去"那一下至少要看满 FLIP_OUT_MS：命中缓存时新数据几乎立刻就到，不等一下的话
   * 翻卡片会被压成一帧、看不出来（需求要的就是这个效果）。
   */
  private flipIn(): void {
    if (!this.switching) {
      return;
    }
    this.switching = false;
    const waited: number = Date.now() - this.flipAt;
    const delay: number = FLIP_OUT_MS - waited;
    if (this.flipInTimer >= 0) {
      clearTimeout(this.flipInTimer);
      this.flipInTimer = -1;
    }
    if (delay > 0) {
      this.flipInTimer = setTimeout((): void => {
        this.flipInTimer = -1;
        this.animateFlipIn();
      }, delay);
      return;
    }
    this.animateFlipIn();
  }

  private animateFlipIn(): void {
    // 先"瞬移"到另一面（这一刻卡片是侧对着的，看不出跳变），再翻回 0。
    this.applyFlip(this.flipDir * FLIP_MAX_ANGLE);
    animateTo({
      duration: FLIP_IN_MS,
      // 阻尼调大一点（0.68 → 0.82）：回弹别那么"猛"（用户反馈）。
      curve: curves.springMotion(0.45, 0.82)
    }, (): void => {
      this.applyFlip(0);
    });
  }

  // ---------------------------------------------------------------- 翻卡片

  /**
   * 把"翻到某个角度"写下来。
   *
   * 头像现在**住在卡片里**（见 build），所以不用再替它算位移/压扁 —— 它自动跟着卡片转。
   * 之前那套"自己算 dx·(cosθ-1) 位移 + cosθ 压扁"的手工合成已删掉（用户建议的包一层更干净）。
   */
  private applyFlip(angle: number): void {
    this.flipAngle = angle;
  }

  // ---------------------------------------------------------------- 左右滑：跟手翻页

  /**
   * 手指横滑过程中：卡片**跟着手指转**（需求："左滑右滑需要卡片翻页跟手"）。
   *
   * 映射：位移 / 卡片宽 → 角度，钳在 ±FLIP_MAX_ANGLE 之内。左滑（offsetX 为负）对应"接下一位"
   * 的那个方向（`-FLIP_MAX_ANGLE`），和松手后 beginUserSwitch 的终点是同一个方向，
   * 所以松手时是"从手指停的地方接着转过去"，不会跳一下。
   */
  private swipeFollow(offsetX: number): void {
    if (this.switching) {
      return;
    }
    const width: number = this.cardW();
    if (width <= 0) {
      return;
    }
    const ratio: number = Math.max(-1, Math.min(1, offsetX / width));
    // 跟手是**逐帧直接赋值**（不套 animateTo），所以三个量在这里一起写（见 applyFlip）。
    this.applyFlip(ratio * FLIP_MAX_ANGLE);
  }

  /**
   * 松手：过阈值就换人（接着把卡片翻完），没过就弹回原面。
   *
   * 左滑 = 下一位、右滑 = 上一位；那个方向没人了（第一位/最后一位）也弹回来。
   */
  private swipeRelease(offsetX: number): void {
    hilog.info(DOMAIN, TAG, 'swipe x=%{public}d hasNext=%{public}s hasPrev=%{public}s',
      Math.round(offsetX), `${this.hasNextUser}`, `${this.hasPrevUser}`);
    if (this.switching) {
      return;
    }
    const next: boolean = offsetX < 0;
    const wanted: boolean = Math.abs(offsetX) >= SWIPE_SWITCH_VP;
    if (!wanted || (next ? !this.hasNextUser : !this.hasPrevUser)) {
      // 没拉够 / 那个方向没人：弹回原面（阻尼大一点，别弹得那么猛）。
      animateTo({ duration: 240, curve: curves.springMotion(0.45, 0.85) }, (): void => {
        this.applyFlip(0);
      });
      return;
    }
    this.waiting = true;
    this.beginUserSwitch(next ? 1 : -1);
    if (next) {
      this.onNextUser();
      return;
    }
    this.onPrevUser();
  }

  /** 把翻卡片的状态立刻归位（收起 / 关闭时用：那时不能再叠一层旋转）。 */
  private resetFlip(): void {
    if (this.flipInTimer >= 0) {
      clearTimeout(this.flipInTimer);
      this.flipInTimer = -1;
    }
    this.switching = false;
    this.applyFlip(0);
  }

  /** 从头播当前这条（重置时钟 + 换媒体节点）。 */
  private restartItem(): void {
    this.elapsed = 0;
    this.startedAt = Date.now();
    this.seqEven = !this.seqEven;
    // 换了这一条（或那条换了一位用户）：把媒体区的比例/高度打进日志（排查黑边用）。
    this.logMedia('item');
  }

  /** 第一帧之后放大到全屏（在根 Stack 的 onAppear 里叫，那时布局已经量过一遍）。 */
  private expand(): void {
    this.pageAlpha = 1;
    /*
     * **把"展开动画起点那一刻的媒体区形状"记一行**（需求：打开动画就该是 9:16）。
     *
     * 这一发很关键：它发生在 reel 还没到（或刚到）的时候，`currentItem()` 往往是 null，
     * 于是走的是 `MEDIA_RATIO` 兜底 —— 兜底写错（曾经是 16/9 横版）时，卡片会先画成矮宽块、
     * 数据到了再跳成竖版（用户报的"先 16:9 再 9:16"）。有这行日志，一眼能看出展开那一刻
     * 用的到底是哪个比例、以及它和这一条真实比例（`item` 那两列）差多少。
     */
    this.logMedia('open-start');
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    animateTo({
      duration: HERO_MS,
      // **弹性**：展开也走 springMotion（收敛时会稍微过一点再回来）。
      curve: curves.springMotion(0.45, 0.72),
      onFinish: (): void => {
        /*
         * 两重守卫：
         *   · 代次对不上 = 这段展开已经被打断（收起 / 又重新展开了一次），回调直接作废；
         *   · `closing` / 不在展开态 = 返回手势正好落在这一瞬间（这就是"返回收起时动画消失"的根因：
         *     这条 onFinish 照样会来，把内容挂上、视频起播、还淡入一次）。
         */
        if (gen !== this.gen || this.closing || !this.open) {
          return;
        }
        /*
         * 长满全屏了才：挂内容 → 起播视频 → 内容淡入。
         *
         * 顺序有意如此：挂载和起播都放在动画之后，动画那 300ms 里这一层只有黑底（重排代价为零），
         * 视频也不会在缩放里每帧合成一次视频面（那是"展开时卡"的大头）。
         */
        this.contentMounted = true;
        if (this.currentIsVideo()) {
          this.videoController.start();
        }
        // 展开到位那一刻也量一次：这时"飞行头像"应该正好停在资讯栏那颗的位置。
        this.logRects('open');
        // 同时量卡片/媒体区的实际框（排查底部黑边，见 logBoxes）。
        this.logBoxes('open');
        animateTo({ duration: CONTENT_MS, curve: Curve.EaseOut }, (): void => {
          this.contentAlpha = 1;
        });
      }
    }, (): void => {
      this.open = true;
      // 展开时两层一起走同一条曲线（弹性只用在收起那头，见 avatarOpen 的说明）。
      this.avatarOpen = true;
      // 遮罩跟着淡进来（卡片四周于是"透出首页但被压暗"）。
      this.scrimAlpha = 1;
      // 下滑手势拖出来的位移在这里一起收回（掉头重新展开时它就是歪的）；
      // "掉进口袋"那一路的动作区/资讯栏/裁切线也一起复位。
      this.dragY = 0;
      this.resetSink();
    });
  }

  /**
   * **打断收起**：收起动画还在播的时候点头像 / 卡片 → 立刻掉头重新展开（需求）。
   *
   * 要做三件事：取消"摘掉内容"的定时器、作废上一条收起的回调（靠代次）、然后照常 expand()。
   */
  private reopen(): void {
    if (!this.closing) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'reopen (interrupt close)');
    this.closing = false;
    if (this.unmountTimer >= 0) {
      clearTimeout(this.unmountTimer);
      this.unmountTimer = -1;
    }
    // 收起走的是"掉进口袋"那一路时，tab 栏可能正鼓着：松开它（见 onPocketExit）。
    this.onPocketExit();
    // 收起时可能已经把内容摘掉了：重新挂上（expand 结束会再淡入一次）。
    this.contentMounted = true;
    // 告诉宿主"这次收起被取消了"：它会清掉 storyClosing，返回键才继续有效（见 onReopen）。
    this.onReopen();
    /*
     * **被打断的收起要能把计时器重新点起来**（审计发现的"停摆"）。
     *
     * `collapseAndClose` / `slideDownAndClose` 一开始就 `stopTimer()`，而这个计时器只在
     * `aboutToAppear` 里建过一次 —— 于是"按下返回/下滑触发了收起 → 中途又点一下打断展开"之后，
     * 进度条与自动前进就**永久停摆**了（画面还在，就是再也不走）。
     */
    if (this.timerId < 0) {
      this.timerId = setInterval((): void => {
        this.tick();
      }, TICK_MS);
      hilog.info(DOMAIN, TAG, 'reopen: timer restarted');
    }
    this.expand();
  }

  /**
   * 收回去：页面**缩成圆形蒙版**落回序列头像的位置，头像**弹性**收缩到位，然后宿主把这一层删掉
   * （播完 / 返回键 / 下滑都用它）。
   *
   * 四件事**故意错开**：
   *   ① 卡片（0 → HERO_MS，springMotion）：宽高缩到比头像还小一圈的正圆（CARD_END_SCALE）。
   *   ② 头像（0 → AVATAR_CLOSE_MS，springMotion）：**弹性**收缩，比卡片晚到一点、还带回弹。
   *   ③ 内容（CONTENT_KEEP_MS 后摘掉）：前半程还看得见画面在往圆形蒙版里缩，后半程只剩黑圆，
   *      重排代价几乎为零。
   *   ④ 黑卡（HERO_MS 的**最后 FADE_MS** 淡出，和**卡片**一起结束而不是和头像）：黑边必须在
   *      头像落定**之前**就消失 —— 它比头像大/久一点，就会露出"外层黑边"，浮层一撤看着就是
   *      头像"瞬间归位"（用户报的）。现在黑卡先缩得比头像小、再在自己的动画末尾淡掉。
   *
   * `onClose` 挂在**最长的那一条**（头像）上：浮层必须等两层都收完才撤；
   * 而且要比对**代次**：收起途中被点击掉头展开时（reopen），这条回调必须作废，不能把浮层删掉。
   */
  private collapseAndClose(): void {
    this.stopTimer();
    // 收起时把翻卡片的状态立刻归位（不能再叠一层缩放/偏移，否则落点会歪）。
    this.resetFlip();
    // 视频先停：收起动画里它还播的话，每一帧都要合成一次视频面。
    if (this.currentIsVideo()) {
      this.videoController.pause();
    }
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    animateTo({ duration: HERO_MS, curve: curves.springMotion(0.45, 0.72) }, (): void => {
      this.open = false;
      this.contentAlpha = 0;
      // 下滑手势触发的收起：把手指拖出来的位移一起收回 0（不然收缩起点是歪的）。
      this.dragY = 0;
    });
    animateTo({
      duration: AVATAR_CLOSE_MS,
      curve: curves.springMotion(0.42, 0.7),
      onFinish: (): void => {
        if (gen !== this.gen) {
          return;
        }
        // 收起动画刚结束、浮层还没撤：这一刻量两边头像的位置，看落点差多少（排查用）。
        this.logRects('closed');
        this.onClose();
      }
    }, (): void => {
      this.avatarOpen = false;
    });
    this.unmountTimer = setTimeout((): void => {
      this.unmountTimer = -1;
      this.contentMounted = false;
    }, CONTENT_KEEP_MS);
    // 黑卡淡出：跟着**卡片**那 300ms（不是头像那 420ms），黑边才不会留到最后。
    animateTo({ duration: FADE_MS, delay: HERO_MS - FADE_MS, curve: Curve.EaseIn }, (): void => {
      this.pageAlpha = 0;
    });
    // 遮罩和卡片一起淡掉（卡片收成圆的过程中，四周的压暗也退掉，露出首页）。
    animateTo({ duration: HERO_MS, curve: curves.springMotion(0.45, 0.72) }, (): void => {
      this.scrimAlpha = 0;
    });
  }

  /**
   * 收起（点 ✕ / 播完 / 返回键 / 没得往下走时统一走这里），**分两种**：
   *
   *   · 当前这位的头像还在主页托盘上（`heroUsable()`）→ 缩回它那儿（原来那套转场）；
   *   · 不在（顺着右半屏接了好几位之后、或者头像已经滚出屏幕）→ **直接向下收起**
   *     （需求："如果 story 页用户头像不在主页显示就向下收起 story 页就可以，
   *     不用位移到主页头像上"）。
   *
   * `closing` 是防重入：返回键 / 下滑 / 播完可能在动画那 200 多毫秒里撞到一起，
   * 没有它就会连发两次 onClose（宿主那边表现为浮层闪一下）。
   */
  private requestClose(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    if (this.heroUsable()) {
      hilog.info(DOMAIN, TAG, 'close mode=hero rect=%{public}s,%{public}s',
        `${Math.round(this.heroX)}`, `${Math.round(this.heroY)}`);
      this.collapseAndClose();
      return;
    }
    hilog.info(DOMAIN, TAG, 'close mode=down valid=%{public}s w=%{public}d',
      `${this.heroValid}`, Math.round(this.heroW));
    this.slideDownAndClose();
  }

  /** 返回键那一发（见 closeSignal 的说明）。 */
  private closeSignalChanged(): void {
    hilog.info(DOMAIN, TAG, 'close by back key');
    this.requestClose();
  }

  /** 宿主请求掉头展开（收起途中点了空白 / 点到了别的用户的头像，见 reopenSignal）。 */
  private reopenSignalChanged(): void {
    hilog.info(DOMAIN, TAG, 'reopen by host');
    this.reopen();
  }

  /**
   * 按 id 量出"飞行头像"和"序列里那颗头像"的**窗口坐标**，并排打一行日志。
   *
   * 排查转场错位只能靠这个：两边各自的内部坐标空间（页面坐标 vs 窗口坐标、有没有滚动偏移）
   * 光看代码看不出来，量成同一个空间一比就清楚了 —— `d=` 那一段就是两者中心的差（vp），
   * 正常应该接近 0；差多少、差在哪个轴上，一眼可见。
   */
  private logRects(tag: string): void {
    try {
      // 类型不写出来：`ComponentUtils` / `ComponentInfo` 这两个名字不在 @kit.ArkUI 的导出里，
      // 靠 getUIContext() 的返回值推断即可（写出来反而编译不过 —— 踩过）。
      const utils = this.getUIContext().getComponentUtils();
      const fly = utils.getRectangleById(STORY_FLYING_AVATAR_ID);
      const flyX: number = px2vp(fly.windowOffset.x);
      const flyY: number = px2vp(fly.windowOffset.y);
      const flyW: number = px2vp(fly.size.width);
      let text: string = `flying=${Math.round(flyX)},${Math.round(flyY)} ${Math.round(flyW)}`;
      if (this.heroUserId.length > 0) {
        const tray = utils.getRectangleById(storyAvatarNodeId(this.heroUserId));
        const trayX: number = px2vp(tray.windowOffset.x);
        const trayY: number = px2vp(tray.windowOffset.y);
        const trayW: number = px2vp(tray.size.width);
        text += ` tray=${Math.round(trayX)},${Math.round(trayY)} ${Math.round(trayW)}`
          + ` d=${Math.round(flyX + flyW / 2 - trayX - trayW / 2)},`
          + `${Math.round(flyY + flyW / 2 - trayY - trayW / 2)}`;
      }
      hilog.info(DOMAIN, TAG, 'rect %{public}s %{public}s', tag, text);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'rect %{public}s failed: %{public}s', tag,
        (error as Error).message ?? '-');
    }
  }

  /**
   * **头像不在屏幕上**时的收起：**先向上收缩（动作区融入、资讯栏缓慢隐藏）→ 快速下沉掉进
   * 底部 tab 栏（口袋）**。
   *
   * ① 向上收缩（0 → SHRINK_MS）：
   *    · 卡片：`exitScale → SLIDE_OUT_SCALE` 且 `dragY → -LIFT_VP`（一边缩一边抬）；
   *    · **动作区向上融入消失**（一滴水融进一滩水）：`actionsMelt → 1`，上移 + 淡出 + 缩小；
   *    · **资讯栏 + 更多按钮缓慢隐藏**：`infoAlpha → 0`，时长更长（INFO_FADE_MS，跨过两段）。
   * ② 快速下沉（SHRINK_MS → +SINK_MS）：`dragY → 口袋里`，同时把**裁剪线收到 tab 栏顶边**
   *    （`clipH = overlayH - BAR_H`）—— 卡片于是"从栏顶边穿过去消失"；
   *    进袋口时叫宿主让 tab 栏**鼓一下**，穿完再叫它**弹性回原状**。
   *
   * 两段之间用定时器串（`animateTo` 不能排程），回调都比对**代次**：中途被点/返回打断时
   * （`reopen`）第二段作废，`reopen` 里也会把口袋那口气松开（`onPocketExit`）。
   */
  private slideDownAndClose(): void {
    this.stopTimer();
    if (this.currentIsVideo()) {
      this.videoController.pause();
    }
    this.gen = this.gen + 1;
    const gen: number = this.gen;
    /*
     * 一开始就做两件事（需求："卡片上滑收缩时就放大 tabbar"、"卡片消失遮罩应该在 tabbar 顶部边缘"）：
     *   · 叫宿主把 tab 栏**鼓起来**（弹性就是这条 + 后面那条 settle）；
     *   · 把裁切线**立刻**钉在栏（鼓起来之后）的顶边 —— 注意是**立刻**、不是跟着下沉动画滑过来，
     *     否则会看到一条遮罩线从屏幕下方往上扫，而不是"卡片从栏顶边钻进去"。
     *     这时卡片已经被抬起（phase ①），底边在袋口之上，所以钉上去不会切到它。
     */
    this.onPocketEnter();
    this.clipH = this.pocketMaskTop();
    // ① 先向上收缩（弹性：会稍微过一点再回到目标值）。
    animateTo({
      duration: SHRINK_MS,
      curve: curves.springMotion(0.4, 0.78)
    }, (): void => {
      this.exitScale = SLIDE_OUT_SCALE;
      this.dragY = -LIFT_VP;
    });
    // 动作区：同上抬一点、淡出、缩小 —— "融入"卡片。
    animateTo({
      duration: SHRINK_MS,
      curve: curves.springMotion(0.42, 0.75)
    }, (): void => {
      this.actionsMelt = 1;
    });
    // 资讯栏 / 更多：**缓慢**隐藏（时长比收缩段长，跨过后面那段下沉）。
    animateTo({ duration: INFO_FADE_MS, curve: Curve.EaseIn }, (): void => {
      this.infoAlpha = 0;
    });
    // ② 抬起来之后快速下沉：从钉好的袋口钻进去，穿完才让宿主把浮层撤掉、并让栏**直接恢复**原状。
    setTimeout((): void => {
      if (gen !== this.gen) {
        return;
      }
      /*
       * 卡片**刚穿过袋口**就让栏回位（需求："卡片经过后 tabbar 马上恢复，现在的恢复时间太晚了"）。
       *
       * 不再等整段下沉跑完：下沉距离是留了富余的（保证整张卡片看不见），所以"卡片顶边越过袋口"
       * 那一刻大概只在下沉段的前 2/3。这里按几何算一下那一刻，用定时器提前叫 onPocketExit；
       * 下沉段自己的 onFinish 里再叫一次（幂等，`settleStoryPocket` 见到已经是 0 就直接返回）。
       */
      const passTimer: number = setTimeout((): void => {
        if (gen !== this.gen) {
          return;
        }
        hilog.info(DOMAIN, TAG, 'pocket pass → bar settle');
        this.onPocketExit();
      }, this.pocketPassMs());
      this.pocketExitTimer = passTimer;
      animateTo({
        duration: SINK_MS,
        // 陡一点 = "快速下沉"（响应短、几乎不回弹）。
        curve: curves.springMotion(0.34, 0.86),
        onFinish: (): void => {
          if (gen !== this.gen) {
            return;
          }
          // 兜底：万一上面那条没跑到（被打断的话 gen 已经变了，走不到这里）。
          this.onPocketExit();
          this.onClose();
        }
      }, (): void => {
        this.dragY = this.pocketSinkY();
        this.exitScale = POCKET_SINK_SCALE;
        this.contentAlpha = 0;
        this.pageAlpha = 0;
        this.scrimAlpha = 0;
      });
    }, SHRINK_MS);
  }

  /**
   * 卡片顶边"越过袋口"大概在下沉段的多长时间（毫秒）。
   *
   * 几何：下沉时卡片**一边缩一边往下走**，所以它的上边同时在两个方向上往袋口靠 ——
   *   · 位移：`dragY` 往下走；
   *   · 收缩：缩到 `POCKET_SINK_SCALE` 时，上边自己又往下掉了 `cardH × (1 - 缩放) / 2`
   *     （缩放以中心为原点）。
   * 所以"上边够到袋口"只需要走 `need = 袋口 - (卡片顶 + 收缩带来的那一段)`，
   * 除以总位移 `pocketSinkY()` 就是进度比例，再乘这段的时长。
   * 再乘 `POCKET_PASS_TRIM`（<1）留一点提前量，钳在 [0.15, 0.55]。
   */
  private pocketPassMs(): number {
    const travel: number = this.pocketSinkY();
    if (travel <= 0) {
      return SINK_MS * 0.35;
    }
    const shrinkDrop: number = this.cardH() * (1 - POCKET_SINK_SCALE) / 2;
    const need: number = this.pocketMaskTop() - (this.cardY() + shrinkDrop);
    const raw: number = (need / travel) * POCKET_PASS_TRIM;
    const ratio: number = Math.min(0.55, Math.max(0.15, raw));
    return SINK_MS * ratio;
  }

  /**
   * 卡片"消失遮罩"该钉在哪（= tab 栏**弹着的时候**的顶边，浮层坐标）。
   *
   * 栏弹的时候是"高 +4、整体下压 7"（见 Index 那两个常量），所以袋口 = `overlayH - (60 + 4) + 7`。
   * 卡片整个下沉过程都发生在这一次弹动之内，所以按弹着的位置算才是对的。
   */
  private pocketMaskTop(): number {
    const top: number = this.overlayH - (BAR_H + BAR_POCKET_GROW) + BAR_POCKET_DIP;
    return top > 0 ? top : this.overlayH;
  }

  /** 掉进口袋要沉多远：卡片顶边滑到 tab 栏顶边之下还多留一截（保证整张看不见）。 */
  private pocketSinkY(): number {
    const barTop: number = this.overlayH - BAR_H;
    const need: number = barTop - this.cardY() + this.cardH() * POCKET_SINK_SCALE + POCKET_EXTRA_VP;
    return need > 0 ? need : this.overlayH;
  }

  /** 把"掉进口袋"这套状态复位（展开 / 掉头重新展开时用，见 expand / reopen）。 */
  private resetSink(): void {
    if (this.pocketExitTimer >= 0) {
      clearTimeout(this.pocketExitTimer);
      this.pocketExitTimer = -1;
    }
    this.exitScale = 1;
    this.actionsMelt = 0;
    this.infoAlpha = 1;
    this.clipH = this.overlayH;
  }

  /** 当前这位的头像能不能飞回去（见 heroValid 的说明）。 */
  private heroUsable(): boolean {
    if (!this.heroValid || this.heroW <= 1 || this.heroH <= 1) {
      return false;
    }
    // 头像滚出屏幕了：飞回去等于飞到屏幕外，不如向下收。
    if (this.heroX + this.heroW < 0 || this.heroX > this.screenW) {
      return false;
    }
    if (this.heroY + this.heroH < 0 || this.heroY > this.screenH) {
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- 下滑手势
  // 注意：这几个方法名**不能叫 onDragStart / onDragUpdate / onDragEnd** —— 那些名字在
  // CustomComponent 基类上已经有了（组件的拖拽事件回调），重名会编译不过。

  private dragBegin(): void {
    this.dragPaused = true;
    if (this.currentIsVideo()) {
      this.videoController.pause();
    }
  }

  private dragMove(offsetY: number): void {
    this.dragY = offsetY > 0 ? offsetY : 0;
  }

  private dragFinish(offsetY: number, velocityY: number): void {
    this.dragPaused = false;
    if (offsetY > DRAG_CLOSE_VP || velocityY > DRAG_FLING_VP) {
      hilog.info(DOMAIN, TAG, 'drag close y=%{public}d v=%{public}d',
        Math.round(offsetY), Math.round(velocityY));
      /*
       * 拉够了 = 要收起，但**收起的样子交给 requestClose 决定**，不是一律往下滑：
       * 当前这一位的头像还在主页托盘里就朝它收缩（需求："收起 story 页如果用户头像在主页头像
       * 序列中显示的话就往头像收缩页面"），不在才整页往下滑走。
       * `collapseAndClose` 会把 dragY 一起收回 0，所以是从手指拖到的位置弹回去再收缩。
       */
      this.requestClose();
      return;
    }
    // 没拉够：弹回去接着播。
    animateTo({ duration: 180, curve: Curve.Friction }, (): void => {
      this.dragY = 0;
    });
    if (this.currentIsVideo()) {
      this.videoController.start();
    }
    this.startedAt = Date.now() - this.elapsed;
  }

  /** 拖动时整层的透明度（越拉越淡，但留一点，别看着像闪）。 */
  private dragAlpha(): number {
    const limit: number = this.screenH * 0.8;
    const ratio: number = limit > 0 ? this.dragY / limit : 0;
    return Math.max(DRAG_MIN_ALPHA, 1 - ratio);
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private tick(): void {
    // 数据还没到（宿主是"先弹卡片、后到数据"，见 Index.openStory）：进度条不动、也不会往下跳。
    if (this.paused || this.waiting || this.dragPaused || !this.open || this.reel.items.length === 0) {
      // 暂停（或正在取下一位 / 手指正按着 / 展开动画还没跑完）时把起播时刻往后推，
      // 恢复后进度条接着走（不是跳回去）。展开动画那 300ms 不推进度：那段时间进度条本身
      // 还在淡入，推进去只是白白让这一页重绘。
      this.startedAt = Date.now() - this.elapsed;
      return;
    }
    this.elapsed = Date.now() - this.startedAt;
    if (this.elapsed >= this.currentDuration()) {
      this.next();
    }
  }

  /**
   * 下一条（右半屏 / 自动播完）。
   *
   * 已经是这一份的最后一条时：**后面还有人就叫宿主接下一位**（需求："最后一个照片/视频
   * 点击右半屏接续下一个用户的 story"）；**没有了（最后一位用户的最后一页）就收起整个 story 页**
   * （需求："最后一个 story 的最后一页点击右侧收起 stories 页"）。
   */
  private next(): void {
    /*
     * **重入保护**（审计发现：连点两次右半屏会跳两位用户）。
     *
     * 换用户那条路是"先翻出去、等新数据回来再弹回来"的异步过程（`beginUserSwitch` +
     * `onNextUser` → 宿主取数 → `onReelChanged`）。`waiting` 只是把状态立起来，本身并**不**阻止
     * 第二次点击再走一遍这段 —— 于是一个连点就会让宿主连续接两位，界面直接跳过一个人的 story。
     * 正在切用户/正在收起时一律忽略。
     */
    if (this.waiting || this.switching || this.closing) {
      return;
    }
    // 数据还没到（空 reel）：什么都不做，等 @Watch 把数据换上来。
    if (this.reel.items.length === 0) {
      return;
    }
    if (this.index + 1 >= this.reel.items.length) {
      if (this.hasNextUser) {
        this.waiting = true;
        // 换用户：先翻出去，新数据到了再弹回来（见 beginUserSwitch / onReelChanged）。
        this.beginUserSwitch(1);
        this.onNextUser();
        return;
      }
      this.requestClose();
      return;
    }
    this.index = this.index + 1;
    this.restartItem();
  }

  /**
   * 上一条（左半屏）。
   *
   * 顺序：不是第一条 → 上一条；是第一条但前面还有人 → 回上一位用户（见 onPrevUser）；
   * **是第一条且就是第一位用户 → 什么都不做**（需求："在第一个 story 的第一页禁用点击左侧"）。
   */
  /**
   * 结束"长按暂停"并让进度接着走（`onActionEnd` 与 `onActionCancel` 共用）。
   *
   * 为什么要共用：被根 PanGesture / 卡片 PanGesture 抢走手势时 `onActionEnd` 不会回调，
   * 只登记 end 会让 `paused` 永久卡 true（见那两处 gesture 上的注释）。
   */
  private resumeFromLongPress(): void {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    // 暂停这段不该算进进度：把起点往后推，等于"把刚才停住的时间抹掉"。
    this.startedAt = Date.now() - this.elapsed;
    if (this.currentIsVideo()) {
      this.videoController.start();
    }
  }

  private prev(): void {
    // 同 next()：切用户/收起过程中连点会连跳，一律忽略（见 next 里的说明）。
    if (this.waiting || this.switching || this.closing) {
      return;
    }
    // 数据还没到：不做任何事。
    if (this.reel.items.length === 0) {
      return;
    }
    if (this.index > 0) {
      this.index = this.index - 1;
      this.restartItem();
      return;
    }
    if (this.hasPrevUser) {
      this.waiting = true;
      this.beginUserSwitch(-1);
      this.onPrevUser();
      return;
    }
    // 第一位用户的第一页：左侧无效（不重播、也不做任何事）。
  }

  /**
   * 左滑 = **下一位用户**（需求）；这里只留给"右半屏点到最后一条"那条路复用。
   */
  private swipeToNextUser(): void {
    this.swipeRelease(-SWIPE_SWITCH_VP - 1);
  }

  /** 右滑 = **上一位用户**（需求）。 */
  private swipeToPrevUser(): void {
    this.swipeRelease(SWIPE_SWITCH_VP + 1);
  }

  private currentItem(): StoryItem | null {
    const items: Array<StoryItem> = this.reel.items;
    if (items.length === 0) {
      return null;
    }
    return items[Math.min(this.index, items.length - 1)];
  }

  private currentDuration(): number {
    const item: StoryItem | null = this.currentItem();
    return item === null ? 5000 : item.durationMs;
  }

  private currentImage(): ResourceStr {
    const item: StoryItem | null = this.currentItem();
    if (item === null || item.imageUrl.length === 0) {
      return $r('app.media.startIcon');
    }
    return item.imageUrl;
  }

  private currentVideo(): string {
    const item: StoryItem | null = this.currentItem();
    return item === null ? '' : item.videoUrl;
  }

  private currentIsVideo(): boolean {
    const item: StoryItem | null = this.currentItem();
    return item === null ? false : item.videoUrl.length > 0;
  }

  private titleNow(): string {
    if (this.username.length > 0) {
      return this.username;
    }
    return this.reel.username;
  }

  private avatarNow(): string {
    if (this.avatarUrl.length > 0) {
      return this.avatarUrl;
    }
    return this.reel.avatarUrl;
  }

  /** 起始矩形的四个值（量不到就给兜底，见 FALLBACK_W）。 */
  private startW(): number {
    return this.heroW > 1 ? this.heroW : FALLBACK_W;
  }

  private startH(): number {
    return this.heroH > 1 ? this.heroH : FALLBACK_W;
  }

  /**
   * 收起时卡片缩到多大 = **托盘那颗头像的照片圆**（`startW()` 去掉两边描边）。
   *
   * 因为头像现在就住在卡片里（见 build 卡片层）：卡片和照片一样大时，头像正好把它铺满，
   * 黑卡完全被盖住 —— 既没有"外层黑边"，也不会被卡片的 clip 切掉（早先缩小到 70% 的那套
   * 是在头像还挂在浮层外层时用的，现在不需要了）。
   */
  private cardClosedW(): number {
    const size: number = this.startW() - AVATAR_PHOTO_INSET * 2;
    return size > 8 ? size : 8;
  }

  /**
   * 起始位置：**把托盘量到的窗口坐标换算成浮层坐标**（减掉 spaceOffset）。
   *
   * 量不到（heroW<=1）就直接用卡片自己的左上角 —— 那个本来就是浮层坐标，不需要换算。
   */
  private startX(): number {
    return this.heroW > 1 ? this.heroX - this.spaceOffsetX : this.cardX();
  }

  private startY(): number {
    return this.heroH > 1 ? this.heroY - this.spaceOffsetY : this.cardY();
  }

  // ------------------------------------------------- 卡片几何（都算在**浮层坐标**里）
  // 依赖 measureSpace() 量到的浮层尺寸，所以展开动画必须等它量完（见 build 的 onAppear）。

  /** 卡片宽 = 屏幕宽 - 两侧留白。 */
  private cardW(): number {
    const width: number = this.overlayW - CARD_SIDE_VP * 2;
    return width > 160 ? width : 160;
  }

  /**
   * 媒体区高：按**当前这一条的媒体比例**算，再被"可用高度"夹一次（别顶到屏幕边）。
   *
   * 为什么要按真实比例（原来是写死 9:16）：比例对不上时 `Cover` 会裁内容、`Contain` 会留黑边
   * —— 用户报的"媒体区出现黑边"就是这个。现在媒体区 = 媒体本身的形状，于是可以放心用 `Cover`
   * 铺满：既没有黑边，也不裁内容。
   */
  private mediaH(): number {
    const room: number = this.overlayH - CARD_SIDE_VP * 2 - ACTION_TOP_VP - ACTION_H;
    const aspect: number = this.mediaAspect();
    // h = w / (w/h)
    const byRatio: number = this.cardW() / aspect;
    return room > 120 && byRatio > room ? room : byRatio;
  }

  /**
   * 当前这条媒体的宽高比（w/h）。
   *
   * 拿不到宽高（老数据 / 解析缺字段）就退回竖版 9:16；比例离谱（超宽或超长）也钳一下，
   * 免得卡片变成一条线或一根柱子。
   */
  private mediaAspect(): number {
    const item: StoryItem | null = this.currentItem();
    if (item === null || item.width <= 0 || item.height <= 0) {
      return MEDIA_RATIO;
    }
    const aspect: number = item.width / item.height;
    return Math.min(2.2, Math.max(0.45, aspect));
  }

  /** 卡片总高（= 媒体区 + 间隔 + 功能区，用来把整块**居中**；功能区本身在卡片外，见 build）。 */
  private cardH(): number {
    return this.mediaH() + ACTION_TOP_VP + ACTION_H;
  }

  private cardX(): number {
    return CARD_SIDE_VP;
  }

  /** 纵向居中（悬浮感就来自四周留出的空白）。 */
  private cardY(): number {
    const y: number = (this.overlayH - this.cardH()) / 2;
    return y > CARD_SIDE_VP ? y : CARD_SIDE_VP;
  }

  /** 资讯栏（进度条下面那一行）在浮层坐标里的顶边。 */
  private infoY(): number {
    return this.cardY() + PROGRESS_TOP_VP + SEG_H + INFO_GAP_VP;
  }

  /**
   * 资讯栏里那颗头像停稳后的位置。
   *
   * 飞行头像的**终点**就是这里（需求："序列头像和用户资讯头像绑定位移动画"），
   * 所以它必须和 header 里那行胶囊内部的排布一致：胶囊左内缩 3、头像在 40 高的胶囊里居中。
   */
  private infoAvatarX(): number {
    return this.cardX() + INFO_SIDE_VP + 3;
  }

  private infoAvatarY(): number {
    return this.infoY() + (INFO_PILL_H - INFO_AVATAR_VP) / 2;
  }

  /**
   * 量出浮层自己的原点在窗口里的位置（= 两个坐标系的偏移）+ 浮层尺寸。
   *
   * 在展开动画**之前**叫（见 build 的 onAppear）：这时根节点还没动过，量到的就是纯偏移。
   * 量不到就保持默认值（退化成"不换算"，和以前一样，不至于把动画弄崩）。
   */
  private measureSpace(): void {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(STORY_ROOT_ID);
      this.spaceOffsetX = px2vp(info.windowOffset.x);
      this.spaceOffsetY = px2vp(info.windowOffset.y);
      this.overlayW = px2vp(info.size.width);
      this.overlayH = px2vp(info.size.height);
      // 裁切线先按"不裁"初始化（掉进口袋那一路才会收紧，见 clipH）。
      if (this.clipH <= 0) {
        this.clipH = this.overlayH;
      }
      hilog.info(DOMAIN, TAG, 'space offset=%{public}d,%{public}d size=%{public}dx%{public}d',
        Math.round(this.spaceOffsetX), Math.round(this.spaceOffsetY),
        Math.round(this.overlayW), Math.round(this.overlayH));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'measureSpace failed: %{public}s', (error as Error).message ?? '-');
    }
  }

  /** 一段进度条占多宽（去掉留白与段间距后均分）—— 有几张就分几段（需求）。 */
  private segWidth(): number {
    const count: number = this.reel.items.length;
    if (count <= 0) {
      return 0;
    }
    const usable: number = this.cardW() - PROGRESS_SIDE_VP * 2 - SEG_GAP * (count - 1);
    return usable > 0 ? usable / count : 0;
  }

  /** 这一段已经走到哪（0..1 → 宽度）。 */
  private segFill(position: number): number {
    if (position < this.index) {
      return this.segWidth();
    }
    if (position > this.index) {
      return 0;
    }
    const duration: number = this.currentDuration();
    const ratio: number = duration > 0 ? this.elapsed / duration : 0;
    return this.segWidth() * Math.min(1, Math.max(0, ratio));
  }

  /**
   * 量**卡片**与**媒体区**的实际渲染框并打一行（排查"卡片底部那条黑边"）。
   *
   * 判据很简单：如果 `media` 的下边比 `card` 的下边高出一截，那就是卡片比媒体高（黑边就是这么来的）；
   * 两者下边一致还看到黑，那黑来自媒体自身（内容/解码）。
   */
  private logBoxes(tag: string): void {
    try {
      const utils = this.getUIContext().getComponentUtils();
      const card = utils.getRectangleById(STORY_CARD_ID);
      const media = utils.getRectangleById(STORY_MEDIA_ID);
      const cardTop: number = px2vp(card.windowOffset.y);
      const cardBottom: number = cardTop + px2vp(card.size.height);
      const mediaTop: number = px2vp(media.windowOffset.y);
      const mediaBottom: number = mediaTop + px2vp(media.size.height);
      hilog.info(DOMAIN, TAG,
        'box %{public}s card=%{public}d..%{public}d media=%{public}d..%{public}d gapBottom=%{public}d',
        tag, Math.round(cardTop), Math.round(cardBottom),
        Math.round(mediaTop), Math.round(mediaBottom), Math.round(cardBottom - mediaBottom));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'box %{public}s failed: %{public}s', tag,
        (error as Error).message ?? '-');
    }
  }

  /** 把"这一条媒体区按什么比例算"打进日志。
   *
   * 黑边这类问题光看代码说不清（同一个 story 时好时坏），有这几行就能对上：`aspect` 是不是
   * 这一条真实的比例、`area` 是不是按它算出来的高度、`size` 是不是 0（0 = 没解析到宽高、退回了
   * `MEDIA_RATIO` 兜底 —— 见那个常量的说明，它必须是竖版 9:16）。
   */
  private logMedia(tag: string): void {
    const item: StoryItem | null = this.currentItem();
    hilog.info(DOMAIN, TAG,
      'media %{public}s i=%{public}d/%{public}d video=%{public}s size=%{public}dx%{public}d aspect=%{public}d.%{public}d area=%{public}dx%{public}d',
      tag, this.index, this.reel.items.length,
      item === null ? '-' : `${item.isVideo()}`,
      item === null ? 0 : item.width, item === null ? 0 : item.height,
      Math.floor(this.mediaAspect()), Math.round((this.mediaAspect() % 1) * 100),
      Math.round(this.cardW()), Math.round(this.mediaH()));
  }

  @Builder
  progressBar() {
    Row() {
      ForEach(this.reel.items, (one: StoryItem, position: number): void => {
        Row() {
          Row()
            .width(this.segFill(position))
            .height(SEG_H)
            .borderRadius(SEG_H / 2)
            .backgroundColor(Color.White)
        }
        .width(this.segWidth())
        .height(SEG_H)
        .borderRadius(SEG_H / 2)
        .backgroundColor('#66FFFFFF')
        .margin({ right: SEG_GAP })
      }, (one: StoryItem, position: number): string => `${one.id}-${position}`)
    }
    .width('100%')
    /*
     * **高度从第一帧就固定**（需求："进度条需要优先加载，不然头像会错位"）。
     *
     * 资讯栏头像的落点是算出来的：`infoY() = 卡片顶 + PROGRESS_TOP + SEG_H + INFO_GAP`。
     * 而进度条是 `ForEach(reel.items)` —— 数据没到时一个子节点都没有，Row 的内容高就是 0，
     * 整条只有 PROGRESS_TOP 那么高，资讯栏于是比"算出来的位置"高 SEG_H（2.5vp），
     * 头像就落偏了；数据一到又跳回原位。
     * 这里把高度钉成 `PROGRESS_TOP_VP + SEG_H`：不管有没有数据、分成几段，排版高度都一样。
     */
    .height(PROGRESS_TOP_VP + SEG_H)
    // 需求："媒体区顶部显示进度条，和媒体顶部保持 5vp 距离"。
    .padding({ left: PROGRESS_SIDE_VP, right: PROGRESS_SIDE_VP, top: PROGRESS_TOP_VP })
  }

  /**
   * 用户资讯栏（进度条下面那一行）：左边是**沉浸光感**的"头像 + 用户名"胶囊，
   * 右边是 feeds 那颗「更多」（≡，`sys.symbol.sort`）。
   *
   * 直接把 feeds 资料行那套抄过来（见 FeedList.profileRow）：材质只能由 Toggle 承载，所以
   * 胶囊 = 一颗透明 Toggle 垫材质 + 里面放头像和名字；`hitTestBehavior(Transparent)` 让点击
   * 落到胶囊自己身上（这一版不接功能，点了只记日志）。
   *
   * 头像的位置必须和 `infoAvatarX()/infoAvatarY()` 算出来的**完全一致**：飞行头像的终点就是
   * 那儿（需求："序列头像和用户资讯头像绑定位移动画"）。所以内缩写死成 3、高 40，
   * 头像在里面居中 —— 和那两个方法里的算式一一对应，改一处要改两处。
   */
  @Builder
  infoRow() {
    Row() {
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Row({ space: 8 }) {
          /*
           * 头像位置**留空**：真正显示的是浮层里那颗"飞行头像"（build ② 那一层）。
           *
           * 为什么不在这里再画一颗静态头像（原来就是那样，用户报的正是它）：
           * 飞行头像的弹性动画要 400 多毫秒才落定，而静态那颗是内容挂载（300ms）时就出现的
           * —— 两颗同图不同相位，看起来就是"弹性还没播完，图片**瞬间位移**到静态位置上"。
           * 只留一颗（飞行的这颗）就没有"切换"这回事：它从序列头像一路动到这儿就停在这儿。
           */
          Row()
            .width(INFO_AVATAR_VP)
            .height(INFO_AVATAR_VP)
          Text(this.titleNow())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            // 这一行永远压在画面上，所以文字固定白色（feeds 那边是按卡片/视频两种底分色的）。
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: this.cardW() * 0.45 })
          // 高光：标题后面跟一行小字的发布日期（需求："还有该 highlight 的发布日期"）。
          if (this.dateText.length > 0) {
            Text(this.dateText)
              .fontSize(11)
              .fontColor('#B3FFFFFF')
              .maxLines(1)
              .constraintSize({ maxWidth: this.cardW() * 0.3 })
          }
        }
      }
      .padding({ left: 3, right: 12, top: 3, bottom: 3 })
      .borderRadius(INFO_PILL_H / 2)
      .backgroundColor(Color.Transparent)
      .selectedColor(Color.Transparent)
      .attributeModifier(new SurfaceModifier(this.thickness, false))
      .hitTestBehavior(HitTestMode.Transparent)
      .onChange((): void => {
        // 纯材质宿主，不接开关语义（点击由下面 onClick 接）。
      })
      .onClick((): void => {
        this.onAction('info');
      })

      /*
       * 资讯胶囊右边那颗「关注」（需求："查阅快拍内容但未关注该用户就在用户资讯旁显示一个关注按钮"）。
       *
       * 只在"没关注"时画；点赞/评论/查看更多都保持不变。材质走全 app 那一套
       * （MaterialLabelButton = 透明 Toggle 承载沉浸光感），颜色固定白色（这一行永远压在画面上，
       * 同胶囊里的用户名），所以关掉自动反色。
       */
      if (!this.following && this.username.length > 0) {
        Row() {
          MaterialLabelButton({
            labelRes: $r('app.string.action_follow'),
            fontSize: 14,
            pillWidth: STORY_FOLLOW_W_VP,
            pillHeight: STORY_FOLLOW_H_VP,
            tint: '#FFFFFF',
            autoInvert: false,
            onTap: (): void => {
              this.tapFollow();
            }
          })
        }
        .margin({ left: 8 })
        /*
         * 这里**不加 `hitTestBehavior(Transparent)`**：加了的话这一次点击会同时落到下面的
         * "点左/右半屏翻一条"上（点关注顺手把快拍翻了）。默认让按钮自己吃下点击。
         */
      }

      // 右侧「更多」：feeds 那颗（≡）。
      Row().layoutWeight(1)
      MaterialIconButton({
        symbol: $r('sys.symbol.sort'),
        buttonSize: 40,
        iconSize: 20,
        tint: '#FFFFFF',
        autoInvert: false,
        onTap: (on: boolean): void => {
          this.onAction('more');
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: INFO_SIDE_VP, right: INFO_SIDE_VP, top: INFO_GAP_VP })
    // 收起时"缓慢隐藏"（需求）：整行（胶囊 + 更多按钮）一起淡出，见 slideDownAndClose。
    .opacity(this.infoAlpha)
  }

  /** 媒体：视频就真播（自动起播），图片就按进度条停着；**数据还没到就给个转圈**。 */
  @Builder
  mediaLayer() {
    if (this.reel.items.length === 0) {
      // 宿主是"先弹卡片、后取数据"（见 Index.openStory）：这一段是空窗期。
      LoadingProgress()
        .width(36)
        .height(36)
        .color('#FFFFFF')
    } else if (this.currentIsVideo()) {
      /*
       * 视频：**底下垫一张同帧的封面图**（`Cover` 铺满），视频压在上面。
       *
       * 为什么多这一层：播放器的 `objectFit` 在有些版本/有些片上不生效（会按自己的比例居中，
       * 于是露出黑边），而"同一个 story 时好时坏"正是这种"看片下菜"的表现。垫一层同帧封面之后，
       * 即使播放器自己留了边，露出来的也是这一帧的画面，不会出现黑边（也不会闪）。
       */
      Stack({ alignContent: Alignment.Center }) {
        Image(this.currentImage())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
        Video({
          src: this.currentVideo(),
          currentProgressRate: 1,
          controller: this.videoController
        })
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
        /*
         * 展开动画跑完（内容也挂上了）之前**不起播**（见 expand 的说明）。
         * `restartItem` 换节点时这两位已经是 true（浮层早开着了），所以连播两条视频
         * 第二条照样会自己播。
         */
        .autoPlay(this.open && this.contentMounted)
        .controls(false)
        .loop(false)
        .onFinish((): void => {
          // 播完 = 右半屏那一下，直接下一条（时钟那条兜底可能先到，next() 自己会判重）。
          this.next();
        })
        .onError((): void => {
          // 视频放不出来（CDN 被墙 / 解码不了）：别卡死在这儿，交给进度条按时长往下走。
          hilog.warn(DOMAIN, TAG, 'video error url=%{public}s',
            this.currentVideo().substring(0, 80));
        })
      }
      .width('100%')
      .height('100%')
    } else {
      Image(this.currentImage())
        .width('100%')
        .height('100%')
        // 同视频：媒体区按真实比例算好了，`Cover` 不裁也不留黑边。
        .objectFit(ImageFit.Cover)
        .draggable(false)
    }
  }

  @Builder
  mediaArea() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 媒体铺满这一整块（进度条 / 用户名是**浮在它上面**的，不再占布局高度 —— 需求：
      // "媒体区往上移动"）。
      Stack({ alignContent: Alignment.Center }) {
        // 每换一条重建一次（见 seqEven 的说明）。
        if (this.seqEven) {
          this.mediaLayer()
        } else {
          this.mediaLayer()
        }
      }
      .width('100%')
      .height('100%')

      // 顶部浮层：进度条 + 用户资讯栏（需求："媒体区顶部显示进度条；进度条下方显示用户资讯栏"）。
      Column() {
        this.progressBar()
        this.infoRow()
      }
      .width('100%')

      // 点击层：**最上面一层、全透明**（所以要盖在上面，连进度条那一行也点得到），
      // 左半屏 = 上一条、右半屏 = 下一条（需求）；长按暂停。
      Row() {
        Row()
          .width('50%')
          .height('100%')
          .onClick((): void => {
            this.prev();
          })
        Row()
          .width('50%')
          .height('100%')
          .onClick((): void => {
            this.next();
          })
      }
      .width('100%')
      .height('100%')
      .gesture(
        LongPressGesture({ repeat: false })
          .onAction((): void => {
            this.paused = true;
            if (this.currentIsVideo()) {
              this.videoController.pause();
            }
          })
          .onActionEnd((): void => {
            this.resumeFromLongPress();
          })
          /*
           * **被别的手势抢走时也要复位**（审计发现：只登记了 onActionEnd）。
           *
           * 长按暂停期间，如果根部的 PanGesture（下滑收起）或卡片那层 PanGesture 把这一串事件接管了，
           * `onActionEnd` **不会**回调 —— 于是 `paused` 卡在 true，进度条永久停住（画面还在、就是不走）。
           * `onActionCancel` 走同一套复位逻辑。
           */
          .onActionCancel((): void => {
            this.resumeFromLongPress();
          })
      )
    }
    .width('100%')
    // 媒体区固定高度（圆角卡片的那块"底"），进度条 / 资讯栏都浮在它上面。
    .height(this.mediaH())
    .id(STORY_MEDIA_ID)
    .borderRadius({ topLeft: CARD_RADIUS_VP, topRight: CARD_RADIUS_VP })
    .clip(true)
  }

  /**
   * 右下角一颗沉浸光感互动按钮。
   *
   * 用的是全 app 那套材质按钮（`MaterialIconButton`，reels 页互动区同一个组件、同一份材质
   * 设定），所以厚度跟着设定页走。`autoInvert: false` + 固定白图标：这一页底色永远是黑的，
   * 不能让图标跟着"材质反色"飘。
   */
  @Builder
  actionButton(symbol: Resource, kind: string) {
    MaterialIconButton({
      symbol: symbol,
      tint: '#FFFFFF',
      autoInvert: false,
      onTap: (on: boolean): void => {
        this.onAction(kind);
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      /*
       * ⓪ 遮罩：整屏半透明的一层，**点它收起**（需求："点击空白处收起页面"）。
       *
       * 它也就是"悬浮"的来源 —— 卡片四周留白处透出的是首页，被这一层压暗。
       * `expandSafeArea` 是必要的：浮层的布局原点在状态栏下面，不扩的话状态栏那一条不会被压暗。
       */
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.comments_scrim'))
        .opacity(this.scrimAlpha)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onClick((event: ClickEvent): void => {
          /*
           * 点空白处收起（需求）。但**收起动画还在播的时候**这一下有两种意思：
           *   · 点在托盘里某位用户的头像上 → 交给宿主**换成那一位的 story**（需求：
           *     "收起 stories 时点击用户头像必须切换到该用户的 story，而不是保持原来的用户"）；
           *   · 点在别处 → 撤销收起（于是"收起 → 点一下 → 又展开 → 再收起…"可以连续打断）。
           * 判断需要托盘里的矩形（宿主才有），所以把**窗口坐标**报上去，由宿主决定。
           */
          if (this.closing) {
            this.onTapPoint(event.windowX, event.windowY);
            return;
          }
          this.requestClose();
        })

      /*
       * 裁切容器：平时高度 = 浮层高（等于不裁），只有"掉进口袋"那一路会收到 tab 栏顶边，
       * 卡片于是从栏顶边穿过去消失（见 slideDownAndClose / clipH）。
       */
      Stack({ alignContent: Alignment.TopStart }) {
        /*
         * ① 卡片层：**圆角卡片只包住媒体区**（需求："媒体区不用延申至功能区，圆角卡片仅包裹媒体"）。
         *
         * 几何**老老实实改布局属性**（width / height / position / borderRadius）：
         *   收起 = startW() 见方 + 半径 = 边长一半（正圆）；展开 = 卡片宽高 + 半径 CARD_RADIUS_VP。
         *   于是观感是"从序列头像的圆形蒙版弹出一张卡片"，收起时反过来（需求：
         *   "展开和收起需要统一从序列头像圆形蒙版弹出和收起"）。
         *   **弹性**靠 `springMotion`（展开、收起各一条，见 expand / collapseAndClose）。
         * **不用** translate/scale 做转场几何：那两个在 ArkUI 里是相乘的，落点会算不准（踩过）。
         */
        Stack({ alignContent: Alignment.TopStart }) {
        /*
         * 内容**只在动画跑完之后才挂**（见 contentMounted）：动画那几百毫秒里这一层只有一块
         * 底色，重排几乎为零；等卡片到位再把媒体 / 资讯栏挂上来淡入。
         */
        if (this.contentMounted) {
          Column() {
            // 媒体区（进度条 + 用户资讯栏浮在它顶部；媒体就是这张圆角卡片的底）。
            this.mediaArea()
          }
          .width('100%')
          .height('100%')
          .opacity(this.contentAlpha)
        }

        /*
         * **头像就住在卡片里面**（需求："让头像组件被卡片组件包裹，跟随卡片统一翻页"）。
         *
         * 这样它天然继承卡片的一切变换：翻转、下滑位移、缩放 —— 不用再自己算位移或自转，
         * 也就不会出现"头像转得比卡片快 / 不跟随支点"这类对不齐的问题 ✓
         *
         * 代价是**坐标要改成卡片内部坐标**（相对卡片左上角，不再是浮层坐标）：
         *   · 收起态：卡片自己就是"头像那圈照片"那么大（见 cardClosedW），所以头像在 (0,0) 铺满；
         *   · 展开态：头像停在资讯栏那颗的位置 = `infoAvatar*() - 卡片左上角`。
         * 卡片尺寸/位置在动画里是连续变的，子节点的绝对位置 = 卡片位置 + 本地位移，
         * 所以两端对得上，中间每一帧也就都对得上。
         */
        Image(this.avatarNow().length > 0 ? this.avatarNow() : $r('app.media.startIcon'))
          .id(STORY_FLYING_AVATAR_ID)
          .width(this.avatarOpen ? INFO_AVATAR_VP : this.cardClosedW())
          .height(this.avatarOpen ? INFO_AVATAR_VP : this.cardClosedW())
          .position({
            x: this.avatarOpen ? this.infoAvatarX() - this.cardX() : 0,
            y: this.avatarOpen ? this.infoAvatarY() - this.cardY() : 0
          })
          .borderRadius(this.avatarOpen ? INFO_AVATAR_VP / 2 : this.cardClosedW() / 2)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .backgroundColor('#333333')
          // 收起动画还在播的时候点头像 = 掉头重新展开（需求）。
          .onClick((): void => {
            if (this.closing) {
              this.reopen();
            }
          })
      }
      .width(this.open ? this.cardW() : this.cardClosedW())
      .height(this.open ? this.mediaH() : this.cardClosedW())
      .id(STORY_CARD_ID)
      .position({
        // 收起时卡片就是头像那圈照片，中心对齐（所以子节点 (0,0) 正好落在照片左上角）。
        x: this.open ? this.cardX() : this.startX() + (this.startW() - this.cardClosedW()) / 2,
        y: this.open ? this.cardY() : this.startY() + (this.startW() - this.cardClosedW()) / 2
      })
      .opacity(this.pageAlpha)
      /*
       * 半径：收起时是正圆（`cardClosedW()/2`），展开后是卡片圆角。
       * "圆形蒙版弹出卡片 / 收回圆形蒙版"就是靠**几何**做出来的（不靠透明度变化）。
       */
      .borderRadius(this.open ? CARD_RADIUS_VP : this.cardClosedW() / 2)
      .clip(true)
      // 卡片的底：媒体会盖满它，这一层兜住动画期间（内容还没挂）那一块。
      .backgroundColor(Color.Black)
      // 下滑跟手 + 翻卡片：**只动卡片**（需求："下滑时不要移动蒙版"）。拖出去时底下的遮罩留在原地。
      // 翻卡片是**原地绕竖轴旋转**（不位移不缩放，需求："卡片留在原地然后左旋/右旋翻面"）。
      // `exitScale` 只在"头像不在屏幕"那一路收起时小于 1（非线性收缩下沉滑出，见 slideDownAndClose）。
      .translate({ y: this.dragY })
      .scale({ x: this.exitScale, y: this.exitScale })
      .rotate({ x: 0, y: 1, z: 0, angle: this.flipAngle })
      /*
       * 卡片范围内要**吃掉点击**：不然点它会穿到背后的遮罩上、直接把页面收了
       * （只有遮罩那一层才有 requestClose）。子节点照常先响应。
       * 收起动画还在播的时候点它 = **掉头重新展开**（需求："收起 stories 时点击头像可以立马展开"）。
       */
      .onClick((): void => {
        if (this.closing) {
          this.reopen();
        }
      })
      /*
       * 左右滑切换用户（需求："新增左滑切换下一个用户和右滑切换上一个用户，需要联动翻卡片效果"）。
       *
       * 挂在**卡片**上（横向），下滑收起那条竖着的手势挂在根节点上 —— 方向不同，互不干扰。
       */
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
          .onActionUpdate((event: GestureEvent): void => {
            // **跟手**：手指横滑多少，卡片就转多少（见 swipeFollow）。
            this.swipeFollow(event.offsetX);
          })
          .onActionEnd((event: GestureEvent): void => {
            this.swipeRelease(event.offsetX);
          })
      )
      }
      .width('100%')
      .height(this.clipH > 0 ? this.clipH : this.overlayH)
      .clip(true)

      /*
       * ② 功能区：在**媒体区外面**、卡片下面（需求："媒体区外底部是功能区"）。
       *
       *   [输入框("发消息"，占满剩余宽)] [❤] [💬] [✈]，四者**统一间隔**（Row 的 space）。
       * 宽度和媒体区一样（`cardW()`），左右与卡片对齐 = 需求里的"媒体区和功能区统一宽度"。
       * 它是独立一层（不在卡片的 clip 里），所以媒体区不用为它让出圆角。
       * 同样只在动画结束后挂上来，所以收起/展开时不会在屏幕上乱飘。
       */
      if (this.contentMounted && !this.hideActions) {
        Row({ space: ACTION_GAP_VP }) {
          CommentInputBar({
            hint: $r('app.string.story_message_hint'),
            sideInset: 0,
            bottomInset: 0,
            onSend: (text: string): void => {
              this.onSend(text);
            }
          })
            .layoutWeight(1)

          this.actionButton($r('sys.symbol.heart'), 'like')
          this.actionButton($r('sys.symbol.message'), 'comment')
          this.actionButton($r('sys.symbol.paperplane'), 'share')
        }
        .width(this.cardW())
        .height(ACTION_H)
        .alignItems(VerticalAlign.Center)
        .position({ x: this.cardX(), y: this.cardY() + this.mediaH() + ACTION_TOP_VP })
        .opacity(this.contentAlpha)
        /*
         * 下滑时跟着卡片走（一起收缩）；**翻卡片时功能区不动**（需求："不用动功能区"）。
         * 收起走"掉进口袋"那一路时，动作区**向上融入消失**（需求，像一滴水融进一滩水）：
         * 上移 ACTION_MELT_VP × actionsMelt、淡出、再缩小一点。
         */
        .translate({ y: this.dragY - this.actionsMelt * ACTION_MELT_VP })
        .opacity(this.contentAlpha * (1 - this.actionsMelt))
        .scale({
          x: this.exitScale * (1 - 0.12 * this.actionsMelt),
          y: this.exitScale * (1 - 0.12 * this.actionsMelt)
        })
        // 功能区那一块也要吃掉点击（按钮之间那点缝点到就收页会很烦）。
        .onClick((): void => {
        })
      }
    }
    .width('100%')
    .height('100%')
    // 量偏移要用（见 measureSpace）：这个根节点的 windowOffset 就是浮层坐标的原点。
    .id(STORY_ROOT_ID)
    /*
     * 下滑收起（需求："新增下滑收起 story 页"）。
     *
     * 手势挂在**根这一层**而不是内容里：从画面任何地方往下拖都能收（黑边、卡片上、功能区都行），
     * 而左右半屏那两下是子节点的 onClick，两者不冲突（点就点、拖就拖）。
     * **位移不在这里做**：跟手的位移挂在卡片 / 功能区 / 头像那三层上（见各自的 `.translate`），
     * 遮罩留在原地 —— 需求："下滑时不要移动蒙版"。
     * 这里只留整体淡出。
     */
    .opacity(this.dragAlpha())
    .gesture(
      PanGesture({ direction: PanDirection.Down, distance: 8 })
        .onActionStart((): void => {
          this.dragBegin();
        })
        .onActionUpdate((event: GestureEvent): void => {
          this.dragMove(event.offsetY);
        })
        .onActionEnd((event: GestureEvent): void => {
          this.dragFinish(event.offsetY, event.velocityY);
        })
    )
    .onAppear((): void => {
      /*
       * 先量偏移、下一帧再开始动画。
       *
       * 为什么不能直接 expand()：托盘的矩形是**窗口坐标**，而这里 position 用**浮层坐标**，
       * 得先把根节点自己的 windowOffset 量出来才能换算（实机差 39vp = 状态栏高度，不换算
       * 头像就落在序列头像下方 39vp）。晚一帧（16ms）完全看不出来。
       */
      setTimeout((): void => {
        this.measureSpace();
        /*
         * 量完尺寸**再**挂内容（预构建）：这时卡片和媒体区用的是同一套 `overlayW/H`，
         * 不会差出一截黑边；而且仍在展开动画之前，所以"点开时已经构建好"照样成立。
         */
        if (this.reel.items.length > 0) {
          this.contentMounted = true;
        }
        this.expand();
      }, MEASURE_DELAY_MS);
    })
  }
}
