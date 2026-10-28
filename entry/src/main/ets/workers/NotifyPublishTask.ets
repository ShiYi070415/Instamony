/*
 * **在 taskpool 线程里发通知**（用户要求："通知器单独分配线程"）。
 *
 * 为什么：`notificationManager.publish` 走的是 IPC，冷启动/主线程忙（信息流渲染、解析、
 * 图片解码）时那一拍可能被排在后面，通知就"晚几秒才弹"。把它放到 taskpool，主线程再忙
 * 也不影响通知出现。
 *
 * ⚠️ ArkTS 限制：`@Concurrent` 函数**只能引用导入的符号或局部变量**，参数只传基本类型 ——
 * 所以这里用「id + 标题 + 正文 + 分类」四个值，不传 WantAgent（那是主线程的对象）。
 * 点通知直达会话的 wantAgent 由调用方在主线程"补一次同 id 的发布"来完成（覆盖，不重复提醒）。
 */
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

// 注意：`@Concurrent` 函数里**不能引用模块级常量**（编译期报 "should only use import
// variable or local variable"），所以日志域/标签只能写字面量。
@Concurrent
export async function publishNotificationTask(id: number, title: string, text: string,
                                              slot: number): Promise<boolean> {
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
      notificationSlotType: slot as notificationManager.SlotType
    };
    await notificationManager.publish(request);
    return true;
  } catch (error) {
    hilog.warn(0xFF00, 'NotifyPublishTask', 'publish failed: %{public}s',
      (error as Error).message ?? '-');
    return false;
  }
}
