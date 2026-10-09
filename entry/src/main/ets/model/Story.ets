/*
 * 限时快拍（主页 feeds 流上方那条托盘）的模型。
 *
 * 字段跟着 `PolarisStoriesV3TrayContainerQuery` 的响应走，但**键名不写死**：
 * 解析在 core/NativeStories 里按"结构特征"找（托盘是一个 item 里带 user + 观看状态的数组），
 * 认到什么就打什么日志 —— 真机/模拟器的响应形状不一样时，照着日志补一处即可。
 */

/** 托盘里的一项（一个用户的所有未过期快拍）。 */
export class StoryTrayItem {
  /** 用户数字 id（点击进播放页要用）。 */
  readonly userId: string;
  readonly username: string;
  readonly avatarUrl: string;
  /**
   * 这个用户的快拍**是不是全看过了**。
   *
   * 需求："未查看快拍外层用一圈渐变色圆圈套着头像，已读该用户所有快拍则变灰"。
   */
  readonly seen: boolean;
  /** 有几条（拿不到给 0，只影响"有没有内容"的判断，不影响展示）。 */
  readonly count: number;
  /**
   * **备选 id**：同一条托盘条目里出现的其它数字字段（`user.pk` 之外的那些）。
   *
   * 为什么需要（用户报的"点开提示没取到、原因 empty，但换个人/换台设备又正常"）：
   * 托盘解析是"按结构找 + 按**键名优先级**取 id"（见 NativeStories 的 ID_KEYS）。
   * 条目里**有 `user` 对象**时取到的是用户 pk，一切正常；但有些条目没有 `user` 对象，
   * 于是退回取**条目自己的 `id`** —— 那个 id 很可能是 reel/media 的 id，不是用户 pk。
   * 拿它去 `reels_media?reel_ids=` 问，IG 会**如实回一个空 reels**（就是 `empty`），
   * 所以只有"托盘里带这类条目"的用户才会踩到，别人（包括开发机）完全正常。
   *
   * 有了它：主 id 问不出内容时**换备选 id 再问一发**，把这一整类问题就地消化掉。
   */
  readonly altIds: Array<string>;

  constructor(userId: string, username: string, avatarUrl: string, seen: boolean,
              count: number = 0, altIds: Array<string> = []) {
    this.userId = userId;
    this.username = username;
    this.avatarUrl = avatarUrl;
    this.seen = seen;
    this.count = count;
    this.altIds = altIds;
  }
}

/** 一整条托盘（顺序就是界面上的顺序）。 */
export class StoryTray {
  readonly items: Array<StoryTrayItem>;

  constructor(items: Array<StoryTrayItem>) {
    this.items = items;
  }
}

/**
 * 一条快拍（播放页里"一格进度条"对应的那一张）。
 *
 * 字段同样**不写死键名**（解析见 core/NativeStories.reel）：视频快拍也有静图封面
 * （`image_versions2` / `display_url`），所以 `imageUrl` 基本总能拿到；`videoUrl` 拿不到
 * 就按静图播（当前播放页就是这么做的，见 components/StoryViewer 的说明）。
 */
export class StoryItem {
  readonly id: string;
  /** 展示用图（视频快拍也有，是它的封面）。 */
  readonly imageUrl: string;
  /** 视频地址（图片快拍为空串）。 */
  readonly videoUrl: string;
  /** 秒（`taken_at`；拿不到给 0）。 */
  readonly takenAt: number;
  /** 这一格该显示多久（毫秒）：视频用 `video_duration`，图片用默认 5 秒。 */
  readonly durationMs: number;
  /**
   * 媒体的原始宽高（像素；拿不到给 0）。
   *
   * **为什么必须留着**：媒体区的高度要按**这一条的真实比例**算，不然定死了 9:16 而媒体是别的
   * 比例时，`Contain` 会在卡片里留出黑边（用户报的"媒体区出现黑边"）。有了宽高就能把媒体区
   * 做成和媒体一样的比例，再用 `Cover` 铺满 —— 既没黑边也不裁内容。
   */
  readonly width: number;
  readonly height: number;

  constructor(id: string, imageUrl: string, videoUrl: string, takenAt: number, durationMs: number,
              width: number = 0, height: number = 0) {
    this.id = id;
    this.imageUrl = imageUrl;
    this.videoUrl = videoUrl;
    this.takenAt = takenAt;
    this.durationMs = durationMs;
    this.width = width;
    this.height = height;
  }

  isVideo(): boolean {
    return this.videoUrl.length > 0;
  }
}

/** 某个用户当前**未过期**的全部快拍（点开托盘里一项后拉到的就是这个）。 */
export class StoryReel {
  readonly userId: string;
  readonly username: string;
  readonly avatarUrl: string;
  readonly items: Array<StoryItem>;

  constructor(userId: string, username: string, avatarUrl: string, items: Array<StoryItem>) {
    this.userId = userId;
    this.username = username;
    this.avatarUrl = avatarUrl;
    this.items = items;
  }
}

/** 空 reel（给"还没加载出来"占位用，见 components/StoryViewer）。 */
export const EMPTY_REEL: StoryReel = new StoryReel('', '', '', []);

/**
 * 托盘里某个用户的头像节点 id（`StoriesTray` 挂上去、`StoryViewer` 按它量位置）。
 *
 * 为什么要能按 id 量：转场必须让"播放页那颗头像"和"序列里那颗头像"落到**同一个矩形**上，
 * 而两边各自算出来的坐标空间不一定一致（一个是页面坐标、一个是窗口坐标）。有了 id 就能用
 * `getComponentUtils().getRectangleById()` 把两边都量成**窗口坐标**再比，差多少一目了然。
 */
export function storyAvatarNodeId(userId: string): string {
  return `story-avatar-${userId}`;
}

/** 播放页里那颗"飞行的头像"的节点 id（只为量位置，见 storyAvatarNodeId 的说明）。 */
export const STORY_FLYING_AVATAR_ID: string = 'story-flying-avatar';

/**
 * 播放页浮层根节点的 id（只为量它自己的原点）。
 *
 * **为什么需要**：托盘用 `onAreaChange` 量到的是**窗口坐标**（相对屏幕左上角），而浮层里
 * `.position()` 用的是**浮层自己的坐标**（它的原点在状态栏下面）。两者差一个状态栏高度 ——
 * 实机量出来 x 对得上、y 差 39vp，于是"头像落回序列"永远偏低 39vp（用户报的错位）。
 * 量一下根节点的 `windowOffset` 就是那个偏移，换算掉即可，不用写死状态栏高度。
 */
export const STORY_ROOT_ID: string = 'story-root';

/** 卡片节点 id（只为量它的实际渲染尺寸，见 StoryViewer.logBoxes）。 */
export const STORY_CARD_ID: string = 'story-card';
/** 媒体区节点 id（同上：和卡片比一比就知道底部那条黑边是不是"卡片比媒体高"）。 */
export const STORY_MEDIA_ID: string = 'story-media';

/**
 * 被点开的那个头像在**屏幕上的位置与大小**（vp）。
 *
 * 转场要用：播放页第一帧就画在这个矩形里（于是看着就是头像本身），然后放大到全屏；
 * 头像那一层则从同一个矩形位移到左上角。矩形由托盘测量（见 components/StoriesTray
 * 的 onAreaChange），坑在于**列表滚动过、或者测量还没来**，所以 `valid()` 不成立时
 * 宿主会退化成"淡入"而不是硬套一个错位置的矩形。
 */
export class StoryHeroRect {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;

  constructor(x: number, y: number, w: number, h: number) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }

  valid(): boolean {
    return this.w > 1 && this.h > 1;
  }

  dump(): string {
    return `${Math.round(this.x)},${Math.round(this.y)},${Math.round(this.w)}x${Math.round(this.h)}`;
  }
}
