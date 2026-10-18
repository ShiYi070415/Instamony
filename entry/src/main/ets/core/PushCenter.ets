/*
 * **消息通知**：Push Kit（远端推送）+ NotificationKit（本地兜底）。
 *
 * 需求："把消息通知接入 push kit，包括通知页和私信"。
 *
 * ## 两层各管什么
 *   · **Push Kit**：拿推送 token（`pushService.getToken()`）并监听 `tokenUpdate`。
 *     真正把通知送到设备上还要**服务端**用这个 token 发 —— 那需要 AGC 项目里开推送、
 *     配 `client_id`、以及一台会发推送的服务器。没有后台时这里只负责"注册 + 记日志"，
 *     绝不因为拿不到 token 影响 App 任何功能（真机上没配 AGC 时会直接报错，见 start）。
 *   · **本地通知**：我们自己拉到了新的未读（通知页 / 私信）就用 `notificationManager.publish`
 *     弹一条系统通知。这一层不依赖任何后台，装到手机上就能看到效果。
 *
 * ## 幂等 + 静默失败
 * 整条链只做"能就做、不能就算"：没权限 / 没配 AGC / 低版本设备一律只写一行日志。
 */

import { common, UIAbility } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PushCenter';

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
  /** 上一条未读数：kind → total。 */
  private static marks: Array<UnreadMark> = [];

  /**
   * 启动：申请通知权限 + 取推送 token。
   *
   * 任意一步失败都只记日志：通知是"加分项"，不能影响启动。
   */
  static start(ability: UIAbility, context: common.UIAbilityContext): void {
    if (PushCenter.started) {
      return;
    }
    PushCenter.started = true;
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
   * 记一次未读数：**比上次多**才弹本地通知。
   *
   * @param kind  `'direct'`（私信）或 `'feed'`（通知页）
   * @param total 这次拉到的未读总条数
   */
  static noteUnread(kind: string, total: number): void {
    let previous: number = -1;
    for (let index: number = 0; index < PushCenter.marks.length; index++) {
      if (PushCenter.marks[index].kind === kind) {
        previous = PushCenter.marks[index].total;
        PushCenter.marks[index] = new UnreadMark(kind, total);
        break;
      }
    }
    if (previous < 0) {
      // 第一次见到这一类：只记账，不弹（否则一启动就"叮"一条）。
      PushCenter.marks.push(new UnreadMark(kind, total));
      return;
    }
    if (total <= previous || total <= 0) {
      return;
    }
    const added: number = total - previous;
    hilog.info(DOMAIN, TAG, 'unread up kind=%{public}s %{public}d → %{public}d',
      kind, previous, total);
    PushCenter.publish(kind === 'direct' ? NOTIFY_ID_DIRECT : NOTIFY_ID_FEED,
      kind === 'direct' ? '私信' : '通知',
      kind === 'direct' ? `你有 ${added} 条新私信` : `你有 ${added} 条新通知`);
  }

  /**
   * **私信专用的通知**：标题是发信人、正文是消息内容。
   *
   * 与 `noteUnread` 的区别是要有内容才有用："你有 1 条新私信"点开还得自己找是谁；
   * 而"某人：内容"在通知栏就能看完（这也是所有聊天软件的做法）。
   * 未读计数仍然只在**变多**时才可能调用它（判断在调用方，见 DirectViewModel.refreshQuietly）。
   *
   * @param sender  发信人昵称（群聊里是群名）
   * @param preview 最新的那条内容（调用方已经截断）
   */
  static notifyDirect(sender: string, preview: string, added: number): void {
    const name: string = sender.trim().length > 0 ? sender.trim() : '私信';
    const body: string = preview.trim().length > 0 ? preview.trim()
      : `你有 ${added} 条新私信`;
    hilog.info(DOMAIN, TAG, 'direct notify from=%{public}s added=%{public}d',
      name, added);
    PushCenter.publish(NOTIFY_ID_DIRECT, name, body);
  }

  /** 上一次记下的未读数（-1 = 还没记过）。调用方用它判断"这一轮是不是变多了"。 */
  static lastUnread(kind: string): number {
    for (let index: number = 0; index < PushCenter.marks.length; index++) {
      if (PushCenter.marks[index].kind === kind) {
        return PushCenter.marks[index].total;
      }
    }
    return -1;
  }

  /**
   * 真正发一条本地通知。
   *
   * 同一类通知用**同一个 id**：后来的覆盖前一条，通知栏不会堆一屏"n 条新私信"。
   */
  private static publish(id: number, title: string, text: string): void {
    const request: notificationManager.NotificationRequest = {
      id: id,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    try {
      notificationManager.publish(request)
        .then((): void => {
          hilog.info(DOMAIN, TAG, 'notification published id=%{public}d', id);
        })
        .catch((error: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, 'notification publish failed: %{public}s',
            error.message ?? '-');
        });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'notification publish threw: %{public}s',
        (error as Error).message);
    }
  }
}
