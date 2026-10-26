/*
 * 「查看翻译 / 显示原文」那一颗小字（需求的三处都用它：帖子发布时间旁、评论"回复"旁、
 * 评论面板顶部的帖子卡片里）。
 *
 * 组件本身**无状态**：显示什么文案、要不要翻译，全由宿主的 `showing` 决定；点击只回调
 * `onToggle(要显示译文吗)`，翻译的取数/缓存/替换正文都由宿主自己做（见 core/Translator）。
 *
 * 只有**非中文**文本才会渲染出东西（`Translator.needsTranslation`），所以宿主可以无脑放，
 * 中文内容不会多出一颗按钮。
 *
 * 文案来自 `translate_action` / `translate_show_original` 两个资源键（全 app 一致，
 * 改动只在这里与 resources 里，别在各个页面里再写字面量）。
 */

import { Translator } from '../core/Translator';

@Component
export struct TranslateLabel {
  /** 要翻译的原文（决定要不要显示按钮）。 */
  @Prop source: string = '';
  /** 现在显示的是不是译文（文案据此在「查看翻译 / 显示原文」之间切）。 */
  @Prop showing: boolean = false;
  /** 字号（跟各个位置自己的小字对齐：评论/时间 12、正文 13…）。 */
  @Prop fontSize: number = 12;
  /**
   * 左内边距（vp，默认 6 = 原来那颗"指头热区"）。
   *
   * 为什么要能改：它默认是**紧跟在时间后面**排的（那颗内边距正好是"时间与翻译之间的间隙"），
   * 但在"左对齐的卡片"里（见 components/PostCardPanel）它必须和正文/时间同一条左边界，
   * 传 0 就能把文字自己对到左边界上（右/上下那点内边距保留，热区不至于缩没）。
   */
  @Prop padLeft: number = 6;
  /** 点击：`showTranslated` = 点完之后该显示译文吗。 */
  onToggle: (showTranslated: boolean) => void = (showTranslated: boolean): void => {
  };

  build() {
    if (Translator.needsTranslation(this.source)) {
      Text(this.showing
        ? $r('app.string.translate_show_original')
        : $r('app.string.translate_action'))
        .fontSize(this.fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.secondary_text'))
        // 点它是"切换"，不是"跳转"：给点内边距让手指好按，但别把行高撑起来。
        .padding({ left: this.padLeft, right: 2, top: 2, bottom: 2 })
        .onClick((): void => {
          this.onToggle(!this.showing);
        })
    }
  }
}
