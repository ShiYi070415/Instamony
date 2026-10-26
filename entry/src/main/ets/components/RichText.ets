/*
 * **全局富文本**（@提及 / #话题）：把一段纯文本切成"文字 / @用户 / #话题"片段并逐段渲染。
 *
 * 为什么单独一个组件：帖子正文、评论、简介三处都要"同样一套"的切分与配色，
 * 复制三份必然分叉（切分正则和点击行为一旦不一致，用户就会遇到"这里能点那里不能点"）。
 *
 * 渲染方式照简介那套已验证的做法：`Text(){ Span(...) }` —— `Span` 继承 `CommonMethod`，
 * 可以挂 `onClick`，也不会破坏整段文字自动换行。
 *
 * 性能：切分结果按文本做**进程内缓存**（评论一屏几十条，每条都重切太浪费）。
 */

/** 一段文本里的一个片段。 */
export class RichTextSeg {
  /** 原样要显示的文本（含 `@` / `#` 前缀）。 */
  text: string = '';
  /** `text` = 普通文字 / `mention` = @用户 / `hashtag` = #话题。 */
  kind: string = 'text';
  /** 去掉前缀之后的名字（mention 给用户名，hashtag 给话题词；text 为空串）。 */
  name: string = '';
}

@Component
export struct RichTextView {
  @Prop text: string = '';
  /** 字号（各处自己的小字对齐：评论 13 / 正文 14 …）。 */
  @Prop fontSize: number = 13;
  /** 最多几行（0 = 不限制）。 */
  /** 普通文字的颜色（默认主题正文色）。 */
  @Prop color: ResourceColor = $r('app.color.primary_text');
  /** 点 @用户：交给宿主开主页。 */
  onMention: (username: string) => void = (username: string): void => {
  };
  /** 点 #话题：交给宿主跳搜索。 */
  onHashtag: (tag: string) => void = (tag: string): void => {
  };

  /** 切分结果的进程内缓存（键 = 原文）。 */
  private static cache: Map<string, Array<RichTextSeg>> = new Map<string, Array<RichTextSeg>>();

  /**
   * 把文本切成片段。
   *
   * 规则（与 IG 观感一致、也足够简单）：
   *   · `@` 后面连续的用户名字符（字母/数字/下划线/点）；
   *   · `#` 后面连续的非空白、非 `#` 字符。
   * 都要求长度 ≥ 1，否则整段按普通文字处理。
   */
  static split(text: string): Array<RichTextSeg> {
    if (text.length === 0) {
      return [];
    }
    const hit: Array<RichTextSeg> | undefined = RichTextView.cache.get(text);
    if (hit !== undefined) {
      return hit;
    }
    const out: Array<RichTextSeg> = [];
    const pattern: RegExp = /[@#][A-Za-z0-9_.\u4e00-\u9fff]+/g;
    let last: number = 0;
    let match: RegExpExecArray | null = pattern.exec(text);
    while (match !== null) {
      const at: number = match.index;
      if (at > last) {
        const plain: RichTextSeg = new RichTextSeg();
        plain.text = text.substring(last, at);
        plain.kind = 'text';
        out.push(plain);
      }
      const token: string = match[0];
      const seg: RichTextSeg = new RichTextSeg();
      seg.text = token;
      seg.kind = token.startsWith('@') ? 'mention' : 'hashtag';
      seg.name = token.substring(1);
      out.push(seg);
      last = at + token.length;
      match = pattern.exec(text);
    }
    if (last < text.length) {
      const tail: RichTextSeg = new RichTextSeg();
      tail.text = text.substring(last);
      tail.kind = 'text';
      out.push(tail);
    }
    // 缓存上限：评论/正文文本量大，超过就整表清空（简单且不会长期吃内存）。
    if (RichTextView.cache.size > 400) {
      RichTextView.cache.clear();
    }
    RichTextView.cache.set(text, out);
    return out;
  }

  build() {
    Text() {
      ForEach(RichTextView.split(this.text), (seg: RichTextSeg, index: number): void => {
        if (seg.kind === 'text') {
          Span(seg.text)
            .fontColor(this.color)
        } else {
          Span(seg.text)
            .fontColor($r('app.color.accent'))
            .onClick((): void => {
              if (seg.kind === 'mention') {
                this.onMention(seg.name);
              } else {
                this.onHashtag(seg.name);
              }
            })
        }
      }, (seg: RichTextSeg, index: number): string => `${index}-${seg.kind}-${seg.text}`)
    }
    .fontSize(this.fontSize)
    .width('100%')
  }
}
