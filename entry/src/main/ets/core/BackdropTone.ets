/*
 * 「叠字背后是什么颜色」的自动侦测。
 *
 * 需求：叠在视频上的那行文字，只有当它背后那块**确实是白/浅色**时才转成深色。
 * 视频画面和系统主题没关系，所以不能按深浅色猜，得真的去取"背后的像素"。
 *
 * 做法：定时给**内容层**（信息流那一层）拍一张低分辨率快照，取**叠字行所占的那块**
 * 的平均亮度（位置由 FeedList 报上来，见 SETTING_OVERLAY_TOP/BOTTOM）。
 * 快照带 scale，一张只有一两百像素宽，取一次是毫秒级，因此可以几赫兹地"连续侦测"，
 * 滚动时颜色跟着画面走。
 *
 * 判定带**迟滞**（明显亮才算亮、明显暗才算暗，中间保持上一次的判断），
 * 否则画面在阈值附近时会来回闪。
 *
 * 注意：**底栏图标的反色不走这里** —— 那是系统材质的 colorInvert 干的活
 * （见 pages/Index.ets 的 barFloatingStyle）。
 */

import { componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettings, SETTING_OVERLAY_BACKDROP_LIGHT, SETTING_OVERLAY_BOTTOM,
  SETTING_OVERLAY_TOP } from './AppSettings';

const TAG: string = 'InstarmonyTone';
const DOMAIN: number = 0xFF00;
/** 采样间隔（毫秒）：滚动时颜色要跟得上，静止时又不至于白耗电。 */
const SAMPLE_INTERVAL_MS: number = 700;
/** 快照缩放：0.12 时 1280 宽的屏只有 154 像素，取一次足够快。 */
const SNAPSHOT_SCALE: number = 0.12;
/**
 * 叠字那块的横向采样范围（屏幕宽度比例）。
 *
 * 只取"文字真正盖住的那一段"：左起 8%（跳过卡片左边距）到 55%（用户名 + 正文那一带，
 * 右边那颗「更多」图标不参与，它的背景由同一行决定）。
 */
const TEXT_X0: number = 0.08;
const TEXT_X1: number = 0.55;
/**
 * 亮度迟滞阈值（0~255）。
 *
 * 高于 HIGH 才算"浅色背景"（文字要转深色），低于 LOW 才算"深色背景"，
 * 两者之间维持上一次的判断 —— 不然画面在阈值附近抖动时颜色会来回闪。
 */
const LUM_HIGH: number = 168;
const LUM_LOW: number = 132;

/** 一块区域的采样结果。 */
class ToneSample {
  /** 平均亮度（0~255）；count 为 0 时无意义。 */
  luminance: number = 0;
  count: number = 0;
}

export class BackdropTone {
  private static timer: number = -1;
  private static busy: boolean = false;
  /** 上一次的判断，用于迟滞。 */
  private static overlayLight: boolean = false;

  /** 开始连续侦测（传内容层的组件 id）。重复调用只会重置定时器。 */
  static start(contentId: string): void {
    BackdropTone.stop();
    BackdropTone.timer = setInterval((): void => {
      BackdropTone.tick(contentId);
    }, SAMPLE_INTERVAL_MS);
  }

  /** 停止侦测（页面销毁 / 进后台时调）。 */
  static stop(): void {
    if (BackdropTone.timer >= 0) {
      clearInterval(BackdropTone.timer);
      BackdropTone.timer = -1;
    }
  }

  private static tick(contentId: string): void {
    // 上一次还没跑完就跳过这一拍：快照是异步的，堆积起来没有意义。
    if (BackdropTone.busy) {
      return;
    }
    BackdropTone.busy = true;
    BackdropTone.sample(contentId).then((): void => {
      BackdropTone.busy = false;
    }).catch((error: Error): void => {
      BackdropTone.busy = false;
      hilog.debug(DOMAIN, TAG, 'sample failed: %{public}s', error.message);
    });
  }

  private static async sample(contentId: string): Promise<void> {
    // 没有叠字（上=下=0）就不用拍了：这一拍没有任何要判断的东西。
    const top: number = AppSettings.overlayTop();
    const bottom: number = AppSettings.overlayBottom();
    if (bottom <= top) {
      return;
    }
    // get(id, options)：options.scale 就是"缩到多小再给我"，0.12 时 1280 宽的屏只有 154 像素。
    const shot: image.PixelMap = await componentSnapshot.get(contentId, { scale: SNAPSHOT_SCALE });
    const info: image.ImageInfo = await shot.getImageInfo();
    const width: number = info.size.width;
    const height: number = info.size.height;
    if (width <= 0 || height <= 0) {
      await shot.release();
      return;
    }
    const buffer: ArrayBuffer = new ArrayBuffer(width * height * 4);
    await shot.readPixelsToBuffer(buffer);
    const pixels: Uint8Array = new Uint8Array(buffer);
    await shot.release();

    const text: ToneSample = BackdropTone.average(pixels, width, height, TEXT_X0, TEXT_X1, top, bottom);
    if (text.count > 0) {
      BackdropTone.overlayLight = BackdropTone.decide(text.luminance, BackdropTone.overlayLight);
      AppStorage.setOrCreate(SETTING_OVERLAY_BACKDROP_LIGHT, BackdropTone.overlayLight);
      // 每一次采样都留一行（debug 级）：颜色不对时，看一眼亮度就知道是"取错了区域"
      // 还是"快照根本没拿到画面"。亮度取整后再打：hilog 不支持 %{public}.1f 这种写法。
      hilog.debug(DOMAIN, TAG, 'text=%{public}d(%{public}s) band=%{public}d-%{public}d',
        Math.round(text.luminance), BackdropTone.overlayLight ? 'light' : 'dark',
        Math.round(top * 1000), Math.round(bottom * 1000));
    }
  }

  /**
   * 取一块矩形区域的平均亮度。
   *
   * 入参都是**比例**（0~1），和快照的实际像素尺寸无关。RGBA_8888 每像素 4 字节。
   */
  private static average(pixels: Uint8Array, width: number, height: number,
    x0f: number, x1f: number, y0f: number, y1f: number): ToneSample {
    const out: ToneSample = new ToneSample();
    const x0: number = Math.max(0, Math.floor(width * x0f));
    const x1: number = Math.min(width, Math.ceil(width * x1f));
    const y0: number = Math.max(0, Math.floor(height * y0f));
    const y1: number = Math.min(height, Math.ceil(height * y1f));
    let sum: number = 0;
    let count: number = 0;
    for (let y: number = y0; y < y1; y++) {
      for (let x: number = x0; x < x1; x++) {
        const index: number = (y * width + x) * 4;
        const red: number = pixels[index];
        const green: number = pixels[index + 1];
        const blue: number = pixels[index + 2];
        sum += 0.2126 * red + 0.7152 * green + 0.0722 * blue;
        count++;
      }
    }
    out.luminance = count > 0 ? sum / count : 0;
    out.count = count;
    return out;
  }

  /** 带迟滞的"算不算浅色底"。 */
  private static decide(luminance: number, previous: boolean): boolean {
    if (luminance > LUM_HIGH) {
      return true;
    }
    if (luminance < LUM_LOW) {
      return false;
    }
    return previous;
  }
}
