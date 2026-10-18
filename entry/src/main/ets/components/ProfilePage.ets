/*
 * 「我的」原生页面：头部 + 帖子网格。
 *
 * 排版与配色跟首页信息流是同一套（page_background / field_background、primary_text /
 * secondary_text、圆角与间距对得上），不引新的视觉语言。
 *
 * 数据由 ProfileViewModel 给（原生 HTTP 优先，见它的说明）；这里只管画与手势：
 *   - 头像 + 全名 + 已验证标记；
 *   - 三项计数（帖子 / 粉丝 / 关注）；
 *   - 签名与外链；
 *   - 三列等宽网格，格子按 4:5 裁切（和 IG 一样），视频给个小角标；
 *   - 触底自动翻页；下拉刷新走 Refresh（和首页同一套）。
 *
 * ## 分段按钮为什么会有"两条"
 * 需求："上滑到分段按钮在页面顶部（hdsnavigation 下方）时让它固定，转为分页滚动"。
 * 页面里那条（个人信息下方）随列表滚；滚过个人信息之后它就该钉在标题栏正下方不动
 * —— 钉住那条是**本页的一层浮层**（见 pinnedSegmentBar），位置和在流那条完全重合，
 * 靠 180ms 交叉淡入淡出交接。这一页负责"钉住了没有"与分页号这两件事。
 *
 * **为什么不交给 HDS 标题栏的 `bottomBuilder`**（上一版的做法）：那一行会被算进标题栏，
 * 标题栏的毛玻璃蒙层跟着从 94vp 长到 154vp —— 用户看到的就是"背景模糊太高了，收缩到
 * hds title 下方"。浮层落在内容区，按钮自己那层沉浸光感材质照样生效（Toggle 全页面生效）。
 */

import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { media } from '@kit.MediaKit';
import { ProfileHeader, ProfileHighlight, ProfileMapper, ProfilePost, ProfileStreamPage, BioSegment, splitMentions } from '../model/Profile';
import { MediaPost } from '../model/MediaPost';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { SaveState } from '../core/SaveState';
import { MaterialChipButton, MaterialIconButton, MaterialLabelButton } from './MaterialSurface';
import { SEGMENT_SIDE, SEGMENT_MODE_USER } from './ProfileSegmentBar';
import { ProfileViewModel, PROFILE_TAB_POSTS, PROFILE_TAB_REELS, PROFILE_TAB_SAVED, PROFILE_TAB_TAGGED } from '../viewmodel/ProfileViewModel';
import { ScrollDelta } from '../core/ScrollReport';
import { PROFILE_TAB } from '../core/AppSettings';
import { ProfileSegmentBar, SEGMENT_MODE_SELF } from './ProfileSegmentBar';

/** 诊断用（分页位置恢复那条路，临时）。 */
const DOMAIN: number = 0xFF00;
const TAG: string = 'ProfilePage';

/** 顶部让出标题栏（与首页同一个数），底部让出悬浮 tab 栏。 */
const PROFILE_TOP_OFFSET: number = 94;
const PROFILE_BOTTOM_OFFSET: number = 96;
/**
 * 重新进入这一页时，数据多新就不重复拉（毫秒）。
 *
 * 一分钟内进过就用手上的数据（见 ProfileViewModel.loadIfStale）：省一次原生往返，也不会
 * 和"恢复滚动位置"抢时间。用户下拉刷新时照旧一定拉。
 */
const PROFILE_FRESH_MS: number = 60 * 1000;
/**
 * 距上次滚动多久之内算"用户还在滑"（毫秒，见 askMore 的第一道闸）。
 *
 * 1.2 秒：手指离开后惯性还会滚一会儿，滑到底连拉几页是正常的；停下来之后就不再自动翻，
 * 免得列表自己一路长下去。
 */
const ASK_MORE_IDLE_MS: number = 1200;
/** 列表还没这么多条时允许自动翻页（一屏左右，见 askMore）：短列表要自己补满。 */
const AUTO_MORE_MIN_POSTS: number = 12;
/**
 * 帖子页"再拉一页"时的轮询间隔与等待上限（毫秒，见 makeStreamLoader）。
 *
 * 间隔 150ms：翻页本身几百毫秒起，这个粒度足够跟上、又不会空转太多次；上限 8 秒是为了
 * "网络卡住时帖子页别一直转圈"——超时就把当前这份还回去，调用方按"长度没变"收手。
 */
const STREAM_LOAD_POLL_MS: number = 150;
const STREAM_LOAD_TIMEOUT_MS: number = 8000;
/** 催一页最多催几次（见 pumpStream：第一轮可能被网格占着，要再催）。 */
const STREAM_LOAD_TRIES: number = 2;
/**
 * 别人主页"关注 / 发消息"那一行：两颗按钮的高度与中间间距（vp）。
 *
 * 高度和全 app 的材质按钮对齐（40，见 MaterialSurface 的 MATERIAL_PILL_HEIGHT）；
 * 间距 8 让两颗并排看着是一组。宽度由 followButtonWidth() 算 —— 保证
 * "两颗 + 间距"正好等于分段按钮那条胶囊的宽度（需求）。
 */
const FOLLOW_BUTTON_HEIGHT: number = 40;
const FOLLOW_GAP: number = 8;
/** 头像直径（vp）。 */
const AVATAR_SIZE: number = 88;
/** 精选快拍那一排：和主页快拍托盘同一套尺寸（头像 / 环 / 文字 / 每格宽度）。 */
const HIGHLIGHT_SIZE: number = 80;
const HIGHLIGHT_RING_GAP: number = 3;
const HIGHLIGHT_RING_W: number = 2.5;
const HIGHLIGHT_LABEL_W: number = 106;
/** 横幅区胶囊的高度，以及它四周要留的"呼吸位"（材质按下/拖拽会形变，贴着边会被裁）。 */
const CHIP_HEIGHT_VP: number = 28;
/** 左右各留 16（= 简介的左边）。 */
const CHIP_SIDE_VP: number = 16;
/**
 * 胶囊行的**上内边距**：容器紧贴简介，靠这段 padding 把按钮往下推。
 *
 * 为什么要这么多：材质按下/拖拽时"交互形变"会往上长出去，容器（Scroll）自己会裁掉
 * 超出视口的那一条 —— 顶部留白给够（这里 14vp），按钮就永远在视口里面，不会被裁。
 */
const CHIP_TOP_VP: number = 14;
const CHIP_BOTTOM_VP: number = 8;
/** 头部那块 Column 的行距（横幅区要用负 margin 抵掉它，见 bannerChips）。 */
const HEADER_ROW_GAP_VP: number = 12;
/**
 * 名字左边要空出多少（vp）—— 让它和「帖子」那一列文字左对齐。
 *
 * 计数是三等分、文字居中，所以"帖子"比格子左边多出 `(格宽 − 文字宽) / 2`。
 * 这里按屏宽现算（见 nameIndentVp），不再写死：换屏宽、改头像尺寸都会自动跟上。
 */
const STAT_LABEL_W_VP: number = 26;
const STAT_PAGE_SIDE_VP: number = 32;
const STAT_AVATAR_GAP_VP: number = 16;
/** 网格列数与间距（vp）。 */
const GRID_COLUMNS: number = 3;
const GRID_GAP: number = 2;
/**
 * 格子高宽比（宽 : 高 = 4 : 5）。
 *
 * 用固定比例而不是按每条真实宽高比：网格要对齐，长短不一会参差不齐；IG 自己也统一裁切。
 */
const GRID_ASPECT: number = 1.25;
/** 量不到屏幕宽度时的兜底（vp）。 */
const FALLBACK_WIDTH_VP: number = 360;
/**
 * 分段按钮那一块的总高（vp）= 胶囊高 + 组件自己的上下内边距（8 + 12）。
 *
 * 用途：列表里那条"未钉住"的占位高度、以及算"末尾要补多高"（见 tailSpacerVp）。
 * 页面里那条与标题栏里那条**同高**，钉住前后列表才不会跳一下。
 */
const SEGMENT_BLOCK_HEIGHT: number = 60;
/**
 * 触底翻页的**提前量**（行）：末尾还剩这么多行没露出来就去拉下一页。
 *
 * 一行 3 格，2 行就是 6 条 —— 和搜索页瀑布流那个提前量同量级（官方《创建瀑布流》
 * "提前新增数据"那节的做法：等真到底了再拉，用户会先看到一次停顿）。
 */
const PROFILE_LOAD_AHEAD: number = 2;
/**
 * 分段按钮从页面交到标题栏（以及交回来）的时长（毫秒）。
 *
 * 两条宿主是两棵子树，没法做真正的共享元素转场，能做的是**原地交叉淡入淡出**
 * （两条的落点完全重合，见 inFlowSegmentBar 的说明）。时长取 180：短到不拖沓，
 * 又比一帧长得多，看不出切换。
 */
const BAR_HANDOFF_MS: number = 180;
/**
 * 钉住的判定余量（vp）：外层偏移到"个人信息高 − 这个数"就算钉住。
 *
 * 外层的可滚范围**就是**个人信息的高度（内容高 = 视口 + 头部，见 profileList 的说明），
 * 所以这里留一点余量只是吃掉取整误差，保证"一定滑得到、抬得上去"。
 */
const PIN_SLACK_VP: number = 16;

/**
 * 网格的**行数据源**（`LazyForEach` 要的 `IDataSource`）。
 *
 * 一条"数据"= 一行（最多 GRID_COLUMNS 个格子）。为什么要自己实现：官方对长列表/网格一贯的
 * 建议是 `LazyForEach`（只建可见的那几行），而 `ForEach` 会把三十几条帖子全建出来 ——
 * 三十几个 `Image` 同时开始下封面，首屏自然慢（这正是"封面加载太慢"的另一半原因，
 * 另一半是封面档位，见 core/NativeProfile 的 COVER_WIDTH）。
 *
 * 换数据时要**通知框架**（`onDataReloaded`），否则节点会复用旧数据、网格和图对不上。
 */
class ProfileRowSource implements IDataSource {
  private rows: Array<Array<ProfilePost>> = [];
  private listeners: Array<DataChangeListener> = [];
  /**
   * 代次：**列表头变了**（切分页、收藏后刷新后新帖子排到了最前面）+1，并拼进 LazyForEach 的键。
   *
   * 为什么要有它：用户报过"我的页面收藏第一排直接被刚收藏的帖子/视频那一排覆盖" ——
   * 真机现象就是**第一行没有跟着换数据**（下面是新数据、第一行还是上一段的图）。键里带上代次
   * 之后，头一变**每一行的键都变**，框架没有任何复用旧节点的余地，整块网格一定按新数据重建。
   * 只有"头变了"才 +1（翻页是往尾部追加，头没变，那一页不该让整块网格重建）。
   */
  private generation: number = 0;

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): Array<ProfilePost> {
    return this.rows[index];
  }

  /** 当前代次（拼进键用，见 generation 的说明）。 */
  gen(): number {
    return this.generation;
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /** 换一批帖子：切分页、翻页、刷新都走这里。 */
  apply(posts: Array<ProfilePost>): void {
    const rows: Array<Array<ProfilePost>> = [];
    for (let index: number = 0; index < posts.length; index += GRID_COLUMNS) {
      rows.push(posts.slice(index, index + GRID_COLUMNS));
    }
    // 头变了（第一条不是原来那条）= 换了一整份内容：代次 +1（见 generation）。
    const headBefore: string = this.rows.length > 0 && this.rows[0].length > 0
      ? this.rows[0][0].shortcode : '';
    const headAfter: string = rows.length > 0 && rows[0].length > 0 ? rows[0][0].shortcode : '';
    if (headBefore !== headAfter) {
      this.generation++;
    }
    this.rows = rows;
    for (let at: number = 0; at < this.listeners.length; at++) {
      this.listeners[at].onDataReloaded();
    }
  }
}

@Component
export struct ProfilePage {
  /**
   * 视图模型：**普通属性**，不用 @ObjectLink。
   *
   * 页面自己用 @State 存显示用的数据（回调里赋值），所以这里不需要观察能力；
   * 用 @ObjectLink 反而要求它被 @Observed 包起来、还要求父组件用状态变量持有。
   */
  vm: ProfileViewModel = new ProfileViewModel();
  /**
   * 分段按钮的图标组（本人的四段 / 别人主页的三段，见 ProfileSegmentBar 的 SEGMENT_MODE_*）。
   *
   * 段数本身从视图模型读（`vm.segmentCount()`）—— 别人主页没有"收藏"那一段，顺序也由它给。
   */
  @Prop segmentMode: string = SEGMENT_MODE_SELF;
  /** 点一个格子：交给页面打开那条帖子。 */
  onOpen: (post: ProfilePost) => void = (post: ProfilePost): void => {
  };
  /**
   * 点一个格子 → 打开**帖子页**（需求："该页面会将当前分页所有帖子整理成 feeds 流，
   * 点进帖子会定位到帖子在 feeds 流的位置"）。
   *
   * 参数给的是"这一分页目前的全部帖子 + 点到的那一条在里面的下标"，外加一个
   * **继续翻页的入口**（帖子页触底时用，见 ProfilePage.makeStreamLoader）：
   * 有了它，帖子页就不必等网格先把后面几页翻完 —— 它自己滑到底就能接着加载
   * （用户报的"要在分页加载帖子后帖子页面才会显示"就是这么修的）。
   */
  onOpenStream: (posts: Array<MediaPost>, index: number,
                  loadMore: () => Promise<ProfileStreamPage>) => void =
    (posts: Array<MediaPost>, index: number,
     loadMore: () => Promise<ProfileStreamPage>): void => {
    };
  /**
   * 点**视频分页**里的格子：开 Reels 页（需求："用户和我的页面的视频分页点进去是新的页面，
   * 采用 reels 模板"，见 pages/Index 的 PROFILE_REELS_PAGE）。
   *
   * 和 onOpenStream 的区别只有"点的是哪一段"：帖子 / 收藏 / 被提及那几段照旧进帖子页，
   * **视频那一段**进 Reels 页（一条一条竖着刷、只播当前那条）。
   *
   * 参数是"这一分页目前的全部帖子 + 点到那一条的 shortcode + 有没有下一页 + 继续翻页的入口"。
   * 这里传 shortcode 而不是下标：Reels 那份会**滤掉没有视频地址的条目**，下标会对不上。
   *
   * 宿主没接这条回调时退回 onOpenStream（老行为是帖子页），不要留给用户"点了没反应"。
   */
  onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                loadMore: () => Promise<ProfileStreamPage>) => void =
    (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
     loadMore: () => Promise<ProfileStreamPage>): void => {
      for (let index: number = 0; index < posts.length; index++) {
        if (posts[index].shortcode === shortcode) {
          this.onOpenStream(posts, index, loadMore);
          return;
        }
      }
    };
  @State private header: ProfileHeader | null = null;
  /** 精选快拍（高光）那排的数据（见 ProfileViewModel.loadHighlights）。 */
  @State private highlights: Array<ProfileHighlight> = [];
  /** 背景音乐在不在播（横幅区那颗音乐胶囊的播放/暂停图标看它）。 */
  @State private musicPlaying: boolean = false;
  /** 背景音乐的播放器（首次播放时才创建，见 toggleMusic）。 */
  private audio: media.AVPlayer | null = null;
  /** 播放器正在创建（防连点创建出两个）。 */
  private audioOpening: boolean = false;
  @State private posts: Array<ProfilePost> = [];
  @State private busy: boolean = false;
  @State private status: string = '';
  @State private refreshing: boolean = false;
  @State private hasMore: boolean = true;
  @State private screenWidthVp: number = FALLBACK_WIDTH_VP;
  /** 当前分页（见 PROFILE_TAB_*，和分段按钮的四段一一对应）。 */
  @State private tab: number = 0;
  /**
   * 分段按钮**钉住了没有**（见文件头）。
   *
   * 判据：滚动偏移 ≥ 个人信息那一块的高度（量出来的，见 headerBlockVp）—— 也就是
   * "分段按钮已经顶到列表可视区顶边（HDS 标题栏正下方）"。钉住之后列表里那条只留高度不画，
   * 由标题栏那条顶上（两条同高，所以不会跳）。
   */
  @State private barPinned: boolean = false;
  /**
   * **本机有没有关注这一页的用户**（别人主页那一行的「关注 / 已关注」按钮）。
   *
   * 初值来自头部（`followedByViewer`）+ 本地覆盖表（`FollowState`，本地点过的以本地为准），
   * 点按后自己更新（见 tapFollowUser）。
   */
  @State private following: boolean = false;
  /**
   * 关注状态的**全局版本号**（见 core/FollowState 的文件头"全局刷新"）。
   *
   * 这一页自己点的关注当然会就地更新，但**别处**点的（首页那张卡、通知页那颗「回关」、
   * 帖子页标题栏那颗）也得让这一页跟着变 —— 否则从首页关注完再进这一页，看到的还是旧状态。
   * 变了就按覆盖表重算（判据和 syncFromVm 里那条完全一样）。
   *
   * 值本身不用（读了就够），要的是 @Watch 这一次回调。
   */
  @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
  /** 别处改了关注状态：把这一页那颗按钮按覆盖表重算（见 following 的说明）。 */
  private onFollowVersion(): void {
    if (this.isSelfPage()) {
      // 自己的主页没有那一行，不用管。
      return;
    }
    const header: ProfileHeader | null = this.vm.headerNow();
    const fallback: boolean = header === null ? this.following : header.followedByViewer;
    const name: string = header === null ? this.vm.targetName() : header.username;
    const known: boolean = FollowState.resolve(this.vm.targetId(),
      FollowState.resolveName(name, fallback));
    if (this.following !== known) {
      this.following = known;
      hilog.info(DOMAIN, TAG, 'PF follow refresh → %{public}s', known ? 'y' : 'n');
    }
  }
  /** 关注请求进行中：防连点（同一个按钮连点两下会发两次请求）。 */
  private followBusy: boolean = false;
  /** 别人主页的**关注 / 发消息**那一行：点关注/取关（由宿主发请求，见 pages/Index.followUser）。 */
  onFollowUser: (follow: boolean) => Promise<boolean> =
    (follow: boolean): Promise<boolean> => Promise.resolve(false);
  /**
   * 点简介里的 `@账号`：请宿主打开那个人的主页（需求："点击后进入该用户主页"）。
   *
   * 由 pages/Index 接到 `openUserProfile` 上；宿主没接时点了只记日志。
   */
  onOpenUser: (username: string) => void = (username: string): void => {
  };
  /** 个人信息那一块的高度（vp，量出来的）：钉住的判据就是它。 */
  private headerBlockVp: number = 0;
  /** 屏幕高度（vp）：算"末尾补高"要用（见 tailSpacerVp）。 */
  private screenHeightVp: number = 0;
  /** 外层滚动（头部 + 分段按钮）的控制器。 */
  private readonly pageScroller: Scroller = new Scroller();
  /** 内层滚动（当前分页内容）的控制器。 */
  private readonly listScroller: Scroller = new Scroller();
  /**
   * 有待恢复的**内层**滚动位置（vp，<0 = 没有）。
   *
   * 需求："固定后切换分页不会被影响位置" —— 外层偏移（分段按钮的位置）不因切页而改，
   * 每个分页只记自己那份内层偏移，切回来时恢复它（见 vm.onTab / restoreScroll）。
   *
   * 位置本身存在**视图模型**里（见 ProfileViewModel.rememberOffset）：页面会跟着 tab 重建，
   * 存页面里一律归零（用户报的"切回来选中态跳回第一项、位置回到顶部"就是它）。
   *
   * 为什么要"待"：切到没缓存的分页时内容还没到（异步），那一刻滚下去会被夹回顶部，
   * 所以先记着，等内容到位（onPosts）或下一帧再滚一次。
   */
  private pendingOffset: number = -1;
  /**
   * 有待恢复的**外层**滚动位置（vp，<0 = 没有，见 aboutToAppear）。
   *
   * 外层管的是"个人信息滚上去多少、分段按钮钉住了没有"。不做这一步，切回来页面就回到顶部。
   */
  private pendingOuter: number = -1;
  /** 内层最近一次滚动是什么时候（毫秒，见 askMore 的第一道闸）。 */
  private lastScrollMs: number = 0;
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

  /**
   * 「横幅区」那三颗胶囊（需求：Meta 旗下软件的"软件图标 + 用户名称" / 音乐 / 添加）。
   *
   * 全部走 `MaterialChipButton`（沉浸光感：透明 Toggle 承载材质 + 图标/文字内容）。
   * 音乐那颗点一下播放/暂停（见 toggleMusic）；另外两颗按需求**先不接功能**。
   */
  @Builder
  bannerChips() {
    Scroll() {
      /*
       * 左右各 16vp：**第一颗胶囊的左边和简介文字对齐**（简介那行也在这 16 的位置）。
       * 上下只留一点（需求："顶部留白太多，缩小一点"）—— 竖直方向材质形变小，
       * 留一点就够它不贴边。
       */
      Row({ space: 8 }) {
        // ① 主页 / Meta 软件：图标 + 用户名称（这里用账号名，点它先不接功能）。
        MaterialChipButton({
          symbol: $r('sys.symbol.at'),
          labelText: this.chipName(),
          onTap: (): void => {
            hilog.info(DOMAIN, TAG, 'PF chip profile tap (not wired)');
          }
        })
        // ② 音乐：标题 + 播放/暂停（有歌才画，见 header.music）。
        if (this.header !== null && this.header.music !== null) {
          MaterialChipButton({
            symbol: $r('sys.symbol.music'),
            labelText: this.musicLabel(),
            trailing: this.musicPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'),
            onTap: (): void => {
              this.toggleMusic();
            }
          })
        }
        // ③ 添加（先不接功能）。
        MaterialChipButton({
          symbol: $r('sys.symbol.plus'),
          labelRes: $r('app.string.profile_chip_add'),
          onTap: (): void => {
            hilog.info(DOMAIN, TAG, 'PF chip add tap (not wired)');
          }
        })
      }
      .padding({ top: CHIP_TOP_VP, bottom: CHIP_BOTTOM_VP, left: CHIP_SIDE_VP, right: CHIP_SIDE_VP })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .height(CHIP_HEIGHT_VP + CHIP_TOP_VP + CHIP_BOTTOM_VP)
    .align(Alignment.Start)
    /*
     * **抵掉外层那 16 的内边距**：Scroll 自己铺满整屏（宽 = 屏宽、左边 -16 抵掉内边距），
     * 这样第一颗胶囊从 16 开始（**和简介文字左对齐**），它往左形变时仍有 16vp 的空间可用，
     * 不会贴着 Scroll 视口被裁。
     *
     * 上边再 `-HEADER_ROW_GAP_VP`：让容器**紧贴简介**（抵掉头部 Column 的行距），
     * 按钮的下移完全交给内容行的 `padding.top`（CHIP_TOP_VP）—— 这样视口上沿就在简介
     * 下面一点点，按钮离上沿有整整 14vp，形变永远不会被裁。
     */
    .margin({
      left: -CHIP_SIDE_VP,
      right: -CHIP_SIDE_VP,
      top: -HEADER_ROW_GAP_VP
    })
    .width(this.screenWidthVp)
  }

  /**
   * 「功能区」：编辑主页 / 分享主页（椭圆按钮）+ 推荐关注（圆形按钮）。
   *
   * 需求明确"先不用做功能"，所以只做外观；三颗都用沉浸光感组件
   * （`MaterialLabelButton` / `MaterialIconButton`，见 components/MaterialSurface）。
   */
  @Builder
  actionRow() {
    Row({ space: 8 }) {
      Row() {
        MaterialLabelButton({
          labelRes: $r('app.string.profile_action_edit'),
          fullWidth: true,
          fontSize: 14,
          pillHeight: 36,
          onTap: (): void => {
            hilog.info(DOMAIN, TAG, 'PF edit profile tap (not wired)');
          }
        })
      }
      .layoutWeight(1)

      Row() {
        MaterialLabelButton({
          labelRes: $r('app.string.profile_action_share'),
          fullWidth: true,
          fontSize: 14,
          pillHeight: 36,
          onTap: (): void => {
            hilog.info(DOMAIN, TAG, 'PF share profile tap (not wired)');
          }
        })
      }
      .layoutWeight(1)

      MaterialIconButton({
        symbol: $r('sys.symbol.person_badge_plus'),
        buttonSize: 36,
        iconSize: 18,
        onTap: (on: boolean): void => {
          hilog.info(DOMAIN, TAG, 'PF suggest follow tap (not wired)');
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 「精选快拍」区：一颗「+ 新」+ 每个高光一颗圆图 + 标题（版式照参考图）。
   *
   * 数据来自 `highlights_tray/<pk>/`（见 ProfileViewModel.loadHighlights）；拿不到就只剩
   * 「+ 新」那一颗 —— 和 Instagram 上新号看到的一样。
   */
  @Builder
  highlightsRow() {
    Scroll() {
      Row({ space: 0 }) {
        // 「+ 新」：和托盘里"你的快拍"同一种画法（大圆 + 细环 + 11sp 小字）。
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width(HIGHLIGHT_SIZE + HIGHLIGHT_RING_GAP * 2)
              .height(HIGHLIGHT_SIZE + HIGHLIGHT_RING_GAP * 2)
              .borderRadius((HIGHLIGHT_SIZE + HIGHLIGHT_RING_GAP * 2) / 2)
              .border({ width: HIGHLIGHT_RING_W, color: $r('app.color.divider') })
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(26)
              .fontColor([$r('app.color.primary_text')])
          }
          .width(HIGHLIGHT_SIZE + (HIGHLIGHT_RING_GAP + HIGHLIGHT_RING_W) * 2)
          .height(HIGHLIGHT_SIZE + (HIGHLIGHT_RING_GAP + HIGHLIGHT_RING_W) * 2)
          Text($r('app.string.profile_highlight_new'))
            .fontSize(11)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
        }
        .width(HIGHLIGHT_LABEL_W)
        .onClick((): void => {
          hilog.info(DOMAIN, TAG, 'PF highlight new tap (not wired)');
        })

        ForEach(this.highlights, (one: ProfileHighlight): void => {
          Column({ space: 6 }) {
            Stack({ alignContent: Alignment.Center }) {
              Column()
                .width(HIGHLIGHT_SIZE + HIGHLIGHT_RING_GAP * 2)
                .height(HIGHLIGHT_SIZE + HIGHLIGHT_RING_GAP * 2)
                .borderRadius((HIGHLIGHT_SIZE + HIGHLIGHT_RING_GAP * 2) / 2)
                .border({ width: HIGHLIGHT_RING_W, color: $r('app.color.divider') })
              Image(one.coverUrl.length > 0 ? one.coverUrl : $r('app.media.startIcon'))
                .draggable(false)
                .width(HIGHLIGHT_SIZE)
                .height(HIGHLIGHT_SIZE)
                .borderRadius(HIGHLIGHT_SIZE / 2)
                .objectFit(ImageFit.Cover)
                .backgroundColor($r('app.color.field_background'))
                .border({ width: 2, color: $r('app.color.page_background') })
            }
            .width(HIGHLIGHT_SIZE + (HIGHLIGHT_RING_GAP + HIGHLIGHT_RING_W) * 2)
            .height(HIGHLIGHT_SIZE + (HIGHLIGHT_RING_GAP + HIGHLIGHT_RING_W) * 2)
            Text(one.title.length > 0 ? one.title : ' ')
              .fontSize(11)
              .fontColor($r('app.color.primary_text'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width(HIGHLIGHT_LABEL_W - 8)
          }
          .width(HIGHLIGHT_LABEL_W)
          .onClick((): void => {
            hilog.info(DOMAIN, TAG, 'PF highlight tap id=%{public}s (not wired)', one.id);
          })
        }, (one: ProfileHighlight): string => one.id)
      }
      /*
       * 左右各 16vp 的**内容**留白（需求："把 margin 取消，改用 padding left right 16"）：
       * Scroll 本身满屏宽，所以滑起来头像可以穿出屏幕边；第一颗从这里 16vp 开始。
       */
      .padding({ top: 2, bottom: 2, left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(HIGHLIGHT_SIZE + (HIGHLIGHT_RING_GAP + HIGHLIGHT_RING_W) * 2 + 28)
    .align(Alignment.Start)
  }

  /**
   * 简介：把 `@账号` 变成超链接（需求："检测文本里的 @ 号…动态转换为超链接，
   * 点击后进入该用户主页"）。
   *
   * 做法：切成"文字 / @提及"片段，逐段挂 `Span`（`Span` 继承 `CommonMethod`，所以它能挂
   * `onClick`，也不会影响整段文字自动换行）；提及用强调色 + 下划线，点了交给宿主开主页。
   */
  @Builder
  bioText() {
    Text() {
      ForEach(this.bioSegments(), (seg: BioSegment, index: number): void => {
        if (seg.mention) {
          Span(`@${seg.text}`)
            .fontColor($r('app.color.accent'))
            .onClick((): void => {
              hilog.info(DOMAIN, TAG, 'PF mention tap @%{public}s', seg.text);
              this.onOpenUser(seg.text);
            })
        } else {
          Span(seg.text)
            .fontColor($r('app.color.primary_text'))
        }
      }, (seg: BioSegment, index: number): string => `${index}-${seg.text}`)
    }
    .fontSize(13)
    .width('100%')
  }

  /** 简介切好的片段（见 model/Profile 的 splitMentions）。 */
  private bioSegments(): Array<BioSegment> {
    return splitMentions(this.header === null ? '' : this.header.bio);
  }

  /** 横幅区第一颗胶囊的文字：账号名（没有就给空串，胶囊里只剩图标）。 */
  private chipName(): string {
    return this.header === null ? '' : this.header.username;
  }

  /**
   * 名字的左侧缩进（vp）：让它的左沿和下面「帖子」两个字对齐。
   *
   * 列宽 = 屏宽 − 左右留白 − 头像 − 头像与文字的间距；每个计数格是列宽的三分之一，
   * 文字居中 → 比格子左边多出 `(格宽 − 文字宽) / 2`。
   */
  private nameIndentVp(): number {
    const column: number = this.screenWidthVp - STAT_PAGE_SIDE_VP - AVATAR_SIZE
      - STAT_AVATAR_GAP_VP;
    if (column <= 0) {
      return 0;
    }
    const cell: number = column / 3;
    const indent: number = (cell - STAT_LABEL_W_VP) / 2;
    return indent > 0 ? indent : 0;
  }

  /** 音乐胶囊的文字：`歌名 · 演唱者`（演唱者没有就只给歌名）。 */
  private musicLabel(): string {
    if (this.header === null || this.header.music === null) {
      return '';
    }
    const music = this.header.music;
    return music.subtitle.length > 0 ? `${music.title} · ${music.subtitle}` : music.title;
  }

  /**
   * 音乐胶囊的播放 / 暂停（需求："音乐要做播放功能，点击暂停/播放"）。
   *
   * 播放器按需创建（AVPlayer + url，不需要 surface）；没有可播地址时只记一行日志 ——
   * IG 有的账号只挂了"这首歌"的元数据、没给音频直链，这时界面上不该假装在播。
   */
  private async toggleMusic(): Promise<void> {
    if (this.header === null || this.header.music === null) {
      return;
    }
    const music = this.header.music;
    if (!music.canPlay()) {
      hilog.info(DOMAIN, TAG, 'PF music has no audio url title=%{public}s', music.title);
      return;
    }
    const player: media.AVPlayer | null = await this.ensureAudio(music.url);
    if (player === null) {
      return;
    }
    try {
      if (this.musicPlaying) {
        await player.pause();
        this.musicPlaying = false;
        hilog.info(DOMAIN, TAG, 'PF music pause');
      } else {
        await player.play();
        this.musicPlaying = true;
        hilog.info(DOMAIN, TAG, 'PF music play url=%{public}s',
          music.url.substring(0, 40));
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'PF music toggle failed: %{public}s', (error as Error).message);
      this.musicPlaying = false;
    }
  }

  /** 拿到（必要时创建）音频播放器；失败给 null。 */
  private async ensureAudio(url: string): Promise<media.AVPlayer | null> {
    if (this.audio !== null) {
      return this.audio;
    }
    if (this.audioOpening) {
      return null;
    }
    this.audioOpening = true;
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      player.on('stateChange', (state: media.AVPlayerState): void => {
        // 播完了把图标切回"播放"（否则会一直显示暂停）。
        if (state === 'completed') {
          this.musicPlaying = false;
        }
      });
      player.url = url;
      this.audio = player;
      hilog.info(DOMAIN, TAG, 'PF audio ready');
      return player;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'PF audio create failed: %{public}s', (error as Error).message);
      return null;
    } finally {
      this.audioOpening = false;
    }
  }

  /** 页面销毁：把播放器放掉（不停会继续出声）。 */
  private releaseAudio(): void {
    const player: media.AVPlayer | null = this.audio;
    this.audio = null;
    this.musicPlaying = false;
    if (player === null) {
      return;
    }
    player.release().catch((): void => {
    });
  }

  aboutToDisappear(): void {
    this.releaseAudio();
  }

  aboutToAppear(): void {
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(dsp.width);
      this.screenHeightVp = this.getUIContext().px2vp(dsp.height);
    } catch (error) {
      this.screenWidthVp = FALLBACK_WIDTH_VP;
      this.screenHeightVp = 0;
    }
    /*
     * **先把"上次停在哪"接回来**。
     *
     * 切到别的分页再切回来时，这个组件是**重建**的（页面里的 @State 一律归零）：不接回来就会
     * 出现用户报的那一组症状 —— 分段按钮的选中态跳回第一项，内容却还是视图模型里那一页
     * （它一直活着），页面也回到了顶部。
     * 所以：当前分页、每个分页的内层位置、外层的滚动位置都从视图模型读回来（见 ProfileViewModel
     * 的 offsetOf / outerNow）。
     */
    this.tab = this.vm.tabNow();
    this.pendingOffset = this.vm.offsetOf(this.tab);
    this.pendingOuter = this.vm.outerNow();
    hilog.info(DOMAIN, TAG, 'PF enter tab=%{public}d inner=%{public}d outer=%{public}d',
      this.tab, this.pendingOffset, this.pendingOuter);
    this.vm.onHeader = (header: ProfileHeader): void => {
      this.header = header;
      // 头部到了：关注状态也一起校准（见 syncFromVm）。
      this.following = FollowState.resolve(
        this.vm.targetId(), FollowState.resolveName(header.username, header.followedByViewer));
    };
    this.vm.onPosts = (posts: Array<ProfilePost>, hasMore: boolean): void => {
      this.posts = posts;
      // 行数据源也要换：LazyForEach 只认数据源，不认这个 @State（@State 只用来判断"空不空"）。
      this.rowSource.apply(posts);
      this.hasMore = hasMore;
      // 内容到位了：把切页时记下的滚动位置补上（见 pendingOffset 的说明）。
      this.restoreScroll();
    };
    this.vm.onBusy = (busy: boolean): void => {
      this.busy = busy;
    };
    this.vm.onStatus = (text: string): void => {
      this.status = text;
    };
    // 精选快拍（高光）到了：那一排跟着长出来（拿不到就一直是空的，只留「+ 新」）。
    this.vm.onHighlights = (items: Array<ProfileHighlight>): void => {
      this.highlights = items;
    };
    this.highlights = this.vm.highlightsNow();
    /*
     * 分页变了：这里做**唯一的**切页记账，然后广播给标题栏那条分段按钮。
     *
     * 为什么记账放在回调里而不是 selectTab 里：切页有两个入口 —— 页面里那条（未钉住）和
     * **标题栏里那条**（钉住后，见 pages/Index 的 pinnedProfileBar）。后者直接调
     * `profileVm.setTab`，走不到 ProfilePage 的方法；只有把记账挂在视图模型回调上，
     * 两个入口才会做同一套事（记老分页的滚动位置、恢复新分页的位置）。
     */
    this.vm.onTab = (tab: number): void => {
      if (tab !== this.tab) {
        // 只记/恢复**内层**的位置：外层（分段按钮的位置）不因切页而变（需求）。
        this.vm.rememberOffset(this.tab, this.listScroller.currentOffset().yOffset);
        this.tab = tab;
        this.pendingOffset = this.vm.offsetOf(tab);
        // 换了内容、也换了滚动容器：把底栏动画那份增量记账清零，免得跨容器算出一个假增量。
        this.scrollDelta.reset();
        this.restoreScroll();
      }
      // 标题栏那条读这份全局事实来画选中态（见 AppSettings 的 PROFILE_TAB）。
      AppStorage.setOrCreate(PROFILE_TAB, tab);
    };
    // 先把视图模型里已有的数据回填进来：切 tab 会**重建**这个组件，而取数结果留在
    // 视图模型里（它一直在）；不回填的话，重新进入页面时会先看到 0 计数/空网格。
    this.syncFromVm();
    // 分页号也先广播一次：标题栏那条（钉住时显示）要按它画选中态。
    AppStorage.setOrCreate(PROFILE_TAB, this.tab);
    // 外层的滚动位置（分段按钮钉住到哪儿）也接回来 —— 头部那一块已经渲染出来了，
    // 下一帧再落实一次（量完高度才滚得动，见 restoreOuter）。
    this.restoreOuter();
    // 再拉一次，保证计数与首屏是最新的（有模板时是毫秒级回放）。
    // **够新就不拉**（见 loadIfStale）：每次切回来都发一轮请求既没必要，还会和"恢复滚动
    // 位置"抢时间（真机上就是它把刚恢复的位置顶掉的）。下拉刷新那条路不受影响。
    // **完成后从视图模型回读一次**：回调是绑在"当时那个组件实例"上的，实例一旦被
    // 切 tab 销毁，回调里的 @State 赋值就落空（实测就是计数一直显示 0）。
    this.vm.loadIfStale(PROFILE_FRESH_MS)
      .then((): void => {
        this.syncFromVm();
      })
      .catch((): void => {
      });
  }

  /** 从视图模型回读当前数据（唯一的数据出口，避免依赖回调时序）。 */
  /**
   * 状态行要显示的内容。
   *
   * 只有两句"正常态"被过滤掉（`已加载` / `这个分页还没有内容`）：
   * 前者没有信息量，后者内容区自己就有"还没有帖子"的空态图。
   * 其余（正在抓模板 / 被限流还有几分钟 / 读取失败 + native、replay 诊断）**原样显示** ——
   * 它是这个页面唯一的排查通道（hilog 在真机上常被 chromium 刷掉）。
   */
  private visibleStatus(): string {
    const text: string = this.status;
    if (text === '已加载' || text === '这个分页还没有内容') {
      return '';
    }
    return text;
  }

  private syncFromVm(): void {
    const header: ProfileHeader | null = this.vm.headerNow();
    if (header !== null) {
      this.header = header;
      // 关注状态跟着头部更新（本地覆盖表优先：本地点过的以本地为准，别被旧快照顶回去）。
      this.following = FollowState.resolve(
        this.vm.targetId(), FollowState.resolveName(header.username, header.followedByViewer));
    }
    const posts: Array<ProfilePost> = this.vm.postsNow();
    this.posts = posts;
    this.rowSource.apply(posts);
    this.hasMore = this.vm.hasMore();
    this.busy = this.vm.isBusy();
  }

  /**
   * 内层网格的**行数据源**（`LazyForEach` 要的 `IDataSource`）。
   *
   * 为什么必须懒加载：原来这里是 `ForEach(this.rows(), …)` —— **所有行一次性建出来**，
   * 三十几条帖子就是三十几个 `Image` 节点同时开始下封面，"用户主页/我的页封面加载太慢"
   * 有一半是它（另一半是封面档位，见 core/NativeProfile 的 COVER_WIDTH）。懒加载之后
   * 只有可见的那几行（约两三屏）会去拉图，首屏自然就快了。
   */
  private readonly rowSource: ProfileRowSource = new ProfileRowSource();

  /** 格子宽度：等分屏宽（减去间隔），这样最后一行不满也不会被拉宽。 */
  private cellWidth(): number {
    const total: number = this.screenWidthVp - GRID_GAP * (GRID_COLUMNS - 1);
    return total > 0 ? total / GRID_COLUMNS : 0;
  }

  /**
   * 这一格要不要画播放标记。
   *
   * 判据两条：载荷自己说是视频（`isVideo`），**或者封面位上是 mp4** —— 后者其实也是视频，
   * 只是收藏 / 视频那两段的载荷偶尔没给对 `video` 标志（见 ProfilePost.hasUsableCover）。
   */
  private cellShowsPlay(post: ProfilePost): boolean {
    if (post.isVideo) {
      return true;
    }
    return post.coverUrl.length > 0 && !post.hasUsableCover();
  }

  /** 计数文案：上万折成"x.x万"（和 IG 中文版一致）。 */
  private countText(value: number): string {
    if (value >= 10000) {
      return `${Math.floor(value / 1000) / 10}万`;
    }
    return `${value}`;
  }

  /** 三项计数的取值：**在 builder 内部读**，不要按值传进来（见 statCell 的说明）。 */
  private statValue(which: number): number {
    if (this.header === null) {
      return 0;
    }
    if (which === 0) {
      return this.header.posts;
    }
    if (which === 1) {
      return this.header.followers;
    }
    return this.header.following;
  }

  /**
   * 一项计数。
   *
   * 参数只传"第几项"（常量），**数值在 builder 内部从状态里读** —— @Builder 的按值参数
   * 不参与状态观察：把 `this.header.posts` 按值传进来，header 后到（首次取数回来）时
   * 这个格子不会重绘，界面就永远显示 0（实测踩过，和占位页那次是同一个坑）。
   */
  @Builder
  statCell(which: number, label: Resource) {
    Column({ space: 2 }) {
      Text(this.countText(this.statValue(which)))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
    }
    .layoutWeight(1)
  }

  /**
   * **未钉住时**那条分段按钮：跟在个人信息下面，随列表一起滚（本体见 ProfileSegmentBar）。
   *
   * 三件事：
   *   1. **钉住前后都留在布局里**（钉住时只把透明度补间到 0）—— 直接 `if` 掉会和标题栏
   *      那条一进一出变成"硬切"，用户看着就是"转换动画不流畅"（需求）；
   *   2. `.zIndex(2)`：初态就抬到这一层的**最上面**，滚动时网格里的图不会盖过它
   *      （需求："将分段按钮初始 z 轴抬至最顶层"）；
   *   3. 钉住后 `hitTestBehavior(None)`：那会儿它已经透明，别继续吃触摸（否则手指点在
   *      看不见的它身上，看起来就是"点了没反应"）。
   *
   * 为什么不会出现"两条同时看得见"：分段按钮顶到列表可视区顶边的那一刻，它的位置正好是
   * 钉住那条浮层的位置（都在标题栏正下方同一处），两条完全重合，所以是**原地**交叉淡入淡出。
   */
  @Builder
  inFlowSegmentBar() {
    Column() {
      this.segmentBar()
    }
    .width('100%')
    .height(SEGMENT_BLOCK_HEIGHT)
    .opacity(this.barPinned ? 0 : 1)
    .animation({ duration: BAR_HANDOFF_MS, curve: Curve.EaseOut })
    .hitTestBehavior(this.barPinned ? HitTestMode.None : HitTestMode.Default)
    .zIndex(2)
  }

  /**
   * 钉住后的分段按钮 —— **页面里的一层浮层**（需求："模糊只盖到 HDS 标题行，不要盖分段按钮那一行"）。
   *
   * 上一版把它交给标题栏的 `bottomBuilder`：好处是"HDS 导航栏的上层"，代价是那一行也算进标题栏
   * —— 标题栏的毛玻璃蒙层于是从 94vp 长到 154vp，用户看到的就是"背景模糊太高了"。
   * 现在改成页面里的浮层，落点和上一版**完全一样**（y = PROFILE_TOP_OFFSET，高 SEGMENT_BLOCK_HEIGHT），
   * 只是它背后不再有整条毛玻璃：滚动的内容从它两侧（胶囊外）清晰地穿过去。
   * 按钮自己那层沉浸光感材质照样在内容区生效 —— 官方《沉浸光感–功耗优化》里 **Toggle 是全页面
   * 生效的那几个组件之一**（Search 不是，所以搜索框必须另有安排，见 SearchPage 的搜索框浮层），
   * 而分段按钮正是 Toggle 搭的（见 ProfileSegmentBar / MaterialSurface）。
   *
   * 和在流那条（inFlowSegmentBar）对称：同样 180ms 原地交叉淡入淡出（两条落点重合），
   * 钉住时才吃触摸（没钉住时它是透明的，别继续吃触摸）。
   */
  @Builder
  pinnedSegmentBar() {
    Column() {
      // 占位：把这条压到标题栏正下方（和上一版 bottomBuilder 的落点一致）。
      Stack()
        .width('100%')
        .height(PROFILE_TOP_OFFSET)
        .hitTestBehavior(HitTestMode.None)
      Column() {
        this.segmentBar()
      }
      .width('100%')
      .height(SEGMENT_BLOCK_HEIGHT)
      .opacity(this.barPinned ? 1 : 0)
      .animation({ duration: BAR_HANDOFF_MS, curve: Curve.EaseOut })
      .hitTestBehavior(this.barPinned ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%')
    // 浮层自身不吃触摸（None = 自身不参与命中测试、子节点照常响应）：
    // 没钉住时它整条透明，钉住后只有胶囊那一条要响应。
    .hitTestBehavior(HitTestMode.None)
    .zIndex(3)
  }

  /** 分段按钮本体（抽成组件是因为它有两个宿主：页面里 + 标题栏下方的浮层，见 ProfileSegmentBar）。 */
  @Builder
  segmentBar() {
    ProfileSegmentBar({
      // 传的是**第几段**（本人 4 段 / 别人主页 3 段，见 ProfileViewModel 的 order 映射）。
      tab: this.vm.segmentOfTab(this.tab),
      count: this.vm.segmentCount(),
      mode: this.segmentMode,
      availableWidthVp: this.screenWidthVp,
      onSelect: (segment: number): void => {
        this.selectTab(segment);
      }
    })
  }

  /** 帖子格子。 */
  @Builder
  gridCell(post: ProfilePost) {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (post.hasUsableCover()) {
        Image(post.coverUrl)
          .draggable(false)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          // 加载中 / **加载失败**（网页回放那条路偶尔给一条过期的封面地址，真机上就是一格纯黑）
          // 都垫这张灰底播放占位图（resources/base/media/grid_placeholder.png）。
          .alt($r('app.media.grid_placeholder'))
          .backgroundColor($r('app.color.field_background'))
      } else {
        /*
         * **封面用不了**（空串，或者 cover 位上是 mp4 —— 见 ProfilePost.hasUsableCover）：
         * 画一个"没有预览"的占位，不要留一块纯黑。
         *
         * 这种格子主要出在**视频**上（收藏 / 视频那两段的载荷经常只给 mp4，没有海报帧；
         * 网页回放那条路给的那几段连媒体 id 都没有，补不了封面，见
         * ProfileViewModel.backfillVideoCovers）。原来这里垫的是 App 图标，深色下看着就是一块黑
         * —— 用户看到"第一排是坏的"有一半是它。灰底 + 一颗图标，一眼能看出这条有内容、
         * 只是没有预览图。补到封面之后这一格会自己换成真图（键里带了封面长度，见 tabContent）。
         */
        Column() {
          SymbolGlyph(this.cellShowsPlay(post) ? $r('sys.symbol.play_fill') : $r('sys.symbol.camera'))
            .fontSize(22)
            .fontColor([$r('app.color.secondary_text')])
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.field_background'))
      }
      if (this.cellShowsPlay(post) && post.hasUsableCover()) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(13)
          .fontColor([Color.White])
          .margin({ top: 6, right: 6 })
      }
    }
    .width(this.cellWidth())
    .height(this.cellWidth() * GRID_ASPECT)
    .clip(true)
    .onClick((): void => {
      // 点格子打开哪一页**看当前是哪一段**（需求）：
      //   视频那一段 → **Reels 页**（新页面，reels 模板，见 onOpenReels）；
      //   其余（帖子 / 收藏 / 被提及）→ 帖子页（feeds 流并定位到这一条）。
      // 两个入口都拿不到下标/宿主没接时退回老行为（用网页打开帖子），
      // 免得把"点了没反应"留给用户。
      if (this.tab === PROFILE_TAB_REELS) {
        this.onOpenReels(this.streamPosts(), post.shortcode, this.vm.moreOfTab(this.tab),
          this.makeStreamLoader());
        return;
      }
      const index: number = this.indexOfPost(post);
      if (index >= 0) {
        /*
         * **整份分页按顺序铺成 feeds 流**（需求："收藏feeds流按照分页顺序展示，不用随机"、
         * "我的帖子和被标注帖子需要改回 feeds 流形态"）。
         *
         * 三种分页统一这么做：
         *   - 顺序就是**分页本身的顺序**（网格里第 1 条就是流里第 1 条）；
         *   - 进页只带手上这一份，之后触底再由 makePostPageLoader **按页追加**（见它那里的
         *     增量语义：只交出新出现的那几条，顺序仍然是从前到后）。
         * 早先收藏那一段试过"只带点中的那一条"，顺序就从"点中的那条"重新开始 —— 看起来就是
         * 乱序，已按需求改回来。
         */
        this.onOpenStream(this.streamPosts(), index, this.makePostPageLoader());
        return;
      }
      this.onOpen(post);
    })
  }

  /**
   * 帖子页"再拉一页"的入口（闭包，交出去之后由帖子页在进页/触底时调用）。
   *
   * 做法：让**当前分页**再取一页（数据仍然落在视图模型里，见 requestMoreForTab），
   * 等它长起来之后把**整份**最新的帖子列表 + "还有没有下一页"一起回给帖子页。
   *
   * 三条讲究（都是真机上踩出来的）：
   *   1. **有没有下一页由视图模型说了算**（`moreOfTab`），不是"这次条数有没有变多"：
   *      翻页可能正被网格占着（`requestMoreFor` 会把它记成 wantMore 延后执行），那一刻条数
   *      当然没长；按条数判就会误判成"到底了"，帖子页从此再也加载不动。
   *   2. 所以"催了一次但没长起来、而它确实还有下一页"时要**再催一次**（最多 STREAM_LOAD_TRIES
   *      次），而不是直接收手。
   *   3. 全程有上限（STREAM_LOAD_TIMEOUT_MS），网络卡住时帖子页不会一直转圈。
   */
  private makeStreamLoader(): () => Promise<ProfileStreamPage> {
    return (): Promise<ProfileStreamPage> => {
      return this.pumpStream(this.tab, STREAM_LOAD_TRIES, false);
    };
  }

  /**
   * **帖子页**专用的"再要一页"（增量语义）。
   *
   * 需求："初次点进帖子页面时不将分页中的图片整理成 feeds 流" —— 进页时只带点中的那一两条，
   * 之后每翻到底部再要一页、**追加**到帖子页那份列表上（见 pages/Index.loadPostPageMore）。
   * 所以这里回的**只有这次新取到的那几条**，而不是整个分页的最新全量：
   * 回全量的话，帖子页第一轮就会把整个分页（可能几十上百条）全铺成 feeds 卡片 ——
   * 那正是这次要避免的事（一次要转几十张图的模型、还要给它们补详情）。
   *
   * Reels 页那条路仍然是全量语义（见 onOpenReels），两边不要混。
   */
  private makePostPageLoader(): () => Promise<ProfileStreamPage> {
    return (): Promise<ProfileStreamPage> => {
      return this.pumpStream(this.tab, STREAM_LOAD_TRIES, true);
    };
  }

  /**
   * 催一页并等它到位（见 makeStreamLoader / makePostPageLoader 的说明）。
   *
   * @param delta true = 只回这次**新追加**的那几条（帖子页）；false = 回整份最新列表（Reels 页）。
   */
  private pumpStream(tab: number, triesLeft: number, delta: boolean): Promise<ProfileStreamPage> {
    const done: () => ProfileStreamPage = (): ProfileStreamPage => {
      if (delta) {
        // 增量语义：这次没长起来就是**空页**（调用方按 hasMore 决定要不要再来一轮）。
        return new ProfileStreamPage([], this.vm.moreOfTab(tab));
      }
      return new ProfileStreamPage(this.streamPostsOfTab(tab), this.vm.moreOfTab(tab));
    };
    if (!this.vm.moreOfTab(tab)) {
      // 已经到底：直接把当前这份还回去（**不发请求**，调用方按 hasMore=false 收手）。
      return Promise.resolve(done());
    }
    const before: number = this.vm.postsOfTab(tab).length;
    /*
     * 增量模式要"这次**新出现**的那几条"，这里先记下手上的键。
     *
     * 为什么不用下标差（`slice(before)`）：这一轮等的时候，网格那边可能也在翻同一段
     * （同一个视图模型），条数会**从别处**长起来 —— 按下标切片就会切错位/漏条，
     * 帖子页看起来就是"顺序乱、还少了几条"（需求："按照分页顺序展示，不用随机"）。
     * 按键做差集则永远是"新出现的、按原顺序"。
     */
    const beforeKeys: Set<string> = new Set<string>();
    if (delta) {
      const list: Array<ProfilePost> = this.vm.postsOfTab(tab);
      for (let index: number = 0; index < list.length; index++) {
        const one: ProfilePost = list[index];
        beforeKeys.add(one.shortcode.length > 0 ? one.shortcode : one.coverUrl);
      }
    }
    this.vm.requestMoreForTab(tab);
    return new Promise<ProfileStreamPage>((resolve: (page: ProfileStreamPage) => void): void => {
      const deadline: number = Date.now() + STREAM_LOAD_TIMEOUT_MS;
      const poll: () => void = (): void => {
        const list: Array<ProfilePost> = this.vm.postsOfTab(tab);
        const grew: boolean = list.length > before;
        const more: boolean = this.vm.moreOfTab(tab);
        if (grew || !more || Date.now() > deadline) {
          if (!grew && more && triesLeft > 0) {
            // 还没长起来但确实还有下一页：多半是这一轮被网格占着了，再催一次。
            this.pumpStream(tab, triesLeft - 1, delta).then(resolve);
            return;
          }
          if (delta && grew) {
            const fresh: Array<MediaPost> = [];
            const mapped: Array<MediaPost> = this.streamPostsOfTab(tab);
            for (let index: number = 0; index < mapped.length; index++) {
              const one: MediaPost = mapped[index];
              if (!beforeKeys.has(one.shortcode.length > 0 ? one.shortcode : one.id)) {
                fresh.push(one);
              }
            }
            resolve(new ProfileStreamPage(fresh, more));
            return;
          }
          resolve(done());
          return;
        }
        setTimeout(poll, STREAM_LOAD_POLL_MS);
      };
      setTimeout(poll, STREAM_LOAD_POLL_MS);
    });
  }

  /** 指定分页的全部帖子 → 信息流卡片要的模型。 */
  private streamPostsOfTab(tab: number): Array<MediaPost> {
    const mapped: Array<MediaPost> = ProfilePage.toStreamPosts(this.vm.postsOfTab(tab));
    // 「收藏」这一段的每一条**本身就是已收藏**的：写进会话覆盖表，那颗书签才会是实心
    // （需求："收藏页面的收藏按钮没有显示为收藏状态"）。
    if (tab === PROFILE_TAB_SAVED) {
      ProfilePage.markSaved(mapped);
    }
    return mapped;
  }

  /**
   * 把一批帖子标成"已收藏"（见 streamPostsOfTab）。
   *
   * 为什么写覆盖表而不是给 MediaPost 加字段：收藏状态在**卡片**那一层读
   * `core/SaveState`（见 FeedList.syncUiList 与 PostUi.saved），在这儿写一次，
   * 网格/帖子页/翻页后重建的卡片就都是实心的；用户取消收藏时那条覆盖会被改回 false。
   */
  private static markSaved(posts: Array<MediaPost>): void {
    for (let index: number = 0; index < posts.length; index++) {
      const id: string = posts[index].id;
      if (id.length > 0 && id.indexOf('profile-') !== 0) {
        SaveState.remember(id, true);
      }
    }
  }

  /** 某条帖子在当前分页里的下标（找不到给 -1）。 */
  private indexOfPost(post: ProfilePost): number {
    for (let index: number = 0; index < this.posts.length; index++) {
      if (this.posts[index].shortcode === post.shortcode) {
        return index;
      }
    }
    return -1;
  }

  /**
   * 当前分页的全部帖子 → 信息流卡片要的模型（见 ProfileMapper.toMediaPost）。
   *
   * 作者一并补上（见 ownerName 的说明）：**视频分页**那条数据本身没有作者。
   *
   * 但**收藏 / 被标注**那两段不能补：那两段的帖子是**别人**发的（收藏是别人的帖子、
   * 被标注是别人标注我的帖子），补成"这一页的主人"就成了张冠李戴（头像/名字都不是作者本人）。
   * 那两段宁可不设作者，也不要挂错人。
   */
  private streamPosts(): Array<MediaPost> {
    const own: boolean = this.tab === PROFILE_TAB_POSTS || this.tab === PROFILE_TAB_REELS;
    const mapped: Array<MediaPost> = ProfilePage.toStreamPosts(this.posts,
      own ? this.ownerName() : '', own ? this.ownerAvatar() : '', own ? this.vm.targetId() : '');
    // 「收藏」那一段同上：这一份里的每条都是已收藏（见 streamPostsOfTab）。
    if (this.tab === PROFILE_TAB_SAVED) {
      ProfilePage.markSaved(mapped);
    }
    return mapped;
  }

  /** 一份网格数据 → 信息流卡片要的模型（帖子页的初始数据与翻页后的更新都走它）。 */
  private static toStreamPosts(posts: Array<ProfilePost>, owner: string = '',
                               avatar: string = '', ownerId: string = ''): Array<MediaPost> {
    const out: Array<MediaPost> = [];
    for (let index: number = 0; index < posts.length; index++) {
      try {
        out.push(ProfileMapper.toMediaPost(posts[index], owner, avatar, ownerId));
      } catch (error) {
      }
    }
    return out;
  }

  /**
   * 头部那一行**粗体的名字**。
   *
   * 需求："Empty 才是用户名，_yijin.__ 是用户名称（先不用显示这个）" —— 也就是显示 IG 的
   * 显示名（`full_name`），**不显示**账号名（`username`）。显示名为空时才退回账号名，
   * 免得头部只剩一个空行（有些账号确实没设显示名）。
   */
  private displayName(): string {
    const header: ProfileHeader | null = this.header;
    if (header === null) {
      return '';
    }
    if (header.fullName.length > 0) {
      return header.fullName;
    }
    return header.username;
  }

  /**
   * 这一页主人的**账号名 / 头像**（`@Builder` 里不能先取局部变量，所以包成方法）。
   *
   * 用途：**视频分页**那条查询不给作者（`user` 是空的，真机实测）—— 而这一页整段都是同一个人，
   * 作者本来就等于这一页的主人，拿它补上。不补的话 Reels 页左下角只有孤零零一个 `@`。
   */
  private ownerName(): string {
    const header: ProfileHeader | null = this.header;
    if (header !== null && header.username.length > 0) {
      return header.username;
    }
    return this.vm.targetName();
  }

  /** 同上，头像。 */
  private ownerAvatar(): string {
    const header: ProfileHeader | null = this.header;
    return header === null ? '' : header.avatarUrl;
  }

  build() {
    // 根容器是 Column，最上面垫一层**透明 Stack**（和首页 FeedList 同一套做法）：
    // 下拉刷新用的是 Refresh 自带的**系统原生**图标，而它画在 Refresh 的顶边上 —— Refresh
    // 铺满整屏时图标落在 y≈0，正好被状态栏 + HdsNavigation 的沉浸材质压住，看不见（实测）。
    // 把 Refresh 整体下移到标题栏之下，原生图标就落在标题栏下方；顶部避让改由这层占位接管，
    // 所以下面列表的 contentStartOffset 一并去掉（两者不能叠加）。
    // 这条占位同时也是"分段按钮钉住的判据"依赖的那条线（列表视口顶边，见 barPinned）。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Stack()
          .width('100%')
          .height(PROFILE_TOP_OFFSET)

        this.profileList()
      }
      .width('100%')
      .height('100%')

      // 钉住后的那一条：**页面里的浮层**，盖在内容之上（见 pinnedSegmentBar）。
      // 必须是 Stack 的兄弟节点（不能放进上面那个 Column：那会占掉列表的高度）。
      this.pinnedSegmentBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  /**
   * **关注 / 发消息**那一行（需求：放在分段按钮上方，两颗并排、加起来和分段按钮一样宽、
   * 用沉浸光感材质；关注要显示关注状态并支持关注/取关；发消息暂不做功能）。
   *
   * 几点讲究：
   *   1. **只有别人主页有这一行**（`isSelfPage()`）：关注自己没有意义；
   *   2. 宽度：分段按钮那条胶囊占的是"屏宽 − SEGMENT_SIDE×2"（见 ProfileSegmentBar 的内缩），
   *      所以两颗按钮各占 `(胶囊宽 − 间距) / 2`，加起来**正好等于胶囊的宽度**；
   *   3. 材质：直接用 `MaterialLabelButton`（Toggle + `SurfaceModifier`，全 app 那一套沉浸光感，
   *      带材质自带的阴影），和分段按钮同一层观感；
   *   4. 跟随状态：初值取头部里的 `followedByViewer`（再叠一层**本地覆盖表** `FollowState`，
   *      本地点过的以本地为准），点按先乐观翻转、失败回滚（同首页那颗关注按钮的判据）。
   */
  @Builder
  followRow() {
    Row({ space: FOLLOW_GAP }) {
      MaterialLabelButton({
        // 文案走资源（en_US 也有）：未关注 = 关注，已关注 = 已关注。
        labelRes: this.following
          ? $r('app.string.action_following') : $r('app.string.action_follow'),
        // 已关注用次要前景色（和首页那颗 FollowPill 的观感一致），未关注用主题正文色。
        tint: this.following ? '#737373' : '',
        pillWidth: this.followButtonWidth(),
        pillHeight: FOLLOW_BUTTON_HEIGHT,
        fontSize: 14,
        onTap: (): void => {
          this.tapFollowUser();
        }
      })
      MaterialLabelButton({
        labelRes: $r('app.string.notify_message'),
        pillWidth: this.followButtonWidth(),
        pillHeight: FOLLOW_BUTTON_HEIGHT,
        fontSize: 14,
        onTap: (): void => {
          // 需求：这颗按钮暂时不做功能。
        }
      })
      /*
       * 「推荐关注」（圆形）——需求："将…推荐关注按钮接入其他用户主页"。
       * 本人主页那颗画在功能区（见 actionRow），别人主页就挂在关注 / 发消息这一行的末尾。
       */
      MaterialIconButton({
        symbol: $r('sys.symbol.person_badge_plus'),
        buttonSize: FOLLOW_BUTTON_HEIGHT,
        iconSize: 20,
        onTap: (on: boolean): void => {
          hilog.info(DOMAIN, TAG, 'PF suggest follow tap (not wired)');
        }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: SEGMENT_SIDE, right: SEGMENT_SIDE, top: 4, bottom: 12 })
  }

  /** 这一页是不是"我自己"（只有别人主页才画关注/发消息那一行）。 */
  private isSelfPage(): boolean {
    return this.segmentMode !== SEGMENT_MODE_USER;
  }

  /**
   * 一颗按钮的宽度：让"两颗 + 中间间距 + 那颗圆按钮"正好等于分段按钮那条胶囊的宽度。
   *
   * 圆按钮和药丸同高（`FOLLOW_BUTTON_HEIGHT`），所以宽度上要把它和它两侧的间距一起扣掉。
   */
  private followButtonWidth(): number {
    const capsule: number = this.screenWidthVp - SEGMENT_SIDE * 2;
    const one: number = (capsule - FOLLOW_GAP * 2 - FOLLOW_BUTTON_HEIGHT) / 2;
    return one > 48 ? one : 48;
  }

  /** 点关注 / 取关：先乐观翻转，回调返回失败就回滚（同首页那颗关注按钮）。 */
  private tapFollowUser(): void {
    if (this.followBusy) {
      return;
    }
    const next: boolean = !this.following;
    this.followBusy = true;
    this.following = next;
    this.onFollowUser(next).then((ok: boolean): void => {
      this.followBusy = false;
      if (!ok) {
        // 失败了要弹回去，否则用户以为关注成功了。
        this.following = !next;
      }
    }).catch((): void => {
      this.followBusy = false;
      this.following = !next;
    });
  }

  /**
   * 可下拉刷新的那一块：Refresh 包住**外层滚动**（List 是它的可滚动子节点）。
   *
   * **不要给 Refresh 传 builder / refreshingContent**：试过（想把转圈从标题栏下面挪出来），结果
   * 整个页面被顶成一块全屏空白、列表要下拉一次才出现，顶部避让也一起失效 —— 自定义刷新内容会被
   * 当作"刷新区里常驻的一团"，它和 List 的布局是互相牵连的。首页那边同样只用原生图标。
   *
   * ## 为什么是**两层滚动**（外层 = 头部 + 分段按钮，内层 = 当前分页）
   * 需求："无论分页多短都可以上滑到标题栏下方固定；固定后切换分页不会被影响位置；
   * 分页用容器套着、在内部滚动；分段按钮未固定时禁用滚动"。
   * 一条列表做不到这四点：切分页会换掉整条列表的内容，长度一变，**外层的偏移就跟着变**
   * （短分页拉不住，按钮就滑回页面里）。拆成两层之后：
   *   - **外层**只装 头部 + 分段按钮 + 内层容器，而内层容器是**固定高度**（视口 − 分段条高）——
   *     于是外层内容高恒等于 `视口 + 头部高`，**滑到底正好把分段按钮顶到标题栏下方**，
   *     和分页有几条内容毫无关系（需求 1）。不用再靠"末尾补高"那种估算。
   *   - 外层滑到底之后**再滑不动**（范围就是头部那么高），于是手势自然落到**内层**：
   *     分页内容在里面滚（需求 3）。
   *   - 切分页只换内层的内容，外层偏移一动不动 —— 分段按钮**位置不受影响**（需求 2）。
   *   - 未钉住时内层 `enableScrollInteraction(false)`，手势全归外层（需求 4）。
   */
  @Builder
  profileList() {
    Refresh({ refreshing: $$this.refreshing }) {
      List({ scroller: this.pageScroller }) {
        // ---- 头部（个人信息）：会被外层滚出去 ----
        ListItem() {
          /*
           * 外层这个 Column **不带左右内边距**：精选快拍那一排要**满屏宽**（滑起来像主页那条
           * 快拍列表一样能穿出屏幕边），靠它自己行内的 `padding left/right 16` 和上面的内容对齐
           * （见 highlightsRow）。
           */
          Column() {
            Column({ space: HEADER_ROW_GAP_VP }) {
            /*
             * 头像 + 右侧一列（需求："将我的页面的用户名移到帖子数量上方，粗体显示"）。
             *
             * 版式照 Instagram 个人页来：头像单独在左，右边从上到下是
             *   **用户名（粗体）** → 帖子/粉丝/关注 三格。
             *
             * 这里的"用户名"就是 IG 的**显示名**（`full_name`，比如 `Empty`）—— 需求明确
             * 说了"_yijin.__ 那一串（`username`）先不显示"。只有显示名为空时，才退回账号名，
             * 免得头部只剩一个空行。
             */
            Row({ space: 16 }) {
              Image(this.header === null || this.header.avatarUrl.length === 0
                ? $r('app.media.startIcon') : this.header.avatarUrl)
                .draggable(false)
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                .borderRadius(AVATAR_SIZE / 2)
                .objectFit(ImageFit.Cover)
                .backgroundColor($r('app.color.field_background'))
              Column({ space: 8 }) {
                Row({ space: 5 }) {
                  Text(this.displayName())
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.primary_text'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.header !== null && this.header.isVerified) {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(15)
                      .fontColor([$r('app.color.accent')])
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                // 名字和下面"帖子"那一列文字左对齐（见 nameIndentVp）。
                .padding({ left: this.nameIndentVp() })

                Row({ space: 0 }) {
                  this.statCell(0, $r('app.string.profile_stat_posts'))
                  this.statCell(1, $r('app.string.profile_stat_followers'))
                  this.statCell(2, $r('app.string.profile_stat_following'))
                }
                .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Column({ space: 4 }) {
              // 状态行：取数失败原因 / 正在干什么（正常加载成功后**不显示**）。
              //
              // 它同时是**排查通道** —— 这个项目里日志经常被刷掉，界面上的这行字
              // 用 uitest dumpLayout 一定读得到。所以只过滤掉那两句"没什么信息量"的正常态：
              // 以前正常进页面也会在名字和简介之间插一行"已加载"，看起来像简介的一部分。
              if (this.visibleStatus().length > 0) {
                Text(this.visibleStatus())
                  .fontSize(12)
                  .fontColor($r('app.color.secondary_text'))
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }

              // 简介：`@账号` 现渲染成可点的超链接（见 bioText）。
              this.bioText()
              if (this.header !== null && this.header.link.length > 0) {
                Text(this.header.link)
                  .fontSize(13)
                  .fontColor($r('app.color.accent'))
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            /*
             * ---- 横幅区（chips）----
             * 需求："包括 meta 旗下软件的主页：软件图标 + 用户名称 / 音乐（要做播放功能，
             * 点击暂停/播放）/ 添加（先不用做功能）"，样式全部用沉浸光感组件。
             *
             * 后来还要求"接入其他用户主页"——所以**本人/别人都画**；
             * 只有「编辑主页 / 分享主页」是本人的动作，留在 actionRow 里按身份判断。
             */
            this.bannerChips()

            // ---- 功能区：编辑主页 / 分享主页（椭圆）+ 推荐关注（圆形）----
            if (this.isSelfPage()) {
              this.actionRow()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 12, bottom: 14 })
          // 量一下这一块的高度：它就是"分段按钮什么时候顶到标题栏下方"的那条线（见 barPinned）。
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const height: number = typeof newArea.height === 'number'
              ? newArea.height as number : 0;
            if (height > 0 && Math.abs(height - this.headerBlockVp) > 0.5) {
              this.headerBlockVp = height;
            }
          })

            // ---- 精选快拍区：满屏宽的一排（左右留白在它自己行内，见 highlightsRow）----
            if (this.isSelfPage()) {
              this.highlightsRow()
            }
          }
          .width('100%')
        }

        // ---- 关注 / 发消息：**分段按钮上方那一行**（只有别人主页有，见 followRow）----
        if (!this.isSelfPage()) {
          ListItem() {
            this.followRow()
          }
        }

        // ---- 分段按钮：钉住后由标题栏接手（这里淡出，见 inFlowSegmentBar）----
        ListItem() {
          this.inFlowSegmentBar()
        }
        // ---- 当前分页的内容：**固定高度的内层滚动容器**（见 profileList 的说明）----
        ListItem() {
          this.tabContent()
        }
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 外层只滚"头部 + 分段按钮"那一段；滚动上报给底栏动画用（见 onFeedScroll）。
      .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
        const y: number = this.pageScroller.currentOffset().yOffset;
        // 分段按钮钉住/松开（见 barPinned）。
        this.updatePinned(y);
        this.scrollDelta.report(y, scrollState, this.onFeedScroll);
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

  /**
   * 当前分页的内容：**固定高度**的内层滚动容器（高度 = 视口 − 分段条高）。
   *
   * 固定高度是这套结构的关键：外层的内容高因此恒等于 `视口 + 头部高`，滑到底正好把分段按钮
   * 顶到标题栏下方 —— 分页只有 1 条也一样（需求 1），不需要"末尾补高"。
   */
  @Builder
  tabContent() {
    List({ space: GRID_GAP, scroller: this.listScroller }) {
      // **LazyForEach**：只建可见的那几行（见 ProfileRowSource 的说明）。行内的格子仍然用
      // ForEach —— 一行最多三格，没必要再懒一层。
      LazyForEach(this.rowSource, (row: Array<ProfilePost>, rowIndex: number): void => {
        ListItem() {
          Row({ space: GRID_GAP }) {
            ForEach(row, (post: ProfilePost): void => {
              this.gridCell(post)
            }, (post: ProfilePost): string => post.shortcode)
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }
      }, (row: Array<ProfilePost>, rowIndex: number): string => {
        /*
         * 键 = **这一行的内容签名**（代次 + 行号 + 每格的 shortcode/封面长度/是不是视频）。
         *
         * 为什么不用"行号 + 第一条 shortcode"那么简：封面回填（见 ProfileViewModel.
         * backfillVideoCovers）只换封面、不动 shortcode，那种改动也要让这一行重建，否则
         * 补到的封面画不出来（格子还是黑的）。带上封面长度就够了，不用整条地址（键太长没意义）。
         */
        let signature: string = '';
        for (let at: number = 0; at < row.length; at++) {
          const one: ProfilePost = row[at];
          signature += `${one.shortcode.length}.${one.coverUrl.length}.${one.isVideo ? 1 : 0}|`;
        }
        return `g${this.rowSource.gen()}:row:${rowIndex}:${signature}`;
      })

      // ---- 触底哨兵：进到可见范围就翻页 ----
      if (this.posts.length > 0) {
        ListItem() {
          Row({ space: 8 }) {
            if (this.busy && this.hasMore) {
              LoadingProgress()
                .width(22)
                .height(22)
                .color($r('app.color.secondary_text'))
            }
            Text(this.hasMore ? $r('app.string.profile_loading_more') : $r('app.string.profile_end'))
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
          }
          .width('100%')
          .height(56)
          .justifyContent(FlexAlign.Center)
          .onAppear((): void => {
            // 哨兵只是**顺带**的一个触发点；真正可靠的是内层的 onReachEnd / onScrollIndex
            // （onAppear 只报一次，很容易在加载中被吞掉）。
            this.askMore();
          })
        }
      } else if (!this.busy) {
        ListItem() {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.camera'))
              .fontSize(34)
              .fontColor([$r('app.color.secondary_text')])
            Text($r('app.string.profile_empty'))
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
    .height(this.tabContentHeightVp())
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    /*
     * 内外层的**滚动优先级**（这一段是"固定时卡手"的修复点）。
     *
     * 规则（静态，不随状态切换）：
     *   - `scrollForward`（上滑、内容往上走）= **PARENT_FIRST**：外层还能滚时先滚外层 ——
     *     也就是"分段按钮先顶上去"；外层滚到底之后，同一个手势会**接着传给内层**
     *     （嵌套滚动是逐帧接力的，不用抬手重滑）；
     *   - `scrollBackward`（下滑）= **SELF_FIRST**：先滚内层，内层回到顶部之后才轮到外层
     *     （头部滑回来、分段按钮松开）—— 正是需求："固定时下滑优先滚动内部容器，
     *     到顶部后才能滚动外部容器"。
     *
     * 为什么**不再用 `enableScrollInteraction(this.barPinned)` 开关**（上一版那么写的）：
     * 那个开关会在"钉住"那一帧**中途改掉内层的识别器**，正在滑的手势会被丢掉 ——
     * 表现就是"固定时无法继续滑动、卡手"（用户报的）。优先级是静态的，手势一路不断。
     * 未固定时内层之所以不抢：`PARENT_FIRST` 已经保证外层优先，外层没到底内层拿不到手势。
     */
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    // 底部悬浮 tab 栏是浮在内容上的，不内缩最后一行会被它压住。
    .contentEndOffset(PROFILE_BOTTOM_OFFSET)
    /*
     * 触底翻页：挂两个**会反复触发**的判据（`onReachEnd` 真的到底了、`onScrollIndex` 还剩
     * 几条时提前拉），哨兵的 onAppear 只是顺带的一个触发点 —— 它只报一次，很容易在加载中
     * 被吞掉（那正是"收藏分页无法上滑继续加载"的原因，见 ProfileViewModel.requestMore）。
     */
    .onReachEnd((): void => {
      this.askMore();
    })
    .onScrollIndex((start: number, end: number): void => {
      // 这个容器里只有网格行 + 末尾哨兵，下标从 0 开始。
      const rows: number = Math.ceil(this.posts.length / GRID_COLUMNS);
      if (end + PROFILE_LOAD_AHEAD >= rows) {
        this.askMore();
      }
    })
    // 内层滚动：记这一分页的位置（切页要恢复）并上报给底栏动画。
    .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
      const y: number = this.listScroller.currentOffset().yOffset;
      this.vm.rememberOffset(this.tab, y);
      // 用户还在滑：允许自动翻页（见 askMore）。程序化恢复位置也会走到这里，同样算"在动"，
      // 但那种情况只持续一两帧，不会把列表拉长。
      this.lastScrollMs = Date.now();
      this.scrollDelta.report(y, scrollState, this.onFeedScroll);
    })
    /*
     * **别裁**（需求："让分页帖子可以穿过分段按钮到屏幕顶层"）。
     *
     * 这一层是"当前分页的窗口"，但关掉裁剪之后，滚出窗口上沿的那几行**照样会被画出来**：
     * 于是分页帖子会穿过分段按钮、一直画到屏幕最顶上（标题栏的材质是半透明的，透出来就是
     * 首页那种"内容从标题栏底下过"的观感）。
     * 顺序上不会乱：分段按钮那一条 `.zIndex(2)` 在它之上，标题栏又是另一棵树（更高），
     * 所以帖子是**从它们底下穿过去**，而不是盖住它们 —— 这正是要的效果（和首页 FeedList 同一套）。
     */
    .clip(false)
  }

  /** 内层容器的高度（vp）= 视口 − 分段条那一块（见 tabContent 的说明）。 */
  private tabContentHeightVp(): number {
    if (this.screenHeightVp <= 0) {
      return 0;
    }
    const viewport: number = this.screenHeightVp - PROFILE_TOP_OFFSET;
    const inner: number = viewport - SEGMENT_BLOCK_HEIGHT;
    return inner > 0 ? inner : 0;
  }

  /**
   * 点了某一段：切分页（视图模型先把这一分页已有内容秒铺出来，再去补，见 ProfileViewModel.setTab）。
   *
   * 这里**不做记账**：记老分页的位置、恢复新分页的位置都在 `vm.onTab` 那个回调里统一做
   * （标题栏那条分段按钮走不到这个方法，见 aboutToAppear 的说明）。
   */
  private selectTab(segment: number): void {
    // 进来的是**第几段**（本人 4 段 / 别人主页 3 段），先映射成内部分页号（见 ProfileViewModel.order）。
    const index: number = this.vm.tabAtSegment(segment);
    if (index === this.tab) {
      return;
    }
    const own: string = this.header === null ? '' : this.header.username;
    // **不要在这里清空 this.posts**：清空就等于每次切页都先白一下。新分页的内容由
    // 视图模型同步回调铺出来（缓存命中时当帧就换，没有缓存时才是空的）。
    this.vm.setTab(index, own);
  }

  /**
   * 把"待恢复的滚动位置"落实一次。
   *
   * 为什么要补两枪：`scrollTo` 只能滚到**当前已布局**的范围内，内容刚换（或还没到）时最大
   * 偏移可能还不够，滚下去会被夹回顶部；隔一帧再滚一次就稳了（不带动画，用户看不到过程）。
   */
  private restoreScroll(): void {
    const target: number = this.pendingOffset;
    if (target < 0) {
      return;
    }
    this.pendingOffset = -1;
    this.applyScroll(target);
  }

  private applyScroll(target: number): void {
    const run: () => void = (): void => {
      try {
        // 恢复的是**内层**（当前分页）的位置；外层的偏移（分段按钮的位置）不动。
        this.listScroller.scrollTo({ xOffset: 0, yOffset: target, animation: false });
      } catch (error) {
      }
    };
    run();
    hilog.info(DOMAIN, TAG, 'PF inner restore target=%{public}d now=%{public}d pinned=%{public}s posts=%{public}d',
      target, this.innerOffsetNow(), `${this.barPinned}`, this.posts.length);
    setTimeout((): void => {
      hilog.info(DOMAIN, TAG, 'PF inner +250ms now=%{public}d pinned=%{public}s',
        this.innerOffsetNow(), `${this.barPinned}`);
    }, 250);
    if (target > 0) {
      // 内容异步到位的情况：下一帧再对一次（那时行已经布局完，滚得到）。
      setTimeout(run, 0);
      setTimeout(run, 60);
    }
  }

  /** 当前内层偏移（诊断用，拿不到给 -1）。 */
  private innerOffsetNow(): number {
    try {
      return this.listScroller.currentOffset().yOffset;
    } catch (error) {
      return -1;
    }
  }

  /** 当前外层偏移（诊断用，拿不到给 -1）。 */
  private outerOffsetNow(): number {
    try {
      return this.pageScroller.currentOffset().yOffset;
    } catch (error) {
      return -1;
    }
  }

  /**
   * 把**外层**的位置接回来（需求："切回来别再回到顶部"，见 pendingOuter）。
   *
   * 补几枪的理由和内层一样：外层能滚多远取决于**头部那一块量出来的高度**（headerBlockVp），
   * 而那是首帧布局之后才有的 —— 第一枪多半会被夹到 0，隔一帧再对两次才落得准。
   * 滚回去之后 `onDidScroll` 会把"钉住了没有"算回来（见 updatePinned），所以分段按钮的
   * 固定态也跟着回来，不需要单独记录。
   */
  private restoreOuter(): void {
    const target: number = this.pendingOuter;
    if (target < 0) {
      return;
    }
    this.pendingOuter = -1;
    const run: () => void = (): void => {
      try {
        this.pageScroller.scrollTo({ xOffset: 0, yOffset: target, animation: false });
      } catch (error) {
      }
    };
    run();
    if (target > 0) {
      setTimeout(run, 0);
      setTimeout(run, 60);
      setTimeout(run, 160);
    }
  }

  /** 按当前滚动偏移更新"分段按钮钉住了没有"（见 barPinned 的说明）。 */
  private updatePinned(offsetY: number): void {
    // 顺手把外层的偏移记进视图模型：切到别的分页再切回来时要靠它恢复位置（见 pendingOuter）。
    this.vm.rememberOuter(offsetY);
    if (this.headerBlockVp <= 0) {
      return;
    }
    // 留 PIN_SLACK_VP 的余量：外层的可滚范围就是"个人信息的高度"，取整误差下卡太死会差一点。
    const pinned: boolean = offsetY >= this.headerBlockVp - PIN_SLACK_VP;
    if (pinned !== this.barPinned) {
      this.barPinned = pinned;
      // 钉住 = 外层滚到底、内层开始接管：换了容器，底栏那份增量记账清零。
      this.scrollDelta.reset();
      // 钉住这一刻把内层滚回它自己的位置（外层刚滑到底，内层多半还在 0）。
      if (pinned) {
        this.restoreScroll();
      }
    }
  }

  /**
   * 请求下一页（幂等入口：触底、提前量、末尾哨兵三个触发点都走它）。
   *
   * 两道闸：
   *   1. **只有用户还在滑（或列表还没铺满一屏）时才自动翻页**。原来只要"末尾还露着"就翻 ——
   *      而每翻一页末尾还是露着，于是变成一台永动机：真机日志里一次滑动之后
   *      24→36→48→…→96 条，网络全被它占满、列表还在不停长大。程序化恢复滚动位置时同样会踩到。
   *   2. 真正发请求**推到下一个 tick**（setTimeout 0）：未钉住时"触底"是在布局过程中判出来的，
   *      同步走进去会一路回调到页面里改 @State —— ArkUI 会报
   *      "State variable 'busy' has changed during render"（真机日志里抓到过）。
   */
  private askMore(): void {
    if (!this.hasMore || this.busy) {
      return;
    }
    const recent: boolean = Date.now() - this.lastScrollMs < ASK_MORE_IDLE_MS;
    if (!recent && this.posts.length >= AUTO_MORE_MIN_POSTS) {
      return;
    }
    setTimeout((): void => {
      this.vm.requestMore();
    }, 0);
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
}
