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
import { MediaVideo, NativeMediaInfo } from '../core/NativeMediaInfo';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ProfileReelsVM';

export class ProfileReelsViewModel implements ReelStreamVm {
  /** 这一分页的帖子（翻页时整体替换；视频地址在 videos 里另行记着）。 */
  private posts: Array<MediaPost> = [];
  /** shortcode → 已经取到的视频地址（见文件头"按需去取"）。 */
  private videos: Map<string, MediaVideo> = new Map<string, MediaVideo>();
  /** 正在取视频地址的 shortcode（防同一集重复请求）。 */
  private fetching: Set<string> = new Set<string>();
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
    this.ensureVideo(this.active);
    this.ensureVideo(this.active + 1);
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
    this.ensureVideo(this.active);
    this.ensureVideo(this.active + 1);
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
   * 第 index 条还没有视频地址就去取一次（见文件头）。
   *
   * 拿到之后**原地改这条 Reel**（`videoUrl` 是可变字段，ReelsPage 那一页用 `@ObjectLink`
   * 订阅它，见 ReelSlide）：补到地址那一刻那一页就地重绘、把播放器挂上。
   *
   * 为什么不换一条新 Reel、重报整列表：ForEach 认键，键没变时它不会重跑 item builder；
   * 而把键改成"带有没有视频地址"又会让 Swiper 在替换子节点的过程中把当前页往前带
   * （实测：一补地址页面自己往下翻了一条）。原地改两头都没有这个问题。
   */
  private ensureVideo(index: number): void {
    if (index < 0 || index >= this.reels.length) {
      return;
    }
    const reel: Reel = this.reels[index];
    // 短码也算"能定位"：这一页（个人页的视频分页）的条目常常只有短码，
    // 没有数字 id —— 交给 NativeMediaInfo 用短码去换真 pk（见它的 detailFor）。
    if (reel.videoUrl.length > 0 || (reel.mediaId.length === 0 && reel.shortcode.length === 0)) {
      return;
    }
    if (this.fetching.has(reel.shortcode)) {
      return;
    }
    this.fetching.add(reel.shortcode);
    const shortcode: string = reel.shortcode;
    NativeMediaInfo.videoFor(reel.mediaId, shortcode).then((video: MediaVideo | null): void => {
      this.fetching.delete(shortcode);
      if (video === null || !video.ok()) {
        hilog.warn(DOMAIN, TAG, 'video missing code=%{public}s why=%{public}s',
          shortcode, NativeMediaInfo.lastDetail());
        return;
      }
      // 翻页重建列表时要能把这地址贴回去（见 toReels）。
      this.videos.set(shortcode, video);
      reel.videoUrl = video.display;
      reel.originalVideoUrl = video.original;
      // 记一份"这条来自哪张帖子"的封面信息不用重算：Reel 里那几个字段本来就没变。
      this.publish();
      hilog.info(DOMAIN, TAG, 'video ready code=%{public}s', shortcode);
    }).catch((error: Error): void => {
      this.fetching.delete(shortcode);
      hilog.warn(DOMAIN, TAG, 'video failed code=%{public}s: %{public}s',
        shortcode, error.message);
    });
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
        post.ownerFollowKnown
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
