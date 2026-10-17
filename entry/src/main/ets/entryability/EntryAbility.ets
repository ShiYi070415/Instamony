/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, uiMaterial } from '@kit.ArkUI';
import { AppLifecycle } from '../core/AppLifecycle';
import { AppSettings } from '../core/AppSettings';
import { MediaPrefetch } from '../core/MediaPrefetch';
import { NativeFeed } from '../core/NativeFeed';
import { FeedCache } from '../core/FeedCache';
import { NativeSearch } from '../core/NativeSearch';
import { NativeReels } from '../core/NativeReels';
import { ReelsCache } from '../core/ReelsCache';
import { NetworkState } from '../core/NetworkState';
import { PlatformCap } from '../core/PlatformCap';
import { ApiRegistry } from '../bridge/ApiRegistry';
import { MobileSession } from '../core/mobileapi/MobileSession';
import { MobileProbe } from '../core/mobileapi/MobileProbe';
import { DirectCache } from '../core/DirectCache';
import { AccountScope } from '../core/AccountScope';
import { webview } from '@kit.ArkWeb';
import { AppConfig } from '../config/AppConfig';
import { DeepLink, DeepLinkIntent } from '../core/DeepLink';
import { Translator } from '../core/Translator';

const DOMAIN = 0x0000;
/**
 * 启动预热要几条。
 *
 * 和信息流首屏那个 NATIVE_FIRST_COUNT 保持一致（7）：预热的结果会被首屏直接拿去用，
 * 两边不一致就会出现"预热了 7 条、首屏又按 12 条重发一次"这种白干。
 */
const WARM_FEED_COUNT: number = 7;
/** reels 预热的条数（和 ReelsViewModel 的 NATIVE_PAGE_COUNT 一致，别让它再发一次）。 */
const WARM_REELS_COUNT: number = 7;
/** 材质能力诊断日志的 tag（`hilog -T InstarmonyMaterialDiag` 单独抓）。 */
const TAG_MATERIAL: string = 'InstarmonyMaterialDiag';

export default class EntryAbility extends UIAbility {
  /**
   * 冷启动这次带进来的深链（`instarmony://…`）。
   *
   * 冷启动的 Want 只在 onCreate 来一次，而决定"先铺哪一页"的时机在 onWindowStageCreate，
   * 所以先存下来；热启动那条路（onNewWant）不走这个字段，直接存进 core/DeepLink 的 pending。
   */
  private coldDeepLink: DeepLinkIntent | null = null;
  /**
   * 本次实例的**第一个** Want（= onCreate 那个）已经处理过了。
   *
   * 为什么要这个标记：冷启动时系统会先 onCreate 再 onNewWant（携同一个 Want）——
   * 不挡一下，同一条链接会被处理两次（落地页与 pending 各留一份，用户点"打开"时行为就重了）。
   * 而热启动只走 onNewWant，所以标记在第一次 onNewWant 里清掉，之后每次都是真的新意图。
   */
  private coldWantHandled: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 设置与"当前是不是深色"早点发布到 AppStorage：页面第一次 build 就要用它们配色。
    AppSettings.init(this.context);
    // ---- 材质能力诊断（一次性）----
    // 标题栏背板一直是一块偏黑的板子、看不到"渐变模糊"：官方 FAQ 说材质的**模糊/折射**
    // （materialFilter）只在**高/中算力**设备上渲染，低算力设备只保留背景色/边框/阴影。
    // 打这一行就能判定"是代码问题还是设备档位不支持"，出问题时凭它定位。
    // `uiMaterial` 是 API 26 起才有的模块：低版本设备上**连问都不能问**，所以先判能力。
    hilog.info(DOMAIN, TAG_MATERIAL, 'platform %{public}s', PlatformCap.describe());
    if (PlatformCap.hasArkMaterial()) {
      try {
        const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
        hilog.info(DOMAIN, TAG_MATERIAL,
          'state=%{public}d type=%{public}d deviceLevel=%{public}d immersive=%{public}s',
          info.state, info.type, uiMaterial.getGlobalMaterialLevel(),
          `${uiMaterial.isImmersiveMaterialSupported()}`);
      } catch (err) {
        hilog.warn(DOMAIN, TAG_MATERIAL, 'probe failed: %{public}s', JSON.stringify(err));
      }
    }
    // ---- 网页启动提速（官方那两条）----
    // 1) initializeWebEngine()：在 Web 组件创建**之前**把 Web 内核的动态库加载好（官方原话
    //    "以提高启动性能"），并且会自动预连接历史高频站点。全局一次即可，而且**不能在异步线程
    //    调用**（会崩），所以放在 ability 的同步 onCreate 里最合适。
    // 2) prepareForPageLoad()：对即将加载的首页做**预解析 + 预连接**（DNS/TLS 先走完），
    //    等 Web 真正 loadUrl 时省掉这一段。
    // 两条都是"只提前、不改行为"的优化：失败也不影响任何正常路径。
    try {
      webview.WebviewController.initializeWebEngine();
      hilog.info(DOMAIN, 'testTag', 'web engine prewarmed');
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'web prewarm failed: %{public}s', JSON.stringify(err));
    }
    // ---- 首屏预热：**在 UI 起来之前**就把第一页请求发出去 ----
    //
    // 为什么放在这儿：首屏数据现在是原生直发 HTTP（core/NativeFeed），实测要 1.2~2.4 秒。
    // 而从这一刻到用户真正盯上信息流，中间还有启动窗口、组件构建、网页宿主创建那一段 ——
    // 把请求提前到这段里发，等页面来要数据时它多半已经在内存里躺好了（见 NativeFeed.takeWarm），
    // 用户看到的就是"内容已经在那儿"而不是"转圈等一秒多"。
    //
    // 前置条件两个，都在这一行之前就绪：
    //   1) 请求模板：ApiRegistry.init 把上次落盘的模板读回内存（同步读 preferences，很快）；
    //   2) 会话 Cookie：上面 initializeWebEngine() 已经起了 Web 内核，WebCookieManager 能读罐。
    // 失败无所谓：预热只是"提前量"，页面那条路会照旧自己发一次。
    try {
      /*
       * **账号分区**（见 core/AccountScope）必须**第一个** init。
       *
       * 为什么顺序这么紧要：`ApiRegistry.init` 在里面**立刻读盘**（loadPersisted），
       * 而所有缓存的键都要过 `AccountScope.slot()`。账号还没读出来时槽位是 `anon` ——
       * 那样读到的永远是"匿名槽"（等于没分区），而且第一次读盘的结果会被当成这个账号的模板
       * 留在内存里。所以先建立账号，再让任何 cache 碰盘。
       */
      AccountScope.init(this.context);
      ApiRegistry.init(this.context);
      // 信息流第一页的落盘缓存（见 core/FeedCache）：冷启动时页面会先把它铺出来，
      // 再让网络那份整体替换 —— 用户一进 app 就有画面。这里只是同步打开那个 store。
      FeedCache.init(this.context);
      // 搜索页推荐的缓存 + "上次成功那条模板"（见 core/SearchCache / core/NativeSearch.init）：
      // 省掉冷启动时一条条试候选（每条都是 400KB 的请求，实测 2.5 秒量级）。
      NativeSearch.init(this.context);
      // reels 第一页的落盘缓存（见 core/ReelsCache）：clips 那条查询被 IG 限流时，
      // 视频标签靠它"至少还能看上次那批"，而不是一片空白。
      ReelsCache.init(this.context);
      // 移动 API 的设备身份（见 core/mobileapi/MobileSession）：**只开落盘文件**，
      // 不读 Cookie 罐、不发请求。身份必须跨重启稳定，所以这里同步把上次那份读回内存。
      MobileSession.init(this.context);
      /*
       * 私信会话的**预取快照缓存**（见 core/DirectCache）：同步把上次那几十条读回内存。
       *
       * 为什么放在启动里同步做：进私信列表时要用它判断"哪几条还新鲜、不用再预取"，
       * 也要用它给点开的会话铺第一屏 —— 异步读的话这两件事都会赶在数据到手之前发生。
       */
      DirectCache.init(this.context);
      NativeFeed.warmStart(WARM_FEED_COUNT);
      // reels 的预热**只在 Wi-Fi/不计费网络**下做：它是一次完整的 Clips 请求（响应比信息流那条
      // 更大），而用户开 app 未必会点进 Reels —— 蜂窝网下这笔钱不值得先花（见 core/NetworkState）。
      if (NetworkState.allowPrefetch()) {
        NativeReels.warmStart(WARM_REELS_COUNT);
      }
      hilog.info(DOMAIN, 'testTag', 'warmup kicked off %{public}s', NetworkState.describe());
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'feed warmup failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // ---- 移动 API 自检（移植确认用，见 core/mobileapi/MobileProbe）----
    // 为什么延迟：Cookie 罐里要有 IG 的会话，得等 Web 内核把持久化的 Cookie 载进来（上面才
    // initializeWebEngine）；onCreate 这一刻读往往是空的。所以等几秒再跑，**不挡 UI**。
    // 探针只报告形状，不解析、不改任何界面状态；失败也不影响任何既有路径。
    // 传 context 是为了把结论**落盘**（`filesDir/Instarmony_mobile.txt`）：真机上 chromium 的
    // 日志会把 hilog 环形缓冲冲掉，只有落盘能用 `hdc file recv` 取到（同 core/StoryDiag）。
    MobileProbe.scheduleSelfTest(this.context);
    // ---- 翻译自检（诊断用，见 core/Translator 的 SELF_TEST_ON_START）----
    // 用户报"全部文本点翻译都失败"：界面里点不出结论，这里启动后翻一句固定英文并落盘
    // `filesDir/Instarmony_translate.txt`（原因码 / 端点 / 耗时），取回来就能分清是网络不通
    // 还是端点拒绝。不影响任何用户路径。
    Translator.scheduleSelfTest(this.context);
    // ---- 深链：冷启动这次是不是被 instarmony:// 唤起的 ----
    // 放在最后：预热那几条都是"只提前、不改行为"的优化，深链才是这次启动的**真实原因**，
    // 它需要的数据（解析）只是一次字符串处理，不依赖上面任何一步。
    this.readColdDeepLink(want, launchParam);
  }

  /**
   * 冷启动读深链（Want.uri → intent）。
   *
   * 只解析、不跳页：跳页在 onWindowStageCreate 里（那时才有 windowStage 可以 loadContent）。
   */
  private readColdDeepLink(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 记下启动原因，出问题时能区分"被 startAbility 拉起"还是"预加载/迁移"。
    const reason: number = launchParam === undefined ? -1 : launchParam.launchReason;
    this.coldWantHandled = true;
    const intent: DeepLinkIntent | null = this.parseIntent(want, 'onCreate');
    if (intent === null) {
      return;
    }
    this.coldDeepLink = intent;
    /*
     * 同时放进 pending 队列（和热启动同一条出口）。
     *
     * 落地页（pages/DeepLink）点「打开」后是 replaceUrl 进首页的，那时 EntryAbility 已经不参与
     * 了 —— 首页只能从 core/DeepLink 里取意图。所以冷启动的这份也必须入队，否则"打开"会变成
     * 单纯的回首页（链接丢在半路）。
     */
    DeepLink.stash(intent);
    hilog.info(DOMAIN, 'testTag', 'cold deep link %{public}s reason=%{public}d',
      intent.describe(), reason);
  }

  /**
   * 热启动：App 实例已经在（可能在别的页面上），系统带着新 Want 把本 ability 唤到前台。
   *
   * 这里**不推页面**：当前压着哪些 NavDestination、网页宿主处于什么状态只有 pages/Index 知道。
   * 所以只把 intent 存进 core/DeepLink.pending，由 Index 的 onForeground 取走执行 ——
   * 这也是"网页/外部 App 的一个链接 = 原生侧一次普通方法调用"最省事的落地方式。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (this.coldWantHandled) {
      // 冷启动必然紧跟一次携带同一 Want 的 onNewWant：那一次已经在 onCreate 处理过了。
      this.coldWantHandled = false;
      return;
    }
    const intent: DeepLinkIntent | null = this.parseIntent(want, 'onNewWant');
    if (intent === null) {
      return;
    }
    DeepLink.stash(intent);
    hilog.info(DOMAIN, 'testTag', 'warm deep link %{public}s', intent.describe());
  }

  /**
   * 从 Want 里取 uri 并解析成 intent（不是深链就返回 null）。
   *
   * 解析本身在 core/DeepLink 里（纯字符串处理、可单测），这里只负责"从 Want 到字符串"这一段。
   */
  private parseIntent(want: Want, from: string): DeepLinkIntent | null {
    const uri: string = want === undefined || want.uri === undefined ? '' : `${want.uri}`;
    const intent: DeepLinkIntent | null = DeepLink.parse(uri);
    if (intent === null) {
      return null;
    }
    if (!intent.isComplete()) {
      // 认识这个 scheme 但目标不完整（例如 profile 没给 id）：照样存起来，
      // 让落地页把"缺什么"显示给用户看，比默默忽略更有用。
      hilog.warn(DOMAIN, 'testTag', 'deep link (%{public}s) incomplete: %{public}s', from, intent.raw);
    }
    return intent;
  }

  /**
   * 系统深浅色切换。
   *
   * 底栏图标、信息流叠字都是按"当前背景深浅"取色的，所以要重新判一次并发布。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    AppSettings.refreshTheme(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 退出应用：把预下载的媒体清掉（理由见 MediaPrefetch.clearCache）。
    MediaPrefetch.clearCache();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 注：试过在这里 setWindowLayoutFullScreen(true) + 状态栏底色透明，让内容连系统状态栏一起盖住
    // —— 效果是有了，但全屏布局会把 HDS 标题栏的内容整体上移一个状态栏高度（标题和状态栏时钟
    // 叠在一起）。按需求**改回去了**：内容画到状态栏下沿为止，状态栏那一条仍由系统画。

    /*
     * `loadContent(page, storage, cb)` 的第二个参数必须是 **LocalStorage**，不能直接塞一个
     * `Record<string, Object>`（编译期会报 `Argument of type 'Record<string, Object>' is not
     * assignable to parameter of type 'LocalStorage'`）。深链参数放进这个 storage，
     * `LinkIn` 页用 `getUIContext().getSharedLocalStorage()` 取（见 LinkIn.aboutToAppear）。
     */
    const landingStorage: LocalStorage = new LocalStorage();
    landingStorage.setOrCreate('linkInParams', this.landingParams());
    windowStage.loadContent(this.landingPage(), landingStorage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  /**
   * 首屏铺哪一页。
   *
   * 默认就是首页；**被深链唤起**时先铺落地页（pages/DeepLink）：把 Want 里收到的东西摊开给
   * 用户看，点"打开"才进首页。为什么要多这一跳，见 pages/DeepLink 顶部的说明
   * （冷启动时网页宿主还没建好，立刻切 tab/导航网页不可靠）。
   */
  private landingPage(): string {
    return this.coldDeepLink === null ? 'pages/Index' : 'pages/LinkIn';
  }

  /** 落地页的路由参数：把**原始 uri** 原样交过去，解析在页面里做一次（单一解析入口）。 */
  private landingParams(): Record<string, Object> {
    const params: Record<string, Object> = {};
    if (this.coldDeepLink !== null) {
      params['uri'] = this.coldDeepLink.raw;
      // 解析好的 route/id 也带上：落地页用它做展示，省得再解一遍。
      params['route'] = this.coldDeepLink.route;
      params['id'] = this.coldDeepLink.id;
    }
    return params;
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // 让常驻的 WebView 恢复 JS 定时器与媒体（见 InstagramWebHost.applyVisibility）。
    if (AppLifecycle.isRegistered()) {
      AppLifecycle.notifyForeground();
    }
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 离开应用（回桌面/切走）就把预下载的媒体清掉：那些是"这次浏览用的"，留着只会占磁盘
    // （见 MediaPrefetch.clearCache）。下次进来滑到哪几张再重新预下载。
    MediaPrefetch.clearCache();
    if (AppLifecycle.isRegistered()) {
      AppLifecycle.notifyBackground();
    }
  }
}