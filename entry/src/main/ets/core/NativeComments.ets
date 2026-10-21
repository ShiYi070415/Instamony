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
import { MobileRequest, MobileResult, MobileOptions } from './mobileapi/MobileRequest';
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

  /** 这次会话里评论用的是不是 GraphQL 那条（决定翻页跟着哪条游标走，见 fetch）。 */
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
      NativeComments.source = '-';
    }
    /*
     * **只走移动端私有通道**（见 core/mobileapi/MobileComments）：
     * 与 instagrapi 的 `media_comments_v1_chunk` 同一个端点、同一套 App 身份，
     * **不需要任何网页模板**。原先那两条网页退路（REST + GraphQL doc_id）
     * 已随模板机制删除。
     */
    const viaMobile: CommentsPayload | null = await NativeComments.fetchViaMobile(id, maxId);
    if (viaMobile !== null && viaMobile.state === 'ok') {
      NativeComments.source = 'mobile';
      if (maxId.length === 0) {
        NativeComments.cursorMin = viaMobile.nextMin === true;
      }
      return viaMobile;
    }
    return viaMobile;
  }

  /** 上一次评论数据来自哪条路（rest / graphql / -）。 */
  static lastSource(): string {
    return NativeComments.source;
  }

  /** 媒体 id 归一化：`3991085364986982562_7419457815` 只取 `_` 前面那段。 */
  private static pureId(raw: string): string {
    const text: string = raw.trim();
    const cut: number = text.indexOf('_');
    return cut > 0 ? text.substring(0, cut) : text;
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

  /**
   * **评论点赞 / 取消**（只走移动端私有接口，见 core/mobileapi/MobileEngage）。
   *
   * @param commentPk 评论的数字 id
   * @param like      true = 点赞，false = 取消
   * @param mediaId   这条评论所属的媒体 id（端点路径需要）
   */
  static async like(commentPk: string, like: boolean, mediaId: string = ''): Promise<boolean> {
    const id: string = commentPk.trim();
    if (id.length === 0) {
      NativeComments.likeVia = 'no-comment-id';
      return false;
    }
    let ok: boolean = false;
    try {
      ok = await MobileEngage.setCommentLiked(mediaId, id, like);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'comment like threw: %{public}s', (error as Error).message);
      ok = false;
    }
    NativeComments.likeVia = ok ? `mobile:comment_` + (like ? 'like' : 'unlike') : 'mobile-failed';
    hilog.info(DOMAIN, TAG, 'comment like pk=%{public}s media=%{public}s like=%{public}s ok=%{public}s',
      id, mediaId, `${like}`, ok ? 'y' : 'n');
    return ok;
  }

  /** 上一次评论点赞走的是哪条路（诊断）。 */
  static lastLikeVia(): string {
    return NativeComments.likeVia;
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
   * 走移动端私有接口 `media/{媒体id}/comments/{评论pk}/child_comments/`（见 core/mobileapi）。
   * 失败返回空数组 —— 调用方保留预览那几条，不影响已经画出来的内容。
   */
  static async childComments(mediaId: string, commentPk: string): Promise<Array<CommentItem>> {
    if (mediaId.length === 0 || commentPk.length === 0) {
      return [];
    }
    try {
      const result: MobileResult = await MobileRequest.send(
        `media/${encodeURIComponent(mediaId)}/comments/${encodeURIComponent(commentPk)}/child_comments/`,
        '', 'can_support_threading=true', true, null,
        new MobileOptions(ApiThrottle.COMMENTS, ApiThrottle.interactive()));
      if (!result.ok) {
        hilog.info(DOMAIN, TAG, 'child comments miss pk=%{public}s %{public}s',
          commentPk, result.summary());
        return [];
      }
      const items: Array<CommentItem> = NativeComments.parseChildren(result.body);
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
