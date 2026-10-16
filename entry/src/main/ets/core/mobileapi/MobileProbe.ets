/*
 * 移动 API 移植的**自检探针**。
 *
 * 为什么单独一个文件：这条链路（Cookie 罐 → 身份 → 请求骨架 → IG 是否接受）有很多"安静失败"
 * 的可能（会话读不到、claim 不对、challenge、被限流……），需要在真机日志里**一眼看出卡在哪一步**。
 * 本项目在网页那条路上已经吃过这个亏（见 AUDIT_TODO 的 E 类"静默失败"），所以移植一开始
 * 就把自检做成常驻能力，而不是临时往调用点塞日志。
 *
 * 三发请求，层层递进（任何一发失败都能定位到层）：
 *   ① `GET /api/v1/users/{uid}/info/` —— 最小的一发，只验"会话 + 请求骨架"能不能过；
 *   ② `POST /api/v1/feed/reels_tray/` —— 快拍托盘（本次移植的主目标之一）；
 *   ③ `POST /api/v1/direct_v2/inbox/` —— 私信收件箱（另一个主目标）。
 *
 * 探针**不解析数据**，只报形状（键名 / 条数 / 字节数）：解析交给各自的端点模块，
 * 这里的目标是"IG 认不认我们这套身份"。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
import { SUPPORTED_CAPABILITIES } from './MobileConfig';
import { InstagramProbe } from '../../probe/InstagramProbe';
import { DirectInboxPage, DirectMapper, DirectThreadView } from '../../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileProbe';

/**
 * 自检结论落盘的文件名（`dumpFixed` 会补 `.txt`）。
 *
 * 为什么要落盘：真机上 chromium 的日志会把 hilog 环形缓冲冲掉 —— 本项目在网页那条路上
 * 已经吃过这个亏（自检结论发出来了，但拉日志时那几行早没了）。落盘 + `hdc file recv`
 * 是这条链路上唯一可靠的取证方式（同 `core/StoryDiag` 的做法），也顺带让测试者能在
 * 设置页里直接读到结论（见 `lastSummary`）。
 */
const REPORT_NAME: string = 'Instarmony_mobile';

/**
 * **端点侦察**：把"下一步要接的移动端点"逐条打一发，把响应结构写进单独一份文件
 * （`filesDir/Instarmony_scout.txt`）。
 *
 * 为什么要它（而不是直接照 instagrapi 写解析）：移动端这些端点的形状每隔一阵就变
 * （托盘不再给 `items` 就是本项目踩过的例子），而"哪个端点在**我们这套身份**下通、
 * 顶层与嵌套键叫什么"只能问服务端。侦察跑一遍，写解析层就不用猜。
 *
 * 默认**关**：一次 7 发，只在移植新端点时手工打开（或从设定页那顆自检按钮触发）。
 */
const ENDPOINT_SCOUT: boolean = false;

/** 侦察用的搜索词（只读查询；用一个中性词，别拿真实用户名去搜）。 */
const SCOUT_QUERY: string = 'photo';

/** 侦察文件里每层最多打几个键（防一份响应铺满整份报告）。 */
const SCOUT_KEYS_PER_LEVEL: number = 14;
/** 侦察文件最深钻几层（`sectional_items[0].layout_content.medias[0].media` 是第 4~5 层）。 */
const SCOUT_MAX_DEPTH: number = 5;

/** 一条"翻页游标候选"（label 只用于报告）。 */
class CursorTry {
  readonly label: string;
  readonly value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/** 响应摘要里最多列几个键。 */
const MAX_KEYS: number = 14;
/** 摘要里每个值最多留多少字符。 */
const MAX_VALUE: number = 60;
/** 落盘时最多留几行形状（够写解析层就行，别把文件撑大）。 */
const MAX_SHAPE_LINES: number = 160;
/**
 * 是否在自检里跑**收件箱翻页传参实验**（`inboxPageVariants`）。
 *
 * 默认关：这个实验一发就是 6 条请求，而它的结论**已经跑出来了**（四种传法全被拒或被忽略，
 * 见 `MobileDirect.withCursor` 与 `INSTAGRAPI_PORT.md` 第 9.6 节）。留在自检里每次启动都白打
 * 六发、白白把 DIRECT 家族的限流窗口往前推 —— 要再研究时把它打开（或从设置页那个自检入口
 * 触发一次）即可，代码路径一直都在。
 */
const INBOX_CURSOR_EXPERIMENT: boolean = false;

export class MobileProbe {
  /** 上一次自检的结论（一行；给诊断面板用）。 */
  private static last: string = '-';
  /** 自检是否已经排过（App 可能因配置变化再走一次 onCreate，别重复发请求）。 */
  private static scheduled: boolean = false;
  /** 落盘用的上下文（`scheduleSelfTest` 传进来；没有就不落盘，只写日志）。 */
  private static context: common.UIAbilityContext | null = null;
  /** 本次自检里每一发的形状行（落盘用，见 logShape）。 */
  private static shape: Array<string> = [];
  /** 本次自检的身份摘要（落盘用；不含会话串的值）。 */
  private static identityLine: string = '-';
  /**
   * 托盘里第一条 reel 的 id（给 ⑤ `reels_media` 用）。
   *
   * 从**托盘那一发的响应**里现取，不写死：写死的 id 换账号就失效，
   * 而这一发正是用来回答"按 id 取快拍这条路通不通"的，前提必须是真实 id。
   */
  private static firstReelId: string = '';
  /** 托盘里第一条那个人的数字 id（给 ⑤「某个人的快拍」用；同样现取，不写死）。 */
  private static firstTrayUserId: string = '';
  /** 收件箱里第一条会话的 thread_id（给 ⑧「会话消息」用；现取，不写死）。 */
  private static firstThreadId: string = '';
  /** ⑧ 要试的 thread_id（前两条；对比用 —— 见 run() 里的说明）。 */
  private static threadIds: Array<string> = [];
  /**
   * **自己的用户名**（从 ① 那一发的响应里读出来）。
   *
   * 侦察 ⑦ 要按用户名问一发 `users/{username}/usernameinfo/`（别人主页只有用户名时走的那条），
   * 而写死名字换账号就失效 —— 所以从他自己的 `users/{id}/info/` 里现取。
   */
  private static selfUsername: string = '';
  /** 收件箱响应里给出的翻页游标（给 ⑨ 的传参实验用）。 */
  private static inboxCursor: string = '';
  /** 收件箱响应里的 `prev_cursor` / `prev_cursor_v2`（同样是翻页材料）。 */
  private static inboxPrevCursor: string = '';
  private static inboxPrevCursorV2: string = '';
  /**
   * ⑨ 要试的翻页游标候选（在 `describeInbox` 里按响应现填）。
   *
   * 上一轮实验只测了"结构游标整体/其 id 字段/prev_cursor 系列"进 `cursor` 参数 —— 全被 400 或忽略。
   * 这一轮补上**从没测过**的那几个：`oldest_cursor`（105 字符的字符串，看着最像游标）、
   * `prev_cursor_v2` 的原始值、以及**表单体里带游标**那种传法。
   */
  private static cursorTries: Array<CursorTry> = [];
  /**
   * 启动自检的延迟（毫秒）。
   *
   * 取 6 秒：要等 Web 内核把持久化 Cookie 载进罐、网页至少要开始加载
   * （见 EntryAbility.onCreate 的说明）。这段时间**不挡 UI**。
   */
  private static readonly DELAY_MS: number = 6000;

  static lastSummary(): string {
    return MobileProbe.last;
  }

  /**
   * **删掉自检报告文件**（退出登录 / 换账号时调）。
   *
   * 报告里有账号 uid、托盘/私信的形状摘要 —— 都属于上一个人。留着换账号后导出，
   * 等于把它一起发出去（见 core/AccountScope 的文件头）。
   */
  static clearReport(context: common.UIAbilityContext): void {
    MobileProbe.last = '-';
    MobileProbe.shape = [];
    MobileProbe.identityLine = '-';
    try {
      const path: string = `${context.filesDir}/${REPORT_NAME}.txt`;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      hilog.info(DOMAIN, TAG, 'selftest report cleared');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'selftest report clear failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 排一次启动自检（幂等）。
   *
   * 自检本身是"只读探询"：三发请求都是 IG 客户端本来就会发的读接口，不改任何状态。
   * 失败一律只写日志，绝不抛给调用方 —— 它不能影响 App 的任何既有路径。
   */
  static scheduleSelfTest(context: common.UIAbilityContext): void {
    MobileProbe.context = context;
    if (MobileProbe.scheduled) {
      return;
    }
    MobileProbe.scheduled = true;
    setTimeout((): void => {
      MobileProbe.run(false).catch((error: Error): void => {
        hilog.warn(DOMAIN, TAG, 'selftest threw: %{public}s', error.message ?? 'unknown');
      });
    }, MobileProbe.DELAY_MS);
  }

  /**
   * 跑一遍自检并把结论打进日志。
   *
   * @param announce 是否额外出三行"能不能用"的结论（启动自检时给 true）
   * @returns 三发里成功了几发
   */
  static async run(announce: boolean = true): Promise<number> {
    MobileProbe.shape = [];
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      MobileProbe.last = 'no-session（未登录 / Cookie 罐里没有 sessionid）';
      MobileProbe.identityLine = 'no-session';
      hilog.info(DOMAIN, TAG, 'selftest skipped: %{public}s', MobileProbe.last);
      MobileProbe.persist();
      return 0;
    }
    MobileProbe.identityLine = identity.summary();
    hilog.info(DOMAIN, TAG, 'selftest start %{public}s', MobileProbe.identityLine);
    let ok: number = 0;
    let total: number = 0;
    // ① 最小一发：用户信息（GET，不带签名体）
    total++;
    const info: MobileResult = await MobileProbe.userInfo(identity);
    if (info.ok) {
      ok++;
    }
    // ② 快拍托盘（本次移植的主目标之一；顺带记下第一条 reel id 给 ⑤ 用）
    total++;
    const tray: MobileResult = await MobileProbe.reelsTray(identity);
    if (tray.ok) {
      ok++;
    }
    // ③ 私信收件箱（另一个主目标）
    total++;
    const inbox: MobileResult = await MobileProbe.directInbox(identity);
    if (inbox.ok) {
      ok++;
    }
    // ④ 自己的快拍（instagrapi 的 `user_stories`；先拿自己这个账号试路，多半是空列表但形状清楚）
    total++;
    const story: MobileResult = await MobileProbe.userStories(identity, identity.userId);
    if (story.ok) {
      ok++;
    }
    // ⑤ 托盘里那个人的快拍 —— **这一发才是"点开快拍"真正要走的路**。
    //    用托盘响应里现取的 user id：托盘里出现的人必然有内容，形状才有参考价值。
    let other: MobileResult | null = null;
    if (MobileProbe.firstTrayUserId.length > 0) {
      total++;
      other = await MobileProbe.userStories(identity, MobileProbe.firstTrayUserId);
      if (other.ok) {
        ok++;
      }
    } else {
      MobileProbe.shape.push('feed/user/…/story/ 跳过（托盘里没取到 user id）');
    }
    // ⑥⑦ 按 reel id 取快拍媒体：网页那条 REST 在部分会话上回 500，这里用移动端那套头再试。
    //    两种传参形式都试（裸 id / JSON 数组）：网页那条用的是 JSON 数组，而 instagrapi 里
    //    是裸 id —— 到底哪种被接受，让响应说话，别猜。
    let mediaBare: MobileResult | null = null;
    let mediaJson: MobileResult | null = null;
    if (MobileProbe.firstReelId.length > 0) {
      total++;
      mediaBare = await MobileProbe.reelsMedia(identity, MobileProbe.firstReelId, false);
      if (mediaBare.ok) {
        ok++;
      }
      total++;
      mediaJson = await MobileProbe.reelsMedia(identity, MobileProbe.firstReelId, true);
      if (mediaJson.ok) {
        ok++;
      }
    } else {
      MobileProbe.shape.push('reels_media 跳过（托盘里没取到 reel id）');
    }
    // ⑧ 一条会话的消息（instagrapi 的 `direct_messages`）——私信能不能"看得全"就看这一发。
    //    **前两条都试**：实测有一条会话（1:1）解析出 0 条消息，而第一条（群聊）有 15 条 ——
    //    两发对比才能分清是"服务端没给"还是"某类会话的解析不一样"。
    let thread: MobileResult | null = null;
    for (let index: number = 0; index < MobileProbe.threadIds.length; index++) {
      total++;
      const one: MobileResult = await MobileProbe.directThread(identity, MobileProbe.threadIds[index]);
      if (index === 0) {
        thread = one;
      }
      if (one.ok) {
        ok++;
      }
    }
    if (MobileProbe.threadIds.length === 0) {
      MobileProbe.shape.push('direct thread 跳过（收件箱里没取到 thread_id）');
    }
    // ⑨ 收件箱翻页传参实验（**不计入分母**；默认关闭，见 INBOX_CURSOR_EXPERIMENT 的说明）。
    if (INBOX_CURSOR_EXPERIMENT && MobileProbe.cursorTries.length > 0) {
      await MobileProbe.inboxPageVariants(identity, MobileProbe.firstThreadId);
    }
    // ⑩ 端点侦察（**不计入分母**；默认关闭，见 ENDPOINT_SCOUT 的说明）。
    if (ENDPOINT_SCOUT) {
      await MobileProbe.scout(identity);
    }
    MobileProbe.last = `ok=${ok}/${total} info=${MobileProbe.tip(info)} tray=${MobileProbe.tip(tray)}`
      + ` inbox=${MobileProbe.tip(inbox)} self=${MobileProbe.tip(story)}`
      + ` user=${MobileProbe.tipOrSkip(other)} media=${MobileProbe.tipOrSkip(mediaBare)}`
      + ` mediaJson=${MobileProbe.tipOrSkip(mediaJson)} thread=${MobileProbe.tipOrSkip(thread)}`;
    hilog.info(DOMAIN, TAG, 'selftest done %{public}s', MobileProbe.last);
    if (announce) {
      hilog.info(DOMAIN, TAG, '1) 会话与身份：%{public}s', identity.isComplete() ? '就绪' : '不完整');
      hilog.info(DOMAIN, TAG, '2) 请求被 IG 接受：%{public}s', ok > 0 ? '是' : '否（看上面每一发的 err）');
      hilog.info(DOMAIN, TAG, '3) 结论：%{public}s',
        ok === total ? '全通，可以开始接端点' : (ok > 0 ? '部分通，按失败那发的 err 定位' : '全失败'));
    }
    MobileProbe.persist();
    return ok;
  }

  /**
   * 把这次自检写进沙箱文件（`filesDir/Instarmony_mobile.txt`，覆盖写）。
   *
   * 覆盖而不是追加：这是"当前会话行不行"的快照，留一堆历史只会让人分不清哪份是这次的
   * （对比 `InstagramProbe` 的带时间戳 dump：那个要按时间序列还原"哪一发之后变了"，
   * 这里只需要最新结论）。失败只记日志 —— 落盘不该影响任何调用方。
   */
  private static persist(): void {
    const context: common.UIAbilityContext | null = MobileProbe.context;
    if (context === null) {
      return;
    }
    const lines: Array<string> = [];
    lines.push(`Instarmony 移动 API 自检 ${MobileProbe.stamp()}`);
    lines.push(`结论 ${MobileProbe.last}`);
    lines.push(`身份 ${MobileProbe.identityLine}`);
    lines.push(`主机 ${MobileSession.host()}`);
    lines.push('');
    lines.push('== 每一发的形状（键名 + 值预览）==');
    for (let index: number = 0; index < MobileProbe.shape.length
      && index < MAX_SHAPE_LINES; index++) {
      lines.push(MobileProbe.shape[index]);
    }
    try {
      const path: string = InstagramProbe.dumpFixed(context, REPORT_NAME, lines.join('\n'));
      hilog.info(DOMAIN, TAG, 'selftest report written %{public}s', path);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'selftest report failed: %{public}s', (error as Error).message);
    }
  }

  /** 落盘用的时间戳（`yyyy-MM-dd HH:mm:ss`，与 InstagramProbe/StoryDiag 同格式）。 */
  private static stamp(): string {
    const now: Date = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} `
      + `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  }

  /**
   * 自检那几发的排队策略：**空闲优先级**（`ApiThrottle.idle()`）。
   *
   * 为什么不是默认的 WARM：自检一次 9 发，跑在启动后 6 秒那个时间点上 —— 恰好是用户已经
   * 开始滑首屏、点快拍的时候。给它们最低优先级，用户此刻点的请求就能插到队头，
   * 不会被自检一排 9 发挡住（挡一下就是 1 秒起）。
   */
  private static opts(): MobileOptions {
    return new MobileOptions(ApiThrottle.MOBILE, ApiThrottle.idle());
  }

  /** ① `GET /api/v1/users/{uid}/info/`（instagrapi 的 `user_info_v1`，最小的一发）。 */
  static async userInfo(identity: MobileIdentity): Promise<MobileResult> {
    const result: MobileResult = await MobileRequest.send(
      `users/${identity.userId}/info/`, '', '', true, null, MobileProbe.opts());
    MobileProbe.logShape('user_info', result);
    // 顺手把自己的用户名记下来：侦察 ⑦（`users/{username}/usernameinfo/`）要拿它问一发。
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed !== null) {
      const user: Record<string, Object> | null = MobileProbe.objectOf(parsed['user']);
      if (user !== null) {
        const name: string = MobileProbe.firstText(user, ['username']);
        if (name.length > 0) {
          MobileProbe.selfUsername = name;
        }
      }
    }
    return result;
  }

  /**
   * ② `POST /api/v1/feed/reels_tray/`（instagrapi 的 `get_reels_tray_feed`）。
   *
   * 表单字段照抄：`reason` / `timezone_offset` / `tray_session_id` / `request_id` /
   * `page_size` / `_uuid` / `supported_capabilities_new` / `reel_tray_impressions`。
   */
  static async reelsTray(identity: MobileIdentity, reason: string = 'cold_start',
                         pageSize: number = 50): Promise<MobileResult> {
    const data: Record<string, Object> = {};
    data['supported_capabilities_new'] = SUPPORTED_CAPABILITIES;
    data['reason'] = reason;
    data['timezone_offset'] = `${identity.timezoneOffset}`;
    data['tray_session_id'] = identity.traySessionId;
    data['request_id'] = identity.requestId;
    data['page_size'] = pageSize;
    data['_uuid'] = identity.uuid;
    // cold_start 空对象、其余带上自己（instagrapi 的 `reel_tray_impressions`）。
    if (reason === 'cold_start') {
      const none: Record<string, Object> = {};
      data['reel_tray_impressions'] = none;
    } else {
      const impressions: Record<string, Object> = {};
      impressions[identity.userId] = `${Math.floor(Date.now() / 1000)}`;
      data['reel_tray_impressions'] = impressions;
    }
    const result: MobileResult = await MobileRequest.send(
      'feed/reels_tray/', MobileRequest.formOf(data), '', true, null, MobileProbe.opts());
    MobileProbe.logShape('reels_tray', result);
    MobileProbe.describeTray(result);
    return result;
  }

  /** ③ `POST /api/v1/direct_v2/inbox/`（instagrapi 的 `direct_threads` 第一发）。 */
  static async directInbox(identity: MobileIdentity, limit: number = 20): Promise<MobileResult> {
    const data: Record<string, Object> = MobileRequest.withExtraData(identity);
    data['visual_message_return_type'] = 'unseen';
    data['thread_message_limit'] = 10;
    data['persistentBadging'] = 'true';
    data['limit'] = limit;
    const query: string = 'visual_message_return_type=unseen'
      + `&thread_message_limit=10&persistentBadging=true&limit=${limit}`;
    const result: MobileResult = await MobileRequest.send(
      'direct_v2/inbox/', MobileRequest.formOf(data), query, true, null, MobileProbe.opts());
    MobileProbe.logShape('direct_inbox', result);
    MobileProbe.describeInbox(result);
    return result;
  }

  /**
   * ④ `GET /api/v1/feed/user/{uid}/story/`（instagrapi 的 `user_stories`）。
   *
   * 这一发是**快拍能不能点开**的关键：网页那条 REST（`/api/v1/feed/reels_media/`）在部分会话上
   * 被 IG 回 500，而这条是移动端自己走的路径。判别标准很干脆：200（哪怕 `items` 是空的）
   * 就说明这条路可用，400/404/500 就说明还得换。
   */
  static async userStories(identity: MobileIdentity, userId: string): Promise<MobileResult> {
    const result: MobileResult = await MobileRequest.send(
      `feed/user/${userId}/story/`, '', '', true, null, MobileProbe.opts());
    MobileProbe.logShape('user_stories', result);
    MobileProbe.describeStoryItems(result);
    return result;
  }

  /**
   * ⑥⑦ `GET /api/v1/feed/reels_media/?reel_ids=…`（网页 REST 的同一条路，但用移动端那套头）。
   *
   * 为什么要再试一次：网页那条路失败时我们判不出"是端点被弃用"还是"是网页来源被拒"。
   * 同一发请求换成移动端的头（App-ID / UA / signed_body / Authorization）就能把这两件事分开。
   *
   * @param asJsonArray `true` 用 `["id"]`（网页那条用的形式），`false` 用裸 `id`（instagrapi 的形式）
   */
  static async reelsMedia(identity: MobileIdentity, reelId: string,
                          asJsonArray: boolean): Promise<MobileResult> {
    const ids: Array<string> = [reelId];
    const value: string = asJsonArray ? JSON.stringify(ids) : reelId;
    const label: string = asJsonArray ? 'reels_media[arr]' : 'reels_media[bare]';
    const params: string = `reel_ids=${encodeURIComponent(value)}`;
    const result: MobileResult = await MobileRequest.send('feed/reels_media/', '', params, true, null, MobileProbe.opts());
    MobileProbe.logShape(label, result);
    MobileProbe.describeStoryItems(result, label);
    return result;
  }

  /**
   * 托盘深处的形状：写解析层要用的那几层（`tray[0]` / `items[0]` / `user`）。
   *
   * 为什么非要这个：托盘那一发有 400KB / 212 条，`logShape` 只给顶层键名，
   * 而**环下第一张图/视频在 `tray[i].items[0]` 里**（instagrapi 的 `extract_reels_tray`
   * 就是从这里取封面与 media_type）。没有这一层形状，解析层只能靠猜。
   */
  private static describeTray(result: MobileResult): void {
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed === null) {
      return;
    }
    const tray: Object | undefined = parsed['tray'];
    if (!Array.isArray(tray)) {
      MobileProbe.shape.push('tray 不是数组');
      return;
    }
    const list: Array<Object> = tray as Array<Object>;
    MobileProbe.shape.push(`tray 条数=${list.length}`);
    if (list.length === 0) {
      return;
    }
    const first: Record<string, Object> = list[0] as Record<string, Object>;
    MobileProbe.shape.push(`tray[0] keys=[${Object.keys(first).join(' ')}]`);
    // 第一条 reel 的 id：⑤ 要用（`id` 是字符串化的数字，`strong_id__` 是同一件事的新字段）。
    const id: Object | undefined = first['id'];
    if (id !== undefined && id !== null) {
      MobileProbe.firstReelId = `${id}`;
      MobileProbe.shape.push(`tray[0].id=${MobileProbe.firstReelId}`);
    }
    MobileProbe.describeMediaList(first['items'], 'tray[0].items');
    const user: Object | undefined = first['user'];
    if (user !== undefined && user !== null) {
      const who: Record<string, Object> = user as Record<string, Object>;
      MobileProbe.shape.push(`tray[0].user keys=[${Object.keys(who).join(' ')}]`);
      // `pk` / `id` 都是数字 id（`pk` 是新字段，`id` 是老的）；username 给日志看着方便。
      const pk: Object | undefined = who['pk'] !== undefined ? who['pk'] : who['id'];
      if (pk !== undefined && pk !== null) {
        MobileProbe.firstTrayUserId = `${pk}`;
      }
      MobileProbe.shape.push(`tray[0].user pk=${MobileProbe.firstTrayUserId}`
        + ` username=${MobileProbe.preview(who['username'])}`
        + ` private=${MobileProbe.preview(who['is_private'])}`
        + ` pic=${who['profile_pic_url'] !== undefined ? 'y' : 'n'}`);
    }
    // 内容计数：判断"这个环下到底有没有东西"（`media_count` 与 `media_ids` 条数）。
    const mediaIds: Object | undefined = first['media_ids'];
    const idCount: string = Array.isArray(mediaIds) ? `${(mediaIds as Array<Object>).length}` : '-';
    MobileProbe.shape.push(`tray[0] media_count=${MobileProbe.preview(first['media_count'])}`
      + ` media_ids=[${idCount}] seen=${MobileProbe.preview(first['seen'])}`
      + ` latest_reel_media=${MobileProbe.preview(first['latest_reel_media'])}`
      + ` expiring_at=${MobileProbe.preview(first['expiring_at'])}`
      + ` has_video=${MobileProbe.preview(first['has_video'])}`
      + ` reel_type=${MobileProbe.preview(first['reel_type'])}`);
    if (idCount !== '-' && idCount !== '0') {
      const list2: Array<Object> = mediaIds as Array<Object>;
      MobileProbe.shape.push(`tray[0].media_ids[0]=${MobileProbe.preview(list2[0])}`);
    }
  }

  /** 私信收件箱深处的形状（`inbox.threads[0]` 那层：写私信列表要用的字段）。 */
  private static describeInbox(result: MobileResult): void {
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed === null) {
      return;
    }
    const inbox: Object | undefined = parsed['inbox'];
    if (inbox === undefined || inbox === null) {
      MobileProbe.shape.push('inbox 缺失');
      return;
    }
    const box: Record<string, Object> = inbox as Record<string, Object>;
    const threads: Object | undefined = box['threads'];
    if (!Array.isArray(threads)) {
      MobileProbe.shape.push(`inbox keys=[${Object.keys(box).join(' ')}] threads 不是数组`);
      return;
    }
    const list: Array<Object> = threads as Array<Object>;
    MobileProbe.shape.push(`inbox.threads=${list.length}`);
    if (list.length === 0) {
      return;
    }
    const first: Record<string, Object> = list[0] as Record<string, Object>;
    MobileProbe.shape.push(`threads[0] keys=[${Object.keys(first).join(' ')}]`);
    MobileProbe.describeMediaList(first['items'], 'threads[0].items');
    // 第一条会话的 thread_id：⑧ 要用（`thread_id` 是 19~20 位数字，取值时不能过 double，
    // 所以这里只做"有没有"的判断，真正的精确取值交给 JsonRead.parseWithBigIds 那条解析路径）。
    const threadId: Object | undefined = first['thread_id'];
    if (threadId !== undefined && threadId !== null) {
      MobileProbe.firstThreadId = `${threadId}`;
      MobileProbe.shape.push(`threads[0].thread_id=${MobileProbe.firstThreadId}`);
    }
    // 前两条会话都记下（⑧ 各试一发：一条是群聊、一条是 1:1，实测解析结果不同）。
    MobileProbe.threadIds = [];
    for (let at: number = 0; at < list.length && MobileProbe.threadIds.length < 2; at++) {
      const one: Record<string, Object> = list[at] as Record<string, Object>;
      const idValue: Object | undefined = one['thread_id'];
      if (idValue === undefined || idValue === null) {
        continue;
      }
      const text: string = `${idValue}`;
      if (text.length > 0 && MobileProbe.threadIds.indexOf(text) < 0) {
        MobileProbe.threadIds.push(text);
      }
    }
    MobileProbe.shape.push(`threads[0] is_group=${MobileProbe.preview(first['is_group'])}`
      + ` title=${MobileProbe.preview(first['thread_title'])}`
      + ` activity=${MobileProbe.preview(first['last_activity_at'])}`
      + ` last_seen=${MobileProbe.preview(first['last_seen_at'])}`
      + ` img=${first['thread_image'] !== undefined ? 'y' : 'n'}`);
    // 顺手用**现成的**收件箱解析器（网页那条路也在用）解一遍：形状兼容就一行 `parser inbox=ok`。
    MobileProbe.verifyInboxParser(result.body);
    // 收件箱自己这一层的键名（翻页游标到底叫什么、长什么样，就看这几行）。
    const cursorBox: Record<string, Object> | null = MobileProbe.objectOf(parsed['inbox']);
    if (cursorBox !== null) {
      MobileProbe.shape.push(`inbox keys=[${Object.keys(cursorBox).join(' ')}]`);
      const nc: Object | undefined = cursorBox['next_cursor'];
      if (nc !== undefined && nc !== null) {
        // 形状（不是值）：是个结构还是字符串，决定了翻页参数怎么传。
        const shape: Record<string, Object> | null = MobileProbe.objectOf(nc);
        const shapeKeys: string = shape === null ? '-' : Object.keys(shape).join(' ');
        MobileProbe.shape.push(`inbox next_cursor type=${Array.isArray(nc) ? 'array' : typeof nc}`
          + ` keys=[${shapeKeys}]`);
        MobileProbe.inboxCursor = JSON.stringify(nc);
      }
      MobileProbe.shape.push(`inbox next_cursor raw=${MobileProbe.preview(nc)}`
        + ` has_older=${MobileProbe.preview(cursorBox['has_older'])}`
        + ` prev_cursor_type=${MobileProbe.preview(cursorBox['prev_cursor_type'])}`);
      MobileProbe.inboxPrevCursor = MobileProbe.firstText(cursorBox, ['prev_cursor']);
      MobileProbe.inboxPrevCursorV2 = MobileProbe.firstText(cursorBox, ['prev_cursor_v2']);
      // ⑨ 的候选：把响应里所有"像游标"的东西都排进去，逐个试（见 cursorTries 的说明）。
      MobileProbe.cursorTries = [];
      MobileProbe.addCursorTry('oldest_cursor', MobileProbe.firstText(cursorBox, ['oldest_cursor']));
      MobileProbe.addCursorTry('prev_cursor', MobileProbe.rawTextOf(cursorBox['prev_cursor']));
      MobileProbe.addCursorTry('prev_cursor_v2', MobileProbe.rawTextOf(cursorBox['prev_cursor_v2']));
      MobileProbe.addCursorTry('next_cursor', MobileProbe.inboxCursor);
      MobileProbe.shape.push(`inbox cursor candidates=[${MobileProbe.cursorTries.map(
        (one: CursorTry): string => `${one.label}:${one.value.length}`).join(' ')}]`);
    }
  }

  /** 候选清单里加一条（空值跳过；同名不重复）。 */
  private static addCursorTry(label: string, value: string): void {
    if (value.length === 0) {
      return;
    }
    for (let index: number = 0; index < MobileProbe.cursorTries.length; index++) {
      if (MobileProbe.cursorTries[index].label === label) {
        return;
      }
    }
    MobileProbe.cursorTries.push(new CursorTry(label, value));
  }

  /** 一个字段的"原始文本"（字符串原样给，对象/数组给 JSON）——翻页实验要拿原值去试。 */
  private static rawTextOf(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value as string;
    }
    try {
      return JSON.stringify(value);
    } catch (error) {
      return '';
    }
  }

  /** 快拍条目那层（`items[0]`）：media_type / 图片与视频字段在不在。 */
  private static describeStoryItems(result: MobileResult, label: string = 'items'): void {
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed === null) {
      return;
    }
    MobileProbe.describeMediaList(parsed['items'], label);
    // `reels_media` 那种按 id 取的响应形状是 `{reels:{<id>:{items:[…]}}}`：
    // 顶层没有 `items`，媒体在 `reels` 里。两种形状都描述一遍，写解析层才知道取哪一条。
    const reels: Object | undefined = parsed['reels'];
    if (reels === undefined || reels === null || Array.isArray(reels)) {
      return;
    }
    const map: Record<string, Object> = reels as Record<string, Object>;
    const ids: Array<string> = Object.keys(map);
    MobileProbe.shape.push(`${label} reels.keys=[${ids.join(' ')}]`);
    for (let index: number = 0; index < ids.length && index < 2; index++) {
      const reel: Object = map[ids[index]];
      if (reel === null || reel === undefined) {
        continue;
      }
      const one: Record<string, Object> = reel as Record<string, Object>;
      MobileProbe.shape.push(`${label} reels[${ids[index]}] keys=[${Object.keys(one).join(' ')}]`);
      MobileProbe.describeMediaList(one['items'], `${label} reels[${ids[index]}].items`);
    }
  }

  /** 一个 media 数组的形状：条数 + 第一条的键名 + 图片/视频字段在不在。 */
  private static describeMediaList(value: Object | undefined, label: string): void {
    if (value === undefined || value === null || !Array.isArray(value)) {
      MobileProbe.shape.push(`${label} 缺失`);
      return;
    }
    const list: Array<Object> = value as Array<Object>;
    MobileProbe.shape.push(`${label}=[${list.length}]`);
    if (list.length === 0) {
      return;
    }
    const media: Record<string, Object> = list[0] as Record<string, Object>;
    MobileProbe.shape.push(`${label}[0] keys=[${Object.keys(media).join(' ')}]`);
    MobileProbe.shape.push(`${label}[0] media_type=${MobileProbe.preview(media['media_type'])}`
      + ` image_versions2=${media['image_versions2'] !== undefined ? 'y' : 'n'}`
      + ` video_versions=${media['video_versions'] !== undefined ? 'y' : 'n'}`
      + ` candidates=${MobileProbe.candidatesOf(media['image_versions2'])}`);
  }

  /** `image_versions2.candidates` 的条数（封面有几个尺寸可选）。 */
  private static candidatesOf(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return '-';
    }
    const versions: Record<string, Object> = value as Record<string, Object>;
    const candidates: Object | undefined = versions['candidates'];
    if (candidates === undefined || candidates === null || !Array.isArray(candidates)) {
      return '-';
    }
    const list: Array<Object> = candidates as Array<Object>;
    if (list.length === 0) {
      return '0';
    }
    const first: Record<string, Object> = list[0] as Record<string, Object>;
    return `${list.length}(${MobileProbe.preview(first['width'])}x${MobileProbe.preview(first['height'])})`;
  }

  /**
   * ⑧ `GET /api/v1/direct_v2/threads/{id}/?limit=…`（instagrapi 的 `direct_messages`）。
   *
   * 用户报的"会话只显示 4~5 条"要么是服务端就只给了这么多，要么是我们解析丢了几条 ——
   * 这一发把**服务端到底给了几条**（`items` 条数）如实写进报告，二分法立刻见效。
   * 同时用**现成的** `DirectMapper.threadFromJson` 解析一遍：解析层与网页那条路共用，
   * 通了就说明新路径的响应形状与老解析器完全兼容（`parser=` 那几行）。
   */
  static async directThread(identity: MobileIdentity, threadId: string,
                            limit: number = 20): Promise<MobileResult> {
    const params: string = `limit=${limit}`;
    const result: MobileResult = await MobileRequest.send(
      `direct_v2/threads/${threadId}/`, '', params, true, null, MobileProbe.opts());
    MobileProbe.logShape('direct_thread', result);
    MobileProbe.describeThread(result, threadId);
    return result;
  }

  /**
   * ⑨ 收件箱**翻页**的传参实验（只做诊断，不计入自检分母）。
   *
   * 为什么非做不可：实测把 `inbox.next_cursor` 放进 `cursor` 参数会被 IG 回
   * `400 Invalid Inbox Cursor: The cursor parameter passed in the Inbox API must be …`，
   * 而"加载更多"翻不动时界面会连打四发再退到模板那条老路（真机日志 16:12:20）。
   *
   * 第一次实验暴露了两件事：
   *   1. `inbox.next_cursor` **不是字符串**，是个结构
   *      `{cursor_thread_v2_id, cursor_timestamp_seconds, cursor_relevancy_score}`；
   *   2. `max_id=…` / 表单体里带 `cursor=…` 都回 **200** —— 但那**不能说明翻页成功了**：
   *      参数不认识时 IG 会**原样再给第一页**（本项目在 `inboxRest` 注释里专门警告过这个坑）。
   *      所以这次每种传法都要比对"回来的第一会话 id 与上一页是否不同"才算数。
   *
   * @param cursorJson `next_cursor` 结构的 JSON 串
   * @param firstId 上一页第一条会话的 id（用来判断"是不是又给了第一页"）
   */
  static async inboxPageVariants(identity: MobileIdentity, firstId: string): Promise<string> {
    if (MobileProbe.cursorTries.length === 0) {
      return 'no-cursor';
    }
    const base: string = 'visual_message_return_type=unseen'
      + '&thread_message_limit=10&persistentBadging=true&limit=20';
    const data: Record<string, Object> = MobileRequest.withExtraData(identity);
    data['visual_message_return_type'] = 'unseen';
    data['thread_message_limit'] = 10;
    data['persistentBadging'] = 'true';
    data['limit'] = 20;
    const out: Array<string> = [];
    let detail: string = '-';
    for (let index: number = 0; index < MobileProbe.cursorTries.length; index++) {
      const one: CursorTry = MobileProbe.cursorTries[index];
      const result: MobileResult = await MobileRequest.send('direct_v2/inbox/',
        MobileRequest.formOf(data), `${base}&cursor=${encodeURIComponent(one.value)}`, true,
        null, MobileProbe.opts());
      out.push(`${one.label}=${MobileProbe.pageVerdict(result, firstId)}`);
      if (!result.ok && detail === '-') {
        detail = result.detail;
      }
    }
    // 表单体里带游标那种传法（第一次实验用的是 "[object Object]"，等于没测）。
    const bodyData: Record<string, Object> = MobileRequest.withExtraData(identity);
    bodyData['visual_message_return_type'] = 'unseen';
    bodyData['thread_message_limit'] = 10;
    bodyData['persistentBadging'] = 'true';
    bodyData['limit'] = 20;
    bodyData['cursor'] = MobileProbe.inboxCursor;
    const inBody: MobileResult = await MobileRequest.send('direct_v2/inbox/',
      MobileRequest.formOf(bodyData), base, true, null, MobileProbe.opts());
    out.push(`body-cursor=${MobileProbe.pageVerdict(inBody, firstId)}`);
    const summary: string = out.join(' ');
    hilog.info(DOMAIN, TAG, 'inbox page variants → %{public}s', summary);
    MobileProbe.shape.push(`inbox 翻页实验(比对首页 id) ${summary}`);
    MobileProbe.shape.push(`inbox 翻页 400 原话=${detail.substring(0, 200)}`);
    return summary;
  }

  /**
   * 一发翻页请求的判读：**只有"回来了且第一会话与上一页不同"才算翻页成功**。
   *
   * 这一条判据是本项目踩过的坑换来的（`inboxRest` 的注释）：IG 对不认识的翻页参数
   * 不报错，而是**再给一遍第一页** —— 只看状态码会把"原地打转"当成成功。
   */
  private static pageVerdict(result: MobileResult, previousFirstId: string): string {
    if (!result.ok) {
      return `${result.code}/${result.error}`;
    }
    const page: DirectInboxPage | null = DirectMapper.inboxFromRestJson(result.body);
    if (page === null || page.threads.length === 0) {
      return `${result.code}/empty`;
    }
    const same: boolean = previousFirstId.length > 0 && page.threads[0].id === previousFirstId;
    return `${result.code}/${same ? 'SAME-page1' : 'NEW'}(n=${page.threads.length})`;
  }

  /** 会话深处的形状（`thread.items[]` / `users[]` / 游标），并跑一遍现成解析器。 */
  private static describeThread(result: MobileResult, threadId: string): void {
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed === null) {
      return;
    }
    // 标签带上 id 尾部：两发（群聊 / 1:1）的形状要能对得上号。
    const tag: string = `thread[${threadId.substring(Math.max(0, threadId.length - 6))}]`;
    const thread: Record<string, Object> | null = MobileProbe.objectOf(parsed['thread']);
    if (thread === null) {
      MobileProbe.shape.push(`${tag} thread 缺失 keys=[${Object.keys(parsed).join(' ')}]`);
      return;
    }
    MobileProbe.describeMediaList(thread['items'], `${tag}.items`);
    MobileProbe.shape.push(`${tag} is_group=${MobileProbe.preview(thread['is_group'])}`
      + ` has_older=${MobileProbe.preview(thread['has_older'])}`
      + ` users=[${MobileProbe.objectsOfCount(thread['users'])}]`
      + ` title=${MobileProbe.preview(thread['thread_title'])}`);
    // 第一条消息的 `item_type`：解析层丢条目时，靠它判断"丢的是哪一类"。
    const items: Object | undefined = thread['items'];
    if (items !== undefined && items !== null && Array.isArray(items)) {
      const list: Array<Object> = items as Array<Object>;
      MobileProbe.shape.push(`${tag}.item_types=${MobileProbe.itemTypes(list)}`);
      // **每种类型的第一条**把键名摊开：解析层要认的字段名（尤其 xma_clip / generic_xma
      // 这类"分享"消息，图片挂在哪个子对象上）只能从真实响应里看出来。
      MobileProbe.describeFirstOfEachType(list, tag);
    }
    // 现成解析器（网页那条路也在用）跑一遍：形状兼容与否一句话说清。
    const view: DirectThreadView | null = DirectMapper.threadFromJson(result.body, '');
    MobileProbe.shape.push(`parser ${tag}=${view === null ? 'null' : `ok msgs=${view.messages.length}`
      + ` with=${view.withUsername} older=${view.hasOlder}`}`);
  }

  /** 数组字段的条数（不是数组给 0）。 */
  private static objectsOfCount(value: Object | undefined): number {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return 0;
    }
    return (value as Array<Object>).length;
  }

  /** 前几条消息的 `item_type` 汇总（形如 `text=3,media=1`）——看解析层丢了哪一类。 */
  private static itemTypes(items: Array<Object>): string {
    const counts: Map<string, number> = new Map<string, number>();
    for (let index: number = 0; index < items.length; index++) {
      const one: Record<string, Object> | null = MobileProbe.objectOf(items[index]);
      if (one === null) {
        continue;
      }
      const type: string = MobileProbe.firstText(one, ['item_type', 'content_type']);
      const key: string = type.length > 0 ? type : '(none)';
      const had: number | undefined = counts.get(key);
      counts.set(key, had === undefined ? 1 : had + 1);
    }
    const parts: Array<string> = [];
    counts.forEach((value: number, key: string): void => {
      parts.push(`${key}=${value}`);
    });
    return parts.join(',');
  }

  /**
   * 每种 `item_type` 的**第一条**：把它自己与几个可疑子对象的键名摊开。
   *
   * 为什么必须看这一眼：`DirectMapper` 现在只认 `text` / `media` / `media_share` / `clip` /
   * `reel_share` / `link`，而真机上 1:1 会话里整条线程可以是 `xma_clip` / `xma_media_share` /
   * `generic_xma`（实测 21 条全部是这三类，解析出来 0 条消息 → 界面报"读取失败"）。
   * 图片到底挂在哪一层，只能从响应里读出来。
   */
  private static describeFirstOfEachType(items: Array<Object>, tag: string): void {
    const seen: Array<string> = [];
    const holders: Array<string> = ['xma_clip', 'xma_media_share', 'generic_xma', 'animated_media',
      'xma_share', 'clip', 'media_share', 'media', 'reel_share', 'link'];
    for (let index: number = 0; index < items.length && seen.length < 6; index++) {
      const one: Record<string, Object> | null = MobileProbe.objectOf(items[index]);
      if (one === null) {
        continue;
      }
      const type: string = MobileProbe.firstText(one, ['item_type', 'content_type']);
      if (type.length === 0 || seen.indexOf(type) >= 0) {
        continue;
      }
      seen.push(type);
      MobileProbe.shape.push(`${tag} type=${type} keys=[${Object.keys(one).join(' ')}]`);
      for (let at: number = 0; at < holders.length; at++) {
        const value: Object | undefined = one[holders[at]];
        if (value === undefined || value === null) {
          continue;
        }
        // 数组也要能看出来：`xma_*` 这类附件可能是**数组**（objectOf 会把数组判成 null，
        // 只靠键名看不出这一点，于是这一行专门标出容器类型）。
        const asArray: Array<Object> | null = Array.isArray(value) ? value as Array<Object> : null;
        if (asArray !== null) {
          MobileProbe.shape.push(`${tag}   ${type}.${holders[at]} 是数组 len=${asArray.length}`);
          if (asArray.length > 0) {
            const inner: Record<string, Object> | null = MobileProbe.objectOf(asArray[0]);
            MobileProbe.shape.push(`${tag}   ${type}.${holders[at]}[0] keys=[`
              + `${inner === null ? '-' : Object.keys(inner).join(' ')}]`);
          }
          continue;
        }
        const sub: Record<string, Object> | null = MobileProbe.objectOf(value);
        if (sub !== null) {
          MobileProbe.shape.push(`${tag}   ${type}.${holders[at]} keys=[${Object.keys(sub).join(' ')}]`);
        }
      }
      /*
       * **看不懂的那几类直接留原始 JSON**（截断）。
       *
       * 为什么不再靠"猜键名"：`xma_clip` / `xma_media_share` / `generic_xma` 是"分享帖子/Reel"
       * 那类消息，`DirectMapper` 现在完全不认它们 —— 1:1 会话里整条线程都是这三类时，
       * 解析出来 0 条消息，界面就报"读取失败"（用户报的"会话只显示几条"就是这个）。
       * 要写这层映射，必须看清真实结构，而键名列表已经不够用了。
       */
      if (type !== 'text') {
        MobileProbe.shape.push(`${tag} raw(${type})=${MobileProbe.rawOf(one, 900)}`);
      }
    }
  }

  /** 一条 item 的原始 JSON（截断；诊断用）。 */
  private static rawOf(value: Object, limit: number): string {
    try {
      const text: string = JSON.stringify(value);
      return text.length > limit ? `${text.substring(0, limit)}…` : text;
    } catch (error) {
      return '(unserializable)';
    }
  }

  /** 收件箱解析器验证（在 describeInbox 里调，报告里给一行 `parser inbox=…`）。 */
  private static verifyInboxParser(body: string): void {
    const page: DirectInboxPage | null = DirectMapper.inboxFromRestJson(body);
    if (page === null) {
      MobileProbe.shape.push('parser inbox=null');
      return;
    }
    MobileProbe.shape.push(`parser inbox=ok n=${page.threads.length}`
      + ` first=${page.threads.length > 0 ? page.threads[0].title : '-'}`
      + ` cursor=${page.endCursor.length}b more=${page.hasMore}`);
  }

  /**
   * 端点的短预览：值的短预览（见 preview），失败时给 err。
   *
   * 侦察报告里"这一发通不通"比什么都重要，所以先写一行结论再写结构树。
   */
  private static scoutLine(label: string, result: MobileResult): string {
    return `${label} ${result.ok ? '✓' : '✗'} ${result.summary()}`;
  }

  /**
   * 把一个 JSON 节点按**缩进树**写进侦察行（数组只展开第 0 个元素）。
   *
   * 为什么是树而不是 instagrapi 那样直接读字段：解析层要的是"这条路给什么"，
   * 而 IG 的字段名新旧混杂（`pk` / `id` / `strong_id__`）—— 树能把它们一次摊开，
   * 不用来回抓包。
   */
  private static scoutTree(lines: Array<string>, label: string, node: Object | undefined,
                           depth: number, maxDepth: number): void {
    const pad: string = '  '.repeat(depth);
    if (node === undefined || node === null) {
      lines.push(`${pad}${label} = null`);
      return;
    }
    if (Array.isArray(node)) {
      const list: Array<Object> = node as Array<Object>;
      lines.push(`${pad}${label} [${list.length}]`);
      if (list.length > 0 && depth < maxDepth) {
        MobileProbe.scoutTree(lines, '[0]', list[0], depth + 1, maxDepth);
      }
      return;
    }
    if (typeof node !== 'object') {
      const text: string = `${node}`;
      lines.push(`${pad}${label} = ${text.length > 72 ? `${text.substring(0, 72)}…` : text}`);
      return;
    }
    const obj: Record<string, Object> = node as Record<string, Object>;
    const keys: Array<string> = Object.keys(obj);
    lines.push(`${pad}${label} {${keys.length}} = [${keys.slice(0, SCOUT_KEYS_PER_LEVEL).join(' ')}]`);
    if (depth >= maxDepth) {
      return;
    }
    for (let index: number = 0; index < keys.length && index < SCOUT_KEYS_PER_LEVEL; index++) {
      MobileProbe.scoutTree(lines, keys[index], obj[keys[index]], depth + 1, maxDepth);
    }
  }

  /**
   * 侦察那 7 发（见 ENDPOINT_SCOUT）。
   *
   * 每一发都写两样：结论行（ok / err / http / ms / bytes）+ 结构树。
   * **只读**，不改任何状态；失败也继续往下打（"这条不通"也是结论）。
   */
  private static async scout(identity: MobileIdentity): Promise<void> {
    const lines: Array<string> = [];
    lines.push(`Instarmony 移动端点侦察 ${MobileProbe.stamp()}`);
    lines.push(`身份 ${identity.summary()}`);
    lines.push(`主机 ${MobileSession.host()}`);
    lines.push('说明：每段 = 一行结论 + 一层缩进树（数组只展开 [0]，最多 '
      + `${SCOUT_MAX_DEPTH} 层 / 每层 ${SCOUT_KEYS_PER_LEVEL} 键）`);
    lines.push('');
    const timezone: string = `${identity.timezoneOffset}`;
    const sessionId: string = identity.uuid;
    const selfId: string = identity.userId;
    const tries: Array<string> = [];

    // ① reels 流：移动端 `clips/home/`（GET 与 POST 各一发，哪种被接受让服务端说话）。
    const clipsGet: MobileResult = await MobileRequest.send(
      'clips/home/', '', `max_id=&_uid=${encodeURIComponent(selfId)}`,
      true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('clips/home[GET]', clipsGet));
    MobileProbe.scoutBody(lines, 'clips/home[GET]', clipsGet);

    const clipsBody: Record<string, Object> = MobileRequest.withExtraData(identity);
    clipsBody['max_id'] = '';
    clipsBody['seen_reels'] = '[]';
    const clipsPost: MobileResult = await MobileRequest.send(
      'clips/home/', MobileRequest.formOf(clipsBody), '', true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('clips/home[POST]', clipsPost));
    MobileProbe.scoutBody(lines, 'clips/home[POST]', clipsPost);

    // ② 探索/推荐流：instagrapi 的 `explore_page`（`discover/topical_explore/`）。
    const exploreParams: string = 'is_prefetch=false&omit_cover_media=true&max_id='
      + '&module=explore_popular&reels_configuration=hide_hero&use_sectional_payload=true'
      + `&timezone_offset=${encodeURIComponent(timezone)}&cluster_id=${encodeURIComponent('explore_all:0')}`
      + `&session_id=${encodeURIComponent(sessionId)}&include_fixed_destinations=true`;
    const explore: MobileResult = await MobileRequest.send(
      'discover/topical_explore/', '', exploreParams, true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('discover/topical_explore', explore));
    MobileProbe.scoutBody(lines, 'discover/topical_explore', explore);

    // ③ 搜索账号（v2 SERP）：instagrapi 的 `fbsearch_accounts_v2`。
    const accounts: MobileResult = await MobileRequest.send(
      'fbsearch/account_serp/', '',
      `search_surface=account_serp&timezone_offset=${encodeURIComponent(timezone)}`
      + `&query=${encodeURIComponent(SCOUT_QUERY)}`, true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('fbsearch/account_serp', accounts));
    MobileProbe.scoutBody(lines, 'fbsearch/account_serp', accounts);

    // ④ 搜索账号（老 v1）：instagrapi 的 `search_users`。
    const users: MobileResult = await MobileRequest.send(
      'users/search/', '',
      `search_surface=user_search_page&timezone_offset=${encodeURIComponent(timezone)}&count=30`
      + `&q=${encodeURIComponent(SCOUT_QUERY)}`, true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('users/search', users));
    MobileProbe.scoutBody(lines, 'users/search', users);

    // ⑤ 搜索帖子（混合 SERP 里的 media_grid）：instagrapi 的 `fbsearch_topsearch_v2`。
    const top: MobileResult = await MobileRequest.send(
      'fbsearch/top_serp/', '',
      `search_surface=top_serp&timezone_offset=${encodeURIComponent(timezone)}`
      + `&query=${encodeURIComponent(SCOUT_QUERY)}&rank_token=${encodeURIComponent(sessionId)}`,
      true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('fbsearch/top_serp', top));
    MobileProbe.scoutBody(lines, 'fbsearch/top_serp', top);

    // ⑥ 主页格子：instagrapi 的 `user_medias`（`feed/user/{pk}/`）。
    const grid: MobileResult = await MobileRequest.send(
      `feed/user/${selfId}/`, '', 'count=12', true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('feed/user/{self}', grid));
    MobileProbe.scoutBody(lines, 'feed/user/{self}', grid);

    // ⑦ **按用户名**取资料：instagrapi 的 `user_info_by_username`
    //    （`users/{username}/usernameinfo/`）—— 别人主页只有用户名时走这一条。
    //    用户名从 ① 那一发的响应里现取（写死会随账号失效）。
    if (MobileProbe.selfUsername.length > 0) {
      const byName: MobileResult = await MobileRequest.send(
        `users/${encodeURIComponent(MobileProbe.selfUsername)}/usernameinfo/`, '', '',
        true, null, MobileProbe.opts());
      tries.push(MobileProbe.scoutLine('users/{username}/usernameinfo', byName));
      MobileProbe.scoutBody(lines, 'users/{username}/usernameinfo', byName);
    } else {
      lines.push('');
      lines.push('users/{username}/usernameinfo 跳过（没从 user_info 里读到自己的用户名）');
    }

    // ⑧ 主页**另外三个分页**（"我的"下面那四个）：被标注 / Reels / 收藏。
    //    目标是让它们也走移动端，不再依赖 GraphQL 模板（用户要求）。
    //    被标注：instagram-private-api 的 `UsertagsFeed` → `usertags/{pk}/feed/`（GET）。
    const tagged: MobileResult = await MobileRequest.send(
      `usertags/${selfId}/feed/`, '', '', true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('usertags/{pk}/feed', tagged));
    MobileProbe.scoutBody(lines, 'usertags/{pk}/feed', tagged);

    //    Reels 分页：instagrapi 的 `user_clips`（`clips/user/`，表单带 target_user_id）。
    //    GET 与 POST 都试一发 —— 这条端点本项目从没打过，哪种被接受让服务端说话。
    const clipsByUserGet: MobileResult = await MobileRequest.send(
      'clips/user/', '', `target_user_id=${encodeURIComponent(selfId)}&page_size=12`,
      true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('clips/user[GET]', clipsByUserGet));
    MobileProbe.scoutBody(lines, 'clips/user[GET]', clipsByUserGet);

    const clipsByUserData: Record<string, Object> = MobileRequest.withExtraData(identity);
    clipsByUserData['target_user_id'] = selfId;
    clipsByUserData['page_size'] = 12;
    const clipsByUserPost: MobileResult = await MobileRequest.send(
      'clips/user/', MobileRequest.formOf(clipsByUserData), '', true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('clips/user[POST]', clipsByUserPost));
    MobileProbe.scoutBody(lines, 'clips/user[POST]', clipsByUserPost);

    //    收藏：候选两条（`feed/saved/` 与 `collections/list/`——后者列的是"合集"而不是媒体，
    //    但如果它通、`feed/collection/{id}/` 也就有戏）。
    const saved: MobileResult = await MobileRequest.send(
      'feed/saved/', '', '', true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('feed/saved', saved));
    MobileProbe.scoutBody(lines, 'feed/saved', saved);

    const collections: MobileResult = await MobileRequest.send(
      'collections/list/', '', '', true, null, MobileProbe.opts());
    tries.push(MobileProbe.scoutLine('collections/list', collections));
    MobileProbe.scoutBody(lines, 'collections/list', collections);

    lines.push('');
    lines.push('== 结论一览 ==');
    for (let index: number = 0; index < tries.length; index++) {
      lines.push(tries[index]);
      hilog.info(DOMAIN, TAG, 'scout %{public}s', tries[index]);
    }
    MobileProbe.writeScout(lines);
  }

  /** 侦察的正文：一段结论 + 一棵结构树。 */
  private static scoutBody(lines: Array<string>, label: string, result: MobileResult): void {
    lines.push('');
    lines.push(`---- ${label} ----`);
    lines.push(MobileProbe.scoutLine(label, result));
    if (!result.ok || result.body.length === 0) {
      return;
    }
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed === null) {
      lines.push(`（响应不是 JSON，前 120 字）${result.body.substring(0, 120)}`);
      return;
    }
    MobileProbe.scoutTree(lines, 'root', parsed, 0, SCOUT_MAX_DEPTH);
  }

  /** 侦察结论落盘（单独一份文件，不挤占常规自检报告）。 */
  private static writeScout(lines: Array<string>): void {
    const context: common.UIAbilityContext | null = MobileProbe.context;
    if (context === null) {
      return;
    }
    try {
      const path: string = InstagramProbe.dumpFixed(context, 'Instarmony_scout', lines.join('\n'));
      hilog.info(DOMAIN, TAG, 'scout report written %{public}s lines=%{public}d', path, lines.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'scout report failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 把响应的**形状**打进日志（键名 + 值预览，最多 MAX_KEYS 个）。
   *
   * 只打形状不打全文：搬评论那条路时吃过教训 —— 几百 KB 的响应灌进日志，
   * 真机日志会被冲掉，反而看不到结论。这里够用来写解析层就行。
   */
  static logShape(label: string, result: MobileResult): void {
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, '%{public}s ✗ %{public}s', label, result.summary());
      // 失败那一发**必须**落盘：它才是"为什么不行"的答案（err / http 码 / IG 的原话）。
      MobileProbe.shape.push(`${label} ✗ ${result.summary()}`);
      return;
    }
    const parsed: Record<string, Object> | null = MobileProbe.parse(result.body);
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, '%{public}s ✓ %{public}s (body not an object)', label, result.summary());
      MobileProbe.shape.push(`${label} ✓ ${result.summary()} (body not an object)`);
      return;
    }
    const keys: Array<string> = Object.keys(parsed);
    const parts: Array<string> = [];
    for (let index: number = 0; index < keys.length && index < MAX_KEYS; index++) {
      parts.push(`${keys[index]}=${MobileProbe.preview(parsed[keys[index]])}`);
    }
    hilog.info(DOMAIN, TAG, '%{public}s ✓ %{public}s keys=[%{public}s]',
      label, result.summary(), parts.join(' '));
    // 键名落盘的意义：写解析层时不用再抓一次包 —— 快拍托盘的形状就是从这里知道的。
    MobileProbe.shape.push(`${label} ✓ ${result.summary()} keys=[${parts.join(' ')}]`);
  }

  /** 值的短预览：数组给条数，对象给键数，标量给截断后的值。 */
  private static preview(value: Object): string {
    if (value === null || value === undefined) {
      return 'null';
    }
    if (Array.isArray(value)) {
      const list: Array<Object> = value as Array<Object>;
      return `[${list.length}]${list.length > 0 ? MobileProbe.preview(list[0]) : ''}`;
    }
    if (typeof value === 'object') {
      const obj: Record<string, Object> = value as Record<string, Object>;
      const keys: Array<string> = Object.keys(obj);
      return `{${keys.length}:${keys.slice(0, 3).join(',')}}`;
    }
    const text: string = `${value}`;
    return text.length > MAX_VALUE ? `${text.substring(0, MAX_VALUE)}…` : text;
  }

  private static parse(text: string): Record<string, Object> | null {
    try {
      return JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      return null;
    }
  }

  /** 取一个对象字段（不是对象 / 不存在给 null）。 */
  private static objectOf(value: Object | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || Array.isArray(value)) {
      return null;
    }
    if (typeof value !== 'object') {
      return null;
    }
    return value as Record<string, Object>;
  }

  /** 取第一个非空字符串字段（键名新旧不一，容错比精确重要）。 */
  private static firstText(holder: Record<string, Object>, names: Array<string>): string {
    for (let index: number = 0; index < names.length; index++) {
      const value: Object | undefined = holder[names[index]];
      if (value === undefined || value === null) {
        continue;
      }
      const text: string = typeof value === 'string' ? value as string : `${value}`;
      if (text.length > 0 && text !== 'null' && text !== 'undefined') {
        return text;
      }
    }
    return '';
  }

  /** 一发结果的短标签（`ok/…`、`err/http`）。 */
  private static tip(result: MobileResult): string {
    return result.ok ? `ok(${result.bytes}b)` : `${result.error}/${result.code}`;
  }

  /** 可能被跳过的那几发：null = 跳过（不计入分母）。 */
  private static tipOrSkip(result: MobileResult | null): string {
    return result === null ? 'skip' : MobileProbe.tip(result);
  }
}
