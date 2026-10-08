/*
 * 多图帖的轮播：图片 + 图片下方的圆点指示器。
 *
 * 为什么指示器要自己做：Swiper 自带的 indicator 画在**图片内部**（压在图上），
 * 而需求要的是「媒体下方、动作区上方」那一条。而且它是移不出去的 —— 官方文档写明
 * 指示器的位置范围是 [0, Swiper 高度 - 指示器高度]，超出会被夹到边界上。
 *
 * 动画绑定在图片移动上：指示器不是「滑完再补一个过渡」，而是直接跟着滚动位置走 ——
 * 用 onContentDidScroll 每帧拿到当前的活动位置，圆点的宽度/透明度都是它的纯函数。
 * 手指拖到一半，椭圆就是一半；松手后的回弹动画期间同样每帧回调，所以也跟得住。
 * 正因为形状直接由位置算出来，这里**不需要也不应该**再加 .animation()：
 * 给每帧的新值再套一层补间，只会让椭圆拖在手指后面。
 */

import { PosterCache } from '../core/PosterCache';

/** 圆点尺寸与间距（vp）：活动的那颗拉成椭圆，所以另有一个宽度。 */
const DOT_SIZE: number = 6;
const DOT_ACTIVE_WIDTH: number = 16;
const DOT_SPACE: number = 5;
/**
 * 指示器那一条的高度。
 *
 * **导出**是因为外层（FeedList）要给"媒体区右下角那排按钮"算对齐壳的高度：
 * 轮播的媒体盒子 = 图片 + 这一条，算漏了按钮就会比媒体底边高出半个圆点行。
 */
export const DOT_ROW_HEIGHT: number = 22;
/** 非活动圆点的透明度：同一个色，靠虚实区分。 */
const DOT_INACTIVE_OPACITY: number = 0.35;
/** 活动位置变化小于这个值就不通知（每帧都会回调，避免无谓的重绘）。 */
const DOT_EPSILON: number = 0.001;

/**
 * 连续的活动位置。
 *
 * 不是「第几页」这种整数，而是 0.5 = 第 0、1 页各占一半 —— 这样椭圆才能跟着手指
 * 连续地长/缩，而不是跳变。
 *
 * 为什么用 @Observed 对象而不是普通 @State 数字：圆点行是 ForEach 渲染的，而
 * ForEach 对**键值没变**的项不会重跑 item builder，普通 @State 变了圆点根本不更新；
 * 而把状态塞进键值又会让那一项被**重建**，每帧重建代价很大。
 * @ObjectLink 让属性变化直接通知到子组件、就地更新已有节点，正好适合每帧刷新。
 */
@Observed
class CarouselActive {
  position: number = 0;
}

/** 一颗圆点。第几页由外层给，形状由共享的活动位置算出来。 */
@Component
struct CarouselDot {
  @ObjectLink active: CarouselActive;
  /**
   * 这颗圆点代表第几页。
   *
   * 不能叫 position —— 那是 CommonMethod 自带的属性方法，同名的 @Prop 会和基类
   * 成员冲突（编译器直接报类型不匹配）。
   */
  @Prop pageIndex: number = 0;

  /** 离活动位置越近越接近椭圆，正好压住时就是满宽；差一页以上就是普通圆点。 */
  private dotWidth(): number {
    const distance: number = Math.abs(this.pageIndex - this.active.position);
    if (distance >= 1) {
      return DOT_SIZE;
    }
    return DOT_SIZE + (DOT_ACTIVE_WIDTH - DOT_SIZE) * (1 - distance);
  }

  /** 透明度同理：越靠近活动位置越实。 */
  private dotOpacity(): number {
    const distance: number = Math.abs(this.pageIndex - this.active.position);
    if (distance >= 1) {
      return DOT_INACTIVE_OPACITY;
    }
    return DOT_INACTIVE_OPACITY + (1 - DOT_INACTIVE_OPACITY) * (1 - distance);
  }

  build() {
    Column()
      .width(this.dotWidth())
      .height(DOT_SIZE)
      .borderRadius(DOT_SIZE / 2)
      // 随主题自适应：深色主题下是白色，浅色主题下是近黑 —— 都能看见。
      .backgroundColor($r('app.color.primary_text'))
      .opacity(this.dotOpacity())
  }
}

@Component
export struct MediaCarousel {
  @Prop imageUrls: string[] = [];
  /** 键值前缀：用帖子 id，保证同一张卡片内的图片/圆点键值唯一。 */
  @Prop idPrefix: string = '';
  /** 媒体宽高比（宽/高）：由外层算好传进来（已含高度上限的修正）。 */
  @Prop aspect: number = 1;
  /**
   * 打开时显示第几张。
   *
   * 这个组件会被**重建**：点赞状态一变，外层 ForEach 的键值就变，整张卡片重新构建，
   * 新建出来的 Swiper 默认回到第一张。所以外层把「上次看到第几张」按帖子存在表里，
   * 每次重建时传回来，看到一半的图就不会被拽回开头。
   */
  @Prop initialPage: number = 0;
  /**
   * 首屏封面已解码张数（由 core/PosterCache 写）。
   *
   * 多图帖的第一张也会被预解码（见 PosterCache）：解好了就先垫上，真图加载完盖住 ——
   * 和单图帖同一套（见 FeedList 的 posterReady）。
   */
  @Prop posterReady: number = 0;
  /** 翻页后回报当前页号，供外层记住。 */
  onPageChange: (index: number) => void = (index: number): void => {
  };
  @State active: CarouselActive = new CarouselActive();

  aboutToAppear(): void {
    // 圆点形状由 position 算出来，重建时也得跟着回到那一张，否则图在第三张、圆点还在第一张。
    this.active.position = this.initialPage;
  }

  build() {
    Column({ space: 0 }) {
      Swiper() {
        ForEach(this.imageUrls, (url: string, index: number): void => {
          if (index === 0 && PosterCache.has(url, this.posterReady)) {
            // 第一张先垫预解码的小图（见 core/PosterCache）：首屏那格不用等真图。
            Stack() {
              Image(PosterCache.pixel(url)!)
                .draggable(false)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .backgroundColor($r('app.color.field_background'))
              Image(url)
                .draggable(false)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .backgroundColor($r('app.color.field_background'))
            }
            .width('100%')
            .height('100%')
          } else {
            Image(url)
              .draggable(false)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .backgroundColor($r('app.color.field_background'))
          }
        }, (url: string, index: number): string => `${this.idPrefix}-img-${index}`)
      }
      .width('100%')
      .aspectRatio(this.aspect)
      .loop(false)
      // 起始页 = 上次看到的那张。initialPage 在组件生命周期内不变，所以这条属性只会在
      // Swiper 创建时生效一次，不会在滑动过程中把页面拽回去。
      .index(this.initialPage)
      // 关掉内置指示器：它画在图里（也移不出去）。
      .indicator(false)
      // 关键：拖动过程中**以及**松手后的回弹动画期间，都逐帧回调。
      // position 是该页相对视口的连续偏移（单位：页），于是
      // 活动位置 = index - position（同一帧里各页算出来是同一个值）。
      .onContentDidScroll((selectedIndex: number, index: number, position: number,
                           mainAxisLength: number): void => {
        const next: number = index - position;
        if (Math.abs(next - this.active.position) < DOT_EPSILON) {
          return;
        }
        this.active.position = next;
      })
      // 兜底：稳定下来后对齐到整数页，免得最后一帧有零点几的残差留在那儿；
      // 同时把页号回报给外层记住（卡片重建时要靠它还原）。
      .onChange((index: number): void => {
        this.active.position = index;
        this.onPageChange(index);
      })

      Row({ space: DOT_SPACE }) {
        // 键值只用下标（稳定）：刷新走 @ObjectLink，不靠 ForEach 重建。
        ForEach(this.imageUrls, (url: string, index: number): void => {
          CarouselDot({ active: this.active, pageIndex: index })
        }, (url: string, index: number): string => `${this.idPrefix}-dot-${index}`)
      }
      .width('100%')
      .height(DOT_ROW_HEIGHT)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
