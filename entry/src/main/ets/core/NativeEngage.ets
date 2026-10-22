/*
 * 点赞 / 转发：**移动端私有接口优先**（`core/mobileapi/MobileEngage`，instagrapi 同源）。
 *
 *   · 点赞 / 取消赞 → `media/{pk}/like|unlike/`
 *   · 转发 / 取消转发 → 移动端没有对应端点，如实返回"不支持"，
 *     由调用方走**网页驱动**那条路（见 pages/Index.repostPost：把隐藏网页导航到帖子页点它自己的按钮）
 *
 * ## 历史
 * 这里原来是"回放页面抓来的两条 GraphQL 变更（`usePolaris*LikeMedia*Mutation`）+
 * EngageSkeleton 骨架兜底"，两条都要 `doc_id` / `fb_dtsg` / claim 那套会话令牌。
 * 页面注入退役后模板抓不到、令牌也过期，那套一并删除。
 *
 * ## 会话级台账（EngageState）
 * 载荷里没有"本机点过赞 / 转发过"的字段（收藏页/被标注尤其如此），而列表每次翻页都会重建，
 * 所以把用户点过的结果记在内存里，重建时来问一句 —— 否则会出现"点了赞，翻一页又变灰"。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { MobileEngage } from './mobileapi/MobileEngage';
import { WebRepost } from './WebRepost';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeEngage';

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
  /**
   * 点赞 / 取消赞 —— **只走移动端私有接口**（`media/{id}/like|unlike/`，见 MobileEngage）。
   *
   * 失败时如实回 detail，由调用方决定要不要退回"网页驱动"那条路（pages/Index 里有）。
   */
  static async setLiked(mediaId: string, like: boolean, shortcode: string = ''): Promise<EngageResult> {
    const id: string = await NativeEngage.mediaId(mediaId, shortcode);
    if (id.length === 0) {
      return new EngageResult(false, like, 'no-media-id');
    }
    let ok: boolean = false;
    try {
      ok = await MobileEngage.setLiked(id, like);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'like threw: %{public}s', (error as Error).message);
      ok = false;
    }
    hilog.info(DOMAIN, TAG, 'like mobile id=%{public}d like=%{public}s ok=%{public}s',
      id.length, `${like}`, ok ? 'y' : 'n');
    if (ok) {
      return new EngageResult(true, like, 'mobile');
    }
    return new EngageResult(false, like, 'mobile-failed');
  }

  /**
   * 转发 / 取消转发 —— 走移动端私有接口（`media/create_note/v2/` + `notes/delete_note/`，
   * 见 MobileEngage.setReposted 的说明：IG 的 repost 在服务端就是一条带媒体的 note）。
   *
   * 以前这里回 `mobile-unsupported`、由调用方退回"让隐藏网页点它自己的按钮"那条老路：
   * 网页一按需挂载，点转发就会把整页 IG 拉起来（还得现读 lsd / fb_dtsg 那套指纹）。
   * 现在两条腿都在移动端，**不再需要网页**；失败如实回 detail，由调用方回滚界面并提示。
   */
  static async setReposted(mediaId: string, repost: boolean,
                           shortcode: string = ''): Promise<EngageResult> {
    const id: string = await NativeEngage.mediaId(mediaId, shortcode);
    if (id.length === 0) {
      return new EngageResult(false, repost, 'no-media-id');
    }
    /*
     * 两条腿，按"哪条真的通"排：
     *   ① 移动端私有接口（`media/create_note/v2/`，见 MobileEngage.setReposted）；
     *   ② 网页 GraphQL（`usePolarisCreateMediaRepostMutation`，见 core/WebRepost）——
     *      IG 的网页端就是这么转发的，令牌从首页 HTML 里读，**不需要挂载网页组件**。
     *
     * 为什么 ② 是主力：真机上 ① 对这个账号一律回 400（连普通 note 都发不出去），
     * 而 ② 用的正是官方网页客户端自己那条变更。① 留着是因为它更省事，IG 哪天放开就直接生效。
     */
    let ok: boolean = false;
    try {
      ok = await MobileEngage.setReposted(mediaId.trim().length > 0 ? mediaId : id, shortcode, repost);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'mobile repost threw: %{public}s', (error as Error).message);
      ok = false;
    }
    hilog.info(DOMAIN, TAG, 'repost mobile id=%{public}d on=%{public}s ok=%{public}s detail=%{public}s',
      id.length, `${repost}`, ok ? 'y' : 'n', MobileEngage.lastRepostDetail());
    if (ok) {
      return new EngageResult(true, repost, 'mobile');
    }
    let web: boolean = false;
    try {
      web = await WebRepost.setReposted(mediaId.trim().length > 0 ? mediaId : id, id, repost,
        shortcode);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'web repost threw: %{public}s', (error as Error).message);
      web = false;
    }
    hilog.info(DOMAIN, TAG, 'repost web id=%{public}d on=%{public}s ok=%{public}s detail=%{public}s',
      id.length, `${repost}`, web ? 'y' : 'n', WebRepost.lastDetail());
    if (web) {
      return new EngageResult(true, repost, 'web');
    }
    return new EngageResult(false, repost,
      `failed:${MobileEngage.lastRepostDetail()}/${WebRepost.lastDetail()}`);
  }

  /**
   * 媒体 id：能直接用的纯数字 id 就用，否则拿短码去换一次真 pk
   * （见 core/mobileapi/MobileEngage.mediaIdOf）。
   */
  static async mediaId(raw: string, shortcode: string): Promise<string> {
    try {
      return await MobileEngage.mediaIdOf(raw, shortcode);
    } catch (error) {
      return '';
    }
  }

  /** 同 mediaId（旧名字，保留给现有调用点）。 */
  static async mediaIdOf(raw: string, shortcode: string): Promise<string> {
    return await NativeEngage.mediaId(raw, shortcode);
  }
}