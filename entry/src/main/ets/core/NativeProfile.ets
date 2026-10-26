/*
 * 「我的」页面的**取数** —— 只走移动端私有接口（core/mobileapi/MobileProfile，instagrapi 同源）。
 *
 *   · 头部     users/{pk}/info/（或 users/web_profile_info/?username=）
 *   · 四个分页 feed/user/{pk}/、clips/user/、usertags/{pk}/feed/、feed/saved/
 *   · 高光     highlights/{pk}/
 *
 * 请求由 core/mobileapi 统一签名（App 身份 + 会话字段），**不需要网页模板**，响应在原生侧解析。
 *
 * ## 历史
 * 这里原来是"回放网页抓来的 GraphQL 模板（PolarisProfile*）+ variables.after 翻页"。
 * 页面注入退役后模板抓不到、里面的 doc_id 与 fb_dtsg 也过期，那套一并删除。
 *
 * ## 分页
 * 游标直接用移动端的 next_max_id（与网页游标互不通用，但这一路只走移动端）。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsonRead } from './JsonRead';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';
import { ApiThrottle } from './ApiThrottle';
import { MobileProfile, MobileUserBody, MobileGridPage } from './mobileapi/MobileProfile';
import { ProfileHeader, ProfileHighlight, ProfileMusic, ProfilePost, ProfilePostsPage } from '../model/Profile';
// UA 的**唯一来源**（见 AppConfig.webUserAgent）：这里只读取，不再自己拼一份型号。
import { AppConfig } from '../config/AppConfig';

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

  /**
   * 自己的数字 id（Cookie 里的 `ds_user_id`），**每次调用都重新读一次**。
   *
   * ⚠️ 这里以前是"读一次就缓存到进程结束"，那是个真 bug：换账号 / 重新登录之后
   * `ds_user_id` 变了、缓存还是旧值 —— 于是"我的"页面按**上一个账号的 id** 去取
   * `users/{pk}/info/`，拿回来的是**别人的头部**（用户报的"我的页面会出现拿到的不是
   * 本账号头部数据"）。读 Cookie 罐很便宜（`MobileRequest` 每一发请求也在读它），
   * 所以别再缓存"结果"，只在读失败时用上一次的值兜底。
   */
  static async ownId(): Promise<string> {
    let fresh: string = '';
    try {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const cookie: string = jar.cookie ?? '';
      const parts: Array<string> = cookie.split(';');
      for (let index: number = 0; index < parts.length; index++) {
        const one: string = parts[index].trim();
        if (one.indexOf('ds_user_id=') === 0) {
          fresh = one.substring('ds_user_id='.length).trim();
          break;
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'own id read failed: %{public}s', (error as Error).message);
    }
    if (fresh.length === 0) {
      // 读不到（Cookie 罐还没起来 / 已退出登录）：用上一次读到的兜底，空就空。
      return NativeProfile.ownIdCache;
    }
    if (NativeProfile.ownIdCache.length > 0 && NativeProfile.ownIdCache !== fresh) {
      /*
       * 账号换了（或者网页那边重新登录了）。这里必须说出来：之后所有"本人"的请求都会
       * 用新 id，而视图模型里缓存的 ownName / header 还是上一个账号的 —— 不清就会
       * **自洽地显示错的人**（头部按新 id 取、核对却拿旧名字比，比不出来）。
       */
      hilog.info(DOMAIN, TAG, 'own id changed %{public}s → %{public}s (account switched)',
        NativeProfile.ownIdCache, fresh);
    }
    NativeProfile.ownIdCache = fresh;
    return fresh;
  }

  /** 清掉进程内的账号相关缓存（退出登录 / 换账号时调，见 ownId 的说明）。 */
  static clearCache(): void {
    NativeProfile.ownIdCache = '';
    NativeProfile.detail = '-';
    NativeProfile.headerCache.clear();
    NativeProfile.headerCacheAt.clear();
    NativeProfile.headerInflight.clear();
  }

  /** 已经读到的自己的数字 id（同步；没读过给空串，见 ownId）。 */
  static ownIdCached(): string {
    return NativeProfile.ownIdCache;
  }

  /**
   * 用户节点里的数字 id（`pk` 优先，退回 `id`）。
   *
   * 用途：核对 `users/{pk}/info/` 回来的到底是不是**我要的那个人**。登录账号的 id 是
   * 十一位量级，`pk` 在 JSON 里是 number 也不会丢精度（19 位的媒体 id 才需要 `strong_id__`）。
   */
  static userIdOf(user: Record<string, Object> | null): string {
    if (user === null) {
      return '';
    }
    const pk: string = NativeProfile.strOf(user, 'pk').trim();
    if (pk.length > 0) {
      return pk;
    }
    const asNumber: number = NativeProfile.numOf(user, 'pk');
    if (asNumber > 0) {
      return `${asNumber}`;
    }
    return NativeProfile.strOf(user, 'id').trim();
  }

  /**
   * 最近一次原生请求为什么失败（`http-403` / `no-template` / `throw:…`）。
   *
   * 为什么要留一份：这条链路的失败一直在**界面状态行**上（hilog 会被系统刷掉），
   * 而"请求失败"和"解析出 0 条"是两种完全不同的毛病（前者要查头/模板，后者要查形状），
   * 不把 detail 带出去就只能靠猜。
   */
  private static detail: string = '-';
  /** 是否已经把 user 的键名打过一行日志（见 headerFromUser，只为找字段名）。 */
  private static loggedUserKeys: boolean = false;
  /** "因为没有图片候选而丢掉了 mp4 封面"这件事只记一次（见 postOf 的 cover 兜底）。 */
  private static diagCoverDropped: number = 0;

  /** 最近一次失败的原因（成功时清成 `-`）。 */
  static lastDetail(): string {
    return NativeProfile.detail;
  }

  /**
   * 头部结果的**短缓存**（key = 目标用户的数字 id）。
   *
   * 为什么需要（用户报的"从新号切回大号，获取头部数据太慢"）：`users/{pk}/info/` 这一发
   * 在真机上经常被**限速闸门**排在别的请求后面（日志里 `waited=2494ms`、甚至
   * `waited=24106ms`），而"我的"页每进一次都会要一次。同一个账号 5 分钟内不会变，
   * 缓存住它就够了；换账号时 `clearCache()` 一并清掉。
   */
  private static headerCache: Map<string, ProfileHeader> = new Map<string, ProfileHeader>();
  private static headerCacheAt: Map<string, number> = new Map<string, number>();
  /** 同一个目标**正在飞的那一发**（两次 load 同时要头部时只打一次接口）。 */
  private static headerInflight: Map<string, Promise<ProfileHeader | null>> =
    new Map<string, Promise<ProfileHeader | null>>();
  private static readonly HEADER_TTL_MS: number = 5 * 60 * 1000;

  /**
   * 拉一次个人页头部（拿不到就 null）。
   *
   * 外面这层只管三件事：**缓存命中**、**并发合并**、**成功后回填缓存**；
   * 真正的取数在 loadHeaderBody 里（移动端优先、模板回放兜底）。
   */
  /**
   * 按账号名问一次数字 id（用户主页路由要它：`feed/user/{pk}/` 这类端点只认 pk）。
   *
   * 用途：简介里的 `@账号` 只有名字，点开主页时得先把 id 补上，否则那一页的网格/头部
   * 都只有"按用户名"那半边能用、整页会像"加载不出来"（用户报的就是这个）。
   */
  static async userIdByUsername(username: string): Promise<string> {
    const name: string = username.trim();
    if (name.length === 0) {
      return '';
    }
    const body: MobileUserBody | null = await MobileProfile.info('', name,
      ApiThrottle.interactive());
    if (body === null) {
      hilog.info(DOMAIN, TAG, 'userIdByUsername miss @%{public}s', name);
      return '';
    }
    const id: string = NativeProfile.userIdOf(body.user);
    hilog.info(DOMAIN, TAG, 'userIdByUsername @%{public}s → %{public}s', name, id);
    return id;
  }

  static async fetchHeader(target: ProfileTarget = ProfileTarget.self()): Promise<ProfileHeader | null> {
    return NativeProfile.headerWithCache(target);
  }

  /**
   * 精选快拍（个人页高光那排）。
   *
   * 就是移动端 `highlights_tray/<pk>/` 的薄包装（见 core/mobileapi/MobileProfile.highlights）——
   * 放在这里是为了让视图模型只依赖 NativeProfile 这一层。
   */
  static async highlights(userId: string): Promise<Array<ProfileHighlight>> {
    return MobileProfile.highlights(userId, ApiThrottle.warm());
  }

  private static async headerWithCache(target: ProfileTarget): Promise<ProfileHeader | null> {
    let uid: string = target.id;
    if (uid.length === 0 && target.isSelf()) {
      uid = await NativeProfile.ownId();
    }
    const key: string = uid.length > 0 ? uid : `name:${target.username}`;
    const cached: ProfileHeader | undefined = NativeProfile.headerCache.get(key);
    const at: number = NativeProfile.headerCacheAt.get(key) ?? 0;
    if (cached !== undefined && Date.now() - at < NativeProfile.HEADER_TTL_MS) {
      hilog.info(DOMAIN, TAG, 'header cached key=%{public}s age=%{public}dms',
        key, Date.now() - at);
      return cached;
    }
    const inflight: Promise<ProfileHeader | null> | undefined =
      NativeProfile.headerInflight.get(key);
    if (inflight !== undefined) {
      hilog.info(DOMAIN, TAG, 'header join inflight key=%{public}s', key);
      return inflight;
    }
    const job: Promise<ProfileHeader | null> = NativeProfile.loadHeaderCached(target, key);
    NativeProfile.headerInflight.set(key, job);
    job.then((): void => {
      NativeProfile.headerInflight.delete(key);
    }).catch((): void => {
      NativeProfile.headerInflight.delete(key);
    });
    return job;
  }

  private static async loadHeaderCached(target: ProfileTarget,
                                        key: string): Promise<ProfileHeader | null> {
    const header: ProfileHeader | null = await NativeProfile.loadHeaderBody(target);
    if (header !== null) {
      NativeProfile.headerCache.set(key, header);
      NativeProfile.headerCacheAt.set(key, Date.now());
    }
    return header;
  }

  /** 拉一次个人页头部（拿不到就 null）——**不带缓存的那一层**，见 fetchHeader。 */
  private static async loadHeaderBody(target: ProfileTarget): Promise<ProfileHeader | null> {
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
      /*
       * **本人这一发一定要核对"回来的是不是我自己"**（用户报的"我的页面会出现拿到的不是
       * 本账号头部数据"）。
       *
       * 判据用**数字 id**，不用账号名：id 是从当前会话的 Cookie（`ds_user_id`）现读的，
       * 服务端回的 `user.pk` 必须与它一致。以前没有这道校验，只要 id 读旧了（换账号后
       * 缓存没清），`users/{旧id}/info/` 顺顺当当返回**上一个账号**的资料，界面上就是
       * "我的页面显示成别人"。
       */
      if (target.isSelf() && uid.length > 0) {
        const got: string = NativeProfile.userIdOf(mobile.user);
        if (got.length > 0 && got !== uid) {
          hilog.warn(DOMAIN, TAG, 'header mobile is another account asked=%{public}s got=%{public}s → ignore',
            uid, got);
          // 账已换：把缓存清掉，下一次调用会按新的 Cookie 重新取。
          NativeProfile.ownIdCache = '';
          return null;
        }
      }
      const mapped: ProfileHeader | null = NativeProfile.headerFromUser(mobile.user);
      if (mapped !== null) {
        hilog.info(DOMAIN, TAG, 'header via mobile user=%{public}s ms=%{public}d bytes=%{public}d',
          mapped.username, mobile.ms, mobile.bytes);
        return mapped;
      }
    }
    // 移动端这一发没拿到：如实回报（原先的网页模板兜底已随模板机制删除）。
    hilog.warn(DOMAIN, TAG, 'header mobile miss uid=%{public}d user=%{public}s',
      uid.length, target.username);
    NativeProfile.detail = 'header-mobile-miss';
    return null;
  }

  /**
   * 按当前会话的 id 问一次**自己的用户名**（拿不到给空串）。
   *
   * 用途：视图模型解析"我是谁"有两条路 —— 隐藏网页的地址（`OWN_PROFILE_SCRIPT`）和这里。
   * 网页桥不可用时（引擎还没就绪 / 共用网页正被别的流程导航）前者会失败，
   * 而"没有账号名"会让后面"重抓模板 / 收藏被标注按用户名取"全部卡住 ——
   * 这时按 `ds_user_id` 问一发 `users/{pk}/info/` 就能把名字补回来，代价只是一发小请求。
   */
  static async selfUsername(): Promise<string> {
    const uid: string = await NativeProfile.ownId();
    if (uid.length === 0) {
      return '';
    }
    /*
     * 交互优先级：这一发是"回放模板"的前置条件，用户正等着界面出东西，
     * 排到预取/自检后面会白等好几秒（见 ProfileViewModel.ensureOwnName）。
     */
    const mobile: MobileUserBody | null = await MobileProfile.info(uid, '', ApiThrottle.interactive());
    if (mobile === null) {
      return '';
    }
    return NativeProfile.strOf(mobile.user, 'username').trim();
  }

  /**
   * 拉一页网格（拿不到就 null）。
   *
   * **只走移动端**（四个分页各有对应端点，见 core/mobileapi/MobileProfile.tab）：
   * 帖子 feed/user/{pk}/、Reels clips/user/、被标注 usertags/{pk}/feed/、收藏 feed/saved/。
   * 模板回放那条退路已随模板机制删除：失败就如实回报，由界面提示重试。
   */
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
     * 合成操作名（`mobile:clips`）以前在这里直接 return null 是**错的**（那条分支等于
     * "移动端失败就什么都不试"，收藏/被标注的整段加载不出来就是它造成的）——
     * 现在由调用方先试移动端、再带着 `skipMobile` 走模板，两条路都走完才算失败。
     */
    const kind: string = NativeProfile.mobileKindOf(op);
    if (kind.length === 0) {
      NativeProfile.detail = 'unknown-kind';
      hilog.warn(DOMAIN, TAG, 'fetchPosts unknown op=%{public}s', op);
      return null;
    }
    let uid: string = target.id;
    if (uid.length === 0 && target.isSelf()) {
      uid = await NativeProfile.ownId();
    }
    if (uid.length === 0 && target.username.length > 0) {
      uid = await NativeProfile.userIdByUsername(target.username);
    }
    if (uid.length === 0) {
      NativeProfile.detail = 'no-user-id';
      return null;
    }
    const page: MobileGridPage | null = await MobileProfile.tab(kind, uid, after, undefined,
      ApiThrottle.interactive());
    if (page === null) {
      NativeProfile.detail = `tab-${kind}-fail`;
      hilog.warn(DOMAIN, TAG, 'tab failed kind=%{public}s uid=%{public}s', kind, uid);
      return null;
    }
    const posts: Array<ProfilePost> = NativeProfile.postsFromItems(page.items);
    hilog.info(DOMAIN, TAG,
      'tab via mobile kind=%{public}s uid=%{public}s items=%{public}d posts=%{public}d more=%{public}s ms=%{public}d',
      kind, uid, page.items.length, posts.length, `${page.hasMore}`, page.ms);
    NativeProfile.detail = '-';
    // 移动端这一路只走移动端，所以直接交它的 `next_max_id`。
    return new ProfilePostsPage(posts, page.nextCursor, page.hasMore);
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

  /**
   * 这一分页在"没有模板"时的**合成操作名**（`mobile:clips` 这种，见 viewmodel/ProfileViewModel.opNameOf）。
   *
   * 以前这里要 `MobileProfile.tabUsable(kind)` 为真才给（帖子/被标注乐观、Reels/收藏要先"试出来"），
   * 于是**新进程里 Reels / 收藏两段永远没有操作名** → 视图模型只能去跑"抓模板"那条冷路径
   * （导航隐藏网页、秒级、可能失败）→ 用户看到的就是"我的页面四个分页有时加载不出来"。
   *
   * 现在一律给合成名：`fetchPage` 会先试移动端这一发，失败再带着 `skipMobile` 退回模板，
   * 两条路都走完才算失败 —— "先试试移动端"不该被一个进程内的学习标记挡住。
   */
  static mobileOpFor(kind: string): string {
    if (kind.length === 0) {
      return '';
    }
    return `${NativeProfile.MOBILE_OP_PREFIX}${kind}`;
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

  static headerFromUser(user: Record<string, Object>): ProfileHeader | null {
    const username: string = NativeProfile.strOf(user, 'username');
    if (username.length === 0) {
      return null;
    }
    // 一次性把和音乐相关的键打出来（找字段名用；只打一次，别刷屏）。
    if (!NativeProfile.loggedUserKeys) {
      NativeProfile.loggedUserKeys = true;
      const musicKeys: Array<string> = Object.keys(user)
        .filter((key: string): boolean => key.indexOf('music') >= 0
          || key.indexOf('audio') >= 0 || key.indexOf('song') >= 0);
      hilog.info(DOMAIN, TAG, 'user music keys=[%{public}s] has_music=%{public}s',
        musicKeys.join(','), `${NativeProfile.boolOf(user, 'has_music_on_profile')}`);
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
      followed,
      NativeProfile.musicOf(user),
      NativeProfile.boolOf(user, 'has_music_on_profile'));
  }

  /**
   * 从**网页版个人页的 HTML**里取背景音乐（移动端 `users/{pk}/info/` 只给布尔值）。
   *
   * IG 的个人页 HTML 里带着一段 SSR 数据，形如
   *   "profile_music":{"music_asset_info":{title,display_artist,progressive_download_url,…}}
   * 这里用"找键名 + 配对大括号"的方式把它整块切出来（不整页 JSON.parse：那不是合法 JSON），
   * 再解析标题/演唱者/音频地址。拿不到就 null —— 界面上那颗音乐胶囊就不显示。
   *
   * 代价：一发网页 HTML（几百 KB），所以只在"头部说 has_music_on_profile 但没给歌"时发一次。
   */
  static async fetchMusicByUsername(username: string): Promise<ProfileMusic | null> {
    const name: string = username.trim();
    if (name.length === 0) {
      return null;
    }
    const headers: Record<string, string> = await NativeProfile.webHeaders();
    if (Object.keys(headers).length === 0) {
      return null;
    }
    const url: string = `https://www.instagram.com/${encodeURIComponent(name)}/`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 12000,
        readTimeout: 12000,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      hilog.info(DOMAIN, TAG, 'profile html code=%{public}d len=%{public}d',
        response.responseCode, text.length);
      const raw: string = NativeProfile.objectAfter(text, 'profile_music');
      if (raw.length === 0) {
        /*
         * 没找到就把 HTML 里第一处 "music 前后的片段打出来（只打一次）：
         * IG 各版本字段名不一样，凭这一段就能把键名对上，不用再猜。
         */
        const at: number = text.toLowerCase().indexOf('music');
        hilog.info(DOMAIN, TAG, 'profile html music at=%{public}d snip=%{public}s',
          at, at >= 0 ? text.substring(Math.max(0, at - 60), at + 140)
            .replace(/[\r\n]+/g, ' ') : '-');
        hilog.info(DOMAIN, TAG, 'profile music not in html');
        return null;
      }
      const music: ProfileMusic | null = NativeProfile.musicFromJson(raw);
      if (music !== null) {
        hilog.info(DOMAIN, TAG, 'profile music ok title=%{public}s playable=%{public}s',
          music.title, `${music.url.length > 0}`);
      }
      return music;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'profile music fetch failed: %{public}s',
        (error as Error).message);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 抓一次**网页版个人页 HTML** 要用的最小请求头（Cookie + 公开的网页 app id + 浏览器 UA）。
   *
   * 为什么不复用模板头：模板机制已经删除，而这条只读 HTML 的请求只需要"带着会话 Cookie"，
   * 不再需要 `x-ig-www-claim` / `fb_dtsg` 那类会话级令牌。
   */
  private static async webHeaders(): Promise<Record<string, string>> {
    let jar: InstagramCookieSnapshot;
    try {
      jar = await InstagramCookieJar.inspect();
    } catch (error) {
      return {};
    }
    if (!jar.signedIn) {
      return {};
    }
    const out: Record<string, string> = {};
    out['cookie'] = jar.cookie;
    out['x-ig-app-id'] = '1217981644879628';
    // 和 WebView / 私有 API 用**同一个**身份（见 AppConfig.webUserAgent）：三处各写一份
    // 型号名，就会出现"网页说 Pixel、原生说 HarmonyOS、邮件说第三个"的分裂。
    out['user-agent'] = AppConfig.webUserAgent();
    out['accept'] = 'text/html,application/xhtml+xml';
    out['accept-language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    return out;
  }

  /** 从文本里切出 `"key":{…}` 这一整块对象（按大括号配对，跳过字符串里的括号）。 */
  private static objectAfter(text: string, key: string): string {
    const at: number = text.indexOf(`"${key}"`);
    if (at < 0) {
      return '';
    }
    const start: number = text.indexOf('{', at);
    if (start < 0) {
      return '';
    }
    let depth: number = 0;
    let inString: boolean = false;
    let escaped: boolean = false;
    const limit: number = Math.min(text.length, start + 24000);
    for (let index: number = start; index < limit; index++) {
      const ch: string = text.charAt(index);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = !inString;
        continue;
      }
      if (inString) {
        continue;
      }
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          return text.substring(start, index + 1);
        }
      }
    }
    return '';
  }

  /** 一块 `profile_music` JSON → ProfileMusic（字段名各版本不一，能认多少认多少）。 */
  private static musicFromJson(raw: string): ProfileMusic | null {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(raw) as Record<string, Object>;
    } catch (error) {
      return null;
    }
    const holders: Array<string> = ['music_asset_info', 'audio_asset', 'music_consumption_info'];
    let holder: Record<string, Object> = root;
    for (let index: number = 0; index < holders.length; index++) {
      const inner: Record<string, Object> | null = NativeProfile.recordOf(root, holders[index]);
      if (inner !== null) {
        holder = inner;
        break;
      }
    }
    const title: string = NativeProfile.firstString(holder,
      ['title', 'display_title', 'song_name', 'music_title']);
    if (title.length === 0) {
      return null;
    }
    const artist: string = NativeProfile.firstString(holder,
      ['display_artist', 'artist_name', 'subtitle', 'artist']);
    const url: string = NativeProfile.firstString(holder,
      ['progressive_download_url', 'download_url', 'audio_url', 'url']);
    return new ProfileMusic(title, artist, url);
  }

  /**
   * 从用户节点里挖**背景音乐**（横幅区那颗音乐胶囊要用）。
   *
   * IG 各版本把这歌挂在不同位置：`profile_music` / `music_metadata` / `audio_asset`，
   * 而且外层可能再包一层（`music_asset_info`）。这里按"找到哪个算哪个"取：
   * 标题、演唱者、可播放地址（`progressive_download_url` / `download_url` / `url`）。
   * 一个都找不到就给 null —— 界面上那颗胶囊就不显示（总比放个空壳好）。
   */
  private static musicOf(user: Record<string, Object>): ProfileMusic | null {
    const holders: Array<string> = ['profile_music', 'music_metadata', 'audio_asset'];
    for (let index: number = 0; index < holders.length; index++) {
      const outer: Record<string, Object> | null = NativeProfile.recordOf(user, holders[index]);
      if (outer === null) {
        continue;
      }
      // 再往里剥一层（`music_asset_info` / `music_consumption_info` 这类包装）。
      const inner: Record<string, Object> | null = NativeProfile.recordOf(outer, 'music_asset_info');
      const holder: Record<string, Object> = inner !== null ? inner : outer;
      const title: string = NativeProfile.firstString(holder,
        ['title', 'song_name', 'display_title', 'music_title']);
      if (title.length === 0) {
        continue;
      }
      const artist: string = NativeProfile.firstString(holder,
        ['display_artist', 'artist_name', 'subtitle', 'artist']);
      const url: string = NativeProfile.firstString(holder,
        ['progressive_download_url', 'download_url', 'audio_url', 'url']);
      hilog.info(DOMAIN, TAG, 'profile music key=%{public}s title=%{public}s playable=%{public}s',
        holders[index], title, `${url.length > 0}`);
      return new ProfileMusic(title, artist, url);
    }
    return null;
  }

  /** 按候选键取第一个非空字符串（音乐那种各版本字段名不一的解析用）。 */
  private static firstString(holder: Record<string, Object>, keys: Array<string>): string {
    for (let index: number = 0; index < keys.length; index++) {
      const value: string = NativeProfile.strOf(holder, keys[index]);
      if (value.length > 0) {
        return value;
      }
    }
    return '';
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
    /*
     * 分享数：候选名与信息流 / reels 那边**同一套**（IG 会改名，取第一个有值的）。
     *
     * 以前这条路根本不读它，`ProfileMapper.toMediaPost` 又写死 0 —— 于是"从我的主页点进
     * feeds 页 / reels 页"的那些卡片永远没有分享数（用户报的"看不到分享数量"里也有这一段）。
     * 取不到就是 0，界面按 0 把那颗数字整颗不画，不会挂一个 "0"。
     */
    let shareCount: number = NativeProfile.numOf(node, 'share_count');
    if (shareCount <= 0) {
      shareCount = NativeProfile.numOf(node, 'shares_count');
    }
    if (shareCount <= 0) {
      shareCount = NativeProfile.numOf(node, 'media_share_count');
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
          displayList.length > 1 ? minAspect : 0, repostCount, liked, shareCount);
      }
    }
    return new ProfilePost(code, isVideoNode, cover, width, height,
      NativeProfile.numOf(node, 'like_count'), NativeProfile.numOf(node, 'comment_count'),
      display.url, displayImages, original.url.length > 0 ? [original.url] : displayImages,
      displayVideo, originalVideo, caption, username, avatar, ownerId, following, takenAt,
      mediaId, 0, repostCount, liked, shareCount);
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
