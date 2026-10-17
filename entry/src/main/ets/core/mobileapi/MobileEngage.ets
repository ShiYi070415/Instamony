/*
 * 移动 API 的**写操作集合**（对应 instagrapi 的 MediaMixin / UserMixin / CommentMixin 里那几条 REST）。
 *
 * ## 这一层存在的理由
 * 原来这些动作都走 `bridge/ApiRegistry` 的**网页模板回放**（`LikeMediaXIG` / `SaveMedia` /
 * `friendships/create` / `comment` …）。模板是从隐藏网页里抓下来的，`doc_id` / `variables` /
 * `x-ig-www-claim` 会随页面重载失效；失效时 IG 常常回 **"HTTP 200 + 体内 errors"** 或一整页
 * HTML —— 老代码一律当成成功，于是"界面变了、服务端没收到"（点赞那条用户已经实测到）。
 *
 * 下面这几条都是**一发私有 REST、不需要任何模板**，和本项目已经跑通的快拍 / 私信 / 主页
 * 共用同一套身份（见 core/mobileapi/MobileRequest 的文件头）：
 *
 *   点赞 / 取消      POST media/{pk}/like/            POST media/{pk}/unlike/
 *   收藏 / 取消收藏  POST media/{pk}/save/            POST media/{pk}/unsave/
 *   关注 / 取关      POST friendships/create/{pk}/    POST friendships/destroy/{pk}/
 *   发评论           POST media/{pk}/comment/         （表单 comment_text / replied_to_comment_id）
 *   评论点赞         POST media/{pk}/comment_like/    POST media/{pk}/comment_unlike/
 *
 * ## 没有 REST 等价物的（只能继续走模板回放）
 *   · **转发**：IG 的转发只有 GraphQL（没有 media/repost 这类私有 REST）；
 *   · **信息流时间线**：官方 App 自己也走 GraphQL，没有对应 REST；
 *   · **通知**：`news/inbox/` 虽是 REST，但分页与形状和网页那套差别大，另开一轮再接。
 *
 * ## 成功判据一律是"HTTP 200 且体内没有 errors"
 * 这一条是为"200 但没生效"专门加的（见 setLiked 的注释）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileEngage';

export class MobileEngage {
  /**
   * 点赞 / 取消点赞（`media_id` 必须是**纯数字的 pk**）。
   *
   * @returns 成功（服务端已接受这次变更）返回 true；任何不确定的情况都返回 false，
   *          让调用方回滚界面并如实提示 —— 绝不假装成功。
   */
  static async setLiked(mediaId: string, like: boolean,
                        priority: number = ApiThrottle.interactive()): Promise<boolean> {
    const id: string = MobileEngage.numericId(mediaId);
    if (id.length === 0) {
      return false;
    }
    const ok: boolean = await MobileEngage.write(`media/${id}/${like ? 'like' : 'unlike'}/`,
      MobileEngage.mediaForm(id), like ? 'like' : 'unlike', priority);
    return ok;
  }

  /** 收藏 / 取消收藏（instagrapi 的 `media_save` / `media_unsave`）。 */
  static async setSaved(mediaId: string,
                        save: boolean, priority: number = ApiThrottle.interactive()): Promise<boolean> {
    const id: string = MobileEngage.numericId(mediaId);
    if (id.length === 0) {
      return false;
    }
    return await MobileEngage.write(`media/${id}/${save ? 'save' : 'unsave'}/`,
      MobileEngage.mediaForm(id), save ? 'save' : 'unsave', priority);
  }

  /** 关注 / 取关（instagrapi 的 `user_follow` / `user_unfollow`）。 */
  static async setFollowing(userId: string, follow: boolean,
                            priority: number = ApiThrottle.interactive()): Promise<boolean> {
    const id: string = MobileEngage.numericId(userId);
    if (id.length === 0) {
      return false;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return false;
    }
    const data: Record<string, Object> = MobileRequest.withActionData(identity);
    data['user_id'] = id;
    return await MobileEngage.write(`friendships/${follow ? 'create' : 'destroy'}/${id}/`,
      MobileRequest.formOf(data), follow ? 'follow' : 'unfollow', priority);
  }

  /** 发一条评论（instagrapi 的 `media_comment`）。 */
  static async postComment(mediaId: string, text: string, replyToCommentId: string = '',
                           priority: number = ApiThrottle.interactive()): Promise<boolean> {
    const id: string = MobileEngage.numericId(mediaId);
    const body: string = text.trim();
    if (id.length === 0 || body.length === 0) {
      return false;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return false;
    }
    const data: Record<string, Object> = MobileRequest.withActionData(identity);
    data['comment_text'] = body;
    if (replyToCommentId.length > 0) {
      data['replied_to_comment_id'] = replyToCommentId;
    }
    return await MobileEngage.write(`media/${id}/comment/`, MobileRequest.formOf(data), 'comment',
      priority);
  }

  /** 给评论点赞 / 取消（instagrapi 的 `comment_like` / `comment_unlike`）。 */
  static async setCommentLiked(mediaId: string, commentId: string, like: boolean,
                               priority: number = ApiThrottle.interactive()): Promise<boolean> {
    const id: string = MobileEngage.numericId(mediaId);
    const cid: string = MobileEngage.numericId(commentId);
    if (id.length === 0 || cid.length === 0) {
      return false;
    }
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      return false;
    }
    const data: Record<string, Object> = MobileRequest.withActionData(identity);
    data['comment_id'] = cid;
    return await MobileEngage.write(`media/${id}/comment_${like ? 'like' : 'unlike'}/`,
      MobileRequest.formOf(data), like ? 'comment-like' : 'comment-unlike', priority);
  }

  // ------------------------------------------------------------------ 内部

  /** 点赞/收藏这类"媒体级"写操作的表单（instagrapi 用 with_action_data + media_id）。 */
  private static mediaForm(mediaId: string): string {
    const data: Record<string, Object> = {};
    data['media_id'] = mediaId;
    return MobileRequest.formOf(data);
  }

  /**
   * 发一发写请求并给出**可信的**成败。
   *
   * 判据：`ok`（由 `MobileRequest.classify` 判，已涵盖 status:fail / 限流 / 未登录）
   * **且**体内没有 `errors`。后者是为"200 但没生效"专门加的（点赞那批实测见过）。
   */
  private static async write(endpoint: string, data: string, label: string,
                             priority: number): Promise<boolean> {
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, '%{public}s skipped: no session', label);
      return false;
    }
    /*
     * 写操作也要那串设备/会话字段（`_uid` / `_uuid` / `_csrftoken` / `device_id` / `guid` /
     * `phone_id`，见 MobileRequest.withExtraData）—— 官方 App 每一发都带。放在前面，
     * 调用方给的业务字段（`media_id` / `comment_text` …）接在后面。
     */
    const extra: string = MobileRequest.formOf(MobileRequest.withExtraData(identity));
    const payload: string = data.length > 0 ? `${extra}&${data}` : extra;
    const result: MobileResult = await MobileRequest.send(endpoint, payload, '', true, null,
      new MobileOptions(ApiThrottle.MOBILE, priority));
    const hasErrors: boolean = result.body.indexOf('"errors"') >= 0;
    const ok: boolean = result.ok && !hasErrors;
    hilog.info(DOMAIN, TAG, '%{public}s ok=%{public}s errors=%{public}s %{public}s',
      label, ok ? 'y' : 'n', hasErrors ? 'y' : 'n', result.summary());
    return ok;
  }

  /** 只接受纯数字 id（IG 的 pk；带指数/前缀的合成 id 一律拒绝，见 NativeSearch 的浮点坑）。 */
  private static numericId(raw: string): string {
    const id: string = (raw ?? '').trim();
    if (id.length === 0) {
      return '';
    }
    for (let index: number = 0; index < id.length; index++) {
      const ch: string = id.charAt(index);
      if (ch < '0' || ch > '9') {
        hilog.warn(DOMAIN, TAG, 'id not numeric, skipped: %{public}s', id.substring(0, 24));
        return '';
      }
    }
    return id;
  }
}
