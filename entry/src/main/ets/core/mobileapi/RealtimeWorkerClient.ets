/*
 * **实时通道的主线程门面**：把 MQTToT 的活交给 Worker（见 workers/RealtimeWorker）。
 *
 * ## 它做什么
 *   · `start()`：主线程这边只做两件轻活 —— 从 `MobileSession` 拿身份、拍平成纯数据传进 Worker；
 *   · `stop()` / `status()`：转发指令；
 *   · `publish(topic, json)`：订阅（134 iris）与指令（132）都走它；
 *   · `onFrame(handler)`：Worker 解压 + 转成字符串之后，把 `{topic, text, size}` 回给主线程。
 *
 * ## 为什么门面要留一份"和 MobileRealtime 同形"的 API
 * 现在主链路用的还是主线程那版 `MobileRealtime`（见 core/mobileapi/MobileRealtime）；
 * 这一版是**替代品**，接口对齐是为了切换时只改一处调用点（pages/Index），
 * 也方便两边对照日志。切换开关见 pages/Index 的 `USE_REALTIME_WORKER`。
 *
 * ## 线程边界
 * Worker 不许碰 UI / AppStorage / 单例；所以主线程这边负责**所有**会话相关的取数，
 * 只把"能序列化的东西"过线（identity 的 6 个字段、topic、json 字符串）。
 */

import { worker, ErrorEvent, MessageEvents } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MobileSession, MobileIdentity } from './MobileSession';
import { MqttIdentity } from './MobileMqtt';
import { WorkerCommand, WorkerEvent, WorkerIdentity } from './RealtimeProtocol';

const DOMAIN: number = 0xFF00;
const TAG: string = 'RealtimeWorker';
/** Worker 的入口路径（相对模块的 `src/main`：模块名 + ets 下的路径）。 */
const WORKER_PATH: string = 'entry/ets/workers/RealtimeWorker.ets';
const KEEP_ALIVE_S: number = 20;
/** 等 Worker 报"连上了"的上限（毫秒）：TLS + CONNACK 实测 200ms 级，给足弱网余量。 */
const READY_WAIT_MS: number = 12000;
/**
 * 掉线重连的退避（毫秒）。第 n 次用它，超出取最后一档。
 *
 * 为什么要退避：弱网下马上重连只会连着失败，把线程和 IG 的尝试次数一起烧掉。
 */
const BACKOFF_MS: Array<number> = [1000, 3000, 8000, 20000, 30000];

/** Worker 回传的一帧（已经解压成字符串）。 */
export class RealtimeFrame {
  readonly topic: string;
  readonly text: string;
  readonly size: number;
  readonly seq: number;

  constructor(topic: string, text: string, size: number, seq: number) {
    this.topic = topic;
    this.text = text;
    this.size = size;
    this.seq = seq;
  }
}

export class RealtimeWorkerClient {
  private static instance: RealtimeWorkerClient | null = null;
  private port: worker.ThreadWorker | null = null;
  private up: boolean = false;
  private lastError: string = '';
  private frames: number = 0;
  /** 是否"应该保持连接"（false = 被 stop() 主动停掉，不再自动重连）。 */
  private wanted: boolean = false;
  /** 并发 start 的单飞（见 start）。 */
  private startInFlight: Promise<boolean> | null = null;
  /** 重连定时器 / 已经重试几次（退避用）。 */
  private reconnectTimer: number = 0;
  private attempts: number = 0;
  private frameHandler: (frame: RealtimeFrame) => void = (frame: RealtimeFrame): void => {
  };
  /** `start()` 里等 Worker 回报时的兑现函数（null = 没人在等）。 */
  private readyResolve: ((up: boolean) => void) | null = null;

  static getInstance(): RealtimeWorkerClient {
    if (RealtimeWorkerClient.instance === null) {
      RealtimeWorkerClient.instance = new RealtimeWorkerClient();
    }
    return RealtimeWorkerClient.instance;
  }

  /** 收到一帧（主线程回调；在 Worker 解压之后）。 */
  onFrame(handler: (frame: RealtimeFrame) => void): void {
    this.frameHandler = handler;
  }

  /** 现在连没连上（同步）。 */
  isUp(): boolean {
    return this.up;
  }

  status(): string {
    return `worker up=${this.up} frames=${this.frames} err=${this.lastError}`;
  }

  /**
   * 启动（幂等）：已经有 Worker 就直接报当前状态。
   *
   * 注意：**并发调用只会建一个 Worker**（`startInFlight`），否则两个 ThreadWorker 里
   * 有一个永远不会 terminate（审计发现的泄漏）。
   *
   * @returns 是否在 `READY_WAIT_MS` 内等到 CONNACK
   */
  async start(): Promise<boolean> {
    this.wanted = true;
    if (this.port !== null) {
      return this.up;
    }
    const running: Promise<boolean> | null = this.startInFlight;
    if (running !== null) {
      return running;
    }
    const task: Promise<boolean> = this.spawn();
    this.startInFlight = task;
    try {
      return await task;
    } finally {
      this.startInFlight = null;
    }
  }

  /** 真正建 Worker 并等 CONNACK（只被 start 调）。 */
  private async spawn(): Promise<boolean> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || !identity.isComplete()) {
      this.lastError = 'no-session';
      hilog.info(DOMAIN, TAG, 'worker start skipped: no mobile session');
      return false;
    }
    const plain: MqttIdentity = RealtimeWorkerClient.plainIdentity(identity);
    try {
      const port: worker.ThreadWorker = new worker.ThreadWorker(WORKER_PATH);
      this.port = port;
      port.onmessage = (event: MessageEvents): void => {
        this.onMessage(event);
      };
      port.onerror = (error: ErrorEvent): void => {
        this.lastError = `worker: ${error.message ?? 'unknown'}`;
        hilog.warn(DOMAIN, TAG, 'worker error: %{public}s', this.lastError);
        this.up = false;
        /*
         * **必须把 port 也清掉**：只置 up=false 的话，下次 start() 会看到 port 非空直接返回 false，
         * 这个 Worker 线程就永远闲在那儿（线程 + 它的 TLS 都泄漏）。
         */
        this.dropPort();
        this.onDown('worker-error');
      };
      port.postMessage(RealtimeWorkerClient.startCommand(plain));
      hilog.info(DOMAIN, TAG, 'worker started, waiting connack (user=%{public}s)',
        plain.userId);
      this.attempts = 0;
      return await this.waitReady(READY_WAIT_MS);
    } catch (error) {
      this.lastError = `spawn: ${(error as Error).message ?? 'unknown'}`;
      hilog.warn(DOMAIN, TAG, 'worker spawn failed: %{public}s', this.lastError);
      this.dropPort();
      this.onDown('spawn-failed');
      return false;
    }
  }

  /**
   * **掉线后自己重连**（审计：Worker 版原来完全没有重连，断一次就永久静默）。
   *
   * 策略：`wanted` 为真时按 `BACKOFF_MS` 退避重建 Worker（新 Worker = 新 socket + 新心跳，
   * 比在旧线程里救更干净）。`stop()` 会把 `wanted` 置假，于是不再重连。
   */
  private onDown(why: string): void {
    this.up = false;
    if (!this.wanted || this.reconnectTimer !== 0) {
      return;
    }
    const delay: number = BACKOFF_MS[Math.min(this.attempts, BACKOFF_MS.length - 1)];
    this.attempts++;
    hilog.info(DOMAIN, TAG, 'worker down (%{public}s) → reconnect in %{public}dms (#%{public}d)',
      why, delay, this.attempts);
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = 0;
      if (!this.wanted) {
        return;
      }
      this.dropPort();
      this.start().catch((): void => {
      });
    }, delay);
  }

  /** 把 Worker 收掉（不 terminate 会留下线程与它的 TLS）。 */
  private dropPort(): void {
    const port: worker.ThreadWorker | null = this.port;
    this.port = null;
    this.up = false;
    if (port === null) {
      return;
    }
    try {
      port.postMessage(RealtimeWorkerClient.simpleCommand('stop'));
      port.terminate();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'worker drop failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 断开并回收 Worker（下次 start 会新建一条）。
   *
   * **谁调它**：换账号 / 退出登录（见 pages/Index.forgetAccountMemory）。
   * 审计发现的 P0：以前全仓没有任何调用点，于是换号之后旧 Worker 带着**上一个账号的 sessionid**
   * 继续收私信并派发到新账号的界面。
   */
  stop(): void {
    this.wanted = false;
    this.attempts = 0;
    if (this.reconnectTimer !== 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = 0;
    }
    this.dropPort();
    hilog.info(DOMAIN, TAG, 'worker stopped (frames=%{public}d)', this.frames);
  }

  /** 发一条 JSON（topic 134 = 私信同步订阅；132 = 私信指令）。 */
  publish(topic: string, json: string): boolean {
    const port: worker.ThreadWorker | null = this.port;
    if (port === null || !this.up) {
      return false;
    }
    try {
      const cmd: WorkerCommand = RealtimeWorkerClient.simpleCommand('publish');
      cmd.topic = topic;
      cmd.json = json;
      port.postMessage(cmd);
      return true;
    } catch (error) {
      this.lastError = `publish: ${(error as Error).message ?? 'unknown'}`;
      return false;
    }
  }

  /** 组一条只有 cmd 的指令。 */
  private static simpleCommand(cmd: string): WorkerCommand {
    const one: WorkerCommand = new WorkerCommand();
    one.cmd = cmd;
    return one;
  }

  /** 组 start 指令（身份是纯数据，可以跨线程）。 */
  private static startCommand(identity: MqttIdentity): WorkerCommand {
    const one: WorkerCommand = new WorkerCommand();
    one.cmd = 'start';
    one.keepAlive = KEEP_ALIVE_S;
    const info: WorkerIdentity = new WorkerIdentity();
    info.phoneId = identity.phoneId;
    info.userId = identity.userId;
    info.userAgent = identity.userAgent;
    info.appVersion = identity.appVersion;
    info.locale = identity.locale;
    info.sessionId = identity.sessionId;
    one.identity = info;
    return one;
  }

  private waitReady(timeoutMs: number): Promise<boolean> {
    if (this.up) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (up: boolean) => void): void => {
      this.readyResolve = resolve;
      setTimeout((): void => {
        if (this.readyResolve === resolve) {
          this.readyResolve = null;
          resolve(this.up);
        }
      }, timeoutMs);
    });
  }

  /** Worker 的消息全在这里分流（只有三类：state / log / frame）。 */
  private onMessage(event: MessageEvents): void {
    const data: WorkerEvent = event.data as WorkerEvent;
    const type: string = `${data.type ?? ''}`;
    if (type === 'state') {
      const up: boolean = data.up === true;
      this.up = up;
      const detail: string = `${data.detail ?? ''}`;
      hilog.info(DOMAIN, TAG, 'worker state up=%{public}s %{public}s', `${up}`, detail);
      const resolve: ((up: boolean) => void) | null = this.readyResolve;
      if (resolve !== null) {
        this.readyResolve = null;
        resolve(up);
      }
      /*
       * **掉线自愈**：Worker 内部没有重连（它只负责一条连接的生命周期），
       * 策略放在这一层 —— 只要还"想要连着"，就退避重建。
       * 注意 `already-connected` 那种重复上报不算掉线。
       */
      if (!up && detail.indexOf('already-connected') < 0) {
        this.onDown(detail);
      }
      return;
    }
    if (type === 'log') {
      hilog.info(DOMAIN, TAG, 'worker: %{public}s', `${data.text ?? ''}`);
      return;
    }
    if (type === 'frame') {
      this.frames++;
      const frame: RealtimeFrame = new RealtimeFrame(`${data.topic ?? ''}`,
        `${data.body ?? ''}`, Number(data.size ?? 0), Number(data.seq ?? 0));
      hilog.info(DOMAIN, TAG, 'frame #%{public}d topic=%{public}s size=%{public}d',
        frame.seq, frame.topic, frame.size);
      this.frameHandler(frame);
    }
  }

  private static plainIdentity(identity: MobileIdentity): MqttIdentity {
    return new MqttIdentity(identity.phoneId, identity.userId, identity.userAgent(),
      identity.app.appVersion, identity.locale, identity.sessionId);
  }
}
