/*
 * 信息流 DTO → 展示模型 的纯映射、去重与补全逻辑。
 *
 * 从 pages/Index.ets 抽出来：这里不碰 ArkUI、不碰页面桥，只做数据变换，
 * 因此不必和 1300 行的页面组件绑在一起。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedItemDto, FeedMediaItemDto } from './FeedDto';
import { MediaPost, MediaSlide } from './MediaPost';
import { FollowState } from '../core/FollowState';

const DOMAIN: number = 0xFF00;
const TAG: string = 'FeedMapper';

/** merge / enrich 的结果：新的帖子数组 + 本次有效变更条数。 */
export class MergeResult {
  readonly posts: MediaPost[];
  readonly changed: number;

  constructor(posts: MediaPost[], changed: number) {
    this.posts = posts;
    this.changed = changed;
  }
}

export class FeedMapper {
  /** 单条 DTO → MediaPost。所有字段做 undefined 兜底。 */
  static toPost(item: FeedItemDto, index: number): MediaPost {
    const shortcode: string = item.shortcode ?? '';
    const id: string = (item.id ?? '').length > 0 ? item.id : `feed-${index}`;
    const images: string[] = item.images ?? [];
    const poster: string = item.poster ?? '';
    const displayUrl: string = poster.length > 0
      ? poster
      : (images.length > 0 ? images[0] : '');
    const rawVideo: string = item.videoUrl ?? '';
    // blob: 是页面内部的对象地址，原生播放器拿不到，一律当作没有视频。
    const playable: string = rawVideo.startsWith('blob:') ? '' : rawVideo;
    const isVideo: boolean = (item.hasVideo ?? false) || playable.length > 0;
    /*
     * 诊断（只打多图帖）：逐页媒体到底有没有到原生侧、里面有几页视频、最高那页的比例是多少。
     * "多图含视频"这条路有没有数据在走，看这一行就够了。
     */
    const slides: Array<MediaSlide> = FeedMapper.toSlides(item);
    if (images.length > 1) {
      let videos: number = 0;
      for (let at: number = 0; at < slides.length; at++) {
        if (slides[at].isVideo()) {
          videos++;
        }
      }
      hilog.info(DOMAIN, TAG,
        'slides key=%{public}s imgs=%{public}d raw=%{public}d pages=%{public}d videos=%{public}d aspectMin=%{public}s',
        shortcode, images.length, (item.mediaItems ?? []).length, slides.length, videos,
        (item.aspectMin ?? 0).toFixed(3));
    }
    return new MediaPost({
      id: id,
      shortcode: shortcode,
      caption: item.caption ?? '',
      mediaType: isVideo ? 'video' : 'image',
      displayUrl: displayUrl,
      likeCount: item.likes ?? 0,
      commentCount: item.comments ?? 0,
      takenAtMs: item.takenAt ?? 0,
      ownerUsername: item.username ?? '',
      ownerAvatarUrl: item.avatar ?? '',
      // 关注按钮要用：作者 id（接口里的 pk）与"是否已关注"（friendship_status.following）。
      // **本地点过按钮的以本地为准**（见 core/FollowState）：接口那份是取数那一刻的快照，
      // 刷新/切页拿回来常常还是旧值，直接用它会把刚点的状态顶回去。
      ownerId: item.userId ?? '',
      ownerFollowing: FollowState.resolve(item.userId ?? '',
        FollowState.resolveName(item.username ?? '', item.following ?? false)),
      /*
       * **数据源到底说没说**这件事必须记下来（需求："非关注状态的用户帖子不要显示在关注流中"）。
       *
       * 时间线给的 `friendship_status.following` 有时**整个字段都没有**（推荐卡片、稀疏载荷），
       * 这时 `ownerFollowing` 只是个默认的 false —— 拿它当"没关注"就会把正常帖子误删。
       * 所以 `FeedViewModel` 的过滤判据是"**明确说了**没关注"（known && !following）。
       */
      ownerFollowKnown: item.following !== undefined,
      videoUrl: playable,
      imageUrls: images,
      liked: item.liked ?? false,
      viewCount: item.views ?? 0,
      repostCount: item.reposts ?? 0,
      shareCount: item.shares ?? 0,
      // 收藏数：载荷给了才有（IG 基本不给），没有就 0 —— 界面按 0 不画那颗数字。
      saveCount: item.saves ?? 0,
      mediaWidth: item.w ?? 0,
      mediaHeight: item.h ?? 0,
      // 下载用的原始地址：接口给了就用，没给就退回展示用的那份（至少还能下载）。
      originalImageUrls: (item.originalImages ?? []).length > 0 ? item.originalImages : images,
      originalVideoUrl: (item.originalVideo ?? '').length > 0 ? item.originalVideo : playable,
      // 首屏封面预解码用的低一档封面（见 core/PosterCache）：只有原生那条路会给。
      thumbUrl: item.thumb ?? '',
      // 逐页媒体（图 / 视频混排）+ "最高的那一页"的比例：见 toSlides 与 FeedItemDto。
      mediaSlides: slides,
      imageAspectMin: item.aspectMin ?? 0
    });
  }

  /**
   * DTO 的逐页媒体 → 模型的 `MediaSlide[]`（**只收多图帖**；单图/单视频帖返回空数组）。
   *
   * 为什么只认 >1 页：单视频帖的"那一页"由帖子级 `videoUrl` 表达（那条链上的老逻辑
   * 一个字都不用改）；多图帖才需要逐页区分图/视频。
   */
  private static toSlides(item: FeedItemDto): Array<MediaSlide> {
    return FeedMapper.slidesFromItems(item.mediaItems ?? []);
  }

  /**
   * 逐页媒体 DTO → `MediaSlide[]`（**只收多图帖**；≤1 页返回空数组）。
   *
   * 公开是因为**探索流的帖子**也要走同一套：它的数据来自 `SearchPost`
   * （`discover/topical_explore/` 的 `carousel_media`），字段形状与时间线那份一致。
   * 早先搜索/探索那条路只带一张封面，于是多图帖在 feeds 里只剩第一张图
   * （用户报的"多图片/视频媒体帖子是不是没适配"）。
   */
  static slidesFromItems(raw: Array<FeedMediaItemDto>): Array<MediaSlide> {
    if (raw.length <= 1) {
      return [];
    }
    const built: Array<MediaSlide> = [];
    for (let index: number = 0; index < raw.length; index++) {
      const one: FeedMediaItemDto = raw[index];
      const img: string = one.img ?? '';
      const vid: string = one.vid ?? '';
      if (img.length === 0 && vid.length === 0) {
        continue;
      }
      // blob: 是页面内部地址、原生播放器拿不到（同 toPost 里 videoUrl 的处理）。
      const playable: string = vid.startsWith('blob:') ? '' : vid;
      built.push(new MediaSlide(img, playable, one.w ?? 0, one.h ?? 0));
    }
    return built.length > 1 ? built : [];
  }

  /** 去重 key：shortcode 优先，其次 id，都没有就用位置（视为不去重）。 */
  static dedupeKey(post: MediaPost, index: number): string {
    if (post.shortcode.length > 0) {
      return `sc:${post.shortcode}`;
    }
    if (post.id.length > 0) {
      return `id:${post.id}`;
    }
    return `u:${index}`;
  }

  /**
   * 与位置无关的稳定标识：shortcode 优先，其次 id。
   *
   * 用来回答「当前正在内联播放的是哪一条」—— 列表重排、翻页合并都不会让它变。
   */
  static keyOf(post: MediaPost): string {
    return post.shortcode.length > 0 ? post.shortcode : post.id;
  }

  /**
   * 复制一条帖子，按需替换「是否已赞 / 是否已转发 / 转发数」。
   *
   * 字段是只读的、列表又是整体替换语义，所以点赞和转发状态一变就得重造整条 MediaPost。
   * 把这一长串字段收在**一个地方**：之前就漏过 repostCount / shareCount（点一次赞
   * 转发数就被清成 0），每多一处拷贝就多一次同样的坑。
   *
   * 公开是因为「按台账补回转发标记」也要用它（见 FeedViewModel.applyRepostedLedger）。
   *
   * @param repostCount 新的转发数；传 **-1** 表示"不动它，沿用原值"（默认）。
   */
  static withState(post: MediaPost, liked: boolean, reposted: boolean,
                   repostCount: number = -1): MediaPost {
    return new MediaPost({
      id: post.id,
      shortcode: post.shortcode,
      caption: post.caption,
      mediaType: post.mediaType,
      displayUrl: post.displayUrl,
      likeCount: post.likeCount,
      commentCount: post.commentCount,
      takenAtMs: post.takenAtMs,
      ownerUsername: post.ownerUsername,
      ownerAvatarUrl: post.ownerAvatarUrl,
      // 作者 id / 关注态也要带上：漏了的话"点一次赞"就会把关注按钮打回默认值
      // （以前这里就漏着，只是恰好没人在帖子页点赞之后再去点关注）。
      ownerId: post.ownerId,
      ownerFollowing: post.ownerFollowing,
      ownerFollowKnown: post.ownerFollowKnown,
      videoUrl: post.videoUrl,
      imageUrls: post.imageUrls,
      liked: liked,
      viewCount: post.viewCount,
      // 这条最容易漏：MediaPost 是整体重建的，不带上这几项，点一次赞就会把
      // 转发/分享/收藏数清成 0。
      reposted: reposted,
      repostCount: repostCount >= 0 ? repostCount : post.repostCount,
      shareCount: post.shareCount,
      saveCount: post.saveCount,
      // 尺寸同理：漏了就退回正方形，图片会被重新裁掉。
      mediaWidth: post.mediaWidth,
      mediaHeight: post.mediaHeight,
      // 多图帖"按最高那张钉高"的比例同理：漏了点一次赞比例就退回第一张（见 imageAspectMin）。
      imageAspectMin: post.imageAspectMin,
      // 原始地址同理：漏了下载按钮就只能下到降级后的那份。
      originalImageUrls: post.originalImageUrls,
      originalVideoUrl: post.originalVideoUrl,
      // 低一档封面同理：漏了首屏预解码那张小图就白解了（见 core/PosterCache）。
      thumbUrl: post.thumbUrl
    });
  }

  /**
   * 生成一条**补上了视频地址 / 作者头像**的新帖子（字段只读，所以换新对象）。
   *
   * 用途：收藏 / 被标注那两段的查询**只给封面、不给视频地址**，`user` 对象里也**没有头像**
   * （见 core/NativeProfile.postOf）。帖子页那边按 id 后补（core/NativeMediaInfo /
   * core/NativeUserInfo），补到之后用这个换一条新的，列表整体替换 → 卡片的键里带着
   * "有没有视频地址"（见 FeedList 的键），那一张随之重建、播放器才挂得上去。
   *
   * 空串 = **不动这一项**（沿用原来的值）。
   *
   * 这一版把"一发 media info 能补齐的四样东西"合成一个入口（见 withDetails）：
   * 视频 / 头像 / **多图** / **发布时间**。只补视频与头像的老调用点仍可用这个方法。
   */
  static withMedia(post: MediaPost, videoUrl: string, originalVideoUrl: string,
                   avatarUrl: string): MediaPost {
    return FeedMapper.withDetails(post, videoUrl, originalVideoUrl, avatarUrl, [], [], 0, 0);
  }

  /**
   * 同上，但把**多图**与**发布时间**也一起补上（帖子页从收藏 / 被标注进来时那三样都缺）。
   *
   * @param images         多图的展示档（空数组 = 不动）
   * @param originalImages 多图的下载档（空数组 = 不动）
   * @param takenAtMs      发布时间毫秒（0 = 不动）
   *
   * 为什么要"长度 > 1 才替换"：单图帖的 media info 也会给一张图，而载荷里那张封面
   * **已经是对的**（还带着 core/MediaQuality 挑好的档位），不该被换掉 ——
   * 只有真的拿到多张（轮播）时才覆盖 `imageUrls`（`FeedList` 就是按长度 > 1 画 Swiper 的）。
   */
  static withDetails(post: MediaPost, videoUrl: string, originalVideoUrl: string,
                     avatarUrl: string, images: Array<string>, originalImages: Array<string>,
                     takenAtMs: number, imageAspectMin: number = 0,
                     repostCount: number = -1): MediaPost {
    const nextVideo: string = videoUrl.length > 0 ? videoUrl : post.videoUrl;
    const many: boolean = images.length > 1;
    return new MediaPost({
      id: post.id,
      shortcode: post.shortcode,
      caption: post.caption,
      mediaType: nextVideo.length > 0 ? 'video' : post.mediaType,
      displayUrl: post.displayUrl,
      likeCount: post.likeCount,
      commentCount: post.commentCount,
      takenAtMs: takenAtMs > 0 ? takenAtMs : post.takenAtMs,
      ownerUsername: post.ownerUsername,
      ownerAvatarUrl: avatarUrl.length > 0 ? avatarUrl : post.ownerAvatarUrl,
      ownerId: post.ownerId,
      ownerFollowing: post.ownerFollowing,
      videoUrl: nextVideo,
      imageUrls: many ? images : post.imageUrls,
      liked: post.liked,
      viewCount: post.viewCount,
      reposted: post.reposted,
      // 转发数：这一发 media info 给了就更新（需求："没有显示转发数量"——那两段的载荷里
      // 常常没有这个数，而媒体详情里有）。
      repostCount: repostCount >= 0 ? repostCount : post.repostCount,
      shareCount: post.shareCount,
      saveCount: post.saveCount,
      mediaWidth: post.mediaWidth,
      mediaHeight: post.mediaHeight,
      originalImageUrls: many ? originalImages : post.originalImageUrls,
      originalVideoUrl: originalVideoUrl.length > 0 ? originalVideoUrl : post.originalVideoUrl,
      thumbUrl: post.thumbUrl,
      // 多图帖的媒体盒子按最高那张钉高（见 MediaPostInit.imageAspectMin）。
      imageAspectMin: many && imageAspectMin > 0 ? imageAspectMin : post.imageAspectMin
    });
  }

  /**
   * 生成一条只改了「是否已赞」的新帖子。
   *
   * MediaPost 的字段是只读的，列表又是整体替换语义，所以点赞状态变化要造一条新的；
   * 返回 null 表示目标不在列表里。
   */
  static withLiked(posts: MediaPost[], key: string, liked: boolean): MediaPost[] | null {
    let hit: boolean = false;
    const next: MediaPost[] = [];
    for (let index: number = 0; index < posts.length; index++) {
      const post: MediaPost = posts[index];
      if (FeedMapper.keyOf(post) !== key || post.liked === liked) {
        next.push(post);
        continue;
      }
      hit = true;
      next.push(FeedMapper.withState(post, liked, post.reposted));
    }
    return hit ? next : null;
  }

  /**
   * 生成一条只改了「是否已转发」的新帖子（和 withLiked 同一套路数）。
   *
   * **转发数也一起改**（本机视角）：转 +1、取消 −1，并且"自己转过的至少显示 1"。
   * 为什么要本地也算：转发数在 IG 的网页/接口两侧都不一定给得出来（网页界面根本不渲染它，
   * 接口字段名不确定，见 NativeTimelineParser 与 bridge/WebScripts 的说明）—— 只等接口的话，
   * 用户刚转过的帖子也会一个数字都不显示（用户报的"转发数量没有显示"）。
   * 接口下次真给了数，会由 syncUiList 用真实值覆盖回去。
   *
   * 返回 null 表示目标不在列表里、或者它已经是这个状态。
   */
  static withReposted(posts: MediaPost[], key: string, reposted: boolean): MediaPost[] | null {
    let hit: boolean = false;
    const next: MediaPost[] = [];
    for (let index: number = 0; index < posts.length; index++) {
      const post: MediaPost = posts[index];
      if (FeedMapper.keyOf(post) !== key || post.reposted === reposted) {
        next.push(post);
        continue;
      }
      hit = true;
      // 转发数：已知就 ±1，未知（0）时按"自己这一次"记 1。
      const count: number = reposted
        ? (post.repostCount > 0 ? post.repostCount + 1 : 1)
        : Math.max(post.repostCount - 1, 0);
      next.push(FeedMapper.withState(post, post.liked, reposted, count));
    }
    return hit ? next : null;
  }

  /** 按 dedupeKey 把 incoming 累积合并到 existing 之后（existing 内部也去一次重）。 */
  static merge(existing: MediaPost[], incoming: MediaPost[]): MergeResult {
    const seen: Set<string> = new Set<string>();
    const merged: MediaPost[] = [];
    for (let index: number = 0; index < existing.length; index++) {
      const post: MediaPost = existing[index];
      const key: string = FeedMapper.dedupeKey(post, index);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(post);
    }
    let added: number = 0;
    for (let index: number = 0; index < incoming.length; index++) {
      const post: MediaPost = incoming[index];
      const key: string = FeedMapper.dedupeKey(post, merged.length + index);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(post);
      added++;
    }
    return new MergeResult(merged, added);
  }

  /**
   * 下拉刷新专用：把新读到的一页放在**头部**，后面接上原有、但这一页没覆盖到的帖子。
   *
   * 不能复用 merge —— 它是「原有在前、新内容追加到末尾」，刷新拿到的更新帖子会跑到
   * 列表最底部；而下拉刷新恰恰应该让新内容出现在最上面。
   * changed 保持「这批内容里有多少条是列表原先没有的」这个语义，状态行据此判断。
   */
  static mergePrepend(fresh: MediaPost[], existing: MediaPost[]): MergeResult {
    const known: Set<string> = new Set<string>();
    for (let index: number = 0; index < existing.length; index++) {
      known.add(FeedMapper.dedupeKey(existing[index], index));
    }
    const seen: Set<string> = new Set<string>();
    const merged: MediaPost[] = [];
    let changed: number = 0;
    for (let index: number = 0; index < fresh.length; index++) {
      const key: string = FeedMapper.dedupeKey(fresh[index], index);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(fresh[index]);
      if (!known.has(key)) {
        changed++;
      }
    }
    for (let index: number = 0; index < existing.length; index++) {
      const key: string = FeedMapper.dedupeKey(existing[index], merged.length + index);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(existing[index]);
    }
    return new MergeResult(merged, changed);
  }

  /**
   * 用首页接口的结果按 shortcode 对齐，补齐 DOM 抽不到的字段：
   * 视频的真实地址 `video_versions[].url`、多图 `carousel_media[]`、精确计数。
   *
   * 只有真的补到了东西（changed > 0）调用方才应该替换现有数组，这点与原实现一致。
   */
  static enrich(posts: MediaPost[], items: FeedItemDto[]): MergeResult {
    if (items.length === 0) {
      return new MergeResult(posts, 0);
    }
    const byCode: Map<string, FeedItemDto> = new Map<string, FeedItemDto>();
    for (let index: number = 0; index < items.length; index++) {
      const item: FeedItemDto = items[index];
      const code: string = item.shortcode ?? '';
      if (code.length > 0) {
        byCode.set(code, item);
      }
    }
    const merged: MediaPost[] = [];
    let enriched: number = 0;
    for (let index: number = 0; index < posts.length; index++) {
      const post: MediaPost = posts[index];
      const hit: FeedItemDto | undefined =
        post.shortcode.length > 0 ? byCode.get(post.shortcode) : undefined;
      if (hit === undefined) {
        merged.push(post);
        continue;
      }
      const images: string[] = hit.images ?? [];
      const video: string = hit.videoUrl ?? '';
      const hitCaption: string = hit.caption ?? '';
      const hitPoster: string = hit.poster ?? '';
      if (video.length > 0 || images.length > 1 || hitCaption.length > post.caption.length) {
        enriched++;
      }
      /*
       * **逐页媒体**（需求："feeds 流多图片媒体可以包含视频媒体"）。
       *
       * 页面脚本按 `carousel_media[]` 逐页导出 `mediaItems`（每页带 图/视频/宽高），
       * 这里翻成模型的 `MediaSlide[]`。**只有多图帖（>1 页）且真的导出成功时**才替换：
       * 单图/单视频帖、以及老数据（脚本没给 items）一律保留原样，那些路的行为一个字都不变。
       */
      const rawItems: Array<FeedMediaItemDto> = hit.mediaItems ?? [];
      let slides: Array<MediaSlide> = post.mediaSlides;
      if (rawItems.length > 1) {
        const built: Array<MediaSlide> = [];
        for (let at: number = 0; at < rawItems.length; at++) {
          const one: FeedMediaItemDto = rawItems[at];
          const img: string = one.img ?? '';
          const vid: string = one.vid ?? '';
          if (img.length === 0 && vid.length === 0) {
            continue;
          }
          built.push(new MediaSlide(img, vid, one.w ?? 0, one.h ?? 0));
        }
        if (built.length > 1) {
          slides = built;
          // 诊断：多图帖里有几页视频。"多图含视频"这条路到底有没有数据在走，看这一行。
          let videos: number = 0;
          for (let at: number = 0; at < built.length; at++) {
            if (built[at].isVideo()) {
              videos++;
            }
          }
          if (videos > 0) {
            hilog.info(DOMAIN, TAG, 'carousel with video pages=%{public}d videos=%{public}d key=%{public}s',
              built.length, videos, post.shortcode);
          }
        }
      }
      const apiImage: string = images.length > 0 ? images[0] : post.displayUrl;
      // 视频优先用接口给的封面；没有封面就退回第一张图 / 原封面。
      const displayUrl: string = video.length > 0
        ? (hitPoster.length > 0 ? hitPoster : apiImage)
        : apiImage;
      const hitLikes: number = hit.likes ?? 0;
      const hitComments: number = hit.comments ?? 0;
      const hitUsername: string = hit.username ?? '';
      const hitAvatar: string = hit.avatar ?? '';
      merged.push(new MediaPost({
        id: post.id,
        shortcode: post.shortcode,
        caption: hitCaption.length > post.caption.length ? hitCaption : post.caption,
        mediaType: video.length > 0 ? 'video' : post.mediaType,
        displayUrl: displayUrl,
        likeCount: hitLikes > 0 ? hitLikes : post.likeCount,
        commentCount: hitComments > 0 ? hitComments : post.commentCount,
        takenAtMs: hit.takenAt ?? post.takenAtMs,
        ownerUsername: hitUsername.length > 0 ? hitUsername : post.ownerUsername,
        ownerAvatarUrl: hitAvatar.length > 0 ? hitAvatar : post.ownerAvatarUrl,
        videoUrl: video.length > 0 ? video : post.videoUrl,
        imageUrls: images.length > 1 ? images : post.imageUrls,
        // 逐页媒体（含视频页）：只有多图帖导出成功时才替换，见上面 rawItems 那段。
        mediaSlides: slides,
        // 多图帖的盒子按"最高的那一页"钉高（见 MediaPostInit.imageAspectMin）。
        imageAspectMin: (hit.aspectMin ?? 0) > 0 ? (hit.aspectMin ?? 0) : post.imageAspectMin,
        liked: hit.liked ?? post.liked,
        viewCount: hit.views ?? post.viewCount,
        // 转发状态接口里没有，只能保留原生这边记住的（见 FeedViewModel.repostedKeys）。
        reposted: post.reposted,
        // 转发/分享/收藏数只有接口侧有；接口给了就用接口的，否则保留原值。
        repostCount: (hit.reposts ?? 0) > 0 ? (hit.reposts ?? 0) : post.repostCount,
        shareCount: (hit.shares ?? 0) > 0 ? (hit.shares ?? 0) : post.shareCount,
        saveCount: (hit.saves ?? 0) > 0 ? (hit.saves ?? 0) : post.saveCount,
        // 尺寸同样来自接口；DOM 兜底那条路径本来就没尺寸，所以没有就保留原值。
        mediaWidth: (hit.w ?? 0) > 0 ? (hit.w ?? 0) : post.mediaWidth,
        mediaHeight: (hit.h ?? 0) > 0 ? (hit.h ?? 0) : post.mediaHeight,
        // 下载用的原始地址：接口给了就用接口的（更新），否则保留原来那份。
        originalImageUrls: (hit.originalImages ?? []).length > 0 ? hit.originalImages : post.originalImageUrls,
        originalVideoUrl: (hit.originalVideo ?? '').length > 0 ? hit.originalVideo : post.originalVideoUrl,
        // 低一档封面：接口带了就用新的，否则保留原值（见 core/PosterCache）。
        thumbUrl: (hit.thumb ?? '').length > 0 ? (hit.thumb ?? '') : post.thumbUrl
      }));
    }
    return new MergeResult(merged, enriched);
  }

  /** 打点：数组长度 + id/shortcode 唯一值数量 + 前三条样本。 */
  static logKeys(stage: string, list: MediaPost[]): void {
    const ids: Set<string> = new Set<string>();
    const codes: Set<string> = new Set<string>();
    let sample: string = '';
    for (let index: number = 0; index < list.length; index++) {
      const post: MediaPost = list[index];
      ids.add(post.id);
      if (post.shortcode.length > 0) {
        codes.add(post.shortcode);
      }
      if (index < 3) {
        sample += ` |${index}:id=${post.id} sc=${post.shortcode}`;
      }
    }
    hilog.info(DOMAIN, TAG,
      'KEY %{public}s n=%{public}d uid=%{public}d usc=%{public}d%{public}s',
      stage, list.length, ids.size, codes.size, sample);
  }
}
