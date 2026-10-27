/*
 * Reels 视频流的数据模型。
 *
 * 数据来自页面侧的小脚本抽取（见 bridge/WebScripts 的 reelsScript）：
 *   .data.xdt_api__v1__clips__home__connection_v2.edges[].node.media
 * 这里的 DTO 就对应那份输出，不镜像 IG 的整棵树。
 */

/** reelsScript 里的一条。 */
export interface ReelDto {
  code?: string;
  /** 媒体数字 id（`pk`）：见 Reel.mediaId（个人主页视频分页要靠它补视频地址）。 */
  id?: string;
  url?: string;
  cover?: string;
  /** 下载用的原视频/原封面（最大的一档）；展示用的 url/cover 已按 core/MediaQuality 降级。 */
  origUrl?: string;
  origCover?: string;
  w?: number;
  h?: number;
  author?: string;
  /** 作者的 pk（Reels 页那颗关注按钮要用，见 Reel.authorId）。 */
  uid?: string;
  avatar?: string;
  verified?: boolean;
  music?: string;
  /** 正文（Reels 页作者行下面那一段，见 Reel.caption）。 */
  caption?: string;
  /**
   * 发布时间（**毫秒**；0 = 这条没给）。
   *
   * 网页脚本（bridge/WebScripts 的 reelsScript）里已经把秒换算成毫秒再回来，见 Reel.takenAtMs。
   */
  takenAt?: number;
  /** 本机点赞了没有（`has_liked`）。 */
  liked?: boolean;
  /** 本机关注这位作者了没有（`user.friendship_status.following`）；没给就是 undefined。 */
  following?: boolean;
  /** 本机收藏了没有（载荷给了 `has_saved` 才有；真机上一般不给，见 Reel.saved）。 */
  saved?: boolean;
  /** 转发数（`media_repost_count`）。 */
  reposts?: number;
  /** 分享数（网页脚本按字段名找到的；找不到就不给 → 0，界面不画）。 */
  shares?: number;
  /** 收藏数（同上；IG 基本不公开这个数字，真机上多半拿不到）。 */
  saves?: number;
  likes?: number;
  comments?: number;
  plays?: number;
}

/** reelsScript 的整包输出。 */
export interface ReelsDto {
  state?: string;
  /** 数据来源：capture=探针抓的页面响应（快路径）/ replay=回放请求 / ...（诊断与计时用）。 */
  src?: string;
  items?: Array<ReelDto>;
  cursor?: string;
  more?: boolean;
  count?: number;
  http?: number;
  keys?: string;
  message?: string;
}

/**
 * 一条 Reel：只要"播视频 + 画封面 + 标作者"需要的字段。
 *
 * **@Observed**：视频地址在"个人主页的视频分页"那条路上是**后补**的（先给封面，进到 Reels 页
 * 之后才去 `/api/v1/media/{id}/info/` 取，见 core/NativeMediaInfo）。所以 `videoUrl` /
 * `originalVideoUrl` 两个字段是可变的，页面上那一块由 `@ObjectLink` 订阅（见 ReelsPage 的
 * ReelSlide）—— 补到地址那一刻**就地重绘**并挂上播放器。
 *
 * 为什么不做成"换一条新 Reel、整列表重报"：ForEach 认的是键，换了对象键没变时它根本不重跑
 * item builder；而把键改成"带有没有视频地址"又会让 Swiper 在重建子节点的过程中把当前页
 * 往前带（实测：一补地址页面自己往下翻一条）。原地改 + @ObjectLink 没有这两个毛病。
 */
@Observed
export class Reel {
  readonly shortcode: string;
  /**
   * 可播放的视频地址（**可变**，见类头的说明）；空 = 还没取到（那时只画封面）。
   */
  videoUrl: string;
  readonly coverUrl: string;
  readonly width: number;
  readonly height: number;
  /** 作者名（**可变**：从私信卡片点开的那条是先有封面、进页后再按短码补数据的，见 ProfileReelsViewModel.ensureDetail）。 */
  author: string;
  /**
   * 作者的**数字 id**（`pk`）。空 = 这一条没给。
   *
   * Reels 页那行"头像 + 账号名"右边的**关注按钮**要用它发 HTTP
   * （见 pages/Index.followReelAuthor）。拿不到就不画那颗按钮。
   */
  readonly authorId: string;
  /** 作者头像（同 author，进页后可能被补上）。 */
  avatarUrl: string;
  readonly isVerified: boolean;
  readonly music: string;
  /**
   * 这条的**正文**（需求：Reels 页作者行下方显示正文，超过两行折叠成" ... 展开"）。
   *
   * 和 `music` 分开：以前个人主页那条路把配文塞进 `music`（那一栏本来是给"音乐名"的），
   * 现在正文有自己的位置，音乐名照旧单独一行。
   */
  caption: string;
  /**
   * 点赞数（**可变**：Reels 页点一下就地 ±1，见 ReelsPage.tapLike）。
   */
  likeCount: number;
  /** 评论数（同 caption：进页后按短码补数据时会就地改）。 */
  commentCount: number;
  /**
   * **转发数**（可变：点一下就地 ±1，见 ReelsPage.tapRepost）。
   *
   * 数据源给了 `media_repost_count` 就填进来；个人主页那条没有这个字段，默认 0。
   */
  repostCount: number;
  /**
   * **分享数**（动作区那颗 `share` 下面的数字）。
   *
   * 数据源给了就填，拿不到就是 **0** —— 那时界面上那一颗数字**整颗不画**（见
   * components/ReelsPage 的 actionColumn）。为什么不显示 "0"：IG 自己的界面在计数为 0 时
   * 也不画这个数字，而且我们这边 0 的语义其实是"载荷没说"，不是"真的没人分享"。
   *
   * 只读：分享按钮点下去只打开转发面板，**不改这个数**（我们不伪造计数）。
   */
  readonly shareCount: number;
  /**
   * **收藏数**（动作区那颗 `bookmark` 下面的数字）。
   *
   * IG 侧基本**不公开**（网页不渲染、clips 载荷里通常连字段都没有），所以实际几乎总是 0
   * → 那一颗数字不画。点收藏同样是**不改这个数**（本机点一下不可能知道全站收藏量）。
   */
  readonly saveCount: number;
  /** 下载用的原视频地址（最大的一档）；为空时退回 videoUrl。**可变**，同 videoUrl。 */
  originalVideoUrl: string;
  /**
   * 这条媒体的**数字 id**（`pk`）。
   *
   * 首页 clips 流用不到它（那条响应直接带 video_versions），但**个人主页的视频分页**要用：
   * 那条查询只给封面、不给视频地址（真机实测，见 core/NativeMediaInfo 的文件头），
   * 得拿 id 去 `/api/v1/media/{id}/info/` 补一次。空串 = 不知道。
   */
  /** 同 author：从私信卡片点开的那条一开始只有短码，进页补到详情后换成真 pk（见 ProfileReelsViewModel.applyDetail）。 */
  mediaId: string;
  /**
   * 本机**点赞了没有**（可变：Reels 页右侧那颗心按它画，点一下乐观翻转）。
   *
   * 数据源（clips 查询）给了 `has_liked` 就填进来；个人主页那条没有这个字段，默认 false。
   */
  liked: boolean;
  /**
   * 本机**转发过没有**（可变）。IG 的响应里没有"本机是否转过"这个字段，只能自己记
   * （同信息流那条：转发成功后置真，见 pages/Index.repostReel）。
   */
  reposted: boolean;
  /**
   * 本机**关注这位作者了没有**（Reels 页作者行右边那颗按钮按它画）。
   *
   * 数据源给了才可信：clips / 个人主页视频 / 搜索推荐三条路的载荷里都可能有
   * `user.friendship_status.following`（见 NativeReels / NativeSearch / ProfileMapper）。
   * 拿不到时它是 false，同时 `followKnown` 也是 false —— 界面据此决定要不要单独问一次
   * （见 NativeFollow.statesFor 与 ReelsPage 的 ReelOverlay.ensureFollowState）。
   */
  following: boolean;
  /**
   * `following` 是**数据源真的说了**，还是只是默认的 false。
   *
   * 为什么不能只看 `following`：不关注和不认识都会是 false，而这两种要区别对待 ——
   * 不认识就该去问一次，不关注就直接画"关注"。
   */
  followKnown: boolean;
  /**
   * 本机**收藏了没有**（可变：Reels 页右侧那颗书签按它画，点一下乐观翻转）。
   *
   * 载荷给了 `has_saved` 就用它；真机上 clips / 个人主页那几条查询一般都不给这个字段
   * （和"不给头像"是同一类稀疏），所以默认 false，之后以 **core/SaveState 的会话覆盖表**为准
   * —— 用户点过之后，无论信息层被重建多少次，那颗书签都还是实心的（见 ReelOverlay）。
   */
  saved: boolean;
  /**
   * 这条的**发布时间**（毫秒；0 = 数据源没给）。
   *
   * 用途：评论面板里那张置顶帖子卡片要显示"x 分钟前 / x 小时前"
   * （见 components/PostCardPanel 的 agoText 与 pages/Index.reelAsPost）。
   *
   * 来源：IG 载荷里的 `taken_at`（移动端 v1 媒体对象是 **Unix 秒**，见
   * core/NativeReels.takenAtMsOf；网页脚本那条把秒 ×1000 之后再回来）。
   * 真机上 clips 这条查询**不一定给**它 —— 拿不到就是 0，卡片那边退回
   * "本机第一次见到这条的时刻"（见 core/ReelSeenTime）。所以它允许是 0，界面按 0 不画。
   */
  readonly takenAtMs: number;

  constructor(shortcode: string, videoUrl: string, coverUrl: string, width: number, height: number,
              author: string, avatarUrl: string, isVerified: boolean, music: string,
              likeCount: number, commentCount: number, originalVideoUrl: string = '',
              mediaId: string = '', authorId: string = '', caption: string = '',
              liked: boolean = false, reposted: boolean = false, repostCount: number = 0,
              following: boolean = false, followKnown: boolean = false,
              saved: boolean = false, takenAtMs: number = 0,
              // 分享数 / 收藏数**追加在末尾**（而不是插到 repostCount 旁边）：这个构造器
              // 已经是 20 个位置参数了，插在中间会让所有调用点整体错位 —— 加在尾部、
              // 带默认值，老调用点一个字都不用改（见 Reel.shareCount / saveCount）。
              shareCount: number = 0, saveCount: number = 0) {
    this.shortcode = shortcode;
    this.videoUrl = videoUrl;
    this.coverUrl = coverUrl;
    this.width = width;
    this.height = height;
    this.author = author;
    this.authorId = authorId;
    this.avatarUrl = avatarUrl;
    this.isVerified = isVerified;
    this.music = music;
    this.caption = caption;
    this.likeCount = likeCount;
    this.commentCount = commentCount;
    this.originalVideoUrl = originalVideoUrl.length > 0 ? originalVideoUrl : videoUrl;
    this.mediaId = mediaId;
    this.liked = liked;
    this.reposted = reposted;
    this.repostCount = repostCount;
    this.following = following;
    this.followKnown = followKnown;
    this.saved = saved;
    this.takenAtMs = takenAtMs > 0 ? takenAtMs : 0;
    this.shareCount = shareCount > 0 ? shareCount : 0;
    this.saveCount = saveCount > 0 ? saveCount : 0;
  }

  /** 能不能播（没有地址就只画封面）。 */
  playable(): boolean {
    return this.videoUrl.length > 0;
  }

  /** 真实宽高比；没给尺寸按竖屏 9:16 兜底（reels 基本都是竖的）。 */
  aspect(): number {
    if (this.width > 0 && this.height > 0) {
      return this.width / this.height;
    }
    return 9 / 16;
  }
}

/** 一页 reels + 游标。 */
export class ReelsPage {
  readonly reels: Array<Reel>;
  readonly endCursor: string;
  readonly hasMore: boolean;

  constructor(reels: Array<Reel>, endCursor: string, hasMore: boolean) {
    this.reels = reels;
    this.endCursor = endCursor;
    this.hasMore = hasMore;
  }
}

/**
 * **ReelsPage 需要的那几件事**（视频流视图模型的契约，见 components/ReelsPage）。
 *
 * 为什么要抽成接口：同一套界面有两个数据来源 ——
 *   ① 首页「视频」标签：clips 首页流（viewmodel/ReelsViewModel）；
 *   ② 「用户 / 我的」页面的**视频分页**点进去的那一页：某个人的视频
 *      （viewmodel/ProfileReelsViewModel，数据来自 ProfileViewModel）。
 * 两者的取数方式完全不同（一个认 clips 那条 GraphQL 与它的游标，一个认个人主页分页那条），
 * 但对界面来说只有这几个动作。让界面认接口，两个视图模型各自实现，就不用为了复用界面
 * 把两套游标硬塞进同一个类里。
 */
export interface ReelStreamVm {
  /** 列表变了（首屏到位 / 又接了一页）。 */
  onReels: (reels: Array<Reel>, hasMore: boolean) => void;
  onBusy: (busy: boolean) => void;
  onStatus: (text: string) => void;
  /** 手上这份列表（组件用它回填，见 ReelsPage.aboutToAppear）。 */
  list(): Array<Reel>;
  isBusy(): boolean;
  hasMore(): boolean;
  /** 当前看到第几条（切页重建时要恢复位置）。 */
  activeIndex(): number;
  setActiveIndex(index: number): void;
  /** 首次取数（手上已经有数据时什么都不用做）。 */
  loadFirst(): Promise<void>;
  /** 再要一页。 */
  requestMore(): Promise<void>;
}

/** small JSON → 模型；拿不到必要字段就返回 null。 */
export class ReelMapper {
  static pageFromJson(raw: string): ReelsPage | null {
    let dto: ReelsDto;
    try {
      dto = JSON.parse(raw) as ReelsDto;
    } catch (error) {
      return null;
    }
    if (dto.state !== 'ok') {
      return null;
    }
    const items: Array<ReelDto> = dto.items ?? [];
    const reels: Array<Reel> = [];
    for (let index: number = 0; index < items.length; index++) {
      const item: ReelDto = items[index];
      const code: string = item.code ?? '';
      // 只收有视频地址的：reels 流的本职就是播视频（封面兜底留给别的页面）。
      if (code.length === 0) {
        continue;
      }
      reels.push(new Reel(code, item.url ?? '', item.cover ?? '', item.w ?? 0, item.h ?? 0,
        item.author ?? '', item.avatar ?? '', item.verified === true, item.music ?? '',
        item.likes ?? 0, item.comments ?? 0, item.origUrl ?? '', item.id ?? '',
        item.uid ?? '', item.caption ?? '', item.liked === true, false, item.reposts ?? 0,
        item.following === true, item.following !== undefined, item.saved === true,
        item.takenAt ?? 0, item.shares ?? 0, item.saves ?? 0));
    }
    return new ReelsPage(reels, dto.cursor ?? '', dto.more === true);
  }
}
