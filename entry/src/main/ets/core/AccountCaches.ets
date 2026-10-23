/*
 * **账号作用域的进程内缓存清理**（换账号 / 退出登录时调，见 pages/Index.forgetAccountMemory）。
 *
 * ## 为什么单独一个文件
 * "换账号要清掉哪些进程内缓存"这件事原来散落在 `pages/Index` 里十几行：快拍托盘、头像小图、
 * 预下载、译文、消息页句柄、页面级 memo……每加一个缓存就要回页面里补一行，**漏一个就是
 * "还把上一个人的东西留在内存里"**（真机上出现过：换号后快拍托盘、Reels 首屏、搜索推荐
 * 各自残留过一轮）。集中到这里之后，新增缓存只需要在这里登记一次。
 *
 * ## 边界（故意不放进来的）
 *   · `viewmodel/*` 的 `reset()` —— 它们由页面持有的实例调（页面才是所有者）；
 *   · `AccountScope` / `AccountBook` 的落盘分区 —— 那是 `core/` 里的持久化事务；
 *   · 隐藏网页的 HTTP 缓存 —— 需要 `controller.removeCache`，由页面拿句柄清；
 *   · `MobileSession.clearSession()` —— 会话材料，与"缓存"是两件事，保留在页面事务里。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaPrefetch } from './MediaPrefetch';
import { MobileDiscover } from './mobileapi/MobileDiscover';
import { NativeFeed } from './NativeFeed';
import { NativeProfile } from './NativeProfile';
import { NativeStories } from './NativeStories';
import { PosterCache } from './PosterCache';
import { StoryCache } from './StoryCache';
import { Translator } from './Translator';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AccountCaches';

export class AccountCaches {
  /**
   * 把**所有按人生效的进程内缓存**清空（内存级，不碰落盘分区）。
   *
   * 幂等：没有数据时各个 `clear*` 自己什么都不做。
   */
  static clearProcessCaches(): void {
    // 快拍：托盘队列的另一半（已取到的 story 内容 + "已看过/已隐藏"那几张表）。
    StoryCache.reset([], 0);
    NativeStories.clearHidden();
    NativeStories.forgetTray();
    // 头像小图（`PosterCache`）与视频/图片预下载：它们都是"已经解码好、等着直接显示"的字节，
    // 换上一个人的头像就是最直观的串号。
    PosterCache.clear();
    MediaPrefetch.clearCache();
    // 译文缓存：两个账号的文案互相喂没有意义，而且它是按原文做键的。
    Translator.clear();
    // "我是谁"那份缓存（`ds_user_id`）：不清的话换账号后「我的」会按上一个人的 id 取头部。
    NativeProfile.clearCache();
    // 页面级短缓存（按游标存、不带账号）：不清就会把上一个人的帖子/推荐页当成"刚拿到的"。
    NativeFeed.clearCache();
    MobileDiscover.clearCache();
    hilog.info(DOMAIN, TAG, 'process caches cleared');
  }
}
