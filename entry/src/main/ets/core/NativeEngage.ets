/*
 * 点赞 / 转发：**HTTP 直发**（不驱动隐藏网页）。
 *
 * ## 为什么是"模板回放"而不是"自己拼请求"
 * 这四条操作在 IG 网页上是**私有 GraphQL 变更**，请求体里除了 `variables` 还有
 * `doc_id`（IG 会轮换）、`lsd` / `fb_dtsg` / `jazoest` / `__dyn` / `__csr` 一整套指纹，
 * 硬编码任何一样都会在几天后失效。所以照搬信息流那条路的做法：
 *   **让页面自己发一次 → 把那条请求原样存成模板 → 原生照着重放**（只换 media_id）。
 *
 * 探针真机抓到的四条（见 .tmp/engagediag3.txt）：
 *   点赞   POST /api/graphql    #usePolarisLikeMediaXIGLikeMutation
 *   取消赞 POST /api/graphql    #usePolarisLikeMediaXIGUnlikeMutation
 *   转发   POST /graphql/query  #usePolarisCreateMediaRepostMutation
 *   取消转发 POST /api/graphql  #usePolarisDeleteMediaRepostMutation
 * 都是 `variables={"input":{...}}` 的形状，改 `input.media_id` 就能对任意一条帖子生效。
 *
 * ## 取消转发为什么需要 note_id
 * `usePolarisDeleteMediaRepostMutation` 的入参里**没有 media_id，只有 `note_id`** ——
 * 那是"转发"这条动作自己生成的 id，只能从转发那次的**响应**里读出来。
 * 所以：转发成功 → 把 note_id 记进 EngageState；取消转发时取出来用。
 * 没有 note_id（比如 App 重启过、这次转发不是我们发的）就**不猜**，直接交给调用方回退到
 * 网页那条路（见 pages/Index.repostPost）。
 *
 * ## 自举（模板从哪来）
 * 模板只在"页面自己发过一次"之后才有。所以策略是**边用边抓**：
 * 某一次操作走了网页（老路径）时顺手 `ApiRegistry.capture()`，那之后（模板 24 小时有效）
 * 同样的操作就走原生 HTTP —— 用户不需要为模板做任何额外的动作。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeFeed, NativeFetchResult } from './NativeFeed';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { WebTokens } from './WebTokens';
import { EngageSkeleton } from './EngageSkeleton';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { MobileEngage } from './mobileapi/MobileEngage';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeEngage';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 10000;

/** 四个操作的模板名片段（就是 IG 自己的 fb_api_req_friendly_name）。 */
export const LIKE_OP: string = 'usePolarisLikeMediaXIGLikeMutation';
export const UNLIKE_OP: string = 'usePolarisLikeMediaXIGUnlikeMutation';
export const REPOST_OP: string = 'usePolarisCreateMediaRepostMutation';
export const UNREPOST_OP: string = 'usePolarisDeleteMediaRepostMutation';

/** 一次点赞/转发的结果（不抛异常）。 */
export class EngageResult {
  readonly ok: boolean;
  /** 服务端确认后的状态（失败时原样回传入的期望值）。 */
  readonly state: boolean;
  readonly detail: string;
  /** 原始响应片段（诊断用）。 */
  readonly sample: string;

  constructor(ok: boolean, state: boolean, detail: string, sample: string = '') {
    this.ok = ok;
    this.state = state;
    this.detail = detail;
    this.sample = sample;
  }
}

/**
 * 转发动作的**note_id**（取消转发要用，见文件头）。
 *
 * 只活在内存里：App 重启后拿不到，那时取消转发会回退网页路径（安全）。
 */
export class EngageState {
  private static readonly notes: Map<string, string> = new Map<string, string>();
  /**
   * 本机点过赞 / 转发过的媒体 id（**会话级台账**）。
   *
   * 为什么需要（用户报的"收藏页点赞失效 / 转发没反应"）：那两段（收藏 / 被标注）的载荷里
   * **没有** `has_liked` / 转发态，`ProfileMapper.toMediaPost` 只能给 false；而帖子页的列表
   * 每次"再要一页"都会**用视图模型那份重建**（`postPagePosts = page.posts`）—— 于是用户刚点的赞
   * 在一次翻页之后就被还原成 false，看起来就是"点了没用"。
   * 把用户点过的结果记在这里，任何时候重建帖子都来问一句 `likedOf/repostedOf`（同 FollowState 的思路）。
   */
  private static readonly likedIds: Map<string, boolean> = new Map<string, boolean>();
  private static readonly repostedIds: Map<string, boolean> = new Map<string, boolean>();
  /**
   * 同一张台账，**按 shortcode** 再记一份。
   *
   * 为什么单纯按媒体 id 不够（用户报："推荐流进 reels 点赞，退出重进心还是灰的"）：
   * 媒体 id 在两条数据源里的写法不统一 —— 推荐流那条给的是 `strong_id__`（纯数字），
   * clips 首页给的是 `pk`（`<媒体id>_<作者id>`），个人页/收藏给的是纯 id，拿不到时甚至
   * 只能塞 `search-<code>` 这样的占位串；而**写入那一刻**（Reels 页那颗心）手里往往压根
   * 没有 id（见 ProfileReelsViewModel.mediaIdOf 的说明），只有 shortcode。
   * 于是"写进去的键"和"重建时来查的键"永远对不上 —— 状态就丢了。
   *
   * shortcode 是 IG 全局唯一的短码，两条数据源都一定给，所以用它兜底。
   * 这里**不做 normalize**：shortcode 的字母表里本来就有 `_` 和 `-`
   * （normalize 会在第一个 `_` 处截断，把短码切坏）。
   */
  private static readonly likedCodes: Map<string, boolean> = new Map<string, boolean>();
  private static readonly repostedCodes: Map<string, boolean> = new Map<string, boolean>();

  static rememberNote(mediaId: string, noteId: string): void {
    const key: string = EngageState.normalize(mediaId);
    if (key.length > 0 && noteId.trim().length > 0) {
      EngageState.notes.set(key, noteId.trim());
    }
  }

  static noteId(mediaId: string): string {
    const one: string | undefined = EngageState.notes.get(EngageState.normalize(mediaId));
    return one === undefined ? '' : one;
  }

  /** 记下"这条被赞/取消赞了"（媒体 id 为空时忽略）。 */
  static rememberLiked(mediaId: string, liked: boolean): void {
    const key: string = EngageState.normalize(mediaId);
    if (key.length > 0) {
      EngageState.likedIds.set(key, liked);
    }
  }

  /** 这条被本机赞过没有（没记过就给 `fallback` = 载荷里的值）。 */
  static likedOf(mediaId: string, fallback: boolean): boolean {
    const one: boolean | undefined = EngageState.likedIds.get(EngageState.normalize(mediaId));
    return one === undefined ? fallback : one;
  }

  /** 同上，按 shortcode 记（键不归一，见 likedCodes 的说明）。 */
  static rememberLikedByCode(shortcode: string, liked: boolean): void {
    const key: string = shortcode.trim();
    if (key.length > 0) {
      EngageState.likedCodes.set(key, liked);
    }
  }

  /** 这条 shortcode 被本机赞过没有（没记过就给 `fallback`）。 */
  static likedOfByCode(shortcode: string, fallback: boolean): boolean {
    const one: boolean | undefined = EngageState.likedCodes.get(shortcode.trim());
    return one === undefined ? fallback : one;
  }

  /** 同上，转发。 */
  static rememberReposted(mediaId: string, reposted: boolean): void {
    const key: string = EngageState.normalize(mediaId);
    if (key.length > 0) {
      EngageState.repostedIds.set(key, reposted);
    }
  }

  static repostedOf(mediaId: string, fallback: boolean): boolean {
    const one: boolean | undefined = EngageState.repostedIds.get(EngageState.normalize(mediaId));
    return one === undefined ? fallback : one;
  }

  static rememberRepostedByCode(shortcode: string, reposted: boolean): void {
    const key: string = shortcode.trim();
    if (key.length > 0) {
      EngageState.repostedCodes.set(key, reposted);
    }
  }

  static repostedOfByCode(shortcode: string, fallback: boolean): boolean {
    const one: boolean | undefined = EngageState.repostedCodes.get(shortcode.trim());
    return one === undefined ? fallback : one;
  }

  /**
   * **媒体 id 归一化**：只留 `_` 前面那一段。
   *
   * 为什么必须归（真机上就是这么丢状态的）：同一条媒体在两个数据源里的 id 写法不一样 ——
   * 信息流那条是 **`<媒体id>_<作者id>`**（`pk` 就是这个组合串），而个人页/收藏/被标注那几条
   * 是**纯媒体 id**。不归一的话，在信息流里点的转发记在组合串上，回到收藏页拿纯 id 来查
   * 必然查不到 → 用户看到的就是"转发完再进来又变回未转发"（需求报的正是这个）。
   */
  private static normalize(mediaId: string): string {
    const text: string = mediaId.trim();
    const cut: number = text.indexOf('_');
    return cut > 0 ? text.substring(0, cut) : text;
  }

  static clear(): void {
    EngageState.notes.clear();
    EngageState.likedIds.clear();
    EngageState.repostedIds.clear();
    EngageState.likedCodes.clear();
    EngageState.repostedCodes.clear();
  }
}

export class NativeEngage {
  /** `client_mutation_id` 的自增序号（同一个 id 重复发会被服务端去重）。 */
  private static seq: number = 0;

  /** Cookie 串里取一个值（csrf / ds_user_id 都从这里来）。 */
  private static cookieValue(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const one: string = parts[i].trim();
      if (one.indexOf(`${name}=`) === 0) {
        return one.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  /** 点赞模板在不在（不在就说明页面还没发过点赞请求，得先走一次网页）。 */
  static hasLikeTemplate(): boolean {
    return ApiRegistry.getInstance().storedForNative(LIKE_OP) !== null
      && ApiRegistry.getInstance().storedForNative(UNLIKE_OP) !== null;
  }

  /** 转发模板在不在（取消转发还要额外有 note_id，见 repost 的说明）。 */
  static hasRepostTemplate(): boolean {
    return ApiRegistry.getInstance().storedForNative(REPOST_OP) !== null;
  }

  /**
   * 点赞 / 取消赞。
   *
   * @param mediaId 帖子 id（信息流里的 `pk`，形如 `3991085364986982562_7419457815` 的第一段）。
   * @param like    true = 点赞，false = 取消赞。
   */
  static async setLiked(mediaId: string, like: boolean): Promise<EngageResult> {
    const id: string = NativeEngage.mediaIdOf(mediaId);
    if (id.length === 0) {
      return new EngageResult(false, like, 'no-media-id');
    }
    /*
     * **移动端 REST 优先**（见 core/mobileapi/MobileEngage）：点赞只需要一发
     * media/{id}/like/，完全不依赖网页模板。原来那条模板回放遇到 doc_id / claim 过期会回
     * "200 + errors"（被当成成功），于是界面红了、服务端其实没收到（用户报的现象）。
     */
    const mobileOk: boolean = await MobileEngage.setLiked(id, like);
    if (mobileOk) {
      return new EngageResult(true, like, 'mobile');
    }
    const op: string = like ? LIKE_OP : UNLIKE_OP;
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl !== null) {
      // ① 有网页抓来的模板：它和页面刚发的请求一模一样，最稳。
      const body: string = NativeEngage.patchInput(tpl.body, id, '', true);
      const response: NativeFetchResult = await NativeEngage.send(op, tpl.url, body);
      const ok: boolean = NativeEngage.looksOk(response);
      if (ok) {
        return new EngageResult(true, like, '', '');
      }
      // 模板失败（多半是 doc_id 过期）→ 往下走骨架那条路再试一次。
      hilog.warn(DOMAIN, TAG, 'template like failed (%{public}s) → skeleton', response.error);
    }
    // ② 没有模板（新装/换会话）或模板已过期：用**包内骨架 + 现场读到的页面令牌**拼一条。
    const built: EngageResult = await NativeEngage.skeletonLike(id, like);
    if (built.ok) {
      return built;
    }
    return new EngageResult(false, like, tpl === null ? `no-template/${built.detail}` : built.detail,
      built.sample);
  }

  /** 骨架 + 页面令牌拼出来的点赞/取消赞（见 EngageSkeleton 的说明）。 */
  private static async skeletonLike(mediaId: string, like: boolean): Promise<EngageResult> {
    if (!await WebTokens.ensure()) {
      return new EngageResult(false, like, 'no-tokens');
    }
    const actor: string = await WebTokens.actorId();
    if (actor.length === 0) {
      return new EngageResult(false, like, 'no-actor-id');
    }
    const name: string = like ? EngageSkeleton.LIKE_NAME : EngageSkeleton.UNLIKE_NAME;
    const seq: number = NativeEngage.nextSeq();
    const vars: string = like
      ? EngageSkeleton.likeVariables(actor, mediaId, seq)
      : EngageSkeleton.unlikeVariables(actor, mediaId, seq);
    const body: string = EngageSkeleton.graphqlBody(name, EngageSkeleton.docOf(name), vars, actor);
    const headers: Record<string, string> = await NativeEngage.skeletonHeaders(name);
    if (Object.keys(headers).length === 0) {
      return new EngageResult(false, like, 'no-session');
    }
    const response: NativeFetchResult = await NativeEngage.postRaw(EngageSkeleton.urlOf(name),
      body, headers);
    const ok: boolean = NativeEngage.looksOk(response);
    hilog.info(DOMAIN, TAG, 'skeleton like like=%{public}s ok=%{public}s code=%{public}d len=%{public}d',
      `${like}`, `${ok}`, response.code, response.body.length);
    return new EngageResult(ok, like, ok ? '' : response.error, response.body.substring(0, 400));
  }

  /**
   * 转发 / 取消转发。
   *
   * 取消转发需要 `note_id`：有就用原生，没有就回 `no-note-id`（调用方回退网页路径）。
   */
  static async setReposted(mediaId: string, repost: boolean): Promise<EngageResult> {
    const id: string = NativeEngage.mediaIdOf(mediaId);
    if (id.length === 0) {
      return new EngageResult(false, repost, 'no-media-id');
    }
    const op: string = repost ? REPOST_OP : UNREPOST_OP;
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    let note: string = '';
    if (!repost) {
      note = EngageState.noteId(id);
      if (note.length === 0) {
        return new EngageResult(false, repost, 'no-note-id');
      }
    }
    if (tpl !== null) {
      const body: string = NativeEngage.patchInput(tpl.body, repost ? id : '', note, false);
      const response: NativeFetchResult = await NativeEngage.send(op, tpl.url, body);
      const ok: boolean = NativeEngage.looksOk(response);
      if (ok) {
        if (repost) {
          EngageState.rememberNote(id, NativeEngage.noteIdOf(response.body));
        }
        return new EngageResult(true, repost, '', '');
      }
      hilog.warn(DOMAIN, TAG, 'template repost failed (%{public}s) → skeleton', response.error);
    }
    const built: EngageResult = await NativeEngage.skeletonRepost(id, repost, note);
    if (built.ok && repost && built.sample.length > 0) {
      EngageState.rememberNote(id, built.sample);
    }
    return new EngageResult(built.ok, repost,
      tpl === null ? `no-template/${built.detail}` : built.detail, '');
  }

  /** 骨架 + 页面令牌拼出来的转发/取消转发。成功时把 note_id 放在 sample 里回传。 */
  private static async skeletonRepost(mediaId: string, repost: boolean,
                                      note: string): Promise<EngageResult> {
    if (!await WebTokens.ensure()) {
      return new EngageResult(false, repost, 'no-tokens');
    }
    const actor: string = await WebTokens.actorId();
    if (actor.length === 0) {
      return new EngageResult(false, repost, 'no-actor-id');
    }
    const name: string = repost ? EngageSkeleton.REPOST_NAME : EngageSkeleton.UNREPOST_NAME;
    const vars: string = EngageSkeleton.repostVariables(actor, mediaId, note, NativeEngage.nextSeq());
    const body: string = EngageSkeleton.graphqlBody(name, EngageSkeleton.docOf(name), vars, actor);
    const headers: Record<string, string> = await NativeEngage.skeletonHeaders(name);
    if (Object.keys(headers).length === 0) {
      return new EngageResult(false, repost, 'no-session');
    }
    const response: NativeFetchResult = await NativeEngage.postRaw(EngageSkeleton.urlOf(name),
      body, headers);
    const ok: boolean = NativeEngage.looksOk(response);
    const parsedNote: string = ok && repost ? NativeEngage.noteIdOf(response.body) : '';
    hilog.info(DOMAIN, TAG, 'skeleton repost repost=%{public}s ok=%{public}s code=%{public}d note=%{public}d',
      `${repost}`, `${ok}`, response.code, parsedNote.length);
    return new EngageResult(ok, repost, ok ? '' : response.error, parsedNote);
  }

  /** 骨架请求要用的头：会话级的 csrf / cookie 从 Cookie 罐现取。 */
  private static async skeletonHeaders(op: string): Promise<Record<string, string>> {
    try {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      if (!jar.signedIn) {
        return {};
      }
      const csrf: string = NativeEngage.cookieValue(jar.cookie ?? '', 'csrftoken');
      return EngageSkeleton.headers(await NativeFeed.sessionOrBrowserHeaders(), op, csrf, jar.cookie ?? '');
    } catch (error) {
      return {};
    }
  }

  /** 每次请求换一个 client_mutation_id（同一个 id 重复发会被服务端去重）。 */
  private static nextSeq(): number {
    NativeEngage.seq = (NativeEngage.seq + 1) % 100000;
    return NativeEngage.seq;
  }

  /**
   * 帖子 id 归一化。
   *
   * 信息流里的 `pk` 形如 `3991085364986982562_7419457815`（`媒体id_作者id`），
   * 而这几个变更要的是**纯媒体 id**（前半段）；已经是纯 id 就原样返回。
   */
  static mediaIdOf(raw: string): string {
    const one: string = raw.trim();
    const cut: number = one.indexOf('_');
    return cut > 0 ? one.substring(0, cut) : one;
  }

  /** 成不成功：HTTP 200 + 响应是 JSON 且里面没有 errors。 */
  private static looksOk(response: NativeFetchResult): boolean {
    if (!response.ok) {
      return false;
    }
    const text: string = response.body;
    if (text.indexOf('"errors"') >= 0) {
      return false;
    }
    return text.indexOf('"data"') >= 0;
  }

  /** 从转发响应里挖 note_id（形状见下面三种；挖不到就空串）。 */
  private static noteIdOf(text: string): string {
    // 真机实测的形状：`{"data":{"xdt_create_media_note_v2":{"id":"2377080386366591",…`
    const root: number = text.indexOf('"xdt_create_media_note_v2"');
    if (root >= 0) {
      const idAt: number = text.indexOf('"id"', root);
      if (idAt >= 0) {
        const value: string = NativeEngage.stringAfter(text, idAt);
        if (value.length > 0) {
          return value;
        }
      }
    }
    const at: number = text.indexOf('"note_id"');
    if (at < 0) {
      const note: number = text.indexOf('"note"');
      if (note < 0) {
        return '';
      }
      const idAt: number = text.indexOf('"id"', note);
      if (idAt < 0) {
        return '';
      }
      return NativeEngage.stringAfter(text, idAt);
    }
    return NativeEngage.stringAfter(text, at);
  }

  /** 取 `"key"` 之后第一个字符串字面量的值。 */
  private static stringAfter(text: string, at: number): string {
    const colon: number = text.indexOf(':', at);
    if (colon < 0) {
      return '';
    }
    const start: number = text.indexOf('"', colon);
    if (start < 0) {
      return '';
    }
    const end: number = text.indexOf('"', start + 1);
    if (end < 0) {
      return '';
    }
    const value: string = text.substring(start + 1, end);
    // 纯数字才算（避免把别的字符串字段当成 id）。
    for (let i: number = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code < 48 || code > 57) {
        return '';
      }
    }
    return value;
  }

  /**
   * 改 `variables.input`：把 `media_id` / `note_id` 换成目标值，并把
   * `client_mutation_id` 递增（同一个 id 重复发会被服务端去重，看起来就是"点了没反应"）。
   *
   * @param mediaId 非空时写 `input.media_id`。
   * @param noteId  非空时写 `input.note_id`。
   * @param dropTrackingToken 点赞那两条要连 `tracking_token` 一起**删掉**：
   *        它是**跟着某一条帖子**签发的（payload 里嵌着那条的 id 与签名），
   *        换一条帖子还带着旧 token 会被判成无效（见文件头）。
   */
  private static patchInput(body: string, mediaId: string, noteId: string,
                            dropTrackingToken: boolean): string {
    const parts: Array<string> = body.split('&');
    const out: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const part: string = parts[index];
      if (part.indexOf('__req=') === 0) {
        out.push(`__req=${Math.random().toString(36).substring(2, 4)}`);
        continue;
      }
      if (part.indexOf('variables=') !== 0) {
        out.push(part);
        continue;
      }
      try {
        const src: Record<string, Object> =
          JSON.parse(decodeURIComponent(part.substring('variables='.length))) as Record<string, Object>;
        const input: Record<string, Object> = (src['input'] ?? {}) as Record<string, Object>;
        const rebuilt: Record<string, Object> = {};
        const keys: Array<string> = Object.keys(input);
        for (let k: number = 0; k < keys.length; k++) {
          const key: string = keys[k];
          if (dropTrackingToken && key === 'tracking_token') {
            continue;
          }
          rebuilt[key] = input[key];
        }
        if (mediaId.length > 0) {
          rebuilt['media_id'] = mediaId;
        }
        if (noteId.length > 0) {
          rebuilt['note_id'] = noteId;
        }
        rebuilt['client_mutation_id'] = `${Date.now() % 100000}`;
        const vars: Record<string, Object> = {};
        const varKeys: Array<string> = Object.keys(src);
        for (let v: number = 0; v < varKeys.length; v++) {
          vars[varKeys[v]] = src[varKeys[v]];
        }
        vars['input'] = rebuilt;
        out.push(`variables=${encodeURIComponent(JSON.stringify(vars))}`);
      } catch (error) {
        out.push(part);
      }
    }
    return out.join('&');
  }

  /** 照模板发一次（头 = 模板头 + 我们的 Cookie/csrftoken，见 NativeFeed.headersFor）。 */
  private static async send(op: string, url0: string,
                            body: string): Promise<NativeFetchResult> {
    const headers: Record<string, string> = await NativeFeed.headersFor(op);
    if (Object.keys(headers).length === 0) {
      return new NativeFetchResult(false, 'no-session', 0, 0, 0, false, 0, '');
    }
    return NativeEngage.postRaw(url0, body, headers);
  }

  /** 一次表单 POST（头由调用方给；结果用 NativeFetchResult 表达，不抛异常）。 */
  private static async postRaw(url0: string, body: string,
                               headers: Record<string, string>): Promise<NativeFetchResult> {
    const started: number = Date.now();
    const url: string = url0.indexOf('http') === 0
      ? url0 : `https://www.instagram.com${url0.charAt(0) === '/' ? '' : '/'}${url0}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const looksJson: boolean = text.length > 0 && text.charAt(0) === '{';
      hilog.info(DOMAIN, TAG, 'engage POST code=%{public}d json=%{public}s len=%{public}d',
        response.responseCode, `${looksJson}`, text.length);
      return new NativeFetchResult(response.responseCode === 200 && looksJson,
        looksJson ? `http-${response.responseCode}` : `http-${response.responseCode}/non-json`,
        response.responseCode, Date.now() - started, text.length, looksJson, 0, text);
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'engage failed url=%{public}s: %{public}s', url, message);
      return new NativeFetchResult(false, `throw:${message}`.substring(0, 60), 0,
        Date.now() - started, 0, false, 0, '');
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }
}
