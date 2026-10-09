/*
/**
 * Instarmony native shell.
 *
 * Instagram's own web client runs in one persistent WebView. The shell keeps
 * that WebView mounted underneath native ArkUI and asks it for feed data through
 * the page bridge, so login, cookies, CSRF state and writes all stay in the
 * web origin.
 *
 * 本文件只做「页面装配 + 会话 / 网页 / 探针 / 播放的交互编排」：
 *   取数流程      viewmodel/FeedViewModel.ets
 *   映射与去重    model/FeedMapper.ets
 *   具体界面      components/*.ets
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
// curves：下沉收缩的补间用系统那套弹簧（springMotion，带过冲，比 EaseOut 更"弹"）。
// uiMaterial：只用来读应用级沉浸光感开关的状态（见 aboutToAppear 的日志）。
// display：量屏宽，底栏胶囊的左右留白按它反算。
import { curves, display, uiMaterial, window } from '@kit.ArkUI';
import {
  HdsAnimationMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigation,
  HdsNavigationMenuContentOptions,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleMode,
  TitleBarStyleOptions,
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  hdsMaterial,
  ScrollEffectType,
  TextStyleMode
} from '@kit.UIDesignKit';
import { AppConfig } from '../config/AppConfig';
import { ApiRegistry, ApiTemplate, DigestResult, ReplayResult } from '../bridge/ApiRegistry';
import { InstagramPageBridge } from '../bridge/PageBridge';
import {
  commentsByStoredCfgScript,
  commentsOnPostPageScript,
  DOM_COMMENTS_PROBE_SCRIPT,
  DOM_SURVEY_SCRIPT,
  followClickScript,
  followStateScript,
  likeOnPostPageScript,
  likeCommentScript,
  likePostScript,  OWN_PROFILE_SCRIPT,
  PROBE_WATCH_ON_SCRIPT,
  repostPostScript,
  saveOnPostPageScript,
  TIMELINE_PROBE_SCRIPT
} from '../bridge/WebScripts';
import { CommentsPanel, CommentsListController, COMMENTS_DRAG_ZONE_VP } from '../components/CommentsPanel';
import { NotificationsPanel } from '../components/NotificationsPanel';
import { FeedList } from '../components/FeedList';
import { FEED_START_OFFSET } from '../components/FeedList';
import { FeedSkeleton } from '../components/FeedSkeleton';
import { InstagramWebHost } from '../components/InstagramWebHost';
import { LoginPanel } from '../components/LoginPanel';
import { ProbePanel } from '../components/ProbePanel';
import { WebChromeBar } from '../components/WebChromeBar';
import { InstagramCookieJar, InstagramCookieSnapshot } from '../core/InstagramCookieJar';
import { MediaPrefetch } from '../core/MediaPrefetch';
import { MediaDownloader } from '../core/MediaDownloader';
import { NativeFollow, FollowResult } from '../core/NativeFollow';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { SaveState } from '../core/SaveState';
import { NativeSave, SaveResult } from '../core/NativeSave';
import { WebTokens } from '../core/WebTokens';
import { EngageSkeleton } from '../core/EngageSkeleton';
import { NativeEngage, EngageResult, EngageState, LIKE_OP, UNLIKE_OP, REPOST_OP, UNREPOST_OP } from '../core/NativeEngage';
import { NativeNotifications } from '../core/NativeNotifications';
import { NativeComments } from '../core/NativeComments';
import { ReelsAction, REELS_ACTION_VERSION } from '../core/ReelsAction';
import {
  AppSettings,
  BAR_HIDE_SINK,
  BAR_HIDE_SYSTEM,
  MATERIAL_LEVEL_ADAPTIVE,
  SEARCH_BOX_COLLAPSED,
  SEARCH_BOX_FOCUS_REQUEST,
  SETTING_BAR_HIDE,
  SETTING_DARK_UI,
  SETTING_MATERIAL_LEVEL,
  SETTING_VIDEO_MUTED
} from '../core/AppSettings';
import { BackdropTone } from '../core/BackdropTone';
// 沉浸光感的档位/类型换算（设定页里的字符串 → hdsMaterial 的枚举，含设备能力降级）。
import { BarChromeModifier, immersiveLevel, immersiveMaterialType, titleScrollEffectType } from '../core/ImmersiveLight';
import { PlatformCap } from '../core/PlatformCap';
import { SettingsPanel } from '../components/SettingsPanel';
import { AppTab } from '../model/AppTab';
import { DeepLink, DeepLinkIntent, DeepLinkRoute } from '../core/DeepLink';
import { CommentItem, CommentsPayload, LikePayload, RepostPayload, SavePayload } from '../model/Comment';
import { FeedMapper } from '../model/FeedMapper';
import { FeedStatus } from '../model/FeedStatus';
import { MediaPost } from '../model/MediaPost';
import {
  FollowClickResult,
  FollowOutcome,
  FollowPageState,
  NotificationsPayload,
  NotifyGroup,
  NotifyItem,
  NotifyPayloadItem
} from '../model/Notification';
import { ProfilePage } from '../components/ProfilePage';
import { SEGMENT_MODE_USER } from '../components/ProfileSegmentBar';
import { DirectPage } from '../components/DirectPage';
import { DirectThreadPage } from '../components/DirectThreadPage';
import { SearchPage } from '../components/SearchPage';
import { StoriesTray } from '../components/StoriesTray';
import { StoryViewer } from '../components/StoryViewer';
import { ReelsPage } from '../components/ReelsPage';
import { Reel } from '../model/Reel';
import { CommentInputBar } from '../components/CommentInputBar';
import { ProfileHeader, ProfilePost, ProfileStreamPage } from '../model/Profile';
import { DirectThread } from '../model/Direct';
import { SearchUser, SearchPost } from '../model/Search';
import { EMPTY_REEL, StoryHeroRect, StoryReel, StoryTray, StoryTrayItem } from '../model/Story';
import { NativeStories } from '../core/NativeStories';
import { StoryCache } from '../core/StoryCache';
import { PROFILE_TAB_POSTS, PROFILE_TAB_REELS, PROFILE_TAB_TAGGED, ProfileViewModel } from '../viewmodel/ProfileViewModel';
import { DirectViewModel } from '../viewmodel/DirectViewModel';
import { DirectThreadViewModel } from '../viewmodel/DirectThreadViewModel';
import { NativeDirect } from '../core/NativeDirect';
import { SearchViewModel } from '../viewmodel/SearchViewModel';
import { ReelsViewModel } from '../viewmodel/ReelsViewModel';
import { ProfileReelsViewModel } from '../viewmodel/ProfileReelsViewModel';
import { MediaDetail, NativeMediaInfo } from '../core/NativeMediaInfo';
import { NativeUserInfo } from '../core/NativeUserInfo';
import { ApiThrottle } from '../core/ApiThrottle';
import { InstagramProbe } from '../probe/InstagramProbe';
import { FeedViewModel } from '../viewmodel/FeedViewModel';

const TAG: string = 'InstarmonyHome';
const DOMAIN: number = 0xFF00;
/** 通知页在 NavPathStack 里的名字（见 destinationBuilder）。 */
const NOTIFICATIONS_PAGE: string = 'notifications';
/** 设定页在 NavPathStack 里的名字（见 destinationBuilder）。 */
const SETTINGS_PAGE: string = 'settings';
/** **用户主页**在 NavPathStack 里的名字（从信息流的资料行点进去，见 destinationBuilder）。 */
const USER_PROFILE_PAGE: string = 'userProfile';
/**
 * **帖子页**在 NavPathStack 里的名字（点某个网格格子进去，见 destinationBuilder）。
 *
 * 这一页把"当前分页的全部帖子"铺成信息流（需求），并**定位到点进去的那一条**
 * —— 数据由 ProfilePage 整份转好放在 core/PostStream 里（见那里的说明）。
 */
const POST_PAGE: string = 'postPage';
/**
 * **视频分页的 Reels 页**在 NavPathStack 里的名字（点「我的」/别人主页**视频那一段**的格子进去）。
 *
 * 需求："用户和我的页面的视频分页点进去是新的页面，采用 reels 模板"。内容就是首页那个
 * ReelsPage（竖向翻页、只播当前那条），数据换成这一分页的视频（见 ProfileReelsViewModel），
 * 标题栏由 HdsNavDestination 给（左上角原生返回键 + 标题 Reels），底部压一层评论输入框
 * （见 CommentInputBar）。
 */
const PROFILE_REELS_PAGE: string = 'profileReels';
/**
 * **搜索页推荐流的 Reels 页**在 NavPathStack 里的名字（需求："把搜索页推荐流实现点击帖子进入
 * 带返回的 reels 页面，底部是评论，点击的帖子显示在第一条，上滑按照浏览 reels 的逻辑运行"）。
 *
 * 和 PROFILE_REELS_PAGE 是同一个界面（ReelsPage + 底部评论输入框 + HDS 标题栏），
 * 只是数据来源不同：一个来自某个人的视频分页，一个来自搜索页的推荐流
 * （见 openSearchReels）。分成两个路由名是为了"返回"与 onShown/onHidden 的记账各自独立。
 */
const SEARCH_REELS_PAGE: string = 'searchReels';
/**
 * **私信会话页**在 NavPathStack 里的名字（点收件箱里的一行进来，见 destinationBuilder）。
 *
 * 这一页是**原生 HTTP** 读消息 + 发消息（`/api/v1/direct_v2/…`，见 core/NativeDirect）——
 * 以前点一行是 `openWeb(thread.threadUrl())`（把隐藏网页导航到私信会话），现在不再需要网页。
 */
const DIRECT_THREAD_PAGE: string = 'directThread';
/**
 * 帖子页每轮最多补几条视频地址（见 Index.loadPostPageVideos）。
 *
 * 每条都要发一次 `/api/v1/media/{id}/info/`（几百毫秒），又不能并发猛打（会被 IG 限流），
 * 所以**串行 + 每轮限量**：进页先补前几条，翻页/重进再补剩下的。
 */
const POST_PAGE_VIDEO_FILLS: number = 6;
/**
 * 一页最多在后台再补几轮（每轮 POST_PAGE_VIDEO_FILLS 条），以及两轮之间的间隔（毫秒）。
 *
 * 见 loadPostPageVideos：一轮 6 条对"一页几十条视频"是不够的，后台接着补两轮（共 18 条上限）
 * 就够覆盖"用户接下来会滚到的那些"；再多就成请求机器了（而且 IG 会限流）。
 */
const POST_PAGE_FILL_ROUNDS: number = 2;
const POST_PAGE_FILL_GAP_MS: number = 1500;
/**
 * 驱动隐藏网页做互动时的超时（毫秒）。
 *
 * 点赞脚本自己最多等 2.5 秒看 aria-label 翻转，评论脚本最多等 9 秒看评论列表渲染，
 * 这里给的是外层上限。
 */
const LIKE_TIMEOUT_MS: number = 12000;
/**
 * 收藏脚本（网页驱动那条，见 saveReelByWeb）的外层上限。
 *
 * 脚本自己最多等 8 秒渲染 + 3 秒等文案翻转，所以外层给到 14 秒 —— 比它长一点，
 * 免得脚本还在等按钮渲染时被外层先掐掉（那样会误报成失败、把乐观翻转回滚）。
 */
const SAVE_TIMEOUT_MS: number = 14000;
/** 「为你推荐」模板的抓取参数：等页面加载的上限、轮询次数与间隔，以及模板名片段。 */
const AYML_OP: string = 'ayml';
const ACTIVITY_URL: string = 'https://www.instagram.com/accounts/activity/';
const AYML_NAV_TIMEOUT_MS: number = 20000;
const AYML_CAPTURE_POLLS: number = 6;
const AYML_CAPTURE_GAP_MS: number = 1200;


/** 探针报告自动落盘的最小间隔（毫秒），见 dumpProbeSilently。 */
const PROBE_DUMP_MIN_INTERVAL_MS: number = 60000;
/**
 * 下拉刷新时"等网页从别处导航回来"的上限与轮询间隔（毫秒）。
 *
 * 隐藏网页在活动页/帖子页时读信息流必定失败；等它回首页再读，比直接放弃（用户看到
 * "拉了一下什么也没发生"）好。上限给 8 秒，超了就照常试一次，由取数流程自己报状态。
 */
const REFRESH_NAV_WAIT_MS: number = 8000;
const REFRESH_NAV_POLL_MS: number = 200;
/** 页面级导航（去帖子页 / 回首页）的等待上限，以及帖子页上读评论的上限。 */
const NAV_READY_TIMEOUT_MS: number = 20000;
/**
 * 深链执行前等"网页宿主就绪"的上限（毫秒）。
 *
 * 冷启动被深链唤起时，网页宿主可能还在建首帧，这时 loadUrl 会被随后的初始化覆盖
 * （表现就是"链接点了没反应"）。给 6 秒：正常冷启动 1~2 秒内就绪，超时就放弃并回首页，
 * 不让用户对着白屏等（见 Index.consumePendingDeepLink / openDeepLinkPost）。
 */
const DEEP_LINK_READY_TIMEOUT_MS: number = 6000;
/** 等网页宿主就绪时的轮询间隔（毫秒）。 */
const DEEP_LINK_READY_POLL_MS: number = 150;
/**
 * 帖子页上读评论的上限。
 *
 * 脚本内部最多等 9 秒等页面自己的评论响应，再最多 6 秒回放一次，所以外层给 20 秒。
 */
/**
 * 帖子页上读评论的上限（毫秒）。
 *
 * **刻意给得短**：实测这一版的 IG 帖子页上，"导航后几秒内注入的那个较大脚本"经常要等到
 * 桥超时都拿不到结果（同一个页面上 15~20 秒后注入的小脚本 8~16ms 就回来了），
 * 而"逼页面去发评论请求"那条路已经被证伪（点击会把页面导航走）。与其让用户对着转圈等
 * 20 秒，不如**快速失败**：读不到就说读不到，正文/评论数照样显示。真正靠谱的是下面那条
 * 回放路径（模板存在原生侧，跨页面可用）。
 */
const POST_PAGE_READ_TIMEOUT_MS: number = 6000;
/**
 * 评论回放快路径的上限（毫秒）。
 *
 * 它只做一件事：用页面里缓存的评论接口模板发一次 fetch（页面里 9 秒自己中止），
 * 失败就退回上面的导航路径 —— 所以上限给得比导航那条短，别让用户白等。
 */
const COMMENTS_REPLAY_TIMEOUT_MS: number = 12000;
/**
 * 回放评论时一次要多少条。
 *
 * 接口默认一页只给 10~20 条；回放的好处之一就是能把这个数直接调大。
 */
const COMMENTS_REPLAY_FIRST: number = 50;
/**
 * 用户没碰过评论列表时，最多自动往后补几页。
 *
 * `onReachEnd` 在"内容还没铺满一屏"时会连着触发（实测一次打开评论 8 秒里连要 10 页），
 * 所以要有个上限；2 页刚好把半屏面板填满，之后完全按用户的滑动来（见 canLoadCommentsMore）。
 */
const COMMENTS_AUTO_FILL_MAX: number = 2;
/**
 * 导航到帖子页之后、注入读评论脚本之前先等多久（毫秒）。
 *
 * pageReady 只代表文档加载完，之后还有水合与视频起播，那几秒主线程满负荷 ——
 * 实测这时注入的脚本连桥超时都排不上队（同一页面晚十几秒再跑的探针脚本 11ms 就回来了）。
 */
const POST_PAGE_SETTLE_MS: number = 900;
/**
 * 网页加载完之后**补一次**接口登记的时间（毫秒）。
 *
 * pageReady 到"页面自己把查询发出去"之间还有水合，搜索页/个人页上实测会晚几秒；
 * 只在那一刻登记会漏掉它们。这个补登记很便宜（一次索引过桥，几 KB）。
 */
const API_INDEX_LATE_SYNC_MS: number = 5000;
/** 探测用：抓这几条 GraphQL 的完整模板来验证"跨文档回放"（见 captureFeedTemplate）。 */
const FEED_TEMPLATE_KEY: string = 'Polaris';/** 评论接口的操作名片段（评论模板按它抓，见 captureCommentTemplate）。 */
const COMMENT_TEMPLATE_KEY: string = 'comment';
/** 评论浮层：面板与输入框之间的间隙（vp）。需求："输入框和面板之间要有间隙"。 */
const COMMENTS_GAP_VP: number = 10;
/**
 * 评论浮层**置中档**占屏幕高度的比例（需求："将评论面板的置中档高度增加到屏幕的 3/5"）。
 *
 * 三档：置中 = 屏幕 × 这个比例、置顶 = 状态栏下方、收起 = 关闭（见 commentsMidVp / commentsMaxVp）。
 */
const COMMENTS_MID_SCREEN_RATIO: number = 3 / 5;
/** 取"全部回复"的兜底超时（ms）：超时就用已经拿到的预览，别让"正在加载回复…"一直挂着。 */
const COMMENTS_REPLIES_TIMEOUT_MS: number = 6000;
/**
 * 评论浮层：左右留白（vp）。
 *
 * 面板和输入框要**等宽**（需求："面板宽度按照评论输入框"），所以两边都不自己留：
 * 由外层容器统一给这一条，面板/输入条各占剩下的整宽。
 */
const COMMENTS_SIDE_VP: number = 12;
/** 评论浮层入场时长（ms）：从屏幕下方滑上来（需求："类似半模态页面的弹出效果"）。 */
const COMMENTS_IN_MS: number = 320;
/** 评论浮层出场时长（ms）：滑下去（下滑 / 返回 / 点面板外面，需求）。 */
const COMMENTS_OUT_MS: number = 220;
/**
 * 先让底栏的原生隐藏动效动起来，再弹评论面板（需求给的顺序：
 * "调用原生隐藏动画隐藏tabbar→弹出评论面板和输入框"）。
 */
const COMMENTS_BAR_LEAD_MS: number = 130;
/**
 * 手势停下多久算"松手"（ms）。
 *
 * 吸附（三档之间）靠列表的 `onScrollStop` / 拖拽的 `onActionEnd` / 触摸抬起；
 * 这几个万一都不来（列表没真正滚动、或者在空白处抬手），再靠这道静默计时兜底。
 */
const COMMENTS_SETTLE_MS: number = 240;
/**
 * "手指还按着"这个判断的有效期（ms）。
 *
 * 静默计时到点时如果手指还按着、而且**刚才还在动**，就再等一等（那是拖到一半停了一下，
 * 不该这时候吸附，更不该顺势收起）。超过这个时长没再动过，就当触摸抬起事件丢了，
 * 照常吸附 —— 免得面板卡在半路。
 */
const COMMENTS_TOUCH_STALE_MS: number = 500;
/**
 * **换档需要拖过两档之间距离的多少**（比例）。
 *
 * 需求："轻滑动的力度太猛" —— 所以不能按"离哪一档近就去哪一档"（那样轻轻一碰就可能窜到顶/收掉）：
 * 必须拖过两档间距的这么多才算真换档，轻滑一律**回到原来那一档**。
 */
const COMMENTS_MOVE_RATIO: number = 0.4;
/** 快速一甩（vp/s）也算换一档：慢拖看距离，快甩看速度。 */
const COMMENTS_FLING_VP_S: number = 800;
/** 吸附动画的弹簧（response 越大越"软"，dampingFraction < 1 会回弹）：需求"要有弹性动画"。 */
const COMMENTS_SETTLE_SPRING_RESPONSE: number = 0.32;
const COMMENTS_SETTLE_SPRING_DAMPING: number = 0.66;
/** 面板拖动时"跟手"的位移上限（vp）：拖到面板本身高度就够了，再多也没有意义。 */
const COMMENTS_DRAG_MAX_VP: number = 420;
/**
 * 从"中间"档往下拖时，整块跟着手指走的**比例**与**上限**（vp）。
 *
 * 需求："下滑优先内部滚动，**禁用外部面板收缩**" —— 所以往下拖时面板不该真的被拉走：
 * 这里只做一点点"橡皮筋"跟手（1/3 阻尼、最多 60vp）当作反馈，松手按**手指实际位移**决定收起。
 * 拉不动、也绝不可能滑到屏幕底部去（之前 1:1 + 大上限，看着就是"滑到底部卡住"）。
 */
const COMMENTS_PULL_DAMP: number = 0.34;
const COMMENTS_PULL_MAX_VP: number = 60;
/**
 * 从"中间"那一档往下拖多少就算**收起**（vp）。
 *
 * 为什么门槛这么低（不是"两档间距的 40%"）：中间档下面已经没有档位了，需求原话是
 * "置中档（最小值）下滑直接收起面板" —— 轻滑也要收，只是留一点余量避免手指抖动误触。
 */
const COMMENTS_CLOSE_MIN_VP: number = 14;

/**
 * 把 vp 夹在 [lo, hi] 之间。
 *
 * 项目里到处在写三目嵌套，评论浮层这段夹取特别多（高度、越界位移都要夹），抽一个出来。
 */
function clampVp(value: number, lo: number, hi: number): number {
  if (value < lo) {
    return lo;
  }
  return value > hi ? hi : value;
}
/**
 * 收藏 / 取消收藏模板的操作名片段（见 captureSaveTemplates）。
 *
 * 一次就能同时命中两条：收藏那条名字含 `save`，取消收藏那条含 `unsave`（也含 `save`）。
 */
const SAVE_TEMPLATE_KEY: string = 'save';
/**
 * 顺手抓评论模板的最小间隔（毫秒）。
 *
 * 它挂在路由变化/加载完成/切页上，网页里一次浏览会连着改好几次路由；节流到 8 秒一次，
 * 既有机会抓到，又不会把桥占住（一次抓取只有十几毫秒、几 KB）。
 */
const COMMENT_CAPTURE_MIN_INTERVAL_MS: number = 8000;

/** 底部 tab 图标大小（fp）。图标之间的间隔不靠它调，靠栏宽 BAR_WIDTH。 */
const TAB_ICON_SIZE: number = 25;
/**
 * 内容层的组件 id：BackdropTone 定时给它拍低分辨率快照，用来侦测底栏/叠字背后的明暗。
 *
 * 拍**内容层**而不是整页：底栏自己也在整页里，拍整页会把栏本身算进"背景"。
 */
const SHELL_CONTENT_ID: string = 'instarmonyShellContent';

/** 底部悬浮 tab 栏的一项。 */
interface TabItem {
  tab: AppTab;
  /** 未选中 / 选中两种图标。 */
  iconNormal: Resource;
  iconSelected: Resource;
  label: ResourceStr;
}

/**
 * 探针入口（标题栏右上角那颗「探针」胶囊）是否显示。
 *
 * **默认关掉**：那是排查/挖接口用的工具，不属于面向用户的界面。需要时把这里改成 `true`
 * 重新编译即可 —— 代码、面板、抓模板/结构摘要/打开页面这些能力全部保留（见 menus 与 ProbePanel）。
 * 界面上的其它入口（页内右上角 more、设定页）都不再暴露探针。
 */
const PROBE_MENU_VISIBLE: boolean = false;

// 搜索框那几套常量（高度、收起来的时机、动画时长）跟着搜索框一起搬进了 SearchPage ——
// 搜索框现在画在那一页里（见 SearchPage 的 searchBoxOverlay），标题栏只管标题和菜单。

// ==========================================================================
// 启动预热
// ==========================================================================

/**
 * 启动预热：**分两阶段**（需求："进入 app 时先获取 feeds 流并缓存，进入 feeds 页后缓存通知
 * 页面、reels、搜索和我的"）。
 *
 * 启动画面本身就是**系统那条启动窗口**（module.json5 的 startWindowIcon，用的就是
 * `resources/base/media/splash_icon.png`）—— 应用里**不再自绘启动页**。
 *
 *   阶段一（挡在首屏上）：只读 feeds 第一页 —— 用户落地就是首页，这一屏必须是现成的；
 *   阶段二（后台、串行、见 warmOtherTabs）：通知 → Reels → 搜索 → 我的。
 */
/** 预热前等会话核对完的上限（毫秒）。 */
const PRELOAD_SESSION_WAIT_MS: number = 3000;
/** 预热 feeds 前等网页就绪的上限（毫秒）。 */
const PRELOAD_PAGE_WAIT_MS: number = 8000;
/**
 * 首屏铺好之后隔多久开始第二阶段（毫秒）。
 *
 * 1.2 秒是留给"首屏自己收尾"的：骨架屏换成内容、第一屏封面开始解码、列表首次布局 ——
 * 这几件事都在 JS/渲染线程上，后台这时候插进来读四个页面只会让首屏更慢。
 */
const WARM_START_DELAY_MS: number = 1200;
/**
 * "用户点开的这一发快拍取数失败"之后隔多久重试（毫秒，见 playStoryAt）。
 *
 * 取 600ms：够让一次瞬时的 Cookie/claim 刷新、网络抖动或一秒级的限流窗口过去，
 * 又不至于让用户对着转圈等太久（浮层已经开着，转圈本来就在）。
 */
const STORY_RETRY_GAP_MS: number = 600;
/**
 * **会话详情自检开关**（诊断用，与 DirectViewModel.SELF_TEST_THREAD 配套）。
 *
 * true = 启动预热跑完顺手让 App 自己读一次私信会话，把结果打进日志。排查期开着，
 * 结论拿到之后两处一起关掉。
 */
const DM_THREAD_SELFTEST: boolean = false;
/** 每步之间隔多久（毫秒）：一次网络 + 一次 JSON 解析（解析在 JS 线程），连着跑会抢滚动。 */
const WARM_STEP_GAP_MS: number = 500;
/** 用户刚滚过就再等一会儿（毫秒）：滚动优先，别在手指动的时候解析 JSON。 */
const WARM_IDLE_MS: number = 400;
/** 等"手停下来"的上限（毫秒）：不能因为用户一直在滑就永远不预热。 */
const WARM_IDLE_MAX_MS: number = 4000;
/**
 * 首屏没有内容时的自动重试：间隔与次数上限。
 *
 * 20 次 × 3 秒 ≈ 最长一分钟 —— 冷启动那几秒网页没就绪是常事，自动试一会儿就够了；
 * 一直失败（例如真断网）时也不能无限刷，一分钟之后停下来，状态行会照旧显示原因。
 */
const FEED_RETRY_GAP_MS: number = 3000;
const FEED_RETRY_MAX: number = 20;
/**
 * 底部标签的图标与文案，**顺序就是显示顺序**，并且和 AppTab 的枚举值一一对应
 * （TAB_ITEMS 的下标直接当 AppTab 用）。
 *
 * 只存字形本身：栏里的项是自己画的（见 tabBarItem），颜色按选中状态给系统自带的
 * tab 图标色，深浅色跟着系统走。label 现在只给占位页当标题用，栏上不显示文字。
 */
const TAB_ITEMS: TabItem[] = [
  {
    tab: AppTab.Home,
    iconNormal: $r('sys.symbol.house'),
    iconSelected: $r('sys.symbol.house_fill'),
    label: $r('app.string.tab_home')
  },
  {
    tab: AppTab.Reels,
    iconNormal: $r('sys.symbol.template'),
    iconSelected: $r('sys.symbol.template_fill'),
    label: $r('app.string.tab_reels')
  },
  {
    tab: AppTab.Direct,
    iconNormal: $r('sys.symbol.paperplane'),
    iconSelected: $r('sys.symbol.paperplane_fill'),
    label: $r('app.string.tab_direct')
  },
  {
    tab: AppTab.Search,
    // 搜索没有对应的 _fill 变体，两个状态用同一个字形、只换颜色。
    iconNormal: $r('sys.symbol.magnifyingglass'),
    iconSelected: $r('sys.symbol.magnifyingglass'),
    label: $r('app.string.tab_search')
  },
  {
    tab: AppTab.Profile,
    iconNormal: $r('sys.symbol.person'),
    iconSelected: $r('sys.symbol.person_fill'),
    label: $r('app.string.tab_profile')
  }
];

/**
 * 悬浮页签离屏幕底边的距离（vp），喂给 barFloatingStyle.barBottomMargin。
 *
 * 栏的高度、圆角、高亮胶囊、沉浸光感材质、以及**上滑隐藏/下拉露出的动画**都由系统算，
 * 这里只给它位置和宽度。
 */
const BAR_REST_BOTTOM: number = 28;
/**
 * 快拍卡片经过栏时，栏"弹一下"的幅度（vp）。
 *
 * 需求："卡片经过时 tabbar 弹一下" + "需要缩放的弹性动画，轻微就行"：所以两样都给一点、
 * 但都很小 —— 只动栏本来就接受的三个布局尺寸（barHeight / barSideMargin / barBottomMargin，
 * 滚动下沉那套用的也是它们），观感是"被砸了一下、轻微缩一下又弹回来"。
 */
const BAR_POCKET_GROW_H: number = 4;
const BAR_POCKET_GROW_W: number = 6;
const BAR_POCKET_DIP: number = 7;
/**
 * 系统栏的高度（vp）。
 *
 * 两个用途：
 *   - 算承载层的高度（见 BAR_LAYER_HEIGHT）；
 *   - **降级档**下当作栏高的基准，再加出让给系统导航条的那一段（见 degradedBarHeight）。
 * 悬浮档**不喂** `barHeight`：栏高、圆角由 HDS 按设计规范自己定（官方示例里也不设），
 * 硬设会干扰它自己的几何（交互形变就是按栏的原始矩形算的）。
 */
const BAR_HEIGHT: number = 60;
/**
 * 栏宽（vp）：底栏的宽度。
 *
 * **图标间隔就靠它调**：栏内 5 项平分栏宽，栏越窄图标越靠拢。想更松就加大。
 */
const BAR_WIDTH: number = 300;
/**
 * 承载栏那一层**额外**留出的高度（vp）：栏上方的余量。
 *
 * 之前这里给的是 44vp（给"按着栏往上扯时材质形变/点光源外溢"留空间）。问题是这一层是
 * **不透明的触摸面**：它是内容层的兄弟节点、又盖在上面，那 44vp 的**透明**区域照样会把
 * 触摸吃掉 —— 用户在那一段上滑不动页面（报的正是"悬浮 tab 上方有部分区域无法滑动"）。
 *
 * 现在只留 5vp：容器刚好把栏（栏高 + 离底距离）包住，栏顶边往上一指头的余量，够材质重新
 * 合成用；再往上就是内容层，滑动照旧。（代价：按着栏往上猛扯时那点形变可能被裁一点点，
 * 但那是拿"整个上方一条滑不动"换来的，不值。）
 */
const BAR_LAYER_HEADROOM: number = 5;
/**
 * **系统显隐**那一档额外再留的高度（vp）：见 barLayerHeight。
 *
 * 那一支的动效会把栏往外带一点，实测会被承载层裁掉一块（用户报的"原生隐藏动画播放时被
 * stack 裁剪"），所以这一档多留。**先给 5 还不够（实测仍被裁），加到 10** —— 下沉收缩
 * 只是原地缩放、不外扩，所以这一档不加。
 */
const BAR_SYSTEM_HIDE_HEADROOM: number = 10;
/**
 * 承载系统栏的那一层的高度 = 栏高 + 离底距离 + 上方余量。
 *
 * 栏画在 Tabs 内部、拿不出来，所以让它单独待在一层里：这一层贴着 Stack 的底、
 * 高度装得下栏并留出余量，内容层是它的兄弟节点，栏的位置变化（含系统那条隐藏动画）
 * 不会碰到内容。
 *
 * 注意：这一层的高度**直接等于"挡住触摸的那一段"**（透明也挡），所以只能按栏的实际
 * 贴边范围来定，见 barLayerHeight()（降级档的栏更高，要跟着算）。
 */
const BAR_LAYER_HEIGHT: number = BAR_HEIGHT + BAR_REST_BOTTOM + BAR_LAYER_HEADROOM;
/**
 * 降级底栏：**完全不加高时**，图标墨迹的底边离屏幕底边的距离（vp）。
 *
 * 这是**实测值**：HDS 的普通页签栏贴着屏幕底边、栏高 60vp 时，图标在栏里居中 ——
 * 中心离底 30vp、墨迹半高约 10vp（TAB_ICON_SIZE 25vp 的符号画出来约 20vp 高），
 * 所以底边约 20vp。避让量要做到"刚好够"（需求），就得从图标**真正**的底边起算，
 * 所以不按公式推、直接按实测写；换设备密度不同会有几 vp 出入，那点余量可以接受。
 * （三次实测：加高 36vp 时底边在 56vp、加高 14vp 时在 35vp、加高 10vp 时在 30vp，
 * 三条都指向"自然落点 ≈ 20vp"。）
 */
const BAR_ICON_BOTTOM_NATURAL: number = 20;
/**
 * 降级底栏：图标底边与底部系统条之间留的空隙（vp）。
 *
 * 需求："图标刚好能避让的高度就行" —— 所以只留一条缝，不按"手感"留大块空白。
 */
const BAR_ICON_CLEARANCE: number = 6;
/**
 * 读不到底部系统条高度时的兜底值（vp）。
 *
 * 取不到就按"有个普通手势条"的量级算，宁可多避一点也别让图标压在系统条上。
 */
const NAV_INDICATOR_FALLBACK: number = 16;
/**
 * 下沉收缩（默认那套）能用的前提：**设备支持悬浮底栏**（API ≥ 23，见 PlatformCap.hasHdsMaterial）。
 *
 * 那套形变动的全是悬浮样式上的参数（栏高 / 左右留白 / 离底距离），低版本设备上栏是普通
 * 页签栏、这些参数一个都不生效 —— 所以降级档下滚动根本不碰底栏（见 onFeedScroll）。
 */

/**
 * 下沉收缩：收缩时**宽度减少**多少 vp。
 *
 * 栏窄了以后几个图标会在更窄的栏里重新平分，图标本身不变、只是间距变紧
 * （用 scaleX 压的话图标会跟着被压扁，所以改的是布局宽度）。取值 60：300 → 240vp。
 */
const BAR_SINK_WIDTH: number = 60;
/** 下沉收缩：收缩时**高度减少**多少 vp（喂给 Tabs 的 barHeight，60 → 45）。 */
const BAR_SINK_HEIGHT: number = 15;
/**
 * 下沉收缩：上滑时栏往下挪多少 vp。
 *
 * 挪的是 `barFloatingStyle.barBottomMargin`（离底距离 28 → 18），**不是**给承载层套
 * translate。早先那版是"整层下沉 + 缩放"，结果栏被撕裂/缺一块：沉浸光感的材质是系统按
 * 组件**原始**位置去取背景再合成的，父节点上的变换它不认，于是材质矩形和栏的圆角胶囊
 * 对不上。改成动栏自己的属性之后，材质永远跟着栏的实际位置重算，怎么滑都不会缺。
 */
const BAR_SINK_DISTANCE: number = 10;
/**
 * 下沉收缩时，**信息层（右侧动作区 + 左下资讯区）跟着下沉**的距离（vp）。
 *
 * 需求："reels 页 tabbar 下沉收缩时所有控件跟着下沉……我需要动作区和资讯区跟随 tabbar 下沉"
 * —— 也就是这两块要跟栏一起往下走，而不是钉在原地。
 *
 * 取 `BAR_SINK_DISTANCE + BAR_SINK_HEIGHT` = 25vp：这是**栏顶边**下沉的距离（离底距离少 10vp、
 * 栏又矮了 15vp）。跟这个量走，信息层底边与栏顶边之间那 24vp 的间距**收缩前后一模一样**，
 * 看着就是"整块一起沉下去"；只跟 10vp（栏底边那点位移）的话，栏矮下去之后两者之间会空出
 * 一截，反而像信息层没跟上。栏收窄（BAR_SINK_WIDTH）不在竖向跟随的范围里 —— 需求只要"下沉"。
 */
const OVERLAY_SINK_DISTANCE: number = BAR_SINK_DISTANCE + BAR_SINK_HEIGHT;
/**
 * **系统显隐**那支：同方向累计滚过这么多 vp 才翻转栏的状态。
 *
 * 为什么累加而不是看单帧：慢速拖动时单帧增量可能只有 1vp 上下，看单帧就永远不触发。
 * 换方向会清零（见 onFeedScrollNative），所以来回抖动不会攒出一次误判。想更灵敏就调小。
 *
 * （下沉收缩**不用**这个死区：它只认"手指动了"这一个事实，见 onSinkRequest。）
 */
const BAR_SCROLL_DEAD_ZONE: number = 24;
/**
 * **系统显隐**那支：列表至少滚过这么多 vp 才允许翻转栏的状态。
 *
 * 两个作用：一是在最顶上不给藏（还没开始看内容，栏保持原样）；
 * 二是挡掉顶部边缘回弹 —— 在顶端下拉再弹回去时 yOffset 会由负回到 0，
 * 那一下在增量上看着是「上滑」，不加这道闸会把栏错误地藏掉。
 */
const BAR_TOP_GUARD_OFFSET: number = 60;
/**
 * 栏显隐翻转之后的冷却期（毫秒）。两套行为共用。
 *
 * 翻转会把列表"顶"一下（栏的位置变了、可视区跟着变），紧接着的几帧增量方向是反的，
 * 正好够把它立刻翻回去。冷却期内一律不认滚动增量，抖动就断了。
 */
const BAR_TOGGLE_COOLDOWN_MS: number = 420;
/**
 * 下沉收缩：点击还原之后的"保护期"（毫秒）。
 *
 * 点击还原要把**这一轮滚动剩下的增量全部作废**，正常靠滚动状态回到 Idle 收尾；
 * 这个时限只是兜底，防止 Idle 一直不来导致栏从此再也不下沉。
 */
const BAR_RESTORE_GRACE_MS: number = 700;
/**
 * 下沉收缩：底栏被点击还原之后的"吞点击"窗口（毫秒）。
 *
 * 一次触摸可能报进来不止一个 tabBar 回调（栏项自己一个、系统栏一个），窗口内的后续回调
 * 只当"把栏捞回来"，不切页。窗口**必须很短**：它只用来吃掉同一次点击的重复回调；
 * 用户下一拍（通常 200ms 以上）就该正常切页了。
 */
const BAR_CLICK_GUARD_MS: number = 120;

/**
 * 读对方主页那颗关注按钮的轮询参数。
 *
 * 主页是分段水合的：`onPageEnd` 时头部按钮常常还没渲染出来，所以要反复读。
 * 12 次 × 700ms ≈ 8 秒，和之前写在页面脚本里的等待上限一致。
 */
const FOLLOW_BUTTON_TRIES: number = 12;
const FOLLOW_BUTTON_POLL_MS: number = 700;
/** 关注流程里每一步注入脚本的超时（毫秒）：每步都是**不做长等待**的短脚本。 */
const FOLLOW_STEP_TIMEOUT_MS: number = 6000;
/** 点完关注后等页面确认的时间（毫秒）。 */
const FOLLOW_SETTLE_MS: number = 1500;

/**
 * 手动兑现的 Promise 外壳。
 *
 * ArkTS 里在 Promise 的 executor 里给外层变量赋值容易踩类型问题，项目里一律用这种
 * 「先建壳、再拿 resolve」的写法（见 bridge/PageBridge 的 DeferredOutcome）。
 */
class DelayStep {
  resolve: (value: string) => void = (value: string): void => {
  };
  promise: Promise<string> = Promise.resolve('');
}

/**
 * **用户主页的路由壳**（NavDestination 的内容，见 Index.destinationBuilder）。
 *
 * 为什么单独一个组件：一个人一份数据，这个壳负责**持有那一个** ProfileViewModel 实例，
 * 并把路由参数（用户名 + 数字 id）设进它。页面本身（ProfilePage）完全复用「我的」页那套 ——
 * 需求："页面使用我的页面那套模板"。
 *
 * 分段：只有三段（帖子 / 视频 / 被提及），需求明确去掉"收藏"（见 setOrder）。
 */
@Component
struct UserProfileRoute {
  /** 路由参数：`用户名|数字id`（见 Index.parseUserParam）。 */
  @Prop param: string = '';
  private vm: ProfileViewModel = new ProfileViewModel();
  /** 打开一条帖子：交给隐藏网页（同「我的」页）。 */
  onOpen: (post: ProfilePost) => void = (post: ProfilePost): void => {
  };
  /** 关注 / 取关这一页的用户（页面那一行按钮的动作，实现在 pages/Index.followUser）。 */
  onFollowUser: (id: string, username: string, follow: boolean) => Promise<boolean> =
    (id: string, username: string, follow: boolean): Promise<boolean> => Promise.resolve(false);
  /** 路由参数里的用户名（头部还没到时的兜底，见 build 里的关注回调）。 */
  private userName: string = '';
  /** 路由参数里的数字 id（关注接口的路径参数）。 */
  private userId: string = '';
  /** 点格子 → 帖子页（见 pages/Index.openPostStream）。 */
  onOpenStream: (posts: Array<MediaPost>, index: number,
                  loadMore: () => Promise<ProfileStreamPage>) => void =
    (posts: Array<MediaPost>, index: number,
     loadMore: () => Promise<ProfileStreamPage>): void => {
    };
  /** 点**视频那一段**的格子 → Reels 页（见 pages/Index.openProfileReels）。 */
  onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                loadMore: () => Promise<ProfileStreamPage>) => void =
    (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
     loadMore: () => Promise<ProfileStreamPage>): void => {
    };
  onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
    };

  aboutToAppear(): void {
    const parts: Array<string> = `${this.param}`.split('|');
    const username: string = parts.length > 0 ? parts[0] : '';
    const userId: string = parts.length > 1 ? parts[1] : '';
    this.userName = username;
    this.userId = userId;
    this.vm.setTarget(userId, username);
    // 三段：帖子 / 视频 / 被提及（没有收藏）。
    this.vm.setOrder([PROFILE_TAB_POSTS, PROFILE_TAB_REELS, PROFILE_TAB_TAGGED]);
    hilog.info(DOMAIN, TAG, 'user profile open @%{public}s id=%{public}s',
      username, userId.length > 0 ? 'y' : 'n');
  }

  build() {
    ProfilePage({
      vm: this.vm,
      segmentMode: SEGMENT_MODE_USER,
      onOpen: (post: ProfilePost): void => {
        this.onOpen(post);
      },
      // 关注 / 取关这一页的用户：id 来自路由参数，用户名以头部为准（拿不到就退回参数里的）。
      onFollowUser: (follow: boolean): Promise<boolean> => {
        const header: ProfileHeader | null = this.vm.headerNow();
        const username: string = header === null ? this.userName : header.username;
        return this.onFollowUser(this.userId, username, follow);
      },
      // 别人主页的格子同样进**帖子页**（需求：所有用户主页都接进去）。
      onOpenStream: (posts: Array<MediaPost>, index: number,
                     loadMore: () => Promise<ProfileStreamPage>): void => {
        this.onOpenStream(posts, index, loadMore);
      },
      // 别人主页**视频那一段**的格子 → Reels 页（需求）。
      onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                    loadMore: () => Promise<ProfileStreamPage>): void => {
        this.onOpenReels(posts, shortcode, hasMore, loadMore);
      },
      onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
        this.onFeedScroll(deltaY, offsetY, scrollState);
      }
    })
  }
}

/**
 * 去掉「帖子的配文被当成评论收进来」的那一条。
 *
 * 配文块与评论块在 DOM 里同形，网页侧无法区分，所以由原生侧按「作者与正文都与配文
 * 完全相同」剔掉 —— 配文本来就已经作为面板第一条单独展示了。
 */
function withoutCaption(items: CommentItem[], post: MediaPost): CommentItem[] {
  if (post.caption.length === 0) {
    return items;
  }
  const out: CommentItem[] = [];
  for (let index: number = 0; index < items.length; index++) {
    const item: CommentItem = items[index];
    if (item.username === post.ownerUsername && item.text === post.caption) {
      continue;
    }
    out.push(item);
  }
  return out;
}

@Entry
@Component
struct Index {
  @State signedIn: boolean = false;
  @State sessionChecked: boolean = false;
  @State bridgeReady: boolean = false;
  @State webVisible: boolean = false;
  @State busy: boolean = false;
  /**
   * 是否已经跑完过至少一轮加载。
   *
   * 用来区分「还在等第一屏」（铺骨架屏）和「加载过了但确实没有内容 / 失败了」
   * （显示空态与加载按钮），避免首屏出现空态一闪。
   */
  @State loadedOnce: boolean = false;
  @State statusText: ResourceStr = '';
  /** 状态行是否显示。ResourceStr 是联合类型，没法直接取 .length 判空，所以单独记。 */
  @State statusShown: boolean = false;
  @State currentUrl: string = AppConfig.INSTAGRAM_HOME_URL;
  @State posts: MediaPost[] = [];
  /**
   * 下拉刷新是否进行中。
   *
   * 与 FeedList 里的 Refresh 组件双向绑定（@Link）：下拉触发后置 true，
   * 刷新这一轮彻底结束后再置 false —— 转圈收起的时机由页面掌握。
   */
  @State refreshing: boolean = false;
  /**
   * 当前选中的标签。
   *
   * 切页由页面按它决定（见 nativeShellContent 的内容层）；Tabs 只当"系统那条栏"用，
   * 不承担切页。会话确认、从帖子页回首页、取数判断都要用到它（见 selectTab）。
   */
  @State selectedTab: AppTab = AppTab.Home;
  /** 当前 tab 下标（和 selectedTab 同步）。栏里的图标高亮、内容层切页都按它判断。 */
  @State selectedIndex: number = 0;
  /**
   * 底栏行为（设定页里的开关，见 AppSettings 的 BAR_HIDE_*）。**只有支持悬浮底栏的设备
   * （API ≥ 23）才用得上**：降级档下栏是普通页签栏，滚动一律不碰它（见 onFeedScroll）。
   *
   *   sink   —— 下沉收缩（默认）：上滑时栏往下挪一截、同时收窄缩矮，始终留在屏幕上；
   *   system —— 系统显隐：调 HdsTabsController 自带的隐藏/显示动效，栏整条收走。
   * 滚动回调按它分流（见 onFeedScroll），换模式时把另一套留下的状态收干净
   * （见 onBarHideModeChanged）。
   */
  @StorageProp(SETTING_BAR_HIDE) @Watch('onBarHideModeChanged') barHideMode: string = BAR_HIDE_SINK;
  /**
   * 下沉收缩的"下沉程度"：0 = 原位，1 = 完全下沉（下沉 BAR_SINK_DISTANCE + 收窄 + 缩矮）。
   *
   * 两态量，中间值全靠弹簧曲线补出来（见 setBarSink）。不做隐藏：栏只是往下沉一截、
   * 缩小一点，始终留在屏幕上。
   */
  @State barSink: number = 0;
  /**
   * 系统显隐：底栏当前是不是已经藏起来了（见 hideBar / showBar）。
   *
   * 只用来**去重**：官方动效接口是"播一次动效"，重复播同一支动效会打断上一支，
   * 滑得慢的时候就成了"一顿一顿"。所以记一份当前状态，只有翻转时才调接口。
   */
  @State barHidden: boolean = false;
  /**
   * 同方向累计的滚动量（vp），到 BAR_SCROLL_DEAD_ZONE 才翻转栏的状态。
   *
   * 不是 @State：它不参与渲染，只是滚动手势的记账本。
   */
  private barScrollPull: number = 0;
  /**
   * 下沉收缩："点击还原优先"的保护期截止时刻（毫秒时间戳，0 = 没有保护期）。
   *
   * 要解决的冲突：feeds 正在往上滑（尤其是惯性还在跑），用户点一下栏想把它捞回来，
   * 可紧接着那几帧的滚动增量又把它蹬下去 —— 看起来就是"点了没用"。
   * 所以点击还原之后，**这一轮滚动剩下的增量一律不认**，一直忽略到滚动停下来
   * （scrollState 回到 Idle）；超时（BAR_RESTORE_GRACE_MS）只是兜底。
   */
  private ignoreScrollUntilMs: number = 0;
  /**
   * 下沉收缩："吞点击"保护期的截止时刻（毫秒时间戳，0 = 没有保护期）。
   *
   * 底栏点击还原之后的一小段时间内，后续点击只当"把栏捞回来"，不切页（见 onTabBarClick）。
   */
  private barClickGuardUntilMs: number = 0;
  /**
   * 栏状态翻转后的冷却期截止时刻（毫秒时间戳，0 = 没有冷却）。两套行为共用。
   *
   * 见 BAR_TOGGLE_COOLDOWN_MS。
   */
  private barToggleCooldownUntilMs: number = 0;
  /**
   * 现在这一次"深色"是不是**我们为 Reels 页强制**的（见 syncReelsColorMode）。
   *
   * 记它是为了离开 Reels 时**只撤销自己做过的事**：没强制过就什么都不做，
   * 强制过才设回 `COLOR_MODE_NOT_SET`（跟系统）。
   */
  private reelsDarkForced: boolean = false;
  /**
   * 正在把 Tabs 的内部下标对齐到 `selectedIndex`。
   *
   * 对齐动作本身可能再报一次点击回调，用它区分"我自己的同步"和"用户的点击"。
   */
  private syncingTabsIndex: boolean = false;
  /** 底部标签「我的」那个原生页面的视图模型（页面一直在，状态留着，切回来不白屏）。 */
  private profileVm: ProfileViewModel = new ProfileViewModel();
  /** Reels 视频流的视图模型（同上：数据留在视图模型里，切 tab 不重拉）。 */
  private reelsVm: ReelsViewModel = new ReelsViewModel();
  /** 私信收件箱的视图模型（同上）。 */
  private directVm: DirectViewModel = new DirectViewModel();
  /** 私信**会话页**的视图模型（一条会话的消息 + 发送，见 DirectThreadViewModel）。 */
  private directThreadVm: DirectThreadViewModel = new DirectThreadViewModel();
  /** 搜索页的视图模型（同上）。 */
  private searchVm: SearchViewModel = new SearchViewModel();
  /**
   * **帖子页**正在显示的那份数据（见 openPostStream / POST_PAGE）。
   *
   * 放在 Index 这一层而不是帖子页自己的组件里：这一页的点赞/转发要走页面已有的那套流程
   * （见 setLikedEverywhere），而那套流程改的是 Index 手里的列表 —— 两边必须是同一份，
   * 否则在帖子页点个赞，心不会变红。
   */
  @State private postPagePosts: Array<MediaPost> = [];
  /** 帖子页打开时要定位到的那一条（FeedMapper.keyOf 的键）。 */
  @State private postPageAnchor: string = '';
  /**
   * 帖子页那位作者**关注了没有**（决定标题栏右上角那颗「关注」出不出现）。
   *
   * 打开这一份数据时按第一条的作者算一次；用户在标题栏点过之后置真（见 postPageMenu）。
   */
  @State private postPageFollowed: boolean = false;
  /** 帖子页那位作者的**数字 id**（关注接口要用；空 = 拿不到，那颗按钮就不出现）。 */
  private postPageAuthorId: string = '';
  /** 帖子页那位作者的**用户名**（关注失败时退回网页驱动那条路要用）。 */
  private postPageAuthor: string = '';
  /**
   * 关注状态的**全局版本号**（见 core/FollowState 的文件头"全局刷新"）。
   *
   * 页面上有两处画着别人的关注状态，而且都是"算一次就定住"的：
   *   ① 帖子页标题栏右上角那颗「关注」（`postPageFollowed`，只有**没关注**时才出现）；
   *   ② 通知列表里那些「回关 / 发消息」按钮（`notifications` 里每个 item 的 `following`）。
   * 在用户主页点了关注之后，这两处不会自己变（用户报的"关注状态没有全局刷新"），
   * 所以盯住这个版本号，变了就一起重算。
   *
   * 值本身不用（读了就够），要的是 @Watch 这一次回调。
   */
  @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
  /**
   * 帖子页"再拉一页"的入口（由 ProfilePage 交出来，见它的 makeStreamLoader）。
   *
   * 有了它，帖子页的翻页和网格的翻页是同一条链路（数据都落在 ProfileViewModel 里）：
   * 帖子页自己滑到底就能往下加载，不必等网格先翻完。
   */
  private postPageLoadMore: (() => Promise<ProfileStreamPage>) | null = null;
  /** 帖子页正在要下一页（防重入 + 尾部转圈）。 */
  @State private postPageLoadingMore: boolean = false;
  /** 帖子页还有没有下一页（**由视图模型给**，见 model/Profile 的 ProfileStreamPage）。
   * 不能用"这次条数有没有变多"来判：翻页可能正被网格占着（那一轮会被记成 wantMore 延后
   * 执行），条数一时没长就被当成"到底了"，帖子页从此加载不动（用户报的"还是只能加载分页中
   * 已加载的帖子"）。这里只认视图模型报的结论。
   */
  private postPageHasMore: boolean = true;
  /**
   * 视频分页那个 **Reels 页**的视图模型（点进去时现造一个，见 openProfileReels）。
   *
   * 每个"某个人的视频分页"一份：数据是进页那一刻带进来的（不必等任何请求），翻页仍然走
   * 那一分页的 ProfileViewModel（见 ProfileReelsViewModel 的文件头）。
   *
   * **默认值是一个空实例**（不是 null）：`@Builder` 里只能写 UI 语法，不能先取个局部变量再判空，
   * 而这个字段在 push 之前一定被 openProfileReels 换掉了 —— 空实例只是让类型非空、永不渲染。
   */
  private profileReelsVm: ProfileReelsViewModel =
    new ProfileReelsViewModel([], '', false,
      (): Promise<ProfileStreamPage> => Promise.resolve(new ProfileStreamPage([], false)));
  /**
   * 帖子页里"已经补过视频地址"的 shortcode（见 loadPostPageVideos；补过就不再补）。
   */
  /**
   * 帖子页这一份是不是**我从自己主页进来的**（标题栏据此一律不显示关注按钮，见 postPageMenu）。
   */
  private postPageFromOwnProfile: boolean = false;
  /**
   * 帖子页里"这一次进页已经请求过详情"的 shortcode（防同一轮里重复请求，进页清零）。
   */
  private videoTried: Set<string> = new Set<string>();
  /**
   * shortcode → **已经取到的那一条详情**（视频 + 多图 + 发布时间 + 头像；跨次进页复用）。
   *
   * 为什么要缓存：`postPagePosts` 每次进页都会被换成新的一份（收藏 / 被标注那两段的数据本来就
   * 不带地址/多图/时间/头像），只记"补过哪些"的话，第二次进来那些帖子又会退回封面一张 ——
   * 而请求其实是不必再发的。
   */
  private mediaDetails: Map<string, MediaDetail> = new Map<string, MediaDetail>();
  /** 帖子页的视频地址补齐**正在跑**（防重入）。 */
  private postPageVideoFilling: boolean = false;
  /** 这一次进帖子页已经在后台补了几轮（上限见 POST_PAGE_FILL_ROUNDS）。 */
  private postPageFillRounds: number = 0;
  /**
   * **搜索页推荐流**那个 Reels 页的视图模型（见 openSearchReels）。
   *
   * 和 profileReelsVm 同一套（ProfileReelsViewModel）：数据是"当前这份推荐列表按点的顺序
   * 重排（点的那条第一）"，翻页继续吃搜索推荐那条游标链。
   */
  private searchReelsVm: ProfileReelsViewModel =
    new ProfileReelsViewModel([], '', false,
      (): Promise<ProfileStreamPage> => Promise.resolve(new ProfileStreamPage([], false)));
  /** 搜索推荐流这一页"点的是哪一条"（重排列表时要用；换页/重进时重设）。 */
  private searchReelsAnchor: string = '';
  /**
   * 搜索推荐流这一页**当前的播放顺序**（shortcode 的列表，见 orderSearchReels）。
   *
   * 需求："上滑下一条视频是推荐流的第一条视频，我想要做成随机的" —— 顺序在这里定一次、
   * 之后不再重洗（理由见 orderSearchReels 的说明）。
   */
  private searchReelsOrder: Array<string> = [];
  /**
   * 现在压着几层整屏页面（NavDestination），以及最上面那层是谁（见 onPageShown/onPageHidden）。
   *
   * 为什么需要：**压上一整屏页面之后，下面那一页的可见性回调不会变**（列表还在布局里、比例
   * 也没变），所以首页信息流里正在播的视频会继续播、继续出声，帖子页里的也一样
   * —— 用户报的"主页进入用户页面和帖子页面没有自动停止播放"就是这个。
   *
   * `coveringPages > 0` = 首页那份 FeedList 不该播（`active=false`）；
   * `topPage === POST_PAGE` = 帖子页那份 FeedList 才该播（它被用户主页压住时同样要停）。
   */
  @State private coveringPages: number = 0;
  @State private topPage: string = '';

  /** 某一层整屏页面**显示出来了**（HdsNavDestination 的 onShown）。 */
  private onPageShown(name: string): void {
    /*
     * **整屏页面压上来之前，先让评论浮层让位。**
     *
     * 浮层是根 Stack 里的一层（`zIndex(70)`，见 commentsOverlay），NavDestination **压不住它**：
     * 面板开着的时候推进任何整屏页面（用户主页 / 帖子页 / 设置…），面板都会**继续画在新页面
     * 上面** —— 用户报的"feeds/reels 类页面进入用户页面后评论面板会弹出"就是这个
     * （在帖子页开着评论，再去点头像就能复现）。
     *
     * 之前只有"在评论里点头像"那条路会挂起（见 openUserFromComments），别的入口一律漏掉；
     * 这里挂成**兜底**：任何整屏页面压上来都让它让位，页面关掉时再放回来
     * （见 onPageHidden 的 commentsSuspendBase）。
     *
     * 必须**在计数之前**调：挂起基准 = 这一页压上来之前的层数，返回时正好回到那一层。
     * 这里不播收起动画而是立刻藏（页面已经在推了，动画期间会给"面板压在新页面上"留几帧）。
     *
     * **返回时也会走这里**（下面那一层被盖住时 `onHidden` 已经从 `shownPages` 里摘掉了，
     * 返回时再 `onShown` 一次，看起来就像"新的一页"）。那种情况绝不能挂起：顺序上
     * `onPageHidden`（先把面板放回来）可能正好在它前面，再挂一次就等于"回来时面板又没了"。
     * 判据用的是**导航栈深度**（`navStack.size()`）：深度变大 = 真的压上来新的一页；
     * 变小或不变 = 返回时又显示出来的那一层。不能拿 `shownPages` 判 —— 被盖住的那一层
     * 早就在 `onHidden` 里被摘出去了，返回时看着也是"没见过的名字"。
     */
    const depth: number = this.navDepthNow();
    if (depth > this.navDepth) {
      this.suspendCommentsForPages();
    }
    this.navDepth = depth;
    this.topPage = name;
    // 同一层重复 onShown（返回时也会来一次）不该把计数堆上去。
    if (this.shownPages.indexOf(name) < 0) {
      this.shownPages.push(name);
      this.coveringPages = this.shownPages.length;
    }
    // Reels 类的整屏页面（视频分页 / 搜索推荐进的那一页）要**整页走深色**（见 syncReelsColorMode）。
    this.syncReelsColorMode();
  }

  /** 某一层整屏页面**被盖住/关掉了**（HdsNavDestination 的 onHidden）。 */
  private onPageHidden(name: string): void {
    const at: number = this.shownPages.indexOf(name);
    if (at >= 0) {
      this.shownPages.splice(at, 1);
      this.coveringPages = this.shownPages.length;
    }
    // 关掉的正好是最上面那层：把"谁在最上面"清掉（返回时下面那层的 onShown 会重新写上）。
    if (this.topPage === name) {
      this.topPage = '';
    }
    /*
     * 覆盖层数回到"挂起时那一层"：把评论浮层接回来（需求："不要收起评论面板"）。
     *
     * 判据是 `coveringPages <= commentsSuspendBase`（不是"所有页面都关了"：
     * 面板可能是在帖子页 / Reels 页上开着的，回到那一页就该弹回来，见 commentsSuspendBase）。
     */
    if (this.commentsSuspendBase >= 0 && this.coveringPages <= this.commentsSuspendBase) {
      this.resumeCommentsAfterProfile();
    }
    // 离开 Reels 类页面：把配色交回系统（浅色模式就该恢复浅色，见 syncReelsColorMode）。
    this.syncReelsColorMode();
  }

  /** 现在显示着的整屏页面（顺序 = 压栈顺序；见 onPageShown）。 */
  private shownPages: Array<string> = [];
  /**
   * 上一次看到的**导航栈深度**（见 onPageShown）。
   *
   * 只用来分清"压上来新的一页"和"返回时又显示出来的那一层"：`shownPages` 那套是按**名字**
   * 记账、被盖住就摘掉，分不出这两种情况；深度增加才是真的压栈。
   */
  private navDepth: number = 0;

  /** 当前导航栈深度（拿不到给 -1，调用方按"没变化"处理）。 */
  private navDepthNow(): number {
    try {
      return this.navStack.size();
    } catch (error) {
      return -1;
    }
  }
  /** 帖子页下拉刷新用的状态（这一页没有可刷新的东西，占位给 FeedList 的 `$refreshing`）。 */
  @State private postPageRefreshing: boolean = false;
  /** 上一次自动抓评论模板的时刻（节流用，见 captureCommentTemplate）。 */
  private lastCommentCaptureMs: number = 0;
  /** 上一次探针自动落盘的时刻（节流用，见 dumpProbeSilently）。 */
  private lastProbeDumpMs: number = 0;
  /** 屏幕宽度（vp）：底栏胶囊的左右留白按它反算（见 barSideMargin）。 */
  private screenWidthVp: number = 0;
  /**
   * 沉浸光感的材质等级（设定页里的四档，见 AppSettings 的 MATERIAL_LEVEL_*）。
   *
   * 底栏的悬浮材质、标题栏和导航项的材质都读它 —— 这就是"全局沉浸光感"的开关。
   * @Watch 只是记账（改档时打一行日志便于定位），重绘由 @StorageProp 自己触发。
   */
  @StorageProp(SETTING_MATERIAL_LEVEL) @Watch('onMaterialLevelChanged') materialLevel: string =
    MATERIAL_LEVEL_ADAPTIVE;
  /**
   * 当前界面是不是深色（由 AppSettings.refreshTheme 写进 AppStorage）。
   *
   * 页面本身不靠它上色（颜色都走资源，系统自己换），**只有标题栏的滚动效果类型**要按它分档：
   * 浅色模式下不能用 `IMMERSIVE_GRADIENT_BLUR`（会把标题文字刷成白色 → 最顶上白字压白底，
   * 见 titleScrollEffectType）。用 @StorageProp 是**订阅**：系统切深浅色时这一层会重绘，
   * 标题栏样式才会跟着换（不然要等下一次别的重建）。
   */
  @StorageProp(SETTING_DARK_UI) @Watch('onThemeChanged') isDarkUi: boolean = true;
  /**
   * 搜索框**收起来了没有**（需求："上滑搜索框收缩成按钮到右上角，点击或者回到顶部时才展开"）。
   *
   * 真相在 SearchPage（只有它知道内容滚到哪了，见那边的 trackSearchBox）；这一层只是**订阅**
   * 一个事实：收起时标题栏右上角的菜单里换成一颗放大镜按钮（见 menus）。
   * 点那颗按钮 = 写 `SEARCH_BOX_COLLAPSED=false` + 一个变化的 `SEARCH_BOX_FOCUS_REQUEST`，
   * 页面据此把搜索框放出来并要焦点（输入法随之起来）。
   */
  @StorageProp(SEARCH_BOX_COLLAPSED) searchBoxCollapsed: boolean = false;

  /**
   * 系统明暗变了：如果**正停在 Reels 上**，要重新判定一次（见 syncReelsColorMode）。
   *
   * 场景：用户停在 Reels 页时把系统从深色切成浅色 —— 没有切页事件，得靠这个 @Watch
   * 把"Reels 要深色"重新落实一次。反过来（浅→深）也走这里，而那种情况本来就该是深色，
   * syncReelsColorMode 里会自然什么都不做；两边都不会来回抖（它只在需要时改一次配置）。
   */
  private onThemeChanged(): void {
    this.syncReelsColorMode();
  }
  /**
   * 屏幕底部那一条**系统占位**的高度（vp）：手势条 / 三键导航条都算（见 readBottomSafeVp）。
   *
   * **降级底栏**用它避让（见 degradedBarInset）。设备支持悬浮样式（API ≥ 23）时，栏的位置
   * 由 `barFloatingStyle.barBottomMargin` 决定、它自己就躲开了系统条，这个值用不上。
   */
  @State private bottomSafeVp: number = NAV_INDICATOR_FALLBACK;
  /**
   * 顶部状态栏那一条的高度（vp，见 readBottomSafeVp）。
   *
   * 用途只有一个：评论浮层"上滑加高"的**上界** —— 加高到状态栏下方就停
   * （见 commentsMaxVp）。取不到时按 28vp 的常见量级兜底。
   */
  @State private topSafeVp: number = 28;
  @State probeVisible: boolean = false;
  /** 视频静音（全局；标题栏那颗 reels 喇叭键改它）。 */
  @StorageProp(SETTING_VIDEO_MUTED) videoMuted: boolean = false;
  /**
   * 标题栏那两颗 Reels 按钮（静音 / 下载）的**版本号**。
   *
   * 值本身没用：要的是"ReelsPage 报了一次当前条"这件事引起重绘（`@StorageProp` 才有订阅）。
   * 具体某一页该显示什么由 `ReelsAction.visibleFor(来源)` 决定（见 core/ReelsAction 的说明：
   * 三个 reels 类页面各存一份，免得下载按钮下到另一条视频）。
   */
  @StorageProp(REELS_ACTION_VERSION) reelsActionVersion: number = 0;
  /** 通知页的数据：抓回来的条目、是否在读、读不到时的原因与诊断。 */
  @State notifications: NotifyItem[] = [];
  /**
   * 通知数据是走哪条路来的（`native` / `web` / `none`）——**只进日志，不进界面**。
   *
   * 原来它是 `@State`：写它会让整页重算一遍，而它只在几行 hilog 里用到
   * （标题栏那个 `通知 native·42` 的临时后缀已经删掉了，见审计 F2）。
   * 改成普通字段：日志照旧，少一次无意义的重渲染。
   */
  private notifySrc: string = '';
  @State notificationsLoading: boolean = false;
  @State notificationsState: string = '';
  @State notificationsDiag: string = '';
  /**
   * 现在屏幕上这份通知是**存档**的话，这里是存档时间（毫秒）；实时数据则为 0。
   *
   * 面板据此在列表上方提示"先显示上次的存档，正在刷新" —— 免得用户以为这就是最新的。
   */
  /**
   * 通知页原生下拉刷新的动画状态：取数期间一直为 true（用户看得见"正在取数据"），
   * 用户自己下拉时由 Refresh 置 true 并回调 onRefresh（见 NotificationsPanel）。
   */
  @State notificationsRefreshing: boolean = false;
  /** 通知取数是否正在跑（挡住重入：并发导航隐藏网页会互相打断）。 */
  private notificationsBusy: boolean = false;
  /** 正在去网页抓 ayml 模板（挡住并发抓取：两个页面同时导航会互相打断）。 */
  private aymlCapturing: boolean = false;
  /** 隐藏网页 DOM 探针的报告文本（诊断面板显示 / 可复制 / 可落盘）。 */
  @State probeText: string = '';
  /** 评论面板：是否可见、是否还在等网页渲染、读回来的评论、以及读不到的原因。 */
  @State commentsVisible: boolean = false;
  @State commentsLoading: boolean = false;
  @State comments: CommentItem[] = [];
  /**
   * 评论没读出来时的原因，交给面板映射成文案：
   * ''（无内容）/ 'not-found'（网页没渲染这条帖子）/ 'failed'（其它失败）。
   */
  @State commentsState: string = '';
  /** 配文与作者：配文作为面板第一条展示（与图上一致），评论读不到时也还能看到正文。 */
  @State commentsOwner: string = '';
  @State commentsCaption: string = '';
  /** 作者头像（信息流里就有，直接用，省得评论面板自己再去找）。 */
  @State commentsAvatar: string = '';
  /** 网页结构摘要，读不到评论时显示出来便于定位。 */
  @State commentsDiag: string = '';
  /**
   * 这次评论面板对应的**媒体数字 id**：给评论点赞时私有 API 那条候选要用
   * （见 core/NativeComments.like）。空 = 只试网页那条 REST。
   */
  private commentsMediaId: string = '';
  /** 正在点赞的评论 pk（防连点：同一条在处理中就忽略后续点击）。 */
  private commentLiking: Array<string> = [];
  /** 这次评论面板对应的那条帖子（网页驱动兜底要导航到它，见 likeCommentOnWeb）。 */
  private commentsPost: MediaPost | null = null;
  /** 同上，只要 shortcode（脚本与日志用）。 */
  private commentsShortcode: string = '';
  /**
   * 评论翻页：下一页游标 + 还有没有下一页（触底加载，需求："没有加载全部评论，
   * 做一个触底加载功能"）。游标来自数据源（REST 的 next_max_id / GraphQL 的 end_cursor）。
   */
  @State commentsNextId: string = '';
  @State commentsHasMore: boolean = false;
  @State commentsLoadingMore: boolean = false;
  /** 用户碰过评论列表没有（区分"真的滑到底"和"刚打开还没铺满"，见 canLoadCommentsMore）。 */
  private commentsTouched: boolean = false;
  /** 用户没碰过列表时已经自动补了几页（上限 COMMENTS_AUTO_FILL_MAX）。 */
  private commentsAutoLoads: number = 0;
  /** 正在要下一页（防重入：onReachEnd 会连着触发好几次）。 */
  private commentsMoreBusy: boolean = false;
  /**
   * 正在点赞的帖子 key 集合。   *
   * 原来是**一个**字符串：只要有一条还没跑完，后面所有点赞都被直接丢掉 —— 而一条点赞
   * 可能走「导航到帖子页再点」那条慢路径（十几秒），这期间用户点谁都没反应，看起来就是
   * 「点赞很卡」。改成按帖子记：同一个帖子在处理中仍然挡住（避免把一次赞点成两次翻转），
   * 但不同帖子互不影响。
   */
  private likingKeys: Set<string> = new Set<string>();
  /**
   * 正在关注/取关的账号（小写用户名）集合。
   *
   * 和点赞同一个道理：关注要真导航一次网页（去对方主页、点完再回首页），是秒级的，
   * 这期间同一颗按钮上的第二次点击必须挡住（否则乐观翻转 + 两次点击会算出错误的目标），
   * 但不同账号互不阻塞。用集合而不是单个布尔，是为了以后在推荐列表里连点多个也不打架。
   */
  private followingKeys: Set<string> = new Set<string>();
  /**
   * 正在转发的帖子 key 集合（与点赞分开：两个操作互不阻塞）。
   */
  private repostingKeys: Set<string> = new Set<string>();
  /**
   * 正在为互动临时导航网页（去帖子页 / 回首页）。
   *
   * 这期间信息流不在页面上，触底翻页必定失败，所以用它挡住取更多，避免无谓的失败日志。
   */
  private navigating: boolean = false;
  private bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private viewModel: FeedViewModel = new FeedViewModel();
  private lastSessionState: boolean = false;
  /**
   * 信息流列表的滚动控制器。
   *
   * HdsNavigation 的 bindToScrollable 需要拿到内容的滚动容器才会接管标题栏的
   * 滚动效果，所以这里建一个、同时交给 FeedList 用在 List 上。
   */
  private feedScroller: Scroller = new Scroller();
  /**
   * 信息流离开时停在哪一条（帖子 key）。
   *
   * 切 tab 会把内容层销毁重建（List 是新实例、从顶端开始），所以位置要**页面这一层记着**：
   * FeedList 上报可见区第一条的 key，重建时按它滚回去（见 FeedList.restoreAnchor）。
   */
  private feedAnchorKey: string = '';
  /**
   * 系统 tab 栏（HDS 的 HdsTabs）的控制器。
   *
   * 底栏用**官方的 HDS 底部页签**（HdsTabs）：
   *   - 悬浮胶囊样式与沉浸光感材质等级（systemMaterialEffect）走这条接口，
   *     等级与标题栏同源（设定页「材质等级」，见 immersiveLevel）；
   *   - 上滑隐藏 / 下拉露出的**官方动效**就在这个控制器上
   *     （applyHideAnimation / applyShowAnimation，见 onFeedScroll）。
   *   注：HDS 这层材质**没有反色字段**（hdsMaterial 里没有 invert 接口），所以页签图标不会
   *   随背景自动取反色；要反色得换回原生 Tabs 的 `systemMaterial({colorInvert: true})`。
   */
  private tabsController: HdsTabsController = new HdsTabsController();
  /**
   * 原生页面栈。
   *
   * 通知页这类"整屏页面"走 NavDestination（见 destinationBuilder），而不是弹模态：
   * 模态（bindContentCover）的内容区到不了屏幕最底，底部会露出主页一条（实测绘过三种撑法
   * 都不行）。NavDestination 是页面级承载，安全区和底部由它负责。
   */
  private navStack: NavPathStack = new NavPathStack();
  /**
   * 当前分页（标题栏的标题与菜单都按它取，见 pageTitle / menus）。
   *
   * 单独一个方法：下标越界或没选时统一退回 Home，标题、菜单、内容层三处的判断不会各写一遍。
   */
  private currentTab(): AppTab {
    if (this.selectedIndex >= 0 && this.selectedIndex < TAB_ITEMS.length) {
      return TAB_ITEMS[this.selectedIndex].tab;
    }
    return AppTab.Home;
  }

  /**
   * 标题栏的标题：**跟着当前分页走**。
   *
   * 首页（信息流）用应用名，其余页用页面自己的标题（和页内那颗大图标下面的文字一致），
   * 这样切页时标题栏和页面是同一个名字。
   */
  private pageTitle(): ResourceStr {
    return this.currentTab() === AppTab.Home
      ? $r('app.string.app_title')
      : TAB_ITEMS[this.selectedIndex].label;
  }

  /**
   * 标题栏右上角的菜单：**每个分页各自独立**。
   *
   *   Home（主页）    → 刷新 + 探针：这两个是刷新页面 / 排查问题用的，留在首页；
   *   我的（Profile） → 退出登录；
   *   其余分页        → 空（Reels / 私信 / 搜索还没有原生实现，先不摆不属于本页的按钮）。
   *
   * 做成**方法**而不是字段：字段只在组件创建时求值一次，菜单不会跟着 selectedIndex 变；
   * 方法在每次 build 时求值，切页自然就换了一组按钮。
   */
  private menus(): HdsNavigationMenuContentOptions {
    const tab: AppTab = this.currentTab();
    if (tab === AppTab.Profile) {
      // 「我的」页自己的动作绑到标题栏菜单上（页内右上角那颗 more 按钮保留，两处都能进设定）。
      return {
        value: [
          {
            content: {
              icon: $r('sys.symbol.more'),
              label: $r('app.string.action_settings'),
              action: (): void => {
                this.openSettings();
              }
            }
          }
        ]
      };
    }
    if (tab === AppTab.Home) {
      // 从左到右：通知（爱心）/ 上传（加号）；探针入口默认**不显示**（见 PROBE_MENU_VISIBLE）。
      const items: Array<HdsNavigationMenuItemOptions> = [];
      if (PROBE_MENU_VISIBLE) {
        items.push({
          content: {
            // 探针入口是文字胶囊按钮：用文字样式（TextStyleMode.NORMAL）
            // 保持「看得见字」，而不是去猜一个图标。
            label: $r('app.string.probe_title'),
            type: TextStyleMode.NORMAL,
            action: (): void => {
              this.openProbe();
            }
          }
        });
      }
      items.push({
        content: {
          icon: $r('sys.symbol.heart'),
          label: $r('app.string.notifications'),
          action: (): void => {
            this.openNotifications();
          }
        }
      });
      items.push({
        content: {
          icon: $r('sys.symbol.plus'),
          label: $r('app.string.action_create'),
          action: (): void => {
            this.openCreatePost();
          }
        }
      });
      return { value: items };
    }
    if (tab === AppTab.Reels) {
      // reels 的两颗按钮放在**标题栏**（需求）：标题栏是官方支持沉浸光感的区域，
      // 而且不遮挡视频画面。当前这条的原视频地址由 ReelsPage 报进来（见 core/ReelsAction）。
      return this.reelsMenu(ReelsAction.HOME);
    }
    if (tab === AppTab.Search) {
      // 「搜索」页：搜索框收起来之后，右上角这颗放大镜就是"把它叫回来"的按钮
      // （需求："收缩成按钮到右上角，点击……才展开"）。展开着的时候标题栏里已经有完整的
      // 搜索框，这里不摆多余的按钮。
      if (!this.searchBoxCollapsed) {
        return { value: [] };
      }
      return {
        value: [
          {
            content: {
              icon: $r('sys.symbol.magnifyingglass'),
              label: $r('app.string.search_action'),
              action: (): void => {
                // 展开**并进入输入模式**（需求）：页面收到这个请求就把搜索框放出来、要焦点，
                // 输入法随之起来（见 SearchPage.onFocusRequested）。
                // 写一个**变化的值**而不是布尔：连点两次也要各弹一次。
                AppStorage.setOrCreate(SEARCH_BOX_COLLAPSED, false);
                AppStorage.setOrCreate(SEARCH_BOX_FOCUS_REQUEST, Date.now());
              }
            }
          }
        ]
      };
    }
    return { value: [] };
  }

  /**
   * 关注 / 取关某位作者（信息流「关注」按钮）。
   *
   * 两条路：
   *   ① **HTTP 直发**（core/NativeFollow）：`POST /api/v1/friendships/create|destroy/{id}/`，
   *      会话头复用信息流模板里真机抓到的那份（Cookie + csrftoken + x-ig-app-id + UA）。
   *      判据很严：响应体里必须真的有 `friendship_status`（IG 对不认识的请求会回 200 + HTML，
   *      只看 HTTP 码会把"没成功"报成成功 —— 用户反馈的"点了没触发关注"就是这个）。
   *   ② ①失败且是**关注**动作时，退回已经跑通的**网页驱动**路径（followAccount：打开对方主页
   *      → 找到并点它的关注按钮 → 读回真实状态），保证点了真的能关注上。
   *      取关没有这条退路 —— 网页的取关要走「已关注」→ 菜单里的「取消关注」，脚本点不出菜单
   *      （见 followAccount 的注释），所以取关只认 HTTP 的结果。
   */
  private async followAuthor(post: MediaPost, follow: boolean): Promise<boolean> {
    return await this.followUser(post.ownerId, post.ownerUsername, follow);
  }

  /**
   * **按用户**关注 / 取关（信息流卡片那颗按钮、用户主页那一行、帖子页标题栏那颗都走它）。
   *
   * 两条路（和原来一样，只是入参从"帖子"换成了"用户"）：
   *   ① HTTP 直发（core/NativeFollow）：路径参数要的是**数字 id**；以服务端确认的状态为准
   *      （私密账号可能回 following=false），成功就记进会话级覆盖表 `FollowState`；
   *   ② ①失败且是**关注**动作时，退回网页驱动（打开对方主页点它自己的关注按钮、读回状态）。
   *      取关没有这条退路（网页的取关要走菜单，脚本点不出来），所以取关只认 HTTP 的结果。
   */
  private async followUser(id: string, username: string, follow: boolean): Promise<boolean> {
    const name: string = username.length > 0 ? username : 'instagram';
    const result: FollowResult = await NativeFollow.setFollowing(id, follow);
    if (result.ok) {
      // 以服务端确认的状态为准（有时候 create 会回 following=false，比如对方是私密账号）。
      // 同时记进会话级覆盖表：切页/刷新重建列表时，接口那份旧快照不会再把它顶回去。
      FollowState.remember(id, username, result.following);
      this.setLocalStatus(result.following
        ? $r('app.string.follow_done')
        : $r('app.string.unfollow_done', name));
      return result.following === follow;
    }
    hilog.warn(DOMAIN, TAG, 'native follow failed (%{public}s), fallback=%{public}s',
      result.detail, follow ? 'web' : 'none');
    if (!follow) {
      this.setLocalStatus($r('app.string.follow_failed'));
      return false;
    }
    // 退回网页驱动：它自己会导航、等按钮、点击、读回状态，最后回信息流。
    const outcome: FollowOutcome | null = await this.followAccount(name);
    if (outcome !== null && outcome.following) {
      FollowState.remember(id, username, true);
      this.setLocalStatus($r('app.string.follow_done'));
      return true;
    }
    this.setLocalStatus($r('app.string.follow_failed'));
    return false;
  }

  /**
   * reels 类页面标题栏右上角那两颗按钮：**静音（左）+ 下载（右）**。
   *
   * 需求："除了底栏 reels，其他 reels 页面右上角没有静音和下载按钮，添加一下" ——
   * 所以这一份做成了按**来源**取用（见 core/ReelsAction）：底栏那页、用户主页视频分页那页、
   * 搜索推荐进的那页各存一份状态，标题栏只读自己那一份，下载才不会下到另一条视频。
   *
   * 没东西可播（`visibleFor` 为假）时整组按钮不出现 —— 空着两颗点不动的按钮反而让人以为坏了。
   */
  private reelsMenu(source: string): HdsNavigationMenuContentOptions {
    /*
     * **先读一次版本号**（判据恒假，只为"注册依赖"）。
     *
     * 这两颗按钮的显隐来自 `ReelsAction.visibleFor`（AppStorage），而 AppStorage 的读取
     * **不是可观察量**：不读一个 @StorageProp 的话，ReelsPage 那边 publish 完，标题栏不会重绘，
     * 于是按钮一直不出现（实测：进 reels 页后标题栏右上角空的，切一次别的 tab 再回来才有）。
     * 版本号就是为这件事准备的（见 core/ReelsAction），读一下它，发布那一下就能把标题栏刷新。
     */
    if (this.reelsActionVersion < 0) {
      return { value: [] };
    }
    if (!ReelsAction.visibleFor(source)) {
      return { value: [] };
    }
    return {
      value: [
        {
          content: {
            icon: this.videoMuted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker_wave_2'),
            label: $r('app.string.action_mute'),
            action: (): void => {
              AppSettings.setVideoMuted(!this.videoMuted);
            }
          }
        },
        {
          content: {
            icon: $r('sys.symbol.arrow_down_to_line'),
            label: $r('app.string.action_download'),
            action: (): void => {
              this.downloadReel(source);
            }
          }
        }
      ]
    };
  }

  /**
   * 下载某个 reels 页当前这条的原视频（标题栏那颗按钮的动作）。
   *
   * 地址由那个页面的 ReelsPage 通过 ReelsAction 报上来（原始视频，不是降级后的展示地址）。
   */
  private downloadReel(source: string): void {
    const url: string = ReelsAction.urlFor(source);
    if (url.length === 0) {
      return;
    }
    const host: common.Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    MediaDownloader.save(host as common.UIAbilityContext, url, 'mp4',
      ReelsAction.titleFor(source), true).then((ok: boolean): void => {
      this.toast(ok ? $r('app.string.media_saved') : $r('app.string.media_save_failed'));
    }).catch((): void => {
    });
  }

  /**
   * Reels 页右侧那颗心的动作：**HTTP 直发**（需求："点赞和转发按钮通过 http 请求实现功能"）。
   *
   * 走的是和首页卡片同一条路（core/NativeEngage）：成功之后再把状态落到**别的列表**上
   * （信息流 / 帖子页里可能也有这一条，见 setLikedEverywhere），这样返回列表时那颗心也是红的。
   */
  private async likeReel(reel: Reel, like: boolean): Promise<boolean> {
    const id: string = reel.mediaId;
    if (id.length === 0) {
      this.toast($r('app.string.like_failed'));
      return false;
    }
    const result: EngageResult = await NativeEngage.setLiked(id, like);
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'reel like failed (%{public}s) id=%{public}s', result.detail, id);
      this.toast($r('app.string.like_failed'));
      return false;
    }
    this.setLikedEverywhere(`sc:${reel.shortcode}`, result.state);
    return true;
  }

  /** Reels 页那颗转发按钮的动作：同样 HTTP 直发（取消转发要 note_id，见 core/NativeEngage）。 */
  private async repostReel(reel: Reel, repost: boolean): Promise<boolean> {
    const id: string = reel.mediaId;
    if (id.length === 0) {
      this.toast($r('app.string.repost_unsupported'));
      return false;
    }
    const result: EngageResult = await NativeEngage.setReposted(id, repost);
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'reel repost failed (%{public}s) id=%{public}s', result.detail, id);
      this.toast($r('app.string.repost_unsupported'));
      return false;
    }
    this.setRepostedEverywhere(`sc:${reel.shortcode}`, result.state);
    return true;
  }

  /**
   * Reels 页那颗**收藏（书签）**的动作：转给 saveMedia（见那里的三条路）。
   */
  private async saveReel(reel: Reel, save: boolean): Promise<boolean> {
    return await this.saveMedia(reel.mediaId, reel.shortcode, true, save);
  }

  /**
   * feeds 流卡片那颗**收藏（书签）**的动作：同一条路（需求："feeds 流的收藏按钮也需要
   * 实现功能，所有收藏按钮都走 http 请求用探针抓模板"）。
   */
  private async savePost(post: MediaPost, save: boolean): Promise<boolean> {
    return await this.saveMedia(post.id, post.shortcode, post.isVideo(), save);
  }

  /**
   * 收藏 / 取消收藏的**唯一实现**（reels 页与 feeds 流共用）。
   *
   * 三条路，从快到慢（需求："所有收藏按钮都走 http 请求**用探针抓模板**"）：
   *   ① **探针抓到的模板**（最理想）：页面自己发过一次收藏请求之后，模板就已经存进
   *      ApiRegistry（见 captureSaveTemplates）。这里把它原样回放、只把媒体 id 换成这一条 ——
   *      网页会话与 csrf 都在模板头里，是最快也最稳的一条；
   *   ② **App 主机的 route**：`POST i.instagram.com/api/v1/media/{id}/save|unsave/`
   *      （core/NativeSave）。真机实测这条路由**要 App 身份的会话**，我们只有网页会话，
   *      所以经常落空（回 `{"status":"fail"}`）—— 但它是"最快的那条"，留着；
   *   ③ **网页驱动**：把隐藏网页导航到这条的页面，注入 saveOnPostPageScript 点它自己的书签，
   *      做完再导航回首页（和点赞 / 转发失败时退回去的那条完全一样）。
   *      **这一发会顺带把模板抓下来**（见 captureSaveTemplates），于是下一次点收藏就走 ①。
   *
   * 成功之后写进会话覆盖表 core/SaveState：信息流那颗书签、reels 那颗、以及翻页重建后的
   * 卡片，全靠它保持实心（见 FeedList.syncUiList / ReelOverlay.syncSaved）。
   */
  private async saveMedia(mediaId: string, shortcode: string, isVideo: boolean,
                          save: boolean): Promise<boolean> {
    const id: string = mediaId.trim();
    if (id.length === 0) {
      this.toast($r('app.string.save_failed'));
      return false;
    }
    // ① 探针抓到的模板（最省事的一条）。
    const viaTemplate: SaveResult | null = await NativeSave.byTemplate(id, save);
    if (viaTemplate !== null && viaTemplate.ok) {
      SaveState.remember(id, save);
      this.profileVm.refreshSavedTab();
      hilog.info(DOMAIN, TAG, 'save ok via=%{public}s id=%{public}s save=%{public}s',
        NativeSave.lastVia(), id, `${save}`);
      return true;
    }
    // ② App 主机的 route。
    const direct: SaveResult = await NativeSave.setSaved(id, save);
    if (direct.ok) {
      SaveState.remember(id, save);
      this.profileVm.refreshSavedTab();
      hilog.info(DOMAIN, TAG, 'save ok via=%{public}s id=%{public}s save=%{public}s',
        NativeSave.lastVia(), id, `${save}`);
      return true;
    }
    /*
     * 被 IG 限流（见 core/ApiThrottle）：**连网页那条路也一起停**（审计 E5/E6）。
     *
     * 为什么不能"原生不行就退回网页"：网页驱动是"把隐藏的 Web 导航到这条帖子、再点那颗书签"，
     * 它发出去的是**同一个账号的写请求** —— 撞的正是这把限流锁。原来这里会接着跑：
     * 界面上转半天、日志里一串失败，最后只给一句"没能收藏这条帖子"，用户完全不知道
     * 是"现在不能点"还是"这个功能坏了"。如实说 + 不再打，就是这一段的全部内容。
     */
    const throttleLeft: number = ApiThrottle.remainingMinutes(ApiThrottle.SAVE);
    if (ApiThrottle.blocked(ApiThrottle.SAVE)) {
      hilog.warn(DOMAIN, TAG, 'save skipped: save family throttled %{public}dmin left id=%{public}s',
        throttleLeft, id);
      this.toast($r('app.string.save_rate_limited', throttleLeft));
      return false;
    }
    hilog.info(DOMAIN, TAG, 'save native failed (%{public}s) id=%{public}s → web',
      direct.detail, id);
    // ③ 网页驱动（顺手抓模板，下次走 ①）。
    const ok: boolean = await this.saveByWeb(shortcode, isVideo, save);
    if (!ok) {
      this.toast($r('app.string.save_failed'));
      return false;
    }
    await this.captureSaveTemplates();
    SaveState.remember(id, save);
    // **收藏分页要刷新**（需求）：不然用户切到「收藏」看不到刚存的这一条 / 取消收藏后它还在。
    this.profileVm.refreshSavedTab();
    return true;
  }

  /**
   * 收藏的**网页驱动**那条路（见 saveMedia 的第 ③ 步）。
   *
   * 导航到这条的页面 → 注入 saveOnPostPageScript（它会先核对 URL 里就是这条 shortcode，
   * 再点 `main article` 里那颗书签）→ 无论成败都导航回首页（同 likeOnPostPage / returnToFeed：
   * 不回去的话后面的翻页、预热都会对着帖子页空转）。
   */
  private async saveByWeb(shortcode: string, isVideo: boolean, save: boolean): Promise<boolean> {
    if (shortcode.length === 0) {
      return false;
    }
    const post: MediaPost = new MediaPost({
      id: `save-${shortcode}`,
      shortcode: shortcode,
      caption: '',
      // 按调用方说的是不是视频决定走 `/reel/` 还是 `/p/`（见 navigateToPost）。
      mediaType: isVideo ? 'video' : 'image',
      displayUrl: '',
      likeCount: 0,
      commentCount: 0,
      takenAtMs: 0,
      ownerUsername: '',
      ownerAvatarUrl: '',
      ownerId: ''
    });
    const ready: boolean = await this.navigateToPost(post);
    try {
      if (!ready) {
        return false;
      }
      const raw: string = await this.bridge.runBridge(
        saveOnPostPageScript(shortcode, save), SAVE_TIMEOUT_MS);
      const payload: SavePayload = JSON.parse(raw) as SavePayload;
      hilog.info(DOMAIN, TAG, 'save web state=%{public}s save=%{public}s',
        payload.state, `${save}`);
      return payload.state === 'ok';
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'save web failed: %{public}s', (error as Error).message);
      return false;
    } finally {
      await this.returnToFeed();
    }
  }

  /**
   * 把网页刚发过的**收藏请求**存成模板（需求："用探针抓模板"）。
   *
   * 和 captureEngageTemplates 同一个套路（那是点赞/转发的自举）：页面一发出这类请求就会
   * 通过 PageBridge 通知原生（见 WebScripts 里那条正则），这里把它抓进 ApiRegistry 并落盘
   * —— 之后所有收藏按钮都走 **HTTP 回放**，不必再导航网页。
   *
   * 只抓 `save` 这一个词：`capture` 是按名字片段过滤的，词太大（比如 `Polaris`）会把一堆
   * 查询挤进模板表（坑位有限），真正要用的两条反而被挤掉（点赞那边踩过这个坑）。
   * 收藏与取消收藏的模板名里都含 `save`（`…SaveMedia…` / `rest_/api/v1/media/{id}/save/`、
   * `…/unsave/`），所以一次能同时抓到两条。
   */
  private async captureSaveTemplates(): Promise<void> {
    try {
      const ok: boolean = await ApiRegistry.getInstance().capture(SAVE_TEMPLATE_KEY);
      hilog.info(DOMAIN, TAG, 'save templates captured=%{public}s have=%{public}s',
        `${ok}`, NativeSave.describeTemplates());
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save template capture failed: %{public}s',
        (error as Error).message);
    }
  }

  /**
   * Reels 页作者行那颗关注按钮：走已有的 followUser（HTTP 优先，网页兜底）。
   *
   * **没有作者 id 也要往下走**：`followUser` 里本来就备了"拿不到 id 就退回网页驱动"那条路
   * （打开对方主页点它自己的关注按钮，见它的说明），而这里原来直接用 id 是否为空挡掉了 ——
   * 结果凡是 id 缺一条的数据源（搜索推荐流那条以前就没带作者 id），点下去就是
   * "关注失败"的提示 + 按钮弹回去（用户报的"点击关注按钮……没有改变成功"）。
   * 取关那条没有网页退路（要进菜单），所以 id 空时 followUser 会如实回失败，也照旧往下走。
   */
  private async followReelAuthor(reel: Reel, follow: boolean): Promise<boolean> {
    if (reel.author.length === 0) {
      this.toast($r('app.string.follow_failed'));
      return false;
    }
    if (reel.authorId.length === 0) {
      hilog.info(DOMAIN, TAG, 'reel follow without author id name=%{public}s → web path',
        reel.author);
    }
    return await this.followUser(reel.authorId, reel.author, follow);
  }

  /** Reels 页点作者行 → 打开这位用户的主页（和信息流资料行同一条路）。 */
  private openReelAuthor(reel: Reel): void {
    this.openUserProfile(reel.author, reel.authorId);
  }

  /**
   * Reels 页的「评论」：把这一条转成一条最小的 `MediaPost` 交给已有的评论面板
   * （那条面板只认 shortcode 与作者，见 openComments）。
   */
  private openReelComments(reel: Reel): void {
    this.openComments(new MediaPost({
      id: reel.mediaId.length > 0 ? reel.mediaId : `reel-${reel.shortcode}`,
      shortcode: reel.shortcode,
      caption: reel.caption,
      mediaType: 'video',
      displayUrl: reel.coverUrl,
      likeCount: reel.likeCount,
      commentCount: reel.commentCount,
      takenAtMs: 0,
      ownerUsername: reel.author,
      ownerAvatarUrl: reel.avatarUrl,
      ownerId: reel.authorId,
      videoUrl: reel.videoUrl
    }));
  }

  aboutToAppear(): void {
    // ---- 材质能力诊断（放在最前面：后面任何一步抛异常都不会把它挡掉）----
    // 标题栏背板一直是一块偏黑的板子、看不到"渐变模糊"：官方 FAQ 说材质的**模糊/折射**
    // （materialFilter）只在**高/中算力**设备上渲染，低算力设备只保留背景色/边框/阴影。
    // 这一行用来判定"是代码问题还是设备档位不支持"。
    // `uiMaterial` 是 API 26 起才有的模块：低版本设备上**连问都不能问**（会抛），所以先判能力。
    hilog.info(DOMAIN, TAG, 'platform cap %{public}s', PlatformCap.describe());
    if (PlatformCap.hasArkMaterial()) {
      try {
        const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
        hilog.info(DOMAIN, TAG,
          'material diag state=%{public}d type=%{public}d deviceLevel=%{public}d immersive=%{public}s',
          info.state, info.type, uiMaterial.getGlobalMaterialLevel(),
          `${uiMaterial.isImmersiveMaterialSupported()}`);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'material diag failed: %{public}s', (error as Error).message);
      }
    } else {
      hilog.info(DOMAIN, TAG, 'arkui material unsupported (api<26) → plain surfaces');
    }
    // 起来就在后台预热 feeds / Reels / 我的（见 preloadTabs）。
    // 启动画面是系统那条启动窗口，应用里不自绘 —— 这里只是趁它显示的那几秒先取数据。
    this.preloadTabs();
    // 起始分页的配色（正常是首页；万一恢复到了 Reels，这里也把深色落实一次）。
    this.syncReelsColorMode();
    // 降级底栏要避让系统条：量一次它的高度（支持悬浮栏的设备上直接返回，见 readBottomSafeVp）。
    this.readBottomSafeVp();
    // 设置的兜底初始化：正常路径是 EntryAbility.onCreate 里读一次（见 AppSettings.init），
    // 这里再来一次只是防"页面比 ability 先用到这些值"（重复调用是幂等的）。
    const host: common.Context | undefined = this.getUIContext().getHostContext();
    if (host !== undefined) {
      AppSettings.init(host);
      // 接口模板落盘（幂等）：读回上次抓到的请求模板，"不走网页"的第一发要用它
      // （见 bridge/ApiRegistry.persistTemplates 与 core/NativeFeed）。
      ApiRegistry.init(host);
      // 搜索页冷路径抓完模板会把"结构摘要"交回来 → 落进探针文件（见 dumpProbeFile）。
      this.searchVm.onDigest = (text: string): void => {
        this.dumpProbeFile('search', text);
      };
      // 「我的」四个分页同理：探针按钮跑完把四条接口的结构摘要落一份。
      this.profileVm.onDigest = (text: string): void => {
        this.dumpProbeFile('profile', text);
      };
      // 媒体预下载（幂等）：把缓存下载的下载信息表开大一点，信息流封面命中率才高。
      MediaPrefetch.init();
    }
    // 开始连续侦测**叠字**背后的画面明暗（沉浸式视频里的文字颜色靠它，见 overlayTextColor）。
    BackdropTone.start(SHELL_CONTENT_ID);
    // 底栏胶囊的左右留白要按屏宽反算（见 barSideMargin）。
    try {
      const widthPx: number = display.getDefaultDisplaySync().width;
      this.screenWidthVp = widthPx > 0 ? this.getUIContext().px2vp(widthPx) : 0;
    } catch (error) {
      this.screenWidthVp = 0;
    }
    hilog.info(DOMAIN, TAG, 'material level=%{public}s sideVp=%{public}d',
      this.materialLevel, Math.round(this.screenWidthVp));
    // 打一行材质状态：底栏图标的自动反色依赖它（DEFAULT/ENABLE 才有戏，DISABLE 则整套材质
    // 都不生效），出问题时凭这一行定位。应用级开关在 module.json5 里配成 enable（见那里的注释）。
    // 同样先判能力：`uiMaterial` 是 API 26 起才有的模块（低版本设备上调用会抛）。
    if (PlatformCap.hasArkMaterial()) {
      try {
        const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
        // 设备算力档位：材料的"模糊/折射"效果只在**高/中算力**设备上渲染；低算力只保留
        // 背景色/边框/阴影 —— 也就是标题栏会变成一块纯色（用户报的"没有渐变模糊、被黑色挡住"）。
        // 打这一行是为了凭日志判断"是代码问题还是设备档位问题"。
        hilog.info(DOMAIN, TAG, 'material state=%{public}d type=%{public}d level=%{public}d immersive=%{public}s',
          info.state, info.type, uiMaterial.getGlobalMaterialLevel(),
          `${uiMaterial.isImmersiveMaterialSupported()}`);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'material info failed: %{public}s', (error as Error).message);
      }
    }
    // view-model 不持有 ArkUI 状态，任何变化都回调到这里再落到 @State 上。
    this.viewModel.onBusy = (busy: boolean): void => {
      this.busy = busy;
    };
    this.viewModel.onPosts = (posts: MediaPost[]): void => {
      this.posts = posts;
      if (posts.length > 0) {
        // 有内容了：停掉"一直重试"的定时器。
        this.feedRetryLeft = 0;
      }
    };
    this.viewModel.onStatus = (kind: FeedStatus, detail: string): void => {
      this.applyStatus(kind, detail);
      // 首屏还没内容 + 失败/未就绪 → 排一次自动重试（见 scheduleFeedRetry）：
      // 用户要的是"一直刷新到 IG 页面准备好"，而不是自己反复下拉。
      if (this.posts.length === 0
        && (kind === FeedStatus.PageNotReady || kind === FeedStatus.Failed
          || kind === FeedStatus.Unparsable || kind === FeedStatus.NoneVisible)) {
        this.feedRetryLeft = FEED_RETRY_MAX;
        this.scheduleFeedRetry();
      }
    };
    this.viewModel.onSettled = (): void => {
      // 一轮加载（无论成功失败）就此结束，首屏骨架屏该让位给空态了。
      this.loadedOnce = true;
      // 只落轻量报告（同步、毫秒级）。重脚本改到探针面板手动触发。
      this.dumpProbeSilently();
      // 顺带看一眼接口登记表有没有新东西（有 TTL，过桥不频繁）。
      this.syncApiIndex();
    };
    this.bridge.setReadyHandler((): void => {
      this.bridgeReady = true;
      // 网页宿主就绪 = 切 tab / 导航网页都已经可用 → 这时候才执行深链意图（见 consumePendingDeepLink）。
      this.consumePendingDeepLink();
    });
    // 页面刚发出评论请求 → 立刻把那份模板抓下来存住（见 PageBridge.commentTemplateHandler）。
    // 这是"评论回放"能不能成立的关键一环：模板只在当前文档里有效，等我们回首页就没了。
    this.bridge.setCommentTemplateHandler((name: string): void => {
      hilog.info(DOMAIN, TAG, 'comment request seen name=%{public}s', name);
      ApiRegistry.getInstance().capture(COMMENT_TEMPLATE_KEY);
    });
    // 页面刚发出**点赞 / 转发 / 收藏**的写请求 → 同一条道理，立刻存模板
    // （core/NativeEngage 与 core/NativeSave 全靠它）。**立刻**是关键：网页里这条请求随时可能
    // 被下一次整页导航冲掉（去帖子页点那种情况）。
    this.bridge.setEngageTemplateHandler((name: string): void => {
      hilog.info(DOMAIN, TAG, 'engage request seen name=%{public}s', name);
      // 收藏那条与点赞/转发分开抓：`capture` 一次只按一个词过滤，抓太宽会把模板表挤满。
      if (name.toLowerCase().indexOf('save') >= 0) {
        this.captureSaveTemplates();
        return;
      }
      this.captureEngageTemplates();
    });
    this.bridge.setSessionHandler((signedIn: boolean): void => {
      this.handleSessionSignal(signedIn);
    });
    this.bridge.setRouteHandler((url: string): void => {
      this.currentUrl = url;
      // 路由一变就顺手抓一次评论模板：网页里"点开一条帖子"正是靠 SPA 换路由，
      // 那一下之后页面才会去请求评论（见 captureCommentTemplate）。
      this.captureCommentTemplate();
      // 页面令牌（lsd / fb_dtsg / 整页指纹）跟着**一份文档**走：换路由/重载就作废，
      // 下次需要时重新读一遍（见 core/WebTokens）。
      WebTokens.invalidate();
    });
    // 这里刻意不读 Cookie 罐：WebCookieManager 会提前拉起 ArkWeb 引擎，抢在
    // Web 组件创建浏览器之前初始化会让内核初始化失败（页面整片空白）。
    // 首次会话核对交给 Web 宿主的 onControllerAttached。
  }

  /**
   * 首屏没有内容时的**自动重试**（排在定时器上，见 scheduleFeedRetry）。
   *
   * 为什么要有：冷启动那几秒网页可能还没就绪、或正被别的页面导航着，这一轮读必然失败。
   * 用户不该为此自己反复下拉 —— 这里替他一直试，直到读到内容、或者试够次数、或者他离开首页。
   */
  private feedRetryTimer: number = 0;
  private feedRetryLeft: number = 0;
  /**
   * 后台预热队列**跑过了没有**（它只在启动时排一次，见 preloadTabs 的第二阶段）。
   */
  private warmStarted: boolean = false;
  /**
   * 会话详情自检（诊断用）：启动预热跑完顺手读一次私信会话并把结果打进日志。
   *
   * 排查时不必每轮都让人手动点开会话；结论拿到后把这里改成 false 即可
   * （真正的行为开关在 DirectViewModel.SELF_TEST_THREAD）。
   */
  private dmSelfTestRun: boolean = false;
  /**
   * 最近一次**用户滚动**的时刻（毫秒）。
   *
   * 后台预热靠它让路：每步开始前先等"手停下来"（见 warmStep/waitIdle）——
   * 每步都是一次网络 + 一次 JSON 解析，而解析跑在 JS 线程上，正在滑的时候做这些就是掉帧。
   */
  private lastInteractionMs: number = 0;

  /** 排一次自动重试（已经在排队、或次数用尽就直接返回）。 */
  private scheduleFeedRetry(): void {
    if (this.feedRetryLeft <= 0 || this.feedRetryTimer !== 0) {
      return;
    }
    this.feedRetryTimer = setTimeout((): void => {
      this.feedRetryTimer = 0;
      if (!this.signedIn || this.selectedTab !== AppTab.Home || this.posts.length > 0) {
        // 没登录 / 已经离开首页 / 已经有内容：不再试。
        this.feedRetryLeft = 0;
        return;
      }
      this.feedRetryLeft--;
      hilog.info(DOMAIN, TAG, 'feed auto-retry left=%{public}d', this.feedRetryLeft);
      this.viewModel.loadFeed();
    }, FEED_RETRY_GAP_MS);
  }

  /**
   * 页面销毁：停掉背景侦测的定时快照，并把评论浮层的两个定时器清干净。
   *
   * 评论那两个（审计 G5）：`commentsExitTimer` 是收起动画结束后的收尾，
   * `commentsSettleTimer` 是拖动松手后的吸附 —— 都是"到点改状态"的。
   * 页面走了它们还在排着队，等回来时可能正好在动画中途改 `commentsClosing`，
   * 于是 `closeComments` / `openComments` 撞上"正在关"的守卫直接 return，面板拉不起也关不掉。
   * 这里清掉句柄并把两个过程标志复位（`commentsVisible`/数据不动：回来时面板该是什么样还是什么样）。
   */
  aboutToDisappear(): void {
    BackdropTone.stop();
    if (this.commentsExitTimer >= 0) {
      clearTimeout(this.commentsExitTimer);
      this.commentsExitTimer = -1;
    }
    if (this.commentsSettleTimer >= 0) {
      clearTimeout(this.commentsSettleTimer);
      this.commentsSettleTimer = -1;
    }
    this.commentsClosing = false;
  }

  // ==========================================================================
  // 启动预热
  // ==========================================================================

  /**
   * 启动预热：**阶段一只读 feeds，阶段二在后台依次读其余四个页面**。
   *
   * 阶段一只做一件事的理由：首屏就是 feeds，用户在等的是它；后台四个页面一起上会把首屏的
   * 网络与 JS 线程（JSON 解析）抢走，观感是"启动反而更慢"。
   *
   * 阶段二见 warmOtherTabs：串行 + 间隔 + 让路给滚动 + 每步幂等（有数据就跳过）。
   *
   * 失败一律吞掉：预热只是"让用户切过去不用等"，它失败了不该影响任何正常路径。
   */
  private async preloadTabs(): Promise<void> {
    try {
      // 等会话核对完（最多等一小会儿）：没登录就没必要预热。
      const deadline: number = Date.now() + PRELOAD_SESSION_WAIT_MS;
      while (!this.sessionChecked && Date.now() < deadline) {
        await this.delay(100);
      }
      if (!this.signedIn) {
        hilog.info(DOMAIN, TAG, 'preload skipped: not signed in');
        return;
      }
      const started: number = Date.now();
      // ===== 阶段一：feeds（首屏）=====
      // 网页没就绪时注入脚本会被判 not-ready，所以先等它就绪（有上限）；
      // 等不到就**跳过**这一步（页面就绪后 handlePageReady 会自己读一次），
      // 别在这里硬读——那只会给列表下面挂一条"页面尚未就绪"。
      const ready: string = await this.bridge.awaitPageReady(PRELOAD_PAGE_WAIT_MS);
      if (ready === 'ready' && this.viewModel.list().length === 0) {
        await this.viewModel.loadFeed();
      }
      hilog.info(DOMAIN, TAG, 'preload feed posts=%{public}d %{public}dms',
        this.viewModel.list().length, Date.now() - started);
      // ===== 阶段二：其余四个页面（不 await，别挡着首屏）=====
      this.warmOtherTabs();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'preload failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 后台预热其余四个页面（需求："进入 feeds 页后缓存通知页面，reels，搜索和我的"）。
   *
   * 顺序 = 用户最可能先切过去的顺序（标题栏那颗爱心随时可能点 → 通知；然后是 Reels、搜索、
   * 我的）。四点讲究：
   *
   *   1. **等首屏收尾**：先等 WARM_START_DELAY_MS，别和骨架屏/封面解码抢线程；
   *   2. **串行 + 间隔**：四条都写在同一个隐藏网页上（冷启动时各自会导航一次再回首页，
   *      见 AppConfig 与 returnToFeed），并发就是互相抢页面；而且每步都有一次 JSON 解析，
   *      连着跑会把滚动挤掉 —— 每步之间歇 WARM_STEP_GAP_MS；
   *   3. **滚动优先**：每步开始前先等"手停下来"（见 waitIdle）；
   *   4. **幂等**：目标页已经有数据就整步跳过（用户可能自己已经切过去读过了）。
   *
   * 任何一步失败都只记一行日志：预热失败不该影响正常路径（用户切过去时页面自己会再读一次）。
   */
  private async warmOtherTabs(): Promise<void> {
    if (this.warmStarted) {
      return;
    }
    this.warmStarted = true;
    await this.delay(WARM_START_DELAY_MS);
    /*
     * 0) **限时快拍托盘**（需求："快拍功能在启动 app 时预加载，和 feeds 流一样"）。
     *
     * 以前托盘是等它自己挂载后才去取数（首屏能看到"空一拍再长出来"），这里跟着 feeds 的预热链
     * 一起把它拉回来，并且顺手把**前几位用户的 story 内容**预建好（StoryCache.ensure）——
     * 这样用户启动后第一次点开头像也是秒开，和 feeds 首屏贴子已经预热是同一套做法。
     */
    await this.warmStep('stories', (): boolean => this.storyQueue.length > 0,
      (): Promise<void> => {
        return NativeStories.tray().then((tray: StoryTray | null): void => {
          if (tray !== null && tray.items.length > 0) {
            this.rememberStoryQueue(tray.items);
            StoryCache.reset(tray.items, 0);
            StoryCache.ensure(tray.items, 0);
            hilog.info(DOMAIN, TAG, 'warm stories n=%{public}d cached=%{public}d',
              tray.items.length, StoryCache.size());
          }
        }).catch((): void => {
        });
      });
    // 1) 通知页（原生一条链：news/inbox → show_many → ayml）。
    //    预热这一轮传 warmOnly：模板缺失时**不**导航隐藏网页去抓 ayml（见 loadNotifications）。
    await this.warmStep('notify', (): boolean => this.notifications.length > 0,
      (): Promise<void> => {
        return this.loadNotifications(true);
      });
    // 2) Reels（有模板时是毫秒级回放；没有才导航一次）。
    await this.warmStep('reels', (): boolean => this.reelsVm.list().length > 0,
      (): Promise<void> => {
        return this.reelsVm.loadFirst();
      });
    // 3) 搜索页的推荐流：**只走原生 HTTP**（warm 不会导航隐藏网页），顺手预取第二页。
    await this.warmStep('search', (): boolean => this.searchVm.postList().length > 0,
      (): Promise<void> => {
        return this.searchVm.warm();
      });
    // 4) 我的。
    await this.warmStep('profile', (): boolean => this.profileVm.postsNow().length > 0,
      (): Promise<void> => {
        return this.profileVm.load(true);
      });
    // 顺手把「我的」四个分页的 feeds 页与媒体也备好（见 selectTab 里那一段的说明）：
    // 用户切过去、或点进帖子页时，数据和图片都已经在手边了。
    this.profileVm.preloadAllSegments();
    /*
     * 6) **搜索结果模板体检**（需求："进入首页时就测试搜索请求模板，失败重新抓 http 请求模板，
     *    抓到更新进模板库"）。
     *
     * 放在**最后一步**：体检本身是一发几百毫秒的原生请求；万一模板不可用，它会走冷路径
     * （导航共用的隐藏网页去重抓），那一步不能和前面的预热步骤抢页面。
     * 失败不影响任何东西：它是"提前把搜索修好"，不是首屏路径的一部分。
     */
    try {
      await this.searchVm.healthCheck();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'search health check threw: %{public}s', (error as Error).message);
    }
    // 5) **会话详情自检**（诊断用，见 DirectViewModel.selfTestThread 与 SELF_TEST_THREAD）。
    //    跑在最后：它要多打两条私信接口，别和首屏那几步抢时间。
    if (DM_THREAD_SELFTEST && !this.dmSelfTestRun) {
      this.dmSelfTestRun = true;
      this.directVm.selfTestThread().catch((): void => {
      });
    }
    hilog.info(DOMAIN, TAG, 'warm done');
  }

  /**
   * 后台预热的一步：**有数据就跳过 → 等手停 → 跑 → 记时长 → 歇一下**。
   *
   * @param name 日志用的名字（`warm <name> Ndms` 一行，便于判断哪一步最贵）。
   * @param cached 目标页已经有数据了没有（有就跳过整步）。
   * @param run 真正取数的那一步。
   */
  private async warmStep(name: string, isCached: () => boolean,
                         run: () => Promise<void>): Promise<void> {
    if (isCached()) {
      hilog.info(DOMAIN, TAG, 'warm %{public}s skip (cached)', name);
      return;
    }
    await this.waitIdle();
    // 等空闲的这段时间里用户可能自己切过去了（页面自己会读一次）：那就别重复读了。
    if (isCached()) {
      hilog.info(DOMAIN, TAG, 'warm %{public}s skip (loaded while waiting)', name);
      return;
    }
    const started: number = Date.now();
    try {
      await run();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'warm %{public}s failed: %{public}s', name, (error as Error).message);
    }
    hilog.info(DOMAIN, TAG, 'warm %{public}s %{public}dms', name, Date.now() - started);
    await this.delay(WARM_STEP_GAP_MS);
  }

  /** 等用户"手停下来"（WARM_IDLE_MS 内没有滚动），最多等 WARM_IDLE_MAX_MS。 */
  private async waitIdle(): Promise<void> {
    const deadline: number = Date.now() + WARM_IDLE_MAX_MS;
    while (Date.now() - this.lastInteractionMs < WARM_IDLE_MS && Date.now() < deadline) {
      await this.delay(120);
    }
  }

  // ==========================================================================
  // 状态行
  // ==========================================================================

  /**
   * view-model 只报语义（FeedStatus），文案在这里落到资源上。
   *
   * 「读取失败」要带动态原因，用带占位符的资源串（`%s`）而不是拼接中文字面量，
   * 这样 en_US 也能正常显示。
   */
  private applyStatus(kind: FeedStatus, detail: string): void {
    if (kind === FeedStatus.Idle) {
      this.statusShown = false;
      return;
    }
    // 「正在加载」不再用文字表达：首屏由骨架屏承担，触底由列表底部的圆环承担。
    if (kind === FeedStatus.Loading || kind === FeedStatus.LoadingMore) {
      this.statusShown = false;
      return;
    }
    let text: ResourceStr = '';
    if (kind === FeedStatus.PageNotReady) {
      text = $r('app.string.status_page_not_ready');
    } else if (kind === FeedStatus.Unparsable) {
      text = $r('app.string.status_unparsable');
    } else if (kind === FeedStatus.NoneVisible) {
      text = $r('app.string.feed_none_visible');
    } else if (kind === FeedStatus.NoMore) {
      text = $r('app.string.feed_no_more');
    } else if (kind === FeedStatus.NoneRead) {
      text = $r('app.string.feed_none_read');
    } else if (kind === FeedStatus.Failed) {
      text = $r('app.string.status_failed', detail);
    }
    this.statusText = text;
    this.statusShown = true;
  }

  /** 页面自己直接设置文案的状态（登录引导、播放失败）。 */
  private setLocalStatus(text: ResourceStr): void {
    this.statusText = text;
    this.statusShown = true;
  }

  /**
   * 在最上层弹一条轻提示（系统 toast）。
   *
   * 专给"整屏页面里的操作"用：statusShown 那条提示横幅画在主页外壳里，而通知页是
   * NavDestination 整屏盖上去的，横幅根本露不出来。关注/取关就是在通知页上点的，
   * 成功与失败都必须让用户当场看见，所以走系统 toast。
   */
  private toast(text: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text, duration: 1600 });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (error as Error).message);
    }
  }

  // ==========================================================================
  // 会话
  // ==========================================================================

  /**
   * 网页侧上报的登录态提示。
   *
   * 「已登录」直接采信：页面已经渲染出登录后的导航，会话肯定生效了。
   * 「未登录」只是提示——移动版网页的结构不一定命中判断用的标记——所以回到
   * Cookie 罐核对一次，只有罐里也确实没有会话才切回登录页。
   */
  private async handleSessionSignal(signedIn: boolean): Promise<void> {
    if (signedIn) {
      this.applySession(true);
      return;
    }
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    this.applySession(snapshot.signedIn);
  }

  /** 以 Cookie 罐为准刷新登录态；罐里有会话时顺手落盘。 */
  private async refreshSessionFromJar(): Promise<void> {
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    hilog.info(DOMAIN, TAG, 'cookie jar entries=%{public}d signedIn=%{public}s names=%{public}s',
      snapshot.count, snapshot.signedIn ? '1' : '0', snapshot.names);
    if (snapshot.signedIn) {
      await InstagramCookieJar.save();
    }
    this.applySession(snapshot.signedIn);
  }

  private applySession(signedIn: boolean): void {
    const changed: boolean = !this.sessionChecked || this.lastSessionState !== signedIn;
    this.sessionChecked = true;
    this.lastSessionState = signedIn;
    this.signedIn = signedIn;
    if (!changed) {
      return;
    }
    // 换了登录态 = 列表会清空重来，首屏骨架屏要重新生效。
    this.loadedOnce = false;
    if (signedIn) {
      this.selectedTab = AppTab.Home;
      // 直接改 selectedTab 会绕过 selectTab 里的可见性同步：搜索页已经不是当前页了，
      // 必须显式关掉它的"接受滚动翻页"闸门（审计 C1：否则 active 与实际可见页不符）。
      this.searchVm.setActive(false);
      this.webVisible = false;
      this.viewModel.reset();
      // 会话刚生效：把网页送回首页信息流，页面加载完成后再由 handlePageReady 读流。
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      return;
    }
    this.viewModel.reset();
    // 退出登录：内存里的通知与它的存档都作废（不清的话下次登录会把上一个人的通知铺出来）。
    this.forgetNotifications();
    this.setLocalStatus($r('app.string.status_sign_in_required'));
  }

  private handlePageReady(): void {
    this.bridgeReady = true;
    hilog.info(DOMAIN, TAG, 'pageReady signedIn=%{public}s tab=%{public}d posts=%{public}d',
      this.signedIn ? '1' : '0', this.selectedTab, this.viewModel.list().length);
    // 探针：每次网页加载完成后落一份报告，方便直接取用（不含任何凭据与正文）。
    this.dumpProbeSilently();
    // 网页刚走完一轮，接口模板多半又多了几条（例如刚从别的页面回来）。
    this.syncApiIndex();
    // 有些查询是**水合之后**才发的（搜索页、个人页都见过），pageReady 那一刻还没出现；
    // 隔几秒再补一次，免得清单里漏掉它们。
    setTimeout((): void => {
      this.syncApiIndex();
      // 水合之后页面才会把评论请求发出去，这一趟正好也把评论模板收下来。
      this.captureCommentTemplate();
    }, API_INDEX_LATE_SYNC_MS);
    if (this.signedIn && this.selectedTab === AppTab.Home && this.viewModel.list().length === 0) {
      this.viewModel.loadFeed();
    }
  }

  /**
   * 丢掉"按人抓的"会话级状态：通知列表 + 关注状态覆盖表 + 收藏覆盖表 + 转发的 note_id。
   *
   * 退出登录时调用（applySession 与 signOut 两条路都要走）：这几样都是按人抓的，
   * 不清的话下次登进另一个账号时，通知页会先把上一个人的通知显示出来、关注按钮、
   * reels 那颗书签也会顶着上一个人的状态 —— 那是最不能犯的错。
   * （**存档已经移除**，见需求"通知存档功能移除"，所以这里只清内存。）
   */
  private forgetNotifications(): void {
    this.notifications = [];
    FollowState.clear();
    SaveState.clear();
    EngageState.clear();
  }

  private async signOut(): Promise<void> {
    // 退出登录是从设定页点的：先把设定页收掉，免得登出之后还停在一个没有上下文的页面上。
    this.navStack.clear();
    // 退出登录走 SDK 清罐（见 InstagramCookieJar.clear 的说明）。
    await InstagramCookieJar.getInstance().clear();
    this.forgetNotifications();
    this.signedIn = false;
    this.sessionChecked = true;
    this.lastSessionState = false;
    this.viewModel.reset();
    this.loadedOnce = false;
    this.statusShown = false;
    this.webVisible = true;
    this.bridge.loadUrl(AppConfig.INSTAGRAM_LOGIN_URL);
  }

  // ==========================================================================
  // 探针
  // ==========================================================================

  /**
   * 把当前探针报告落一份盘（排查用）。
   *
   * **节流到最多 60 秒一次**：它原来挂在每次信息流"一轮加载结束"上，等于每刷一次首页
   * 就写一次文件 + 读一次 Cookie 罐（`InstagramCookieJar.inspect`）；这些都是纯开销，
   * 与取数速度无关。探针面板里的手动操作（`probeAndDump`）不受这个节流限制。
   */
  private async dumpProbeSilently(): Promise<void> {
    const now: number = Date.now();
    if (now - this.lastProbeDumpMs < PROBE_DUMP_MIN_INTERVAL_MS) {
      return;
    }
    this.lastProbeDumpMs = now;
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const sessionLine: string = `登录态=${snapshot.signedIn ? '已登录' : '未登录'} `
        + `cookie=${snapshot.count} 名=${snapshot.names}`;
      InstagramProbe.getInstance().dump(context, 'probe',
        InstagramProbe.getInstance().report(sessionLine));
    } catch (error) {
    }
  }

  /** 回放首页信息流接口并落盘摘要（只读，用页面自己的会话）。 */
  private async probeAndDump(): Promise<void> {
    const list: MediaPost[] = this.viewModel.list();
    const first: MediaPost | null = list.length > 0 ? list[0] : null;
    const local: string = first === null
      ? `posts=${list.length}`
      : `posts=${list.length} 首条=${first.ownerUsername}|赞${first.likeCount}|评${first.commentCount}`
        + `|图${first.displayUrl.length}|v${first.videoUrl.length}|n${first.imageUrls.length}`
        + `|${first.displayUrl.substring(0, 60)}|${this.viewModel.debugText()}`;
    try {
      const digest: string = await this.bridge.runBridge(TIMELINE_PROBE_SCRIPT, 20000);
      InstagramProbe.getInstance().setApiDigest(`${local}\n${digest}`);
    } catch (error) {
      InstagramProbe.getInstance().setApiDigest(local);
    }
    try {
      const dom: string = await this.bridge.runBridge(DOM_SURVEY_SCRIPT, 15000);
      InstagramProbe.getInstance().setDomReport(dom);
    } catch (error) {
    }
    await this.dumpProbeSilently();
  }

  /** 汇总当前登录态 + 已采集到的接口，生成可读报告。 */
  private async refreshProbeReport(): Promise<void> {
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    const sessionLine: string = `登录态=${snapshot.signedIn ? '已登录' : '未登录'} `
      + `cookie=${snapshot.count} 名=${snapshot.names}`;
    this.probeText = InstagramProbe.getInstance().report(sessionLine);
  }

  private async openProbe(): Promise<void> {
    this.probeVisible = true;
    // 打开探针时顺手把页面里"请求/响应上报"的开关打开：平时它是关着的（那是有成本的常驻开销，
    // 见 PROBE_WATCH_ON_SCRIPT 的说明），要看报告时才开。
    try {
      await this.bridge.runBridge(PROBE_WATCH_ON_SCRIPT, 3000, 'probe-watch-on');
    } catch (error) {
    }
    await this.refreshProbeReport();
  }

  /** 网页结构探测：把当前页面（登录后首页 / 详情页 / 个人页都行）的骨架读出来。 */
  private async probeDom(): Promise<void> {
    const raw: string = await this.bridge.runBridge(DOM_SURVEY_SCRIPT, 15000);
    InstagramProbe.getInstance().setDomReport(raw);
    await this.refreshProbeReport();
  }

  private copyProbeReport(): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.probeText);
      pasteboard.getSystemPasteboard().setData(data, (err: BusinessError | undefined) => {
        this.probeText = err === undefined
          ? `${this.probeText}\n\n[已复制到剪贴板]`
          : `${this.probeText}\n\n[复制失败：${err.message}]`;
      });
    } catch (error) {
      this.probeText = `${this.probeText}\n\n[剪贴板不可用]`;
    }
  }

  /** 落盘到应用沙箱，便于用 hdc 直接把报告取出来。 */
  private saveProbeReport(): void {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const name: string = InstagramProbe.getInstance().dump(context, 'probe', this.probeText);
      this.probeText = name.length > 0
        ? `${this.probeText}\n\n[已写入沙箱 ${name}]`
        : `${this.probeText}\n\n[写入沙箱失败]`;
    } catch (error) {
      this.probeText = `${this.probeText}\n\n[写入沙箱失败]`;
    }
  }

  private clearProbe(): void {
    InstagramProbe.getInstance().clear();
    this.refreshProbeReport();
  }

  /**
   * 把一份探针摘要写进沙箱（`probe_<kind>_*.txt`）并返回文件名。
   *
   * 为什么要落文件：hilog 刷得太快（chromium 每秒几千行，缓冲区几秒就滚没了），
   * 而"某条接口的真实结构"恰恰是写解析时唯一要看的东西 —— 只有文件能留住它。
   */
  private dumpProbeFile(kind: string, text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const name: string = InstagramProbe.getInstance().dump(context, kind, text);
      hilog.info(DOMAIN, TAG, '%{public}s digest dumped %{public}s', kind, name);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s digest dump failed: %{public}s',
        kind, (error as Error).message);
    }
  }

  // ==========================================================================
  // 网页
  // ==========================================================================

  private openLoginWeb(): void {
    this.webVisible = true;
    this.statusShown = false;
    this.bridge.loadUrl(AppConfig.INSTAGRAM_LOGIN_URL);
  }

  private openWeb(url: string): void {
    this.webVisible = true;
    this.statusShown = false;
    this.bridge.loadUrl(url);
  }

  /**
   * 打开**用户主页**（需求："从 feeds 点击用户资讯模块后进入新页面"）。
   *
   * 走 NavDestination（和通知页/设定页同一套承载，见 destinationBuilder）：标题栏、返回键、
   * 沉浸光感材质都由 HdsNavDestination 负责，内容复用「我的」页那套模板（见 ProfilePage）。
   *
   * @param username 目标用户的用户名（标题与"帖子"那条查询用它）。
   * @param userId   目标用户的数字 id（头部/视频/被提及那三条查询用它；拿不到时头部就不发，
   *                 不会把我自己的资料画上去，见 ProfileViewModel.loadHeader）。
   */
  private openUserProfile(username: string, userId: string): void {
    const name: string = username.trim();
    if (name.length === 0) {
      return;
    }
    // 已经在同一个人的主页上：不再压一层（连着压两层的话"返回"一次还停在原地）。
    const names: Array<string> = this.navStack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === USER_PROFILE_PAGE) {
      const param: Object = this.navStack.getParamByIndex(names.length - 1) as Object;
      if (param !== undefined && param !== null && `${param}` === `${name}|${userId}`) {
        hilog.info(DOMAIN, TAG, 'user profile already open: %{public}s', name);
        return;
      }
    }
    /*
     * **评论面板开着的时候点头像**（帖子页 / Reels 页的资讯模块、Reels 侧栏那颗头像）：
     * 先让面板收下去、再推主页 —— 和"在评论里点头像"那条路完全一致
     * （见 openUserFromComments）。
     *
     * 为什么必须在这儿处理：浮层在根 Stack 里、`zIndex(70)`，NavDestination 压不住它，
     * 不挂起的话面板会**画在用户主页上面**（用户报的"feeds/reels 类页面进入用户页面后
     * 评论面板会弹出"）。兜底还有 onPageShown 那道（任何整屏页面压上来都让位）。
     *
     * 已经挂起时 `suspendCommentsForProfile` 直接走 `after()`（不会重复记账）；
     * 面板本来就关着时同理 —— 两条路都是"推页面"。
     */
    this.suspendCommentsForProfile((): void => {
      this.navStack.pushPath({ name: USER_PROFILE_PAGE, param: `${name}|${userId}` });
    });
  }

  /**
   * 用户主页的路由参数：`用户名|数字id`（见 openUserProfile）。
   *
   * 用一个字符串而不是对象：NavPathStack 的 param 传对象时跨页面拿出来是 `Object`，还得再
   * 断言一次类型；这里两个字段都是字符串，拼起来最省事（分隔符用 `|`，用户名里不会有它）。
   */
  private static parseUserParam(param: object): Array<string> {
    const text: string = param === undefined || param === null ? '' : `${param}`;
    const parts: Array<string> = text.split('|');
    const username: string = parts.length > 0 ? parts[0] : '';
    const userId: string = parts.length > 1 ? parts[1] : '';
    return [username, userId];
  }

  /** 路由参数里的用户名（标题栏用；见 parseUserParam）。 */
  private static userNameOf(param: string): string {
    const at: number = param.indexOf('|');
    return at >= 0 ? param.substring(0, at) : param;
  }

  /**
   * 打开**帖子页**（需求：点网格里的某个格子 → 新页面，把当前分页整理成 feeds 流并定位到那一条）。
   *
   * @param posts 当前分页的全部帖子（信息流卡片用的模型，ProfilePage 已经转好）。
   * @param index 点进去的那一条在里面的下标。
   */
  private openPostStream(posts: Array<MediaPost>, index: number,
                         loadMore: () => Promise<ProfileStreamPage>,
                         fromOwnProfile: boolean = false): void {
    if (posts.length === 0 || index < 0 || index >= posts.length) {
      return;
    }
    const key: string = FeedMapper.keyOf(posts[index]);
    // 这一页是从**我自己的主页**进来的吗（帖子 / 收藏 / 被标注那几段）：是的话标题栏不给关注，
    // 见 postPageMenu。
    this.postPageFromOwnProfile = fromOwnProfile;
    // 帖子页的作者（这一整段都是同一个人的帖子）：标题栏那颗「关注」按他算。
    const author: MediaPost = posts[0];
    this.postPageAuthorId = author.ownerId;
    this.postPageAuthor = author.ownerUsername;
    this.postPageFollowed = FollowState.resolve(author.ownerId,
      FollowState.resolveName(author.ownerUsername, author.ownerFollowing));
    // 触底翻页的入口（由 ProfilePage 交出来，见它的 makeStreamLoader）：
    // 有了它，帖子页不必等网格把后面几页翻完 —— 自己滑到底就能接着加载。
    this.postPageLoadMore = loadMore;
    /*
     * **翻页状态每次进页都要重新起算**。
     *
     * 这两个字段是页面的常驻状态，而"到底了没有"是**按分页**算的：上一次从「帖子」那一段进来时
     * 它只有一页（`hasMore=false`），这个 false 会一直留着 —— 换到「收藏」「被标注」再进来时
     * `loadPostPageMore` 第一道闸就把请求挡了，表现就是"只能看分页里已有的帖子、上滑到底不加载"
     * （用户报的正是这个）。`postPageLoadingMore` 同理：上一次的请求被打断时它可能停在 true。
     */
    this.postPageHasMore = true;
    this.postPageLoadingMore = false;
    // "这一次进页补过哪些"也要清零（详情**本身**有跨次缓存，见 mediaDetails，不会重复请求）。
    this.videoTried.clear();
    // 已经在帖子页上（比如从"更多"里再点一次）：只换数据、不再压一层。
    const names: Array<string> = this.navStack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === POST_PAGE) {
      this.postPagePosts = posts;
      this.postPageAnchor = key;
      hilog.info(DOMAIN, TAG, 'post page already open → retarget anchor=%{public}s', key);
      return;
    }
    this.postPagePosts = posts;
    this.postPageAnchor = key;
    // `multi` = 这一份里有多少条是**多图帖**（`imageUrls.length > 1`）：多图帖的卡片是轮播
    // （FeedList → MediaCarousel），这一行日志用来确认"多图帖的所有图都带过来了"。
    // `videos/withUrl` = 视频帖有多少条、其中多少条**真的带视频地址**：收藏 / 被标注那两段
    // 的查询只给封面（没有 video_versions），要靠 core/NativeMediaInfo 按 id 补，
    // 这一对数就是"补之前/补之后"的判据（见 loadPostPageVideos）。
    let multi: number = 0;
    let videos: number = 0;
    let withUrl: number = 0;
    // 已经带着"本机赞过 / 转过"的条数（诊断用：会话台账有没有生效，一眼能看出来）。
    let likedKnown: number = 0;
    let repostedKnown: number = 0;
    for (let index2: number = 0; index2 < posts.length; index2++) {
      if (posts[index2].imageUrls.length > 1) {
        multi++;
      }
      if (posts[index2].liked) {
        likedKnown++;
      }
      if (posts[index2].reposted) {
        repostedKnown++;
      }
      if (posts[index2].isVideo()) {
        videos++;
        if (posts[index2].videoUrl.length > 0) {
          withUrl++;
        }
      }
    }
    hilog.info(DOMAIN, TAG,
      'post page open n=%{public}d multi=%{public}d videos=%{public}d/%{public}d liked=%{public}d reposted=%{public}d anchor=%{public}s',
      posts.length, multi, withUrl, videos, likedKnown, repostedKnown, key);
    this.navStack.pushPath({ name: POST_PAGE });
    // 这一页**不是**只有进页时那几条：先自己补一轮（见 fillPostPage）。
    // 用户报的"要在分页加载帖子后帖子页面才会显示"就是"网格翻到哪儿、帖子页才有多少"，
    // 现在数据源在视图模型里，帖子页可以自己往下要（触底也会继续要）。
    this.fillPostPage();
    // 视频地址后补（收藏 / 被标注那两段的查询只给封面，见 loadPostPageVideos）。
    // 轮数记账每次进页清零：上一页补过的轮数不该算到这一页头上。
    this.postPageFillRounds = 0;
    this.loadPostPageVideos();
  }

  /**
   * 给帖子页里**缺字段**的那些按 media id 补齐（视频地址 / 多图 / 发布时间 / 作者头像）。
   *
   * 为什么需要：IG 的**收藏 / 被标注**那两个分页查询只下发封面 —— 真机实测媒体节点里
   * `media_type=2`（视频）却没有任何 `video_versions`，`carousel_media` 与 `taken_at` 同样没有，
   * `user` 对象里也只有 pk/username（没有头像）。所以那些帖子进帖子页时：
   *   - 视频只有一张封面（"收藏分页点进帖子视频无法正常播放"）；
   *   - **多图帖只显示一张**（用户报的"收藏和被标注帖子进入帖子页面无法显示多图片"）；
   *   - **不显示发布时间**（卡片那一行按 `takenAtMs > 0` 才画，见 FeedList.hasPostedTime）；
   *   - **头像是一块空底色**（用户报的"作者头像加载不出来"）。
   * 这四样在 `/api/v1/media/{id}/info/` 那一发响应里都有（core/NativeMediaInfo.detailFor），
   * 所以**一次请求把它们全补齐**（只是把原来只取视频+头像的那一发扩成整份详情，没有多发请求）。
   *
   * 几点讲究：
   *   - **一次只发一条、串行**：这是给 IG 的重查询之外又加请求，并发打过去容易被限流
   *     （见 core/ApiThrottle，真机就是这么撞上的）；
   *   - **每轮有上限**（POST_PAGE_VIDEO_FILLS）：一页十几条要好几秒，先补前几条，
   *     剩下的下一轮再说；
   *   - **已经补过的不再补**（`videoTried` 记着这一次进页请求过哪些，`mediaDetails` 存着跨次
   *     复用的详情）；
   *   - 补到一条就换一条新 `MediaPost`（字段只读）→ 列表整体替换 → 那张卡片的键里带着
   *     "有没有视频地址 / 有几张图"（见 FeedList 的键），于是那一张重建、播放器与轮播挂上；
   *   - 被限流期间直接跳过（见 core/ApiThrottle）。
   */
  private async loadPostPageVideos(): Promise<void> {
    if (this.postPageVideoFilling) {
      return;
    }
    this.postPageVideoFilling = true;
    const startedMs: number = Date.now();
    let requests: number = 0;
    try {
      /*
       * **先从"用户第一眼看的那条"开始**（`postPageAnchor` 是点进来的那一条）：
       * 这一轮是串行的（每条几百毫秒），按列表顺序从头扫的话，锚点在第 5 条就要白等 2~3 秒
       * 才轮到它 —— 用户看到的正是"视频和头像加载得很慢"。
       * 扫完锚点再从头扫其余的，一屏之内基本都能覆盖。
       */
      const anchorKey: string = this.postPageAnchor;
      for (let pass: number = 0; pass < 2; pass++) {
        for (let index: number = 0; index < this.postPagePosts.length; index++) {
          if (requests >= POST_PAGE_VIDEO_FILLS) {
            break;
          }
          const post: MediaPost = this.postPagePosts[index];
          const isAnchor: boolean = anchorKey.length > 0 && FeedMapper.keyOf(post) === anchorKey;
          if (pass === 0 ? !isAnchor : isAnchor) {
            continue;
          }
          const id: string = post.id.indexOf('profile-') === 0 ? '' : post.id;
          const needVideo: boolean = post.isVideo() && post.videoUrl.length === 0;
          const needAvatar: boolean = post.ownerAvatarUrl.length === 0 && post.ownerId.length > 0;
          /*
           * **时间也是"缺字段"之一**：收藏 / 被标注那两段的载荷没有 `taken_at`
           * （用户报的"帖子发布时间没有显示"）。这三样任一缺，就值得发这一发 ——
           * 而**多图不用单独判**：那两段的载荷同样没有 `carousel_media`，而"没有头像"这一条
           * 在那些帖子上几乎恒真，所以请求本来就会发，多图与时间就顺手一起补上了。
           */
          const needTime: boolean = post.takenAtMs <= 0;
          if (!needVideo && !needAvatar && !needTime) {
            continue;
          }
          if (ApiThrottle.blocked(ApiThrottle.MEDIA_INFO)) {
            hilog.info(DOMAIN, TAG, 'post page fill skipped: rate limited');
            return;
          }
          let detail: MediaDetail | null = null;
          if (needVideo || needAvatar || needTime) {
            const known: MediaDetail | undefined = this.mediaDetails.get(post.shortcode);
            if (known !== undefined) {
              // 以前取过（同一个 shortcode）：**直接用，不再发请求**。
              detail = known;
            } else if (id.length > 0 && !this.videoTried.has(post.shortcode)) {
              this.videoTried.add(post.shortcode);
              requests++;
              detail = await NativeMediaInfo.detailFor(id);
              if (detail !== null) {
                this.mediaDetails.set(post.shortcode, detail);
              } else {
                hilog.info(DOMAIN, TAG, 'post page detail missing anchor=%{public}s why=%{public}s',
                  post.shortcode, NativeMediaInfo.lastDetail());
              }
            }
          }
          let avatar: string = detail === null ? '' : detail.avatarUrl;
          if (avatar.length === 0 && needAvatar) {
            // 详情那一发没带上头像（少见）：只能单独问一次（同一个作者会命中缓存）。
            avatar = NativeUserInfo.cached(post.ownerId);
            if (avatar.length === 0) {
              requests++;
              avatar = await NativeUserInfo.avatarFor(post.ownerId);
            }
          }
          const videoUrl: string = detail === null || !detail.hasVideo() ? '' : detail.display;
          const videoOriginal: string = detail === null || !detail.hasVideo() ? '' : detail.original;
          const images: Array<string> = detail === null ? [] : detail.images;
          const originalImages: Array<string> = detail === null ? [] : detail.originalImages;
          const takenAtMs: number = detail === null ? 0 : detail.takenAtMs;
          const aspectMin: number = detail === null ? 0 : detail.imageAspectMin;
          const detailReposts: number = detail === null ? -1 : detail.repostCount;
          if (videoUrl.length === 0 && avatar.length === 0 && images.length <= 1 && takenAtMs <= 0) {
            continue;
          }
          // 用**最新的那一份**列表替换（这中间可能有别的更新把列表换过）。
          const next: Array<MediaPost> = [];
          for (let at: number = 0; at < this.postPagePosts.length; at++) {
            const one: MediaPost = this.postPagePosts[at];
            next.push(one.shortcode === post.shortcode
              ? FeedMapper.withDetails(one, videoUrl, videoOriginal, avatar, images, originalImages,
                takenAtMs, aspectMin, detailReposts > 0 ? detailReposts : -1)
              : one);
          }
          this.postPagePosts = next;
          hilog.info(DOMAIN, TAG,
            'post page fill anchor=%{public}s mine=%{public}s video=%{public}s img=%{public}d time=%{public}s avatar=%{public}s ms=%{public}d',
            post.shortcode, `${isAnchor}`, `${videoUrl.length > 0}`, images.length,
            `${takenAtMs > 0}`, `${avatar.length > 0}`, Date.now() - startedMs);
        }
      }
      /*
       * 一页可能有几十条要补（真机日志见过 `videos=0/70`）：一轮只补 6 条，
       * 剩下的**在后台接着补**（间隔一点、仍然串行、仍然受限流闸门约束），
       * 这样用户往下滚时后面那些也已经是可播的了，而不是"翻到哪儿都是封面"。
       * 只排后续两轮（一共 18 条上限），免得变成一台请求机器。
       */
      if (requests >= POST_PAGE_VIDEO_FILLS && this.postPageFillRounds < POST_PAGE_FILL_ROUNDS
        && this.hasUnfilledPostVideo()) {
        this.postPageFillRounds++;
        setTimeout((): void => {
          this.loadPostPageVideos();
        }, POST_PAGE_FILL_GAP_MS);
      }
    } finally {
      this.postPageVideoFilling = false;
    }
  }

  /**
   * 这一页里还有"字段缺着、而且这次没请求过"的吗（决定要不要在后台再补一轮）。
   *
   * 判据和 loadPostPageVideos 里那道闸**必须一致**（视频没地址 / 没头像 / 没发布时间）——
   * 收藏 / 被标注那两段的帖子三样全缺，所以这里几乎恒真，后台会接着把后面几条也补上。
   */
  private hasUnfilledPostVideo(): boolean {
    if (ApiThrottle.blocked(ApiThrottle.MEDIA_INFO)) {
      return false;
    }
    for (let index: number = 0; index < this.postPagePosts.length; index++) {
      const post: MediaPost = this.postPagePosts[index];
      if (post.id.indexOf('profile-') === 0 || this.videoTried.has(post.shortcode)) {
        continue;
      }
      if (post.isVideo() && post.videoUrl.length === 0) {
        return true;
      }
      if (post.ownerAvatarUrl.length === 0 && post.ownerId.length > 0) {
        return true;
      }
      if (post.takenAtMs <= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 打开**视频分页的 Reels 页**（需求：点「我的」/别人主页视频那一段的格子 → 新页面，
   * 用 reels 模板、HdsNavigation 承载、左上角返回、标题 Reels、底部一个光感评论输入框）。
   *
   * 数据是**进页那一刻整份带进来**的（`posts` 就是那一分页目前的全部帖子），所以这一页
   * 一进去就有画面，不用等任何请求；触底翻页仍然交给 ProfilePage 那个闭包
   * （`loadMore` → 那一分页的 ProfileViewModel，和网格/帖子页共用同一条游标链）。
   *
   * `shortcode` 是点的那一条：Reels 那份会滤掉没有视频地址的条目（见 ProfileReelsViewModel
   * 的 toReels），所以按 shortcode 定位，不能按下标。
   */
  private openProfileReels(posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                           loadMore: () => Promise<ProfileStreamPage>): void {
    const vm: ProfileReelsViewModel =
      new ProfileReelsViewModel(posts, shortcode, hasMore, loadMore);
    if (vm.list().length === 0) {
      // 一条能播的都没有（这一段还没取到视频）：不进这一页，免得白屏。
      hilog.info(DOMAIN, TAG, 'profile reels skip: no video in %{public}d post(s)', posts.length);
      return;
    }
    this.profileReelsVm = vm;
    // 这一页已经在最上面了（理论上点不到：它压着网格）：不再压一层，免得"返回一次还在原地"。
    const names: Array<string> = this.navStack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === PROFILE_REELS_PAGE) {
      hilog.info(DOMAIN, TAG, 'profile reels already open n=%{public}d', vm.list().length);
      return;
    }
    hilog.info(DOMAIN, TAG, 'profile reels open n=%{public}d anchor=%{public}s more=%{public}s',
      vm.list().length, shortcode, `${hasMore}`);
    this.navStack.pushPath({ name: PROFILE_REELS_PAGE });
  }

  /**
   * 帖子页进页时**先备一页**（和这个项目其它地方一致："手里常备一页"——个人页预取 2 页、
   * 搜索 3 页、信息流 3 页）。
   *
   * 为什么需要：网格那一屏常常只加载了第一页。用户报的"要在分页加载帖子后帖子页面才会显示"
   * 就是这个 —— 帖子页现在**自己**往下要，不再依赖网格先翻完；触底之后由 FeedList 的
   * `onNearEnd` 继续要（见 loadPostPageMore）。
   *
   * 没有下一页时这一下**不花任何代价**：loader 一看 `moreOfTab` 为假就直接把当前这份还回来
   * （不发请求），`loadPostPageMore` 按"长度没变"把 postPageHasMore 置假、不再触发。
   */
  private fillPostPage(): void {
    this.loadPostPageMore();
  }

  /**
   * 把新一页**追加**到帖子页那份列表后面（按 shortcode 去重）。
   *
   * 为什么要去重：loader 在"没长起来 / 已经到底"那两条路上可能回空页、也可能回整份列表
   * （见 ProfilePage.pumpStream），去重之后这两种都能安全落地。
   */
  private static appendPosts(current: Array<MediaPost>, add: Array<MediaPost>): Array<MediaPost> {
    if (add.length === 0) {
      return current;
    }
    const seen: Set<string> = new Set<string>();
    const out: Array<MediaPost> = [];
    for (let index: number = 0; index < current.length; index++) {
      const one: MediaPost = current[index];
      seen.add(FeedMapper.keyOf(one));
      out.push(one);
    }
    for (let index: number = 0; index < add.length; index++) {
      const one: MediaPost = add[index];
      const key: string = FeedMapper.keyOf(one);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(one);
    }
    return out;
  }

  /**
   * 帖子页**再要一页**（触底 / 进页补一轮都走这里）。
   *
   * 三道闸：正在要就不再要、没有下一頁就不再要、没有 loader（理论上不会有）也不动。
   * 拿回来的是**这一分页最新的整份列表**（视图模型里那份，见 ProfilePage.makeStreamLoader）：
   * 直接替换而不是自己拼接，避免和视图模型那份错位（重复/漏条）。
   */
  private async loadPostPageMore(): Promise<void> {
    if (this.postPageLoadingMore || this.postPageLoadMore === null) {
      hilog.info(DOMAIN, TAG, 'post page more skipped busy=%{public}s loader=%{public}s',
        `${this.postPageLoadingMore}`, `${this.postPageLoadMore !== null}`);
      return;
    }
    // 视图模型说没有下一页了就不再触发（一开始是乐观的 true，第一次要完就会校准）。
    if (!this.postPageHasMore) {
      hilog.info(DOMAIN, TAG, 'post page more skipped: no more (n=%{public}d)',
        this.postPagePosts.length);
      return;
    }
    this.postPageLoadingMore = true;
    try {
      const before: number = this.postPagePosts.length;
      const page: ProfileStreamPage = await this.postPageLoadMore();
      if (page.posts.length > 0) {
        /*
         * **追加**而不是整体替换（需求："初次点进帖子页面时不将分页中的图片整理成 feeds 流"）。
         *
         * 进页时只有点中的那一条，loader 每次只回"这一轮新取到的几条"
         * （见 ProfilePage.makePostPageLoader 的增量语义），所以这里拼在后面。
         * `appendPosts` 按 shortcode 去重：loader 在"没长起来"那条路上会回空页、
         * 极端情况下也可能回整份列表，去重之后两种都能安全落地、不会重复。
         */
        this.postPagePosts = Index.appendPosts(this.postPagePosts, page.posts);
      }
      this.postPageHasMore = page.hasMore;
      hilog.info(DOMAIN, TAG, 'post page more %{public}d → %{public}d more=%{public}s',
        before, page.posts.length, `${this.postPageHasMore}`);
      // 新来的这几条里可能也有"只带封面"的视频：接着补地址（见 loadPostPageVideos）。
      this.loadPostPageVideos();
    } catch (error) {
      this.postPageHasMore = false;
    } finally {
      this.postPageLoadingMore = false;
    }
  }

  /**
   * 探针面板用：把**信息流**那条接口的完整模板存到原生侧。
   *
   * 为了验证"跨文档回放"：模板在 A 文档存下，页面整页重载（B 文档）之后还能不能拿来用。
   * 评论那条链路现在拿不到模板（帖子页读评论本身在超时），所以先用信息流这条做验证 ——
   * 机制是同一个（catch / stored / replay 都与接口无关）。
   */
  private async captureFeedTemplate(): Promise<void> {
    const ok: boolean = await ApiRegistry.getInstance().capture(FEED_TEMPLATE_KEY);
    hilog.info(DOMAIN, TAG, 'probe capture feed ok=%{public}s', ok ? 'y' : 'n');
  }

  /**
   * 探针面板用：把「我的」**四个分页**的接口模板都抓一遍。
   *
   * 四个分页在网页上是四个地址（`/用户名/`、`/用户名/reels/`、`/用户名/saved/`、`/用户名/tagged/`），
   * 各自发一条查询；原生 HTTP 那条路（core/NativeProfile）靠这些模板才能把对应分页拉下来。
   * 这里逐个导航 + capture，最后回到首页并把当前分页重新加载一次（模板齐了就走原生）。
   *
   * 用户名从"自己的主页地址"脚本里拿（`/用户名/`）—— 探针按钮可能在信息流页上被按，
   * 那时 ProfileViewModel 还没有 header 可用。
   */
  private async captureProfileTemplates(): Promise<void> {
    let username: string = '';
    try {
      const href: string = await this.bridge.runBridge(OWN_PROFILE_SCRIPT, 8000, 'own-profile');
      // 形如 `/用户名/`（也可能带查询串）。
      const parts: Array<string> = href.split('/').filter((one: string): boolean => one.length > 0);
      if (parts.length > 0) {
        username = parts[0].split('?')[0];
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'probe profile: own-profile failed: %{public}s',
        (error as Error).message);
    }
    if (username.length === 0) {
      hilog.warn(DOMAIN, TAG, 'probe profile: no own username');
      this.setLocalStatus($r('app.string.follow_failed'));
      return;
    }
    this.setLocalStatus($r('app.string.probe_profile_templates'));
    for (let tab: number = 0; tab < 4; tab++) {
      await this.profileVm.captureTab(username, tab);
    }
    // 抓完顺手落一份**四条接口的结构摘要**（`probe_profile_*.txt`）：哪个分页的媒体
    // 挂在哪一层、游标有没有，看这一份就知道（见 NativeProfile.digest）。
    this.dumpProbeFile('profile', await this.profileVm.digestTabs());
    // 模板齐了：把「我的」当前分页重新拉一次（这次会走原生 HTTP）。
    this.profileVm.load(true);
    hilog.info(DOMAIN, TAG, 'probe profile templates done %{public}s',
      ApiRegistry.getInstance().storedSummary());
  }

  /**
   * 探针面板用：抓**搜索页**的接口模板（需求："用探针抓一下模板"）。
   *
   * 走的是 SearchViewModel 的冷路径：导航到搜索页 → 抓该页全部请求 → 在页面搜索框里打一次字
   * 逼出"结果那条" → 回首页；跑完把结构摘要落进沙箱（`probe_search_*.txt`，见 dumpSearchDigest）。
   */
  private async captureSearchTemplates(): Promise<void> {
    this.setLocalStatus($r('app.string.probe_search_templates'));
    const digest: string = await this.searchVm.captureTemplates();
    hilog.info(DOMAIN, TAG, 'probe search templates done %{public}s | digest=%{public}d chars',
      ApiRegistry.getInstance().storedSummary(), digest.length);
  }

  /** 探针面板用：读当前页面里内嵌的评论数据，结果进 hilog 与探针报告。 */
  private async probeCommentsEmbed(): Promise<void> {
    try {
      const raw: string = await this.bridge.runBridge(DOM_COMMENTS_PROBE_SCRIPT, 12000, 'comments-embed');
      hilog.info(DOMAIN, TAG, 'comments embed probe %{public}s', raw);
      InstagramProbe.getInstance().setDomReport(`comments embed ${raw}`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'comments embed probe failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 探针面板用：把**当前页面**的接口模板全部抓下来，再逐个回放一次打出**结构摘要**
   * （写原生页面时照着它写解析）。
   *
   * 抓的是**全部**（filter 传空串 = 匹配所有操作名），不是只抓信息流那一条：做「私信」「搜索」
   * 这些新页面时，要看的正是那几个操作的响应结构 —— 页面停在哪一页，就抓哪一页的接口。
   */
  private async probeDigests(): Promise<void> {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    // 空过滤器 = 全都要（见 ApiRegistry.capture 的说明）。
    const stored: boolean = await registry.capture('');
    hilog.info(DOMAIN, TAG, 'digest capture all ok=%{public}s %{public}s',
      stored ? 'y' : 'n', registry.storedSummary());
    const names: Array<string> = registry.storedNames();
    if (names.length === 0) {
      hilog.info(DOMAIN, TAG, 'digest: no stored template (%{public}s)', registry.storedSummary());
      return;
    }
    for (let index: number = 0; index < names.length && index < 12; index++) {
      const digest: DigestResult | null = await registry.replayDigest(names[index], {}, 5, 140);
      if (digest === null) {
        hilog.info(DOMAIN, TAG, 'digest %{public}s: null', names[index]);
        continue;
      }
      hilog.info(DOMAIN, TAG, 'digest %{public}s state=%{public}s http=%{public}d n=%{public}d %{public}s',
        names[index], digest.state, digest.http, digest.lines.length, digest.text());
    }
  }

  /** 探针面板用：用原生侧存下来的模板回放一次，并把关键结果打进日志。 */
  private async replayStoredTemplate(): Promise<void> {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    const result: ReplayResult | null =
      await registry.replayStored(FEED_TEMPLATE_KEY, {}, 200000);
    if (result === null) {
      hilog.info(DOMAIN, TAG, 'probe stored replay: no template (stored=%{public}s)',
        registry.storedSummary());
      return;
    }
    // 判据只看"这是一份正常的 GraphQL 响应"：HTTP 200 + 响应体里有 data 字段。
    const hit: boolean = result.body.indexOf('"data"') >= 0;
    hilog.info(DOMAIN, TAG,
      'probe stored replay state=%{public}s http=%{public}d ms=%{public}d bytes=%{public}d data=%{public}s',
      result.state, result.http, result.ms, result.bytes, hit ? 'y' : 'n');
  }

  /**
   * 探针面板上的「打开某个页面」：把常驻网页揭出来导航过去。
   *
   * **不收起面板**：下面几个探测按钮（结构摘要 / 存信息流模板 / 读内嵌评论）都要对着
   * "当前这个页面"跑脚本，面板留着才连着点得到；要看网页本身，按面板上的「关闭」即可。
   */
  private openWebFromProbe(url: string): void {
    this.openWeb(url);
  }

  /**
   * 顺手同步一次「接口登记表」（见 ApiRegistry）。
   *
   * 只登记、不取数；索引自带 20 秒 TTL（在 ApiRegistry 里），所以切页、网页加载完、
   * 一轮取数结束都可以放心调。目的是：在 reels / 私信 / 搜索 / 我的 逛一圈之后，
   * 日志里能直接看到这几页用到的 GraphQL 操作名（登记表只在清单变化时打一行）。
   */
  private syncApiIndex(): void {
    ApiRegistry.getInstance().sync(false);
  }

  /**
   * 顺手抓一次评论模板（带节流）。
   *
   * 为什么不能只在"打开评论"时抓：帖子的评论请求只有**网页真的进到那条帖子**才会发，
   * 而那一步在网页上是 **SPA 弹层**，不会触发 pageReady。所以这里挂在"路由变化 /
   * 加载完成 / 切页"几处，并且节流 —— 页面上真有评论模板时存下来，下次打开评论就能
   * 直接回放（不用再导航一次）。
   */
  private captureCommentTemplate(): void {
    const now: number = Date.now();
    if (now - this.lastCommentCaptureMs < COMMENT_CAPTURE_MIN_INTERVAL_MS) {
      return;
    }
    this.lastCommentCaptureMs = now;
    ApiRegistry.getInstance().capture(COMMENT_TEMPLATE_KEY);
  }

  /**
   * 通知：打开窗口 → 立刻去原生取一趟。
   *
   * 取数链路见 loadNotifications（一条原生链：inbox → show_many → ayml）。
   * 页面空着的时候显示"正在读取通知…"，取回来就是最新的。
   */
  private async openNotifications(): Promise<void> {
    // 已经在通知页就不要再压一层：标题栏那颗爱心的菜单项在个别情况下 down/up 会各回调一次，
    // 连着压两层的话"返回"一次还停在通知页上（像点了没反应）。按路由栈顶判断，已经在
    // 通知页就只刷新。
    const names: Array<string> = this.navStack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === NOTIFICATIONS_PAGE) {
      hilog.info(DOMAIN, TAG, 'notify page already open → refresh only');
      this.refreshNotifications();
      return;
    }
    this.navStack.pushPath({ name: NOTIFICATIONS_PAGE });
    await this.loadNotifications();
  }

  /**
   * 抓通知：**一趟原生**（core/NativeNotifications）。
   *
   * 链路：`news/inbox`（通知主列表）→ `friendships/show_many`（这批人的关注状态）→
   * `discover/ayml`（为你推荐）。三条都走原生直发，会话头复用信息流模板那份
   * （Cookie / csrftoken / x-ig-app-id / UA），**不再导航隐藏网页、也不再扫 DOM**。
   *
   * 两点：**不先清空** `notifications`（旧列表显示到新数据回来），取回来整份替换；
   * 整个过程 `notificationsRefreshing` 为 true，通知页的原生下拉刷新动画会一直转，
   * 用户看得见"正在取数据"。
   */
  private async loadNotifications(warmOnly: boolean = false): Promise<void> {
    if (this.notificationsBusy) {
      // 已经在取了（例如刚打开页面就开始取、用户这会儿又下拉了一下）：不重入。
      return;
    }
    this.notificationsBusy = true;
    this.notificationsState = '';
    this.notificationsDiag = '';
    this.notificationsLoading = true;
    this.notificationsRefreshing = true;
    const started: number = Date.now();
    try {
      // 「为你推荐」（ayml）那条接口的原生请求需要网页专有令牌（x-ig-www-claim / fb_dtsg），
      // 那只有"页面自己发过一次 ayml"才有 → 第一次（或模板过期后）先去抓一次模板。
      //
      // **预热时跳过这一步**（warmOnly）：抓模板会把**共用的隐藏网页**导航到活动页再回来，
      // 启动那几秒正是信息流的网页补充那条路在用同一个网页 —— 预热不该把它抢走。
      // 跳过之后通知主体（news/inbox → show_many）照样是原生取回来的，只是"为你推荐"那一段
      // 空着；用户真的点开通知页时再按正常那条路抓模板（那时网页也不忙）。
      if (warmOnly && ApiRegistry.getInstance().storedForNative(AYML_OP) === null) {
        hilog.info(DOMAIN, TAG, 'notify warm: ayml template missing → skip cold path');
      } else {
        await this.ensureAymlTemplate();
      }
      // **一趟到底**：原生一条链（news/inbox → show_many → ayml），不再有第二段网页流程。
      const fresh: NotifyItem[] = await this.readNotificationsFast();
      if (fresh.length > 0) {
        // 整份替换：fresh 已经是"通知 + 关注状态 + 为你推荐"的完整集合。
        this.notifications = fresh;
        this.notificationsLoading = false;
      } else if (this.notifications.length === 0) {
        this.notificationsState = 'failed';
      }
      hilog.info(DOMAIN, TAG, 'notify done items=%{public}d src=%{public}s %{public}dms',
        this.notifications.length, this.notifySrc, Date.now() - started);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'notify error: %{public}s', (error as Error).message);
      if (this.notifications.length === 0) {
        this.notificationsState = 'failed';
      }
    } finally {
      this.notificationsLoading = false;
      this.notificationsRefreshing = false;
      this.notificationsBusy = false;
    }
  }

  /** 用户下拉刷新：跑同一趟取数（重入由 loadNotifications 挡掉）。 */
  private refreshNotifications(): void {
    this.loadNotifications();
  }

  /**
   * 通知取数：**完全原生**（不再依赖隐藏网页）。
   *
   * core/NativeNotifications 一条链打三个 REST：
   *   news/inbox（通知主列表）→ friendships/show_many（这批人的关注状态）→ discover/ayml（为你推荐）；
   * 会话头复用信息流模板那份（Cookie / csrftoken / x-ig-app-id / UA），失败时回空数组，
   * 页面走进"读不到通知"的提示 —— 不会再退回网页脚本（那条路已经删掉）。
   */
  private async readNotificationsFast(): Promise<NotifyItem[]> {
    try {
      const native: NotificationsPayload = await NativeNotifications.fetch(Date.now());
      const items: NotifyItem[] = this.mapNotifications(native);
      this.notifySrc = items.length > 0 ? 'native' : 'none';
      hilog.info(DOMAIN, TAG, 'notify native items=%{public}d src=%{public}s',
        items.length, this.notifySrc);
      return items;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'notify native failed: %{public}s', (error as Error).message);
      this.notifySrc = 'none';
      return [];
    }
  }



  /**
   * 确保「为你推荐」（ayml）那条 REST 模板在原生侧。
   *
   * 为什么要模板：这条接口是 `/api/v1/` 的 POST，只有网页自己发的时候才带
   * `x-ig-www-claim`（会话级 hmac）、`x-instagram-ajax`、`x-asbd-id` 和表单令牌
   * `fb_dtsg`/`jazoest`；原生裸发的结果是 IG 回**一整页 HTML**（真机实测：GET 405、
   * POST 200/404 + 641KB 页面），所以"为你推荐"整段永远空着。
   *
   * 做法和私信/搜索/个人页那几条冷路径完全一样：让常驻网页打开一次活动页，
   * 页面自己会发 ayml（"为你推荐"就是它渲染的），抓下来存进模板表（24 小时有效），
   * 之后原生照着模板回放 —— 运行期不再依赖网页。
   */
  private async ensureAymlTemplate(): Promise<boolean> {
    if (ApiRegistry.getInstance().storedForNative(AYML_OP) !== null) {
      return true;
    }
    if (this.aymlCapturing) {
      return false;
    }
    this.aymlCapturing = true;
    hilog.info(DOMAIN, TAG, 'ayml template missing → open activity page once');
    try {
      this.bridge.loadUrl(ACTIVITY_URL);
      await this.bridge.awaitPageReady(AYML_NAV_TIMEOUT_MS);
      for (let attempt: number = 1; attempt <= AYML_CAPTURE_POLLS; attempt++) {
        await ApiRegistry.getInstance().capture(AYML_OP);
        if (ApiRegistry.getInstance().storedForNative(AYML_OP) !== null) {
          hilog.info(DOMAIN, TAG, 'ayml template captured try=%{public}d', attempt);
          this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
          this.aymlCapturing = false;
          return true;
        }
        if (attempt < AYML_CAPTURE_POLLS) {
          await this.delay(AYML_CAPTURE_GAP_MS);
        }
      }
      hilog.warn(DOMAIN, TAG, 'ayml template not captured: %{public}s',
        ApiRegistry.getInstance().storedSummary());
      // 抓不到也要把网页送回首页：它停在活动页会让信息流模板过期。
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      this.aymlCapturing = false;
      return false;
    } catch (error) {
      this.aymlCapturing = false;
      hilog.warn(DOMAIN, TAG, 'ayml template capture failed: %{public}s', (error as Error).message);
      return false;
    }
  }

  /** 原生取回的 payload → UI 用的条目（含分组与日期文案）。 */
  private mapNotifications(payload: NotificationsPayload | null): NotifyItem[] {
    if (payload === null) {
      return [];
    }
    const diag: string = payload.diag ?? payload.message ?? '';
    this.notificationsDiag = diag;
    if (diag.length > 0) {
      hilog.info(DOMAIN, TAG, 'notify diag: %{public}s', diag);
    }
    const raw: NotifyPayloadItem[] = payload.items ?? [];
    const out: NotifyItem[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      const one: NotifyPayloadItem = raw[i];
      const isSuggested: boolean = (one.group ?? '') === 'suggested';
      // 推荐项直接按 suggested 归组；通知项按时间戳算今天 / 本月 / 更早。
      const group: NotifyGroup = isSuggested ? 'suggested' : this.groupOf(one.ts ?? 0);
      // 关注状态同样以**本地点过的**为准（core/FollowState）：信息流里刚关注过的人，
      // 通知页这次取回来的旧快照不该再显示成"未关注"。
      const following: boolean = FollowState.resolve(one.userId ?? '',
        FollowState.resolveName(one.username ?? '', one.following ?? false));
      // 按钮文案：**先看原生给的 button**（只有关注类通知才有），有才谈"回关 / 发消息"。
      //
      // 不能写成 `following ? 'following' : …` 一刀切：点赞快拍那条的按钮位是空的，
      // 但如果点赞的人我恰好已关注（following=true），一刀切就会给一条"赞了你的快拍"
      // 画出发消息按钮。
      const canFollow: boolean = (one.button ?? '').length > 0;
      const buttonLabel: string = isSuggested ? ''
        : (canFollow ? (following ? 'following' : 'follow') : '');
      out.push(new NotifyItem(
        group,
        one.avatars ?? [],
        one.usernames ?? [],
        one.text ?? '',
        this.dateTextOf(one.date, one.ts ?? 0),
        one.thumb ?? '',
        buttonLabel,
        following,
        one.username ?? '',
        one.displayName ?? '',
        one.social ?? '',
        // 「回关」按钮发 HTTP 要用的用户 id（见 NativeFollow.setFollowing）。
        one.userId ?? ''
      ));
    }
    return out;
  }

  /**
   * 时间戳 → 分组。
   *
   * 今天的算"今天"，同一自然月内的算"本月"，其余算"更早" —— 和参考图一致。
   * 时间戳拿不到（0）就落到"更早"，至少不会丢。
   */
  private groupOf(ts: number): NotifyGroup {
    if (ts <= 0) {
      return 'earlier';
    }
    const now: Date = new Date();
    const then: Date = new Date(ts);
    if (now.getFullYear() === then.getFullYear() && now.getMonth() === then.getMonth()) {
      return now.getDate() === then.getDate() ? 'today' : 'month';
    }
    return 'earlier';
  }

  /** 时间戳 → "9月19日"（网页给了现成文案就优先用它）。 */
  private dateTextOf(given: string | undefined, ts: number): string {
    if (given !== undefined && given.length > 0) {
      return given;
    }
    if (ts <= 0) {
      return '';
    }
    const then: Date = new Date(ts);
    return `${then.getMonth() + 1}月${then.getDate()}日`;
  }

  /**
   * 点「回关」：先乐观翻转，再用服务端/网页回报的状态校正。
   *
   * 两条路（和信息流的关注按钮同一套）：
   *   ① **HTTP 直发**（core/NativeFollow）：`POST /api/v1/friendships/create/{id}/`，
   *      头与表单令牌取自网页抓来的 REST 模板（`x-ig-www-claim` / `fb_dtsg` / `jazoest`）——
   *      少了这些 IG 只回一整页 HTML，这正是"点了没反应"的原因。
   *   ② ①失败才退回**网页驱动**（followAccount：打开对方主页点它的关注按钮）。
   *
   * 乐观翻转放在最前面：HTTP/导航都是秒级的，等结果再变色会像「点了没反应」。
   * 失败就回滚，并弹一句提示。
   */
  private async toggleFollow(item: NotifyItem): Promise<void> {
    const name: string = item.accountName();
    // 已关注的条目在界面上根本没有关注按钮（那颗换成了「发消息」），不该走到这里。
    // 名字为空也照样放行：**关注本身只认用户 id**（HTTP 请求用的是它），
    // 名字只用来做本地状态匹配（见 NativeNotifications.storyToItem 里从 destination 挖名字）。
    if ((name.length === 0 && item.userId.length === 0) || item.following) {
      return;
    }
    const key: string = name.length > 0 ? name.toLowerCase() : item.userId;
    // 同一个账号正在处理中、或者网页正在别处导航（信息流/帖子页），都不掺和。
    if (this.followingKeys.has(key) || this.navigating) {
      return;
    }
    this.followingKeys.add(key);
    // 先翻转，点下去立刻有反馈；下面再用真实结果校正。
    this.setFollowing(name, true);
    FollowState.remember(item.userId, name, true);
    try {
      const native: FollowResult = await NativeFollow.setFollowing(item.userId, true);
      if (native.ok && native.following) {
        this.setFollowing(name, true);
        this.toast($r('app.string.follow_done'));
        return;
      }
      hilog.warn(DOMAIN, TAG, 'notify follow http failed (%{public}s) id=%{public}s → web',
        native.detail, item.userId);
      const outcome: FollowOutcome | null = await this.followAccount(name);
      if (outcome === null) {
        this.setFollowing(name, false);
        FollowState.remember(item.userId, name, false);
        hilog.info(DOMAIN, TAG, 'follow failed: %{public}s', name);
        this.toast($r('app.string.follow_failed'));
      } else if (outcome.following) {
        // 用网页上的实际状态校正：列表里显示的状态可能是抓错了的（点一下正好修回来）。
        this.setFollowing(name, true);
        FollowState.remember(item.userId, name, true);
        // 只有"这次真的点了"才报结果：页面上本来就是已关注时不必弹提示。
        if (outcome.clicked) {
          this.toast($r('app.string.follow_done'));
        }
      } else {
        // 点了但网页上还是未关注：如实说没成功，界面保持网页上的真实状态。
        this.setFollowing(name, false);
        FollowState.remember(item.userId, name, false);
        hilog.info(DOMAIN, TAG, 'follow unchanged: %{public}s', name);
        this.toast($r('app.string.follow_failed'));
      }
    } catch (error) {
      this.setFollowing(name, false);
      FollowState.remember(item.userId, name, false);
      hilog.warn(DOMAIN, TAG, 'follow error: %{public}s', (error as Error).message);
      this.toast($r('app.string.follow_failed'));
    } finally {
      this.followingKeys.delete(key);
    }
  }

  /**
   * 真的去网页里关注一个账号：导航到对方主页 → 等头部按钮出现 → 点它 → 回首页。
   *
   * 返回**网页上的实际状态**（FollowOutcome）：following 是网页上真实是否已关注；
   * null 表示没做成（主页没有关注按钮、URL 没对上、脚本报错）—— 由调用方回滚。
   *
   * 只做关注这一个方向：取关（点「已关注」）在网页侧要点一个二次确认菜单，而那个菜单
   * **只认真实用户的触摸手势** —— 实测用脚本合成点击（连 pointer 事件都补上了）菜单
   * 始终不弹（`dlg=0 hasUnfollow=false`，整页文字里根本没有"取消关注"），所以取关
   * 从这个 App 里触发不了，通知页上那颗按钮改成了「发消息」（见 NotificationsPanel）。
   *
   * 为什么要拆成好几步、等待都放在原生侧：最初写成一个"在页面里 await 到底"的长脚本，
   * 实测会**整整卡满超时**（脚本跑了 20 秒一个回报都没有）—— 主页是分段水合的，中途
   * 页面自己的一次重载/路由跳转就会把执行上下文连同回调一起丢掉。拆开之后每一步都是
   * 不含 await 的短脚本，页面再怎么跳转也只是某一步丢了、退化成一次可重试的读取。
   */
  private async followAccount(name: string): Promise<FollowOutcome | null> {
    this.navigating = true;
    this.bridge.loadUrl(`https://www.instagram.com/${name}/`);
    const ready: string = await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    hilog.info(DOMAIN, TAG, 'nav to profile ready=%{public}s name=%{public}s', ready, name);
    let outcome: FollowOutcome | null = null;
    try {
      if (ready !== 'ready') {
        return null;
      }
      // 1) 等头部那颗按钮渲染出来（主页水合慢，这里轮询）。
      const state: FollowPageState | null = await this.waitFollowButton(name);
      if (state === null) {
        return null;
      }
      // 2) 网页上其实已经关注了：不用点，只把**真实状态**带回去（界面可能显示错了）。
      if (state.following ?? false) {
        hilog.info(DOMAIN, TAG, 'follow already name=%{public}s label=%{public}s',
          name, state.label ?? '');
        return new FollowOutcome(true, false);
      }
      // 3) 点它。
      const click: FollowClickResult = await this.clickFollow(name);
      if (click.state !== 'clicked' && click.state !== 'already') {
        hilog.info(DOMAIN, TAG, 'follow click state=%{public}s seen=%{public}s',
          click.state, click.seen ?? '');
        return null;
      }
      const clicked: boolean = click.state === 'clicked';
      if (clicked) {
        hilog.info(DOMAIN, TAG, 'follow clicked name=%{public}s node=%{public}s',
          name, click.node ?? '');
      }
      // 4) 等页面把状态改完，再读一次：用**网页上的实际结果**校正界面，不靠猜。
      await this.delay(FOLLOW_SETTLE_MS);
      const after: FollowPageState | null = await this.waitFollowButton(name);
      const now: boolean = after === null ? true : (after.following ?? true);
      outcome = new FollowOutcome(now, clicked);
      hilog.info(DOMAIN, TAG, 'follow done name=%{public}s actual=%{public}s',
        name, now ? '1' : '0');
    } catch (error) {
      outcome = null;
    } finally {
      await this.returnToFeed();
    }
    return outcome;
  }

  /**
   * 轮询读对方主页头部的关注按钮，直到它出现（或到上限）。
   *
   * 主页是分段水合的，`onPageEnd` 时头部按钮常常还没渲染出来，所以不能只读一次。
   * 读不到返回 null（附最后一次的回报到日志里，便于定位是"没按钮"还是"URL 不对"）。
   */
  private async waitFollowButton(name: string): Promise<FollowPageState | null> {
    let last: string = '';
    for (let attempt: number = 0; attempt < FOLLOW_BUTTON_TRIES; attempt++) {
      const raw: string = await this.bridge.runBridge(followStateScript(name), FOLLOW_STEP_TIMEOUT_MS);
      last = raw;
      let state: FollowPageState | null = null;
      try {
        state = JSON.parse(raw) as FollowPageState;
      } catch (error) {
        state = null;
      }
      if (state !== null && state.state === 'ok') {
        return state;
      }
      await this.delay(FOLLOW_BUTTON_POLL_MS);
    }
    hilog.info(DOMAIN, TAG, 'follow button not found: %{public}s', last);
    return null;
  }

  /** 点一下主页头部的关注按钮（脚本本身不做等待）。 */
  private async clickFollow(name: string): Promise<FollowClickResult> {
    const raw: string = await this.bridge.runBridge(followClickScript(name), FOLLOW_STEP_TIMEOUT_MS);
    try {
      return JSON.parse(raw) as FollowClickResult;
    } catch (error) {
      return { state: 'error', message: 'unparsable' };
    }
  }

  /** 原生侧的短暂等待（`await this.delay(ms)`）。 */
  private delay(ms: number): Promise<string> {
    const step: DelayStep = new DelayStep();
    step.promise = new Promise<string>((resolve: (value: string) => void): void => {
      step.resolve = resolve;
    });
    setTimeout((): void => {
      step.resolve('done');
    }, ms);
    return step.promise;
  }

  /**
   * 就地把某个账号的关注状态换掉（列表整体替换，同 FeedMapper.withLiked 的做法）。
   *
   * 通知项和「为你推荐」里可能出现同一个账号（比如同一个人既点了赞又在推荐列表里），
   * 所以按用户名**全列表**匹配，一次改干净，免得同一个账号两处状态不一致。
   */
  private setFollowing(name: string, following: boolean): void {
    const key: string = name.toLowerCase();
    const next: NotifyItem[] = [];
    let changed: boolean = false;
    for (let i: number = 0; i < this.notifications.length; i++) {
      const one: NotifyItem = this.notifications[i];
      if (one.accountName().toLowerCase() === key && one.following !== following) {
        next.push(one.withFollowing(following));
        changed = true;
      } else {
        next.push(one);
      }
    }
    if (changed) {
      // 换新数组：@Prop 只在数组身份变化时才把新值推给面板。
      this.notifications = next;
    }
  }

  /**
   * 关注状态在**别处**被改了（用户主页那一行 / 首页卡片 / 通知页自己那颗按钮）。
   *
   * 见 core/FollowState 的文件头"全局刷新"：覆盖表变了只会让**下一次** `resolve` 拿到新值，
   * 已经画出来的界面是算一次就定住的，得在这里主动重算。本页管着两处：
   *   ① 帖子页标题栏右上角那颗「关注」（没关注才出现）；
   *   ② 通知列表里每个账号的「回关 / 发消息」。
   * 首页那份列表由 FeedList 自己盯同一个版本号（那边是 @ObjectLink 就地重绘，见 syncFollowStates）。
   */
  private onFollowVersion(): void {
    this.syncPostPageFollow();
    this.syncNotifyFollowStates();
  }

  /**
   * 帖子页标题栏那颗「关注」按覆盖表重算。
   *
   * 没有覆盖值时以**当前值**兜底（= 不变）：接口给的初值在 openPostStream 里已经算过一次，
   * 这里只负责"别处点过之后跟着变"。
   */
  private syncPostPageFollow(): void {
    if (this.postPageAuthorId.length === 0) {
      return;
    }
    const known: boolean = FollowState.resolve(this.postPageAuthorId,
      FollowState.resolveName(this.postPageAuthor, this.postPageFollowed));
    if (this.postPageFollowed !== known) {
      this.postPageFollowed = known;
      hilog.info(DOMAIN, TAG, 'PST follow refresh → %{public}s', known ? 'y' : 'n');
    }
  }

  /**
   * 通知列表里每个账号的关注状态按覆盖表重算（判据同 setFollowing：按账号名全列表匹配）。
   *
   * 整体替换数组：`NotifyItem` 的字段是只读的，面板的 `ForEach` 又是按"值 + following"做 key 的
   * —— 换新对象列表那一项才会重建，按钮才会从「回关」变成「发消息」。
   */
  private syncNotifyFollowStates(): void {
    const next: NotifyItem[] = [];
    let changed: boolean = false;
    for (let i: number = 0; i < this.notifications.length; i++) {
      const one: NotifyItem = this.notifications[i];
      const known: boolean = FollowState.resolve(one.userId,
        FollowState.resolveName(one.accountName(), one.following));
      if (known !== one.following) {
        next.push(one.withFollowing(known));
        changed = true;
      } else {
        next.push(one);
      }
    }
    if (changed) {
      this.notifications = next;
      hilog.info(DOMAIN, TAG, 'NTF follow refresh');
    }
  }

  /**
   * 标题栏那颗加号：跳转到"发布新帖子"页面（见 pages/CreatePost.ets）。
   *
   * 用 router 打开一个**独立的新页面**（必须登记在 resources/base/profile/main_pages.json 里），
   * 而不是浮层/弹窗：发布是一个完整的编辑流程，需要自己的整屏空间和返回栈，
   * 页面自己的返回键 popUrl 回来即可。
   */
  private openCreatePost(): void {
    if (this.webVisible) {
      // 正在看网页时先收起网页，免得返回栈里叠着一层网页 chrome。
      this.closeWeb();
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/CreatePost' })
      .catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'open create page failed: %{public}s', err.message);
      });
  }

  /** 关掉网页回到原生视图：用罐里的最新会话决定下一步，而不是沿用旧状态。 */
  private async closeWeb(): Promise<void> {
    /*
     * **临时探针**：关掉网页浮层时，把网页刚抓到的请求名打出来。
     *
     * 为什么放这儿：私信翻页要抓的是"网页自己翻历史时发的那条请求"，而网页的消息容器只认
     * 真实触摸 —— 我在可见网页里滑完、关掉浮层，这一下 `capture('')` 就把页面钩子里的请求
     * 倒进模板表，`recentNames` 再列出最近更新过的。之前把探针放在会话页里，打开网页浮层时
     * 那个页面被卸载、定时器跟着没了，所以一直打不出来。打通翻页后删掉这一段。
     */
    ApiRegistry.getInstance().capture('').then((): void => {
      hilog.info(DOMAIN, TAG, 'web probe recent=%{public}s',
        ApiRegistry.getInstance().recentNames(60000).join('|'));
    }).catch((): void => {
    });
    this.webVisible = false;
    this.selectedTab = AppTab.Home;
    // 同上（审计 C1）：绕过 selectTab 时要显式同步搜索页的可见性闸门。
    this.searchVm.setActive(false);
    const signedBefore: boolean = this.signedIn;
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    this.applySession(snapshot.signedIn);
    if (!snapshot.signedIn) {
      return;
    }
    if (signedBefore && this.bridge.isReady()) {
      // 登录态没变：网页没有被重载，但它这会儿多半**停在帖子页 / 活动页**上（用户刚看完）。
      // 这一步整页导航回首页不能省：信息流的游标翻页靠的是"网页当前这份文档里记着的
      // feed 请求配置"，停在别处就等于没有 —— 用户关掉网页以后回到信息流，再往下滑
      // 就永远加载不出新帖子了（读通知 / 读评论 / 读个人页那几条路都有回首页这一步，
      // 只有"用户自己打开网页再看回来"这条漏了）。
      await this.returnToFeed();
      if (this.viewModel.list().length === 0) {
        // 列表本来就空：顺带把首屏读出来（有内容时不重读，免得列表闪一下）。
        this.viewModel.loadFeed();
      }
    }
    // 刚确认登录时 applySession 已把网页送回首页，等它加载完会自动读流。
  }

  /** 网页 chrome 的返回：网页能后退就后退，否则当作关闭回到原生。 */
  private handleWebBack(): void {
    if (this.bridge.canGoBack()) {
      this.bridge.goBack();
      return;
    }
    this.closeWeb();
  }

  /**
   * ⚠️ 目前**没有调用方**（暂时保留，不是遗漏）。
   *
   * 原来是「我的」标签的实现：先用 OWN_PROFILE_SCRIPT 从网页里查出自己的主页地址，
   * 再把网页载过去。标签改成原生页面之后这条路不再被点了 —— 但它查地址那一步正是
   * 将来做**原生**「我的」页面时需要的（原生要显示谁的主页，就得先知道地址），
   * 所以留着，等原生实现接上。若确定不做原生「我的」页，连同 runProfileLookup 一起删。
   */
  private openProfile(): void {
    if (!this.signedIn) {
      this.openLoginWeb();
      return;
    }
    this.runProfileLookup();
  }

  private async runProfileLookup(): Promise<void> {
    this.busy = true;
    try {
      const href: string = await this.bridge.runBridge(OWN_PROFILE_SCRIPT, 10000);
      if (href.length > 1 && href.charAt(0) === '/') {
        this.openWeb(`${AppConfig.INSTAGRAM_HOME_URL.replace(/\/$/, '')}${href}`);
      } else {
        this.openWeb(AppConfig.INSTAGRAM_HOME_URL);
      }
    } catch (error) {
      this.openWeb(AppConfig.INSTAGRAM_HOME_URL);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 切换底部标签。
   *
   * 只切**原生页面**：标签栏现在是真的 tab 容器（Tabs 自己切 TabContent），
   * 不再把常驻网页揭出来。非 Home 的标签目前是占位页（还没有原生实现）。
   *
   * 网页并没有废弃 —— 它仍然用在别处：打开帖子、登录、读评论、探针。
   * AppConfig 里的 SEARCH / REELS / DIRECT 地址也留着，等这几个标签做出原生实现时
   * 可能还要用（现在是没人引用了）。
   */
  private selectTab(tab: AppTab): void {
    this.selectedTab = tab;
    // 用户动作：后台预热让路（切页后新页面自己要先读，别和它抢网络/线程）。
    this.lastInteractionMs = Date.now();
    // 换页面就把底栏复位（上一页可能把它沉下去/藏起来了；新页面还没滚过，
    // 栏沉在那儿会很怪）。系统显隐那支也一样收干净（见 restoreBar / showBar）。
    this.restoreBar();
    // 搜索框每次进「搜索」页都从**展开**开始（上一轮可能滚着滚着收起来了；
    // 新进来还没滚过，右上角只挂一颗放大镜会很莫名）。只改状态，**不要**顺带弹输入法。
    AppStorage.setOrCreate(SEARCH_BOX_COLLAPSED, false);
    if (this.barHidden) {
      this.showBar();
    }
    // Reels 进出要换应用配色（进 = 深色、出 = 交回系统，见 syncReelsColorMode）。
    this.syncReelsColorMode();
    // 切页顺手登记一次接口（有 TTL，不会真的每次都过桥）。
    this.syncApiIndex();
    // 也顺手看看评论模板到了没有（同样有节流）。
    this.captureCommentTemplate();
    if (tab === AppTab.Home && this.viewModel.list().length === 0) {
      this.viewModel.loadFeed();
    }
    // 搜索页：进来就确保模板 + 拉推荐（幂等，见 SearchViewModel.open）。
    if (tab === AppTab.Search) {
      this.searchVm.open();
      // `open()` 一次进程只跑一遍，而它可能正撞上接口限流（那一轮推荐是空的/只有旧缓存）：
      // 每次切到这一页再试一次，冷却过去了就能自己恢复（见 SearchViewModel.retryRecommend）。
      this.searchVm.retryRecommend();
    }
    // 「我的」：进来就把**四个分页的 feeds 页**都备好（需求）—— 数据那一半见
    // ProfileViewModel.prefetchOthers/prefetchNext，媒体那一半（封面小图 + 图片预下载，
    // 多图只两张）见 preloadAllSegments。幂等，切回来不会重复拉。
    if (tab === AppTab.Profile) {
      this.profileVm.preloadAllSegments();
    }
    // 搜索页的可见性：不可见时它**不接受滚动触发的翻页**（Tabs 会把五个分页都建出来，
    // 隐藏的瀑布流视口是 0，"接近底部"永远成立 —— 会把整条推荐流一路拉到底）。
    this.searchVm.setActive(tab === AppTab.Search);
  }

  // ==========================================================================
  // 深链（deep link）
  //
  // 外部（系统浏览器 / 其他 App / 二维码）打开 instarmony://open?... 时，EntryAbility 把
  // Want.uri 解析成 DeepLinkIntent：冷启动先铺 pages/DeepLink，热启动存进 core/DeepLink 的
  // pending（见它的 onNewWant）。**执行**统一收在这里 —— 因为"当前能不能切页/导航网页"
  // 只有本页面知道。
  // ==========================================================================

  /** 深链执行正在跑（防重入：消费过程中会换 tab / 导航网页，可能再次触发 onPageShow）。 */
  private deepLinkRunning: boolean = false;

  /**
   * 取走待执行的深链意图并执行。
   *
   * 三个调用时机（都在下面）：
   *   · 网页桥就绪（setReadyHandler）—— 冷启动主路径；
   *   · 页面重新显示（onPageShow）—— 热启动：App 已在首页，onNewWant 存下 pending 后回到前台；
   *   · 用户从落地页点「打开」进首页 —— 其实也是走桥就绪那条。
   *
   * 取走即清（DeepLink.take），所以同一条链接不会被反复执行。
   */
  private async consumePendingDeepLink(): Promise<void> {
    if (this.deepLinkRunning || !DeepLink.hasPending()) {
      return;
    }
    this.deepLinkRunning = true;
    try {
      const intent: DeepLinkIntent | null = DeepLink.take();
      if (intent === null) {
        return;
      }
      if (!intent.isComplete()) {
        // 认识这个 scheme、但目标不完整（例如 profile 没给 id）：不猜，落到首页并在日志里留痕。
        hilog.warn(DOMAIN, TAG, 'deep link incomplete, ignored: %{public}s', intent.raw);
        return;
      }
      hilog.info(DOMAIN, TAG, 'executing deep link %{public}s', intent.describe());
      switch (intent.route) {
        case DeepLinkRoute.Reels:
          this.selectTab(AppTab.Reels);
          return;
        case DeepLinkRoute.Search:
          this.selectTab(AppTab.Search);
          return;
        case DeepLinkRoute.Direct:
          this.selectTab(AppTab.Direct);
          return;
        case DeepLinkRoute.Profile:
          // 深链只带用户名、没有数字 id：走搜索页并按该用户名发起一次搜索。
          // 为什么不直接 openUserProfile：那条路要先按用户名换出数字 id（ProfileViewModel
          // 的查询链），属于"进主页之后"的事；搜索页是一次现成的、按名字能出结果的入口。
          this.selectTab(AppTab.Search);
          this.searchVm.search(intent.id);
          return;
        case DeepLinkRoute.Post:
          await this.openDeepLinkPost(intent);
          return;
        default:
          this.selectTab(AppTab.Home);
          return;
      }
    } finally {
      this.deepLinkRunning = false;
    }
  }

  /**
   * 等"网页宿主就绪"（`bridgeReady`）或超时。
   *
   * 为什么不用 PageBridge 自己的 `awaitPageReady`：那条路等的是"当前这次的页面加载完成"，
   * 而这里要等的是"宿主建好并跑完首帧、可以接受 loadUrl 了"——判据是 Index 自己的
   * bridgeReady 标志（由 setReadyHandler 置位）。轮询间隔取 150ms：状态一变就往下走，
   * 又不会在冷启动那一两秒里空转。
   */
  private async waitBridgeReady(timeoutMs: number): Promise<void> {
    const deadline: number = Date.now() + timeoutMs;
    while (!this.bridgeReady && Date.now() < deadline) {
      await Index.delay(DEEP_LINK_READY_POLL_MS);
    }
  }

  /** 睡一会儿（ArkTS 没有内置 sleep；Promise 包一层，和 WebTokens.delay 同一写法）。 */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  /**
   * 深链到一条帖子。
   *
   * 为什么用**隐藏网页导航**而不是帖子页（openPostStream）：深链只有一个 shortcode，
   * 而帖子页要的是一整份分页列表 + 翻页回调，凑不出那份上下文（见 core/DeepLink.toInstagramUrl）。
   *
   * 为什么要等桥就绪：冷启动点进帖子时网页宿主可能刚建好、还没跑完首帧，
   * 这时 loadUrl 会被随后的初始化覆盖掉（表现就是"链接点了没反应"）。
   */
  private async openDeepLinkPost(intent: DeepLinkIntent): Promise<void> {
    if (!this.bridgeReady) {
      // PageBridge 没有"等就绪"的接口（只有 awaitPageReady / runBridge），而这里要等的是
      // "网页宿主建好并报过一次 ready"（见 setReadyHandler），所以按标志轮询。
      await this.waitBridgeReady(DEEP_LINK_READY_TIMEOUT_MS);
    }
    if (!this.bridgeReady) {
      hilog.warn(DOMAIN, TAG, 'deep link post skipped: web host not ready');
      this.selectTab(AppTab.Home);
      return;
    }
    this.selectTab(AppTab.Home);
    this.openWeb(DeepLink.toInstagramUrl(intent));
  }

  /**
   * 页面重新显示（含从后台回到前台）。
   *
   * 深链的热启动路径落在这里：onNewWant 只把 intent 存进 pending，真正执行要等页面回到前台。
   * 没有待执行意图时这里什么都不做（`hasPending` 只是一次判空，开销可忽略）。
   */
  onPageShow(): void {
    this.consumePendingDeepLink();
  }

  // ==========================================================================
  // 帖子与播放
  // ==========================================================================

  private openPost(post: MediaPost): void {
    if (post.shortcode.length === 0) {
      return;
    }
    const kind: string = post.isVideo() ? 'reel' : 'p';
    this.openWeb(`https://www.instagram.com/${kind}/${post.shortcode}/`);
  }

  // 视频播放已经完全交给 components/FeedList：哪条视频出现在屏幕上就播哪条。
  // 页面这一层不再持有播放状态，「点封面」也不再触发跳转或播放。

  // ==========================================================================
  // 互动：点赞 / 评论
  //
  // 两者都不由原生发请求：原生只是让隐藏的网页去点它自己的按钮，写操作由页面用它
  // 自己的会话与 csrf 完成，再把结果读回来。
  //
  // 回退路径靠**真的导航**。以前这里用 pushState 做 SPA 路由，URL 会立刻变、但视图
  // 未必真的切过去，于是「已经在帖子页」的判断成立、操作的却还是信息流的 DOM ——
  // 评论读到的是信息流的内容，点赞甚至可能点到别的帖子。所以现在由原生侧用 loadUrl
  // 真正导航到该帖页面，等 onPageEnd 之后再注入脚本，做完再导航回首页。
  // ==========================================================================

  /** 把隐藏网页真的导航到某条帖子的页面；返回是否加载完成。 */
  private async navigateToPost(post: MediaPost): Promise<boolean> {
    const kind: string = post.isVideo() ? 'reel' : 'p';
    this.navigating = true;
    this.bridge.loadUrl(`https://www.instagram.com/${kind}/${post.shortcode}/`);
    const ready: string = await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    hilog.info(DOMAIN, TAG, 'nav to post ready=%{public}s', ready);
    return ready === 'ready';
  }

  /** 回到信息流首页并等它加载完。失败也要回，否则翻页会一直对着帖子页空转。 */
  private async returnToFeed(): Promise<void> {
    this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
    const ready: string = await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    hilog.info(DOMAIN, TAG, 'back to feed ready=%{public}s', ready);
    this.navigating = false;
  }

  /**
   * 按钮传进来的 post 可能是**旧的**：卡片不再因为点赞而重建，回调是建卡片时闭包捕获的，
   * 那时这条帖子的 liked 还是老值。所以这里按 key 回自己的列表里取当前那条，
   * 否则「取消赞」会算出错误的翻转目标。
   */
  private currentPost(post: MediaPost): MediaPost {
    const key: string = FeedMapper.keyOf(post);
    for (let index: number = 0; index < this.posts.length; index++) {
      if (FeedMapper.keyOf(this.posts[index]) === key) {
        return this.posts[index];
      }
    }
    return post;
  }

  /** 点赞 / 取消赞：先乐观翻转，再走 HTTP 直发（模板没抓到才退回网页）。 */
  private async likePost(post: MediaPost): Promise<void> {
    const current: MediaPost = this.currentPost(post);
    const key: string = FeedMapper.keyOf(current);
    // 只挡「同一条正在处理中」：换一条帖子可以立刻点，不必排队等前一条跑完。
    if (this.likingKeys.has(key) || this.navigating || current.shortcode.length === 0) {
      return;
    }
    const before: boolean = current.liked;
    this.likingKeys.add(key);
    // 先翻转，点下去立刻有反馈；下面再用真实结果校正。
    // 走 setLikedEverywhere：信息流与**帖子页**那两份列表都要跟着变（见那里的说明）。
    this.setLikedEverywhere(key, !before);
    try {
      // ① **HTTP 直发**（core/NativeEngage）：模板回放那条 GraphQL 变更，不发网页、不等 DOM。
      const native: EngageResult = await NativeEngage.setLiked(current.id, !before);
      if (native.ok) {
        this.setLikedEverywhere(key, !before);
        return;
      }
      hilog.info(DOMAIN, TAG, 'native like failed (%{public}s) → web', native.detail);
      // ② 网页驱动（模板还没抓到 / 原生那一发被拒）：老路子，点完顺手把模板抓下来，
      //    下一次同样的操作就走 ①（自举，见 core/NativeEngage 的文件头）。
      // 1) 帖子就在网页当前信息流里：直接点（快路径）。
      let state: string = await this.runLike(likePostScript(post.shortcode), LIKE_TIMEOUT_MS);
      // 2) 不在（靠游标翻出来的帖子，页面自己没渲染过）：真的导航到帖子页再点。
      if (state === 'not-found') {
        // 走兜底之前**先把图标回滚**。兜底要真导航一次网页（去帖子页、点完再回首页），
        // 是秒级的；让它红着等这么久，万一最后没点成，用户看到的就是「红了半天又变回去」，
        // 像个 bug。这里先回到原状，兜底真点成了再由下面按 state 翻回来 ——
        // 那个「后来变红」本身就是成功反馈。
        this.setLikedEverywhere(key, before);
        state = await this.likeOnPostPage(post);
      }
      await this.captureEngageTemplates();
      if (state === 'liked' || state === 'unliked') {
        this.setLikedEverywhere(key, state === 'liked');
        return;
      }
      // 没点成：回滚乐观状态，并说明原因。
      this.setLikedEverywhere(key, before);
      hilog.info(DOMAIN, TAG, 'like failed state=%{public}s', state);
      this.setLocalStatus(state === 'not-found'
        ? $r('app.string.engage_not_rendered')
        : $r('app.string.like_failed'));
    } catch (error) {
      this.setLikedEverywhere(key, before);
      hilog.warn(DOMAIN, TAG, 'like error: %{public}s', (error as Error).message);
      this.setLocalStatus($r('app.string.like_failed'));
    } finally {
      this.likingKeys.delete(key);
    }
  }



  /**
   * 把网页刚发过的那几条"互动"请求存成模板（点赞 / 取消赞 / 转发 / 取消转发）。
   *
   * 它就是 core/NativeEngage 那条原生路的**自举**：模板只在"页面自己发过一次"之后才有，
   * 所以每次走网页路径成功后都抓一把（页面一发出这类请求也会主动通知，见
   * PageBridge.setEngageTemplateHandler）；抓到之后（24 小时有效）同样的操作就走 HTTP。
   *
   * 四个操作名**分开抓**：`capture` 是按名字片段过滤的，用一个大而全的词（比如 `Polaris`）
   * 会把个人页/推荐位那一堆查询一起塞进模板表 —— 表里坑位有限（落盘 24 个），
   * 真正要用的这四条反而会被挤掉（真机上就是这么丢的）。
   */
  private async captureEngageTemplates(): Promise<void> {
    const ops: Array<string> = [LIKE_OP, UNLIKE_OP, REPOST_OP, UNREPOST_OP];
    let stored: number = 0;
    try {
      for (let index: number = 0; index < ops.length; index++) {
        if (await ApiRegistry.getInstance().capture(ops[index])) {
          stored++;
        }
      }
      // 顺手把模板里的 **doc_id 回写到包内骨架**：IG 改前端时 doc_id 会换，模板是可靠的新值
      // 来源；回写之后即使模板过期（24 小时），骨架那条路也还能直接发（见 core/EngageSkeleton）。
      this.rememberEngageDocs(ops);
      hilog.info(DOMAIN, TAG, 'engage templates stored=%{public}d like=%{public}s repost=%{public}s',
        stored, `${NativeEngage.hasLikeTemplate()}`, `${NativeEngage.hasRepostTemplate()}`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'engage template capture failed: %{public}s',
        (error as Error).message);
    }
  }

  /** 把已存模板里的 doc_id 回写给包内骨架（见 captureEngageTemplates 的说明）。 */
  private rememberEngageDocs(ops: Array<string>): void {
    for (let index: number = 0; index < ops.length; index++) {
      const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(ops[index]);
      if (tpl === null) {
        continue;
      }
      const at: number = tpl.body.indexOf('doc_id=');
      if (at < 0) {
        continue;
      }
      const start: number = at + 'doc_id='.length;
      const end: number = tpl.body.indexOf('&', start);
      const doc: string = (end < 0 ? tpl.body.substring(start) : tpl.body.substring(start, end)).trim();
      EngageSkeleton.rememberDoc(ops[index], doc);
    }
  }

  /**
   * 双击媒体点赞。
   *
   * 只做「喜欢」、不做切换：双击在 Instagram 的语义就是点赞，已经赞过的再双击不该把它
   * 取消掉。所以先判一下 liked，剩下交给 likePost。
   *
   * 走的是和动作区那颗心**完全同一条**路径（likePost → 先乐观翻转，再驱动隐藏网页去点
   * 它自己的点赞按钮，最后用网页回报的状态校正），所以赞是真的落到网页/账号上，
   * 不只是原生这边的显示状态。
   */
  private async likeByDoubleTap(post: MediaPost): Promise<void> {
    // 同 likePost：传进来的可能是旧对象，得看当前这条赞没赞过。
    if (this.currentPost(post).liked) {
      return;
    }
    await this.likePost(post);
  }

  /**
   * 转发 / 取消转发。
   *
   * 两条路（和点赞完全同一套）：
   *   ① **HTTP 直发**（core/NativeEngage）：模板回放那条 GraphQL 变更。取消转发要用
   *      "转发那次响应里的 note_id"（见 NativeEngage/EngageState），拿不到（比如 App 重启过）
   *      就不猜，直接走 ②。
   *   ② 网页驱动（老路径）：让隐藏网页去点它自己的转发入口，点完顺手把模板抓下来（自举）。
   *
   * 本地状态是本机自己记的（接口里没有这个字段，见 FeedViewModel.repostedKeys）：
   * 点下去先乐观翻转，图标立刻给反馈，再用真实结果校正；网页的文案压根不翻
   * （读不出方向）时保留这次乐观结果 —— 绝不拿一个猜出来的方向把用户刚做的操作弹回去。
   */
  private async repostPost(post: MediaPost): Promise<void> {
    const current: MediaPost = this.currentPost(post);
    const key: string = FeedMapper.keyOf(current);
    if (this.repostingKeys.has(key) || this.navigating || current.shortcode.length === 0) {
      return;
    }
    const before: boolean = current.reposted;
    this.repostingKeys.add(key);
    // 先翻转，点下去立刻有反馈（对勾出现 / 消失）；下面再用真实结果校正。
    this.setRepostedEverywhere(key, !before);
    try {
      // ① HTTP 直发。
      const native: EngageResult = await NativeEngage.setReposted(current.id, !before);
      if (native.ok) {
        this.setRepostedEverywhere(key, !before);
        this.setLocalStatus(!before
          ? $r('app.string.repost_done') : $r('app.string.unrepost_done'));
        return;
      }
      hilog.info(DOMAIN, TAG, 'native repost failed (%{public}s) → web', native.detail);
      let state: string = 'error';
      let labelBefore: string = '-';
      let labelAfter: string = '-';
      try {
        const raw: string = await this.bridge.runBridge(repostPostScript(current.shortcode), LIKE_TIMEOUT_MS);
        const payload: RepostPayload = JSON.parse(raw) as RepostPayload;
        state = payload.state;
        labelBefore = payload.label ?? '-';
        labelAfter = payload.labelAfter ?? '-';
        hilog.info(DOMAIN, TAG,
          'repost state=%{public}s via=%{public}s label=%{public}s->%{public}s cnt=%{public}d cands=%{public}s toast=%{public}s seen=%{public}s',
          state, payload.via ?? '-', labelBefore, labelAfter, payload.cnt ?? -1,
          payload.cands ?? '-', payload.toast ?? '-', payload.seen ?? '-');
      } catch (error) {
        state = 'error';
      }
      await this.captureEngageTemplates();
      // 读到了网页翻转后的真状态：按它落定，并说明这一步做了什么。
      if (state === 'reposted' || state === 'unreposted') {
        this.setRepostedEverywhere(key, state === 'reposted');
        this.setLocalStatus(state === 'reposted'
          ? $r('app.string.repost_done')
          : $r('app.string.unrepost_done'));
        return;
      }
      // 点到了、但网页的文案没翻（有的版本两个方向共用一套文案，DOM 里读不出方向）：
      // 保留上面那次乐观翻转的结果，别用猜出来的方向把用户刚做的操作弹回去。
      if (state === 'assumed') {
        hilog.info(DOMAIN, TAG, 'repost assumed label=%{public}s->%{public}s keep=%{public}s',
          labelBefore, labelAfter, before ? 'off' : 'on');
        this.setLocalStatus(before ? $r('app.string.unrepost_done') : $r('app.string.repost_done'));
        return;
      }
      // 没转发入口：回滚乐观状态、不装作转发过了，退回打开帖子页并把原因说清楚。
      this.setRepostedEverywhere(key, before);
      this.setLocalStatus(state === 'not-found'
        ? $r('app.string.engage_not_rendered')
        : $r('app.string.repost_unsupported'));
      this.openPost(current);
    } finally {
      this.repostingKeys.delete(key);
    }
  }

  /** 跑一次点赞脚本，只要 state（异常算 'error'）。 */
  private async runLike(script: string, timeoutMs: number): Promise<string> {
    try {
      const raw: string = await this.bridge.runBridge(script, timeoutMs);
      const payload: LikePayload = JSON.parse(raw) as LikePayload;
      return payload.state;
    } catch (error) {
      return 'error';
    }
  }

  /** 导航到帖子页点一次赞；无论成败都回到首页。 */
  private async likeOnPostPage(post: MediaPost): Promise<string> {
    const ready: boolean = await this.navigateToPost(post);
    try {
      if (!ready) {
        return 'error';
      }
      return await this.runLike(likeOnPostPageScript(post.shortcode), LIKE_TIMEOUT_MS);
    } finally {
      await this.returnToFeed();
    }
  }

  /**
   * 打开评论。
   *
   * 三条路，从快到慢：
   *   0) **原生 HTTP**（`GET /api/v1/media/{id}/comments/`，见 core/NativeComments）：
   *      不碰隐藏网页、一次往返就回来 —— 只要手上这条有媒体数字 id 就先试它。
   *   1) **回放**：页面里已经缓存了评论接口的请求模板时（`__ogReplay` 里带 comment 的那条），
   *      直接用它发一次 fetch 要数据 —— 不用 `loadUrl` 到帖子页、不用等页面自己发请求，
   *      一次往返就回来了（见 commentsByReplayScript）。刚启动、还没打开过任何帖子页时
   *      没有模板，这一步会落空。
   *   2) **导航到帖子页**读（老路径）：页面首屏/点评论按钮/滚一屏，从它自己收到的响应里读，
   *      读不到再用同一份模板回放一次（见 commentsOnPostPageScript）。
   *
   * 后面两条留着：原生那条要媒体 id（少数数据源给不出），而且它也可能被限流/换形状；
   * 第 2 条是最后兜底。
   */
  private async openComments(post: MediaPost): Promise<void> {
    if (this.navigating || post.shortcode.length === 0) {
      return;
    }
    /*
     * 用户**主动**开评论：把"为整屏页面挂起"的记账清掉（见 suspendCommentsForPages）。
     *
     * 不清的话会踩这个坑：面板曾经被某个页面挂起过，用户回到这一页再点评论按钮 ——
     * `commentsVisible` 虽然写成了 true，但 `commentsSuspended` 还是 true（整层 `Hidden`），
     * 结果点了没反应、面板再也不出来。主动开这一下永远该显示。
     */
    this.commentsSuspended = false;
    this.commentsSuspendBase = -1;
    // 每次开都回到"半个屏幕"的默认高度：上次拖到哪儿不该影响这一次（见 resetCommentsHeight）。
    this.resetCommentsHeight();
    /*
     * 弹出流程（需求给的顺序）：
     *   ① **先走原生的底栏隐藏动效**（下沉档是下沉收缩，系统显隐档是 HDS 显隐）；
     *   ② 等它先动起来（`COMMENTS_BAR_LEAD_MS`），再让浮层入场 —— 入场动画在
     *      `commentsOverlay` 的 onAppear 里（第一帧摆到屏幕外，再收到位）。
     */
    this.commentsClosing = false;
    if (this.commentsExitTimer >= 0) {
      clearTimeout(this.commentsExitTimer);
      this.commentsExitTimer = -1;
    }
    /*
     * 刚才那一段收起动画被这一下"重新开"取消了 —— 但它排队着的收尾动作不能跟着消失
     * （用户点了评论里的头像，面板正好在关；见 commentsAfterQueue）。当场跑掉。
     */
    this.flushCommentsAfter();
    this.commentsMaskAlpha = 0;
    this.commentsEnterVp = this.commentsHeightVp;
    this.sinkBarForComments();
    try {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, COMMENTS_BAR_LEAD_MS);
      });
    } catch (error) {
      // 不 await 也没关系：下面照样弹面板。
    }
    this.commentsVisible = true;
    /*
     * 入场动画：**下一帧**再收到位。
     *
     * 为什么不只靠浮层根节点的 `onAppear`：那是"节点出现之后"的回调，节点正好在切后台那一刻
     * 被创建、或者首帧没赶上时，它不一定来 —— 真机上见过一次"浮层开着但整块停在屏幕外"
     * （dump 里有节点、屏幕上什么都没有）。所以这里补两条，三条都幂等：
     *   ① `onAppear`（见 commentsOverlay）；
     *   ② 16ms 后自己再收一次（节点已经在位就什么都不做）；
     *   ③ `COMMENTS_IN_MS + 150` 之后**硬写**到位 —— 动画真没跑起来时至少不是一片空白。
     */
    setTimeout((): void => {
      this.enterCommentsOverlay();
    }, 16);
    setTimeout((): void => {
      this.forceCommentsOverlayShown();
    }, COMMENTS_IN_MS + 150);
    this.commentsLoading = true;
    this.commentsState = '';
    this.comments = [];
    this.commentsDiag = '';
    this.commentsOwner = post.ownerUsername;
    this.commentsCaption = post.caption;
    this.commentsAvatar = post.ownerAvatarUrl;
    // 记下这条帖子：评论点赞的网页驱动兜底要导航到它（见 likeCommentOnWeb）。
    this.commentsPost = post;
    this.commentsShortcode = post.shortcode;
    /*
     * **媒体 id 在开面板时就按这一条算好**（审计 G3）。
     *
     * 它是评论翻页（`loadMoreComments`）与取回复（`loadCommentReplies`）要用的参数，
     * 原来只在**原生那条路成功**时才写（见 readCommentsNative）。于是
     * "上一条帖子原生成功、这一条原生失败（走回放）"时，面板会拿着**上一条帖子的 mediaId**
     * 去要评论/回复 —— 拿回来的是别人的评论，或者干脆空，而且现场看不出哪里不对。
     */
    this.commentsMediaId = Index.mediaIdOfPost(post.id);
    // 评论翻页状态：每次开面板都从头来（见 loadMoreComments）。
    this.commentsNextId = '';
    this.commentsHasMore = false;
    this.commentsLoadingMore = false;
    this.commentsMoreBusy = false;
    this.commentsTouched = false;
    this.commentsAutoLoads = 0;
    try {
      const native: CommentsPayload | null = await this.readCommentsNative(post);
      if (native !== null) {
        hilog.info(DOMAIN, TAG, 'comments src=native n=%{public}d',
          (native.items ?? []).length);
        this.applyComments(native, post);
        return;
      }
      const fast: CommentsPayload | null = await this.readCommentsByReplay(post);
      if (fast !== null) {
        hilog.info(DOMAIN, TAG, 'comments src=replay n=%{public}d',
          (fast.items ?? []).length);
        this.applyComments(fast, post);
        return;
      }
      const payload: CommentsPayload | null = await this.readCommentsOnPostPage(post);
      this.applyComments(payload, post);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'comments error: %{public}s', (error as Error).message);
      this.commentsState = 'failed';
    } finally {
      this.commentsLoading = false;
    }
  }

  /**
   * 评论的**原生直发**快路径（见 core/NativeComments）。
   *
   * 返回 null = "这条路不可用"（没有媒体数字 id / 没会话 / 非 200 / 被限流 / 一条都没读到），
   * 由调用方接着走下一条路 —— 所以这里**不报错、不改界面状态**，只当没发生过。
   *
   * 为什么"一条都没读到"也算不可用：`state=empty` 有可能是这条媒体真的没有评论，
   * 也有可能是这条端点给的形状变了（那就要去网页那条路看看了）—— 交给后面两条路兜底更稳。
   */
  private async readCommentsNative(post: MediaPost): Promise<CommentsPayload | null> {
    // 帖子 id 形如 `<mediaId>_<userId>`；reels 那条直接就是媒体 id（见 openReelComments）。
    const mediaId: string = Index.mediaIdOfPost(post.id);
    const payload: CommentsPayload | null = await NativeComments.fetch(mediaId, '');
    if (payload === null || payload.state !== 'ok') {
      hilog.info(DOMAIN, TAG, 'comments native skip state=%{public}s detail=%{public}s',
        payload === null ? 'null' : payload.state, NativeComments.lastDetail());
      return null;
    }
    // 记下媒体 id：评论点赞那条私有 API 候选要用（见 likeComment）。
    this.commentsMediaId = mediaId;
    return payload;
  }

  /**
   * 帖子 id → 媒体数字 id（`<mediaId>_<userId>` 取前半段；reels 那条本身就是媒体 id）。
   *
   * 抽出来是因为**开面板**（`openComments`）与**原生读取**（`readCommentsNative`）
   * 都要它，而两边必须算出同一个值（见 openComments 里 commentsMediaId 的说明，审计 G3）。
   */
  private static mediaIdOfPost(postId: string): string {
    const cut: number = postId.indexOf('_');
    return cut > 0 ? postId.substring(0, cut) : postId;
  }

  /**
   * 点某一条评论右侧那颗心（用户报的"评论点赞实现一下"）。
   *
   * 乐观翻转：点下去立刻变色、计数 ±1，宿主回了 false 再翻回来 —— 等网络回结果会像
   * "点了没反应"。HTTP 那条路见 core/NativeComments.like（网页 REST 优先，私有可能兜底）。
   *
   * @param index 评论在 `comments` 里的下标（面板给的）。
   */
  private async likeComment(index: number): Promise<void> {
    if (index < 0 || index >= this.comments.length) {
      return;
    }
    const item: CommentItem = this.comments[index];
    const pk: string = item.pk ?? '';
    if (pk.length === 0) {
      // 没有评论 id 就没法发请求（少数响应不给 pk）：如实记一行，不假装点上。
      hilog.info(DOMAIN, TAG, 'comment like skipped: no pk name=%{public}s', item.username);
      return;
    }
    if (this.commentLiking.indexOf(pk) >= 0) {
      return;
    }
    this.commentLiking.push(pk);
    const next: boolean = item.liked !== true;
    const before: number = item.likes ?? 0;
    this.replaceComment(index, next ? before + 1 : (before > 0 ? before - 1 : 0), next);
    let ok: boolean = false;
    try {
      // ① 原生 HTTP（core/NativeComments.like）：最快，但 IG 对这条写接口有客户端指纹校验。
      ok = await NativeComments.like(pk, next, this.commentsMediaId);
      if (!ok) {
        // ② 网页驱动兜底：让页面自己点（和帖子点赞的兜底同一套路数），顺手把那条请求存成
        //    模板，下次就能走 ①（自举，见 core/NativeComments 与 bridge/WebScripts）。
        hilog.info(DOMAIN, TAG, 'comment like native failed via=%{public}s → web',
          NativeComments.lastLikeVia());
        ok = await this.likeCommentOnWeb(pk, next);
      }
    } catch (error) {
      ok = false;
    }
    const at: number = this.commentLiking.indexOf(pk);
    if (at >= 0) {
      this.commentLiking.splice(at, 1);
    }
    if (!ok) {
      // 失败回滚（并说明走的是哪条路、为什么没成）。
      this.replaceComment(index, before, item.liked === true);
      hilog.info(DOMAIN, TAG, 'comment like failed via=%{public}s pk=%{public}s like=%{public}s',
        NativeComments.lastLikeVia(), pk, `${next}`);
      return;
    }
    hilog.info(DOMAIN, TAG, 'comment like ok via=%{public}s pk=%{public}s like=%{public}s',
      NativeComments.lastLikeVia(), pk, `${next}`);
  }

  /** 到点兑现一个空回复数组（给"取回复"兜底超时用，见 loadCommentReplies）。 */
  private static emptyRepliesAfter(ms: number): Promise<Array<CommentItem>> {
    return new Promise<Array<CommentItem>>((resolve: (value: Array<CommentItem>) => void): void => {
      setTimeout((): void => {
        resolve([]);
      }, ms);
    });
  }

  /**
   * **展开某条评论的回复**时去要全部回复（面板点"查看另外 n 条回复"触发）。
   *
   * 拿到之后写回那条评论的 `replies`（预览那几条会被完整的替换掉），并把 `comments` 重新赋值
   * 一次 —— @State 数组只认"整体换一个引用"，改字段不会重绘（同信息流/Reels 那套做法）。
   *
   * **带超时**：`NativeComments.get` 那条 HTTP 在极端情况下可能一直不回调（真机上见过
   * "正在加载回复…"一直挂着），所以和一条"到点返回空数组"的比赛，谁先到算谁 ——
   * 超时后预览那几条照样在，只是不再显示加载中（`repliesLoaded` 置真，也不反复发请求）。
   *
   * @param parentIndex 父评论在 `comments` 里的下标（面板给的）。
   */
  private async loadCommentReplies(parentIndex: number): Promise<void> {
    if (parentIndex < 0 || parentIndex >= this.comments.length) {
      return;
    }
    const item: CommentItem = this.comments[parentIndex];
    const pk: string = item.pk ?? '';
    if (pk.length === 0 || item.repliesLoaded === true) {
      return;
    }
    const items: Array<CommentItem> = await Promise.race([
      NativeComments.childComments(this.commentsMediaId, pk),
      Index.emptyRepliesAfter(COMMENTS_REPLIES_TIMEOUT_MS)
    ]);
    /*
     * **await 回来要按 pk 重新定位，不能按下标写回**（审计 G4）。
     *
     * 这几百毫秒里 `this.comments` 可能已经被整份换掉（`applyComments` 重读、
     * `loadMoreComments` 把下一页并进来……），`parentIndex` 那时指向的是**另一条评论**；
     * 直接改那个下标，回复就挂到别人身上了（界面上是"点开 A 的回复，B 多出几条"）。
     * 定位不到（这条评论已经不在列表里）就整个丢弃 —— 记一行，不猜。
     */
    const at: number = Index.indexOfComment(this.comments, pk);
    if (at < 0) {
      hilog.info(DOMAIN, TAG, 'comment replies dropped pk=%{public}s (list changed)', pk);
      return;
    }
    const target: CommentItem = this.comments[at];
    if (items.length > 0) {
      target.replies = items;
      if (items.length > (target.repliesCount ?? 0)) {
        target.repliesCount = items.length;
      }
    }
    target.repliesLoaded = true;
    hilog.info(DOMAIN, TAG, 'comment replies loaded pk=%{public}s n=%{public}d at=%{public}d',
      pk, items.length, at);
    // 换一个数组引用，触发评论列表重绘（面板里的 ForEach 才会补上这些回复）。
    this.comments = this.comments.slice(0);
  }

  /** 按 pk 找一条顶层评论的下标（找不到给 -1；见 loadCommentReplies 的重定位）。 */
  private static indexOfComment(list: Array<CommentItem>, pk: string): number {
    for (let index: number = 0; index < list.length; index++) {
      if ((list[index].pk ?? '') === pk) {
        return index;
      }
    }
    return -1;
  }

  /**
   * 给**某条回复**点赞（面板里下挂回复右侧那颗心）。
   *
   * 逻辑和 likeComment 一模一样，只是目标从"顶层评论"换成"回复"：
   * 乐观翻转 → 原生 HTTP（core/NativeComments.like，评论 pk 是同一套） → 网页兜底 → 失败回滚。
   */
  private async likeReply(parentIndex: number, replyIndex: number): Promise<void> {
    if (parentIndex < 0 || parentIndex >= this.comments.length) {
      return;
    }
    const replies: Array<CommentItem> = this.comments[parentIndex].replies ?? [];
    if (replyIndex < 0 || replyIndex >= replies.length) {
      return;
    }
    let item: CommentItem = replies[replyIndex];
    let pk: string = item.pk ?? '';
    if (pk.length === 0) {
      /*
       * **预览里那几条回复常常不带评论 id**（`preview_child_comments` 有的版本只给正文和作者），
       * 没有 id 就发不了点赞请求 —— 那就先把这条评论的全部回复取回来，再用取回来的那条重试。
       * 不做这一步的话，用户在展开后的**预览那几行**上点心会"完全没反应"（用户报的"子评论无法点赞"）。
       */
      hilog.info(DOMAIN, TAG, 'reply like: no pk, fetching replies first name=%{public}s',
        item.username);
      await this.loadCommentReplies(parentIndex);
      const fresh: Array<CommentItem> = this.comments[parentIndex].replies ?? [];
      if (replyIndex < 0 || replyIndex >= fresh.length) {
        hilog.info(DOMAIN, TAG, 'reply like skipped: reply gone after reload');
        return;
      }
      item = fresh[replyIndex];
      pk = item.pk ?? '';
      if (pk.length === 0) {
        hilog.info(DOMAIN, TAG, 'reply like skipped: still no pk name=%{public}s', item.username);
        return;
      }
    }
    if (this.commentLiking.indexOf(pk) >= 0) {
      return;
    }
    this.commentLiking.push(pk);
    const next: boolean = item.liked !== true;
    const before: number = item.likes ?? 0;
    this.applyReplyLike(parentIndex, replyIndex, next ? before + 1 : (before > 0 ? before - 1 : 0),
      next);
    let ok: boolean = false;
    try {
      ok = await NativeComments.like(pk, next, this.commentsMediaId);
      if (!ok) {
        ok = await this.likeCommentOnWeb(pk, next);
      }
    } catch (error) {
      ok = false;
    }
    const at: number = this.commentLiking.indexOf(pk);
    if (at >= 0) {
      this.commentLiking.splice(at, 1);
    }
    if (!ok) {
      this.applyReplyLike(parentIndex, replyIndex, before, item.liked === true);
      hilog.info(DOMAIN, TAG, 'reply like failed via=%{public}s pk=%{public}s like=%{public}s',
        NativeComments.lastLikeVia(), pk, `${next}`);
      return;
    }
    hilog.info(DOMAIN, TAG, 'reply like ok via=%{public}s pk=%{public}s like=%{public}s',
      NativeComments.lastLikeVia(), pk, `${next}`);
  }

  /**
   * 就地改一条回复的赞（乐观翻转 / 回滚都用它）。
   *
   * 改完**整体换一次 `comments` 引用**：@State 数组里的对象改字段是不重绘的
   * （和 replaceComment 同一个道理，只是深了一层）。
   */
  private applyReplyLike(parentIndex: number, replyIndex: number, likes: number,
                         liked: boolean): void {
    if (parentIndex < 0 || parentIndex >= this.comments.length) {
      return;
    }
    const replies: Array<CommentItem> = this.comments[parentIndex].replies ?? [];
    if (replyIndex < 0 || replyIndex >= replies.length) {
      return;
    }
    const item: CommentItem = replies[replyIndex];
    item.likes = likes;
    item.liked = liked;
    this.comments = this.comments.slice(0);
  }

  /**
   * 评论点赞的**网页驱动**兜底：让隐藏网页自己去点那条评论的心。
   *
   * 两种情形：页面当前就停在这条帖子上（评论面板是原生浮层，页面可能正好是帖子页）→ 直接点；
   * 否则真导航到帖子页再点、点完回首页（同 likeOnPostPage）。
   * 点完顺手 `capture('comment')`：页面刚发过的那条点赞请求会被存成模板，
   * 下一次同样的操作就能走原生那条路（自举，和帖子点赞一样）。
   */
  private async likeCommentOnWeb(commentPk: string, like: boolean): Promise<boolean> {
    const script: string = likeCommentScript(commentPk, like);
    let state: string = await this.runLike(script, LIKE_TIMEOUT_MS);
    if (state === 'not-found' && this.commentsPost !== null && !this.navigating) {
      // 页面没渲染这条帖子的评论：导航过去再点一次（同样无论成败都回首页）。
      const ready: boolean = await this.navigateToPost(this.commentsPost);
      try {
        if (ready) {
          state = await this.runLike(script, LIKE_TIMEOUT_MS);
        }
      } finally {
        await this.returnToFeed();
      }
    }
    // 无论成没成都存一次：模板是"页面发过才有"的，这一下就是下次走原生那条路的原料。
    await ApiRegistry.getInstance().capture('comment');
    hilog.info(DOMAIN, TAG, 'comment like web state=%{public}s pk=%{public}s', state, commentPk);
    return state === 'liked' || state === 'unliked';
  }

  /** 就地换掉第 index 条评论（新数组，保证面板重绘）。 */
  private replaceComment(index: number, likes: number, liked: boolean): void {
    if (index < 0 || index >= this.comments.length) {
      return;
    }
    /*
     * **就地改这两个字段**，再整体换一次数组引用（@State 数组只认整体换引用，见下）。
     *
     * 千万不要重建对象：评论项上现在还挂着 `userId`、下挂回复（`replies` / `repliesCount` /
     * `repliesLoaded`）、`createdAt`、贴图尺寸这些字段 —— 重建一份"只带几样"的对象会把它们
     * 全丢掉，表现就是**一点赞，这条评论下面的回复直接消失**（用户报的正是这个，
     * id 旁的发布时间、头像点击要用的 userId 也一起没了）。
     */
    const item: CommentItem = this.comments[index];
    item.likes = likes;
    item.liked = liked;
    this.comments = this.comments.slice(0);
  }

  /**
   * 现在能不能去要下一页评论。
   *
   * 除了"有下一页 + 没在要"之外，还有一条**自动补页上限**（见 COMMENTS_AUTO_FILL_MAX）：
   * `onReachEnd` 在内容没铺满一屏时会连着触发，实测一次打开评论 8 秒里连要了 10 页 ——
   * 那不叫"触底加载"，叫拿接口当刷新按。所以：用户没碰过列表时最多自动补 2 页
   * （刚好把面板填满），碰过之后就完全按用户的滑动来。
   */
  private canLoadCommentsMore(): boolean {
    if (this.commentsMoreBusy || !this.commentsHasMore) {
      return false;
    }
    if (this.commentsTouched) {
      return true;
    }
    return this.commentsAutoLoads < COMMENTS_AUTO_FILL_MAX;
  }

  /**
   * 评论**触底加载下一页**（需求："没有加载全部评论，做一个触底加载功能"）。
   *
   * 闸门三道：没有下一页 / 正在要 / 没有媒体 id 时都不动。游标来自上一页（见
   * `commentsNextId`），拿回来的条目**按 pk 去重后追加** —— IG 的评论游标常把上一条又带回来，
   * 直接 concat 会让同一条评论出现好几次（信息流那边踩过这个坑）。
   */
  private async loadMoreComments(): Promise<void> {
    if (!this.canLoadCommentsMore()) {
      return;
    }
    if (this.commentsMediaId.length === 0 || this.commentsNextId.length === 0) {
      this.commentsHasMore = false;
      return;
    }
    if (!this.commentsTouched) {
      this.commentsAutoLoads++;
    }
    this.commentsMoreBusy = true;
    this.commentsLoadingMore = true;
    try {
      const payload: CommentsPayload | null =
        await NativeComments.fetch(this.commentsMediaId, this.commentsNextId);
      if (payload === null || payload.state !== 'ok') {
        // 要不到就收手（不然触底会一直重复要同一页）。
        this.commentsHasMore = false;
        hilog.info(DOMAIN, TAG, 'comments more stop state=%{public}s detail=%{public}s',
          payload === null ? 'null' : payload.state, NativeComments.lastDetail());
        return;
      }
      const known: Array<string> = [];
      for (let index: number = 0; index < this.comments.length; index++) {
        known.push(`${this.comments[index].pk ?? ''}|${this.comments[index].username}`);
      }
      const fresh: Array<CommentItem> = [];
      const incoming: Array<CommentItem> = payload.items ?? [];
      for (let index: number = 0; index < incoming.length; index++) {
        const one: CommentItem = incoming[index];
        const key: string = `${one.pk ?? ''}|${one.username}`;
        if (known.indexOf(key) >= 0) {
          continue;
        }
        known.push(key);
        fresh.push(one);
      }
      const before: string = this.commentsNextId;
      this.comments = this.comments.concat(fresh);
      this.commentsNextId = payload.nextMaxId ?? '';
      /*
       * **只有"游标没前进"才算到底**（审计 C2）。
       *
       * 原来是 `… && fresh.length > 0`：IG 的分页游标经常**回带**（下一页里混着一批已经见过的
       * 评论），这一页去重后 `fresh` 就会是 0 —— 于是 `hasMore` 被永久置 false，面板停在
       * "没有更多"，而服务端其实还有。现在改成看游标：
       *   · 游标没变（或为空）→ 真的到底了，停；
       *   · 游标变了但这一页全是重复 → **继续**，下一趟拿新游标接着翻。
       */
      const cursorAdvanced: boolean = this.commentsNextId.length > 0
        && this.commentsNextId !== before;
      this.commentsHasMore = payload.hasMore === true && cursorAdvanced;
      hilog.info(DOMAIN, TAG,
        'comments more added=%{public}d total=%{public}d more=%{public}s cursorMoved=%{public}s',
        fresh.length, this.comments.length, `${this.commentsHasMore}`, `${cursorAdvanced}`);
    } catch (error) {
      this.commentsHasMore = false;
      hilog.warn(DOMAIN, TAG, 'comments more failed: %{public}s', (error as Error).message);
    } finally {
      this.commentsMoreBusy = false;
      this.commentsLoadingMore = false;
    }
  }

  /**
   * 评论回放快路径：原生侧存过评论模板就直接重放，**不导航、不等页面渲染**。
   *
   * 模板从哪来：第一次打开评论走导航（见 readCommentsOnPostPage），那时页面自己请求过评论，
   * 顺手把模板倒到原生存下来（见 ApiRegistry.capture）。之后每次打开评论都走这里。
   *
   * 返回 null 表示"这条快路径不可用"（没有模板 / 请求没成 / 一条评论都没读到），
   * 由调用方退回导航那条路 —— 所以这里**不报错、不改状态**，只当没发生过。
   */
  private async readCommentsByReplay(post: MediaPost): Promise<CommentsPayload | null> {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    // 先看存的；没有就问问当前页面有没有（例如网页正好停在帖子页上）。
    let cfg: string = registry.storedJson('comment');
    if (cfg.length === 0) {
      await registry.capture('comment');
      cfg = registry.storedJson('comment');
    }
    if (cfg.length === 0) {
      hilog.info(DOMAIN, TAG, 'comments replay skip %{public}s %{public}s',
        registry.summary(), registry.storedSummary());
      return null;
    }
    // 帖子 id 形如 `<mediaId>_<userId>`，GraphQL 变量里的 media_id 就是前面那段。
    const cut: number = post.id.indexOf('_');
    const mediaId: string = cut > 0 ? post.id.substring(0, cut) : post.id;
    const payload: CommentsPayload | null = await this.readComments(
      commentsByStoredCfgScript(cfg, post.shortcode, mediaId, COMMENTS_REPLAY_FIRST),
      COMMENTS_REPLAY_TIMEOUT_MS);
    if (payload === null) {
      return null;
    }
    hilog.info(DOMAIN, TAG, 'comments replay state=%{public}s n=%{public}d diag=%{public}s',
      payload.state, (payload.items ?? []).length, payload.diag ?? '-');
    return payload.state === 'ok' ? payload : null;
  }

  /** 跑一次评论脚本；异常算 null。 */
  private async readComments(script: string, timeoutMs: number): Promise<CommentsPayload | null> {
    try {
      const raw: string = await this.bridge.runBridge(script, timeoutMs);
      return JSON.parse(raw) as CommentsPayload;
    } catch (error) {
      return null;
    }
  }

  /** 简单的等待（页面里编排时序用，别再引一份 setTimeout 拼装）。 */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 导航到帖子页读评论；无论成败都回到首页。
   *
   * 读完**不管成没成都把评论模板存到原生侧**：模板只要求"页面自己发过那个请求"，一旦发过
   * 它就在 `__ogReplay` 里了。这一步必须在 `returnToFeed()` 之前做 —— 回首页是整页
   * `loadUrl`，模板会连同页面上下文一起重建，晚一步就没得存。
   *
   * 为什么不再要求"这次读到了才存"：帖子页那条读法本身会超时（实测 `state=timeout`），
   * 拿它当存模板的前提，等于把快路径一起废了。
   */
  private async readCommentsOnPostPage(post: MediaPost): Promise<CommentsPayload | null> {
    const ready: boolean = await this.navigateToPost(post);
    try {
      if (!ready) {
        return null;
      }
      // 等页面"喘口气"再注入：pageReady 只是文档加载完，之后还有水合 + 视频起播，
      // 那几秒里主线程被占满 —— 实测这时注入的脚本要等到桥超时都排不上队
      // （同一页面上晚十几秒再跑的探针脚本 11ms 就返回了）。
      await Index.sleep(POST_PAGE_SETTLE_MS);
      const payload: CommentsPayload | null =
        await this.readComments(commentsOnPostPageScript(), POST_PAGE_READ_TIMEOUT_MS);
      await ApiRegistry.getInstance().capture('comment');
      return payload;
    } finally {
      await this.returnToFeed();
    }
  }

  /** 把脚本回报的评论落到面板状态上。 */
  private applyComments(payload: CommentsPayload | null, post: MediaPost): void {    // 一次把状态、条数、诊断全打出来：读不到时要能一眼看出是"没等到数据"还是"脚本报错"。
    hilog.info(DOMAIN, TAG, 'comments payload state=%{public}s n=%{public}d msg=%{public}s',
      payload === null ? 'null' : payload.state,
      payload === null ? 0 : (payload.items ?? []).length,
      payload === null ? '' : (payload.message ?? ''));
    if (payload === null) {
      this.commentsState = 'failed';
      return;
    }
    if (payload.state === 'ok') {
      this.comments = withoutCaption(payload.items ?? [], post);
      // 翻页游标：有下一页时列表底部会自动接着要（见 loadMoreComments）。
      // 网页回放/导航那两条路不给游标，那就当"到底了"（它们本来就只取一面）。
      this.commentsNextId = payload.nextMaxId ?? '';
      this.commentsHasMore = payload.hasMore === true && this.commentsNextId.length > 0;
      hilog.info(DOMAIN, TAG, 'comments more=%{public}s cursor=%{public}d min=%{public}s',
        `${this.commentsHasMore}`, this.commentsNextId.length, `${payload.nextMin === true}`);
      // 下挂回复：这一页有多少条评论是**带回复**的、以及预览带回来几条（一行够定位问题）。
      let withReplies: number = 0;
      let previewTotal: number = 0;
      for (let index: number = 0; index < this.comments.length; index++) {
        const one: CommentItem = this.comments[index];
        if ((one.repliesCount ?? 0) > 0) {
          withReplies++;
          previewTotal += (one.replies ?? []).length;
        }
      }
      hilog.info(DOMAIN, TAG, 'comments replies: withReplies=%{public}d previews=%{public}d',
        withReplies, previewTotal);
    } else if (payload.state === 'not-found') {
      this.commentsState = 'not-found';
    } else if (payload.state !== 'empty') {
      this.commentsState = 'failed';
    }
    // 结构摘要写进探针与 hilog：读不到时凭它定位选择器该改哪里，不用靠猜。
    const diag: string = payload.diag ?? '';
    this.commentsDiag = diag;
    if (diag.length > 0) {
      hilog.info(DOMAIN, TAG, 'comments diag: %{public}s', diag);
      InstagramProbe.getInstance().setDomReport(`comments ${post.shortcode} ${diag}`);
    }
  }

  /**
   * 收起评论浮层（下滑够多 / 返回键 / 点面板外面都走这里）。
   *
   * 需求给的顺序是"先动画收起评论 → 再调用原生动画把底栏显示回来"：
   *   ① 面板 + 输入框滑下去、遮罩淡出（`COMMENTS_OUT_MS`）；
   *   ② 动画跑完才真正隐藏浮层，并让底栏回来（`restoreBarAfterComments`）。
   *
   * @param after 收起动画跑完之后的收尾动作（点评论里的头像去主页要用，见 openUserFromComments）。
   */
  private closeComments(after?: () => void): void {
    if (!this.commentsVisible) {
      if (after !== undefined) {
        after();
      }
      return;
    }
    // 正在收：记下这一次的收尾动作，等同一个计时器跑完再一起做（不叠第二段动画）。
    if (this.commentsClosing) {
      if (after !== undefined) {
        this.commentsAfterQueue.push(after);
      }
      return;
    }
    this.commentsClosing = true;
    const height: number = this.commentsHeightVp > 0 ? this.commentsHeightVp : this.commentsMidVp();
    this.getUIContext().animateTo({ curve: Curve.FastOutSlowIn, duration: COMMENTS_OUT_MS },
      (): void => {
        this.commentsEnterVp = height;
        // 下拉收起时整块已经跟着手指走了一段（`commentsPullVp`）：这里把它一起收干净，
        // 动画就是"接着往下走"，而不是先跳回去再滑走。
        this.commentsPullVp = 0;
        this.commentsMaskAlpha = 0;
      });
    this.commentsExitTimer = setTimeout((): void => {
      this.commentsExitTimer = -1;
      this.commentsVisible = false;
      this.commentsClosing = false;
      /*
       * **关掉就是关掉**：连"被整屏页面挂起"的记账一起清（审计 G2）。
       *
       * 这期间可能有页面压上来把面板挂起（`suspendCommentsForPages` 只跳过"正在收"的面板，
       * 但反过来 —— 先挂起、再被关 —— 是完全可能的）。只清 `commentsVisible` 的话，
       * 会留下 `commentsVisible=false` + `commentsSuspended=true` + `commentsSuspendBase≥0`：
       * 用户从那一页返回时 `onPageHidden` 会调 `resumeCommentsAfterProfile()`，
       * 把一层**已经关掉、数据也清空了**的面板重新弹出来。
       */
      this.commentsSuspended = false;
      this.commentsSuspendBase = -1;
      this.commentsEnterVp = 0;
      this.commentsPullVp = 0;
      this.commentsState = '';
      this.comments = [];
      this.commentsDiag = '';
      this.commentsOwner = '';
      this.commentsCaption = '';
      this.commentsAvatar = '';
      // ④ 面板收完了，再把底栏放回来（需求流程最后一步）。
      this.restoreBarAfterComments();
      if (after !== undefined) {
        this.commentsAfterQueue.push(after);
      }
      // 排队中的收尾动作统一在这里跑（见 commentsAfterQueue）。
      this.flushCommentsAfter();
    }, COMMENTS_OUT_MS);
  }

  /** 跑掉排队中的收尾动作（见 commentsAfterQueue）。一个抛了不影响后面几个。 */
  private flushCommentsAfter(): void {
    const queued: Array<() => void> = this.commentsAfterQueue;
    this.commentsAfterQueue = [];
    for (let index: number = 0; index < queued.length; index++) {
      try {
        queued[index]();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'comments after threw: %{public}s', (error as Error).message);
      }
    }
  }

  /**
   * 评论里点头像 / 用户名 → 打开 TA 的主页（需求："点击头像或id进入用户详情页"）。
   *
   * 需求："点进用户页面**先收起面板**，退出页面后弹出面板并定位到进入用户页面前的位置" ——
   * 所以先播收起动画（状态留着，见 suspendCommentsForProfile），动画跑完再 push 用户主页；
   * 主页关掉时再把面板**弹出**到原来的档位（见 onPageHidden → resumeCommentsAfterProfile）。
   */
  private openUserFromComments(username: string, userId: string): void {
    const name: string = username.trim();
    if (name.length === 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'comments user tap: %{public}s id=%{public}s', name, userId);
    this.suspendCommentsForProfile((): void => {
      this.openUserProfile(name, userId);
    });
  }

  /**
   * 整屏页面（NavDestination）上的**返回键**。
   *
   * 需求："返回优先收起面板" —— 评论浮层是全局的一层（盖在所有页面之上），所以不管当前是
   * 首页、Reels 页，还是帖子页 / 用户主页 / 视频分页这些 feeds / reels 类页面，
   * 返回键都该**先把评论收起来**，而不是把下面的页面 pop 掉。
   *
   * 首页那条走页面级 `onBackPress`（见 build 上方的 onBackPress）；这里补的是各个
   * NavDestination 的 `onBackPressed`（不接管的话返回键会被 Navigation 拿去 pop 页面）。
   *
   * @returns true = 这次返回被吃掉了（不 pop 页面）。
   */
  private handleDestinationBack(): boolean {
    /*
     * **挂起中的面板不算"开着"**：用户主页压在上面、评论面板正为它让位（见
     * suspendCommentsForPages），这时返回键该关掉这一页，而不是去关一层看不见的面板
     * （不然第一次返回像是"没反应"）。
     */
    if (this.commentsVisible && !this.commentsSuspended) {
      this.closeComments();
      return true;
    }
    return false;
  }

  /**
   * 把评论浮层**收起来**，但状态全留着（进用户主页之前用）。
   *
   * 需求："点进用户页面**先收起面板**，退出页面后弹出面板并定位到进入用户页面前的位置" ——
   * 所以这里走的是**和收起一模一样的那套动画**（面板滑下去 + 遮罩淡出 + 底栏放回来），
   * 只是动画跑完之后**不清数据**、只把整层藏起来（`commentsSuspended`）：
   * 评论列表、翻页游标、面板档位、列表滚动位置全部留着，回来时原样弹出（见 resumeCommentsAfterProfile）。
   *
   * @param after 动画跑完之后的收尾动作（用来 push 用户主页）。
   */
  private suspendCommentsForProfile(after: () => void): void {
    if (!this.commentsVisible || this.commentsSuspended) {
      after();
      return;
    }
    if (this.commentsClosing) {
      // 正在收（用户先点了别处 / 上一次点头像还没跑完）：记下收尾动作，别把它吞掉（见 commentsAfterQueue）。
      this.commentsAfterQueue.push(after);
      return;
    }
    this.commentsSuspendBase = this.coveringPages;
    this.commentsClosing = true;
    this.commentsTouching = false;
    const height: number = this.commentsHeightVp > 0 ? this.commentsHeightVp : this.commentsMidVp();
    this.getUIContext().animateTo({ curve: Curve.FastOutSlowIn, duration: COMMENTS_OUT_MS },
      (): void => {
        this.commentsEnterVp = height;
        this.commentsPullVp = 0;
        this.commentsMaskAlpha = 0;
      });
    this.commentsExitTimer = setTimeout((): void => {
      this.commentsExitTimer = -1;
      this.commentsClosing = false;
      // 藏起来（不是隐藏节点）：列表还在树上，滚动位置留着。
      this.commentsSuspended = true;
      this.commentsEnterVp = 0;
      this.commentsPullVp = 0;
      this.restoreBarAfterComments();
      this.commentsAfterQueue.push(after);
      this.flushCommentsAfter();
    }, COMMENTS_OUT_MS);
  }

  /**
   * 整屏页面压上来时**立刻**让评论浮层让位（不给"面板画在新页面上"留一帧）。
   *
   * 和 `suspendCommentsForProfile` 的区别只有"动不动画"：那条路是用户点了头像、面板该**看着**
   * 收下去（再推页面）；这条路是页面已经在推了（用户点的是别的东西，或从别的入口进了页面），
   * 这时只能立刻藏起来。两边的状态语义完全一样：`commentsVisible` 留着、数据和档位全留着，
   * 页面关掉时按 `commentsSuspendBase` 放回来（见 resumeCommentsAfterProfile）。
   */
  private suspendCommentsForPages(): void {
    if (!this.commentsVisible || this.commentsSuspended || this.commentsClosing) {
      return;
    }
    this.commentsSuspendBase = this.coveringPages;
    this.commentsTouching = false;
    this.commentsSuspended = true;
    this.commentsEnterVp = 0;
    this.commentsPullVp = 0;
    this.commentsMaskAlpha = 0;
    this.restoreBarAfterComments();
    hilog.info(DOMAIN, TAG, 'comments hidden under page (covering=%{public}d)',
      this.coveringPages);
  }

  /**
   * 从用户主页回来：**弹出面板**并回到进主页前的位置（档位、列表滚动位置都是原样）。
   *
   * 做法和"打开评论"的入场一致：先摆到屏幕外 + 遮罩透明，再 `animateTo` 收上来 ——
   * 所以看到的就是"面板弹出来"，而不是"突然出现"。
   */
  private resumeCommentsAfterProfile(): void {
    if (!this.commentsSuspended) {
      return;
    }
    // 档位（`commentsHeightVp`）还是进主页前那一档，直接拿它当起点。
    this.commentsEnterVp = this.commentsHeightVp > 0 ? this.commentsHeightVp : this.commentsMidVp();
    this.commentsMaskAlpha = 0;
    this.commentsSuspended = false;
    this.commentsSuspendBase = -1;
    this.sinkBarForComments();
    setTimeout((): void => {
      this.enterCommentsOverlay();
    }, 16);
  }

  // ==========================================================================
  // 装配
  // ==========================================================================

  /**
   * 下拉刷新：重新读第一页。
   *
   * 刷新期间列表**不清空**（view-model 走 mergePrepend 把新一页放到头部），
   * 所以不会闪成骨架屏，也不会跳。
   *
   * 两个曾经让用户"以为没反应"的点：
   *   1) 隐藏网页正在别处导航（读通知 / 评论 / 帖子页）时，以前是**直接放弃**（转圈秒收、
   *      什么也不发生）；现在改成等它回来（有上限）再读；
   *   2) `viewModel.refresh()` 撞上在跑的一轮取数时只是排队就返回了，转圈会提前收起 ——
   *      所以再 `awaitIdle()` 等它排完并跑完，转圈才收。
   */
  private async refreshFeed(): Promise<void> {
    this.refreshing = true;
    try {
      const deadline: number = Date.now() + REFRESH_NAV_WAIT_MS;
      while (this.navigating && Date.now() < deadline) {
        await this.delay(REFRESH_NAV_POLL_MS);
      }
      await this.viewModel.refresh();
      await this.viewModel.awaitIdle();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', (error as Error).message);
      this.setLocalStatus($r('app.string.status_unparsable'));
    } finally {
      this.refreshing = false;
    }
  }

  /**
   * 信息流那一个页签的内容。
   *
   * 从 nativeShellContent 里抽出来：内容改成放进 TabContent 之后，这一百多行再嵌一层
   * 会把缩进推得很深，单独一个 @Builder 更清楚。
   */
  @Builder
  homeTab() {
    Column() {
      if (!this.sessionChecked) {
        // 还在核对登录态：先铺信息流骨架屏，别让用户对着白屏等。
        FeedSkeleton()
          .layoutWeight(1)
      } else if (!this.signedIn) {
        LoginPanel({
          onOpenWeb: (): void => {
            this.openLoginWeb();
          },
          onRecheck: (): void => {
            this.refreshSessionFromJar();
          }
        })
          .layoutWeight(1)
      } else {
        /*
         * **限时快拍托盘已经搬进 FeedList 内部**（`showStories: true` + 三个回调），见
         * components/FeedList 的说明：需求要的"置顶 + 跟随信息流滚动"只有放进 List 里才对
         * ——摆在这一层的话它不跟着滚，而且会压在标题栏底下（内容区从屏幕顶开始）。
         *
         * 所以这里只剩两件事：把顺序/位置/点开这三个回调转进去，别的什么都不用做。
         */
        FeedList({
          posts: this.posts,
          // 列表顶部放那条托盘（数据由托盘自己拉）。
          showStories: true,
          /*
           * **把上次拉到的托盘交给它当首帧内容**（需求："切页面保留当前数据，回到主页秒盖上
           * 刚刚的数据"）。`storyQueue` 活在页面里、不随 tab 切换消失，而 FeedList / StoriesTray
           * 每次切回主页都是**重建**的 —— 没有这份 seed，托盘就只能从空开始等一发网络。
           */
          storySeed: this.storyQueue,
          storySeedAtMs: this.storyQueueAtMs,
          // 点开某一项：取数 + 开播放页（转场要用被点头像的屏幕矩形）。
          onStoryOpen: (item: StoryTrayItem, rect: StoryHeroRect): void => {
            this.openStory(item, rect);
          },
          // 整条顺序交过来：看某位最后一条时点右半屏要接"下一位"（见 advanceStory）。
          onStoryLoaded: (items: Array<StoryTrayItem>): void => {
            this.rememberStoryQueue(items);
            hilog.info(DOMAIN, TAG, 'story queue n=%{public}d', items.length);
            // 托盘一到就开始**预加载**：从第一位起把前五个用户的 story 热起来（见 core/StoryCache）。
            StoryCache.reset(items, 0);
          },
          // 每一项头像的当前位置：收起时要朝"现在这一位"的托盘头像收缩（见 storyRects）。
          onStoryRect: (userId: string, rect: StoryHeroRect): void => {
            this.storyRects.set(userId, rect);
          },
          /*
           * 托盘里**看得见**的那几位：立刻把他们的 story 预取好（需求："显示在屏幕中的用户
           * stories 提前加载，点开秒显示内容"）。`StoryCache.ensure` 会在已经盖住这个范围时
           * 什么都不做，所以滚托盘不会反复打接口。
           */
          onStoryVisible: (start: number, end: number): void => {
            hilog.info(DOMAIN, TAG, 'story visible %{public}d-%{public}d', start, end);
            StoryCache.ensure(this.storyQueue, start);
          },
          // 正文翻译失败：弹一句（卡片自己把"显示译文"的状态退回去了）。
          onTranslateFailed: (): void => {
            this.toast($r('app.string.translate_failed'));
          },
          // 整屏页面（通知/设定/用户主页/帖子页）压上来时**不要再播视频**：
          // 可见性回调不会因为被盖住而变化，不显式停就会一直在下面播、还在出声。
          // 快拍播放浮层也是一样（它盖满整屏，下面的视频不能继续出声）。
          active: this.coveringPages === 0 && !this.storyOpen,
          // 交给 HdsNavigation 的 bindToScrollable 用（见 nativeShell）。
          listScroller: this.feedScroller,
          // 切 tab 回来时停回离开时那一条（FeedList 用 key 定位，见它的 restoreAnchor）。
          initialKey: this.feedAnchorKey,
          onAnchorChange: (key: string): void => {
            this.feedAnchorKey = key;
          },
          loading: this.busy || !this.loadedOnce,
          // 已有内容还在忙 = 正在触底翻页 → 列表底部显示圆环。
          loadingMore: this.busy && this.posts.length > 0,
          refreshing: $refreshing,
          onRefresh: (): void => {
            this.refreshFeed();
          },
          onLoad: (): void => {
            if (!this.navigating) {
              this.viewModel.loadFeed();
            }
          },
          onNearEnd: (): void => {
            // 临时导航去帖子页 / 回首页期间信息流不在页面上，翻页必定失败，先跳过。
            if (!this.navigating) {
              this.viewModel.requestMore();
            }
          },
          onPlaybackError: (): void => {
            this.setLocalStatus($r('app.string.video_play_failed'));
          },
          onOpen: (post: MediaPost): void => {
            this.openPost(post);
          },
          // 用户资讯模块（头像 + 用户名）→ 打开用户主页（NavDestination，见 openUserProfile）。
          onOpenUser: (post: MediaPost): void => {
            this.openUserProfile(post.ownerUsername, post.ownerId);
          },
          onLike: (post: MediaPost): void => {
            this.likePost(post);
          },
          onLikeMedia: (post: MediaPost): void => {
            this.likeByDoubleTap(post);
          },
          onComments: (post: MediaPost): void => {
            this.openComments(post);
          },
          onRepost: (post: MediaPost): void => {
            this.repostPost(post);
          },
          // 收藏（书签）：走 HTTP（原生模板 / App 主机 route / 网页驱动兜底，见 savePost）。
          onSave: (post: MediaPost, save: boolean): Promise<boolean> => {
            return this.savePost(post, save);
          },
          // 关注 / 取关：走 HTTP 直发（core/NativeFollow），成功/失败各弹一句提示。
          onFollow: (post: MediaPost, follow: boolean): Promise<boolean> => {
            return this.followAuthor(post, follow);
          },
          // 滚动方向 → 触发官方那条"底栏隐藏/露出"动效（见 onFeedScroll）。
          onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
            this.onFeedScroll(deltaY, offsetY, scrollState);
          }
        })
          .layoutWeight(1)
      }
      if (this.statusShown) {
        Text(this.statusText)
          .fontSize(13)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(2)
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  /**
   * 原生壳的**内容**：内容层 + 系统悬浮页签层
   * （标题栏由外层的 HdsNavigation 提供，见 nativeShell）。
   *
   * 为什么是两层、而不是把内容塞进 TabContent：
   *   内容层要按 `selectedIndex` 切页、并且要被 BackdropTone 单独拍快照，而 HDS 的悬浮栏
   *   画在 Tabs 内部、拿不出来。所以让它单独待在一层里：这一层只装得下栏，内容层是它的
   *   兄弟节点 —— 栏的动效不会碰到内容。
   *
   * 栏本身是**官方那条**：HdsTabs + barFloatingStyle，材质走 systemMaterialEffect
   * （等级与标题栏同源，见 immersiveLevel），只有里面的项是自己画的（要图标不要文字，见 tabBarItem）。
   * 注意：HDS 这层材质**没有反色字段**，页签图标不会随背景自动取反色（要反色得用原生 Tabs 的
   * `systemMaterial({colorInvert: true})`）。
   *
   * **滚动对底栏的影响按能力分档**：
   *   悬浮档（API ≥ 23）—— 两套行为二选一（设定页里切，见 barHideMode）：
   *     · sink（默认）下沉收缩：栏往下挪一截 + 收窄 + 缩矮，始终留在屏幕上。这一支要把
   *       **栏自己的三个布局参数**喂进去（barHeight / barSideMargin / barBottomMargin），
   *       由 animateTo 走同一条弹簧曲线（见 setBarSink）；栏高写成直接属性，
   *       只有直接属性才走得动补间。
   *     · system 系统显隐：调 HdsTabsController 自带的隐藏/显示动效，栏整条收走。
   *       这一支**不设** barHeight 之外的形变（栏高保持 BAR_HEIGHT）。
   *   降级档（API < 23）—— 没有悬浮样式，上面那些参数一个都不生效，所以滚动**完全不碰**
   *     底栏；栏靠自己的底边加高来避让系统条（见 degradedBarHeight），栏高写成
   *     AttributeModifier 里的常量。
   */
  @Builder
  nativeShellContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ---- 内容层：按 selectedIndex 切页（栏那层不参与切页）----
      Column() {
        if (this.selectedIndex === 0) {
          this.homeTab()
        } else if (this.currentTab() === AppTab.Profile) {
          // 「我的」有原生实现，不走占位页。
          this.profilePage()
        } else if (this.currentTab() === AppTab.Reels) {
          // Reels 现在只做视频流（见 ReelsPage 的说明）。
          this.reelsTab()
        } else if (this.currentTab() === AppTab.Direct) {
          // 私信：原生收件箱（只读，不做发送，见 DirectPage 的说明）。
          this.directPage()
        } else {
          // 搜索：原生搜索框 + 账号结果（见 SearchPage 的说明）。
          this.searchPage()
        }
      }
      .width('100%')
      .height('100%')
      // 给一个 id：BackdropTone 要定时给**这一层**拍低分辨率快照，用来侦测底栏/叠字
      // 背后的画面明暗（不含底栏本身，所以拍它而不是拍整页）。
      .id(SHELL_CONTENT_ID)

      // ---- 底栏那一层：栏单独待在这一层里，内容层是它的兄弟节点 ----
      Stack({ alignContent: Alignment.Bottom }) {
        if (PlatformCap.hasHdsMaterial()) {
          // ============ 悬浮档：系统胶囊 + 下沉收缩 / 系统显隐 ============
          HdsTabs({
            barPosition: BarPosition.End,
            index: this.selectedIndex,
            controller: this.tabsController
          }) {
            this.tabsBody()
          }
          // 高度直接喂 barHeight：和宽度一样是布局尺寸，包在 animateTo 里一起动。
          // 末项是卡片经过时"轻微缩一下"的那一点（见 BAR_POCKET_GROW_H）。
          .barHeight(BAR_HEIGHT - BAR_SINK_HEIGHT * this.barSink
            + BAR_POCKET_GROW_H * this.storyPocket)
          .barOverlap(true)
          .vertical(false)
          .scrollable(false)
          .attributeModifier(new BarChromeModifier(
            this.floatingStyle(this.barHideMode !== BAR_HIDE_SYSTEM), BAR_HEIGHT))
          .onTabBarClick((index: number): void => {
            this.onTabBarClick(index);
          })
          .onChange((index: number): void => {
            this.onTabsChanged(index);
          })
          .width('100%')
          .height(this.barLayerHeight())
        } else {
          // ============ 降级档：普通页签栏，靠栏自己的底边加高避让系统条 ============
          HdsTabs({
            barPosition: BarPosition.End,
            index: this.selectedIndex,
            controller: this.tabsController
          }) {
            this.tabsBody()
          }
          .barOverlap(true)
          .vertical(false)
          .scrollable(false)
          // 栏高（含让给系统条的那一段）与背景模糊都在 modifier 里下发，且**不随滚动变**。
          .attributeModifier(new BarChromeModifier(
            this.floatingStyle(false), this.degradedBarHeight()))
          .onTabBarClick((index: number): void => {
            this.onTabBarClick(index);
          })
          .onChange((index: number): void => {
            this.onTabsChanged(index);
          })
          .width('100%')
          .height(this.barLayerHeight())
        }
      }
      // 承载层只负责"让栏单独待在一层里"，本身不做任何变换、也不给栏加内边距：
      // 降级时栏往哪让是由栏自己的高度决定的（见 degradedBarHeight），
      // 抬整层会让栏和它的背板一起离开屏幕底边 —— 那就成了需求里不要的"悬浮"。
      .width('100%')
      .height(this.barLayerHeight())
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 承载栏那一层的**实际高度**（vp）= 栏贴边范围 + 余量。
   *
   * 这一层是内容层的兄弟节点、又盖在它上面，**透明的部分也照样吃触摸**，所以它的高度就是
   * "底栏上方那一条滑不动的区域"有多大（用户报的"悬浮 tab 上方有部分区域无法滑动页面，
   * 应该是被 stack 组件挡住了"）。因此按栏真正贴边的范围来算，只多留 `BAR_LAYER_HEADROOM`：
   *   悬浮档：离底距离 + 栏高（胶囊坐在 `barBottomMargin` 上，顶边就在这个高度）；
   *   降级档：栏自己的高度（普通页签栏贴着承载层底边，避让量已经算在栏高里，见 degradedBarHeight）。
   *
   * **系统显隐那一档再多留 `BAR_SYSTEM_HIDE_HEADROOM`**：那一支的动效会把栏往外带一点
   * （用户报的"原生隐藏动画播放时被 stack 裁剪"，5vp 不够、加到 10vp），而**下沉收缩只是原地
   * 缩放**、不会外扩，所以只有这一档需要它 —— 不动另一档，免得白白多挡一条滑不动的区域。
   */
  private barLayerHeight(): number {
    const extra: number = this.barHideMode === BAR_HIDE_SYSTEM
      ? BAR_SYSTEM_HIDE_HEADROOM : 0;
    if (PlatformCap.hasHdsMaterial()) {
      return BAR_REST_BOTTOM + BAR_HEIGHT + BAR_LAYER_HEADROOM + extra;
    }
    return this.degradedBarHeight() + BAR_LAYER_HEADROOM + extra;
  }

  /**
   * 栏里的项。
   *
   * 空内容：这一层只为把系统那条栏撑出来，切页由内容层的 selectedIndex 管。
   */
  @Builder
  tabsBody() {
    ForEach(TAB_ITEMS, (item: TabItem, index: number): void => {
      TabContent() {
      }
      .tabBar(this.tabBarItem(index))
    }, (item: TabItem, index: number): string => `tab-${index}`)
  }

  /**
   * **降级底栏**要往上让出的高度（vp）。
   *
   * 设备支持悬浮样式（API ≥ 23）时返回 0：栏的位置由 `barFloatingStyle.barBottomMargin`
   * 决定，本身就在手势条上方。
   *
   * 低版本设备上没有悬浮样式，栏是 HDS 的**普通页签栏**、贴着承载层底边；而外层
   * `HdsNavigation` 是 `.ignoreLayoutSafeArea([...TOP, BOTTOM])`（见 nativeShell）——
   * 内容一直铺到屏幕最底，所以必须自己把系统条那一条让出来（需求）。
   *
   * **只让"刚好够"的高度**（需求："图标刚好能避让的高度就行"）：
   *   不加高时图标底边离屏幕底边 `BAR_ICON_BOTTOM_NATURAL`（实测 24vp），
   *   要让这条底边落到「系统条高度 + 一条缝」之上，还差多少就补多少 —— 多一个 vp 都不给。
   * 所以底部系统条本来就矮、或者根本没有的设备上，这个值会小到 0（不加高）。
   */
  private degradedBarInset(): number {
    if (PlatformCap.hasHdsMaterial()) {
      return 0;
    }
    const wanted: number = this.bottomSafeVp + BAR_ICON_CLEARANCE;
    return Math.max(0, wanted - BAR_ICON_BOTTOM_NATURAL);
  }

  /**
   * 喂给 HdsTabs 的**降级档栏高**（vp）：普通栏高 + 让出系统条的那一段。
   *
   * 只在降级档用得上（悬浮档的栏高写在调用处的 `.barHeight(BAR_HEIGHT - 收缩量)` 上，
   * 因为下沉收缩要让它跟着滚动量动）。
   *
   * 降级档（需求："通过增加容器底部高度来避让，不要直接悬浮"）让的是**栏自己的底边**：
   * 栏高变高，栏的背板跟着一直铺到屏幕底边，底部那一条是栏的背板而不是露出来的内容；
   * 栏里面图标的落点由 `tabBarItem` 的下内边距顶回去，所以图标不会跟着往下走。
   * （另一种做法是把整层往上抬/给栏加下外边距 —— 那会让栏连同背板一起离开屏幕底边，
   * 看起来就是栏浮在内容上，正是需求里不要的。）
   *
   * 这个高度**不随滚动变**：降级档下 HDS 的普通页签栏不吃下沉那一套参数，
   * 收缩只在支持悬浮底栏的版本上做（需求，见 onFeedScroll）。
   */
  private degradedBarHeight(): number {
    return BAR_HEIGHT + this.degradedBarInset();
  }

  /**
   * 量一次屏幕底部系统条的高度（只给降级底栏用）。
   *
   * 两个来源取**大者**：
   *   `TYPE_NAVIGATION_INDICATOR` —— 手势条（手势导航的设备给这个）；
   *   `TYPE_SYSTEM`              —— 系统条整块（三键导航的设备上手势条是 0，只有这个有值）。
   * 只读手势条的话，三键导航的设备会量到 0、图标就压在导航键上了。
   * 两个接口给的矩形都是**px**，转成 vp 再存；一个都拿不到就保留兜底值
   * （见 NAV_INDICATOR_FALLBACK）。
   */
  private async readBottomSafeVp(): Promise<void> {
    try {
      const host: common.Context | undefined = this.getUIContext().getHostContext();
      if (host === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(host);
      // 顶部状态栏那一条（评论浮层"上滑加高"的上界要用，见 commentsMaxVp）。
      const topPx: number = win.getWindowAvoidArea(
        window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const topVp: number = topPx > 0 ? px2vp(topPx) : 0;
      if (topVp > 0) {
        this.topSafeVp = topVp;
      }
      // 降级底栏才需要底部那一条（悬浮档由 HDS 自己让开）。
      if (PlatformCap.hasHdsMaterial()) {
        return;
      }
      const navPx: number = win.getWindowAvoidArea(
        window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      const sysPx: number = win.getWindowAvoidArea(
        window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height;
      const navVp: number = navPx > 0 ? px2vp(navPx) : 0;
      const sysVp: number = sysPx > 0 ? px2vp(sysPx) : 0;
      const bottom: number = Math.max(navVp, sysVp);
      if (bottom > 0) {
        this.bottomSafeVp = bottom;
      }
      hilog.info(DOMAIN, TAG,
        'bottom safe area: indicator=%{public}dpx(%{public}dvp) system=%{public}dpx(%{public}dvp)'
          + ' → used %{public}dvp, bar inset=%{public}dvp, top=%{public}dvp',
        Math.round(navPx), Math.round(navVp), Math.round(sysPx), Math.round(sysVp),
        Math.round(this.bottomSafeVp), Math.round(this.degradedBarInset()),
        Math.round(this.topSafeVp));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read bottom safe area failed: %{public}s',
        (error as Error).message);
    }
  }

  /**
   * 悬浮样式的配置（悬浮档专用，见 BarChromeModifier）。
   *
   * 悬浮页签的三件套在调用处：barOverlap(true) + vertical(false) + barPosition(End)，
   * 缺一个悬浮样式和沉浸光感都不生效（官方文档「设置页签栏的悬浮样式」的约束条件）。
   *
   * 材质：HDS 的 `systemMaterialEffect`，材质类型交给系统自适应，等级与标题栏同源
   * （设定页「材质等级」→ immersiveLevel：自适应 ADAPTIVE / 精美 EXQUISITE / 轻柔 GENTLE /
   * 流畅 SMOOTH，低算力设备会降级）。这一层没有反色字段，所以页签图标不随背景反色。
   *
   * @param sinkable true = 下沉收缩那套：离底距离随下沉程度变小（栏高走调用处的直接属性）；
   *                 false = 系统显隐那套 / 降级档：位置固定。
   */
  private floatingStyle(sinkable: boolean): HdsTabsFloatingStyle {
    const style: HdsTabsFloatingStyle = {
      // 胶囊宽度靠左右留白控制：留白 = (屏宽 - 目标宽度) / 2，见 barSideMargin()。
      barSideMargin: this.barSideMargin(),
      // 下沉走"离底距离"，不给承载层套 translate（原因见 BAR_SINK_DISTANCE）。
      // 快拍卡片经过时再压下去 `BAR_POCKET_DIP × storyPocket`（"弹一下"，见 storyPocket 的说明）。
      barBottomMargin: (sinkable ? BAR_REST_BOTTOM - BAR_SINK_DISTANCE * this.barSink : BAR_REST_BOTTOM)
        - BAR_POCKET_DIP * this.storyPocket,
      // 智感握姿（官方空间化能力之一）：宽屏/平板握持时悬浮栏会跟着手左右靠。
      // 官方首页示例默认开着，但我们实测在手机上它会按握持手把胶囊整体偏移（实测偏了
      // 约 72vp，看着就是"栏没对准屏幕中心"），而需求要的是居中那条悬浮栏，所以关掉。
      // 想要这个效果把 false 改回 true 即可（一行的事）。
      adaptToHandedness: false
    };
    // 沉浸光感的材质字段是 **6.1.0(23)** 起的：低版本设备上连那个枚举都不存在，
    // 所以整段**有条件地加上去**（而不是传 undefined 进去，见 core/PlatformCap）。
    if (PlatformCap.hasHdsMaterial()) {
      style.systemMaterialEffect = {
        materialType: immersiveMaterialType(),
        materialLevel: immersiveLevel(this.materialLevel)
      };
    }
    return style;
  }

  /**
   * 标题栏样式：**按当前分页给**（首页一套、其余分页一套）。
   *
   * 为什么不能所有分页都用首页那套"随内容滚动的动态模糊"：
   *   HDS 的动态模糊（`scrollEffectOpts.enableScrollEffect`）是**跟着绑定的滚动容器**走的
   *   —— 首页把信息流那条交给了标题栏（见 nativeShell 的 bindToScrollable([feedScroller])），
   *   所以它一滚、背板就渐显，观感正确。而 Reels / 私信 / 搜索 / 我的这四页，用的是它们
   *   **各自的**列表 / 翻页容器（ReelsPage 的 Swiper、DirectPage/SearchPage/ProfilePage 的
   *   List），一个都没绑到标题栏上 —— 于是标题栏永远停在"还没开始滚"的那个状态上，
   *   也就是**完全透明**（用户报的"这四页的 hd title 没有模糊背景、纯透明"）。
   *
   * 所以其余分页改用通知页/设定页那套（见 destinationTitleStyle）：不做滚动联动，
   * 背板（沉浸光感材质给的模糊）**常驻**，任何时候都有模糊背景 —— 和用户认可的通知页一致。
   */
  private pageTitleStyle(): TitleBarStyleOptions {
    return this.currentTab() === AppTab.Home ? this.feedTitleStyle() : this.destinationTitleStyle();
  }

  /**
   * 首页标题栏样式（HDS 的 `titleBar({ style })`）。
   *
   * **为什么包成一个方法**：沉浸光感那两个字段是 6.1.0(23) 起才有的，而这个包 compatibleSdk 是 20。
   * 直接写在字面量里，低版本设备上拿到的是 undefined（枚举不存在）——轻则没效果，重则异常。
   * 所以按 `PlatformCap.hasHdsMaterial()` 有条件地加上去；滚动效果类型还要看明暗主题
   * （浅色模式下 `IMMERSIVE_GRADIENT_BLUR` 会把标题刷成白字，见 titleScrollEffectType）。
   */
  private feedTitleStyle(): TitleBarStyleOptions {
    const style: TitleBarStyleOptions = {
      // 标题栏随内容滚动的**动态背景**（官方叫"动态模糊"/沉浸式标题栏）：内容滑到标题栏
      // 底下时，栏背板按滚动量渐变，所以标题栏看起来是"透"的。
      //
      // 上一版这里是 `enableScrollEffect: false`（当时想着"长列表滚动时突变抢眼"），
      // 结果就是用户看到的"title 的背景变成黑色" —— 关掉之后标题栏不再有随内容滚动的
      // 背板，只剩材质铺在页面底色上，而页面底色是黑的（见 build 里 root 的
      // page_background），于是整条栏就是一块黑。
      // 效果类型按设备能力 + 明暗主题给，见 titleScrollEffectType（浅色模式下不能要
      // IMMERSIVE_GRADIENT_BLUR：它会把标题文字刷成白色，最顶上就是白字压白底）。
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: titleScrollEffectType(this.isDarkUi)
      }
    };
    if (PlatformCap.hasHdsMaterial()) {
      // 沉浸光感：材质类型交给系统按环境自适应，档位跟设定页那一档（和底部悬浮栏同源）。
      style.systemMaterialEffect = {
        materialType: immersiveMaterialType(),
        materialLevel: immersiveLevel(this.materialLevel)
      };
    }
    return style;
  }

  /** 二级页（通知 / 设定）标题栏样式：不做滚动模糊，其余同上。 */
  private destinationTitleStyle(): TitleBarStyleOptions {
    const style: TitleBarStyleOptions = {
      // 信息流式的长列表不做滚动模糊，短列表也不做。
      scrollEffectOpts: {
        enableScrollEffect: false,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
      }
    };
    if (PlatformCap.hasHdsMaterial()) {
      style.systemMaterialEffect = {
        materialType: immersiveMaterialType(),
        materialLevel: immersiveLevel(this.materialLevel)
      };
    }
    return style;
  }

  /**
   * 胶囊左右留白（vp）：由目标宽度换算出来。
   *
   * HDS 的悬浮样式没有"直接给宽度"的入口（barWidth 是按设备档位给三档宽度），
   * 所以"栏多宽"反过来算：留白 = (屏宽 - 目标宽度) / 2。
   * 下沉收缩那套还要在此基础上再收窄 BAR_SINK_WIDTH（见 BAR_SINK_WIDTH）；系统显隐
   * 那套不动宽度。屏幕宽度拿不到时退回一个固定留白，不至于把栏挤没。
   *
   * 降级档下这个值用不上（`barFloatingStyle` 整个不生效），算出来是 0 也无人问津。
   */
  private barSideMargin(): number {
    const screenVp: number = this.screenWidthVp;
    if (screenVp <= 0) {
      return 16;
    }
    const target: number = this.barHideMode === BAR_HIDE_SYSTEM
      ? BAR_WIDTH + BAR_POCKET_GROW_W * this.storyPocket
      : BAR_WIDTH - BAR_SINK_WIDTH * this.barSink + BAR_POCKET_GROW_W * this.storyPocket;
    return Math.max(8, (screenVp - target) / 2);
  }

  /**
   * 系统栏里那一项的内容：**只有图标，没有文字**。
   *
   * 用 Stack 装图标：Stack 默认就把子节点居中，不用再算文字留白 ——
   * HDS 默认项是"图标 + 文字"整体居中，文字那一行会把图标顶上去（本项目踩过），
   * 所以这里给自定义项，自己说了算。
   *
   * 图标之间的间隔由**栏宽**决定（见 BAR_WIDTH / barSideMargin），不在这里调。
   * 颜色见 tabIconColor：系统色资源 + 材质自动反色。
   *
   * 降级档下栏的底边被加高了 `degradedBarInset`（见 degradedBarHeight），项区域跟着变高，
   * 图标如果不管就整体往下走一截、贴到系统条上。这里用**下内边距**把图标顶回原来那一段：
   * 项区底部多出来的那一段被内边距吃掉，图标仍然落在"栏高 60vp 那一段"里
   * （离栏顶 30vp，也就是离屏幕底边 `30 + inset` vp —— 多高由 degradedBarInset 算，
   * 悬浮档 inset = 0，这段是零）。
   *
   * 为什么是下内边距而不是上：内容区在"上下内边距"之间居中 —— 想让图标留在**上面**那 60vp
   * 里，就得把底部那一段挖掉（挖上面会把图标往下推，实测图标会压到手势条上）。
   */
  @Builder
  tabBarItem(index: number) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(this.selectedIndex === index
        ? TAB_ITEMS[index].iconSelected
        : TAB_ITEMS[index].iconNormal)
        .fontSize(TAB_ICON_SIZE)
        .fontColor([this.tabIconColor(this.selectedIndex === index)])
    }
    .width('100%')
    .height('100%')
    // 下边距 = 栏底部让出去的那一段：图标的落点因此与栏没加高时一致。
    .padding({ bottom: this.degradedBarInset() })
  }

  /**
   * 底栏图标的颜色。
   *
   * **必须写"资源里的系统颜色"**（文档：开启自动反色后文字颜色没有变化）。材质的智能反色
   * 只对**通过资源接口设置**的颜色生效：写到 `SymbolGlyph.fontColor` 上的系统色会由系统按
   * 材质下方背景取反色，深色背景给浅色、浅色背景给深色 —— 这正是需求里"浅色背景用深色图标、
   * 深色背景用浅色图标"，而且不用我们自己盯像素。
   * 写死色值（`#FFFFFF` 之类）不会参与反色，所以这里一个都不能有。
   */
  private tabIconColor(selected: boolean): Resource {
    return selected ? $r('sys.color.font_primary') : $r('sys.color.font_secondary');
  }

  /**
   * 系统那条栏换了项（Tabs 的 onChange）。
   *
   * 回调顺序是**先 `onTabBarClick`、后 `onChange`**：点了栏，系统先通知我们，然后自己把
   * 内部下标换到被点的那一项。所以：
   *   - 我们**打算切页**时，`selectedIndex` 已经被设成同一个值 → 这里 `index` 与它相等，不用管；
   *   - 下标"多出来"时（系统自己换了项、而我们没跟着换页）必须把它拉回去，否则那份内部下标
   *     和 `selectedIndex` 长期分叉，被点过的那一项在系统眼里已经选中，之后再点它不再报点击
   *     （表现：某项点一次之后再也点不动）。
   *
   * 对齐动作是幂等的、也不会闪：底部高亮是照 `selectedIndex` 自己画的，与这份内部下标无关。
   */
  private onTabsChanged(index: number): void {
    if (this.syncingTabsIndex) {
      return;
    }
    if (index === this.selectedIndex) {
      return;
    }
    hilog.debug(DOMAIN, TAG, 'tabs index %{public}d != selected %{public}d, resync',
      index, this.selectedIndex);
    this.syncTabsIndex();
  }

  /**
   * 点了栏里的某一项。**两套行为下不一样**：
   *
   *   系统显隐（system）：藏起来的时候整条栏根本不在屏幕上，用户点不到它，所以能点到就是
   *     露着，直接切页。**Reels 例外**：那一页两档都用下沉收缩（见 onReelsSink），所以要按
   *     下面的"沉着先捞回来"处理 —— 需求："只有点击才会恢复"。
   *   下沉收缩（sink）：栏沉下去时**还在屏幕上**，那一下点击按需求只负责"把栏捞回来"、
   *     不切页（"点击弹回不切页，点击恢复优先"）；并且同一轮滚动剩下的增量作废，免得
   *     惯性又把它蹬下去。站稳之后再点才切页。
   *   降级档：`barSink` 恒为 0、吞点击窗口恒为 0，所以直接走"切页"这条路。
   *
   * 这里**不**去对齐系统的内部下标：系统随后还会自己换一次项，会把这里的对齐覆盖掉，
   * 对齐统一放到 onTabsChanged（它在系统换完之后才来）。
   */
  private onTabBarClick(index: number): void {
    if (this.syncingTabsIndex) {
      return;
    }
    if (index < 0 || index >= TAB_ITEMS.length) {
      return;
    }
    hilog.debug(DOMAIN, TAG, 'tab click i=%{public}d sink=%{public}d sel=%{public}d',
      index, this.barSink, this.selectedIndex);
    if (this.barHideMode === BAR_HIDE_SYSTEM && this.currentTab() !== AppTab.Reels) {
      this.selectedIndex = index;
      this.selectTab(TAB_ITEMS[index].tab);
      // 切页之后栏必须露着（新页面的内容一般在上半屏，用户也会想接着用栏）。
      this.showBar();
      return;
    }
    // 沉着：这一下只负责把栏捞回来（同时开一个很短的吞点击窗口给同一次点击的重复回调）。
    if (this.barSink !== 0) {
      this.restoreBarByTap();
      return;
    }
    // 吞点击窗口内：只吃掉，**绝不延长窗口**。
    // 这里以前是"再调一次 restoreBarByTap"，等于每被吞一次就把窗口续 320ms ——
    // 连着点几下（间隔小于窗口）时窗口永远续着，怎么点都切不了页，
    // 表现就是"从首页/我的能切进中间三页，之后中间三页之间怎么点都换不过去"。
    if (Date.now() < this.barClickGuardUntilMs) {
      return;
    }
    this.selectedIndex = index;
    this.selectTab(TAB_ITEMS[index].tab);
  }

  /**
   * 把系统那条 Tabs 的内部下标拉回 `selectedIndex`。
   *
   * 我们的"当前页"只有一个真相来源 `selectedIndex`（内容层按它切页）；Tabs 内部还有一份
   * 自己的下标，用户点栏时它会先动。两份不一致时会出现"点了没反应"（系统认为那一项已经
   * 选中，不再报点击）和底部高亮漂移，所以每次处理完点击都对齐一次。
   * 同步期间挂一个标志，避免 syncTabsIndex 自身触发的回调被当成用户点击。
   */
  private syncTabsIndex(): void {
    this.syncingTabsIndex = true;
    try {
      this.tabsController.changeIndex(this.selectedIndex);
    } catch (error) {
      // 控制器还没绑上（页面刚建）：下一次点击时会再对齐，忽略即可。
    }
    this.syncingTabsIndex = false;
  }

  /**
   * 页面滚动 → 驱动底栏。**四个列表页共用这一个入口**（首页信息流、私信、搜索、我的各自
   * 把自己列表的滚动增量报上来）。
   *
   * 分流按**能力 + 设定页那个开关**：
   *   降级档（API < 23，没有悬浮样式）—— 直接返回：那两套行为动的全是悬浮样式上的参数
   *     （栏高 / 左右留白 / 离底距离）与 HDS 的显隐动效，低版本的普通页签栏一样都不吃，
   *     滚动**完全不碰**底栏（需求：收缩只在支持悬浮底栏的版本上做）。
   *   悬浮档 —— 按设定页的开关二选一：
   *     sink（默认）下沉收缩：栏往下挪一截 + 收窄 + 缩矮，始终留在屏幕上（本项目自绘）；
   *     system     系统显隐：调 HdsTabsController 自带的隐藏/显示动效，栏整条收走。
   *
   * **Reels 不走这里**：那一页是整屏翻页的 Swiper，用的是自己那套（见 onReelsSink）——
   * 只沉不回、点一下才回来，和这里的"上滑沉 / 下滑弹回"语义不同。这里保留 `!== Reels` 的
   * 判断只是兜底：万一哪天真有 Reels 的滚动报进来，也不会去播系统那支动效。
   *
   * 两支的判据与记账各自独立（见下面两个方法）：口径不一样 —— 下沉有"点击还原优先"和两档
   * 死区，系统显隐只有翻转去重 —— 混在一起会互相干扰。
   */
  private onFeedScroll(deltaY: number, offsetY: number, scrollState: ScrollState): void {
    // 用户正在滑：记一笔，后台预热据此让路（见 warmStep/waitIdle）。
    this.lastInteractionMs = Date.now();
    // 搜索框的收放不在这里判：它已经跟着搜索框搬进了 SearchPage（见那边的 trackSearchBox），
    // 页面在把事实报上来之前就自己处理完了。
    if (!PlatformCap.hasHdsMaterial()) {
      return;
    }
    const system: boolean = this.barHideMode === BAR_HIDE_SYSTEM
      && this.currentTab() !== AppTab.Reels;
    if (system) {
      this.onFeedScrollNative(deltaY, offsetY, scrollState);
      return;
    }
    // 下沉收缩：手指一动就沉，方向/位置一概不看（见 onSinkRequest）。
    this.onSinkRequest(scrollState);
  }

  /**
   * Reels：**手指一开始划就把栏沉下去**（需求："灵敏一些，手指开始滑动时就收缩"）。
   *
   * 和别的页面共用同一条下沉逻辑（`onSinkRequest`），额外的两点在入口处分流：
   *   1. 不看设定页那一档 —— Reels **两档都用下沉收缩**（系统那支"整条栏收走"在这里没有
   *      内容可躲，还会和翻页动画抢戏，见 onFeedScroll）；
   *   2. 没有滚动状态可传（只有"手指开始划"这一个事件），保护期判定按"新的一次手势"处理。
   */
  private onReelsSink(): void {
    this.onSinkRequest();
  }

  /**
   * 系统显隐那套：按滚动方向调 HdsTabsController 自带的那两个接口。
   *
   *   `applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION)` —— 滚动场景的隐藏动效；
   *   `applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION)` —— 滚动场景的显示动效。
   * 栏怎么滑走、滑多远、曲线多长都由 HDS 定，我们只负责在正确的时机调一次。
   *
   * 判据是**方向**而不是位置：往上滑（deltaY > 0）→ 藏起来；往下滑（deltaY < 0）→ 露出来。
   * 只有「和当前状态相反」的那个方向才累加，顺势的滚动直接清零 —— 也就是说栏一旦藏起来，
   * 得先真的往下滑一段（死区 `BAR_SCROLL_DEAD_ZONE`）才会露回来。
   *
   * 累加只在**手指拖着**的时候做（惯性阶段直接返回）：上滑的惯性末尾、到顶/到底的回弹
   * 都会冒出几帧反向增量，用单帧判断的话栏会"藏一下又露出来"，看起来就是什么都没发生。
   */
  private onFeedScrollNative(deltaY: number, offsetY: number, scrollState: ScrollState): void {
    // 还在顶部（含边缘回弹）：栏一定是露着的，顺便清掉累计，
    // 免得顶端下拉再弹回去那一下被算成"上滑"把栏藏了。
    if (offsetY <= BAR_TOP_GUARD_OFFSET) {
      this.barScrollPull = 0;
      if (this.barHidden) {
        this.showBar();
      }
      return;
    }
    // 惯性阶段不参与判断（动效有自己的时长，惯性里的抖动只会让它被反复打断）。
    if (scrollState !== ScrollState.Scroll) {
      this.barScrollPull = 0;
      return;
    }
    // 刚翻转过的这一小段（冷却期）里什么增量都不认：翻转会让列表"顶"一下，
    // 回弹的反向增量正好够把它立刻翻回去。冷却期很短，用户接着滑照样能翻转。
    if (Date.now() < this.barToggleCooldownUntilMs) {
      this.barScrollPull = 0;
      return;
    }
    // 只有"推着栏往目标状态走"的那个方向才算数：还露着就等上滑（deltaY > 0），
    // 已经藏起来就等下滑（deltaY < 0）；反方向的增量直接清零。
    const wantHide: boolean = !this.barHidden;
    const productive: boolean = wantHide ? deltaY > 0 : deltaY < 0;
    if (!productive) {
      this.barScrollPull = 0;
      return;
    }
    this.barScrollPull += deltaY;
    if (Math.abs(this.barScrollPull) < BAR_SCROLL_DEAD_ZONE) {
      return;
    }
    this.barScrollPull = 0;
    this.barToggleCooldownUntilMs = Date.now() + BAR_TOGGLE_COOLDOWN_MS;
    if (wantHide) {
      this.hideBar();
    } else {
      this.showBar();
    }
  }

  /**
   * 「下沉收缩」的**唯一入口**：沉下去就完了 —— 方向、位置、增量一概不看。
   *
   * 语义（需求，Reels 与其它页面统一）：**手指一开始滑就收缩；往下滑不会恢复大小；
   * 只有点栏才恢复**（见 onTabBarClick）。所以这里没有死区、没有方向判据，也不再累计
   * 滚动量：整张表只有一个目标状态"沉"。
   *
   * 唯一要挡的是"点击还原之后那一下惯性"：用户点栏把栏捞回来时，上一轮滚动的惯性往往还在跑，
   * 那几帧增量会立刻把它蹬回去（看起来就是"点了没用"），所以点击还原会开一个保护期
   * （见 restoreBarByTap / ignoreScrollUntilMs），保护期内不再下沉。
   *
   * @param scrollState 调用方拿得到这一帧的滚动状态时传进来（`Idle` 表示这一轮滚动结束，
   *   保护期可以提前解除）；Reels 只有"手指开始划"这一个事件，传 undefined。
   */
  private onSinkRequest(scrollState?: ScrollState): void {
    if (!PlatformCap.hasHdsMaterial()) {
      return;
    }
    if (scrollState !== undefined && this.ignoreScrollUntilMs > 0) {
      if (scrollState === ScrollState.Idle || Date.now() >= this.ignoreScrollUntilMs) {
        this.ignoreScrollUntilMs = 0;
      } else {
        return;
      }
    }
    this.applyBarSink(1);
  }

  /**
   * 把栏藏起来（HDS 的隐藏动效，只在系统显隐下调用）。
   *
   * `barHidden` 是**去重**用的：同一支动效连着播会互相打断，看着就一顿一顿的，
   * 所以状态没变就直接返回。调用失败只记日志 —— 栏露着不影响用。
   */
  private hideBar(): void {
    if (this.barHidden) {
      return;
    }
    this.barHidden = true;
    hilog.info(DOMAIN, TAG, 'bar hide animation (native)');
    try {
      this.tabsController.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'hide bar failed: %{public}s', (error as Error).message);
    }
  }

  /** 把栏露出来（HDS 的显示动效）。切页、回到列表顶部都会走这里。 */
  private showBar(): void {
    if (!this.barHidden) {
      return;
    }
    this.barHidden = false;
    this.barScrollPull = 0;
    hilog.info(DOMAIN, TAG, 'bar show animation (native)');
    try {
      this.tabsController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'show bar failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 把栏设到某个状态（0 = 原位，1 = 完全下沉）。**下沉收缩那套专用**，会先看设定页那一档。
   *
   * 降级档下这套不跑（没有悬浮样式，那几个参数一个都不生效）；系统显隐档下也不跑
   * （显隐由 HDS 动效负责，免得两种效果叠在一起）。真正下发在 `applyBarSink`。
   */
  private setBarSink(value: number): void {
    // 降级档：滚动不碰底栏（见 onFeedScroll）。
    if (!PlatformCap.hasHdsMaterial()) {
      return;
    }
    // 系统显隐模式下这一层不动（显隐由 HDS 动效负责），免得两种效果叠在一起。
    if (this.barHideMode === BAR_HIDE_SYSTEM) {
      return;
    }
    this.applyBarSink(value);
  }

  /**
   * **无条件**把栏设到某个下沉程度（不看设定页那一档，调用方自己负责判模式）。
   *
   * 谁需要绕过模式判断：**Reels 页**——需求要求那一页两档都用下沉收缩（见 onReelsSink），
   * 以及"切页/点击还原"这类**收尾**动作（`restoreBar`：系统显隐档下 barSink 本来就是 0，
   * 这里会直接返回，不会有副作用）。
   *
   * 补间用 `animateTo` 做：这次一起动的是**栏自己的三个布局参数**（`barHeight` 变矮、
   * `barSideMargin` 变宽、`barBottomMargin` 变小，见 floatingStyle / 调用处的 barHeight），
   * 它们都是 Tabs 的属性，只有包进 animateTo 才会走同一条弹簧曲线。
   */
  private applyBarSink(value: number): void {
    if (!PlatformCap.hasHdsMaterial()) {
      return;
    }
    if (this.barSink === value) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'bar sink=%{public}d', value);
    // 顶部 HDS 标题栏**不跟着动**（需求："不需要隐藏 hdsnavigation"）：早先那版会在下沉时用
    // HDS 的原生显隐动画把标题栏收走，已按需求撤掉。跟着栏下沉的是 reels 页的**动作区 +
    // 资讯区**（见 OVERLAY_SINK_DISTANCE / reelsTab 传下去的 overlaySink）。
    this.barToggleCooldownUntilMs = Date.now() + BAR_TOGGLE_COOLDOWN_MS;
    this.getUIContext().animateTo({ curve: curves.springMotion() }, (): void => {
      this.barSink = value;
    });
  }

  /** 把栏弹回原位（系统显隐 / 降级档下不用我们管）。 */
  private restoreBar(): void {
    this.barScrollPull = 0;
    this.applyBarSink(0);
  }

  /**
   * 下沉收缩的"点击还原"：弹回原尺寸，并且**把这一轮滚动剩下的增量作废**。
   *
   * 这是"点击恢复优先"的落点：还原之后紧接着来的滚动事件（惯性滚动尤其明显）不再
   * 把它蹬下去，直到这一轮滚动结束（ScrollState.Idle）或超过保护期。
   * 同时开一个很短的吞点击窗口，把**同一次点击**里多报进来的回调一并吃掉（见 onTabBarClick）。
   */
  private restoreBarByTap(): void {
    this.ignoreScrollUntilMs = Date.now() + BAR_RESTORE_GRACE_MS;
    this.barClickGuardUntilMs = Date.now() + BAR_CLICK_GUARD_MS;
    this.restoreBar();
  }

  /**
   * 设定页里换了沉浸光感的档位。
   *
   * HDS 那几处（标题栏）读 `immersiveLevel(this.materialLevel)`，@StorageProp 一变就重绘；
   * 这里只打一行日志，出问题时能确认"档位真的切了"。
   */
  private onMaterialLevelChanged(): void {
    hilog.info(DOMAIN, TAG, 'material level -> %{public}s', this.materialLevel);
  }

  /**
   * 设定页里换了底栏的行为。
   *
   * 换行为时要把**另一套留下的状态**收干净：
   *   - 切到系统显隐：自绘形变回原位（否则栏会以"缩着"的尺寸去播 HDS 动效），直接赋值、
   *     不走 animateTo（那是给用户滚动看的补间）；
   *   - 切到下沉收缩：系统动效留下的"已隐藏"状态清零，并且把栏叫回来
   *     （栏那个组件实例**不会**因为开关而重建 —— 现在是按能力分支、不是按开关分支，
   *     所以不能指望新实例天然是露着的）。
   * 降级档下两套都不跑（设定页里那一组也看不到），这里只是把记账清零。
   */
  private onBarHideModeChanged(): void {
    this.barScrollPull = 0;
    this.barToggleCooldownUntilMs = 0;
    this.ignoreScrollUntilMs = 0;
    this.barClickGuardUntilMs = 0;
    this.barSink = 0;
    const wantShow: boolean = this.barHidden && this.barHideMode !== BAR_HIDE_SYSTEM;
    if (wantShow && PlatformCap.hasHdsMaterial()) {
      this.showBar();
    }
    this.barHidden = false;
    hilog.info(DOMAIN, TAG, 'bar mode -> %{public}s', this.barHideMode);
  }

  /**
   * 「我的」页面。
   *
   * 还没有真正的个人主页实现，所以主体是占位说明。
   *
   * **这里不再自己画标题栏**：早先页面顶上有一行"我的 + more 按钮"，那是标题栏和菜单
   * 还没绑到 HdsNavigation 时的临时做法；现在标题、设定入口都走 HdsNavigation 的
   * title / menu（见 pageTitle / menus），页内再留一行就是**两个标题栏**了。
   * 退出登录在设定页最底下（见 SettingsPanel）。
   */
  @Builder
  profilePage() {
    ProfilePage({
      vm: this.profileVm,
      // 滚动 → 底栏下沉/隐藏（和首页同一条路，见 onFeedScroll）。
      onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
        this.onFeedScroll(deltaY, offsetY, scrollState);
      },
      // 点格子 → **帖子页**（需求：把我的页的帖子/收藏/被提及分页也接进去）：
      // 当前分页整份铺成 feeds 流，并定位到点的那一条；loadMore 供帖子页进页/触底继续翻。
      // `true` = 这一页是从**我自己的主页**进来的（帖子 / 收藏 / 被标注都算）——
      // 那种帖子页标题栏不给关注按钮（见 postPageMenu 与 postPageFromOwnProfile）。
      onOpenStream: (posts: Array<MediaPost>, index: number,
                     loadMore: () => Promise<ProfileStreamPage>): void => {
        this.openPostStream(posts, index, loadMore, true);
      },
      // 点**视频那一段**的格子 → Reels 页（需求：视频分页点进去是新的页面，用 reels 模板）。
      onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                    loadMore: () => Promise<ProfileStreamPage>): void => {
        this.openProfileReels(posts, shortcode, hasMore, loadMore);
      },
      onOpen: (post: ProfilePost): void => {
        // 兜底（没接 onOpenStream 时才会走到）：交给网页打开那条帖子。
        this.openWeb(`https://www.instagram.com/p/${post.shortcode}/`);
      }
    })
  }

  /** Reels 标签：现在只有视频流（见 ReelsPage）。 */
  @Builder
  reelsTab() {
    ReelsPage({
      vm: this.reelsVm,
      // 标题栏那两颗按钮按**来源**取用（见 core/ReelsAction）：这是底栏那一页。
      source: ReelsAction.HOME,
      // 刷到自己的视频时不画关注按钮（同其它两页）。
      ownAuthor: this.profileVm.ownAccountName(),
      // 手指一动就下沉，且**只沉不回**（点栏才恢复）——见 onReelsSink。
      onReelSwipe: (): void => {
        this.onReelsSink();
      },
      // **动作区 + 资讯区跟着栏一起下沉**（需求）：栏沉 10vp 时这两块跟着往下走
      // OVERLAY_SINK_DISTANCE（见那个常量）。`barSink` 是 0→1 的两态量，中间值由下面那条
      // 弹簧曲线补出来（见 applyBarSink），所以这里直接乘出距离即可 —— 动画是同一条。
      overlaySink: OVERLAY_SINK_DISTANCE * this.barSink,
      onLike: (reel: Reel, like: boolean): Promise<boolean> => {
        return this.likeReel(reel, like);
      },
      onRepost: (reel: Reel, repost: boolean): Promise<boolean> => {
        return this.repostReel(reel, repost);
      },
      // 收藏（书签）：HTTP 直发到 `/api/v1/media/{id}/save|unsave/`，见 saveReel。
      onSave: (reel: Reel, save: boolean): Promise<boolean> => {
        return this.saveReel(reel, save);
      },
      onFollow: (reel: Reel, follow: boolean): Promise<boolean> => {
        return this.followReelAuthor(reel, follow);
      },
      onOpenUser: (reel: Reel): void => {
        this.openReelAuthor(reel);
      },
      onComments: (reel: Reel): void => {
        this.openReelComments(reel);
      },
      onShare: (reel: Reel): void => {
        this.toast($r('app.string.feature_pending'));
      },
      onMore: (reel: Reel): void => {
        this.toast($r('app.string.feature_pending'));
      },
      // 正文翻译失败：弹一句（页面自己退回原文态）。
      onTranslateFailed: (): void => {
        this.toast($r('app.string.translate_failed'));
      }
    })
  }

  /**
   * 私信标签：原生收件箱（会话列表）。
   *
   * 点一条会话**交给网页打开**（和「点帖子」「点「我的」格子」同一条路）：原生不构造写请求，
   * 也不做发送 —— 需求明确不要发送功能，看会话在网页里进行。
   */
  @Builder
  directPage() {
    DirectPage({
      vm: this.directVm,
      onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
        this.onFeedScroll(deltaY, offsetY, scrollState);
      },
      onOpen: (thread: DirectThread): void => {
        this.openDirectThread(thread);
      }
    })
  }

  /**
   * 私信会话页右上角的两颗按钮：**电话 / 视频**（需求："menus分别有两个按钮，电话和视频，
   * sys.symbol.phone 和 sys.symbol.video，先不用做功能"）。
   *
   * 说明：HDS 的 menu 不是"随便一个 builder"，而是**数据式菜单项**（`{ content: { label,
   * type, action } }`，见 postPageMenu / reelsMenu）；这里用 label 承载"电话 / 视频"，
   * 点下去先给一句"功能还没接上"。
   */
  private directThreadMenus(): HdsNavigationMenuContentOptions {
    /*
     * 需求："menus分别有两个按钮，电话和视频，sys.symbol.phone 和 sys.symbol.video"。
     *
     * 三条踩过的坑（都验证过）：
     *   ① `label` 要**字符串或资源**，不能是 Resource 对象以外的东西；写错会把资源名当文本印出来
     *      （真机上出现过 `app.string.direct_call` 那串字面量 —— 那是 `$r` 被脚本吃掉造成的）；
     *   ② `symbolIcon` 不是 HdsNavigationIconOptions 的字段（那是普通 NavigationMenuItem 的）；
     *      `symbolStyle` + 显式类型又会撞 arkts-no-untyped-obj-literals；
     *   ③ 所以图标走 **`icon`** 字段（`$r('sys.symbol.*')` 本身就是资源，能直接给）。
     */
    /*
     * 图标：HDS 这条 menu 是**数据式**菜单项，试过的三条路都被 ArkTS/HDS 挡住：
     *   · `symbolIcon` → 不是 HdsNavigationIconOptions 的字段；
     *   · `symbolStyle`（无论直接写字面量、还是先把 SymbolGlyphModifier 放进变量）→
     *     菜单项本身是字面量，仍撞 `arkts-no-untyped-obj-literals`；
     *   · 只剩 `icon`（`$r('sys.symbol.*')` 本身就是资源）这一条能编译 —— 先用它。
     * 若真机上仍不显示符号，就改成把两颗符号按钮放进**页面内容**右上角（不自绘整条标题栏）。
     */
    return {
      value: [
        {
          content: {
            label: $r('app.string.direct_call'),
            icon: $r('sys.symbol.phone'),
            action: (): void => {
              this.toast($r('app.string.feature_pending'));
            }
          }
        },
        {
          content: {
            label: $r('app.string.direct_video_call'),
            icon: $r('sys.symbol.video'),
            action: (): void => {
              this.toast($r('app.string.feature_pending'));
            }
          }
        }
      ]
    };
  }

  /**
   * 打开一条私信会话（NavDestination，见 destinationBuilder）。
   *
   * 以前这里是 `openWeb(thread.threadUrl())` —— 把隐藏网页导航到私信会话，用户看到的是 IG 的
   * 网页版界面（还有地址栏那条外壳）。现在整条会话走**原生 HTTP**（读消息 + 发消息，见
   * core/NativeDirect），所以进的是自己的原生页（DirectThreadPage）。
   */
  private openDirectThread(thread: DirectThread): void {
    /*
     * **直接进原生会话页**（不再先探一次、失败就弹网页）。
     *
     * 以前这里先探一发 `NativeDirect.thread()`，读不到就 `openWeb(thread.threadUrl())` ——
     * 真机上 IG 对私信私有 REST 回 `404 + not-logged-in`（且当时原生侧还没有会话模板），
     * 所以**每次点会话都被弹去网页**（用户报的"弹到网页去了"）。
     *
     * 现在读数的三条路都收在 DirectThreadViewModel.load() 里：
     *   ① 原生 REST → ② 原生回放会话模板（NativeDirect.threadViaTemplate）→
     *   ③ 冷启动：让隐藏网页真开一次这条会话、抓到会话模板再回 ②。
     * 所以这里只管进页面；万一三条都不成，页面上的「在网页中打开」按钮是出口
     * （见 DirectThreadPage.onOpenWeb）。
     */
    this.directThreadVm.open(thread.id, thread.title, thread.avatarUrl, thread.isGroup,
      thread.key.length > 0 ? thread.key : '', thread.username);
    this.navStack.pushPath({ name: DIRECT_THREAD_PAGE, param: thread.id });
  }

  // ---------------------------------------------------------------- 限时快拍（主页托盘）

  /** 快拍播放浮层开着没有（见 build 末尾那一层 + onBackPress）。 */
  @State private storyOpen: boolean = false;
  /** 正在播的这一份（点开后先取数，拿到了才开浮层）。 */
  @State private storyReel: StoryReel | null = null;
  /** 被点头像在屏幕上的矩形（转场第一帧就画在这里，见 StoryViewer）。 */
  @State private storyHero: StoryHeroRect = new StoryHeroRect(0, 0, 0, 0);
  /**
   * 现在播的这位，头像**是不是还在主页托盘的那个位置**上（能飞回去）。
   *
   * 只有"用户点开的那一位"才是 true —— 顺着右半屏接了下一位之后就不是了，收起时
   * 播放页据此改成**向下收起**（需求，见 StoryViewer.requestClose）。
   */
  @State private storyHeroValid: boolean = false;
  /** 被点那一项的头像 / 用户名（取数回来那份里可能没有，先拿托盘的顶上）。 */
  @State private storyAvatar: string = '';
  @State private storyName: string = '';
  /** 正在播的这一位的 userId（播放页按它去量序列里那颗头像，排查转场错位用）。 */
  @State private storyUserId: string = '';
  /** 正在取数（防连点；转圈由托盘自己画，见 StoriesTray.pendingUser）。 */
  private storyLoading: boolean = false;
  /**
   * 系统返回键的"请收起"信号（每按一次 +1，见 StoryViewer.closeSignal）。
   *
   * 返回键**不能直接把浮层删掉** —— 那样收起就没有动画了（需求："做一下系统返回动画"）。
   */
  @State private storyCloseSignal: number = 0;
  /**
   * 宿主请求播放页**掉头展开**（收起途中点了空白，或点到了别的用户的头像）。
   *
   * 和 closeSignal 对称：动画在浮层里，宿主只发信号（见 StoryViewer.reopenSignal）。
   */
  @State private storyReopenSignal: number = 0;
  /**
   * 快拍卡片"掉进口袋"时，让底部 tab 栏**鼓一下**的量（0 = 原状，1 = 鼓到最大）。
   *
   * 需求："卡片接触到 tabbar 顶层穿过消失，卡片穿过时 tabbar 要稍微放大，完全穿过后回归原状，
   * 要有弹性动画"。栏是官方 HDS 悬浮栏，没有"直接缩放"的入口，但它本来就接受
   * `barHeight` / `barSideMargin` 这两个**布局尺寸**（下沉收缩那套就在用），所以在它们上各加
   * 一点：栏变高一点、变宽一点，就是"鼓起来"；两条都包在 animateTo 里，用 springMotion 做弹性。
   */
  @State private storyPocket: number = 0;
  /** 已经在收起（返回键连按两下时别把信号堆起来）。 */
  private storyClosing: boolean = false;
  /** 托盘那一整条顺序（托盘拉到后由 onLoaded 交过来）—— "下一位是谁"靠它。 */
  private storyQueue: Array<StoryTrayItem> = [];
  /**
   * 上面那份顺序是什么时候拿到的（毫秒；0 = 还没有）。
   *
   * 交给托盘用它判断 seed 还新不新鲜（见 StoriesTray.TRAY_FRESH_MS）：切回主页时
   * "有就先画、只有过期才后台刷"，避免每切一次 tab 就打一发 IG 的托盘接口。
   */
  private storyQueueAtMs: number = 0;
  /** 现在播的是队列里第几位（点右半屏接续下一位用）。 */
  private storyQueueIndex: number = 0;
  /** 这一发是"用户点开的"（拿到数据后要开浮层 + 播放大转场）。 */
  private storyPendingOpen: boolean = false;
  /**
   * 托盘每一项头像**当前**在屏幕上的位置（userId → 矩形，托盘每次布局变化都会更新）。
   *
   * 用途：收起播放页时要知道"**现在这一位**的头像在不在托盘里、在哪个位置" —— 在就朝它收缩
   * 并把播放页头像横移过去落上，不在就向下滑收（需求）。
   */
  private storyRects: Map<string, StoryHeroRect> = new Map<string, StoryHeroRect>();

  /**
   * 记下"最新这份托盘顺序"+时间。
   *
   * 两处要用它（别直接写 `storyQueue`）：
   *   · 托盘拉到数据时（`onStoryLoaded` / 启动预热）；
   *   · 切回主页重建托盘时，这份数据就是它的**首帧内容**（见 `storyQueueAtMs` 与
   *     StoriesTray.seed）：所以时间戳必须跟着一起更新，否则托盘会把刚拉到的数据判成过期、
   *     又白打一发。
   */
  private rememberStoryQueue(items: Array<StoryTrayItem>): void {
    this.storyQueue = items;
    this.storyQueueAtMs = Date.now();
    /*
     * **一份进程只落一次托盘原始条目**（诊断，见 NativeStories.rawNodesDump）：
     * "点开快拍提示没取到（原因 empty）只有部分用户遇到"这类问题，答案就在**托盘条目的原始形状**
     * 里（带不带 user、有没有 items、id 字段叫什么）——而远端用户的日志我们拿不到，
     * 所以让他们把这个文件发回来。一次进程一份，不做磁盘churn。
     */
    if (!this.trayRawDumped) {
      this.trayRawDumped = true;
      /*
       * 两份一起落：**形状摘要**（一行一条，看 `reel_type`/`expiring_at`/`besties`，
       * 判断"这条该不该有快拍"）与**原始条目**（截断到 1200 字符，看 id 字段与结构）。
       */
      const shapes: Array<string> = NativeStories.shapesDump();
      this.dumpProbeFile('trayshape',
        `Instamony 托盘形状 n=${shapes.length}\n` + shapes.join('\n'));
      this.dumpProbeFile('trayraw', NativeStories.rawNodesDump());
    }
  }

  /** 这一轮进程里托盘原始条目落过盘没有（见 rememberStoryQueue）。 */
  private trayRawDumped: boolean = false;

  /**
   * 点开托盘里的一个用户：先取数，成功才进播放页（需求："加载成功跳进新页面"）。
   *
   * 取数失败**不进页**（在首页弹一句就完），因为进来也是一片黑。
   */
  private openStory(item: StoryTrayItem, rect: StoryHeroRect): void {
    if (this.storyLoading) {
      return;
    }
    /*
     * **先弹卡片，后取数据**（需求："初次点击序列头像没有立马展开 stories"）。
     *
     * 以前是"取到 reel 才开浮层"，所以第一次点一位没缓存过的人要等一次网络往返（半秒上下）
     * 才看到任何东西。现在：头像矩形、名字、头像地址托盘里本来就有 → 立刻开浮层播转场，
     * 媒体那一块在数据到之前显示转圈（见 StoryViewer.mediaLayer）；
     * reel 一到，@Watch 把它换上去接着播（见 onReelChanged）。
     */
    this.storyHero = rect;
    this.storyPendingOpen = true;
    let at: number = -1;
    for (let index: number = 0; index < this.storyQueue.length; index++) {
      if (this.storyQueue[index].userId === item.userId) {
        at = index;
        break;
      }
    }
    hilog.info(DOMAIN, TAG, 'story tap uid=%{public}s hero=%{public}s at=%{public}d',
      item.userId, rect.dump(), at);
    // 点开了谁：**没缓存过**才把队列重置到他那一位（已在队列里就别动，否则白扔一次预取）。
    if (!StoryCache.has(item.userId)) {
      StoryCache.reset(this.storyQueue, at >= 0 ? at : 0);
    }
    this.storyQueueIndex = at >= 0 ? at : 0;
    this.storyAvatar = item.avatarUrl;
    this.storyName = item.username;
    this.storyUserId = item.userId;
    this.storyHeroValid = true;
    this.storyReel = EMPTY_REEL;
    // 立刻展开（转场从被点的头像开始）。
    this.storyOpen = true;
    // 队列里没有（托盘还没把顺序交过来）就当成第一位：转场照旧，只是"下一位"得从 0 往后找。
    this.playStoryAt(at >= 0 ? at : 0, item, 1);
  }

  /**
   * 播队列里第 `at` 位用户的快拍。
   *
   * 取不到就**顺着 `step` 往后/往前试**（跳着走），而不是把整个播放卡死在一位身上；
   * 一个方向试到头就收页。
   *
   * @param at 队列下标。
   * @param first 只有"用户点开的那一发"才传（它带被点头像的矩形 / 名字，见 openStory）。
   * @param step 取不到时往哪边继续找：接续下一位 = +1，回上一位 = -1。
   */
  private playStoryAt(at: number, first: StoryTrayItem | null, step: number,
                      retried: boolean = false): void {
    if (at < 0 || at >= this.storyQueue.length) {
      // 那个方向没人了：第一发失败就只弹一句，已经开着浮层就直接收。
      if (this.storyPendingOpen) {
        this.storyPendingOpen = false;
        this.showStoryFail(null, at);
        return;
      }
      this.closeStory();
      return;
    }
    const item: StoryTrayItem = this.storyQueue[at];
    /*
     * 先问**预缓存队列**（core/StoryCache）：命中就**同步**拿到，播放页零等待
     * （"抽出一页"的同时队列会自己补一个，见 StoryCache.take）。
     * 没命中才走网络，回来同样把队列补满。
     */
    const cached: StoryReel | null = StoryCache.take(item.userId);
    if (cached !== null && cached.items.length > 0) {
      this.storyLoading = false;
      this.applyStoryReel(at, item, cached, true);
      return;
    }
    this.storyLoading = true;
    StoryCache.fetch(item.userId, item.altIds).then((reel: StoryReel | null): void => {
      this.storyLoading = false;
      if (reel === null || reel.items.length === 0) {
        hilog.warn(DOMAIN, TAG, 'story load failed uid=%{public}s why=%{public}s → 试 %{public}d',
          item.userId, NativeStories.lastDetail(), step);
        /*
         * **"用户点开的这一发"再试一次**（用户报的"点开显示取不到、页面自己收起"）。
         *
         * 这一发失败的原因里有一大类是**一次性的**：Cookie/claim 正好在这一刻被刷新、
         * 网络抖动、IG 那边一次瞬时限流。原来直接 toast + 收起 —— 用户看到的就是
         * "明明有快拍，点开却说没取到，还自己退回首页"。隔一拍重发一次几乎不花代价
         * （托盘在浮层下面，用户本来就等着），却能把这一整类失败就地消化掉。
         * 只在**用户点开的那一发**重试：接续下一位（first === null）时失败了应该
         * 继续往后找，不能在同一位上耗着。
         */
        if (!retried && first !== null) {
          hilog.info(DOMAIN, TAG, 'story retry uid=%{public}s once', item.userId);
          setTimeout((): void => {
            this.playStoryAt(at, first, step, true);
          }, STORY_RETRY_GAP_MS);
          return;
        }
        if (this.storyPendingOpen) {
          // 卡片已经弹出来了（先弹后取数）：取不到就**带动画收回去**，别留一张空卡片。
          this.storyPendingOpen = false;
          this.showStoryFail(item, at);
          this.requestStoryClose();
          return;
        }
        this.playStoryAt(at + step, null, step);
        return;
      }
      this.applyStoryReel(at, item, reel, false);
    }).catch((error: Error): void => {
      this.storyLoading = false;
      hilog.warn(DOMAIN, TAG, 'story load threw: %{public}s', error.message ?? '-');
      if (!retried && first !== null) {
        setTimeout((): void => {
          this.playStoryAt(at, first, step, true);
        }, STORY_RETRY_GAP_MS);
        return;
      }
      if (this.storyPendingOpen) {
        this.storyPendingOpen = false;
        this.showStoryFail(item, at);
        this.requestStoryClose();
        return;
      }
      this.playStoryAt(at + step, null, step);
    });
  }

  /**
   * **快拍取不到时：把原因摆到用户眼前，并把现场落成文件**。
   *
   * 为什么不能只弹一句"没取到（请看日志）"：真机上 hilog 里我们自己的 INFO 行几秒就被
   * chromium 冲没了（缓冲区太小），**远端用户复现时我们什么也拿不到**；而这条失败恰恰只在他们
   * 那边发生。所以两件事一起做：
   *   ① 消息里带上 `NativeStories.lastDetail()` 那一档原因（`empty` / `http-429` /
   *      `throttled-12min` / `no-session` / `throw:…`）—— 测试同学截一张图就是一条有效线索；
   *   ② 把逐发轨迹（谁的身份、哪条 URL、状态码、长度、响应开头、托盘条目、预缓存状态）
   *      写进沙箱 `probe_storyfail_*.txt`（见 dumpProbeFile），用 hdc 取出来就是完整现场。
   */
  private showStoryFail(item: StoryTrayItem | null, at: number): void {
    const why: string = NativeStories.lastDetail();
    if (item === null) {
      // 队列走到底那一发：连"问的是谁"都没有，记一行就够（原因仍是 detail）。
      hilog.warn(DOMAIN, TAG, 'story fail (queue end) why=%{public}s at=%{public}d', why, at);
      this.toast($r('app.string.story_load_failed', why));
      return;
    }
    const head: Array<string> = [];
    for (let index: number = 0; index < this.storyQueue.length && index < 6; index++) {
      const one: StoryTrayItem = this.storyQueue[index];
      /*
       * 把**备选 id** 也写进去：这是"取错 id 字段"与"快拍真的过期"的判据 ——
       * 备选里有别的数字、而主 id 问出来是空，就说明这条条目取错了字段（报告里一眼可见）。
       */
      const alts: string = one.altIds.length > 0 ? `,[alts ${one.altIds.join('/')}]` : '';
      head.push(`${one.userId}:${one.username}:seen=${one.seen}:n=${one.count}${alts}`);
    }
    const report: string = NativeStories.failureReport(item.userId, item.username,
      this.storyQueue.length, head.join(' | '), at, StoryCache.has(item.userId),
      this.storyQueueAtMs > 0 ? Date.now() - this.storyQueueAtMs : -1);
    hilog.warn(DOMAIN, TAG, 'story fail uid=%{public}s why=%{public}s at=%{public}d',
      item.userId, why, at);
    this.dumpProbeFile('storyfail', report);
    this.toast($r('app.string.story_load_failed', why));
  }

  /**
   * 让播放页**带着动画**收起来（宿主这一侧只能发信号，动画在浮层里，见 StoryViewer.closeSignal）。
   *
   * 返回键、以及"卡片先弹出来但数据取不到"都走它。
   */
  private requestStoryClose(): void {
    if (this.storyClosing) {
      return;
    }
    this.storyClosing = true;
    this.storyCloseSignal = this.storyCloseSignal + 1;
  }

  /**
   * 收起途中点了一下（窗口坐标 vp）：点到谁的头像就换到谁的 story，否则撤销收起。
   *
   * 这是需求"收起 stories 时点击用户头像必须切换到该用户的 story，而不是保持原来的用户"的实现：
   * 托盘的矩形表（`storyRects`）本来就是**窗口坐标**，直接拿点击点去命中即可。
   */
  private onStoryTapPoint(x: number, y: number): void {
    const hit: StoryTrayItem | null = this.storyItemAt(x, y);
    this.storyClosing = false;
    if (hit === null || hit.userId === this.storyUserId) {
      // 没点到别人的头像（或点的就是当前这位）：单纯撤销收起，继续看原来的。
      hilog.info(DOMAIN, TAG, 'story tap point=%{public}d,%{public}d → reopen',
        Math.round(x), Math.round(y));
      this.storyReopenSignal = this.storyReopenSignal + 1;
      return;
    }
    let at: number = -1;
    for (let index: number = 0; index < this.storyQueue.length; index++) {
      if (this.storyQueue[index].userId === hit.userId) {
        at = index;
        break;
      }
    }
    const rect: StoryHeroRect | undefined = this.storyRects.get(hit.userId);
    this.storyHero = rect !== undefined && rect.valid() ? rect : this.storyHero;
    this.storyHeroValid = rect !== undefined && rect.valid();
    this.storyAvatar = hit.avatarUrl;
    this.storyName = hit.username;
    this.storyUserId = hit.userId;
    this.storyReel = EMPTY_REEL;
    if (!StoryCache.has(hit.userId)) {
      StoryCache.reset(this.storyQueue, at >= 0 ? at : 0);
    }
    hilog.info(DOMAIN, TAG, 'story switch by tap uid=%{public}s at=%{public}d',
      hit.userId, at);
    // 先掉头展开（浮层那边还在收起动画里），新数据随后到 → 媒体填上。
    this.storyReopenSignal = this.storyReopenSignal + 1;
    this.playStoryAt(at >= 0 ? at : 0, hit, 1);
  }

  /**
   * 快拍卡片经过时把栏**弹一下**（需求："弹一下" + "需要缩放的弹性动画，轻微就行"）。
   *
   * 三样都动一点点：高度 +4vp、宽 +6vp（轻微"涨"一下）、离底距离 -7vp（被砸下去）。
   * 弹性靠 springMotion：压得脆（阻尼 0.5），回位时过冲再落下（也是 0.5）。
   */
  private swellStoryPocket(): void {
    animateTo({ duration: 130, curve: curves.springMotion(0.35, 0.5) }, (): void => {
      this.storyPocket = 1;
    });
  }

  /** 卡片穿过之后**直接**弹回来（需求："卡片经过 tabbar 后直接恢复，需要弹性动画"）。 */
  private settleStoryPocket(): void {
    if (this.storyPocket === 0) {
      return;
    }
    animateTo({ duration: 320, curve: curves.springMotion(0.45, 0.5) }, (): void => {
      this.storyPocket = 0;
    });
  }

  /** 窗口坐标 (x,y) 落在托盘哪一项的头像上（没有给 null）。 */  private storyItemAt(x: number, y: number): StoryTrayItem | null {
    for (let index: number = 0; index < this.storyQueue.length; index++) {
      const item: StoryTrayItem = this.storyQueue[index];
      const rect: StoryHeroRect | undefined = this.storyRects.get(item.userId);
      if (rect === undefined || !rect.valid()) {
        continue;
      }
      if (x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h) {
        return item;
      }
    }
    return null;
  }

  /**
   * 拿到某一位的 reel 之后统一在这里落状态（缓存命中和网络回来都走它）。
   *
   * @param cached 是不是预缓存命中的（只影响日志：`src=cache|net`，排查卡顿时一眼看出）。
   */
  private applyStoryReel(at: number, item: StoryTrayItem, reel: StoryReel, cached: boolean): void {
    this.storyQueueIndex = at;
    /*
     * 收起时朝哪儿收缩：**看这一位的头像现在还在不在托盘里**（不是"是不是被点开的那一位"）。
     *
     * 在（托盘里量得到它的矩形）→ 页面朝它收缩、播放页头像横移过去落在它上面（需求）；
     * 不在（托盘里没有它 / 那一项已经滚出屏幕）→ 宿主把 heroValid 置假，播放页改成向下滑收。
     * 每次换人都重算一遍，所以顺着右半屏一路看下去，收到哪一位就落在哪一位的头像上。
     */
    const rect: StoryHeroRect | undefined = this.storyRects.get(item.userId);
    if (rect === undefined || !rect.valid()) {
      this.storyHeroValid = false;
    } else {
      this.storyHero = rect;
      this.storyHeroValid = true;
    }
    // 名字 / 头像优先用托盘那份（和托盘上看到的一致），reel 里那份当兜底。
    this.storyAvatar = item.avatarUrl.length > 0 ? item.avatarUrl : reel.avatarUrl;
    this.storyName = item.username.length > 0 ? item.username : reel.username;
    this.storyUserId = item.userId;
    // 最后再换 reel：@Prop 一变，播放页自己回到第一条重播（见 StoryViewer.onReelChanged）。
    this.storyReel = reel;
    // 卡片在 openStory 里就已经弹出来了（先弹后取数），这里只把"点开那一发"的标记清掉。
    this.storyPendingOpen = false;
    hilog.info(DOMAIN, TAG,
      'story play at=%{public}d uid=%{public}s n=%{public}d src=%{public}s heroValid=%{public}s hero=%{public}s',
      at, item.userId, reel.items.length, cached ? 'cache' : 'net',
      `${this.storyHeroValid}`, this.storyHero.dump());
  }

  /**
   * 接**下一位用户**（需求："最后一个照片/视频点击右半屏接续下一个用户的 story"）。
   *
   * 取的还是同一套（取不到就再往后一位，见 playStoryAt）。
   */
  private advanceStory(): void {
    const next: number = this.storyQueueIndex + 1;
    hilog.info(DOMAIN, TAG, 'story next user from=%{public}d next=%{public}d of=%{public}d',
      this.storyQueueIndex, next, this.storyQueue.length);
    this.playStoryAt(next, null, 1);
  }

  /**
   * 回**上一位用户**（需求："story 页不是第一个用户时在第一张照片/视频点击左半屏可以回到
   * 上一个用户 story 第一个照片/视频"）。
   *
   * 进的是上一位的**第一条**：播放页换 reel 时本来就从第一条重播（见 StoryViewer.onReelChanged）。
   */
  private backStory(): void {
    const prev: number = this.storyQueueIndex - 1;
    hilog.info(DOMAIN, TAG, 'story prev user from=%{public}d prev=%{public}d of=%{public}d',
      this.storyQueueIndex, prev, this.storyQueue.length);
    this.playStoryAt(prev, null, -1);
  }

  /** 关掉播放浮层（收起动画播完后浮层自己叫这里；返回键只是发信号，见 onBackPress）。 */
  private closeStory(): void {
    this.storyOpen = false;
    this.storyReel = null;
    this.storyPendingOpen = false;
    this.storyHeroValid = false;
    this.storyClosing = false;
  }

  /**
   * 搜索标签：搜索框（**页面里的浮层**，见 SearchPage）+ 账号结果 / 推荐瀑布流。
   *
   * 搜索框**不再住在标题栏里**了（需求："模糊只盖到 HDS 标题行，不要盖搜索框那一行"）：
   * 它和「我的」页钉住后的分段按钮当初都挂在标题栏的 `bottomBuilder` 上，那一行会被算进标题栏，
   * 毛玻璃蒙层于是从 94vp 长到 146/154vp —— 用户看到的就是"背景模糊太高了"。
   * 现在两者都改成本页的浮层，标题栏回到 MINI 高度（全 app 一致）。
   */
  @Builder
  searchPage() {
    SearchPage({
      vm: this.searchVm,
      onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
        this.onFeedScroll(deltaY, offsetY, scrollState);
      },
      onOpen: (user: SearchUser): void => {
        // 搜到的账号 → **原生用户主页**（需求："把搜索到的用户接入用户显示页面"）：
        // 和信息流资料行点进去是同一页（UserProfileRoute），id 来自搜索响应里的 `pk`
        // （见 model/Search 的 SearchUser.userId）；万一没给 id，那一页会按用户名取网格。
        this.openUserProfile(user.username, user.userId);
      },
      onOpenPost: (post: SearchPost): void => {
        // 兜底（没接 onOpenReels 时才会走到）：交给网页打开那条帖子
        // （视频是 /reel/，和首页那套同一判据）。
        this.openWeb(`https://www.instagram.com/${post.isVideo ? 'reel' : 'p'}/${post.code}/`);
      },
      // 推荐流点一条 → **Reels 页**（需求：带返回、底部评论、点的那条排第一、上滑按 reels 翻）。
      onOpenReels: (posts: Array<SearchPost>, index: number): void => {
        this.openSearchReels(posts, index);
      }
    })
  }

  /** 打开设定页（NavDestination，见 destinationBuilder）。 */
  private openSettings(): void {
    this.navStack.pushPath({ name: SETTINGS_PAGE });
  }

  /**
   * 非 Home 标签的原生页面占位。
   *
   * Reels / 私信 / 搜索 这几个标签还没有原生实现，先给一个明确的占位说明，
   * 而不是一片空白让人以为坏了。以后逐个换成真正的原生页面即可。
   *
   * **不接 index 参数，直接读 `this.selectedIndex`**：@Builder 的**按值参数**不参与
   * 状态观察 —— 传 `placeholderPage(this.selectedIndex)` 时，1→2 这种"同一个分支内换值"
   * 不会让这个 Builder 重跑，页面就停在旧的那一项上（标题栏却会变，因为它是另一处直接读
   * selectedIndex 的），表现正是"点了私信/搜索，标题变了、内容还是 Reels"。
   * 在 Builder **内部**读状态，这一节点才会跟着状态重建。
   */
  @Builder
  placeholderPage() {
    Column({ space: 10 }) {
      SymbolGlyph(TAB_ITEMS[this.selectedIndex].iconNormal)
        .fontSize(48)
        .fontColor([$r('app.color.secondary_text')])
      Text(TAB_ITEMS[this.selectedIndex].label)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Text($r('app.string.tab_placeholder_hint'))
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }

  /**
   * 原生壳：标题栏改用 HDS 的 HdsNavigation（HarmonyOS Design System 的导航容器）。
   *
   * 标题与右上角动作都由 titleBar 配置，字号、点击热区、配色跟随系统设计规范；
   * 原来自绘的 NativeTopBar 已归档到 legacy/unwired（未接线）。
   * titleMode 取 MINI（固定 56vp）：FREE 模式下大标题会随滚动变大缩小，
   * 那需要额外绑定滚动容器，这里不引入这个变数。
   */
  @Builder
  nativeShell() {
    // 传入页面栈：通知页是它的一个 NavDestination（见 destinationBuilder）。
    HdsNavigation(this.navStack) {
      this.nativeShellContent()
    }
    // 示例里 HdsNavigation 是 build() 的根，所以不写尺寸；这里是 Stack 的子节点，
    // 必须显式撑满，否则会缩到内容大小。
    .width('100%')
    .height('100%')
    .mode(NavigationMode.Stack)
    .titleBar({
      content: {
        // 标题跟当前分页走（首页=应用名，其余页=页面标题），菜单也按分页给（见 menus）。
        title: { mainTitle: this.pageTitle() },
        menu: this.menus()
        // **没有 bottomBuilder**（需求："模糊只盖到 HDS 标题行"）：搜索框和「我的」页那条
        // 分段按钮都改成了各自页面里的浮层（见 SearchPage / ProfilePage）。挂 bottomBuilder
        // 会把那一行算进标题栏，标题栏的毛玻璃蒙层跟着从 94vp 长到 146/154vp。
      },
      style: this.pageTitleStyle(),
      // 和官方示例保持一致：两个都 false。
      // 这两个开关管的是 HDS 要不要替标题栏/内容避让系统安全区；示例一路 false，
      // 前提就是「忽略安全区之后由自己负责留白」—— 我们的留白给了列表的内容起始偏移
      // （见 FeedList 的 FEED_START_OFFSET），所以这里保持和示例一致。
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    // 把内容的滚动容器交给标题栏，滚动效果才有的放矢（当前效果本身是关的）。
    .bindToScrollable([this.feedScroller])
    // 这是应用根页面，没有上一级可回，所以不显示返回键（示例里是 false）。
    .hideBackButton(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    // **不给标题栏绑 hideTitleBar**：需求"不需要隐藏 hdsnavigation"——下沉时收走标题栏那版已撤掉，
    // 现在跟着底栏下沉的是 reels 页的动作区 / 资讯区（见 OVERLAY_SINK_DISTANCE 与 reelsTab）。
    // 让标题栏铺到系统栏下方，沉浸光感才有连续的底；内容下边距由各栏自己留。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .zIndex(10)
    // 通知等整屏页面作为 NavDestination 压在这一层之上（见 destinationBuilder）。
    .navDestination(this.destinationBuilder)
  }

  /**
   * 现在屏幕上是不是**reels 类页面**（需求："浅色模式下进入 reels 类页面统一变为深色模式，
   * 退出 reels 类页面时恢复"）。
   *
   * 有两类：
   *   1. 底栏「视频」标签那一页（首页里的 reels 流）；
   *   2. **独立整屏的 Reels 页**：从「我的」/别人主页视频分页点进去的（PROFILE_REELS_PAGE）、
   *      从搜索页推荐流点进去的（SEARCH_REELS_PAGE）—— 后两个是后加的，判据当时只看底栏标签，
   *      所以在浅色模式下从这两个页面进去时，HDS 标题栏还是浅色的（用户报的正是这个）。
   */
  private reelsLikeOnScreen(): boolean {
    return this.currentTab() === AppTab.Reels
      || this.topPage === PROFILE_REELS_PAGE
      || this.topPage === SEARCH_REELS_PAGE;
  }

  /**
   * Reels 页的明暗：**进去把应用切成深色，离开交回系统**（需求）。
   *
   * 为什么要整页切深色、而不是只把顶部/底部那两条栏涂黑：Reels 整屏都是视频，浅色主题下
   * 系统栏材质是白的（压在画面上又脏又读不清），而"只涂黑两条栏"既要跟材质打架（材质优先于
   * 背景色），我们自己画的图标/文字也还是浅色主题那一套。切应用配色一次解决全部：
   * HDS 材质、标题栏、底栏、我们自己的图标文字会一起走深色。
   *
   * 只在"当前是浅色"时切；`reelsDarkForced` 记账是为了**只在需要时**动配置 ——
   * 离开 Reels 时设置的是 `COLOR_MODE_NOT_SET`（跟系统），不是硬写浅色，所以系统本来就是
   * 深色的用户离开 Reels 依旧深色。
   */
  private syncReelsColorMode(): void {
    const onReels: boolean = this.reelsLikeOnScreen();
    // 判据本身也记一行（debug 级）：浅色模式下"进/出 Reels 类页面"有没有走到这里，
    // 看日志就清楚（真机浅色不好造，只能靠这一行 + AppSettings 那行一起判断）。
    hilog.debug(DOMAIN, TAG, 'reels color: reels=%{public}s dark=%{public}s forced=%{public}s',
      `${onReels}`, `${this.isDarkUi}`, `${this.reelsDarkForced}`);
    if (onReels) {
      if (!this.isDarkUi && !this.reelsDarkForced) {
        this.reelsDarkForced = true;
        this.applyAppColorMode(true);
      }
      return;
    }
    if (this.reelsDarkForced) {
      this.reelsDarkForced = false;
      this.applyAppColorMode(false);
    }
  }

  /** 真正下发配色（拿不到 host context 就放弃，下一次切页会再试）。 */
  private applyAppColorMode(dark: boolean): void {
    const host: common.Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    AppSettings.forceDarkMode(host, dark);
  }

  onBackPress(): boolean {
    // 快拍浮层最先收（它是最上面那一层，见 build 末尾的 zIndex 80）。
    if (this.storyOpen) {
      /*
       * **发信号让它自己收**，不在这里直接删浮层：返回键要和下滑手势、播完自动收走
       * 走同一套动画（朝当前这一位的托盘头像收缩 / 不在托盘里就整页下滑，见
       * StoryViewer.requestClose）。动画播完浮层会叫 onClose → closeStory()。
       *
       * 连按两下：第二下什么都不做（`storyClosing` 已经立起来了），不然会叠一次动画；
       * 中途被打断展开时浮层会回调 onReopen，把这一位清掉（见那里的说明）。
       */
      this.requestStoryClose();
      return true;
    }
    if (this.commentsVisible) {
      this.closeComments();
      return true;
    }
    if (this.probeVisible) {
      this.probeVisible = false;
      return true;
    }
    /*
     * **搜索有结果时，返回键先回"推荐流"，不退出 App**（需求）。
     *
     * 搜索页是 tab 内的一个状态（关键词非空 = 结果列表，空 = 推荐瀑布流），不是压栈的页面，
     * 所以系统返回手势原来会直接冒到"退出 App"那条路上。这里把它接住：清掉关键词、回到
     * 推荐态（`clear()` 不重新拉网络，缓存还在，切回去是即时的）。
     */
    if (this.currentTab() === AppTab.Search && this.searchVm.queryNow().length > 0) {
      this.searchVm.clear();
      return true;
    }
    if (!this.webVisible) {
      return false;
    }
    if (this.bridge.canGoBack()) {
      this.bridge.goBack();
      return true;
    }
    this.closeWeb();
    return true;
  }

  /**
   * 通知页（NavDestination 的内容）。
   *
   * 标题栏、返回键、沉浸光感材质都由 HdsNavDestination 负责 —— 返回键走它自己的
   * 路由栈 pop，不需要页面再兜一层 onBackPress（这正是换掉模态的收益之一）。
   */
  @Builder
  destinationBuilder(name: string, param: object) {
    if (name === NOTIFICATIONS_PAGE) {
      HdsNavDestination() {
        NotificationsPanel({
          items: this.notifications,
          loading: this.notificationsLoading,
          state: this.notificationsState,
          diag: this.notificationsDiag,
          // 下拉刷新：动画状态双向绑定，用户下拉时回调这里重新取数。
          refreshing: $notificationsRefreshing,
          onRefresh: (): void => {
            this.refreshNotifications();
          },
          onFollow: (item: NotifyItem): void => {
            this.toggleFollow(item);
          }
        })
      }
      .titleBar({
        content: {
          title: { mainTitle: $r('app.string.notifications') }
        },
        // 标题栏样式统一由 style 助手生成：材质那段只在设备支持 HDS 系统材质时才有
        // （API < 23 传下去就是 undefined，见 core/PlatformCap）。
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      // 有上一级（首页），所以显示返回键；点击由 NavDestination 自己 pop 路由栈。
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 标题栏铺到系统栏下方，沉浸光感才有连续的底。
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      // **别裁内容**：页面里的列表要能把行画到标题栏底下（和主页同一套"内容穿过标题栏"）；
      // NavDestination 默认会裁掉超出内容区的部分，不放开的话列表行滚到标题栏下沿就没了。
      .clip(false)
      // 整屏页面压上来/被关掉：首页信息流据此停播（见 onPageShown / FeedList.active）。
      .onShown((): void => {
        this.onPageShown(NOTIFICATIONS_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(NOTIFICATIONS_PAGE);
      })
      // 返回键：**评论浮层开着就先收评论**（需求："返回优先收起面板"），不再 pop 页面。
      .onBackPressed((): boolean => this.handleDestinationBack())
    } else if (name === SETTINGS_PAGE) {
      // 设定页：和通知页同一套承载（标题栏 + 返回键 + 沉浸光感），内容见 SettingsPanel。
      HdsNavDestination() {
        SettingsPanel({
          onSignOut: (): void => {
            this.signOut();
          }
        })
      }
      .titleBar({
        content: {
          title: { mainTitle: $r('app.string.action_settings') }
        },
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      // 同通知页：放开裁剪，页面内容才能画到标题栏底下。
      .clip(false)
      // 整屏页面压上来/被关掉：首页信息流据此停播（见 onPageShown / FeedList.active）。
      .onShown((): void => {
        this.onPageShown(SETTINGS_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(SETTINGS_PAGE);
      })
      // 返回键：**评论浮层开着就先收评论**（需求："返回优先收起面板"），不再 pop 页面。
      .onBackPressed((): boolean => this.handleDestinationBack())
    } else if (name === USER_PROFILE_PAGE) {
      /*
       * **用户主页**（从信息流的资料行点进来）。
       *
       * 内容和「我的」页**同一套模板**（ProfilePage + ProfileViewModel），差别只有三处：
       *   1. 目标是别人（`setTarget` 把请求体里"目标用户"那几个键换成他的 id / 用户名）；
       *   2. 没有"收藏"那一段（`setOrder([帖子, 视频, 被提及])`，需求）；
       *   3. 这里自己 new 一个视图模型（一个人的主页一份数据，不和「我的」页共用）。
       *
       * 标题栏：左上角返回键（HdsNavDestination 自带，点击 pop 路由栈）、标题 = 用户 id（用户名）、
       * 右上角「更多」按钮 —— 需求里那颗暂时不做功能，所以 action 是空的。
       */
      HdsNavDestination() {
        UserProfileRoute({
          param: `${param}`,
          onOpen: (post: ProfilePost): void => {
            // 点格子打开帖子页（和「我的」页同一条路：交给隐藏网页）。
            this.openWeb(`https://www.instagram.com/${post.isVideo ? 'reel' : 'p'}/${post.shortcode}/`);
          },
          // **这条不能漏**：别人主页的格子也要能进帖子页（用户报的"feeds 流进入用户主页后
          // 点击帖子无法进入帖子页面"就是这里没接 —— 组件里的默认实现是空函数，点了什么都不发生）。
          // `false` = 不是从**我自己的**主页进来的：别人的主页里，标题栏那颗关注照旧要有。
          onOpenStream: (posts: Array<MediaPost>, index: number,
                         loadMore: () => Promise<ProfileStreamPage>): void => {
            this.openPostStream(posts, index, loadMore, false);
          },
          // 别人主页**视频那一段**的格子 → Reels 页（同 onOpenStream，这条也不能漏）。
          onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                        loadMore: () => Promise<ProfileStreamPage>): void => {
            this.openProfileReels(posts, shortcode, hasMore, loadMore);
          },
          // 别人主页那一行的「关注 / 已关注」（需求：显示状态 + 支持关注、取关）。
          onFollowUser: (id: string, username: string, follow: boolean): Promise<boolean> => {
            return this.followUser(id, username, follow);
          },
          onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
            this.onFeedScroll(deltaY, offsetY, scrollState);
          }
        })
      }
      .titleBar({
        content: {
          title: { mainTitle: Index.userNameOf(`${param}`) },
          menu: {
            value: [
              {
                content: {
                  icon: $r('sys.symbol.more'),
                  label: $r('app.string.action_more'),
                  action: (): void => {
                    // 需求：这颗按钮暂时不做功能（先占位，避免菜单里少一项）。
                  }
                }
              }
            ]
          }
        },
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .clip(false)
      // 压上来/被关掉：首页信息流据此停播（见 onPageShown / FeedList.active）。
      .onShown((): void => {
        this.onPageShown(USER_PROFILE_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(USER_PROFILE_PAGE);
      })
      // 返回键：**评论浮层开着就先收评论**（需求："返回优先收起面板"），不再 pop 页面。
      .onBackPressed((): boolean => this.handleDestinationBack())
    } else if (name === POST_PAGE) {
      /*
       * **帖子页**（点网格里的某个格子进来，需求）。
       *
       * 结构参考信息流主页：内容就是**同一个 FeedList**（同一套卡片、内联视频播放、点赞/评论/
       * 转发都在），只是数据换成"当前分页的全部帖子"，并且一进来就**定位到点进去的那一条**
       * （FeedList 的 initialKey，见它的 restoreAnchor）。
       *
       * 标题栏：
       *   - 返回键用 **HDS 原生的那颗**（左上角，点击 pop 路由栈）——需求："返回按钮用
       *     hdsnavigation 原生的显示在左边"；
       *   - 右上角：**作者还没关注时**出现一颗「关注」（需求："只有未关注的用户才在
       *     hdsnavigation 右上角显示关注按钮"）；已关注就不显示任何东西。
       */
      HdsNavDestination() {
        this.postPageBody()
      }
      .titleBar({
        content: {
          title: { mainTitle: $r('app.string.post_page_title') },
          menu: this.postPageMenu()
        },
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .clip(false)
      // 帖子页自己也要知道"我是不是在最前面"：它被用户主页压住时同样要停播
      // （见 onPageShown / postPageBody 的 FeedList.active）。
      .onShown((): void => {
        this.onPageShown(POST_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(POST_PAGE);
      })
      // 返回键：**评论浮层开着就先收评论**（需求："返回优先收起面板"），不再 pop 页面。
      .onBackPressed((): boolean => this.handleDestinationBack())
    } else if (name === PROFILE_REELS_PAGE) {
      /*
       * **视频分页的 Reels 页**（点「我的」/别人主页视频那一段的格子进来，需求）。
       *
       * 需求原文："用户和我的页面的视频分页点进去是新的页面，采用 reels 模板，使用 hdsnavigation，
       * 左上角返回按钮，title「Reels」，底部是一个沉静光感输入框，用于添加评论。"
       * 所以：
       *   - 内容 = 首页那个 **ReelsPage**（竖向翻页、只播当前那条），数据换成这一分页的视频
       *     （见 ProfileReelsViewModel）；
       *   - 承载 = **HdsNavDestination**（原生返回键在左上角、标题在 titleBar 里）；
       *   - 底部 = **CommentInputBar**（沉浸光感的评论输入框，压在视频上）。
       */
      HdsNavDestination() {
        this.reelsBody(this.profileReelsVm, ReelsAction.PROFILE)
      }
      .titleBar({
        content: {
          title: { mainTitle: $r('app.string.reels_page_title') },
          // 需求："除了底栏 reels，其他 reels 页面右上角没有静音和下载按钮，添加一下"。
          menu: this.reelsMenu(ReelsAction.PROFILE)
        },
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      // 左上角那颗**原生**返回键（点击 pop 路由栈）—— 需求明确要它。
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      // 视频要铺到标题栏底下（沉浸式），所以不裁内容。
      .clip(false)
      // 压上来/被关掉：首页信息流据此停播（和其它整屏页面同一条路，见 onPageShown）。
      .onShown((): void => {
        this.onPageShown(PROFILE_REELS_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(PROFILE_REELS_PAGE);
      })
      // 返回键：**评论浮层开着就先收评论**（需求："返回优先收起面板"），不再 pop 页面。
      .onBackPressed((): boolean => this.handleDestinationBack())
    } else if (name === SEARCH_REELS_PAGE) {
      /*
       * **搜索页推荐流的 Reels 页**（需求："把搜索页推荐流实现点击帖子进入带返回的 reels 页面，
       * 底部是评论，点击的帖子显示在第一条，上滑按照浏览 reels 的逻辑运行"）。
       *
       * 和视频分页那一页**同一个界面**（见 reelsBody）：HdsNavDestination 的原生返回键 +
       * 标题「Reels」、内容 ReelsPage、底部 CommentInputBar 评论输入框。
       * 差别只有数据来源与顺序（点的那条排第一，见 openSearchReels）。
       */
      HdsNavDestination() {
        this.reelsBody(this.searchReelsVm, ReelsAction.SEARCH)
      }
      .titleBar({
        content: {
          title: { mainTitle: $r('app.string.reels_page_title') },
          // 同视频分页那一页：右上角补上静音 / 下载（需求）。
          menu: this.reelsMenu(ReelsAction.SEARCH)
        },
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .clip(false)
      .onShown((): void => {
        this.onPageShown(SEARCH_REELS_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(SEARCH_REELS_PAGE);
      })
      // 返回键：**评论浮层开着就先收评论**（需求："返回优先收起面板"），不再 pop 页面。
      .onBackPressed((): boolean => this.handleDestinationBack())
    } else if (name === DIRECT_THREAD_PAGE) {
      /*
       * **私信会话页**（点收件箱里的一行进来）。
       *
       * 承载和其它整屏页面同一套：HdsNavDestination 给原生返回键 + 标题；内容 DirectThreadPage
       * （消息列表 + 底部发送条）。数据与发送都走原生 HTTP（core/NativeDirect），不再需要把
       * 隐藏网页导航到 /direct/t/{id}/。
       *
       * 标题用**对方的名字**（读消息之前先用收件箱那一行的标题，读到了再用真名覆盖）——
       * 和 IG 一致：会话页标题就是对方，不是"私信"。
       */
      HdsNavDestination() {
        DirectThreadPage({
          vm: this.directThreadVm,
          onOpenWeb: (): void => {
            // 兜底出口：关掉原生会话页、把隐藏网页导航到这条会话（老行为）。
            const url: string = this.directThreadVm.webUrl();
            hilog.info(DOMAIN, TAG, 'direct thread → web fallback %{public}s', url);
            if (this.navStack.size() > 0) {
              this.navStack.pop();
            }
            this.openWeb(url);
          },
          onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
            this.onFeedScroll(deltaY, offsetY, scrollState);
          },
          onOpenUser: (username: string, userId: string): void => {
            this.openUserProfile(username, userId);
          }
        })
      }
      .titleBar({
        content: {
          /*
           * 需求：返回键右边是头像、再右边是"名字 + id"上下排列（群聊只显示群名）。
           *
           * **HDS 的 `title` 只接受 `HdsNavigationTitle` 对象（mainTitle / subTitle），不接受
           * 自定义 builder**（传 builder 会报 `Type 'void' is not assignable to 'HdsNavigationTitle'`）。
           * 所以这里用它的两行式：mainTitle 大字（HDS 自己给粗体）+ subTitle 灰色小字；
           * **头像因此放不进标题栏**，改放在右上角菜单那一排的第一个（见 directThreadMenus）。
           */
          title: {
            mainTitle: this.directThreadVm.titleNow().length > 0
              ? this.directThreadVm.titleNow() : $r('app.string.direct_empty'),
            subTitle: this.directThreadVm.subtitleNow()
          },
          menu: this.directThreadMenus()
        },
        style: this.destinationTitleStyle(),
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .hideBackButton(false)
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .clip(false)
      .onShown((): void => {
        this.onPageShown(DIRECT_THREAD_PAGE);
      })
      .onHidden((): void => {
        this.onPageHidden(DIRECT_THREAD_PAGE);
      })
      .onBackPressed((): boolean => this.handleDestinationBack())
    }
  }

  /**
   * Reels 页的正文：**视频**铺满整屏 + 底部一层评论输入框。
   *
   * 视频分页那一页（PROFILE_REELS_PAGE）和搜索推荐流那一页（SEARCH_REELS_PAGE）**共用**这里
   * —— 需求要的就是"同一个 reels 模板"，差别只在数据来源（见各自的 open* 方法）。
   *
   * 为什么用 Stack：输入框要**压在视频上**（IG 的 Reels 就是这样，不是把视频顶上去）——
   * 它是浮层，所以放 Stack 的上面一层并给 zIndex（同「我的」页那层钉住的分段按钮）。
   */
  @Builder
  reelsBody(vm: ProfileReelsViewModel, source: string) {
    Stack({ alignContent: Alignment.Bottom }) {
      ReelsPage({
        vm: vm,
        // 标题栏那两颗按钮（静音 / 下载）按**来源**取用（见 core/ReelsAction）：
        // 三个 reels 类页面各存一份，免得下载下到另一条视频。
        source: source,
        // 我自己的账号名：作者是我时不画关注按钮（"我的"页视频分页那一页就是这样）。
        ownAuthor: this.profileVm.ownAccountName(),
        // 这一页没有浮动底栏，所以"手指一动就沉栏"这件事这里什么都不用做；回调留着是为了
        // 和首页同一个形状（以后要接进来时不必改组件）。
        onReelSwipe: (): void => {
        },
        // 右侧动作栏与作者行：点赞 / 转发走 HTTP，关注走 followUser，
        // 评论开已有的评论面板，转发给好友与更多这一版只提示一句。
        onLike: (reel: Reel, like: boolean): Promise<boolean> => {
          return this.likeReel(reel, like);
        },
        onRepost: (reel: Reel, repost: boolean): Promise<boolean> => {
          return this.repostReel(reel, repost);
        },
        // 收藏（书签）：和底栏那页同一条路（见 saveReel）。
        onSave: (reel: Reel, save: boolean): Promise<boolean> => {
          return this.saveReel(reel, save);
        },
        onFollow: (reel: Reel, follow: boolean): Promise<boolean> => {
          return this.followReelAuthor(reel, follow);
        },
        onOpenUser: (reel: Reel): void => {
          this.openReelAuthor(reel);
        },
        onComments: (reel: Reel): void => {
          this.openReelComments(reel);
        },
        onShare: (reel: Reel): void => {
          this.toast($r('app.string.feature_pending'));
        },
        onMore: (reel: Reel): void => {
          this.toast($r('app.string.feature_pending'));
        },
        // 正文翻译失败：弹一句（页面自己退回原文态）。
        onTranslateFailed: (): void => {
          this.toast($r('app.string.translate_failed'));
        }
      })
      // 底部评论输入框（沉浸光感，见 CommentInputBar）。
      //
      // 这一版**不真的发评论**（用户确认："先只做输入框 UI，不真发"）：输入框把内容交上来之后
      // 只提示一句，不假装发布成功。
      // 提示走**系统 toast**（不是 setLocalStatus）：那条横幅画在主页外壳里，而这一页是整屏
      // NavDestination，横幅根本露不出来 —— 用户会以为"点了没反应"（同 toast 的说明）。
      CommentInputBar({
        onSend: (text: string): void => {
          this.toast($r('app.string.comment_pending'));
          hilog.info(DOMAIN, TAG, 'reels draft comment len=%{public}d (not sent)', text.length);
        }
      })
        .zIndex(2)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  /**
   * 帖子页右上角那颗**关注**（只在"作者还没关注、不是我自己、而且这一页不是从我主页进来的"时出现）。
   *
   * 为什么放在标题栏：需求要求"不用在每项帖子顶栏显示关注按钮"（见 FeedList.showFollowInRow）
   * —— 那一页整段都是同一个人的帖子，挂一颗在标题栏就够了，而且一直看得见（不随滚动跑掉）。
   *
   * **从我自己的主页进来的帖子页一律不给这一颗**（需求："我的页面进入帖子显示页面，右上角
   * hdsnavigation 不需要关注按钮"，之后又补了"收藏和被标注的帖子页面右上角的关注也移除"）：
   * 那几段（帖子 / 收藏 / 被标注）是我自己主页里的内容 —— 帖子那段作者就是我（关注自己没意义），
   * 收藏 / 被标注那段虽然作者是别人，但那是"我收藏的 / 我被标注的"列表，用户在那儿看到一颗
   * 关注按钮既突兀又容易误点。判据由宿主在打开时给（见 openPostStream 的 fromOwnProfile）。
   *
   * 另外再兜一道 `postPageIsMine()`：在**别人**的主页里翻到一条我自己发的帖子时也不给关注。
   *
   * 状态怎么来：打开这一份数据时按第一条的作者算一次（见 openPostStream 的 postPageFollowed），
   * 点过之后自己更新；作者的来源见 core/FollowState（本地点过的以本地为准）。
   */
  private postPageMenu(): HdsNavigationMenuContentOptions {
    if (this.postPageFollowed || this.postPageAuthor.length === 0
      || this.postPageFromOwnProfile || this.postPageIsMine()) {
      return { value: [] };
    }
    return {
      value: [
        {
          content: {
            label: $r('app.string.action_follow'),
            type: TextStyleMode.NORMAL,
            action: (): void => {
              this.followPostPageAuthor();
            }
          }
        }
      ]
    };
  }

  /** 帖子页这一份是不是**我自己**发的（标题栏据此不显示关注按钮，见 postPageMenu）。 */
  private postPageIsMine(): boolean {
    const own: string = this.profileVm.ownAccountName();    if (own.length > 0 && this.postPageAuthor.length > 0
      && own.toLowerCase() === this.postPageAuthor.toLowerCase()) {
      return true;
    }
    const ownId: string = this.profileVm.ownIdSync();
    return ownId.length > 0 && this.postPageAuthorId.length > 0 && ownId === this.postPageAuthorId;
  }

  /** 关注帖子页那位作者（成功后把标题栏那颗按钮收掉）。 */
  private async followPostPageAuthor(): Promise<void> {
    const post: MediaPost | null = this.postPageFirst();
    if (post === null) {
      return;
    }
    const ok: boolean = await this.followAuthor(post, true);
    if (ok) {
      this.postPageFollowed = true;
    }
  }

  /** 帖子页这一份数据里的第一条（关注按钮靠它拿到作者 id 与用户名）。 */
  private postPageFirst(): MediaPost | null {
    return this.postPagePosts.length > 0 ? this.postPagePosts[0] : null;
  }

  /**
   * 打开**搜索页推荐流的 Reels 页**（需求）。
   *
   * 四条要求对应四处实现：
   *   1. "带返回" —— HdsNavDestination 的原生返回键 + 标题 Reels（和视频分页那一页同一套）；
   *   2. "点击的帖子显示在第一条" —— 列表按点的顺序**重排**（点的那条挪到最前，其余保持原序），
   *      ReelsPage 的初始页就是第 0 条；
   *   3. "上滑按照浏览 reels 的逻辑运行" —— 还是那个 ReelsPage（竖向翻页、只播当前那条、
   *      下一条预加载），滑到末尾继续吃**搜索推荐**那条游标链（见 makeSearchReelsLoader）；
   *   4. "底部是评论" + "沉浸光感" —— CommentInputBar（Toggle 承载材质的输入框），
   *      和视频分页那一页完全同一个组件。
   */
  private openSearchReels(posts: Array<SearchPost>, index: number): void {
    if (index < 0 || index >= posts.length || posts.length === 0) {
      return;
    }
    const anchor: string = posts[index].code;
    // 进一次 = 一副新牌（需求要的就是"下一条随机"）；同一次浏览里滑到末尾再要一页**不重洗**
    // （那会让当前正看着的那条当场跳掉，见 orderSearchReels）。
    this.searchReelsOrder = [];
    const ordered: Array<SearchPost> = this.orderSearchReels(posts, anchor);
    const list: Array<MediaPost> = Index.searchPostsToMedia(ordered);
    if (list.length === 0) {
      hilog.info(DOMAIN, TAG, 'search reels skip: no playable item in %{public}d post(s)',
        posts.length);
      return;
    }
    this.searchReelsAnchor = anchor;
    this.searchReelsVm = new ProfileReelsViewModel(list, anchor, true,
      (): Promise<ProfileStreamPage> => this.loadSearchReelsMore());
    hilog.info(DOMAIN, TAG, 'search reels open n=%{public}d anchor=%{public}s',
      list.length, anchor);
    // 已经在同一页上：只换数据，不再压一层（返回一次不该还停在原地）。
    const names: Array<string> = this.navStack.getAllPathName();
    if (names.length > 0 && names[names.length - 1] === SEARCH_REELS_PAGE) {
      return;
    }
    this.navStack.pushPath({ name: SEARCH_REELS_PAGE });
  }

  /**
   * 把推荐流排成 Reels 页要的顺序：**点的那条在第一**，其余**随机**。
   *
   * 需求："点进视频后上滑下一条视频是推荐流的第一条视频，我想要做成随机的" ——
   * 原来的顺序是"锚点 + 推荐流原序"（点的那条排第一，后面照瀑布流排），所以上滑看到的就是
   * 瀑布流里第一条；现在把剩下的**洗一遍**。
   *
   * 为什么要"洗一次就定住"（顺序记在 searchReelsOrder 里）而不是每次调用重洗：
   * 滑到末尾会再要一页，而拿回来的是**整份**列表（整体替换语义，见 ProfileReelsViewModel）——
   * 每洗一次都会让"第 N 条"换成另一条视频，用户正看着的那条会当场跳掉。
   * 所以：**已经在顺序里的位置原样保留**，只有这次新出现的（下一页那些）追加到末尾，
   * 追加之前同样洗一遍（新来的也不按推荐流原序排）。
   */
  private orderSearchReels(posts: Array<SearchPost>, anchor: string): Array<SearchPost> {
    const byCode: Map<string, SearchPost> = new Map<string, SearchPost>();
    for (let index: number = 0; index < posts.length; index++) {
      const post: SearchPost = posts[index];
      if (post.code.length > 0 && !byCode.has(post.code)) {
        byCode.set(post.code, post);
      }
    }
    const order: Array<string> = [];
    if (anchor.length > 0 && byCode.has(anchor)) {
      order.push(anchor);
    }
    for (let index: number = 0; index < this.searchReelsOrder.length; index++) {
      const code: string = this.searchReelsOrder[index];
      if (code !== anchor && byCode.has(code) && order.indexOf(code) < 0) {
        order.push(code);
      }
    }
    // 这次新出现的：洗一遍再追加（下一页面不该按它自己的顺序接在后面）。
    const fresh: Array<string> = [];
    for (let index: number = 0; index < posts.length; index++) {
      const code: string = posts[index].code;
      if (code.length > 0 && order.indexOf(code) < 0 && fresh.indexOf(code) < 0) {
        fresh.push(code);
      }
    }
    Index.shuffle(fresh);
    for (let index: number = 0; index < fresh.length; index++) {
      order.push(fresh[index]);
    }
    this.searchReelsOrder = order;
    const out: Array<SearchPost> = [];
    for (let index: number = 0; index < order.length; index++) {
      const post: SearchPost | undefined = byCode.get(order[index]);
      if (post !== undefined) {
        out.push(post);
      }
    }
    // 诊断一行：推荐流原本的第一条 vs 洗过之后"上滑的下一条" —— 随机有没有生效看这两个。
    hilog.info(DOMAIN, TAG, 'search reels order n=%{public}d anchor=%{public}s streamFirst=%{public}s next=%{public}s',
      out.length, anchor, posts.length > 0 ? posts[0].code : '-',
      out.length > 1 ? out[1].code : '-');
    return out;
  }

  /** 原地洗牌（Fisher–Yates）：给"下一条随机"用，见 orderSearchReels。 */
  private static shuffle(codes: Array<string>): void {
    for (let index: number = codes.length - 1; index > 0; index--) {
      const swap: number = Math.floor(Math.random() * (index + 1));
      const tmp: string = codes[index];
      codes[index] = codes[swap];
      codes[swap] = tmp;
    }
  }

  /**
   * 推荐流的一条 → Reels 页要的 `MediaPost`。
   *
   * **计数、正文、作者 id 都要带上**：Reels 页作者行（正文 / 关注按钮）和右侧动作栏
   * （点赞 / 评论 / 转发三个计数）读的就是它们。以前这里只给了封面和视频地址，于是
   * 搜索推荐流点进去那页"没有显示点赞评论转发数量"，关注按钮也因为没有作者 id 走不通
   * （用户报的两个问题；字段由 core/NativeSearch.readPost 采出来）。
   */
  private static searchPostsToMedia(posts: Array<SearchPost>): Array<MediaPost> {
    const out: Array<MediaPost> = [];
    for (let index: number = 0; index < posts.length; index++) {
      const post: SearchPost = posts[index];
      if (post.code.length === 0) {
        continue;
      }
      out.push(new MediaPost({
        id: post.mediaId.length > 0 ? post.mediaId : `search-${post.code}`,
        shortcode: post.code,
        caption: post.caption,
        mediaType: post.isVideo ? 'video' : 'image',
        displayUrl: post.coverUrl,
        likeCount: post.likeCount,
        commentCount: post.commentCount,
        takenAtMs: 0,
        ownerUsername: post.ownerUsername,
        ownerAvatarUrl: post.ownerAvatarUrl,
        ownerId: post.ownerId,
        liked: post.liked,
        // 关注状态：推荐流那条载荷给了就带上，Reels 页那颗按钮照它画
        // （没给时 followKnown=false → 界面自己问一次，见 model/Search 的 following）。
        ownerFollowing: post.following === true,
        ownerFollowKnown: post.following !== undefined,
        videoUrl: post.videoUrl,
        imageUrls: [post.coverUrl],
        mediaWidth: post.width,
        mediaHeight: post.height,
        originalVideoUrl: post.originalVideoUrl,
        repostCount: post.repostCount,
        thumbUrl: post.coverUrl
      }));
    }
    return out;
  }

  /**
   * 搜索推荐流的"再要一页"（Reels 页滑到末尾时调）。
   *
   * 复用搜索页那条游标链（`SearchViewModel.requestMoreForReels`）—— 它自己带可见性/限流的闸门
   * ——然后按**同一个顺序**（点的那条第一 + 随机，见 orderSearchReels）把整份列表还回去
   * （列表是整体替换语义，见 ProfileReelsViewModel.requestMore）。
   */
  private async loadSearchReelsMore(): Promise<ProfileStreamPage> {
    const more: boolean = await this.searchVm.requestMoreForReels();
    const ordered: Array<SearchPost> =
      this.orderSearchReels(this.searchVm.recommendPosts(), this.searchReelsAnchor);
    const list: Array<MediaPost> = Index.searchPostsToMedia(ordered);
    hilog.info(DOMAIN, TAG, 'search reels more n=%{public}d more=%{public}s',
      list.length, `${more}`);
    return new ProfileStreamPage(list, more);
  }

  /**
   * 把"这条被赞/取消赞"落到**显示着它的每一份列表**上。
   *
   * 为什么需要：信息流的列表在 FeedViewModel 手里，而**帖子页**那一份在 Index 手里
   * （见 openPostStream）—— 两份都可能正在显示同一条帖子。只改一份的话，在帖子页点赞心不变红
   * （或者反过来，信息流里那颗心不跟着变）。
   */
  private setLikedEverywhere(key: string, liked: boolean): void {
    this.viewModel.setLiked(key, liked);
    // 会话台账：媒体 id → 本机点过的状态（见 core/NativeEngage.EngageState 的说明）。
    // 帖子页翻页 / 从网格重建那两份列表时，`ProfileMapper.toMediaPost` 会来查这张表。
    const id: string = this.engageIdOf(key);
    if (id.length > 0) {
      EngageState.rememberLiked(id, liked);
    }
    const updated: Array<MediaPost> | null = FeedMapper.withLiked(this.postPagePosts, key, liked);
    if (updated !== null) {
      this.postPagePosts = updated;
    }
  }

  /**
   * 同上，转发那条。
   *
   * **帖子页那份也要跟着改**（需求："转发按钮点击没反应，也没有显示转发数量"）：
   * 以前这里只动信息流那份，帖子页的图标和计数一个都不变 —— 请求其实发出去了（日志里
   * `skeleton repost ok=true`），但界面上毫无反应。
   */
  private setRepostedEverywhere(key: string, reposted: boolean): void {
    this.viewModel.setReposted(key, reposted);
    const id: string = this.engageIdOf(key);
    if (id.length > 0) {
      EngageState.rememberReposted(id, reposted);
    }
    const updated: Array<MediaPost> | null = FeedMapper.withReposted(this.postPagePosts, key, reposted);
    if (updated !== null) {
      this.postPagePosts = updated;
    }
  }

  /**
   * 按列表的 key（`sc:` / `id:`）反查**媒体 id**（台账用）。
   *
   * 两份列表都要看：信息流那份在视图模型里，帖子页那份在 `postPagePosts` 里。
   */
  private engageIdOf(key: string): string {
    const feed: Array<MediaPost> = this.viewModel.list();
    for (let index: number = 0; index < feed.length; index++) {
      if (FeedMapper.keyOf(feed[index]) === key) {
        return feed[index].id;
      }
    }
    for (let index: number = 0; index < this.postPagePosts.length; index++) {
      if (FeedMapper.keyOf(this.postPagePosts[index]) === key) {
        return this.postPagePosts[index].id;
      }
    }
    return '';
  }

  /**
   * 帖子页的正文：**和首页同一个 FeedList**，数据换成当前分页那一份。
   *
   * **不再垫任何留白**：FeedList 自己顶上就有一层 94vp 的透明占位（见它的 FEED_START_OFFSET），
   * 首页那条留白就是它出的 —— 这里再垫一层等于让帖子多下沉一整个标题栏（用户报的
   * "帖子下沉太多了，只需要避让标题栏就可以"）。
   */
  @Builder
  postPageBody() {
    Column() {
      FeedList({
        posts: this.postPagePosts,
        // 帖子页只有在自己是最上面那层时才播（被用户主页压住时要停）。
        active: this.topPage === POST_PAGE,
        // 一进来就定位到点进去的那一条（见 FeedList.restoreAnchor）。
        initialKey: this.postPageAnchor,
        onAnchorChange: (key: string): void => {
          this.postPageAnchor = key;
        },
        // 资料行里不显示关注按钮（需求）：这一页整段是同一个人，关注在标题栏右上角。
        showFollowInRow: false,
        loading: false,
        loadingMore: this.postPageLoadingMore,
        refreshing: $postPageRefreshing,
        onRefresh: (): void => {
          // 这一页没有"重新取数"这一说（数据是进页时整份带过来的），刷一下只把状态收回去。
          this.postPageRefreshing = false;
        },
        onLoad: (): void => {
        },
        // 触底：接着跟网格那边要下一页（同一条链路，见 loadPostPageMore）。
        onNearEnd: (): void => {
          this.loadPostPageMore();
        },
        onPlaybackError: (): void => {
          this.setLocalStatus($r('app.string.video_play_failed'));
        },
        // 点帖子本身：这一页里就是"看这一条"，不跳走（老行为是打开网页帖子页，在这里会把人带出原生）。
        onOpen: (post: MediaPost): void => {
        },
        // 资料行（头像 + 用户名）→ 打开那位用户的主页（和首页同一条路）。
        onOpenUser: (post: MediaPost): void => {
          this.openUserProfile(post.ownerUsername, post.ownerId);
        },
        onLike: (post: MediaPost): void => {
          this.likePost(post);
        },
        onLikeMedia: (post: MediaPost): void => {
          this.likeByDoubleTap(post);
        },
        onComments: (post: MediaPost): void => {
          this.openComments(post);
        },
        onRepost: (post: MediaPost): void => {
          this.repostPost(post);
        },
        // 收藏：和首页同一条路（见 savePost）。
        onSave: (post: MediaPost, save: boolean): Promise<boolean> => {
          return this.savePost(post, save);
        },
        onFollow: (post: MediaPost, follow: boolean): Promise<boolean> => {
          return this.followAuthor(post, follow);
        },
        onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
          this.onFeedScroll(deltaY, offsetY, scrollState);
        }
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  /**
   * 评论浮层的**当前高度**（vp）：`评论详情面板 + 评论输入框` 两块加起来的整体高度。
   *
   * 需求："评论详情面板+评论输入框的高度为屏幕的一半，上滑增加高度到系统状态栏下方"。
   * 打开时置为**置中档（屏幕 3/5）**（见 `commentsMidVp`），拖动时在 [置中档, 状态栏下方] 之间变，
   * 抬手吸附到最近的那一档（见 onCommentsDrag*）。
   */
  @State private commentsHeightVp: number = 0;
  /**
   * 评论浮层**入场 / 出场**的位移（vp）：0 = 已经就位，= 高度 = 完全滑到屏幕下方。
   *
   * 弹出动画（需求："增加弹出动画，类似半模态页面的弹出效果"）：打开时先把它摆到"整块在
   * 屏幕外"，下一帧再 `animateTo` 回 0；收起时反过来，动画跑完才真正隐藏浮层。
   */
  @State private commentsEnterVp: number = 0;
  /**
   * **下拉越界的跟手位移**（vp，≥0）：面板已经在置中档、列表也已经在顶部，再往下拉时整块跟着
   * 手指往下走这一截。
   *
   * 抬手时超过 `COMMENTS_PULL_CLOSE_VP` 就**整个收起**（需求："下滑评论面板…后动画收起评论"），
   * 没超过就弹回去。
   */
  @State private commentsPullVp: number = 0;
  /** 遮罩的不透明度（0 = 全透明）：跟弹出/收起动画一起变。 */
  @State private commentsMaskAlpha: number = 0;
  /**
   * 打开评论**之前**底栏是不是已经处于"下沉收缩"那一档。
   *
   * 收起评论时要还原成它（需求："收起评论面板还原打开评论前的状态（下沉收缩/展开）"）——
   * 不然用户本来是展开的，关掉评论却留下一根缩着的底栏（或者反过来）。
   */
  private commentsBarWasSunk: boolean = false;
  /**
   * 顶部那条上一次收到的**累计**位移（vp，记账用）。
   *
   * `PanGesture` 给的是"相对按下点"的累计 `offsetY`，而下面的路由吃的是**每帧增量**
   * （列表那条路给的就是增量）—— 这里存上一帧的值，相减得到增量，两条路才同一种语义。
   * 不转的话每一帧都会把"从按下到现在的全部位移"再加一遍，面板一碰就窜到最高。
   */
  private commentsDragBaseVp: number = 0;
  /**
   * 这一轮拖动**从哪一档出发**（vp = 起始高度）。
   *
   * 三档吸附要用它：轻滑的落点是"回到出发那一档"，不是"离哪档近去哪档"（需求："轻滑动太猛"）。
   */
  private commentsDragFromVp: number = 0;
  /** 这一轮拖动一共走了多少（vp，**>0 = 上滑**）：决定够不够换档。 */
  private commentsDragTravelVp: number = 0;
  /** 离手速度（vp/s，**>0 = 上滑**）：快甩也能换一档（慢拖看距离）。 */
  private commentsDragVelocity: number = 0;
  /** 这一轮拖动是不是已经在记账（第一条被吃掉的位移开账，见 routeCommentsDelta）。 */
  private commentsDragActive: boolean = false;
  /**
   * 这一轮拖动里面板**到过"顶部"档**没有。
   *
   * 为什么需要它：往下拖是"换一档"还是"收起"，看的是**面板现在在哪一档**，不是"这一轮从哪
   * 开始"。同一个手势里先上滑到顶、再往下拖，如果按"从中间出发"算，就会整块一路滑到屏幕
   * 底部（用户报的"越过置中档卡在最底部"）。有它以后：到过顶部就只换一档（顶 → 中），
   * **不会**顺势把面板拖到底；想收起要**再下滑一次**（需求）。
   */
  private commentsDragSawTop: boolean = false;
  /**
   * 手指是不是正按在浮层上（面板的手势开始时置真）。
   *
   * 用途：静默计时到点时不至于在"用户拖到一半停了一下"的时候吸附/收起（见 scheduleCommentsSettle）。
   */
  private commentsTouching: boolean = false;
  /**
   * 评论列表的控制器（面板把自己的 Scroller 接上来，见 CommentsPanel 里的类说明）。
   *
   * 面板的拖动只有一个手势（面板根节点的 PanGesture），列表自己不接收手指 ——
   * "滚列表"这件事由这里下发，所以**不会再出现"下滑滚不动列表"**。
   */
  private commentsList: CommentsListController = new CommentsListController();
  /** 这一轮位移最后是作用在**列表**上吗（决定松手给列表惯性还是给面板吸附）。 */
  private commentsListDrag: boolean = false;
  /** 面板最后一次真的动了的时间（ms）：判断"还按着"是不是过期了（见 COMMENTS_TOUCH_STALE_MS）。 */
  private commentsLastMoveAtMs: number = 0;
  /**
   * 评论浮层现在停在**置顶档**吗（false = 置中档）。
   *
   * 只反映"**档位**"，不跟拖动中的高度走：拖动过程中它保持不变，松手吸附到某一档时才更新。
   * 面板那边靠它决定拖动方向 / 列表能不能滚（见 CommentsPanel 文件头的状态机）——
   * 只在手势边界变化，才不会把正在进行的拖动打断。
   */
  @State private commentsAtTop: boolean = false;
  /** 浮层正在播收起动画（期间不再接受新的收起请求，也不响应拖动）。 */
  private commentsClosing: boolean = false;
  /**
   * 收起动画期间**又来的**收尾动作（见 closeComments / suspendCommentsForProfile）。
   *
   * 一段收起动画只播一次，但"动画跑完要做什么"可能来两次：用户连点两下、
   * 或者点头像时面板正好在关。`closeComments` 的注释一直写着"记下这一次的收尾动作，
   * 等同一个计时器跑完再一起做"，但代码里是**直接 return** —— 于是那次点击彻底消失
   * （表现就是"在收起动画里点评论头像，用户主页永远不打开"，审计 G2）。
   * 这里把注释说的那件事真的做出来：排队，动画跑完统一跑掉。
   */
  private commentsAfterQueue: Array<() => void> = [];
  /**
   * 评论浮层**被挂起**了（被上面压上来的整屏页面挡住，比如"从评论点进用户主页"）。
   *
   * 挂起 ≠ 收起：`commentsVisible` 还是 true、评论数据/档位/列表滚动位置全留着，只是这一层
   * `Visibility.Hidden`（不显示、不响应触摸）。页面关掉就显回来 —— 需求："从评论点击进入
   * 用户主页不要收起评论面板"。
   */
  @State private commentsSuspended: boolean = false;
  /**
   * 挂起时**压着几层整屏页面**（见 suspendCommentsForProfile / onPageHidden）。
   *
   * 为什么需要它：浮层在根 Stack 里、`zIndex(70)`，NavDestination 压不住它 —— 所以只要上面
   * 有整屏页面，这一层就必须让位。而"什么时候该放回来"不能再用"所有页面都关掉了"来判：
   * 评论面板也可能是在**帖子页 / Reels 页开着**的（用户在那些页面上点头像进主页，见
   * openUserProfile），那种情况回到"帖子页还在"那一层就该把面板放回来。
   *
   * -1 = 没挂起。
   */
  private commentsSuspendBase: number = -1;
  /** 吸附用的静默计时器（见 scheduleCommentsSettle）。 */
  private commentsSettleTimer: number = -1;
  /** 出场动画的计时器：动画跑完才隐藏浮层、把底栏放回来。 */
  private commentsExitTimer: number = -1;

  /**
   * 评论浮层的**置中档高度**（vp）= **屏幕高度的 3/5**（需求）。
   *
   * 三档里的中间那一档（另外两档：置顶 = 状态栏下方、收起 = 关闭面板）。
   *
   * 容器最底下**不再留**输入条那条底部让位：输入条在浮层里传 `bottomInset: 0`
   * （容器底边已经在窗口底边、比屏幕底边高出一条手势条，正是 reels 页那条输入条的高度，
   * 见 CommentInputBar），所以容器高度就是"面板 + 间隙 + 输入框"。
   *
   * 这一版**不再用系统半模态**（bindSheet）：需求要求"评论输入框与详情面板分离"，而系统弹窗
   * 只给一块整体内容，输入框只能嵌在里面。现在是自己画的一层浮层（见 build 里的
   * `commentsOverlay`），高度完全由这里控制。
   */
  private commentsMidVp(): number {
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      const heightVp: number = this.getUIContext().px2vp(dsp.height);
      if (heightVp > 200) {
        return Math.round(heightVp * COMMENTS_MID_SCREEN_RATIO);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'comments mid height failed: %{public}s', (error as Error).message);
    }
    return 480;
  }

  /**
   * 评论浮层的**最高高度**（vp）：上滑到底时，面板顶边落在**系统状态栏下方**。
   *
   * 需求："上滑增加高度到系统状态栏下方"。
   *
   * 三段都要减掉（真机实测：只减状态栏的话，浮层是从**屏幕底边**往上量的，而浮层实际
   * 贴在窗口底边（比屏幕底边高出一条底部系统条）—— 不扣这两段就会顶出去：
   *   ① 顶部状态栏（`topSafeVp`，窗口避让区给的）；
   *   ② 底部系统条（`bottomSafeVp`）—— 浮层贴的是窗口底边，不是屏幕底边；
   *   ③ 顶部那条**可拖的小横条**自身的高度（`COMMENTS_DRAG_ZONE_VP` = 22vp）：它是面板的第一行，
   *      要留在状态栏下面，否则拖到头时它正好被状态栏盖住（真机拖到顶后小横条确实看不见了）。
   *
   * 之前少了 ②③：算出来 764vp > 窗口高度 742vp，多出的 77px 跑到窗口上方去了 —— 小横条和
   * 内容第一行都被状态栏盖掉（dump 里那条 36×4 的小横条直接消失了）。
   */
  private commentsMaxVp(): number {
    const top: number = this.topSafeVp > 0 ? this.topSafeVp : 28;
    const bottom: number = this.bottomSafeVp > 0 ? this.bottomSafeVp : 28;
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      const heightVp: number = this.getUIContext().px2vp(dsp.height);
      const max: number = heightVp - top - bottom - COMMENTS_DRAG_ZONE_VP;
      if (max > 240) {
        return Math.round(max);
      }
    } catch (error) {
    }
    return 700;
  }

  /** 打开评论浮层时把高度复位到**置中档（屏幕 3/5）**（见 openComments）。 */
  private resetCommentsHeight(): void {
    this.commentsHeightVp = this.commentsMidVp();
    this.commentsPullVp = 0;
    // 打开时是"置中档"（列表还不能滚、整块面板都能拖，见 CommentsPanel 的状态机）。
    this.commentsAtTop = false;
  }

  /** 面板开始拖：开账（这一轮从当前档位出发）+ 标记手指按着。 */
  private onCommentsDragStart(): void {
    this.commentsDragBaseVp = 0;
    this.commentsTouching = true;
    this.beginCommentsDrag();
  }

  /** 开账：记下出发高度、清空位移与速度。 */
  private beginCommentsDrag(): void {
    this.commentsDragActive = true;
    this.commentsDragFromVp = this.commentsHeightVp > 0 ? this.commentsHeightVp : this.commentsMidVp();
    this.commentsDragTravelVp = 0;
    this.commentsDragVelocity = 0;
    this.commentsLastMoveAtMs = Date.now();
    this.commentsListDrag = false;
    // 出发时就在顶部档 → 这一轮已经"到过顶部"。
    this.commentsDragSawTop = this.commentsHeightVp >= this.commentsMaxVp() - 1;
  }

  /**
   * 面板在拖（面板根节点那个 PanGesture，见 CommentsPanel）：手势给的是**累计** `offsetY`
   * （向上为负），先转成"这一帧的增量"再交给路由。
   *
   * 列表区域平时是**列表自己**在收手势（原生滚动，顺滑），这一路只在"手指落在非列表区域"
   * （小横条、标题、空白）时才会来 —— 所以它吃不下时得替列表滚。
   */
  private onCommentsDragUpdate(offsetY: number): void {
    const step: number = this.commentsDragBaseVp - offsetY;
    this.commentsDragBaseVp = offsetY;
    const eaten: boolean = this.routeCommentsDelta(step, this.commentsList.offset() <= 0.5);
    if (!eaten) {
      // 面板吃不下（该滚列表了）：拖着的是标题这种地方，只能替列表滚一段。
      this.scrollCommentsList(step);
    }
  }

  /**
   * 松手（面板手势）：这一轮最后作用在哪儿，就由谁收尾。
   *
   *   · 最后在滚列表 → 列表的惯性已经由 ArkUI 原生滚动接管，这里只结账；
   *   · 最后在动面板 → 吸附到某一档（弹簧，带一点回弹）。
   */
  private onCommentsDragEnd(velocityUp: number): void {
    this.commentsTouching = false;
    this.commentsDragVelocity = velocityUp;
    if (this.commentsListDrag) {
      this.finishCommentsDrag();
      return;
    }
    this.settleCommentsHeight();
  }

  /** 结清这一轮拖动的账（下一轮从新高度重新出发）。 */
  private finishCommentsDrag(): void {
    // 一行一次（收尾时）：这一轮是"滚列表"还是"动面板"、走了多少 —— 排查手感问题用。
    hilog.info(DOMAIN, TAG, 'comments drag end: list=%{public}s travel=%{public}d listOff=%{public}d',
      `${this.commentsListDrag}`, Math.round(this.commentsDragTravelVp),
      Math.round(this.commentsList.offset()));
    this.commentsDragActive = false;
    this.commentsDragTravelVp = 0;
    this.commentsDragVelocity = 0;
    this.commentsDragSawTop = false;
    this.commentsListDrag = false;
  }

  /**
   * **面板上的位移路由**（需求："上滑优先扩展面板，禁用内部滚动；下滑优先内部滚动，
   * 禁用外部面板收缩"）。
   *
   * 两条路都汇到这里：**列表每帧想滚的位移**（`onScrollDelta`，放行时由列表原生滚动）和
   * 面板手势（拖小横条/标题时）。
   *
   * 裁决（唯一的裁决点）：
   *   · 上滑：面板没到顶就加高面板（列表一帧都不滚）；到顶了才把位移留给列表；
   *   · 下滑：**列表只要还能往上滚（offset > 0）就滚列表**，面板一点不动；
   *           列表已经在顶部时，才轮到面板（顶档 → 中档，中档 → 收起）。
   *
   * @param deltaVp 位移（vp，**>0 = 上滑**，<0 = 下滑）。
   * @param atTop 列表是不是已经在顶部（直接读它的 Scroller）。
   * @returns true = 面板吃掉了（列表这一帧不要滚）。
   */
  private routeCommentsDelta(deltaVp: number, atTop: boolean): boolean {
    if (this.commentsClosing || !this.commentsVisible || deltaVp === 0) {
      return false;
    }
    const mid: number = this.commentsMidVp();
    const max: number = this.commentsMaxVp();
    if (!this.commentsDragActive) {
      this.beginCommentsDrag();
    }
    /*
     * 这一帧的归属默认是**面板**，只有真把位移留给列表时才置 `false`。
     *
     * 必须按帧重算、不能只在开账时清一次：一个手势里常见"先把列表滚到顶、再接着收面板"，
     * 归属会中途从列表换成面板 —— 松手时若还认为归列表，面板就会停在半路不吸附。
     */
    this.commentsListDrag = false;
    let eaten: boolean = true;
    if (deltaVp > 0) {
      // 上滑：**先把面板加到顶**（需求："禁用内部滚动"），加不动了才轮到列表。
      if (this.commentsPullVp > 0) {
        // 上一轮下拉越界还没弹回去：先把手感收回来，再谈加高。
        this.commentsPullVp = Math.max(0, this.commentsPullVp - deltaVp);
      } else if (this.commentsHeightVp < max) {
        this.commentsHeightVp = clampVp(this.commentsHeightVp + deltaVp, mid, max);
        if (this.commentsHeightVp >= max - 0.5) {
          // 这一轮到过顶部档了：之后再往下拖就只"换一档"，不许一路滑到底（见 commentsDragSawTop）。
          this.commentsDragSawTop = true;
        }
      } else {
        // 面板已经在最高：这一帧留给**列表**（放行给它的原生滚动）。
        eaten = false;
      }
    } else if (!atTop) {
      // 列表还能往上滚：**下滑优先滚列表**，面板一点不动（需求："禁用外部面板收缩"）。
      eaten = false;
    } else {
      const next: number = this.commentsHeightVp + deltaVp;
      if (next > mid) {
        // 还在"顶部 ↔ 中间"之间：跟着手指收（**不越过中间**）。
        this.commentsHeightVp = next;
      } else if (!this.commentsDragSawTop) {
        /*
         * **这一轮没到过顶部（也就是从"置中档"往下）**：下面没有档位了，再往下就是**收起**。
         *
         * 面板本身**不再跟着手指走**（需求："禁用外部面板收缩"）：只留一点橡皮筋反馈
         * （见 COMMENTS_PULL_DAMP），松手时按**手指实际走了多少**（`commentsDragTravelVp`）
         * 决定是否收起。
         */
        this.commentsHeightVp = mid;
        this.commentsPullVp = clampVp(this.commentsPullVp - deltaVp * COMMENTS_PULL_DAMP,
          0, COMMENTS_PULL_MAX_VP);
      } else {
        /*
         * **这一轮到过顶部、而且已经收到"置中档"了**：到此为止（需求："置顶档用力下滑……
         * 卡在置中档，然后再下滑才是收起面板"）—— 不能越过置中档继续往下。
         */
        this.commentsHeightVp = mid;
      }
    }
    if (eaten) {
      // 记账用的是**手指实际走了多少**：换档阈值按手指量算。
      this.commentsDragTravelVp += deltaVp;
      this.commentsLastMoveAtMs = Date.now();
      this.scheduleCommentsSettle();
    } else {
      // 这一帧交给列表了：用户真的在翻列表（放开自动补页上限）。
      this.commentsListDrag = true;
      this.commentsTouched = true;
    }
    return eaten;
  }

  /**
   * **兜底**：替列表滚一段（`commentsList.scrollBy`）。
   *
   * 只在"手指落在非列表区域（小横条/标题/空白），而这一段按优先级该滚列表"时才会用到 ——
   * 列表区域本身是原生滚动，不走这儿（那才是顺滑的那条路）。
   */
  private scrollCommentsList(deltaVp: number): void {
    this.commentsListDrag = true;
    this.commentsTouched = true;
    this.commentsList.scrollBy(clampVp(deltaVp, -COMMENTS_DRAG_MAX_VP, COMMENTS_DRAG_MAX_VP));
  }

  /** 面板高度吸附到某一档（弹簧带一点回弹，需求："要有弹性动画"）。 */
  private animateCommentsTo(target: number): void {
    const next: number = Math.round(target);
    // 档位（只在手势边界更新，见 commentsAtTop 的说明）。
    this.commentsAtTop = next >= Math.round(this.commentsMaxVp()) - 1;
    if (next === Math.round(this.commentsHeightVp) && this.commentsPullVp === 0) {
      return;
    }
    this.getUIContext().animateTo({
      curve: curves.springMotion(COMMENTS_SETTLE_SPRING_RESPONSE, COMMENTS_SETTLE_SPRING_DAMPING)
    }, (): void => {
      this.commentsHeightVp = next;
      this.commentsPullVp = 0;
    });
  }

  /**
   * 手势停了：在**三档**（顶部 / 中间 / 收起）之间落位。
   *
   * 规则（需求："分三档，顶部，中间和收起" + "轻滑动的力度太猛了"）：
   *   · 出发档 = 这一轮拖动开始时的高度（`commentsDragFromVp`）；
   *   · 只有当**拖过两档间距的 `COMMENTS_MOVE_RATIO`** 或者**离手够快（甩）**时，才换**一档**；
   *   · 其余情况（轻滑、短拖）一律**回到出发那一档** —— 不再"离哪档近去哪档"；
   *   · 从"中间"往下换档 = **收起**（需求给的第三档）。
   */
  private settleCommentsHeight(): void {
    if (this.commentsSettleTimer >= 0) {
      clearTimeout(this.commentsSettleTimer);
      this.commentsSettleTimer = -1;
    }
    if (this.commentsClosing || !this.commentsVisible || this.commentsSuspended) {
      // **挂起中也一律不吸附**：进用户主页前那一刻如果还有一颗待结算的吸附计时器，
      // 它会把面板的档位改掉 —— 回来时就不是"进入前的位置"了
      // （需求："退出页面后弹出面板并定位到进入用户页面前的位置"）。
      return;
    }
    // 这一轮面板根本没被拖过（用户只是在滚列表）：不吸附，面板停在原地。
    if (!this.commentsDragActive) {
      return;
    }
    /*
     * 这一轮的最后归属是**列表**（用户正在滚评论）：面板不动，但**账要结清**。
     *
     * 不结账的话 `commentsDragActive/from/travel` 会一直留到下一轮手势，两次手势的位移被
     * 累加成一段假的"大幅下拉"——真机上就出现过"滚完列表随手一甩，面板自己被收起"
     * （日志里是一段 `travel=-2112` 的位移）。
     */
    if (this.commentsListDrag) {
      this.finishCommentsDrag();
      return;
    }
    const mid: number = this.commentsMidVp();
    const max: number = this.commentsMaxVp();
    const span: number = Math.max(1, max - mid);
    const from: number = this.commentsDragFromVp > 0 ? this.commentsDragFromVp : this.commentsHeightVp;
    const travel: number = this.commentsDragTravelVp;
    // 速度只在**和面板自己的拖动方向一致**时才算数：手先上滑把面板顶高、再顺势下滑去滚列表，
    // 列表离手时报的是一个向下的巨大速度 —— 采纳它就会把刚顶高的面板又缩回去。
    const velocity: number = (travel === 0 || (travel > 0) === (this.commentsDragVelocity > 0))
      ? this.commentsDragVelocity : 0;
    // 出发时在"顶部"那一档吗。
    //
    // 两个来源取或：这一轮**到过顶部**（哪怕中间又滑下来了），或者出发高度就在上半区。
    const fromTop: boolean = this.commentsDragSawTop || (from - mid) > span / 2;
    // 够"实"的一拖、或者够快的一甩，才算换档/收起（**轻滑不换**，需求："轻滑动的力度太猛"）。
    const strong: boolean = Math.abs(travel) >= span * COMMENTS_MOVE_RATIO
      || Math.abs(velocity) >= COMMENTS_FLING_VP_S;
    const up: boolean = travel > 0 || velocity > 0;
    /*
     * 往下是不是要**收起**。
     *
     * 两档都适用（需求："置中档（最小值）下滑直接收起面板" + "置顶档下滑直接收起面板"）：
     *   · 从"置中档"往下：门槛放得很低（`COMMENTS_CLOSE_MIN_VP`），轻滑也收；
     *   · 从"置顶档"往下：走 `strong`（拖过两档间距的 40% 或快甩）—— 顶档离"收起"更远，
     *     门槛太低会一碰就没了。
     */
    const wantsClose: boolean = travel <= -COMMENTS_CLOSE_MIN_VP
      || velocity <= -COMMENTS_FLING_VP_S;
    hilog.info(DOMAIN, TAG,
      'comments settle from=%{public}d travel=%{public}d v=%{public}d strong=%{public}s up=%{public}s'
        + ' close=%{public}s',
      Math.round(from), Math.round(travel), Math.round(velocity), `${strong}`, `${up}`,
      `${wantsClose}`);
    // 收尾：这一轮的账结清（下一轮从新高度重新出发）。
    this.finishCommentsDrag();
    if (fromTop) {
      /*
       * **置顶档往下 → 直接收起面板**（需求）。
       *
       * 往上没有档了（面板已经在最高）→ 原地不动；轻滑（不够 strong）也留在顶部，
       * 免得碰一下就整块没了。
       */
      if (strong && !up) {
        this.closeComments();
        return;
      }
      this.animateCommentsTo(max);
      return;
    }
    // 置中档往下 = 收起；往上（够实/够快）= 顶部；否则留在置中档。
    if (wantsClose) {
      this.closeComments();
      return;
    }
    this.animateCommentsTo(strong && up ? max : mid);
  }

  /**
   * 手势静默一小会儿就当作"松手"（见 COMMENTS_SETTLE_MS）。
   *
   * 为什么不只靠 `onScrollStop` / `onActionEnd`：列表内容比屏幕短时它不一定会报滚动停止，
   * 那样面板就会停在半路不吸附。两道都留着 —— 重复调用是幂等的（状态已经到位就直接返回）。
   *
   * 手指还按着时**不吸附**（拖到一半停一下不该被当成松手、更不该顺势收起），只是再等一轮；
   * 触摸抬起（`onPanelTouch(false)`）或者 `onScrollStop` 会立刻结账。
   */
  private scheduleCommentsSettle(): void {
    if (this.commentsSettleTimer >= 0) {
      clearTimeout(this.commentsSettleTimer);
    }
    this.commentsSettleTimer = setTimeout((): void => {
      this.commentsSettleTimer = -1;
      const quietMs: number = Date.now() - this.commentsLastMoveAtMs;
      if (this.commentsTouching && quietMs < COMMENTS_TOUCH_STALE_MS) {
        this.scheduleCommentsSettle();
        return;
      }
      this.settleCommentsHeight();
    }, COMMENTS_SETTLE_MS);
  }

  /**
   * 把底栏**收起来**（需求流程第一步：先走原生的隐藏动效，再弹评论面板）。
   *
   * 需求要的两种模式：
   *   · 系统显隐档：走 HDS 的显隐动效（`hideBar`）；
   *   · **下沉收缩档：先下沉收缩，再额外走一次原生隐藏动效**（需求："在下沉收缩的状态下
   *     打开评论额外调用原生隐藏动画"）。
   *
   * 打开之前底栏是"已下沉"还是"展开"要记下来：收起评论时要**还原成那一档**
   * （见 restoreBarAfterComments）。
   */
  private sinkBarForComments(): void {
    this.commentsBarWasSunk = this.barSink > 0.5;
    hilog.info(DOMAIN, TAG, 'comments open: bar mode=%{public}s sunk=%{public}s',
      this.barHideMode, `${this.commentsBarWasSunk}`);
    if (this.barHideMode === BAR_HIDE_SYSTEM) {
      this.hideBar();
      return;
    }
    this.setBarSink(1);
    // 下沉之后再叫一次原生隐藏动效：这是需求点名要的"额外"那一下。
    if (PlatformCap.hasHdsMaterial()) {
      this.hideBar();
    }
  }

  /**
   * 评论收起之后把底栏**放回来**（需求流程最后一步）。
   *
   * 需求："收起评论面板还原打开评论前的状态（下沉收缩/展开）" —— 所以不能像以前那样一律
   * `restoreBar()`（那是弹回展开）：先把原生隐藏动效放回来，再回到**打开前那一档**。
   */
  private restoreBarAfterComments(): void {
    this.barScrollPull = 0;
    if (this.barHideMode === BAR_HIDE_SYSTEM) {
      this.showBar();
      return;
    }
    this.showBar();
    this.applyBarSink(this.commentsBarWasSunk ? 1 : 0);
  }

  /** 把浮层收到位（弹出动画）。幂等：已经在位就什么都不做。 */
  private enterCommentsOverlay(): void {
    if (!this.commentsVisible || this.commentsClosing) {
      return;
    }
    if (this.commentsEnterVp === 0 && this.commentsMaskAlpha === 1) {
      return;
    }
    this.getUIContext().animateTo({ curve: curves.springMotion(), duration: COMMENTS_IN_MS },
      (): void => {
        this.commentsEnterVp = 0;
        this.commentsMaskAlpha = 1;
      });
  }

  /** 兜底：入场动画万一带不上就**硬写**到位（见 openComments 的三条说明）。 */
  private forceCommentsOverlayShown(): void {
    if (!this.commentsVisible || this.commentsClosing) {
      return;
    }
    this.commentsEnterVp = 0;
    this.commentsMaskAlpha = 1;
  }

  /**
   * **评论浮层**（自己画的一层，不再用系统半模态）。
   *
   * 需求："点击评论后弹出面板，最底部是评论输入框，ui 采用 reels 类页面底部输入评论和发送的
   * 沉浸光感样式，上方是评论详情面板，两者分离，不要将评论输入框嵌入面板中；评论详情面板 +
   * 评论输入框的高度为屏幕的一半，上滑增加高度到系统状态栏下方。"
   *
   * 结构（从下往上）：
   *   ① 半透明遮罩：点一下关掉（等价于系统弹窗点遮罩），不透明度跟着弹出/收起动画走；
   *   ② 底部容器（高度 = `commentsHeightVp`，整块跟着 `commentsEnterVp + commentsPullVp` 上下走）：
   *        · 评论详情面板（CommentsPanel：沉浸光感材质 + 四角圆角 + 小横条 + 「评论」标题）；
   *        · **一条间隙**（需求："输入框和面板之间要有间隙"）；
   *        · **评论输入框单独一条**（CommentInputBar = reels 页那条沉浸光感输入条），
   *          和面板**分离**、不嵌在面板里；
   *   ③ 三者加起来 = 需求里说的"评论详情面板 + 评论输入框的高度"。
   *
   * 宽度：容器统一留 `COMMENTS_SIDE_VP` 的左右白，**面板和输入框因此等宽**
   * （需求："面板宽度按照评论输入框"）—— 输入条自己那份左右白在这儿传 0。
   *
   * 弹出动画：`onAppear` 里把 `commentsEnterVp`（先摆成"整块在屏幕外"）和遮罩一起收到位，
   * 效果就是半模态那种从底部滑上来（收起草见 closeComments）。
   */
  @Builder
  commentsOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ① 遮罩：点一下收起（和系统弹窗一致的手感）。
      Column()
        .width('100%')
        .height('100%')
        /*
         * 遮罩颜色跟明暗走（资源 `comments_scrim`）：
         *   · 深色模式 = `#66000000`（40% 黑，压暗）；
         *   · 浅色模式 = `#66FFFFFF`（40% **高透明度的白**，需求："浅色模式下蒙版改为浅白色"）。
         */
        .backgroundColor($r('app.color.comments_scrim'))
        .opacity(this.commentsMaskAlpha)
        /*
         * **遮罩要盖满整屏**（需求："评论输入框下方蒙版没有延申" + "延申到状态栏避让区"
         * + "输入法弹出时蒙版没有延申到输入法避让区"）。
         *
         * 浮层所在的这一层是"窗口内容区"：上下都比屏幕边少一条系统避让区（上 = 状态栏、
         * 下 = 手势条 / 输入法）。所以要三种避让区都扩：
         *   · `SYSTEM`   —— 状态栏 + 底部导航/手势条；
         *   · `KEYBOARD` —— 输入法弹起时，窗口底边到输入法顶边之间那一条。
         * `expandSafeArea` 只扩**绘制**区域、不动布局，所以面板/输入框的位置一点不变。
         */
        .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD],
          [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onClick((): void => {
          this.closeComments();
        })

      // ② 底部那一块：面板 + 间隙 + 输入条，左右统一留白（两者等宽）。
      Column() {
        // 评论详情面板（占满输入条以上的空间）。
        CommentsPanel({
          comments: this.comments,
          loading: this.commentsLoading,
          loadingMore: this.commentsLoadingMore,
          hasMore: this.commentsHasMore,
          state: this.commentsState,
          ownerUsername: this.commentsOwner,
          caption: this.commentsCaption,
          ownerAvatar: this.commentsAvatar,
          diag: this.commentsDiag,
          // 列表控制器：面板把它的 Scroller 接上来（读偏移用）。
          listCtl: this.commentsList,
          // 档位：面板据此决定拖动方向 / 列表能不能滚（见 CommentsPanel 文件头的状态机）。
          panelAtTop: this.commentsAtTop,
          // **整个面板一个拖动手势**（PanGesture，见 CommentsPanel）：加高面板 / 滚列表 / 收起。
          onPanelDragStart: (): void => {
            this.onCommentsDragStart();
          },
          onPanelDragUpdate: (offsetY: number): void => {
            this.onCommentsDragUpdate(offsetY);
          },
          // 离手速度（vp/s，向上为正）：决定吸附换档（慢拖看距离、快甩看速度）。
          onPanelDragEnd: (velocityUp: number): void => {
            this.onCommentsDragEnd(velocityUp);
          },
          // 点头像 / 用户名 → TA 的主页（需求："点击头像或id进入用户详情页"）。
          onUserTap: (username: string, userId: string): void => {
            this.openUserFromComments(username, userId);
          },
          // 展开回复：去要这条评论的全部回复（见 loadCommentReplies）。
          onLoadReplies: (parentIndex: number): void => {
            this.loadCommentReplies(parentIndex);
          },
          // 给某条下挂回复点赞（右侧那颗心）。
          onLikeReply: (parentIndex: number, replyIndex: number): void => {
            this.likeReply(parentIndex, replyIndex);
          },
          // 评论点赞：乐观翻转 + HTTP（见 likeComment）。
          onLikeComment: (index: number): void => {
            this.likeComment(index);
          },
          // 触底加载下一页（见 loadMoreComments）。
          onLoadMore: (): void => {
            this.loadMoreComments();
          },
          // 用户碰过列表了：自动补页不再设上限（见 canLoadCommentsMore）。
          onUserTouch: (): void => {
            this.commentsTouched = true;
          },
          // 评论正文翻译失败：弹一句（面板自己把状态退回去了）。
          onTranslateFailed: (): void => {
            this.toast($r('app.string.translate_failed'));
          }
        })
          .layoutWeight(1)

        // **评论输入框：和面板分离的一条**（需求），样式就是 reels 页那条沉浸光感输入条。
        // 左右白由容器统一给（sideInset: 0，跟面板等宽）；底部不再自己让位
        // （bottomInset: 0）—— 容器底边本来就在窗口底边，正好是 reels 页那条的高度。
        CommentInputBar({
          sideInset: 0,
          bottomInset: 0,
          onSend: (text: string): void => {
            this.toast($r('app.string.comment_pending'));
            hilog.info(DOMAIN, TAG, 'comments draft len=%{public}d (not sent)', text.length);
          }
        })
          .margin({ top: COMMENTS_GAP_VP })
      }
      .width('100%')
      .padding({ left: COMMENTS_SIDE_VP, right: COMMENTS_SIDE_VP })
      .height(this.commentsHeightVp > 0 ? this.commentsHeightVp : this.commentsMidVp())
      // 弹出/收起 + 下拉越界：整块一起走（两个位移相加，见各自的说明）。
      .translate({ y: this.commentsEnterVp + this.commentsPullVp })
    }
    .width('100%')
    .height('100%')
    // 盖在标题栏（zIndex 10）、底栏层、以及 NavDestination（帖子页 / Reels 页）之上。
    .zIndex(70)
    /*
     * 挂起时**只是不显示**（`Visibility.Hidden`：不参与命中测试，但仍在组件树上 ——
     * 评论列表的滚动位置、面板档位都留着，见 suspendCommentsForProfile）。
     * 用户主页那种整屏页面压上来时靠它让位。
     */
    .visibility(this.commentsSuspended ? Visibility.Hidden : Visibility.Visible)
    .onAppear((): void => {
      // 弹出动画：第一帧是"整块在屏幕外 + 遮罩透明"，这里再收到位（半模态那种滑上来）。
      // 另外两条兜底在 openComments 里（这个回调不一定来）。
      this.enterCommentsOverlay();
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      InstagramWebHost({
        visible: this.webVisible,
        onPageReady: (): void => {
          this.handlePageReady();
        },
        onSessionChanged: (signedIn: boolean): void => {
          this.applySession(signedIn);
        }
      })
        .width('100%')
        .height('100%')

      if (!this.webVisible) {
        this.nativeShell()
      } else {
        WebChromeBar({
          onBack: (): void => {
            this.handleWebBack();
          },
          onReload: (): void => {
            this.bridge.reload();
          },
          onClose: (): void => {
            this.closeWeb();
          }
        })
          .zIndex(30)
      }

      if (this.probeVisible) {
        ProbePanel({
          text: this.probeText,
          onRefresh: (): void => {
            this.refreshProbeReport();
          },
          onDom: (): void => {
            this.probeDom();
          },
          onCopy: (): void => {
            this.copyProbeReport();
          },
          onSave: (): void => {
            this.saveProbeReport();
          },
          onClear: (): void => {
            this.clearProbe();
          },
          // 要挖 reels / 私信 / 搜索 / 我的 的接口，只能让网页真的走一遍那些页面；
          // 原生这几页还没实现，所以从探针面板直接开（开完面板会自动收起）。
          onOpenReels: (): void => {
            this.openWebFromProbe(AppConfig.INSTAGRAM_REELS_URL);
          },
          onOpenSearch: (): void => {
            this.openWebFromProbe(AppConfig.INSTAGRAM_SEARCH_URL);
          },
          onOpenDirect: (): void => {
            this.openWebFromProbe(AppConfig.INSTAGRAM_DIRECT_URL);
          },
          onOpenProfile: (): void => {
            // 「我的」要先从网页里查出自己的主页地址（见 openProfile / OWN_PROFILE_SCRIPT）。
            this.openProfile();
          },
          onCommentsFirst: (): void => {
            // 面板要先收掉：评论面板和它都是这一层的浮层，留着会互相盖住。
            this.probeVisible = false;
            const list: MediaPost[] = this.viewModel.list();
            if (list.length === 0) {
              this.setLocalStatus($r('app.string.feed_empty'));
              return;
            }
            // 挑第一条**图片**帖：视频帖会走 `/reel/` 页面，那张页面的评论入口和帖子页结构不同，
            // 而现在这条读法（点评论按钮 + 滚一屏逼它发请求）是照帖子页写的，拿视频帖试必然超时。
            let target: MediaPost = list[0];
            for (let index: number = 0; index < list.length; index++) {
              if (!list[index].isVideo()) {
                target = list[index];
                break;
              }
            }
            this.openComments(target);
          },
          onCaptureTemplate: (): void => {
            this.captureFeedTemplate();
          },
          // 「我的」四个分页的模板：逐页导航一次，把四条查询都抓下来（见 captureProfileTemplates）。
          onProfileTemplates: (): void => {
            this.captureProfileTemplates();
          },
          // 搜索页的模板（推荐 + 结果那两条），顺手落一份结构摘要（见 captureSearchTemplates）。
          onSearchTemplates: (): void => {
            this.captureSearchTemplates();
          },
          onReplayStored: (): void => {
            this.replayStoredTemplate();
          },
          onOpenPostPage: (): void => {
            // 打开首条**图片**帖的帖子页（视频帖走 /reel/，结构不同）。
            // 这里**故意不收起面板**：下面的"读内嵌评论"要对着这个页面跑脚本，
            // 面板留着才点得到那颗按钮（网页被盖住也会照常加载，脚本读的是它的文档）。
            const list: MediaPost[] = this.viewModel.list();
            if (list.length === 0) {
              this.setLocalStatus($r('app.string.feed_empty'));
              return;
            }
            let target: MediaPost = list[0];
            for (let index: number = 0; index < list.length; index++) {
              if (!list[index].isVideo()) {
                target = list[index];
                break;
              }
            }
            this.openPost(target);
          },
          onCommentsEmbed: (): void => {
            this.probeCommentsEmbed();
          },
          onDigest: (): void => {
            this.probeDigests();
          },
          onClose: (): void => {
            this.probeVisible = false;
          }
        })
          .zIndex(60)
      }

      // ---- 启动页浮层已移除 ----
      // 启动画面就是**系统那条启动窗口**（module.json5 的 startWindowIcon = splash_icon）。
      // 原来那层自绘浮层（图标 + 应用名 + 最短驻留）整块删掉了：同一张图系统已经画过一遍，
      // 再盖一层只会多一次"图标重画"的闪烁。预热不受影响，见 aboutToAppear 的 preloadTabs。

      // ---- 评论浮层（自己画的一层，见 commentsOverlay）----
      // 放在最后一个兄弟节点 + zIndex(70)：要盖住标题栏、底栏层和 NavDestination。
      if (this.commentsVisible) {
        this.commentsOverlay()
      }

      // ---- 限时快拍播放浮层（见 components/StoryViewer）----
      // zIndex(80)：比评论浮层还高 —— 快拍是从首页点开的，这时评论浮层不该压在上面。
      // 数据没拿到就不开（openStory 只在取数成功后把 storyOpen 置真）。
      if (this.storyOpen) {
        StoryViewer({
          reel: this.storyReel === null ? EMPTY_REEL : this.storyReel,
          username: this.storyName,
          avatarUrl: this.storyAvatar,
          // 正在播的这一位（播放页按它去量序列里那颗头像的位置，见 StoryViewer.logRects）。
          heroUserId: this.storyUserId,
          // 后面还有人 → 最后一条点右半屏接他（见 Index.advanceStory）。
          hasNextUser: this.storyQueueIndex + 1 < this.storyQueue.length,
          // 前面还有人 → 第一条点左半屏回他（见 Index.backStory）。
          hasPrevUser: this.storyQueueIndex > 0,
          // 这位的头像还在主页托盘上吗（不在就改成向下收起，见 StoryViewer.requestClose）。
          heroValid: this.storyHeroValid,
          onNextUser: (): void => {
            this.advanceStory();
          },
          onPrevUser: (): void => {
            this.backStory();
          },
          /*
           * 收起被**打断**（点头像/卡片/空白又展开了）→ 把"正在收起"的记账清掉。
           *
           * 不清的话 `storyClosing` 会一直立着，之后 `onBackPress` 就再也不发收起信号了
           * —— 用户报的"连续打断会导致返回手势失效"就是这个。
           */
          onReopen: (): void => {
            hilog.info(DOMAIN, TAG, 'story reopen (close interrupted)');
            this.storyClosing = false;
          },
          // 底部输入框：这一版只做样式（需求："先不用做功能"），弹一句和评论输入框一样的话。
          onSend: (text: string): void => {
            hilog.info(DOMAIN, TAG, 'story draft len=%{public}d (not sent)', text.length);
            this.toast($r('app.string.comment_pending'));
          },
          // 右下角三颗互动按钮：也只做样式（点赞 / 评论 / 转发给朋友）。
          onAction: (kind: string): void => {
            hilog.info(DOMAIN, TAG, 'story action=%{public}s (not wired)', kind);
            this.toast($r('app.string.story_action_pending'));
          },
          // 系统返回键的收起信号（见 Index.onBackPress 与 StoryViewer.closeSignal）。
          closeSignal: this.storyCloseSignal,
          // 宿主请求掉头展开（收起途中点空白 / 点到别的用户头像，见 onStoryTapPoint）。
          reopenSignal: this.storyReopenSignal,
          // 收起途中点了一下：把窗口坐标交上来做命中测试（点别人头像 = 换人）。
          onTapPoint: (x: number, y: number): void => {
            this.onStoryTapPoint(x, y);
          },
          // 掉进口袋：进袋口时把 tab 栏鼓一下，穿完再弹性回原状（见 swellStoryPocket）。
          onPocketEnter: (): void => {
            this.swellStoryPocket();
          },
          onPocketExit: (): void => {
            this.settleStoryPocket();
          },
          heroX: this.storyHero.x,
          heroY: this.storyHero.y,
          heroW: this.storyHero.w,
          heroH: this.storyHero.h,
          onClose: (): void => {
            this.closeStory();
          }
        })
          .zIndex(80)
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
