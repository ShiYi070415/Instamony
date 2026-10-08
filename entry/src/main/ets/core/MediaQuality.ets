/*
 * 媒体清晰度策略：**展示用降级、下载用原图**。
 *
 * 背景：Instagram 的每个媒体都给一组候选（图片是 `image_versions2.candidates[]`，视频是
 * `video_versions[]`），原来我们的解析一律"取最大的那张" —— 实测因此经常拉到 1440/2160 宽的
 * 原图和水位最高的视频，流量与解码内存都白白多花。
 *
 * 这里的策略：
 *   - **展示**：取"宽度 ≥ 目标宽度里最接近的那档"，没有更大的就用最大的。
 *     目标是屏幕宽度的 1.5 倍左右（这里取 1080）—— 手机上肉眼已无差别，
 *     而 IG 的 1080 档通常只有 1440/2160 档的 1/2 ~ 1/3 大小。
 *   - **下载**：单独保留"最大的一档"（见 originalImage/originalVideo）——
 *     用户点下载要的是原图/原视频，不能因为省流把画质降了。
 *
 * 所以解析出来的每条媒体都带两份地址：展示用的（降级）+ 原始用的（最大）。
 */

/** 展示用目标宽度（像素）。1080 足够本机（1280px 宽屏幕）全宽显示且看不出差别。 */
const TARGET_WIDTH: number = 1080;

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
  /** 展示用目标宽度（供脚本侧拼参数用）。 */
  static targetWidth(): number {
    return TARGET_WIDTH;
  }

  /**
   * 图片候选 → 展示用那一张（宽度 ≥ 目标里最接近的；都不够就取最大的）。
   *
   * 入参是"任意形状的候选数组"，只认 url/width/height 三个字段 —— 原生与页面脚本
   * 用的是同一套判据（页面脚本里那份是等价实现，见 WebScripts 的 pickImage）。
   */
  static displayImage(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, TARGET_WIDTH);
  }

  /**
   * 图片候选 → 展示用那一张，**目标宽度自己指定**。
   *
   * 给"格子比屏幕小得多"的地方用：搜索页三列网格每格约 141vp，按全宽的 1080 档取是白给带宽
   * （解码 + 上屏都慢），调用方传自己的目标宽度就行（见 NativeSearch.COVER_WIDTH）。
   */
  static displayImageAt(urls: Array<string>, widths: Array<number>, heights: Array<number>,
                        target: number): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, target);
  }

  /** 图片候选 → 下载用的原图（最大的一张）。 */
  static originalImage(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, -1);
  }

  /** 视频候选 → 展示用那一档（宽度 ≥ 目标里最接近的；都不够就取最大的）。 */
  static displayVideo(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, TARGET_WIDTH);
  }

  /** 视频候选 → 下载用的原视频（最大的一档）。 */
  static originalVideo(urls: Array<string>, widths: Array<number>, heights: Array<number>): PickedMedia {
    return MediaQuality.pick(urls, widths, heights, -1);
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
