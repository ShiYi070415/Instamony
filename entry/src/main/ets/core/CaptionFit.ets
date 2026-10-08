/*
 * 正文（caption）的**折叠排版**：超过 N 行就截断，调用方在尾巴上追加灰色的" ... 展开"。
 *
 * ## 为什么要"量"而不是交给 Text 自己省略
 * ArkUI 的 `textOverflow: Ellipsis` 会把超出部分的**所有**内容一起裁掉 —— 挂在尾巴上的
 * " ... 展开"提示会跟着一起消失（用户看到的就是"明明截断了却没有展开入口"）。
 * 所以这里先量出可用宽度与行高，再二分找"加了提示仍然不超 N 行"的最长前缀；
 * 返回的串天生排得下，Text 上的 maxLines(N) 只是最后一道保险。
 *
 * ## 谁在用
 *   - `components/FeedList`（信息流卡片的正文）；
 *   - `components/ReelsPage`（Reels 页作者行下面那段正文，需求："超过两行以 ' ... 展开' 显示，
 *     展开后文末显示 ' 收起'"）。
 * 两处**必须同一套判据**，否则同一个人的同一段正文在信息流和 Reels 页上折的行数不一样。
 *
 * 量不到（接口不可用 / 宽度未知）时**不做截断**，原样返回 —— 宁可多显示，也不要显示半截。
 */

import { UIContext } from '@kit.ArkUI';

/** 折叠时最多显示几行。 */
export const CAPTION_COLLAPSED_MAX_LINES: number = 2;
/** 折叠时追加在结尾的提示（灰色）。 */
export const CAPTION_MORE: string = ' ... 展开';
/** 展开时追加在结尾的提示（灰色）。 */
export const CAPTION_LESS: string = ' 收起';
/**
 * 提示尾巴的**安全余量**（vp）：量前缀时多留一点，免得" ... 展开"正好卡在行尾被裁掉。
 * 量得偏乐观的话提示就白加了。
 */
export const CAPTION_TAIL_SAFETY_VP: number = 6;

export class CaptionFit {
  /**
   * 折叠态的**前缀**：放得下就原样返回全文；放不下就返回"加了 CAPTION_MORE 仍不超 N 行"的最长前缀。
   *
   * @param availVp 可用宽度（vp，已扣掉左右内边距）。
   * @param fontSize 正文字号。
   */
  static prefix(ui: UIContext, caption: string, availVp: number,
                fontSize: number, maxLines: number = CAPTION_COLLAPSED_MAX_LINES,
                more: string = CAPTION_MORE): string {
    if (caption.length === 0 || availVp <= 0) {
      return caption;
    }
    try {
      const utils = ui.getMeasureUtils();
      const oneLinePx: number = utils.measureTextSize({
        textContent: 'M',
        fontSize: fontSize
      }).height as number;
      if (oneLinePx <= 0) {
        return caption;
      }
      // 整段本来就排得下：原样显示，一个字都不截、也不加提示。
      if (CaptionFit.fits(ui, caption, availVp, oneLinePx, fontSize, maxLines)) {
        return caption;
      }
      // 二分：找"加了提示仍不超 N 行"的最长前缀。
      let lo: number = 0;
      let hi: number = caption.length;
      while (lo < hi) {
        const mid: number = Math.ceil((lo + hi) / 2);
        if (CaptionFit.fits(ui, `${caption.substring(0, mid)}${more}`, availVp, oneLinePx,
          fontSize, maxLines)) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return CaptionFit.safeCut(caption, lo);
    } catch (error) {
      // 测量失败（接口不可用等）就退回不截断，界面照常显示。
      return caption;
    }
  }

  /**
   * 这段文字在给定宽度下是否不超过 maxLines 行。
   *
   * 行高按"一个字的高度"当基准：整段只有一种字号，行高是一样的，所以高度 ≤ 行数 × 行高
   * 就能反推行数。比较时留 1/4 行余量吸收取整误差 —— 三行是三倍行高，离得很远，
   * 不会被这点余量误判成两行。
   */
  static fits(ui: UIContext, text: string, availVp: number, oneLinePx: number,
              fontSize: number, maxLines: number = CAPTION_COLLAPSED_MAX_LINES): boolean {
    const height: number = ui.getMeasureUtils().measureTextSize({
      textContent: text,
      constraintWidth: availVp,
      fontSize: fontSize
    }).height as number;
    return height <= oneLinePx * (maxLines + 0.25);
  }

  /**
   * 把截断位置从"码元"修正到"码点"边界。
   *
   * JS 的 substring 按 UTF-16 码元切，emoji 之类由两个码元组成，切在中间会出半个字符
   * （接口文档也专门提醒过这一点）。这里只在必要时退一格，并去掉结尾空白
   * （免得出现"正文␣ ... 展开"这种双空格）。
   */
  static safeCut(text: string, cut: number): string {
    let end: number = cut;
    if (end > 0 && end < text.length) {
      const code: number = text.charCodeAt(end - 1);
      if (code >= 0xD800 && code <= 0xDBFF) {
        end = end - 1;
      }
    }
    return text.substring(0, end).replace(/[\s\u3000]+$/, '');
  }
}
