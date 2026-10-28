/*
 * **设备级会话的实时通道（FBNS）**：把 `MobileFbnsClient` 接进 App 的私信/通知链路。
 *
 * 分工：
 *   · 网页会话（Cookie 罐里有 `sessionid`）→ 继续走 iris 的 `edge-mqtt`（见 Index.startRealtime）；
 *   · **设备级会话**（只有 `Authorization: Bearer IGT:2:…`）→ 走 FBNS（本文件）。
 *
 * 为什么要分两条：iris 那条是 `cookie_auth`，设备级会话没有 sessionid，连接会 `CONNACK rc=5`；
 * FBNS 是 `device_auth`，用两段式握手换到的设备凭据连接，实测可用（relay 早已验证）。
 *
 * 收到 topic 76 的推送后做两件事：
 *   1. 造一条 `message_sync`（topic 146）补丁喂给 `DirectRealtime` —— 开着的会话即时插入；
 *   2. 直接走 `PushCenter.notifyDirect` 弹本地通知（不依赖界面是否开着）。
 *
 * 注意 `push/register/` 那一步：FBNS 只负责把 token 要来，**必须把它交给 IG**（带设备级会话），
 * 之后 IG 才会把私信往这条连接推。relay 里这一步回 `{"status":"ok"}` 才算通路打开。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { PushCenter } from '../PushCenter';
import { DirectRealtime } from '../DirectRealtime';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileRequest, MobileResult } from './MobileRequest';
import { FBNS_PACKAGE } from './MobileFbns';
import { MobileFbnsClient } from './MobileFbnsClient';
import { RealtimeEvent } from './MobileRealtime';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileFbnsService';

export class MobileFbnsService {
  private static client: MobileFbnsClient | null = null;
  private static started: boolean = false;
  /** 最近一次拿到的 push token（诊断用；值本身不记日志）。 */
  private static tokenLength: number = 0;

  /** 当前是不是设备级会话（没有 sessionid）。 */
  static isDeviceLevel(identity: MobileIdentity): boolean {
    return identity.sessionId.length === 0 && identity.authorization.length > 0;
  }

  /**
   * 按当前会话决定要不要起 FBNS。
   *
   * @returns true = 已由 FBNS 接管实时（调用方不要再连 iris）
   */
  static async startFromSession(): Promise<boolean> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || !identity.isComplete()) {
      return false;
    }
    if (!MobileFbnsService.isDeviceLevel(identity)) {
      // 网页会话：iris 那条路还能用，别抢
      return false;
    }
    if (MobileFbnsService.started && MobileFbnsService.client !== null
      && MobileFbnsService.client.isUp()) {
      return true;
    }
    const clientId: string = identity.uuid.substring(0, 20);
    const client: MobileFbnsClient = new MobileFbnsClient(clientId);
    MobileFbnsService.client = client;
    hilog.info(DOMAIN, TAG, 'start fbns (uid=%{public}s)', identity.userId);
    const ok: boolean = await client.start(clientId,
      (token: string): void => {
        MobileFbnsService.tokenLength = token.length;
        MobileFbnsService.registerToken(token, identity).catch((): void => {
        });
      },
      (push: ESObject): void => {
        MobileFbnsService.handlePush(push);
      });
    MobileFbnsService.started = ok;
    hilog.info(DOMAIN, TAG, 'fbns start result=%{public}s', ok ? 'up' : 'failed');
    return ok;
  }

  static stop(): void {
    const client: MobileFbnsClient | null = MobileFbnsService.client;
    if (client !== null) {
      client.stop();
    }
    MobileFbnsService.client = null;
    MobileFbnsService.started = false;
  }

  /** 一行诊断（给「导出诊断」用）。 */
  static describe(): string {
    const up: boolean = MobileFbnsService.client !== null && MobileFbnsService.client.isUp();
    return `fbns=${up ? 'up' : 'down'} started=${MobileFbnsService.started ? '1' : '0'} `
      + `token=${MobileFbnsService.tokenLength}`;
  }

  /**
   * 把 push token 交给 IG（`push/register/`）。
   *
   * 字段与 relay 完全一致（见 `tools/relay/instamony.js` 里那段 form）：漏一个 IG 就不认，
   * 表现是"token 拿到了、却一条推送都不来"。
   */
  private static async registerToken(token: string, identity: MobileIdentity): Promise<void> {
    const form: string = 'device_type=android_mqtt&is_main_push_channel=true&device_sub_type=2'
      + `&device_token=${encodeURIComponent(token)}`
      + `&_csrftoken=${encodeURIComponent(identity.csrf)}`
      + `&guid=${encodeURIComponent(identity.uuid)}`
      + `&uuid=${encodeURIComponent(identity.uuid)}`
      + `&users=${encodeURIComponent(identity.userId)}`
      + `&family_device_id=${encodeURIComponent(identity.phoneId)}`;
    const extra: Record<string, string> = {
      'X-FB-Friendly-Name': 'IgApi: push/register/',
      'Content-Type': 'application/x-www-form-urlencoded'
    };
    // 注意路径前缀：`MobileRequest.absoluteUrl` 会自己拼 `https://i.instagram.com/api`，
    // 所以这里只能给 `/v1/push/register/`。写成 `/api/v1/...` 会变成
    // `.../api/api/v1/push/register/` → 404（真机就是这么拿了张 HTML 登录页回来）。
    const result: MobileResult = await MobileRequest.send('/v1/push/register/', form, '',
      false, extra);
    const ok: boolean = result.ok && result.body.indexOf('"ok"') >= 0;
    hilog.info(DOMAIN, TAG, 'push/register http=%{public}d ok=%{public}s',
      result.code, ok ? '1' : '0');
    if (!ok) {
      hilog.warn(DOMAIN, TAG, 'push/register body=%{public}s',
        result.body.substring(0, 120));
    }
  }

  /**
   * 处理一条 FBNS 推送（topic 76 的 `fbpushnotif`）。
   *
   * 字段见 relay 的注释：`m` 正文 / `t_id` 会话 / `s` 发信人 / `n` 消息 id / `c` 类型。
   */
  private static handlePush(push: ESObject): void {
    if (push === null || push === undefined || typeof push !== 'object') {
      return;
    }
    const record: Record<string, ESObject> = push as Record<string, ESObject>;
    const read = (name: string): string => {
      const value: ESObject = record[name];
      return value === undefined || value === null ? '' : `${value}`;
    };
    const threadId: string = read('t_id');
    const itemId: string = read('n');
    const sender: string = read('s');
    const text: string = read('m');
    const kind: string = read('c');
    if (threadId.length === 0) {
      return;
    }
    if (kind.length > 0 && kind.indexOf('direct') < 0 && kind.indexOf('text') < 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'fbns push thread=%{public}s len=%{public}d', threadId, text.length);
    /*
     * 造一条 message_sync 补丁喂给 `DirectRealtime`：形状与 iris 推来的 topic 146 一致，
     * 这样"开着的会话即时插入 / 列表刷新"这两条既有逻辑一行都不用改。
     */
    if (itemId.length > 0) {
      const item: Record<string, ESObject> = {
        'item_id': itemId,
        'item_type': 'text',
        'text': text,
        'user_id': sender,
        'timestamp': `${Date.now()}`,
        'client_context': ''
      };
      const patch: Record<string, ESObject> = {
        'path': `/direct_v2/threads/${threadId}/items/${itemId}/`,
        'op': 'add',
        'value': item
      };
      const data: Record<string, ESObject> = { 'data': [patch] };
      const event: RealtimeEvent = new RealtimeEvent('146', JSON.stringify([data]));
      DirectRealtime.handle(event);
    }
    // 本地通知（不依赖界面是否开着）：标题先用发信人 id，正文是消息内容。
    PushCenter.notifyDirect(sender, text, 1, threadId);
  }
}
