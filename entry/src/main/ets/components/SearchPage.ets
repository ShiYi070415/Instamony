/*
 * 「搜索」原生页面。
 *
 * ## 布局（需求）
 *   - **搜索框不在这里**：它在 HDS 标题栏里（见 pages/Index 的 searchTitleBar），因为
 *     `Search` 的沉浸光感只在标题栏区域生效（官方功耗优化那条限制，见 MaterialSurface
 *     的 SearchSurfaceModifier 说明）。这一页只画**内容**。
 *   - 没关键词 → **推荐帖子**：三列瀑布流（WaterFlow），格子高度按每条封面的宽高比算；
 *   - 有关键词 → 账号结果列表（一行一个：头像 + 用户名 + 全名 + 认证标记）。
 *
 * ## 瀑布流的写法照官方文档来（这一版是重写的，前两版都在"格子尺寸"上踩了坑）
 * 官方《WaterFlow》参考里那条说明是全部要害：
 *   > 当 FlowItem 的**主轴大小在显示后发生变化**时，WaterFlow 会清理受影响的布局信息，
 *   > 并根据 layoutMode 重新计算相关 FlowItem 的布局位置……**表现为位置跳动**。
 *   > 为减少位置跳动，建议**保持 FlowItem 主轴大小稳定**；图片等异步内容建议
 *   > **预先设置固定宽高或占位大小**。
 * 所以：
 *   1. 主轴大小（高度）**写在 FlowItem 上**，而且是**进布局之前就算死的**
 *      （列宽 ÷ 封面自己的比例，见 tileHeight）—— 不能让它跟着"图片量出来多高"走；
 *      官方所有示例也都是 `.width('100%').height(...)` 直接给 FlowItem。
 *   2. 用 `layoutMode: SLIDING_WINDOW`：官方推荐（动态数据、大列表、屏幕旋转都更稳）。
 *   3. 用 `LazyForEach`：官方明确"更推荐"（配 IDataSource，数据换了要通知框架）。
 *   4. 图片在格子里 `100%×100%` + `Cover`：比例一致 ⇒ 不裁画面。
 *
 * ## 配色
 * 全页黑白（page_background / primary_text / secondary_text / field_background），
 * 认证标记也从原来的强调色改成主题前景色 —— 需求："全页面控件以黑白为主题"。
 *
 * ## 取数
 * 都由 SearchViewModel 走原生 HTTP（见它的文件头）；这里只管画，并且把滚动增量报给
 * pages/Index（底栏那两套动画的判据，和 FeedList/ProfilePage 同一个约定）。
 */

import { display } from '@kit.ArkUI';
import { SearchPost, SearchUser } from '../model/Search';
import { SearchViewModel } from '../viewmodel/SearchViewModel';
import { ScrollDelta } from '../core/ScrollReport';
import { MATERIAL_THICKNESS_ULTRA_THIN, SEARCH_BOX_COLLAPSED, SEARCH_BOX_FOCUS_REQUEST,
  SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { PlatformCap } from '../core/PlatformCap';
import { SearchSurfaceModifier, SurfaceModifier } from './MaterialSurface';

/**
 * 顶部让出的高度（vp）= 状态栏 + MINI 标题栏。
 *
 * **搜索框不再住在标题栏里**（需求："模糊只盖到 HDS 标题行"）：它现在是本页顶部的一层浮层
 * （见 searchBoxOverlay），所以这一页的顶部留白分两段 —— 标题栏那一段 + 搜索框那一块。
 */
const SEARCH_BAR_TOP_OFFSET: number = 94;
/** 搜索框那一块的高度（vp）= 框 40 + 上 4 + 下 8（与 pages/Index 里那个数保持一致）。 */
const SEARCH_BOX_BLOCK: number = 52;
/** 让出标题栏 + 搜索框那一块（搜索框收起时只让标题栏）。 */
const SEARCH_TOP_OFFSET: number = SEARCH_BAR_TOP_OFFSET + SEARCH_BOX_BLOCK;
/** 搜索框本体高度（vp，和全 app 的按钮对齐）。 */
const SEARCH_BOX_HEIGHT: number = 40;
/**
 * 内容滚过这么多（vp）就把搜索框收起来（需求："上滑搜索框收缩成按钮到右上角"）。
 *
 * 给一点死区是为了"手指刚碰一下就收"不至于太神经质；回到顶部（偏移 ≤ 0）无条件展开。
 */
const SEARCH_COLLAPSE_AFTER_VP: number = 24;
/** 收放的动画时长（毫秒）：搜索框淡出/缩向右上角，留白同步收掉。 */
const SEARCH_BOX_ANIM_MS: number = 200;
/**
 * 手动叫出搜索框之后，滚过这么多（vp）才算"用户又开始滑了"，可以重新收起。
 *
 * 见 trackSearchBox：展开这一下本身会让页面重新布局（顶部留白 +52vp），随之而来的
 * onDidScroll 会把刚展开的框立刻收回去 —— 用户报的"点击搜索按钮无法唤出搜索框"就是这个。
 */
const SEARCH_MANUAL_RELEASE_VP: number = 6;
/** 搜索框的组件 id：点右上角那颗放大镜时用它要焦点（要了焦点才会拉起输入法）。 */
const SEARCH_FIELD_ID: string = 'instarmony_search_field';
/** 展开之后等这一会儿再去要焦点：得先让搜索框挂上（同一次事件里它还不在树上）。 */
const SEARCH_FOCUS_DELAY_MS: number = 120;
const SEARCH_BOTTOM_OFFSET: number = 96;
/** 头像直径、左右内边距（vp）。 */
const AVATAR_SIZE: number = 48;
const SIDE_PADDING: number = 16;
/** 瀑布流：列数、格子缝隙（vp）。IG 那面网格就是三列细缝密排。 */
const COLUMNS: number = 3;
const GRID_GAP: number = 2;
/** 量不到屏宽时的兜底（vp）。 */
const FALLBACK_WIDTH_VP: number = 360;
/** 瀑布流尾部的固定高度（vp）：转圈/到底提示都住在这条里。 */
const FOOTER_HEIGHT: number = 48;
/**
 * 提前多少条去拉下一页（官方《创建瀑布流》"提前新增数据"那节的做法）。
 * 6 条 ≈ 两行，够在用户真的滑到底之前把新内容接上。
 */
const LOAD_MORE_AHEAD: number = 6;

/**
 * 推荐帖子的数据源（`LazyForEach` 要的 `IDataSource`）。
 *
 * 官方对 WaterFlow 子组件生成的建议是"更推荐 LazyForEach 或 Repeat"；用 LazyForEach 就
 * 必须自己实现数据源，**换数据时要通知框架**（`onDataReloaded`）—— 不通知的话节点会复用
 * 旧数据，表现就是"列表和图对不上"。
 */
class SearchPostSource implements IDataSource {
  private posts: Array<SearchPost> = [];
  private listeners: Array<DataChangeListener> = [];

  totalCount(): number {
    return this.posts.length;
  }

  getData(index: number): SearchPost {
    return this.posts[index];
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

  /**
   * 换一批数据。
   *
   * **能追加就追加**：长度变长且前缀一模一样 = 只是尾巴上多了几条，这时按官方要求用
   * `onDataAdd` 逐条通知（"在数据末尾增加数据后，应使用 onDataAdd 通知……同时避免对已有数据
   * 进行重复处理"）——整面 onDataReloaded 会让已经排好的格子全部重算，滑到底部时就是一顿抖。
   * 其余情况（换关键词、重新拉第一页）才整体重载。
   */
  apply(posts: Array<SearchPost>): void {
    const oldLength: number = this.posts.length;
    let appended: boolean = posts.length > oldLength;
    if (appended) {
      for (let index: number = 0; index < oldLength; index++) {
        if (this.posts[index].code !== posts[index].code) {
          appended = false;
          break;
        }
      }
    }
    this.posts = posts;
    if (appended) {
      for (let index: number = oldLength; index < posts.length; index++) {
        for (let at: number = 0; at < this.listeners.length; at++) {
          this.listeners[at].onDataAdd(index);
        }
      }
      return;
    }
    for (let at: number = 0; at < this.listeners.length; at++) {
      this.listeners[at].onDataReloaded();
    }
  }
}

@Component
export struct SearchPage {
  /** 视图模型：普通属性（页面自己用 @State 存显示用的数据）。 */
  vm: SearchViewModel = new SearchViewModel();
  /** 当前关键词（搜索框在本页，见 searchText）：空 = 推荐态。 */
  @State private searchText: string = '';
  /** 点一个账号：交给页面用网页打开主页。 */
  onOpen: (user: SearchUser) => void = (user: SearchUser): void => {
  };
  /** 点一条推荐帖子：交给页面用网页打开帖子页。 */
  onOpenPost: (post: SearchPost) => void = (post: SearchPost): void => {
  };
  /**
   * 点一条推荐帖子 → 打开 **Reels 页**（需求："把搜索页推荐流实现点击帖子进入带返回的 reels 页面，
   * 底部是评论，点击的帖子显示在第一条，上滑按照浏览 reels 的逻辑运行"）。
   *
   * 参数给的是"当前这份推荐列表 + 点到的那一条在里面的下标"：Reels 页自己把点的那条排到第一条，
   * 后续上滑继续按推荐流的游标翻页（见 pages/Index.openSearchReels）。
   */
  onOpenReels: (posts: Array<SearchPost>, index: number) => void =
    (posts: Array<SearchPost>, index: number): void => {
      // 宿主没接（老行为）：退回"用网页打开这一条"。
      if (index >= 0 && index < posts.length) {
        this.onOpenPost(posts[index]);
      }
    };
  @State private users: Array<SearchUser> = [];
  @State private posts: Array<SearchPost> = [];
  @State private busy: boolean = false;
  @State private status: string = '';
  /** 还有没有下一页（尾部提示与"要不要继续加载"都看它）。 */
  @State private hasMore: boolean = false;
  /** 正在加载下一页（尾部转圈）。 */
  @State private loadingMore: boolean = false;
  /**
   * 瀑布流的可用宽度（vp）。
   *
   * 为什么必须先知道宽度：格子高度 = 列宽 ÷ 封面比例，而**这个高度必须在 FlowItem 进布局
   * 之前就是确定的**（官方那条"主轴大小要稳定"，见文件头）。所以宽度在 aboutToAppear 里
   * 直接量屏幕（和 ProfilePage 量法一致），不靠 onAreaChange 事后回填 —— 事后回填等于
   * "先进布局、再改尺寸"，正是官方说的位置跳动。
   */
  @State private flowWidthVp: number = FALLBACK_WIDTH_VP;
  /** 推荐流的数据源（LazyForEach 要它，见 SearchPostSource）。 */
  private readonly postSource: SearchPostSource = new SearchPostSource();
  /**
   * 搜索框收起来了没有（需求："上滑搜索框收缩成按钮到右上角，点击或者回到顶部时才展开"）。
   *
   * **判据在本页**（见 trackSearchBox / scrollSink）：只有这一页知道内容滚到哪了。
   * 走 AppStorage 是因为右上角那颗放大镜住在 HDS 标题栏里（见 pages/Index 的 menus），
   * 和本页不是同一棵子树 —— 两边只能靠全局这份事实对齐；收起时本页的顶部留白也跟着减掉。
   */
  @StorageProp(SEARCH_BOX_COLLAPSED) @Watch('onCollapsedChanged') private searchBoxCollapsed: boolean =
    false;
  /**
   * "请把搜索框叫出来并进入输入模式"的请求（毫秒时间戳，由 pages/Index 那颗放大镜写）。
   *
   * 用**变化的值**而不是布尔：同一次会话里连点两次也要各弹一次输入法。
   */
  @StorageProp(SEARCH_BOX_FOCUS_REQUEST) @Watch('onFocusRequested') private focusRequestMs: number = 0;
  /** 材质厚度（和全局设定联动，搜索框那层材质底板用它）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) private materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * 这一次展开是**手动的**（点了右上角那颗放大镜）：在用户真的再滑一下之前不许自动收起。
   *
   * 见 trackSearchBox 的说明 —— 展开会让页面重新布局，紧接着来的 onDidScroll 会把刚展开的
   * 框立刻收回去。
   */
  private manualExpand: boolean = false;
  private readonly listScroller: Scroller = new Scroller();
  /** 瀑布流自己的控制器：`currentOffset()` 只对**绑上去的那个容器**有效，不能和 List 共用。 */
  private readonly flowScroller: Scroller = new Scroller();
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
   * 两个滚动容器共用的出口：**先记搜索框的收放，再把事实报给页面**。
   *
   * 必须是箭头属性（而不是普通方法）：`scrollDelta.report` 是当回调调的，普通方法取引用会丢
   * `this`（和 onFeedScroll 同一个理由）。
   */
  private readonly scrollSink: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
      this.trackSearchBox(deltaY, offsetY, scrollState);
      this.onFeedScroll(deltaY, offsetY, scrollState);
    };

  aboutToAppear(): void {
    // 瀑布流宽度：这一层是满屏的（页面没有左右内边距），所以屏宽就是它。
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      const width: number = this.getUIContext().px2vp(dsp.width);
      if (width > 0) {
        this.flowWidthVp = width;
      }
    } catch (error) {
      this.flowWidthVp = FALLBACK_WIDTH_VP;
    }
    this.vm.onUsers = (users: Array<SearchUser>): void => {
      this.users = users;
    };
    this.vm.onPosts = (posts: Array<SearchPost>): void => {
      this.posts = posts;
      // 数据源也要换：LazyForEach 只认数据源，不认这个 @State（@State 只用来判断"空不空"）。
      this.postSource.apply(posts);
    };
    this.vm.onMore = (hasMore: boolean): void => {
      this.hasMore = hasMore;
    };
    this.vm.onLoadingMore = (busy: boolean): void => {
      this.loadingMore = busy;
    };
    this.vm.onBusy = (busy: boolean): void => {
      this.busy = busy;
    };
    this.vm.onStatus = (text: string): void => {
      this.status = text;
    };
    /*
     * **关键词由视图模型反向同步回本页**。
     *
     * 页面渲染看的是本页的 `searchText`（空 = 推荐瀑布流，非空 = 结果列表），而清空关键词这件事
     * 有两个来源：用户点搜索框上那个 ✕，以及**系统返回手势**（Index.onBackPress 里让"有结果时
     * 先回推荐流"，见那里的说明）。后者只能通过视图模型通知过来 —— 不接这个回调的话，
     * 返回后 users 被清空、searchText 还留着，页面就停在"输入账号名开始搜索"的空态上，
     * 而不是回到推荐流。
     */
    this.vm.onQuery = (text: string): void => {
      this.searchText = text;
    };
    // 切 tab 会**重建**这个组件，而取数与"有没有推荐"的状态都留在视图模型里（它一直在）：
    // 先把已有数据回填，避免重新进入时先闪一下空态。
    this.users = this.vm.list();
    this.posts = this.vm.postList();
    this.postSource.apply(this.posts);
    this.busy = this.vm.isBusy();
    this.hasMore = this.vm.hasMorePosts();
    this.loadingMore = this.vm.isLoadingMore();
    // 关键词也回填：切走再切回来时，搜索框里还是上次那个词，下面也还是那批账号结果。
    this.searchText = this.vm.lastQuery();
  }

  // ==========================================================================
  // 搜索框的收放与输入模式
  // ==========================================================================

  /**
   * 搜索框的收放（需求："上滑搜索框收缩成按钮到右上角，点击或者回到顶部时才展开"）。
   *
   * 判定只有两条：
   *   - **回到顶部**（`offsetY <= 0`）→ 展开；
   *   - **内容滚过 SEARCH_COLLAPSE_AFTER_VP** → 收起来（收起来之后再往上滑也不会变）。
   * 中间那一段（0 < offsetY ≤ 死区）保持原样 —— 于是"收起来后轻轻下滑一点"不会又弹开，
   * 真要展开只能点右上角那颗放大镜、或者真的滚回顶部（需求要的正是这两条）。
   *
   * 手动展开（点放大镜）之后有一道**闸**：得等用户真的再滑一下（Scroll 状态、增量超过
   * SEARCH_MANUAL_RELEASE_VP）才允许收起。否则展开引起的重新布局会把刚展开的框立刻收回去
   * —— 就是"页面滚动时点击搜索按钮无法唤出搜索框"。
   */
  private trackSearchBox(deltaY: number, offsetY: number, scrollState: ScrollState): void {
    if (this.manualExpand) {
      if (scrollState !== ScrollState.Scroll || Math.abs(deltaY) <= SEARCH_MANUAL_RELEASE_VP) {
        return;
      }
      this.manualExpand = false;
    }
    if (offsetY <= 0) {
      this.setCollapsed(false);
      return;
    }
    if (offsetY > SEARCH_COLLAPSE_AFTER_VP) {
      this.setCollapsed(true);
    }
  }

  /** 改"搜索框收起来了没有"（先去重：滚动回调一秒几十次，别每帧都写 AppStorage 触发重绘）。 */
  private setCollapsed(collapsed: boolean): void {
    if (this.searchBoxCollapsed === collapsed) {
      return;
    }
    AppStorage.setOrCreate(SEARCH_BOX_COLLAPSED, collapsed);
  }

  /** 收起状态变了（含"回到顶部自动展开"）：手动展开的闸门在自动收起时也要放开。 */
  onCollapsedChanged(): void {
    if (this.searchBoxCollapsed) {
      this.manualExpand = false;
    }
  }

  /**
   * 右上角那颗放大镜被点了：**展开并进入输入模式**（需求："点击搜索按钮时弹出搜索框并进入
   * 输入模式（弹出输入法）"）。
   *
   * 两步：① 把搜索框放出来（置 manualExpand，免得紧接着的滚动回调又把它收走）；
   * ② 隔一小会儿要焦点 —— 要焦点这一步必须在搜索框**挂上之后**做，所以等一帧多一点；
   *    焦点到了输入法会自己起来（官方：`Search` 的 `enableKeyboardOnFocus` 默认为真）。
   */
  onFocusRequested(): void {
    if (this.focusRequestMs <= 0) {
      return;
    }
    this.manualExpand = true;
    this.setCollapsed(false);
    setTimeout((): void => {
      try {
        // 走 UIContext 的 focusController（官方推荐；模块级的 focusControl 会有"UI 上下文
        // 不明确"的问题，而且 @kit.ArkUI 里没有导出它）。
        this.getUIContext().getFocusController().requestFocus(SEARCH_FIELD_ID);
      } catch (error) {
        // 要不到焦点而已（组件还没挂上/被别的页面拿走），不是错误路径。
      }
    }, SEARCH_FOCUS_DELAY_MS);
  }

  /** 提交搜索（回车 / 搜索按钮都走这里；Search 的 onSubmit 和按钮回调给的是同一个词）。 */
  private submitSearch(value: string): void {
    const text: string = value.trim();
    this.searchText = text;
    if (text.length === 0) {
      this.vm.clear();
      return;
    }
    this.vm.search(text);
  }

  /** 一列的宽度（vp）：(瀑布流宽 − 列缝) ÷ 列数。 */
  private columnWidth(): number {
    const inner: number = this.flowWidthVp - GRID_GAP * (COLUMNS - 1);
    return inner > 0 ? inner / COLUMNS : FALLBACK_WIDTH_VP / COLUMNS;
  }

  /**
   * 格子的**主轴大小**（vp，纵向瀑布流就是高度）：列宽 ÷ 格子的比例。
   *
   * 这个数**只依赖数据（封面尺寸）和列宽**，不依赖图片有没有加载完、也不依赖子组件量出来
   * 多高 —— 所以 FlowItem 一进布局就有确定的主轴大小，瀑布流不会因为图片陆续加载而重排
   * （这正是前两版"错位/跳动"的根因，见文件头）。
   *
   * 注意用的是 `tileAspect()` 而不是封面自己的比例：方图/横图会被压到 4:5（需求：给它们
   * 上下加黑边，让整体比 1:1 高），竖图仍然用自己的比例。
   */
  private tileHeight(post: SearchPost): number {
    return this.columnWidth() / post.tileAspect();
  }

  /** 一行账号结果。 */
  @Builder
  userRow(user: SearchUser) {
    Row({ space: 12 }) {
      Image(user.avatarUrl.length > 0 ? user.avatarUrl : $r('app.media.startIcon'))
        .draggable(false)
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .borderRadius(AVATAR_SIZE / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))
      Column({ space: 3 }) {
        Row({ space: 5 }) {
          Text(user.username)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (user.verified) {
            // 认证标记也走主题前景色：全页黑白（需求）。
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(13)
              .fontColor([$r('app.color.primary_text')])
          }
        }
        .width('100%')

        if (user.fullName.length > 0) {
          Text(user.fullName)
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 8, bottom: 8 })
    .onClick((): void => {
      this.onOpen(user);
    })
  }

  /**
   * 一条推荐帖子的**内容**（格子本体与尺寸在 recommendFlow 里给 FlowItem，见那里的说明）。
   *
   * 图怎么铺取决于比例（需求："封面不超过 1:1 的在图片上下添加黑边使整体超过 1:1"）：
   *   - **竖图**（本来就比 4:5 高）：格子比例 = 图自己的比例 ⇒ `Cover` 等于原样铺满，不裁；
   *   - **方图/横图**：格子被压到 4:5 ⇒ 用 `Contain` 按原比例居中放进格子，多出来的上下两条
   *     就是**黑边**（底色 `grid_letterbox` 两个主题下都是纯黑）。用 Cover 会把画面裁掉，
   *     那正是用户之前报的"图片裁剪"。
   */
  @Builder
  tile(post: SearchPost) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image(post.coverUrl)
        .draggable(false)
        .width('100%')
        .height('100%')
        .objectFit(post.letterboxed() ? ImageFit.Contain : ImageFit.Cover)
      // 视频角标：黑白主题下用白图标压在画面上（不引强调色）。
      if (post.isVideo) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(14)
          .fontColor([$r('app.color.on_accent')])
          .margin({ top: 6, right: 6 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(post.letterboxed()
      ? $r('app.color.grid_letterbox') : $r('app.color.field_background'))
    .onClick((): void => {
      // 推荐流点一条 → **带返回的 Reels 页**（需求：点的那条排第一、上滑按 reels 那样翻，
      // 底部是沉浸光感的评论输入框）。宿主没接这条回调时退回老行为（用网页打开帖子）。
      const index: number = this.indexOfPost(post);
      if (index >= 0) {
        this.onOpenReels(this.posts, index);
        return;
      }
      this.onOpenPost(post);
    })
  }

  /** 某条推荐帖子在当前列表里的下标（找不到给 -1）。 */
  private indexOfPost(post: SearchPost): number {
    for (let index: number = 0; index < this.posts.length; index++) {
      if (this.posts[index].code === post.code) {
        return index;
      }
    }
    return -1;
  }

  /**
   * 搜索框本体：**材质底板 + 透明的搜索框**。
   *
   * 为什么要两层：`Search` **不在**"沉浸光感全页面生效"那几个组件里（官方《沉浸光感–功耗优化》：
   * 只有 Slider / Toggle / Select 与弹窗类可以在任意位置生效，其他组件只在 HDS 标题栏里生效）
   * —— 搜索框现在按需求搬出了标题栏（模糊只盖标题栏那一行），摆在内容区的 `Search` 是**不会**
   * 有材质的。而 Toggle 可以，所以底下垫一颗**空的 Toggle** 承载材质（和全 app 的按钮同一套
   * `SurfaceModifier`），搜索框透明地压在上面：材质照样在，形状/阴影也一致。
   *
   * API < 26 时没有系统材质，底板整层不画，搜索框自己那份降级底（`SearchSurfaceModifier` 的
   * "低透明度中性底 + 背景模糊"）接手 —— 不会出现两层糊在一起。
   */
  @Builder
  searchField() {
    Stack({ alignContent: Alignment.Center }) {
      if (PlatformCap.hasArkMaterial()) {
        Toggle({ type: ToggleType.Button, isOn: false })
          .width('100%')
          .height(SEARCH_BOX_HEIGHT)
          .padding(0)
          .borderRadius(SEARCH_BOX_HEIGHT / 2)
          .backgroundColor(Color.Transparent)
          // 选中态也透明（Toggle 默认的 selectedColor 是主题强调色）。
          .selectedColor(Color.Transparent)
          .attributeModifier(new SurfaceModifier(this.materialThickness, false))
          // 底板只是观感：触摸一律让给上面的搜索框（自己不吃、也不阻塞）。
          .hitTestBehavior(HitTestMode.None)
      }
      Search({ value: this.searchText, placeholder: $r('app.string.search_hint') })
        .width('100%')
        .height(SEARCH_BOX_HEIGHT)
        // 点右上角放大镜时要焦点靠它（见 onFocusRequested）。
        .id(SEARCH_FIELD_ID)
        .backgroundColor(Color.Transparent)
        .placeholderColor($r('app.color.secondary_text'))
        .placeholderFont({ size: 14 })
        .textFont({ size: 14 })
        .fontColor($r('app.color.primary_text'))
        .caretStyle({ color: $r('app.color.primary_text') })
        // 搜索按钮：黑白主题（默认是主题强调色），点它等同回车。
        .searchButton($r('app.string.search_action'), { fontSize: 14,
          fontColor: $r('app.color.primary_text') })
        .onChange((value: string): void => {
          this.searchText = value;
          // 清空输入框 = 回到推荐流（那面三列瀑布流）。
          if (value.length === 0) {
            this.vm.clear();
          }
        })
        .onSubmit((value: string): void => {
          this.submitSearch(value);
        })
        // 材质：系统给不了就退成"中性底 + 背景模糊"（见 SearchSurfaceModifier）。
        .attributeModifier(new SearchSurfaceModifier(this.materialThickness))
    }
    .width('100%')
    .height(SEARCH_BOX_HEIGHT)
  }

  /**
   * 搜索框浮层：钉在标题栏正下方那一块（y = SEARCH_BAR_TOP_OFFSET）。
   *
   * 它是本页的一层浮层（不是 HDS 标题栏的 bottomBuilder）—— 这正是"模糊只盖到 HDS 标题行"的
   * 做法：标题栏保持 MINI 高度（94vp，毛玻璃也只铺到这里），搜索框自己带着材质浮在内容之上。
   *
   * 收放动画（需求："搜索框和按钮需要有动画转换"）：淡出 + **缩向右上角**（中心点取右上角，
   * 也就是右上角那颗放大镜的位置），留白同步收掉（见 build 里那段占位）。
   */
  @Builder
  searchBoxOverlay() {
    Column() {
      Row() {
        this.searchField()
      }
      .width('100%')
      .height(SEARCH_BOX_BLOCK)
      .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 4, bottom: 8 })
    }
    .width('100%')
    // 占位：把这一行压到标题栏正下方（和它当初住在标题栏 bottomBuilder 时落点一致）。
    .padding({ top: SEARCH_BAR_TOP_OFFSET })
    // 外层不吃触摸（None = 自身不参与命中测试、子节点照常响应）：只有搜索框那一行要响应。
    .hitTestBehavior(HitTestMode.None)
    .zIndex(4)
    .transition(TransitionEffect.OPACITY
      .animation({ duration: SEARCH_BOX_ANIM_MS, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.9, y: 0.9, centerX: '100%', centerY: '0%' })
        .animation({ duration: SEARCH_BOX_ANIM_MS, curve: Curve.EaseOut })))
  }

  /**
   * 瀑布流的尾部：正在加载下一页时转圈，到底了显示"没有更多了"。
   *
   * 官方《创建瀑布流》里"到达末尾时新增数据"就是这么做的（footer 用 LoadingProgress）。
   */
  @Builder
  flowFooter() {
    Row({ space: 6 }) {
      if (this.loadingMore) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('app.color.secondary_text'))
        Text($r('app.string.profile_loading_more'))
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      } else if (!this.hasMore && this.posts.length > 0) {
        Text($r('app.string.profile_end'))
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
    }
    .width('100%')
    .height(FOOTER_HEIGHT)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 推荐帖子：三列瀑布流（写法照官方文档，见文件头的四条）。
   *
   * 属性（`.width('100%')` / `.height(...)`）**写在 FlowItem 上**：官方示例一律如此，
   * 而且"主轴大小"必须是 FlowItem 自己的属性，写进子组件里等于让瀑布流去量子组件、
   * 量完再决定放哪 —— 图片异步加载一变就这么重排。
   *
   * 翻页（需求："上滑到底部时瀑布流不刷新"）：`onScrollIndex` 里**提前**触发下一页
   * —— 官方《创建瀑布流》"提前新增数据"那节写的就是这个做法（等到 onReachEnd 再拉，
   * 滑到底时会先停一下再出新内容，很顿）。
   */
  @Builder
  recommendFlow() {
    WaterFlow({
      scroller: this.flowScroller,
      footer: this.flowFooter(),
      layoutMode: WaterFlowLayoutMode.SLIDING_WINDOW
    }) {
      LazyForEach(this.postSource, (post: SearchPost): void => {
        FlowItem() {
          this.tile(post)
        }
        .width('100%')
        .height(this.tileHeight(post))
      }, (post: SearchPost): string => post.code)
    }
    .columnsTemplate('1fr 1fr 1fr')
    .columnsGap(GRID_GAP)
    .rowsGap(GRID_GAP)
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .contentEndOffset(SEARCH_BOTTOM_OFFSET)
    .clip(false)
    /*
     * 还剩这么多条没露出来就先去拉下一页（提前量，别等真的滑到底）。
     *
     * ⚠️ 原来是"`last + LOAD_MORE_AHEAD >= total` 就拉"，真机上会**一次把推荐流拉到底**
     * （隐藏时瀑布流视口是 0，这个条件永远成立）—— 于是加过一道闸，但闸加过头了：
     * 现在 `onScrollIndex` 只报"可见区间"，滑到底时 last 不再变化、这一回调也就不再触发，
     * 结果就是"19 个格子之后再怎么滑都不加载、连转圈都没有"（用户报的）。
     * 所以改成**触底由 onReachEnd 兜底**（见下面那一段），这里只保留"提前量"这一层。
     */
    .onScrollIndex((first: number, last: number): void => {
      const total: number = this.postSource.totalCount();
      if (!this.hasMore || this.loadingMore || total === 0) {
        return;
      }
      if (last + LOAD_MORE_AHEAD >= total) {
        // **页面可见时才翻页**（见 SearchViewModel.active）：隐藏时视口为 0，会把整条流拉到底。
        this.vm.requestMoreFromScroll();
      }
    })
    // 触底兜底：滑到底（或接近底）一定再要一页 —— 光靠 onScrollIndex 的提前量会漏掉"到底那一下"。
    .onReachEnd((): void => {
      if (!this.hasMore || this.loadingMore) {
        return;
      }
      this.vm.requestMoreFromScroll();
    })
    // 滚动 → 底栏下沉/隐藏 + 搜索框收放（见 scrollSink）。
    .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
      this.scrollDelta.report(this.flowScroller.currentOffset().yOffset, scrollState,
        this.scrollSink);
    })
  }

  /** 账号结果列表。 */
  @Builder
  resultList() {
    List({ space: 0, scroller: this.listScroller }) {
      ForEach(this.users, (user: SearchUser): void => {
        ListItem() {
          this.userRow(user)
        }
      }, (user: SearchUser, index: number): string => `${index}-${user.username}`)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .contentEndOffset(SEARCH_BOTTOM_OFFSET)
    .onDidScroll((scrollOffset: number, scrollState: ScrollState): void => {
      this.scrollDelta.report(this.listScroller.currentOffset().yOffset, scrollState,
        this.scrollSink);
    })
    // **别裁内容**：列表可视区在顶部那层透明占位下面，关掉裁剪后滚动的行才会画到标题栏
    // 底下去（和 FeedList 同一套结构：透明 Stack 避让 + 内容可穿过标题栏）。
    .clip(false)
  }

  /** 空态（没推荐也没结果时的那块提示）。 */
  @Builder
  emptyHint() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(34)
        .fontColor([$r('app.color.secondary_text')])
      Text(this.status.length > 0 ? this.status : $r('app.string.search_empty'))
        .fontSize(14)
        .fontColor($r('app.color.secondary_text'))
        .textAlign(TextAlign.Center)
        .padding({ left: SIDE_PADDING, right: SIDE_PADDING })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 顶部让出标题栏 + 搜索框那一块（见 SEARCH_TOP_OFFSET）。
        // 搜索框收起来时那一块不占位，留白跟着减掉 —— 加 animation 让它和搜索框的淡出同步
        // （不然上面的框在动、下面的内容却是"啪"地跳一下）。
        Stack()
          .width('100%')
          .height(this.searchBoxCollapsed ? SEARCH_BAR_TOP_OFFSET : SEARCH_TOP_OFFSET)
          .animation({ duration: SEARCH_BOX_ANIM_MS, curve: Curve.EaseOut })

        if (this.status.length > 0 && !(this.searchText.length === 0 && this.posts.length > 0)) {
          // 状态行：进度 / 结果条数 / 失败原因（同时是排查通道）。
          // 推荐流已经有内容时不占一行位置（那一句"正在读取推荐…"没必要一直挂着）。
          Text(this.status)
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: SIDE_PADDING, right: SIDE_PADDING, bottom: 6 })
        }

        if (this.searchText.length > 0) {
          if (this.users.length === 0 && !this.busy) {
            this.emptyHint()
          } else {
            this.resultList()
          }
        } else {
          if (this.posts.length === 0) {
            this.emptyHint()
          } else {
            this.recommendFlow()
          }
        }
      }
      .width('100%')
      .height('100%')

      // 搜索框：**本页的浮层**，画在内容之上、标题栏之下（见 searchBoxOverlay）。
      if (!this.searchBoxCollapsed) {
        this.searchBoxOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
