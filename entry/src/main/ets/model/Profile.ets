/*
 * 「我的」页面的数据模型。
 *
 * 注意数据是**页面侧的小脚本抽好之后**回传的（见 bridge/WebScripts 的
 * profileHeaderScript / profilePostsScript）：回的是十几个字段，不是整包 JSON ——
 * 帖子那条查询一条就 70KB+（每条都挂着巨大的 organic_tracking_token），
 * 整包过桥 800KB+ 再原生解析，实测会卡住。
 *
 * 所以这里的 DTO 就是那些脚本的输出形状，直接对应，不再镜像 IG 的整棵结构。
 */

import { MediaPost } from './MediaPost';
import { FollowState } from '../core/FollowState';
import { EngageState } from '../core/NativeEngage';

/** 头部那条脚本的输出。 */
export interface ProfileHeaderDto {
  state?: string;
  username?: string;
  fullName?: string;
  bio?: string;
  link?: string;
  avatar?: string;
  verified?: boolean;
  isPrivate?: boolean;
  followers?: number;
  following?: number;
  posts?: number;
  /** 本机有没有关注他（只有"在网页里回放"那条路会给；原生那条见 NativeProfile.headerOf）。 */
  followedByViewer?: boolean;
  http?: number;
  message?: string;
}

/** 帖子那条脚本里的一条。 */
export interface ProfilePostDto {
  code?: string;
  video?: boolean;
  cover?: string;
  w?: number;
  h?: number;
  likes?: number;
  comments?: number;
}

/** 帖子那条脚本的输出。 */
export interface ProfilePostsDto {
  state?: string;
  items?: Array<ProfilePostDto>;
  cursor?: string;
  more?: boolean;
  count?: number;
  http?: number;
  keys?: string;
  message?: string;
}

/** 页面头部。 */
export class ProfileHeader {
  readonly username: string;
  readonly fullName: string;
  readonly bio: string;
  readonly link: string;
  readonly avatarUrl: string;
  readonly isVerified: boolean;
  readonly isPrivate: boolean;
  readonly followers: number;
  readonly following: number;
  readonly posts: number;
  /**
   * **本机有没有关注这个人**（真机实测：`friendship_status.following`）。
   *
   * 只有"别人主页"用得上（用户主页头部那颗「关注 / 已关注」按钮的初始状态，见 ProfilePage）；
   * 取不到时给 false —— 那颗按钮会先画成「关注」，点一下如果服务端说已经关注了，
   * 会用返回值校正（见 pages/Index.followUser）。
   */
  readonly followedByViewer: boolean;

  constructor(username: string, fullName: string, bio: string, link: string, avatarUrl: string,
              isVerified: boolean, isPrivate: boolean,
              followers: number, following: number, posts: number,
              followedByViewer: boolean = false) {
    this.username = username;
    this.fullName = fullName;
    this.bio = bio;
    this.link = link;
    this.avatarUrl = avatarUrl;
    this.isVerified = isVerified;
    this.isPrivate = isPrivate;
    this.followers = followers;
    this.following = following;
    this.posts = posts;
    this.followedByViewer = followedByViewer;
  }
}

/** 网格里的一条：画格子要用的字段 + **帖子页（feeds 流样式）要用的那一套**。 */
export class ProfilePost {
  readonly shortcode: string;
  /**
   * 这条媒体的**数字 id**（`node.pk` / `node.id`）。
   *
   * 帖子页的点赞/转发要拿它发给 IG（core/NativeEngage 的路径参数就是媒体 id）——
   * 网格本身用不到，但少了它，从帖子页点赞就只能退回"网页驱动"那条慢路。
   */
  readonly mediaId: string;
  readonly isVideo: boolean;
  /**
   * 网格封面（低一档，约 360px，见 core/NativeProfile 的 COVER_WIDTH）。
   *
   * 注意它和下面的 `displayUrl` 是**同一张图的两档**：网格用小的（快），帖子页那张大卡片用
   * displayUrl（清晰）。
   */
  readonly coverUrl: string;
  readonly width: number;
  readonly height: number;
  readonly likeCount: number;
  readonly commentCount: number;
  /**
   * 展示档（约 1080px）的媒体地址 + 下载用的原档。
   *
   * 为什么网格那条数据也要带上它们：用户点一个格子会进**帖子页**，那一页把整个分页整理成
   * feeds 流（需求），卡片要的就是这几个字段 —— 带上之后帖子页**不用再为首屏发任何请求**
   * （数据在网格那次取数里已经拿到了）。
   */
  readonly displayUrl: string;
  readonly imageUrls: Array<string>;
  readonly originalImageUrls: Array<string>;
  readonly videoUrl: string;
  readonly originalVideoUrl: string;
  readonly caption: string;
  readonly ownerUsername: string;
  readonly ownerAvatarUrl: string;
  readonly ownerId: string;
  readonly ownerFollowing: boolean;
  readonly takenAtMs: number;
  /**
   * 多图帖里**最高那张图**的宽高比（w/h；0 = 不知道）。
   *
   * 需求："所有 feeds 流多图片帖子媒体区高度根据高度最高的图片" —— 逐张子媒体量出来的
   * （见 core/NativeProfile.postOf 的 carousel 分支）。单图帖恒为 0（用外层的比例）。
   */
  readonly imageAspectMin: number;
  /** 转发数（`media_repost_count`；载荷没给就是 0）。见 ProfileMapper.toMediaPost。 */
  readonly repostCount: number;

  constructor(shortcode: string, isVideo: boolean, coverUrl: string, width: number, height: number,
              likeCount: number, commentCount: number, displayUrl: string = '',
              imageUrls: Array<string> = [], originalImageUrls: Array<string> = [],
              videoUrl: string = '', originalVideoUrl: string = '', caption: string = '',
              ownerUsername: string = '', ownerAvatarUrl: string = '', ownerId: string = '',
              ownerFollowing: boolean = false, takenAtMs: number = 0, mediaId: string = '',
              imageAspectMin: number = 0, repostCount: number = 0) {
    this.shortcode = shortcode;
    this.mediaId = mediaId.length > 0 ? mediaId : shortcode;
    this.isVideo = isVideo;
    this.coverUrl = coverUrl;
    this.width = width;
    this.height = height;
    this.likeCount = likeCount;
    this.commentCount = commentCount;
    this.displayUrl = displayUrl.length > 0 ? displayUrl : coverUrl;
    this.imageUrls = imageUrls.length > 0 ? imageUrls : (this.displayUrl.length > 0 ? [this.displayUrl] : []);
    this.originalImageUrls = originalImageUrls.length > 0 ? originalImageUrls : this.imageUrls;
    this.videoUrl = videoUrl;
    this.originalVideoUrl = originalVideoUrl.length > 0 ? originalVideoUrl : videoUrl;
    this.caption = caption;
    this.ownerUsername = ownerUsername;
    this.ownerAvatarUrl = ownerAvatarUrl;
    this.ownerId = ownerId;
    this.ownerFollowing = ownerFollowing;
    this.takenAtMs = takenAtMs;
    this.imageAspectMin = imageAspectMin;
    this.repostCount = repostCount;
  }

  /** 真实宽高比；没给尺寸就退回正方形（网格用固定 4:5 裁切，这个值留给详情页用）。 */
  aspect(): number {
    if (this.width > 0 && this.height > 0) {
      return this.width / this.height;
    }
    return 1;
  }

  /**
   * 封面地址**能不能当图片用**。
   *
   * 两种不算：
   *   - 空串（载荷里根本没有 `image_versions2`）；
   *   - **看着就是视频地址**（`.mp4` / `.m4v` / `.mov`）—— 收藏 / 视频那几段偶尔把
   *     `video_versions` 那条 mp4 塞在 cover 位上，`Image` 拿它画出来的是一格花屏 / 纯黑
   *     （真机现象："收藏第一排直接被刚收藏的…覆盖"里那一排坏格子就是这么来的）。
   *
   * 判据只看**路径**那一段：IG 的查询串里带别字样的情况不去猜。
   */
  hasUsableCover(): boolean {
    const url: string = this.coverUrl;
    if (url.length === 0) {
      return false;
    }
    const lower: string = url.toLowerCase();
    const cut: number = lower.indexOf('?');
    const path: string = cut >= 0 ? lower.substring(0, cut) : lower;
    if (path.endsWith('.mp4') || path.endsWith('.m4v') || path.endsWith('.mov')) {
      return false;
    }
    return path.indexOf('/mp4/') < 0;
  }

  /**
   * 复制一条、**只换封面**（视频封面回填用，见 ProfileViewModel.backfillVideoCovers）。
   *
   * 为什么需要它：收藏 / 视频那两段的载荷里，视频经常只给 `video_versions`（mp4），
   * 没有 `image_versions2` —— 网格那一格就没有封面（`cover` 是空串），真机上表现为
   * **一整块黑格子**（更早的版本还会把 mp4 当成图去解，画出来是一格花屏，见 NativeProfile.postOf）。
   * 补封面要按媒体 id 再问一次 `/api/v1/media/{id}/info/`（core/NativeMediaInfo），
   * 拿到之后必须**换掉这一条** —— 而这里的字段都是 readonly，所以在类里复制一份。
   *
   * 传入空串 = 原样返回（调用方不用先判）。
   */
  withCover(cover: string): ProfilePost {
    if (cover.length === 0) {
      return this;
    }
    const display: string = this.displayUrl.length > 0 ? this.displayUrl : cover;
    const images: Array<string> = this.imageUrls.length > 0 ? this.imageUrls : [cover];
    return new ProfilePost(this.shortcode, this.isVideo, cover, this.width, this.height,
      this.likeCount, this.commentCount, display, images, this.originalImageUrls,
      this.videoUrl, this.originalVideoUrl, this.caption, this.ownerUsername,
      this.ownerAvatarUrl, this.ownerId, this.ownerFollowing, this.takenAtMs,
      this.mediaId, this.imageAspectMin, this.repostCount);
  }
}

/** 一页帖子 + 游标。 */
export class ProfilePostsPage {
  readonly posts: Array<ProfilePost>;
  readonly endCursor: string;
  readonly hasMore: boolean;

  constructor(posts: Array<ProfilePost>, endCursor: string, hasMore: boolean) {
    this.posts = posts;
    this.endCursor = endCursor;
    this.hasMore = hasMore;
  }
}

/**
 * **帖子页**要的一份流数据：帖子 + "这一分页还有没有下一页"。
 *
 * 为什么要带上 `hasMore`：帖子页自己不知道视图模型里那条游标链走到哪了 ——
 * 光看"这一次拿回来的条数有没有变多"会误判：翻页可能正被网格占着（那次请求会被记成
 * `wantMore` 延后执行），条数一时没长就被当成"到底了"，帖子页从此再也加载不动
 * （用户报的"还是只能加载分页中已加载的帖子"）。所以结论由视图模型给，页面照着走。
 */
export class ProfileStreamPage {
  readonly posts: Array<MediaPost>;
  readonly hasMore: boolean;

  constructor(posts: Array<MediaPost>, hasMore: boolean) {
    this.posts = posts;
    this.hasMore = hasMore;
  }
}

/** small JSON → 模型。拿不到必要字段就返回 null，由调用方决定怎么提示。 */
export class ProfileMapper {
  /**
   * 网格里的一条 → **信息流卡片用的 `MediaPost`**（帖子页把整个分页铺成 feeds 流时用）。
   *
   * 两份模型字段几乎一一对应，差别是：
   *   - `MediaPost.displayUrl` 用**展示档**（1080），不是网格那张 360 的小图（见 ProfilePost）；
   *   - `imageUrls` 给一张（帖子页卡片按单图铺，多图帖在网格里也只看第一张）；
   *   - 关注状态走 `FollowState.resolve`（本地点过按钮的以本地为准，和首页同一条判据）。
   */
  static toMediaPost(post: ProfilePost, owner: string = '', avatar: string = '',
                     ownerId: string = ''): MediaPost {
    const images: Array<string> = post.imageUrls.length > 0 ? post.imageUrls : [post.displayUrl];
    const isVideo: boolean = post.isVideo || post.videoUrl.length > 0;
    // 作者 id 同理：视频分页那条查询连作者对象都没有，由页面把这一页主人的 id 补进来
    // （Reels 页那颗关注按钮要用，见 ReelsPage.authorRow）。
    const ownerKey: string = post.ownerId.length > 0 ? post.ownerId : ownerId;
    return new MediaPost({
      // 用**真实媒体 id**（点赞/转发那条接口的路径参数就是它）。
      id: post.mediaId.length > 0 ? post.mediaId : `profile-${post.shortcode}`,
      shortcode: post.shortcode,
      caption: post.caption,
      mediaType: isVideo ? 'video' : 'image',
      displayUrl: post.displayUrl,
      likeCount: post.likeCount,
      commentCount: post.commentCount,
      takenAtMs: post.takenAtMs,
      // 作者：帖子自己带的优先；**视频分页那条查询不给作者**（`user` 是空的），
      // 由页面把它知道的主人补进来（见 ProfilePage.ownerName）。
      ownerUsername: post.ownerUsername.length > 0 ? post.ownerUsername : owner,
      ownerAvatarUrl: post.ownerAvatarUrl.length > 0 ? post.ownerAvatarUrl : avatar,
      ownerId: ownerKey,
      // 关注状态：有作者 id 才问覆盖表（没有 id 时问也没意义，见 core/FollowState）。
      ownerFollowing: ownerKey.length > 0 && FollowState.resolve(ownerKey,
        FollowState.resolveName(post.ownerUsername.length > 0 ? post.ownerUsername : owner,
          post.ownerFollowing)),
      videoUrl: post.videoUrl,
      imageUrls: images,
      // **本机点过的赞 / 转发以会话台账为准**（见 core/NativeEngage.EngageState 的说明）：
      // 那两段的载荷不带这两个状态，帖子页翻页又会用视图模型那份重建列表 ——
      // 不查台账的话，用户刚点的赞会被下一次翻页抹掉（"点赞功能失效"）。
      liked: EngageState.likedOf(post.mediaId, false),
      viewCount: 0,
      reposted: EngageState.repostedOf(post.mediaId, false),
      repostCount: post.repostCount,
      shareCount: 0,
      mediaWidth: post.width,
      mediaHeight: post.height,
      originalImageUrls: post.originalImageUrls,
      originalVideoUrl: post.originalVideoUrl,
      // 多图帖的媒体盒子按**最高那张**钉高（见 MediaPostInit.imageAspectMin）。
      imageAspectMin: post.imageAspectMin,
      // 低一档封面（360 那张，就是网格用的 coverUrl）：**首屏封面预解码**用它
      // （见 core/PosterCache）。不填的话这条路径整段跳过，冷启动/进帖子页时先解的就是
      // 1080 那张大图 —— 用户感知就是"封面/头像那一块出来得慢"。
      thumbUrl: post.coverUrl
    });
  }

  static headerFromJson(raw: string): ProfileHeader | null {
    let dto: ProfileHeaderDto;
    try {
      dto = JSON.parse(raw) as ProfileHeaderDto;
    } catch (error) {
      return null;
    }
    const username: string = dto.username ?? '';
    if (dto.state !== 'ok' || username.length === 0) {
      return null;
    }
    return new ProfileHeader(username, dto.fullName ?? '', dto.bio ?? '', dto.link ?? '',
      dto.avatar ?? '', dto.verified === true, dto.isPrivate === true,
      dto.followers ?? 0, dto.following ?? 0, dto.posts ?? 0, dto.followedByViewer === true);
  }

  static postsFromJson(raw: string): ProfilePostsPage | null {
    let dto: ProfilePostsDto;
    try {
      dto = JSON.parse(raw) as ProfilePostsDto;
    } catch (error) {
      return null;
    }
    if (dto.state !== 'ok') {
      return null;
    }
    const items: Array<ProfilePostDto> = dto.items ?? [];
    const posts: Array<ProfilePost> = [];
    for (let index: number = 0; index < items.length; index++) {
      const item: ProfilePostDto = items[index];
      const code: string = item.code ?? '';
      if (code.length === 0) {
        continue;
      }
      posts.push(new ProfilePost(code, item.video === true, item.cover ?? '',
        item.w ?? 0, item.h ?? 0, item.likes ?? 0, item.comments ?? 0));
    }
    return new ProfilePostsPage(posts, dto.cursor ?? '', dto.more === true);
  }
}
