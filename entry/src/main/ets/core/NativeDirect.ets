/*
 * 私信（Direct）的取数与发送 —— **只走移动端私有接口**（core/mobileapi/MobileDirect）。
 *
 * ## 端点（instagrapi 同源）
 *   GET/POST `direct_v2/inbox/`                                    收件箱一页
 *   GET      `direct_v2/threads/{id}/`                             一条会话的消息
 *   POST     `direct_v2/threads/broadcast/text/`                   发一条文本
 *   POST     `direct_v2/threads/{tid}/items/{mid}/seen/`           标已读（见 MobileDirect.markSeen）
 *
 * 请求由 core/mobileapi 统一签名（App 身份 + `_uuid` / `_csrftoken` / `device_id` /
 * `X-IG-*` 头），**不需要网页模板、不需要 fb_dtsg、也不驱动隐藏网页**。
 *
 * ## 历史
 * 这里原来有三条基于网页模板的路：回放 `IGDThreadDetailQuery`、
 * `/api/v1/direct_v2/…` 的 REST 兜底（借 `NativeFeed.headersFor` 的网页头 + 安卓 UA 混搭）、
 * 以及"页面里用模板再发一次"的回放。页面注入退役之后模板抓不到、里面的会话令牌也早已过期，
 * 这三条一并删除。
 *
 * ## 本文件现在只剩什么
 *   · 把移动端那几发包一层"家族冷却"（`ApiThrottle.DIRECT`）与人速间隔（写操作）；
 *   · 失败原因记在 `lastDetail()` 里，界面状态行直接显示，不用翻日志。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from './ApiThrottle';
import { DirectInboxPage, DirectThreadView } from '../model/Direct';
import { MobileDirect } from './mobileapi/MobileDirect';
import { MobileRequest } from './mobileapi/MobileRequest';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeDirect';

export class NativeDirect {
  /** 上一次失败的原因（诊断：界面状态行直接用）。 */
  private static detail: string = '-';

  static lastDetail(): string {
    return NativeDirect.detail;
  }

  /**
   * 拉一页收件箱。
   *
   * @param after 翻页游标（空串 = 第一页）。
   */
  static async inbox(after: string): Promise<DirectInboxPage | null> {
    const cooled: string = NativeDirect.cooling('inbox');
    if (cooled.length > 0) {
      NativeDirect.detail = cooled;
      return null;
    }
    const page: DirectInboxPage | null = await MobileDirect.inbox(after);
    if (page === null) {
      NativeDirect.detail = NativeDirect.mobileDetail('inbox');
      return null;
    }
    NativeDirect.detail = '-';
    return page;
  }

  /**
   * 收件箱翻页（和 `inbox` 同一条路：移动端的游标就在查询串里，能真正翻页）。
   */
  static async inboxRest(cursor: string): Promise<DirectInboxPage | null> {
    return await NativeDirect.inbox(cursor);
  }

  /**
   * 读一条会话的消息。
   *
   * @param threadId   会话 id
   * @param olderCursor 上一页的游标（空串 = 最新一页）
   * @param altId      同一条会话的另一个 id（收件箱带过来的 `thread_key`）：第一个 id 读不出时再试它
   * @param priority   限速优先级
   * @param limit      每页条数（0 = 接口默认；预取会传 5）
   */
  static async thread(threadId: string, olderCursor: string,
                      altId: string = '',
                      priority: number = ApiThrottle.warm(),
                      limit: number = 0): Promise<DirectThreadView | null> {
    const id: string = threadId.trim();
    if (id.length === 0) {
      NativeDirect.detail = 'no-thread-id';
      return null;
    }
    const cooled: string = NativeDirect.cooling('thread');
    if (cooled.length > 0) {
      NativeDirect.detail = cooled;
      return null;
    }
    const view: DirectThreadView | null = limit > 0
      ? await MobileDirect.thread(id, olderCursor, priority, limit)
      : await MobileDirect.thread(id, olderCursor, priority);
    if (view !== null && view.messages.length > 0) {
      NativeDirect.detail = '-';
      hilog.info(DOMAIN, TAG, 'thread ok id=%{public}d msgs=%{public}d older=%{public}s',
        id.length, view.messages.length, `${view.hasOlder}`);
      return view;
    }
    /*
     * 第二个 id 再试一次：IG 有两个 id（`thread_id` 与 `thread_v2_id` / `thread_key`），
     * 收件箱给的和会话接口认的偶尔不是同一个 —— 一次额外的只读请求换"少一次读取失败"值得。
     */
    const alt: string = altId.trim();
    if (alt.length > 0 && alt !== id) {
      const second: DirectThreadView | null = limit > 0
        ? await MobileDirect.thread(alt, olderCursor, priority, limit)
        : await MobileDirect.thread(alt, olderCursor, priority);
      if (second !== null && second.messages.length > 0) {
        NativeDirect.detail = '-';
        hilog.info(DOMAIN, TAG, 'thread ok via alt id=%{public}d msgs=%{public}d',
          alt.length, second.messages.length);
        return second;
      }
    }
    NativeDirect.detail = NativeDirect.mobileDetail('thread');
    return view !== null ? view : null;
  }

  /**
   * 发一条文本私信（成功给 true）。
   *
   * 写操作先过人速间隔（见 `ApiThrottle.writeSlot`）：发消息是最容易被判成脚本的写操作，
   * 用户视角只是"发送中"多转一会儿圈。
   */
  static async sendText(threadId: string, text: string): Promise<boolean> {
    const id: string = threadId.trim();
    if (id.length === 0 || text.length === 0) {
      NativeDirect.detail = 'no-thread-or-text';
      hilog.warn(DOMAIN, TAG, 'send abort: empty thread=%{public}d text=%{public}d',
        id.length, text.length);
      return false;
    }
    await ApiThrottle.writeSlot();
    const cooled: string = NativeDirect.cooling('send');
    if (cooled.length > 0) {
      NativeDirect.detail = cooled;
      return false;
    }
    const ok: boolean = await MobileDirect.sendText(id, text);
    if (!ok) {
      NativeDirect.detail = NativeDirect.mobileDetail('send');
      return false;
    }
    NativeDirect.detail = '-';
    hilog.info(DOMAIN, TAG, 'send ok thread=%{public}d len=%{public}d', id.length, text.length);
    return true;
  }

  /** 家族冷却（见 core/ApiThrottle）。空串 = 可以发。 */
  private static cooling(label: string): string {
    if (!ApiThrottle.blocked(ApiThrottle.DIRECT)) {
      return '';
    }
    const minutes: number = ApiThrottle.remainingMinutes(ApiThrottle.DIRECT);
    hilog.warn(DOMAIN, TAG, '%{public}s skipped: direct family throttled %{public}dmin left',
      label, minutes);
    return `throttled-${minutes}min`;
  }

  /** 失败原因：优先用移动端那一层记的，其次给个可读的兜底。 */
  private static mobileDetail(label: string): string {
    const detail: string = MobileRequest.detail();
    if (detail.length > 0) {
      return detail;
    }
    const error: string = MobileRequest.error();
    return error.length > 0 ? `${label}-fail:${error}` : `${label}-fail`;
  }
}
