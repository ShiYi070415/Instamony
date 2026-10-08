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
import { webview } from '@kit.ArkWeb';
import { AppConfig } from '../config/AppConfig';

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

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
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