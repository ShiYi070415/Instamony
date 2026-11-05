import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProfilePage } from './ProfilePage';
import { PROFILE_TAB_POSTS, PROFILE_TAB_REELS, PROFILE_TAB_TAGGED, ProfileViewModel } from '../viewmodel/ProfileViewModel';
import { SEGMENT_MODE_USER } from './ProfileSegmentBar';
import { ProfileHeader, ProfileHighlight, ProfilePost, ProfileStreamPage } from '../model/Profile';
import { StoryHeroRect } from '../model/Story';
import { MediaPost } from '../model/MediaPost';

const DOMAIN: number = 0xFF00;
const TAG: string = 'UserProfileRoute';

@Component
export struct UserProfileRoute {
  /** 路由参数：`用户名|数字id`（见 Index.parseUserParam）。 */
  @Prop param: string = '';
  /** 嵌在首页平行视界右栏时的实际宽度（0 = 整屏路由）。 */
  @Prop layoutWidthVp: number = 0;
  /** 嵌在右栏时标题由右栏画，ProfilePage 不再额外避让 HDS 标题栏。 */
  @Prop embedded: boolean = false;
  /** 右栏 Reels 背景下的其他页面：强制浅色。 */
  vm: ProfileViewModel = new ProfileViewModel();
  /** 打开一条帖子：交给隐藏网页（同「我的」页）。 */
  onOpen: (post: ProfilePost) => void = (post: ProfilePost): void => {
  };
  /** 关注 / 取关这一页的用户（页面那一行按钮的动作，实现在 pages/Index.followUser）。 */
  onFollowUser: (id: string, username: string, follow: boolean) => Promise<boolean> =
    (id: string, username: string, follow: boolean): Promise<boolean> => Promise.resolve(false);
  /** 简介里的 @账号 → 打开那个人的主页（实现在 pages/Index.openUserProfile）。 */
  onOpenUserProfile: ((username: string) => void) | null = null;
  /** 路由参数里的用户名（头部还没到时的兜底，见 build 里的关注回调）。 */
  private userName: string = '';
  /** 路由参数里的数字 id（关注接口的路径参数）。 */
  private userId: string = '';
  /** 点格子 → 帖子页（见 pages/Index.openPostStream）。 */
  onOpenStream: (posts: Array<MediaPost>, index: number,
                  loadMore: () => Promise<ProfileStreamPage>) => void =
    (posts: Array<MediaPost>, index: number,
     loadMore: () => Promise<ProfileStreamPage>): void => {
    };
  /** 点**视频那一段**的格子 → Reels 页（见 pages/Index.openProfileReels）。 */
  onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                loadMore: () => Promise<ProfileStreamPage>) => void =
    (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
     loadMore: () => Promise<ProfileStreamPage>): void => {
    };
  onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState) => void =
    (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
    };
  /**
   * 点**精选快拍** → 快拍播放页（别人主页也要能看，和"我的"页面同一套）。
   *
   * 之前这里没有这个属性：内部 ProfilePage 虽然给每颗高光都挂好了 onClick，
   * 但回调落在空实现上 —— 表现就是"高光画出来了，点下去没反应"。
   */
  onOpenHighlight: (items: Array<ProfileHighlight>, index: number, rect: StoryHeroRect,
    rects: Map<string, StoryHeroRect>) => void =
    (items: Array<ProfileHighlight>, index: number, rect: StoryHeroRect,
      rects: Map<string, StoryHeroRect>): void => {
    };

  aboutToAppear(): void {
    const parts: Array<string> = `${this.param}`.split('|');
    const username: string = parts.length > 0 ? parts[0] : '';
    const userId: string = parts.length > 1 ? parts[1] : '';
    this.userName = username;
    this.userId = userId;
    this.vm.setTarget(userId, username);
    // 三段：帖子 / 视频 / 被提及（没有收藏）。
    this.vm.setOrder([PROFILE_TAB_POSTS, PROFILE_TAB_REELS, PROFILE_TAB_TAGGED]);
    hilog.info(DOMAIN, TAG, 'user profile open @%{public}s id=%{public}s',
      username, userId.length > 0 ? 'y' : 'n');
  }

  build() {
    ProfilePage({
      vm: this.vm,
      layoutWidthVp: this.layoutWidthVp,
      topOffsetVp: this.embedded ? 0 : 94,
      segmentMode: SEGMENT_MODE_USER,
      // 简介里的 @账号：开那个人的主页（需求："点击后进入该用户主页"）。
      onOpenUser: (username: string): void => {
        if (this.onOpenUserProfile !== null) {
          this.onOpenUserProfile(username);
        }
      },
      onOpen: (post: ProfilePost): void => {
        this.onOpen(post);
      },
      // 关注 / 取关这一页的用户：id 来自路由参数，用户名以头部为准（拿不到就退回参数里的）。
      onFollowUser: (follow: boolean): Promise<boolean> => {
        const header: ProfileHeader | null = this.vm.headerNow();
        const username: string = header === null ? this.userName : header.username;
        return this.onFollowUser(this.userId, username, follow);
      },
      // 别人主页的格子同样进**帖子页**（需求：所有用户主页都接进去）。
      onOpenStream: (posts: Array<MediaPost>, index: number,
                     loadMore: () => Promise<ProfileStreamPage>): void => {
        this.onOpenStream(posts, index, loadMore);
      },
      // 别人主页**视频那一段**的格子 → Reels 页（需求）。
      onOpenReels: (posts: Array<MediaPost>, shortcode: string, hasMore: boolean,
                    loadMore: () => Promise<ProfileStreamPage>): void => {
        this.onOpenReels(posts, shortcode, hasMore, loadMore);
      },
      onFeedScroll: (deltaY: number, offsetY: number, scrollState: ScrollState): void => {
        this.onFeedScroll(deltaY, offsetY, scrollState);
      },
      // 精选快拍：转发给外壳（见 onOpenHighlight 的说明）。别人主页也要能点开。
      onOpenHighlight: (items: Array<ProfileHighlight>, index: number, rect: StoryHeroRect,
        rects: Map<string, StoryHeroRect>): void => {
        this.onOpenHighlight(items, index, rect, rects);
      }
    })
  }
}
