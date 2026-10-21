/*
 * 信息流**骨架屏**：冷启动/首屏加载期间唯一的占位。
 *
 * 用户要求：
 *   · "冷启动主页显示占位加载动画，包括快拍列表、帖子、文字等都需要占位加载动画，
 *     抛弃加载上一次缓存覆盖的功能"；
 *   · "占位组件需要按照原组件大小，并且分各部分单独占位"。
 *
 * 所以这里不是"一块大灰块"，而是**逐块对齐真实组件**：
 *
 * | 占位 | 对齐的真实组件 / 尺寸 |
 * | --- | --- |
 * | 快拍托盘 | `StoriesTray`：头像 80 + 外环 3(环宽 2.5)、项宽 106、名字条 11 高、托盘高 109、首端留白 EDGE_SPACER（直接复用 `StoryTraySkeleton`） |
 * | 作者行 | `FeedList.profileRow`：行高 52、头像 34(r17)、名字 14pt、关注胶囊 72×40、更多按钮 40×40 |
 * | 媒体 | 真实卡片的媒体块：`aspectRatio(0.8)`（4:5 竖图，IG 最常见） |
 * | 动作行 | `PostActions`：按钮高 40、内缩 8、图标 24~27、计数 13pt |
 * | 正文 | `CAPTION_FONT_SIZE` 14pt / 左右内缩 12 / 上 6，最多两行 |
 * | 发布时间 | 12pt 那一行（正文下面、底部留 16） |
 *
 * 尺寸常量能复用就复用（`StoryTraySkeleton`、`PROFILE_ROW_HEIGHT` 等按同值写在这里并注明来源），
 * 占位色统一 `field_background`（与真实媒体未加载时的底色同源），骨架 → 内容不跳色。
 */

import { StoryTraySkeleton } from './StoriesTray';

/** 光雾带宽（vp）。 */
const SHIMMER_WIDTH: number = 220;
/** 光雾横向扫过的起止位置（vp）：从屏幕左侧外扫到右侧外（手机宽度都落在这个区间）。 */
const SHIMMER_FROM: number = -SHIMMER_WIDTH;
const SHIMMER_TO: number = 560;
/** 一趟扫动的时长（毫秒）。 */
const SHIMMER_DURATION_MS: number = 1500;

/** 帖子骨架画几张（一屏大约 1.5 张，给两张足够铺满且不浪费）。 */
const CARD_PLACEHOLDERS: number = 2;

/* ---- 下面这些数字全部取自真实组件，改真实组件时要一起改 ---- */
/** 作者行行高（同 FeedList.PROFILE_ROW_HEIGHT）。 */
const PROFILE_ROW_H: number = 52;
/** 作者头像直径（同 FeedList.authorAvatar 的 34×34 / 圆角 17）。 */
const AVATAR: number = 34;
/** 关注胶囊尺寸（同 MaterialSurface.MATERIAL_PILL_WIDTH / MATERIAL_PILL_HEIGHT）。 */
const PILL_W: number = 72;
const PILL_H: number = 40;
/** 右侧「更多」按钮（同 MaterialIconButton 的 buttonSize 40）。 */
const MORE_BTN: number = 40;
/** 动作区：按钮高 40、整行左右内缩 8（同 PostActions）。 */
const ACTION_ROW_H: number = 40;
const ACTION_ROW_PAD: number = 8;
/** 动作区图标字号（同 FeedList 的 ICON_HEART / ICON_MESSAGE / ICON_TRANSFER / ICON_PLANE / ICON_BOOKMARK）。 */
const ICON_HEART: number = 24;
const ICON_MESSAGE: number = 27;
const ICON_TRANSFER: number = 25;
const ICON_PLANE: number = 24;
const ICON_BOOKMARK: number = 27;
/** 正文：字号 14、左右内缩 12、上 6（同 FeedList.CAPTION_FONT_SIZE / CAPTION_SIDE_PADDING）。 */
const CAPTION_FONT: number = 14;
const CAPTION_PAD: number = 12;
const CAPTION_TOP: number = 6;
/** 发布时间那一行：12pt，底部留 16。 */
const TIME_FONT: number = 12;
const CAPTION_BOTTOM: number = 16;
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

  /** 一条灰色横条（代表一行文字或一个未知尺寸的元素）。 */
  @Builder
  bar(barWidth: Length, barHeight: number) {
    Column()
      .width(barWidth)
      .height(barHeight)
      .borderRadius(barHeight / 2)
      .backgroundColor(PLACEHOLDER_BG)
  }

  /** 一块圆形占位（头像 / 图标 / 按钮）。 */
  @Builder
  circle(size: number) {
    Column()
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .backgroundColor(PLACEHOLDER_BG)
  }

  /* ================= 帖子：按真实组件的每一块单独占位 ================= */

  /**
   * **作者行**：高 52（同 PROFILE_ROW_HEIGHT）。
   *
   * 左：头像 34 + 名字（14pt 那行，占位条给个"典型宽度"）；
   * 右：「关注」胶囊 72×40 + 「更多」圆按钮 40 高。
   */
  @Builder
  profileRow() {
    Row({ space: 10 }) {
      this.circle(AVATAR)
      this.bar(118, 14)
      Blank()
      // 关注胶囊（真实那颗是 72×40 的材质胶囊）
      Column()
        .width(PILL_W)
        .height(PILL_H)
        .borderRadius(PILL_H / 2)
        .backgroundColor(PLACEHOLDER_BG)
      // 更多（真实那颗是 40×40 的圆按钮，里面的图标 20）
      this.circle(MORE_BTN)
    }
    .width('100%')
    .height(PROFILE_ROW_H)
    .padding({ left: CAPTION_PAD, right: CAPTION_PAD })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * **媒体块**：真实卡片的媒体是 `aspectRatio(mediaAspect)`（4:5 竖图 0.8、方形 1.0、横图 >1）。
   *
   * 骨架里取 **1:1**：0.8 的话一张占位就吃掉整屏（下方动作行 / 正文那几块占位全被推到屏幕外，
   * 看起来还是"一大块灰色"）；方形既在真实尺寸范围内，又能在首屏看到"作者行 / 媒体 / 动作行 /
   * 正文"四块各自独立的占位（用户要求："分各部分单独占位"）。真实卡片到达后按自己的比例排版。
   */
  @Builder
  mediaBlock() {
    Column()
      .width('100%')
      .aspectRatio(1)
      .backgroundColor(PLACEHOLDER_BG)
  }

  /**
   * **动作行**：与 PostActions 同一套尺寸 ——
   * 按钮高 40、整行左右内缩 8；四颗图标（心/评论/转发/分享）各带一条计数条，右端是收藏。
   */
  @Builder
  actionsRow() {
    Row({ space: 0 }) {
      this.actionItem(ICON_HEART)
      this.actionItem(ICON_MESSAGE)
      this.actionItem(ICON_TRANSFER)
      this.actionItem(ICON_PLANE)
      Blank()
      // 收藏：真实那颗是 40×40 的方按钮、图标 27
      Column()
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center) {
          this.circle(ICON_BOOKMARK)
        }
    }
    .width('100%')
    .height(ACTION_ROW_H)
    .padding({ left: ACTION_ROW_PAD, right: ACTION_ROW_PAD })
    .alignItems(VerticalAlign.Center)
  }

  /** 动作区的一颗「图标 + 计数」：按钮高 40、左右各 6 内缩（同 PostActions 的 Button）。 */
  @Builder
  actionItem(iconSize: number) {
    Row({ space: 4 }) {
      this.circle(iconSize)
      // 计数（真实那条是 13pt 数字，宽度不定 —— 给一个典型宽）
      this.bar(22, 13)
    }
    .height(40)
    .padding({ left: 6, right: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * **正文 + 发布时间**：正文 14pt（两行）、发布时间 12pt。
   *
   * 内缩与真实卡片一致（左右 12、正文上 6、底部 16），所以真实文字到货时不会把卡片撑高一截。
   */
  @Builder
  captionBlock() {
    Column({ space: 0 }) {
      Column({ space: 6 }) {
        this.bar('92%', CAPTION_FONT + 4)
        this.bar('58%', CAPTION_FONT + 4)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CAPTION_PAD, right: CAPTION_PAD, top: CAPTION_TOP })

      // 发布时间那一行（12pt）
      Row() {
        this.bar(72, TIME_FONT)
      }
      .width('100%')
      .padding({ left: CAPTION_PAD, right: CAPTION_PAD, top: 8, bottom: CAPTION_BOTTOM })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一张骨架帖子 = 作者行 + 媒体 + 动作行 + 正文（和真实卡片同序、同尺寸）。 */
  @Builder
  skeletonCard() {
    Column({ space: 0 }) {
      this.profileRow()
      this.mediaBlock()
      this.actionsRow()
      this.captionBlock()
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        /*
         * 快拍托盘：**直接用真实的托盘骨架组件**（`StoryTraySkeleton`），尺寸天然对齐
         * （头像 80 + 外环、项宽 106、名字条 11 高、托盘高 109）。托盘的取数还在路上时
         * 首页顶部就是这一排灰圆环，不会是一块空白。
         */
        StoryTraySkeleton()
        ForEach([0, 1], (index: number): void => {
          if (index < CARD_PLACEHOLDERS) {
            this.skeletonCard()
          }
        }, (index: number): string => `sk-card-${index}`)
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
