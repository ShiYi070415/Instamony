/*
 * 「我的」页面的视图模型。
 *
 * 和 FeedViewModel / ReelsViewModel 同一套路数：页面只负责画，取数编排都在这里。
 *
 * ## 取数：**原生 HTTP 优先**，网页回放兜底
 *   1) 原生直发（core/NativeProfile）：模板 + 会话头 → `http.request` → 原生解析。
 *      没有过桥、没有体积上限、也不占用隐藏网页（见 NativeProfile 文件头的说明）。
 *   2) 原生这条拿不到（模板还没抓到 / 会话没就绪）才退回**网页回放**
 *      （profilePostsScript：在网页里用同一份模板 fetch 一次，结果过桥回原生解析）。
 *   3) 连模板都没有（全新安装）→ 冷启动那条路：让隐藏网页打开一次自己的主页，
 *      页面自己会发这些查询，NETWORK_WATCHER 把模板抓下来（capture），之后就走上面两条。
 *
 * ## 四个分页
 * 帖子 / 视频 / 收藏 / 被标注 在 IG 网页上是**四个不同的地址**（`/用户名/`、`/用户名/reels/`、
 * `/用户名/saved/`、`/用户名/tagged/`），各自发一条查询。所以：
 *   - 模板按**操作名**区分，每条分页一条（操作名不写死，按名字特征认，见 TAB_PATTERNS ——
 *     IG 换名字也认得出）；
 *   - 页面侧切分页时，如果那条分页的模板还没有，就把隐藏网页导航到对应地址、抓一次
 *     （captureTab），抓到就走原生。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { OWN_PROFILE_SCRIPT } from '../bridge/WebScripts';
import { AppConfig } from '../config/AppConfig';
import { NativeProfile, ProfileTarget } from '../core/NativeProfile';
import { ProfileHeader, ProfileHighlight, ProfileMapper, ProfileMusic, ProfilePostsPage, ProfilePost } from '../model/Profile';
import { MediaPost } from '../model/MediaPost';
import { MediaPrefetch } from '../core/MediaPrefetch';
import { PosterCache } from '../core/PosterCache';
import { MediaDetail, NativeMediaInfo } from '../core/NativeMediaInfo';
import { ApiThrottle } from '../core/ApiThrottle';
// 头部落盘快照（见 AppSettings.saveProfileHeader 与 load 里的 paintHeaderSnapshot）。
import { AppSettings } from '../core/AppSettings';
// 关注状态校正：`friendships/show_many` 比头部那个字段更权威（见 verifyOtherFollow）。
import { NativeFollow } from '../core/NativeFollow';
import { FollowState } from '../core/FollowState';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ProfileViewModel';

/** 分页下标（和界面上那四个图标一一对应，见 ProfilePage 的分段按钮）。 */
export const PROFILE_TAB_POSTS: number = 0;
export const PROFILE_TAB_REELS: number = 1;
export const PROFILE_TAB_SAVED: number = 2;
export const PROFILE_TAB_TAGGED: number = 3;

/**
 * 每个分页的**缓存页深度**（需求："翻页预取深度调深一档"）。
 *
 * 一页不够：滑得快的人第二次触底就撞上"缓存已空、现抓几百毫秒"，所以备两页 —— 连续两次
 * 滑到底都吃内存里的页。再多就没必要了（一页 12 条，两页已经二十多屏）。
 */
const PREFETCH_DEPTH: number = 2;
/**
 * 每一段媒体预加载只看**前几条**（同主页 feeds 的"往后看几张"，见 FeedList.PREFETCH_AHEAD）。
 *
 * 12 ≈ 一屏多一点的网格：再往后是"用户还没翻到"的东西，提前抓等于跟正在看的那几张抢带宽。
 */
const PRECACHE_POSTS_PER_TAB: number = 12;
/** 多图帖**只预加载两张**（需求："多图片只需预加载两张"）。 */
const PRECACHE_IMAGES_PER_POST: number = 2;
/**
 * 视频封面回填看**前几条**（见 backfillVideoCovers）。
 *
 * 12 和 PRECACHE_POSTS_PER_TAB 一样 ≈ 一屏多一点：用户一眼能看到的格子就那么几格，
 * 为了一屏外的东西连打十几个 `/media/{id}/info/` 不划算（那条端点还有限流）。
 */
const COVER_BACKFILL_POSTS: number = 12;
/** 四个分页之间错开的间隔（毫秒，见 preloadAllSegments）。 */
const PRECACHE_GAP_MS: number = 600;

/** 冷启动抓模板用的片段（一次把个人页相关的都抓下来）。 */
const CAPTURE_FILTER: string = 'Profile';
/** 冷启动那次：等页面把手上的查询发出去的时间。 */
const HYDRATE_WAIT_MS: number = 1800;
/** 单次回放的上限。 */
const REPLAY_TIMEOUT_MS: number = 15000;
/** 导航到自己主页时的等待上限。 */
const NAV_READY_TIMEOUT_MS: number = 20000;
/**
 * 一页要多少条（回放那条路上用）。
 *
 * 用 12（接口默认）而不是 24：那条查询的响应里每条帖子都挂着巨大的
 * `organic_tracking_token` 之类的字段，24 条一次要回传 800KB+，会被回传上限**截断** ——
 * 截断的 JSON 解析必失败（实测 `posts map failed bytes=835146`）。12 条约 400KB，稳。
 * （原生 HTTP 那条路没有这个限制，条数直接用模板里的。）
 */
const PAGE_SIZE: number = 12;
/** 单次回放的回传上限：留足 12 条一页的余量（截断 = JSON 坏了，宁可多给一点）。 */
const POSTS_MAX_BYTES: number = 900000;
/** 冷启动首轮失败后，等这么久再重试一次。 */
const COLD_RETRY_WAIT_MS: number = 1500;
/**
 * 「自己的主页地址」那一步的尝试次数 / 单次超时 / 间隔。
 *
 * 冷启动时网页往往还没就绪，脚本会返回空 —— 那就解析不出自己的主页，只能退回首页，
 * 而首页上不会发个人页的查询（模板就抓不到）。所以多试几次，见 ensureTemplates。
 */
const OWN_PROFILE_ATTEMPTS: number = 3;
const OWN_PROFILE_TIMEOUT_MS: number = 8000;
const OWN_PROFILE_GAP_MS: number = 1500;
/**
 * 冷启动那次「抓模板」的轮询次数与间隔。
 *
 * 为什么不能只抓一次：导航完之后页面是**分段水合**的，那两条查询不一定立刻发出去。
 * 改成轮询：抓齐了立刻走，没抓齐再等一轮。
 */
const CAPTURE_POLLS: number = 8;
const CAPTURE_POLL_GAP_MS: number = 1500;
/**
 * 抽取脚本（仅回放兜底那条路用）的单次超时与重试。
 *
 * 压到 6 秒而不是 15：刚导航完页面还在水合时，注入脚本经常要等到桥超时才返回；
 * 短超时 + 多次重试的总耗时可控，而页面一闲下来（回放毫秒级）数据就出来了。
 */
const EXTRACT_TIMEOUT_MS: number = 6000;
const EXTRACT_ATTEMPTS: number = 3;
const EXTRACT_RETRY_GAP_MS: number = 2000;

/**
 * 四个分页的**操作名特征**（按顺序对应上面四个下标）。
 *
 * 不写死完整名字：IG 改过好几次命名（`PolarisProfilePostsQuery` 只是"帖子"那条），
 * 按"含 Profile + 关键词"来认，抓到哪个用哪个；认不出就把已存的操作名列出来（见 tabDiag），
 * 照着补一个特征即可。
 */
const TAB_PATTERNS: Array<string> = ['posts', 'reel', 'saved', 'tag'];

/**
 * 四个分页在**移动端**那套端点里的名字（见 core/mobileapi/MobileProfile.tab）。
 *
 * 与 `TAB_PATTERNS` 一一对应：posts（帖子）/ clips（Reels）/ saved（收藏）/ tagged（被标注）。
 * 有了它，"没有 GraphQL 模板"时也能给出 `mobile:<kind>` 这个合成操作名，切分页不再去抓模板。
 */
const PROFILE_TAB_KINDS: Array<string> = ['posts', 'clips', 'saved', 'tagged'];


/**
 * 一个分页的取数状态。
 *
 * 四个分页各自独立存一份：切到某个分页时**先把这一份铺出来**（有内容就是"秒显示"），
 * 再去补没拉过的部分 —— 这是"切换分页要立刻看到内容"（需求）的落点。
 */
class ProfileTabState {
  posts: Array<ProfilePost> = [];
  cursor: string = '';
  more: boolean = true;
  /** 第一页拉回来过没有（拉过就不在切页时重复请求）。 */
  loaded: boolean = false;
  /** 正在拉（避免同一分页并发两次）。 */
  loading: boolean = false;
  /** 正在后台抓这一分页的接口模板（避免重复导航隐藏网页）。 */
  capturing: boolean = false;
  /**
   * 有人在"正在加载"的时候要过下一页。
   *
   * 为什么必须记：列表末尾那个哨兵（"正在加载…"那一条）常常在第一页数据刚铺出来时就露出来了，
   * 那一刻 `loading` 还是 true —— 直接把 requestMore 丢掉的话，哨兵之后再也不会 onAppear，
   * 用户就一直滑不出新内容（需求报的"收藏分页无法上滑继续加载"就是这个）。
   */
  wantMore: boolean = false;
  /**
   * **下一页的缓存队列**（提前拉好放在手边）。
   *
   * 需求："给每个分页做一下缓存页加载，提升加载速度"。用户滑到底时直接把这一页贴上去
   * （毫秒级、不见"正在加载"），贴完再去后台补队列 —— 连续滑就一直顺。
   *
   * 深度见 PREFETCH_DEPTH：一页不够，滑得快的人第二次触底就撞上"缓存已空、现抓几百毫秒"。
   */
  nextPages: Array<ProfilePostsPage> = [];
  /** 正在预取下一页（避免同一分页并发预取）。 */
  prefetching: boolean = false;
  /** 这一分页上次真正取到数据是什么时候（毫秒，见 ProfileViewModel.loadIfStale）。 */
  loadedAtMs: number = 0;
}

export class ProfileViewModel {
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private header: ProfileHeader | null = null;
  /**
   * 一次性的**全量清空**（退出登录 / 换账号时调）。
   *
   * ⚠️ 以前这里只清了 `posts / endCursor / more / busy` 这四个**显示镜像**，四个分页各自的
   * `tabs[]`、头部、ownName、selfId、target 一个都没动 —— 于是用户报的
   * "退出登录后注册新账号，分页里的内容还是上一个人的"就成了必然：新账号进来时
   * `setTab` 看到 `state.loaded === true` 直接铺旧列表，连请求都不发。
   *
   * 现在：四个分页全部回到"没加载过"，头部与身份信息一起作废，`generation` 自增让
   * **清空之前发出去的那几发**回来时不要写状态（否则慢请求回来又把旧内容写回来了）。
   */
  reset(): void {
    this.generation++;
    for (let tab: number = 0; tab < this.tabs.length; tab++) {
      const state: ProfileTabState = this.tabs[tab];
      state.posts = [];
      state.cursor = '';
      state.more = true;
      state.loaded = false;
      state.loading = false;
      state.capturing = false;
      state.wantMore = false;
      state.nextPages = [];
      this.tabOffsets[tab] = 0;
    }
    this.tab = PROFILE_TAB_POSTS;
    this.posts = [];
    this.endCursor = '';
    this.more = true;
    this.busy = false;
    this.outerOffset = 0;
    // 头部与"我是谁"：换账号后这些都不可信，全部回到初始态（见 ensureSelfScope）。
    this.header = null;
    this.headerFromSnapshot = false;
    // 精选快拍也按人：换账号后必须清掉，否则会显示上一个人的高光。
    this.highlightItems = [];
    this.highlightsFor = '';
    this.onHighlights([]);
    this.ownName = '';
    this.headerVerified = false;
    this.selfId = '';
    this.target = ProfileTarget.self();
    this.diag = '-';
    this.replayDiag = '-';
    this.precaching = false;
    this.usedColdPath = false;
    this.coverTried = [];
    hilog.info(DOMAIN, TAG, 'profile reset (generation=%{public}d)', this.generation);
  }

  /**
   * 这次异步操作是不是已经**过期**（reset 之后 / 换过账号）。
   *
   * 每个耗时入口开头取一份 `generation`，写任何状态之前先问一句：过期的结果一律丢掉。
   * 不做这一道的话，退出登录时正在飞的那一发（可能要十几秒）回来会把旧账号的列表 / 头部
   * 重新写进视图模型 —— 表现就是"清了又回来了"。
   */
  private stale(gen: number): boolean {
    return gen !== this.generation;
  }

  private posts: Array<ProfilePost> = [];
  private endCursor: string = '';
  /** 还有没有下一页（名字避开公开方法 hasMore()，否则同名冲突）。 */
  private more: boolean = true;
  private busy: boolean = false;
  /** 当前分页（见 PROFILE_TAB_*）。 */
  private tab: number = PROFILE_TAB_POSTS;
  /**
   * **这一份数据是谁的**（空 = 本人，见 core/NativeProfile 的 ProfileTarget）。
   *
   * 决定取数时请求体里"目标用户"那几个键换成谁：本人时一个字都不改（"我的"页行为不变），
   * 别人主页时换成他的 id / 用户名（见 pages/Index 的用户主页路由）。
   */
  private target: ProfileTarget = ProfileTarget.self();
  /**
   * **自己的账号名**（`setTab` 时由页面传进来）。
   *
   * 只有一个用途：原生那一发失败之后重抓模板时要导航到 `/用户名/saved/` 这类地址
   * （见 recaptureAndRetry）。空 = 还不知道（那时不重抓，如实报错）。
   */
  private ownName: string = '';
  /**
   * 本人的头部**已经核对过一次**（拿到的账号名对不上时只重抓一次模板，见 loadHeader）。
   */
  private headerVerified: boolean = false;
  /**
   * 上面这些"本人"状态**属于哪个账号**（`ds_user_id`）。
   *
   * 为什么必须有：视图模型是长寿命对象（页面只建一次），而 `ownName` / `header` 都是
   * "我"的缓存。换账号之后它们还在，于是"头部按新账号的 id 取、核对却拿旧账号的名字比"
   * —— 要么把别人的资料当成自己的画上去，要么莫名其妙报"头部读取异常"。
   * 每次进本人这条链先比一次 id，变了就把这几样**全部作废**（见 ensureSelfScope）。
   */
  private selfId: string = '';
  /**
   * 账号代次（见 stale / reset）。
   *
   * reset() 与"检测到换账号"时自增；每个异步入口开头取一份快照，写状态前比对一次，
   * 过期就整段丢掉 —— 这是"清空后旧请求又把内容写回来"的唯一可靠解法。
   */
  private generation: number = 0;
  /**
   * **分段按钮与内部分页的对应关系**（第 n 段 = 哪个分页）。
   *
   * 本人 4 段：[帖子, 视频, 收藏, 被标注]；别人主页 3 段（需求："移除收藏分页"）：
   * [帖子, 视频, 被提及]。内部仍然按 PROFILE_TAB_* 那套下标记账（tabs 数组长度不变），
   * 只是界面上的"第几段"要经过这层映射 —— 这样两边都不用改自己的记账方式。
   */
  private order: Array<number> = [PROFILE_TAB_POSTS, PROFILE_TAB_REELS, PROFILE_TAB_SAVED,
    PROFILE_TAB_TAGGED];
  /** 各分页内层的滚动位置 + 外层的滚动位置（跨页面重建要用，见 offsetOf/rememberOffset）。 */
  private tabOffsets: Array<number> = [0, 0, 0, 0];
  private outerOffset: number = 0;
  /**
   * 四个分页各自的取数状态（下标同 PROFILE_TAB_*）。
   *
   * 页面上 `this.posts` / `endCursor` / `more` 三件套始终指向**当前分页**那一份的镜像，
   * 页面读它们就行；切页时把新分页那一份拷回来（见 setTab）。
   */
  private tabs: Array<ProfileTabState> = [
    new ProfileTabState(), new ProfileTabState(), new ProfileTabState(), new ProfileTabState()
  ];
  /** 做没做过"后台预取另外三个分页"（只做一次）。 */
  /** 媒体的全分页预加载**正在跑**（见 preloadAllSegments，防重入）。 */
  private precaching: boolean = false;
  /** 已经为哪些媒体 id 试过补封面了（见 backfillVideoCovers：同一个 id 只试一次）。 */
  private coverTried: Array<string> = [];
  /** 这一轮是不是靠"真的打开一次网页"换来的数据（状态行据此措辞）。 */
  private usedColdPath: boolean = false;
  /** 最近一次失败的原样回报（截断），失败提示里带上它 —— 界面就是排查通道。 */
  private diag: string = '-';
  /**
   * 回放兜底那条路最近一次为什么没成。
   *
   * 单独一个字段（原来是往 diag 前面**叠**"回放第N次未成"）：叠起来会把真正有用的原因
   * （原生那句 `native=http-403 …`）挤出状态行的可视范围，界面上只剩一串"第3次未成"。
   */
  private replayDiag: string = '-';

  onHeader: (header: ProfileHeader) => void = (header: ProfileHeader): void => {
  };
  /**
   * 头部资料的**第二拨订阅方**（见 addHeaderListener）。
   *
   * 为什么必须多播：这个视图模型是长驻的，而订阅它的有两拨 ——
   *   · `pages/Index`（要它来填当前账号的头像/用户名、写进花名册、刷新多账号选单）；
   *   · `components/ProfilePage`（页面里那份头部 UI）。
   * 上一版只有一个**回调槽**，ProfilePage 一挂载就把它整个覆盖掉：从那以后头部资料回来，
   * Index 那一边再也收不到 —— 账号按钮、花名册、多账号选单就停在"未命名账号 + 没头像"
   * （用户报的正是这个，而且"重进 App 可能好、多刷几次又坏"，因为它取决于哪一方最后挂载）。
   * 现在 `onHeader` 保留给 Index（单槽，够用），ProfilePage 走这里注册，两拨各收一份。
   */
  private headerListeners: Array<(header: ProfileHeader) => void> = [];

  /** 注册一个头部资料订阅者（ProfilePage 用；页面销毁时要移除，见 removeHeaderListener）。 */
  addHeaderListener(listener: (header: ProfileHeader) => void): void {
    if (this.headerListeners.indexOf(listener) < 0) {
      this.headerListeners.push(listener);
    }
  }

  /** 移除订阅（只移除注册过的那个函数对象，别把别人的也清了）。 */
  removeHeaderListener(listener: (header: ProfileHeader) => void): void {
    const at: number = this.headerListeners.indexOf(listener);
    if (at >= 0) {
      this.headerListeners.splice(at, 1);
    }
  }

  /** 头部资料到齐：单槽 + 多播一起发（所有调用点都走这里）。 */
  private emitHeader(header: ProfileHeader): void {
    this.onHeader(header);
    for (let index: number = 0; index < this.headerListeners.length; index++) {
      try {
        this.headerListeners[index](header);
      } catch (error) {
        // 一个订阅方抛异常不能把另一个也带走（以前单槽覆盖时这个问题被掩盖了）。
        hilog.warn(DOMAIN, TAG, 'header listener threw: %{public}s', (error as Error).message);
      }
    }
  }
  onPosts: (posts: Array<ProfilePost>, hasMore: boolean) => void =
    (posts: Array<ProfilePost>, hasMore: boolean): void => {
    };
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
  };
  /** 取数进度（给人看的短句，页面直接显示）。 */
  onStatus: (text: string) => void = (text: string): void => {
  };
  /** 四个分页模板的**结构摘要**（探针用，页面把它落进沙箱文件，见 dumpProbeFile）。 */
  onDigest: (text: string) => void = (text: string): void => {
  };
  /**
   * 当前分页变了。
   *
   * 为什么要广播：分段按钮有**两个宿主**（页面里那条、钉住后标题栏里那条），
   * 两边的选中态必须同源 —— 真相放在视图模型这里（见 pages/Index 的 profileTab）。
   */
  onTab: (tab: number) => void = (tab: number): void => {
  };

  headerNow(): ProfileHeader | null {
    return this.header;
  }

  postsNow(): Array<ProfilePost> {
    return this.posts;
  }

  isBusy(): boolean {
    return this.busy;
  }

  hasMore(): boolean {
    return this.more;
  }

  tabNow(): number {
    return this.tab;
  }

  /**
   * 设定**目标用户**（别人主页用；本人不用调）。
   *
   * 只影响请求体里"目标用户"那几个键（见 NativeProfile.ProfileTarget），取数、记账、缓存
   * 那套逻辑完全共用 —— 所以别人主页能直接吃"我的"页那套模板与分页机制。
   */
  setTarget(id: string, username: string): void {
    this.target = new ProfileTarget(id, username);
  }

  /** 现在这一份数据是不是本人（页面据此决定要不要显示"收藏"那一段）。 */
  isSelfTarget(): boolean {
    return this.target.isSelf();
  }

  /** 目标用户的**数字 id**（空 = 本人/拿不到）。关注按钮要用它查本地关注状态。 */
  targetId(): string {
    return this.target.id;
  }

  /**
   * 目标用户的账号名（空 = 本人/拿不到）。
   *
   * 头部还没到时的兜底：关注状态既认 id 也认名字（见 core/FollowState），
   * 名字在路由参数里就有（`setTarget` 的第二个入参）。
   */
  targetName(): string {
    return this.target.username;
  }

  /**
   * **我自己**的账号名（拿到了就给；"我的"页一进就会去读，见 ensureOwnName）。
   *
   * 用途：帖子页标题栏判断"这一条是不是我发的"（自己不给关注按钮，见 pages/Index.postPageMenu）。
   */
  ownAccountName(): string {
    return this.ownName;
  }

  /**
   * **我自己**的数字 id（同步的；Cookie 里读过一次就有了）。
   *
   * 和 ownName 一样只用于"是不是我发的"这类判断 —— 异步读那一路在发请求时会顺手准备好
   * （见 NativeProfile.ownId），这里只做一次同步取用，读不到给空串。
   */
  ownIdSync(): string {
    return NativeProfile.ownIdCached();
  }

  /**
   * 设定分段顺序（别人主页去掉"收藏"：`[帖子, 视频, 被提及]`）。
   *
   * 顺带把当前分页夹回合法值：如果当前停在"收藏"而新顺序里没有它，就回到第一段。
   */
  setOrder(order: Array<number>): void {
    if (order.length === 0) {
      return;
    }
    this.order = order;
    if (this.indexOfTab(this.tab) < 0) {
      this.tab = order[0];
    }
  }

  /** 分段数（界面上的胶囊有几段）。 */
  segmentCount(): number {
    return this.order.length;
  }

  /** 第 segment 段对应哪个分页（越界就给第一段）。 */
  tabAtSegment(segment: number): number {
    if (segment < 0 || segment >= this.order.length) {
      return this.order[0];
    }
    return this.order[segment];
  }

  /** 某个分页在第几段（不在顺序里给 0）。 */
  segmentOfTab(tab: number): number {
    const index: number = this.indexOfTab(tab);
    return index < 0 ? 0 : index;
  }

  /** 某个分页在顺序里的下标（不在里面给 -1）。 */
  private indexOfTab(tab: number): number {
    for (let index: number = 0; index < this.order.length; index++) {
      if (this.order[index] === tab) {
        return index;
      }
    }
    return -1;
  }

  /**
   * 每个分页**内层**的滚动位置（vp）与**外层**（个人信息那一段）的滚动位置。
   *
   * 为什么放在视图模型里而不是页面的 @State：页面是**跟着 tab 走的**（切到别的分页再切回来，
   * ProfilePage 会被整个重建），页面里的字段一律归零 —— 于是"选中的分页、滚动到哪儿了"
   * 全丢，回来时选中态跳回第一项、内容却还是原来那一页、位置回到顶部（用户报的正是这个）。
   * 视图模型活在整个进程里，位置记在这儿才跨得过重建。
   */
  offsetOf(tab: number): number {
    if (tab < 0 || tab >= this.tabOffsets.length) {
      return 0;
    }
    return this.tabOffsets[tab];
  }

  rememberOffset(tab: number, y: number): void {
    if (tab < 0 || tab >= this.tabOffsets.length) {
      return;
    }
    this.tabOffsets[tab] = y > 0 ? y : 0;
  }

  /** 外层（头部那一段）的滚动位置：回来时要滚回这里，分段按钮的钉住状态也跟着回来。 */
  outerNow(): number {
    return this.outerOffset;
  }

  rememberOuter(y: number): void {
    this.outerOffset = y > 0 ? y : 0;
  }

  /**
   * 切分页：**先把这一分页已有的内容立刻铺出来**，再去补没拉过的部分（需求：切换要"秒显示"）。
   *
   * 三种情况：
   *   1. 这一分页已经拉过 → 立刻显示（同步回调，界面当帧就换），**不再发请求**；
   *   2. 正在拉 → 什么都不做，等它回调（避免并发两次）；
   *   3. 没模板 → **后台**抓一次（导航隐藏网页是秒级的，绝不能挡在切页路径上），抓完自动重拉；
   *      这期间界面立刻显示"这个分页还没有内容/正在抓"，不是白屏转圈。
   * 头部只在没有的时候拉（四个分页共用同一份个人信息）。
   */
  async setTab(tab: number, ownUsername: string): Promise<void> {
    if (tab === this.tab) {
      return;
    }
    this.tab = tab;
    // 记下自己的账号名：别人的主页要按用户名换 id 时才用得上（见 NativeProfile.fetchPosts）。
    if (ownUsername.length > 0 && ProfileViewModel.isUsername(ownUsername)) {
      this.ownName = ownUsername;
    }
    // 广播出去：标题栏里那条分段按钮（钉住时显示的那条）也要跟着换选中态。
    this.onTab(tab);
    /*
     * 切分页时头部若还没有，顺手补上（**不 await**：切页要秒开，头部是一发小请求）。
     * 头部与网格互不依赖，谁先回来都不影响另一个（见 load 里那段的说明）。
     */
    if (this.header === null) {
      this.loadHeader().catch((): void => {
      });
    }
    const state: ProfileTabState = this.tabs[tab];
    // 立刻铺出这一分页已有的内容（空就空着，但状态行会说清在干什么）。
    this.posts = state.posts;
    this.endCursor = state.cursor;
    this.more = state.more;
    this.onPosts(this.posts, this.more);
    if (state.loaded) {
      this.onStatus(state.posts.length > 0 ? '已加载' : '这个分页还没有内容');
      // 这一分页已经加载过：顺手把它的**下一页**也预取上（需求："缓存页加载"）。
      this.prefetchNext(tab);
      return;
    }
    if (state.loading) {
      return;
    }
    // 这一分页还没拉过：起一次加载（不阻塞切页，界面已经显示上面的空态/缓存）。
    this.load(true);
  }

  /**
   * 两份列表**合并**：`first` 在前，`second` 里没出现过的接在后面（按 shortcode/id 去重）。
   *
   * 两个用途：
   *   - 刷新（`load(true)`）：新一页在前、旧内容接在后面 —— 长度只增不减，滚动位置不会被夹回顶部；
   *   - 翻页（`requestMore`）：已有的在前、新的一页接在后面 —— IG 的分页偶尔会重复给同一条，
   *     不去重就会在网格里出现重复格子。
   */
  private static mergePosts(first: Array<ProfilePost>, second: Array<ProfilePost>): Array<ProfilePost> {
    const seen: Array<string> = [];
    const out: Array<ProfilePost> = [];
    for (let index: number = 0; index < first.length; index++) {
      const key: string = ProfileViewModel.keyOf(first[index]);
      if (seen.indexOf(key) >= 0) {
        continue;
      }
      seen.push(key);
      out.push(first[index]);
    }
    for (let index: number = 0; index < second.length; index++) {
      const key: string = ProfileViewModel.keyOf(second[index]);
      if (seen.indexOf(key) >= 0) {
        continue;
      }
      seen.push(key);
      out.push(second[index]);
    }
    return out;
  }

  /** 一条帖子的去重键（shortcode 优先，没有就退回封面地址 —— ProfilePost 没有 id 字段）。 */
  private static keyOf(post: ProfilePost): string {
    return post.shortcode.length > 0 ? post.shortcode : post.coverUrl;
  }

  /**
   * **够新就不重复拉**（页面重新进入时用，见 ProfilePage.aboutToAppear）。
   *
   * 为什么要有这个入口：以前每次切回「我的」都会 `load(true)` —— 一次原生 HTTP 往返（几百
   * 毫秒）换来的往往是一模一样的第一页；更要命的是它会和"恢复滚动位置"抢时间。
   * 现在一分钟内进过就不拉，直接用手上的数据（下拉刷新那条路不受影响，用户主动拉就一定拉）。
   */
  async loadIfStale(maxAgeMs: number): Promise<void> {
    const state: ProfileTabState = this.tabs[this.tab];
    if (state.loaded && state.loadedAtMs > 0 && Date.now() - state.loadedAtMs < maxAgeMs) {
      hilog.info(DOMAIN, TAG, 're-enter tab=%{public}d fresh (%{public}dms) → skip grid load',
        this.tab, Date.now() - state.loadedAtMs);
      /*
       * **网格够新不拉，但头部是独立的一份，必须补**（这是用户报的
       * "打开 app 进入我的页面头部数据没有加载"的直接原因）。
       *
       * 以前这里直接 `return`：而"网格够新"在**冷启动**时几乎恒成立 —— 启动预热
       * （`preloadAllSegments` → `prefetchOthersSequential` → `loadTabInBackground`）
       * 已经在后台把四个分页的第一页拉完了，但它**故意不碰头部**（不打扰当前显示）。
       * 于是用户第一次点进「我的」时：网格 fresh → 整段跳过 → 头部一次都没请求 →
       * 界面上头像空白、名字/简介为空、三个计数全 0。
       */
      if (this.header === null) {
        hilog.info(DOMAIN, TAG, 're-enter: header missing → fetch it now');
        await this.loadHeader();
      }
      return;
    }
    await this.load(true);
  }

  /** 拉一次（refresh=true 时丢掉游标从头拉）。 */
  async load(refresh: boolean): Promise<void> {
    /*
     * **进函数先把分页钉死**（审计 G1）。
     *
     * 这里到写回之间有六七个 await（`ensureOwnName` / 头部 / 网格 / 抓模板，几秒起步）。
     * 原来全程用 `this.tab`：用户在这几秒里切到别的分页，回来的时候
     *   - 请求用的是**新**分页的 op，游标却是**旧**分页的（拿 A 的游标去翻 B）；
     *   - `syncFrom(state)` 把 **A 分页的帖子**写进当前显示的列表（B 分页上看到 A 的内容）；
     *   - `backfillVideoCovers/next/requestMoreFor` 也全都作用在切过去那一页上。
     * 同文件里 `requestMoreFor`(698/707)、`applyCover`(1043)、`loadTabInBackground`(1113)
     * 都有 `this.tab === tab` 守卫，只有 `load` 漏了 —— 这里补齐：
     * 入口取一次 `tab`，全程只用 `tab`，**写显示状态之前先确认用户还停在那一页**。
     */
    const tab: number = this.tab;
    const state: ProfileTabState = this.tabs[tab];
    if (state.loading) {
      return;
    }
    if (refresh) {
      state.cursor = '';
      state.more = true;
    }
    state.loading = true;
    this.busy = true;
    this.onBusy(true);
    /*
     * 这一轮属于哪个"账号代次"（见 stale 的说明）。reset / 换账号之后，这里拿到的那几发
     * 结果一律不许再写状态 —— 否则退出登录时在飞的请求回来会把旧账号的内容铺回去。
     * 声明在 try 外面：catch / finally 也要用它做判断；真正的取值在 ensureSelfScope 之后
     * （那里可能刚刚 reset 过，代次已经变了）。
     */
    let gen: number = this.generation;
    /*
     * **高光提前发**：它走的是另一条私有接口、和帖子/头部没有依赖关系，
     * 以前排在首屏之后（首屏 1~3 秒），于是一排高光要等"帖子回来了再排队发"才出现。
     * 放到最前面与其它请求并行，用户会先看到快拍、再看到网格。
     */
    this.loadHighlights().catch((): void => {
    });
    try {
      // 本人：网格请求体的目标键也要回正（见 ensureOwnName），所以发请求前先落实"我是谁"。
      // 同样先确认这份本人状态属于当前账号（换账号后必须作废，见 ensureSelfScope）。
      await this.ensureSelfScope();
      /*
       * 网络那一发之前，**先用上次的快照把头部画出来**（见 AppSettings.saveProfileHeader）。
       *
       * 用户报的"切回大号，头部数据太慢"：头部这一发常被限速闸门排在别的请求后面
       * （真机 2~4 秒，闸门日志 `waited=2407ms waiting=6`）。这份数据变化很慢，
       * 先画快照、网络回来再覆盖，观感就是"进来就有"。
       */
      this.paintHeaderSnapshot();
      /*
       * 账号名**不再提前要**（见 loadHeader 那段说明 + 用户报的"切回大号头部太慢"）：
       * 头部那一发本来就会把 `username` 带回来（loadHeader 末尾会写进 ownName），
       * 这里再要一次等于把同一发 `users/{pk}/info/` 打两遍 —— 两发还共用同一个
       * ApiThrottle 家族（900ms 起跳），纯粹是自己把自己拖慢。真要回放模板时，
       * loadHeader / fetchPage 里那两处会各自 `await this.ensureOwnName()`。
       */
      gen = this.generation;
      /*
       * 头部与网格**并发**拉（原来是先把头部拉完再拉网格）。
       *
       * 两条都是原生 HTTP（几百毫秒起），串起来首屏就白等一趟；而用户一眼要看的是**网格**，
       * 头部只是计数与简介。两条互不依赖（头部失败也不影响网格），所以一起发。
       * 页面那边两个回调都只写自己的状态，谁先回来都不影响另一个。
       */
      // 头部：还没有、或者现在这份只是**落盘快照**（见 paintHeaderSnapshot）都要真去拉一次。
      const headerJob: Promise<void> = (this.header === null || this.headerFromSnapshot)
        ? this.loadHeader() : Promise.resolve();
      let page: ProfilePostsPage | null =
        await this.fetchPage(this.opNameOf(tab), state.cursor, tab);
      if (page === null) {
        /*
         * 失败后**再给一次机会**（用户报的"偶尔加载不出来"）：绝大多数偶发失败是网络抖动 /
         * 一发超时，隔 700ms 重试一次基本就过了。限流期间不重试（那只会把冷却窗口拖更长）。
         */
        if (!ApiThrottle.blocked(ApiThrottle.MOBILE)) {
          hilog.info(DOMAIN, TAG, 'tab load failed (%{public}s) → retry once', this.diag);
          await ProfileViewModel.sleep(700);
          page = await this.fetchPage(this.opNameOf(tab), state.cursor, tab);
        }
      }
      await headerJob;
      if (this.stale(gen)) {
        hilog.info(DOMAIN, TAG, 'tab load result dropped (generation %{public}d → %{public}d)',
          gen, this.generation);
        return;
      }
      if (page === null) {
        /*
         * 状态行要能区分"被限流"和"真的读不到"：限流时用户等一会儿自己就好了，
         * 这条文案直接告诉他还要多久，比一句笼统的"读取失败"有用得多。
         */
        if (ApiThrottle.blocked(ApiThrottle.MOBILE)) {
          const left: number = ApiThrottle.remainingMinutes(ApiThrottle.MOBILE);
          this.onStatus(left > 0
            ? `接口被限流，约 ${left} 分钟后自动恢复`
            : '接口被限流，稍后自动恢复');
        } else {
          // 带上诊断：这个项目的 hilog 常被系统刷掉，界面上的这一行是可靠的排查通道。
          this.onStatus(`读取失败：${this.diag}`);
        }
        hilog.info(DOMAIN, TAG, 'tab load gave up tab=%{public}d diag=%{public}s',
          tab, this.diag);
        return;
      }
      if (refresh && state.posts.length > 0) {
        /*
         * 刷新**不清空已有内容**：新一页放前面，旧的里没重复的接在后面（按 shortcode 去重）。
         *
         * 为什么必须这样：页面重新进入时也会走这一趟（见 ProfilePage.aboutToAppear）。
         * 直接替换会把用户已经翻出来的那几页全丢掉 —— 列表从 36 条缩回 12 条，内层的滚动位置
         * 当场被夹回顶部，也就是用户报的"切换页面返回后分页还是回到第一行"（真机日志：
         * `inner restore target=376.9` 已经落上了，紧接着列表被替换成 12 条，位置就被夹回 0）。
         * 合并没有这个问题：长度只增不减，位置一直有效。
         */
        state.posts = ProfileViewModel.mergePosts(page.posts, state.posts);
      } else {
        state.posts = page.posts;
      }
      state.cursor = page.endCursor;
      // 记下"这一分页刚拉过"：页面重新进入时够新就不重复拉（见 loadIfStale）。
      state.loadedAtMs = Date.now();
      // 游标为空就没法再往下翻：这时把"还有下一页"按没有处理，否则触底哨兵会一遍遍
      // 空转（它只看 more，不看游标），界面上一直转圈却永远不来新的。
      state.more = page.hasMore && page.endCursor.length > 0;
      state.loaded = true;
      // 第一页重新来过了：缓存队列作废（游标链从头开始）。
      state.nextPages = [];
      /*
       * 写显示状态之前先确认用户还停在这一页（见函数开头 tab 的说明）：
       * 切走了就只更新那一分页自己的 state，显示的那份等切回来时由 selectTab 铺上。
       */
      if (this.tab === tab) {
        this.syncFrom(state);
        this.onStatus(state.posts.length > 0 ? '已加载' : '这个分页还没有内容');
      }
      // 这一段首屏里"没有封面的视频"补一下封面（见 backfillVideoCovers）。
      this.backfillVideoCovers(tab);
      // 首屏到手之后：① 顺手把另外三个分页也备好（**顺序**拉，模板已有的才拉，
      //    见 prefetchOthersSequential）；② 把本分页的**下一页**也预取上（需求："缓存页加载"）。
      this.prefetchOthersSequential().catch((): void => {
      });
      this.prefetchNext(tab);
      // 精选快拍（高光）：首屏之后的那一发保留（缓存未命中时这里才真正走网络）。
    } catch (error) {
      // 这里必须吞掉并记下来：异常一旦从这里跑出去，页面上的 aboutToAppear 是
      // "发了就不管"的调用，用户只会看到永远空白的页，日志里也什么都没有。
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      if (!this.stale(gen)) {
        this.onStatus('加载出错');
      }
    } finally {
      /*
       * **过期的一轮不要再动状态**：reset() 之后 `tabs[]` 已经全部回到"没加载过"，
       * 这里要是还去清 loading/busy 或补一次 requestMore，就会把新账号那一轮搅乱
       * （最直观的后果是新账号一进来就显示"没有更多了"、或者触底直接空转）。
       */
      if (this.stale(gen)) {
        return;
      }
      state.loading = false;
      this.busy = false;
      this.onBusy(false);
      // 第一页加载期间就要过下一页的（列表短、哨兵早露头）：现在补一次。
      if (state.wantMore) {
        state.wantMore = false;
        if (state.more && state.cursor.length > 0) {
          // 补的是**这一分页**的下一页（不是"现在显示的那一页"，见函数开头 tab 的说明）。
          this.requestMoreFor(tab);
        }
      }
    }
  }

  /**
   * 触底翻页：只改游标，不导航。
   *
   * 三条守则：
   *   1. **正在加载时不能丢**（记进 wantMore，加载完补一次）—— 见 ProfileTabState.wantMore；
   *   2. 只写"那一分页"的状态，并且**只有它还显示着**才推给界面（用户在加载期间切了页，
   *      不能把另一个分页的内容糊上去）；
   *   3. 没有游标/没有下一页就收手，别让触底判据空转。
   */
  async requestMore(): Promise<void> {
    await this.requestMoreFor(this.tab);
  }

  /**
   * **帖子页**用：让**指定分页**再拉一页（不要求它是当前分页）。
   *
   * 为什么需要：帖子页把"某个分页的所有帖子"铺成信息流，它的翻页和网格的翻页是同一件事
   * —— 数据都在视图模型里（游标、缓存页、预取都在这一份状态上），所以帖子页触底时只要喊
   * 这一声，拉回来的内容就会进到 `tabs[tab].posts`；再由页面把它转成信息流那一条条交回去。
   */
  async requestMoreForTab(tab: number): Promise<void> {
    await this.requestMoreFor(tab);
  }

  /** 某一分页目前已经拿到的帖子（帖子页每次翻页后从它重建列表）。 */
  postsOfTab(tab: number): Array<ProfilePost> {
    if (tab < 0 || tab >= this.tabs.length) {
      return [];
    }
    return this.tabs[tab].posts;
  }

  /** 某一分页还有没有下一页（帖子页据此决定要不要继续触底加载）。 */
  moreOfTab(tab: number): boolean {
    if (tab < 0 || tab >= this.tabs.length) {
      return false;
    }
    const state: ProfileTabState = this.tabs[tab];
    return state.more && state.cursor.length > 0;
  }

  private async requestMoreFor(tab: number): Promise<void> {
    const state: ProfileTabState = this.tabs[tab];
    if (state.loading) {
      state.wantMore = true;
      return;
    }
    if (!state.more || state.cursor.length === 0) {
      return;
    }
    const op: string = this.opNameOf(tab);
    if (op.length === 0) {
      return;
    }
    state.loading = true;
    this.busy = true;
    this.onBusy(true);
    try {
      // **有缓存页就直接贴**（毫秒级、不会闪"正在加载"）；没有才发请求（见 nextPages 的说明）。
      let cached: ProfilePostsPage | null = null;
      if (state.nextPages.length > 0) {
        cached = state.nextPages[0];
        state.nextPages = state.nextPages.slice(1);
      }
      const page: ProfilePostsPage | null = cached !== null
        ? cached
        : await this.fetchPage(op, state.cursor);
      if (page === null || page.posts.length === 0) {
        state.more = false;
        if (this.tab === tab) {
          this.syncFrom(state);
        }
        return;
      }
      // 已有的在前、新的一页接在后面 —— 顺便去重（IG 偶尔会在页与页之间重复同一条）。
      state.posts = ProfileViewModel.mergePosts(state.posts, page.posts);
      state.cursor = page.endCursor;      // 同 load：没有游标就当到底了，别让触底哨兵空转。
      state.more = page.hasMore && page.endCursor.length > 0;
      if (this.tab === tab) {
        this.syncFrom(state);
      }
      hilog.info(DOMAIN, TAG, 'requestMore tab=%{public}d cached=%{public}s +%{public}d total=%{public}d',
        tab, cached !== null ? 'y' : 'n', page.posts.length, state.posts.length);
      // 贴完这一页，顺手把"再下一页"预取上（连续下滑就一直有存货）。
      this.prefetchNext(tab);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'requestMore tab=%{public}d threw: %{public}s',
        tab, (error as Error).message);
    } finally {
      state.loading = false;
      this.busy = false;
      this.onBusy(false);
      // 加载期间被要过下一页：补一次（这里不再走 requestMore()，免得又落到"当前分页"上）。
      if (state.wantMore) {
        state.wantMore = false;
        if (state.more && state.cursor.length > 0) {
          this.requestMoreFor(tab);
        }
      }
    }
  }

  /** 把某一分页的状态同步成"当前显示"（页面读的就是这三个字段）。 */
  private syncFrom(state: ProfileTabState): void {
    this.posts = state.posts;
    this.endCursor = state.cursor;
    this.more = state.more;
    this.onPosts(this.posts, this.more);
  }


  /**
   * 拉一页（**只走移动端**，见 core/NativeProfile.fetchPosts）。
   *
   * @param tab 这一页属于哪一段（只用于日志与失败原因）。
   */
  private async fetchPage(op: string, cursor: string,
                          tab: number = PROFILE_TAB_POSTS): Promise<ProfilePostsPage | null> {
    const page: ProfilePostsPage | null =
      await NativeProfile.fetchPosts(op, cursor, this.target);
    if (page !== null) {
      this.diag = '-';
      hilog.info(DOMAIN, TAG, 'posts op=%{public}s tab=%{public}d n=%{public}d more=%{public}s',
        op, tab, page.posts.length, page.hasMore ? 'y' : 'n');
      return page;
    }
    this.diag = NativeProfile.lastDetail();
    hilog.info(DOMAIN, TAG, 'posts failed op=%{public}s tab=%{public}d why=%{public}s',
      op, tab, this.diag);
    return null;
  }

  /** 当前分页对应的操作名。 */
  private tabOpName(): string {
    return this.opNameOf(this.tab);
  }

  /** 某个分页对应的操作名（合成名 `mobile:<kind>`，见 NativeProfile.mobileOpFor）。 */
  private opNameOf(tab: number): string {
    return NativeProfile.mobileOpFor(PROFILE_TAB_KINDS[tab]);
  }

  /**
   * 进入「我的」时把**所有分页的 feeds 页**都备好（需求："进入我的页面时预加载所有分页的
   * feeds 页面，加载逻辑使用主页 feeds 那套预缓存页"）。
   *
   * 两半：
   *   ① **数据**：另外三段的第一页（`prefetchOthers`，已经有）+ 当前分页往后两页
   *      （`prefetchNext`，PREFETCH_DEPTH）—— 和主页 feeds 的 NATIVE_CACHE_PAGES 同一个意思；
   *   ② **媒体**（这里补的）：封面小图预解码 + 图片预下载，用的就是主页 feeds 那两件套
   *      （core/PosterCache.warm + core/MediaPrefetch.prefetch，见 FeedList.prefetchAhead）。
   *
   * 约束（需求）：**多图帖只预加载两张**（PRECACHE_IMAGES_PER_POST）；
   * **视频不在这里预下载** —— 它由播放器自己的缓冲负责（`VideoSurface.BUFFER_TOTAL_SEC = 2`
   * 秒，起播只要 1 秒，见那里的说明），提前把视频文件抓下来对播放器没有任何帮助。
   *
   * 幂等：同一进程只跑一遍（`precaching` + 每一段各自的去重见 PosterCache/MediaPrefetch）。
   */
  async preloadAllSegments(): Promise<void> {
    if (this.precaching) {
      return;
    }
    this.precaching = true;
    try {
      // ① 数据：四个分页**顺序**拉（需求："我的页面中分页帖子页面加载逻辑改为顺序加载"）——
      //    一个拉完再拉下一个（`prefetchOthersSequential` 里 await 住了），不再一口气并发打四条
      //    重查询（那条帖子查询真机上是 800KB 级）。
      await this.prefetchOthersSequential();
      // ② 媒体：同样一段一段来（每一段内部先解封面小图、再提交图片预下载）。
      const tabs: Array<number> = this.order.slice(0);
      for (let index: number = 0; index < tabs.length; index++) {
        this.precacheTabMedia(tabs[index]);
        await ProfileViewModel.sleep(PRECACHE_GAP_MS);
      }
    } finally {
      this.precaching = false;
    }
  }

  /**
   * 把另外几段的第一页**顺序**拉起来（见 preloadAllSegments 的第 ① 步）。
   *
   * 和 `prefetchOthers` 的区别只有一个：**串行**。并发的四条重查询在真机上会把网页/网络
   * 挤在一起，用户切过去时反而更慢（而且日志里那四条大小不一的响应会互相插队）。
   */
  private async prefetchOthersSequential(): Promise<void> {
    const tabs: Array<number> = this.order.slice(0);
    for (let index: number = 0; index < tabs.length; index++) {
      const tab: number = tabs[index];
      if (tab === this.tab) {
        continue;
      }
      const state: ProfileTabState = this.tabs[tab];
      if (state.loaded || state.loading) {
        continue;
      }
      const op: string = this.opNameOf(tab);
      if (op.length === 0) {
        continue;
      }
      await this.loadTabInBackground(tab, op);
    }
  }

  /**
   * 收藏 / 取消收藏成功之后：把「收藏」分页**整段作废并重拉**。
   *
   * 需求："点击收藏按钮后需要触发收藏分页刷新状态不然分页不会显示新的收藏帖子/视频"。
   * 只作废那一段（`loaded=false` + 清掉预取队列），用户下次进「收藏」就是新的一份；
   * 如果他正看着那一段，`loadTabInBackground` 会把新内容直接铺上去（见那里的说明）。
   */
  refreshSavedTab(): void {
    const tab: number = PROFILE_TAB_SAVED;
    if (tab < 0 || tab >= this.tabs.length || this.indexOfTab(tab) < 0) {
      return;
    }
    const state: ProfileTabState = this.tabs[tab];
    state.loaded = false;
    state.nextPages = [];
    const op: string = this.opNameOf(tab);
    if (op.length === 0 || state.loading) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'saved tab invalidated → refetch');
    this.loadTabInBackground(tab, op);
  }

  /** 某一段的媒体预加载（见 preloadAllSegments）。 */
  private precacheTabMedia(tab: number): void {
    const posts: Array<ProfilePost> = this.postsOfTab(tab);
    if (posts.length === 0) {
      return;
    }
    // 顺手把"没有封面的视频"补上（见 backfillVideoCovers）——放在这里是因为它天然就是
    // "进「我的」时把四段都过一遍"的那个时机，和封面预解码同一个循环。
    this.backfillVideoCovers(tab);
    const mapped: Array<MediaPost> = [];
    const urls: Array<string> = [];
    for (let index: number = 0; index < posts.length && index < PRECACHE_POSTS_PER_TAB; index++) {
      const post: MediaPost = ProfileMapper.toMediaPost(posts[index]);
      mapped.push(post);
      // 多图帖**只预加载两张**（需求）：滑到前两张时不白。
      for (let at: number = 0; at < post.imageUrls.length && at < PRECACHE_IMAGES_PER_POST; at++) {
        const url: string = post.imageUrls[at];
        if (url.length > 0) {
          urls.push(url);
        }
      }
    }
    if (mapped.length === 0) {
      return;
    }
    PosterCache.warm(mapped, PRECACHE_POSTS_PER_TAB);
    const started: number = MediaPrefetch.prefetch(urls);
    hilog.info(DOMAIN, TAG, 'precache media tab=%{public}d posts=%{public}d imgs=%{public}d/%{public}d',
      tab, mapped.length, started, urls.length);
  }

  /**
   * **视频封面回填**（真机现象："收藏我的帖子和视频后进入收藏，第一排直接被刚收藏的我的帖子/
   * 视频那一排覆盖" —— 那一排里"一整排黑格子 / 一格是花屏"的那一半就是这个）。
   *
   * 根因：收藏 / 视频 / 被标注那几段的载荷里，视频条目**经常没有 `image_versions2`**
   * （只给 `video_versions` 那串 mp4）。网格那一格拿不到封面：
   *   - 老版本把 mp4 当图片地址去解 → 画出来是一格**花屏**（那一格的内容其实是视频首帧）；
   *   - 现在的版本（见 NativeProfile.postOf）直接丢掉非图片候选 → 是**一块黑**。
   * 两种情况用户看到的都是"刚收藏的那一排是坏的"。而封面其实是有的：按媒体 id 再问一次
   * `/api/v1/media/{id}/info/`，`images[0]` 就是视频的海报帧（帖子页本来就走这条端点）。
   *
   * 三条约束：
   *   1. **只回填"封面用不了"的条目**（空串，或者 cover 位上是 mp4 那种，
   *      见 ProfilePost.hasUsableCover）；
   *   2. **只回填前 COVER_BACKFILL_POSTS 条**（用户一眼能看到的就是那几格）；
   *   3. **不 await**（一发请求几百毫秒，不能挡在切页/取数路径上），同一媒体 id 只试一次
   *      （`coverTried`）；拿到封面之后**换掉那一条**并通知界面（见 runCoverBackfill）。
   */
  private backfillVideoCovers(tab: number): void {
    const state: ProfileTabState = this.tabs[tab];
    const todo: Array<string> = [];
    for (let index: number = 0; index < state.posts.length && index < COVER_BACKFILL_POSTS; index++) {
      const post: ProfilePost = state.posts[index];
      if (post.hasUsableCover()) {
        continue;
      }
      const id: string = post.mediaId;
      // 网页回放那条路给的是 `profile-<shortcode>` 这种占位 id，问不出东西（见 fetchPage）。
      if (id.length === 0 || id.indexOf('profile-') === 0) {
        continue;
      }
      if (this.coverTried.indexOf(id) >= 0) {
        continue;
      }
      this.coverTried.push(id);
      todo.push(id);
    }
    if (todo.length === 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'cover backfill tab=%{public}d n=%{public}d', tab, todo.length);
    this.runCoverBackfill(tab, todo);
  }

  /** 真去要封面（见 backfillVideoCovers）：一条一条来，拿到就换上并推给界面。 */
  private async runCoverBackfill(tab: number, ids: Array<string>): Promise<void> {
    let filled: number = 0;
    for (let at: number = 0; at < ids.length; at++) {
      const id: string = ids[at];
      const detail: MediaDetail | null = await NativeMediaInfo.detailFor(id);
      if (detail === null || detail.images.length === 0) {
        continue;
      }
      const cover: string = detail.images[0];
      if (cover.length === 0) {
        continue;
      }
      // 期间列表可能被换过（切页 / 保存后刷新）：按媒体 id 重新找一次，找不到就跳过。
      const state: ProfileTabState = this.tabs[tab];
      let hit: number = -1;
      for (let index: number = 0; index < state.posts.length; index++) {
        if (state.posts[index].mediaId === id) {
          hit = index;
          break;
        }
      }
      if (hit < 0) {
        continue;
      }
      const next: Array<ProfilePost> = state.posts.slice(0);
      next[hit] = state.posts[hit].withCover(cover);
      state.posts = next;
      filled++;
      hilog.info(DOMAIN, TAG, 'cover backfill tab=%{public}d [%{public}d] id=%{public}s → %{public}s',
        tab, hit, id, cover.substring(0, 64));
    }
    if (filled === 0) {
      return;
    }
    // 只有这一段还显示着才推给界面（用户可能已经切走了，判据同 requestMoreFor）。
    if (this.tab === tab) {
      this.syncFrom(this.tabs[tab]);
    }
  }

  /**
   * 后台把某一分页的**缓存队列补满到 PREFETCH_DEPTH 页**（需求："给每个分页做一下缓存页加载"）。
   *
   * 为什么值得：原生 HTTP 一页也要几百毫秒；等用户滑到底再发请求，那一下必然看到"正在加载"。
   * 提前放两页在手边，滑到底就是直接贴上去，同时后台再补 —— 连续滑一直是顺的。
   * 只预取**当前分页**：四个分页都预取会一口气打八个请求，没必要（另外三个分页的第一页
   * 由 prefetchOthersSequential 负责）。每次只发一页（prefetching 闸住并发），拉完自己再调一次补满。
   */
  private prefetchNext(tab: number): void {
    const state: ProfileTabState = this.tabs[tab];
    if (!state.more || state.prefetching || state.nextPages.length >= PREFETCH_DEPTH) {
      return;
    }
    const op: string = this.opNameOf(tab);
    if (op.length === 0) {
      return;
    }
    // 接着队尾翻；队列空时接着"已显示内容"的游标翻。
    const tail: ProfilePostsPage | null = state.nextPages.length > 0
      ? state.nextPages[state.nextPages.length - 1] : null;
    const cursor: string = tail === null ? state.cursor : tail.endCursor;
    if (cursor.length === 0) {
      return;
    }
    state.prefetching = true;
    this.fetchPage(op, cursor, tab).then((page: ProfilePostsPage | null): void => {
      state.prefetching = false;
      if (page !== null && page.posts.length > 0) {
        state.nextPages.push(page);
        hilog.info(DOMAIN, TAG, 'prefetch next tab=%{public}d n=%{public}d depth=%{public}d',
          tab, page.posts.length, state.nextPages.length);
        // 还差就继续补（递归一层，深度由 PREFETCH_DEPTH 封顶）。
        this.prefetchNext(tab);
      }
    }).catch((): void => {
      state.prefetching = false;
    });
  }

  /** 后台拉某一分页的第一页（只写进那一分页的状态，不打扰当前显示）。 */
  private async loadTabInBackground(tab: number, op: string): Promise<void> {
    const state: ProfileTabState = this.tabs[tab];
    const gen: number = this.generation;
    state.loading = true;
    try {
      const page: ProfilePostsPage | null = await this.fetchPage(op, '', tab);
      if (page === null) {
        return;
      }
      // 过期的预取结果不许写（见 stale）：退出登录 / 换账号时在飞的这一发必须丢掉。
      if (this.stale(gen)) {
        hilog.info(DOMAIN, TAG, 'prefetch dropped tab=%{public}d (generation %{public}d → %{public}d)',
          tab, gen, this.generation);
        return;
      }
      state.posts = page.posts;
      state.cursor = page.endCursor;
      state.more = page.hasMore && page.endCursor.length > 0;
      state.loaded = true;
      hilog.info(DOMAIN, TAG, 'prefetch tab=%{public}d n=%{public}d', tab, page.posts.length);
      /*
       * 诊断：把这一段前三条的（shortcode / 是不是视频 / 封面地址前缀）打出来。
       *
       * 排查"收藏分页第一排被刚收藏的视频那一格覆盖"时，光看截屏分不清是
       * "封面地址是 mp4 / 空 / 还是别的页面的图"，这一行能一眼看出来。
       */
      for (let index: number = 0; index < page.posts.length && index < 3; index++) {
        const one: ProfilePost = page.posts[index];
        hilog.info(DOMAIN, TAG,
          'seg tab=%{public}d [%{public}d] code=%{public}s video=%{public}s cover=%{public}s',
          tab, index, one.shortcode, `${one.isVideo}`, one.coverUrl.substring(0, 72));
      }
      // 用户在预取期间已经切到这个分页了：把内容补给他（切过去时还是空的）。
      if (this.tab === tab) {
        this.syncFrom(state);
        this.onStatus(state.posts.length > 0 ? '已加载' : '这个分页还没有内容');
      }
      // 收藏 / 视频那两段里"没有封面的视频"就在这里被补上（见 backfillVideoCovers）——
      // 保存之后刷新走的就是这条路，用户切进收藏时那一排已经是好的。
      this.backfillVideoCovers(tab);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'prefetch tab=%{public}d failed: %{public}s',
        tab, (error as Error).message);
    } finally {
      if (!this.stale(gen)) {
        state.loading = false;
      }
    }
  }

  /** 已存的操作名（给状态行做诊断用）。 */
  private tabDiag(): string {
    return 'mobile';
  }

  /**
   * 确保知道**自己的账号名**（本人这一路发请求之前先拿到它）。
   *
   * 为什么必须提前拿到：模板是按操作名共用的，可能在别人的主页上被抓过 —— 那份模板里的
   * `username` 是别人的。本人这一路要靠 `ProfileTarget.selfName` 把它改回自己
   * （见 ProfileTarget 的类头说明），名字空着就只能原样发 → 显示成别人的资料。
   * 名字从隐藏网页的地址里读（`/用户名/`，见 OWN_PROFILE_SCRIPT），一次桥调用、几百毫秒，
   * 拿到之后一直记着。
   */
  private async ensureOwnName(): Promise<void> {
    if (!this.target.isSelf() || this.ownName.length > 0) {
      return;
    }
    /*
     * **先问移动端**（几百毫秒的一发小请求），网页桥放后面。
     *
     * 以前是反过来的：先跑隐藏网页里的脚本，页面没就绪 / 正在导航时要**等到超时**
     * （几秒）；而这只是在"回放模板"那条兜底路上才需要的东西 —— 用户报的
     * "从新号切回大号，头部数据太慢"里，有一大截就是这里白等的。
     */
    const fast: string = await NativeProfile.selfUsername();
    if (ProfileViewModel.isUsername(fast)) {
      this.ownName = fast;
      this.target = this.target.withSelfName(fast);
      hilog.info(DOMAIN, TAG, 'own name resolved via mobile @%{public}s', fast);
      return;
    }
    try {
      const href: string = await this.bridge.runBridge(OWN_PROFILE_SCRIPT,
        OWN_PROFILE_TIMEOUT_MS, 'own-profile');
      /*
       * ⚠️ **桥返回的不一定是路径**：页面没就绪 / 脚本出错时 `runBridge` 回的是
       * `{"state":"not-ready"}` / `{"state":"error",…}` 这种 JSON 状态串。
       * 以前这里直接 `href.split('/')[0]` 当账号名用 —— 于是 `ownName` 变成
       * `{"state":"not-ready"}` 这串垃圾，紧接着头部一致性校验拿它去比 `xingli_415`，
       * 必然不相等 → **头部被当成"别人的资料"丢掉**，界面上就是
       * 头像空白 + 名字/简介空 + 三个计数全 0（用户刚报的"头部数据没有加载"）。
       * 所以：先认状态串、再校验"像不像账号名"。
       */
      if (href.startsWith('{')) {
        hilog.warn(DOMAIN, TAG, 'own name bridge state=%{public}s', href.substring(0, 80));
      } else {
        const parts: Array<string> = href.split('/').filter((one: string): boolean => one.length > 0);
        const name: string = parts.length > 0 ? parts[0].split('?')[0] : '';
        if (ProfileViewModel.isUsername(name)) {
          this.ownName = name;
          this.target = this.target.withSelfName(name);
          hilog.info(DOMAIN, TAG, 'own name resolved @%{public}s', name);
        } else if (name.length > 0) {
          hilog.warn(DOMAIN, TAG, 'own name rejected (not a username): %{public}s',
            name.substring(0, 40));
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'own name failed: %{public}s', (error as Error).message);
    }
    if (this.ownName.length === 0) {
      hilog.warn(DOMAIN, TAG, 'own name still unknown (mobile + bridge both failed)');
    }
  }

  /**
   * 这段字符串**像不像 Instagram 账号名**（只允许字母/数字/下划线/点，1~40 个字符）。
   *
   * 用途只有一个：挡住"桥返回的 JSON 状态串 / 空串 / 一整段 HTML"被当成账号名塞进
   * `ownName` —— 那会让头部一致性校验永远不通过（见 ensureOwnName 的说明）。
   */
  private static isUsername(name: string): boolean {
    if (name.length === 0 || name.length > 40) {
      return false;
    }
    for (let index: number = 0; index < name.length; index++) {
      const ch: string = name.charAt(index);
      const ok: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
        || (ch >= '0' && ch <= '9') || ch === '_' || ch === '.';
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  /**
   * 确保帖子 + 头部这两条模板都在原生侧（冷启动那条路）。
   *
   * 冷启动必然没有 —— 这时让隐藏网页打开一次自己的主页：页面自己会发那两条查询，
   * 网络钩子把模板交上来（capture）。
   *
   * ⚠️ 判断"有没有模板"要用 **storedJson**（已存模板），不能用 `has()` ——
   * 确保"本人这份状态"属于**当前登录的账号**（见 selfId 的说明）。
   *
   * 换账号时把 `ownName` / `headerVerified` / `header` / `target` 全部作废：
   * 接下来会按新账号重新解析自己是谁、重新取头部 —— 宁可多跑一次，也不许把上一个人的资料
   * 当成"我的"（用户报的"我的页面会出现拿到的不是本账号头部数据"）。
   */
  private async ensureSelfScope(): Promise<void> {
    if (!this.target.isSelf()) {
      return;
    }
    const id: string = await NativeProfile.ownId();
    if (id.length === 0) {
      return;
    }
    if (this.selfId.length === 0) {
      this.selfId = id;
      return;
    }
    if (this.selfId === id) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'self account changed %{public}s → %{public}s → reset 本人缓存',
      this.selfId, id);
    /*
     * **换账号要把四个分页一起清掉**（用户报的"退出登录后注册新账号，分页里还是上一个人的内容"）：
     * 只清头部是不够的 —— `tabs[]` 里每一段都存着 posts / cursor / loaded，
     * 新账号进来 `setTab` 看到 `loaded === true` 就直接铺旧列表，连请求都不发。
     * reset() 会顺手把 generation 自增，在飞的那几发回来也就写不进来了。
     */
    this.reset();
    this.selfId = id;
  }

  private headerFromSnapshot: boolean = false;

  /**
   * 用**落盘快照**先把头部画出来（没有就什么都不做）。
   *
   * 只在"还没有 header"时画：网络那一发回来会正常覆盖它（见 loadHeader）。
   * 快照按账号 id 分开存放 —— 换账号后读的是新账号自己那份，不会串号。
   */
  private paintHeaderSnapshot(): void {
    if (this.header !== null || !this.target.isSelf()) {
      return;
    }
    const uid: string = this.selfId.length > 0 ? this.selfId : NativeProfile.ownIdCached();
    if (uid.length === 0) {
      return;
    }
    const snap: ProfileHeader | null = ProfileHeader.fromJson(AppSettings.loadProfileHeader(uid));
    if (snap === null) {
      return;
    }
    this.header = snap;
    /*
     * ⚠️ 必须记下"这是快照"：`load()` 里"要不要发网络那一发"看的正是 `header === null`。
     * 不记的话快照一画上去就再也不会刷新 —— 真实数据永远停在旧快照上（踩过）。
     */
    this.headerFromSnapshot = true;
    hilog.info(DOMAIN, TAG, 'header snapshot @%{public}s posts=%{public}d',
      snap.username, snap.posts);
    this.emitHeader(snap);
  }

  /**
   * 精选快拍（个人页高光那排）的加载入口与结果。
   *
   * **本人和别人主页都拉**（需求：其他用户主页也要有 highlight 列表）；一发
   * `highlights_tray/<pk>/`，失败就保持空（界面那一排不报错）。
   */
  onHighlights: (items: Array<ProfileHighlight>) => void = (items: Array<ProfileHighlight>): void => {
  };
  private highlightItems: Array<ProfileHighlight> = [];
  /**
   * 高光的**内存缓存**（按主人 id）。
   *
   * 为什么必须有：这一发走的是移动端私有接口，实测 1~3 秒才回来；而"切回同一个主页"
   * 在 IG 里是高频操作（关注列表来回点）。缓存之后第二次进是**当帧出图**，
   * 网络那一发只在缓存缺失时才发。
   */
  private static highlightCache: Map<string, Array<ProfileHighlight>> =
    new Map<string, Array<ProfileHighlight>>();
  private highlightsFor: string = '';
  /** 已经从网页侧拉过歌的账号名（见 fillMusicFromWeb：只试一次）。 */
  private musicTriedFor: string = '';

  highlightsNow(): Array<ProfileHighlight> {
    return this.highlightItems;
  }

  /** 这一页高光的主人 id（本人取 selfId，别人取 target 的 id）。 */
  private highlightsOwnerId(): string {
    if (this.target.isSelf()) {
      return this.selfId.length > 0 ? this.selfId : NativeProfile.ownIdCached();
    }
    return this.target.id;
  }

  private async loadHighlights(): Promise<void> {
    /*
     * 用**这个主页主人的 id**：本人页就是 selfId，别人页是 target 带的 id。
     * 以前这里直接 `if (!target.isSelf()) return` 把别人页整条跳过了 —— 于是别人主页
     * 永远没有高光（界面那一排是空的）。
     */
    const uid: string = this.highlightsOwnerId();
    if (uid.length === 0) {
      return;
    }
    // **缓存命中：当帧就给出去**（不再等网络，也不再受 highlightsFor 去重影响）。
    const cached: Array<ProfileHighlight> | undefined = ProfileViewModel.highlightCache.get(uid);
    if (cached !== undefined) {
      this.highlightItems = cached;
      this.onHighlights(cached);
      // 有缓存就不必每次重发：只有"上次没拉到"时才补一发（见下面的空结果分支）。
      if (cached.length > 0) {
        return;
      }
    }
    if (this.highlightsFor === uid) {
      return;
    }
    this.highlightsFor = uid;
    try {
      const list: Array<ProfileHighlight> = await NativeProfile.highlights(uid);
      if (list.length === 0 || this.staleOfHighlights(uid)) {
        return;
      }
      this.highlightItems = list;
      // 写进缓存（空结果也写：下次进来当帧就知道"这里没有高光"，不必再等 2 秒空白）。
      ProfileViewModel.highlightCache.set(uid, list);
      hilog.info(DOMAIN, TAG, 'highlights n=%{public}d', list.length);
      this.onHighlights(list);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'highlights failed: %{public}s', (error as Error).message);
    }
  }

  /** 这一发回来时账号是不是已经换了（换了就丢掉，别把上一个人的高光画上去）。 */
  private staleOfHighlights(uid: string): boolean {
    const now: string = this.highlightsOwnerId();
    return now !== uid;
  }

  /**
   * 头部说"这个人挂了歌"（`has_music_on_profile`）但接口没给曲目时，去**网页版个人页**
   * 的 HTML 里补一次（见 NativeProfile.fetchMusicByUsername），拿到之后把头部换成带歌的副本、
   * 再通知页面重绘 —— 横幅区那颗音乐胶囊就是这么出现的。
   *
   * 每个账号只试一次（`musicTriedFor`）：那是一发几百 KB 的 HTML，不能反复打。
   */
  private fillMusicFromWeb(header: ProfileHeader): void {
    if (header.music !== null || !header.hasMusicProfile || header.username.length === 0) {
      return;
    }
    if (this.musicTriedFor === header.username) {
      return;
    }
    this.musicTriedFor = header.username;
    hilog.info(DOMAIN, TAG, 'music: fetching from web for @%{public}s', header.username);
    NativeProfile.fetchMusicByUsername(header.username).then((music: ProfileMusic | null): void => {
      if (music === null) {
        return;
      }
      const now: ProfileHeader | null = this.header;
      if (now === null || now.username !== header.username) {
        // 这一发回来时页面已经换人了：丢掉。
        return;
      }
      this.header = now.withMusic(music);
      hilog.info(DOMAIN, TAG, 'music: header updated title=%{public}s', music.title);
      this.emitHeader(this.header);
    }).catch((): void => {
    });
  }

  /**
   * 校正「我有没有关注这个人」（只在别人主页用）。
   *
   * 判据用 `friendships/show_many`（一次能问一批、GET 就通，见 core/NativeFollow）：
   * 头部里那个 `friendship_status.following` 在某些载荷里缺失或是旧值，界面就会
   * "明明已关注却显示关注"。这里拿到权威值后写进本地覆盖表 `FollowState`（其它页面
   * 那颗按钮也跟着对）并把头部换成校正后的副本，再通知页面重绘。
   */
  private verifyOtherFollow(header: ProfileHeader): void {
    const id: string = this.target.id;
    if (id.length === 0) {
      return;
    }
    NativeFollow.statesFor([id]).then((states: Map<string, boolean>): void => {
      const known: boolean | undefined = states.get(id);
      if (known === undefined) {
        return;
      }
      FollowState.remember(id, header.username, known);
      if (header.followedByViewer === known) {
        return;
      }
      const now: ProfileHeader | null = this.header;
      if (now === null || now.username !== header.username) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'follow state corrected @%{public}s → %{public}s',
        header.username, `${known}`);
      this.header = now.withFollowedByViewer(known);
      this.emitHeader(this.header);
    }).catch((): void => {
    });
  }

  /** 拉一次头部（本人的话顺带把快照落盘，见 AppSettings.saveProfileHeader）。 */
  private async loadHeader(): Promise<void> {    // 目标用户是"别人"、但我们只有用户名（没有数字 id）时**不发头部这条**：它的请求体里
    // 目标是用 `id` 表示的，没有 id 就只能原样重发 —— 那会把我自己的资料显示成他的
    // （比"头部空着"糟糕得多）。网格仍然能用（帖子那条按 username 取）。
    if (!this.target.isSelf() && this.target.id.length === 0) {
      hilog.info(DOMAIN, TAG, 'header skipped: target has no numeric id');
      return;
    }
    /*
     * 本人：先确认这份状态属于当前账号（换账号时整份作废，见 ensureSelfScope）。
     *
     * ⚠️ **这里不再等 `ensureOwnName()`**（用户报的"从新号切回大号，头部数据太慢"）：
     * 账号名只给**模板回放**用（请求体里的目标键要按它回正），而移动端那条
     * `users/{pk}/info/` 用的是 Cookie 里的 pk，根本不需要账号名。以前先等它 ——
     * 它要跑一段**隐藏网页里的脚本**（`OWN_PROFILE_SCRIPT`，换账号后网页正在重载，
     * 常常等到超时），头部于是白等好几秒。现在移动端先发，账号名由头部自己带回来
     * （见下面 `this.ownName = native.username`）；真要回放模板时才补它。
     */
    await this.ensureSelfScope();
    /*
     * **头部一律先走 `NativeProfile.fetchHeader`**（它内部就是移动端优先：
     * `users/{pk}/info/` / `users/{username}/usernameinfo/`，**不需要任何模板**；
     * 模板回放只是它的兜底）。
     *
     * 以前这里先判 `NativeProfile.hasTemplate(NativeProfile.OP_HEADER)` —— 没有模板就整段跳过。
     * 于是"新装 / 换账号后模板被清 / 模板过期"的时候，"我的"头部永远是空的，
     * 而且连状态行都不写（用户报的"打开 app 进入我的页面头部数据没有加载"就是这个）。
     */
    // 这一发属于哪个账号代次（见 stale）：**必须在发请求之前**取，exit/reset 之后回来才丢得掉。
    const gen: number = this.generation;
    const startedMs: number = Date.now();
    let native: ProfileHeader | null = await NativeProfile.fetchHeader(this.target);
    if (native === null && !ApiThrottle.blocked(ApiThrottle.MOBILE)) {
      // 偶发的超时 / 抖动：隔 600ms 再来一次（限流期间不重试，见 load 里的同一取舍）。
      hilog.info(DOMAIN, TAG, 'header failed (%{public}s) → retry once',
        NativeProfile.lastDetail());
      await ProfileViewModel.sleep(600);
      native = await NativeProfile.fetchHeader(this.target);
    }
    // 耗时一行（用户报的"头部太慢"：换账号后拿它核对是哪一段在花时间）。
    hilog.info(DOMAIN, TAG, 'header round ms=%{public}d ok=%{public}s detail=%{public}s',
      Date.now() - startedMs, `${native !== null}`, NativeProfile.lastDetail());
    if (native !== null) {
      /*
       * **本人的头部要核对账号名**：模板回放那条是按操作名共用的，如果在别人的主页上抓过一次，
       * 那份模板里的目标是那个人 —— 本人这一路会把别人的资料当成"我的"显示出来
       * （用户报的"我的页面信息错误显示为其他用户"）。
       * NativeProfile 已经会把目标键回正成自己（见 ProfileTarget 的类头），这里再核一道：
       * 回正失败（读不到自己的 id 等）时**宁可当成读取失败**，也不把别人的资料画上去。
       */
      if (this.target.isSelf() && ProfileViewModel.isUsername(this.ownName)
        && native.username.toLowerCase() !== this.ownName.toLowerCase()) {
        hilog.warn(DOMAIN, TAG, 'header mismatch @%{public}s vs own @%{public}s → retry once',
          native.username, this.ownName);
        if (!this.headerVerified) {
          // 只重试一次（移动端那一发偶尔会把旧会话的缓存带回来）。
          this.headerVerified = true;
          await ProfileViewModel.sleep(400);
          await this.loadHeader();
          return;
        }
        this.onStatus('头部读取异常：拿到的不是本账号的资料');
        return;
      }
      if (this.stale(gen)) {
        hilog.info(DOMAIN, TAG, 'header result dropped (generation %{public}d → %{public}d)',
          gen, this.generation);
        return;
      }
      this.header = native;
      // 拿到真数据了：这一份不再是快照（见 paintHeaderSnapshot）。
      this.headerFromSnapshot = false;
      // 本人这一页顺手把自己的账号名记下来：切分页时页面若还没拿到头部（own 传空），
      // 收藏 / 被标注 / 视频那几段就抓不到模板、也没法重抓（见 ownName 的说明）。
      if (this.target.isSelf() && native.username.length > 0) {
        this.ownName = native.username;
        // 名字也是"回正请求体"要用的（见 ProfileTarget.selfName）。
        this.target = this.target.withSelfName(native.username);
        // 落一份快照：下次进「我的」先把这份画上去（见 paintHeaderSnapshot）。
        AppSettings.saveProfileHeader(
          this.selfId.length > 0 ? this.selfId : NativeProfile.ownIdCached(), native.toJson());
      }
      // 头部说"有歌"但没给曲目：去网页侧补一次（见 fillMusicFromWeb）。
      this.fillMusicFromWeb(native);
      hilog.info(DOMAIN, TAG, 'header ok @%{public}s posts=%{public}d',
        native.username, native.posts);
      this.emitHeader(native);
      /*
       * **别人主页的关注状态要以 `show_many` 为准**（用户报的"用户主页的关注状态没有正确显示"）：
       * 头部那个 `friendship_status` 有时缺、有时是旧值，于是界面上"明明关注了却显示关注"。
       * 这里先按头部画出来（不等），再在后台问一次、不一致就静默改过来。
       */
      if (!this.target.isSelf()) {
        this.verifyOtherFollow(native);
      }
      return;
    }
    // 移动端这一发没拿到：如实写到状态行（网页模板回放那条路已随模板机制删除）。
    this.onStatus('头部读取失败：' + NativeProfile.lastDetail());
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
