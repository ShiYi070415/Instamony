/*
 * 关注 / 取关：走 HTTP 直发（不驱动网页）。
 *
 * ## 端点与依据
 * IG 网页/客户端关注用的是 REST 那一套（不是 GraphQL）：
 *   POST https://www.instagram.com/api/v1/friendships/create/{user_id}/
 *   POST https://www.instagram.com/api/v1/friendships/destroy/{user_id}/
 *   body: user_id={user_id}（form-urlencoded）
 * 和我们已经在用的 `graphql/query` 一样，鉴权全靠 **Cookie + x-csrftoken**，所以直接复用
 * 信息流模板里那份会话头（NativeFeed.sessionHeaders）—— 里面已经有真机抓到的
 * `x-ig-app-id` / `x-asbd-id` / `x-csrftoken` / `user-agent` 等，见 core/NativeFeed.buildHeaders。
 *
 * 为什么不再另抓一份模板：探针（ProbePanel）抓模板是"把网页发过的请求原样存下来回放"，
 * 用来对付那些带了一大堆签名字段的 GraphQL 请求；关注这条只是表单 POST + 会话头，
 * 模板里真正有用的部分（Cookie / csrf / app-id / UA）信息流模板已经全都有了。
 * 真机上如果 IG 回 400/403，用探针在网页里点一次关注、抓到 `friendships/create` 那条，
 * 把它的额外头（如 `x-ig-www-claim`、`x-requested-with`）补进 NativeFeed.HEADER_EXTRA 即可。
 *
 * ## 返回什么
 * 响应体形如 `{"status":"ok","friendship_status":{"following":true,...}}`，
 * 所以"到底成没成"以服务端回的 friendship_status.following 为准，不看我们自己发的是 create
 * 还是 destroy（IG 有时候对重复关注直接回 idempotent 成功）。
 */

import { http } from '@kit.NetworkKit';
import { MobileEngage } from './mobileapi/MobileEngage';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiTemplate } from '../bridge/ApiRegistry';
import { RestSession } from './RestSession';
import { JsonRead } from './JsonRead';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeFollow';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 8000;
/** `statesFor` 那次批量查询的超时（比关注本身短一点：它只是补状态，等不到就算了）。 */
const TIMEOUT_MS: number = 6000;

/** 关注请求的结果（不抛异常，失败用 ok=false + detail 表达）。 */
export class FollowResult {
  readonly ok: boolean;
  /** 服务端确认的最终状态（失败时原样回传入的期望值，调用方据此决定要不要回滚 UI）。 */
  readonly following: boolean;
  readonly detail: string;

  constructor(ok: boolean, following: boolean, detail: string) {
    this.ok = ok;
    this.following = following;
    this.detail = detail;
  }
}

export class NativeFollow {
  /**
   * 关注 / 取关。
   *
   * @param userId 作者的用户 id（信息流里解析出来的 `user.pk`）。
   * @param follow true = 关注，false = 取关。
   */
  static async setFollowing(userId: string, follow: boolean): Promise<FollowResult> {
    /*
     * **移动端 REST 优先**（见 core/mobileapi/MobileEngage）：
     * friendships/create|destroy/{pk}/，不需要网页模板。失败再走原路。
     */
    try {
      const mobileOk: boolean = await MobileEngage.setFollowing(userId, follow);
      if (mobileOk) {
        return new FollowResult(true, follow, 'mobile');
      }
    } catch (error) {
    }
    const id: string = userId.trim();
    if (id.length === 0) {
      return new FollowResult(false, follow, 'no-user-id');
    }
    // 先要 REST 模板那份头（网页专有：claim / instagram-ajax / asbd-id）：
    // 少了它这条 POST 会被 IG 当成页面导航，回一整页 HTML。
    // 头与表单令牌都由 core/RestSession 统一给（和 media info 那条路同一套）。
    const tpl: ApiTemplate | null = RestSession.template();
    const headers: Record<string, string> = await RestSession.headers();
    if (Object.keys(headers).length === 0) {
      return new FollowResult(false, follow, 'no-session');
    }
    const action: string = follow ? 'create' : 'destroy';
    const url: string = `https://www.instagram.com/api/v1/friendships/${action}/${id}/`;    // 表单体：优先用模板里的 `fb_dtsg` / `jazoest`（两者必须成对，校验和是对得上的）；
    // 模板还没抓到就**现从页面读**（见 RestSession.formTokens）。再带上目标 id（id 本来在路径里，
    // 写进表单只是让服务端多一个确认来源，多余参数会被忽略）。
    const tokens: string = await RestSession.formTokens(tpl);
    const body: string = tokens.length > 0
      ? `${tokens}&user_id=${encodeURIComponent(id)}`
      : `user_id=${encodeURIComponent(id)}`;
    hilog.info(DOMAIN, TAG, 'follow req action=%{public}s id=%{public}s tpl=%{public}s tokens=%{public}s hdr=[%{public}s]',
      action, id, `${tpl !== null}`, `${tokens.length > 0}`, Object.keys(headers).join(','));
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
      const code: number = response.responseCode;
      // **判据要严**：IG 对不认识的请求会回 200 + 一整页 HTML（信息流那边踩过同一个坑），
      // 只看 HTTP 码会把"其实没关注成功"报成成功。这里要求响应体里真的有
      // friendship_status（关注接口的 JSON 标志），否则一律算失败并打出响应片段。
      const looksJson: boolean = text.indexOf('"friendship_status"') >= 0
        || text.indexOf('"status":"ok"') >= 0;
      const following: boolean = NativeFollow.readFollowing(text, follow);
      const ok: boolean = code === 200 && looksJson;
      hilog.info(DOMAIN, TAG, 'follow rsp action=%{public}s code=%{public}d json=%{public}s following=%{public}s len=%{public}d',
        action, code, `${looksJson}`, `${following}`, text.length);
      if (!ok) {
        hilog.warn(DOMAIN, TAG, 'follow rsp body: %{public}s',
          text.substring(0, 160).replace(/[\r\n]+/g, ' '));
      }
      return new FollowResult(ok, following, ok ? '' : `http-${code}${looksJson ? '' : '/non-json'}`);
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'follow failed: %{public}s', message);
      return new FollowResult(false, follow, `throw:${message}`.substring(0, 60));
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * **批量问一批用户的关注状态**（`friendships/show_many`）。
   *
   * 为什么要它：Reels 页那颗关注按钮的状态来自数据源（clips / 推荐流那条载荷里的
   * `user.friendship_status.following`），但**有的载荷没这个字段** —— 那就只能问一次。
   * 这个端点一次能问一批人（`user_ids=1,2,3`），GET 就能通（和 NativeNotifications 里
   * 那条同一个端点、同一套头）。
   *
   * @returns id → following 的表（问不到的人不在表里）。
   */
  static async statesFor(ids: Array<string>): Promise<Map<string, boolean>> {
    const out: Map<string, boolean> = new Map<string, boolean>();
    const wanted: Array<string> = [];
    for (let index: number = 0; index < ids.length; index++) {
      const one: string = ids[index].trim();
      if (one.length > 0 && wanted.indexOf(one) < 0) {
        wanted.push(one);
      }
    }
    if (wanted.length === 0) {
      return out;
    }
    const headers: Record<string, string> = await RestSession.headers();
    if (Object.keys(headers).length === 0) {
      return out;
    }
    const url: string = 'https://www.instagram.com/api/v1/friendships/show_many/'
      + `?user_ids=${encodeURIComponent(wanted.join(','))}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const code: number = response.responseCode;
      if (code !== 200 || text.indexOf('"friendship_statuses"') < 0) {
        hilog.info(DOMAIN, TAG, 'show_many code=%{public}d len=%{public}d (no states)',
          code, text.length);
        return out;
      }
      const dto: Record<string, Object> = JsonRead.parse(text);
      const statuses: Record<string, Object> | null = JsonRead.recordOf(dto, 'friendship_statuses');
      if (statuses === null) {
        return out;
      }
      for (let index: number = 0; index < wanted.length; index++) {
        const one: Record<string, Object> | null = JsonRead.recordOf(statuses, wanted[index]);
        if (one === null) {
          continue;
        }
        out.set(wanted[index], JsonRead.boolOf(one, 'following'));
      }
      hilog.info(DOMAIN, TAG, 'show_many asked=%{public}d got=%{public}d',
        wanted.length, out.size);
      return out;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'show_many failed: %{public}s', (error as Error).message);
      return out;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 从响应体里读最终关注状态。
   *
   * 不引 JSON 结构体（这里的形状可能会变），只在文本里找 `"following":true/false`：
   * 与 NativeFeed 里统计数据那套"按字段名找"的做法一致。
   *
   * **优先在 `friendship_status` 里面找**：同一个响应里别处也可能出现 `"following"`（推荐位、
   * 建议关注列表等），从文档开头一路 indexOf 有可能先撞上它们 —— 那样取关明明成功、
   * 我们却读到 `true`，于是"取关后界面又弹回已关注"（用户报的"无法取消关注"）。
   * 找不到 `friendship_status` 才退回全文查找；再找不到就用调用方给的**意图值**兜底。
   */
  private static readFollowing(text: string, fallback: boolean): boolean {
    const lower: string = text.toLowerCase();
    const anchor: number = lower.indexOf('"friendship_status"');
    const from: number = anchor >= 0 ? anchor : 0;
    const at: number = lower.indexOf('"following"', from);
    if (at < 0) {
      return fallback;
    }
    const tail: string = lower.substring(at, Math.min(lower.length, at + 24));
    if (tail.indexOf('true') >= 0) {
      return true;
    }
    if (tail.indexOf('false') >= 0) {
      return false;
    }
    return fallback;
  }
}
