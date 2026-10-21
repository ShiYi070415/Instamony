/*
 * 媒体清晰度策略：**按设置 + 网络类型挑选展示档，下载永远用原图**。
 *
 * 背景：Instagram 的每个媒体都给一组候选（图片是 `image_versions2.candidates[]`，视频是
 * `video_versions[]`）。早先一律"取最大的那张"→ 流量与解码内存白花；后来一律降到 1080 →
 * 用户反馈"媒体分辨率有点糊"。现在两头都可调：设定页的「图片和视频」板块里
 * 「图片质量 / 视频质量」各有 自适应 / 省流 / 高清 / 原画 四档（见 SETTING_IMAGE_QUALITY）。
 *
 * 策略：
 *   - **展示**：取"宽度 ≥ 目标里最接近的那档"，没有更大的就用最大的。
 *     目标是屏幕宽度的 1 倍多（默认档见下面 TARGET_* 与 targetOf）。
 *   - **下载**：单独保留"最大的一档"（见 originalImage/originalVideo）——
 *     用户点下载要的是原图/原视频，不能因为省流把画质降了。
 *
 * 所以解析出来的每条媒体都带两份地址：展示用的 + 原始用的（最大）。
 */

import { AppSettings, MEDIA_QUALITY_HIGH, MEDIA_QUALITY_ORIGINAL, MEDIA_QUALITY_SAVER } from './AppSettings';
import { NetworkState } from './NetworkState';

/** 展示用目标宽度（像素）。1080 足够本机（1280px 宽屏幕）全宽显示且看不出差别。 */
const TARGET_WIDTH: number = 1080;

/*
 * 清晰度档位（需求："图片质量/视频质量"两个下拉：自适应 / 省流 / 高清 / 原画）。
 * 值来自 `core/AppSettings`（设定页里改，存盘并在 AppStorage 里发布）。
 *
 * 这里只决定**展示用**那一档的"目标宽度"：
 *   省流 → 720（够看，流量最小）
 *   高清 → 1440（手机上肉眼已到顶，仍比原画小很多）
 *   原画 → 取 IG 给的最大一档（= 原来的 original* 那套）
 *   自适应 → 按网络类型：Wi-Fi / 不计费 → 高清；蜂窝 → 省流
 * 下载（originalImage/originalVideo）永远取最大档，不受这里影响。
 */
const TARGET_SAVER: number = 720;
const TARGET_HIGH: number = 1440;
/** 目标宽度低于这个值时当成"未知"，按兜底处理（防脏数据）。 */
const TARGET_MIN: number = 240;

/** 一组图片候选里挑出来的结果。 */
export class PickedMedia {
  readonly url: string;
  readonly width: number;
  readonly height: number;

  constructor(url: string, width: number, height: number) {
    this.url = url;
    this.width = width;
    this.height = height;
  }
}

export class MediaQuality {
  /**
   * 图片候选 → 展示用那一张（宽度 ≥ 目标里最接近的；都不够就取最大的）。
   *
   * 入参是"任意形状的候选数组"，只认 url/width/height 三个字段 —— 原生与页面脚本
   * 用的是同一套判据（页面脚本里那份是等价实现，见 WebScripts 的 pickImage）。
   */
  static displayImage(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, MediaQuality.imageTarget());
  }

  /**
   * 图片候选 → 展示用那一张，**目标基数自己指定**。
   *
   * 给"格子比屏幕小得多"的地方用：搜索页三列网格每格约 141vp，按全宽的档取是白给带宽
   * （解码 + 上屏都慢），调用方传自己的目标宽度就行（见 NativeSearch.COVER_WIDTH）。
   * 目标基数仍会按清晰度设置缩放（见 scaledTarget）——"高清/原画"下网格图也跟着变清晰。
   */
  static displayImageAt(urls: Array<string>, widths: Array<number>, heights: Array<number>,
                        target: number): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, MediaQuality.scaledTarget(target, true));
  }

  /** 图片候选 → 下载用的原图（最大的一张）。 */
  static originalImage(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, -1);
  }

  /** 视频候选 → 展示用那一档（宽度 ≥ 目标里最接近的；都不够就取最大的）。 */
  static displayVideo(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, MediaQuality.videoTarget());
  }

  /** 视频候选 → 下载用的原视频（最大的一档）。 */
  static originalVideo(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, -1);
  }

  /** 当前**图片**清晰度对应的目标宽度（-1 = 原画，取最大档）。 */
  static imageTarget(): number {
    return MediaQuality.targetOf(AppSettings.imageQualityNow());
  }

  /** 当前**视频**清晰度对应的目标宽度（-1 = 原画，取最大档）。 */
  static videoTarget(): number {
    return MediaQuality.targetOf(AppSettings.videoQualityNow());
  }

  /** 档位值 → 目标宽度。 */
  private static targetOf(quality: string): number {
    if (quality === MEDIA_QUALITY_SAVER) {
      return TARGET_SAVER;
    }
    if (quality === MEDIA_QUALITY_HIGH) {
      return TARGET_HIGH;
    }
    if (quality === MEDIA_QUALITY_ORIGINAL) {
      return -1;
    }
    // auto：按网络类型自己挑（拿不准时按计费网络处理 → 省流）。
    return NetworkState.allowPrefetch() ? TARGET_HIGH : TARGET_SAVER;
  }

  /**
   * 给"格子/封面"那类**自带目标基数**的调用方按清晰度缩放。
   *
   * 为什么不直接返回 -1（原画）：网格封面本来就比屏幕小得多，原画等于白花好几倍带宽；
   * 这里只在"高清"时放大一档，"原画"时也只用 TARGET_HIGH 封顶。
   */
  private static scaledTarget(base: number, image: boolean): number {
    const quality: string = image ? AppSettings.imageQualityNow() : AppSettings.videoQualityNow();
    if (quality === MEDIA_QUALITY_SAVER) {
      return Math.max(TARGET_MIN, Math.floor(base * 0.72));
    }
    if (quality === MEDIA_QUALITY_HIGH) {
      return Math.max(base, Math.floor(base * 1.4));
    }
    if (quality === MEDIA_QUALITY_ORIGINAL) {
      return Math.max(base, TARGET_HIGH);
    }
    // auto：蜂窝网络下按省流处理，Wi-Fi 下用原始基数。
    return NetworkState.allowPrefetch() ? base : Math.max(TARGET_MIN, Math.floor(base * 0.72));
  }

  /**
   * 通用挑选：
   *   target > 0 → 取"宽度 ≥ target 里最小的那个"（够清晰又最省）；没有 ≥ target 的取最大的；
   *   target < 0 → 直接取最大的（下载原图/原视频）。
   * 宽度缺失（0）的候选当作"未知"，只在没有别的选择时才用。
   */
  private static pick(urls: Array<string>, widths: Array<number>, heights: Array<number>,
                      target: number): PickedMedia {
    let bestUrl: string = '';
    let bestWidth: number = -1;
    let bestHeight: number = 0;
    let fallbackUrl: string = '';
    let fallbackWidth: number = -1;
    let fallbackHeight: number = 0;
    for (let index: number = 0; index < urls.length; index++) {
      const url: string = (urls[index] ?? '').trim();
      if (url.length === 0) {
        continue;
      }
      const width: number = widths[index] ?? 0;
      const height: number = heights[index] ?? 0;
      // 宽度未知的候选：留作兜底，别让它把已知宽度的候选挤掉。
      if (width <= 0) {
        if (fallbackUrl.length === 0) {
          fallbackUrl = url;
          fallbackWidth = width;
          fallbackHeight = height;
        }
        continue;
      }
      if (target < 0) {
        if (width > bestWidth) {
          bestUrl = url;
          bestWidth = width;
          bestHeight = height;
        }
        continue;
      }
      if (width >= target) {
        // 够清晰里最小的那个。
        if (bestWidth < 0 || width < bestWidth) {
          bestUrl = url;
          bestWidth = width;
          bestHeight = height;
        }
      } else if (width > fallbackWidth) {
        // 都不够清晰时，记下最大的那个当兜底。
        fallbackUrl = url;
        fallbackWidth = width;
        fallbackHeight = height;
      }
    }
    if (bestUrl.length > 0) {
      return new PickedMedia(bestUrl, bestWidth, bestHeight);
    }
    return new PickedMedia(fallbackUrl, fallbackWidth < 0 ? 0 : fallbackWidth, fallbackHeight);
  }
}
