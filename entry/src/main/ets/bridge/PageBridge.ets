/*
 * Instarmony page bridge.
 *
 * One WebView owns the real Instagram session. Native ArkUI asks the page to
 * read its own DOM or perform a same-origin request; asynchronous results come
 * back through window.ogNative.onBridgeResult instead of runJavaScript's
 * synchronous return value.
 */

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramProbe } from '../probe/InstagramProbe';
import { SessionGate } from '../core/SessionGate';
// 实时通道的回传落点（见 onMqttEvent）。
import { MobileMqttWs } from '../core/mobileapi/MobileMqttWs';

const DEFAULT_TIMEOUT_MS: number = 20000;
/**
 * "刚刚确认网页不就绪"的记忆能管多久（毫秒，见 `awaitPageReady`）。
 *
 * 取 10 秒：足够覆盖启动预热那几步串行的间隔（每步之间还有 `WARM_STEP_GAP_MS`），
 * 又不至于让用户过一会儿主动重试时也被跳过等待。
 */
const NOT_READY_MEMO_MS: number = 10000;
/**
 * 快速通道上**限流**日志：同一份"不就绪"记忆期间，最多每隔这么久打一行。
 *
 * 为什么必须限流：这条通道是同步返回的，调用方如果在 while 里重试，就能在几秒里调它
 * 几万次 —— 曾经真的这么打过 36 万行日志（日志本身又反过来占住主线程，见下面的 yield）。
 */
const NOT_READY_LOG_GAP_MS: number = 500;
const TAG: string = 'InstarmonyBridge';
const DOMAIN: number = 0xFF00;

class PendingBridge {
  resolve: (value: string) => void;

  constructor(resolve: (value: string) => void) {
    this.resolve = resolve;
  }
}

/** 手动兑现的 Promise 外壳，避免在 executor 里给外层变量赋值。 */
class DeferredOutcome {
  resolve: (outcome: string) => void = (outcome: string): void => {
  };
  promise: Promise<string> = Promise.resolve('');
}

/** 等页面加载完成的登记项（onPageEnd → markReady 时兑现）。 */
class ReadyWaiter {
  readonly resolve: (outcome: string) => void;

  constructor(resolve: (outcome: string) => void) {
    this.resolve = resolve;
  }
}

export class InstagramBridgeProxy {
  onBridgeResult(id: string, json: string): void {
    InstagramPageBridge.getInstance().resolve(id, json);
  }

  onRouteChange(url: string): void {
    InstagramPageBridge.getInstance().publishRoute(url);
  }

  onSessionState(state: string): void {
    InstagramPageBridge.getInstance().publishSession(state === '1');
  }

  /** 探针：页面自己发出的请求 / 响应样本（JSON 字符串）。 */
  onApiDetail(json: string): void {
    InstagramProbe.getInstance().record(json);
  }


  /**
   * **MQTT over WebSocket 的回传通道**（见 core/mobileapi/MobileMqttWs）。
   *
   * 为什么实时通道要走网页：ArkTS 的 `TLSSocket` 在本运行时**收不到任何数据**
   * （实测对照见 core/mobileapi/NetProbe：明文 TCP 收得到、TLS 一条都收不到），
   * 而隐藏在应用里的 WebView 用的是 Chromium 的网络栈，WSS 是好的。
   * 于是：原生负责拼 MQTT 报文（Thrift + zlib），网页负责收发帧。
   *
   * @param kind  `open` / `bin`（二进制帧，data 是 base64）/ `text` / `error` / `close`
   * @param data  载荷（二进制帧为 base64，其余为短字符串）
   */
  onMqttEvent(kind: string, data: string): void {
    MobileMqttWs.onEvent(kind, data);
  }


}

/**
 * Shared bridge around the single Instagram WebView controller.
 */
export class InstagramPageBridge {
  private static instance: InstagramPageBridge | null = null;
  readonly controller: webview.WebviewController = new webview.WebviewController();
  private readonly proxy: InstagramBridgeProxy = new InstagramBridgeProxy();
  private readonly pending: Map<string, PendingBridge> = new Map<string, PendingBridge>();
  /** 等页面加载完成的等候者。 */
  private readonly readyWaiters: Array<ReadyWaiter> = [];
  /** 单调递增，不随换页归零——归零会让换页前登记的等待永远等不到。 */
  private ready: boolean = false;
  /**
   * 控制器现在有没有真的绑到一个 `Web` 组件上（见 `markAttached` / `markDetached`）。
   *
   * 为什么要这个标志：控制器是**单例**（一个 Web 组件），而宿主组件是按需挂载的
   * （见 Index 的 `webHostMounted`）。宿主没挂上时 `controller.loadUrl()` 会抛
   * `Init error`（17100001），旧代码把它 `catch {}` 吞掉了 —— 用户看到的就是
   * "点了帖子只打开 IG 首页，没到那条帖子"。
   */
  private attached: boolean = false;
  /**
   * 宿主还没挂上时收到的导航请求（只留最后一条）：挂上那一刻补发（见 `markAttached`）。
   *
   * 只留最后一条是有意的 —— 连点几条时用户要看的是最后点的那一条，前面的排队补发
   * 既浪费一发生成请求，也会让界面"闪过去又闪回来"。
   */
  private pendingUrl: string = '';
  /**
   * "上一次等就绪超时"的时刻（毫秒）。见 `awaitPageReady`：短时间内别一段一段地陪等。
   * `markReady()` / `markUnready()` 都会清掉它（就绪状态变了，这份记忆就不成立了）。
   */
  private notReadyAtMs: number = 0;
  /** 上一次在快速通道上打日志的时刻 / 期间被抑制的次数（见 NOT_READY_LOG_GAP_MS）。 */
  private notReadyLoggedAt: number = 0;
  private notReadySkipCount: number = 0;
  private sequence: number = 0;
  private routeHandler: (url: string) => void = (url: string): void => {
  };
  private sessionHandler: (signedIn: boolean) => void = (signedIn: boolean): void => {
  };
  private readyHandler: () => void = (): void => {
  };

  static getInstance(): InstagramPageBridge {
    if (InstagramPageBridge.instance === null) {
      InstagramPageBridge.instance = new InstagramPageBridge();
    }
    return InstagramPageBridge.instance;
  }

  pageProxy(): InstagramBridgeProxy {
    return this.proxy;
  }

  setRouteHandler(handler: (url: string) => void): void {
    this.routeHandler = handler;
  }

  setSessionHandler(handler: (signedIn: boolean) => void): void {
    this.sessionHandler = handler;
  }

  setReadyHandler(handler: () => void): void {
    this.readyHandler = handler;
  }


  markReady(): void {
    this.ready = true;
    // 真的就绪了：把"刚刚确认不就绪"的记忆清掉（见 awaitPageReady 的说明）。
    this.notReadyAtMs = 0;
    // 先兑现等候者，再回调页面：这样「等加载完成」的调用方不会被页面回调的顺序影响。
    const waiters: Array<ReadyWaiter> = this.readyWaiters.splice(0, this.readyWaiters.length);
    for (let index: number = 0; index < waiters.length; index++) {
      waiters[index].resolve('ready');
    }
    this.readyHandler();
  }

  /** 页面开始/结束一轮导航：文档会重建，页面内存里的 __ogReplay 也随之作废。 */
  markUnready(): void {
    this.ready = false;
    /*
     * 新一轮导航开始了：作废"不就绪"的记忆 —— 这一次是真的要等它加载完
     * （清掉记忆后，`awaitPageReady` 会老老实实挂上去等）。
     */
    this.notReadyAtMs = 0;
  }

  isReady(): boolean {
    return this.ready;
  }

  /**
   * 宿主组件把控制器绑好了（`InstagramWebHost.onControllerAttached` 里调）。
   *
   * @param mountedUrl 这个组件是**从哪条地址起步**的（`Web({src})` 那个值）。
   *   如果挂载前攒下的导航请求正好就是它，说明页面已经在往那儿走了，不用再导航一次。
   */
  markAttached(mountedUrl: string): void {
    this.attached = true;
    const pending: string = this.pendingUrl;
    this.pendingUrl = '';
    if (pending.length === 0) {
      return;
    }
    if (pending === mountedUrl) {
      hilog.info(DOMAIN, TAG, 'navigation already served by mounted src: %{public}s', pending);
      return;
    }
    hilog.info(DOMAIN, TAG, 'navigation flush after attach: %{public}s', pending);
    this.loadUrl(pending);
  }

  /** 宿主组件被卸掉（组件销毁）时调：之后收到的导航请求一律先攒着。 */
  markDetached(): void {
    this.attached = false;
    this.ready = false;
  }

  /** 现在有没有"等着宿主挂上再发"的导航（诊断用）。 */
  pendingNavigation(): string {
    return this.pendingUrl;
  }

  /**
   * 等页面加载完成（onPageEnd → markReady）。
   *
   * 点互动需要临时把隐藏网页真的导航到帖子页再读，导航是页面级的、会重造文档，
   * 所以原生侧必须能等到「这一次导航结束」再注入脚本，否则会在旧文档上执行。
   * 返回 'ready' 或 'timeout'。
   */
  async awaitPageReady(timeoutMs: number): Promise<string> {
    const started: number = Date.now();
    if (this.ready) {
      return 'ready';
    }
    /*
     * **刚刚已经确认"不就绪"，短时间内不再陪等一遍**（审计 G6）。
     *
     * 启动预热链是一步接一步串行的，每一步在自己的"网页兜底"路径里都会
     * `awaitPageReady(20000)`。网页一直不就绪时那就是**每步白等 20 秒** ——
     * 用户切到 Reels / 我的 看到的是空页 + "页面尚未就绪"，后台却还在一段一段地等。
     * 结论本来就是同一个（就是没就绪），所以这里直接给 timeout。
     * 页面真的就绪（markReady）或开始新一轮导航（markUnready）时，这份记忆都会作废。
     */
    if (this.notReadyAtMs > 0 && Date.now() - this.notReadyAtMs < NOT_READY_MEMO_MS) {
      const now: number = Date.now();
      const skipped: number = this.notReadySkipCount + 1;
      this.notReadySkipCount = skipped;
      if (now - this.notReadyLoggedAt >= NOT_READY_LOG_GAP_MS) {
        this.notReadyLoggedAt = now;
        this.notReadySkipCount = 0;
        hilog.info(DOMAIN, TAG, 'awaitPageReady skip: not ready %{public}dms ago (x%{public}d)',
          now - this.notReadyAtMs, skipped);
      }
      /*
       * **让出一个宏任务再返回。**
       *
       * 这条通道是"立刻返回"的，而调用方往往写成 `while (...) { await awaitPageReady() }`。
       * 只 await 一个**已解决**的 promise 只会排微任务：定时器、触摸、绘制这些宏任务
       * 一辈子排不进来，主线程就被那一圈代码占死。真机实测：连续 10 秒、36 万行日志、
       * 系统记 `uv_timer_task 10004ms` 并报 AppFreeze。
       * 这里 sleep 0 毫秒，等于把调用方的自旋强制降速成"每圈一个宏任务"，即使调用方
       * 没改也不会再冻住主线程（调用方那侧另有正当的等待，见 FeedViewModel.waitPageReady）。
       */
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 0);
      });
      return 'timeout';
    }
    const deferred: DeferredOutcome = new DeferredOutcome();
    deferred.promise = new Promise<string>((resolve: (outcome: string) => void) => {
      deferred.resolve = resolve;
    });
    const waiter: ReadyWaiter = new ReadyWaiter(deferred.resolve);
    this.readyWaiters.push(waiter);
    const timeout: Promise<string> = new Promise<string>((resolve: (outcome: string) => void) => {
      setTimeout((): void => {
        resolve('timeout');
      }, timeoutMs);
    });
    const outcome: string = await Promise.race([deferred.promise, timeout]);
    hilog.info(DOMAIN, TAG, 'awaitPageReady %{public}s %{public}dms',
      outcome, Date.now() - started);
    if (outcome !== 'ready') {
      // 记下"这一刻它不就绪"：后面几步短时间内再来问就立刻回 timeout（见函数开头）。
      this.notReadyAtMs = Date.now();
      const keep: Array<ReadyWaiter> = [];
      for (let index: number = 0; index < this.readyWaiters.length; index++) {
        if (this.readyWaiters[index] !== waiter) {
          keep.push(this.readyWaiters[index]);
        }
      }
      this.readyWaiters.length = 0;
      for (let index: number = 0; index < keep.length; index++) {
        this.readyWaiters.push(keep[index]);
      }
    }
    return outcome;
  }

  publishRoute(url: string): void {
    if (url.length > 0) {
      this.routeHandler(url);
    }
  }

  publishSession(signedIn: boolean): void {
    this.sessionHandler(signedIn);
  }

  resolve(id: string, json: string): void {
    const entry: PendingBridge | undefined = this.pending.get(id);
    if (entry === undefined) {
      return;
    }
    this.pending.delete(id);
    entry.resolve(json);
  }

  // ---- 导航 ----------------------------------------------------------------

  loadUrl(url: string): void {
    /*
     * **未登录闸门**（见 core/SessionGate 的文件头）。
     *
     * 这里是全 app 唯一的导航入口，所以闸门放在这一层：未登录时，后台那些"顺手导航一下"
     * （预热的冷启动抓模板、失败重抓、页面自己回首页…）一条都别想推动隐藏网页 —— 它们推动的
     * 结果就是 IG 把登录页连同 `next=` 一遍遍重定向，用户看到"登录页反复刷新"。
     * 只放行登录流程自己那几条地址（登录页 / 验证 / challenge），否则登录路会被堵死。
     *
     * `reload()` 不设闸门：那是用户按的刷新键，也是渲染进程崩了之后的恢复路径，
     * 拦下来只会让界面卡死（见 InstagramWebHost.onRenderExited）。
     */
    if (!SessionGate.allowsNavigation(url)) {
      hilog.info(DOMAIN, TAG, 'navigation blocked (signed out): %{public}s', url);
      return;
    }
    /*
     * **宿主还没挂上**：控制器没绑组件，`loadUrl` 必抛 `Init error`。
     * 以前这里把它 catch 掉就算了，于是"点帖子 → 打开网页"看到的永远是 IG 首页
     * （宿主是在下一次渲染才建的，而建的时候从 `src` 回到首页）。
     * 现在先记下来，宿主挂上那一刻补发（见 markAttached）。
     */
    if (!this.attached) {
      this.pendingUrl = url;
      hilog.info(DOMAIN, TAG, 'navigation queued (host not attached): %{public}s', url);
      return;
    }
    this.ready = false;
    this.pendingUrl = '';
    try {
      this.controller.loadUrl(url);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadUrl failed: %{public}s', (error as Error).message);
      this.pendingUrl = url;
    }
  }

  reload(): void {
    this.ready = false;
    // 宿主没挂上时 refresh() 同样会抛；等挂上之后自会加载，不必记请求。
    if (!this.attached) {
      return;
    }
    try {
      this.controller.refresh();
    } catch (error) {
    }
  }

  canGoBack(): boolean {
    if (!this.attached) {
      return false;
    }
    try {
      return this.controller.accessBackward();
    } catch (error) {
      return false;
    }
  }

  goBack(): void {
    if (!this.attached) {
      return;
    }
    try {
      this.controller.backward();
    } catch (error) {
    }
  }

  /**
   * **直接执行一段 JS 并把结果当字符串拿回来**（不依赖页面的 ogNative 桥）。
   *
   * 用在哪：无头网页登录（见 core/WebLogin）—— 要在登录页里填账号密码、点提交、读错误文案，
   * 那几条都不该走 `runBridge`：它要求页面里已经注入过 `ogNative`（模板机制的产物），
   * 而登录页是 IG 自己的 React 页面，没有我们的桥对象。
   *
   * 之所以还能用：宿主是 `Visibility.Hidden` 的，但引擎里 JS / 定时器 / 网络照常跑
   * （见 InstagramWebHost 那段注释），所以"看不见地登录"这件事成立。
   */
  async runScript(script: string): Promise<string> {
    if (!this.attached) {
      return '';
    }
    try {
      const out: string = await this.controller.runJavaScript(script);
      return out === undefined || out === null ? '' : `${out}`;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'runScript failed: %{public}s', (error as Error).message);
      return '';
    }
  }

  /** 宿主挂上了没有（`runScript` 是否有意义）。 */
  isAttached(): boolean {
    return this.attached;
  }

  /**
   * Runs a page-side expression and waits for its asynchronous result.
   *
   * The expression should return a value or a Promise. Everything is serialized
   * to a string before it crosses the JavaScript proxy.
   *
   * `label` 只是给耗时日志用的（见下面的计时）：非空才打日志，所以探针之类的高频调用
   * 不会把日志刷满。日志同时给出**注入脚本自身耗时**（页面里跑多久）和**回传数据大小**，
   * 优化取数速度时一眼能看出是"页面慢"还是"数据太大"。
   */
  async runBridge(script: string, timeoutMs: number = DEFAULT_TIMEOUT_MS,
    label: string = ''): Promise<string> {
    if (!this.ready) {
      return '{"state":"not-ready"}';
    }
    const started: number = Date.now();
    this.sequence++;
    const id: string = `og${Date.now()}_${this.sequence}`;
    const promise: Promise<string> = new Promise<string>((resolve) => {
      this.pending.set(id, new PendingBridge(resolve));
    });
    const idLiteral: string = JSON.stringify(id);
    const wrapped: string =
      '(function(){var id=' + idLiteral + ';' +
      'function send(v){try{window.ogNative.onBridgeResult(id,String(v));}catch(e){}}' +
      'try{Promise.resolve(' + script + ').then(send).catch(function(e){' +
      'send(JSON.stringify({state:"error",message:String(e).slice(0,160)}));});}' +
      'catch(e){send(JSON.stringify({state:"error",message:String(e).slice(0,160)}));}' +
      'return "";})()';
    try {
      // **不要 await runJavaScript**：页面正在导航或忙的时候，ArkWeb 的这个 promise
      // 可能永远不 settle —— 那样下面的超时根本没机会生效，整个桥调用会**永远挂住**
      // （实测：读评论、个人页首次加载都因此卡死，日志里连一行都不打）。
      // 注入只是"发起"，要等的是页面通过 window.ogNative.onBridgeResult 回传的结果；
      // 注入自己失败时，立刻把结论交给等待者，别让它白等。
      this.controller.runJavaScript(wrapped).catch((): void => {
        const entry: PendingBridge | undefined = this.pending.get(id);
        if (entry !== undefined) {
          this.pending.delete(id);
          entry.resolve('{"state":"inject-failed"}');
        }
      });
    } catch (error) {
      this.pending.delete(id);
      return '{"state":"inject-failed"}';
    }
    const timeout: Promise<string> = new Promise<string>((resolve) => {
      setTimeout((): void => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          hilog.info(DOMAIN, TAG, 'bridge %{public}s timeout %{public}dms',
            label.length > 0 ? label : '-', timeoutMs);
          resolve('{"state":"timeout"}');
        }
      }, timeoutMs);
    });
    const out: string = await Promise.race([promise, timeout]);
    if (label.length > 0) {
      hilog.info(DOMAIN, TAG, 'bridge %{public}s %{public}dms out=%{public}d bytes',
        label, Date.now() - started, out.length);
    }
    return out;
  }
}
