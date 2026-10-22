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
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PushCenter';

/** 兜底包名（拿不到系统信息时用；和 AppScope/app.json5 保持一致）。 */
const FALLBACK_BUNDLE: string = 'com.oneleaf.instamony';
/** 私信通知在 want 里带的参数名（以后 Index 里"点通知直接进会话"要用）。 */
export const NOTIFY_KEY_THREAD: string = 'threadId';

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

export class PushCenter {
  /** Push Kit 给的 token（空 = 没拿到 / 没配 AGC）。 */
  private static token: string = '';
  /** 已经初始化过（幂等）。 */
  private static started: boolean = false;
  /** 通知分类（slot）注册过没有（幂等）。 */
  private static slotsReady: boolean = false;
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
   * @param slotType 落哪个通知分类（见 ensureSlots）
   * @param threadId 非空时写进 want 参数，点通知能知道是哪条会话
   */
  private static publish(id: number, title: string, text: string,
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
      /*
       * 点通知拉起 app：**没有 wantAgent 的通知点了没反应**，所以这一项必须给。
       * 会话 id 放进 parameters，Index 那边以后可以据此直接打开那条会话。
       */
      PushCenter.wantAgentFor(threadId).then((agent: WantAgent | undefined): void => {
        const finalRequest: notificationManager.NotificationRequest = request;
        if (agent !== undefined) {
          finalRequest.wantAgent = agent;
        }
        PushCenter.send(finalRequest, id);
      }).catch((): void => {
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
          hilog.info(DOMAIN, TAG, 'notification published id=%{public}d', id);
        })
        .catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'notification publish failed (%{public}d): %{public}s',
            error.code, error.message ?? '-');
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'notification publish rejected: %{public}s',
        (error as Error).message);
    }
  }

  /** 构造"点通知 → 打开本应用"的 WantAgent（带上会话 id）。 */
  private static async wantAgentFor(threadId: string): Promise<WantAgent | undefined> {
    const parameters: Record<string, Object> = {};
    if (threadId.length > 0) {
      parameters[NOTIFY_KEY_THREAD] = threadId;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: PushCenter.bundleName(),
          abilityName: 'EntryAbility',
          parameters: parameters
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
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
