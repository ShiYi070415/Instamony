/*
 * 搜索页的模型。
 *
 * 字段名与页面脚本（WebScripts.searchResultsScript）一一对应：脚本在页面里按**形状**扫出用户对象
 * （有 username + profile_pic_url/full_name），原生只做映射。
 */

/** 拿不到尺寸时用的宽高比（宽/高，4:5）：IG 上最常见的一档竖图。 */
// 逐页媒体（轮播）用的就是时间线那份 DTO，见 SearchPost.mediaItems。
import { FeedMediaItemDto } from './FeedDto';

const DEFAULT_ASPECT: number = 0.8;
/** 比例的安全边界（防脏数据把格子拉成一根柱子，见 SearchPost.aspect）。 */
const MIN_ASPECT: number = 0.4;
const MAX_ASPECT: number = 2.5;
/**
 * **方图/横图的格子比例**（宽/高 = 0.8，即 4:5）。
 *
 * 需求："封面不超过 1:1 的在图片上下添加黑边使整体超过 1:1" —— 瀑布流里夹着几张方图/横图时，
 * 格子会比邻居矮一大截，网格看着就是断的。这里的做法是把它们的**格子**一律压到 4:5
 * （比 1:1 高，满足"整体超过 1:1"），图本身按原比例居中，多出来的上下两条就是黑边。
 * 竖图（本来比 4:5 还高）不动，用自己原本的比例铺满 —— 那样才不会被裁。
 */
const WIDE_TILE_ASPECT: number = 0.8;

/** 一条搜索到的用户。 */
export class SearchUser {
  readonly username: string;
  readonly fullName: string;
  readonly avatarUrl: string;
  readonly verified: boolean;
  readonly privateAccount: boolean;
  /**
   * 这个人的**数字 id**（`pk`）。空 = 这条响应没给。
   *
   * 用途：点一下要进**原生用户主页**（需求："把搜索到的用户接入用户显示页面"），
   * 而那一页的头部/分页查询都要靠 id 定位（见 core/NativeProfile.ProfileTarget）。
   * 拿不到 id 时那一页仍能按用户名取网格，只是头部会缺（见 ProfileViewModel.loadHeader）。
   */
  readonly userId: string;

  constructor(username: string, fullName: string, avatarUrl: string,
              verified: boolean, privateAccount: boolean, userId: string = '') {
    this.username = username;
    this.fullName = fullName;
    this.avatarUrl = avatarUrl;
    this.verified = verified;
    this.privateAccount = privateAccount;
    this.userId = userId;
  }

  /** 打开这个人的主页（交给网页）。 */
  profileUrl(): string {
    return `https://www.instagram.com/${this.username}/`;
  }
}


/**
 * 一条**推荐帖子**（搜索页没输入关键词时那面三列瀑布流里的格子）。
 *
 * **宽高是"要显示的那张封面自己的尺寸"**，不是帖子原始尺寸 —— 这一点决定了瀑布流对不对：
 *   - 格子高度按这个比例算 ⇒ 图不会被裁（`ImageFit.Cover` 在比例一致时等于原样铺满）；
 *   - 用原始尺寸（比如视频的 1080×1920）去套一张 4:5 的封面，就会"比例不对 → Cover 硬裁"，
 *     而且所有帖子都拿不到尺寸时会退化成同一个比例，整面网格变成等高格子（都不像瀑布流了）。
 *
 * 尺寸走 core/MediaQuality 那套"展示档"挑选（宽度 ≥ 目标里最小的那一档），
 * 所以 url / width / height 三者永远是一张图自己的三个字段，天然自洽。
 */
export class SearchPost {
  readonly code: string;
  readonly coverUrl: string;
  readonly width: number;
  readonly height: number;
  readonly isVideo: boolean;
  /**
   * 媒体的**数字 id**（`pk`）。空 = 这条没给。
   *
   * 用途：推荐流点开的那一页是 **Reels 页**（需求），而 Reels 播放要"可播地址" ——
   * 推荐那条查询（clips）虽然带 `video_versions`，但个别条目（以及只给封面的情况）要拿 id 去
   * `/api/v1/media/{id}/info/` 补，见 core/NativeMediaInfo。
   */
  readonly mediaId: string;
  /** 视频地址（推荐那条查询里通常就有；空 = 需要按 id 补）。 */
  readonly videoUrl: string;
  /** 下载用的原视频地址（最大的一档）；空则退回 videoUrl。 */
  readonly originalVideoUrl: string;
  /** 作者账号名（推荐流那一格里不显示，但 Reels 页作者行要）。 */
  readonly ownerUsername: string;
  /** 作者头像（Reels 页作者行要）。 */
  readonly ownerAvatarUrl: string;
  /** 作者数字 id（Reels 页那颗关注按钮要用，见 model/Reel 的 authorId）。 */
  readonly ownerId: string;
  /** 正文（Reels 页作者行下方那一段）。 */
  readonly caption: string;
  /**
   * 点赞 / 评论 / **转发**数（Reels 页右侧动作栏那三个计数）。
   *
   * 推荐流那条响应本来就带着它们（和首页 clips 是同形状，见 core/NativeSearch.readPost），
   * 以前这里没接，于是"搜索推荐流点进去的 reels 页"三个计数全是空的（用户报的问题）。
   */
  readonly likeCount: number;
  readonly commentCount: number;
  readonly repostCount: number;
  /** 本机点过赞没有（`has_liked` / `viewer_has_liked`）：有心时那颗心直接是红的。 */
  readonly liked: boolean;
  /**
   * 本机关注这位作者了没有（`user.friendship_status.following`）。
   *
   * undefined = **载荷没给**（不是"没关注"）—— Reels 页据此决定要不要单独问一次
   * （见 model/Reel 的 followKnown 与 core/NativeFollow.statesFor）。
   */
  readonly following?: boolean;
  /**
   * 发布时刻（**Unix 秒**，IG 的 `taken_at`；0 = 这条没给）。
   *
   * 首页把探索流那一段也铺进 FeedList 之后，卡片底部要有"3小时前" +「翻译」那一行
   * （两者同属一行，见 FeedList.postCard）；这里以前压根没带时间，于是探索流的帖子
   * **日期和翻译按钮一起消失**（用户报的问题）。
   * 用法：`SearchPost.takenAt` → `MediaPost.takenAtMs`（×1000，见 Index.searchPostsToMedia）。
   */
  readonly takenAt: number;
  /**
   * **逐页媒体**（多图 / 图文视频混排的轮播帖；≤1 页 = 空数组）。
   *
   * 为什么要有：探索流（`discover/topical_explore/`）里同样有 `carousel_media`，
   * 但这条路以前只取第一张封面 —— 于是探索流的多图帖在 feeds 里永远只显示一张
   * （用户报的"多图片/视频媒体帖子是不是没适配"）。字段形状与时间线那份完全一致，
   * 所以直接用 `FeedMediaItemDto`，再由 `FeedMapper.slidesFromItems` 转成 `MediaSlide[]`。
   */
  readonly mediaItems: Array<FeedMediaItemDto>;
  /**
   * 分享 / 收藏数（`share_count` / `save_count` 等；**0 = 载荷没说**）。
   *
   * 为什么必须在这一层就带上：首页「为你推荐」那一段与搜索推荐流都是把 `SearchPost`
   * 转成 `MediaPost`（见 pages/Index.searchPostsToMedia）—— 这一层丢了，后面 UI 读到的
   * 就永远是 0，列表里那颗分享数**无论载荷给不给都画不出来**。
   * 界面对 0 的处理是"整颗数字不画"（见 components/FeedList 的 PostActions）。
   */
  readonly shareCount: number;
  readonly saveCount: number;

  constructor(code: string, coverUrl: string, width: number, height: number, isVideo: boolean,
              mediaId: string = '', videoUrl: string = '', originalVideoUrl: string = '',
              ownerUsername: string = '', ownerAvatarUrl: string = '', ownerId: string = '',
              caption: string = '', likeCount: number = 0, commentCount: number = 0,
              repostCount: number = 0, liked: boolean = false, following?: boolean,
              takenAt: number = 0, mediaItems: Array<FeedMediaItemDto> = [],
              shareCount: number = 0, saveCount: number = 0) {
    this.code = code;
    this.coverUrl = coverUrl;
    this.width = width;
    this.height = height;
    this.isVideo = isVideo;
    this.mediaId = mediaId;
    this.videoUrl = videoUrl;
    this.originalVideoUrl = originalVideoUrl.length > 0 ? originalVideoUrl : videoUrl;
    this.ownerUsername = ownerUsername;
    this.ownerAvatarUrl = ownerAvatarUrl;
    this.ownerId = ownerId;
    this.caption = caption;
    this.likeCount = likeCount;
    this.commentCount = commentCount;
    this.repostCount = repostCount;
    this.liked = liked;
    this.following = following;
    this.takenAt = takenAt > 0 ? takenAt : 0;
    this.mediaItems = mediaItems;
    this.shareCount = shareCount > 0 ? shareCount : 0;
    this.saveCount = saveCount > 0 ? saveCount : 0;
  }

  /**
   * 格子的宽高比（宽 / 高）：**直接来自封面自己**，缺失时按 4:5（IG 最常见的竖图）。
   *
   * 夹在 [0.4, 2.5] 之间只是防脏数据（比如某条响应把尺寸填成 1×9999）：
   * 真出现那种比例，格子会高得离谱、把整面网格挤成一根柱子。
   */
  aspect(): number {
    if (this.width <= 0 || this.height <= 0) {
      return DEFAULT_ASPECT;
    }
    const ratio: number = this.width / this.height;
    if (ratio < MIN_ASPECT) {
      return MIN_ASPECT;
    }
    return ratio > MAX_ASPECT ? MAX_ASPECT : ratio;
  }

  /**
   * **格子的比例**（宽/高）：竖图用自己的比例，方图/横图压到 4:5（见 WIDE_TILE_ASPECT）。
   *
   * 瀑布流的高度就按这个算，图按 `ImageFit.Contain` 居中放进去 ⇒ 宽图上下自带黑边。
   */
  tileAspect(): number {
    const natural: number = this.aspect();
    return natural > WIDE_TILE_ASPECT ? WIDE_TILE_ASPECT : natural;
  }

  /** 这张封面放进格子时**上下要不要补黑边**（比 4:5 宽 = 要）。 */
  letterboxed(): boolean {
    return this.aspect() > WIDE_TILE_ASPECT;
  }
}

/** 脚本回传的一条。 */
interface SearchUserDto {
  u?: string;
  name?: string;
  avatar?: string;
  verified?: boolean;
  priv?: boolean;
}

/** 脚本回传的整包。 */
interface SearchResultDto {
  state?: string;
  items?: Array<SearchUserDto>;
  count?: number;
  err?: string;
}



