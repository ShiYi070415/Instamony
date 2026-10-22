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
   * shortcode → 媒体数字 pk 的缓存（见 `mediaPkFor`）。
   *
   * 为什么需要这张表：从**个人页那几个分页**（帖子 / 视频 / 收藏 / 被标注）进来的条目，
   * 载荷里常常没有可用的媒体 id —— 移动端 REST 给的是 `pk`（19 位 number，JSON.parse 之后
   * **已经丢精度**）和 `id`（`<媒体id>_<作者id>` 字符串，这个才是精确的），而模板/网页那条
   * 更惨，只有 `shortcode`。用户报的"我的页面四个分页的 feeds 页和 reels 页点赞状态不对 /
   * 点赞没绑定"就是这个：拿不到数字 id 时点赞**根本没发出去**。
   * shortcode 在每种载荷里都有，所以用它去问一次 oembed 把 pk 换回来，换到的记在这里。
   */
  private static pks: Map<string, string> = new Map<string, string>();

  /**
   * 一条媒体的短码链接（`oembed` 与网页都认这个形状）。
   *
   * 视频帖子在 IG 的规范链接是 `/reel/<code>/`，图片/多图是 `/p/<code>/`；
   * 两个在 oembed 那边都能解析，这里统一用 `/p/`（不必知道是不是视频）。
   */
  static linkOf(shortcode: string): string {
    const code: string = (shortcode ?? '').trim();
    return code.length === 0 ? '' : `https://www.instagram.com/p/${encodeURIComponent(code)}/`;
  }

  /**
   * shortcode → 媒体数字 pk（`GET oembed/?url=<短码链接>`，instagrapi 的 `media_pk_from_code`）。
   *
   * 成功就缓存；失败返回空串（调用方当成"这条没有 id"，照旧回滚并如实提示）。
   */
  static async mediaPkFor(shortcode: string): Promise<string> {
    const code: string = (shortcode ?? '').trim();
    if (code.length === 0) {
      return '';
    }
    const known: string | undefined = MobileEngage.pks.get(code);
    if (known !== undefined) {
      return known;
    }
    const link: string = MobileEngage.linkOf(code);
    const result: MobileResult = await MobileRequest.send('oembed/', '', `url=${encodeURIComponent(link)}`,
      true, null, new MobileOptions(ApiThrottle.MOBILE, ApiThrottle.interactive()));
    if (!result.ok) {
      hilog.info(DOMAIN, TAG, 'oembed code=%{public}s failed %{public}s', code, result.summary());
      return '';
    }
    const id: string = MobileEngage.parseOembedId(result.body);
    if (id.length === 0) {
      hilog.info(DOMAIN, TAG, 'oembed code=%{public}s no media_id body=%{public}s',
        code, result.body.substring(0, 120));
      return '';
    }
    MobileEngage.pks.set(code, id);
    hilog.info(DOMAIN, TAG, 'oembed code=%{public}s → pk=%{public}s', code, id);
    return id;
  }

  /**
   * 已经给的 id 能用就用它，不能（空 / 带前缀 / 非数字）再按 shortcode 换一个。
   *
   * 这是**所有写操作统一的前置**：个人页那几个分页的 id 多半是 `profile-<code>` 这种占位串
   * 或者整段缺失，先换回真 pk 才发得出去。
   */
  static async mediaIdOf(raw: string, shortcode: string): Promise<string> {
    const direct: string = MobileEngage.numericId(raw);
    if (direct.length > 0) {
      return direct;
    }
    return await MobileEngage.mediaPkFor(shortcode);
  }

  /** 点赞 / 取消点赞（`media_id` 必须是**纯数字的 pk**）。
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

  /** oembed 返回里的 `media_id`（字符串，个别情况下是 number）。 */
  private static parseOembedId(body: string): string {
    try {
      const root: Object = JSON.parse(body);
      const box: Record<string, Object> = root as Record<string, Object>;
      const value: Object | undefined = box['media_id'];
      if (value === undefined || value === null) {
        return '';
      }
      return MobileEngage.numericId(`${value}`);
    } catch (error) {
      return '';
    }
  }

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

  /**
   * 只接受 IG 的数字 pk；`<媒体pk>_<作者pk>` 这种**规范形状取 `_` 前面那段**。
   *
   * 为什么必须认后一种：移动端接口给的媒体 `id` 就是这个形状 —— 真机日志里
   * `id not numeric, skipped: 3999089584633758181_6752`，而 REST 的
   * `media/{pk}/like/` 要的正是 `_` 前面那 19 位（instagrapi 的 `media_pk`
   * 也是同一个取法：`id.split('_')[0]`）。以前一律拒绝，于是信息流里的点赞会静默回退到
   * "让隐藏网页去点"那条老路，还先白打一发 `oembed/`（换 id 也换不出来：
   * 那条端点对部分帖子根本不回 `media_id`）。
   *
   * 其余非数字（`profile-<code>` 这类占位串、短码）照旧拒绝，交给 shortcode 那条路去换。
   */
  private static numericId(raw: string): string {
    const text: string = (raw ?? '').trim();
    if (text.length === 0) {
      return '';
    }
    const cut: number = text.indexOf('_');
    const id: string = cut > 0 ? text.substring(0, cut) : text;
    for (let index: number = 0; index < id.length; index++) {
      const ch: string = id.charAt(index);
      if (ch < '0' || ch > '9') {
        hilog.warn(DOMAIN, TAG, 'id not numeric, skipped: %{public}s', text.substring(0, 24));
        return '';
      }
    }
    return id;
  }
}
