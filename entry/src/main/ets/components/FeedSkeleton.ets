/*
 * 信息流**骨架屏**（冷启动/首屏加载期间唯一的占位）。
 *
 * 用户要求（原话）："冷启动主页显示占位加载动画，包括快拍列表、帖子、文字等都需要占位加载动画，
 * 抛弃加载上一次缓存覆盖的功能。" —— 也就是：宁可先看一屏规整的骨架，也不要"先铺上次的缓存、
 * 几秒后再整体换掉"（那种观感像是内容闪了一下又重排）。
 *
 * 所以这一屏要按**真实版式**摆齐三块：
 *   ① 快拍托盘：一排圆环 + 圆环下面的名字条（和 StoriesTray 的形状对齐）；
 *   ② 帖子：作者行（头像 + 名字条 + 关注胶囊）、媒体块、动作行（四颗图标 + 右侧收藏）、
 *      正文两三行 —— 帖子给两张，滚动一屏之内都是骨架而不是空白；
 *   ③ 文字：正文与计数都用灰色横条表示。
 * 上面再扫过一条竖直光雾（shimmer），避免"整屏死灰"让人以为卡住了。
 *
 * 占位色用 `field_background`（和真实卡片的媒体占位色一致），骨架 → 真实内容不会跳色。
 */

/** 光雾带宽（vp）。 */
const SHIMMER_WIDTH: number = 220;
/** 光雾横向扫过的起止位置（vp）：从屏幕左侧外扫到右侧外（手机宽度都落在这个区间）。 */
const SHIMMER_FROM: number = -SHIMMER_WIDTH;
const SHIMMER_TO: number = 560;
/** 一趟扫动的时长（毫秒）。 */
const SHIMMER_DURATION_MS: number = 1500;

/** 托盘骨架画几个圆环（真机一屏大约能放下 5 个多一点）。 */
const TRAY_PLACEHOLDERS: number = 5;
/** 托盘圆环直径（vp）：比真实头像略小一点，看起来更"占位"。 */
const TRAY_CIRCLE: number = 62;
/** 帖子骨架画几张。 */
const CARD_PLACEHOLDERS: number = 2;
/** 动作行里的小块尺寸（vp）。 */
const ACTION_DOT: number = 22;
/** 统一的占位灰（与真实媒体未加载时的底色同源）。 */
const PLACEHOLDER_BG: ResourceStr = $r('app.color.field_background');

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

  /** 一条灰色横条，代表一行未加载的文字（或一个未知尺寸的元素）。 */
  @Builder
  bar(barWidth: Length, barHeight: number) {
    Column()
      .width(barWidth)
      .height(barHeight)
      .borderRadius(barHeight / 2)
      .backgroundColor(PLACEHOLDER_BG)
  }

  @Builder
  dot(size: number, radius: number) {
    Column()
      .width(size)
      .height(size)
      .borderRadius(radius)
      .backgroundColor(PLACEHOLDER_BG)
  }

  /**
   * **快拍托盘骨架**：一排圆环 + 下面的名字条。
   *
   * 形状照着 StoriesTray 的真实布局做（圆环 62 + 名字条 10 高、间距一致），
   * 这样真实托盘长出来时只是"灰块变成头像"，不会整块重排。
   */
  @Builder
  trayRow() {
    Row({ space: 16 }) {
      ForEach([0, 1, 2, 3, 4], (index: number): void => {
        Column({ space: 10 }) {
          this.dot(TRAY_CIRCLE, TRAY_CIRCLE / 2)
          this.bar(46, 10)
        }
        .alignItems(HorizontalAlign.Center)
      }, (index: number): string => `tray-${index}`)
    }
    .width('100%')
    .height(TRAY_CIRCLE + 24)
    .alignItems(VerticalAlign.Top)
    .padding({ left: 16, right: 16, top: 12 })
  }

  /**
   * **一张帖子骨架**：版式与真实卡片一致。
   *
   * 从上到下：作者行（34 头像 + 名字条 + 右侧「关注」胶囊）、媒体块（4:5，和常见竖图一致）、
   * 动作行（心 / 评论 / 转发 / 分享 + 右侧收藏）、正文两行 + 时间条。
   */
  @Builder
  skeletonCard() {
    Column({ space: 0 }) {
      // 作者行
      Row({ space: 10 }) {
        this.dot(34, 17)
        this.bar(118, 12)
        Blank()
        this.bar(62, 26)
        this.dot(24, 12)
      }
      .width('100%')
      .height(52)
      .padding({ left: 12, right: 12 })

      // 媒体块
      Column()
        .width('100%')
        .aspectRatio(0.8)
        .backgroundColor(PLACEHOLDER_BG)

      // 动作行：四颗图标 + 右侧收藏
      Row({ space: 18 }) {
        this.dot(ACTION_DOT, ACTION_DOT / 2)
        this.dot(ACTION_DOT, ACTION_DOT / 2)
        this.dot(ACTION_DOT, ACTION_DOT / 2)
        this.dot(ACTION_DOT, ACTION_DOT / 2)
        Blank()
        this.dot(ACTION_DOT, ACTION_DOT / 2)
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12 })

      // 正文 + 发布时间
      Column({ space: 8 }) {
        this.bar('92%', 12)
        this.bar('64%', 12)
        this.bar(72, 10)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 6, bottom: 18 })
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.trayRow()
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
