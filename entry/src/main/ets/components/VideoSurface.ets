/*
 * 视频播放表面（AVPlayer + XComponent）—— feeds 流与 reels 共用同一个播放实现。
 *
 * 为什么不用 ArkUI 的 `Video` 组件：它走的是原生表面，自己**首帧之前画黑**，而这类表面在合成上
 * 未必被 ArkUI 的兄弟节点盖住 —— 试过"封面叠在它上面"、也试过"首帧前整层透明"，黑闪依然可见。
 *
 * 官方在《基于 AVPlayer 播放短视频实践》里走的是另一条路：自己用 **AVPlayer + XComponent**，并在
 * `media.PlaybackStrategy` 里开 **showFirstFrameOnPrepare**（prepare 阶段就把首帧解出来送显）
 * 与 **preferredBufferDurationForPlaying**（起播所需缓冲，单位**秒**）。这样首帧在
 * `prepared`/`playing` 那一刻就已经在表面上了，父组件在首帧回调之后才撤封面 —— 封面直切画面，没有黑。
 *
 * 另外本组件支持"预加载"：父组件把列表里**下一条**视频的 `preload` 置 true，这里的播放器会
 * 提前 prepare（缓冲好、首帧也解好），轮到它播时直接 play —— 这正是官方"播放器池 + 提前 prepare"
 * 的做法（官方给出的指标：切换起播 ≤230ms）。
 *
 * 生命周期：aboutToAppear 建播放器，aboutToDisappear 释放；`playing` / `preload` / `url` 变化时按
 * 状态机决定 prepare 还是 play/pause。所有失败只回调 onError / 记日志，不抛。
 *
 * 状态机的硬约束（照官方接口文档 + 真机实测，错一步就"永远不出画面"）：
 *   - `setMediaSource` 只能在 **idle** 调（所以要在建完播放器、还没设源之前）；这一步本身会
 *     **预下载媒体数据**，预加载的"提前量"主要就来自这里。
 *   - `surfaceId` 要**早于 prepare**：真机实测对一个 prepare 时没有表面的播放器再设 surfaceId 会被拒
 *     （`5400102 Operate Not Permit: switch surface with no old surface`），所以表面没到就先把
 *     prepare 挂起（pendingPrepare），onLoad 到了再补。
 *   - `play()` 时表面必须在，否则进不了 playing（那就记下 pendingPlay，等 onLoad 补播）。
 *   - `videoScaleType` / `loop` 只能在 prepared 及之后设，所以放在 prepared 那一刻。
 */

import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
// 前后台信号：切后台要把解码器还回去（见 appForeground 的说明）。
import { AppLifecycle, VisibilityHandler } from '../core/AppLifecycle';

const DOMAIN: number = 0xFF00;
const TAG: string = 'VideoSurface';

/** 起播所需缓冲（秒）—— 官方短视频示例就是 1：既够起播不卡，又不至于等太久。 */
const BUFFER_FOR_PLAYING_SEC: number = 1;
/**
 * 预下载缓冲（秒）。
 *
 * **这是流量开销最大的一处**：每个播放器都会先把这么多秒的视频抓下来（下一条还要提前 prepare，
 * 于是同一时刻往往有两个播放器在缓冲）。原来给 20 秒，等于每换一条视频就多下 20 秒的片子；
 * 按需求收到 **2 秒**：起播只要有 1 秒（见 BUFFER_FOR_PLAYING_SEC），2 秒足够顶住起播那一下，
 * 后面边播边缓冲。流量比原来少一个数量级，而 feeds/reels 的起播观感不变。
 */
const BUFFER_TOTAL_SEC: number = 2;
/** 设源失败后的重试间隔（毫秒）。 */
const SOURCE_RETRY_MS: number = 150;
/** 同一条视频最多重试几次设源（再多就是地址真有问题了）。 */
const SOURCE_RETRY_MAX: number = 2;

@Component
export struct VideoSurface {
  /** 视频地址（空串 = 什么都不播，父组件该走封面/占位）。 */
  @Prop @Watch('onPropChanged') url: string = '';
  /** 现在是不是"该播这一条"。 */
  @Prop @Watch('onPropChanged') playing: boolean = false;
  /**
   * 本页所属分段（0 = 探索 / 1 = 关注 / -1 = 独立页）。创建后不变。
   */
  segment: number = -1;
  /**
   * **全局播放开关**（组件自己订阅，不靠 @Prop 逐层传）。
   *
   * 为什么必须在这里订阅：播放器节点在 ForEach 里，键没变时上层传下来的 @Prop 到不了
   * 已经建好的节点 —— 结果就是「另一段还在播」「滑动时不停」。@StorageLink 是组件级订阅，
   * 值一变本组件一定重跑、@Watch 一定触发，才真能 pause()。
   */
  @StorageLink('reels_frozen_all') @Watch('onPropChanged') frozenAll: boolean = false;
  @StorageLink('reels_active_segment') @Watch('onPropChanged') activeSegment: number = 0;
  /** 是不是"下一条"（只提前 prepare，不播）—— 预加载就靠它。 */
  @Prop @Watch('onPropChanged') preload: boolean = false;
  /**
   * 画面填充方式：true = 裁切填满（Cover），false = 完整显示（Contain）。
   * 沉浸式视频（feeds 里那种竖版铺满）与 reels 都要 Cover；普通卡片里的横视频要 Contain。
   */
  @Prop @Watch('onPropChanged') cover: boolean = true;
  /** 静音（全局开关，见 AppSettings.SETTING_VIDEO_MUTED）：true = 音量 0。 */
  @Prop @Watch('onPropChanged') muted: boolean = false;
  /** 首帧真的上屏了（父组件据此撤掉封面）。只回调一次。 */
  onFirstFrame: () => void = (): void => {
  };
  /** 播放出错（父组件弹提示 / 也要撤封面）。 */
  onError: () => void = (): void => {
  };
  /**
   * **真实视频尺寸**（prepared 那一刻从播放器读，w/h 都 > 0 才回调）。
   *
   * 为什么要它：接口给的宽高不一定是**视频**的（搜索推荐流那批 SearchPost 的宽高是
   * **封面图**的尺寸，见 model/Search 的说明）—— 16:9 的视频配上 4:5 的封面尺寸，
   * 画面盒子就是竖的，视频只能被拉伸或留大黑边。播放器自己知道真实尺寸，
   * 交给上层用来纠正盒子比例（见 ReelsPage 的 ReelSlide）。
   */
  onVideoSize: (w: number, h: number) => void = (w: number, h: number): void => {
  };

  /**
   * **这一颗播放器此刻该不该真的在播**：调用方说该播 + 没被全局冻住 + 自己是当前分段。
   * 只暂停、不销毁（销毁了就回到「黑一下」的老问题）。
   */
  private wantsPlay(): boolean {
    if (!this.playing || this.frozenAll) {
      return false;
    }
    if (this.segment >= 0 && this.segment !== this.activeSegment) {
      return false;
    }
    return true;
  }

  private readonly xController: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  private surfaceId: string = '';
  /** XComponent 的 onLoad 已经给过 surfaceId（播放器可能比它先到，所以两边都要兜）。 */
  private surfaceReady: boolean = false;
  /** 该播了但表面还没就绪：等 onLoad 补播（见 beginWhenSurfaceReady）。 */
  private pendingPlay: boolean = false;
  /** 表面没就绪时被挂起的 prepare，等 onLoad 补一次（表面必须早于 prepare，见 onState）。 */
  private pendingPrepare: boolean = false;
  private prepared: boolean = false;
  /** 组件已经消失（异步回调回来时不要再碰播放器）。 */
  private destroyed: boolean = false;
  /** 当前已经交给播放器的地址：换地址时要重新走一遍 setMediaSource。 */
  private loadedUrl: string = '';
  private firstFrameSent: boolean = false;
  private prepareStartedMs: number = 0;
  /** 最近一次调 play() 的时刻（用来算"切换起播"耗时，见 first frame 的日志）。 */
  private playRequestedMs: number = 0;
  /** createAVPlayer 还在飞（异步）：防止属性连续变化时创建出两个播放器。 */
  private creating: boolean = false;
  /** 当前这条地址已经设源几次（失败重试用，见 retrySource）。 */
  private urlAttempts: number = 0;
  /** 正在重试的那个地址（用来判断"换地址了、计数该归零"，见 applyUrl）。 */
  private attemptUrl: string = '';
  /**
   * 应用现在是不是前台。
   *
   * **为什么播放器要关心这件事**（真机量出来的）：以前它完全不管前后台 —— 用户按 Home 键
   * 回桌面之后，`playing` 还是 true，解码器接着解、表面接着出帧，进程**后台仍吃 69% CPU**，
   * 手机明显发烫。现在切后台就把播放器拆掉（`wanted()` 直接变 false → teardownPlayer），
   * 回前台再按同一个 `playing` 重建、接着播。
   */
  @State private appForeground: boolean = true;
  /** 前后台回调函数（销毁时要撤掉，见 AppLifecycle.removeVisibilityListener）。 */
  private visibilityHandler: VisibilityHandler = (foreground: boolean): void => {
    this.appForeground = foreground;
    // 重新走一遍"该建/该拆/该播/该停"那套判断（见 onPropChanged）。
    this.onPropChanged();
  };

  aboutToAppear(): void {
    this.destroyed = false;
    this.appForeground = AppLifecycle.isForeground();
    AppLifecycle.addVisibilityListener(this.visibilityHandler);
    if (this.wanted()) {
      this.createPlayer();
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    AppLifecycle.removeVisibilityListener(this.visibilityHandler);
    this.teardownPlayer();
  }

  /** 现在需不需要播放器（只播的那条 + 预加载的下一条才建，别让缓存区里每条都占一个解码器）。 */
  private wanted(): boolean {
    if (!this.appForeground) {
      // 后台一律不占解码器（见 appForeground 的说明）。
      return false;
    }
    return this.url.length > 0 && (this.playing || this.preload);
  }

  /** 建播放器并挂状态机；策略在 setMediaSource 时就带上（那是最早能带的时机）。 */
  private createPlayer(): void {
    if (this.player !== null || this.creating || this.destroyed || !this.wanted()) {
      return;
    }
    this.creating = true;
    media.createAVPlayer().then((player: media.AVPlayer): void => {
      this.creating = false;
      // 等播放器创出来的这段时间里，属性可能已经变了（用户滑走了）：那就当场释放，
      // 不要留下一个没人管的播放器（它会自己去缓冲，占带宽还占解码器）。
      if (this.destroyed || !this.wanted()) {
        try {
          player.release();
        } catch (error) {
        }
        return;
      }
      this.player = player;
      player.on('stateChange', (state: string): void => {
        this.onState(state);
      });
      player.on('error', (error: BusinessError): void => {
        this.reportError(`player error code=${error.code} msg=${error.message}`);
      });
      /*
       * **真实视频尺寸**（见 onVideoSize 的说明）。
       *
       * 不能用 `player.videoWidth/videoHeight` —— 这个版本的 `AVPlayer` 没有那两个属性，
       * 尺寸只在 `videoSizeChange` 事件里给；事件可能早于 prepared，所以在这里注册。
       */
      player.on('videoSizeChange', (width: number, height: number): void => {
        try {
          if (width > 0 && height > 0) {
            this.onVideoSize(width, height);
          }
        } catch (error) {
        }
      });
      this.applyUrl();
    }).catch((error: BusinessError): void => {
      this.creating = false;
      this.reportError(`createAVPlayer failed code=${error.code} msg=${error.message}`);
    });
  }

  /**
   * 播放出错。
   *
   * **只有"用户正在看的这条"才往上抛**：预加载的下一条失败不该弹提示 —— 用户根本没在看它，
   * 弹了只会让人以为"这个 app 播不了视频"（实际那条真正播的那条好好的）。
   * 记日志一律记（含错误码），否则线上没法查。
   */
  private reportError(detail: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s url=%{public}s playing=%{public}s',
      detail, this.shortUrl(), this.playing ? 'y' : 'n');
    if (this.wantsPlay()) {
      this.onError();
    }
  }

  /** 释放播放器（组件消失、或这条已经不需要播/预加载了）。 */
  private teardownPlayer(): void {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    this.prepared = false;
    this.pendingPlay = false;
    this.pendingPrepare = false;
    this.loadedUrl = '';
    this.attemptUrl = '';
    this.urlAttempts = 0;
    this.firstFrameSent = false;
    if (player === null) {
      return;
    }
    try {
      player.off('stateChange');
      player.off('error');
      player.release();
    } catch (error) {
    }
  }

  /** 状态机：initialized 挂表面（没表面就把 prepare 挂起）；prepared 校正缩放/循环并按需起播。 */
  private onState(state: string): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (state === 'initialized') {
      // 有表面就先挂上；**没有表面则把 prepare 挂起**（等 onLoad 补一次）。
      //
      // 为什么不能"先 prepare、表面后到"：实测真机上，对一个 prepare 时没有表面的播放器再设
      // surfaceId 会被拒：`5400102 Operate Not Permit: switch surface with no old surface`
      // —— "切换表面"这个动作要求它本来就有表面。所以表面必须先于 prepare 就位。
      // （曾试过让预加载不等表面，结果是换页时先报一次错、画面要等 3 秒才出来，回退。）
      //
      // 那预加载靠什么提前？靠**播放器建出来就 setMediaSource**（见 createPlayer → applyUrl）：
      // 那一步本身就会预下载媒体数据（官方接口说明："流媒体预下载资源设置…预先下载部分媒体数据"），
      // 表面一到位就能很快 prepare。feeds 里下一条卡片本来就被布局出来（cachedCount），
      // 所以它是真正的"提前 prepare"；reels 里下一条页面要等滑进可视区才有 Surface，能提前的就是这段预下载。
      this.tryBindSurface();
      if (this.surfaceId.length === 0) {
        this.pendingPrepare = true;
        hilog.info(DOMAIN, TAG, 'waiting for surface before prepare url=%{public}s', this.shortUrl());
        return;
      }
      this.doStrategyAndPrepare();
    } else if (state === 'prepared') {
      this.prepared = true;
      this.applyRenderOptions();
      hilog.info(DOMAIN, TAG, 'prepared in %{public}dms surface=%{public}s url=%{public}s',
        Date.now() - this.prepareStartedMs, this.surfaceReady ? 'y' : 'n', this.shortUrl());
      if (this.wantsPlay()) {
        this.beginWhenSurfaceReady();
      }
    } else if (state === 'playing') {
      // playing 才是"画面真的在动了"的可靠时刻（prepared 只是准备完成）。
      if (!this.firstFrameSent) {
        this.firstFrameSent = true;
        // 两个口径都记：prepare→首帧（这条视频要多久才可用）和 play→首帧（用户滑动切换要等多久）。
        // 官方短视频指标只算后者（≤230ms），所以后者才是"切换快不快"的证据；前者里包含
        // "预加载期间静静准备"的那段时间，别拿它当切换耗时。
        const now: number = Date.now();
        hilog.info(DOMAIN, TAG, 'first frame play+%{public}dms prepare+%{public}dms url=%{public}s',
          this.playRequestedMs > 0 ? now - this.playRequestedMs : -1,
          now - this.prepareStartedMs, this.shortUrl());
        this.onFirstFrame();
      }
    } else if (state === 'paused' || state === 'stopped' || state === 'completed') {
      // 播放中被暂停（如被别的播放器抢占）、或播完：还想播就接着播（feeds/reels 都是循环短视频）。
      if (this.wantsPlay()) {
        this.beginWhenSurfaceReady();
      }
    }
  }

  /**
   * 该播了：表面在就播，不在就等表面（并把等的这件事记下来，见 onSurfaceReady）。
   *
   * 为什么要等：没有渲染目标时 play() 进不了 playing，画面也出不来 —— 用户看到的就是"卡住"。
   * 但等的是"播"这一下，不是"prepare"（prepare 早就在预加载阶段做完了）。
   */
  private beginWhenSurfaceReady(): void {
    if (!this.prepared) {
      return;
    }
    if (this.surfaceReady) {
      this.startPlayback();
      return;
    }
    this.pendingPlay = true;
    hilog.info(DOMAIN, TAG, 'waiting for surface before play url=%{public}s', this.shortUrl());
  }

  /** loop 与缩放模式只能在 prepared 及之后设（接口文档明写），所以放这一刻。 */
  private applyRenderOptions(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    try {
      player.loop = true;
      player.videoScaleType = this.cover
        ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
        : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      // 静音：音量 0（不用 audioInterruptMode —— 那是"让不让别人抢"的语义，不是静音）。
      player.setVolume(this.muted ? 0 : 1);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'applyRenderOptions failed');
    }
  }

  /** 预下载缓冲固定 2 秒（见 BUFFER_TOTAL_SEC）；不再按网络类型分档，避免"省流量把体验也省掉"。 */
  private bufferSeconds(): number {
    return BUFFER_TOTAL_SEC;
  }

  /** 起播缓冲 1 秒 + prepare 阶段解首帧 —— 这两条就是"没有黑闪 + 起播快"的关键。 */
  private doStrategyAndPrepare(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const strategy: media.PlaybackStrategy = {
      preferredBufferDurationForPlaying: BUFFER_FOR_PLAYING_SEC,
      preferredBufferDuration: this.bufferSeconds(),
      showFirstFrameOnPrepare: true
    };
    this.prepareStartedMs = Date.now();
    // 策略必须在 prepare 之前生效，所以先设策略再 prepare；这一步同样可能返回 undefined
    // （见 watchPromise 的说明），拿不到 then 也要照常 prepare，否则这条视频就永远不会起播。
    let applied: Promise<void> | undefined = undefined;
    try {
      applied = player.setPlaybackStrategy(strategy);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'setPlaybackStrategy threw url=%{public}s', this.shortUrl());
    }
    if (applied === undefined || applied === null) {
      this.prepareNow();
      return;
    }
    applied.then((): void => {
      this.prepareNow();
    }).catch((error: BusinessError): void => {
      // 策略没设上不是致命的（只是少了"首帧预解"），照样 prepare，别让视频卡在初始化。
      hilog.warn(DOMAIN, TAG, 'setPlaybackStrategy failed code=%{public}d', error.code);
      this.prepareNow();
    });
  }

  /** 真正调 prepare（来源已设好、表面已挂上）。 */
  private prepareNow(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.destroyed) {
      return;
    }
    this.watchPromise(player.prepare(), (error: BusinessError): void => {
      this.reportError(`prepare failed code=${error.code} msg=${error.message}`);
    });
  }

  /** playing / preload / url / cover 变了：重新评估该不该建播放器、该不该播。 */
  private onPropChanged(): void {
    if (!this.wanted()) {
      // 不再是"该播/该预加载"的这条：把解码器还回去（滚动时最常走这条路）。
      this.teardownPlayer();
      return;
    }
    if (this.player === null) {
      this.createPlayer();
      return;
    }
    this.applyUrl();
    if (!this.prepared) {
      return;
    }
    this.applyRenderOptions();
    if (this.wantsPlay()) {
      this.beginWhenSurfaceReady();
    } else {
      this.pausePlayback();
    }
  }

  private pausePlayback(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    try {
      player.pause();
    } catch (error) {
    }
  }

  /** 把 surfaceId 交给播放器（XComponent 与播放器谁先到都得兜住）。 */
  private tryBindSurface(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.surfaceId.length === 0) {
      return;
    }
    try {
      player.surfaceId = this.surfaceId;
      this.surfaceReady = true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'bind surface failed');
    }
  }

  /**
   * XComponent 就绪后的收尾。
   *
   * 两件事：把 surfaceId 挂上去；把"因为没表面而等着"的 prepare / play 补上。
   */
  private onSurfaceReady(): void {
    this.tryBindSurface();
    if (this.pendingPrepare && this.surfaceReady && !this.prepared) {
      this.pendingPrepare = false;
      hilog.info(DOMAIN, TAG, 'surface ready, preparing url=%{public}s', this.shortUrl());
      this.doStrategyAndPrepare();
    }
    if (this.pendingPlay && this.prepared) {
      this.pendingPlay = false;
      hilog.info(DOMAIN, TAG, 'surface ready, playing url=%{public}s', this.shortUrl());
      this.startPlayback();
    }
  }

  private startPlayback(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || !this.prepared) {
      return;
    }
    this.playRequestedMs = Date.now();
    this.watchPromise(player.play(), (error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'play failed: %{public}s', error.message);
    });
  }

  /** 地址变了（列表复用同一组件实例时必须重新设源）。setMediaSource 只允许 idle 调。 */
  private applyUrl(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.url.length === 0 || this.url === this.loadedUrl) {
      return;
    }
    // 换了新地址就重置重试计数；同一条地址的重试不算"新地址"（retrySource 会清掉 loadedUrl 再进来）。
    if (this.url !== this.attemptUrl) {
      this.attemptUrl = this.url;
      this.urlAttempts = 0;
    }
    this.loadedUrl = this.url;
    this.prepared = false;
    this.firstFrameSent = false;
    this.playRequestedMs = 0;
    const strategy: media.PlaybackStrategy = {
      preferredBufferDurationForPlaying: BUFFER_FOR_PLAYING_SEC,
      preferredBufferDuration: this.bufferSeconds(),
      showFirstFrameOnPrepare: true
    };
    try {
      const source: media.MediaSource = media.createMediaSourceWithUrl(this.url, {});
      // 注意：实测这一版实现在**成功时返回 undefined**（接口声明是 Promise<void>）——
      // 直接 `.catch()` 会抛 "Cannot read property catch of undefined"，而且会被误当成"设源失败"。
      // 所以统一走 watchPromise：拿不到 promise 就只靠 stateChange 看结果。
      this.watchPromise(player.setMediaSource(source, strategy), (error: BusinessError): void => {
        this.retrySource(`setMediaSource failed code=${error.code} msg=${error.message}`);
      });
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      this.retrySource(`setMediaSource threw code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 盯一个"可能不存在"的 promise。
   *
   * 见上面 setMediaSource 的注释：ArkTS 里部分 media 接口在成功路径上并不返回 promise（返回 undefined），
   * 所以不能无脑 `.catch`。拿不到就什么都不做 —— 结果由 stateChange / on('error') 告诉我们要不要处理。
   */
  private watchPromise(promise: Promise<void> | undefined, onFail: (error: BusinessError) => void): void {
    if (promise === undefined || promise === null) {
      return;
    }
    promise.catch((error: BusinessError): void => {
      onFail(error);
    });
  }

  /**
   * 设源失败后的重试。
   *
   * 为什么值得单独一条路：实测里"同步抛"之后紧接着的同一 URL 是能 prepare 成功的
   * （多半是那一拍播放器状态还没落定），所以重试 1 次就能救回来；不重试的话这条视频
   * 就只剩封面 + 一条"播放失败"提示。重试有上限，避免真坏的地址无限重试。
   */
  private retrySource(detail: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s url=%{public}s', detail, this.shortUrl());
    this.loadedUrl = '';
    if (this.urlAttempts >= SOURCE_RETRY_MAX || !this.wanted() || this.destroyed) {
      this.reportError(detail);
      return;
    }
    this.urlAttempts++;
    setTimeout((): void => {
      if (this.destroyed || !this.wanted() || this.prepared) {
        return;
      }
      this.applyUrl();
    }, SOURCE_RETRY_MS);
  }

  private shortUrl(): string {
    return this.url.length > 60 ? this.url.substring(this.url.length - 60) : this.url;
  }

  build() {
    // 表面一直留着（哪怕这一拍不需要播）：surface 本身很便宜，留着可以让 surfaceId 稳定复用，
    // 换来的是"轮到它播时不用等 onLoad"。播放器是否创建由 wanted() 决定。
    XComponent({
      id: 'videoSurface',
      type: XComponentType.SURFACE,
      libraryname: '',
      controller: this.xController
    })
      .width('100%')
      .height('100%')
      .onLoad((): void => {
        try {
          this.surfaceId = this.xController.getXComponentSurfaceId();
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'getXComponentSurfaceId failed');
        }
        this.onSurfaceReady();
      })
      .onDestroy((): void => {
        // 表面被系统回收（比如整层被移出渲染树）：下次 onLoad 会给新 id。
        this.surfaceId = '';
        this.surfaceReady = false;
      })
  }
}
