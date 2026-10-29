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
import { common, Want, WantAgent, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { preferences } from '@kit.ArkData';
import { PushCenter } from '../PushCenter';
import { DirectRealtime } from '../DirectRealtime';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileRequest, MobileResult } from './MobileRequest';
import { MobileProfile, MobileUserBody } from './MobileProfile';
import { FBNS_PACKAGE } from './MobileFbns';
import { FbnsAuthStore, MobileFbnsClient } from './MobileFbnsClient';
import { RealtimeEvent } from './MobileRealtime';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileFbnsService';

/** 待发的一条通知（同一条会话的连发会合并成一条，见 handlePush 末尾）。 */
class FbnsPendingNotify {
  name: string = '';
  text: string = '';
  added: number = 0;
  timer: number = -1;
}

export class MobileFbnsService {
  private static client: MobileFbnsClient | null = null;
  private static started: boolean = false;
  /** 最近一次拿到的 push token（诊断用；值本身不记日志）。 */
  private static tokenLength: number = 0;
  /**
   * 发信人 id → 用户名 的缓存。
   *
   * 为什么必须有：FBNS 推送里只带发信人的**数字 id**（`s`），直接拿去当通知标题就是
   * "用户名变成数字"。而用户名要么从已加载的会话里拿（推送这条路拿不到），要么现查
   * `users/{id}/info/`（一发很小的请求）。缓存住之后同一个人只查一次。
   */
  private static senderNames: Map<string, string> = new Map<string, string>();
  /**
   * 正在查的 uid → 查名请求（**同一人只查一次**）。
   *
   * 为什么必须去重：一条消息连发时，推送会在几百毫秒内来好几条。若每条都各发一次
   * `users/{id}/info/`，就会被节流排队 —— 真机上表现为"通知晚 20 秒才弹、还连弹 6 次"。
   * 现在同一 uid 共用同一个 Promise，后到的等它就行。
   */
  private static pendingNames: Map<string, Promise<string>> =
    new Map<string, Promise<string>>();
  /**
   * 落盘的发信人名字缓存（`instarmony_fbns_names`）。
   *
   * 为什么要落盘：内存缓存重启就没了，而第一次收到某个人的私信时若查不到名字，
   * 通知标题就会退成「私信」（用户看到的就是"有时候标题是私信"）。落盘之后，
   * 同一个人第二次起一定有名字，且不受"查名超时"影响。
   */
  private static nameStore: preferences.Preferences | null = null;
  private static namesLoaded: boolean = false;
  /**
   * 会话 id → 显示名的**同步查询**（由私信列表注册，见 Index.onPageShow）。
   *
   * 为什么需要：私信列表已经把"这条会话叫什么"拿到了（收件箱里就有），推送到达时直接问它
   * 就能**同步**拿到名字，不用发请求、也不会超时退回「私信」。
   */
  private static titleLookup: ((threadId: string) => string) | null = null;
  /** 正在合并的通知（会话 id → 待发）。 */
  private static pendingNotifies: Map<string, FbnsPendingNotify> =
    new Map<string, FbnsPendingNotify>();
  /**
   * 已提醒过的消息 id（**去重**，与中转 `instamony.js` 的 `seenItems` 同一目的）。
   *
   * 为什么要有：FBNS 在网络抖动/重连时会**重投**同一条推送。没有去重就会对同一条消息
   * 反复弹通知（比"漏弹"更让人烦）。
   */
  private static seenItems: Set<string> = new Set<string>();
  /** 自己的账号 id（用来跳过自己发的消息，与中转那条 `s === session.userId` 一致）。 */
  private static ownUserId: string = '';
  /**
   * 长期任务（continuous task）的上下文与状态。
   *
   * 为什么要长期任务：退到后台后系统很快冻结进程 → FBNS socket 断开 → 一条推送都收不到
   * （真机日志：后台两分钟里 `fbns push` 一行都没有，回到前台才把积压的推过来）。
   * 短时任务（core/BackgroundKeep）只有分钟级额度，撑不住"后台常驻"。
   */
  private static taskContext: common.UIAbilityContext | null = null;
  private static taskRunning: boolean = false;

  /** 绑定 ability 上下文（EntryAbility.onCreate 里调一次；长期任务需要它）。 */
  static bindContext(context: common.UIAbilityContext): void {
    MobileFbnsService.taskContext = context;
    MobileFbnsService.openNameStore(context);
  }

  /** 私信列表注册"会话 id → 显示名"的同步查询（见 titleLookup 的说明）。 */
  static setTitleLookup(lookup: (threadId: string) => string): void {
    MobileFbnsService.titleLookup = lookup;
  }

  /** 打开名字缓存（幂等；失败就当没有，不影响通知）。 */
  private static openNameStore(context: common.Context): void {
    if (MobileFbnsService.nameStore !== null) {
      return;
    }
    try {
      MobileFbnsService.nameStore = preferences.getPreferencesSync(context,
        { name: 'instarmony_fbns_names' });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open name store failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

  /** 首次用到时把落盘的名字读进内存（只读一次）。 */
  private static loadNames(): void {
    if (MobileFbnsService.namesLoaded) {
      return;
    }
    MobileFbnsService.namesLoaded = true;
    const store: preferences.Preferences | null = MobileFbnsService.nameStore;
    if (store === null) {
      return;
    }
    try {
      const text: string = String(store.getSync('names_v1', '') as string);
      if (text.length === 0) {
        return;
      }
      const record: Record<string, ESObject> = JSON.parse(text) as Record<string, ESObject>;
      for (const key of Object.keys(record)) {
        const value: ESObject = record[key];
        if (value !== undefined && value !== null && `${value}`.length > 0) {
          MobileFbnsService.senderNames.set(key, `${value}`);
        }
      }
      hilog.info(DOMAIN, TAG, 'name cache loaded (%{public}d)', MobileFbnsService.senderNames.size);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load name cache failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

  /** 名字进缓存并落盘（幂等；失败不影响通知）。 */
  private static rememberName(uid: string, name: string): void {
    const id: string = uid.trim();
    const label: string = name.trim();
    if (id.length === 0 || label.length === 0) {
      return;
    }
    MobileFbnsService.senderNames.set(id, label);
    const store: preferences.Preferences | null = MobileFbnsService.nameStore;
    if (store === null) {
      return;
    }
    try {
      const record: Record<string, string> = {};
      // 只留最近 200 个，避免无限长
      let count: number = 0;
      for (const key of MobileFbnsService.senderNames.keys()) {
        if (count >= 200) {
          break;
        }
        const value: string | undefined = MobileFbnsService.senderNames.get(key);
        if (value !== undefined) {
          record[key] = value;
          count++;
        }
      }
      store.putSync('names_v1', JSON.stringify(record));
      store.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save name cache failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

  /**
   * 申请长期任务：让进程在后台保持运行，FBNS 长连接才不会被系统掐断。
   *
   * 前提（module.json5 已声明）：`ohos.permission.KEEP_BACKGROUND_RUNNING` + ability 的
   * `backgroundModes: ["dataTransfer"]`。系统会在通知栏展示一条"正在运行"的常驻通知，
   * 这是长期任务的规矩，不是我们的广告。
   */
  private static async startContinuousTask(): Promise<void> {
    if (MobileFbnsService.taskRunning) {
      return;
    }
    const context: common.UIAbilityContext | null = MobileFbnsService.taskContext;
    if (context === null) {
      hilog.warn(DOMAIN, TAG, 'no ability context → skip continuous task');
      return;
    }
    try {
      // 常驻通知点一下回到 App（用 home want，不需要会话参数）
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      MobileFbnsService.taskRunning = true;
      hilog.info(DOMAIN, TAG, 'continuous task started (dataTransfer)');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'continuous task failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

  /** 交还长期任务（退出登录 / 停实时时调）。 */
  private static async stopContinuousTask(): Promise<void> {
    if (!MobileFbnsService.taskRunning) {
      return;
    }
    MobileFbnsService.taskRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(MobileFbnsService.taskContext);
      hilog.info(DOMAIN, TAG, 'continuous task stopped');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'stop continuous task failed: %{public}s',
        (error as Error).message ?? 'unknown');
    }
  }

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
    /*
     * **不再区分"设备级会话 / 带 sessionid 的会话"**（这一条是 App 内账密登录打通之后改的）。
     *
     * 以前这里写着"网页会话：iris 那条路还能用，别抢"，于是：
     *   · 用 `settings.caa.json` 导入的设备级会话 → 走 FBNS（后台能收）；
     *   · **App 内密码登录**拿到的会话是**带 sessionid 的**（真机验证：CAA 登录成功那一刻
     *     `authorization` 里就带 sessionid），于是 `isDeviceLevel()` 为 false → **FBNS 压根没起**，
     *     退到 iris；而 iris 只在前台活着 —— 用户看到的就是"后台收不到消息"。
     *
     * 但 FBNS 本身并不挑会话形状：`/v1/push/register/` 与 FBNS 的 token 请求都吃普通会话
     * （PC 上的 `instamony.js` 一直是用带 sessionid 的 settings.json 跑 FBNS 的）。
     * 所以现在**只要会话完整就起 FBNS**；起不来再退回 iris（下面的返回值管这个）。
     */
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
        MobileFbnsService.handlePush(push).catch((): void => {
        });
      });
    MobileFbnsService.started = ok;
    hilog.info(DOMAIN, TAG, 'fbns start result=%{public}s', ok ? 'up' : 'failed');
    if (ok) {
      // 长连接活着不代表后台也活着：申请长期任务，进程不被冻结才收得到推送
      await MobileFbnsService.startContinuousTask();
    }
    return ok;
  }

  static stop(): void {
    const client: MobileFbnsClient | null = MobileFbnsService.client;
    if (client !== null) {
      client.stop();
    }
    MobileFbnsService.client = null;
    MobileFbnsService.started = false;
    MobileFbnsService.stopContinuousTask().catch((): void => {
    });
  }

  /**
   * **退出登录：把这个账号的推送凭据与名字缓存一起抹掉**。
   *
   * 为什么必须清：
   *   · `instarmony_fbns` 存的是**这个账号的推送授权**（clientId / userId / password /
   *     deviceSecret）—— 留着等于把上一个人的推送通道留在本机；
   *   · `instarmony_fbns_names` 存的是"谁发过消息"的 id → 昵称表，也是按人的资讯。
   * 设备身份（USDID / uuid / mid）不动，那是这台手机的，不是这个账号的。
   */
  static forgetAccount(): void {
    MobileFbnsService.stop();
    try {
      FbnsAuthStore.clear();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clear fbns auth failed: %{public}s', (error as Error).message);
    }
    MobileFbnsService.senderNames.clear();
    MobileFbnsService.pendingNames.clear();
    const store: preferences.Preferences | null = MobileFbnsService.nameStore;
    if (store !== null) {
      try {
        store.putSync('names_v1', '');
        store.flush();
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'clear fbns names failed: %{public}s', (error as Error).message);
      }
    }
    hilog.info(DOMAIN, TAG, 'fbns account state cleared');
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
   * 解析发信人的**显示名**（带缓存；查不到返回空串）。
   *
   * 判据必须与界面一致：私信列表/标题栏显示的是 `full_name`（例如 `Jin`），**没有才退回
   * username**（见 `model/Direct.ets` 里 `person.label` 的注释）。早先这里直接取 username，
   * 通知标题就成了 `yijin.0415_` 而列表里是 `Jin` —— 同一个人两个名字，看着像"取数取错了"。
   */
  private static async nameOf(userId: string): Promise<string> {
    const id: string = userId.trim();
    if (id.length === 0) {
      return '';
    }
    const cached: string | undefined = MobileFbnsService.senderNames.get(id);
    if (cached !== undefined) {
      return cached;
    }
    // 已经在查了就等同一发（见 pendingNames 的说明）
    const pending: Promise<string> | undefined = MobileFbnsService.pendingNames.get(id);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<string> = MobileFbnsService.lookupName(id);
    MobileFbnsService.pendingNames.set(id, task);
    try {
      return await task;
    } finally {
      MobileFbnsService.pendingNames.delete(id);
    }
  }

  /** 真正去查一次用户名（`nameOf` 负责缓存与去重）。 */
  private static async lookupName(id: string): Promise<string> {
    try {
      const body: MobileUserBody | null = await MobileProfile.info(id, '');
      if (body === null) {
        return '';
      }
      const read = (name: string): string => {
        const value: Object | undefined = body.user[name];
        return value === undefined || value === null ? '' : `${value}`.trim();
      };
      const fullName: string = read('full_name');
      const username: string = read('username');
      // 与界面同一判据：full_name 优先，没有才用 username。
      const label: string = fullName.length > 0 ? fullName : username;
      if (label.length > 0) {
        MobileFbnsService.rememberName(id, label);
        hilog.info(DOMAIN, TAG, 'sender name resolved uid=%{public}s name=%{public}s',
          id, label);
      }
      return label;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'name lookup failed for %{public}s: %{public}s',
        id, (error as Error).message);
      return '';
    }
  }

  /**
   * 取名字，但**最多等 `ms` 毫秒**（超时先弹通知，名字留给下一次）。
   *
   * 为什么要设上限：`users/{id}/info/` 是一发网络请求，第一次遇到某个发信人时可能被节流排队。
   * 通知不该等它 —— 等不到就用兜底标题先弹，查回来的名字会进缓存，下一条就是准的。
   */
  private static async nameWithin(userId: string, threadId: string,
                                  ms: number): Promise<string> {
    const id: string = userId.trim();
    if (id.length === 0) {
      return '';
    }
    MobileFbnsService.loadNames();
    // ① 内存/落盘缓存（同一个发信人第二次起一定命中）
    const cached: string | undefined = MobileFbnsService.senderNames.get(id);
    if (cached !== undefined) {
      return cached;
    }
    // ② 问私信列表：这条会话叫什么（同步、不发请求）
    const lookup: ((threadId: string) => string) | null = MobileFbnsService.titleLookup;
    if (lookup !== null && threadId.length > 0) {
      try {
        const title: string = lookup(threadId).trim();
        if (title.length > 0) {
          MobileFbnsService.rememberName(id, title);
          hilog.info(DOMAIN, TAG, 'sender name from thread list uid=%{public}s', id);
          return title;
        }
      } catch (error) {
        // 列表还没准备好：继续走网络
      }
    }
    // ③ 现查一次资料（最多等 ms）
    const pending: Promise<string> = MobileFbnsService.nameOf(id);
    const timeout: Promise<string> = new Promise<string>((resolve: (value: string) => void): void => {
      setTimeout((): void => {
        resolve('');
      }, ms);
    });
    return Promise.race([pending, timeout]);
  }

  /**
   * 处理一条 FBNS 推送（topic 76 的 `fbpushnotif`）。
   *
   * 字段见 relay 的注释：`m` 正文 / `t_id` 会话 / `s` 发信人 / `n` 消息 id / `c` 类型。
   */
  private static async handlePush(push: ESObject): Promise<void> {
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
      /*
       * **两条补丁一起发**：
       *   ① 消息补丁（带 value）→ 开着的会话即时插入；
       *   ② 会话级补丁（`value` 故意不给）→ `DirectRealtime.applyPatch` 见到空 value 就当成
       *      "这条会话有别的变化"，emitThread → 私信列表补刷一次。
       *
       * 只发①的话真机表现是"会话里实时更新、但私信列表不动"——列表读的是 inbox 的摘要，
       * 必须由"会话变了"这个信号去刷。
       */
      const threadPatch: Record<string, ESObject> = {
        'path': `/direct_v2/inbox/threads/${threadId}/`,
        'op': 'replace'
      };
      const group: Record<string, ESObject> = { 'data': [patch, threadPatch] };
      const event: RealtimeEvent = new RealtimeEvent('146', JSON.stringify([group]));
      DirectRealtime.handle(event);
    }
    /*
     * **一条推送一条通知**（与中转 `instamony.js` 同一套判断，别再合并了）。
     *
     * 中转那边的顺序（`handlePush`）就是标准答案，这里逐条照搬：
     *   1. 自己发的消息跳过（`s === 自己的 userId`）；
     *   2. 同一条消息只提醒一次（`seenItems`，防 FBNS 重投）；
     *   3. 正文截到 120 字符，空正文用兜底文案；
     *   4. 标题用发信人显示名（`full_name` 优先，见 `nameOf`）；
     *   5. **每条都发一条通知**（通知 id 按消息 id 算，所以连发 6 条 = 6 条通知）。
     *
     * 之前我按"同一会话 700ms 合并"处理，与中转行为不一致 —— 用户要的是"来一条弹一条"。
     */
    if (MobileFbnsService.ownUserId.length === 0) {
      const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
      MobileFbnsService.ownUserId = identity === null ? '' : identity.userId;
    }
    if (MobileFbnsService.ownUserId.length > 0 && sender === MobileFbnsService.ownUserId) {
      hilog.info(DOMAIN, TAG, 'skip own message thread=%{public}s', threadId);
      return;
    }
    if (itemId.length > 0) {
      if (MobileFbnsService.seenItems.has(itemId)) {
        hilog.info(DOMAIN, TAG, 'skip duplicate item=%{public}s', itemId);
        return;
      }
      MobileFbnsService.seenItems.add(itemId);
      // 别让集合无限长（一次运行里几千条足够覆盖重投窗口）
      if (MobileFbnsService.seenItems.size > 2000) {
        MobileFbnsService.seenItems.clear();
        MobileFbnsService.seenItems.add(itemId);
      }
    }
    const name: string = await MobileFbnsService.nameWithin(sender, threadId, 500);
    const preview: string = text.trim().slice(0, 120);
    PushCenter.notifyDirectEach(name, preview, threadId, itemId);
  }
}
