/*
 * **实时通道的跨线程消息契约**（主线程 ↔ RealtimeWorker）。
 *
 * ArkTS 禁止"无类型的对象字面量"（`arkts-no-untyped-obj-literals`），跨线程 `postMessage`
 * 又不能传带方法的实例。所以这里用**纯字段的 class** 定死两类消息的形状：
 *   · `WorkerCommand`：主线程 → Worker（start / stop / publish）；
 *   · `WorkerEvent`：Worker → 主线程（state / log / frame）。
 * 两边各自 new 一个再传，字段缺省值保证"没给的就是空/零"，读的时候不用判空。
 */

/** 组 CONNECT 需要的身份（纯数据，见 MobileMqtt.identityOf）。 */
export class WorkerIdentity {
  phoneId: string = '';
  userId: string = '';
  userAgent: string = '';
  appVersion: string = '';
  locale: string = '';
  sessionId: string = '';
}

/** 主线程 → Worker 的指令。 */
export class WorkerCommand {
  /** `start` / `stop` / `publish` / `status`。 */
  cmd: string = '';
  /** 心跳秒数（只有 start 用）。 */
  keepAlive: number = 20;
  /** 身份（只有 start 用）。 */
  identity: WorkerIdentity = new WorkerIdentity();
  /** 目标 topic（只有 publish 用）。 */
  topic: string = '';
  /** 要发出去的 JSON 文本（只有 publish 用）。 */
  json: string = '';
}

/** Worker → 主线程的事件。 */
export class WorkerEvent {
  /** `state`（连接状态变化）/ `log`（一行日志）/ `frame`（一条已解压的实时帧）。 */
  type: string = '';
  /** state 用：现在连没连上。 */
  up: boolean = false;
  /** state / log 用：给人和排查看的说明。 */
  detail: string = '';
  /** log 用：日志正文。 */
  text: string = '';
  /** frame 用：topic / 原始字节数 / 已解压的文本 / 序号。 */
  topic: string = '';
  size: number = 0;
  body: string = '';
  seq: number = 0;

  static state(up: boolean, detail: string): WorkerEvent {
    const one: WorkerEvent = new WorkerEvent();
    one.type = 'state';
    one.up = up;
    one.detail = detail;
    return one;
  }

  static log(text: string): WorkerEvent {
    const one: WorkerEvent = new WorkerEvent();
    one.type = 'log';
    one.text = text;
    return one;
  }

  static frame(topic: string, size: number, body: string, seq: number): WorkerEvent {
    const one: WorkerEvent = new WorkerEvent();
    one.type = 'frame';
    one.topic = topic;
    one.size = size;
    one.body = body;
    one.seq = seq;
    return one;
  }
}
