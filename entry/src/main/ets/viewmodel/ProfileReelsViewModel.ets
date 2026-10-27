/*
 * 「用户 / 我的」页面 → **视频分页**点进去的那个 Reels 页的视图模型。
 *
 * 需求："用户和我的页面的视频分页点进去是新的页面，采用 reels 模板"。所以这一页的界面就是
 * 首页那个 ReelsPage（竖向翻页、只播当前那条），只是**数据来源不同**：
 *   首页那份来自 clips 首页流（ReelsViewModel → NativeReels / 网页回放）；
 *   这一份来自**某个人的视频分页**（ProfileViewModel 里那一页的 ProfilePost）。
 *
 * ## 为什么不复用 ReelsViewModel
 * ReelsViewModel 认的是 clips 首页那条 GraphQL（模板、游标、原生分页都是那一条的），
 * 而"某个人的视频"本来就在 ProfileViewModel 手里（和网格、帖子页共用同一条游标链，
 * 见 ProfilePage.makeStreamLoader）。硬塞进去会让两套游标互相带偏 —— 和帖子页当初
 * 的处理一样：**翻页只走 ProfileViewModel，这里只负责把结果转成 Reel**。
 *
 * ## 视频地址要**按需去取**（这一页最大的坑）
 * 个人主页的视频分页那条查询（`PolarisProfileReelsTabContentQuery`）**只给封面**：
 * 真机实测解析出来的媒体键里 `media_type=2`（视频）却没有任何 video/dash/url 字段
 * （见 core/NativeMediaInfo 的文件头）。所以这一页的流程是：
 *   1. 进页先把"封面 + shortcode + media id"铺上（立刻有画面、能翻页）；
 *   2. 当前这条（以及下一条）再去 `/api/v1/media/{id}/info/` 补视频地址；
 *   3. 补到了就换一条**新的 Reel**（只读对象）并重报列表 —— 组件那边那一页的播放器这时才挂上。
 * 已经补到的地址记在 `videos` 里，翻页重建列表时不会丢。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { EngageState } from '../core/NativeEngage';
import { Reel, ReelStreamVm } from '../model/Reel';
import { MediaPost } from '../model/MediaPost';
import { ProfileStreamPage } from '../model/Profile';
import { MediaDetail, MediaVideo, NativeMediaInfo } from '../core/NativeMediaInfo';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ProfileReelsVM';

export class ProfileReelsViewModel implements ReelStreamVm {
  /** 这一分页的帖子（翻页时整体替换；视频地址在 videos 里另行记着）。 */
  private posts: Array<MediaPost> = [];
  /** shortcode → 已经取到的视频地址（见文件头"按需去取"）。 */
  private videos: Map<string, MediaVideo> = new Map<string, MediaVideo>();
  /** 正在取视频地址的 shortcode（防同一集重复请求）。 */
  private fetching: Set<string> = new Set<string>();
  /** 已经补过整份详情的键（shortcode 优先，见 ensureDetail）—— 同一条不重复请求。 */
  private fetched: Set<string> = new Set<string>();
  private reels: Array<Reel> = [];
  /** 当前看到第几条（切页/被压住后重建时靠它恢复位置）。 */
  private active: number = 0;
  private busy: boolean = false;
  private more: boolean = true;
  /** 这一分页"再要一页"的入口（由 ProfilePage 交出来，见它的 makeStreamLoader）。 */
  private loadMore: () => Promise<ProfileStreamPage> = (): Promise<ProfileStreamPage> => {
    return Promise.resolve(new ProfileStreamPage([], false));
  };

  onReels: (reels: Array<Reel>, hasMore: boolean) => void =
    (reels: Array<Reel>, hasMore: boolean): void => {
    };
  onBusy: (busy: boolean) => void = (busy: boolean): void => {
    };
  onStatus: (text: string) => void = (text: string): void => {
    };

  /**
   * @param posts          点进去那一刻该分页的全部帖子（已经是 MediaPost）。
   * @param anchorShortcode 点的那一条的 shortcode（定位到它；找不到就从第一条开始）。
   * @param hasMore        该分页还有没有下一页（`ProfileViewModel.moreOfTab`）。
   * @param loadMore       再要一页的入口（见上）。
   */
  constructor(posts: Array<MediaPost>, anchorShortcode: string, hasMore: boolean,
              loadMore: () => Promise<ProfileStreamPage>) {
    this.posts = posts;
    this.more = hasMore;
    this.loadMore = loadMore;
    this.reels = ProfileReelsViewModel.toReels(posts, this.videos);
    let at: number = 0;
    for (let index: number = 0; index < this.reels.length; index++) {
      if (this.reels[index].shortcode === anchorShortcode) {
        at = index;
        break;
      }
    }
    this.active = at;
    hilog.info(DOMAIN, TAG, 'open n=%{public}d anchor=%{public}d more=%{public}s',
      this.reels.length, at, `${hasMore}`);
    // 当前这条的视频地址马上取（`onReels` 此刻还是空实现，取回来时会已经被组件接上）。
    this.ensureDetail(this.active);
    this.ensureDetail(this.active + 1);
  }

  list(): Array<Reel> {
    return this.reels;
  }

  isBusy(): boolean {
    return this.busy;
  }

  hasMore(): boolean {
    return this.more;
  }

  activeIndex(): number {
    return this.active;
  }

  /**
   * 换了一条：把它的视频地址补上，并**顺手预取下一条**（滑过去就不用等）。
   *
   * 由 ReelsPage 的 switchTo 调用（见它的 onChange / onAnimationStart）。
   */
  setActiveIndex(index: number): void {
    this.active = index > 0 ? index : 0;
    this.ensureDetail(this.active);
    this.ensureDetail(this.active + 1);
  }

  /**
   * ReelsPage 只在自己手上没数据时才调它（见它的 aboutToAppear）。
   *
   * 这一页的数据是进页时**带进来**的，所以这里不发列表请求，只把已有的那份再报一次
   * （视图模型和组件各持一份 @State，报一次让两边对齐）。
   */
  async loadFirst(): Promise<void> {
    this.publish();
  }

  /**
   * 再要一页：调 ProfilePage 那个闭包，把拿回来的**整份**帖子列表重新转一遍。
   *
   * 三道闸同帖子页（见 pages/Index.loadPostPageMore）：正在要、没有下一页、列表为空时都不动。
   */
  async requestMore(): Promise<void> {
    if (this.busy || !this.more) {
      return;
    }
    this.busy = true;
    this.onBusy(true);
    try {
      const page: ProfileStreamPage = await this.loadMore();
      const before: number = this.reels.length;
      if (page.posts.length >= this.posts.length) {
        this.posts = page.posts;
      }
      this.reels = ProfileReelsViewModel.toReels(this.posts, this.videos);
      this.more = page.hasMore;
      this.publish();
      hilog.info(DOMAIN, TAG, 'more %{public}d → %{public}d more=%{public}s',
        before, this.reels.length, `${this.more}`);
    } catch (error) {
      // 出错就收手：不然滑到末尾会一直重复要同一页。
      this.more = false;
      this.publish();
      hilog.warn(DOMAIN, TAG, 'more failed: %{public}s', (error as Error).message);
    } finally {
      this.busy = false;
      this.onBusy(false);
    }
  }

  /** 把当前那份列表报给组件（切页/翻页/补到视频地址都走它）。 */
  private publish(): void {
    this.onReels(this.reels, this.more);
    this.onStatus('');
  }

  /**
   * 第 index 条进页时**按短码 / 媒体 id 补一次整份详情**（视频地址、正文、作者、三个计数）。
   *
   * 为什么从"只补视频地址"扩成"补整份详情"（用户需求原话："进入 reels 类页面后通过对应
   * 帖子/视频链接获取数据，实现动作区功能和显示正文内容"）：
   * 从私信卡片点进来的那条**只有封面和一小截正文**（载荷里就这些），动作区下面那几个数字
   * 全是 0、正文也可能不全。`media/{pk}/info/` 那一发响应里视频地址、正文、作者名/头像、
   * 点赞数、评论数都有 —— 一次请求补齐四样，比再各开一条路省事，也不额外多发请求。
   *
   * 拿到之后**原地改这条 Reel**：ReelsPage 那一页用 `@ObjectLink` 订阅它（见 ReelSlide），
   * 补到数据那一刻就地重绘、把播放器挂上。为什么不换一条新 Reel、重报整列表：
   * ForEach 认键，键没变时它不会重跑 item builder；而把键改成"带不带有数据"又会让 Swiper
   * 在替换子节点的过程中把当前页往前带（实测：一补数据页面自己往下翻了一条）。
   */
  private ensureDetail(index: number): void {
    if (index < 0 || index >= this.reels.length) {
      return;
    }
    const reel: Reel = this.reels[index];
    // 短码也算"能定位"：这两条路的条目常常只有短码，没有数字 id ——
    // 交给 NativeMediaInfo 用短码去换真 pk（见它的 detailFor）。
    if (reel.mediaId.length === 0 && reel.shortcode.length === 0) {
      return;
    }
    const key: string = reel.shortcode.length > 0 ? reel.shortcode : reel.mediaId;
    if (this.fetched.has(key) || this.fetching.has(key)) {
      return;
    }
    this.fetching.add(key);
    NativeMediaInfo.detailFor(reel.mediaId, reel.shortcode).then((detail: MediaDetail | null): void => {
      this.fetching.delete(key);
      if (detail === null) {
        hilog.warn(DOMAIN, TAG, 'detail missing key=%{public}s why=%{public}s',
          key, NativeMediaInfo.lastDetail());
        return;
      }
      this.fetched.add(key);
      ProfileReelsViewModel.applyDetail(reel, detail);
      // 翻页重建列表时要能把这地址贴回去（见 toReels）。
      if (detail.hasVideo()) {
        this.videos.set(key, new MediaVideo(detail.display, detail.original,
          detail.width, detail.height, detail.avatarUrl));
      }
      this.publish();
      hilog.info(DOMAIN, TAG,
        'detail ready key=%{public}s video=%{public}d cap=%{public}d like=%{public}d comment=%{public}d',
        key, detail.display.length, detail.caption.length, detail.likeCount, detail.commentCount);
    }).catch((error: Error): void => {
      this.fetching.delete(key);
      hilog.warn(DOMAIN, TAG, 'detail failed key=%{public}s: %{public}s',
        key, error.message);
    });
  }

  /**
   * 把一份详情**原地**贴到这条 Reel 上（只补空的那几项，不覆盖数据源已经给过的值）。
   *
   * 正文例外：详情那边一般更全（私信载荷里的 caption 常常被截过），所以**谁长用谁**。
   */
  private static applyDetail(reel: Reel, detail: MediaDetail): void {
    /*
     * 真 pk 优先：从私信卡片进来的那条 `mediaId` 一开始只是短码，而点赞/收藏/评论这几条
     * 移动端接口都只认数字 pk（见 core/mobileapi/MobileEngage.mediaPkFor）。详情里给了
     * 就从现在起换成它 —— 后面每个动作都少绕一次 oembed。
     */
    if (detail.mediaId.length > 0 && !ProfileReelsViewModel.isNumeric(reel.mediaId)) {
      reel.mediaId = detail.mediaId;
    }
    /*
     * **封面**（用户报："进入 reels 页显示封面，而不是应用图标"）：
     * 从私信卡片进来的那条进页时 `coverUrl` 是空的（按需求不从会话里取数），所以这里必须把
     * 详情里的那张图贴上去 —— 否则那一页永远只有 `startIcon` 兜底。
     * 视频帖的详情里也带 `image_versions2`（首帧封面），一样用它。
     */
    if (reel.coverUrl.length === 0 && detail.images.length > 0) {
      reel.coverUrl = detail.images[0];
    }
    if (reel.width <= 0 && detail.width > 0) {
      reel.width = detail.width;
      reel.height = detail.height;
    }
    if (reel.videoUrl.length === 0 && detail.hasVideo()) {
      reel.videoUrl = detail.display;
      reel.originalVideoUrl = detail.original;
    }
    if (detail.caption.length > reel.caption.length) {
      reel.caption = detail.caption;
    }
    if (reel.author.length === 0 && detail.username.length > 0) {
      reel.author = detail.username;
    }
    if (reel.avatarUrl.length === 0 && detail.avatarUrl.length > 0) {
      reel.avatarUrl = detail.avatarUrl;
    }
    if (reel.likeCount <= 0 && detail.likeCount > 0) {
      reel.likeCount = detail.likeCount;
    }
    if (reel.commentCount <= 0 && detail.commentCount > 0) {
      reel.commentCount = detail.commentCount;
    }
    if (detail.likedKnown) {
      reel.liked = detail.liked;
      // 台账也记一笔：这一页的"红心"要靠它，否则下次进来又回灰（见 core/EngageState）。
      EngageState.rememberLiked(reel.mediaId.length > 0 ? reel.mediaId : reel.shortcode,
        detail.liked);
    }
  }

  /** 这串是不是纯数字（媒体 pk 的判据；短码里有字母，一眼就能分开）。 */
  private static isNumeric(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    for (let index: number = 0; index < text.length; index++) {
      const ch: string = text.charAt(index);
      if (ch < '0' || ch > '9') {
        return false;
      }
    }
    return true;
  }

  /**
   * 一批帖子 → Reels，按 shortcode 去重，并把**已经取到的视频地址**贴回去。
   *
   * 去重是必须的：翻页时 IG 的游标经常把上一条又带回来，重复的 shortcode 会让
   * ForEach 出现重复键（ReelsPage 的键就是 shortcode），渲染会乱。
   */
  static toReels(posts: Array<MediaPost>,
                 videos: Map<string, MediaVideo>): Array<Reel> {
    const seen: Set<string> = new Set<string>();
    const out: Array<Reel> = [];
    let noVideo: number = 0;
    for (let index: number = 0; index < posts.length; index++) {
      const post: MediaPost = posts[index];
      if (post.shortcode.length === 0 || seen.has(post.shortcode)) {
        continue;
      }
      seen.add(post.shortcode);
      const known: MediaVideo | undefined = videos.get(post.shortcode);
      const video: string = known === undefined ? post.videoUrl : known.display;
      const original: string = known === undefined ? post.originalVideoUrl : known.original;
      if (video.length === 0) {
        noVideo++;
      }
      out.push(new Reel(
        post.shortcode,
        video,
        post.displayUrl,
        post.mediaWidth,
        post.mediaHeight,
        post.ownerUsername,
        post.ownerAvatarUrl,
        false,
        // 音乐名：个人主页那条数据拿不到，留空（正文现在有自己的字段，见 Reel.caption）。
        '',
        post.likeCount,
        post.commentCount,
        original,
        ProfileReelsViewModel.mediaIdOf(post),
        // 作者数字 id：视频分页那条查询**不给作者**，由页面把它知道的主人补进来
        // （见 ProfilePage.streamPosts 的 owner/avatar 回填 → MediaPost.ownerId）。
        post.ownerId,
        post.caption,
        // 点赞状态：shortcode 台账优先（Reels 页写入时就按它记，见 EngageState.likedCodes），
        // 再退回媒体 id 台账，最后才是载荷里的旧值。否则"点赞→退出→重进"心会回到灰的。
        EngageState.likedOfByCode(post.shortcode,
          EngageState.likedOf(ProfileReelsViewModel.mediaIdOf(post), post.liked)),
        // 转发同理：按短码那份台账优先（载荷里的 reposted 也是抓取当时的旧值）。
        EngageState.repostedOfByCode(post.shortcode,
          EngageState.repostedOf(ProfileReelsViewModel.mediaIdOf(post), post.reposted)),
        // 转发数：搜索推荐流那条响应带着 `media_repost_count`（见 core/NativeSearch.readPost
        // → MediaPost.repostCount）；个人主页那条没有这个字段，那就是 0。
        // 以前这里没传，于是推荐流那页的"转发数量"是空的（用户报的问题之一）。
        post.repostCount,
        // 关注状态：个人主页那条查询给的是 `friendship_status.following`（见 NativeProfile），
        // 搜索推荐流那条由 NativeSearch 采到 user 上 —— 两边都会落进 MediaPost.ownerFollowing。
        // Reels 页那颗按钮以前只信本地覆盖表，所以"我明明关注了却还显示关注"（用户报的问题）。
        post.ownerFollowing,
        post.ownerFollowKnown,
        // 收藏状态：个人主页这条查询不给 `has_saved`，交给 core/SaveState 的会话覆盖表（传 false）。
        false,
        // 发布时间（毫秒）：个人主页/推荐流那条解析已经取到 `taken_at`（见 NativeProfile、
        // NativeSearch.readPost → MediaPost.takenAtMs），这里直接带过去 —— 评论面板里那张
        // 帖子卡片就靠它显示"x 小时前"（见 PostCardPanel.agoText）。
        post.takenAtMs,
        // 分享 / 收藏数：这条路上它们本来就来自 MediaPost（推荐流那条解析给了就带上；
        // 个人主页那条没有就是 0）。**不传的话**这里会静默丢成 0，
        // 于是同一批视频从推荐流进 Reels 页时那两颗数字又消失了（本项目的老坑）。
        post.shareCount,
        post.saveCount
      ));
    }
    hilog.info(DOMAIN, TAG, 'map %{public}d post → %{public}d reel (pending video %{public}d)',
      posts.length, out.length, noVideo);
    return out;
  }

  /**
   * 一条帖子的**媒体数字 id**（取视频地址要用它）。
   *
   * `MediaPost.id` 就是它（见 ProfileMapper.toMediaPost），但有两种情况要归一：
   *   1. **占位串**：拿不到真 id 时那里塞的是 `profile-<shortcode>` / `search-<shortcode>`
   *      （见 pages/Index.searchPostsToMedia）—— 拿它去请求只会白挨一发 404；
   *   2. **组合形式** `<媒体id>_<作者id>`（信息流那边的 `pk` 就长这样，见 NativeEngage.mediaIdOf）——
   *      `/api/v1/media/{id}/info/` 要的是前半段。
   *
   * 判据落在"归一之后必须全是数字"：IG 的媒体 id 就是纯数字，不满足的当"不知道"，
   * 免得拿脏 id 去喂接口。
   */
  private static mediaIdOf(post: MediaPost): string {
    const id: string = post.id;
    if (id.length === 0) {
      return '';
    }
    if (id.indexOf('profile-') === 0 || id.indexOf('search-') === 0) {
      return '';
    }
    const cut: number = id.indexOf('_');
    const pure: string = cut > 0 ? id.substring(0, cut) : id;
    if (pure.length === 0) {
      return '';
    }
    for (let index: number = 0; index < pure.length; index++) {
      const ch: string = pure.charAt(index);
      if (ch < '0' || ch > '9') {
        return '';
      }
    }
    return pure;
  }
}
