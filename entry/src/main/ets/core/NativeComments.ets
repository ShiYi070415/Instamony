/*
 * 评论的**原生 HTTP**取数（`GET /api/v1/media/{id}/comments/`）。
 *
 * ## 为什么要它
 * 评论原来只有两条路，都要**隐藏网页**：
 *   1. 页面里已经缓存过"评论请求"的模板时回放一次（`commentsByStoredCfgScript`）；
 *   2. 没有模板就导航到帖子页、等页面自己发请求、再把响应读出来（`commentsOnPostPageScript`）。
 * 第 2 条要整页导航 + 等水合 + 等它自己请求，实测几秒起步、还常常 `state=timeout`。
 * 而这条 REST 端点是**公开形状**的：只要 Cookie + csrf（见 core/RestSession），
 * 原样 GET 就能拿到评论列表 —— 和 `/api/v1/media/{id}/info/`（补视频地址那条）同一个套路，
 * 那条已经真机验证可用。所以这里补上"原生直发"这条最快的路。
 *
 * ## 响应形状（真机抓包 + 实测）
 *   {"comments":[{"pk":"…","text":"…","comment_like_count":3,
 *                 "user":{"username":"…","profile_pic_url":"…"},"child_comment_count":0}],
 *    "next_max_id":"…","has_more_comments":true,"comment_count":42,"status":"ok"}
 * 字段全按 `?? 空` 兜底：IG 各版本会缺字段，缺了不该整条读不出来。
 *
 * ## 失败一律给 null / state=error
 * 调用方（pages/Index.openComments）照着"原生 → 页面回放 → 导航"的顺序退，所以这里
 * **不抛异常、不阻塞**：拿不到就当场说拿不到，让上面换下一条路。
 */

import { http } from '@kit.NetworkKit';
import { MobileEngage } from './mobileapi/MobileEngage';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CommentsPayload, CommentItem } from '../model/Comment';
import { RestSession } from './RestSession';
import { JsonRead } from './JsonRead';
import { ApiThrottle } from './ApiThrottle';
// 评论的移动端私有通道（对应 instagrapi 的 media_comments_v1_chunk，不需要网页模板）。
import { MobileComments } from './mobileapi/MobileComments';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeComments';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 12000;
/**
 * 移动端 App 的身份（评论点赞那条私有端点会校验客户端指纹，回 `useragent mismatch`）。
 *
 * URL / 头 / 表单体都照 instagrapi 的 comment_like 那套；UA 里的版本号跟 IG 发版走，
 * 太旧会被判 `unsupported_version` —— 这里取一个较新的值，失败也只影响这一次点赞
 * （前面几条候选与网页兜底还在）。
 */
const APP_UA: string = 'Instagram 448.0.0.52.84 Android (34/14; 480dpi; 1080x2340; '
  + 'samsung; SM-S918B; dm3q; qcom; en_US; 632518945)';
/** 移动端 App 的 `x-ig-app-id`（网页那个是 1217981644879628）。 */
const APP_ID: string = '567067343352427';

  /**
   * 一张贴图（地址 + 它自己的宽高）。
   *
   * 宽高是需求"**不超过 1:1 的不用添加上下黑边、横向沾满正文区**"的依据：
   * 知道比例才能让盒子按比例铺满宽度（不知道比例就只能塞进方盒子里留黑边）。
   * 接口没给尺寸时是 0（那种仍按方盒 + 完整显示处理）。
   */
class CommentImage {
  readonly url: string;
  readonly w: number;
  readonly h: number;

  constructor(url: string, w: number, h: number) {
    this.url = url;
    this.w = w;
    this.h = h;
  }
}

/** 响应里的一条评论（只列要用的字段）。 */
interface CommentUserDto {
  pk?: string | number | null;
  username?: string | null;
  profile_pic_url?: string | null;
}

interface CommentDto {
  pk?: string | number | null;
  text?: string | null;
  comment_like_count?: number | null;
  child_comment_count?: number | null;
  /** 发布时间（Unix 秒）——面板显示"多久之前"用。 */
  created_at?: number | null;
  /** 接口顺带给的回复预览（0~2 条）：展开回复时先显示它，见 toItem。 */
  preview_child_comments?: Array<CommentDto> | null;
  user?: CommentUserDto | null;
}
interface CommentsDto {
  status?: string;
  comments?: Array<CommentDto> | null;
  next_max_id?: string | null;
  /**
   * 头部加载（默认那种）的游标。
   *
   * 真机实测：第一页回来的是 `has_more_headload_comments=true` + **`next_min_id`**，
   * 而 `next_max_id` 是空的 —— 只认后者就会"永远只加载一页"（`has_more_comments` 那条
   * 是尾部翻页用的，走 `max_id`）。instagrapi 的 media_comments 也是两个都认。
   */
  next_min_id?: string | null;
  has_more_comments?: boolean | null;
  has_more_headload_comments?: boolean | null;
  comment_count?: number | null;
  message?: string | null;
}

export class NativeComments {
  /** 上一次失败的原因（诊断用，同 NativeMediaInfo.detail）。 */
  private static detail: string = '-';
  /** 上一次读到的**评论总数**（`comment_count`；没给就是 -1）。列表里那颗计数可以拿它对一下。 */
  private static total: number = -1;
  /** 诊断：正文读不出来的那几条长什么样（见 parse）。 */
  private static noTextSample: string = '';
  /** 上一次评论点赞走的哪条路（诊断，见 like）。 */
  private static likeVia: string = '-';
  /** 上一次评论数据来自哪条路（mobile / rest / graphql，见 fetch）。 */
  private static source: string = '-';
  /**
   * **迁移期对照开关**：true = 只走移动端那条（不走 REST / GraphQL 兜底）。
   *
   * 存在的意义只有一个：验证"**没有网页模板也能取评论**"（这是把评论从抓包迁出来的前提）。
   * 平时 false（两条并存，移动端失败自动退回）；确认稳定后可以把兜底整段删掉。
   */
  private static mobileOnly: boolean = false;
  /** 这次会话里评论用的是不是 GraphQL 那条（决定翻页跟着哪条游标走，见 fetch）。 */
  private static useGraphql: boolean = false;
  /** 翻页游标是 `min_id`（头部加载）还是 `max_id`（尾部）：由第一页决定。 */
  private static cursorMin: boolean = false;
  /** 诊断：贴图字段认不出形状时，把那个容器的键记一条（见 findImage）。 */
  private static imgDiag: string = '';
  /**
   * 网页那条评论 GraphQL 的 doc_id。
   *
   * 跟 IG 前端发版轮换（同 EngageSkeleton 里那几个 doc_id 的性质）；失效时这一发失败，
   * 调用方保留 REST 那份结果。当前值取自 instagrapi 的 `MEDIA_COMMENTS_DOC_ID`。
   */
  private static readonly COMMENTS_DOC: string = '6974885689225067';

  static lastDetail(): string {
    return NativeComments.detail;
  }

  /** 上一次响应里的评论总数（-1 = 这条响应没给）。 */
  static lastTotal(): number {
    return NativeComments.total;
  }

  /**
   * 取一条媒体的评论。
   *
   * **两条数据源，先私有 REST 再看网页 GraphQL**：
   *   - `GET /api/v1/media/{id}/comments/`（快，一次往返）；
   *   - 真机实测这条 REST 对**不少评论回 `text:""`**（用户报的"大部分评论只有头像和 id、
   *     没有正文"就是它）—— 这时补一发网页那条 GraphQL（`/graphql/query`，doc_id 见
   *     COMMENTS_DOC），它给的是网页自己渲染用的那份，正文齐全。哪条正文更全就用哪条，
   *     由 `lastSource()` 说出来。
   *
   * @param mediaId 媒体的**数字 id**（`Reel.mediaId` / `MediaPost.id` 里 `_` 前面那段）。
   * @param maxId   翻页游标（第一页传空串）。
   * @returns 拿到了给 `state='ok'`（哪怕一条评论都没有，`items` 是空数组）；
   *          这一类失败给 null（没有会话 / 非 200 / 不是 JSON / 被限流）。
   */
  static async fetch(mediaId: string, maxId: string = ''): Promise<CommentsPayload | null> {
    NativeComments.total = -1;
    NativeComments.noTextSample = '';
    NativeComments.imgDiag = '';
    const id: string = NativeComments.pureId(mediaId);
    if (id.length === 0) {
      NativeComments.detail = 'no-media-id';
      return null;
    }
    if (ApiThrottle.blocked(ApiThrottle.COMMENTS)) {
      NativeComments.detail = 'rate-limited';
      hilog.info(DOMAIN, TAG, 'comments skipped: rate limited %{public}dmin left',
        ApiThrottle.remainingMinutes(ApiThrottle.COMMENTS));
      return null;
    }
    if (maxId.length === 0) {
      // 第一页：数据源还没定，先按 REST 走（见下）。
      NativeComments.useGraphql = false;
      NativeComments.source = '-';
    } else if (NativeComments.useGraphql) {
      // 翻页要**跟着第一页那条数据源**（游标是那一条给的，换源就翻不动了）。
      const more: CommentsPayload | null = await NativeComments.fetchViaGraphql(id, maxId);
      if (more !== null) {
        NativeComments.source = 'graphql';
        return more;
      }
      NativeComments.useGraphql = false;
    }
    /*
     * **先走移动端私有通道**（见 core/mobileapi/MobileComments）：
     * 与 instagrapi 的 `media_comments_v1_chunk` 同一个端点、同一套 App 身份，
     * **不需要任何网页模板** —— 这是"评论不再依赖抓包"的那一步。
     * 失败（无会话/非 200/被限流）再退回下面网页那条 REST（迁移期两条并存）。
     */
    const viaMobile: CommentsPayload | null = await NativeComments.fetchViaMobile(id, maxId);
    if (viaMobile !== null && viaMobile.state === 'ok') {
      NativeComments.source = 'mobile';
      if (maxId.length === 0) {
        NativeComments.cursorMin = viaMobile.nextMin === true;
      }
      return viaMobile;
    }
    // 迁移期的对照开关：打开后只走移动端（用来验证"没有模板也能取评论"）。
    if (NativeComments.mobileOnly) {
      NativeComments.detail = `mobile-only:${MobileComments.detail()}`;
      hilog.warn(DOMAIN, TAG, 'comments mobile-only failed: %{public}s',
        MobileComments.detail());
      return viaMobile;
    }
    const rest: CommentsPayload | null = await NativeComments.fetchViaRest(id, maxId);
    if (rest === null || rest.state !== 'ok') {
      return rest;
    }
    // 记下游标种类（min_id / max_id）：翻页要照着它拼（见 fetchViaRest）。
    if (maxId.length === 0) {
      NativeComments.cursorMin = rest.nextMin === true;
    }
    // 第一页的 REST 到手了：正文缺得多就再问一次网页那条 GraphQL（它那份是渲染用的，正文齐全）。
    const missing: number = NativeComments.emptyTexts(rest);
    if (missing > 0 && maxId.length === 0) {
      const gql: CommentsPayload | null = await NativeComments.fetchViaGraphql(id, '');
      if (gql !== null && gql.state === 'ok'
        && NativeComments.emptyTexts(gql) < missing) {
        NativeComments.source = 'graphql';
        NativeComments.useGraphql = true;
        hilog.info(DOMAIN, TAG, 'comments src=graphql n=%{public}d noText %{public}d→%{public}d',
          (gql.items ?? []).length, missing, NativeComments.emptyTexts(gql));
        return gql;
      }
      hilog.info(DOMAIN, TAG, 'comments src=rest n=%{public}d noText=%{public}d (graphql %{public}s)',
        (rest.items ?? []).length, missing, gql === null ? 'null' : `${NativeComments.emptyTexts(gql)}`);
    }
    NativeComments.source = 'rest';
    return rest;
  }

  /** 上一次评论数据来自哪条路（rest / graphql / -）。 */
  static lastSource(): string {
    return NativeComments.source;
  }

  /**
   * 这份结果里有多少条**既没正文、也没贴图**（用来判断要不要换数据源）。
   *
   * 只数这种：GIF/图片评论**本来就**没有正文（`text:""` + `giphy_media_info`/`media_comment_info`），
   * 把它们算进"缺正文"会让每开一次评论都白问一次 GraphQL。真正可疑的是"没正文也没图"。
   */
  private static emptyTexts(payload: CommentsPayload): number {
    const items: Array<CommentItem> = payload.items ?? [];
    let count: number = 0;
    for (let index: number = 0; index < items.length; index++) {
      const one: CommentItem = items[index];
      if (one.text.length === 0 && (one.imageUrl ?? '').length === 0) {
        count++;
      }
    }
    return count;
  }

  /** 私有 REST：`GET /api/v1/media/{id}/comments/`（**移动端身份**，见 core/mobileapi/MobileComments）。 */
  private static async fetchViaMobile(id: string, maxId: string): Promise<CommentsPayload | null> {
    const body: string | null = await MobileComments.page(id, maxId, NativeComments.cursorMin);
    if (body === null) {
      return null;
    }
    const payload: CommentsPayload | null = NativeComments.parse(body);
    if (payload === null) {
      return null;
    }
    hilog.info(DOMAIN, TAG,
      'comments(mobile) id=%{public}s n=%{public}d total=%{public}d more=%{public}s',
      id, (payload.items ?? []).length, NativeComments.total, `${payload.hasMore}`);
    return payload;
  }

  /** 私有 REST：`GET /api/v1/media/{id}/comments/`。 */
  private static async fetchViaRest(id: string, maxId: string): Promise<CommentsPayload | null> {
    const headers: Record<string, string> = await RestSession.headers();
    if (Object.keys(headers).length === 0) {
      NativeComments.detail = 'no-session';
      return null;
    }
    // can_support_threading / permalink_enabled 是网页自己那两条查询串，照抄；
    // 少了它们 IG 会给一版**不含回复**的旧结构（实测字段名都还在，但顺带带上最稳）。
    let url: string = `https://www.instagram.com/api/v1/media/${encodeURIComponent(id)}`
      + `/comments/?can_support_threading=true&permalink_enabled=false`;
    if (maxId.length > 0) {
      // 头部加载那条用 min_id（见 CommentsDto 的说明）。
      url += NativeComments.cursorMin
        ? `&min_id=${encodeURIComponent(maxId)}`
        : `&max_id=${encodeURIComponent(maxId)}`;
    }
    const text: string = await NativeComments.get(url, headers);
    if (text.length === 0) {
      return null;
    }
    const payload: CommentsPayload | null = NativeComments.parse(text);
    hilog.info(DOMAIN, TAG, 'comments id=%{public}s state=%{public}s n=%{public}d total=%{public}d detail=%{public}s',
      id, payload === null ? 'null' : payload.state, payload === null ? 0 : (payload.items ?? []).length,
      NativeComments.total, NativeComments.detail);
    return payload;
  }

  /**
   * 网页那条 GraphQL 评论查询（`/graphql/query`，doc_id 见 COMMENTS_DOC）。
   *
   * doc_id 是**包的常量**（同 EngageSkeleton 那套：跟着 IG 前端发版轮换，换掉之后这一发会失败，
   * 调用方保留 REST 那份结果，不影响可用性）。
   * 响应的连接键名各版本不同（`xdt_api__v1__media__media_id__comments__connection` / …），
   * 所以**不写死键名**：在 `data` 下找第一个带 `edges` 的对象，逐条读 node。
   */
  private static async fetchViaGraphql(mediaId: string, after: string): Promise<CommentsPayload | null> {
    const headers: Record<string, string> = await RestSession.headers();
    if (Object.keys(headers).length === 0) {
      return null;
    }
    const tokens: string = await RestSession.formTokens();
    const cursor: string = after.length > 0 ? `"${after}"` : 'null';
    const vars: string = `{"after":${cursor},"before":null,"first":24,"last":null,`
      + `"media_id":"${mediaId}","sort_order":"popular"}`;
    const base: string = `doc_id=${NativeComments.COMMENTS_DOC}`
      + `&variables=${encodeURIComponent(vars)}&server_timestamps=true`;
    const body: string = tokens.length > 0 ? `${base}&${tokens}` : base;
    const text: string = await NativeComments.postText('https://www.instagram.com/graphql/query',
      headers, body, 'gql-comments');
    if (text.length === 0) {
      return null;
    }
    const dto: Record<string, Object> = JsonRead.parse(text);
    const data: Record<string, Object> | null = JsonRead.recordOf(dto, 'data');
    if (data === null) {
      return null;
    }
    const keys: Array<string> = Object.keys(data);
    for (let index: number = 0; index < keys.length; index++) {
      const conn: Record<string, Object> | null = JsonRead.recordOf(data, keys[index]);
      if (conn === null) {
        continue;
      }
      const edges: Array<Object> = JsonRead.arrayOf(conn, 'edges');
      if (edges.length === 0) {
        continue;
      }
      const items: Array<CommentItem> = [];
      for (let at: number = 0; at < edges.length; at++) {
        const edge: Record<string, Object> | null = JsonRead.asRecord(edges[at]);
        const node: Record<string, Object> | null = edge === null ? null : JsonRead.recordOf(edge, 'node');
        if (node === null) {
          continue;
        }
        items.push(NativeComments.fromGraphqlNode(node));
      }
      if (items.length > 0) {
        const page: Record<string, Object> | null = JsonRead.recordOf(conn, 'page_info');
        const cursor: string = page === null ? '' : JsonRead.strOf(page, 'end_cursor');
        const more: boolean = page !== null && JsonRead.boolOf(page, 'has_next_page');
        return { state: 'ok', items: items, diag: `graphql key=${keys[index]}`,
          nextMaxId: cursor, hasMore: more };
      }
    }
    return null;
  }

  /** GraphQL 的一个评论 node → CommentItem（字段名与 REST 那份基本一致）。 */
  private static fromGraphqlNode(node: Record<string, Object>): CommentItem {
    const user: Record<string, Object> | null = JsonRead.recordOf(node, 'user');
    const id: Object = node['pk'] ?? node['id'] ?? '';
    const body: string = NativeComments.textOf(node);
    // 图片评论在这条 GraphQL 里也可能是空正文（同 REST 那份，见 findImage）。
    const image: CommentImage = body.length === 0
      ? NativeComments.findImage(node as CommentDto) : NativeComments.emptyImage();
    if (body.length === 0 && image.url.length === 0 && NativeComments.imgDiag.length === 0) {
      const info: Record<string, Object> | null = JsonRead.recordOf(node, 'media_comment_info');
      NativeComments.imgDiag = info === null
        ? `gql node keys=${Object.keys(node).join(',')}`
        : `gql media_comment_info keys=${Object.keys(info).join(',')}`;
      hilog.info(DOMAIN, TAG, 'sticker shape(gql) %{public}s', NativeComments.imgDiag);
    }
    return {
      username: user === null ? '' : JsonRead.strOf(user, 'username'),
      // 作者数字 id（同 REST 那条；评论面板点头像/用户名要开 TA 的主页）。
      userId: user === null ? '' : `${user['pk'] ?? user['id'] ?? ''}`.trim(),
      text: body,
      avatar: user === null ? '' : JsonRead.strOf(user, 'profile_pic_url'),
      likes: JsonRead.numOf(node, 'comment_like_count'),
      pk: `${id}`.trim(),
      liked: JsonRead.boolOf(node, 'has_liked_comment'),
      imageUrl: image.url,
      mediaW: image.w,
      mediaH: image.h,
      // 下挂回复：总数 + 接口自带的预览（见 toItem 的说明）。
      repliesCount: JsonRead.numOf(node, 'child_comment_count'),
      replies: NativeComments.graphqlReplies(node),
      // 发布时间（Unix 秒）。
      createdAt: JsonRead.numOf(node, 'created_at')
    };
  }

  /**
   * GraphQL 评论节点里的**回复预览**（`preview_child_comments`）。
   *
   * 各版本形状不一：有的是节点数组，有的是 `{edges:[{node:…}]}` 连接。两种都认，
   * 认不出来就返回空数组（展开时再去要全部，见 childComments）。
   */
  private static graphqlReplies(node: Record<string, Object>): Array<CommentItem> {
    const raw: Object = node['preview_child_comments'] ?? node['child_comments'] ?? [];
    if (raw === null || raw === undefined) {
      return [];
    }
    let list: Array<Object> = [];
    if (Array.isArray(raw)) {
      list = raw as Array<Object>;
    } else {
      const boxed: Record<string, Object> | null = JsonRead.recordOf(node, 'preview_child_comments');
      if (boxed !== null) {
        const edges: Object = boxed['edges'] ?? [];
        list = Array.isArray(edges) ? (edges as Array<Object>) : [];
      }
    }
    const out: Array<CommentItem> = [];
    for (let index: number = 0; index < list.length; index++) {
      const one: Object = list[index];
      let record: Record<string, Object> | null = null;
      try {
        record = one as Record<string, Object>;
      } catch (error) {
        record = null;
      }
      if (record === null) {
        continue;
      }
      // `{edges:[{node:{…}}]}` 那种要先取 node。
      const inner: Record<string, Object> | null = JsonRead.recordOf(record, 'node');
      out.push(NativeComments.fromGraphqlNode(inner === null ? record : inner));
    }
    return out;
  }

  /**
   * **给一条评论点赞 / 取消点赞**（用户报的"评论点赞实现一下"）。
   *
   * 端点（按 instagrapi 的实现，见 https://github.com/subzeroid/instagrapi 的 comment_like）：
   *   `POST /api/v1/media/{评论id}/comment_like/` 与 `.../comment_unlike/`
   * —— 注意路径里那段是**评论 id**，不是媒体 id（第一次写成了媒体 id，IG 回
   * `400 {"message":"useragent mismatch"}`，看着像 UA 问题，其实是路由对不上）。
   * 另外再留一条网页路径 `/api/v1/web/comments/{评论id}/like|unlike/` 当候选（IG 换实现时先撞上它）。
   *
   * 会话、csrf、`x-instagram-ajax` 都走 RestSession 那套头；请求体沿用网页那两个表单令牌
   * （`fb_dtsg`/`jazoest`/`lsd`），再补上 IG 自己会在动作请求里带的几个上下文参数
   * （`is_carousel_bumped_post` / `container_module` / `feed_position`）。
   *
   * @param commentPk 评论的数字 id（列表里那条的 `pk`；空 = 没法点，调用方别发）。
   * @param like      true = 点赞，false = 取消。
   * @param mediaId   这条评论所属的媒体 id（诊断用；不再拼进路径）。
   * @returns 真的成功了给 true；全都失败给 false（调用方据此回滚乐观状态）。
   */
  static async like(commentPk: string, like: boolean, mediaId: string = ''): Promise<boolean> {
    /*
     * **移动端 REST 优先**（见 core/mobileapi/MobileEngage）：
     * media/{pk}/comment_like|comment_unlike/，不需要网页模板。失败再走原路。
     */
    try {
      const mobileOk: boolean = await MobileEngage.setCommentLiked(mediaId, commentPk, like);
      if (mobileOk) {
        return true;
      }
    } catch (error) {
    }
    const id: string = commentPk.trim();
    if (id.length === 0) {
      NativeComments.likeVia = 'no-comment-id';
      return false;
    }
    const headers: Record<string, string> = await RestSession.headers();
    if (Object.keys(headers).length === 0) {
      NativeComments.likeVia = 'no-session';
      return false;
    }
    const tokens: string = await RestSession.formTokens();
    const action: string = like ? 'like' : 'unlike';
    const extra: string = 'is_carousel_bumped_post=false'
      + '&container_module=feed_contextual_self_profile&feed_position=1';
    const api: string = `https://www.instagram.com/api/v1/media/${encodeURIComponent(id)}/comment_${action}/`;
    const apiBody: string = tokens.length > 0 ? `${tokens}&${extra}` : extra;
    /*
     * **先按 App 的身份发**（实测这条端点的正主）：
     *   - 带网页 UA 打同一个地址 → `400 {"message":"useragent mismatch"}`；
     *   - 换成 App 的 UA + app-id → `200 {"status":"ok"}`（真机验证）。
     * 所以 App 身份放第一个，其余两条留作 IG 改实现时的候选。
     * 只这一条请求换身份，别的请求仍是网页会话。
     */
    const appHeaders: Record<string, string> = {};
    const appKeys: Array<string> = Object.keys(headers);
    for (let index: number = 0; index < appKeys.length; index++) {
      appHeaders[appKeys[index]] = headers[appKeys[index]];
    }
    appHeaders['user-agent'] = APP_UA;
    appHeaders['x-ig-app-id'] = APP_ID;
    if (await NativeComments.post(api, appHeaders, apiBody, 'app-ua')) {
      NativeComments.likeVia = `appUA:comment_${action}`;
      return true;
    }
    // 候选 2/3：同一个地址用网页身份（IG 把这条收回网页实现时用）。
    if (await NativeComments.post(api, headers, apiBody, 'private')) {
      NativeComments.likeVia = `private:comment_${action}`;
      return true;
    }
    // 候选 4：网页那条 REST（历史实现）。
    const web: string = `https://www.instagram.com/api/v1/web/comments/${encodeURIComponent(id)}/${action}/`;
    const webBody: string = tokens.length > 0 ? `${tokens}&${extra}` : extra;
    if (await NativeComments.post(web, headers, webBody, 'web')) {
      NativeComments.likeVia = `web:${action}`;
      return true;
    }
    hilog.info(DOMAIN, TAG, 'like all candidates failed pk=%{public}s media=%{public}s like=%{public}s',
      id, mediaId, `${like}`);
    return false;
  }

  /** 上一次评论点赞走的是哪条路（诊断）。 */
  static lastLikeVia(): string {
    return NativeComments.likeVia;
  }

  /** 发一次写请求（POST，表单体）；成功 = HTTP 200 + 响应里有 `"status":"ok"`。 */
  private static async post(url: string, headers: Record<string, string>, body: string,
                            tag: string): Promise<boolean> {
    const text: string = await NativeComments.postText(url, headers, body, tag);
    if (text.length === 0) {
      return false;
    }
    return text.indexOf('"status":"ok"') >= 0;
  }

  /**
   * 发一次 POST（表单体），返回响应文本（失败给空串）。
   *
   * @param tag 日志里的标记（哪条候选/哪条路）。
   */
  private static async postText(url: string, headers: Record<string, string>, body: string,
                                tag: string): Promise<string> {
    const merged: Record<string, string> = {};
    const keys: Array<string> = Object.keys(headers);
    for (let index: number = 0; index < keys.length; index++) {
      merged[keys[index]] = headers[keys[index]];
    }
    merged['content-type'] = 'application/x-www-form-urlencoded';
    merged['x-requested-with'] = 'XMLHttpRequest';
    return await NativeComments.request(url, merged, true, body, tag);
  }

  /** 发一次 GET；失败给空串并把原因记在 detail 里。 */
  private static async get(url: string, headers: Record<string, string>): Promise<string> {
    return await NativeComments.request(url, headers, false, '', 'get');
  }

  /**
   * 真正那一次 http 调用（GET / POST 只差 method 与 body）。
   *
   * @param post **显式传**这是不是写请求（审计 E13）。
   *
   * 原来是 `const post = body.length > 0` 推断出来的：体为空的写请求
   * （变更全在 URL 参数上、体是空串）会被发成 **GET** —— 服务端按只读路由处理，
   * 回 200 但什么都没改，界面上就是"点了没反应"这类最难查的静默失败。
   */
  private static async request(url: string, headers: Record<string, string>, post: boolean,
                               body: string, tag: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: post ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        extraData: post && body.length > 0 ? body : undefined,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const code: number = response.responseCode;
      const looksJson: boolean = text.indexOf('"comments"') >= 0
        || text.indexOf('"status":"ok"') >= 0
        || text.indexOf('"data"') >= 0;
      hilog.info(DOMAIN, TAG, 'rsp %{public}s via=%{public}s code=%{public}d json=%{public}s len=%{public}d',
        post ? 'POST' : 'GET', tag, code, `${looksJson}`, text.length);
      if (ApiThrottle.looksLimited(text)) {
        ApiThrottle.note(ApiThrottle.COMMENTS);
        NativeComments.detail = 'rate-limited';
        return '';
      }
      if (code === 200 && looksJson) {
        if (NativeComments.detail !== 'rate-limited') {
          NativeComments.detail = '-';
        }
        return text;
      }
      NativeComments.detail = `http-${code}${looksJson ? '' : '/non-json'}`;
      if (!looksJson) {
        hilog.warn(DOMAIN, TAG, 'body via=%{public}s: %{public}s', tag,
          text.substring(0, 140).replace(/[\r\n]+/g, ' '));
      }
      return '';
    } catch (error) {
      NativeComments.detail = `throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60);
      return '';
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** `<媒体id>_<作者id>` 取前半段；非数字的（占位串）当"不知道"。 */
  private static pureId(raw: string): string {
    const one: string = raw.trim();    const cut: number = one.indexOf('_');
    const pure: string = cut > 0 ? one.substring(0, cut) : one;
    if (pure.length === 0) {
      return '';
    }
    for (let index: number = 0; index < pure.length; index++) {
      const ch: string = pure.charAt(index);
      if (ch < '0' || ch > '9') {
        return '';
      }
    }
    return pure;
  }

  /** 发一次 GET；失败给空串并把原因记在 detail 里。 */
  private static async send(url: string, headers: Record<string, string>): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const code: number = response.responseCode;
      const looksJson: boolean = text.indexOf('"comments"') >= 0;
      hilog.info(DOMAIN, TAG, 'rsp GET code=%{public}d json=%{public}s len=%{public}d',
        code, `${looksJson}`, text.length);
      if (ApiThrottle.looksLimited(text)) {
        ApiThrottle.note(ApiThrottle.COMMENTS);
        NativeComments.detail = 'rate-limited';
        hilog.warn(DOMAIN, TAG, 'comments rate limited → back off %{public}min',
          ApiThrottle.remainingMinutes(ApiThrottle.COMMENTS));
        return '';
      }
      if (code === 200 && looksJson) {
        NativeComments.detail = '-';
        return text;
      }
      NativeComments.detail = `http-${code}${looksJson ? '' : '/non-json'}`;
      if (!looksJson) {
        // 非 JSON 多半是被当成页面导航（缺会话头）—— 记一小段原始内容好定位。
        hilog.warn(DOMAIN, TAG, 'body: %{public}s',
          text.substring(0, 140).replace(/[\r\n]+/g, ' '));
      }
      return '';
    } catch (error) {
      NativeComments.detail = `throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60);
      return '';
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 一条 REST 评论 DTO → CommentItem（**回复也走这里**）。
   *
   * "下挂回复"用到两个字段：
   *   · `child_comment_count` = 回复总数（面板上"查看另外 n 条回复"的那个 n）；
   *   · `preview_child_comments` = 接口顺带给的预览（一般 1~2 条），展开时先拿它显示，
   *     不够再去要全部（见 childComments）。
   */
  private static toItem(one: CommentDto): CommentItem {
    const body: string = NativeComments.textOf(one as Record<string, Object>);
    const image: CommentImage = body.length === 0
      ? NativeComments.findImage(one) : NativeComments.emptyImage();
    const preview: Array<CommentDto> = one.preview_child_comments ?? [];
    const replies: Array<CommentItem> = [];
    for (let index: number = 0; index < preview.length; index++) {
      // 只挂一层：预览里的回复不再往下递归。
      replies.push(NativeComments.toItem(preview[index]));
    }
    return {
      username: (one.user?.username ?? '').trim(),
      // 作者数字 id：评论面板点头像/用户名要开 TA 的主页（见 pages/Index.openUserProfile）。
      userId: `${one.user?.pk ?? ''}`.trim(),
      text: body,
      avatar: one.user?.profile_pic_url ?? '',
      likes: one.comment_like_count ?? 0,
      pk: `${one.pk ?? ''}`.trim(),
      imageUrl: image.url,
      mediaW: image.w,
      mediaH: image.h,
      repliesCount: one.child_comment_count ?? 0,
      replies: replies,
      // 发布时间（Unix 秒）：面板在用户 id 旁边用灰色小字显示"多久之前"。
      createdAt: one.created_at ?? 0
    };
  }

  /** 解析 `GET /api/v1/media/{id}/comments/{pk}/child_comments/` 的响应。 */
  private static parseChildren(text: string): Array<CommentItem> {
    let root: Record<string, Object> | null = null;
    try {
      root = JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      return [];
    }
    if (root === null) {
      return [];
    }
    const raw: Array<CommentDto> =
      (root['child_comments'] ?? root['comments'] ?? []) as Array<CommentDto>;
    const out: Array<CommentItem> = [];
    for (let index: number = 0; index < raw.length; index++) {
      out.push(NativeComments.toItem(raw[index]));
    }
    return out;
  }

  /**
   * 取某条评论的**全部回复**（面板上"查看另外 n 条回复"点开时用）。
   *
   * 走 `GET /api/v1/media/{媒体id}/comments/{评论pk}/child_comments/`（同 fetchViaRest 那套
   * 会话与查询串）。失败返回空数组 —— 调用方保留预览那几条，不影响已经画出来的内容。
   */
  static async childComments(mediaId: string, commentPk: string): Promise<Array<CommentItem>> {
    if (mediaId.length === 0 || commentPk.length === 0) {
      return [];
    }
    try {
      const headers: Record<string, string> = await RestSession.headers();
      if (Object.keys(headers).length === 0) {
        return [];
      }
      const url: string = `https://www.instagram.com/api/v1/media/${encodeURIComponent(mediaId)}`
        + `/comments/${encodeURIComponent(commentPk)}/child_comments/?can_support_threading=true`;
      const text: string = await NativeComments.get(url, headers);
      if (text.length === 0) {
        return [];
      }
      const items: Array<CommentItem> = NativeComments.parseChildren(text);
      hilog.info(DOMAIN, TAG, 'child comments pk=%{public}s n=%{public}d', commentPk, items.length);
      return items;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'child comments failed: %{public}s', (error as Error).message);
      return [];
    }
  }

  /** 响应文本 → CommentsPayload（state 只有 ok / empty / error）。 */
  private static parse(text: string): CommentsPayload | null {
    let dto: CommentsDto;
    try {
      dto = JSON.parse(text) as CommentsDto;
    } catch (error) {
      NativeComments.detail = 'json-parse';
      return null;
    }
    const raw: Array<CommentDto> = dto.comments ?? [];
    NativeComments.total = dto.comment_count ?? -1;
    const items: Array<CommentItem> = [];
    let noText: number = 0;
    for (let index: number = 0; index < raw.length; index++) {
      const one: CommentDto = raw[index];
      const body: string = NativeComments.textOf(one as Record<string, Object>);
      const who: string = (one.user?.username ?? '').trim();
      // **图片评论**：`text` 是空串，图在别处（见 findImage）。
      const image: CommentImage = body.length === 0
        ? NativeComments.findImage(one) : NativeComments.emptyImage();
      if (body.length === 0) {
        noText++;
        // 诊断：正文读不出来的那几条，看看到底是哪些字段（只记头两条）。
        if (NativeComments.noTextSample.length === 0) {
          NativeComments.noTextSample = `img=${image.url.length > 0 ? 'y' : 'n'} `
            + NativeComments.sample(one);
        } else if (NativeComments.noTextSample.indexOf(' | text=') < 0) {
          NativeComments.noTextSample += ' | img=' + (image.url.length > 0 ? 'y' : 'n')
            + ' ' + NativeComments.sample(one);
        }
      }
      if (body.length === 0 && who.length === 0 && image.url.length === 0) {
        continue;
      }
      items.push(NativeComments.toItem(one));
    }
    if (noText > 0) {
      hilog.info(DOMAIN, TAG, 'no-text n=%{public}d/%{public}d sample=%{public}s',
        noText, raw.length, NativeComments.noTextSample);
      if (NativeComments.imgDiag.length > 0) {
        hilog.info(DOMAIN, TAG, 'sticker shape %{public}s', NativeComments.imgDiag);
      }
    }
    const maxId: string = `${dto.next_max_id ?? ''}`.trim();
    const minId: string = `${dto.next_min_id ?? ''}`.trim();
    // 优先尾部游标（max_id），没有就用头部游标（min_id）——两种翻页方式 IG 都在用。
    const nextId: string = maxId.length > 0 ? maxId : minId;
    const useMin: boolean = maxId.length === 0 && minId.length > 0;
    const hasMore: boolean = dto.has_more_comments === true
      || dto.has_more_headload_comments === true
      || (nextId.length > 0 && items.length > 0);
    const diag: string = `native min=${minId.length} max=${maxId.length} more=${hasMore ? 'y' : 'n'}`;
    return { state: items.length > 0 ? 'ok' : 'empty', items: items, diag: diag,
      nextMaxId: nextId, hasMore: hasMore, nextMin: useMin };
  }

  /**
   * 一条评论节点里的**图片评论**那张图。
   *
   * 字段名各版本不一样（`media_comment_info` / `comment_image` / 直接内嵌 `image_versions2`…），
   * 所以**按形状找**：先看几个已知的容器，再退回"整个节点里第一个像 IG 图片候选列表的对象
   * （有 `candidates` 数组、且不在 `user` 里 —— 那是头像）"。
   *
   * 这样做的另一个好处：以后 IG 换字段名，只要形状还是"candidates + url"就还能读到。
   */
  private static findImage(one: CommentDto): CommentImage {
    const rec: Record<string, Object> = one as Record<string, Object>;
    // GIF 评论（贴图的一种）：`giphy_media_info.images.<档位>.url`。
    const gif: CommentImage = NativeComments.giphyImage(rec);
    if (gif.url.length > 0) {
      return gif;
    }
    const known: Array<string> = ['media_comment_info', 'avatar_media_info', 'comment_image',
      'image_versions2', 'media_comment_sticker'];
    for (let index: number = 0; index < known.length; index++) {
      const container: Record<string, Object> | null = JsonRead.recordOf(rec, known[index]);
      if (container === null) {
        continue;
      }
      const hit: CommentImage = NativeComments.candidatesImage(container);
      if (hit.url.length > 0) {
        return hit;
      }
      // 有的贴图是**直链字段**（实测：`avatar_media_info.avatar_sticker_cdn_url`），
      // 没有 candidates 那一层 —— 那就把容器里第一个 http(s) 字符串当图（这种没有尺寸）。
      const direct: CommentImage = NativeComments.directImage(container);
      if (direct.url.length > 0) {
        return direct;
      }
      // 认不出形状时记一次它的键：贴图字段名换了的话，靠这行定位（只在真的没找到图时打）。
      if (NativeComments.imgDiag.length === 0) {
        NativeComments.imgDiag = `${known[index]} keys=${Object.keys(container).join(',')}`;
      }
    }
    // 兜底：从节点里挖（跳过 user 子树，免得把头像当贴图）。
    const found: CommentImage = NativeComments.scanImage(one, 0);
    if (found.url.length === 0 && NativeComments.imgDiag.length === 0) {
      NativeComments.imgDiag = `node keys=${Object.keys(rec).join(',')}`;
    }
    if (found.url.length > 0) {
      NativeComments.imgDiag = '';
    }
    return found;
  }

  /**
   * GIF 评论那张动图（含 Giphy 给的宽高）。
   *
   * 形状是 `giphy_media_info.images = { fixed_height: {url,width,height}, original: {...}, … }`，
   * 档位名各版本会加/减，所以**在 images 里按顺序找**：先 original，再 fixed_height……
   * 都没有就把 images 里的第一个 url 拿出来。
   */
  private static giphyImage(rec: Record<string, Object>): CommentImage {
    const gif: Record<string, Object> | null = JsonRead.recordOf(rec, 'giphy_media_info');
    if (gif === null) {
      return NativeComments.emptyImage();
    }
    const images: Record<string, Object> | null = JsonRead.recordOf(gif, 'images');
    if (images === null) {
      return NativeComments.firstCandidateImage(gif);
    }
    const prefer: Array<string> = ['original', 'fixed_height', 'fixed_height_downsampled',
      'downsized', 'fixed_width'];
    for (let index: number = 0; index < prefer.length; index++) {
      const one: Record<string, Object> | null = JsonRead.recordOf(images, prefer[index]);
      if (one === null) {
        continue;
      }
      const hit: CommentImage = NativeComments.imageOf(one);
      if (hit.url.length > 0) {
        return hit;
      }
    }
    // 档位名都不认识：images 下第一个带 url 的对象。
    const keys: Array<string> = Object.keys(images);
    for (let index: number = 0; index < keys.length; index++) {
      const one: Record<string, Object> | null = JsonRead.recordOf(images, keys[index]);
      if (one === null) {
        continue;
      }
      const hit: CommentImage = NativeComments.imageOf(one);
      if (hit.url.length > 0) {
        return hit;
      }
    }
    return NativeComments.emptyImage();
  }

  /** 一个容器里的 `image_versions2.candidates[0]` 或直接 `candidates[0]`（带宽高）。 */
  private static candidatesImage(container: Record<string, Object>): CommentImage {
    const direct: CommentImage = NativeComments.firstCandidateImage(container);
    if (direct.url.length > 0) {
      return direct;
    }
    const versions: Record<string, Object> | null = JsonRead.recordOf(container, 'image_versions2');
    return versions === null
      ? NativeComments.emptyImage() : NativeComments.firstCandidateImage(versions);
  }

  /** 容器里第一个像图片直链的字符串（`avatar_sticker_cdn_url` 这类字段用；没有尺寸）。 */
  private static directImage(host: Record<string, Object>): CommentImage {
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object = host[keys[index]];
      if (typeof value !== 'string') {
        continue;
      }
      const url: string = value as string;
      if (url.indexOf('http') === 0 && (url.indexOf('.jpg') >= 0 || url.indexOf('.png') >= 0
        || url.indexOf('.webp') >= 0 || url.indexOf('.gif') >= 0
        || url.indexOf('cdninstagram') >= 0 || url.indexOf('fbcdn') >= 0)) {
        return new CommentImage(url, 0, 0);
      }
    }
    return NativeComments.emptyImage();
  }

  /** `candidates[]` 里第一张图（数组本身也可能是"候选列表"）。 */
  private static firstCandidateImage(host: Record<string, Object>): CommentImage {
    const list: Array<Object> = JsonRead.arrayOf(host, 'candidates');
    for (let index: number = 0; index < list.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(list[index]);
      if (one === null) {
        continue;
      }
      const hit: CommentImage = NativeComments.imageOf(one);
      if (hit.url.length > 0) {
        return hit;
      }
    }
    return NativeComments.emptyImage();
  }

  /** 一个"图对象"（`{url,width,height}`）→ CommentImage。 */
  private static imageOf(one: Record<string, Object>): CommentImage {
    const url: string = JsonRead.strOf(one, 'url');
    if (url.length === 0) {
      return NativeComments.emptyImage();
    }
    return new CommentImage(url, JsonRead.numOf(one, 'width'), JsonRead.numOf(one, 'height'));
  }

  private static emptyImage(): CommentImage {
    return new CommentImage('', 0, 0);
  }

  /** 递归找第一个"图片候选列表"里的图（跳过 user 子树；深度有限）。 */
  private static scanImage(node: Object, depth: number): CommentImage {
    if (depth > 4 || node === null || typeof node !== 'object') {
      return NativeComments.emptyImage();
    }
    if (Array.isArray(node)) {
      const list: Array<Object> = node as Array<Object>;
      for (let index: number = 0; index < list.length; index++) {
        const hit: CommentImage = NativeComments.scanImage(list[index], depth + 1);
        if (hit.url.length > 0) {
          return hit;
        }
      }
      return NativeComments.emptyImage();
    }
    const rec: Record<string, Object> | null = JsonRead.asRecord(node);
    if (rec === null) {
      return NativeComments.emptyImage();
    }
    const hit: CommentImage = NativeComments.candidatesImage(rec);
    if (hit.url.length > 0) {
      return hit;
    }
    const keys: Array<string> = Object.keys(rec);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      if (key === 'user' || key === 'pk' || key === 'id') {
        continue;
      }
      const found: CommentImage = NativeComments.scanImage(rec[key], depth + 1);
      if (found.url.length > 0) {
        return found;
      }
    }
    return NativeComments.emptyImage();
  }

  /**
   * 读一条评论的正文。
   *
   * 绝大部分是字符串，但**有的版本给的是对象**（`"text": {"text": "…"}`）——
   * 直接往界面上一拼就变成 `[object Object]`（真机截图里就是这么冒出来的）。
   * 所以这里按类型分流：字符串直接用；对象取它里面的 `text`；都不是就当空串。
   */
  private static textOf(host: Record<string, Object>): string {
    const value: Object = host['text'];
    if (typeof value === 'string') {
      return (value as string).trim();
    }
    const nested: Record<string, Object> | null = JsonRead.asRecord(value);
    if (nested === null) {
      return '';
    }
    const inner: Object = nested['text'];
    return typeof inner === 'string' ? (inner as string).trim() : '';
  }

  /** 容器里第一个像图片直链的字符串（`avatar_sticker_cdn_url` 这类字段用）。 */
  private static directUrl(host: Record<string, Object>): string {
    return NativeComments.directImage(host).url;
  }

  /** `candidates[]` 里第一张图的 url（数组本身也可能是"候选列表"）。 */
  private static firstCandidate(host: Record<string, Object>): string {
    return NativeComments.firstCandidateImage(host).url;
  }

  /**
   * 一条"读不出正文"的评论节点的摘要。
   *
   * 除了键名，还把**所有非空字符串字段**列出来（正文要是藏在别的字段名下，这里一眼就能看到），
   * 以及 `text` 的原值（空串 / 缺失 / 只有空白，三种情况要分清）。
   */
  private static sample(one: CommentDto): string {
    const rec: Record<string, Object> = one as Record<string, Object>;
    const keys: Array<string> = Object.keys(rec);
    const strings: Array<string> = [];
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const value: Object = rec[key];
      if (typeof value !== 'string') {
        continue;
      }
      const text: string = value as string;
      if (text.length === 0) {
        continue;
      }
      // pk / id 这类标识符也列上（短），长 URL 才裁掉。
      strings.push(`${key}=${text.length > 48 ? text.substring(0, 48) + '…' : text}`);
    }
    let textRaw: string = '';
    try {
      textRaw = JSON.stringify(rec['text']);
    } catch (error) {
      textRaw = 'stringify-failed';
    }
    return `text=${textRaw} keys=${keys.join(',')} strings=[${strings.join(' | ')}]`;
  }
}
