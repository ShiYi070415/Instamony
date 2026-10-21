/*
 * 信息流媒体预下载。
 *
 * 为什么需要它：信息流里一张卡就是一张 IG CDN 上的大图（原图经常 1080×1350、几百 KB）。
 * 用户在滑的时候才去下，就会"滑到哪、白到哪"。
 *
 * 官方文档（显示图片 / Image）给的正是这条路：`Image` 组件在机制上依赖
 * `@ohos.request.cacheDownload` 这个缓存下载模块，**它提供独立的预下载接口** ——
 * 在创建 Image 组件之前把图先抓进缓存，组件创建时直接命中缓存，于是显示快得多。
 * 所以这里只做一件事：把"接下来要看的那几张"提前 `cacheDownload.download()` 掉。
 *
 * 几个刻意的限制：
 *   - 只预取**当前可见位置往后几张**（调用方给的范围），预取太远等于跟正在看的那张抢带宽；
 *   - 同一个 url 一次会话里只下一次（`seen`），避免来回滑时反复提交；
 *   - 全异步、失败只记日志：预下载只是加速，失败了不该影响任何正常路径。
 */

import { cacheDownload } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlatformCap } from './PlatformCap';
import { NetworkState } from './NetworkState';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MediaPrefetch';
/**
 * 一次最多提交几张。
 *
 * 原来 6 = PREFETCH_AHEAD(3) × 每条最多 2 张（多图帖下前两张）。
 * **降到 2**（降噪，见 `FINGERPRINT_ANALYSIS.md` 阶段一）：预取是"我们替用户先下"，
 * 不属于任何真实用户动作，密度越高越像爬虫；现在只预取**下一条**的两张，
 * 再往后就等滚动真的到了跟前再下（那时是用户动作触发的）。
 */
const MAX_PER_CALL: number = 2;
/**
 * `seen` 最多记多少个 url。
 *
 * 原来这个集合**没有上限、进程内也不清**（只有 `clearCache()` 才 clear）：
 * 滑得久了它会一直涨，而缓存下载内部那张"下载信息表"只有 2048 条（见 init）——
 * 表和缓存一被淘汰，`seen` 却还记得，于是那些**缓存里已经没有的图再也不会被预取**
 * （表现是滑回去突然变慢，却查不出原因）。现在按 FIFO 淘汰：超过上限就忘掉最早那批。
 */
const SEEN_MAX: number = 512;
/** 已提交过的 url（会话级，超出 SEEN_MAX 按插入顺序淘汰）。 */
const seen: Set<string> = new Set<string>();

export class MediaPrefetch {
  /**
   * 初始化：把"下载信息表"开大一点。
   *
   * 缓存下载内部按 url 记一条下载信息（命中判断也靠它），默认表比较小，信息被挤掉之后
   * 那些图在缓存里就"查不到"了。2048 是官方示例里的量级，够一屏屏翻很久。
   */
  static init(): void {
    // `setDownloadInfoListSize` 同样是较新版本才有的（见 clearCache 的说明）：
    // 低版本上跳过即可，预下载本身（download，API 18 起）照旧。
    if (!PlatformCap.hasCacheClear()) {
      return;
    }
    try {
      cacheDownload.setDownloadInfoListSize(2048);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setDownloadInfoListSize failed: %{public}s',
        (error as Error).message);
    }
  }

  /** 把一批 url 交给缓存下载（返回真正提交了几张，供日志用）。 */
  static prefetch(urls: Array<string>): number {
    /*
     * **只在不计费网络上预取**（审计 E12）。
     *
     * 这个入口以前不查网络：蜂窝网下照样把"往后三张卡、每张两张图"（几百 KB 到几 MB）
     * 提前拉下来 —— 用户没要求、还可能正在流量套餐里。判据和启动预热那条保持一致
     * （`NetworkState.allowPrefetch()`：Wi-Fi / 不计费网，拿不准按计费处理）。
     * 预取只是加速，跳过它不影响任何正常显示路径。
     */
    if (!NetworkState.allowPrefetch()) {
      return 0;
    }
    let started: number = 0;
    for (let index: number = 0; index < urls.length && started < MAX_PER_CALL; index++) {
      const url: string = urls[index];
      if (url.length === 0 || seen.has(url)) {
        continue;
      }
      MediaPrefetch.remember(url);
      try {
        const options: cacheDownload.CacheDownloadOptions = {};
        cacheDownload.download(url, options);
        started++;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'prefetch failed: %{public}s', (error as Error).message);
      }
    }
    if (started > 0) {
      hilog.info(DOMAIN, TAG, 'prefetch %{public}d (seen=%{public}d)', started, seen.size);
    }
    return started;
  }

  /** 记一个已提交的 url；超过 SEEN_MAX 就忘掉最早那个（见 SEEN_MAX 的说明）。 */
  private static remember(url: string): void {
    while (seen.size >= SEEN_MAX) {
      const oldest: string | undefined = seen.values().next().value;
      if (oldest === undefined) {
        break;
      }
      seen.delete(oldest);
    }
    seen.add(url);
  }

  /**
   * 退出应用时把预下载的媒体删掉。
   *
   * 为什么必须删：缓存下载落的是**应用沙箱 cache 目录里的文件**（见本文件开头），
   * 不清就会一直攒着 —— 用户滑过的每一张封面都留在磁盘上。所以离开应用（onBackground）
   * 与销毁（onDestroy）时都清一次：
   *   - `clearFileCache()` 删磁盘那份；
   *   - `clearMemoryCache()` 顺手把内存缓存也放掉。
   * 两个接口都是 API 23 起，本模块 compatibleSdkVersion 就是 23，可以直接用。
   *
   * 顺带把 `seen` 清空：否则下次进来同一个 url 会被当成"已经提交过"而跳过预下载。
   * 失败只记日志：这只是清缓存，不该影响退出流程。
   */
  static clearCache(): void {
    // 这两个接口是 **API 23** 起才有的（`cacheDownload` 模块本身 18 起、`download` 也是 18 起）：
    // 低版本设备上它们不存在，调用会抛 —— 虽然外面有 try/catch，还是先判一下更干净。
    if (!PlatformCap.hasCacheClear()) {
      seen.clear();
      return;
    }
    try {
      cacheDownload.clearFileCache();
      cacheDownload.clearMemoryCache();
      seen.clear();
      hilog.info(DOMAIN, TAG, 'media cache cleared');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clearCache failed: %{public}s', (error as Error).message);
    }
  }
}
