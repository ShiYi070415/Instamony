/*
 * **转发（repost）的网页那条路** —— 原生 HTTP 直发，不显示、也不依赖隐藏 WebView。
 *
 * ## 为什么需要它
 * IG 的转发在移动端私有接口里是"挂在媒体上的一条 note"（`media/create_note/v2/`），
 * 但真机上这条端点对这个账号一律回 `400 {"message":"很抱歉，出错了，请重试。"}`
 * （普通 `notes/create_note` 也一样，表单/JSON、签名/不签名四种组合都试过），
 * 而 IG 自己给的媒体详情里明明写着 `can_viewer_reshare: true`、
 * `enable_media_notes_production: true` —— 说明能力是有的，只是不走那条 REST。
 *
 * 网页端用的是 GraphQL 变更：
 *   · 转发     `usePolarisCreateMediaRepostMutation`  doc_id 38542997498680691
 *   · 取消转发 `usePolarisDeleteMediaRepostMutation`  doc_id 26656683127335602
 * （两个 doc_id 与 friendly name 都是本项目早期从真机网页里抓下来的，见历史上的
 *   core/EngageSkeleton —— 那个骨架被删掉了，但"网页令牌 + GraphQL"这套做法本身没问题。）
 *
 * ## 关键前提：两个网页令牌
 * GraphQL 变更必须带 `lsd` 与 `fb_dtsg`，它们就在 `https://www.instagram.com/` 的 HTML 里：
 *   `"LSD",[],{"token":"…"}` 与 `"DTSGInitialData",[],{"token":"…"}`
 * 真机实证：用 Cookie 罐直接 GET 首页（597KB）就能读到这两串，因此**不需要挂载网页组件**。
 * 令牌按 `TOKEN_TTL_MS` 缓存，失败时作废重取一次。
 *
 * ## 取消转发要 note_id
 * 删的那一发只认 note_id。转发成功时从响应里取；取不到就再从 `media/{pk}/info/` 的
 * `media_notes.items` 里找一条属于自己、且 `note_style = 13`（转发）的。
 * 都找不到就如实失败 —— 绝不猜一个 id 去删（删错是别人的东西）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { ApiThrottle } from './ApiThrottle';
import { MobileRequest } from './mobileapi/MobileRequest';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';

const DOMAIN: number = 0xFF00;
const TAG: string = 'WebRepost';

/** 网页端 app id（与 core/NativeFeed 里那个一致）。 */
const WEB_APP_ID: string = '1217981644879628';
const ASBD_ID: string = '359341';
const HOME_URL: string = 'https://www.instagram.com/';
const GRAPHQL_URL: string = 'https://www.instagram.com/graphql/query';
/**
 * 转发（doc_id 与 friendly name 来自**用户刚在网页端抓到的真实请求**，2026-10-22）：
 *   doc_id 27933176649688558 / usePolarisCreateMediaRepostMutation
 *   variables {"input":{"actor_id":"…","client_mutation_id":"11","audience":7,
 *              "media_id":"4013502126080504545","note_style":13,"text":""}}
 *
 * 两个关键点（以前都搞错，所以服务端一直回 `data:null`）：
 *   ① doc_id 会换：旧骨架里那个 38542997498680691 现在对应的是另一个操作
 *      （应答根字段是 `xdt_create_media_note_v2`），拿它发转发等于什么都没做；
 *   ② `media_id` 是**纯 pk**（`4013502126080504545`），不是信息流里那种
 *      `<媒体pk>_<作者pk>` 组合串 —— 组合串会被拒。
 */
const REPOST_DOC: string = '27933176649688558';
const REPOST_NAME: string = 'usePolarisCreateMediaRepostMutation';
/** 取消转发：doc_id 待重新抓（见 sendUnrepost 的说明）。 */
const UNREPOST_DOC: string = '26656683127335602';
const UNREPOST_NAME: string = 'usePolarisDeleteMediaRepostMutation';
/** 网页令牌能用多久（毫秒）：太短会每次都拉一次首页，太长会在会话轮换后失效。 */
const TOKEN_TTL_MS: number = 10 * 60 * 1000;
/** 桌面浏览器 UA：网页端变更要这个身份（移动端 UA 会被当成不认识的客户端）。 */
const WEB_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/**
 * 网页端那套"站点参数"（网页客户端每次 POST 都会带）。
 *
 * 为什么要带全：IG 的 GraphQL 变更对这套很敏感，少了它**不报错**，只是把结果解析成 null
 * （`{"data":{"xdt_create_media_note_v2":null},"status":"ok"}`）—— 真机上就是被这个坑住的。
 * 真机实证：这些值都能从首页 HTML 的 SiteData 里读到（2026-10-22）：
 *   `"client_revision":1051294174` / `"haste_session":"20748.HYP:…"` /
 *   `"hsi":"7699460273512893842"` / `"__spin_b":"trunk"` / `"comet_env":7`
 */
class WebTokens {
  readonly lsd: string;
  readonly dtsg: string;
  readonly jazoest: string;
  /** `__hs`（haste_session）。 */
  readonly hs: string;
  /** `__hsi`。 */
  readonly hsi: string;
  /** `__rev` 与 `__spin_r`（客户端的 rollout hash）。 */
  readonly rev: string;
  /** `__spin_b`（分支名，通常是 `trunk`）。 */
  readonly spinB: string;
  /** `__comet_req`（comet_env）。 */
  readonly cometEnv: string;
  readonly atMs: number;

  constructor(lsd: string, dtsg: string, jazoest: string, hs: string, hsi: string, rev: string,
              spinB: string, cometEnv: string, atMs: number) {
    this.lsd = lsd;
    this.dtsg = dtsg;
    this.jazoest = jazoest;
    this.hs = hs;
    this.hsi = hsi;
    this.rev = rev;
    this.spinB = spinB;
    this.cometEnv = cometEnv;
    this.atMs = atMs;
  }
}

/**
 * `client_mutation_id`：**小整数**，网页端自己也是"每次 +1"（抓包里是 11）。
 *
 * 为什么不用时间戳：真机抓到的真实请求就是 `"11"`，跟着它的形状走最稳；
 * 从 11 起、每次 +1，同一进程里不会撞（不同进程撞了也无所谓，服务端不靠它去重）。
 */
let mutationSeq: number = 10;

export class WebRepost {
  private static tokens: WebTokens | null = null;
  private static detail: string = '-';
  /** 转过的那几条 → note id（取消转发要用）。 */
  private static noteIds: Map<string, string> = new Map<string, string>();

  /** 最近一次失败原因（日志/界面提示用）。 */
  static lastDetail(): string {
    return WebRepost.detail;
  }

  /**
   * 转发 / 取消转发。
   *
   * 变量形状**照用户刚抓到的真实请求**（见文件头 REPOST_DOC 那段）：
   *   `{"input":{actor_id, client_mutation_id, audience:7, media_id:<纯pk>, note_style:13, text:""}}`
   * 所以**不再需要** media info 里的 tracking token / carousel 子媒体 —— 少一发请求。
   *
   * @param pk 纯数字媒体 pk（`media_id` 要的就是它，不能带 `_作者` 后缀）
   */
  static async setReposted(pk: string, repost: boolean): Promise<boolean> {
    const actorId: string = await WebRepost.myUserId();
    if (actorId.length === 0) {
      WebRepost.detail = 'no-user-id';
      return false;
    }
    if (repost) {
      return await WebRepost.sendRepost(actorId, pk);
    }
    let noteId: string = WebRepost.noteIds.get(pk) ?? '';
    if (noteId.length === 0) {
      noteId = await WebRepost.findNoteId(pk, actorId);
    }
    if (noteId.length === 0) {
      WebRepost.detail = 'no-note-id';
      hilog.info(DOMAIN, TAG, 'unrepost skipped pk=%{public}s: no note id', pk);
      return false;
    }
    const ok: boolean = await WebRepost.sendUnrepost(actorId, noteId);
    if (ok) {
      WebRepost.noteIds.delete(pk);
    }
    return ok;
  }

  private static async sendRepost(actorId: string, pk: string): Promise<boolean> {
    const input: Record<string, Object> = {};
    input['actor_id'] = actorId;
    input['client_mutation_id'] = WebRepost.nextMutationId();
    // 7 / 13 都是抓包里的原值：audience=7，note_style=13 表示"转发那条 note"。
    input['audience'] = 7;
    input['media_id'] = pk;
    input['note_style'] = 13;
    input['text'] = '';
    const ok: boolean = await WebRepost.sendMutation(actorId, REPOST_NAME, REPOST_DOC, input,
      'repost');
    if (ok) {
      // 顺手问一次 media info 把 note id 记下来（取消转发要它）；失败不影响这次转发。
      const noteId: string = await WebRepost.findNoteId(pk, actorId);
      if (noteId.length > 0) {
        WebRepost.noteIds.set(pk, noteId);
      }
    }
    return ok;
  }

  private static async sendUnrepost(actorId: string, noteId: string): Promise<boolean> {
    const input: Record<string, Object> = {};
    input['actor_id'] = actorId;
    input['client_mutation_id'] = WebRepost.nextMutationId();
    input['note_id'] = noteId;
    return await WebRepost.sendMutation(actorId, UNREPOST_NAME, UNREPOST_DOC, input, 'unrepost');
  }

  /**
   * 发一条 GraphQL 变更（带令牌、失败重取一次）。
   *
   * 成功判据：HTTP 200、能解析成 JSON、**没有 `errors`**（网页端失败也常常是 200 + errors）。
   */
  private static async sendMutation(actorId: string, name: string, docId: string,
                                     input: Record<string, Object>,
                                     label: string): Promise<boolean> {
    const variables: Record<string, Object> = {};
    variables['input'] = input;
    const variablesJson: string = JSON.stringify(variables);
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const tokens: WebTokens | null = await WebRepost.tokensNow(attempt > 0);
      if (tokens === null) {
        WebRepost.detail = 'no-web-tokens';
        return false;
      }
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const body: string = WebRepost.formBody(actorId, name, docId, variablesJson, tokens);
      /*
       * 写操作要**人速**（见 ApiThrottle.writeSlot）并且占用全局闸门：
       * 这一发虽然打在 www 上，但仍然是"这个账号在动"的信号，不该和别的请求挤在一起。
       */
      await ApiThrottle.writeSlot();
      await ApiThrottle.acquire(ApiThrottle.interactive());
      let answered: boolean = false;
      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(GRAPHQL_URL, {
          method: http.RequestMethod.POST,
          header: WebRepost.headers(jar, tokens),
          extraData: body,
          connectTimeout: 15000,
          readTimeout: 25000,
          expectDataType: http.HttpDataType.STRING
        });
        const text: string = typeof response.result === 'string'
          ? response.result as string : '';
        hpLog(label, name, response.responseCode, text);
        /*
         * 判据不能只看 `status:"ok"`：真机实证过"200 + status ok + data 里那个字段是 null"
         * 这种**什么都没做**的应答（见 setReposted 的说明）。所以要求
         * `data.<root>` 不是 null，并且没有 `errors`。
         */
        answered = WebRepost.looksDone(response.responseCode, text);
        if (answered) {
          WebRepost.detail = '-';
        } else {
          WebRepost.detail = `graphql-rejected:${WebRepost.reasonOf(text)}`;
        }
      } catch (error) {
        WebRepost.detail = `graphql-threw:${(error as Error).message}`;
        hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}s', label,
          (error as Error).message);
      } finally {
        try {
          request.destroy();
        } catch (error) {
        }
        ApiThrottle.release();
      }
      if (answered) {
        return true;
      }
      // 第一次失败：把令牌作废，重取一次再试（会话轮换后旧的 lsd/dtsg 会失效）。
      if (attempt === 0) {
        WebRepost.tokens = null;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------- 判据

  /**
   * 这一发到底做成了没有。
   *
   * 三种"看起来成功其实没做"都要排掉：
   *   · `errors` 非空（网页端常见）；
   *   · `status:"fail"`；
   *   · `data` 里那个根字段是 **null**（IG 对"变量不对"的应答就是这样）。
   */
  private static looksDone(code: number, text: string): boolean {
    if (code !== 200 || text.length === 0) {
      return false;
    }
    if (text.indexOf('"errors"') >= 0 || text.indexOf('"status":"fail"') >= 0) {
      return false;
    }
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const data: Object | undefined = root['data'];
      if (data === undefined || data === null) {
        return false;
      }
      const box: Record<string, Object> = data as Record<string, Object>;
      const keys: Array<string> = Object.keys(box);
      for (let index: number = 0; index < keys.length; index++) {
        const value: Object = box[keys[index]];
        if (value === null || value === undefined) {
          continue;
        }
        // 根字段有值就算做成了（data 里就一个根字段，名字会随 IG 改，这里不写死）。
        return true;
      }
      return false;
    } catch (error) {
      return false;
    }
  }

  /** 失败时给一句能看的理由（`errors[0].message`，没有就回状态码/前 40 字）。 */
  private static reasonOf(text: string): string {
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const errors: Object[] | undefined = root['errors'] as Object[] | undefined;
      if (errors !== undefined && errors.length > 0) {
        const first: Record<string, Object> = errors[0] as Record<string, Object>;
        return `${first['message'] ?? first['description'] ?? 'error'}`.substring(0, 80);
      }
      const data: Object | undefined = root['data'];
      if (data !== undefined && data !== null) {
        return 'null-result';
      }
      return `${root['status'] ?? 'no-data'}`.substring(0, 40);
    } catch (error) {
      return text.substring(0, 40);
    }
  }

  // ---------------------------------------------------------------- note id

  /**
   * 从 `media/{pk}/info/` 的 `media_notes.items` 里找**自己那条转发**的 note id。
   *
   * 判据：note 的 `user.pk` 是我，且 `note_style === 13`（转发那种）。找不到给空串。
   */
  private static async findNoteId(pk: string, actorId: string): Promise<string> {
    try {
      const result = await MobileRequest.send(`media/${encodeURIComponent(pk)}/info/`, '', '',
        true, null, null);
      if (!result.ok) {
        return '';
      }
      const root: Record<string, Object> = JSON.parse(result.body) as Record<string, Object>;
      const items: Object[] | undefined = root['items'] as Object[] | undefined;
      if (items === undefined || items.length === 0) {
        return '';
      }
      const item: Record<string, Object> = items[0] as Record<string, Object>;
      const notes: Object | undefined = item['media_notes'];
      if (notes === undefined || notes === null) {
        return '';
      }
      const list: Object[] | undefined = (notes as Record<string, Object>)['items'] as Object[]
        | undefined;
      if (list === undefined) {
        return '';
      }
      hilog.info(DOMAIN, TAG, 'media notes n=%{public}d', list.length);
      for (let index: number = 0; index < list.length; index++) {
        const one: Record<string, Object> = list[index] as Record<string, Object>;
        const style: number = one['note_style'] === undefined ? -1
          : Number.parseInt(`${one['note_style']}`, 10);
        const user: Object | undefined = one['user'];
        let userPk: string = `${one['user_id'] ?? ''}`.trim();
        if (user !== undefined && user !== null) {
          const box: Record<string, Object> = user as Record<string, Object>;
          const fromUser: string = `${box['pk'] ?? ''}`.trim();
          if (fromUser.length > 0) {
            userPk = fromUser;
          }
        }
        if (userPk === actorId && style === 13) {
          return `${one['id'] ?? ''}`.trim();
        }
      }
      return '';
    } catch (error) {
      return '';
    }
  }

  // ---------------------------------------------------------------- 令牌

  private static async tokensNow(refresh: boolean): Promise<WebTokens | null> {
    const cached: WebTokens | null = WebRepost.tokens;
    if (!refresh && cached !== null && Date.now() - cached.atMs < TOKEN_TTL_MS) {
      return cached;
    }
    const fetched: WebTokens | null = await WebRepost.fetchTokens();
    WebRepost.tokens = fetched;
    return fetched;
  }

  /** GET 首页 HTML，把 `lsd` 与 `fb_dtsg` 抠出来（见文件头）。 */
  private static async fetchTokens(): Promise<WebTokens | null> {
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(HOME_URL, {
        method: http.RequestMethod.GET,
        header: {
          'Cookie': MobileRequest.cookieHeader(jar.cookie),
          'User-Agent': WEB_UA,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9'
        },
        connectTimeout: 15000,
        readTimeout: 25000,
        expectDataType: http.HttpDataType.STRING
      });
      const html: string = typeof response.result === 'string' ? response.result as string : '';
      const lsd: string = WebRepost.tokenAfter(html, '"LSD",[],{"token":"');
      const dtsg: string = WebRepost.tokenAfter(html, '"DTSGInitialData",[],{"token":"');
      /*
       * `loggedIn` 只是**诊断**，不用它拦请求。
       *
       * 教训（真机踩的）：我一开始拿"首页 HTML 里有没有 `"logged_in_user"`"当登录判据，
       * 结果会话明明是好的，那份 HTML 里就是没有这几个字 —— 于是每一发转发都在本地被
       * 自己挡掉，用户看到的现象是"点转发完全没反应"（连请求都没发出去）。
       * 登录态该由服务端的应答来说话：真发出去，`data` 里有非 null 结果才算成功。
       */
      /*
       * 站点参数（见 WebTokens 的说明）：全从首页 HTML 的 SiteData 里读。
       */
      const hs: string = WebRepost.valueAfter(html, '"haste_session":"');
      const hsi: string = WebRepost.valueAfter(html, '"hsi":"');
      const rev: string = WebRepost.valueAfter(html, '"client_revision":');
      const spinB: string = WebRepost.valueAfter(html, '"__spin_b":"');
      const cometEnv: string = WebRepost.valueAfter(html, '"comet_env":');
      hilog.info(DOMAIN, TAG,
        'web tokens http=%{public}d bytes=%{public}d lsd=%{public}d dtsg=%{public}d hs=%{public}d hsi=%{public}d rev=%{public}s spinB=%{public}s comet=%{public}s',
        response.responseCode, html.length, lsd.length, dtsg.length, hs.length, hsi.length,
        rev, spinB, cometEnv);
      if (lsd.length === 0 || dtsg.length === 0) {
        WebRepost.detail = 'no-tokens-in-html';
        return null;
      }
      return new WebTokens(lsd, dtsg, WebRepost.jazoestOf(dtsg), hs, hsi, rev, spinB, cometEnv,
        Date.now());
    } catch (error) {
      WebRepost.detail = `token-fetch-threw:${(error as Error).message}`;
      hilog.warn(DOMAIN, TAG, 'token fetch failed: %{public}s', (error as Error).message);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** `marker` 之后、下一个引号之前的那一串（空 = 没找到）。 */
  private static tokenAfter(html: string, marker: string): string {
    const at: number = html.indexOf(marker);
    if (at < 0) {
      return '';
    }
    const from: number = at + marker.length;
    const end: number = html.indexOf('"', from);
    if (end <= from) {
      return '';
    }
    return html.substring(from, end);
  }

  /**
   * 值型参数（`"client_revision":1051294174` 这种**不带引号**的）：读到逗号 / 右括号为止。
   * 带引号的（`"haste_session":"…"`）走 tokenAfter。
   */
  private static valueAfter(html: string, marker: string): string {
    const at: number = html.indexOf(marker);
    if (at < 0) {
      return '';
    }
    const from: number = at + marker.length;
    if (from >= html.length) {
      return '';
    }
    if (html.charAt(from) === '"') {
      return WebRepost.tokenAfter(html, marker);
    }
    let end: number = from;
    while (end < html.length) {
      const ch: string = html.charAt(end);
      if (ch === ',' || ch === '}' || ch === ']' || ch === '"') {
        break;
      }
      end++;
    }
    return html.substring(from, end).trim();
  }

  /**
   * `jazoest`：fb_dtsg 每个字符的码点之和前面加个 `2`（网页端的老规矩）。
   *
   * 这条值本身没签名意义，但缺了/错了网页端会当成"非浏览器"，所以照它的算法现算。
   */
  private static jazoestOf(dtsg: string): string {
    let sum: number = 0;
    for (let index: number = 0; index < dtsg.length; index++) {
      sum += dtsg.charCodeAt(index);
    }
    return `2${sum}`;
  }

  // ---------------------------------------------------------------- 其它

  /** 当前账号的数字 id（取 Cookie 里的 `ds_user_id`，没有再问会话）。 */
  private static async myUserId(): Promise<string> {
    const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    const cookie: string = jar.cookie;
    const marker: string = 'ds_user_id=';
    const at: number = cookie.indexOf(marker);
    if (at >= 0) {
      const from: number = at + marker.length;
      let end: number = cookie.indexOf(';', from);
      if (end < 0) {
        end = cookie.length;
      }
      const id: string = cookie.substring(from, end).trim();
      if (id.length > 0) {
        return id;
      }
    }
    return '';
  }

  /** `csrftoken`（网页端变更要 `X-CSRFToken`，与 Cookie 里那个必须一致）。 */
  private static csrfOf(cookie: string): string {
    const marker: string = 'csrftoken=';
    const at: number = cookie.indexOf(marker);
    if (at < 0) {
      return '';
    }
    const from: number = at + marker.length;
    let end: number = cookie.indexOf(';', from);
    if (end < 0) {
      end = cookie.length;
    }
    return cookie.substring(from, end).trim();
  }

  private static nextMutationId(): string {
    mutationSeq = mutationSeq + 1;
    // 抓包里是 `"11"` 这种小整数（不是时间戳），见 mutationSeq 的说明。
    return `${mutationSeq}`;
  }

  /** 网页 GraphQL 的表单体（字段与真机抓包一致）。 */
  private static formBody(actorId: string, name: string, docId: string, variablesJson: string,
                          tokens: WebTokens): string {
    const parts: Array<string> = [];
    const add = (key: string, value: string): void => {
      if (value.length > 0) {
        parts.push(`${key}=${encodeURIComponent(value)}`);
      }
    };
    add('av', actorId);
    add('__d', 'www');
    add('__user', '0');
    add('__a', '1');
    add('__req', Math.floor(Math.random() * 1679616).toString(36));
    /*
     * 站点参数（见 WebTokens）：真机实证"不带这套 → 服务端静默回 data:null"。
     * `__hs` / `__hsi` / `__rev` / `__spin_b` / `__comet_req` 全部来自首页 HTML 的 SiteData。
     */
    add('__hs', tokens.hs);
    add('__hsi', tokens.hsi);
    add('__rev', tokens.rev);
    add('__spin_r', tokens.rev);
    add('__spin_b', tokens.spinB);
    add('dpr', '3');
    add('__ccg', 'EXCELLENT');
    add('__comet_req', tokens.cometEnv.length > 0 ? tokens.cometEnv : '7');
    add('lsd', tokens.lsd);
    add('fb_dtsg', tokens.dtsg);
    add('jazoest', tokens.jazoest);
    add('__spin_t', `${Math.floor(Date.now() / 1000)}`);
    add('fb_api_caller_class', 'RelayModern');
    add('fb_api_req_friendly_name', name);
    add('server_timestamps', 'true');
    add('variables', variablesJson);
    add('doc_id', docId);
    return parts.join('&');
  }

  /** 网页 GraphQL 的请求头（缺 `sec-fetch-*` / `origin` 会被当成页面导航，回一整个 HTML）。 */
  private static headers(jar: InstagramCookieSnapshot, tokens: WebTokens): Record<string, string> {
    const csrf: string = WebRepost.csrfOf(jar.cookie);
    const out: Record<string, string> = {};
    out['Content-Type'] = 'application/x-www-form-urlencoded';
    out['Cookie'] = MobileRequest.cookieHeader(jar.cookie);
    if (csrf.length > 0) {
      out['X-CSRFToken'] = csrf;
    }
    out['X-FB-LSD'] = tokens.lsd;
    out['X-IG-App-ID'] = WEB_APP_ID;
    out['X-ASBD-ID'] = ASBD_ID;
    /*
     * `X-IG-WWW-Claim: 0` —— 网页端在没有 claim 时就是这么发的（真机抓到的首页 HTML 里
     * 没有 `www_claim` 字段）。试过改用 Cookie 里的 `rur` 当 claim：**结果一模一样**（还是
     * `data:null`），所以别再从那儿凑，保持 0。
     */
    out['X-IG-WWW-Claim'] = '0';
    out['X-Requested-With'] = 'XMLHttpRequest';
    out['Origin'] = 'https://www.instagram.com';
    out['Referer'] = 'https://www.instagram.com/';
    out['User-Agent'] = WEB_UA;
    out['Accept'] = '*/*';
    out['Accept-Language'] = 'en-US,en;q=0.9';
    out['Sec-Fetch-Site'] = 'same-origin';
    out['Sec-Fetch-Mode'] = 'cors';
    out['Sec-Fetch-Dest'] = 'empty';
    return out;
  }
}

/** 一行日志（日志里只放状态码与响应体前 200 字，便于判断是"被拒"还是"回了 HTML"）。 */
function hpLog(label: string, name: string, code: number, body: string): void {
  hilog.info(DOMAIN, TAG, '%{public}s %{public}s http=%{public}d bytes=%{public}d body=%{public}s',
    label, name, code, body.length, body.substring(0, 200));
}
