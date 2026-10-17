/*
 * 「我的」页面的**原生 HTTP 取数**（和首页信息流、Reels 同一套路数）。
 *
 * ## 为什么从"网页回放"改成原生 HTTP
 * 原来这两条查询是**在隐藏网页里**用 `fetch` 回放的（见 bridge/WebScripts 的 profilePostsScript），
 * 再把结果过桥回原生。那条路的代价：
 *   - 每条帖子都挂着巨大的 `organic_tracking_token`，一页 12 条就 400KB+，过桥有**大小上限**，
 *     超了就是截断 → JSON 坏掉 → 「读取失败」（ProfileViewModel 里 900KB 那个常量就是为此存在的）；
 *   - 注入脚本有体积坑、页面还要"水合"，于是冷启动那一轮得反复重试（EXTRACT_ATTEMPTS 那套）；
 *   - 页面一旦被导航到别处（读通知、发关注…），回放就没得跑了。
 * 原生直发没有这些问题：模板 + 会话头是从真机抓下来的（见 bridge/ApiRegistry），请求体照抄，
 * 响应在原生侧解析 —— 不经过桥、没有体积上限、也不占网页。
 *
 * ## 模板（这就是"用探针抓一下模板"的那份东西）
 * 每条请求的 `doc_id` / 变量结构 / 私有头都来自**页面自己发过的那一次**（探针 + NETWORK_WATCHER
 * 抓下来存进 ApiRegistry）。所以：
 *   - 有模板 → 原生直发（本文件）；
 *   - 没模板 → 退回原来那条"驱动网页 + 抓模板"的路（见 ProfileViewModel.ensureTemplates）。
 * 分页只改 `variables.after`，其余变量（含 IG 那些 relay provider 开关）**原样保留** ——
 * 它们决定服务端返回什么形状，动了就会 `noncoercible_variable_value`。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { JsonRead } from './JsonRead';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { NativeFeed } from './NativeFeed';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { ApiThrottle } from './ApiThrottle';
import { MobileProfile, MobileUserBody, MobileGridPage } from './mobileapi/MobileProfile';
import { ProfileHeader, ProfilePost, ProfilePostsPage } from '../model/Profile';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeProfile';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 15000;
/** 模板里那条请求的地址是相对路径（`/graphql/query`），补上站点。 */
const SITE: string = 'https://www.instagram.com';
/**
 * 帖子连接的字段名：IG 时不时换名字，这里按"已知名字优先、再退回第一个带 edges 的对象"来找
 * （和页面脚本同一套判据，见 WebScripts.profilePostsScript 的说明）。
 */
const POSTS_CONN: string = 'xdt_api__v1__feed__user_timeline_graphql_connection';

/** 一次原生请求的结果（不抛异常，失败用 ok=false + detail 表达）。 */
export class NativeProfileResult {
  readonly ok: boolean;
  readonly text: string;
  readonly detail: string;

  constructor(ok: boolean, text: string, detail: string) {
    this.ok = ok;
    this.text = text;
    this.detail = detail;
  }
}

/**
 * 媒体节点外面套的那几层键（各分页包装层数不一样）。
 *
 * 实测背景：**帖子**分页 `edge.node` 就是媒体；**视频 / 收藏 / 被标注**那三个分页多套一层
 * （首页 Clips 那条也是 `edge.node.media`）—— 原来只认 `edge.node`，那三个分页就会"请求成功但
 * 一条都解析不出来"（界面：还没有帖子）。
 */
const MEDIA_WRAPPERS: Array<string> = ['media', 'media_or_ad'];
/** 找媒体连接时往下钻几层（见 connectionsOf：视频/收藏分页把连接藏在包装对象里）。 */
const CONNECTION_MAX_DEPTH: number = 4;
/**
 * 网格封面的**目标宽度**（px）。
 *
 * 格子是 141vp 宽（≈470px），所以 360 这一档就够看，而 IG 那一档只有最大档的 1/4~1/6
 * （一张二十几 KB vs 一二百 KB）。以前这里是 `candidates[0]` —— IG 的候选是**从大到小**排的，
 * 等于每张都拉最大档：一屏十几张就是几 MB，"用户主页/我的页"的封面因此明显变慢。
 * 判据和搜索页那面网格完全一致（见 NativeSearch 的 COVER_WIDTH）。
 */
const COVER_WIDTH: number = 360;
/**
 * 请求体里"这一份数据是谁的"那几个键（见 ProfileTarget / bodyWith）。
 *
 * 四条个人页查询的目标用户写法不同，实测：
 *   - `PolarisProfilePageContentQuery`（头部）   → `id`
 *   - `PolarisProfilePostsQuery`（帖子）         → `username`
 *   - `..._ReelsTabContentQuery`（视频）         → `user_id` + `data.target_user_id`
 *   - `..._TaggedTabContentQuery`（被标注）      → `user_id`
 * 所以按**键名**改：值换成目标用户的 id / 用户名即可，不用为每条查询各写一份。
 */
const TARGET_ID_KEYS: Array<string> = ['id', 'user_id', 'target_user_id'];
const TARGET_NAME_KEYS: Array<string> = ['username'];

/**
 * **一次取数的目标用户**（见 core/NativeProfile 与 viewmodels/ProfileViewModel）。
 *
 * 空 = 本人：这时请求体里的目标键被**回正成本人**（见下面 selfName 的说明）。
 * 非空 = 别人：把上面那几个键换成他的 id / 用户名。
 *
 * ## 为什么"本人"也要带上自己的名字
 * 模板是**按操作名共用**的：`PolarisProfilePageContentQuery` 同一份，既服务"我的"页、
 * 也服务任何人的主页。而模板里存的是**抓到它的那一发**的请求体 —— 只要在别人的主页上抓过一次
 * （比如切分页时那段 `captureTab` 会顺手把这一页发过的请求全存下来），模板里的
 * `username` / `user_id` 就是**那个人的**。
 * 本人这一路原来"一个字都不改"，于是"我的"页会把别人的资料/别人的分页内容当成自己的显示出来
 * （用户报的"我的页面信息错误显示为其他用户、视频分页显示成该用户的视频"就是这个）。
 * 所以本人也要把目标键改回自己：`selfName` 是自己的账号名，id 取 Cookie 里的 `ds_user_id`
 * （见 NativeProfile.ownId）。模板本来就是自己的那一发时，改回去是同值，等于没改。
 */
export class ProfileTarget {
  /** 目标用户的**数字 id**（请求体里"目标用户"那几个 id 键用它）。 */
  readonly id: string;
  /**
   * 目标用户的**账号名**（请求体里的 `username` 键用它）。
   *
   * 取数之外还有一处用途：**关注状态**。头部还没到的时候，页面只能靠账号名去
   * 覆盖表 `FollowState` 里问一句"这个人关注了没有"（见 ProfilePage.onFollowVersion）。
   * 路由参数里本来就带着名字（`用户名|数字id`，见 Index.parseUserParam），所以这里一直有值。
   */
  readonly username: string;
  /** 本人时"我是谁"（只用来把请求体里的目标键回正，见类头说明）。空 = 还不知道。 */
  readonly selfName: string;

  constructor(id: string, username: string, selfName: string = '') {
    this.id = id;
    this.username = username;
    this.selfName = selfName;
  }

  /** 本人（请求体里的目标键回正成自己；名字不知道时只能原样发）。 */
  static self(selfName: string = ''): ProfileTarget {
    return new ProfileTarget('', '', selfName);
  }

  isSelf(): boolean {
    return this.id.length === 0 && this.username.length === 0;
  }

  /** 换一个"自己的账号名"（页面拿到头部之后才知道，见 ProfileViewModel.loadHeader）。 */
  withSelfName(name: string): ProfileTarget {
    return this.isSelf() ? ProfileTarget.self(name) : this;
  }
}

export class NativeProfile {
  /** 头部那条查询的操作名（模板按名字取）。 */
  static readonly OP_HEADER: string = 'PolarisProfilePageContentQuery';
  /** 帖子网格那条查询的操作名。 */
  static readonly OP_POSTS: string = 'PolarisProfilePostsQuery';
  /**
   * **移动端合成操作名**的前缀（`mobile:posts` / `mobile:clips` / `mobile:saved` / `mobile:tagged`）。
   *
   * 用途：视图模型在"这一分页没有 GraphQL 模板"时也要能指出"用移动端那条"（见 mobileOpFor）。
   * 它不是模板操作名，所以 `NativeProfile.post` 那条模板路不会去碰它。
   */
  static readonly MOBILE_OP_PREFIX: string = 'mobile:';
  /**
   * **自己的数字 id**（Cookie 里的 `ds_user_id`），懒读一次。
   *
   * 用途只有一个：本人这一路的请求体里，把"目标用户"那几个 id 键**回正成自己**
   * （模板可能是在别人的主页上抓的，见 ProfileTarget 的类头说明）。
   */
  private static ownIdCache: string = '';

  /** 读一次自己的数字 id（读不到就给空串；调用方按"不改"处理）。 */
  static async ownId(): Promise<string> {
    if (NativeProfile.ownIdCache.length > 0) {
      return NativeProfile.ownIdCache;
    }
    try {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const cookie: string = jar.cookie ?? '';
      const parts: Array<string> = cookie.split(';');
      for (let index: number = 0; index < parts.length; index++) {
        const one: string = parts[index].trim();
        if (one.indexOf('ds_user_id=') === 0) {
          NativeProfile.ownIdCache = one.substring('ds_user_id='.length).trim();
          break;
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'own id read failed: %{public}s', (error as Error).message);
    }
    return NativeProfile.ownIdCache;
  }

  /** 已经读到的自己的数字 id（同步；没读过给空串，见 ownId）。 */
  static ownIdCached(): string {
    return NativeProfile.ownIdCache;
  }

  /**
   * 最近一次原生请求为什么失败（`http-403` / `no-template` / `throw:…`）。
   *
   * 为什么要留一份：这条链路的失败一直在**界面状态行**上（hilog 会被系统刷掉），
   * 而"请求失败"和"解析出 0 条"是两种完全不同的毛病（前者要查头/模板，后者要查形状），
   * 不把 detail 带出去就只能靠猜。
   */
  private static detail: string = '-';
  /** "因为没有图片候选而丢掉了 mp4 封面"这件事只记一次（见 postOf 的 cover 兜底）。 */
  private static diagCoverDropped: number = 0;

  /** 最近一次失败的原因（成功时清成 `-`）。 */
  static lastDetail(): string {
    return NativeProfile.detail;
  }

  /**
   * 分页模板的**结构摘要**（探针用）：逐条发一次，只留"顶层键 / 连接 / 第一条 edge 里媒体挂哪"。
   *
   * 为什么需要它：四个分页的键名与包装层数各不一样（而且响应里混着别的连接），
   * 光看"请求成功"完全不知道解析该往哪找 —— 摘要把这件事一次讲清。落盘由页面负责
   * （见 pages/Index 的 dumpProbeFile），因为 hilog 会被系统刷掉。
   */
  static async digest(ops: Array<string>): Promise<string> {
    const lines: Array<string> = [];
    for (let index: number = 0; index < ops.length; index++) {
      const op: string = ops[index];
      if (op.length === 0) {
        continue;
      }
      const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
      const method: string = tpl === null ? '?' : (tpl.method ?? 'POST');
      const bodyLength: number = tpl === null ? 0 : (tpl.body ?? '').length;
      lines.push(`### ${op} ${method} body=${bodyLength}`);
      const result: NativeProfileResult = await NativeProfile.post(op, '');
      if (!result.ok) {
        lines.push(`  http-fail ${result.detail}`);
        continue;
      }
      lines.push(NativeProfile.shapeOf(result.text));
    }
    if (lines.length === 0) {
      lines.push('no profile templates');
    }
    return lines.join('\n');
  }

  /** 两层的键名树（探针摘要用，见 shapeOf）：`a{b,c}, d[e], e=…`。 */
  private static treeOf(node: Record<string, Object>, depth: number): string {
    if (depth <= 0) {
      return '…';
    }
    const parts: Array<string> = [];
    const keys: Array<string> = Object.keys(node);
    for (let index: number = 0; index < keys.length && index < 10; index++) {
      const key: string = keys[index];
      const child: Record<string, Object> | null = NativeProfile.asRecord(node[key]);
      if (child !== null) {
        const inner: Array<string> = Object.keys(child).slice(0, 6);
        parts.push(`${key}{${inner.join(',')}}`);
        continue;
      }
      if (Array.isArray(node[key])) {
        const list: Array<Object> = NativeProfile.arrayOf(node, key);
        const first: Record<string, Object> | null =
          NativeProfile.asRecord(list.length > 0 ? list[0] : null);
        parts.push(`${key}[${list.length}]${first === null ? ''
          : '{' + Object.keys(first).slice(0, 5).join(',') + '}'}`);
        continue;
      }
      parts.push(key);
    }
    return '  tree: ' + parts.join(' ');
  }

  /** 响应形状摘要：data 的键、每个连接、第一条 edge 里媒体的位置与解析结果。 */
  private static shapeOf(text: string): string {
    const root: Record<string, Object> = NativeProfile.parse(text);
    const out: Array<string> = [];
    const errors: Array<Object> = NativeProfile.arrayOf(root, 'errors');
    if (errors.length > 0) {
      const first: Record<string, Object> | null = NativeProfile.asRecord(errors[0]);
      out.push(`  errors=${first === null ? '?' : NativeProfile.strOf(first, 'message').substring(0, 120)}`);
    }
    const data: Record<string, Object> | null = NativeProfile.recordOf(root, 'data');
    if (data === null) {
      out.push('  data=null');
      return out.join('\n');
    }
    out.push(`  data.keys=${Object.keys(data).slice(0, 8).join(',')}`);
    // 结构树（两层）：连接藏得深时，光看顶层键名是看不出媒体在哪的（实测踩过）。
    out.push(NativeProfile.treeOf(data, 2));
    const connections: Array<Record<string, Object>> = NativeProfile.connectionsOf(data);
    out.push(`  connections=${connections.length}`);
    for (let index: number = 0; index < connections.length && index < 3; index++) {
      const conn: Record<string, Object> = connections[index];
      const edges: Array<Object> = NativeProfile.arrayOf(conn, 'edges');
      const pageInfo: Record<string, Object> | null = NativeProfile.recordOf(conn, 'page_info');
      const cursor: string = pageInfo === null ? '' : NativeProfile.strOf(pageInfo, 'end_cursor');
      const hasMore: boolean = pageInfo !== null && NativeProfile.boolOf(pageInfo, 'has_next_page');
      out.push(`    conn[${index}] edges=${edges.length} hasMore=${hasMore} cursor=${cursor.length}`);
      const edge: Record<string, Object> | null =
        NativeProfile.asRecord(edges.length > 0 ? edges[0] : null);
      if (edge === null) {
        continue;
      }
      out.push(`      edge.keys=${Object.keys(edge).slice(0, 6).join(',')}`);
      const node: Record<string, Object> | null = NativeProfile.recordOf(edge, 'node');
      if (node !== null) {
        out.push(`      node.keys=${Object.keys(node).slice(0, 8).join(',')}`);
      }
      const mapped: ProfilePost | null = NativeProfile.postOfEdge(edge);
      out.push(`      mapped=${mapped === null ? 'null' : mapped.shortcode}`);
    }
    const page: ProfilePostsPage | null = NativeProfile.postsOf(text);
    out.push(`  parsed posts=${page === null ? -1 : page.posts.length}`);
    return out.join('\n');
  }

  /**
   * 这条操作的模板在不在。
   *
   * ⚠️ **必须按"原生那条 TTL"算**：ApiRegistry 里有两套时效 —— 页面内回放用 10 分钟
   * （`storedJson`），原生直发用 24 小时（`storedForNative`）。这里原来用的是前者，于是
   * **抓完模板过 10 分钟，四个分页就集体"没有模板"**：fetchPage 跳过原生 → 回放那条查的也是
   * 同一份 10 分钟时效的表 → 空 → 界面「读取失败：native=- replay=no-template」。
   * 这也是"只有帖子能看、另外三个分页抓不到"的真凶（帖子那条能撑是因为别处也在用
   * storedForNative 发请求）。
   */
  static hasTemplate(op: string): boolean {
    return ApiRegistry.getInstance().storedForNative(op) !== null;
  }

  /** 拉一次个人页头部（拿不到就 null）。 */
  static async fetchHeader(target: ProfileTarget = ProfileTarget.self()): Promise<ProfileHeader | null> {
    /*
     * **① 移动端优先**（instagrapi 的 `user_info_v1` / `user_info_by_username_v1`）。
     *
     * 实测：`users/{pk}/info/` 是几百毫秒的一发小请求，而模板那条（`PolarisProfilePageContentQuery`）
     * 是几百 KB 的重查询、还得先有模板。用户要求"主页数据加载速度提升"，这一发就是那个提升点。
     * 本人这一路也要先把 id 读出来（Cookie 里的 `ds_user_id`，见 ownId）。
     */
    let uid: string = target.id;
    if (uid.length === 0 && target.isSelf()) {
      uid = await NativeProfile.ownId();
    }
    const mobile: MobileUserBody | null = await MobileProfile.info(uid, target.username,
      ApiThrottle.interactive());
    if (mobile !== null) {
      const mapped: ProfileHeader | null = NativeProfile.headerFromUser(mobile.user);
      if (mapped !== null) {
        hilog.info(DOMAIN, TAG, 'header via mobile user=%{public}s ms=%{public}d bytes=%{public}d',
          mapped.username, mobile.ms, mobile.bytes);
        return mapped;
      }
      hilog.info(DOMAIN, TAG, 'header mobile shape unusable, falling back to template');
    }
    const result: NativeProfileResult = await NativeProfile.post(NativeProfile.OP_HEADER, '', target);
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'header http failed: %{public}s', result.detail);
      return null;
    }
    return NativeProfile.headerOf(result.text);
  }

  /** 拉一页网格（拿不到就 null）。 */
  static async fetchPosts(op: string, after: string,
                          target: ProfileTarget = ProfileTarget.self()): Promise<ProfilePostsPage | null> {
    /*
     * **① 移动端优先**（四个分页各有对应端点，见 core/mobileapi/MobileProfile.tab）：
     *   帖子 `feed/user/{pk}/`、Reels `clips/user/`、被标注 `usertags/{pk}/feed/`、收藏 `feed/saved/`。
     *
     * 为什么四个都走它（用户要求："我的（及其下四个分页）尝试改为 instagrapi 的协议"）：
     * 模板那条路要么得先在隐藏网页上抓一次模板（秒级、还要导航共用网页），要么就是
     * "这个分页的接口模板还没有"。移动端这四条同样是一次 GET/POST，且不需要任何模板。
     *
     * 退路完整保留：kind 认不出、没有目标 id、或者移动端这一发没通 → 原样走模板那条路。
     * 用**乐观性**区分（见 MobileProfile.tabUsable）：帖子/被标注直接乐观用；
     * Reels/收藏是试出来的端点，学到能用之后才在"没模板"时也敢用合成操作名。
     */
    const kind: string = NativeProfile.mobileKindOf(op);
    if (kind.length > 0) {
      let uid: string = target.id;
      if (uid.length === 0 && target.isSelf()) {
        uid = await NativeProfile.ownId();
      }
      if (uid.length > 0) {
        const page: MobileGridPage | null = await MobileProfile.tab(kind, uid, after, undefined,
          ApiThrottle.interactive());
        if (page !== null) {
          const posts: Array<ProfilePost> = NativeProfile.postsFromItems(page.items);
          hilog.info(DOMAIN, TAG,
            'tab via mobile kind=%{public}s uid=%{public}s items=%{public}d posts=%{public}d more=%{public}s ms=%{public}d',
            kind, uid, page.items.length, posts.length, `${page.hasMore}`, page.ms);
          // 移动端与 GraphQL 的游标互不通用；这一路只走移动端，所以直接交它的 `next_max_id`。
          return new ProfilePostsPage(posts, page.nextCursor, page.hasMore);
        }
      }
      if (NativeProfile.isMobileOp(op)) {
        // 合成操作名 = 调用方本来就没有模板，只有移动端这一条；这里再退也没得退。
        hilog.warn(DOMAIN, TAG, 'mobile tab failed and no template op: kind=%{public}s', kind);
        return null;
      }
    }
    const result: NativeProfileResult = await NativeProfile.post(op, after, target);
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'posts http failed op=%{public}s: %{public}s', op, result.detail);
      return null;
    }
    return NativeProfile.postsOf(result.text);
  }

  /**
   * 分页 → 移动端那一段的名字（`posts` / `clips` / `saved` / `tagged`；认不出一律空串）。
   *
   * 两种入参都要认：
   *   · **合成操作名** `mobile:clips`（视图模型在"没有模板"时给的，见 `mobileOpFor`）；
   *   · **真模板操作名**（`PolarisProfileReelsTabContentQuery` 等）—— 按名字片段判分页。
   */
  static mobileKindOf(op: string): string {
    if (op.length === 0) {
      return '';
    }
    if (NativeProfile.isMobileOp(op)) {
      return op.substring(NativeProfile.MOBILE_OP_PREFIX.length);
    }
    const lower: string = op.toLowerCase();
    if (lower.indexOf('reels') >= 0 || lower.indexOf('clips') >= 0) {
      return 'clips';
    }
    if (lower.indexOf('saved') >= 0) {
      return 'saved';
    }
    if (lower.indexOf('tagged') >= 0 || lower.indexOf('usertag') >= 0) {
      return 'tagged';
    }
    if (lower.indexOf('postsquery') >= 0) {
      return 'posts';
    }
    return '';
  }

  /** 这一分页在"没有模板"时能不能靠移动端（见 viewmodel/ProfileViewModel.opNameOf）。 */
  static mobileOpFor(kind: string): string {
    if (kind.length === 0) {
      return '';
    }
    return MobileProfile.tabUsable(kind) ? `${NativeProfile.MOBILE_OP_PREFIX}${kind}` : '';
  }

  static isMobileOp(op: string): boolean {
    return op.startsWith(NativeProfile.MOBILE_OP_PREFIX);
  }

  /**
   * **原始媒体节点**（移动端 `feed/user/{pk}/` 的 `items`）→ 网格用的 `ProfilePost`。
   *
   * 复用 `postOf`（封面挑 360 档、多图收子媒体、视频档位…都在里面），所以移动端与模板那条路
   * 出来的卡片字段完全一致 —— 界面与帖子页都不用区分数据是哪条路来的。
   */
  static postsFromItems(items: Array<Object>): Array<ProfilePost> {
    const posts: Array<ProfilePost> = [];
    for (let index: number = 0; index < items.length; index++) {
      const raw: Record<string, Object> | null = NativeProfile.asRecord(items[index]);
      if (raw === null) {
        continue;
      }
      /*
       * **两种包装都要认**（真机实测：收藏那一发 `feed/saved/` 给的是 `{media:{…}}`，
       * 而帖子 `feed/user/{pk}/` 给的是媒体对象本身）—— 只认后者时收藏 24 条会被解析成 0 条
       * （2026-10-17 日志：`tab[saved] ok items=24` 紧跟着 `posts=0`）。
       */
      const wrapped: Record<string, Object> | null = NativeProfile.recordOf(raw, 'media');
      const node: Record<string, Object> = wrapped === null ? raw : wrapped;
      const post: ProfilePost | null = NativeProfile.postOf(node);
      if (post !== null) {
        posts.push(post);
      }
    }
    return posts;
  }

  /**
   * 发一次（模板 → 头 + 体），返回响应文本。
   *
   * 头用 `NativeFeed.headersFor(op)`：它会拿模板里那份**网页自己发过的**头（Cookie / csrf /
   * app-id / UA / `x-bloks-version-id` …）并刷新 Cookie —— 少一个都可能被 IG 当成页面导航、
   * 回一整页 HTML（信息流那边踩过同一个坑）。
   */
  private static async post(op: string, after: string,
                            target: ProfileTarget = ProfileTarget.self()): Promise<NativeProfileResult> {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl === null) {
      NativeProfile.detail = 'no-template';
      return new NativeProfileResult(false, '', 'no-template');
    }
    const headers: Record<string, string> = await NativeFeed.headersFor(op);
    if (Object.keys(headers).length === 0) {
      NativeProfile.detail = 'no-session';
      return new NativeProfileResult(false, '', 'no-session');
    }
    // 本人这一路要拿自己的 id 回正请求体（见 ProfileTarget 的类头说明）；只读一次。
    if (target.isSelf()) {
      await NativeProfile.ownId();
    }
    const body: string = NativeProfile.bodyWith(tpl, after, target);
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
        NativeProfile.detail = `${why} body=${text.substring(0, 60)}`;
        return new NativeProfileResult(false, '', why);
      }
      NativeProfile.detail = '-';
      return new NativeProfileResult(true, text, '');
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'http failed op=%{public}s: %{public}s', op, message);
      NativeProfile.detail = `throw:${message}`.substring(0, 80);
      return new NativeProfileResult(false, '', NativeProfile.detail);
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 请求体：**第一页原样重发**，只有翻页时才动 `variables.after`；指定了目标用户时，
   * 再把"这一份数据是谁的"那几个键换掉（见 ProfileTarget）。
   *
   * 为什么第一页不再"清掉 after"（这版改的）：模板就是页面自己发过的那一发，**原样重发**
   * 才是行为完全一致的那一发；清掉 after 看着无害，实则改了请求体 —— 实测里 `PolarisProfile
   * ReelsTabContentQuery` / `SavedPostsTabContentQuery` 回回来的 `data` 里**根本没有媒体连接**
   * （只有 `fetch__XDTUserDict` / `viewer`），而帖子那条清不清都一样能用。既然没有好处，
   * 就不动它（改坏了只会得到"请求成功但一条都解析不出来"这种最难查的毛病）。
   */
  private static bodyWith(tpl: ApiTemplate, after: string,
                          target: ProfileTarget = ProfileTarget.self()): string {
    const body: string = tpl.body ?? '';
    if (body.length === 0) {
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
        // ArkTS 不支持 `delete`（arkts-no-delete），所以**重建**一份：先全部拷过来、跳过旧的
        // after，再把这次的游标写进去；同时按目标用户改那几个键（递归，见 retarget）。
        const out: Record<string, Object> = {};
        const keys: Array<string> = Object.keys(src);
        for (let k: number = 0; k < keys.length; k++) {
          const key: string = keys[k];
          if (key === 'after') {
            continue;
          }
          out[key] = NativeProfile.retarget(src[key], key, target);
        }
        if (after.length > 0) {
          out['after'] = after;
        }
        parts[index] = `variables=${encodeURIComponent(JSON.stringify(out))}`;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'merge variables failed: %{public}s', (error as Error).message);
      }
      break;
    }
    return parts.join('&');
  }

  /**
   * 按目标用户改写一个变量值（递归进对象/数组）。
   *
   * 规则只看**键名**（见 TARGET_ID_KEYS / TARGET_NAME_KEYS）：命中就换成目标的 id / 用户名，
   * 其余原样。**本人也一样要改**（见 ProfileTarget 的类头说明）：模板可能是"别人的主页"
   * 那一发存下来的，不改回去"我的"页就会显示成别人。
   */
  private static retarget(value: Object, key: string, target: ProfileTarget): Object {
    if (target.isSelf()) {
      // id 只有**读到自己的 ds_user_id** 时才敢写；读不到就原样（宁可少改，不能改错）。
      if (TARGET_ID_KEYS.indexOf(key) >= 0 && NativeProfile.ownIdCache.length > 0) {
        return NativeProfile.ownIdCache;
      }
      if (TARGET_NAME_KEYS.indexOf(key) >= 0 && target.selfName.length > 0) {
        return target.selfName;
      }
      return value;
    }
    if (TARGET_ID_KEYS.indexOf(key) >= 0 && target.id.length > 0) {
      return target.id;
    }
    if (TARGET_NAME_KEYS.indexOf(key) >= 0 && target.username.length > 0) {
      return target.username;
    }
    if (Array.isArray(value)) {
      const list: Array<Object> = value as Array<Object>;
      const out: Array<Object> = [];
      for (let index: number = 0; index < list.length; index++) {
        out.push(NativeProfile.retarget(list[index], '', target));
      }
      return out;
    }
    const record: Record<string, Object> | null = JsonRead.asRecord(value);
    if (record === null) {
      return value;
    }
    const out: Record<string, Object> = {};
    const keys: Array<string> = Object.keys(record);
    for (let index: number = 0; index < keys.length; index++) {
      const child: string = keys[index];
      out[child] = NativeProfile.retarget(record[child], child, target);
    }
    return out;
  }

  /** 响应文本 → 头部模型（形状：`data.user`）。 */
  private static headerOf(text: string): ProfileHeader | null {
    const root: Record<string, Object> = NativeProfile.parse(text);
    const data: Record<string, Object> | null = NativeProfile.recordOf(root, 'data');
    if (data === null) {
      return null;
    }
    const user: Record<string, Object> | null = NativeProfile.recordOf(data, 'user');
    if (user === null) {
      return null;
    }
    return NativeProfile.headerFromUser(user);
  }

  /**
   * **一个 user 对象** → 头部（GraphQL 与移动端 `users/{id}/info/` 共用这一份映射）。
   *
   * 两个形状的字段名基本一致（`follower_count` / `media_count` / `hd_profile_pic_url_info` /
   * `friendship_status.following`），移动端那几个计数在 `user` 上就带着 —— 所以同一段逻辑
   * 两边都能用，只有头像那两处兜底不同（见下面 `profile_pic_url_hd`）。
   */
  static headerFromUser(user: Record<string, Object>): ProfileHeader | null {
    const username: string = NativeProfile.strOf(user, 'username');
    if (username.length === 0) {
      return null;
    }
    const hd: Record<string, Object> | null = NativeProfile.recordOf(user, 'hd_profile_pic_url_info');
    let avatar: string = hd === null ? '' : NativeProfile.strOf(hd, 'url');
    if (avatar.length === 0) {
      // 移动端这条把高清头像直接挂在 user 上（`profile_pic_url_hd`），GraphQL 那条没有。
      avatar = NativeProfile.strOf(user, 'profile_pic_url_hd');
    }
    // 关注状态：`friendship_status.followed_by_viewer`（新版把 `followed_by_viewer` 直接挂在
    // user 上，两处都读一次 —— 少了它，用户主页那颗按钮就永远是"关注"）。
    // 关注状态：**真机上这个字段叫 `friendship_status.following`**（探针实测的键：
    // following, blocking, is_feed_favorite, outgoing_request, followed_by, incoming_request, …）
    // ——没有 `followed_by_viewer`。两种写法都读一次，免得换版本又空。
    const friend: Record<string, Object> | null = NativeProfile.recordOf(user, 'friendship_status');
    const followed: boolean = (friend !== null
      && (NativeProfile.boolOf(friend, 'following')
        || NativeProfile.boolOf(friend, 'followed_by_viewer')))
      || NativeProfile.boolOf(user, 'followed_by_viewer');
    return new ProfileHeader(username,
      NativeProfile.strOf(user, 'full_name'),
      NativeProfile.strOf(user, 'biography'),
      NativeProfile.strOf(user, 'external_url'),
      avatar.length > 0 ? avatar : NativeProfile.strOf(user, 'profile_pic_url'),
      NativeProfile.boolOf(user, 'is_verified'),
      NativeProfile.boolOf(user, 'is_private'),
      NativeProfile.numOf(user, 'follower_count'),
      NativeProfile.numOf(user, 'following_count'),
      NativeProfile.numOf(user, 'media_count'),
      followed);
  }

  /**
   * 响应文本 → 一页网格。
   *
   * **四条分页的包装不一样，所以这里不能只认一个键**：
   *   - 帖子分页：`data.xdt_api__v1__feed__user_timeline_graphql_connection`；
   *   - 视频 / 收藏 / 被标注：键名各不相同，而且响应里往往还有**别的**带 edges 的连接
   *     （推荐用户之类）。所以做法是：把 `data` 下所有"带 edges 的连接对象"都收起来，
   *     **逐条试着解析**，谁先解析出帖子就用谁；一条都解析不出来时才把第一条的信息
   *     （游标/还有没有下一页）作为空页返回，界面才知道"这个分页确实没有内容"。
   */
  private static postsOf(text: string): ProfilePostsPage | null {
    const root: Record<string, Object> = NativeProfile.parse(text);
    const data: Record<string, Object> | null = NativeProfile.recordOf(root, 'data');
    if (data === null) {
      return null;
    }
    const connections: Array<Record<string, Object>> = NativeProfile.connectionsOf(data);
    if (connections.length === 0) {
      // **请求成功、但这页真没有媒体**（比如视频分页只有 clips_connection 为空的时候）。
      // 这里必须回"空页"而不是 null：null 在调用方眼里是"读失败"，界面就会显示"读取失败"，
      // 把"这个分页本来就没有内容"报成故障（实测踩过：明明该显示"还没有帖子"）。
      hilog.info(DOMAIN, TAG, 'no connection (empty tab) keys=%{public}s',
        Object.keys(data).slice(0, 6).join(','));
      return new ProfilePostsPage([], '', false);
    }
    let empty: ProfilePostsPage | null = null;
    for (let index: number = 0; index < connections.length; index++) {
      const conn: Record<string, Object> = connections[index];
      const edges: Array<Object> = NativeProfile.arrayOf(conn, 'edges');
      /*
       * 诊断：一条响应里常常**同时**挂着好几个连接（时间线、clips、推荐…），而 `postsOf` 只认
       * "第一个有内容的" —— 分页取错时光看"拿到了 N 条"完全不知道为什么，所以把每个连接的
       * 键/边数/第一条节点打出来。另外：**视频分页那条查询只给封面、不给视频地址**
       * （真机实测：media_type=2 却没有任何 video/url 字段），那一页的视频要靠
       * core/NativeMediaInfo 按 id 补 —— 这里在缺视频地址时点一句，方便对照。
       */
      if (index < 4 && edges.length > 0) {
        const firstEdge: Record<string, Object> | null = NativeProfile.asRecord(edges[0]);
        const firstNode: Record<string, Object> | null =
          firstEdge === null ? null : NativeProfile.recordOf(firstEdge, 'node');
        const inner: Record<string, Object> | null =
          firstNode === null ? null : NativeProfile.recordOf(firstNode, 'media');
        hilog.info(DOMAIN, TAG, 'conn[%{public}d] keys=%{public}s edges=%{public}d wrap=%{public}s',
          index, Object.keys(conn).slice(0, 6).join(','), edges.length, `${inner !== null}`);
        if (inner !== null && NativeProfile.arrayOf(inner, 'video_versions').length === 0) {
          hilog.info(DOMAIN, TAG, 'media id=%{public}s type=%{public}d has no video (needs info fetch)',
            NativeProfile.strOf(inner, 'pk'), NativeProfile.numOf(inner, 'media_type'));
        }
      }
      const posts: Array<ProfilePost> = [];
      for (let at: number = 0; at < edges.length; at++) {
        const edge: Record<string, Object> | null = NativeProfile.asRecord(edges[at]);
        if (edge === null) {
          continue;
        }
        const post: ProfilePost | null = NativeProfile.postOfEdge(edge);
        if (post !== null) {
          posts.push(post);
        }
      }
      const pageInfo: Record<string, Object> | null = NativeProfile.recordOf(conn, 'page_info');
      const cursor: string = pageInfo === null ? '' : NativeProfile.strOf(pageInfo, 'end_cursor');
      const hasMore: boolean = pageInfo !== null && NativeProfile.boolOf(pageInfo, 'has_next_page');
      const page: ProfilePostsPage = new ProfilePostsPage(posts, cursor, hasMore);
      if (posts.length > 0) {
        hilog.info(DOMAIN, TAG, 'connection[%{public}d] edges=%{public}d posts=%{public}d',
          index, edges.length, posts.length);
        return page;
      }
      if (empty === null) {
        empty = page;
      }
    }
    return empty;
  }

  /**
   * 一条 edge → 帖子（认不出给 null）。
   *
   * 逐层试：先看 `node` 里那几种包装键（`media` / `media_or_ad`），再看 `node` 本身，
   * 最后看 edge 本身（有些连接把媒体直接挂在 edge 上）。
   */
  private static postOfEdge(edge: Record<string, Object>): ProfilePost | null {
    const node: Record<string, Object> | null = NativeProfile.recordOf(edge, 'node');
    const roots: Array<Record<string, Object>> = [];
    if (node !== null) {
      roots.push(node);
    }
    roots.push(edge);
    for (let index: number = 0; index < roots.length; index++) {
      const root: Record<string, Object> = roots[index];
      for (let w: number = 0; w < MEDIA_WRAPPERS.length; w++) {
        const inner: Record<string, Object> | null =
          NativeProfile.recordOf(root, MEDIA_WRAPPERS[w]);
        if (inner === null) {
          continue;
        }
        const wrapped: ProfilePost | null = NativeProfile.postOf(inner);
        if (wrapped !== null) {
          return wrapped;
        }
      }
      const direct: ProfilePost | null = NativeProfile.postOf(root);
      if (direct !== null) {
        return direct;
      }
    }
    return null;
  }

  /**
   * `data` 里所有"带 edges 的连接对象"：已知的帖子连接排第一，其余按出现顺序跟上。
   *
   * **递归找**（最多 4 层）：实测四个分页的包装完全不一样 ——
   *   帖子：`data.xdt_api__v1__feed__user_timeline_graphql_connection`（顶层）；
   *   被标注：`data.xdt_api__v1__usertags__user_id__feed_connection`（顶层）；
   *   视频 / 收藏：顶层只有 `fetch__XDTUserDict` / `viewer` 这种**包装对象**，
   *     媒体连接藏在它们里面（原来只在 data 的**直接子节点**里找，所以这两页永远是 0 条）。
   * 只认"有 edges 数组"的对象，深度封顶——IG 的包装一般两三层，超过就当没看见。
   */
  private static connectionsOf(data: Record<string, Object>): Array<Record<string, Object>> {
    const out: Array<Record<string, Object>> = [];
    const known: Record<string, Object> | null = NativeProfile.recordOf(data, POSTS_CONN);
    if (known !== null && known['edges'] !== undefined) {
      out.push(known);
    }
    NativeProfile.collectConnections(data, 0, out);
    return out;
  }

  /** 递归收集（见 connectionsOf 的说明）。 */
  private static collectConnections(node: Record<string, Object>, depth: number,
                                     out: Array<Record<string, Object>>): void {
    if (depth > CONNECTION_MAX_DEPTH) {
      return;
    }
    if (node['edges'] !== undefined && Array.isArray(node['edges'])) {
      if (out.indexOf(node) < 0) {
        out.push(node);
      }
    }
    const keys: Array<string> = Object.keys(node);
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = NativeProfile.asRecord(node[keys[index]]);
      if (child !== null) {
        NativeProfile.collectConnections(child, depth + 1, out);
        continue;
      }
      // 数组里也可能挂着连接（edges[].node 之外还有别的包装）。
      const list: Array<Object> = NativeProfile.arrayOf(node, keys[index]);
      for (let at: number = 0; at < list.length && at < 4; at++) {
        const one: Record<string, Object> | null = NativeProfile.asRecord(list[at]);
        if (one !== null) {
          NativeProfile.collectConnections(one, depth + 1, out);
        }
      }
    }
  }

  /**
   * 一条节点 → 网格用的那几个字段。
   *
   * 封面判据（这段是"用户主页/我的页封面加载太慢"的修复点）：
   *   1. **优先图片候选里的小档**（约 360px，见 COVER_WIDTH）——`candidates[0]` 是 IG 给的**最大**
   *      那一档（一二百 KB 一张），一屏十几张就是几 MB；视频帖更是直接指向 mp4
   *      （`video_versions[0].url`，`Image` 根本渲染不出来，格子会一直空着）。
   *   2. 只有**完全没有图片候选**时才退回视频那一档（至少还有个东西可画）。
   *   3. 多图帖没有封面时取第一张子媒体（同以前）。
   */
  private static postOf(node: Record<string, Object>): ProfilePost | null {
    const code: string = NativeProfile.strOf(node, 'code');
    if (code.length === 0) {
      return null;
    }
    const videos: Array<Object> = NativeProfile.arrayOf(node, 'video_versions');
    /*
     * **是不是视频**：`video_versions` 非空当然是；但收藏 / 被标注那两段的查询**只给封面、
     * 不给视频地址**（真机实测：`video_versions` 整个缺省），这时只能看 IG 自己的
     * `media_type`（1 = 图片，2 = 视频）。
     *
     * 不认这一位的话，那些帖子会被当成**图片**：卡片走单图那条路，视频只剩一张封面
     * （用户报的"收藏分页点进帖子视频无法正常播放，只有封面"）。地址由
     * core/NativeMediaInfo 按 media id 后补（见 pages/Index.loadPostPageVideos）。
     */
    const mediaType: number = NativeProfile.numOf(node, 'media_type');
    const isVideoNode: boolean = videos.length > 0 || mediaType === 2;
    const images: Record<string, Object> | null = NativeProfile.recordOf(node, 'image_versions2');
    const candidates: Array<Object> = images === null
      ? [] : NativeProfile.arrayOf(images, 'candidates');
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const one: Record<string, Object> | null = NativeProfile.asRecord(candidates[index]);
      if (one === null) {
        continue;
      }
      const url: string = NativeProfile.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(NativeProfile.numOf(one, 'width'));
      heights.push(NativeProfile.numOf(one, 'height'));
    }
    const picked: PickedMedia = MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH);
    // 展示档（1080）与下载档：帖子页那张大卡片用它们（网格只用上面的小档，见 ProfilePost）。
    const display: PickedMedia = MediaQuality.displayImage(urls, widths, heights);
    const original: PickedMedia = MediaQuality.originalImage(urls, widths, heights);
    let cover: string = picked.url;
    if (cover.length === 0) {
      /*
       * 没有图片候选时，**不要把视频地址（mp4）当封面**。
       *
       * 老代码这里回退到 `video_versions[0].url`（一个 mp4）：`Image` 渲染不出来，真机上会画成
       * 一块乱码/黑块 —— 用户报的"收藏分页第一排直接被刚收藏的视频那一排覆盖"就是这个
       * （收藏 / 视频这两段进来的视频条目很多都没有图片候选，于是第一排整排都是坏封面）。
       * 留空更干净：网格会走占位图（见 ProfilePage 的 gridCell），而不是把 mp4 交给 Image。
       * 视频本身照样能播（`videoUrl` 单独带，见下面 displayVideo/originalVideo）。
       */
      const fallback: string = videos.length > 0
        ? NativeProfile.strOf(NativeProfile.asRecord(videos[0]) ?? node, 'url') : '';
      if (fallback.length > 0 && NativeProfile.diagCoverDropped === 0) {
        NativeProfile.diagCoverDropped = 1;
        hilog.info(DOMAIN, TAG,
          'cover: no image candidate, dropping video url (mp4) id=%{public}s url=%{public}s',
          NativeProfile.strOf(node, 'pk'), fallback.substring(0, 48));
      }
      cover = '';
    }
    let width: number = NativeProfile.numOf(node, 'original_width');
    let height: number = NativeProfile.numOf(node, 'original_height');
    if (width <= 0 || height <= 0) {
      width = picked.width;
      height = picked.height;
    }
    // 多图/多视频：没有封面就取第一张子媒体（格子只画一张）。
    /*
     * 帖子页（feeds 流样式）要的字段：这一页把整个分页的帖子铺成信息流那张大卡片，
     * 所以除了封面，还要正文、作者、展示/下载档地址、时间 —— 都从同一个 media 节点里读，
     * 一次取数就把两边的数据都备齐了（帖子页因此不用再发任何请求）。
     */
    const user: Record<string, Object> | null = NativeProfile.recordOf(node, 'user');
    const captionNode: Record<string, Object> | null = NativeProfile.recordOf(node, 'caption');
    const caption: string = captionNode === null ? '' : NativeProfile.strOf(captionNode, 'text');
    const username: string = user === null ? '' : NativeProfile.strOf(user, 'username');
    const avatar: string = user === null ? '' : NativeProfile.avatarOf(user);
    const ownerId: string = user === null ? '' : NativeProfile.strOf(user, 'pk');
    const friend: Record<string, Object> | null = user === null
      ? null : NativeProfile.recordOf(user, 'friendship_status');
    const following: boolean = friend !== null && NativeProfile.boolOf(friend, 'following');
    const displayVideo: string = videos.length > 0
      ? NativeProfile.strOf(NativeProfile.asRecord(videos[0]) ?? node, 'url') : '';
    const best: Record<string, Object> | null = NativeProfile.asRecord(videos[videos.length - 1]);
    const originalVideo: string = best === null ? displayVideo : NativeProfile.strOf(best, 'url');
    const takenAt: number = NativeProfile.numOf(node, 'taken_at') * 1000;
    // 转发数：不同查询给的名字不一样（`media_repost_count` 是媒体节点上那个，`repost_count` 也有）。
    // 以前这里压根没读，于是收藏 / 被标注 / 帖子三段进来的卡片**转发数永远是 0**
    // （用户报的"也没有显示转发数量"）。
    let repostCount: number = NativeProfile.numOf(node, 'media_repost_count');
    if (repostCount <= 0) {
      repostCount = NativeProfile.numOf(node, 'repost_count');
    }
    // 媒体数字 id：见 `mediaIdOfNode`（这里最容易出"点赞打到不存在的媒体"那个坑）。
    const mediaId: string = NativeProfile.mediaIdOfNode(node);
    /*
     * 点赞态：**载荷里本来就有**（移动端 REST 是 `has_liked`，GraphQL 是 `viewer_has_liked`）。
     * 以前这里压根没读，于是"我的页面四个分页 → feeds 页 / reels 页"里所有卡片都画成未点赞
     * （用户报的"没有正确读取点赞状态"）。会话覆盖表仍然优先，见 model/Profile 的 toMediaPost。
     */
    const liked: boolean = NativeProfile.boolOf(node, 'has_liked')
      || NativeProfile.boolOf(node, 'viewer_has_liked')
      || NativeProfile.boolOf(node, 'liked');
    const displayImages: Array<string> = display.url.length > 0 ? [display.url] : [];

    /*
     * **多图帖：把所有子媒体都收进来**（需求："多图片帖子只显示一张"就是这里）。
     *
     * 帖子页那张大卡片是多图轮播（FeedList → MediaCarousel，`imageUrls.length > 1` 才画 Swiper）；
     * 而 IG 的多图帖**外层节点常常自己也带一张图**（第一张），所以"外层有没有封面"这个判据
     * 不能用来决定要不要收子媒体 —— 以前正是靠它（`if (cover.length === 0)`），于是一遇到
     * "外层带图"的多图帖就只拿到一张。现在只要节点里有 `carousel_media` 就整串收，
     * 外层那张只用来当封面/比例（都是第一张）。
     *
     * 网格那边只用第一张（coverUrl），所以多收的是纯增量。
     */
    const carousel: Array<Object> = NativeProfile.arrayOf(node, 'carousel_media');
    if (carousel.length > 0) {
      const displayList: Array<string> = [];
      const originalList: Array<string> = [];
      let firstCover: string = cover;
      let firstDisplay: string = display.url;
      let firstWidth: number = width;
      let firstHeight: number = height;
      let firstVideo: string = displayVideo;
      let firstVideoOriginal: string = originalVideo;
      let anyVideo: boolean = isVideoNode;
      /*
       * 多图帖**最高那张**的宽高比（w/h，取最小；需求："媒体区高度根据高度最高的图片"）。
       * 外层节点自己那张也算一份（它通常就是第一张，但少数帖子外层给的是另一张）。
       * 两边都量不到的条目直接跳过 —— 有一张量不到就不敢用它当"最高"。
       */
      let minAspect: number = 0;
      if (width > 0 && height > 0) {
        minAspect = width / height;
      }
      for (let index: number = 0; index < carousel.length && index < 10; index++) {
        const one: Record<string, Object> | null = NativeProfile.asRecord(carousel[index]);
        if (one === null) {
          continue;
        }
        const inner: ProfilePost | null = NativeProfile.postOf(one);
        if (inner === null) {
          continue;
        }
        if (inner.width > 0 && inner.height > 0) {
          const ratio: number = inner.width / inner.height;
          if (minAspect <= 0 || ratio < minAspect) {
            minAspect = ratio;
          }
        }
        if (displayList.length === 0) {
          // 第一张子媒体同时兜底封面与比例（外层没给的时候用它的）。
          if (firstCover.length === 0) {
            firstCover = inner.coverUrl;
          }
          if (firstDisplay.length === 0) {
            firstDisplay = inner.displayUrl;
          }
          if (firstWidth <= 0 || firstHeight <= 0) {
            firstWidth = inner.width;
            firstHeight = inner.height;
          }
          if (firstVideo.length === 0) {
            firstVideo = inner.videoUrl;
            firstVideoOriginal = inner.originalVideoUrl;
          }
        }
        if (inner.displayUrl.length > 0 && displayList.indexOf(inner.displayUrl) < 0) {
          displayList.push(inner.displayUrl);
        }
        const original: string = inner.originalImageUrls.length > 0 ? inner.originalImageUrls[0] : '';
        if (original.length > 0 && originalList.indexOf(original) < 0) {
          originalList.push(original);
        }
        if (inner.isVideo) {
          anyVideo = true;
        }
      }
      if (displayList.length > 0) {
        return new ProfilePost(code, anyVideo, firstCover, firstWidth, firstHeight,
          NativeProfile.numOf(node, 'like_count'), NativeProfile.numOf(node, 'comment_count'),
          firstDisplay, displayList,
          originalList.length > 0 ? originalList : displayList,
          firstVideo, firstVideoOriginal,
          caption, username, avatar, ownerId, following, takenAt, mediaId,
          displayList.length > 1 ? minAspect : 0, repostCount, liked);
      }
    }
    return new ProfilePost(code, isVideoNode, cover, width, height,
      NativeProfile.numOf(node, 'like_count'), NativeProfile.numOf(node, 'comment_count'),
      display.url, displayImages, original.url.length > 0 ? [original.url] : displayImages,
      displayVideo, originalVideo, caption, username, avatar, ownerId, following, takenAt,
      mediaId, 0, repostCount, liked);
  }

  /**
   * 媒体节点 → **精确的数字媒体 id**（拿不到给空串）。
   *
   * 三条来源的可信度不一样，顺序不能乱：
   *   ① `strong_id__`：GraphQL 专门为"19 位 id 超出 f64 精度"给的那个**字符串**字段，最准；
   *   ② `id`：移动端 REST 给的是 `"<媒体id>_<作者id>"` **字符串** —— 取 `_` 前面那段就是媒体 id；
   *   ③ `pk`：**只有它本身是字符串时才敢用**。它是 19 位数字，`JSON.parse` 之后已经丢精度
   *      （`1234567890123456789` → `1234567890123456800`），拿它发点赞会打到一条**不存在**的媒体上
   *      （真机现象：从个人页那几个分页点赞"没反应/失败"，而信息流点赞是好的）。
   *
   * 三条都没有就返回空串：调用方会拿 shortcode 去换一个（见 MobileEngage.mediaPkFor），
   * 那比拿一个错 id 硬发要靠谱得多。
   */
  private static mediaIdOfNode(node: Record<string, Object>): string {
    const strong: string = NativeProfile.strOf(node, 'strong_id__').trim();
    if (NativeProfile.isDigits(strong)) {
      return strong;
    }
    const rawId: string = NativeProfile.strOf(node, 'id').trim();
    const cut: number = rawId.indexOf('_');
    const head: string = cut > 0 ? rawId.substring(0, cut) : rawId;
    if (NativeProfile.isDigits(head)) {
      return head;
    }
    const pk: Object | undefined = node['pk'];
    if (typeof pk === 'string' && NativeProfile.isDigits((pk as string).trim())) {
      return (pk as string).trim();
    }
    return '';
  }

  /** 纯数字串？（空串算否） */
  private static isDigits(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    for (let index: number = 0; index < text.length; index++) {
      const ch: string = text.charAt(index);
      if (ch < '0' || ch > '9') {
        return false;
      }
    }
    return true;
  }

  /**
   * 一个 `user` 节点里的**头像地址**（读不到给空串）。
   *
   * 为什么要试这么多字段：IG 不同查询给的 user 对象详略不一样 —— 信息流那条有
   * `profile_pic_url`，而**收藏 / 被标注**那两段（以及部分新接口）只给 HD 那份
   * （`profile_pic_url_hd` 或 `hd_profile_pic_url_info.url`）。只认 `profile_pic_url` 的话，
   * 那几段帖子页上的头像就是一块空底色（用户报的"需要正确显示用户头像"）。
   * 真机实测：读到空时打一行 user 的键名，方便对上新字段。
   */
  private static avatarOf(user: Record<string, Object>): string {
    const direct: string = NativeProfile.strOf(user, 'profile_pic_url');
    if (direct.length > 0) {
      return direct;
    }
    const hd: string = NativeProfile.strOf(user, 'profile_pic_url_hd');
    if (hd.length > 0) {
      return hd;
    }
    const hdInfo: Record<string, Object> | null =
      NativeProfile.recordOf(user, 'hd_profile_pic_url_info');
    if (hdInfo !== null) {
      const url: string = NativeProfile.strOf(hdInfo, 'url');
      if (url.length > 0) {
        return url;
      }
    }
    const info: Record<string, Object> | null = NativeProfile.recordOf(user, 'profile_pic_url_info');
    if (info !== null) {
      const url: string = NativeProfile.strOf(info, 'url');
      if (url.length > 0) {
        return url;
      }
    }
    // 只打一次：这件事是"某些查询的 user 对象里压根没有头像字段"（收藏 / 被标注那两段就是），
    // 每条帖子打一行会刷屏 —— 头像由页面那边按 id 后补（见 core/NativeUserInfo）。
    if (!NativeProfile.avatarDiagDone) {
      NativeProfile.avatarDiagDone = true;
      hilog.info(DOMAIN, TAG, 'avatar missing on user keys=%{public}s',
        Object.keys(user).slice(0, 14).join(','));
    }
    return '';
  }

  /** 上面那条诊断只打一次（见 avatarOf）。 */
  private static avatarDiagDone: boolean = false;

  /**
   * 下面这几个读法都搬到 core/JsonRead 了（搜索页也要用同一套），这里只留一个入口名，
   * 免得每个调用点都记住两个类名。
   */
  private static parse(text: string): Record<string, Object> {
    return JsonRead.parse(text);
  }

  private static asRecord(value: Object | null | undefined): Record<string, Object> | null {
    return JsonRead.asRecord(value);
  }

  private static recordOf(host: Record<string, Object>, key: string): Record<string, Object> | null {
    return JsonRead.recordOf(host, key);
  }

  private static arrayOf(host: Record<string, Object>, key: string): Array<Object> {
    return JsonRead.arrayOf(host, key);
  }

  private static strOf(host: Record<string, Object>, key: string): string {
    return JsonRead.strOf(host, key);
  }

  private static numOf(host: Record<string, Object>, key: string): number {
    return JsonRead.numOf(host, key);
  }

  private static boolOf(host: Record<string, Object>, key: string): boolean {
    return JsonRead.boolOf(host, key);
  }
}
