/*
 * 动作图标的动画（feeds 与 reels 共用一套）。
 *
 * 需求（这一版）：
 *   1. "双击点赞需要有跟手动画" —— 双击落在**哪儿**，那颗大爱心就在哪儿炸开（不是固定在正中），
 *      而且点下去立刻开始（不等网络返回）；
 *   2. "点赞图标添加动画" —— 心一变实就弹一下（回弹曲线）；
 *   3. "转发图标添加动画：外层循环图标 360 度镜像旋转，内部勾号图标画线条动画" ——
 *      外层的循环箭头转一整圈、转的过程中左右镜像翻一次；里面的对勾是**一笔画出来**的
 *      （`Path` + `strokeDashOffset` 从"整段藏起来"补间到 0）。
 *
 * ## 为什么放在共用的一个文件里
 * feeds 的卡片动作区和 reels 的右侧动作栏是两套组件，但图标与动画**必须一致**
 * （用户是按"一套动作"在看的）；各写一份迟早会走样（这次就是因为 reels 那边压根没有动画）。
 *
 * ## 关于 @Observed + @ObjectLink 的放大爱心
 * 爱心画在**每一张卡片**的媒体上，而卡片是 ForEach 渲染的：ForEach 对键值没变的项不会重跑
 * item builder，普通 @State 变了爱心根本不会出现；把 key 塞进卡片键值倒是能出现，但那一项会被
 * **重建**（视频重启、轮播回第一张）。所以用一个 @Observed 状态对象 + 每张卡片一个 @ObjectLink
 * 的爱心组件：就地动画，卡片不动。
 */

import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AnimIcon';

/** 放大爱心：起始/终止缩放、单步时长（毫秒）、图标边长（vp）。 */
const BURST_FROM: number = 0.35;
const BURST_TO: number = 1.15;
const BURST_STEP_MS: number = 420;
const BURST_ICON_SIZE: number = 118;
/** 爱心整个动画（两步）的时长：宿主用它决定什么时候把 key 清掉。 */
export const BURST_TOTAL_MS: number = BURST_STEP_MS + 90;

/** 点赞图标弹一下：起点缩小比例与时长（毫秒）。 */
const POP_FROM: number = 0.72;
const POP_MS: number = 320;
/** 一圈旋转的时长（毫秒）：转两半，中途镜像翻一次。 */
const SPIN_HALF_MS: number = 260;
/** 勾号弹出：起点比例、延时（等外层转过去一半）与时长（毫秒）。 */
const CHECK_FROM: number = 0.2;
const CHECK_DELAY_MS: number = 240;
const CHECK_MS: number = 300;

/**
 * 「放大爱心」的瞬时状态（每张卡片一个爱心组件订阅它，见文件头）。
 */
@Observed
export class LikeBurstState {
  /** 正在放动画的那一项的 key；空串表示没有。 */
  key: string = '';
  /** 落点（相对宿主容器的 vp 坐标）：跟手 —— 在哪儿双击就在哪儿炸开。负值 = 没拿到坐标，居中。 */
  x: number = -1;
  y: number = -1;
  scale: number = BURST_FROM;
  opacity: number = 0;
}

/**
 * 媒体/页面上的放大爱心。
 *
 * 只是纯装饰：`hitTestBehavior(None)`，绝不能拦住第二次双击。
 * 节点什么时候消失由宿主清 `key` 决定（opacity 归零时动画还在跑，不能拿它当判据）。
 */
@Component
export struct LikeBurst {
  @ObjectLink state: LikeBurstState;
  @Prop itemKey: string = '';
  /** 图标边长（vp）；名字不叫 size —— 那和 CustomComponent 的保留属性撞名（编译期报错）。 */
  @Prop iconSize: number = BURST_ICON_SIZE;

  build() {
    if (this.state.key === this.itemKey) {
      if (this.state.x >= 0 && this.state.y >= 0) {
        // 跟手：以落点为**中心**（所以减去半个图标边长）。
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(this.iconSize)
          .fontColor([Color.White])
          .scale({ x: this.state.scale, y: this.state.scale })
          .opacity(this.state.opacity)
          .position({ x: this.state.x - this.iconSize / 2, y: this.state.y - this.iconSize / 2 })
          .hitTestBehavior(HitTestMode.None)
          // 放在被动画的属性之后：属性一变就按这个参数补间。
          .animation({ duration: BURST_STEP_MS, curve: Curve.EaseOut })
      } else {
        // 没拿到坐标（极少数）：退回"叠在正中"。`align` 在 Stack 里就是"自己相对父组件对齐"。
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(this.iconSize)
          .fontColor([Color.White])
          .scale({ x: this.state.scale, y: this.state.scale })
          .opacity(this.state.opacity)
          .align(Alignment.Center)
          .hitTestBehavior(HitTestMode.None)
          .animation({ duration: BURST_STEP_MS, curve: Curve.EaseOut })
      }
    }
  }
}

/**
 * 动作区那颗心（feeds / reels 共用）。
 *
 * 变实那一刻弹一下：起点缩小 → 回弹曲线回到 1（`springMotion` 自带过冲，
 * 所以看起来是"啪"地弹出来，而不是线性放大）。取消赞不弹（观感上那一下不该有奖励感）。
 */
@Component
export struct LikeIcon {
  @Prop @Watch('onLiked') liked: boolean = false;
  /** 图标字号（vp）。 */
  @Prop iconSize: number = 26;
  /** 已赞颜色；空串 = 用主题前景色。 */
  @Prop activeColor: string = '#ED4956';
  /** 未赞颜色；空串 = 主题前景色。 */
  @Prop idleColor: string = '';
  /** 弹一下的缩放（名字不叫 scale —— 那和 CustomComponent 的保留属性撞名）。 */
  @State private popScale: number = 1;

  onLiked(): void {
    if (!this.liked) {
      return;
    }
    // 先瞬时缩到起点，再补间回 1：同一帧里"先复位再设终值"框架只看得到终值，补间起不来。
    this.popScale = POP_FROM;
    animateTo({ duration: POP_MS, curve: curves.springMotion(0.42, 0.85) }, (): void => {
      this.popScale = 1;
    });
  }

  /** 颜色（已赞用红，未赞走主题色）。 */
  private color(): ResourceColor {
    if (this.liked) {
      return this.activeColor.length > 0 ? this.activeColor : $r('app.color.primary_text');
    }
    return this.idleColor.length > 0 ? this.idleColor : $r('app.color.primary_text');
  }

  build() {
    SymbolGlyph(this.liked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
      .fontSize(this.iconSize)
      .fontWeight(FontWeight.Medium)
      .fontColor([this.color()])
      .scale({ x: this.popScale, y: this.popScale })
      // 禁止被动作区压缩：一行里图标多了以后，被压的图形会横向缩放，形状就毁了。
      .flexShrink(0)
  }
}

/**
 * 动作区那颗**书签**（收藏；reels 页右侧竖排动作栏用）。
 *
 * 需求："reels 页面添加收藏按钮……收藏按钮实现一下功能，用 http 请求"。
 * 图标用系统那两颗 `bookmark` / `bookmark_fill`（「我的」页分段按钮里"收藏"那一段用的就是它们，
 * 见 ProfileSegmentBar，所以两处的图标语汇是一致的）。
 *
 * 动画：收藏那一刻**由小到大弹一下**（和点赞同一个做法：先瞬时缩到起点，再走弹簧回 1，
 * 见 LikeIcon 的说明）；取消收藏不弹 —— 观感上那一下不该有"奖励"。
 */
@Component
export struct SaveIcon {
  @Prop @Watch('onSaved') saved: boolean = false;
  /** 图标字号（vp）。 */
  @Prop iconSize: number = 26;
  /** 颜色；空串 = 主题前景色。 */
  @Prop tint: string = '';
  /** 弹一下的缩放（不能叫 scale —— 和 CustomComponent 的保留属性撞名）。 */
  @State private popScale: number = 1;

  onSaved(): void {
    if (!this.saved) {
      return;
    }
    this.popScale = POP_FROM;
    animateTo({ duration: POP_MS, curve: curves.springMotion(0.42, 0.85) }, (): void => {
      this.popScale = 1;
    });
  }

  build() {
    SymbolGlyph(this.saved ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'))
      .fontSize(this.iconSize)
      .fontWeight(FontWeight.Medium)
      .fontColor([this.tint.length > 0 ? this.tint : $r('app.color.primary_text')])
      .scale({ x: this.popScale, y: this.popScale })
      // 同 LikeIcon：禁止被动作区压缩（一行里图标多了会把图形压扁）。
      .flexShrink(0)
  }
}

/**
 * 转发图标（外层循环箭头 + 内层对勾，feeds / reels 共用）。
 *
 * 两个动画（需求："外层循环图标 360 度镜像旋转，内部勾号图标…由小到大弹出"）：
 *   - 外层 `transfer_station`：转 360°，**转的过程中镜像翻一次**（前半圈 scaleX: 1→-1，
 *     后半圈 -1→1），所以看起来是"翻着转过去又一圈转回来"，结束时朝向与原来一致；
 *   - 内层 `checkmark`：**被外层图标框住**（固定边长的 Stack + 居中，字号比外层小，
 *     所以整个勾都在循环图标里面），出现时**由小到大弹出来**（0.2 → 1，弹簧曲线带一点过冲），
 *     延后半拍开始，观感是"转出一个勾"。
 * 取消转发时反着转一圈、勾直接收掉。
 */
@Component
export struct RepostIcon {
  @Prop @Watch('onReposted') reposted: boolean = false;
  /** 外层图标字号（vp）。 */
  @Prop iconSize: number = 24;
  /** 对勾字号（vp）：必须明显小于 iconSize，不然会捅出外层的框。 */
  @Prop checkSize: number = 15;
  /** 颜色；空串 = 主题前景色。 */
  @Prop tint: string = '';
  /** 勾号现在画不画（取消转发时收掉）。 */
  @State private drawn: boolean = false;
  @State private angle: number = 0;
  /** 1 = 正常，-1 = 左右镜像（只在旋转过程中短暂出现）。 */
  @State private mirror: number = 1;
  /** 勾号弹出到哪一档（0.2 → 1）。 */
  @State private checkScale: number = CHECK_FROM;

  /** 这一条转发状态刚刚变成什么样。 */
  onReposted(): void {
    // 取消转发：反着转一圈，勾立刻收掉。
    if (!this.reposted) {
      this.drawn = false;
      this.spin(-1);
      return;
    }
    this.drawn = true;
    this.checkScale = CHECK_FROM;
    this.spin(1);
    // 延后半拍再弹勾（等外层转过去）：`animateTo` 的 delay 就是在做这件事。
    animateTo({ duration: CHECK_MS, delay: CHECK_DELAY_MS, curve: curves.springMotion(0.4, 0.7) },
      (): void => {
        this.checkScale = 1;
      });
  }

  /** 转一整圈：前半圈转 180° 并镜像，后半圈转完并翻回来。 */
  private spin(dir: number): void {
    this.angle = 0;
    this.mirror = 1;
    animateTo({ duration: SPIN_HALF_MS, curve: Curve.EaseIn, onFinish: (): void => {
      animateTo({ duration: SPIN_HALF_MS, curve: Curve.EaseOut, onFinish: (): void => {
        // 360° 与 0° 同一朝向，瞬时归零不会有跳动（这样下一次点击还能从头转）。
        this.angle = 0;
      } }, (): void => {
        this.angle = dir * 360;
        this.mirror = 1;
      });
    } }, (): void => {
      this.angle = dir * 180;
      this.mirror = -1;
    });
  }

  private color(): ResourceColor {
    return this.tint.length > 0 ? this.tint : $r('app.color.primary_text');
  }

  build() {
    // 固定边长的 Stack + 居中：勾号被外层图标**框住**（字号更小、且在同一个盒子中心），
    // 它也不参与撑开尺寸，所以两颗图标的中心永远不会漂。
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.transfer_station'))
        .fontSize(this.iconSize)
        .fontWeight(FontWeight.Medium)
        .fontColor([this.color()])
        .rotate({ angle: this.angle })
        .scale({ x: this.mirror, y: 1 })
        .flexShrink(0)
      if (this.drawn) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(this.checkSize)
          .fontWeight(FontWeight.Bold)
          .fontColor([this.color()])
          .scale({ x: this.checkScale, y: this.checkScale })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .flexShrink(0)
  }
}

/**
 * 放一次"跟手"的放大爱心（feeds / reels 共用）。
 *
 * @param state 宿主持有的状态对象（@Observed）。
 * @param key   这一项的 key（和画爱心的 `LikeBurst.itemKey` 对上才会画）。
 * @param x/y   落点（宿主容器的 vp 坐标）；拿不到就传负值 → 爱心居中。
 */
export function playLikeBurst(state: LikeBurstState, key: string, x: number, y: number): void {
  state.key = key;
  state.x = x;
  state.y = y;
  state.scale = BURST_FROM;
  state.opacity = 1;
  // 下一帧再改成终值：同一帧里"先复位再设终值"框架只看得到终值，补间起不来。
  setTimeout((): void => {
    if (state.key !== key) {
      // 这期间又双击了别处，这次就不用管了。
      return;
    }
    state.scale = BURST_TO;
    state.opacity = 0;
  }, 16);
  setTimeout((): void => {
    if (state.key === key) {
      state.key = '';
      hilog.debug(DOMAIN, TAG, 'burst done key=%{public}s', key);
    }
  }, BURST_TOTAL_MS);
}
