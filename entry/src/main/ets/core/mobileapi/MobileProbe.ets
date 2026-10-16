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
import { MobileRequest, MobileResult } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';
import { SUPPORTED_CAPABILITIES } from './MobileConfig';
import { InstagramProbe } from '../../probe/InstagramProbe';

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

/** 响应摘要里最多列几个键。 */
const MAX_KEYS: number = 14;
/** 摘要里每个值最多留多少字符。 */
const MAX_VALUE: number = 60;
/** 落盘时最多留几行形状（够写解析层就行，别把文件撑大）。 */
const MAX_SHAPE_LINES: number = 60;

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
    MobileProbe.last = `ok=${ok}/${total} info=${MobileProbe.tip(info)} tray=${MobileProbe.tip(tray)}`
      + ` inbox=${MobileProbe.tip(inbox)} self=${MobileProbe.tip(story)}`
      + ` user=${MobileProbe.tipOrSkip(other)} media=${MobileProbe.tipOrSkip(mediaBare)}`
      + ` mediaJson=${MobileProbe.tipOrSkip(mediaJson)}`;
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

  /** ① `GET /api/v1/users/{uid}/info/`（instagrapi 的 `user_info_v1`，最小的一发）。 */
  static async userInfo(identity: MobileIdentity): Promise<MobileResult> {
    const result: MobileResult = await MobileRequest.send(
      `users/${identity.userId}/info/`, '', '', true);
    MobileProbe.logShape('user_info', result);
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
      'feed/reels_tray/', MobileRequest.formOf(data), '', true);
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
      'direct_v2/inbox/', MobileRequest.formOf(data), query, true);
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
      `feed/user/${userId}/story/`, '', '', true);
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
    const result: MobileResult = await MobileRequest.send('feed/reels_media/', '', params, true);
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

  /** 一发结果的短标签（`ok/…`、`err/http`）。 */
  private static tip(result: MobileResult): string {
    return result.ok ? `ok(${result.bytes}b)` : `${result.error}/${result.code}`;
  }

  /** 可能被跳过的那几发：null = 跳过（不计入分母）。 */
  private static tipOrSkip(result: MobileResult | null): string {
    return result === null ? 'skip' : MobileProbe.tip(result);
  }
}
