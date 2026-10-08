/*
 * 信息流骨架屏。
 *
 * 进入应用或首屏加载期间，先按真实帖子的版式铺一层灰色占位：头像与用户名是灰块，
 * 媒体是灰色方块，点赞数与正文是灰色横条；上面再扫过一条竖直光雾，避免白屏干等。
 * 真实帖子一到，FeedList 会把整块换成帖子原样。
 *
 * 占位色用的是和真实卡片一致的 field_background（图片未加载时也是这个色），
 * 所以骨架 → 真实内容的切换不会跳色。
 */

/** 光雾带宽（vp）。 */
const SHIMMER_WIDTH: number = 220;
/** 光雾横向扫过的起止位置（vp）：从屏幕左侧外扫到右侧外（手机宽度都落在这个区间）。 */
const SHIMMER_FROM: number = -SHIMMER_WIDTH;
const SHIMMER_TO: number = 560;
/** 一趟扫动的时长（毫秒）。 */
const SHIMMER_DURATION_MS: number = 1500;

@Component
export struct FeedSkeleton {
  @State private shimmerX: number = SHIMMER_FROM;
  /** 光雾只起一次（见 onDidBuild 的说明）。 */
  private shimmerStarted: boolean = false;

  /**
   * 在 build 之后起光雾动画。
   *
   * 不能放 aboutToAppear：SDK 明确说明那个阶段 build 还没执行、内部组件还没创建，
   * 动画拿不到初值，不会生效；而 onAppear 是挂在组件上的属性（返回 CommonAttribute），
   * 不是结构体生命周期。onDidBuild 才是 build 执行之后的回调。
   *
   * 另外全局 animateTo 自 API 18 起已废弃，改用 UIContext 上的这一个；
   * iterations: -1 按 SDK 语义表示无限重复。
   */
  onDidBuild(): void {
    if (this.shimmerStarted) {
      // onDidBuild 每次重渲染都可能被调用；重复起动画会让起点等于终点，光雾反而停住。
      return;
    }
    this.shimmerStarted = true;
    this.getUIContext().animateTo({
      duration: SHIMMER_DURATION_MS,
      curve: Curve.Linear,
      iterations: -1
    }, (): void => {
      this.shimmerX = SHIMMER_TO;
    });
  }

  /** 一条灰色横条，代表一行未加载的文字。 */
  @Builder
  bar(barWidth: Length) {
    Column()
      .width(barWidth)
      .height(12)
      .borderRadius(6)
      .backgroundColor($r('app.color.field_background'))
  }

  /** 一张骨架卡片：版式与真实帖子一致（作者行 / 方形媒体 / 文字行）。 */
  @Builder
  skeletonCard() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Column()
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor($r('app.color.field_background'))
        this.bar(120)
        Blank()
      }
      .width('100%')
      .height(52)
      .padding({ left: 12, right: 12 })

      // 媒体：灰色方块
      Column()
        .width('100%')
        .aspectRatio(1)
        .backgroundColor($r('app.color.field_background'))

      Column({ space: 8 }) {
        this.bar(90)
        this.bar('100%')
        this.bar('72%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 12, bottom: 16 })
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.skeletonCard()
        this.skeletonCard()
      }
      .width('100%')

      // 竖直光雾：angle 90 让渐变沿水平方向推进，于是形成一条竖直的亮带，再横向扫动。
      Column()
        .width(SHIMMER_WIDTH)
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['#00FFFFFF', 0.0], ['#1AFFFFFF', 0.5], ['#00FFFFFF', 1.0]]
        })
        .translate({ x: this.shimmerX })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}
