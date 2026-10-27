/*
 * **消息通知**：Push Kit（远端推送）+ NotificationKit（本地通知）。
 *
 * ## 两层各管什么
 *   · **Push Kit**：拿推送 token（`pushService.getToken()`）并监听 `tokenUpdate`。
 *     真正把通知送到"app 没在跑"的设备上还要**服务端**用这个 token 发 —— 那需要 AGC 开推送、
 *     配 `client_id`、以及一台会发推送的服务器。这里只负责"注册 + 记日志"，
 *     绝不因为拿不到 token 影响任何界面。
 *   · **本地通知**：我们自己拉到了新的未读就用 `notificationManager.publish` 弹一条系统通知。
 *     这一层不依赖后台，装上就能用；app 被划掉之后靠的是上面那条远端推送（未接）。
 *
 * ## 通知长什么样（需求）
 *   · **标题 = 发信人的用户名**（`@xxx` 那个，不是显示名/群名）；
 *   · **正文 = 消息内容**（拿不到内容时退回"你有 N 条新私信"）；
 *   · **独立分类**：注册并固定使用 **`SlotType.SOCIAL_COMMUNICATION`（社交）** 这个通知分类，
 *     私信都落在这里 —— 系统设置里能单独关它/单独设提醒方式，和「动态」分开。
 *     ⚠️ HarmonyOS 的通知分类是**系统预置类型**（社交 / 服务 / 内容 / 客服 / 实况窗），
 *     App 只能选类型、**不能像 Android 那样自定义渠道名**（`addSlot` 只收一个 `SlotType`）。
 *   · 点通知 → 拉起 app，并把 `threadId` 塞进 want 参数（供以后直接进那条会话用）。
 *
 * ## 幂等 + 静默失败
 * 整条链只做"能就做、不能就算"：没权限 / 没配 AGC / 低版本设备一律只写一行日志。
 */

import { common, UIAbility, WantAgent, wantAgent } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
// 点通知要进哪条会话：参数名只留一份真源（放在 core/NotifyRoute）。
import { NOTIFY_THREAD_KEY } from './NotifyRoute';
// 会话 id 除了放进 parameters，也编码进 uri 兜底（见 wantAgentFor）。
import { DEEPLINK_PREFIX } from './DeepLink';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PushCenter';

/** 兜底包名（拿不到系统信息时用；和 AppScope/app.json5 保持一致）。 */
const FALLBACK_BUNDLE: string = 'com.oneleaf.instamony';
/**
 * 私信通知在 want 里带的参数名。
 *
 * **必须**和 `core/NotifyRoute.NOTIFY_THREAD_KEY` 是同一个字符串：那边负责读，
 * 这里负责写。为了只留一份真源，这里直接引用它（原来两边各写一份字面量，容易写歪）。
 */
export const NOTIFY_KEY_THREAD: string = NOTIFY_THREAD_KEY;

/** 上一次的未读总数（按 kind 分开）：只有**变多**才弹通知。 */
class UnreadMark {
  readonly kind: string;
  readonly total: number;

  constructor(kind: string, total: number) {
    this.kind = kind;
    this.total = total;
  }
}

/** 本地通知的通知 id（同一类复用同一个 id，后一条会覆盖前一条，不会堆一屏）。 */
const NOTIFY_ID_DIRECT: number = 9101;
const NOTIFY_ID_FEED: number = 9102;
/**
 * 取 WantAgent 最多等多久（毫秒）。
 *
 * 通知"出不出来"不该取决于一个点击跳转对象能不能拿到：超过这个时间就先发出去 ——
 * 代价只是这一次点开只回到 App（不是那条会话），换来的是通知本身一定出现。
 */
const NOTIFY_AGENT_WAIT_MS: number = 400;

export class PushCenter {
  /** Push Kit 给的 token（空 = 没拿到 / 没配 AGC）。 */
  private static token: string = '';
  /** 已经初始化过（幂等）。 */
  private static started: boolean = false;
  /** 通知分类（slot）注册过没有（幂等）。 */
  private static slotsReady: boolean = false;
  /** "通知开关"那行日志打过了没有（见 logEnabledOnce）。 */
  private static enabledLogged: boolean = false;
  /** 上一条未读数：kind → total。 */
  private static marks: Array<UnreadMark> = [];
  /** UIAbility 的 context（取包名要用；`start` 时注入）。 */
  private static appContext: common.Context | null = null;

  /**
   * 启动：注册通知分类 + 取推送 token。
   *
   * 任意一步失败都只记日志：通知是"加分项"，不能影响启动。
   */
  static start(ability: UIAbility, context: common.UIAbilityContext): void {
    if (PushCenter.started) {
      return;
    }
    PushCenter.started = true;
    PushCenter.appContext = context;
    // 分类要**在第一次 publish 之前**注册好（系统虽然会在 publish 时自动补一个，
    // 但那样拿到的是默认级别，私信该有的横幅/响铃就不一定给）。
    PushCenter.ensureSlots();
    // 权限等界面首帧之后再要（见 requestPermissionNow 的说明）。
    PushCenter.registerPush(ability);
  }

  /** 申请通知权限（用户拒绝就只记日志，后面 publish 会静默失败）。 */
  /**
   * 申请通知权限（用户拒绝就只记日志，后面 publish 会静默失败）。
   *
   * 为什么单独暴露：`requestEnableNotification` 在 `onCreate` 里调会回
   * `IPC communication failed`（窗口还没建好），要等首帧之后再要 —— 见
   * `pages/Index.aboutToAppear` 的那一处调用。
   */
  static requestPermissionNow(context: common.UIAbilityContext): void {
    PushCenter.requestPermission(context);
  }

  private static requestPermission(context: common.UIAbilityContext): void {
    try {
      notificationManager.requestEnableNotification(context)
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'notification permission granted');
        })
        .catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'notification permission denied: %{public}s',
            error.message ?? '-');
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'requestEnableNotification threw: %{public}s',
        (error as Error).message);
    }
  }

  /**
   * 注册两个通知分类：**「私信」= 社交类**（`SOCIAL_COMMUNICATION`）和「动态」= 服务类。
   *
   * `addSlot` 只收一个 `SlotType`（系统预置的那几种），不能自定义名字/描述 ——
   * 名字由系统按类型给（社交 / 服务信息 / 内容信息…）。所以"注册一个私信分类"在 HarmonyOS 上
   * 就等于：**把 SOCIAL_COMMUNICATION 这类登记一下，并且私信通知固定走这一类**。
   * 幂等：重复调用只是把类型再登记一次，失败也只记日志。
   */
  private static ensureSlots(): void {
    if (PushCenter.slotsReady) {
      return;
    }
    PushCenter.slotsReady = true;
    PushCenter.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION, 'direct');
    PushCenter.addSlot(notificationManager.SlotType.SERVICE_INFORMATION, 'feed');
  }

  private static addSlot(type: notificationManager.SlotType, label: string): void {
    try {
      notificationManager.addSlot(type)
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'slot added %{public}s type=%{public}d', label, type);
        })
        .catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'slot %{public}s failed (%{public}d): %{public}s',
            label, error.code, error.message ?? '-');
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'slot %{public}s threw: %{public}s',
        label, (error as Error).message);
    }
  }

  /**
   * 取 Push Kit 的 token 并监听更新。
   *
   * ⚠️ 没在 AGC 里开推送 / 没配 `client_id` 时这里会抛错（真机实测：`1000900013` 一类），
   * 那是**配置问题**不是代码问题 —— 只记日志，不影响任何界面。
   */
  private static registerPush(ability: UIAbility): void {
    try {
      pushService.getToken()
        .then((token: string): void => {
          PushCenter.token = token;
          hilog.info(DOMAIN, TAG, 'push token len=%{public}d head=%{public}s',
            token.length, token.substring(0, 12));
        })
        .catch((error: BusinessError): void => {
          hilog.info(DOMAIN, TAG, 'push token unavailable (%{public}d): %{public}s',
            error.code, error.message ?? '-');
        });
      /*
       * `on('tokenUpdate', …)` 的签名是 `(type, ability, callback)` —— 第二个参数是**具体的
       * UIAbility 实例**（不是 context），漏了它编译期就会报 "Expected 3 arguments"。
       */
      pushService.on('tokenUpdate', ability, (token: string): void => {
        PushCenter.token = token;
        hilog.info(DOMAIN, TAG, 'push token updated len=%{public}d', token.length);
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'pushService unavailable: %{public}s',
        (error as Error).message);
    }
  }

  /** 有没有拿到推送 token（设置页/诊断可以显示）。 */
  static hasToken(): boolean {
    return PushCenter.token.length > 0;
  }

  /** 推送 token 本身（空串 = 还没拿到；BYO 中转要把它抄走，见设置页的「复制中转材料」）。 */
  static tokenNow(): string {
    return PushCenter.token;
  }

  /**
   * 记一次未读数，**返回这一轮涨了多少**（0 = 没涨）。
   *
   * 这里**不**直接发通知：调用方拿到"涨了多少"之后再决定发什么
   * （私信要用"发信人 + 内容"，动态只用条数，见 notifyDirect / notifyFeed）。
   * 第一次见到某一类（`previous < 0`）只记账、不弹 —— 否则一启动就"叮"一条。
   *
   * @param kind  `'direct'`（私信）或 `'feed'`（通知页）
   * @param total 这次拉到的未读总条数
   */
  static noteUnread(kind: string, total: number): number {
    let previous: number = -1;
    for (let index: number = 0; index < PushCenter.marks.length; index++) {
      if (PushCenter.marks[index].kind === kind) {
        previous = PushCenter.marks[index].total;
        PushCenter.marks[index] = new UnreadMark(kind, total);
        break;
      }
    }
    if (previous < 0) {
      PushCenter.marks.push(new UnreadMark(kind, total));
      return 0;
    }
    if (total <= previous || total <= 0) {
      return 0;
    }
    hilog.info(DOMAIN, TAG, 'unread up kind=%{public}s %{public}d → %{public}d',
      kind, previous, total);
    return total - previous;
  }

  /** 上一次记下的未读数（-1 = 还没记过）。 */
  static lastUnread(kind: string): number {
    for (let index: number = 0; index < PushCenter.marks.length; index++) {
      if (PushCenter.marks[index].kind === kind) {
        return PushCenter.marks[index].total;
      }
    }
    return -1;
  }

  /**
   * **私信通知**（需求）：标题 = 发信人**用户名**，正文 = **消息内容**。
   *
   * 为什么用用户名而不是显示名：显示名会重名、还可能带 emoji，在通知栏也最占行宽；
   * 用户名（`@xxx`）唯一、稳定。用户名拿不到才退回"私信"。
   *
   * @param username 发信人用户名（`DirectThread.username`）
   * @param preview  最新那条消息的内容（调用方已截断）
   * @param added    这一轮新增几条（正文兜底时用）
   * @param threadId 会话 id（点通知带给 app，以后可直达那条会话）
   */
  static notifyDirect(username: string, preview: string, added: number,
                       threadId: string = ''): void {
    const title: string = username.trim().length > 0 ? username.trim() : '私信';
    const body: string = preview.trim().length > 0 ? preview.trim()
      : `你有 ${added} 条新私信`;
    hilog.info(DOMAIN, TAG, 'direct notify from=%{public}s added=%{public}d',
      title, added);
    PushCenter.publish(NOTIFY_ID_DIRECT, title, body,
      notificationManager.SlotType.SOCIAL_COMMUNICATION, threadId);
  }

  /** **动态通知**：只有条数（通知页里那些点赞/评论没有"一条正文"的概念）。 */
  static notifyFeed(added: number): void {
    if (added <= 0) {
      return;
    }
    PushCenter.publish(NOTIFY_ID_FEED, '通知', `你有 ${added} 条新通知`,
      notificationManager.SlotType.SERVICE_INFORMATION, '');
  }

  /**
   * 真正发一条本地通知。
   *
   * 同一类通知用**同一个 id**：后来的覆盖前一条，通知栏不会堆一屏"n 条新私信"。
   *
   * ## 全程异步、绝不挡住调用方
   * 调用它的地方是**实时补丁到达**那一拍（`DirectRealtime` → `DirectViewModel`），
   * 那是最不该被别的活拖住的一刻。所以：
   *   · 整个流程挪到**下一拍**再跑（`defer`），调用方立刻返回；
   *   · 取 WantAgent 只等 400ms，超时就"先发出去、这次点开只回首页"，
   *     绝不让一条通知因为等一个 agent 而不出现（以前 `.then` 里才 publish，
   *     `getWantAgent` 一旦卡住/失败，通知就永远不弹）。
   *
   * @param slotType 落哪个通知分类（见 ensureSlots）
   * @param threadId 非空时写进 want 参数，点通知能直达那条会话
   */
  private static publish(id: number, title: string, text: string,
                         slotType: notificationManager.SlotType, threadId: string): void {
    // 挪到下一拍：这个函数只入队，不在实时回调的调用栈里干活。
    setTimeout((): void => {
      PushCenter.publishNow(id, title, text, slotType, threadId);
    }, 0);
  }

  private static publishNow(id: number, title: string, text: string,
                            slotType: notificationManager.SlotType, threadId: string): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text
          }
        },
        notificationSlotType: slotType
      };
      // 分类没登记成功时 publish 会拿默认级别（没有横幅）；这里补一次，幂等。
      PushCenter.ensureSlots();
      PushCenter.logEnabledOnce();
      /*
       * 点通知拉起 app：**没有 wantAgent 的通知点了没反应**，所以这一项要尽量给上；
       * 但它是"加分项"，拿不到也必须把通知发出去（见上面 400ms 的说法）。
       */
      PushCenter.agentWithin(threadId, NOTIFY_AGENT_WAIT_MS)
        .then((agent: WantAgent | undefined): void => {
          const finalRequest: notificationManager.NotificationRequest = request;
          if (agent !== undefined) {
            finalRequest.wantAgent = agent;
          }
          PushCenter.send(finalRequest, id);
        })
        .catch((): void => {
          PushCenter.send(request, id);
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'notification publish threw: %{public}s',
        (error as Error).message);
    }
  }

  private static send(request: notificationManager.NotificationRequest, id: number): void {
    try {
      notificationManager.publish(request)
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'notification published id=%{public}d slot=%{public}d',
            id, request.notificationSlotType === undefined ? -1 : request.notificationSlotType);
        })
        .catch((error: BusinessError): void => {
          /*
           * 常见码（定位用，不改行为）：
           *   1600004 = 通知被关闭（用户在设置里关了这个 App 的通知 / 拒过一次权限）
           *   1600008 = 没有对应分类
           *   201     = 权限不足
           */
          hilog.warn(DOMAIN, TAG, 'notification publish failed (%{public}d): %{public}s',
            error.code, error.message ?? '-');
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'notification publish rejected: %{public}s',
        (error as Error).message);
    }
  }

  /**
   * 打一行"通知开关现在是什么状态"（**只记日志，不改行为**）。
   *
   * 用户报"突然不弹通知"时，这一行能立刻区分是"我们没发"还是"系统不让发"；
   * 只打一次，避免每次通知都多一次 IPC。
   */
  private static logEnabledOnce(): void {
    if (PushCenter.enabledLogged) {
      return;
    }
    PushCenter.enabledLogged = true;
    try {
      notificationManager.isNotificationEnabled()
        .then((enabled: boolean): void => {
          hilog.info(DOMAIN, TAG, 'notification enabled=%{public}s', `${enabled}`);
        })
        .catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'isNotificationEnabled failed (%{public}d)', error.code);
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'isNotificationEnabled threw: %{public}s',
        (error as Error).message);
    }
  }

  /**
   * 取 WantAgent，但**最多等 `timeoutMs`**（超时给 undefined）。
   *
   * 这样通知不会因为"等 agent"而不出现；`getWantAgent` 失败也只记日志。
   */
  private static async agentWithin(threadId: string,
                                   timeoutMs: number): Promise<WantAgent | undefined> {
    try {
      const pending: Promise<WantAgent | undefined> = PushCenter.wantAgentFor(threadId);
      const timeout: Promise<WantAgent | undefined> = new Promise<WantAgent | undefined>(
        (resolve: (value: WantAgent | undefined) => void): void => {
          setTimeout((): void => {
            resolve(undefined);
          }, timeoutMs);
        });
      const agent: WantAgent | undefined = await Promise.race([pending, timeout]);
      if (agent === undefined) {
        hilog.warn(DOMAIN, TAG, 'wantAgent timeout(%{public}dms) → 先发通知', timeoutMs);
      }
      return agent;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'wantAgent failed: %{public}s', (error as Error).message);
      return undefined;
    }
  }

  /** 构造"点通知 → 打开本应用"的 WantAgent（带上会话 id）。 */
  private static async wantAgentFor(threadId: string): Promise<WantAgent | undefined> {
    const parameters: Record<string, Object> = {};
    if (threadId.length > 0) {
      parameters[NOTIFY_THREAD_KEY] = threadId;
    }
    /*
     * **同一份信息走两条路**：parameters 之外再编码进 `uri`。
     *
     * 真机上遇到过"第一条通知点了没反应" —— 如果哪次 agent 的 parameters 没被带过来，
     * uri 还在（`START_ABILITY` 会把 uri 原样交给 ability），于是 EntryAbility 仍能从
     * `instarmony://open?route=direct&id=…&from=notify` 里把会话 id 取回来。
     * `from=notify` 用来区分"外部深链"（那种仍按课程要求走落地页 pages/LinkIn）。
     */
    const uri: string = threadId.length > 0
      ? `${DEEPLINK_PREFIX}?route=direct&id=${encodeURIComponent(threadId)}&from=notify`
      : '';
    const want: Want = {
      bundleName: PushCenter.bundleName(),
      abilityName: 'EntryAbility',
      parameters: parameters,
      uri: uri
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      /*
       * **按会话给不同的 requestCode**：WantAgent 的身份是
       * `(bundle, ability, requestCode)`，同一个 requestCode 会被当成**同一个** agent ——
       * 那样后一条通知的 want 会把前一条的覆盖掉，点旧通知就进到最新的那条会话里。
       */
      requestCode: PushCenter.requestCodeOf(threadId),
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  /** 会话 id → 稳定的 requestCode（同一条会话永远同一个，不同会话大概率不同）。 */
  private static requestCodeOf(threadId: string): number {
    if (threadId.length === 0) {
      return 0;
    }
    let sum: number = 0;
    for (let index: number = 0; index < threadId.length; index++) {
      // 逐位滚动累加：19~20 位数字的会话 id 也能散开，且同一 id 每次结果一致。
      sum = (sum * 31 + threadId.charCodeAt(index)) % 1000000;
    }
    return sum;
  }

  /** 本应用的包名（拿不到就用常量兜底）。 */
  private static bundleName(): string {
    const context: common.Context | null = PushCenter.appContext;
    if (context === null) {
      return FALLBACK_BUNDLE;
    }
    try {
      // `applicationInfo.name` 就是包名（label 才是显示名）。
      const name: string = context.applicationInfo.name;
      return name.length > 0 ? name : FALLBACK_BUNDLE;
    } catch (error) {
      return FALLBACK_BUNDLE;
    }
  }
}
