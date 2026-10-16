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
import { ApiRegistry } from '../bridge/ApiRegistry';
import { OWN_PROFILE_SCRIPT, profileHeaderScript, profilePostsScript } from '../bridge/WebScripts';
import { AppConfig } from '../config/AppConfig';
import { NativeProfile, ProfileTarget } from '../core/NativeProfile';
import { ProfileHeader, ProfileMapper, ProfilePostsPage, ProfilePost } from '../model/Profile';
import { MediaPost } from '../model/MediaPost';
import { MediaPrefetch } from '../core/MediaPrefetch';
import { PosterCache } from '../core/PosterCache';
import { MediaDetail, NativeMediaInfo } from '../core/NativeMediaInfo';

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
  private readonly registry: ApiRegistry = ApiRegistry.getInstance();
  private header: ProfileHeader | null = null;
  /** 清空自己（退出登录 / 换账号时调，见 ReelsViewModel.reset 的说明）。 */
  reset(): void {
    this.posts = [];
    this.endCursor = '';
    this.more = true;
    this.busy = false;
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
    // 记下自己的账号名：原生失败要重抓模板时靠它导航到 `/用户名/saved/` 这类地址
    // （见 recaptureAndRetry）。切页时页面会把它一起传进来。
    if (ownUsername.length > 0) {
      this.ownName = ownUsername;
    }
    // 广播出去：标题栏里那条分段按钮（钉住时显示的那条）也要跟着换选中态。
    this.onTab(tab);
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
    if (this.tabOpName().length === 0) {
      // 页面传进来的账号名为空时用自己记下的那份（头部到了就有，见 ownName）——
      // 少了这一步，"头部还没回来就点收藏/被标注"会直接卡在"模板还没有"上不动。
      const owner: string = ownUsername.length > 0 ? ownUsername : this.ownName;
      if (owner.length > 0 && !state.capturing) {
        state.capturing = true;
        this.onStatus('这个分页的接口还没抓到，后台抓一次…');
        // 不 await：抓模板要导航隐藏网页（秒级），不能挡在切页路径上。
        this.captureTab(owner, tab).then((ok: boolean): void => {
          state.capturing = false;
          if (ok) {
            this.load(true);
          } else {
            this.onStatus(`这个分页的接口还没抓到（已存：${this.tabDiag()}）`);
          }
        }).catch((): void => {
          state.capturing = false;
        });
        return;
      }
      this.onStatus(`这个分页的接口模板还没有（已存：${this.tabDiag()}）`);
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
      hilog.info(DOMAIN, TAG, 're-enter tab=%{public}d fresh (%{public}dms) → skip load',
        this.tab, Date.now() - state.loadedAtMs);
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
    const op: string = this.opNameOf(tab);
    if (op.length === 0) {
      // 连模板都没有：先走冷启动那条路（打开一次自己的主页，把默认分页的模板抓下来）。
      const ok: boolean = await this.ensureTemplates();
      if (!ok) {
        this.onStatus('拿不到接口模板');
        return;
      }
      if (this.opNameOf(tab).length === 0) {
        state.posts = [];
        state.more = false;
        if (this.tab === tab) {
          this.syncFrom(state);
        }
        this.onStatus(`这个分页的接口模板还没有（已存：${this.tabDiag()}）`);
        return;
      }
    }
    state.loading = true;
    this.busy = true;
    this.onBusy(true);
    try {
      // 本人：网格请求体的目标键也要回正（见 ensureOwnName），所以发请求前先落实"我是谁"。
      await this.ensureOwnName();
      /*
       * 头部与网格**并发**拉（原来是先把头部拉完再拉网格）。
       *
       * 两条都是原生 HTTP（几百毫秒起），串起来首屏就白等一趟；而用户一眼要看的是**网格**，
       * 头部只是计数与简介。两条互不依赖（头部失败也不影响网格），所以一起发。
       * 页面那边两个回调都只写自己的状态，谁先回来都不影响另一个。
       */
      const headerJob: Promise<void> = this.header === null ? this.loadHeader() : Promise.resolve();
      let page: ProfilePostsPage | null =
        await this.fetchPage(this.opNameOf(tab), state.cursor, tab);
      if (page === null) {
        /*
         * 原生失败最常见的原因是**那份模板过期了**（IG 对旧 doc_id 回一整页 HTML，
         * 见 NativeProfile 的判据）。这时正确的做法不是退回 DOM 回放（收藏 / 被标注 / 视频
         * 那三段回放出来的数据没有媒体 id 与作者，见 fetchPage 的说明），而是
         * **重新抓一次这一段的模板再试一遍原生**。
         *
         * 抓模板要导航隐藏网页（秒级），所以只在"真的失败了"之后做，而且只做一次。
         */
        page = await this.recaptureAndRetry(tab, state);
      }
      await headerJob;
      if (page === null) {
        // 带上诊断：这个项目的 hilog 常被系统刷掉，界面上的这一行是可靠的排查通道。
        // 原生与回放分开写，一眼能看出是"请求没成"还是"回放没跑起来"。
        this.onStatus(`读取失败：native=${this.diag} ${this.replayDiag}`);
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
    } catch (error) {
      // 这里必须吞掉并记下来：异常一旦从这里跑出去，页面上的 aboutToAppear 是
      // "发了就不管"的调用，用户只会看到永远空白的页，日志里也什么都没有。
      hilog.warn(DOMAIN, TAG, 'load threw: %{public}s', (error as Error).message);
      this.onStatus('加载出错');
    } finally {
      // 走过冷启动就一定要把网页送回首页，否则首页信息流会被留在"我的主页"上（见 returnToFeed）。
      if (this.usedColdPath) {
        this.returnToFeed();
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
   * 拉一页：**原生 HTTP 优先**，回放只给「帖子」那一段兜底（见 fetchPage 的说明）。
   *
   * @param tab 这一页属于哪一段（决定要不要允许 DOM 回放兜底，见 fetchPage）。
   */
  private async fetchPage(op: string, cursor: string,
                          tab: number = PROFILE_TAB_POSTS): Promise<ProfilePostsPage | null> {
    if (NativeProfile.hasTemplate(op)) {
      const page: ProfilePostsPage | null = await NativeProfile.fetchPosts(op, cursor, this.target);
      if (page !== null) {
        hilog.info(DOMAIN, TAG, 'posts native op=%{public}s n=%{public}d more=%{public}s',
          op, page.posts.length, page.hasMore ? 'y' : 'n');
        return page;
      }
      // 原生失败的原因要带出去：界面上那行状态就是排查通道（hilog 会被系统刷掉）。
      this.diag = 'native:' + NativeProfile.lastDetail();
      hilog.info(DOMAIN, TAG, 'posts native failed op=%{public}s why=%{public}s → replay',
        op, NativeProfile.lastDetail());
    }
    // 别人主页**不走回放兜底**：回放是把模板原样重发（页面脚本只合并顶层的 after / username），
    // 视频那条的目标用户藏在 `data.target_user_id` 里改不动 —— 回放出来会是我的内容显示在他的
    // 主页上（比读不出来糟糕得多）。原生那条已经能覆盖四个分页，失败就如实报错。
    if (!this.target.isSelf()) {
      this.replayDiag = 'replay-skipped(not-self)';
      return null;
    }
    /*
     * **只有「帖子」那一段允许 DOM 回放兜底**。
     *
     * 回放读的是网页 DOM 上那一屏格子，而 `ProfilePostsDto` 里**只有
     * code/video/cover/w/h/likes/comments** —— 没有媒体 id、没有作者、没有头像
     * （见 model/Profile 的说明）。对「帖子」段这些字段本来也不参与点赞/转发（那一段
     * 走的是信息流卡片，媒体 id 来自别处），但**收藏 / 被标注 / 视频**这三段就靠它：
     *   - 用户看到的是"头像空着"（ownerUsername / avatarUrl 都是空串）；
     *   - 点赞 / 转发拿不到真实媒体 id（`ProfileMapper.toMediaPost` 只能塞一个
     *     `profile-<shortcode>` 占位 id），原生那发必然被 IG 拒 → 掉回网页驱动那条慢路，
     *     用户感知就是"点了半天没反应"。
     * 所以这三段**宁可如实报"读取失败"**（状态行会说明），也不拿这种数据顶上去 ——
     * 用户报的"收藏和被标注的帖子页面要正确显示头像、点赞/转发要能发出去"就是这一条。
     */
    if (tab !== PROFILE_TAB_POSTS) {
      this.replayDiag = 'replay-skipped(no-media-id)';
      hilog.info(DOMAIN, TAG, 'replay skipped tab=%{public}d (needs native http)', tab);
      return null;
    }
    return this.fetchPostsWithRetry(op, cursor);
  }

  /**
   * 四个分页模板的结构摘要（探针面板那颗「存个人页四页模板」跑完顺手落一份）。
   *
   * 为什么值得落：三个新分页"请求成功但解析出 0 条"和"请求本身就失败"是两种毛病，
   * 这一份摘要把每条分页的 data 键、连接、第一条 edge 里媒体挂在哪全写出来，
   * 照着它写/改解析就不用猜。
   */
  async digestTabs(): Promise<string> {
    const ops: Array<string> = [NativeProfile.OP_HEADER, NativeProfile.OP_POSTS];
    for (let tab: number = 1; tab < this.tabs.length; tab++) {
      const op: string = this.opNameOf(tab);
      if (op.length > 0 && ops.indexOf(op) < 0) {
        ops.push(op);
      }
    }
    // 再把**所有**名字里带 Profile 的模板都带上：四个分页的键名认不出来时，
    // 真正的"带媒体那条"可能就藏在别的名字里（实测见过 `..._connection` 这种变体）。
    const names: Array<string> = this.registry.storedNames();
    for (let index: number = 0; index < names.length; index++) {
      if (names[index].indexOf('Profile') >= 0 && ops.indexOf(names[index]) < 0) {
        ops.push(names[index]);
      }
    }
    return await NativeProfile.digest(ops);
  }

  /** 当前分页对应的操作名（认不出返回空串）。 */
  private tabOpName(): string {
    return this.opNameOf(this.tab);
  }

  /** 某个分页对应的操作名（认不出返回空串）。 */
  private opNameOf(tab: number): string {
    if (tab === PROFILE_TAB_POSTS) {
      // 帖子这条是**已知**的：抓到的模板就是它。
      return NativeProfile.hasTemplate(NativeProfile.OP_POSTS) ? NativeProfile.OP_POSTS : '';
    }
    const keys: Array<string> = [TAB_PATTERNS[tab]];
    const names: Array<string> = this.registry.storedNames();
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      if (name.indexOf('Profile') < 0) {
        continue;
      }
      const lower: string = name.toLowerCase();
      // 已经用掉的三个已知操作名不参与匹配（PageContent / Posts / NoteBubble…），
      // 免得"帖子"那条被当成别的分页。
      if (lower.indexOf('pagecontent') >= 0 || lower.indexOf('postsquery') >= 0
        || lower.indexOf('note') >= 0 || lower.indexOf('storyhighlights') >= 0
        || lower.indexOf('suggestedusers') >= 0 || lower.indexOf('insights') >= 0
        || lower.indexOf('badge') >= 0) {
        continue;
      }
      if (lower.indexOf(keys[0]) >= 0) {
        return name;
      }
    }
    return '';
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

  /** 后台拉某一分页的第一页（只写进那一分页的状态，不打扰当前显示）。 */  private async loadTabInBackground(tab: number, op: string): Promise<void> {
    const state: ProfileTabState = this.tabs[tab];
    state.loading = true;
    try {
      const page: ProfilePostsPage | null = await this.fetchPage(op, '', tab);
      if (page === null) {
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
      state.loading = false;
    }
  }

  /** 已存的操作名（给状态行做诊断用）。 */
  private tabDiag(): string {
    return this.registry.storedNames().join('/');
  }

  /**
   * 原生那发失败之后：**重新抓一次这一段的模板，再试一遍原生**（调用点见 load）。
   *
   * 为什么要它：模板是有寿命的（IG 换了 doc_id 之后旧模板会被回一整页 HTML，见
   * NativeProfile 的判据），而收藏 / 被标注 / 视频这三段**没有可用的回放兜底**
   * （回放数据里没有媒体 id 与作者，见 fetchPage 的说明）—— 不重抓一次的话，用户看到的
   * 就是"读取失败"，或者更糟：一堆头像空着、点赞转发发不出去的帖子。
   *
   * 抓完**顺手重发一次**：`captureTab` 会把隐藏网页送回首页，而模板已经落在原生侧了，
   * 所以这一次重试不会再碰网页。
   */
  private async recaptureAndRetry(tab: number, state: ProfileTabState): Promise<ProfilePostsPage | null> {
    if (this.ownName.length === 0) {
      // 不知道自己的账号名就抓不了（抓模板要导航到 /用户名/saved/）。
      return null;
    }
    /*
     * `tab` 由调用方传进来（审计 G1）：原来这里读 `this.tab` —— 而它的上游（`load`）
     * 已经 await 过好几次，用户切页之后就会给**另一个分页**抓模板 + 重试，
     * 拿回来的帖子还会被写进那一页。
     */
    this.onStatus('这一段读失败，正在重新抓模板…');
    const ok: boolean = await this.captureTab(this.ownName, tab);
    if (!ok) {
      return null;
    }
    const op: string = this.opNameOf(tab);
    if (op.length === 0) {
      return null;
    }
    hilog.info(DOMAIN, TAG, 'recapture tab=%{public}d op=%{public}s → retry native', tab, op);
    return await this.fetchPage(op, state.cursor, tab);
  }

  /**
   * 把隐藏网页导航到某个分页的地址并抓一次模板。
   *
   * 为什么是"导航"而不是"点网页上的分页按钮"：IG 网页上那四个分页就是四个 URL
   * （`/用户名/reels/`、`/用户名/saved/`、`/用户名/tagged/`），直接导航比在 DOM 里找按钮稳得多，
   * 页面自己会把对应的查询发出去，网络钩子把模板交上来（capture）。
   *
   * **别人主页上抓的时候只抓那一条分页查询**（`filter` 见 tabCaptureFilter）：模板是**按操作名
   * 共用**的，把"别人的那一发"整包存下来会把 `PolarisProfilePageContentQuery` 也覆盖成
   * 他的目标 —— 之后"我的"页照着那份模板发请求，就会显示成别人的资料（用户报过）。
   * 自己的主页上抓则是整包抓（那一份本来就是我自己的）。
   *
   * 只抓这一件事：抓完由调用方（setTab / 探针按钮）继续。失败也不抛 —— 状态行会说明。
   */
  async captureTab(username: string, tab: number): Promise<boolean> {
    if (username.length === 0) {
      return false;
    }
    const suffix: string = tab === PROFILE_TAB_REELS ? 'reels/'
      : (tab === PROFILE_TAB_SAVED ? 'saved/' : (tab === PROFILE_TAB_TAGGED ? 'tagged/' : ''));
    const url: string = `${AppConfig.INSTAGRAM_HOME_URL.replace(/\/$/, '')}/${username}/${suffix}`;
    const filter: string = this.target.isSelf() ? '' : ProfileViewModel.tabCaptureFilter(tab);
    hilog.info(DOMAIN, TAG, 'capture tab=%{public}d url=%{public}s filter=%{public}s',
      tab, suffix.length > 0 ? suffix : '-', filter.length > 0 ? filter : '(all)');
    try {
      this.bridge.loadUrl(url);
      await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
      await ProfileViewModel.sleep(HYDRATE_WAIT_MS);
      // 抓**全部**操作名（filter 传空串），并且抓两轮：那三个分页的网格请求实测**晚于**
      // 首屏信息请求（第一轮只抓到 `fetch__XDTUserDict` 那种），隔一会儿再抓一次才抓得齐。
      let ok: boolean = await this.registry.capture(filter);
      await ProfileViewModel.sleep(CAPTURE_POLL_GAP_MS);
      const second: boolean = await this.registry.capture(filter);
      ok = ok || second;
      hilog.info(DOMAIN, TAG, 'capture tab=%{public}d ok=%{public}s %{public}s',
        tab, ok ? 'y' : 'n', this.registry.storedSummary());
      // 抓完必须把网页送回首页：它是全 App 共用的，留在个人页会让首页信息流读不出来。
      this.returnToFeed();
      return ok;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'capture tab failed: %{public}s', (error as Error).message);
      this.returnToFeed();
      return false;
    }
  }

  /**
   * 某个分页对应的**模板名片段**（只在别人主页上抓时用，见 captureTab）。
   *
   * 用名字片段而不是整包抓：这几段各自的查询名都带着自己的特征词
   * （`PolarisProfileReelsTabContentQuery` / `SavedPostsTabContentQuery` / `TaggedTabContentQuery`、
   * 帖子那条 `PolarisProfilePostsQuery`），而头部那条 `PolarisProfilePageContentQuery` 一个都不沾
   * —— 于是它不会被别人的那一发覆盖。
   */
  private static tabCaptureFilter(tab: number): string {
    if (tab === PROFILE_TAB_REELS) {
      return 'ReelsTab';
    }
    if (tab === PROFILE_TAB_SAVED) {
      return 'SavedPosts';
    }
    if (tab === PROFILE_TAB_TAGGED) {
      return 'Tagged';
    }
    return 'ProfilePosts';
  }

  /**
   * 重新抓一次**我自己**主页那几条模板（本人头部对不上账号名时用，见 loadHeader）。
   *
   * 走的是自己的主页地址（`/我的用户名/`），所以整包抓是安全的。
   */
  private async captureOwnProfile(): Promise<boolean> {
    await this.ensureOwnName();
    if (this.ownName.length === 0) {
      return false;
    }
    return await this.captureTab(this.ownName, PROFILE_TAB_POSTS);
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
    try {
      const href: string = await this.bridge.runBridge(OWN_PROFILE_SCRIPT,
        OWN_PROFILE_TIMEOUT_MS, 'own-profile');
      const parts: Array<string> = href.split('/').filter((one: string): boolean => one.length > 0);
      if (parts.length > 0) {
        const name: string = parts[0].split('?')[0];
        if (name.length > 0) {
          this.ownName = name;
          this.target = this.target.withSelfName(name);
          hilog.info(DOMAIN, TAG, 'own name resolved @%{public}s', name);
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'own name failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 确保帖子 + 头部这两条模板都在原生侧（冷启动那条路）。
   *
   * 冷启动必然没有 —— 这时让隐藏网页打开一次自己的主页：页面自己会发那两条查询，
   * 网络钩子把模板交上来（capture）。
   *
   * ⚠️ 判断"有没有模板"要用 **storedJson**（已存模板），不能用 `has()` ——
   * 后者查的是**接口索引**（操作名/URL 那份元信息，按 TTL 从页面同步来的），
   * 刚 capture 完索引还没同步，会误判成"没有"直接放弃（实测就是界面一直显示
   * "拿不到接口模板"的原因）。
   */
  private async ensureTemplates(): Promise<boolean> {
    this.usedColdPath = false;
    if (this.hasTemplates()) {
      return true;
    }
    this.onStatus('首次加载：正在读取网页');
    // 先等网页就绪再做"自己的主页地址"那一步。
    await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    let href: string = '';
    for (let attempt: number = 1; attempt <= OWN_PROFILE_ATTEMPTS; attempt++) {
      try {
        href = await this.bridge.runBridge(OWN_PROFILE_SCRIPT, OWN_PROFILE_TIMEOUT_MS, 'own-profile');
      } catch (error) {
        href = '';
      }
      if (href.length > 1 && href.charAt(0) === '/') {
        break;
      }
      hilog.info(DOMAIN, TAG, 'own-profile try=%{public}d empty', attempt);
      if (attempt < OWN_PROFILE_ATTEMPTS) {
        await ProfileViewModel.sleep(OWN_PROFILE_GAP_MS);
      }
    }
    const base: string = AppConfig.INSTAGRAM_HOME_URL.replace(/\/$/, '');
    const url: string = href.length > 1 && href.charAt(0) === '/'
      ? base + href
      : AppConfig.INSTAGRAM_HOME_URL;
    hilog.info(DOMAIN, TAG, 'cold path url=%{public}s (own=%{public}s)',
      url === AppConfig.INSTAGRAM_HOME_URL ? 'home-fallback' : 'profile', href.length > 1 ? 'y' : 'n');
    this.bridge.loadUrl(url);
    // 这一轮走了冷启动，读完要把网页送回首页（见 returnToFeed）—— 标记立刻立起来，
    // 后面无论成功失败（哪怕导航一直不就绪），收尾那一步都能知道"网页被我导航走了"。
    this.usedColdPath = true;
    await this.bridge.awaitPageReady(NAV_READY_TIMEOUT_MS);
    // 先等一段水合时间再抓第一次（页面这时候才刚把查询发出去）。
    await ProfileViewModel.sleep(HYDRATE_WAIT_MS);
    let stored: boolean = false;
    for (let attempt: number = 1; attempt <= CAPTURE_POLLS; attempt++) {
      stored = await this.registry.capture(CAPTURE_FILTER);
      if (this.hasTemplates()) {
        hilog.info(DOMAIN, TAG, 'cold path templates ready try=%{public}d %{public}s',
          attempt, this.registry.storedSummary());
        return true;
      }
      if (attempt < CAPTURE_POLLS) {
        await ProfileViewModel.sleep(CAPTURE_POLL_GAP_MS);
      }
    }
    hilog.info(DOMAIN, TAG, 'cold path stored=%{public}s %{public}s',
      stored ? 'y' : 'n', this.registry.storedSummary());
    return this.hasTemplates();
  }

  /**
   * 冷启动那条路读完，把隐藏网页送回首页信息流。
   *
   * 为什么必须送回去：这个隐藏网页是**全 App 共用**的，首页信息流的首屏与翻页都指望它停在
   * 首页 —— 页面内存里那份 feed 请求配置只活在当前文档里。冷启动这条路是整页导航到自己的
   * 主页，读完不管它的话网页就一直留在那儿，之后就变成「首页一条帖子都读不出来」。
   */
  private returnToFeed(): void {
    try {
      this.bridge.loadUrl(AppConfig.INSTAGRAM_HOME_URL);
      hilog.info(DOMAIN, TAG, 'cold path done → back to feed');
    } catch (error) {
    }
  }

  /** 帖子模板在不在（见 ensureTemplates 的说明：要查模板，不是接口索引）。 */
  private hasTemplates(): boolean {
    return NativeProfile.hasTemplate(NativeProfile.OP_POSTS);
  }

  private async loadHeader(): Promise<void> {
    // 目标用户是"别人"、但我们只有用户名（没有数字 id）时**不发头部这条**：它的请求体里
    // 目标是用 `id` 表示的，没有 id 就只能原样重发 —— 那会把我自己的资料显示成他的
    // （比"头部空着"糟糕得多）。网格仍然能用（帖子那条按 username 取）。
    if (!this.target.isSelf() && this.target.id.length === 0) {
      hilog.info(DOMAIN, TAG, 'header skipped: target has no numeric id');
      return;
    }
    // 本人：先把"我是谁"落实（请求体里的目标键要按它回正，见 ensureOwnName）。
    await this.ensureOwnName();
    // 原生优先：模板在就直发（见 NativeProfile）。
    if (NativeProfile.hasTemplate(NativeProfile.OP_HEADER)) {
      const native: ProfileHeader | null = await NativeProfile.fetchHeader(this.target);
      if (native !== null) {
        /*
         * **本人的头部要核对账号名**：模板是按操作名共用的，如果在别人的主页上抓过一次，
         * 那份模板里的目标是那个人 —— 本人这一路会把别人的资料当成"我的"显示出来
         * （用户报的"我的页面信息错误显示为其他用户"）。
         * NativeProfile 已经会把目标键回正成自己（见 ProfileTarget 的类头），这里再核一道：
         * 回正失败（读不到自己的 id 等）时**宁可当成读取失败**，也不把别人的资料画上去。
         */
        if (this.target.isSelf() && this.ownName.length > 0
          && native.username.toLowerCase() !== this.ownName.toLowerCase()) {
          hilog.warn(DOMAIN, TAG, 'header mismatch @%{public}s vs own @%{public}s → ignore',
            native.username, this.ownName);
          if (!this.headerVerified) {
            // 只重抓一次（抓模板要导航隐藏网页）：多半是模板串了别人的目标。
            this.headerVerified = true;
            await this.captureOwnProfile();
            return await this.loadHeader();
          }
          this.onStatus('头部读取异常：拿到的不是本账号的资料');
          return;
        }
        this.header = native;
        // 本人这一页顺手把自己的账号名记下来：切分页时页面若还没拿到头部（own 传空），
        // 收藏 / 被标注 / 视频那几段就抓不到模板、也没法重抓（见 ownName 的说明）。
        if (this.target.isSelf() && native.username.length > 0) {
          this.ownName = native.username;
          // 名字也是"回正请求体"要用的（见 ProfileTarget.selfName）。
          this.target = this.target.withSelfName(native.username);
        }
        hilog.info(DOMAIN, TAG, 'header native @%{public}s posts=%{public}d',
          native.username, native.posts);
        this.onHeader(native);
        return;
      }
      hilog.info(DOMAIN, TAG, 'header native failed → replay');
    }
    // 同 fetchPage：别人主页不走回放兜底（回放是原样重发模板，会把**我的**资料画成他的）。
    if (!this.target.isSelf()) {
      this.onStatus('头部读取失败：' + this.diag);
      return;
    }
    const cfg: string = this.registry.storedJson(NativeProfile.OP_HEADER);
    if (cfg.length === 0) {
      hilog.info(DOMAIN, TAG, 'header: no template');
      return;
    }
    for (let attempt: number = 1; attempt <= EXTRACT_ATTEMPTS; attempt++) {
      let raw: string = '';
      try {
        raw = await this.bridge.runBridge(profileHeaderScript(cfg), EXTRACT_TIMEOUT_MS,
          'profile-header');
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'header bridge threw: %{public}s', (error as Error).message);
        raw = '';
      }
      const header: ProfileHeader | null = ProfileMapper.headerFromJson(raw);
      if (header !== null) {
        // 本人这份也要核对（同上面原生那一路）：回放读的是**当前 DOM**，网页要是正停在
        // 别人的主页上，读回来的就是别人的资料（用户报的"我的页面显示成其他用户"）。
        if (this.target.isSelf() && this.ownName.length > 0
          && header.username.toLowerCase() !== this.ownName.toLowerCase()) {
          hilog.warn(DOMAIN, TAG, 'header replay mismatch @%{public}s vs own @%{public}s → ignore',
            header.username, this.ownName);
          if (!this.headerVerified) {
            this.headerVerified = true;
            await this.captureOwnProfile();
            return await this.loadHeader();
          }
          this.onStatus('头部读取异常：拿到的不是本账号的资料');
          return;
        }
        this.header = header;
        if (this.target.isSelf() && header.username.length > 0) {
          this.ownName = header.username;
          this.target = this.target.withSelfName(header.username);
        }
        hilog.info(DOMAIN, TAG,
          'header replay ok @%{public}s posts=%{public}d try=%{public}d',
          header.username, header.posts, attempt);
        this.onHeader(header);
        return;
      }
      hilog.info(DOMAIN, TAG, 'header try=%{public}d failed raw=%{public}s',
        attempt, raw.substring(0, 120));
      this.diag = '头部第' + attempt + '次未成 raw=' + raw.substring(0, 60);
      await ProfileViewModel.sleep(EXTRACT_RETRY_GAP_MS);
    }
    this.onStatus('头部读取失败：' + this.diag);
  }

  /**
   * 回放兜底：在网页里用同一份模板 fetch 一次，失败自动重试。
   *
   * 为什么要重试：刚导航完（冷启动那一次）网页还在水合，注入脚本经常要等到桥超时都
   * 抢不到执行机会；而页面闲下来之后回放是毫秒级。
   */
  private async fetchPostsWithRetry(op: string, cursor: string): Promise<ProfilePostsPage | null> {
    const firstPage: boolean = cursor.length === 0;
    // 第一页回空时先记着：重试全都还是空，才认它（这个人确实没帖子）。
    let emptyPage: ProfilePostsPage | null = null;
    let page: ProfilePostsPage | null = null;
    for (let attempt: number = 1; attempt <= EXTRACT_ATTEMPTS; attempt++) {
      page = await this.fetchPostsReplay(op, cursor, attempt);
      if (page !== null && page.posts.length > 0) {
        return page;
      }
      if (page !== null && firstPage) {
        emptyPage = page;
      } else if (page === null) {
        // 把最后一次的原因留着（不再往前叠字符串，见 replayDiag 的说明）。
        this.replayDiag = `replay=${this.replayDiag}`;
      }
      if (attempt < EXTRACT_ATTEMPTS) {
        await ProfileViewModel.sleep(EXTRACT_RETRY_GAP_MS);
      }
    }
    return emptyPage;
  }

  private async fetchPostsReplay(op: string, cursor: string,
                                 attempt: number): Promise<ProfilePostsPage | null> {
    const cfg: string = this.registry.storedJson(op);
    if (cfg.length === 0) {
      hilog.info(DOMAIN, TAG, 'posts: no template op=%{public}s', op);
      this.replayDiag = 'no-template';
      return null;
    }
    // 只改游标，**不碰 first**：模板里那条请求本来就带着页面自己用的 first，我们覆盖它纯属
    // 多余动作，而 IG 的 GraphQL 对变量**类型**很挑 —— 覆盖之后服务端直接回
    // `noncoercible_variable_value`、`data` 为 null。
    const vars: string = cursor.length > 0
      ? '{"after":' + JSON.stringify(cursor) + '}'
      : '{"after":null}';
    let raw: string = '';
    try {
      raw = await this.bridge.runBridge(profilePostsScript(cfg, vars), EXTRACT_TIMEOUT_MS,
        'profile-posts');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'posts bridge threw: %{public}s', (error as Error).message);
      return null;
    }
    const page: ProfilePostsPage | null = ProfileMapper.postsFromJson(raw);
    if (page === null) {
      this.replayDiag = 'raw=' + raw.substring(0, 90);
      hilog.info(DOMAIN, TAG, 'posts replay try=%{public}d failed raw=%{public}s',
        attempt, raw.substring(0, 500));
      return null;
    }
    this.replayDiag = '-';
    hilog.info(DOMAIN, TAG, 'posts replay ok op=%{public}s n=%{public}d',
      op, page.posts.length);
    return page;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
