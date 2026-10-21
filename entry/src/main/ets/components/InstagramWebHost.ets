/*
 * The only Instagram WebView in Instarmony.
 *
 * It is always mounted. When native content is on screen it stays underneath
 * with opacity 0.01, which keeps Instagram hydrated and preserves cookies/SPA
 * state instead of reloading on every tab change. When login or a web detail is
 * open, the same WebView is revealed with a native top bar above it.
 */

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConfig } from '../config/AppConfig';
import { InstagramPageBridge, InstagramBridgeProxy } from '../bridge/PageBridge';
import { SESSION_WATCHER } from '../bridge/WebScripts';
import { AppLifecycle } from '../core/AppLifecycle';
import { InstagramCookieJar, InstagramCookieSnapshot } from '../core/InstagramCookieJar';

const TAG: string = 'InstagramWebHost';
const DOMAIN: number = 0xFF00;
/** 页面加载完成后延迟再核对一次：Instagram 的会话 Cookie 有时晚于 onPageEnd 落罐。 */
const SESSION_RECHECK_MS: number = 1200;

@Component
export struct InstagramWebHost {
  @Prop @Watch('onVisibleChanged') visible: boolean = false;
  /**
   * 现在是不是已登录（`Index.applySession` 传进来）。
   *
   * 只用于一件事：**未登录时不要预加载**（见 prefetchLikelyPages）。它是本轮那个
   * "退出登录后网页登录页反复刷新"的元凶之一：未登录时 `/reels/`、`/direct/inbox/`
   * 这些预加载会被 IG 一条条重定向到 `/accounts/login/?next=…`，而每次整页导航结束又会
   * 再触发一次预加载 —— 自己把自己踩成了循环。
   */
  @Prop signedIn: boolean = false;
  onPageReady: () => void = (): void => {
  };
  onSessionChanged: (signedIn: boolean) => void = (signedIn: boolean): void => {
  };
  private bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private proxy: InstagramBridgeProxy = InstagramPageBridge.getInstance().pageProxy();

  /**
   * 登录态的权威判据：ArkWeb 的 Cookie 罐。
   *
   * 不看页面 DOM、也不看 `document.cookie`——会话 Cookie 是 HttpOnly，只有原生罐
   * 能读到。拿到会话后立刻落盘，下次启动不必重新登录。
   */
  private async detectSession(): Promise<void> {
    // 这里是"登录态"的权威核对：罐可能刚被网页改过，先作废读罐缓存（见 InstagramCookieJar）。
    InstagramCookieJar.invalidate();
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    hilog.info(DOMAIN, TAG, 'cookie jar entries=%{public}d signedIn=%{public}s names=%{public}s',
      snapshot.count, snapshot.signedIn ? '1' : '0', snapshot.names);
    if (snapshot.signedIn) {
      await InstagramCookieJar.save();
    }
    this.onSessionChanged(snapshot.signedIn);
  }

  private scheduleSessionCheck(): void {
    this.detectSession();
    setTimeout((): void => {
      this.detectSession();
    }, SESSION_RECHECK_MS);
  }

  /**
   * 预加载"接下来很可能要访问"的页面（官方 Web 预测能力）。
   *
   * 官方说明：`prefetchPage()` 会**提前下载该页面所需的主资源与子资源**，避免真正导航时阻塞渲染，
   * 但**不执行页面的 JavaScript**；它是 `WebviewController` 的实例方法，需要一个已经关联好
   * Web 组件的控制器 —— 所以放在 onPageEnd（此时组件已就绪）里调用。
   *
   * 为什么是这三页：私信 / 搜索 / Reels 的原生页在**没有接口模板**时都要让隐藏网页整页导航过去
   * （冷启动那条路），预加载能把这一步的等待抹掉。只预加载、不改变任何现有行为，失败也不管。
   */
  private prefetchLikelyPages(url: string): void {
    if (url.indexOf('instagram.com') < 0) {
      return;
    }
    /*
     * **未登录不预加载**：这几条地址在未登录时都会被 IG 重定向到登录页，而预加载触发的
     * 导航结束又会再调一次本方法 —— 真机日志里就是每几秒一轮 `/` → `/reels/` →
     * `/accounts/login/?next=…reels…` → `/direct/inbox/` → `/accounts/login/?next=…direct…`，
     * 用户点登录把网页亮出来时看到的就是"登录页一直在刷新"（见 core/SessionGate）。
     */
    if (!this.signedIn) {
      hilog.info(DOMAIN, TAG, 'prefetchPage skipped: signed out');
      return;
    }
    const targets: Array<string> = [
      AppConfig.INSTAGRAM_DIRECT_URL,
      AppConfig.INSTAGRAM_SEARCH_URL,
      AppConfig.INSTAGRAM_REELS_URL
    ];
    for (let index: number = 0; index < targets.length; index++) {
      try {
        this.bridge.controller.prefetchPage(targets[index]);
        hilog.info(DOMAIN, TAG, 'prefetchPage %{public}s', targets[index]);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'prefetchPage failed: %{public}s', (error as Error).message);
      }
    }
  }

  aboutToAppear(): void {
    AppLifecycle.onVisibilityChanged((foreground: boolean): void => {
      this.applyVisibility(foreground);
    });
    // 首帧就按当前 `visible` 定调：隐藏态一律降渲染（见 syncEngineActivity）。
    this.syncEngineActivity();
  }

  /**
   * 前后台切换时挂起 / 恢复网页。
   *
   * 原生视图在前台时这个 WebView 是以 opacity 0.01 常驻的：网页自己的定时器
   * （SESSION_WATCHER 里每秒轮询一次）、网络与媒体播放都会继续跑。进后台时把它们
   * 一起停掉，回前台再放开，避免不可见页面持续耗电。
   *
   * pauseAllTimers / resumeAllTimers 是全局静态接口，停的是 JS 定时器；onInactive /
   * onActive 让引擎顺带停掉动画之类「可以安全暂停」的东西（不含 JS，见 SDK 说明）。
   */
  private applyVisibility(foreground: boolean): void {
    try {
      if (foreground) {
        // 回前台：按"网页现在该不该显示"决定恢复多少（见 syncEngineActivity）。
        this.syncEngineActivity();
      } else {
        webview.WebviewController.pauseAllTimers();
        this.bridge.controller.stopAllMedia();
        this.bridge.controller.onInactive();
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'visibility switch failed');
    }
  }

  /** `visible` 变了：网页被亮出来/收回去时同步引擎的渲染强度。 */
  private onVisibleChanged(): void {
    this.syncEngineActivity();
  }

  /**
   * **隐藏时必须让内核降渲染**（"手机发烫"的主因之一）。
   *
   * 现场（真机量的）：原生页面全屏时这个 WebView 还是常驻的（`opacity 0.01`），引擎照样
   * 按 60fps 合成 Instagram 的网页动画 —— 日志被 chromium 的帧回调刷到 **2765 行/秒**
   * （其中约 76% 是它的 `OnVSyncImpl` / `DVsync` 那几条），`hilogd` 自己被拖到 144% CPU，
   * 整机几乎没有空闲。
   *
   * `onInactive()` 是官方给这件事准备的接口：**只降渲染**（停掉"可以安全暂停"的动画与合成），
   * **不停 JS 定时器** —— 隐藏网页要做的导航/取数仍然照常。
   * `visible = true`（登录页/验证页/深链）时才恢复 `onActive()`。
   */
  private syncEngineActivity(): void {
    try {
      if (this.visible) {
        webview.WebviewController.resumeAllTimers();
        this.bridge.controller.onActive();
        return;
      }
      /*
       * 隐藏态：**连 JS 定时器一起停**。
       *
       * 只 `onInactive()` + 不进绘制树时，chromium 那边仍有 2900 行/秒的帧回调
       * （Instagram 网页自己的轮询/动画在驱动）。隐藏时我们只需要它"能执行一段注入的
       * 脚本"（取数/导航），并不需要它跑自己的定时器 —— 停掉之后实测 CPU 从 44% 再降。
       * 可见（登录 / 安全验证 / 深链）时立刻 resume，网页行为完全不受影响。
       */
      webview.WebviewController.pauseAllTimers();
      this.bridge.controller.onInactive();
    } catch (error) {
    }
  }

  aboutToDisappear(): void {
    try {
      InstagramCookieJar.save();
    } catch (error) {
    }
  }

  build() {
    Web({
      src: AppConfig.INSTAGRAM_HOME_URL,
      controller: this.bridge.controller,
      incognitoMode: false
    })
      .width('100%')
      .height('100%')
      .opacity(this.visible ? 1 : 0.01)
      /*
       * **隐藏时不进绘制树**（这是"手机发烫"的真正止血点）。
       *
       * 原来只靠 `opacity(0.01)` 把它"藏起来"，但它仍然是可见的组件：引擎照样按 60fps
       * 合成 Instagram 网页的动画，chromium 的帧回调把日志刷到 3000+ 行/秒（实测 80%
       * 的日志都是它），`hilogd` 被拖到 144% CPU、整机没有空闲。`onInactive()` 也不够
       * （只停"可以安全暂停"的动画，合成与 vsync 还在）。
       * `Visibility.Hidden` 让它在布局里仍占位（不会引起页面重排），但**不参与绘制** ——
       * 引擎不再出帧；JS / 桥接 / 隐藏导航都照常（我们只用它取数，不需要它显示）。
       */
      .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
      .zIndex(this.visible ? 20 : 0)
      .hitTestBehavior(this.visible ? HitTestMode.Default : HitTestMode.None)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .databaseAccess(true)
      .fileAccess(false)
      .mixedMode(MixedMode.Compatible)
      .cacheMode(CacheMode.Default)
      .overviewModeAccess(true)
      .mediaPlayGestureAccess(false)
      .darkMode(WebDarkMode.Auto)
      .textZoomRatio(100)
      .javaScriptProxy({
        object: this.proxy,
        name: 'ogNative',
        methodList: ['onBridgeResult', 'onRouteChange', 'onSessionState', 'onMqttEvent'],
        controller: this.bridge.controller
      })
      .onControllerAttached(() => {
        try {
          this.bridge.controller.setCustomUserAgent(AppConfig.WEB_USER_AGENT);
        } catch (error) {
          hilog.warn(0x0000, TAG, 'custom user agent rejected');
        }
        // 引擎已经起来了，这时读 Cookie 罐才是安全的（见 Index.aboutToAppear 的说明）。
        this.detectSession();
      })
      /*
       * 只注入**会话/路由观察**那一条（它只读 `document.cookie` 与 DOM，体量很小）。
       *
       * `NETWORK_WATCHER`（包住 fetch/XHR 抓请求模板）**已不再注入**：所有取数与写操作
       * 都迁到了移动端私有 API（见 core/mobileapi），页面里不再需要任何网络钩子 ——
       * 这是"不像自动化"的关键一步。模板机制现在只剩兜底读取（盘上已有的那些）。
       */
      .runJavaScriptOnDocumentStart([
        { script: SESSION_WATCHER, scriptRules: ['*'] }
      ])
      .onPageBegin((event) => {
        this.bridge.markUnready();
        // 每次整页导航开一条日志：和 `Index` 里的 `web route` 拼起来，就能看出
        // "同一页被反复整页重载"还是"SPA 在换路由"（见 Index 的 signOut 说明）。
        if (event !== undefined && event.url !== undefined) {
          hilog.info(DOMAIN, TAG, 'page begin %{public}s', event.url);
        }
      })
      .onPageEnd((event) => {
        this.bridge.markReady();
        this.onPageReady();
        if (event !== undefined && event.url.length > 0) {
          this.bridge.publishRoute(event.url);
        }
        this.scheduleSessionCheck();
        // 首页这一趟加载完，就把"接下来很可能要去"的页面**预加载**掉（见 prefetchLikelyPages）。
        this.prefetchLikelyPages(event !== undefined ? event.url : '');
      })
      .onLoadIntercept((event) => {
        try {
          const url: string = event.data.getRequestUrl();
          if (url.indexOf('instagram.com') >= 0) {
            this.bridge.publishRoute(url);
          }
        } catch (error) {
        }
        return false;
      })
      .onWindowNew((event: OnWindowNewEvent) => {
        try {
          const target: string = event.targetUrl;
          event.handler.setWebController(null);
          if (target.length > 0) {
            this.bridge.loadUrl(target);
          }
        } catch (error) {
          hilog.warn(0x0000, TAG, 'new window hand-off failed');
        }
      })
      .onRenderExited(() => {
        this.bridge.markUnready();
        this.bridge.reload();
      })
      .onErrorReceive((event) => {
        try {
          if (event.request.isMainFrame()) {
            this.bridge.markUnready();
            // 主文档加载失败要留痕：反复刷新那类问题常常是"主文档一直在报错 + 页面自己重试"，
            // 只有这里能看到失败原因（超时 / 被中断 / 证书 / 重定向过多）。
            hilog.warn(DOMAIN, TAG, 'main frame error %{public}s %{public}s',
              `${event.error.getErrorCode()}`, event.error.getErrorInfo());
          }
        } catch (error) {
        }
      })
  }
}
