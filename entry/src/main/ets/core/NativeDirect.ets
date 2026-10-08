/*
 * 私信（Direct）的**原生 HTTP** 取数。
 *
 * ## 为什么要这一层
 * 私信最早只有"回放"一条路（DirectViewModel → bridge.runBridge(directInboxScript)）：把存下来的
 * 模板**送回网页里**发一次，再把抽好的十几个字段过桥回来。那条路的三个毛病：
 *   1. 隐藏网页必须活着且**停在能跑脚本的状态**（还在水合时注入常抢不到执行机会，得短超时 +
 *      重试，最坏 4×2.5s）；
 *   2. 每次都要"过桥"一趟（几百 KB 的响应在网页里解析完还要序列化回来）；
 *   3. 页面停在别的地址时还得先导航、读完再送回首页信息流（见 DirectViewModel.returnToFeed）。
 *
 * 这里把它换成**原生直发**：模板（method / url / headers / body）已经在原生侧存着
 * （ApiRegistry.storedForNative），照着它发一次 HTTP 就完事 —— 和「我的」四个分页
 * （core/NativeProfile）完全同一套做法，所以行为也一致：**请求体原样重发、只改 variables.after**。
 *
 * ## 为什么模板名不写死在"字段路径"里
 * 响应里那条连接的**字段名会变**（`threads_by_folder` 挂在 data 下哪个键上，实测不固定），
 * 所以解析和网页脚本一样：在 `data` 里找第一个**带 `threads_by_folder` 的对象**，不认死键名。
 * 线程里的媒体挂法同理（`node.as_ig_direct_thread` 有就用，没有就当 node 本身是 thread）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { ApiThrottle } from './ApiThrottle';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { JsonRead } from './JsonRead';
import { NativeFeed } from './NativeFeed';
import { NativeProfile } from './NativeProfile';
import { RestSession } from './RestSession';
import { DirectInboxPage, DirectMapper, DirectThread, DirectThreadView } from '../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeDirect';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 15000;
const SITE: string = 'https://www.instagram.com';

/** 收件箱那条查询的操作名（网页侧实际发的就是它，见 DirectViewModel 的说明）。 */
const OP_INBOX: string = 'PolarisDirectInboxMobileQuery';
/** 找那条连接用的特征键（字段名不写死，见文件头）。 */
const BOX_KEY: string = 'threads_by_folder';
/** 一次读多少条消息（和手机端一致）。 */
const THREAD_LIMIT: number = 20;
/**
 * IG 网页版的 app id。
 *
 * `direct_v2` 那条私有 REST 校验它；缺了会回 `login_required` 或 403（看着像"没登录"，
 * 其实只是少一个头）。模板里带了就用模板的，没带才用这个兜底值。
 */
const APP_ID: string = '936619743392459';
/** **安卓 App** 的 app id（`broadcast` 那条写接口认的是这一套身份，见 probeSendShape）。 */
const ANDROID_APP_ID: string = '567067343352427';
/**
 * 安卓 App 的 User-Agent（发送自检用）。
 *
 * 真机上第一发私信被 `{"message":"useragent mismatch"}` 拒了：只读那两条（收件箱 / 会话）
 * 不校验身份，**写**那条校验 —— 头里带的是网页 UA，它在等手机 App 那一串。
 */
const ANDROID_UA: string =
  'Instagram 275.0.0.27.98 Android (30/11; 420dpi; 1080x2340; samsung; SM-G991B; o1s; exynos2100; en_US; 303244333)';

/** 自检要试的一种"身份"（见 probeSendShape）。 */
class SendIdentity {
  readonly name: string;
  readonly userAgent: string;
  readonly appId: string;
  readonly device: boolean;
  readonly claimZero: boolean;

  constructor(name: string, userAgent: string, appId: string, claimZero: boolean,
              device: boolean = false) {
    this.name = name;
    this.userAgent = userAgent;
    this.appId = appId;
    this.claimZero = claimZero;
    this.device = device;
  }
}

/** 一次请求的结果（同 NativeProfileResult 的用法：失败也带原因，界面/日志都要用）。 */
class DirectFetchResult {
  readonly ok: boolean;
  readonly text: string;
  readonly detail: string;

  constructor(ok: boolean, text: string, detail: string) {
    this.ok = ok;
    this.text = text;
    this.detail = detail;
  }
}

export class NativeDirect {
  /** 最近一次失败的原因（诊断用，界面上的状态行就是排查通道）。 */
  private static detail: string = '-';
  /** `restHeaders()` 的重入闸（见那里的说明：绕回来就会爆栈）。 */
  private static restBusy: boolean = false;
  /** 最近一次 patchThreadVars 换掉了哪个键（诊断用，见 replayThread）。 */
  private static lastPatch: string = '-';
  /** 结构摘要只打一次（见 replayThread，避免每轮都刷 80 行）。 */
  private static described: number = 0;
  /** 会话模板的请求体只打一次（诊断用，见 replayThread：翻页变量叫什么只能从这里看）。 */
  private static bodyLogged: number = 0;

  static lastDetail(): string {
    return NativeDirect.detail;
  }

  /**
   * 收件箱那条模板在不在（按**原生那条 TTL** 算，理由见 NativeProfile.hasTemplate）。
   */
  static hasInboxTemplate(): boolean {
    return ApiRegistry.getInstance().storedForNative(OP_INBOX) !== null;
  }

  /**
   * **会话（消息）那条模板在不在**。
   *
   * 和收件箱不是同一条查询：收件箱是 `PolarisDirectInboxMobileQuery`，会话详情是另一条
   * （见 threadOps 的候选名单）。所以两者要分别判 —— 「私信列表能用」不代表「会话详情能用」。
   */
  static hasThreadTemplate(): boolean {
    return NativeDirect.threadOps().length > 0;
  }

  /** 会话模板的操作名（第一个候选；没有返回空串）。 */
  static threadOp(): string {
    const ops: Array<string> = NativeDirect.threadOps();
    return ops.length > 0 ? ops[0] : '';
  }

  /**
   * **会话模板的候选操作名**（按优先级，回放时逐个试）。
   *
   * 为什么不写死一个名字：IG 网页版打开一条会话时发的那条查询，名字在不同版本/入口下不一样
   * （`PolarisDirectThreadQuery` / `useDirectThreadQuery` / `PolarisDirectMessageListQuery`…）。
   * 真机实测：进会话页之后多出来的那条是 `useIGDSystemFolderUnreadThreadCountQuery` ——
   * **名字里带 thread 但只是"未读计数"**，拿它回放当然读不出消息（所以下面有排除词表）。
   *
   * 于是按"名字里带 thread / direct / message"放宽，再逐个试着回放，谁解析成功就用谁。
   */
  static threadOps(): Array<string> {
    /*
     * **排除词**：这些名字里带 thread/direct，但不是"读一条会话的消息"。
     *
     * 尤其 `unread`/`count`/`badge`：`useIGDSystemFolderUnreadThreadCountQuery` 会被宽匹配抓进来，
     * 而它的响应里只有未读数 —— 一旦被当成"模板在"，冷启动那条路就会被跳过（真机上就这么
     * 卡住的：hasThreadTemplate 为真 → 不抓模板 → 回放读不出东西 → 一直"读取失败"）。
     */
    const BAD: Array<string> = ['inbox', 'unread', 'count', 'badge', 'presence', 'mutation',
      'folder', 'quickpromotion', 'insights'];
    const names: Array<string> = ApiRegistry.getInstance().storedNames();
    const strong: Array<string> = [];
    const weak: Array<string> = [];
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      const lower: string = name.toLowerCase();
      let bad: boolean = false;
      for (let b: number = 0; b < BAD.length; b++) {
        if (lower.indexOf(BAD[b]) >= 0) {
          bad = true;
          break;
        }
      }
      if (bad) {
        continue;
      }
      if (lower.indexOf('thread') >= 0) {
        // 优先"私信里的会话"（PolarisDirect…Thread…），其次任何带 thread 的。
        if (lower.indexOf('direct') >= 0) {
          strong.unshift(name);
        } else {
          strong.push(name);
        }
      } else if (lower.indexOf('direct') >= 0 || lower.indexOf('message') >= 0) {
        weak.push(name);
      }
    }
    return strong.concat(weak);
  }

  /** 诊断：把"像会话的模板名"打出来（抓模板之后看抓到的是哪一条）。 */
  static logThreadCandidates(): void {
    const ops: Array<string> = NativeDirect.threadOps();
    hilog.info(DOMAIN, TAG, 'thread candidates n=%{public}d %{public}s',
      ops.length, ops.length > 0 ? ops.join('|') : '(none)');
  }

  /**
   * 把会话模板 `variables` 的键名和分页变量（`min_uq_seq_id`）的值打出来（诊断用，可重复调用）。
   *
   * 翻页卡在"这个变量该填什么"上：我们手上的不透明 `end_cursor`（132 字符）和 `mid.$…` 都被
   * IG 忽略（回同一页）。让网页自己往上滚一屏、再抓一次模板，这里就能看到它填的真实值形态。
   */
  static logThreadVars(label: string): void {
    const op: string = NativeDirect.threadOp();
    if (op.length === 0) {
      hilog.warn(DOMAIN, TAG, 'vars %{public}s: no template', label);
      return;
    }
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl === null) {
      hilog.warn(DOMAIN, TAG, 'vars %{public}s: no cfg', label);
      return;
    }
    const body: string = tpl.body ?? '';
    const at: number = body.indexOf('variables=');
    if (at < 0) {
      hilog.warn(DOMAIN, TAG, 'vars %{public}s: no variables len=%{public}d', label, body.length);
      return;
    }
    const seg: string = body.substring(at + 'variables='.length);
    const cut: number = seg.indexOf('&');
    const raw: string = cut >= 0 ? seg.substring(0, cut) : seg;
    try {
      const vars: Record<string, Object> =
        JSON.parse(decodeURIComponent(raw)) as Record<string, Object>;
      const seq: string = JsonRead.strOf(vars, 'min_uq_seq_id');
      const seqType: string = vars['min_uq_seq_id'] === null || vars['min_uq_seq_id'] === undefined
        ? 'null' : typeof vars['min_uq_seq_id'];
      hilog.info(DOMAIN, TAG, 'vars %{public}s keys=%{public}s min_uq_seq_id=%{public}s (%{public}s)',
        label, Object.keys(vars).join(','), seq.length > 0 ? seq : '-', seqType);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'vars %{public}s parse failed: %{public}s',
        label, (error as Error).message);
    }
  }

  /**
   * 拉一页收件箱（拿不到给 null，调用方决定退回回放还是报错）。
   *
   * @param after 翻页游标（空串 = 第一页；第一页**不动** variables，理由见 NativeProfile.bodyWith）。
   */
  static async inbox(after: string): Promise<DirectInboxPage | null> {
    const result: DirectFetchResult = await NativeDirect.post(OP_INBOX, after);
    if (!result.ok) {
      return null;
    }
    const page: DirectInboxPage | null = NativeDirect.inboxOf(result.text);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'inbox parse failed body=%{public}s',
        result.text.substring(0, 400));
      return null;
    }
    hilog.info(DOMAIN, TAG, 'inbox ok n=%{public}d more=%{public}s cursor=%{public}d',
      page.threads.length, `${page.hasMore}`, page.endCursor.length);
    /*
     * 诊断：第一行的标题 + 头像地址前缀。
     *
     * 收件箱头像画成占位圆时要能一眼分清是"地址就是空的"还是"地址有、下载失败" ——
     * 前者是解析问题（字段名/层级变了），后者是网络/URL 问题，两条路的修法完全不同。
     */
    if (page.threads.length > 0) {
      hilog.info(DOMAIN, TAG, 'inbox first title=%{public}s avatar=%{public}s',
        page.threads[0].title, page.threads[0].avatarUrl.substring(0, 90));
    }
    return page;
  }

  /**
   * **收件箱翻页**：走私有 REST `/api/v1/direct_v2/inbox/`（见 DirectMapper.inboxFromRestJson）。
   *
   * 为什么不用上面那条 GraphQL 模板翻页：它的 `variables` 里**没有分页键**
   * （实测只有 device_id 与几个 relay 开关，没有 after/cursor），多传变量会被忽略 ——
   * "加载更多"永远把第一页再要一遍。REST 这条给 `next_max_id`，是真正能翻的游标。
   *
   * @param cursor 上一页的 `next_max_id`（空串 = 第一页）。
   */
  static async inboxRest(cursor: string): Promise<DirectInboxPage | null> {
    const headers: Record<string, string> = await NativeDirect.restHeaders();
    if (Object.keys(headers).length === 0) {
      NativeDirect.detail = 'no-session';
      return null;
    }
    /*
     * 用**手机 App 的身份**发这一发。
     *
     * 模拟器实测：拿 Web 那套头打这条接口，IG 会当成"未登录"——回 404 + 一页
     * `class="no-js not-logged-in"` 的 HTML。会话详情的 REST 走 Web 头是通的，但收件箱
     * 这条要 App 身份，和发送那条一样：**安卓 UA + 安卓 app id**。
     */
    // 手机 App 的完整身份（UA + app id + device id + www-claim 0，见 applyAndroidIdentity）。
    await NativeDirect.applyAndroidIdentity(headers);
    const tail: string = cursor.length > 0 ? `&cursor=${encodeURIComponent(cursor)}` : '';
    const url: string = 'https://www.instagram.com/api/v1/direct_v2/inbox/?limit=20'
      + '&thread_message_limit=1&persistentBadging=true' + tail;
    const text: string = await NativeDirect.send(url, http.RequestMethod.GET, headers, '');
    if (text.length === 0) {
      return null;
    }
    const page: DirectInboxPage | null = DirectMapper.inboxFromRestJson(text);
    if (page === null) {
      hilog.info(DOMAIN, TAG, 'inboxRest parse failed body=%{public}s', text.substring(0, 300));
      return null;
    }
    hilog.info(DOMAIN, TAG, 'inboxRest ok n=%{public}d next=%{public}d',
      page.threads.length, page.endCursor.length);
    return page;
  }

  /**
   * 发一次模板请求（模板 → 头 + 体）。
   *
   * 头用 `NativeFeed.headersFor(op)`：拿模板里那份**网页自己发过的**头（Cookie / csrf /
   * app-id / UA …）并刷新 Cookie —— 少一个都可能被 IG 当成页面导航、回一整页 HTML。
   */
  private static async post(op: string, after: string): Promise<DirectFetchResult> {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl === null) {
      NativeDirect.detail = 'no-template';
      hilog.warn(DOMAIN, TAG, 'no-template op=%{public}s stored=%{public}s',
        op, ApiRegistry.getInstance().storedSummary());
      return new DirectFetchResult(false, '', 'no-template');
    }
    /*
     * 头：先按这条 op 的模板取（模板里那份"网页自己发过的头"最可靠）；取不到就退回
     * `sessionOrBrowserHeaders()`（任意会话头 → 浏览器头），和 RestSession.headers() 一个思路。
     *
     * 为什么必须有这条兜底：**包里预置的模板是剥掉会话令牌的**（cookie / csrf / www-claim 都没了，
     * 见 ApiRegistry 的说明），只靠 headersFor 会拼不出头 → 私信整条读取就废了；而私信这条
     * 接口的模板恰好经常只能来自预置那份（网页很少会去开 /direct/inbox/）。
     */
    let headers: Record<string, string> = await NativeFeed.headersFor(op);
    if (Object.keys(headers).length === 0) {
      hilog.warn(DOMAIN, TAG, 'headersFor empty op=%{public}s → session/browser fallback', op);
      headers = await NativeFeed.sessionOrBrowserHeaders();
    }
    if (Object.keys(headers).length === 0) {
      NativeDirect.detail = 'no-session';
      hilog.warn(DOMAIN, TAG, 'no-session op=%{public}s (fallback also empty)', op);
      return new DirectFetchResult(false, '', 'no-session');
    }
    const body: string = NativeDirect.bodyWith(tpl, after);
    const url: string = tpl.url.startsWith('http') ? tpl.url : `${SITE}${tpl.url}`;
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
      const looksJson: boolean = text.indexOf('"data"') >= 0 || text.indexOf('"errors"') >= 0;
      hilog.info(DOMAIN, TAG, 'http op=%{public}s code=%{public}d json=%{public}s len=%{public}d',
        op, code, `${looksJson}`, text.length);
      if (code !== 200 || !looksJson) {
        hilog.warn(DOMAIN, TAG, 'http body: %{public}s',
          text.substring(0, 160).replace(/[\r\n]+/g, ' '));
        const why: string = `http-${code}${looksJson ? '' : '/non-json'}`;
        NativeDirect.detail = `${why} body=${text.substring(0, 60)}`;
        return new DirectFetchResult(false, '', why);
      }
      NativeDirect.detail = '-';
      return new DirectFetchResult(true, text, '');
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'http failed op=%{public}s: %{public}s', op, message);
      NativeDirect.detail = `throw:${message}`.substring(0, 80);
      return new DirectFetchResult(false, '', NativeDirect.detail);
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 请求体：**第一页原样重发**，只有翻页时才动 `variables.after`。
   *
   * 和 NativeProfile.bodyWith 同一条判据（那里有详细说明）：模板就是页面自己发过的那一发，
   * 原样重发才行为一致；清掉 after 看着无害，实测会让某些查询回一份"没有连接"的 data。
   */
  private static bodyWith(tpl: ApiTemplate, after: string): string {
    const body: string = tpl.body ?? '';
    if (body.length === 0 || after.length === 0) {
      return body;
    }
    const parts: Array<string> = body.split('&');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index];
      if (one.indexOf('variables=') !== 0) {
        continue;
      }
      try {
        const raw: string = decodeURIComponent(one.substring('variables='.length));
        const src: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        // ArkTS 不支持 `delete`（arkts-no-delete）：**重建**一份，跳过旧的 after 再写新的。
        const out: Record<string, Object> = {};
        const keys: Array<string> = Object.keys(src);
        for (let k: number = 0; k < keys.length; k++) {
          const key: string = keys[k];
          if (key === 'after') {
            continue;
          }
          out[key] = src[key];
        }
        out['after'] = after;
        parts[index] = `variables=${encodeURIComponent(JSON.stringify(out))}`;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'merge variables failed: %{public}s', (error as Error).message);
      }
      break;
    }
    return parts.join('&');
  }

  // ==========================================================================
  // 会话详情 + 发送（REST `/api/v1/direct_v2/…` 那条路）
  // ==========================================================================

  /**
   * 读一条会话的消息（拿不到给 null；见下面 threadViaTemplate 与 `thread()` 的三条路）。
   *
   * @param olderCursor 取更老那批消息的游标（空串 = 最新那批）。
   */
  /**
   * **抓模板 + 原生 HTTP 回放**读会话（用户建议的 B 方案）。
   *
   * 背景：REST `/direct_v2/threads/{id}/` 在真机上被 IG 回 `404 not-logged-in`（收件箱那条
   * 也是这么被挡的，现在靠"网页抓模板 → 原生回放"才通，见 DirectViewModel.fetchInbox）。
   * 会话照抄同一条路：
   *   ① 找**会话类**模板（见 threadOps：名字带 thread / direct 且不带 inbox，按优先级排列）；
   *   ② 模板 body 里带着**捕获时那条会话的 id**，把它换成目标 id（见 patchThreadVars）；
   *   ③ 头条 + POST → `DirectMapper.threadFromGraphql` 解析。
   * 逐个候选试（不知道 IG 这版给那条查询起的是什么名字），谁解析成功就用谁；
   * 全都不成给 null，调用方再走别的兜底。
   *
   * @param altId 另一形式的会话 id（收件箱那条带的 `thread_key`）。同一条会话在 IG 里有
   *   两个 id（`thread_id` 是 30 位那种，网页地址栏里用的是另一个 16 位左右的）——
   *   回放时模板要哪个不确定，所以**两个都试**：真机实测拿 30 位那个回放，IG 回的是
   *   `{"data":{"get_slide_thread_nullable":null}}`（id 对不上，查询本身是通的）。
   */
  static async threadViaTemplate(threadId: string, olderCursor: string,
                                 altId: string = ''): Promise<DirectThreadView | null> {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    const ops: Array<string> = NativeDirect.threadOps();
    NativeDirect.logThreadCandidates();
    if (ops.length === 0) {
      NativeDirect.detail = 'no-thread-template';
      hilog.warn(DOMAIN, TAG, 'threadViaTemplate: no thread template stored=%{public}s',
        registry.storedSummary());
      return null;
    }
    const ids: Array<string> = altId.length > 0 && altId !== threadId
      ? [threadId, altId] : [threadId];
    let empty: DirectThreadView | null = null;
    for (let index: number = 0; index < ops.length; index++) {
      for (let a: number = 0; a < ids.length; a++) {
        const view: DirectThreadView | null =
          await NativeDirect.replayThread(ops[index], ids[a], olderCursor);
        if (view !== null && view.messages.length > 0) {
          NativeDirect.detail = '-';
          hilog.info(DOMAIN, TAG, 'threadViaTemplate ok op=%{public}s id=%{public}d msgs=%{public}d',
            ops[index], a, view.messages.length);
          return view;
        }
        if (view !== null && empty === null) {
          // 会话是真的但没有消息（新会话）—— 先留着，万一另一个 id 有消息就用那个。
          empty = view;
        }
        // 这一条不是会话查询 / 这个 id 不对 → 试下一个。
        hilog.info(DOMAIN, TAG, 'threadViaTemplate miss op=%{public}s id=%{public}d detail=%{public}s',
          ops[index], a, NativeDirect.detail);
      }
    }
    if (empty !== null) {
      NativeDirect.detail = '-';
    }
    return empty;
  }

  /** 用**指定**的模板回放一次并解析；失败给 null（detail 里写原因）。 */
  private static async replayThread(op: string, threadId: string,
                                    olderCursor: string): Promise<DirectThreadView | null> {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    const tpl: ApiTemplate | null = registry.storedForNative(op);
    if (tpl === null) {
      NativeDirect.detail = 'no-template';
      return null;
    }
    /*
     * **请求体打一次**（诊断用）。
     *
     * "上拉加载更老"翻不动，根子就在"游标该塞进哪个变量"—— 而变量名只有请求体能说清
     * （`cursor` / `after` / `before` 都试过没命中）。这里把会话模板的 body 开头打一次，
     * 照着它改 patchThreadVars/replaceIdIn 即可。只打一次，不刷日志。
     */
    if (NativeDirect.bodyLogged === 0 && op.indexOf('IGDThread') >= 0) {
      NativeDirect.bodyLogged = 1;
      const body: string = tpl.body ?? '';
      hilog.info(DOMAIN, TAG, 'thread template body len=%{public}d bodyAt=%{public}d',
        body.length, body.indexOf('variables='));
      /*
       * 真正要的是 `variables=` 那一段：它的**键名清单**决定了"翻页该塞哪个变量"。
       * 顺便把解析结果也打出来 —— form ① 没命中（`cursor:none`）到底是"没有 variables 段"
       * 还是"这段解析不了"，一眼就能分清。
       */
      const at: number = body.indexOf('variables=');
      if (at >= 0) {
        const seg: string = body.substring(at + 'variables='.length);
        const cut: number = seg.indexOf('&');
        const raw: string = cut >= 0 ? seg.substring(0, cut) : seg;
        let err: string = '-';
        try {
          const decoded: string = decodeURIComponent(raw);
          const vars: Record<string, Object> = JSON.parse(decoded) as Record<string, Object>;
          hilog.info(DOMAIN, TAG, 'thread vars keys=%{public}s', Object.keys(vars).join(','));
        } catch (error) {
          err = (error as Error).message;
        }
        hilog.info(DOMAIN, TAG, 'thread vars raw len=%{public}d err=%{public}s head=%{public}s',
          raw.length, err, raw.substring(0, 400));
      }
    }
    let headers: Record<string, string> = await NativeFeed.headersFor(op);
    if (Object.keys(headers).length === 0) {
      headers = await NativeFeed.sessionOrBrowserHeaders();
    }
    if (Object.keys(headers).length === 0) {
      NativeDirect.detail = 'no-session';
      return null;
    }
    /*
     * **只改 `variables` 里那个会话 id**。
     *
     * 这里原来是把整条 body 里所有 16+ 位数字一股脑换成目标 id —— 那是错的：body 里除了
     * `variables`，还有 `doc_id`（十几位的数字）、`av`（`av=<viewer id>`）、`__hsi`、
     * `jazoest`、`lsd`… 全被替换掉之后，IG 收到的就是一条**坏请求**：真机实测回
     * `200 + for(;;);{"error":1357004}`（"请尝试关闭浏览器窗口"那套挑战话术），看着像被风控，
     * 其实是自己把请求拼坏了。
     *
     * 现在按字段改：解析 `variables=` 那段 JSON，把**长数字的 id 值**换成目标 id，
     * `cursor` 换游标，其余（含 doc_id 等）原样保留。
     */
    let body: string = tpl.body ?? '';
    const rewritten: string = NativeDirect.patchThreadVars(body, threadId, olderCursor);
    const hit: boolean = rewritten.length > 0;
    /*
     * **换不掉会话 id 就绝不发这一发**。
     *
     * 模板里带的是**抓取时那条会话**的 id：原样发出去就会把别人的会话读回来显示给用户
     * （真机上踩过 —— 用户报"点进所有会话都显示同一个人的聊天记录"）。宁可这一条候选失败，
     * 让调用方去试下一个候选 / 走冷启动重新抓模板。
     */
    if (!hit) {
      NativeDirect.detail = 'no-id-patch';
      hilog.warn(DOMAIN, TAG, 'replayThread skip op=%{public}s: no id to patch body=%{public}s',
        op, body.substring(0, 300));
      return null;
    }
    body = rewritten;
    const url: string = tpl.url.startsWith('http') ? tpl.url : `${SITE}${tpl.url}`;
    hilog.info(DOMAIN, TAG, 'replayThread op=%{public}s patched=%{public}s hdr=%{public}d url=%{public}s',
      op, `${hit}`, Object.keys(headers).length, url.substring(0, 60));
    hilog.info(DOMAIN, TAG, 'replayThread patch %{public}s', NativeDirect.lastPatch);
    const text: string = await NativeDirect.send(url, http.RequestMethod.POST, headers, body);
    if (text.length === 0) {
      NativeDirect.detail = 'empty';
      return null;
    }
    const view: DirectThreadView | null = DirectMapper.threadFromGraphql(text, '');
    if (view === null) {
      NativeDirect.detail = 'gql-parse';
      hilog.warn(DOMAIN, TAG, 'replayThread parse failed op=%{public}s len=%{public}d body=%{public}s',
        op, text.length, text.substring(0, 200).replace(/[\r\n]+/g, ' '));
      // 结构摘要：解析器要照着真实形状写，见 DirectMapper.describe。
      // 只在**有内容**的响应上打（小响应是 `{...:null}`，形状没有参考价值），最多三份。
      if (text.length > 1000 && NativeDirect.described < 3) {
        NativeDirect.described++;
        hilog.info(DOMAIN, TAG, 'replayThread shape len=%{public}d:\n%{public}s',
          text.length, DirectMapper.describe(text));
      }
      return null;
    }
    return view;
  }

  /**
   * 把模板 body 里 `variables` 那段 JSON 的**会话 id** 换成目标 id（顺带换游标）。
   *
   * 两种 body 形态都认：表单编码（`a=1&variables={…}`）和纯 JSON（`{"variables":{…},…}`）。
   *
   * 返回**改好的整条 body**；找不到任何可换的 id 就返回空串 —— 调用方**必须据此放弃这一发**
   * （见 replayThread）。不能像以前那样对整条 body 做正则替换（会把 `doc_id` / `av` / `__hsi`
   * 一起换掉，请求就废了），也**绝不能原样发出去**：模板里带着抓取时那条会话的 id，
   * 原样发就会把**别人的会话**读回来显示给用户。
   *
   * 认 id 的规则（不写死键名，IG 各版本叫 `thread_id` / `thread_fbid` / `thread_v2_id`…）：
   *   1. 值是字符串且 ≥16 位纯数字 → 换；
   *   2. 值是数字且 ≥1e15 → 换（JSON.parse 会把它舍入，但"很大"这一点还看得出来）；
   *   3. 键名里带 `cursor`/`after` 且给了新游标 → 换成新游标。
   * 第 1、2 条只换**第一个**（一条会话查询里通常只有一个目标 id）。
   */
  private static patchThreadVars(body: string, threadId: string, olderCursor: string): string {
    NativeDirect.lastPatch = '-';
    // 形态①：表单编码（`variables=` 是一个 `&` 分段）。
    if (body.indexOf('variables=') >= 0) {
      const form: string = NativeDirect.patchFormVars(body, threadId, olderCursor);
      if (form.length > 0) {
        return form;
      }
    }
    // 形态②：整条 body 就是 JSON（`{"variables":{…}}`）。
    const asJson: Record<string, Object> = JsonRead.parse(body);
    if (Object.keys(asJson).length > 0) {
      const vars: Record<string, Object> | null = JsonRead.recordOf(asJson, 'variables');
      if (vars !== null && NativeDirect.replaceIdIn(vars, threadId, olderCursor)) {
        return JSON.stringify(asJson);
      }
      /*
       * 形态③：JSON body，但 `variables` 是**一段字符串化的 JSON**
       * （`{"variables":"{\"thread_fbid\":…}"}`）—— IG 有几种请求就是这么发的。
       */
      const varsText: string = JsonRead.strOf(asJson, 'variables');
      if (varsText.length > 0) {
        const inner: Record<string, Object> = JsonRead.parse(varsText);
        if (Object.keys(inner).length > 0
          && NativeDirect.replaceIdIn(inner, threadId, olderCursor)) {
          asJson['variables'] = JSON.stringify(inner);
          return JSON.stringify(asJson);
        }
      }
    }
    /*
     * 形态④：前三种都没认出来时，**按字段名直接换**（明文和 URL 编码两种写法都试）。
     *
     * 这一条是给"模板 body 就是另一套形状"兜底的，只认**会话 id 那几个字段名**，
     * 绝不碰 `doc_id` / `av` / `__hsi`（那就是最初把请求拼坏的原因）。
     */
    return NativeDirect.patchByKeyNames(body, threadId, olderCursor);
  }

  /**
   * 按字段名把会话 id 换掉（明文 + URL 编码两种写法）。
   *
   * 字段顺序有讲究：`thread_fbid` / `thread_id` / `thread_v2_id` 是"会话本身"的 id，
   * 而 `thread_key` 在 1:1 会话里其实是**对方用户的 fbid**（真机日志里
   * `thread_key=17842409426348928` 同时也是消息的 `sender_fbid`）—— 只有当前面几个都不在
   * body 里时才退到它（IG 这条查询也接受用它当 `thread_fbid`，实测能读出来）。
   */
  private static patchByKeyNames(body: string, threadId: string, olderCursor: string): string {
    const keys: Array<string> = ['thread_fbid', 'thread_id', 'thread_v2_id', 'thread_key'];
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      // 明文写法：`"thread_fbid":"123"` / `"thread_fbid":123` / `thread_fbid=123`
      const plain: RegExp = new RegExp(`("?${key}"?\\s*[:=]\\s*"?)(\\d{15,})`, 'g');
      // URL 编码写法：`%22thread_fbid%22%3A%22123%22`
      const encoded: RegExp = new RegExp(`(%22${key}%22%3A%22?)(\\d{15,})`, 'g');
      if (plain.test(body) || encoded.test(body)) {
        let out: string = body.replace(plain, `$1${threadId}`);
        out = out.replace(encoded, `$1${threadId}`);
        /*
         * **游标一起换掉**（"上拉加载更老"全靠它）。
         *
         * 明文和 URL 编码两种写法都要试：之前只换了编码那种，模板 body 是明文 JSON 时游标压根没动，
         * 服务端就把**同一页**又回一次 —— 真机日志里就是 `loadOlder: +0`。
         * 换没换到写进 lastPatch（`cursor:set` / `cursor:none`），一眼能看出来是哪一种情况。
         */
        let cursorHit: boolean = false;
        if (olderCursor.length > 0) {
          /*
           * 游标键名挨个试：`cursor` 是最常见的，Relay 那套用 `after`/`before`。
           * 都没命中就把 body 头打出来 —— 真实键名只能从那里看（见下面那条日志）。
           */
          const cursorKeys: Array<string> = ['min_uq_seq_id', 'cursor', 'after', 'before'];
          for (let c: number = 0; c < cursorKeys.length && !cursorHit; c++) {
            const plainCursor: RegExp =
              new RegExp(`("${cursorKeys[c]}"\\s*:\\s*")[^"]*`);
            if (plainCursor.test(out)) {
              out = out.replace(plainCursor, `$1${olderCursor}`);
              cursorHit = true;
            }
            const encodedCursor: RegExp =
              new RegExp(`(%22${cursorKeys[c]}%22%3A%22)[^%]*`);
            if (encodedCursor.test(out)) {
              out = out.replace(encodedCursor, `$1${olderCursor}`);
              cursorHit = true;
            }
          }
          if (!cursorHit) {
            hilog.warn(DOMAIN, TAG, 'no cursor key in body: %{public}s',
              out.substring(0, 400).replace(/[\r\n]+/g, ' '));
          }
        }
        NativeDirect.lastPatch = olderCursor.length > 0
          ? `${key}→${threadId} cursor:${cursorHit ? 'set' : 'none'}`
          : `${key}→${threadId}`;
        return out;
      }
    }
    return '';
  }

  /** 表单编码形态：只重写 `variables=` 那一段（见 patchThreadVars）。 */
  private static patchFormVars(body: string, threadId: string, olderCursor: string): string {
    const parts: Array<string> = body.split('&');
    let changed: boolean = false;
    const out: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const part: string = parts[index];
      if (part.indexOf('variables=') !== 0) {
        out.push(part);
        continue;
      }
      try {
        const vars: Record<string, Object> =
          JSON.parse(decodeURIComponent(part.substring('variables='.length))) as Record<string, Object>;
        if (NativeDirect.replaceIdIn(vars, threadId, olderCursor)) {
          changed = true;
        }
        out.push(`variables=${encodeURIComponent(JSON.stringify(vars))}`);
      } catch (error) {
        out.push(part);
      }
    }
    if (!changed) {
      return '';
    }
    return out.join('&');
  }

  /** 在一份 variables 对象里把会话 id（和游标）换掉；换到了给 true（见 patchThreadVars）。 */
  private static replaceIdIn(vars: Record<string, Object>, threadId: string,
                             olderCursor: string): boolean {
    let changed: boolean = false;
    let replacedId: boolean = false;
    let cursorHit: boolean = false;
    const keys: Array<string> = Object.keys(vars);
    for (let k: number = 0; k < keys.length; k++) {
      const key: string = keys[k];
      const lower: string = key.toLowerCase();
      const value: Object = vars[key];
      if (typeof value === 'string') {
        const text: string = value as string;
        if (!replacedId && text.length >= 16 && /^\d+$/.test(text)) {
          vars[key] = threadId;
          replacedId = true;
          changed = true;
          NativeDirect.lastPatch = `${key}=${text}→${threadId}`;
        } else if (olderCursor.length > 0
          && (lower.indexOf('cursor') >= 0 || lower === 'after'
            || lower.indexOf('seq') >= 0)) {
          vars[key] = olderCursor;
          changed = true;
          cursorHit = true;
        }
      } else if (typeof value === 'number') {
        const num: number = value as number;
        if (!replacedId && num >= 1e15) {
          // 大整数经 JSON.parse 已被舍入，只能整体换成字符串形式的目标 id。
          vars[key] = threadId;
          replacedId = true;
          NativeDirect.lastPatch = `${key}=${num}→${threadId}`;
        }
      }
    }
    /*
     * 翻页诊断：**这条查询的 variables 里到底有没有游标键**。
     *
     * 没有的话"上拉加载更老"永远是同一页（下拉看着没反应）—— 日志里 `cursor:none` 就是这个
     * 意思，得换别的翻页办法（比如按最早那条消息的时间另拉一段）。
     */
    if (olderCursor.length > 0) {
      NativeDirect.lastPatch =
        `${NativeDirect.lastPatch} cursor:${cursorHit ? 'set' : 'none'} keys:${keys.join(',')}`;
    }
    /*
     * **只认"会话 id 换掉了"**（游标换掉不算）—— 否则换了个游标、id 还是上一条会话的，
     * 就等于把**别人的会话**当成本次结果返回（用户报的"点进所有会话都显示同一个人"）。
     */
    return replacedId;
  }

  /**
   * 读一条会话：① **回放会话模板**（`IGDThreadDetailQuery`，见 threadViaTemplate）→
   * ② 原生 REST `/api/v1/direct_v2/threads/{id}/`（兜底）。
   *
   * 顺序为什么是"模板先"：真机上那条 REST 已经被 IG 按会话/设备挡成 `404 not-logged-in`
   * （20KB 的 HTML，看着像"会话不存在"），每次先发它只是白等一个往返；而模板回放实测能拿到
   * 真数据。REST 留着是因为它在别的会话/网络下曾经能通，模板过期时它就是唯一的路。
   *
   * @param altId 同一条会话的另一个 id（收件箱带过来的 `thread_key`），回放时两个都试。
   */
  static async thread(threadId: string, olderCursor: string,
                      altId: string = ''): Promise<DirectThreadView | null> {
    const id: string = threadId.trim();
    if (id.length === 0) {
      NativeDirect.detail = 'no-thread-id';
      return null;
    }
    // ① 模板回放（抓到过会话模板时这条最快，也是真机上唯一能通的那条）。
    const viaTemplate: DirectThreadView | null =
      await NativeDirect.threadViaTemplate(id, olderCursor, altId);
    if (viaTemplate !== null && viaTemplate.messages.length > 0) {
      return viaTemplate;
    }
    // ② REST 兜底。
    const headers: Record<string, string> = await NativeDirect.restHeaders();
    if (Object.keys(headers).length === 0) {
      NativeDirect.detail = 'no-session';
      return viaTemplate;
    }
    const base: string = `https://www.instagram.com/api/v1/direct_v2/threads/${encodeURIComponent(id)}/`;
    const cursor: string = olderCursor.length > 0
      ? `&cursor=${encodeURIComponent(olderCursor)}` : '';
    /*
     * **和收件箱翻页那条一样用手机 App 的身份**（安卓 UA + 安卓 app id）。
     *
     * 真机实测：只带网页那套头发这一条，IG 回 404 + 一页 `class="no-js not-logged-in"` 的 HTML
     * （响应体 20KB、看着像"会话不存在"，其实是被当成没登录）—— 用户报的"打开会话显示 404"
     * 就是这个。`inboxRest` 当初就是这么修的，会话详情这条漏了（它曾经用网页身份能通，
     * 后来 IG 收紧了口径）。
     */
    // 手机 App 的完整身份（UA + app id + device id + www-claim 0，见 applyAndroidIdentity）。
    await NativeDirect.applyAndroidIdentity(headers);
    const url: string = `${base}?limit=${THREAD_LIMIT}&visual_message_return_type=unseen${cursor}`;
    const text: string = await NativeDirect.send(url, http.RequestMethod.GET, headers, '');
    if (text.length === 0) {
      return viaTemplate;
    }
    const view: DirectThreadView | null =
      DirectMapper.threadFromJson(text, NativeProfile.ownIdCached());
    if (view === null) {
      hilog.info(DOMAIN, TAG, 'thread parse failed body=%{public}s', text.substring(0, 400));
      NativeDirect.detail = 'parse';
      return viaTemplate;
    }
    hilog.info(DOMAIN, TAG, 'thread ok id=%{public}s msgs=%{public}d older=%{public}s avatar=%{public}s',
      id, view.messages.length, `${view.hasOlder}`, view.withAvatar.substring(0, 90));
    return view;
  }

  /**
   * 发一条**文本**私信（成功给 true）。
   *
   * 就是网页/手机端自己用的那发（`POST /api/v1/direct_v2/threads/broadcast/text/`）：
   * 表单体是 `action=send_item` + `thread_ids=[…]` + `text=…` + 会话令牌（`_csrftoken` /
   * `fb_dtsg` / `jazoest`，见 RestSession.formTokens）—— 和 NativeEngage 那条"点赞/转发"
   * 的写法完全一致（那条在真机上发出去过）。
   *
   * `client_context` 是这条消息的幂等键：**每次发送必须换一个**（同一个值重发会被 IG 当成
   * 重复消息丢掉，界面看着就是"发了没反应"）。
   */
  static async sendText(threadId: string, text: string): Promise<boolean> {
    const id: string = threadId.trim();
    const body: string = text;
    if (id.length === 0 || body.length === 0) {
      NativeDirect.detail = 'no-thread-or-text';
      return false;
    }
    /*
     * **优先用"刚抓到的那份会话模板"里的头**，而不是自己拼的那套。
     *
     * 写接口（broadcast）在真机上第一发就是被这套头卡住的：`useragent mismatch` / 404
     * `not-logged-in`。而模板里存的是**网页自己那次请求的完整头**（`x-ig-www-claim` 这种
     * 会话级 hmac、`x-asbd-id`、`x-instagram-ajax`、`x-csrftoken`…）—— 网页能发消息，
     * 就说明这套头是 IG 认的。自己拼的那套只当模板还没抓到时兜底。
     */
    let headers: Record<string, string> = {};
    const op: string = NativeDirect.threadOp();
    if (op.length > 0) {
      headers = await NativeFeed.headersFor(op);
      if (Object.keys(headers).length > 0) {
        hilog.info(DOMAIN, TAG, 'send headers from template op=%{public}s n=%{public}d',
          op, Object.keys(headers).length);
      }
    }
    if (Object.keys(headers).length === 0) {
      headers = await NativeDirect.restHeaders();
    }
    if (Object.keys(headers).length === 0) {
      NativeDirect.detail = 'no-session';
      return false;
    }
    /*
     * 这一族在退避期内就**别发了**：写接口被限流时继续打只会把窗口拉长
     * （诊断期间我自己也打过几发握手自检，这里顺手把它们计入的退避当回事）。
     */
    if (ApiThrottle.blocked(ApiThrottle.DIRECT)) {
      NativeDirect.detail = `throttled-${ApiThrottle.remainingMinutes(ApiThrottle.DIRECT)}min`;
      hilog.warn(DOMAIN, TAG, 'send skipped: direct family throttled %{public}dmin left',
        ApiThrottle.remainingMinutes(ApiThrottle.DIRECT));
      return false;
    }
    /*
     * **写接口要换手机 App 的 User-Agent**（自检实测的结论，见 probeSendShape）：
     *   · 网页 UA          → `400 {"message":"useragent mismatch"}`（IG 直接不认）；
     *   · `android-ua`     → 通过了身份校验（IG 改成对"会话不存在"报 500）；
     *   · `android-all`（再叠安卓 app id + 设备头 + www-claim=0）→ 又被判回 400。
     * 所以只换 UA、别的头保持原样，就是能用的那一套。
     */
    NativeDirect.putHeader(headers, 'user-agent', ANDROID_UA);
    const tokens: string = await RestSession.formTokens();
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    const parts: Array<string> = [];
    parts.push('action=send_item');
    parts.push(`thread_ids=${encodeURIComponent(`[${id}]`)}`);
    parts.push(`text=${encodeURIComponent(body)}`);
    parts.push(`client_context=${NativeDirect.clientContext()}`);
    /*
     * `_csrftoken` 要**同时**出现在头（见 restHeaders）和体里：IG 的写类接口
     * （broadcast / save / friendship…）是按表单里的 `_csrftoken` 校验的，只放头里会被判成
     * `csrf` 失败；值就是 Cookie 里的 `csrftoken`。
     */
    const csrf: string = NativeDirect.cookieValue(jar.cookie, 'csrftoken');
    if (csrf.length > 0) {
      parts.push(`_csrftoken=${encodeURIComponent(csrf)}`);
    }
    /*
     * `_uuid` = **设备 uuid**（IG 用 `ig_did` 这个 Cookie 存它）。手机端/网页端发消息都带它，
     * 少了有些会话会被判成"参数不完整"（400 invalid_parameters）。
     */
    const deviceId: string = NativeDirect.cookieValue(jar.cookie, 'ig_did');
    if (deviceId.length > 0) {
      parts.push(`_uuid=${encodeURIComponent(deviceId)}`);
    }
    if (tokens.length > 0) {
      parts.push(tokens);
    }
    const url: string = 'https://www.instagram.com/api/v1/direct_v2/threads/broadcast/text/';
    const sent: string = await NativeDirect.send(url, http.RequestMethod.POST, headers,
      parts.join('&'));
    if (sent.length === 0) {
      return false;
    }
    const ok: boolean = sent.indexOf('"status":"ok"') >= 0 || sent.indexOf('"status": "ok"') >= 0;
    if (!ok) {
      hilog.warn(DOMAIN, TAG, 'send failed body: %{public}s',
        sent.substring(0, 200).replace(/[\r\n]+/g, ' '));
      /*
       * IG 的写接口失败有两层：HTTP 码 + 体里的 `error_code`。把 error_code 抠出来放进
       * detail，界面上的状态行就能直接显示"为什么没发出去"（如 `1545023`），不用翻日志。
       */
      const codeAt: number = sent.indexOf('"error_code":"');
      const errCode: string = codeAt >= 0
        ? sent.substring(codeAt + '"error_code":"'.length, codeAt + 24).replace(/[^0-9].*$/, '')
        : '';
      NativeDirect.detail = `send-${errCode.length > 0 ? errCode : 'fail'}:${sent.substring(0, 60)}`;
      return false;
    }
    // 成功：把回执里的 item_id 打出来（"发出去了"和"服务端真收下了"是两件事）
    hilog.info(DOMAIN, TAG, 'send ok thread=%{public}s len=%{public}d ack=%{public}s',
      id, body.length, sent.substring(0, 120).replace(/[\r\n]+/g, ' '));
    return true;
  }

  /**
   * **空文本发送探针**（诊断用）：请求体与 `sendText` 完全一样，**只有 `text` 是空的**。
   *
   * 用途：把"身份/参数/会话"这三段验完，而不给任何人发消息 —— IG 的 `broadcast/text/`
   * 要求文本非空，所以这一发只会拿到一条"缺参数"的报错；如果它反而回 `useragent mismatch`，
   * 说明头像/UA 那套还是不对。收尾日志里会打 IG 的原文，据此判断。
   */
  static async probeSendEmptyText(threadId: string): Promise<string> {
    const id: string = threadId.trim();
    if (id.length === 0) {
      return 'no-thread-id';
    }
    const headers: Record<string, string> = await NativeDirect.restHeaders();
    if (Object.keys(headers).length === 0) {
      return 'no-session';
    }
    NativeDirect.putHeader(headers, 'user-agent', ANDROID_UA);
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    const parts: Array<string> = ['action=send_item'];
    parts.push(`thread_ids=${encodeURIComponent(`[${id}]`)}`);
    parts.push('text=');
    parts.push(`client_context=${NativeDirect.clientContext()}`);
    const csrf: string = NativeDirect.cookieValue(jar.cookie, 'csrftoken');
    if (csrf.length > 0) {
      parts.push(`_csrftoken=${encodeURIComponent(csrf)}`);
    }
    const did: string = NativeDirect.cookieValue(jar.cookie, 'ig_did');
    if (did.length > 0) {
      parts.push(`_uuid=${encodeURIComponent(did)}`);
    }
    const url: string = 'https://www.instagram.com/api/v1/direct_v2/threads/broadcast/text/';
    const text: string = await NativeDirect.send(url, http.RequestMethod.POST, headers,
      parts.join('&'));
    const out: string = text.length > 0
      ? text.substring(0, 200).replace(/[\r\n]+/g, ' ')
      : `(empty) ${NativeDirect.detail}`;
    hilog.info(DOMAIN, TAG, 'probe empty-text thread=%{public}s → %{public}s', id, out);
    return out;
  }

  /** 一条消息的幂等键（形如 `<时间戳>-<随机>`，IG 只要求"每次不同"）。 */
  private static clientContext(): string {
    const rand: number = Math.floor(Math.random() * 1000000);
    return `${Date.now()}-${rand}`;
  }

  /**
   * **发送握手自检**（探针面板那颗按钮，诊断用）。
   *
   * 为什么需要它：真机上第一发私信被 IG 拒了 ——
   * `400 {"message":"useragent mismatch","status":"fail"}`（见 sendText 的说明）。
   * 那说明这条**写**接口认的"身份"和只读那两条不一样：头里带的是**网页**的 User-Agent，
   * 而 `broadcast` 要的是**手机 App** 那一套（UA + 安卓 app id + 设备 id）。
   *
   * 于是这里把几种身份**都试一遍**，一次装包就能看出哪一种被接受：
   *   web          —— 现状（网页 UA + 网页 app id）；
   *   android-ua   —— 只换 UA；
   *   android-all  —— UA + 安卓 app id + 设备头 + www-claim=0；
   *   web-claim0   —— 网页 UA，但 www-claim 归零。
   *
   * **全部发往一个不存在的 thread id（`0`）**：UA/参数校验在"这个会话存不存在"之前，
   * 所以照样能看出握手过没过（过不了还是 useragent mismatch；过了会换成"会话不存在/参数错"），
   * 而**不会真的发出去任何一条消息**。
   */
  static async probeSendShape(): Promise<string> {
    const variants: Array<SendIdentity> = [
      new SendIdentity('web', '', '', false),
      new SendIdentity('android-ua', ANDROID_UA, '', false),
      new SendIdentity('android-all', ANDROID_UA, ANDROID_APP_ID, true),
      new SendIdentity('web-claim0', '', '', true)
    ];
    const lines: Array<string> = [];
    for (let index: number = 0; index < variants.length; index++) {
      const one: SendIdentity = variants[index];
      const headers: Record<string, string> = await NativeDirect.restHeaders();
      if (Object.keys(headers).length === 0) {
        lines.push(`${one.name}: no-session`);
        continue;
      }
      if (one.userAgent.length > 0) {
        NativeDirect.putHeader(headers, 'user-agent', one.userAgent);
      }
      if (one.appId.length > 0) {
        NativeDirect.putHeader(headers, 'x-ig-app-id', one.appId);
      }
      if (one.device) {
        const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
        const did: string = NativeDirect.cookieValue(jar.cookie, 'ig_did');
        if (did.length > 0) {
          NativeDirect.putHeader(headers, 'x-ig-device-id', did);
          NativeDirect.putHeader(headers, 'x-ig-android-id',
            `android-${did.replace(/[^0-9a-fA-F]/g, '').substring(0, 16)}`);
        }
      }
      if (one.claimZero) {
        NativeDirect.putHeader(headers, 'x-ig-www-claim', '0');
      }
      const tokens: string = await RestSession.formTokens();
      const parts: Array<string> = ['action=send_item'];
      parts.push(`thread_ids=${encodeURIComponent('[0]')}`);
      parts.push(`text=${encodeURIComponent('selftest')}`);
      parts.push(`client_context=${NativeDirect.clientContext()}`);
      const jar2: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const csrf: string = NativeDirect.cookieValue(jar2.cookie, 'csrftoken');
      if (csrf.length > 0) {
        parts.push(`_csrftoken=${encodeURIComponent(csrf)}`);
      }
      const did2: string = NativeDirect.cookieValue(jar2.cookie, 'ig_did');
      if (did2.length > 0) {
        parts.push(`_uuid=${encodeURIComponent(did2)}`);
      }
      if (tokens.length > 0) {
        parts.push(tokens);
      }
      const url: string = 'https://www.instagram.com/api/v1/direct_v2/threads/broadcast/text/';
      const text: string = await NativeDirect.send(url, http.RequestMethod.POST, headers,
        parts.join('&'));
      const body: string = text.length > 0 ? text.substring(0, 120) : `(empty) ${NativeDirect.detail}`;
      lines.push(`${one.name}: ${body}`);
      hilog.info(DOMAIN, TAG, 'probe send variant=%{public}s → %{public}s',
        one.name, body.replace(/[\r\n]+/g, ' '));
    }
    return lines.join('\n');
  }

  /**
   * 给 headers 套上**手机 App 的完整身份**（DM 读接口用）。
   *
   * 为什么不是只换 UA + app id：真机实测（发送自检 probeSendShape）里，"android-all"那一档才握手成功，
   * 它除了 UA 与 app id，还要 `x-ig-device-id` / `x-ig-android-id`（取自 `ig_did` cookie）与
   * `x-ig-www-claim: 0`。收件箱/会话详情这两条读接口原来只带了前两个，IG 回的就是
   * 404 + `class="no-js not-logged-in"` 的 HTML（用户报的"打开会话 404 / 私信列表报错"）。
   *
   * device id 从**已经拿到的 cookie 头**里直接抠（不再 inspect cookie 罐）—— 少一次跨线程取值。
   */
  private static applyAndroidIdentity(headers: Record<string, string>): void {
    NativeDirect.putHeader(headers, 'user-agent', ANDROID_UA);
    NativeDirect.putHeader(headers, 'x-ig-app-id', ANDROID_APP_ID);
    const cookie: string = NativeDirect.headerOf(headers, 'cookie');
    const did: string = NativeDirect.cookieValue(cookie, 'ig_did');
    if (did.length > 0) {
      NativeDirect.putHeader(headers, 'x-ig-device-id', did);
      NativeDirect.putHeader(headers, 'x-ig-android-id',
        `android-${did.replace(/[^0-9a-fA-F]/g, '').substring(0, 16)}`);
    }
    NativeDirect.putHeader(headers, 'x-ig-www-claim', '0');
  }

  /** 大小写无关地写一个头（模板里那份键名不固定，直接赋值会出现两个同名头）。 */
  private static putHeader(headers: Record<string, string>, name: string,
                           value: string): void {
    const keys: Array<string> = Object.keys(headers);
    const wanted: string = name.toLowerCase();
    for (let index: number = 0; index < keys.length; index++) {
      if (keys[index].toLowerCase() === wanted) {
        headers[keys[index]] = value;
        return;
      }
    }
    headers[name] = value;
  }

  /**
   * REST 那条路要的头：`RestSession.headers()`（模板里那份网页自己发过的头 + Cookie 刷新）
   * 再补两个**私有接口必须有**的：`x-ig-app-id`、`x-csrftoken`。
   *
   * 为什么要补：私信那条 REST 不在任何模板里（模板是收件箱那条 GraphQL），所以只能拿
   * "最近一条 REST 模板（ayml）"的头当底子；IG 对 `direct_v2` 校验 app-id，缺了会回
   * `{"message":"login_required"}` 或直接 403 —— 那种失败只看 HTTP 码很像"没登录"，
   * 其实只是少一个头。
   */
  private static async restHeaders(): Promise<Record<string, string>> {
    /*
     * DM 私有 REST 要的是**手机 App 那套极简头**，不是 GraphQL 模板那套 XHR 头。
     *
     * 真机日志：把模板头（`content-type` / `x-fb-friendly-name` / `x-root-field-name` /
     * `x-fb-lsd` / `x-instagram-ajax` / `origin` / `referer` / `x-requested-with`…）原样带去请求
     * `/api/v1/direct_v2/inbox/`，IG 回的是 **404 + 一页 `class="no-js not-logged-in"` 的 HTML** ——
     * 两套身份口径混着发，会被当成"不是本客户端"。所以这里**从零构造**：浏览器/App 的 cookie
     * 是唯一必须的东西，其余全按安卓 App 来。
     *
     * 依据：发送自检（probeSendShape）里只有 `android-all` 那一档握手成功 —— 它用的就是这套
     * （UA + app id + device id + www-claim 0）。
     */
    const source: Record<string, string> = await RestSession.headers();
    let cookie: string = NativeDirect.headerOf(source, 'cookie');
    if (cookie.length === 0) {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      cookie = jar.cookie;
    }
    if (cookie.length === 0) {
      hilog.warn(DOMAIN, TAG, 'restHeaders no cookie (template names=%{public}s)',
        Object.keys(source).join(','));
      return {};
    }
    const out: Record<string, string> = {};
    out['cookie'] = cookie;
    out['user-agent'] = ANDROID_UA;
    out['x-ig-app-id'] = ANDROID_APP_ID;
    out['x-ig-www-claim'] = '0';
    out['x-ig-connection-type'] = 'WIFI';
    out['accept'] = '*/*';
    out['accept-language'] = 'en-US,en;q=0.9';
    const csrf: string = NativeDirect.cookieValue(cookie, 'csrftoken');
    if (csrf.length > 0) {
      out['x-csrftoken'] = csrf;
    }
    const did: string = NativeDirect.cookieValue(cookie, 'ig_did');
    if (did.length > 0) {
      out['x-ig-device-id'] = did;
      out['x-ig-android-id'] = `android-${did.replace(/[^0-9a-fA-F]/g, '').substring(0, 16)}`;
    }
    hilog.info(DOMAIN, TAG, 'restHeaders(android) names=%{public}s cookie=%{public}d csrf=%{public}d did=%{public}d',
      Object.keys(out).join(','), cookie.length, csrf.length, did.length);
    return out;
  }

  /** 大小写无关地取一个头（HTTP 头本来就不分大小写，模板里的键名不固定）。 */
  private static headerOf(headers: Record<string, string>, name: string): string {
    const keys: Array<string> = Object.keys(headers);
    const wanted: string = name.toLowerCase();
    for (let index: number = 0; index < keys.length; index++) {
      if (keys[index].toLowerCase() === wanted) {
        return headers[keys[index]];
      }
    }
    return '';
  }

  /** 从 Cookie 串里取一个键的值（`a=1; b=2`；取不到给空串）。 */
  private static cookieValue(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      const eq: number = one.indexOf('=');
      if (eq > 0 && one.substring(0, eq) === name) {
        return one.substring(eq + 1);
      }
    }
    return '';
  }

  /** 发一次（GET / POST 只差方法与体），返回响应文本（失败给空串并记原因）。 */
  private static async send(url: string, method: http.RequestMethod,
                           headers: Record<string, string>, body: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: method,
        header: headers,
        extraData: method === http.RequestMethod.POST ? body : undefined,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const raw: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      /*
       * **剥掉 `for (;;);` 前缀**（IG 的防 JSON 劫持前缀，带不带空格两种都见过）。
       *
       * 原来这里只认以 `{` 开头，带前缀的响应一律被当成 non-json 丢掉 —— 就算内容是对的也读不出来。
       */
      let text: string = raw;
      const semi: number = raw.indexOf(';');
      if (semi >= 0 && semi <= 10 && raw.startsWith('for')) {
        text = raw.substring(semi + 1);
      }
      const code: number = response.responseCode;
      const json: boolean = text.length > 0 && text.charAt(0) === '{';
      // 日志里只放**接口路径**（整条 URL 太长，而且查询串里有游标）。
      const apiAt: number = url.indexOf('/api/');
      const short: string = apiAt >= 0 ? url.substring(apiAt, apiAt + 56) : url.substring(0, 56);
      hilog.info(DOMAIN, TAG, 'rest %{public}s %{public}s code=%{public}d json=%{public}s len=%{public}d',
        method === http.RequestMethod.POST ? 'POST' : 'GET', short, code, `${json}`, text.length);
      if (code !== 200 || !json) {
        hilog.warn(DOMAIN, TAG, 'rest body: %{public}s',
          text.substring(0, 200).replace(/[\r\n]+/g, ' '));
        NativeDirect.detail = `http-${code}${json ? '' : '/non-json'}`;
        return '';
      }
      if (ApiThrottle.looksLimited(text)) {
        ApiThrottle.note(ApiThrottle.DIRECT);
        hilog.warn(DOMAIN, TAG, 'direct rate limited → back off %{public}min',
          ApiThrottle.remainingMinutes(ApiThrottle.DIRECT));
        NativeDirect.detail = 'rate-limited';
        return '';
      }
      NativeDirect.detail = '-';
      return text;
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'rest failed: %{public}s', message);
      NativeDirect.detail = `throw:${message}`.substring(0, 80);
      return '';
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 收件箱响应文本 → 一页会话（解析规则同网页脚本 directInboxScript）。 */
  private static inboxOf(text: string): DirectInboxPage | null {
    // parseWithBigIds：thread_id 是 19~20 位，普通 JSON.parse 会舍入成错 id（拿去请求会话就 404）。
    const root: Record<string, Object> = JsonRead.parseWithBigIds(text);
    const data: Record<string, Object> | null = JsonRead.recordOf(root, 'data');
    if (data === null) {
      const errors: Array<Object> = JsonRead.arrayOf(root, 'errors');
      const first: Record<string, Object> | null =
        JsonRead.asRecord(errors.length > 0 ? errors[0] : null);
      NativeDirect.detail = first === null ? 'no-data' : `gql:${JsonRead.strOf(first, 'message')}`;
      return null;
    }
    // 字段名不写死：data 下第一个带 threads_by_folder 的对象就是收件箱。
    const keys: Array<string> = Object.keys(data);
    let box: Record<string, Object> | null = null;
    for (let index: number = 0; index < keys.length; index++) {
      const candidate: Record<string, Object> | null = JsonRead.recordOf(data, keys[index]);
      if (candidate !== null && JsonRead.has(candidate, BOX_KEY)) {
        box = candidate;
        break;
      }
    }
    if (box === null) {
      NativeDirect.detail = `no-box keys=${keys.slice(0, 6).join(',')}`;
      return null;
    }
    const folder: Record<string, Object> | null = JsonRead.recordOf(box, BOX_KEY);
    if (folder === null) {
      NativeDirect.detail = 'no-folder';
      return null;
    }
    const edges: Array<Object> = JsonRead.arrayOf(folder, 'edges');
    const threads: Array<DirectThread> = [];
    for (let index: number = 0; index < edges.length; index++) {
      const edge: Record<string, Object> | null = JsonRead.asRecord(edges[index]);
      if (edge === null) {
        continue;
      }
      const node: Record<string, Object> | null = JsonRead.recordOf(edge, 'node');
      if (node === null) {
        continue;
      }
      const wrapped: Record<string, Object> | null = JsonRead.recordOf(node, 'as_ig_direct_thread');
      const th: Record<string, Object> = wrapped !== null ? wrapped : node;
      const id: string = JsonRead.strOf(th, 'thread_id');
      if (id.length === 0) {
        continue;
      }
      threads.push(NativeDirect.threadOf(th, id));
    }
    const pageInfo: Record<string, Object> | null = JsonRead.recordOf(folder, 'page_info');
    const cursor: string = pageInfo === null ? '' : JsonRead.strOf(pageInfo, 'end_cursor');
    const hasMore: boolean = pageInfo !== null && JsonRead.boolOf(pageInfo, 'has_next_page');
    return new DirectInboxPage(threads, cursor, hasMore);
  }

  /**
   * 从两份用户列表里挑一个**带头像**的用户对象（见 threadOf 的说明）。
   *
   * 顺序：先在 `first` 里找带头像的；找不到再去 `second` 里找带头像的；都找不到就退回 `first`
   * 的第一条（至少 id 在，标题/群聊判断仍然成立）。用户对象可能被包一层 `node`，这里一起脱掉。
   */
  private static userWithPicture(first: Array<Object>,
                                second: Array<Object>): Record<string, Object> | null {
    let fallback: Record<string, Object> | null = null;
    const lists: Array<Array<Object>> = [first, second];
    for (let l: number = 0; l < lists.length; l++) {
      const list: Array<Object> = lists[l];
      for (let index: number = 0; index < list.length; index++) {
        const raw: Record<string, Object> | null = JsonRead.asRecord(list[index]);
        if (raw === null) {
          continue;
        }
        const wrapped: Record<string, Object> | null = JsonRead.recordOf(raw, 'node');
        const user: Record<string, Object> = wrapped !== null ? wrapped : raw;
        if (fallback === null) {
          fallback = user;
        }
        if (NativeDirect.avatarOf(user).length > 0) {
          return user;
        }
      }
    }
    return fallback;
  }

  /** 一个用户节点的头像（几种形状依次试；都没有给空串）。 */
  private static avatarOf(user: Record<string, Object>): string {    // ① 直接的几个字段名（网页版不同时期用过不同的键）。
    const direct: Array<string> = ['profile_pic_url', 'profile_pic_url_hd', 'hd_profile_pic_url'];
    for (let index: number = 0; index < direct.length; index++) {
      const url: string = JsonRead.strOf(user, direct[index]);
      if (url.length > 0) {
        return url;
      }
    }
    // ② 套一层 {url} 的两个字段（高清头像）。
    const holders: Array<string> = ['hd_profile_pic_url_info', 'profile_pic_url_info'];
    for (let index: number = 0; index < holders.length; index++) {
      const host: Record<string, Object> | null = JsonRead.recordOf(user, holders[index]);
      if (host !== null) {
        const url: string = JsonRead.strOf(host, 'url');
        if (url.length > 0) {
          return url;
        }
      }
    }
    return '';
  }

  /** 群聊头像挂在 thread 自己身上的几种形状（都没有给空串）。 */
  private static threadImageOf(th: Record<string, Object>): string {
    /*
     * ① **直接的地址字段**：真机实测群图是 `thread_image_url`（不是 `thread_image` /
     * `group_image` 那两个猜的键名 —— 它们的键名只有 thread 节点的键表能说清，
     * 见 `group image miss` 那条诊断日志）。
     */
    const directKeys: Array<string> = ['thread_image_url', 'group_image_url', 'image_url'];
    for (let index: number = 0; index < directKeys.length; index++) {
      const url: string = JsonRead.strOf(th, directKeys[index]);
      if (url.length > 0) {
        return url;
      }
    }
    // ② 嵌套形状（`{image_versions2:{candidates:[{url}]}}` 或 `{url}`）：留着兜底。
    const holders: Array<string> = ['thread_image', 'group_image', 'image_versions2'];
    for (let index: number = 0; index < holders.length; index++) {
      const host: Record<string, Object> | null = JsonRead.recordOf(th, holders[index]);
      if (host === null) {
        continue;
      }
      const versions: Record<string, Object> | null =
        JsonRead.recordOf(host, 'image_versions2');
      const source: Record<string, Object> = versions !== null ? versions : host;
      const candidates: Array<Object> = JsonRead.arrayOf(source, 'candidates');
      for (let at: number = 0; at < candidates.length; at++) {
        const one: Record<string, Object> | null = JsonRead.asRecord(candidates[at]);
        if (one === null) {
          continue;
        }
        const url: string = JsonRead.strOf(one, 'url');
        if (url.length > 0) {
          return url;
        }
      }
      const direct: string = JsonRead.strOf(host, 'url');
      if (direct.length > 0) {
        return direct;
      }
    }
    return '';
  }

  /** 一个 thread 节点 → 收件箱里的一行。 */
  private static threadOf(th: Record<string, Object>, id: string): DirectThread {
    // 1:1 会话看对方（usersWithoutViewer）；群聊用 thread_title。
    let users: Array<Object> = JsonRead.arrayOf(th, 'usersWithoutViewer');
    if (users.length === 0) {
      users = JsonRead.arrayOf(th, 'users');
    }
    /*
     * **头像不在 `usersWithoutViewer` 里**（真机实测：那一条里的用户对象只有
     * `is_internal_user` 和 `id` 两个键，连用户名都没有 —— 用户名是从 `thread_title` 来的）。
     * 头像是在 `users` 那一份里的完整用户对象上。所以：两份都过一遍，取**第一个真能给出头像**的。
     */
    const other: Array<Object> = JsonRead.arrayOf(th, 'users');
    const raw: Record<string, Object> | null =
      NativeDirect.userWithPicture(users, other);
    // 有的形状把用户包一层 `node`（和 profile 那条查询一样），脱一层再读。
    const wrapped: Record<string, Object> | null =
      raw === null ? null : JsonRead.recordOf(raw, 'node');
    const user: Record<string, Object> | null = wrapped !== null ? wrapped : raw;
    let avatar: string = user === null ? '' : NativeDirect.avatarOf(user);
    if (avatar.length === 0 && user !== null) {
      /*
       * 群聊没有"对方用户"（`usersWithoutViewer` 是空的或只有自己），它的头像挂在
       * **thread 自己**身上（`thread_image` / `group_image` / `image_versions2` 都见过）。
       *
       * 取不到时把用户对象的**键名**打出来 —— 真实响应里图片字段叫什么只有它能说清
       * （`profile_pic_url` / `hd_profile_pic_url_info.url` / `profile_pic_url_info.url` 都试过了）。
       */
      const group: string = NativeDirect.threadImageOf(th);
      if (group.length > 0) {
        avatar = group;
      } else {
        hilog.info(DOMAIN, TAG, 'avatar miss id=%{public}s group=%{public}s user.keys=%{public}s',
          id, `${JsonRead.boolOf(th, 'is_group')}`, Object.keys(user).slice(0, 18).join(','));
      }
    }
    const username: string = user === null ? '' : JsonRead.strOf(user, 'username');
    // 需求："私信列表的名称显示应该是用户名字而不是用户 id" —— 列表/标题用 **full_name**，
    // 用户名（alice 这种）留给会话页标题栏的第二行。
    const fullName: string = user === null ? '' : JsonRead.strOf(user, 'full_name');
    const displayName: string = fullName.length > 0 ? fullName : username;
    const groupTitle: string = JsonRead.strOf(th, 'thread_title');
    /*
     * **账号名**：收件箱这条 GraphQL 里用户对象只有 id（连 username 都没有，见 threadOf 的
     * 诊断日志），而会话页标题栏第二行要的就是账号名 —— 它其实在 `thread_title` 上
     * （1:1 会话的 thread_title 就是对方的 username，真机日志里 `inbox first title=alice`
     * 就是这么来的）。所以这里两个都试，取到就算数。
     */
    const account: string = username.length > 0 ? username : groupTitle;
    const isGroup: boolean = JsonRead.boolOf(th, 'is_group');
    /*
     * **群聊必须用自己的名字和头像**（用户报的："列表里有两行同一个人 id 和头像，其中一个是群聊"）。
     *
     * 原因：群会话的 `usersWithoutViewer` / `users` 里是**成员**，按"第一个有头像的用户"取，
     * 就会把群显示成某个成员（名字、头像都一样），于是那一行和该成员的 1:1 会话看起来重复。
     * 所以群聊：标题优先 `thread_title`（空才退回成员用户名），头像优先 thread 自己的
     * `thread_image` / `group_image`（取不到才退回成员头像）。
     */
    let title: string = isGroup
      ? (groupTitle.length > 0 && groupTitle !== 'Empty' ? groupTitle : displayName)
      : (displayName.length > 0 ? displayName : groupTitle);
    if (title === 'Empty' && displayName.length > 0) {
      // IG 偶尔把标题给成字面的 "Empty"：那时退回名字（网页脚本里同样的兜底）。
      title = displayName;
    }
    if (isGroup) {
      /*
       * 群聊：头像只用**群自己的**图（取不到就留空，让界面画一个中性的群图标）。
       * **绝不退回成员头像** —— 列表里那两行"同一个人 + 同一个头像"就是这么来的
       * （群会话把某个成员的资料显示成了自己）。
       */
      avatar = NativeDirect.threadImageOf(th);
      if (avatar.length === 0) {
        /*
         * 诊断：群图到底挂在哪 —— 把 thread 节点的键名打出来（我试过 `thread_image` /
         * `group_image` / `image_versions2` 都没有；真实字段名只有这份键名能说清）。
         */
        hilog.info(DOMAIN, TAG, 'group image miss title=%{public}s th.keys=%{public}s',
          groupTitle, Object.keys(th).slice(0, 40).join(','));
      }
    }
    // 最近几条消息（edges[0] 是最新那条，和网页脚本一致）。
    const messages: Record<string, Object> | null = JsonRead.recordOf(th, 'slide_messages');
    const msgs: Array<Object> = messages === null ? [] : JsonRead.arrayOf(messages, 'edges');
    let text: string = '';
    let kind: string = '';
    if (msgs.length > 0) {
      const firstEdge: Record<string, Object> | null = JsonRead.asRecord(msgs[0]);
      const firstNode: Record<string, Object> | null =
        firstEdge === null ? null : JsonRead.recordOf(firstEdge, 'node');
      if (firstNode !== null) {
        text = JsonRead.strOf(firstNode, 'text');
        kind = JsonRead.strOf(firstNode, 'item_type');
      }
    }
    let ts: number = JsonRead.numOf(th, 'last_activity_timestamp_ms');
    if (ts <= 0) {
      // 有的形状只给秒（`last_activity_at`），补一个兜底。
      ts = JsonRead.numOf(th, 'last_activity_at') * 1000;
    }
    return new DirectThread(id, JsonRead.strOf(th, 'thread_key'), title, avatar,
      JsonRead.boolOf(th, 'is_group'), JsonRead.boolOf(th, 'marked_as_unread'),
      JsonRead.boolOf(th, 'is_muted'), JsonRead.boolOf(th, 'is_pin'), ts, text, kind, account);
  }
}
