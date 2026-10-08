/*
 * 内容模型，对应 Barinsta 的 `Media`。
 *
 * 字段只保留浏览帖子所必需的部分，便于后续接入不同服务端时替换解析层。
 */

/**
 * MediaPost 的构造参数。
 *
 * 原构造函数有 10 个必填 + 4 个可选位置参数，映射与补全两处调用点各写一长串实参，
 * 极易错位（归档代码里就已经有一处把 permalink 传进了 shortcode 位）。
 * 改成配置对象后每个字段在调用处都带名字，漏填和错序都由编译器兜住。
 */
export interface MediaPostInit {
  id: string;
  shortcode: string;
  caption: string;
  mediaType: string;
  displayUrl: string;
  likeCount: number;
  commentCount: number;
  takenAtMs: number;
  ownerUsername: string;
  ownerAvatarUrl: string;
  /**
   * 作者的用户 id（关注/取关接口要用它）。
   *
   * IG 的 GraphQL 里这个字段叫 `pk`（也有 `id`），两处解析层都会填；拿不到就是空串，
   * 这时「关注」按钮不可用（没有 id 就发不出请求）。
   */
  ownerId?: string;
  /**
   * 本机是否已关注这位作者（`friendship_status.following`，拿不到时为 false）。
   *
   * 注意：信息流那条 GraphQL 不一定带 `friendship_status`，所以这个值可能只是
   * "我们这边记的状态"（见 FeedViewModel.followStates）。
   */
  ownerFollowing?: boolean;
  /**
   * `ownerFollowing` 是不是**数据源真的说了**。
   *
   * 缺省 true（信息流/个人主页那两条都带 `friendship_status`）；推荐流那条可能没有这个字段，
   * 那时传 false —— Reels 页会自己用 `friendships/show_many` 问一次
   * （见 core/NativeFollow.statesFor）。
   */
  ownerFollowKnown?: boolean;
  /** 可原生播放的视频地址；`blob:` 之类的页面内部地址在映射阶段就会被清空。 */
  videoUrl?: string;
  /** 多图帖的图片列表；单图帖为单元素数组。 */
  imageUrls?: string[];
  liked?: boolean;
  viewCount?: number;
  /**
   * 本机是否把这条转发过。
   *
   * 和 liked 不同：网页侧的接口里**没有**这个字段、DOM 也不渲染状态，读不到只能自己记
   * （见 FeedViewModel.repostedKeys），所以它默认 false、只由「转发按钮」这一条路径写入。
   */
  reposted?: boolean;
  /** 转发数（网页没专门渲染，只能从接口节点里按字段名找，找不到就是 0）。 */
  repostCount?: number;
  /** 分享数（同上）。 */
  shareCount?: number;
  /** 媒体原始宽高（像素）；接口没给就是 0，排版时退回正方形。 */
  mediaWidth?: number;
  mediaHeight?: number;
  /**
   * **下载用**的原始地址（最大的一档）。
   *
   * 展示用的是降级后的（见 core/MediaQuality）：手机上 1080 宽就够，能省下大半流量；
   * 但用户点"下载"要的是原图/原视频，所以解析时把最大的一档也一起留在这里。
   * 多图帖逐张对应 imageUrls；拿不到就是空数组。
   */
  originalImageUrls?: string[];
  /** 下载用的原视频地址（最大的一档）；非视频帖为空串。 */
  originalVideoUrl?: string;
  /**
   * 封面**低一档**地址（约 360px 宽，可能为空）：首屏封面预解码用（见 core/PosterCache）。
   *
   * 和 displayUrl 指向同一张图、只是更小：冷启动先用它解出一张小图垫在真图下面，
   * 真图加载完自然盖住。拿不到（比如网页那条路没带这一档）就是空串 —— 那时不预热，
   * 显示路径完全不受影响。
   */
  thumbUrl?: string;
  /**
   * 多图帖里**最高那张图**的宽高比（w/h；0 = 不知道）。
   *
   * 需求："所有 feeds 流多图片帖子媒体区高度根据高度最高的图片"。
   * 为什么不能只看第一张：多图帖里横竖混排很常见（第一张 4:3、第二张 3:4），
   * 盒子按第一张算的话，滑到竖图那一张就会被裁掉一截（`ImageFit.Contain` 下是留白，
   * 但盒子本身比图矮时图会被压着画）。取**最高**那张的比例 = 最小的 w/h，
   * 盒子按它钉高，所有图都放得下。
   */
  imageAspectMin?: number;
}

export class MediaPost {
  readonly id: string;
  readonly shortcode: string;
  readonly caption: string;
  readonly mediaType: string;
  readonly displayUrl: string;
  readonly likeCount: number;
  readonly commentCount: number;
  readonly takenAtMs: number;
  readonly ownerUsername: string;
  readonly ownerAvatarUrl: string;
  /** 作者用户 id（关注接口用，见 MediaPostInit.ownerId）。 */
  readonly ownerId: string;
  /** 是否已关注该作者（见 MediaPostInit.ownerFollowing）。 */
  readonly ownerFollowing: boolean;
  /**
   * `ownerFollowing` 是**数据源真的说了**，还是只是默认的 false（见 MediaPostInit）。
   */
  readonly ownerFollowKnown: boolean;
  readonly videoUrl: string;
  readonly imageUrls: Array<string>;
  readonly liked: boolean;
  readonly viewCount: number;
  readonly reposted: boolean;
  readonly repostCount: number;
  readonly shareCount: number;
  readonly mediaWidth: number;
  readonly mediaHeight: number;
  /** 下载用的原始图/原视频（见 MediaPostInit 的同名字段）。 */
  readonly originalImageUrls: Array<string>;
  readonly originalVideoUrl: string;
  /** 首屏封面预解码用的低一档封面（见 MediaPostInit.thumbUrl）。 */
  readonly thumbUrl: string;
  /** 多图帖里最高那张图的宽高比（见 MediaPostInit.imageAspectMin；0 = 不知道）。 */
  readonly imageAspectMin: number;

  constructor(init: MediaPostInit) {
    this.id = init.id;
    this.shortcode = init.shortcode;
    this.caption = init.caption;
    this.mediaType = init.mediaType;
    this.displayUrl = init.displayUrl;
    this.likeCount = init.likeCount;
    this.commentCount = init.commentCount;
    this.takenAtMs = init.takenAtMs;
    this.ownerUsername = init.ownerUsername;
    this.ownerAvatarUrl = init.ownerAvatarUrl;
    this.ownerId = init.ownerId ?? '';
    this.ownerFollowing = init.ownerFollowing ?? false;
    this.ownerFollowKnown = init.ownerFollowKnown ?? true;
    this.videoUrl = init.videoUrl ?? '';
    this.imageUrls = init.imageUrls ?? [];
    this.liked = init.liked ?? false;
    this.viewCount = init.viewCount ?? 0;
    this.reposted = init.reposted ?? false;
    this.repostCount = init.repostCount ?? 0;
    this.shareCount = init.shareCount ?? 0;
    this.mediaWidth = init.mediaWidth ?? 0;
    this.mediaHeight = init.mediaHeight ?? 0;
    this.originalImageUrls = init.originalImageUrls ?? [];
    this.originalVideoUrl = init.originalVideoUrl ?? '';
    this.thumbUrl = init.thumbUrl ?? '';
    this.imageAspectMin = init.imageAspectMin ?? 0;
  }

  isVideo(): boolean {
    return this.mediaType === 'video' || this.mediaType === 'clips';
  }

  /**
   * 媒体的宽高比（宽 / 高），用于「宽度铺满、高度按比例」的排版。
   *
   * 接口没给尺寸时返回 1：宁可退回正方形，也不要拿一个猜的比例把画面裁掉。
   * 调用方配合 ImageFit.Contain 使用，即使比例有偏差也只会留白，不会裁剪。
   */
  aspectRatio(): number {
    if (this.mediaWidth > 0 && this.mediaHeight > 0) {
      return this.mediaWidth / this.mediaHeight;
    }
    return 1;
  }
}
