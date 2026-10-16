/*
 * 限时快拍托盘（主页 feeds 流上方那一排）。
 *
 * 需求："显示在 feeds 流上方、hds title 下方；用户头像横向排列；未查看快拍外层用一圈渐变
 * 色圆圈套着头像；已读该用户所有快拍则变灰；点击头像时加载添加圆圈转圈动画，加载成功
 * 跳进新页面。"
 *
 * 实现在这里只做"好看的那条托盘"：取数交给 core/NativeStories，点开的跳页/转场交给宿主
 * （`onOpen`），因为"从头像放大到全屏 + 头像飞到左上角"要用共享元素过渡，必须由承载页面
 * 那一层来绑 `geometryTransition`。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeStories } from '../core/NativeStories';
import { StoryHeroRect, storyAvatarNodeId, StoryTrayItem } from '../model/Story';

const DOMAIN: number = 0xFF00;
const TAG: string = 'StoriesTray';
/** 头像直径（vp）；外环再各外扩 RING_GAP。需求："头像做大一点"（64 → 72 → 80）。 */
const AVATAR_VP: number = 80;
/** 头像与外环之间的留白（vp）—— 需求里那圈"套着头像"的渐变环。 */
const RING_GAP_VP: number = 3;
/** 环的粗细（vp）。 */
const RING_WIDTH_VP: number = 2.5;
/** 每一项的宽度（含左右留白）。 */
const ITEM_WIDTH_VP: number = 106;
/** 已读（全看完）时的灰色环。 */
const SEEN_GREY: string = '#C7C7C7';
/**
 * 点开之后那一圈转圈最多显示多久（毫秒）。
 *
 * 原来 2500ms 太长：这一项在转圈期间是**不能**再点的，而"点开→马上收起→再点同一位"是常见操作，
 * 2.5 秒内都会被吃掉。1.5 秒够网络慢的情况把转圈显示出来，又不至于挡太久。
 */
const PENDING_MS: number = 1500;
/**
 * 宿主带来的那份托盘数据"够新鲜"多久（毫秒）。
 *
 * 切 tab 回来时组件是**重建**的（内容层是 `if (selectedIndex === 0)`，见 Index.nativeShellContent），
 * 所以每次都会重新 `aboutToAppear`。有宿主那份数据就**立刻画出来**（这就是"秒盖上刚刚的数据"），
 * 只有在它过期时才去后台刷一次 —— 否则每切一次 tab 就打一发 IG 的托盘接口。
 *
 * 取 3 分钟：托盘的内容变化很慢（快拍 24 小时才过期），而"刚看完的快拍变灰"这类状态
 * 由 StoryViewer 主动回报（见 Index 的 storyQueue 更新），不靠重新拉。
 */
const TRAY_FRESH_MS: number = 3 * 60 * 1000;
/** 数据没到时画几个灰色占位头像（需求："数据没加载好可以在头像显示灰色"）。 */
const SKELETON_COUNT: number = 5;
/** 占位头像下面那条灰条的高度（vp）—— 和真名字那一行等高，免得列表上下跳。 */
const SKELETON_LABEL_H_VP: number = 11;

@Component
export struct StoriesTray {
  /**
   * 点开某一项：宿主负责拉数据 + 开播放页（转场要用被点头像**在屏幕上的矩形**，
   * 所以一起传过去，见 model/Story.StoryHeroRect）。
   */
  onOpen: (item: StoryTrayItem, rect: StoryHeroRect) => void =
    (item: StoryTrayItem, rect: StoryHeroRect): void => {
    };
  /**
   * 托盘拉到了（把整条顺序交给宿主）。
   *
   * 宿主需要这份顺序：看某一位的最后一条时，点右半屏要接**下一位**（需求），
   * 那得有"下一位是谁"的名单。
   */
  onLoaded: (items: Array<StoryTrayItem>) => void = (items: Array<StoryTrayItem>): void => {
  };
  /**
   * 托盘里**当前可见**的下标范围（起始 / 结束，对应 `items` 的下标）。
   *
   * 宿主拿它做**预加载**：屏幕上看得见的那几位用户的 story 先取好，用户点开哪一位都是秒显示
   * （需求："显示在屏幕中的用户 stories 提前加载，点开秒显示内容"）。
   */
  onVisibleRange: (start: number, end: number) => void = (start: number, end: number): void => {
  };
  /**
   * 某一项头像**当前**在屏幕上的位置（每次布局变化都会来一发）。
   *
   * 宿主留着这张表：收起播放页时要知道"现在这一位的头像在托盘哪个位置"
   * （见 Index.playStoryAt 与 StoryViewer.requestClose）。
   */
  onRect: (userId: string, rect: StoryHeroRect) => void =
    (userId: string, rect: StoryHeroRect): void => {
    };
  /**
   * 宿主手上那份"上一次拉到的托盘"（Index.storyQueue）。
   *
   * 用途：切 tab 回来时本组件是重建的，`items` 从空开始 —— 没有它就会先空一块（占位）、
   * 再等一发网络才出现，也就是用户报的"每次切换页面都会消失一会才加载出来"。
   * 有它就在 `aboutToAppear` 里**先画出来**，网络只在数据过期时后台补。
   */
  seed: Array<StoryTrayItem> = [];
  /** 那份 seed 是什么时候拉到的（毫秒；0 = 没有）。见 TRAY_FRESH_MS。 */
  seedAtMs: number = 0;
  @State private items: Array<StoryTrayItem> = [];
  /** 正在"点开"的那一项（那一项的外环换成转圈）。 */
  @State private pendingUser: string = '';
  /** 转圈那个定时器的句柄（见 onTap 与 aboutToDisappear）。 */
  private pendingTimer: number = -1;

  aboutToDisappear(): void {
    if (this.pendingTimer >= 0) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = -1;
    }
  }
  @State private loaded: boolean = false;
  /**
   * 每一项头像在当前这一帧的位置（vp）。
   *
   * 用 `onAreaChange` 量的：转场第一帧要**正好画在被点的那个头像上**，差一点点就看得出来。
   * 列表滚过之后这里会跟着更新（onAreaChange 每次布局变化都会来）。
   */
  private rects: Map<string, StoryHeroRect> = new Map<string, StoryHeroRect>();

  /** Length（number | string | Resource）→ vp 数值；认不出给 0。 */
  private static len(value: Length | undefined): number {
    if (value === undefined) {
      return 0;
    }
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'string') {
      const parsed: number = Number.parseFloat(value);
      return Number.isFinite(parsed) ? parsed : 0;
    }
    return 0;
  }

  private captureRect(userId: string, area: Area): void {
    const rect: StoryHeroRect = new StoryHeroRect(
      StoriesTray.len(area.globalPosition.x),
      StoriesTray.len(area.globalPosition.y),
      StoriesTray.len(area.width),
      StoriesTray.len(area.height)
    );
    this.rects.set(userId, rect);
    // 交一份给宿主：播放页收起时要按**当前这一位**的托盘位置收缩（不只是被点开的那一位，
    // 见 Index.storyRects）。
    this.onRect(userId, rect);
  }

  aboutToAppear(): void {
    /*
     * **先铺宿主那份数据，再决定要不要联网**（需求："切页面保留当前数据，回到主页秒盖上刚刚的数据"）。
     *
     * 这一步必须是**同步**的：`items` 在 `aboutToAppear` 里赋好值，首帧就直接画出来，
     * 中间不存在"空一块"的帧。注意这里**不回调 `onLoaded`** —— 宿主本来就还留着这份顺序，
     * 再交一次会触发 `StoryCache.reset`（那会把已经热好的预缓存整条扔掉）。
     */
    if (this.seed.length > 0) {
      this.items = this.seed;
      this.loaded = true;
      // 记一行：这是"切回来没有先空/先灰"的现场证据（也是 seed 时间戳是否合理的核对点）。
      hilog.info(DOMAIN, TAG, 'tray from seed n=%{public}d age=%{public}dms',
        this.seed.length, this.seedAtMs > 0 ? Date.now() - this.seedAtMs : -1);
      if (Date.now() - this.seedAtMs < TRAY_FRESH_MS) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'tray seed stale age=%{public}dms → refresh',
        Date.now() - this.seedAtMs);
    }
    this.load();
  }

  /** 拉一次托盘（失败就整条不显示，别在首页留一块空）。 */
  private load(): void {
    NativeStories.tray().then((tray): void => {
      this.loaded = true;
      if (tray === null) {
        hilog.info(DOMAIN, TAG, 'tray unavailable: %{public}s', NativeStories.lastDetail());
        return;
      }
      this.items = tray.items;
      this.onLoaded(tray.items);
    }).catch((): void => {
      this.loaded = true;
    });
  }

  /** 头像外那一圈：未看完=渐变环，全看完=灰环，点开中=转圈。 */
  @Builder
  ring(one: StoryTrayItem, spinning: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (spinning) {
        // 点开中：外环位置就是转圈（需求："点击头像时加载添加圆圈转圈动画"）。
        LoadingProgress()
          .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
          .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
          .color($r('app.color.accent'))
      } else if (one.seen) {
        Column()
          .width(AVATAR_VP + RING_GAP_VP * 2)
          .height(AVATAR_VP + RING_GAP_VP * 2)
          .borderRadius((AVATAR_VP + RING_GAP_VP * 2) / 2)
          .border({ width: RING_WIDTH_VP, color: SEEN_GREY })
      } else {
        // 未看完：一整圈渐变环（两色线性渐变）；内层再垫一圈页面底色，做出"环"的观感。
        Column()
          .width(AVATAR_VP + RING_GAP_VP * 2)
          .height(AVATAR_VP + RING_GAP_VP * 2)
          .borderRadius((AVATAR_VP + RING_GAP_VP * 2) / 2)
          .linearGradient({
            angle: 45,
            colors: [['#F9CE34', 0.0], ['#EE2A7B', 0.5], ['#6228D7', 1.0]]
          })
      }
      /*
       * 头像本体（比环小一圈，于是环露在外面）。
       *
       * **转场量的就是它这一块**（`captureRect`）：不能量外圈那个 Stack —— 那是"头像 + 渐变环"
       * 的整块（91vp），飞行头像按它收缩会**盖住渐变环**，落地时再弹回 80vp 的真头像，
       * 看着就是"头像下沉一下再归位 + 一圈黑边"（用户报的）。量头像本体，落点分毫不差。
       */
      Image(one.avatarUrl.length > 0 ? one.avatarUrl : $r('app.media.startIcon'))
        .id(storyAvatarNodeId(one.userId))
        .draggable(false)
        .width(AVATAR_VP)
        .height(AVATAR_VP)
        .borderRadius(AVATAR_VP / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))
        .border({ width: 2, color: $r('app.color.page_background') })
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          this.captureRect(one.userId, newArea);
        })
    }
    .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
    .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
  }

  @Builder
  itemView(one: StoryTrayItem) {
    Column({ space: 6 }) {
      this.ring(one, this.pendingUser === one.userId)
      Text(one.username.length > 0 ? one.username : ' ')
        .fontSize(11)
        .fontColor($r('app.color.primary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(ITEM_WIDTH_VP - 8)
        .textAlign(TextAlign.Center)
    }
    .width(ITEM_WIDTH_VP)
    .onClick((): void => {
      /*
       * 防连点**不再挡点击**（需求："退出当前用户 story 后可以马上打开其他用户的 story"）。
       *
       * 以前这里有一道 `pendingUser` 守卫：转圈期间（原来 2500ms、后来 1500ms）同一项点不动
       * —— "点开 → 马上收起 → 再点同一位/另一位"就会被吃掉。现在转圈只是**视觉反馈**，
       * 点一次就照常往上报；真重复点也没事：宿主那边浮层一开就把托盘盖住了。
       */
      this.pendingUser = one.userId;
      /*
       * 转圈只是视觉反馈（PENDING_MS 后自己灭）。**句柄存起来、销毁时清掉** —— 审计发现这个
       * `setTimeout` 没有句柄、也没有 `aboutToDisappear`：托盘在转圈期间被销毁（切 tab/浮层盖住后
       * 重建）时，这个回调仍会去写已卸载组件的 `@State`。
       */
      this.pendingTimer = setTimeout((): void => {
        this.pendingTimer = -1;
        if (this.pendingUser === one.userId) {
          this.pendingUser = '';
        }
      }, PENDING_MS);
      const rect: StoryHeroRect | undefined = this.rects.get(one.userId);
      this.onOpen(one, rect === undefined ? new StoryHeroRect(0, 0, 0, 0) : rect);
    })
  }

  /**
   * 数据还没到时的**灰色占位头像**（需求："数据没加载好可以在头像显示灰色"）。
   *
   * 尺寸与真头像**逐项对齐**（同一个外圈直径 + 同一行文字高度），所以数据到时是"灰圈里
   * 长出内容"，不会有任何跳动。颜色用主题里那两个灰：`field_background` 正好也是真头像
   * 加载不出来时的兜底色，`divider` 比它深/浅一档，用来画外环和下面那条名字位。
   */
  @Builder
  skeletonItem() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(AVATAR_VP + RING_GAP_VP * 2)
          .height(AVATAR_VP + RING_GAP_VP * 2)
          .borderRadius((AVATAR_VP + RING_GAP_VP * 2) / 2)
          .border({ width: RING_WIDTH_VP, color: $r('app.color.divider') })
        Column()
          .width(AVATAR_VP)
          .height(AVATAR_VP)
          .borderRadius(AVATAR_VP / 2)
          .backgroundColor($r('app.color.field_background'))
      }
      .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
      .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
      // 名字那一行也占住：真数据到时高度不变（见文件里"列表不要上下跳"的一贯要求）。
      Column()
        .width(ITEM_WIDTH_VP - 32)
        .height(SKELETON_LABEL_H_VP)
        .borderRadius(SKELETON_LABEL_H_VP / 2)
        .backgroundColor($r('app.color.field_background'))
    }
    .width(ITEM_WIDTH_VP)
  }

  /** 一排灰色占位（横向排列，和真托盘同一套间距/内边距）。 */
  @Builder
  skeletonRow() {
    Row({ space: 0 }) {
      ForEach([0, 1, 2, 3, 4], (index: number): void => {
        if (index < SKELETON_COUNT) {
          this.skeletonItem()
        }
      }, (index: number): string => `sk-${index}`)
    }
    .width('100%')
    .height(AVATAR_VP + RING_GAP_VP * 2 + 26)
    // 左右留白为零（与真托盘一致，见 build 里 List 那段"穿过屏幕"的说明）：占位与真内容
    // 必须左右对齐，否则数据一到位整排会横向跳一下。
    .padding({ left: 0, right: 0 })
    // 占位不接手指：它只是"还没到"的观感，别让它抢掉列表的滑动。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    /*
     * **三态，高度完全一致**：
     *   ① 有数据 → 真托盘（List）；
     *   ② 还没拉到（首启 / 换账号）→ 一排**灰色占位头像**（需求："数据没加载好可以在头像显示灰色"）；
     *   ③ 拉完了但确实没有（没登录 / 接口不给）→ 同高的空占位。
     *
     * 为什么不是"一直建 List、数据到了再灌"：试过，真机上结果是**整条序列真的不渲染**
     * （日志里 `story queue n=136`、`story visible 0-3` 全正常，屏幕上一片空）——
     * 空 List 先建、之后灌数据这条路在真机上不可靠。所以仍然"有数据才建 List"，
     * 但把"没数据"那一段从空白换成占位。
     *
     * 为什么切 tab 回来不会先灰一下：宿主那份 `seed` 在 `aboutToAppear` 里**同步**铺上，
     * 首帧就是真内容（见 aboutToAppear）。
     */
    if (this.items.length > 0) {
      List({ space: 0 }) {
        ForEach(this.items, (one: StoryTrayItem): void => {
          ListItem() {
            this.itemView(one)
          }
        }, (one: StoryTrayItem): string => `${one.userId}-${one.seen ? 's' : 'n'}`)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 可见范围报给宿主：屏幕上看得见的那几位用户的 story 提前取好（见 onVisibleRange）。
      .onScrollIndex((start: number, end: number): void => {
        this.onVisibleRange(start, end);
      })
      .width('100%')
      .height(AVATAR_VP + RING_GAP_VP * 2 + 26)
      /*
       * **左右不留白**（需求："我想让它穿过屏幕左右"；用户报的"屏幕边缘出现空隙"就是这里）。
       *
       * 三条路的实测记录，别再走回头路：
       *   · **List 的左右 padding**（曾经这么写）：滑动区被一起缩窄 → 内容在离屏幕边
       *     8vp 处就被裁掉，两端于是永远有一条**空带**（截图里左边那条黑边 +
       *     被切一半的圆环就是这个）；
       *   · **负 margin**：只能撑大盒子，管不了内容两端 —— 现场是"左边贴住、右边不贴"；
       *   · **`contentStartOffset` / `contentEndOffset`**：装上之后整条快拍序列直接不渲染
       *     （日志里 `story queue n=136`、`story visible 0-3` 全正常，屏幕上一片空）。
       * 所以最终就是**什么都不加**：行本身整屏宽，第一位紧贴左边、内容滑到两端时直接穿出屏幕。
       */
    } else if (!this.loaded) {
      // 正在拉：先摆一排灰色占位（而不是空一块），观感是"内容马上来"。
      this.skeletonRow()
    } else {
      // 拉完了确实没有：占一块同高的空位，信息流不跳。
      Column()
        .width('100%')
        .height(AVATAR_VP + RING_GAP_VP * 2 + 26)
    }
  }
}
