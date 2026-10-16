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
import { MediaSlide } from '../model/MediaPost';
import { VideoSurface } from './VideoSurface';

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
  /**
   * 逐页媒体（图 / 视频混排，见 model/MediaPost 的 MediaSlide）。
   *
   * 需求："feeds 流多图片媒体可以包含视频媒体……多媒体播放逻辑按照视频播放逻辑写"。
   * 所以这一页是不是视频由它自己说（`slide.isVideo()`），是视频就用**和单视频帖完全同一个**
   * `VideoSurface`（AVPlayer + XComponent）来播 —— 不是另起一套播放实现。
   */
  @Prop slides: MediaSlide[] = [];
  /**
   * 兼容用的图片地址表（老数据 / 逐页媒体没解析出来时用它兜底）。
   *
   * 为什么必须留这条兜底：`slides` 来自"逐页媒体"那条新链路，任何一环没给（老缓存、
   * 接口没带 `carousel_media`、脚本那条路没导出）都会是空数组 —— 那时若只画 slides，
   * **整条多图帖会变成空白**（比"视频页不播"严重得多）。所以空数组时按纯图片渲染。
   */
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
  /**
   * 这条帖子现在是不是"该播"（= 被聚焦的那条，见 FeedList.isPlaying）。
   *
   * 视频页是否真的在播 = **本属性 && 当前页是视频页** —— 多图帖翻到图片页时，
   * 上一页的视频必须停下来（否则会有看不见的声音在放）。
   */
  @Prop playing: boolean = false;
  /** 是不是"下一条要预加载"的帖子（提前把它的视频页准备起来，见 FeedList.preloadKey）。 */
  @Prop preload: boolean = false;
  /** 静音（全局开关，见 AppSettings.SETTING_VIDEO_MUTED）。 */
  @Prop muted: boolean = false;
  /** 翻页后回报当前页号，供外层记住。 */
  onPageChange: (index: number) => void = (index: number): void => {
  };
  /** 某一页的视频出了首帧（外层据此把"已就绪"记下来）。 */
  onVideoReady: (page: number) => void = (page: number): void => {
  };
  /** 某一页的视频播不出来（外层据此撤封面，别让那页永远只剩封面）。 */
  onVideoError: (page: number) => void = (page: number): void => {
  };
  @State active: CarouselActive = new CarouselActive();
  /** 当前所在页（整数）：只有它上面的视频才播，见 playing 的说明。 */
  @State private page: number = 0;
  /** 已经出过首帧的页（撤封面用；数组整体替换，@State 才会通知）。 */
  @State private readyPages: Array<number> = [];

  aboutToAppear(): void {
    // 圆点形状由 position 算出来，重建时也得跟着回到那一张，否则图在第三张、圆点还在第一张。
    this.active.position = this.initialPage;
    this.page = this.initialPage;
  }

  /**
   * 实际要渲染的页：优先 `slides`（含视频页），没有就按纯图片兜底（见 imageUrls 的说明）。
   *
   * 每次 build 都算一遍：它是纯函数、只有几项，开销可以忽略；而缓存成字段会在
   * `@Prop` 变化时变旧（@Prop 变了但组件没重建的情况是有的）。
   */
  private pages(): Array<MediaSlide> {
    if (this.slides.length > 0) {
      return this.slides;
    }
    const out: Array<MediaSlide> = [];
    for (let index: number = 0; index < this.imageUrls.length; index++) {
      out.push(new MediaSlide(this.imageUrls[index], ''));
    }
    return out;
  }

  /** 这一页现在该不该播：帖子被聚焦 + 就是当前这一页 + 确实是视频页。 */
  private pagePlaying(index: number): boolean {
    if (!this.playing || index !== this.page) {
      return false;
    }
    const pages: Array<MediaSlide> = this.pages();
    return index >= 0 && index < pages.length && pages[index].isVideo();
  }

  /**
   * 这一页要不要**挂播放器**。
   *
   * 只在"该播的"和"下一条要预加载的那条的第一个视频页"上挂：缓存区里每页都开一个解码器
   * 会互相抢带宽（这正是预加载想避免的）。与单视频帖的 hasSurface 同一条思路。
   */
  private pageHasSurface(index: number): boolean {
    const pages: Array<MediaSlide> = this.pages();
    if (index < 0 || index >= pages.length || !pages[index].isVideo()) {
      return false;
    }
    if (this.pagePlaying(index)) {
      return true;
    }
    return this.preload && index === this.firstVideoPage();
  }

  /** 第一个视频页的下标（预加载用；没有给 -1）。 */
  private firstVideoPage(): number {
    const all: Array<MediaSlide> = this.pages();
    for (let index: number = 0; index < all.length; index++) {
      if (all[index].isVideo()) {
        return index;
      }
    }
    return -1;
  }

  private isReady(index: number): boolean {
    return this.readyPages.indexOf(index) >= 0;
  }

  private markReady(index: number): void {
    if (this.isReady(index)) {
      return;
    }
    const next: Array<number> = this.readyPages.slice(0);
    next.push(index);
    this.readyPages = next;
  }

  build() {
    Column({ space: 0 }) {
      Swiper() {
        ForEach(this.pages(), (slide: MediaSlide, index: number): void => {
          /*
           * **视频页照视频逻辑走**（见 slides 的说明）：和单视频帖一样用 VideoSurface，
           * 封面（这一页的图片地址）在第一帧到位前盖住它。图片页就是原来的那张图。
           */
          if (slide.isVideo() && this.pageHasSurface(index)) {
            Stack() {
              VideoSurface({
                url: slide.videoUrl,
                playing: this.pagePlaying(index),
                // 预加载那条挂上播放器、但不播（VideoSurface 自己会 prepare）。
                preload: this.preload && !this.pagePlaying(index),
                // 与单视频帖一致：盒子是按帖子比例算的，用 Cover 才不会有黑边/闪烁。
                cover: true,
                muted: this.muted,
                onFirstFrame: (): void => {
                  this.markReady(index);
                  this.onVideoReady(index);
                },
                onError: (): void => {
                  // 播不出来也得撤封面，否则这一页永远只剩封面（看着像卡住）。
                  this.markReady(index);
                  this.onVideoError(index);
                }
              })
              .width('100%')
              .height('100%')

              if (!this.isReady(index) && slide.imageUrl.length > 0) {
                Image(slide.imageUrl)
                  .draggable(false)
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Contain)
                  .backgroundColor($r('app.color.field_background'))
              }
            }
            .width('100%')
            .height('100%')
          } else if (index === 0 && !slide.isVideo() && PosterCache.has(slide.imageUrl, this.posterReady)) {
            // 第一张先垫预解码的小图（见 core/PosterCache）：首屏那格不用等真图。
            Stack() {
              Image(PosterCache.pixel(slide.imageUrl)!)
                .draggable(false)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .backgroundColor($r('app.color.field_background'))
              Image(slide.imageUrl)
                .draggable(false)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .backgroundColor($r('app.color.field_background'))
            }
            .width('100%')
            .height('100%')
          } else {
            Image(slide.imageUrl)
              .draggable(false)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .backgroundColor($r('app.color.field_background'))
          }
        }, (slide: MediaSlide, index: number): string => `${this.idPrefix}-slide-${index}`)
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
        // 页号一变，上一页的视频立刻停、这一页的（若视频）开始播 —— 见 pagePlaying。
        this.page = index;
        this.onPageChange(index);
      })

      Row({ space: DOT_SPACE }) {
        // 键值只用下标（稳定）：刷新走 @ObjectLink，不靠 ForEach 重建。
        ForEach(this.pages(), (slide: MediaSlide, index: number): void => {
          CarouselDot({ active: this.active, pageIndex: index })
        }, (slide: MediaSlide, index: number): string => `${this.idPrefix}-dot-${index}`)
      }
      .width('100%')
      .height(DOT_ROW_HEIGHT)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
