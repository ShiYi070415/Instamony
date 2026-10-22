/*
 * 应用设置（用户偏好）：读取、写入、以及"主题是不是深色"的判定。
 *
 * 为什么要有这一层：
 *   - 沉浸光感的材质等级（用户可见的偏好）要能跨启动记住 → 存到 preferences；
 *   - 界面上要能**跟着改**（点一下等级，标题栏和底栏的材质立刻就换）→ 值同时发布到
 *     AppStorage，组件用 @StorageProp 读，改一次全体重绘。
 *
 * 主题判定不走 Configuration.colorMode：应用把它设成了 COLOR_MODE_NOT_SET（跟随系统），
 * 那种情况下 config 里的值不一定是"当前实际生效的那一档"。这里直接**读当前生效的资源色**
 * （page_background：浅色变体是白、深色变体是黑），按亮度判深浅 —— 资源是系统按当前
 * 色彩模式解析的，永远和界面上真正在用的颜色一致。
 */

import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xFF00;
const TAG = 'InstarmonySettings';
/** preferences 文件名。 */
const STORE_NAME: string = 'instarmony_settings';

/**
 * AppStorage 键：沉浸光感的材质等级（'adaptive' / 'exquisite' / 'gentle' / 'smooth'）。
 *
 * 四选一（多选项单选）→ 设定页里用**下拉按钮**呈现（见 SettingsPanel 的 materialRow）。
 */
export const SETTING_MATERIAL_LEVEL: string = 'materialLevel';
/**
 * AppStorage 键：ArkUI 材质的**厚度**（'ultra_thin' / 'thin' / 'regular' / 'thick' / 'ultra_thick'）。
 *
 * 这是 ArkUI 侧唯一能设的材质轴（`ImmersiveStyle`，官方："不同样式对应不同的模糊程度、高光效果"）。
 * 设定页里用**下拉按钮**呈现；全局所有 ArkUI 材质组件（下拉按钮、下拉选单、退出登录按钮）
 * 都读它，所以改一处全应用一起变。
 */
export const SETTING_MATERIAL_THICKNESS: string = 'materialThickness';
/**
 * 材质厚度的五个档位（对应 uiMaterial.ImmersiveStyle 的五个枚举，顺序即下拉顺序）。
 *
 * 存字符串而不是存数字：preferences 里可读、以后加档也不会把旧值读错。
 */
export const MATERIAL_THICKNESS_ULTRA_THIN: string = 'ultra_thin';
export const MATERIAL_THICKNESS_THIN: string = 'thin';
export const MATERIAL_THICKNESS_REGULAR: string = 'regular';
export const MATERIAL_THICKNESS_THICK: string = 'thick';
export const MATERIAL_THICKNESS_ULTRA_THICK: string = 'ultra_thick';
/**
 * AppStorage 键：底栏行为（'sink' = 下沉收缩，'system' = 原生隐藏动画）。
 *
 * 这是一个**行为开关**（两种行为二选一）→ 设定页里用开关呈现，默认下沉收缩（见 BAR_HIDE_SINK）。
 * 只有支持悬浮底栏的设备（API ≥ 23）才用得上、也才在设定页里露出来：
 * 低版本设备上栏是普通页签栏，两种行为都不成立（栏固定不动，见 pages/Index 的 onFeedScroll）。
 */
export const SETTING_BAR_HIDE: string = 'barHideMode';
/**
 * AppStorage 键：**图片清晰度**（`auto` / `saver` / `high` / `original`）。
 *
 * 需求（用户原话）："媒体分辨率有点糊，新增一个按照网络质量提供不同清晰度的媒体，
 * 在设置中可供调节：'图片和视频'板块，显示'图片质量'和'视频质量'选项，
 * 使用沉静光感下拉按钮，两个选项的下拉菜单分别都是 自适应/省流/高清/原画。"
 *
 * 生效点：`core/MediaQuality` 按它（加上网络类型）决定"展示用"取哪一档候选
 * （见 MediaQuality.imageTarget / videoTarget）。下载始终取最大档，不受这里影响。
 */
export const SETTING_IMAGE_QUALITY: string = 'mediaImageQuality';
/** AppStorage 键：**视频清晰度**（取值同上）。 */
export const SETTING_VIDEO_QUALITY: string = 'mediaVideoQuality';
/**
 * 清晰度四个档位（顺序即下拉顺序：自适应 → 省流 → 高清 → 原画，用户指定的顺序）。
 *
 *   auto     —— 自适应：按**网络类型**自己挑（Wi-Fi 走高清档、蜂窝走省流档）；
 *   saver    —— 省流：能看就行，图片/视频都取较小的那一档；
 *   high     —— 高清：手机上肉眼足够（1080 档），流量比原画小得多；
 *   original —— 原画：直接取 IG 给的最大一档（等于放弃降级，最清晰也最费流量）。
 */
export const MEDIA_QUALITY_AUTO: string = 'auto';
export const MEDIA_QUALITY_SAVER: string = 'saver';
export const MEDIA_QUALITY_HIGH: string = 'high';
export const MEDIA_QUALITY_ORIGINAL: string = 'original';
/** 下拉里的四档顺序（下标 → 取值）。 */
export const MEDIA_QUALITY_ORDER: Array<string> = [
  MEDIA_QUALITY_AUTO,
  MEDIA_QUALITY_SAVER,
  MEDIA_QUALITY_HIGH,
  MEDIA_QUALITY_ORIGINAL
];
/** AppStorage 键：当前界面是不是深色（由 refreshTheme 写入）。 */
export const SETTING_DARK_UI: string = 'isDarkUi';
/**
 * AppStorage 键：**实测**叠字背后那一块是不是浅色（由 core/BackdropTone 连续侦测后写入）。
 *
 * 只服务于"叠在视频上的那行字"：底栏图标的反色交给系统材质的 colorInvert，不走这里。
 */
export const SETTING_OVERLAY_BACKDROP_LIGHT: string = 'overlayBackdropLight';
/** AppStorage 键：叠字行的上/下边界（屏幕高度的比例，由 FeedList 报上来）。 */
export const SETTING_OVERLAY_TOP: string = 'overlayTop';
export const SETTING_OVERLAY_BOTTOM: string = 'overlayBottom';
/**
 * AppStorage 键：视频是否静音（媒体区那颗喇叭键控制的**全局**开关）。
 *
 * 做成全局而不是"每条视频各记一个"：用户点静音就是不想要声音，下一条视频又突然出声是最烦的
 * 那种体验。值走存储，重开 app 也记得（和别的设置一样，见 AppSettings.init）。
 */
export const SETTING_VIDEO_MUTED: string = 'videoMuted';
/**
 * AppStorage 键：**「我的」页的分段按钮钉住了没有**（由 ProfilePage 在滚动时写）。
 *
 * 为什么要走 AppStorage：钉住之后那条分段按钮不再画在页面里，而是交给 **HDS 标题栏**
 * （见 pages/Index 的 titleBarBottom）—— 标题栏和页面是两棵互不相识的子树，只有全局这份
 * 事实能把它们连起来。注意它**不是用户设置**，不落盘、不参与 AppSettings.init。
 */
export const PROFILE_BAR_PINNED: string = 'profileBarPinned';
/**
 * AppStorage 键：**「我的」页当前分页**（0..3，由 ProfilePage 在切页时写）。
 *
 * 钉住之后那条分段按钮的宿主是**标题栏**（pages/Index 的 pinnedProfileBar），它和 ProfilePage
 * 不是同一棵子树 —— 点击/拖动发生在标题栏那条上，而"记住老分页的滚动位置、恢复新分页的位置"
 * 这套账只有 ProfilePage 会做。所以分页号走全局这份事实：谁改都先落到视图模型，
 * 再由 ProfilePage 写进这里，标题栏那条读它来画选中态。
 */
export const PROFILE_TAB: string = 'profileTab';
/**
 * AppStorage 键：**「搜索」页的搜索框收起来了没有**（由 pages/Index 按内容滚动位置写）。
 *
 * 需求："上滑搜索框收缩成按钮到右上角，点击或者回到顶部时才展开"。搜索框画在 **HDS 标题栏**里，
 * 而"内容滚到哪了"只有 SearchPage 知道（它把滚动位置报给 pages/Index，见那边的 trackSearchBox）；
 * 反过来页面也要知道收没收起来 —— 收起时标题栏矮一格，页面顶部那段留白得跟着减掉
 * （见 SearchPage 的 SEARCH_TOP_OFFSET）。两边只能靠全局这份事实对齐。
 * 和 PROFILE_BAR_PINNED 一样：**不是用户设置**，不落盘、不参与 AppSettings.init。
 */
export const SEARCH_BOX_COLLAPSED: string = 'searchBoxCollapsed';
/**
 * AppStorage 键：**"请把搜索框叫出来并进入输入模式"的请求**（毫秒时间戳，由 pages/Index 那颗
 * 放大镜写，SearchPage 读）。
 *
 * 需求："页面滚动时点击搜索按钮无法唤出搜索框，逻辑改为点击搜索按钮时弹出搜索框并进入输入模式
 * （弹出输入法）"。为什么用时间戳而不是布尔：布尔没有"变化"，同一会话里连点两次只会弹一次
 * 输入法；时间戳每次都不同，@Watch 每次都会响。
 */
export const SEARCH_BOX_FOCUS_REQUEST: string = 'searchBoxFocusRequest';
/**
 * AppStorage 键：**首屏封面已解码张数**（由 core/PosterCache 写，FeedList 读）。
 *
 * 需求："给首屏那 6 张封面用低一档的地址先解码"。解出来一张就 +1 —— 值一变，列表里那几格
 * 就会重绘并把小图垫到真图下面（见 FeedList 的 posterReady）。同样**不是用户设置**、不落盘。
 */
export const FEED_POSTER_READY: string = 'feedPosterReady';

/**
 * 沉浸光感的材质等级。四个取值对应 HDS 的 `hdsMaterial.MaterialLevel`，**三档 + 一档自适应**
 * （文案就是官方的档位名，见最佳实践「沉浸光感」的档位表）：
 *
 *   ADAPTIVE（默认）—— 自适应：系统按当前设备算力动态决定材质档次，性能与效果自己平衡，
 *                      官方推荐（文档「使用系统自适应的沉浸光感」）；
 *   EXQUISITE       —— 精美：完整的沉浸光感效果（最重的一档）；
 *   GENTLE          —— 轻柔：中等，在效果与性能之间取平衡；
 *   SMOOTH          —— 流畅：最轻，官方建议"设备不支持 IMMERSIVE 材质时用它"。
 *
 * 存字符串而不是存数字：preferences 里可读、跨版本加档也不会把旧值读错。
 */
export const MATERIAL_LEVEL_ADAPTIVE: string = 'adaptive';
export const MATERIAL_LEVEL_EXQUISITE: string = 'exquisite';
export const MATERIAL_LEVEL_GENTLE: string = 'gentle';
export const MATERIAL_LEVEL_SMOOTH: string = 'smooth';

/**
 * 底栏行为：**下沉收缩**（本项目自绘，默认）——上滑时栏往下挪一截、同时收窄缩矮，
 * 始终留在屏幕上（见 pages/Index 的 onFeedScrollSink）。**只支持悬浮底栏的设备（API ≥ 23）**：
 * 那套形变参数（barHeight / barSideMargin / barBottomMargin）全在悬浮样式上，
 * 低版本的普通页签栏不吃这些参数，所以降级档下滚动根本不碰底栏。
 */
export const BAR_HIDE_SINK: string = 'sink';
/**
 * 底栏行为：**原生隐藏动画**——调 HdsTabsController 自带的隐藏/显示动效，整条栏收走
 * （见 pages/Index 的 onFeedScrollNative）。同样只在 API ≥ 23 的设备上有效。
 */
export const BAR_HIDE_SYSTEM: string = 'system';

/**
 * 应用设置。全是静态方法：它不进 UI 树，只负责"读 preferences → 发布到 AppStorage"。
 */
export class AppSettings {
  private static store: preferences.Preferences | null = null;

  /**
   * 读一次持久化的设置并发布到 AppStorage。
   *
   * 可以重复调用（EntryAbility 一次、页面一次兜底）：读不到就用默认值，
   * 任何一步失败都只是"没记住上次的选择"，不该影响启动。
   */
  static init(context: common.Context): void {
    try {
      if (AppSettings.store === null) {
        AppSettings.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open settings store failed: %{public}s', (error as Error).message);
    }
    AppStorage.setOrCreate(SETTING_MATERIAL_LEVEL,
      AppSettings.readString(SETTING_MATERIAL_LEVEL, MATERIAL_LEVEL_ADAPTIVE));
    // 材质厚度默认超薄（下拉按钮那种轻薄的悬浮观感）。
    AppStorage.setOrCreate(SETTING_MATERIAL_THICKNESS,
      AppSettings.readString(SETTING_MATERIAL_THICKNESS, MATERIAL_THICKNESS_ULTRA_THIN));
    // 默认**下沉收缩**（用户明确要的默认值；老版本存下来的 'still' 读进来会落到"非 system"
    // 这一支，正好等价于下沉，见 BAR_HIDE_SINK）。
    AppStorage.setOrCreate(SETTING_BAR_HIDE,
      AppSettings.readString(SETTING_BAR_HIDE, BAR_HIDE_SINK));
    AppStorage.setOrCreate(SETTING_OVERLAY_TOP, 0);
    AppStorage.setOrCreate(SETTING_OVERLAY_BOTTOM, 0);
    // 静音默认关（有声音）：布尔值单独读一次（readString 那套只处理字符串）。
    AppStorage.setOrCreate(SETTING_VIDEO_MUTED, AppSettings.readBool(SETTING_VIDEO_MUTED, false));
    // 图片/视频清晰度：默认**自适应**（按网络类型自己挑，见 core/MediaQuality）。
    AppStorage.setOrCreate(SETTING_IMAGE_QUALITY,
      AppSettings.readString(SETTING_IMAGE_QUALITY, MEDIA_QUALITY_AUTO));
    AppStorage.setOrCreate(SETTING_VIDEO_QUALITY,
      AppSettings.readString(SETTING_VIDEO_QUALITY, MEDIA_QUALITY_AUTO));
    AppSettings.refreshTheme(context);
  }

  /** 设置图片清晰度（存盘 + 发布到 AppStorage）。 */
  static setImageQuality(quality: string): void {
    AppStorage.setOrCreate(SETTING_IMAGE_QUALITY, quality);
    AppSettings.write(SETTING_IMAGE_QUALITY, quality);
  }

  /** 设置视频清晰度（同上）。 */
  static setVideoQuality(quality: string): void {
    AppStorage.setOrCreate(SETTING_VIDEO_QUALITY, quality);
    AppSettings.write(SETTING_VIDEO_QUALITY, quality);
  }

  /**
   * 当前图片清晰度（**给非 UI 代码用**：`core/MediaQuality` 解析媒体时读它）。
   *
   * 读 AppStorage 而不是每次都读盘：这个值在解析每一条媒体时都会被问，读盘太贵。
   * 没初始化（AppSettings.init 还没跑）时按默认值 `auto`。
   */
  static imageQualityNow(): string {
    const value: string = AppStorage.get<string>(SETTING_IMAGE_QUALITY) ?? MEDIA_QUALITY_AUTO;
    return value.length > 0 ? value : MEDIA_QUALITY_AUTO;
  }

  /** 当前视频清晰度（同上）。 */
  static videoQualityNow(): string {
    const value: string = AppStorage.get<string>(SETTING_VIDEO_QUALITY) ?? MEDIA_QUALITY_AUTO;
    return value.length > 0 ? value : MEDIA_QUALITY_AUTO;
  }

  /** 视频静音开关（见 SETTING_VIDEO_MUTED 的说明）。 */
  static setVideoMuted(muted: boolean): void {
    AppStorage.setOrCreate(SETTING_VIDEO_MUTED, muted);
    AppSettings.write(SETTING_VIDEO_MUTED, muted ? '1' : '0');
  }

  /** 读一个布尔设置（存的是 '1'/'0'）。 */
  private static readBool(key: string, fallback: boolean): boolean {
    const raw: string = AppSettings.readString(key, fallback ? '1' : '0');
    return raw === '1';
  }

  /** 沉浸光感的材质等级（见 MATERIAL_LEVEL_* 的说明）。 */
  static setMaterialLevel(level: string): void {
    AppStorage.setOrCreate(SETTING_MATERIAL_LEVEL, level);
    AppSettings.write(SETTING_MATERIAL_LEVEL, level);
  }

  /** 材质的厚度（见 MATERIAL_THICKNESS_* 的说明）。 */
  static setMaterialThickness(thickness: string): void {
    AppStorage.setOrCreate(SETTING_MATERIAL_THICKNESS, thickness);
    AppSettings.write(SETTING_MATERIAL_THICKNESS, thickness);
  }

  /** 底栏的行为（见 BAR_HIDE_* 的说明）。 */  static setBarHideMode(mode: string): void {
    AppStorage.setOrCreate(SETTING_BAR_HIDE, mode);
    AppSettings.write(SETTING_BAR_HIDE, mode);
  }

  /** 叠字行的上边界（屏幕高度比例）；没有叠字时是 0。 */
  static overlayTop(): number {
    const value: number | undefined = AppStorage.get<number>(SETTING_OVERLAY_TOP);
    return value === undefined ? 0 : value;
  }

  /** 叠字行的下边界（屏幕高度比例）。 */
  static overlayBottom(): number {
    const value: number | undefined = AppStorage.get<number>(SETTING_OVERLAY_BOTTOM);
    return value === undefined ? 0 : value;
  }

  /**
   * 报告叠字行的位置（屏幕高度比例）。
   *
   * 由 FeedList 里那一行在 onAreaChange 里调：BackdropTone 靠它知道该去快照的哪一块
   * 取"文字背后的颜色"。传 0/0 表示当前没有叠字（比如切到别的页）。
   */
  static setOverlayBand(top: number, bottom: number): void {
    AppStorage.setOrCreate(SETTING_OVERLAY_TOP, top);
    AppStorage.setOrCreate(SETTING_OVERLAY_BOTTOM, bottom);
  }

  /**
   * 重新判定"当前界面是不是深色"并发布。
   *
   * 系统切换深浅色时由 EntryAbility.onConfigurationUpdate 调一次。
   */
  static refreshTheme(context: common.Context): void {
    let dark: boolean = true;
    try {
      const argb: number = context.resourceManager.getColorSync($r('app.color.page_background').id);
      // ARGB：取 R/G/B 算相对亮度（人眼对绿最敏感、蓝最不敏感）。
      const red: number = (argb >> 16) & 0xFF;
      const green: number = (argb >> 8) & 0xFF;
      const blue: number = argb & 0xFF;
      const luminance: number = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
      dark = luminance < 128;
    } catch (error) {
      // 读不到就按深色：本应用的默认观感就是深色，比"猜成浅色"安全。
      dark = true;
    }
    AppStorage.setOrCreate(SETTING_DARK_UI, dark);
    // 叠字的"背景明暗"在侦测出结果之前先按深色算（浅色字）：BackdropTone 一两百毫秒内
    // 就会用真实像素覆盖它，这里只是别让第一帧的文字跟画面完全糊在一起。
    AppStorage.setOrCreate(SETTING_OVERLAY_BACKDROP_LIGHT, false);
  }

  /**
   * **强制应用以深色渲染**，或（`dark=false`）把明暗交回系统。
   *
   * 只给 Reels 页用（需求："浅色模式下切到 Reels 变深色、离开变回浅色"）：
   * Reels 整屏都是视频，浅色主题下顶部/底部那两条系统栏的材质是白的，压在画面上又脏又
   * 读不清；直接把这页期间的应用配色切成深色，HDS 的材质、标题、我们自己画的图标会**一起**
   * 变成深色（比单独去画黑背板干净，也不依赖任何"运行库未必有"的接口）。
   *
   * `dark=false` 用的是 `COLOR_MODE_NOT_SET`（跟系统），与 EntryAbility.onCreate 里启动时
   * 设的是同一个值 —— 也就是说"离开 Reels"就是回到应用本来的策略，而不是硬写浅色：
   * 系统本来就是深色时，离开 Reels 依旧是深色。
   */
  static forceDarkMode(context: common.Context, dark: boolean): void {
    try {
      const mode: ConfigurationConstant.ColorMode = dark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      context.getApplicationContext().setColorMode(mode);
      hilog.info(DOMAIN, TAG, 'app color mode → %{public}s', dark ? 'dark' : 'follow-system');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * **个人页头部的落盘快照**（按账号 id 分开，见 model/Profile 的 ProfileHeader.toJson）。
   *
   * 用途（用户报的"从新号切回大号，获取头部数据太慢"）：头部那一发常被限速闸门排在
   * 别的请求后面（真机 2~4 秒），而这份数据变化很慢。进「我的」时先把上次的快照画上去，
   * 网络回来再覆盖 —— 观感就是"秒开"。
   */
  static saveProfileHeader(uid: string, json: string): void {
    if (uid.length === 0 || json.length < 2) {
      return;
    }
    AppSettings.write(`profile_header_${uid}`, json);
  }

  /** 取某个账号上次的头部快照（没有给空串）。 */
  static loadProfileHeader(uid: string): string {
    if (uid.length === 0) {
      return '';
    }
    return AppSettings.readString(`profile_header_${uid}`, '');
  }

  /**
   * 存/取**私信实时同步位点**（`seq_id` / `snapshot_at_ms`）。
   *
   * 为什么值得落盘：冷启动要连实时通道，而订阅需要这两个值，它们只有一个来源 ——
   * 一次完整收件箱请求（30KB 起，还要在全局闸门排队，真机上见过排 30 秒）。
   * 存下来之后，冷启动可以**立刻用上次的位点先订阅**（对端会按位点补差量），
   * 收件箱回来后如果更新了位点再补一次订阅 —— 实时通道从"等几秒~几十秒"变成"开局就在"。
   */
  static saveDirectSync(seqId: number, snapshotAtMs: number): void {
    if (seqId <= 0 || snapshotAtMs <= 0) {
      return;
    }
    AppSettings.write('direct_sync', `${seqId}|${snapshotAtMs}`);
  }

  /** 上次存下的同步位点（`seqId <= 0` = 没有）。 */
  static loadDirectSync(): Array<number> {
    const raw: string = AppSettings.readString('direct_sync', '');
    if (raw.length === 0) {
      return [];
    }
    const parts: Array<string> = raw.split('|');
    if (parts.length < 2) {
      return [];
    }
    const seq: number = Number(parts[0]);
    const snapshot: number = Number(parts[1]);
    if (!Number.isFinite(seq) || !Number.isFinite(snapshot) || seq <= 0 || snapshot <= 0) {
      return [];
    }
    return [seq, snapshot];
  }

  private static readString(key: string, fallback: string): string {
    try {
      if (AppSettings.store !== null) {
        const value: preferences.ValueType = AppSettings.store.getSync(key, fallback);
        if (typeof value === 'string' && value.length > 0) {
          return value;
        }
      }
    } catch (error) {
    }
    return fallback;
  }

  private static write(key: string, value: preferences.ValueType): void {
    try {
      if (AppSettings.store === null) {
        return;
      }
      AppSettings.store.putSync(key, value);
      AppSettings.store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save %{public}s failed: %{public}s', key, (error as Error).message);
    }
  }
}
