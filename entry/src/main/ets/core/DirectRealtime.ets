/*
 * **实时私信的分发层**：把 MQTToT 推过来的 `message_sync` 补丁变成"某条会话又多了条消息"。
 *
 * ## 现在解决什么问题
 * 实时通道（core/mobileapi/MobileRealtime）已经能收包了，但收到 `message_sync`（topic 146）
 * 之后只做了一件事：让收件箱**静默刷新**一次。那意味着"新消息到了"这件事仍然要等一次 HTTP
 * 往返（30KB 起）才看得见 —— 所谓"实时"只实时到了"知道该刷新了"。
 * 这一层把补丁**直接解析成一条消息**，交给正在看的那条会话插进去：不请求、不缓存。
 *
 * ## 补丁长什么样（instagrapi 的 `dispatch_message_sync`）
 * topic 146 的载荷是一个数组，每项形如
 *
 *     {"data": [{"path": "/direct_v2/threads/<tid>/items/<iid>/", "op": "add",
 *                "value": "<JSON 字符串 或 对象>"}]}
 *
 * 所以这里做三件事：递归找出所有 `{path, value}` 补丁 → 从 path 里拆出 `thread_id` /
 * `item_id` → 把 value 当"一条 item"喂给 `DirectMapper.messageFromItem`。
 *
 * **防御性**：`value` 有时是字符串套 JSON、有时是对象；path 也可能是线程级更新
 * （已读、改名）而不是消息 —— 后者一律只上报"这条会话变了"，交给收件箱去刷新。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { DirectMessage, DirectMapper } from '../model/Direct';
import { JsonRead } from './JsonRead';
import { RealtimeEvent } from './mobileapi/MobileRealtime';
import { MobileSession } from './mobileapi/MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectRealtime';

/** 会带私信补丁的三个 topic（146 message_sync / 149 realtime sub / 88 pubsub）。 */
const RELEVANT_TOPICS: Array<string> = ['146', '149', '88'];
/** 递归找补丁时的深度上限（载荷本来就浅，只是防脏数据）。 */
const MAX_DEPTH: number = 8;

/** 一条实时推来的消息（带它属于哪条会话）。 */
export class RealtimeMessage {
  readonly threadId: string;
  readonly message: DirectMessage;

  constructor(threadId: string, message: DirectMessage) {
    this.threadId = threadId;
    this.message = message;
  }
}

export class DirectRealtime {
  /** 收到"新消息"的回调（当前开着的会话据此即时插入）。 */
  private static messageHandlers: Array<(incoming: RealtimeMessage) => void> = [];
  /** 收到"某条会话有别的变化"（已读/改名/加人）的回调 —— 列表据此刷新。 */
  private static threadHandlers: Array<(threadId: string) => void> = [];
  /** 自己的 user id（判断气泡左右；懒加载一次）。 */
  private static ownId: string = '';
  /** 累计解析出多少条消息（诊断用）。 */
  private static messageCount: number = 0;
  /** 累计看到多少条"非消息"补丁（诊断用）。 */
  private static updateCount: number = 0;

  static onMessage(handler: (incoming: RealtimeMessage) => void): void {
    DirectRealtime.messageHandlers.push(handler);
  }

  static onThreadChange(handler: (threadId: string) => void): void {
    DirectRealtime.threadHandlers.push(handler);
  }

  /**
   * **换账号 / 退出登录时清干净**（见 pages/Index.forgetAccountMemory）。
   *
   * 要清 `ownId` 的原因：它决定"这条消息是不是我发的"（气泡左右）。不清的话换了账号之后，
   * 上一个人的 id 还留着，新账号发给自己的消息会被判成"别人发的"。
   * 派发回调（handlers）**不清** —— 那是页面注册的，页面还活着。
   */
  static clearAccount(): void {
    DirectRealtime.ownId = '';
    DirectRealtime.messageCount = 0;
    DirectRealtime.updateCount = 0;
    hilog.info(DOMAIN, TAG, 'direct realtime account state cleared');
  }

  /** 一行诊断（`messages` 是"真的解析出新消息"的条数）。 */
  static describe(): string {
    return `messages=${DirectRealtime.messageCount} updates=${DirectRealtime.updateCount}`;
  }

  /** 处理一条实时事件（Index 把 MobileRealtime 的每个事件都丢进来）。 */
  static handle(event: RealtimeEvent): void {
    if (RELEVANT_TOPICS.indexOf(event.topic) < 0) {
      return;
    }
    DirectRealtime.handleAsync(event).catch((): void => {
    });
  }

  private static async handleAsync(event: RealtimeEvent): Promise<void> {
    let root: Object | null = null;
    try {
      root = JSON.parse(event.text) as Object;
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'topic=%{public}s not json len=%{public}d',
        event.topic, event.text.length);
      return;
    }
    const patches: Array<Record<string, Object>> = [];
    DirectRealtime.walk(root, 0, patches);
    if (patches.length === 0) {
      return;
    }
    const own: string = await DirectRealtime.ownIdNow();
    for (let index: number = 0; index < patches.length; index++) {
      DirectRealtime.applyPatch(patches[index], own);
    }
  }

  /** 处理一条 `{path, value}` 补丁。 */
  private static applyPatch(patch: Record<string, Object>, own: string): void {
    const path: string = JsonRead.strOf(patch, 'path');
    if (path.length === 0) {
      return;
    }
    const threadId: string = DirectRealtime.threadIdOf(path);
    if (threadId.length === 0) {
      return;
    }
    const value: Record<string, Object> | null = DirectRealtime.recordOfValue(patch);
    if (value === null) {
      DirectRealtime.emitThread(threadId);
      return;
    }
    // item_id 可能只出现在 path 里（`…/items/<iid>/…`）：补进 value 再映射。
    if (JsonRead.strOf(value, 'item_id').length === 0) {
      const itemId: string = DirectRealtime.itemIdOf(path);
      if (itemId.length > 0) {
        value['item_id'] = itemId;
      }
    }
    const message: DirectMessage | null = DirectMapper.messageFromItem(value, own);
    if (message === null) {
      // 已读回执 / 改名 / 加人这类：不是消息，只上报"这条会话变了"。
      DirectRealtime.updateCount++;
      hilog.info(DOMAIN, TAG, 'thread update thread=%{public}d path=%{public}s',
        threadId.length, path.substring(0, 60));
      DirectRealtime.emitThread(threadId);
      return;
    }
    DirectRealtime.messageCount++;
    hilog.info(DOMAIN, TAG, 'live message #%{public}d thread=%{public}d id=%{public}d kind=%{public}s text=%{public}s',
      DirectRealtime.messageCount, threadId.length, message.id.length, message.kind,
      message.text.substring(0, 60));
    const incoming: RealtimeMessage = new RealtimeMessage(threadId, message);
    for (let index: number = 0; index < DirectRealtime.messageHandlers.length; index++) {
      try {
        DirectRealtime.messageHandlers[index](incoming);
      } catch (error) {
      }
    }
  }

  private static emitThread(threadId: string): void {
    for (let index: number = 0; index < DirectRealtime.threadHandlers.length; index++) {
      try {
        DirectRealtime.threadHandlers[index](threadId);
      } catch (error) {
      }
    }
  }

  /**
   * 递归把载荷里的 `{path, value}` 补丁全找出来。
   *
   * 三种形状都要认（IG 在不同 topic 上混着用）：
   *   · 数组（topic 146 顶层就是数组）；
   *   · `{data: [...]}` / `{message: ...}` / `{json: ...}` / `{payload: ...}` 这类包装；
   *   · `value` / `json` 是**字符串套 JSON**。
   */
  private static walk(value: Object | null | undefined, depth: number,
                      out: Array<Record<string, Object>>): void {
    if (value === undefined || value === null || depth > MAX_DEPTH) {
      return;
    }
    if (Array.isArray(value)) {
      const list: Array<Object> = value as Array<Object>;
      for (let index: number = 0; index < list.length; index++) {
        DirectRealtime.walk(list[index], depth + 1, out);
      }
      return;
    }
    if (typeof value === 'string') {
      const text: string = value as string;
      const head: string = text.length > 0 ? text.charAt(0) : '';
      if (head === '{' || head === '[') {
        try {
          DirectRealtime.walk(JSON.parse(text) as Object, depth + 1, out);
        } catch (error) {
        }
      }
      return;
    }
    if (typeof value !== 'object') {
      return;
    }
    const record: Record<string, Object> = value as Record<string, Object>;
    if (JsonRead.strOf(record, 'path').length > 0) {
      out.push(record);
      return;
    }
    const keys: Array<string> = ['data', 'message', 'json', 'payload', 'value', 'patches'];
    for (let index: number = 0; index < keys.length; index++) {
      const child: Object | undefined = record[keys[index]];
      if (child !== undefined && child !== null) {
        DirectRealtime.walk(child, depth + 1, out);
      }
    }
  }

  /** 补丁的 `value` → 记录（字符串先尝试 JSON 解析）。 */
  private static recordOfValue(patch: Record<string, Object>): Record<string, Object> | null {
    const raw: Object | undefined = patch['value'];
    if (raw === undefined || raw === null) {
      return null;
    }
    if (typeof raw === 'string') {
      const text: string = raw as string;
      if (text.length === 0 || text.charAt(0) !== '{') {
        return null;
      }
      try {
        return JsonRead.asRecord(JSON.parse(text) as Object);
      } catch (error) {
        return null;
      }
    }
    return JsonRead.asRecord(raw);
  }

  /** 从 path 里拆 `thread_id`（`/direct_v2/threads/<tid>/…`）。 */
  private static threadIdOf(path: string): string {
    const marker: string = '/direct_v2/threads/';
    const at: number = path.indexOf(marker);
    if (at < 0) {
      return '';
    }
    const rest: string = path.substring(at + marker.length);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  /** 从 path 里拆 `item_id`（`…/items/<iid>/…`；不是消息补丁就给空串）。 */
  private static itemIdOf(path: string): string {
    const marker: string = '/items/';
    const at: number = path.indexOf(marker);
    if (at < 0) {
      return '';
    }
    const rest: string = path.substring(at + marker.length);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  /** 自己的 user id（懒加载：会话里的"是不是我发的"要用）。 */
  private static async ownIdNow(): Promise<string> {
    if (DirectRealtime.ownId.length > 0) {
      return DirectRealtime.ownId;
    }
    try {
      const identity = await MobileSession.getInstance().ensure();
      if (identity !== null) {
        DirectRealtime.ownId = identity.userId;
      }
    } catch (error) {
    }
    return DirectRealtime.ownId;
  }

  /**
   * **解析自检**：拿一段合成的 `message_sync` 补丁跑一遍，只打日志、**不派发**。
   *
   * 为什么需要它：真实补丁只在"别人给你发私信"时才来，而解析这条路上的形状（字符串套 JSON、
   * item_id 只在 path 里、topic 146 顶层是数组）每一条都可能写错 —— 手边不一定有真消息可等。
   * 位置和取值都是照着 instagrapi 的 `dispatch_message_sync` 造的样例。
   */
  static selfTest(): void {
    const sample: string = '[{"data":[{"path":"/direct_v2/threads/1234567890123/items/'
      + '9999888877776666/","op":"add","value":"{\\"item_id\\":\\"9999888877776666\\",'
      + '\\"item_type\\":\\"text\\",\\"text\\":\\"selftest\\",\\"user_id\\":\\"424242\\",'
      + '\\"timestamp\\":1700000000123456}"}]}]';
    let root: Object | null = null;
    try {
      root = JSON.parse(sample) as Object;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'selftest payload broken');
      return;
    }
    const patches: Array<Record<string, Object>> = [];
    DirectRealtime.walk(root, 0, patches);
    if (patches.length === 0) {
      hilog.warn(DOMAIN, TAG, 'selftest: no patch found');
      return;
    }
    const patch: Record<string, Object> = patches[0];
    const path: string = JsonRead.strOf(patch, 'path');
    const threadId: string = DirectRealtime.threadIdOf(path);
    const itemId: string = DirectRealtime.itemIdOf(path);
    const value: Record<string, Object> | null = DirectRealtime.recordOfValue(patch);
    const message: DirectMessage | null = value === null
      ? null : DirectMapper.messageFromItem(value, '');
    hilog.info(DOMAIN, TAG,
      'selftest patches=%{public}d thread=%{public}s item=%{public}s text=%{public}s kind=%{public}s mine=%{public}s',
      patches.length, threadId, itemId,
      message === null ? '-' : message.text,
      message === null ? '-' : message.kind,
      message === null ? '-' : `${message.mine}`);
  }
}
