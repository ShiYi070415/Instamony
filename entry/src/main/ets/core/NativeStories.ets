/*
 * 限时快拍托盘（主页 feeds 流上方那条）的**原生取数**。
 *
 * 数据来源：包里预置的 `PolarisStoriesV3TrayContainerQuery` 模板（`resources/rawfile/api_templates.json`
 * 里有它）。和私信/个人页一样：**模板直发**（一次 HTTP、不碰隐藏网页），失败再让调用方决定退回回放。
 *
 * 解析**不写死键名**：托盘的键名与"看过没有"的字段名各版本不一样（`tray` / `reels_tray`、
 * `seen` / `is_seen` / `view_state`…），所以这里按结构特征找 —— 在 data 里找第一个
 * **元素带 `user` 对象的数组**，每个元素再按候选字段名逐个试；认不出来就把键树打进日志
 * （`story tray miss …`），照着日志补一处候选名即可。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { ApiThrottle } from './ApiThrottle';
import { NativeFeed } from './NativeFeed';
import { RestSession } from './RestSession';
import { JsonRead } from './JsonRead';
import { StoryItem, StoryReel, StoryTray, StoryTrayItem } from '../model/Story';
import { MobileStories } from './mobileapi/MobileStories';
import { MobileChallenge } from './mobileapi/MobileChallenge';
// 「是不是我自己的快拍」要读当前会话的 `ds_user_id`（见 parse 里 selfReel 那一段）。
import { NativeProfile } from './NativeProfile';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeStories';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 15000;
const SITE: string = 'https://www.instagram.com';
/**
 * **先走移动端私有 API**（见 core/mobileapi/MobileStories）。
 *
 * 为什么放在最前（而不是当第四、第五条退路）：网页这条路在部分会话上被 IG 按**来源**拒
 * —— 测试者的诊断里 `reels_media` 回 500、`feed/user/<id>/story/` 回 400 challenge，
 * 而同一台设备换成移动端那套头（App-ID / UA / signed_body / Authorization）实测五发全通，
 * 且**一发就把 213 条托盘全带回来**（比模板 + GQL 那条既少请求又少解析）。
 *
 * 保留成显式开关（本项目的一贯做法）：真机上一旦发现移动端那条在某些账号上更差，
 * 把这个常量改成 false 就整条退回原来的路径，不用改任何调用点。
 */
const MOBILE_STORIES_FIRST: boolean = true;
/**
 * 点开某个人快拍时那条私有 REST 用的是**手机 App 的身份**（安卓 UA + 安卓 app id）。
 *
 * 和私信收件箱同一条经验（见 NativeDirect.inboxRest）：这类 `/api/v1/feed/…` 是 App 接口，
 * 拿 Web 那套头打过去，IG 常常当成"未登录"回 404 + 一页 HTML。所以这两条常量在这里各留一份
 * （和 NativeDirect 里的同名常量值一致，都来自抓到的安卓端请求）。
 *
 * **但身份要多试几种**：模拟器实测这一串旧版本号被 IG 顶回来
 * （`400` + `{"message":"challenge_required","challenge":{"url":"…/web/unsupported_version/"}}`，
 * 就是嫌客户端太旧），所以 `reel()` 会依次试 [网页头, 安卓新版本号, 安卓旧版本号, 网页头]，
 * 哪一发通就用哪一发 —— 日志里 `reel http id=…` 会写清是哪种身份通的。
 */
const ANDROID_UA: string =
  'Instagram 275.0.0.27.98 Android (30/11; 420dpi; 1080x2340; samsung; SM-G991B; o1s; exynos2100; en_US; 303244333)';
/** 较新的一串安卓 UA（旧串被判"版本不支持"时用它试）。 */
const ANDROID_UA_NEW: string =
  'Instagram 334.0.0.32.93 Android (33/13; 420dpi; 1080x2340; samsung; SM-G991B; o1s; exynos2100; en_US; 303244333)';
/** 安卓 App 的 app id（和 NativeDirect.ANDROID_APP_ID 一致）。 */
const ANDROID_APP_ID: string = '567067343352427';
/** 发请求用的身份（见 ANDROID_UA 的说明）。 */
const IDENTITY_WEB: number = 0;
const IDENTITY_ANDROID_NEW: number = 1;
const IDENTITY_ANDROID_OLD: number = 2;
/** 图片快拍没有时长，按 5 秒播（和 Instagram 自己的默认一致）。 */
const IMAGE_DURATION_MS: number = 5000;
/** 视频快拍的候选时长键（秒，浮点）。 */
const DURATION_KEYS: Array<string> = ['video_duration', 'duration'];
/** 快拍数组元素的候选"媒体类型"键（2 = 视频）。 */
const MEDIA_TYPE_KEYS: Array<string> = ['media_type', 'mediaType'];
/** 托盘那条查询的操作名片段（按片段匹配，IG 改后缀也认得出）。 */
const OP_TRAY: string = 'PolarisStoriesV3';
/** "看过没有"的候选键（顺序即优先级）。 */
const SEEN_KEYS: Array<string> = ['seen', 'is_seen', 'all_seen', 'viewed', 'is_viewed'];
/** 用户名 / 头像 / id 的候选键。 */
const NAME_KEYS: Array<string> = ['username', 'user_name'];
const AVATAR_KEYS: Array<string> = ['profile_pic_url', 'profile_pic_url_hd'];
const ID_KEYS: Array<string> = ['pk', 'id', 'user_id', 'strong_id__'];

export class NativeStories {
  private static detail: string = '-';
  /**
   * **已经关注过的"推荐快拍"**（userId 集合）。
   *
   * 需求："头像底部…点击后关注并消失"。光把它从界面数组里删掉不够：托盘缓存只有 3 分钟
   * （见 StoriesTray.TRAY_FRESH_MS），过期后我们会重新拉一次 `feed/reels_tray/`，
   * 而 IG 那边**这次**的推荐位多半还带着他（关注关系刚落库）—— 于是刚点过关注的那一项
   * 又冒出来了。所以在取数这一层就把它们滤掉：这一轮会话里不再出现，换账号时清空。
   */
  private static followedSuggested: Set<string> = new Set<string>();
  /**
   * 每个用户各自的**逐候选轨迹**（uid → 行数组，最多留 TRACE_MAX 行）。
   *
   * 为什么必须留（用户报的"点开快拍说没取到"）：这条链一次可能发好几发、每发的身份和 URL 都不同，
   * 失败原因（`http-500` / `http-4xx` / 非 JSON / 抛 / 真的没内容）**只有逐发看才能定位**；
   * 而 hilog 在真机上被 chromium 冲得几秒就没了（我们自己的 INFO 行根本留不住）。
   *
   * 为什么按 uid 分开（用户回传的诊断文件暴露的第二个问题）：托盘预取会**并发**对 5 位用户
   * 各发一次 `reel()`，而轨迹原来是一个全局数组 —— 于是一次失败记录里混进了**六个人的 URL**，
   * 根本看不出"被点的那位到底收到了什么"。现在按 uid 存，报告里只看这一位的轨迹。
   */
  private static traces: Map<string, Array<string>> = new Map<string, Array<string>>();
  /** 轨迹最多留几行（四发 + 头尾各留一点余量）。 */
  private static readonly TRACE_MAX: number = 12;
  /** 最多给几个用户留轨迹（防止长时间浏览把内存撑起来）。 */
  private static readonly TRACE_UIDS_MAX: number = 24;
  /** 最多试几个 id（主 id + 备选；见 reel 的第二段）。 */
  private static readonly ID_TRY_MAX: number = 3;
  /**
   * 这一轮里服务端**答过**（200 + JSON）没有 —— 决定要不要换备选 id 再问（见 reel）。
   * 它与 `detail` 不同：`detail` 是给用户/日志看的原因，这个只回答"那条请求通不通"。
   */
  private static answeredJson: boolean = false;
  /** 上一次请求的头里有没有 `x-ig-www-claim` / `x-instagram-ajax`（诊断与"要不要补抓模板"都用它）。 */
  private static lastHadClaim: boolean = false;
  private static lastHadAjax: boolean = false;
  /**
   * **"去抓一次 REST 模板"的钩子**（由 pages/Index 接上 `ensureAymlTemplate`）。
   *
   * 为什么需要：`reels_media` 要 `x-ig-www-claim`（会话级 hmac），而只有"网页自己发过一条
   * `/api/v1/…` 请求"才拿得到它。设备上没抓过那条模板时，我们只能先发一发（大概率 500），
   * 再让宿主去驱动一次隐藏网页把模板抓下来，然后**重试**——这正是用户那台设备需要的动作。
   * 放在 core 里为的是不让"取快拍"这条链直接依赖页面层（钩子为空就跳过，行为同以前）。
   */
  private static claimRefresher: (() => Promise<void>) | null = null;

  static setClaimRefresher(refresher: () => Promise<void>): void {
    NativeStories.claimRefresher = refresher;
  }

  /** 需不需要"补抓模板再重试"：刚才因为 5xx 失败、手上又没有 claim。 */
  private static wantsClaimRefresh(): boolean {
    return NativeStories.claimRefresher !== null
      && !NativeStories.lastHadClaim
      && NativeStories.detail.indexOf('http-5') === 0;
  }

  /**
   * **"去网页打开一次快拍页抓模板"的钩子**（由 pages/Index 接上，见 AppConfig.instagramStoriesUrl）。
   *
   * 为什么需要：`reels_media` 那条私有 REST 在部分会话上被 IG 回 500（诊断文件已证实头与 cookie
   * 都齐、claim 也在，仍然 500），而**网页那条路是通的**（托盘就是网页抓的）。
   * 所以在 REST 全失败之后，让宿主打开一次 `/stories/<用户名>/`，页面自己会发它那条快拍查询 ——
   * 我们把它抓下来、之后原生照着回放（同私信/搜索/个人页的做法）。
   */
  private static storyCapture: ((username: string) => Promise<boolean>) | null = null;

  static setStoryCaptureHook(hook: (username: string) => Promise<boolean>): void {
    NativeStories.storyCapture = hook;
  }

  /**
   * **"直接读故事页渲染出来的媒体"的钩子**（由 pages/Index 接上，见 storyMediaScript）。
   *
   * 为什么模板那条之后还要它：真机实测打开 `/stories/<用户名>/` 后页面**一个新请求都不发**
   * （`story template not captured`），但页面**自己把故事画出来了** —— 那就直接读画出来的那条。
   */
  private static storyPageReader:
    ((username: string, userId: string) => Promise<StoryReel | null>) | null = null;

  static setStoryPageReader(reader: (username: string, userId: string) =>
    Promise<StoryReel | null>): void {
    NativeStories.storyPageReader = reader;
  }

  /**
   * **手动跑一次"故事页抓模板"**（设定页的「抓故事页模板」按钮用；见 storyCapture）。
   *
   * 为什么要暴露出来：这条退路平时只在 REST 失败时触发，出问题的设备上不一定马上复现；
   * 有了它，测试同学（或我们自己）**当场**就能知道"这条路在当前账号上到底通不通"，
   * 不用等碰运气复现 —— 抓到就说明之后快拍能开。
   */
  static async runStoryCapture(): Promise<boolean> {
    const hook: ((username: string) => Promise<boolean>) | null = NativeStories.storyCapture;
    if (hook === null) {
      return false;
    }
    // 用户名传空：由宿主自己决定用谁（它手上有托盘顺序）。
    return await hook('');
  }

  /**
   * **手动跑一次"直接读故事页媒体"**（设定页那个测试入口的第二段，见 storyPageReader）。
   *
   * @returns 读到了没有（`lastDetail()` 里是 `-page` 或失败原因）。
   */
  static async runStoryPageRead(): Promise<boolean> {
    const reader:
      ((username: string, userId: string) => Promise<StoryReel | null>) | null =
      NativeStories.storyPageReader;
    if (reader === null) {
      return false;
    }
    try {
      const reel: StoryReel | null = await reader('', '');
      return reel !== null && reel.items.length > 0;
    } catch (error) {
      return false;
    }
  }

  /**
   * 模板名里像"某个人的快拍"的那几条（**排除托盘容器**那条：它是首页那一排的列表，不含 media）。
   *
   * 判据必须**紧**（真机踩过）：第一版只要求名字含 `stor` 或 `reel`，于是
   * `PolarisProfileReelsTabContentQuery`（个人页的 reels 分页，本来就是存着的）被当成"快拍查询"
   * —— `hasStoryTemplate()` 一开始就为真，抓取直接跳过，而界面还报"已抓到模板"，
   * 等于**用一条错的模板把真正的退路整个挡掉**（还看不出来）。
   *
   * 现在：名字里必须出现 `stories`/`story`，并且不含下面这些"不是我们要的那条"的词
   * （托盘容器、高亮托盘、个人页、reels/clips 分页、未读、归档、变更、广告）。
   */
  private static readonly STORY_BAD: Array<string> = ['tray', 'container', 'highlight', 'seen',
    'mutation', 'archive', 'profile', 'reels', 'clip', 'ads'];

  static storyOps(): Array<string> {
    const names: Array<string> = ApiRegistry.getInstance().storedNames();
    const out: Array<string> = [];
    for (let index: number = 0; index < names.length; index++) {
      const lower: string = names[index].toLowerCase();
      if (lower.indexOf('stories') < 0 && lower.indexOf('story') < 0) {
        continue;
      }
      let skip: boolean = false;
      for (let b: number = 0; b < NativeStories.STORY_BAD.length; b++) {
        if (lower.indexOf(NativeStories.STORY_BAD[b]) >= 0) {
          skip = true;
          break;
        }
      }
      if (!skip) {
        out.push(names[index]);
      }
    }
    return out;
  }

  /** 手上有没有"某个人的快拍"那条模板。 */
  static hasStoryTemplate(): boolean {
    return NativeStories.storyOps().length > 0;
  }

  /**
   * **用网页自己那条快拍查询回放**（见 storyCapture 的说明）。
   *
   * 和 `reel()` 的关系：REST 两条路都失败之后才走这里 —— 先试手上已有的模板；
   * 一条都没有就让宿主打开一次故事页把模板抓下来，再试一遍。
   */
  private static async storyViaTemplate(userId: string,
                                        username: string): Promise<StoryReel | null> {
    let ops: Array<string> = NativeStories.storyOps();
    if (ops.length === 0) {
      const capture: ((username: string) => Promise<boolean>) | null = NativeStories.storyCapture;
      if (capture === null || username.length === 0) {
        return null;
      }
      NativeStories.note(userId, '  → REST 全失败：打开一次故事页抓模板');
      try {
        await capture(username);
      } catch (error) {
        NativeStories.note(userId, `  → 故事页抓模板失败：${(error as Error).message ?? '-'}`);
        return null;
      }
      ops = NativeStories.storyOps();
    }
    for (let index: number = 0; index < ops.length; index++) {
      const op: string = ops[index];
      const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
      if (tpl === null) {
        continue;
      }
      const body: string = NativeStories.patchStoryVars(tpl.body ?? '', userId);
      const headers: Record<string, string> = await NativeFeed.headersFor(op);
      if (Object.keys(headers).length === 0) {
        continue;
      }
      const isGet: boolean = (tpl.method ?? 'POST').toUpperCase() === 'GET';
      const text: string | null = await NativeStories.postForm(tpl, headers, body, isGet, userId);
      if (text === null) {
        continue;
      }
      const reel: StoryReel | null = NativeStories.parseReel(text, userId);
      if (reel !== null && reel.items.length > 0) {
        NativeStories.detail = '-';
        NativeStories.note(userId, `  → 网页查询回放成功 op=${op} items=${reel.items.length}`);
        hilog.info(DOMAIN, TAG, 'reel ok via page query op=%{public}s uid=%{public}s n=%{public}d',
          op, userId, reel.items.length);
        return reel;
      }
      NativeStories.note(userId, `  → 网页查询 op=${op} 没解析出 media（len=${text.length}）`);
    }
    /*
     * **最后：直接读页面渲染出来的那条媒体**（见 storyPageReader）。
     * 真机上"抓网页查询"这条路不成立（页面不发请求），但故事是**页面上画着的**。
     */
    const reader:
      ((username: string, userId: string) => Promise<StoryReel | null>) | null =
      NativeStories.storyPageReader;
    if (reader !== null) {
      try {
        const fromPage: StoryReel | null = await reader(username, userId);
        if (fromPage !== null && fromPage.items.length > 0) {
          NativeStories.detail = '-page';
          NativeStories.note(userId, `  → 读页面媒体成功 op=page items=${fromPage.items.length}`);
          return fromPage;
        }
      } catch (error) {
        NativeStories.note(userId, `  → 读页面媒体失败：${(error as Error).message ?? '-'}`);
      }
    }
    return null;
  }

  /**
   * 把网页快拍查询的 `variables` 里**指向"哪个人/哪条快拍"的那些键**换成目标用户。
   *
   * 按**键名**改（不是按值）：快拍查询的变量名是稳定的几个（`reel_ids` / `reel_media_ids` /
   * `user_id` / `target_user_id`…），比"猜之前那个值"可靠得多（私信那条只能按值改，是因为
   * 它的键名不固定）。
   */
  private static patchStoryVars(body: string, userId: string): string {
    if (body.length === 0) {
      return body;
    }
    const parts: Array<string> = body.split('&');
    const out: Array<string> = [];
    let patched: boolean = false;
    for (let index: number = 0; index < parts.length; index++) {
      const part: string = parts[index];
      if (part.indexOf('variables=') !== 0) {
        out.push(part);
        continue;
      }
      try {
        const raw: string = decodeURIComponent(part.substring('variables='.length));
        const src: Record<string, Object> = JsonRead.parse(raw);
        patched = NativeStories.patchStoryRecord(src, userId) || patched;
        out.push(`variables=${encodeURIComponent(JSON.stringify(src))}`);
      } catch (error) {
        out.push(part);
      }
    }
    return patched ? out.join('&') : body;
  }

  /** 递归改快拍变量里的"目标 id"字段（返回有没有改过）。 */
  private static patchStoryRecord(node: Record<string, Object>, userId: string): boolean {
    const targets: Array<string> = ['reel_ids', 'reel_media_ids', 'user_id', 'target_user_id',
      'target_id', 'user_ids', 'reel_id'];
    let changed: boolean = false;
    const keys: Array<string> = Object.keys(node);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const lower: string = key.toLowerCase();
      if (targets.indexOf(lower) >= 0) {
        const value: Object = node[key];
        // 原来是数组就塞数组（IG 的 `reel_ids` 就是数组），否则塞字符串。
        node[key] = Array.isArray(value) ? [userId] : userId;
        changed = true;
        continue;
      }
      const child: Record<string, Object> | null = JsonRead.asRecord(node[key]);
      if (child !== null && NativeStories.patchStoryRecord(child, userId)) {
        changed = true;
      }
    }
    return changed;
  }

  /** 发一次回放请求（表单体；GET 时把体拼到 query 上，和 NativeProfile.bodyWith 同思路）。 */
  private static async postForm(tpl: ApiTemplate, headers: Record<string, string>, body: string,
                                isGet: boolean, uid: string): Promise<string | null> {
    const base: string = tpl.url.indexOf('http') === 0 ? tpl.url : `${SITE}${tpl.url}`;
    const url: string = isGet && body.length > 0
      ? `${base}${base.indexOf('?') >= 0 ? '&' : '?'}${body}` : base;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: isGet ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: headers,
        extraData: isGet ? undefined : body,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const head: string = text.length > 0 ? text.charAt(0) : '';
      const json: boolean = head === '{' || head === '[';
      NativeStories.note(uid, `  page-query url=${NativeStories.tailOf(url)}`
        + ` code=${response.responseCode} json=${json} len=${text.length}`
        + ` head=${text.substring(0, 160).replace(/[\r\n]+/g, ' ')}`);
      if (response.responseCode !== 200 || !json) {
        NativeStories.detail = `page-http-${response.responseCode}${json ? '' : '/non-json'}`;
        return null;
      }
      return text;
    } catch (error) {
      NativeStories.detail = `page-throw:${(error as Error).message ?? '-'}`.substring(0, 50);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** `/api/v1/…` 要的头名与 cookie 名都在了没有（诊断）。 */
  static lastHeadersDiag(): string {
    return `claim=${NativeStories.lastHadClaim} ajax=${NativeStories.lastHadAjax}`;
  }

  /** 从 cookie 串里取**名字**（不取值：值里有会话材料）。 */
  private static cookieNames(cookie: string): string {
    if (cookie.length === 0) {
      return '';
    }
    const parts: Array<string> = cookie.split(';');
    const names: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const at: number = parts[index].indexOf('=');
      const name: string = (at > 0 ? parts[index].substring(0, at) : parts[index]).trim();
      if (name.length > 0) {
        names.push(name);
      }
    }
    return names.sort().join(',');
  }
  /**
   * 托盘里每条条目的**原始 JSON**（userId → 该条目的 JSON 文本，截断保存）。
   *
   * 两个用途，都是"远端用户复现时我们看不到现场"逼出来的：
   *   ① **兜底**：`reels_media` 不给内容时，用手上这份条目自己带的 media 拼一条（见 reelFromTrayNode）；
   *   ② **诊断**：写进 `storyfail_*.txt` 的 `raw[node]=…` —— entry 里到底有哪些 id / 有没有 items，
   *      只有原始数据能说清（我们解析出来的那几个字段不够）。
   */
  private static nodeRaw: Map<string, string> = new Map<string, string>();
  /** 原始条目最多留多少条（托盘的 143 条也没必要全留）。 */
  private static readonly NODE_RAW_MAX: number = 80;
  /** 每条原始 JSON 截断到多少字符（够看清键名与值，又不至于让内存里的字符串太大）。 */
  private static readonly NODE_RAW_CHARS: number = 1200;
  /**
   * 每条条目的**形状摘要**（userId → `reel_type=… besties=… expiring=… …`）。
   *
   * 为什么单存这个而不是只留原始 JSON：真机上 80 条条目的 JSON 全在 1200 字符处被截断
   * （`items`/`user` 都排在后面），**恰恰是这几个短字段能一眼看出"这条该不该有快拍"**：
   *   · `reel_type` —— 只有 `user_reel` 才是"某个用户的快拍"；别的类型拿用户 pk 去问
   *     `reels_media` 本来就该是空的；
   *   · `has_besties_media` / `latest_besties_reel_media` —— 只发给"密友"的那部分快拍；
   *   · `expiring_at` —— 过期时刻（用来算"我们问的时候是不是已经过期了"）。
   */
  private static nodeShape: Map<string, string> = new Map<string, string>();

  /** 记一条条目的形状摘要（读的就是托盘原始字段，见 nodeShape 的说明）。 */
  private static rememberShape(userId: string, node: Record<string, Object>,
                               user: Record<string, Object> | null): void {
    if (userId.length === 0 || NativeStories.nodeShape.has(userId)) {
      return;
    }
    const reelType: string = JsonRead.strOf(node, 'reel_type');
    const besties: boolean = JsonRead.boolOf(node, 'has_besties_media');
    const latest: number = JsonRead.numOf(node, 'latest_reel_media');
    const expiring: number = JsonRead.numOf(node, 'expiring_at');
    const seen: number = JsonRead.numOf(node, 'seen');
    const nodeId: string = JsonRead.strOf(node, 'id');
    const userPk: string = user === null ? '' : JsonRead.strOf(user, 'pk');
    NativeStories.nodeShape.set(userId,
      `reel_type=${reelType.length > 0 ? reelType : '(none)'} besties=${besties}`
      + ` latest_reel_media=${latest} expiring_at=${expiring} seen=${seen}`
      + ` entryItems=${JsonRead.arrayOf(node, 'items').length}`
      + ` node.id=${nodeId.length > 0 ? nodeId : '(none)'}`
      + ` user.pk=${userPk.length > 0 ? userPk : '(none)'}`);
  }

  /** 某一轮托盘的形状摘要（userId → 摘要行），供诊断落盘。 */
  static shapesDump(): Array<string> {
    const out: Array<string> = [];
    NativeStories.nodeShape.forEach((value: string, key: string): void => {
      out.push(`uid=${key} ${value}`);
    });
    return out;
  }

  /**
   * 把这一轮托盘的**原始条目**整理成文本（诊断：进 `Instarmony_diag.txt`，见 core/StoryDiag）。
   *
   * 为什么值得单独留一份：托盘条目的形状**按账号/设备不一样**（带不带 `user`、有没有 `items`、
   * id 字段叫什么），而"点开快拍 empty 只有部分用户"恰恰取决于这些差异 ——
   * 只留我们自己解析出来的那几个字段，等于把判断依据丢了。
   */
  static rawNodes(): Array<string> {
    const out: Array<string> = [];
    NativeStories.nodeRaw.forEach((value: string, key: string): void => {
      out.push(`uid=${key} ${value}`);
    });
    return out;
  }

  /** 记下一条条目的原始 JSON（见 nodeRaw 的说明）。 */
  private static rememberNode(userId: string, node: Record<string, Object>): void {
    if (userId.length === 0 || NativeStories.nodeRaw.has(userId)) {
      return;
    }
    if (NativeStories.nodeRaw.size >= NativeStories.NODE_RAW_MAX) {
      return;
    }
    try {
      let text: string = JSON.stringify(node);
      if (text.length > NativeStories.NODE_RAW_CHARS) {
        text = text.substring(0, NativeStories.NODE_RAW_CHARS);
      }
      NativeStories.nodeRaw.set(userId, text);
    } catch (error) {
      // 循环引用之类：存一份标记就够了，诊断时看得出"没存成"。
      NativeStories.nodeRaw.set(userId, '(stringify-failed)');
    }
  }

  static lastDetail(): string {
    return NativeStories.detail;
  }

  /**
   * 把一位"推荐快拍"从后续托盘里永久滤掉（用户点了关注，见 followedSuggested 的说明）。
   *
   * 只影响这一轮会话：换账号时 `clearHidden()`。
   */
  static hideSuggested(userId: string): void {
    if (userId.length > 0) {
      NativeStories.followedSuggested.add(userId);
    }
  }

  /** 换账号 / 退出登录：把"已关注过的推荐"那张表清掉（那是上一个人的关注关系）。 */
  static clearHidden(): void {
    NativeStories.followedSuggested.clear();
  }

  /** 取数之后统一过一遍：已关注过的推荐不再出现（托盘条目、顺序、预取都跟着少一位）。 */
  private static pruneHidden(tray: StoryTray): StoryTray {
    if (NativeStories.followedSuggested.size === 0) {
      return tray;
    }
    const kept: Array<StoryTrayItem> = [];
    for (let index: number = 0; index < tray.items.length; index++) {
      const one: StoryTrayItem = tray.items[index];
      if (one.suggested && NativeStories.followedSuggested.has(one.userId)) {
        continue;
      }
      kept.push(one);
    }
    if (kept.length === tray.items.length) {
      return tray;
    }
    hilog.info(DOMAIN, TAG, 'tray pruned followed-suggested %{public}d → %{public}d',
      tray.items.length, kept.length);
    return new StoryTray(kept, tray.selfAvatar);
  }

  /** 记一行轨迹（按 uid 分开存，见 traces 的说明）。 */
  private static note(userId: string, line: string): void {
    let list: Array<string> | undefined = NativeStories.traces.get(userId);
    if (list === undefined) {
      // 控制在 TRACE_UIDS_MAX 个用户以内：满了就整表清空（诊断够用，不做 LRU）。
      if (NativeStories.traces.size >= NativeStories.TRACE_UIDS_MAX) {
        NativeStories.traces.clear();
      }
      list = [];
      NativeStories.traces.set(userId, list);
    }
    list.push(line);
    while (list.length > NativeStories.TRACE_MAX) {
      list.shift();
    }
  }

  /** 某一位的轨迹（没有就给空数组）。 */
  private static traceOf(userId: string): Array<string> {
    const list: Array<string> | undefined = NativeStories.traces.get(userId);
    return list === undefined ? [] : list;
  }

  /** 开一次新尝试：清掉这一位的旧轨迹（同一位被点两次时不会把上一次的行混进来）。 */
  private static resetTrace(userId: string): void {
    NativeStories.traces.set(userId, []);
  }

  /** 上一次网络探针的结果（见 probeNetwork；写进失败报告）。 */
  private static netProbe: string = '-';
  /** 探针用的普通浏览器 UA（只取 robots.txt，不涉及 IG 的客户端校验）。 */
  private static readonly NET_PROBE_UA: string =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    + '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  static lastNetProbe(): string {
    return NativeStories.netProbe;
  }

  /**
   * **网络探针**：确认"到 IG 的基本链路通不通"（只在快拍失败时发一次）。
   *
   * 拿的是 `robots.txt`（公开、极小、不需要会话，也不会被当成接口调用），所以它的成败
   * 只反映**链路**：通了而接口 500 ⇒ 服务端按来源拒（IP/代理问题）；不通 ⇒ VPN/链路本身的事。
   */
  private static async probeNetwork(): Promise<void> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(`${SITE}/robots.txt`, {
        method: http.RequestMethod.GET,
        header: { 'accept': '*/*', 'user-agent': NativeStories.NET_PROBE_UA },
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      NativeStories.netProbe = `robots.txt http-${response.responseCode}`;
    } catch (error) {
      NativeStories.netProbe = `robots.txt throw:${(error as Error).message ?? '-'}`.substring(0, 60);
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
    hilog.info(DOMAIN, TAG, 'net probe %{public}s', NativeStories.netProbe);
  }

  /**
   * 把"这一次为什么没取到"整理成一段可读文本（落文件用，见 pages/Index.dumpProbeFile）。
   *
   * 内容刻意全都是**下次能直接判定的东西**：问了哪个 uid、四发各自的身份/URL/状态码/长度、
   * 响应开头（判断"服务端说没有"还是"我们解析不出来"）、托盘的原始条目、预缓存队列状态。
   */
  static failureReport(userId: string, username: string, trayCount: number,
                       trayHead: string, queueIndex: number, cachedAvailable: boolean,
                       trayAgeMs: number): string {
    const lines: Array<string> = [];
    lines.push(`Instamony 快拍取数失败 uid=${userId} name=${username}`);
    lines.push(`detail=${NativeStories.detail}`);
    lines.push(`tray items=${trayCount} at=${queueIndex} storyCacheHas=${cachedAvailable}`);
    /*
     * 托盘那份数据有多旧。这一条是**判断"快拍已经过期"还是"我们问错了 id"的关键**：
     * 托盘的种子最长允许 3 分钟（见 StoriesTray.TRAY_FRESH_MS），期间 IG 侧完全可能有人的
     * 快拍刚好到期 —— 那种情况下托盘还列着他，而 `reels_media` 已经回空。
     */
    lines.push(`tray age=${trayAgeMs}ms (~${Math.round(trayAgeMs / 1000)}s)`);
    lines.push(`tray head=${trayHead}`);
    /*
     * **网络探针**（见 probeNetwork）：一条最轻的公开资源请求。
     *
     * 为什么要它：出问题的那台设备在**内地 + VPN**（我这台是香港网络，同一账号完全正常），
     * 而 IG 对"可疑来源"会回 `challenge_required`（那次响应里还有 `lock:true`）——
     * 也就是说**很可能是出口 IP/链路的问题，不是我们请求写错了**。
     * 有了这一行就能区分两种完全不同的情况：
     *   · 探针也失败（`http-…`/`throw:`）→ 链路本身不通（VPN 断了 / 被拦）；
     *   · 探针 200 而接口 500 → 链路是通的，是**服务端按来源拒**（IP 被标记 / 透明代理改了头）。
     */
    lines.push(`net=${NativeStories.netProbe}`);
    /*
     * **这一条条目的原始 JSON**（见 nodeRaw 的说明）：`reels_media` 回空时，判断"是我们取错了 id
     * 字段 / 条目来自别的分区 / 根本就没带 media"，只有原始数据能说清 —— 我们解析出来的那几个
     * 字段（uid/username/seen/count）不足以区分这几种。
     */
    const raw: string | undefined = NativeStories.nodeRaw.get(userId);
    lines.push(`raw[node]=${raw === undefined ? '(not kept)' : raw}`);
    /*
     * **形状摘要**（见 nodeShape）：比上面那坨截断的 JSON 好读，
     * 而且直接回答了"这条该不该有快拍"——`reel_type` 不是 `user_reel`、或者
     * `expiring_at` 已经过去，那 `empty` 就是**正常**结果，不是我们的 bug。
     */
    const shape: string | undefined = NativeStories.nodeShape.get(userId);
    lines.push(`shape=${shape === undefined ? '(not kept)' : shape}`);
    lines.push('== 这一位的逐发轨迹 ==');
    const trace: Array<string> = NativeStories.traceOf(userId);
    for (let index: number = 0; index < trace.length; index++) {
      lines.push(`  ${trace[index]}`);
    }
    if (trace.length === 0) {
      lines.push('  (空：还没发过请求就被判定失败 —— 看 detail)');
    }
    return lines.join('\n');
  }

  /**
   * 拉一次托盘（拿不到给 null）。
   *
   * 请求体**原样重发**（模板就是网页自己发过的那一发，不动它的 variables —— 托盘没有分页需求）。
   */
  static async tray(): Promise<StoryTray | null> {
    /*
     * **移动端私有 API 优先**（见文件头 MOBILE_STORIES_FIRST）：
     * 一发 `feed/reels_tray/` 就把整条托盘带回来（实测 213 条 / 425KB），
     * 而且不依赖"网页抓到的模板"——模板缺失正是这条路上最常见的失败（`no-template`）。
     * 失败**静默**落回下面那条老路：老路仍然是模板/GQL 的唯一入口，不该因为新路失败就丢功能。
     */
    if (MOBILE_STORIES_FIRST) {
      const mobile: StoryTray | null = await MobileStories.tray();
      if (mobile !== null && mobile.items.length > 0) {
        NativeStories.detail = '-';
        const tray: StoryTray = NativeStories.pruneHidden(mobile);
        hilog.info(DOMAIN, TAG, 'tray via mobile n=%{public}d first=%{public}s',
          tray.items.length, tray.items.length > 0 ? tray.items[0].username : '-');
        if (tray.items.length > 0) {
          return tray;
        }
      }
    }
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(OP_TRAY);
    if (tpl === null) {
      NativeStories.detail = 'no-template';
      hilog.warn(DOMAIN, TAG, 'no tray template stored=%{public}s',
        ApiRegistry.getInstance().storedSummary());
      return null;
    }
    let headers: Record<string, string> = await NativeFeed.headersFor(OP_TRAY);
    if (Object.keys(headers).length === 0) {
      headers = await NativeFeed.sessionOrBrowserHeaders();
    }
    if (Object.keys(headers).length === 0) {
      NativeStories.detail = 'no-session';
      return null;
    }
    const url: string = tpl.url.startsWith('http') ? tpl.url : `${SITE}${tpl.url}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: tpl.body ?? '',
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const json: boolean = text.indexOf('"data"') >= 0 || text.indexOf('"errors"') >= 0;
      hilog.info(DOMAIN, TAG, 'tray http code=%{public}d json=%{public}s len=%{public}d',
        response.responseCode, `${json}`, text.length);
      if (response.responseCode !== 200 || !json) {
        NativeStories.detail = `http-${response.responseCode}${json ? '' : '/non-json'}`;
        hilog.warn(DOMAIN, TAG, 'tray body: %{public}s',
          text.substring(0, 160).replace(/[\r\n]+/g, ' '));
        return null;
      }
      const parsedTray: StoryTray | null = NativeStories.parse(text);
      if (parsedTray === null) {
        NativeStories.detail = 'parse';
        return null;
      }
      const tray: StoryTray = NativeStories.pruneHidden(parsedTray);
      if (tray.items.length === 0) {
        NativeStories.detail = 'empty';
        return null;
      }
      NativeStories.detail = '-';
      hilog.info(DOMAIN, TAG, 'tray ok n=%{public}d first=%{public}s seen=%{public}s',
        tray.items.length, tray.items[0].username, `${tray.items[0].seen}`);
      return tray;
    } catch (error) {
      NativeStories.detail = `throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60);
      hilog.warn(DOMAIN, TAG, 'tray failed: %{public}s', NativeStories.detail);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 响应文本 → 托盘（按结构找，见文件头）。 */
  private static parse(text: string): StoryTray | null {
    const root: Record<string, Object> = JsonRead.parse(text);
    const data: Record<string, Object> | null = JsonRead.recordOf(root, 'data');
    if (data === null) {
      NativeStories.logMiss(root, 'no-data');
      return null;
    }
    const found: Array<Object> | null = NativeStories.findTrayArray(data, 0);
    if (found === null) {
      NativeStories.logMiss(data, 'no-tray-array');
      return null;
    }
    // 新一轮托盘数据：原始条目表整个换掉（旧的 id 可能已经不在托盘里了）。
    NativeStories.nodeRaw.clear();
    NativeStories.nodeShape.clear();
    const items: Array<StoryTrayItem> = [];
    for (let index: number = 0; index < found.length; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(found[index]);
      if (node === null) {
        continue;
      }
      const user: Record<string, Object> | null = JsonRead.recordOf(node, 'user');
      const host: Record<string, Object> = user !== null ? user : node;
      /*
       * 首选 id 仍按原来的键序（`pk` → `id` → `user_id` → `strong_id__`），
       * 但**备选也一起收下来**：条目没有 `user` 对象时首选会退到 `node.id`（可能是 reel/media id），
       * 这时备选里的 `user_id`/`strong_id__` 往往才是真正的用户 pk（见 StoryTrayItem.altIds）。
       * 有 `user` 对象时首选就是用户 pk，备选基本用不上（留着无害）。
       */
      const id: string = NativeStories.pickStr(host, ID_KEYS, '');
      if (id.length === 0) {
        continue;
      }
      const ids: Array<string> = NativeStories.collectIds(host);
      const altIds: Array<string> = [];
      for (let k: number = 0; k < ids.length; k++) {
        if (ids[k] !== id) {
          altIds.push(ids[k]);
        }
      }
      const username: string = NativeStories.pickStr(host, NAME_KEYS, '');
      let avatar: string = NativeStories.pickStr(host, AVATAR_KEYS, '');
      if (avatar.length === 0) {
        const hd: Record<string, Object> | null = JsonRead.recordOf(host, 'hd_profile_pic_url_info');
        if (hd !== null) {
          avatar = JsonRead.strOf(hd, 'url');
        }
      }
      // "看过没有"：先看这一项自己，再看 user 上有没有。
      let seen: boolean = false;
      for (let at: number = 0; at < SEEN_KEYS.length; at++) {
        if (JsonRead.has(node, SEEN_KEYS[at])) {
          seen = JsonRead.boolOf(node, SEEN_KEYS[at]);
          break;
        }
        if (JsonRead.has(host, SEEN_KEYS[at])) {
          seen = JsonRead.boolOf(host, SEEN_KEYS[at]);
          break;
        }
      }
      const count: number = JsonRead.arrayOf(node, 'items').length;
      /*
       * 新增的三个判据（和移动端那条对齐，见 core/mobileapi/MobileStories.trayItems）：
       *   · `reel_type` 含 `suggested`（或 `is_suggested`）→ 推荐快拍（头像底部挂「+关注」）；
       *   · `user.friendship_status.following` → 播放页那颗关注按钮要不要出现；
       *   · `user.pk` 等于自己的 `ds_user_id` → 这是"我的快拍"（固定排第一位）。
       * 网页模板这条路上这些字段不一定齐，所以"没给"一律按未知处理（followKnown）。
       */
      const reelType: string = NativeStories.pickStr(node, ['reel_type', 'reelType'], '');
      const suggested: boolean = reelType.indexOf('suggested') >= 0
        || JsonRead.boolOf(node, 'is_suggested');
      const friendship: Record<string, Object> | null = JsonRead.recordOf(host, 'friendship_status');
      let followKnown: boolean = false;
      let following: boolean = false;
      if (friendship !== null) {
        followKnown = true;
        following = JsonRead.boolOf(friendship, 'following');
      }
      const ownId: string = NativeProfile.ownIdCached();
      const selfReel: boolean = ownId.length > 0 && id === ownId;
      NativeStories.rememberNode(id, node);
      NativeStories.rememberShape(id, node, user);
      items.push(new StoryTrayItem(id, username, avatar, seen, count, altIds,
        following, followKnown, suggested, selfReel));
    }
    // 自己的头像：托盘里正好有自己那一项就用它（没有时由宿主补，见 StoryTray.selfAvatar）。
    let selfAvatar: string = '';
    for (let index: number = 0; index < items.length; index++) {
      if (items[index].selfReel) {
        selfAvatar = items[index].avatarUrl;
        break;
      }
    }
    return new StoryTray(items, selfAvatar);
  }

  /**
   * 在 data 里找"托盘数组"：元素是对象、且**带 user 对象**的那个数组（广度优先，深度封顶）。
   *
   * 不认键名（`tray` / `reels_tray` / `edges` 都可能），认结构。
   */
  private static findTrayArray(host: Record<string, Object>, depth: number): Array<Object> | null {
    if (depth > 4) {
      return null;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null && JsonRead.recordOf(first, 'user') !== null) {
          return list;
        }
      }
    }
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: Array<Object> | null = NativeStories.findTrayArray(child, depth + 1);
        if (hit !== null) {
          return hit;
        }
      }
    }
    return null;
  }

  /**
   * 按候选键把**所有非空**字符串收下来（第一个是"首选"，后面是备选 id，见 StoryTrayItem.altIds）。
   *
   * 为什么不全用首选就走：托盘条目有三种长相 —— 带完整 `user`、带精简 `user`、根本没有 `user`。
   * 最后一类只能取条目自己的 `id`，而那个位置**可能是 reel/media 的 id**（不是用户 pk）。
   * 把同一层里其它数字字段一起收着，主 id 问不出内容时还能逐个再问（见 reel 的第二段）。
   */
  private static collectIds(host: Record<string, Object>): Array<string> {
    const out: Array<string> = [];
    for (let index: number = 0; index < ID_KEYS.length; index++) {
      const value: string = JsonRead.strOf(host, ID_KEYS[index]);
      if (value.length > 0 && out.indexOf(value) < 0) {
        out.push(value);
      }
    }
    return out;
  }

  /** 按候选键取第一个非空字符串。 */
  private static pickStr(host: Record<string, Object>, keys: Array<string>,
                         fallback: string): string {
    for (let index: number = 0; index < keys.length; index++) {
      const value: string = JsonRead.strOf(host, keys[index]);
      if (value.length > 0) {
        return value;
      }
    }
    return fallback;
  }

  /** 认不出结构时把键树打出来（照着它补候选键名）。 */
  private static logMiss(host: Record<string, Object>, why: string): void {
    const keys: Array<string> = Object.keys(host);
    const lines: Array<string> = [];
    for (let index: number = 0; index < keys.length && index < 8; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        lines.push(`${keys[index]}{${Object.keys(child).slice(0, 6).join(',')}}`);
        continue;
      }
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        lines.push(`${keys[index]}[${list.length}]${first === null ? ''
          : '{' + Object.keys(first).slice(0, 6).join(',') + '}'}`);
        continue;
      }
      lines.push(keys[index]);
    }
    hilog.info(DOMAIN, TAG, 'story tray miss why=%{public}s tree=%{public}s',
      why, lines.join(' '));
  }

  // ---------------------------------------------------------------- 播放页取数

  /**
   * 拉某个用户**当前未过期**的全部快拍（点开托盘里那一项时用；拿不到给 null）。
   *
   * 为什么不用模板：网页版那条"快拍播放页"的查询（doc_id）只有网页真的点开过某个人的快拍
   * 才会被抓到，而托盘是从首页进的 —— 手里只有托盘那条模板。所以这里走**私有 REST**
   * （App 接口），它一次就把 media 列表给全（见 fetchText / parseReel）。
   *
   * @param altIds 这条托盘条目的**备选 id**（见 StoryTrayItem.altIds）：主 id 问不出内容时逐个再问。
   *   它解决的正是"只有部分用户点开提示没取到（原因 empty）"那一类 —— 托盘条目取错了 id 字段。
   */
  static async reel(userId: string, altIds: Array<string> = [],
                    username: string = '',
                    priority: number = ApiThrottle.warm()): Promise<StoryReel | null> {
    if (userId.length === 0) {
      NativeStories.detail = 'no-user';
      return null;
    }
    /*
     * **移动端私有 API 优先**（见文件头 MOBILE_STORIES_FIRST）。
     *
     * 这里的候选顺序是**实测定的**（自检报告见 core/mobileapi/MobileStories 的文件头）：
     *   ① `GET /api/v1/feed/user/{uid}/story/` —— 一发拿到这个人当前全部快拍（媒体在 `reel.items`）；
     *   ② `GET /api/v1/feed/reels_media/?reel_ids=<裸 id>` —— 用户 pk 与 reel id 不一致时靠它；
     *      注意 **JSON 数组形式回空**，所以是裸 id（网页那条用的正是数组形式）。
     * 两条都不成，才落回下面那串"模板/换身份/换主机"的老候选。
     */
    if (MOBILE_STORIES_FIRST) {
      const mobile: StoryReel | null = await MobileStories.reel(userId, altIds, username, priority);
      if (mobile !== null && mobile.items.length > 0) {
        NativeStories.detail = '-';
        hilog.info(DOMAIN, TAG, 'reel via mobile uid=%{public}s user=%{public}s n=%{public}d',
          userId, mobile.username, mobile.items.length);
        return mobile;
      }
      // 记一行轨迹：失败报告里要能看出"移动端这条也试过了、结果是什么"。
      NativeStories.note(userId, `mobile=none user=${userId}`);
    }
    /*
     * 候选 = **一条 URL × 三种身份**（见文件头 ANDROID_UA 的说明）：
     *   ① 整体 reels + 网页身份（模板里那条，最常见能成）
     *   ② 整体 reels + 安卓新版本号
     *   ③ 整体 reels + 安卓旧版本号
     * 另外，主 id "答了但没内容"时，会用**备选 id** 把 ① 再试一遍（见下面第二段）。
     *
     * **第 4 个候选（`/feed/user/<id>/story/`）在这一版 IG 上已经死了，删掉了**：
     * 用户回传的诊断文件里，它对 5 位不同用户**一律回 `http-400`（42 字节 JSON）** ——
     * 也就是每次失败都白打一发，还把一条误导性的 400 写进轨迹（让人以为"id 不对"）。
     * 真正有用的那条始终是 `reels_media`。
     */
    // 候选 id：主 id 在前，后面是备选（去重、封顶，免得失败路径把请求发爆）。
    const ids: Array<string> = [userId];
    for (let index: number = 0; index < altIds.length && ids.length < NativeStories.ID_TRY_MAX; index++) {
      const one: string = altIds[index].trim();
      if (one.length > 0 && ids.indexOf(one) < 0) {
        ids.push(one);
      }
    }
    const reelUrlOf = (id: string): string =>
      `${SITE}/api/v1/feed/reels_media/?reel_ids=${encodeURIComponent(id)}&source=raven`;
    const reelUrl: string = reelUrlOf(userId);
    /*
     * 候选 URL（三条，都是同一条路径的不同**主机/身份**组合）：
     *   ① `www.instagram.com` + 网页身份（网页自己那条，最常成）；
     *   ② `www.instagram.com` + 安卓身份（换客户端指纹）；
     *   ③ **`i.instagram.com` + 安卓身份** —— 官方 App 打的就是这个主机。
     *
     * 为什么要加第 ③ 条（用户提示"测试人在内地挂 VPN、我这边香港网络正常"之后再补的）：
     * IG 对 `reels_media` 这类私有接口会按**来源**判定，两条链路的差异（VPN 出口 IP、
     * 透明代理是否改写头）恰好是"网页主机 + 网页身份"最容易踩的；而 `i.instagram.com`
     * 是 App 端点，走的是另一套网关，值得单独试一发。
     */
    const appHostUrl: string =
      `https://i.instagram.com/api/v1/feed/reels_media/?reel_ids=${encodeURIComponent(userId)}&source=raven`;
    const urls: Array<string> = [reelUrl, reelUrl, appHostUrl];
    const identities: Array<number> =
      [IDENTITY_WEB, IDENTITY_ANDROID_NEW, IDENTITY_ANDROID_NEW];
    /*
     * **已经"答过但没内容"的 URL**：同一条 URL 再换身份打一遍，拿回来的是同一份数据。
     *
     * 为什么记（这就是用户报的"点开这条快拍没取到"里最不该发生的那部分）：
     * 前三个候选是**同一个 URL 换三种身份**。用户点开的那位如果此刻确实没有可看的快拍
     * （全过期 / 全部已看完 / IG 就回了个空壳），原来会把这条 URL 再打两发 ——
     * 白发不说，还正撞在 IG 对这个接口的节流上，把"偶尔一次没内容"放大成"接下来一片都点不开"。
     * 第 4 个候选是**另一条 URL**（老的单用户 story 接口），它仍然照试（可能真有内容）。
     */
    const answeredEmpty: Array<string> = [];
    NativeStories.resetTrace(userId);
    NativeStories.answeredJson = false;
    // 复位上一次留下的具体原因：不然"这一发到底为什么失败"会被上一次的 detail 混淆。
    NativeStories.detail = '-';
    // "补抓 REST 模板再重试"一轮只做一次（见 wantsClaimRefresh）。
    let claimRetried: boolean = false;
    for (let at: number = 0; at < urls.length; at++) {
      // 冷却期内不再往下试（见 core/ApiThrottle.STORIES）：再打只会把窗口拖长。
      const cooled: string = NativeStories.cooling();
      if (cooled.length > 0) {
        NativeStories.detail = cooled;
        NativeStories.note(userId, `try=${at} 跳过：stories 限流 ${cooled}`);
        hilog.warn(DOMAIN, TAG, 'reel stopped: stories throttled %{public}dmin left',
          ApiThrottle.remainingMinutes(ApiThrottle.STORIES));
        break;
      }
      if (answeredEmpty.indexOf(urls[at]) >= 0) {
        NativeStories.note(userId, `try=${at} 跳过：同 URL 已经答过但没内容`);
        continue;
      }
      let text: string | null = await NativeStories.fetchText(urls[at], identities[at], userId);
      /*
       * **5xx 且手上没有 `x-ig-www-claim` → 让宿主去驱动一次隐藏网页把 REST 模板抓下来，再重试这一发。**
       *
       * 这是用户那台设备的修法：他们的 500 正是"头里缺 claim"（见 fetchText 的说明）。
       * 抓模板要点时间（秒级）而且会动共用的隐藏网页，所以**只在真的撞上 5xx 时做一次**，
       * 不是每次开快拍都做。
       */
      if (text === null && !claimRetried && NativeStories.wantsClaimRefresh()) {
        claimRetried = true;
        NativeStories.note(userId,
          '  → 5xx 且没有 claim：抓一次 REST 模板（拿 x-ig-www-claim / x-instagram-ajax）后重试');
        try {
          const refresh: (() => Promise<void>) | null = NativeStories.claimRefresher;
          if (refresh !== null) {
            await refresh();
          }
        } catch (error) {
          NativeStories.note(userId, `  → 抓模板失败：${(error as Error).message ?? '-'}`);
        }
        text = await NativeStories.fetchText(urls[at], identities[at], userId);
      }
      if (text === null) {
        // 传输层没拿到（非 200 / 非 JSON / 抛 / 没会话）：换个身份再试是有意义的。
        NativeStories.note(userId, `try=${at} id=${NativeStories.identityName(identities[at])} `
          + `url=${NativeStories.tailOf(urls[at])} → 传输失败 detail=${NativeStories.detail}`);
        continue;
      }
      NativeStories.answeredJson = true;
      const reel: StoryReel | null = NativeStories.parseReel(text, userId);
      if (reel !== null && reel.items.length > 0) {
        NativeStories.detail = '-';
        NativeStories.note(userId, `try=${at} id=${NativeStories.identityName(identities[at])} `
          + `url=${NativeStories.tailOf(urls[at])} → ok items=${reel.items.length}`);
        hilog.info(DOMAIN, TAG,
          'reel ok try=%{public}d id=%{public}s uid=%{public}s n=%{public}d video=%{public}s size=%{public}dx%{public}d',
          at, NativeStories.identityName(identities[at]), userId, reel.items.length,
          `${reel.items[0].isVideo()}`, reel.items[0].width, reel.items[0].height);
        return reel;
      }
      /*
       * 服务端**答了**（200 + JSON）但这条用户没有可播的媒体：
       * 记住这条 URL，别再换身份重打（见 answeredEmpty 的说明）。
       * 结构没认出来（字段名变了）和"真的没内容"在这里分不开 —— 两种都只能记下来，
       * 而前者需要的现场（响应开头）就在这一行日志 / 轨迹里，换身份重打也救不了它。
       */
      answeredEmpty.push(urls[at]);
      NativeStories.note(userId, `try=${at} id=${NativeStories.identityName(identities[at])} `
        + `url=${NativeStories.tailOf(urls[at])} → 答了但没媒体 items=${reel === null ? -1 : reel.items.length} `
        + `head=${text.substring(0, 160).replace(/[\r\n]+/g, ' ')}`);
      hilog.info(DOMAIN, TAG, 'reel empty try=%{public}d id=%{public}s body=%{public}s',
        at, NativeStories.identityName(identities[at]),
        text.substring(0, 180).replace(/[\r\n]+/g, ' '));
      /*
       * **就在这一发之后试备选 id**（用户报的"只有部分用户点开提示没取到（原因 empty）"）。
       *
       * 为什么放在这里而不是整个循环之后：第一发（网页身份 + `reels_media`）是**最像正主**的那一发，
       * 它"答了空"、而我们手上还有同一托盘条目里的其它 id 字段 —— 这时换 id 收益最大、代价最小（1 发）。
       * 放到循环之后再试的话，会先把"换身份"的两发和"老接口"那发打完（白打三发）才轮到它。
       */
      if (at === 0 && ids.length > 1 && NativeStories.answeredJson) {
        const viaAlt: StoryReel | null =
          await NativeStories.tryAltIds(ids, answeredEmpty);
        if (viaAlt !== null) {
          NativeStories.detail = '-';
          return viaAlt;
        }
      }
    }
    /*
     * **第三段：改用网页自己那条快拍查询回放**（见 storyViaTemplate）。
     *
     * 这一步是用户那台设备的正解：`reels_media` 在他们会话上被 IG 回 500（头/cookie/claim
     * 都验证过是全的），而网页那条路是通的（托盘就是网页抓的）。
     */
    const viaPage: StoryReel | null = await NativeStories.storyViaTemplate(userId, username);
    if (viaPage !== null && viaPage.items.length > 0) {
      return viaPage;
    }
    /*
     * **最后一道：用托盘那份数据自己拼一条**（不需要任何请求，见 reelFromTrayNode）。
     *
     * 放在所有网络候选之后：能拿到"正经那一份"当然最好（有全部条目、有视频地址），
     * 但拿不到时，**手上这份托盘条目自带的 media** 远好过弹一句"没取到"并把整层收掉。
     * 走这条路时 `detail` 记 `-tray`，报告与日志里一眼能看出"这次是托盘兜底顶上的"。
     */
    const fromTray: StoryReel | null = NativeStories.reelFromTrayNode(userId);
    if (fromTray !== null && fromTray.items.length > 0) {
      NativeStories.detail = '-tray';
      NativeStories.note(userId, `托盘兜底：条目自带 items=${fromTray.items.length}`);
      hilog.info(DOMAIN, TAG, 'reel ok via tray node uid=%{public}s n=%{public}d',
        userId, fromTray.items.length);
      return fromTray;
    }
    /*
     * **收尾：只在"服务端真的答过"时才把原因写成 `empty`**（这里以前有个 bug，见下）。
     *
     * 用户回传的诊断文件把这个 bug 抓了出来：`detail=empty` 而轨迹里明明是
     * `reels_media` **500**、`user/<id>/story` **400** —— 因为原来这一行无条件把
     * `detail` 覆盖成了 `empty`（只要不是 throttled）。于是界面一直说"没取到（原因 empty）"，
     * 而真相是**请求根本没成功**，我们却在往"这条快拍没内容"的方向查。
     *
     * 现在：只有"某条候选拿到了 200 + JSON、只是没有媒体"才算 `empty`（那才是真的没内容）；
     * 一条候选都没答上时，**保留具体原因**（http-500 / http-400 / throw:… / no-session）。
     */
    if (NativeStories.answeredJson) {
      NativeStories.detail = 'empty';
    } else if (NativeStories.detail === '-') {
      // 一条候选都没打（全被跳过）—— 给个能区分于 empty 的说法。
      NativeStories.detail = 'no-answer';
    }
    /*
     * 真的失败了：**顺手量一下到 IG 的基本链路**（见 probeNetwork）。
     * 这一发只取 robots.txt、不需要会话，成本极低；但它能把"链路不通（VPN/网络）"与
     * "链路通、服务端按来源拒（IP 被标记 / 代理改写头）"分开 —— 这正是用户问的那个问题。
     */
    if (NativeStories.detail !== 'challenge') {
      await NativeStories.probeNetwork();
      NativeStories.note(userId, `  net=${NativeStories.netProbe}`);
    }
    return null;
  }

  /** URL 里 `/api/` 之后那一段（轨迹里够用，又不至于把整条 URL 抄进去）。 */
  private static tailOf(url: string): string {
    const at: number = url.indexOf('/api/');
    return at >= 0 ? url.substring(at) : url;
  }

  /**
   * **换备选 id 再问一遍**（见 `reel` 里调用点的说明）。
   *
   * 每个备选 id 试两条 URL（`reels_media` 与老的 `user/<id>/story`），跳过已经答过空的那条；
   * 命中就返回，全空返回 null（轨迹里留着每一发的现场）。
   *
   * @param ids 候选 id（`ids[0]` 是主 id，从 `ids[1]` 开始才是备选 —— 主 id 已经问过了）。
   */
  private static async tryAltIds(ids: Array<string>,
                                 answeredEmpty: Array<string>): Promise<StoryReel | null> {
    const mainId: string = ids[0];
    for (let index: number = 1; index < ids.length; index++) {
      const alts: Array<string> = [
        `${SITE}/api/v1/feed/reels_media/?reel_ids=${encodeURIComponent(ids[index])}&source=raven`
      ];
      for (let at: number = 0; at < alts.length; at++) {
        if (answeredEmpty.indexOf(alts[at]) >= 0) {
          continue;
        }
        const cooled: string = NativeStories.cooling();
        if (cooled.length > 0) {
          NativeStories.detail = cooled;
          NativeStories.note(mainId, `alt=${ids[index]} 跳过：stories 限流 ${cooled}`);
          return null;
        }
        const text: string | null = await NativeStories.fetchText(alts[at], IDENTITY_WEB, mainId);
        if (text === null) {
          NativeStories.note(mainId,
            `alt=${ids[index]} url=${NativeStories.tailOf(alts[at])} → 传输失败`);
          continue;
        }
        const reel: StoryReel | null = NativeStories.parseReel(text, ids[index]);
        if (reel !== null && reel.items.length > 0) {
          NativeStories.note(mainId, `alt=${ids[index]} url=${NativeStories.tailOf(alts[at])} `
            + `→ ok items=${reel.items.length}（主 id=${mainId} 为空）`);
          hilog.info(DOMAIN, TAG, 'reel ok via alt id=%{public}s（主 id=%{public}s 为空）n=%{public}d',
            ids[index], mainId, reel.items.length);
          return reel;
        }
        answeredEmpty.push(alts[at]);
        NativeStories.note(mainId, `alt=${ids[index]} url=${NativeStories.tailOf(alts[at])} `
          + `→ 答了但没媒体 head=${text.substring(0, 120).replace(/[\r\n]+/g, ' ')}`);
      }
    }
    return null;
  }

  /** 快拍这一族的退避闸门（见 core/ApiThrottle.STORIES）。 */
  private static cooling(): string {
    if (!ApiThrottle.blocked(ApiThrottle.STORIES)) {
      return '';
    }
    return `throttled-${ApiThrottle.remainingMinutes(ApiThrottle.STORIES)}min`;
  }

  /** 身份的名字（只给日志用）。 */
  private static identityName(identity: number): string {
    if (identity === IDENTITY_ANDROID_NEW) {
      return 'android-new';
    }
    if (identity === IDENTITY_ANDROID_OLD) {
      return 'android-old';
    }
    return 'web';
  }

  /**
   * 发一发 GET，拿响应文本；非 200 / 不是 JSON 给 null。
   *
   * @param identity 用哪套身份（见 ANDROID_UA 的说明）：网页头 / 安卓新版本号 / 安卓旧版本号。
   * @param uid 这一次是为哪位用户发的（轨迹按 uid 分开存，见 traces）。
   */
  private static async fetchText(url: string, identity: number, uid: string): Promise<string | null> {
    /*
     * **头要用"给 `/api/v1/…` 的那套"**（用户回传的诊断文件定案的）。
     *
     * 原来这里用的是 `NativeFeed.sessionOrBrowserHeaders()` —— 那是**信息流 GraphQL 模板**的头
     * （清单里带着 `x-fb-friendly-name` / `x-root-field-name` / `x-fb-lsd`），
     * **没有 `x-ig-www-claim`、也没有 `x-instagram-ajax`**。而 `reels_media` 是**网页私有 REST**，
     * 网页自己发它时是带 claim 的。真机证据：出问题那台设备的轨迹里
     * `code=500 head={"message":"很抱歉，出错了，请重试。","status_code":"500","status":"fail"}`
     * 而头清单里恰好缺 claim。
     *
     * `RestSession.headers()` 就是为这条准备的：优先用**网页抓来的 REST 模板**那份头
     * （claim / instagram-ajax 都在它身上），缺 `x-instagram-ajax` 时还会从页面现读
     * （`WebTokens.rev`）。拿不到才退回信息流那套。
     */
    const restHeaders: Record<string, string> = await RestSession.headers();
    const headers: Record<string, string> = Object.keys(restHeaders).length > 0
      ? restHeaders : await NativeFeed.sessionOrBrowserHeaders();
    NativeStories.lastHadClaim = (headers['x-ig-www-claim'] ?? '').length > 0;
    NativeStories.lastHadAjax = (headers['x-instagram-ajax'] ?? '').length > 0;
    if (Object.keys(headers).length === 0) {
      NativeStories.detail = 'no-session';
      NativeStories.note(uid, `  http id=${NativeStories.identityName(identity)} `
        + `url=${NativeStories.tailOf(url)} → 没有会话（头都拿不到）`);
      return null;
    }
    if (identity === IDENTITY_ANDROID_NEW) {
      headers['user-agent'] = ANDROID_UA_NEW;
      headers['x-ig-app-id'] = ANDROID_APP_ID;
    } else if (identity === IDENTITY_ANDROID_OLD) {
      headers['user-agent'] = ANDROID_UA;
      headers['x-ig-app-id'] = ANDROID_APP_ID;
    }
    const request: http.HttpRequest = http.createHttp();
    /*
     * **老路径也要过限速闸门**（见 ApiThrottle.acquire）。
     *
     * 这一发是"一位用户 × 最多三种身份"里的那一发，预取 5 位就是最多 15 发 —— 与移动端那条
     * 新路是同一种连发形态，限流不认我们内部走的是哪条路。优先级给 WARM（预取是后台行为）；
     * 用户点开那一发在 `StoryCache.fetch` 里已经用交互优先级发起了（移动端那条），
     * 走到这里说明移动端那条没成，此时再抢优先级意义不大。
     */
    await ApiThrottle.acquire(ApiThrottle.warm());
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
      const head: string = text.length > 0 ? text.charAt(0) : '';
      const json: boolean = head === '{' || head === '[';
      hilog.info(DOMAIN, TAG, 'reel http id=%{public}s %{public}s code=%{public}d json=%{public}s len=%{public}d',
        NativeStories.identityName(identity), url.substring(url.indexOf('/api/')),
        response.responseCode, `${json}`, text.length);
      /*
       * 轨迹里**连响应体开头一起记**。
       *
       * 用户回传的诊断文件里，失败轨迹只有 `code=500 len=62`、没有体 —— 而那个 62 字节的 JSON
       * 才是唯一能说明"IG 为什么 500"的东西（是 `{"message":…,"status":"fail"}`？还是
       * `{"require_login":…}`？）。没有它只能猜，所以这里补上（截断 200 字符够看）。
       */
      NativeStories.note(uid, `  http id=${NativeStories.identityName(identity)} `
        + `url=${NativeStories.tailOf(url)} code=${response.responseCode} json=${json} len=${text.length}`
        + ` head=${text.substring(0, 200).replace(/[\r\n]+/g, ' ')}`);
      if (response.responseCode !== 200 || !json) {
        /*
         * **限流要认出来**（见 core/ApiThrottle.STORIES）：IG 的节流响应是
         * `200 + {"errors":[{"message":"Rate limit exceeded","code":1675004}]}`，
         * 只看状态码会被当成"成功但没内容"，于是候选一个个接着打（每位最多 4 发）、
         * 托盘预缓存再乘 5 位 —— 越打窗口越长，用户那边就是"点开快拍没取到、页面自己收起"。
         */
        if (ApiThrottle.looksLimited(text)) {
          ApiThrottle.note(ApiThrottle.STORIES);
          NativeStories.detail = `throttled-${ApiThrottle.remainingMinutes(ApiThrottle.STORIES)}min`;
          hilog.warn(DOMAIN, TAG, 'reel rate limited id=%{public}s → back off %{public}dmin',
            NativeStories.identityName(identity),
            ApiThrottle.remainingMinutes(ApiThrottle.STORIES));
          return null;
        }
        NativeStories.detail = `http-${response.responseCode}${json ? '' : '/non-json'}`;
        /*
         * **`challenge_required` 要单独认出来**（真机证据：安卓身份那条回的正是
         * `{"message":"challenge_required","challenge":{...,"lock":true}}`）。
         *
         * 这不是"请求写错了"，而是 **IG 要求这个账号先完成安全验证** —— 那种状态下私有接口会被
         * 一律拒掉（而网页 GraphQL 可能照常，所以"网页能看、原生 500"这组现象正好对上）。
         * 认出来之后界面就能直接告诉用户"去网页里验证一下"，而不是丢一句 `http-500`。
         */
        if (text.indexOf('challenge_required') >= 0) {
          NativeStories.detail = 'challenge';
          NativeStories.note(uid, '    → 服务端要求 challenge（安全验证），不是请求写错');
          /*
           * 同时记进**全局的验证台账**（见 core/mobileapi/MobileChallenge）：
           * 托盘这边也能撞上挑战（真机证据就是 `reels_media` 回的），而界面上的
           * 「去验证」横幅只认那个台账 —— 不记的话用户只会看到"托盘一直转圈"。
           */
          MobileChallenge.note(text);
        }
        /*
         * 非 200 时把**头名清单 + cookie 名清单**也记进轨迹。
         *
         * 头名：`reels_media` 是网页私有接口，认 `x-ig-www-claim` / `x-instagram-ajax` /
         * `x-csrftoken`。用户回传的文件里正是"500 而头清单里没有 claim"，一眼就能对上。
         * cookie 名：原生请求用的是 Cookie 罐快照；如果快照里少了 `sessionid` / `ds_user_id`
         * 这类关键 cookie（比如会话是在 App 内嵌网页里登的、快照不完整），也是同样的后果。
         * **只记名字，不记值**（值里有会话材料）。
         */
        NativeStories.note(uid, `    hdr=[${Object.keys(headers).sort().join(',')}]`);
        NativeStories.note(uid,
          `    cookie-names=[${NativeStories.cookieNames(headers['cookie'] ?? '')}]`
          + ` claim=${NativeStories.lastHadClaim} ajax=${NativeStories.lastHadAjax}`);
        hilog.info(DOMAIN, TAG, 'reel body=%{public}s',
          text.substring(0, 160).replace(/[\r\n]+/g, ' '));
        return null;
      }
      // 200 + JSON 也可能是节流（IG 把文案放在 errors 里）：这一发照样要记账。
      if (ApiThrottle.looksLimited(text)) {
        ApiThrottle.note(ApiThrottle.STORIES);
        NativeStories.detail = `throttled-${ApiThrottle.remainingMinutes(ApiThrottle.STORIES)}min`;
        hilog.warn(DOMAIN, TAG, 'reel rate limited (json) id=%{public}s → back off %{public}dmin',
          NativeStories.identityName(identity),
          ApiThrottle.remainingMinutes(ApiThrottle.STORIES));
        return null;
      }
      return text;
    } catch (error) {
      NativeStories.detail = `throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60);
      hilog.warn(DOMAIN, TAG, 'reel failed: %{public}s', NativeStories.detail);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
      // 放闸：成败、提前 return 都要放到（拿到 acquire 就必须 release，见那里的说明）。
      ApiThrottle.release();
    }
  }

  /** 响应文本 → 某个用户的快拍（media 数组按结构找，见文件头）。 */
  private static parseReel(text: string, userId: string): StoryReel | null {
    const root: Record<string, Object> = JsonRead.parse(text);
    return NativeStories.reelOf(root, userId, true);
  }

  /**
   * 任意"装着这一位快拍的 JSON 对象" → StoryReel（`parseReel` 与**托盘兜底**共用）。
   *
   * 两条接口的外壳不一样：
   *   · `/feed/reels_media/`       → `{reels: {"<uid>": {items: […]}}}`
   *   · `/feed/user/<uid>/story/`  → `{reel: {items: […]}}`
   *   · **托盘条目自己**            → `{user:{…}, items: […]}`（见 reelFromTrayNode）
   * 所以外壳不认键名，直接从根上按"结构像媒体"的数组找（findMediaArray）。
   *
   * @param logMiss 认不出结构时要不要打键树（托盘兜底那条**不打**：它失败很正常，别刷日志）。
   */
  private static reelOf(root: Record<string, Object>, userId: string,
                        logMiss: boolean): StoryReel | null {
    const nodes: Array<Object> | null = NativeStories.findMediaArray(root, 0);
    if (nodes === null) {
      if (logMiss) {
        NativeStories.logMiss(root, 'reel-no-media-array');
      }
      return null;
    }
    const items: Array<StoryItem> = [];
    for (let index: number = 0; index < nodes.length; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(nodes[index]);
      if (node === null) {
        continue;
      }
      const item: StoryItem | null = NativeStories.itemOf(node);
      if (item !== null) {
        items.push(item);
      }
    }
    if (items.length === 0) {
      return null;
    }
    let username: string = '';
    let avatar: string = '';
    const first: Record<string, Object> | null = JsonRead.asRecord(nodes[0]);
    if (first !== null) {
      const user: Record<string, Object> | null = JsonRead.recordOf(first, 'user');
      if (user !== null) {
        username = NativeStories.pickStr(user, NAME_KEYS, '');
        avatar = NativeStories.avatarOf(user);
      }
    }
    return new StoryReel(userId, username, avatar, items);
  }

  /**
   * **托盘兜底**：拿托盘响应里这一条条目自己带的 media 拼一个 StoryReel（**不需要任何请求**）。
   *
   * 为什么要有它：有些条目 IG 的 `reels_media` 就是不给内容（刚过期但托盘还留着、
   * 私密号未关注、条目来自别的分区……），但**托盘响应里本来就带着这一位的 media**
   * （解析托盘时我们就在数 `items`）。与其弹一句"没取到"，不如把手上这份用起来 ——
   * 用户至少能点开看，而不是整层被收掉。
   */
  static reelFromTrayNode(userId: string): StoryReel | null {
    const raw: string | undefined = NativeStories.nodeRaw.get(userId);
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    try {
      const node: Record<string, Object> = JsonRead.parse(raw);
      return NativeStories.reelOf(node, userId, false);
    } catch (error) {
      return null;
    }
  }

  /** 找"媒体数组"：元素看着像一条 media 的那个数组（广度优先，深度封顶）。 */
  private static findMediaArray(host: Record<string, Object>, depth: number): Array<Object> | null {
    if (depth > 4) {
      return null;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null && NativeStories.looksLikeMedia(first)) {
          return list;
        }
      }
    }
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: Array<Object> | null = NativeStories.findMediaArray(child, depth + 1);
        if (hit !== null) {
          return hit;
        }
      }
    }
    return null;
  }

  /** 一个对象"像不像一条 media"（有图候选 / 有图地址 / 有 media_type）。 */
  private static looksLikeMedia(node: Record<string, Object>): boolean {
    if (JsonRead.recordOf(node, 'image_versions2') !== null) {
      return true;
    }
    if (JsonRead.strOf(node, 'display_url').length > 0) {
      return true;
    }
    for (let at: number = 0; at < MEDIA_TYPE_KEYS.length; at++) {
      if (JsonRead.has(node, MEDIA_TYPE_KEYS[at])) {
        return true;
      }
    }
    return false;
  }

  /** 一条 media → StoryItem（认不出来给 null）。 */
  private static itemOf(node: Record<string, Object>): StoryItem | null {
    let image: string = '';
    /*
     * 顺手把**这张图（或视频封面）的真实宽高**记下来：媒体区的比例要按它算，
     * 不然媒体区定死 9:16 而媒体是别的比例时，`Contain` 会在卡片里留出黑边（用户报过）。
     */
    let width: number = JsonRead.numOf(node, 'original_width');
    let height: number = JsonRead.numOf(node, 'original_height');
    const versions: Record<string, Object> | null = JsonRead.recordOf(node, 'image_versions2');
    if (versions !== null) {
      const list: Array<Object> = JsonRead.arrayOf(versions, 'candidates');
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null) {
          image = JsonRead.strOf(first, 'url');
          if (width <= 0 || height <= 0) {
            width = JsonRead.numOf(first, 'width');
            height = JsonRead.numOf(first, 'height');
          }
        }
      }
    }
    if (image.length === 0) {
      image = NativeStories.pickStr(node, ['display_url', 'image_url', 'thumbnail_url'], '');
    }
    let video: string = '';
    const videos: Array<Object> = JsonRead.arrayOf(node, 'video_versions');
    if (videos.length > 0) {
      const first: Record<string, Object> | null = JsonRead.asRecord(videos[0]);
      if (first !== null) {
        video = JsonRead.strOf(first, 'url');
      }
    }
    if (image.length === 0 && video.length === 0) {
      return null;
    }
    let durationMs: number = IMAGE_DURATION_MS;
    if (video.length > 0) {
      let seconds: number = 0;
      for (let at: number = 0; at < DURATION_KEYS.length; at++) {
        if (JsonRead.has(node, DURATION_KEYS[at])) {
          seconds = JsonRead.numOf(node, DURATION_KEYS[at]);
          break;
        }
      }
      // 时长离谱（0 / 超大）就按默认走：宁可多停一会儿，也别让进度条一闪而过。
      if (seconds > 0.2 && seconds < 120) {
        durationMs = Math.round(seconds * 1000);
      }
    }
    const id: string = NativeStories.pickStr(node, ID_KEYS, '');
    const takenAt: number = JsonRead.numOf(node, 'taken_at');
    return new StoryItem(id.length > 0 ? id : `story-${takenAt}`, image, video, takenAt, durationMs,
      width, height);
  }

  /** 头像地址：先试直接的几个键，再试 `hd_profile_pic_url_info.url`。 */
  private static avatarOf(host: Record<string, Object>): string {
    const direct: string = NativeStories.pickStr(host, AVATAR_KEYS, '');
    if (direct.length > 0) {
      return direct;
    }
    const hd: Record<string, Object> | null = JsonRead.recordOf(host, 'hd_profile_pic_url_info');
    return hd === null ? '' : JsonRead.strOf(hd, 'url');
  }
}
