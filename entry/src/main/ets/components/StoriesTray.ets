/*
 * 限时快拍托盘（主页 feeds 流上方那一排）。
 *
 * 需求："显示在 feeds 流上方、hds title 下方；用户头像横向排列；未查看快拍外层用一圈渐变
 * 色圆圈套着头像；已读该用户所有快拍则变灰；点击头像时加载添加圆圈转圈动画，加载成功
 * 跳进新页面。"
 *
 * 后来加的三条（本文件负责的部分）：
 *   ① **第一位固定是「你的快拍」**：自己的头像 + 右下角一颗沉浸光感的「+」；
 *   ② **推荐快拍**（`suggested_user_reel`，新号最常见）：头像底部一条椭圆「+关注」胶囊，
 *      点了关注就整条消失（见 onFollow 与 followSuggested）；
 *   ③ 整条列表的**首尾都从屏幕边缘往里让一段**（EDGE_PAD_VP），但行本身仍是整屏宽 ——
 *      滚动时头像照样穿出屏幕左右（见 build 里那段说明）。
 *
 * 实现在这里只做"好看的那条托盘"：取数交给 core/NativeStories，点开的跳页/转场交给宿主
 * （`onOpen`），因为"从头像放大到全屏 + 头像飞到左上角"要用共享元素过渡，必须由承载页面
 * 那一层来绑 `geometryTransition`。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeStories } from '../core/NativeStories';
import { StoryHeroRect, storyAvatarNodeId, StoryTrayItem } from '../model/Story';
import { MaterialIconButton, MaterialPillIcon } from './MaterialSurface';

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
/**
 * 头像**可见边**到屏幕左右边的距离（vp）。需求："快拍列表的 padding left right 调整成 16vp"。
 *
 * 注意这是量**头像那一圈**的边，不是项盒子的边：项宽 106 里，环（91）两边各留 ITEM_INNER、
 * 环里头像两边各留 RING_INNER，所以列表两端的空条目只需要 EDGE_SPACER 那么宽 ——
 * 加起来正好 16。改这一个数，可视角落跟着走。
 */
const EDGE_PAD_VP: number = 16;
/** 项内留白：项宽里环两侧的余量。 */
const ITEM_INNER_VP: number = (ITEM_WIDTH_VP - (AVATAR_VP + RING_GAP_VP * 2)) / 2;
/** 环里头像两侧的余量（环的留白 + 描边）。 */
const RING_INNER_VP: number = RING_GAP_VP + RING_WIDTH_VP;
/**
 * 列表两端那条空条目的宽度（vp）。
 *
 * 为什么是"空条目"而不是 List 的 padding：List 的 padding 会把可滚动区一起缩窄，内容就
 * 再也滑不到屏幕边外（以前踩过，见 build 里那段说明）。空条目只在"停住时"占位，
 * 滑起来它自己滚走 —— 两头的留白有了，头像照样整颗穿出屏幕。
 */
const EDGE_SPACER_VP: number = EDGE_PAD_VP - ITEM_INNER_VP - RING_INNER_VP;
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
 * 取 10 分钟：托盘的内容变化很慢（快拍 24 小时才过期），而"刚看完的快拍变灰"这类状态
 * 由 StoryViewer 主动回报（见 Index 的 storyQueue 更新），不靠重新拉。
 *
 * **为什么从 3 分钟拉长到 10 分钟**：IG 的"推荐快拍"是**按时间发放**的（真机日志里两次拿到
 * 推荐正好隔了约一小时），而每 3 分钟拉一次托盘会让账号一直"在刷新"，推荐位迟迟不再发。
 * 拉长之后启动/切页只会复用宿主那份数据，真正打接口的只剩一次，推荐位更容易落下来。
 */
const TRAY_FRESH_MS: number = 10 * 60 * 1000;
/** 数据没到时画几个灰色占位头像（需求："数据没加载好可以在头像显示灰色"）。 */
const SKELETON_COUNT: number = 5;
/** 占位头像下面那条灰条的高度（vp）—— 和真名字那一行等高，免得列表上下跳。 */
const SKELETON_LABEL_H_VP: number = 11;
/** 整条托盘的高度（vp）：头像外圈 + 名字那一行 + 间距。 */
const TRAY_HEIGHT_VP: number = AVATAR_VP + RING_GAP_VP * 2 + 26;
/** 自己那颗「+」的直径（vp，参考图里约头像的 1/3）。 */
const SELF_PLUS_VP: number = 26;
/** 推荐快拍那条椭圆胶囊的宽 / 高（vp）。 */
const FOLLOW_PILL_W_VP: number = 46;
const FOLLOW_PILL_H_VP: number = 24;
/**
 * 那条胶囊离环底边的距离（vp）。
 *
 * 需求："关注按钮上移一些，要在圆圈里面"。所以不再让它骑在环的底边上，而是**整颗落在圈内**：
 * 环盒 91、头像直径 80（上下各留 5.5），胶囊高 24 → 底边留 8 时正好完全在头像圆里。
 */
const FOLLOW_PILL_INSET_VP: number = 8;

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
   * 「你的快拍」：自己的头像（宿主从「我的」头部那份资料里顺手带过来）。
   *
   * 为什么不在这里自己打一发接口：这一项永远要显示，而"自己是谁"只有宿主那边有现成的
   * （见 Index 的 selfAvatarUrl）。空串时退回默认头像图，不影响这一项存在。
   */
  @Prop @Watch('onSelfAvatarReady') selfAvatar: string = '';
  /** 宿主那份头像晚到（「我的」头部还没取回来）时也要跟着更新自己那一项。 */
  private onSelfAvatarReady(): void {
    this.syncSelf();
  }
  /**
   * 宿主让托盘**重新拉一次**（每 +1 一次）。
   *
   * 用处：新号的「推荐快拍」兜底要等「为你推荐」的帖子到手（见 Index.scheduleSuggestRetry）——
   * 那会儿这一条已经画成"只有你的快拍"了，得再拉一次才会长出推荐条目。
   */
  @Prop @Watch('onReloadSignal') reloadSignal: number = 0;

  private onReloadSignal(): void {
    if (this.items.length > 0) {
      // 已经有内容（自己的快拍 / 关注的人的 / IG 发下来的推荐）：不去打扰。
      return;
    }
    hilog.info(DOMAIN, TAG, 'tray reload by host signal');
    this.load();
  }
  /**
   * 点「你的快拍」（含那颗「+」）：这一版**没有发布快拍的入口**，交给宿主给一句提示。
   *
   * 自己**有**快拍时点这一项是"看自己的快拍"（走 onOpen），只有"没有快拍 / 点加号"才来这里。
   */
  onSelfTap: () => void = (): void => {
  };
  /**
   * 点推荐快拍底部那条「+关注」：宿主负责关注（HTTP 优先、网页兜底），回 true = 关注成功。
   *
   * 成功后这一项**从托盘里删掉**（需求："点击后关注并消失"），并且让 NativeStories 记住
   * 别在后续的托盘数据里再冒出来（见 NativeStories.hideSuggested）。
   */
  onFollow: (item: StoryTrayItem) => Promise<boolean> =
    (item: StoryTrayItem): Promise<boolean> => Promise.resolve(false);
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
  /** 正在关注的那一项（防连点；空 = 没有在关注谁）。 */
  @State private followingUser: string = '';
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
     * 「你的快拍」那一项的三个值先按**当前**的 items / selfAvatar 算一遍。
     *
     * 必须在这里就做：托盘没数据（新号 / 接口不给 / 被限流）时下面那条 `load()` 会走到
     * "确实没有"那一支，**不会**再经过 syncSelf —— 漏了这一步，宿主晚到的头像就永远上不去，
     * 界面上一直是占位的应用图标（真机踩到过）。
     */
    this.syncSelf();
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
      this.syncSelf();
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
        // 没有托盘数据也照样把「你的快拍」那一项画对（那头像来自宿主，见 syncSelf）。
        this.syncSelf();
        return;
      }
      this.items = tray.items;
      this.syncSelf();
      this.onLoaded(tray.items);
    }).catch((): void => {
      this.loaded = true;
      this.syncSelf();
    });
  }

  /** 托盘里"我自己那一项"（有 = 我发过快拍；没有 = 只画头像 + 加号）。 */
  private selfStory(): StoryTrayItem | null {
    for (let index: number = 0; index < this.items.length; index++) {
      if (this.items[index].selfReel) {
        return this.items[index];
      }
    }
    return null;
  }

  /** 除自己以外的那些项（自己那一项固定画在最前面，见 build）。 */
  private others(): Array<StoryTrayItem> {
    const out: Array<StoryTrayItem> = [];
    for (let index: number = 0; index < this.items.length; index++) {
      if (!this.items[index].selfReel) {
        out.push(this.items[index]);
      }
    }
    return out;
  }

  /** 头像外那一圈：未看完=渐变环，全看完=灰环，点开中=转圈。 */
  @Builder
  ring(userId: string, avatarUrl: string, seen: boolean, spinning: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (spinning) {
        // 点开中：外环位置就是转圈（需求："点击头像时加载添加圆圈转圈动画"）。
        LoadingProgress()
          .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
          .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
          .color($r('app.color.accent'))
      } else if (seen) {
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
      Image(avatarUrl.length > 0 ? avatarUrl : $r('app.media.startIcon'))
        .id(storyAvatarNodeId(userId))
        .draggable(false)
        .width(AVATAR_VP)
        .height(AVATAR_VP)
        .borderRadius(AVATAR_VP / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))
        .border({ width: 2, color: $r('app.color.page_background') })
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          this.captureRect(userId, newArea);
        })
    }
    .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
    .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
  }

  /** 「你的快拍」有没有自己的快拍（有 → 画环、点开看自己；没有 → 只画头像 + 加号）。 */
  @State private selfSeen: boolean = false;
  /** 自己那一项的用户 id / 头像（没有自己的快拍时 id 为空、头像用宿主的 selfAvatar）。 */
  @State private selfId: string = '';
  @State private selfAvatarUrl: string = '';

  /** items / seed / selfAvatar 变了之后，把"自己那一项"的三个值同步过来。 */
  private syncSelf(): void {
    let mine: StoryTrayItem | null = null;
    for (let index: number = 0; index < this.items.length; index++) {
      if (this.items[index].selfReel) {
        mine = this.items[index];
        break;
      }
    }
    if (mine !== null) {
      this.selfId = mine.userId;
      this.selfSeen = mine.seen;
      this.selfAvatarUrl = mine.avatarUrl;
      return;
    }
    this.selfId = '';
    this.selfSeen = false;
    this.selfAvatarUrl = this.selfAvatar;
  }

  /**
   * 「你的快拍」：自己的头像（有快拍时带环），右下角一颗沉浸光感的「+」。
   *
   * 参考图里这一项**没有渐变环**（自己没发过快拍时），只有头像 + 白色圆形加号；
   * 自己发过快拍就按正常的环来（看过 = 灰环），点它看自己的快拍。
   * 加号走 `MaterialIconButton`（Toggle 承载沉浸光感，见 components/MaterialSurface）。
   */
  @Builder
  selfItemView() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.selfId.length > 0) {
          // 自己发过快拍：按正常的环画（看过 = 灰环），点它看自己的快拍。
          this.ring(this.selfId, this.selfAvatarUrl, this.selfSeen,
            this.pendingUser === this.selfId)
        } else {
          /*
           * 没有自己的快拍：只画头像，不套环（和参考图一致）。
           *
           * **必须自己再包一层居中的 Stack**：外面那层是按 `BottomEnd` 对齐的（为了把加号
           * 摆到右下角），头像直接放进去会被顶到右下角 —— 真机上就是"头像往右偏了一截，
           * 名字还居中，两者对不齐"。包一层等大的 Stack 之后，头像永远落在正中。
           */
          Stack({ alignContent: Alignment.Center }) {
            Image(this.selfAvatarUrl.length > 0 ? this.selfAvatarUrl : $r('app.media.startIcon'))
              .draggable(false)
              .width(AVATAR_VP)
              .height(AVATAR_VP)
              .borderRadius(AVATAR_VP / 2)
              .objectFit(ImageFit.Cover)
              .backgroundColor($r('app.color.field_background'))
              .border({ width: 2, color: $r('app.color.page_background') })
          }
          .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
          .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
        }
        // 右下角的「+」：沉浸光感（点它 = 想发快拍，交给宿主提示）。
        Column() {
          MaterialIconButton({
            symbol: $r('sys.symbol.plus'),
            buttonSize: SELF_PLUS_VP,
            iconSize: 15,
            onTap: (on: boolean): void => {
              hilog.info(DOMAIN, TAG, 'self add tapped');
              this.onSelfTap();
            }
          })
        }
        /*
         * 往外推一点：参考图里那颗加号是**压着头像边缘**的（一半在头像上、一半在外），
         * 所以右下角再补一点点内缩，正好落在那儿。
         */
        .padding({ right: 2, bottom: 2 })
        /*
         * **不要写 `hitTestBehavior(Transparent)`**：那样这一次点击会同时落到下面那一整项上
         * （真机实测：点「+关注」会**顺带把这位的快拍也点开**，浮层盖上来之后关注请求才发出去）。
         * 默认的 Block 让按钮自己吃下这次点击，外层那一条 onClick 就不会再触发。
         */
      }
      .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
      .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)

      Text($r('app.string.story_your_story'))
        .fontSize(11)
        .fontColor($r('app.color.primary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(ITEM_WIDTH_VP - 8)
        .textAlign(TextAlign.Center)
    }
    .width(ITEM_WIDTH_VP)
    .onClick((): void => {
      const mine: StoryTrayItem | null = this.selfStory();
      if (mine === null) {
        // 没发过快拍：这一项就是"去发一条"的入口（宿主给一句提示）。
        this.onSelfTap();
        return;
      }
      this.pendingUser = mine.userId;
      this.pendingTimer = setTimeout((): void => {
        this.pendingTimer = -1;
        if (this.pendingUser === mine.userId) {
          this.pendingUser = '';
        }
      }, PENDING_MS);
      const rect: StoryHeroRect | undefined = this.rects.get(mine.userId);
      this.onOpen(mine, rect === undefined ? new StoryHeroRect(0, 0, 0, 0) : rect);
    })
  }

  @Builder
  itemView(one: StoryTrayItem) {
    Column({ space: 6 }) {
      /*
       * 头像那一块：推荐快拍（`suggested`，新号最常见）在**底部**叠一条椭圆「+关注」胶囊
       * （参考图），点它关注；点头像本身照旧是"看这条快拍"。
       */
      Stack({ alignContent: Alignment.Bottom }) {
        this.ring(one.userId, one.avatarUrl, one.seen, this.pendingUser === one.userId)
        if (one.suggested && !one.following) {
          Column() {
            MaterialPillIcon({
              symbol: $r('sys.symbol.person_badge_plus'),
              pillWidth: FOLLOW_PILL_W_VP,
              pillHeight: FOLLOW_PILL_H_VP,
              iconSize: 14,
              onTap: (): void => {
                this.followSuggested(one);
              }
            })
          }
          // 压在环的底边上（参考图里那条胶囊正好骑在头像下缘）。
          .padding({ bottom: FOLLOW_PILL_INSET_VP })
          /*
           * 这里同样**不能**用 `hitTestBehavior(Transparent)`（见 selfItemView 那颗「+」的说明）：
           * 胶囊必须自己吃下点击，否则点「+关注」等于同时点了这一整项（会把快拍打开）。
           */
        }
      }
      .width(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)
      .height(AVATAR_VP + (RING_GAP_VP + RING_WIDTH_VP) * 2)

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
   * 点「+关注」（推荐快拍）：交给宿主去关注，成功后把这一项从托盘里拿掉。
   *
   * 需求："点击后关注并消失"。两道保险：
   *   ① 本组件立刻把它从 `items` 里删掉（界面马上少一格）；
   *   ② `NativeStories.hideSuggested` 记账 —— 3 分钟后托盘重新拉一次时它不会再回来。
   */
  private async followSuggested(one: StoryTrayItem): Promise<void> {
    if (this.followingUser.length > 0) {
      return;
    }
    this.followingUser = one.userId;
    hilog.info(DOMAIN, TAG, 'follow suggested uid=%{public}s name=%{public}s',
      one.userId, one.username);
    try {
      const ok: boolean = await this.onFollow(one);
      if (!ok) {
        return;
      }
      const kept: Array<StoryTrayItem> = [];
      for (let index: number = 0; index < this.items.length; index++) {
        if (this.items[index].userId !== one.userId) {
          kept.push(this.items[index]);
        }
      }
      this.items = kept;
      this.syncSelf();
      // 关注之后"下一位是谁"也要跟着变（宿主那份顺序里不能还留着这位）。
      this.onLoaded(kept);
    } finally {
      this.followingUser = '';
    }
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

  /** 一排灰色占位（横向排列，和真托盘同一套间距 + 同一个首端留白）。 */
  @Builder
  skeletonRow() {
    Row({ space: 0 }) {
      // 首端留白（EDGE_PAD_VP）：和真托盘那个空 ListItem 对齐，否则数据一到位整排会横跳。
      Row()
        .width(EDGE_SPACER_VP)
        .height(1)
      ForEach([0, 1, 2, 3, 4], (index: number): void => {
        if (index < SKELETON_COUNT) {
          this.skeletonItem()
        }
      }, (index: number): string => `sk-${index}`)
    }
    .width('100%')
    .height(TRAY_HEIGHT_VP)
    // 右侧不留白（滑动区仍是整屏宽，和真托盘一致）。
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
        /*
         * 首端留白（EDGE_PAD_VP）：需求"第一个和最后一个需要增加 padding left 和 right，
         * 和屏幕边缘保持距离，但要让头像穿过屏幕"。
         *
         * 为什么是"空 ListItem"而不是 List 的 padding / margin：
         *   · **List 的左右 padding**（曾经这么写）：滑动区被一起缩窄 → 内容在离屏幕边
         *     8vp 处就被裁掉，两端于是永远有一条**空带**（截图里左边那条黑边 +
         *     被切一半的圆环就是这个），头像再也穿不出屏幕；
         *   · **负 margin**：只能撑大盒子，管不了内容两端 —— 现场是"左边贴住、右边不贴"；
         *   · **`contentStartOffset` / `contentEndOffset`**：装上之后整条快拍序列直接不渲染
         *     （日志里 `story queue n=136`、`story visible 0-3` 全正常，屏幕上一片空）。
         * 空 ListItem 只占"停住时第一项之前"的那一段，滑起来它自己就滚走了 —— 两头的留白有了，
         * 头像照样整颗穿出屏幕。
         */
        ListItem() {
          Row()
            .width(EDGE_SPACER_VP)
            .height(TRAY_HEIGHT_VP)
        }
        // 「你的快拍」：固定第一位（需求），不参与后端顺序。
        ListItem() {
          this.selfItemView()
        }
        ForEach(this.others(), (one: StoryTrayItem): void => {
          ListItem() {
            this.itemView(one)
          }
        }, (one: StoryTrayItem): string => `${one.userId}-${one.seen ? 's' : 'n'}`)
        // 末端留白（同首端）。
        ListItem() {
          Row()
            .width(EDGE_SPACER_VP)
            .height(TRAY_HEIGHT_VP)
        }
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      /*
       * 可见范围报给宿主：屏幕上看得见的那几位用户的 story 提前取好（见 onVisibleRange）。
       * 下标要**减掉前面那两个固定项**（首端留白 + 你的快拍），否则宿主会按错位的下标预取。
       */
      .onScrollIndex((start: number, end: number): void => {
        const last: number = this.items.length - 1;
        const from: number = Math.max(0, start - 2);
        const to: number = Math.max(0, Math.min(last, end - 2));
        this.onVisibleRange(from, to);
      })
      .width('100%')
      .height(TRAY_HEIGHT_VP)
    } else if (!this.loaded) {
      // 正在拉：先摆一排灰色占位（而不是空一块），观感是"内容马上来"。
      this.skeletonRow()
    } else {
      // 拉完了确实没有：占一块同高的空位，信息流不跳。但「你的快拍」**永远在**（需求）。
      Row({ space: 0 }) {
        Row()
          .width(EDGE_SPACER_VP)
          .height(TRAY_HEIGHT_VP)
        this.selfItemView()
      }
      .width('100%')
      .height(TRAY_HEIGHT_VP)
    }
  }
}
