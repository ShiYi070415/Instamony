/*
 * 首屏封面**预解码**（需求："给首屏那 6 张封面用低一档的地址先解码，配合列表首屏，
 * 白屏时间还能再压一点"）。
 *
 * ## 解决的是什么
 * 冷启动时首屏那几张封面要走"网络 → 解码 → 上屏"三步，网好的时候也要几百毫秒，
 * 网差的时候用户就是对着几个空框等。而 IG 每张图都给了多档候选（见 core/MediaQuality），
 * 360px 那一档只有几十 KB —— 几十毫秒就能拿到并解出来。
 *
 * ## 做法
 *   - 首屏铺好之后，取前 PRELOAD_COUNT 条帖子的 `thumbUrl`（解析时就挑好的低一档，见
 *     core/NativeTimelineParser 的 THUMB_WIDTH），**自己发 HTTP + 自己解码**成小 PixelMap；
 *   - 列表里那几格把这张小图垫在真图**下面**（见 FeedList），真图加载完自然盖住；
 *   - 解码尺寸固定在 POSTER_WIDTH 宽：6 张合起来约 1~2MB 内存，且**不随屏幕尺寸变化**。
 *
 * ## 为什么不用"让 Image 组件提前加载"
 * ArkUI 的 `Image(url)` 没有公开的预加载入口，而 `image.createImageSource` 又不支持 http(s)
 * 地址 —— 要"提前把像素拿到手"只能自己发请求 + 自己解码，所以这里就是那条路。
 * 好处是这条路**自带降级**：任何一步失败都只是"没有小图垫底"，真图的显示路径一点不受影响。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { MediaPost } from '../model/MediaPost';
import { FEED_POSTER_READY } from './AppSettings';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PosterCache';

/** 预热几张（首屏可见的那几格）。 */
const PRELOAD_COUNT: number = 6;
/** 小图解码宽度（px）：360 与解析时挑的那一档呼应（见 NativeTimelineParser.THUMB_WIDTH）。 */
const POSTER_WIDTH: number = 360;
/** 单张上限（字节）：超过就当没有（防呆，正常几十 KB）。 */
const MAX_BYTES: number = 2 * 1024 * 1024;
/** 请求超时（毫秒）。 */
const TIMEOUT_MS: number = 6000;
/** 缓存里最多留几张（超了就释放最旧的，别一直占着内存）。 */
const MAX_KEPT: number = PRELOAD_COUNT;

export class PosterCache {
  /** 已解码的小图：key = **展示地址**（列表就是拿它来查的）。 */
  private static posters: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  /** 正在解的 key（避免同一条重复发请求）。 */
  private static warming: Set<string> = new Set<string>();
  /** 就绪顺序（超出 MAX_KEPT 时按它释放最旧的）。 */
  private static order: Array<string> = [];
  /** 一共解出来几张：发布给界面当"重绘计数"用（见 AppStorage 的 FEED_POSTER_READY）。 */
  private static readyCount: number = 0;

  /** 已经解出来的张数（0 表示还没有任何小图可用）。 */
  static ready(): number {
    return PosterCache.readyCount;
  }

  /**
   * 这张展示地址有没有小图可用。
   *
   * @param version 界面当前的重绘计数（见 FeedList 的 posterReady）。**传进来是有用的**：
   *   计数还是 0 就说明一张都还没解出来，直接短路，省掉一次 Map 查询 —— 同时它也让
   *   "界面读了哪个状态"这件事在代码里看得见（读了才会跟着重绘）。
   */
  static has(url: string, version: number): boolean {
    if (version <= 0 || url.length === 0) {
      return false;
    }
    return PosterCache.posters.has(url);
  }

  /** 取小图（调用前用 `has` 判过才有意义；没有返回 undefined）。 */
  static pixel(url: string): image.PixelMap | undefined {
    return PosterCache.posters.get(url);
  }

  /** 清空（下拉刷新换了一批内容时调用；会把 PixelMap 释放掉）。 */
  static clear(): void {
    PosterCache.posters.forEach((value: image.PixelMap): void => {
      try {
        value.release();
      } catch (error) {
      }
    });
    PosterCache.posters.clear();
    PosterCache.warming.clear();
    PosterCache.order = [];
    PosterCache.readyCount = 0;
  }

  /**
   * 预热首屏这几种封面（**不 await，不抛**）。
   *
   * @param posts 首屏已经铺上的帖子。
   * @param count 预热几条（默认 PRELOAD_COUNT）。
   */
  static warm(posts: Array<MediaPost>, count: number = PRELOAD_COUNT): void {
    for (let index: number = 0; index < posts.length && index < count; index++) {
      const post: MediaPost = posts[index];
      const key: string = post.displayUrl;
      const thumb: string = post.thumbUrl;
      // 没有低一档地址（网页那条路不给这一档）、已经在手、或正在解：跳过。
      if (key.length === 0 || thumb.length === 0) {
        continue;
      }
      if (PosterCache.posters.has(key) || PosterCache.warming.has(key)) {
        continue;
      }
      PosterCache.warming.add(key);
      PosterCache.decode(key, thumb);
    }
  }

  /** 取一张小图并解码（自己发 HTTP，因为 image 那套不支持 http 地址）。 */
  private static decode(key: string, url: string): void {
    const request: http.HttpRequest = http.createHttp();
    request.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    }).then((response: http.HttpResponse): void => {
      const buffer: ArrayBuffer = response.result as ArrayBuffer;
      if (response.responseCode !== 200 || buffer === undefined || buffer.byteLength === 0
        || buffer.byteLength > MAX_BYTES) {
        hilog.info(DOMAIN, TAG, 'skip code=%{public}d bytes=%{public}d',
          response.responseCode, buffer === undefined ? 0 : buffer.byteLength);
        PosterCache.warming.delete(key);
        return;
      }
      PosterCache.put(key, buffer, request);
    }).catch((error: Error): void => {
      hilog.info(DOMAIN, TAG, 'fetch failed: %{public}s', error.message);
      PosterCache.warming.delete(key);
      try {
        request.destroy();
      } catch (destroyError) {
      }
    });
  }

  /** 字节 → PixelMap（解码宽度固定 POSTER_WIDTH，高度按原图比例算）。 */
  private static put(key: string, buffer: ArrayBuffer, request: http.HttpRequest): void {
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(buffer);
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'createImageSource failed: %{public}s', (error as Error).message);
      PosterCache.warming.delete(key);
      PosterCache.closeQuietly(request);
      return;
    }
    // 先问原图尺寸：`desiredSize` 是**按给定宽高缩**，给个正方形会把画面拉变形
    // （预览虽然一闪而过，但"先扁一下再变正"比空白更难看）。按原比例算高度。
    source.getImageInfo().then((info: image.ImageInfo): void => {
      const srcW: number = info.size.width > 0 ? info.size.width : POSTER_WIDTH;
      const srcH: number = info.size.height > 0 ? info.size.height : POSTER_WIDTH;
      const height: number = Math.max(1, Math.round(POSTER_WIDTH * srcH / srcW));
      const options: image.DecodingOptions = {
        desiredSize: { width: POSTER_WIDTH, height: height }
      };
      PosterCache.decodeTo(source, key, options, request);
    }).catch((error: Error): void => {
      hilog.info(DOMAIN, TAG, 'image info failed: %{public}s', error.message);
      PosterCache.warming.delete(key);
      PosterCache.closeQuietly(request);
      PosterCache.releaseSource(source);
    });
  }

  /** 真正解码一步（尺寸已经算好）。 */
  private static decodeTo(source: image.ImageSource | null, key: string,
                          options: image.DecodingOptions, request: http.HttpRequest): void {
    if (source === null) {
      PosterCache.warming.delete(key);
      PosterCache.closeQuietly(request);
      return;
    }
    source.createPixelMap(options).then((pixel: image.PixelMap): void => {
      PosterCache.store(key, pixel);
      PosterCache.closeQuietly(request);
      PosterCache.releaseSource(source);
    }).catch((error: Error): void => {
      hilog.info(DOMAIN, TAG, 'decode failed: %{public}s', error.message);
      PosterCache.warming.delete(key);
      PosterCache.closeQuietly(request);
      PosterCache.releaseSource(source);
    });
  }

  /** 存下小图并发布新的重绘计数（超出上限就释放最旧的那张）。 */
  private static store(key: string, pixel: image.PixelMap): void {
    PosterCache.warming.delete(key);
    PosterCache.posters.set(key, pixel);
    PosterCache.order.push(key);
    while (PosterCache.order.length > MAX_KEPT) {
      const oldest: string | undefined = PosterCache.order.shift();
      if (oldest === undefined) {
        break;
      }
      const dropped: image.PixelMap | undefined = PosterCache.posters.get(oldest);
      if (dropped !== undefined) {
        try {
          dropped.release();
        } catch (error) {
        }
        PosterCache.posters.delete(oldest);
      }
    }
    PosterCache.readyCount++;
    // 发布给界面：FeedList 订阅了这个键，值一变那几格就会重绘（见那边的 posterReady）。
    AppStorage.setOrCreate(FEED_POSTER_READY, PosterCache.readyCount);
    hilog.info(DOMAIN, TAG, 'ready #%{public}d %{public}s', PosterCache.readyCount, key.substring(0, 48));
  }

  private static closeQuietly(request: http.HttpRequest): void {
    try {
      request.destroy();
    } catch (error) {
    }
  }

  private static releaseSource(source: image.ImageSource | null): void {
    if (source === null) {
      return;
    }
    try {
      source.release();
    } catch (error) {
    }
  }
}
