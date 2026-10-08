/*
 * 接口登记表：网页里那些「可以原样回放的请求模板」。
 *
 * 为什么需要它：原生想知道"这个页面能不能直接要数据"，而不是靠猜 DOM、或者滚页面去逼
 * 网页自己发请求。模板**本体留在网页里**（那才是最新的 —— 带着 lsd / fb_dtsg 这类令牌），
 * 原生这边只留「有哪些操作、方法/URL、请求体多长、可调的变量名」，够用来判断
 * "能不能回放、要传哪些旋钮"。
 *
 * 数据来源是 REPLAY_INDEX_SCRIPT（见 WebScripts）：NETWORK_WATCHER 会把每一条带
 * x-fb-friendly-name 的请求存进 `window.__ogReplay[操作名]`，信息流快路径只用了其中
 * timeline 那一条，这里把**全部**登记下来 —— reels / 私信 / 搜索 / 个人页以后照同一套接。
 *
 * 索引只回元信息、不回请求体与响应体：一轮页面几十条请求，带体过桥是纯开销。
 *
 * ## 模板的三种来源（优先级从高到低）
 *   1. 这次会话里从网页抓到的（`capture`）——最新、doc_id 与令牌都是当前的；
 *   2. 上次落盘的那份（preferences）——跨重启，24 小时内可用；
 *   3. **包里预置的那份**（resources/rawfile/api_templates.json，见 seedBundled）——
 *      全新安装 / 落盘被清掉时用，省掉"先让网页跑一趟再倒模板"那几秒到十几秒的空窗
 *      （需求："模板空的情况下从网页获取的太慢了，把抓到的模板预先封装进 app 里"）。
 *      预置那份**只补没有的**，而且不带任何会话令牌。
 *
 * ### 预置那份怎么来的（要更新时照着做）
 *   1. 在登录好的设备上拉出落盘文件：
 *      `hdc file recv /data/app/el2/100/base/com.fanha.instarmony/haps/entry/preferences/instarmony_api_templates tpl.xml`
 *   2. 合并历次拉到的（同一个 op 取 `at` 最新的那份），并**剥掉会话令牌**
 *      （cookie / x-csrftoken / x-fb-lsd / x-fb-dtsg / x-ig-www-claim）、跳过
 *      `rest_/api/v1/discover/ayml/`（它的 rollout/claim 头是会话级的，预置反而更差；
 *      REST 那条路本来就有"只用 Cookie 罐"的兜底，见 RestSession），
 *      写成一行 JSON 存到 resources/rawfile/api_templates.json。
 *   生成脚本：`.tmp/make_bundle.js`（`node make_bundle.js <放 tpl*.xml 的目录> <输出路径>`）。
 *   3. 重新编译安装即可；启动日志里 `templates seeded n=<条数>` 能看到它生效。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { InstagramPageBridge } from './PageBridge';
import {
  replayApiScript,
  replayDigestScript,
  replayStoredApiScript,
  replayTemplatesScript,
  REPLAY_INDEX_SCRIPT
} from './WebScripts';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ApiRegistry';
/** 模板落盘的 preferences 文件名 / 键（跨进程重启要用，见 persistTemplates）。 */
const TEMPLATE_STORE: string = 'instarmony_api_templates';
const TEMPLATE_KEY: string = 'templates_v1';
/**
 * 「不走网页」那条路（原生直接发 HTTP）能接受的模板年龄（毫秒）。
 *
 * 比 TEMPLATE_TTL_MS（10 分钟，给页面内回放用）宽得多：请求体里真正会过期的是
 * `lsd` / `fb_dtsg` 这类令牌，而首页信息流这条 GraphQL 只认 cookie + csrftoken +
 * doc_id + variables，实测隔夜还能用；给 24 小时，失败了自然退回网页那条路。
 */
const NATIVE_TEMPLATE_TTL_MS: number = 86400000;
/** 落盘时最多存几份模板、单份请求体上限（preferences 不该被一个大 JSON 占满）。 */
const PERSIST_MAX_ITEMS: number = 24;
const PERSIST_MAX_BODY: number = 20000;
/**
 * **预置模板**的文件名（在 resources/rawfile 下，随包发布）。
 *
 * 需求："模板空的情况下从网页获取的太慢了，把抓到的模板预先封装进 app 里" ——
 * 全新安装（或落盘那份被清掉）时，原来必须先让隐藏网页跑一趟、
 * 等它自己发出那几条请求、再倒模板（几秒到十几秒），这期间列表是空的。
 * 现在包里带一份上次抓到的模板（见 seedBundled），一启动就能直接发原生请求；
 * 万一预置那份的 doc_id 已经过期，各条路的兜底照样会去网页重新抓一份并覆盖它。
 */
const SEED_FILE: string = 'api_templates.json';

/**
 * 索引缓存时长（毫秒）。
 *
 * 不长不短：页面重载/翻页会往 `__ogReplay` 里加东西，但索引本身也要过一次桥，
 * 所以按 TTL 缓存；需要立刻看最新的（例如判断"评论模板到没到"）就 sync(true)。
 */
const INDEX_TTL_MS: number = 20000;
/** 拉索引的时间上限。 */
const INDEX_TIMEOUT_MS: number = 8000;
/**
 * 通用回放的时间上限。
 *
 * 页面里的 fetch 自己 9 秒中止，这里留点余量 —— 别让桥先超时、把页面的请求留在半路。
 */
const REPLAY_TIMEOUT_MS: number = 12000;
/** 响应体默认回传上限（字符）。 */
const REPLAY_MAX_BYTES: number = 200000;
/** 日志里最多列几个操作名。 */
const LOG_NAMES: number = 12;
/**
 * 存下来的模板能用多久（毫秒）。
 *
 * 模板里带着 `lsd` / `fb_dtsg` 这类令牌，放太久会失效；十分钟是个折中：够用户在
 * 信息流里翻几十条帖子，又不至于拿一份过期的去打请求。过期就重新导航抓一次。
 */
const TEMPLATE_TTL_MS: number = 600000;
/** 倒模板时最多拿几条、请求体最多带多少字符（带体过桥是少数几次，别拖太多）。 */
const TEMPLATE_MAX_ITEMS: number = 8;
const TEMPLATE_MAX_BODY: number = 8000;
/**
 * 浏览器/ fetch 禁止脚本设置、或者必须由浏览器自己填的请求头。
 *
 * 不去掉它们，轻则被忽略、重则整个 fetch 抛错（Cookie 就是典型）。
 */
const HEADER_BLOCK: Array<string> = ['cookie', 'content-length', 'host', 'origin', 'referer',
  'connection', 'accept-encoding', 'sec-fetch-dest', 'sec-fetch-mode', 'sec-fetch-site',
  'user-agent', 'te', 'trailer', 'transfer-encoding', 'upgrade'];

/** 索引里的一条接口（字段名对应 REPLAY_INDEX_SCRIPT 的返回）。 */
interface ApiIndexItemDto {
  n?: string;
  m?: string;
  u?: string;
  b?: number;
  v?: Array<string>;
}

/** 索引本身（字段名对应 REPLAY_INDEX_SCRIPT 的返回）。 */
interface ApiIndexDto {
  state?: string;
  n?: number;
  watch?: boolean;
  feed?: boolean;
  comment?: boolean;
  items?: Array<ApiIndexItemDto>;
  message?: string;
}

/** 一次回放的结果（字段名对应 replayApiScript 的返回）。 */
interface ReplayDto {
  state?: string;
  op?: string;
  http?: number;
  ms?: number;
  bytes?: number;
  trunc?: boolean;
  body?: string;
  message?: string;
  have?: string;
}

/** 倒模板时的一条（字段名对应 replayTemplatesScript 的返回）。 */
interface ReplayTemplateDto {
  n?: string;
  u?: string;
  m?: string;
  h?: Array<Array<string>>;
  b?: string;
  trunc?: boolean;
}

/** 倒模板的整包结果。 */
interface ReplayTemplatesDto {
  state?: string;
  n?: number;
  items?: Array<ReplayTemplateDto>;
  have?: string;
  message?: string;
}

/**
 * 落盘用的一份模板（字段名短，因为它要塞进 preferences）。
 *
 * `h` = 过滤后的请求头（页面内回放用），`rh` = 原样请求头（原生发 HTTP 用，见 ApiTemplate）。
 */
class StoredTemplateDto {
  readonly n: string;
  readonly m: string;
  readonly u: string;
  readonly h: Array<Array<string>>;
  readonly rh: Array<Array<string>>;
  readonly b: string;
  readonly at: number;

  constructor(name: string, method: string, url: string, headers: Array<Array<string>>,
              rawHeaders: Array<Array<string>>, body: string, at: number) {
    this.n = name;
    this.m = method;
    this.u = url;
    this.h = headers;
    this.rh = rawHeaders;
    this.b = body;
    this.at = at;
  }
}

/**
 * 存到原生侧的一份请求模板。
 *
 * 只留发请求必需的字段；**请求头要过滤**：Cookie / Content-Length / Host 这类浏览器自己会
 * 填、而且 fetch 明确禁止脚本设置的头必须去掉，否则不是被忽略就是直接抛错。
 *
 * `rawHeaders` 是**过滤前**的原样请求头，只给"原生自己发 HTTP"那条路用（见 core/NativeFeed）：
 * 那条路上没有浏览器替我们补 User-Agent / Origin / Referer，而这些头 Instagram 是认的
 * （少一个就可能被判成脚本请求）。页面内回放仍旧用过滤后的 `headers`。
 */
export class ApiTemplate {
  readonly name: string;
  readonly method: string;
  readonly url: string;
  readonly headers: Array<Array<string>>;
  readonly rawHeaders: Array<Array<string>>;
  readonly body: string;
  readonly at: number;

  constructor(name: string, method: string, url: string,
              headers: Array<Array<string>>, body: string,
              rawHeaders: Array<Array<string>> = [], at: number = 0) {
    this.name = name;
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.rawHeaders = rawHeaders.length > 0 ? rawHeaders : headers;
    this.body = body;
    this.at = at > 0 ? at : Date.now();
  }

  /** 注入脚本用的 JSON（就是 replayStoredApiScript 的 cfg 参数）。 */
  json(): string {
    return JSON.stringify(new TemplateWire(this.url, this.method, this.headers, this.body));
  }
}

/** 传给页面脚本的模板形状（字段名要短：它是拼进脚本里的）。 */
class TemplateWire {
  readonly u: string;
  readonly m: string;
  readonly h: Array<Array<string>>;
  readonly b: string;

  constructor(url: string, method: string, headers: Array<Array<string>>, body: string) {
    this.u = url;
    this.m = method;
    this.h = headers;
    this.b = body;
  }
}

/** 登记在案的一条接口。 */
export class ApiEntry {
  readonly name: string;
  readonly method: string;
  readonly url: string;
  readonly bodyLen: number;
  /** 请求体 variables 里的键：这些就是这条接口可调的旋钮。 */
  readonly vars: Array<string>;

  constructor(name: string, method: string, url: string, bodyLen: number, vars: Array<string>) {
    this.name = name;
    this.method = method;
    this.url = url;
    this.bodyLen = bodyLen;
    this.vars = vars;
  }

  /** 有没有这个旋钮（调用方据此决定要不要传分页/目标参数）。 */
  hasVar(name: string): boolean {
    return this.vars.indexOf(name) >= 0;
  }
}

/** 结构摘要的一次结果（字段名对应 replayDigestScript 的返回）。 */
interface DigestDto {
  state?: string;
  http?: number;
  ms?: number;
  n?: number;
  keys?: Array<string>;
  message?: string;
}

/** 结构摘要：一串 "路径=值预览" / "路径[] n=条数" 的短行。 */
export class DigestResult {
  readonly state: string;
  readonly http: number;
  readonly ms: number;
  readonly message: string;
  readonly lines: Array<string>;

  constructor(dto: DigestDto) {
    this.state = dto.state ?? 'error';
    this.http = dto.http ?? 0;
    this.ms = dto.ms ?? 0;
    this.message = dto.message ?? '';
    this.lines = dto.keys ?? [];
  }

  /** 拼成一行（日志/探针报告用）。 */
  text(): string {
    return this.lines.join(' | ');
  }
}

/** 一次回放的结果。state: ok / no-config / fetch-error / error。 */
export class ReplayResult {
  readonly state: string;
  readonly op: string;
  readonly http: number;
  readonly ms: number;
  readonly bytes: number;
  readonly truncated: boolean;
  readonly body: string;
  readonly message: string;
  /** no-config 时带上：页面当前认得哪些操作名。 */
  readonly have: string;

  constructor(dto: ReplayDto) {
    this.state = dto.state ?? 'error';
    this.op = dto.op ?? '';
    this.http = dto.http ?? 0;
    this.ms = dto.ms ?? 0;
    this.bytes = dto.bytes ?? 0;
    this.truncated = dto.trunc === true;
    this.body = dto.body ?? '';
    this.message = dto.message ?? '';
    this.have = dto.have ?? '';
  }

  isOk(): boolean {
    return this.state === 'ok';
  }
}

/** 预置模板的一条（就是这个 rawfile 的 JSON 形状）。 */
interface SeedTemplateDto {
  n?: string;
  m?: string;
  u?: string;
  h?: Array<Array<string>>;
  rh?: Array<Array<string>>;
  b?: string;
}

export class ApiRegistry {
  private static instance: ApiRegistry | null = null;
  private readonly bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
  private readonly map: Map<string, ApiEntry> = new Map<string, ApiEntry>();
  private order: Array<string> = [];
  private syncedAt: number = 0;
  /** 网页里"请求/响应上报"开关的状态（探针面板控制，纯诊断用）。 */
  private watchOn: boolean = false;
  private feedReady: boolean = false;
  private commentReady: boolean = false;
  /** 预置模板读过了没有（一次进程只读一次，见 seedBundled）。 */
  private static seededBundled: boolean = false;
  /** 上一次打过日志的操作名清单：只有变了才再打，免得每次同步刷一行。 */
  private lastLogged: string = '';
  /**
   * 从页面倒出来、存在原生侧的完整模板（操作名 → 模板）。
   *
   * 为什么非要存到这边：`window.__ogReplay` 只活在当前文档里，而本项目"打开网页"全是整页
   * `loadUrl` —— 读完评论回首页就把模板冲掉了，跨页面回放无从谈起（见 WebScripts 的说明）。
   */
  private readonly templates: Map<string, ApiTemplate> = new Map<string, ApiTemplate>();
  /** 模板落盘的 store（跨重启用；见 persistTemplates）。 */
  private static store: preferences.Preferences | null = null;
  private static loadedPersisted: boolean = false;

  static getInstance(): ApiRegistry {
    if (ApiRegistry.instance === null) {
      ApiRegistry.instance = new ApiRegistry();
    }
    return ApiRegistry.instance;
  }

  /**
   * 打开模板落盘文件并**把上次存下的模板读回内存**（幂等，可在页面起来时兜底调一次）。
   *
   * 为什么非要落盘：模板原来只在内存里（10 分钟 TTL），于是"冷启动直接发请求"这件事根本
   * 无从谈起 —— 每次冷启动都得先让网页跑起来、发一条请求，我们才拿到模板。
   * 落盘之后，上次成功抓到的模板这次开 app 就能直接用（见 core/NativeFeed）。
   */
  static init(context: common.Context): void {
    if (ApiRegistry.store !== null) {
      return;
    }
    try {
      ApiRegistry.store = preferences.getPreferencesSync(context, { name: TEMPLATE_STORE });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open template store failed: %{public}s', (error as Error).message);
      return;
    }
    const registry: ApiRegistry = ApiRegistry.getInstance();
    registry.loadPersisted();
    registry.seedBundled(context);
  }

  /**
   * 把**包里预置的模板**装进模板表（需求："模板空的情况下从网页获取的太慢了，把抓到的模板
   * 预先封装进 app 里"）。
   *
   * 规则简单但很关键：**只补没有的**。已经有的（落盘那份、或这次会话里刚抓到的）一律不动 ——
   * 预置那份是历史快照，doc_id 会随 IG 前端发版过期；把它压在真的抓来的模板上面，
   * 只会让"本来好用的那条"变成不好用。
   *
   * 时间戳盖成"现在"（而不是文件里那个历史时间）：模板的可用期是 NATIVE_TEMPLATE_TTL_MS
   * （24 小时），按历史时间盖的话一装好就已经过期、等于白带。真过期了就靠各条路的兜底去
   * 网页重抓一份覆盖它（见 FeedViewModel / ReelsViewModel 的冷路径）。
   *
   * 模板本体里**没有会话令牌**（生成时就把 cookie / x-csrftoken / x-fb-lsd 剥掉了，见
   * resources/rawfile 那份 JSON）：原生那条路自己会用 Cookie 罐里的 csrf 补上
   * （见 NativeFeed.buildHeaders）。
   */
  private seedBundled(context: common.Context): void {
    if (ApiRegistry.seededBundled) {
      return;
    }
    ApiRegistry.seededBundled = true;
    let text: string = '';
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(SEED_FILE);
      text = util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'seed skipped: %{public}s', (error as Error).message);
      return;
    }
    if (text.length === 0) {
      return;
    }
    let list: Array<SeedTemplateDto> = [];
    try {
      list = JSON.parse(text) as Array<SeedTemplateDto>;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'seed parse failed: %{public}s', (error as Error).message);
      return;
    }
    const added: Array<string> = [];
    for (let index: number = 0; index < list.length; index++) {
      const item: SeedTemplateDto = list[index];
      const name: string = (item.n ?? '').trim();
      const url: string = (item.u ?? '').trim();
      if (name.length === 0 || url.length === 0 || (item.b ?? '').length === 0) {
        continue;
      }
      if (this.templates.has(name)) {
        continue;
      }
      const headers: Array<Array<string>> = item.h ?? [];
      this.templates.set(name, new ApiTemplate(name, item.m ?? 'POST', url,
        headers, item.b ?? '', item.rh ?? headers));
      added.push(name);
    }
    if (added.length > 0) {
      hilog.info(DOMAIN, TAG, 'templates seeded n=%{public}d %{public}s',
        added.length, added.slice(0, LOG_NAMES).join('|'));
    } else {
      hilog.info(DOMAIN, TAG, 'templates seeded n=0 (all present) %{public}s',
        this.storedSummary());
    }
  }

  /** 把当前模板表写盘（只在真的有变化时调，见 capture）。 */
  private persistTemplates(): void {
    const store: preferences.Preferences | null = ApiRegistry.store;
    if (store === null) {
      return;
    }
    const out: Array<StoredTemplateDto> = [];
    const names: Array<string> = Array.from(this.templates.keys());
    // **按"最近抓到的"排**，而不是按插入顺序：落盘只有 PERSIST_MAX_ITEMS 个坑，
    // 而模板表里会攒下越来越多东西（信息流、reels、个人页、私信、通知、点赞/转发…
    // 实测就是这样把后面抓到的点赞/转发模板挤掉的 —— 它们的请求体还都很大）。
    // 新的模板一定比旧的有用：旧的 doc_id/令牌本来也会过期。
    const pool: Array<ApiTemplate> = [];
    for (let index: number = 0; index < names.length; index++) {
      const item: ApiTemplate | undefined = this.templates.get(names[index]);
      if (item === undefined || item.body.length > PERSIST_MAX_BODY) {
        continue;
      }
      pool.push(item);
    }
    pool.sort((a: ApiTemplate, b: ApiTemplate): number => b.at - a.at);
    for (let index: number = 0; index < pool.length && out.length < PERSIST_MAX_ITEMS; index++) {
      const item: ApiTemplate = pool[index];
      out.push(new StoredTemplateDto(item.name, item.method, item.url,
        item.headers, item.rawHeaders, item.body, item.at));
    }
    try {
      store.putSync(TEMPLATE_KEY, JSON.stringify(out));
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'templates persisted n=%{public}d', out.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'persist templates failed: %{public}s', (error as Error).message);
    }
  }

  /** 读回上次落盘的模板；只在第一次调用时真的读一次。 */
  private loadPersisted(): void {
    if (ApiRegistry.loadedPersisted) {
      return;
    }
    ApiRegistry.loadedPersisted = true;
    const store: preferences.Preferences | null = ApiRegistry.store;
    if (store === null) {
      return;
    }
    let list: Array<StoredTemplateDto> = [];
    try {
      const raw: string = store.getSync(TEMPLATE_KEY, '') as string;
      if (raw.length === 0) {
        return;
      }
      list = JSON.parse(raw) as Array<StoredTemplateDto>;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read templates failed: %{public}s', (error as Error).message);
      return;
    }
    let restored: number = 0;
    for (let index: number = 0; index < list.length; index++) {
      const item: StoredTemplateDto = list[index];
      const name: string = (item.n ?? '').trim();
      const url: string = (item.u ?? '').trim();
      if (name.length === 0 || url.length === 0) {
        continue;
      }
      this.templates.set(name, new ApiTemplate(name, item.m ?? 'POST', url,
        item.h ?? [], item.b ?? '', item.rh ?? [], item.at ?? 0));
      restored++;
    }
    if (restored > 0) {
      const shown: string = Array.from(this.templates.keys()).slice(0, LOG_NAMES).join('|');
      hilog.info(DOMAIN, TAG, 'templates restored n=%{public}d %{public}s', restored, shown);
    }
  }

  /**
   * 给"原生自己发 HTTP"用的模板：时效比页面内回放宽得多（见 NATIVE_TEMPLATE_TTL_MS）。
   */
  storedForNative(fragment: string): ApiTemplate | null {
    const now: number = Date.now();
    const exact: ApiTemplate | undefined = this.templates.get(fragment);
    if (exact !== undefined && now - exact.at < NATIVE_TEMPLATE_TTL_MS) {
      return exact;
    }
    const needle: string = fragment.toLowerCase();
    const names: Array<string> = Array.from(this.templates.keys());
    for (let index: number = 0; index < names.length; index++) {
      const item: ApiTemplate | undefined = this.templates.get(names[index]);
      if (item === undefined || now - item.at >= NATIVE_TEMPLATE_TTL_MS) {
        continue;
      }
      if (item.name.toLowerCase().indexOf(needle) >= 0) {
        return item;
      }
    }
    return null;
  }

  count(): number {
    return this.order.length;
  }

  names(): Array<string> {
    return this.order.slice(0);
  }

  entry(name: string): ApiEntry | null {
    const hit: ApiEntry | undefined = this.map.get(name);
    return hit === undefined ? null : hit;
  }

  /** 有没有名字里带这段文字的操作（不分大小写）。 */
  has(fragment: string): boolean {
    return this.find(fragment) !== null;
  }

  /** 名字里带这段文字的第一条（精确同名优先）。 */
  find(fragment: string): ApiEntry | null {
    const exact: ApiEntry | undefined = this.map.get(fragment);
    if (exact !== undefined) {
      return exact;
    }
    const needle: string = fragment.toLowerCase();
    for (let index: number = 0; index < this.order.length; index++) {
      const item: ApiEntry | undefined = this.map.get(this.order[index]);
      if (item !== undefined && item.name.toLowerCase().indexOf(needle) >= 0) {
        return item;
      }
    }
    return null;
  }

  /** 一行摘要：条数 + 两个关键模板 + 操作名（日志与探针报告都用它）。 */
  summary(): string {
    const shown: string = this.order.slice(0, LOG_NAMES).join("|");
    return `apis=${this.order.length} feed=${this.feedReady ? 'y' : 'n'} `
      + `comment=${this.commentReady ? 'y' : 'n'} watch=${this.watchOn ? 'y' : 'n'} ops=${shown}`;
  }

  lastSyncMs(): number {
    return this.syncedAt;
  }

  /**
   * 从网页拉一份索引。
   *
   * @param force 为 true 时忽略缓存（例如刚做完一次交互，想立刻知道模板到没到）。
   */
  async sync(force: boolean = false): Promise<boolean> {
    const now: number = Date.now();
    if (!force && this.syncedAt > 0 && now - this.syncedAt < INDEX_TTL_MS) {
      return this.order.length > 0;
    }
    this.syncedAt = now;
    try {
      const raw: string = await this.bridge.runBridge(REPLAY_INDEX_SCRIPT, INDEX_TIMEOUT_MS, 'api-index');
      const dto: ApiIndexDto = JSON.parse(raw) as ApiIndexDto;
      return this.apply(dto);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'sync failed: %{public}s', (error as Error).message);
      return false;
    }
  }

  private apply(dto: ApiIndexDto): boolean {
    if (dto.state !== 'ok') {
      hilog.info(DOMAIN, TAG, 'index state=%{public}s msg=%{public}s',
        dto.state ?? '-', dto.message ?? '-');
      return false;
    }
    this.map.clear();
    this.order = [];
    const items: Array<ApiIndexItemDto> = dto.items ?? [];
    for (let index: number = 0; index < items.length; index++) {
      const item: ApiIndexItemDto = items[index];
      const name: string = (item.n ?? '').trim();
      if (name.length === 0) {
        continue;
      }
      const entry: ApiEntry = new ApiEntry(name, item.m ?? '', item.u ?? '',
        item.b ?? 0, item.v ?? []);
      this.map.set(name, entry);
      this.order.push(name);
    }
    this.watchOn = dto.watch === true;
    this.feedReady = dto.feed === true;
    this.commentReady = dto.comment === true;
    // 只有清单真的变了才打日志：这个 sync 会被反复调用，别把日志刷满。
    const line: string = this.summary();
    if (line !== this.lastLogged) {
      this.lastLogged = line;
      hilog.info(DOMAIN, TAG, '%{public}s', line);
    }
    return this.order.length > 0;
  }

  /**
   * 通用回放：按操作名（或名字片段）重放网页发过的那个请求。
   *
   * 返回原始响应文本（可能被截断，见 maxBytes），解析交给调用方 —— 这样所有接口共用
   * 一条通道，不用每个接口写一个脚本。
   */
  async replay(op: string, vars: Record<string, string>,
               maxBytes: number = REPLAY_MAX_BYTES): Promise<ReplayResult | null> {
    try {
      const script: string = replayApiScript(op, JSON.stringify(vars ?? {}), maxBytes);
      const raw: string = await this.bridge.runBridge(script, REPLAY_TIMEOUT_MS, `replay:${op}`);
      const result: ReplayResult = new ReplayResult(JSON.parse(raw) as ReplayDto);
      if (!result.isOk()) {
        hilog.info(DOMAIN, TAG, 'replay state=%{public}s op=%{public}s msg=%{public}s have=%{public}s',
          result.state, result.op.length > 0 ? result.op : op, result.message, result.have);
      }
      return result;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'replay failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /**
   * 把页面上匹配的完整模板倒到原生侧存起来（跨页面回放的前提）。
   *
   * @param filter 操作名或名字片段（不分大小写），例如 `comment`。
   * @returns 是否真的存到了东西。
   */
  async capture(filter: string): Promise<boolean> {
    try {
      const script: string = replayTemplatesScript(filter, TEMPLATE_MAX_ITEMS, TEMPLATE_MAX_BODY);
      const raw: string = await this.bridge.runBridge(script, INDEX_TIMEOUT_MS, `templates:${filter}`);
      const dto: ReplayTemplatesDto = JSON.parse(raw) as ReplayTemplatesDto;
      if (dto.state !== 'ok') {
        hilog.info(DOMAIN, TAG, 'capture %{public}s state=%{public}s msg=%{public}s',
          filter, dto.state ?? '-', dto.message ?? '-');
        return false;
      }
      const items: Array<ReplayTemplateDto> = dto.items ?? [];
      let stored: number = 0;
      for (let index: number = 0; index < items.length; index++) {
        const item: ReplayTemplateDto = items[index];
        const name: string = (item.n ?? '').trim();
        const url: string = (item.u ?? '').trim();
        if (name.length === 0 || url.length === 0 || item.trunc === true) {
          // 截断过的模板不能用来回放（请求体少一段就是另一条请求了）。
          continue;
        }
        this.templates.set(name, new ApiTemplate(name, item.m ?? 'POST', url,
          ApiRegistry.sanitizeHeaders(item.h ?? []), item.b ?? '', item.h ?? []));
        stored++;
      }
      if (stored > 0) {
        hilog.info(DOMAIN, TAG, 'capture %{public}s stored=%{public}d/%{public}d have=%{public}s',
          filter, stored, items.length, dto.have ?? '-');
        // 落盘：下次冷启动才有模板可用（"不走网页"那条路全靠它，见 storedForNative）。
        this.persistTemplates();
      } else {
        hilog.info(DOMAIN, TAG, 'capture %{public}s nothing have=%{public}s',
          filter, dto.have ?? '-');
      }
      return stored > 0;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'capture failed: %{public}s', (error as Error).message);
      return false;
    }
  }

  /** 取一份没过期的已存模板；名字精确匹配优先，其次按片段匹配。 */
  stored(fragment: string): ApiTemplate | null {
    const now: number = Date.now();
    const exact: ApiTemplate | undefined = this.templates.get(fragment);
    if (exact !== undefined && now - exact.at < TEMPLATE_TTL_MS) {
      return exact;
    }
    const needle: string = fragment.toLowerCase();
    const names: Array<string> = Array.from(this.templates.keys());
    for (let index: number = 0; index < names.length; index++) {
      const item: ApiTemplate | undefined = this.templates.get(names[index]);
      if (item === undefined || now - item.at >= TEMPLATE_TTL_MS) {
        continue;
      }
      if (item.name.toLowerCase().indexOf(needle) >= 0) {
        return item;
      }
    }
    return null;
  }

  /** 取一份已存模板的 JSON（给注入脚本用）；没有就返回空串。 */
  storedJson(fragment: string): string {
    const hit: ApiTemplate | null = this.stored(fragment);
    return hit === null ? '' : hit.json();
  }

  /** 已存模板的一行摘要（日志用）。 */
  storedSummary(): string {
    if (this.templates.size === 0) {
      return 'stored=0';
    }
    const names: Array<string> = Array.from(this.templates.keys());
    return `stored=${names.length} ${names.slice(0, LOG_NAMES).join("|")}`;
  }

  /**
   * 用**原生存下来的模板**回放（当前页面有没有这个操作都行）。
   *
   * 返回 null 表示"连模板都没有/请求没发出去"，调用方据此退回导航那条慢路径。
   */
  async replayStored(op: string, vars: Record<string, string>,
                     maxBytes: number = REPLAY_MAX_BYTES): Promise<ReplayResult | null> {
    const cfg: string = this.storedJson(op);
    if (cfg.length === 0) {
      return null;
    }
    try {
      const script: string = replayStoredApiScript(cfg, JSON.stringify(vars ?? {}), maxBytes);
      const raw: string = await this.bridge.runBridge(script, REPLAY_TIMEOUT_MS, `stored:${op}`);
      const result: ReplayResult = new ReplayResult(JSON.parse(raw) as ReplayDto);
      if (!result.isOk()) {
        hilog.info(DOMAIN, TAG, 'stored replay state=%{public}s op=%{public}s msg=%{public}s',
          result.state, op, result.message);
      }
      return result;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'stored replay failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /**
   * 同 replayStored，但变量由调用方给**已经序列化好的 JSON**。
   *
   * 为什么需要单独一个：GraphQL 的变量是有类型的（`first` 必须是整数、`after` 是字符串），
   * 用 `Record<string, string>` 会把数字也写成字符串。这里让调用方自己拼，类型就不会走样。
   */
  async replayStoredJson(op: string, varsJson: string, maxBytes: number = REPLAY_MAX_BYTES,
                         timeoutMs: number = REPLAY_TIMEOUT_MS): Promise<ReplayResult | null> {
    const cfg: string = this.storedJson(op);
    if (cfg.length === 0) {
      return null;
    }
    try {
      const script: string = replayStoredApiScript(cfg, varsJson, maxBytes);
      const raw: string = await this.bridge.runBridge(script, timeoutMs, `stored:${op}`);
      const result: ReplayResult = new ReplayResult(JSON.parse(raw) as ReplayDto);
      if (!result.isOk()) {
        hilog.info(DOMAIN, TAG, 'stored replay state=%{public}s op=%{public}s msg=%{public}s',
          result.state, op, result.message);
      }
      return result;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'stored replay failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /** 已存模板的操作名清单（按存入顺序）。 */
  storedNames(): Array<string> {
    return Array.from(this.templates.keys());
  }

  /**
   * 最近 `withinMs` 内**被更新过**的模板名（诊断用）。
   *
   * 抓模板时最想知道的是"页面刚才到底发了哪几条" —— 名字清单本身看不出新旧（同名模板会被
   * 覆盖），而每条模板都带更新时间戳（`at`），拿它一筛就清楚了。
   */
  recentNames(withinMs: number): Array<string> {
    const now: number = Date.now();
    const names: Array<string> = Array.from(this.templates.keys());
    const out: Array<string> = [];
    for (let index: number = 0; index < names.length; index++) {
      const tpl: ApiTemplate | undefined = this.templates.get(names[index]);
      if (tpl !== undefined && now - tpl.at <= withinMs) {
        out.push(names[index]);
      }
    }
    return out;
  }

  /**
   * 用存下来的模板回放一次并拿回**结构摘要**（键路径 + 值预览）。
   *
   * 写原生页面时靠它照着真实结构写解析 —— 比把几百 KB 响应过桥回原生再动态摸结构省得多。
   */
  async replayDigest(op: string, vars: Record<string, string>,
                     depth: number = 5, maxKeys: number = 120): Promise<DigestResult | null> {
    const cfg: string = this.storedJson(op);
    if (cfg.length === 0) {
      return null;
    }
    try {
      const script: string = replayDigestScript(cfg, JSON.stringify(vars ?? {}), depth, maxKeys);
      const raw: string = await this.bridge.runBridge(script, REPLAY_TIMEOUT_MS, `digest:${op}`);
      const result: DigestResult = new DigestResult(JSON.parse(raw) as DigestDto);
      if (result.state !== 'ok') {
        hilog.info(DOMAIN, TAG, 'digest %{public}s state=%{public}s msg=%{public}s',
          op, result.state, result.message);
      }
      return result;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'digest failed: %{public}s', (error as Error).message);
      return null;
    }
  }

  /** 去掉浏览器自己会填、或 fetch 禁止脚本设置的头。 */
  private static sanitizeHeaders(raw: Array<Array<string>>): Array<Array<string>> {
    const out: Array<Array<string>> = [];
    for (let index: number = 0; index < raw.length; index++) {
      const pair: Array<string> = raw[index];
      if (pair.length < 2) {
        continue;
      }
      const name: string = pair[0].toLowerCase();
      if (name.length === 0 || HEADER_BLOCK.indexOf(name) >= 0) {
        continue;
      }
      out.push([pair[0], pair[1]]);
    }
    return out;
  }
}
