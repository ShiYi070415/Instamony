/*
 * 移动 API 的**请求骨架**（对应 instagrapi 的 `PrivateRequestMixin`）。
 *
 * ## 它做了什么
 *   1. `baseHeaders()` 组装那套约 40 个 `X-IG-*` / `X-FB-*` 头（从设备身份派生）；
 *   2. `send()` 发一发原生 HTTP：表单体经 `signedBody()` 包成 `signed_body=SIGNATURE.<体>`，
 *      Cookie + `Authorization: Bearer IGT:2:` 走鉴权（见 MobileSession）；
 *   3. `absorb*` 从**响应头**捡回 claim / rur / mid 并落盘（这条路的自举，见 MobileSession 文件头）；
 *   4. `classify()` 把失败响应对到 IG 的错误语义上（instagrapi 那套异常映射表的等价物）。
 *
 * ## 与 instagrapi 的**故意差异**（都不是偷懒，是这个项目的约束）
 *   - **不抛异常**：项目调用方（`Native*` / 视图模型）习惯"失败回 null、自己换下一条路"
 *     （见 core/NativeFeed 的文件头）。抛异常会逼着每个调用点写 try，
 *     所以这里用 `MobileResult.ok/error` 表达失败，异常语义**落在 `error` 字段里**。
 *   - **cookie 从 Cookie 罐现读**：instagrapi 自己维护 `requests.Session` 的 cookie jar；
 *     我们的会话属于 ArkWeb，所以每发一次都读一遍（见 MobileSession.ensure）。
 *   - **不做 `time.sleep(request_timeout)`**：instagrapi 每次私有请求前固定睡 1 秒。
 *     本项目用的是**全局闸门**（`ApiThrottle.acquire/release`）：同一时刻只允许一发在路上、
 *     两发之间至少隔 900ms±400ms（抖动），而且**优先级可插队** —— 用户此刻点开的那一发
 *     会越过预取/自检排到队头。固定 1 秒 sleep 做不到这两件事：它既不防"我们代码自己排出来的
 *     连发"（预取 5 页 + 自检 9 发就是这么打出去的），又会把用户点开那一发一起拖慢。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramCookieJar, InstagramCookieSnapshot } from '../InstagramCookieJar';
import { ApiThrottle, BACKOFF_MS, FEEDBACK_BACKOFF_MS } from '../ApiThrottle';
import { MobileSession, MobileIdentity } from './MobileSession';
import { MobileChallenge } from './MobileChallenge';
import { signedBody } from './MobileSign';
import {
  API_DOMAIN,
  APP_ID,
  COHERENT_FINGERPRINT,
  CONNECT_TIMEOUT_MS,
  FB_HTTP_ENGINE,
  FixedHeaders,
  IG_CAPABILITIES,
  NAV_CHAIN,
  READ_TIMEOUT_MS
} from './MobileConfig';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileRequest';

/**
 * 失败的种类（`MobileResult.error` 的取值）。
 *
 * 这套名字**故意和 instagrapi 的异常类名对齐**（`ChallengeRequired` → `challenge-required` 等）：
 * 移植代码时要能一眼看出"这一支对应 instagrapi 的哪个 except"。
 */
export const MOBILE_LOGIN_REQUIRED: string = 'login_required';
export const MOBILE_CHALLENGE: string = 'challenge_required';
export const MOBILE_TWO_FACTOR: string = 'two_factor_required';
export const MOBILE_FEEDBACK: string = 'feedback_required';
export const MOBILE_RATE_LIMIT: string = 'rate_limit_error';
export const MOBILE_THROTTLED: string = 'throttled_429';
export const MOBILE_FORBIDDEN: string = 'forbidden_403';
export const MOBILE_NOT_FOUND: string = 'not_found_404';
export const MOBILE_BAD_REQUEST: string = 'bad_request_400';
export const MOBILE_SERVER_ERROR: string = 'server_5xx';
export const MOBILE_NON_JSON: string = 'non-json';
export const MOBILE_NO_SESSION: string = 'no-session';
export const MOBILE_NO_TEMPLATE: string = 'no-template';
export const MOBILE_THREW: string = 'threw';

/** 请求方法（instagrapi 只用到这两个）。 */
export enum MobileMethod {
  GET = 0,
  POST = 1
}

/**
 * 一发的"排队策略"：**家族**（限流退避按它记）+ **优先级**（闸门按它插队）。
 *
 * 为什么要显式传：`MobileRequest` 是通用骨架，它自己不知道"这一发是用户在点快拍"
 * 还是"后台自检"。默认给 `MOBILE` + `WARM`（不抢用户、也不排最后）。
 */
export class MobileOptions {
  readonly family: string;
  readonly priority: number;

  constructor(family: string = ApiThrottle.MOBILE, priority: number = 1) {
    this.family = family;
    this.priority = priority;
  }
}

/** 一发的诊断信息（沿用项目里 NativeFetchResult 的"不抛异常、用字段说话"风格）。 */
export class MobileResult {
  readonly ok: boolean;
  readonly error: string;
  readonly code: number;
  readonly ms: number;
  readonly bytes: number;
  /** 响应体全文（JSON 文本；`ok=false` 时可能是错误体或 HTML）。 */
  readonly body: string;
  /** 服务端下发的原因文案（`message` / `error_type` 等），便于日志一眼看结论。 */
  readonly detail: string;

  constructor(ok: boolean, error: string, code: number, ms: number, bytes: number,
              body: string, detail: string) {
    this.ok = ok;
    this.error = error;
    this.code = code;
    this.ms = ms;
    this.bytes = bytes;
    this.body = body;
    this.detail = detail;
  }

  /** 一行摘要（日志用）。 */
  summary(): string {
    return `ok=${this.ok ? 'y' : 'n'} err=${this.error} http=${this.code} ms=${this.ms} `
      + `bytes=${this.bytes}${this.detail.length > 0 ? ` detail=${this.detail}` : ''}`;
  }
}

export class MobileRequest {
  /** 上一条失败响应体样本（诊断用，同 NativeComments.detail 的角色）。 */
  private static lastDetail: string = '-';
  private static lastError: string = '-';
  private static lastCode: number = 0;
  /**
   * 本进程一共发了几发移动端请求（诊断/度量用）。
   *
   * 用来回答"降噪到底有没有效果"：同一套动作下这个数应该掉一个量级
   * （见 `FINGERPRINT_ANALYSIS.md` 第 5 节那张基线表）。
   */
  private static sends: number = 0;

  static detail(): string {
    return MobileRequest.lastDetail;
  }

  static error(): string {
    return MobileRequest.lastError;
  }

  static lastHttpCode(): number {
    return MobileRequest.lastCode;
  }

  /** 本进程发出的移动端请求数（诊断/降噪度量用，见 `sends` 字段）。 */
  static sendCount(): number {
    return MobileRequest.sends;
  }

  /**
   * 那套约 40 个请求头（instagrapi 的 `base_headers` property）。
   *
   * 里面几类东西值得说明：
   *   - `X-IG-Bandwidth-*` / `X-Pigeon-Rawclienttime`：**每次都变**（instagrapi 也是随机的）；
   *   - `IG-U-*` / `X-IG-Nav-Chain`：**固定串**（见 MobileConfig.FixedHeaders）；
   *   - `X-IG-Android-ID` / `X-IG-Device-ID` / `X-IG-Family-Device-ID`：三条来自设备身份，
   *     这三条是"同一设备"的主要判据，必须跨重启稳定（见 MobileSession 的持久化）。
   */
  static baseHeaders(identity: MobileIdentity): Record<string, string> {
    const locale: string = identity.locale.replace('-', '_');
    const out: Record<string, string> = {};
    out['X-IG-App-Locale'] = locale;
    out['X-IG-Device-Locale'] = locale;
    out['X-IG-Mapped-Locale'] = locale;
    out['X-Pigeon-Session-Id'] = `UFS-${identity.clientSessionId}-1`;
    out['X-Pigeon-Rawclienttime'] = (Date.now() / 1000).toFixed(3);
    out['X-IG-Bandwidth-Speed-KBPS'] = `${Math.round(MobileRequest.randInt(2500000, 3000000)) / 1000}`;
    out['X-IG-Bandwidth-TotalBytes-B'] = `${MobileRequest.randInt(5000000, 90000000)}`;
    out['X-IG-Bandwidth-TotalTime-MS'] = `${MobileRequest.randInt(2000, 9000)}`;
    // 国家：自洽模式下**拿不到就不发**（谎报 US 与真实 IP 矛盾，比缺省更可疑）。
    if (identity.country.length > 0) {
      out['X-IG-App-Startup-Country'] = identity.country.toUpperCase();
    }
    out['X-Bloks-Version-Id'] = identity.app.bloksVersioningId;
    out['X-IG-WWW-Claim'] = identity.wwwClaim.length > 0 ? identity.wwwClaim : '0';
    out['X-Bloks-Is-Layout-RTL'] = 'false';
    out['X-Bloks-Is-Panorama-Enabled'] = 'true';
    out['X-IG-Device-ID'] = identity.uuid;
    out['X-IG-Family-Device-ID'] = identity.phoneId;
    out['X-IG-Android-ID'] = identity.androidDeviceId;
    out['X-IG-Timezone-Offset'] = `${identity.timezoneOffset}`;
    out['X-IG-Connection-Type'] = 'WIFI';
    out['X-IG-Capabilities'] = IG_CAPABILITIES;
    out['X-IG-App-ID'] = APP_ID;
    out['Priority'] = 'u=3';
    out['User-Agent'] = identity.userAgent();
    const languages: Array<string> = ['en-US'];
    const lang: string = locale.replace('_', '-');
    if (lang.length > 0 && languages.indexOf(lang) < 0) {
      languages.unshift(lang);
    }
    out['Accept-Language'] = languages.join(', ');
    if (identity.mid.length > 0) {
      out['X-MID'] = identity.mid;
    }
    /*
     * **`Accept-Encoding` / `Host` / `Connection` 三条不发**（instagrapi 会发，这里故意去掉）。
     *
     * 理由（这是移植里少数"故意不一致"的地方，代价最大的是第一条）：
     *   · `Accept-Encoding: gzip, deflate` —— 鸿蒙 `http` 模块**自己**会协商编码并解压响应。
     *     我们手写一个再声明，等于把它那层解压判断绕开：真机上可能出现"响应回来了、但不是 JSON"
     *     （拿到的还是压缩字节），而自检会把这种失败报成 `non-json`，看起来像"头不全"——
     *     现场会被误导到完全错误的方向。本项目既有路径同样是**丢掉**这个头的
     *     （见 `core/NativeFeed.HEADER_DROP` 里就有 `accept-encoding`）。
     *   · `Host` / `Connection` 是 HTTP 栈自己的事（`HEADER_DROP` 里也丢它们）；
     *     手动覆盖在部分实现上会被忽略，个别实现会直接报错。
     * 服务端看到的效果不变：模块自己补上的那几条与真实的 IG 客户端一致。
     */
    out['X-FB-HTTP-Engine'] = FB_HTTP_ENGINE;    out['X-Tigon-Is-Retry'] = 'False';
    out['X-Zero-Balance'] = 'INIT';
    // `X-Zero-Eh` 在 instagrapi 里是**空串**头。这里干脆不发：鸿蒙 http 模块对空 header value
    // 的行为没有保证（个别实现直接报错），而 IG 侧它只是个占位、去掉不影响任何判据。
    out['X-Zero-State'] = 'unknown';
    out['Zero-HTTP-Network-Interface'] = 'wifi';
    // `Connection` 同 `Host` / `Accept-Encoding`：交给 HTTP 栈（见上面那段说明）。
    out['X-FB-Client-IP'] = 'True';
    out['X-FB-Server-Cluster'] = 'True';
    out['IG-INTENDED-USER-ID'] = identity.userId.length > 0 ? identity.userId : '0';
    /*
     * 身份自洽（见 MobileConfig.COHERENT_FINGERPRINT）：
     *   · 恒定 `X-IG-Nav-Chain` 去掉 —— 真实客户端的导航链随页面变化，不会每条请求都停在
     *     "self_profile → following"（连 explore / clips / direct 都是这一串，一眼假）。
     *   · `IG-U-SHBID` / `IG-U-SHBTS` / `IG-U-RUR` / 区域提示**只发服务端真下发的**
     *     （`identity.igURur` 是 `absorbResponseHeaders` 从响应头捡到的）。
     *     以前是拿 userId + 假 HMAC + now+1y 现造：`SHBTS` 那种签名字段校验不过，
     *     比"不发"更像自动化。（instagrapi 也硬编码这几个，所以它同样容易被判。）
     */
    if (!COHERENT_FINGERPRINT) {
      out['X-IG-Nav-Chain'] = NAV_CHAIN;
    }
    if (identity.userId.length > 0) {
      out['IG-U-DS-USER-ID'] = identity.userId;
      if (identity.igURur.length > 0) {
        out['IG-U-RUR'] = identity.igURur;
      }
      if (!COHERENT_FINGERPRINT) {
        out['IG-U-IG-DIRECT-REGION-HINT'] = FixedHeaders.directRegionHint(identity.userId);
        out['IG-U-SHBID'] = FixedHeaders.shbid(identity.userId);
        out['IG-U-SHBTS'] = FixedHeaders.shbts(identity.userId);
        out['IG-U-RUR'] = identity.igURur.length > 0
          ? identity.igURur : FixedHeaders.rur(identity.userId);
      }
    }
    return out;
  }

  /**
   * 发一发（`data` 非空 = POST，空 = GET，与 instagrapi 的判断一致）。
   *
   * @param endpoint 形如 `feed/reels_media/` 或 `/media/1/info/`；不以 `/` 开头时补 `/v1/`
   *                 （instagrapi 的 `_send_private_request` 里那段路径拼接）。
   * @param data     POST 的表单体（会被 `signedBody()` 包一层）
   * @param params   GET 的查询参数（直接拼在 URL 上）
   * @param withSignature 是否包 `signed_body=`（instagrapi 的 `with_signature`，默认 true）
   * @param extraHeaders 调用方要额外带的头（例如私信那条的 `X-FB-Friendly-Name`）
   * @param options 排队策略（家族 + 优先级，见 MobileOptions）；null = MOBILE + WARM
   */
  static async send(endpoint: string, data: string = '', params: string = '',
                    withSignature: boolean = true,
                    extraHeaders: Record<string, string> | null = null,
                    options: MobileOptions | null = null): Promise<MobileResult> {
    const opts: MobileOptions = options === null ? new MobileOptions() : options;
    const started: number = Date.now();
    MobileRequest.sends = MobileRequest.sends + 1;
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null || !identity.isComplete()) {
      MobileRequest.lastError = MOBILE_NO_SESSION;
      MobileRequest.lastDetail = 'no-usable-session';
      return new MobileResult(false, MOBILE_NO_SESSION, 0, Date.now() - started, 0, '',
        MobileRequest.lastDetail);
    }
    let jar: InstagramCookieSnapshot;
    try {
      jar = await InstagramCookieJar.inspect();
    } catch (error) {
      MobileRequest.lastError = MOBILE_NO_SESSION;
      return new MobileResult(false, MOBILE_NO_SESSION, 0, Date.now() - started, 0, '',
        'cookie-read-failed');
    }
    const url: string = MobileRequest.absoluteUrl(endpoint, params);
    const headers: Record<string, string> = MobileRequest.baseHeaders(identity);
    headers['Cookie'] = MobileRequest.cookieHeader(jar.cookie);
    if (identity.authorization.length > 0) {
      headers['Authorization'] = identity.authorization;
    }
    if (extraHeaders !== null) {
      const extraKeys: Array<string> = Object.keys(extraHeaders);
      for (let index: number = 0; index < extraKeys.length; index++) {
        // 空值头一律不并进请求（同上面 `X-Zero-Eh` 那条说明）。
        if (`${extraHeaders[extraKeys[index]]}`.length > 0) {
          headers[extraKeys[index]] = extraHeaders[extraKeys[index]];
        }
      }
    }
    const isPost: boolean = data.length > 0;
    if (isPost) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
    }
    const payload: string = isPost && withSignature ? signedBody(data) : data;
    hilog.info(DOMAIN, TAG, 'send %{public}s %{public}s m=%{public}s body=%{public}d auth=%{public}s',
      endpoint, MobileRequest.shortUrl(url), isPost ? 'POST' : 'GET', payload.length,
      identity.authorization.length > 0 ? 'y' : 'n');
    const request: http.HttpRequest = http.createHttp();
    /*
     * **闸门**（主动限速，见 ApiThrottle.acquire 的说明）：排队 → 拿到名额才发。
     * 拿到之后**必须** release，所以整段用 try/finally 包住 —— 任何一支抛异常都要放闸，
     * 否则后面的请求全被卡死（`ApiThrottle` 那边还有 30 秒防呆兜底）。
     */
    const queued: number = Date.now();
    await ApiThrottle.acquire(opts.priority);
    if (Date.now() - queued > 50) {
      hilog.info(DOMAIN, TAG, 'paced %{public}s waited=%{public}dms %{public}s',
        endpoint, Date.now() - queued, ApiThrottle.paceDescribe());
    }
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: isPost ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        extraData: isPost ? payload : undefined,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      // 服务端下发的会话材料（claim / mid / rur / authorization）先捡起来，再判成败 ——
      // 420 / 挑战响应里也可能带着新的 claim，捡到就赚一发。
      try {
        MobileSession.getInstance().absorbResponseHeaders(response.header as Record<string, string>);
      } catch (error) {
      }
      const code: number = response.responseCode;
      const outcome: MobileResult = MobileRequest.classify(code, text, Date.now() - started);
      /*
       * **撞上限流就记冷却**（这条以前只有网页那几条路有，移动端这条路是新加的）。
       *
       * 为什么必须在这里做：移动端的连发（预取 5 页 + 自检 9 发）恰恰是最容易把额度打满的，
       * 而"被限流了还接着打"正是本项目审计里 E 类那个"越打越久"的老毛病。
       * 记到**调用方给的家族**上（快拍记 STORIES、私信记 DIRECT），退避才对得上语义。
       */
      if (outcome.error === MOBILE_RATE_LIMIT || outcome.error === MOBILE_THROTTLED
        || outcome.error === MOBILE_FEEDBACK) {
        /*
         * `feedback_required` 是 IG 最明确的一种"你太吵了"信号（"We limit how often you can do
         * certain things…"），比单端点 429 更重：它通常意味着**整类行为**被盯上。
         * 所以给它更长的冷却（45 分钟，见 ApiThrottle.FEEDBACK_BACKOFF_MS），
         * 而且各模块的可选流量（预取 / 轮询）都会读 `blocked(family)` 从而一起停手。
         */
        const ms: number = outcome.error === MOBILE_FEEDBACK
          ? FEEDBACK_BACKOFF_MS : BACKOFF_MS;
        ApiThrottle.note(opts.family, ms);
        /*
         * `feedback_required` 再上一层：**整账号熔断**（见 ApiThrottle.suspendAll）。
         *
         * 只停"出事那个家族"不够 —— IG 的判定是账号级的，限流期间继续打别的端点
         * 只会把窗口拉长。熔断后 `blocked()` 对所有家族都返回 true，
         * 各模块的可选流量（预取/轮询）会一起停手，用户手动动作也会被挡并按提示恢复。
         */
        if (outcome.error === MOBILE_FEEDBACK) {
          ApiThrottle.suspendAll(45, 'feedback_required');
        }
        hilog.warn(DOMAIN, TAG, 'throttled %{public}s family=%{public}s → backoff %{public}dmin',
          endpoint, opts.family, Math.round(ms / 60000));
      }
      hilog.info(DOMAIN, TAG, 'recv %{public}s -> %{public}s', endpoint, outcome.summary());
      return outcome;
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      MobileRequest.lastError = MOBILE_THREW;
      MobileRequest.lastDetail = message.substring(0, 80);
      hilog.warn(DOMAIN, TAG, 'send failed %{public}s: %{public}s', endpoint, message);
      return new MobileResult(false, MOBILE_THREW, 0, Date.now() - started, 0, '',
        MobileRequest.lastDetail);
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
      ApiThrottle.release();
    }
  }

  /**
   * 失败分类：把 HTTP 码 + 响应体对到 IG 的错误语义上
   * （instagrapi `_send_private_request` 里那一长串 `except` 的等价物）。
   *
   * 只挑**对调用方有意义**的那几支：调用方真正要区分的是
   * "要不要提示用户去完成安全验证"（challenge）、"是不是被限流了"（rate_limit / 429）、
   * "是不是会话没了"（login_required）——其余一律落到 `http-<码>`。
   */
  private static classify(code: number, text: string, ms: number): MobileResult {
    MobileRequest.lastCode = code;
    const parsed: Record<string, Object> | null = MobileRequest.parseJson(text);
    const message: string = MobileRequest.strField(parsed, 'message');
    const errorType: string = MobileRequest.strField(parsed, 'error_type');
    const feedback: string = MobileRequest.strField(parsed, 'feedback_message');
    const detail: string = message.length > 0 ? message
      : (errorType.length > 0 ? errorType : text.substring(0, 120));
    if (parsed === null) {
      MobileRequest.lastError = MOBILE_NON_JSON;
      MobileRequest.lastDetail = `http-${code} ${text.substring(0, 60)}`;
      return new MobileResult(false, MOBILE_NON_JSON, code, ms, text.length, text,
        MobileRequest.lastDetail);
    }
    // `status:"fail"` 也是失败（instagrapi 在 `_send_private_request` 末尾专门判了它）。
    const status: string = MobileRequest.strField(parsed, 'status');
    const okCode: boolean = code >= 200 && code < 300;
    if (okCode && status !== 'fail') {
      MobileRequest.lastError = '-';
      MobileRequest.lastDetail = '-';
      return new MobileResult(true, '', code, ms, text.length, text, '');
    }
    let error: string = `http-${code}`;
    if (message === MOBILE_LOGIN_REQUIRED || code === 403) {
      error = message === MOBILE_LOGIN_REQUIRED ? MOBILE_LOGIN_REQUIRED : MOBILE_FORBIDDEN;
    }
    if (message === MOBILE_CHALLENGE || errorType === MOBILE_CHALLENGE) {
      /*
       * **账号安全验证**：把挑战地址记进台账（见 core/mobileapi/MobileChallenge），
       * 界面据此提示"去网页里验证"。这一支**重试没有意义** —— 必须真人/设备验证通过。
       */
      error = MOBILE_CHALLENGE;
      MobileChallenge.note(text);
    } else if (message === MOBILE_FEEDBACK) {
      error = MOBILE_FEEDBACK;
    } else if (errorType === MOBILE_RATE_LIMIT || MobileRequest.looksLimited(text)) {
      error = MOBILE_RATE_LIMIT;
    } else if (errorType === 'two_factor_required') {
      error = MOBILE_TWO_FACTOR;
    } else if (errorType === 'sentry_block') {
      error = 'sentry_block';
    } else if (code === 429) {
      error = MOBILE_THROTTLED;
    } else if (code === 404) {
      // 掩码挑战：IG 会用裸体 "Not Found" 回某些私有接口（instagrapi 明确写了这一支）。
      const bare: boolean = text.trim() === 'Not Found';
      error = bare ? MOBILE_CHALLENGE : MOBILE_NOT_FOUND;
    } else if (code === 400) {
      error = MOBILE_BAD_REQUEST;
    } else if (code >= 500) {
      error = MOBILE_SERVER_ERROR;
    }
    MobileRequest.lastError = error;
    MobileRequest.lastDetail = feedback.length > 0 ? `${message} ${feedback}` : detail;
    return new MobileResult(false, error, code, ms, text.length, text, MobileRequest.lastDetail);
  }

  /** 响应体里有没有"被限流"的判据（与 core/ApiThrottle.looksLimited 同一套判据）。 */
  static looksLimited(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    return text.toLowerCase().indexOf('rate limit') >= 0 || text.indexOf('1675004') >= 0;
  }

  /**
   * 端点 → 绝对地址（instagrapi 的 `_send_private_request` 路径拼接）。
   *
   * 规则照抄：不以 `/` 开头就补 `/v1/`；`/challenge/` 特殊改成 `/v1/challenge/`；
   * 前缀固定 `https://<API_DOMAIN>/api`。
   */
  static absoluteUrl(endpoint: string, params: string = ''): string {
    let path: string = endpoint.trim();
    if (!path.startsWith('/')) {
      path = `/v1/${path}`;
    }
    if (path === '/challenge/') {
      path = '/v1/challenge/';
    }
    const query: string = params.length > 0 ? `?${params}` : '';
    return `https://${API_DOMAIN}/api${path}${query}`;
  }

  /**
   * Cookie 头：把 `name=value; name=value` 那种整串里的**属性**去掉。
   *
   * `WebCookieManager.fetchCookie(url)` 回的是含 `Path` / `Domain` / `Secure` / `HttpOnly`
   * 的完整串？不一定 —— 但真有的话，把它们原样放进请求头就是语法错误
   * （`Cookie: sessionid=xxx; Path=/; Domain=.instagram.com` 这种）。
   * 所以这里只保留 `name=value` 形状的段。
   */
  static cookieHeader(raw: string): string {
    const parts: Array<string> = raw.split(';');
    const keep: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      if (one.length === 0 || one.indexOf('=') <= 0) {
        continue;
      }
      const name: string = one.substring(0, one.indexOf('=')).trim().toLowerCase();
      if (name === 'path' || name === 'domain' || name === 'expires'
        || name === 'max-age' || name === 'secure' || name === 'httponly'
        || name === 'samesite') {
        continue;
      }
      /*
       * **网页专属 cookie 不带给 App 端点**（身份自洽，见 MobileConfig.COHERENT_FINGERPRINT）。
       *
       * 这几条是浏览器侧的东西：`dpr`（设备像素比）、`wd`（窗口尺寸）、`ig_nrcb`、
       * `ps_l`/`ps_n`（页面状态）。官方安卓 App 的 cookie 罐里没有它们 ——
       * 带着它们打 `i.instagram.com` 等于自报"我是从浏览器导出的会话"。
       * `ig_did` / `mid` / `rur` / `sessionid` / `csrftoken` / `ds_user_id` **保留**：
       * App 侧同样有这几条（缺了反而过不了鉴权）。
       */
      if (COHERENT_FINGERPRINT
        && (name === 'dpr' || name === 'wd' || name === 'ig_nrcb'
          || name === 'ps_l' || name === 'ps_n')) {
        continue;
      }
      keep.push(one);
    }
    return keep.join('; ');
  }

  /** URL 摘要（日志里只留主机 + 路径，查询串太长）。 */
  private static shortUrl(url: string): string {
    const at: number = url.indexOf('?');
    return at < 0 ? url : `${url.substring(0, at)}?…`;
  }

  /**
   * 表单体里的默认字段（instagrapi 的 `with_default_data`）。
   *
   * 注意 `_uuid` 与 `device_id` 是**两个不同的设备标识**（前者是 app 级 uuid，
   * 后者是 android id），instagrapi 两个都带 —— 少一个它自己那份请求也缺。
   *
   * @param uuidOverride instagrapi 有两条路会覆盖 `_uuid`（会话那条传 client_session_id，
   *                     登录那条传设备 uuid）；本项目的调用方按需传，默认用设备 uuid。
   */
  static withDefaultData(identity: MobileIdentity, uuidOverride: string = ''): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['_uuid'] = uuidOverride.length > 0 ? uuidOverride : identity.uuid;
    out['device_id'] = identity.androidDeviceId;
    return out;
  }

  /** 动作类表单的额外字段（instagrapi 的 `with_action_data`：`radio_type`）。 */
  static withActionData(identity: MobileIdentity): Record<string, Object> {
    const out: Record<string, Object> = MobileRequest.withDefaultData(identity);
    out['radio_type'] = 'wifi-none';
    return out;
  }

  /**
   * + `_uid` + `_csrftoken` + `phone_id` + `guid`（instagrapi 的 `with_extra_data`）。
   *
   * 这三个是"已验证会话"的标志位：私信 / 快拍这类**读**接口通常也要求它们在场。
   */
  static withExtraData(identity: MobileIdentity): Record<string, Object> {
    const out: Record<string, Object> = MobileRequest.withDefaultData(identity);
    out['phone_id'] = identity.phoneId;
    out['_uid'] = identity.userId;
    out['guid'] = identity.uuid;
    out['_csrftoken'] = identity.csrf;
    return out;
  }

  /** 把字段表序列化成表单体（值一律先 `JSON.stringify`，与 instagrapi 的 `dumps` 一致）。 */
  static formOf(data: Record<string, Object>): string {
    const keys: Array<string> = Object.keys(data);
    const parts: Array<string> = [];
    for (let index: number = 0; index < keys.length; index++) {
      const value: Object = data[keys[index]];
      parts.push(`${keys[index]}=${MobileRequest.encode(value)}`);
    }
    return parts.join('&');
  }

  /** python `json.dumps` 的紧凑形式（无空格）+ URL 编码（instagrapi 的 `dumps` + requests 编码）。 */
  private static encode(value: Object): string {
    if (typeof value === 'string') {
      return encodeURIComponent(value as string);
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    return encodeURIComponent(JSON.stringify(value));
  }

  private static parseJson(text: string): Record<string, Object> | null {
    try {
      const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      return parsed;
    } catch (error) {
      return null;
    }
  }

  /** 取一个字符串字段（缺失 / 非字符串一律回空串）。 */
  private static strField(parsed: Record<string, Object> | null, name: string): string {
    if (parsed === null) {
      return '';
    }
    const value: Object | undefined = parsed[name];
    if (value === undefined || value === null) {
      return '';
    }
    return typeof value === 'string' ? value as string : `${value}`;
  }

  /**
   * 小工具：闭区间随机整数。
   *
   * 与 MobileSign.randomInt 重复？不 —— 那一份走 CryptoArchitectureKit 取随机数，
   * 用在**有安全含义**的地方（uuid / token）；这里只给带宽头上的"看起来像真机"用，
   * 不需要 CSPRNG，而且每发请求都要算好几次，用 `Math.random` 更省。
   */
  private static randInt(min: number, max: number): number {
    return min + Math.floor(Math.random() * (max - min + 1));
  }
}
