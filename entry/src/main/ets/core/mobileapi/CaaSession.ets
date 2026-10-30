/*
 * **App 内账号密码登录的落地面**（CAA 路；协议实现在 core/mobileapi/CaaLogin）。
 *
 * 为什么要有这一层：
 *   · `CaaLogin` 只认"协议"，它不知道这个 App 怎么存会话 —— 它交出 cookie 串就完事；
 *   · 整个 App 的会话**只有一个来源**：Cookie 罐（见 InstagramCookieJar）。网页兜底、
 *     `MobileSession.ensure`、退出登录清罐，全都只看罐里有没有 `sessionid`；
 *   · 所以登录成功后必须把 Cookie **种进罐**，再让 `MobileSession` 重新捡起会话材料，
 *     否则就是"App 有两套会话观"：页面刷新一次就退回登录页。
 *
 * 另外要落盘的是 **USDID（设备侧 P-256 身份）**：真实 App 里它是设备常量，反复登录用同一把；
 * 每次换新等于"一台从没见过的设备"，风控更严。存 preferences，key 见下面常量。
 *
 * 会话与设备身份分开放：`MobileSession` 存的是"会话材料"（claim / rur / authorization），
 * 退出登录要清；USDID 是设备身份，退出登录时**保留**。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
// TLS 变体探针要用 http 的类型与枚举（见 tlsProbe）。
import { http } from '@kit.NetworkKit';
import { InstagramCookieJar, InstagramCookieSnapshot } from '../InstagramCookieJar';
import { CaaLogin, CaaResult, CaaStep, CaaUsdid } from './CaaLogin';
import { MobileIdentity, MobileSession } from './MobileSession';
import { base64, utf8 } from './MobileSign';
// 自建 TLS 1.3 通道（见 tls13Probe：App 内唯一能"换 ClientHello 指纹"的手段）。
import { Tls13Client } from '../net/Tls13Client';

const DOMAIN: number = 0xFF00;
const TAG: string = 'CaaSession';
/** 设备身份的 preferences 文件名（和 AppSettings / MobileSession 的仓分开，互不覆盖）。 */
const STORE_NAME: string = 'instarmony_caa';
const KEY_USDID: string = 'usdid';
const KEY_KID: string = 'usdid_kid';
const KEY_PRIVATE: string = 'usdid_private';
const KEY_PUBLIC: string = 'usdid_public';
/** 最近一次登录/前检/导入的诊断（只有结论与名字，没有密钥；重启还能复制）。 */
const KEY_LAST_DIAG: string = 'last_diag';
/** 最近一次失败时的原始响应（截断 100KB；同样只在本机，重启还能复制）。 */
const KEY_LAST_RAW: string = 'last_raw';
/** 最近一次登录请求体（脱敏副本；和响应分开存，见 rememberRequest）。 */
const KEY_LAST_REQUEST: string = 'last_request';
/**
 * 上次被 IG 限流（429）的时间戳（毫秒）。
 *
 * 为什么要记：限流是**会累加**的 —— 用户被 429 之后还可能继续点，每点一次 IG 就把窗口再推远。
 * 记下来之后，10 分钟内直接拒绝发请求，只提示"还要等多久"，比让他反复撞限流好。
 */
const KEY_LAST_429_AT: string = 'last_429_at';
/** 连续被限流的次数（冷却时长按它升级：10 → 20 → 40 分钟，上限 60）。 */
const KEY_429_COUNT: string = 'count_429';

/**
 * 冷却时长：第 1 次 429 等 10 分钟，之后每次翻倍（20 / 40 / 60 封顶）。
 *
 * 为什么要升级：IG 的限流窗口本身会一次比一次长 —— 同等的"等 10 分钟"在第二次被拒后
 * 根本不够，用户点了还是 429，只会以为"App 坏了"。宁可说得保守些。
 */
function cooldownMsOf(count: number): number {
  const rounds: number = Math.max(1, Math.min(4, count));
  return Math.min(60, 10 * Math.pow(2, rounds - 1)) * 60 * 1000;
}

/** 登录结果（给 UI：不抛异常，全部放在字段里）。 */
export class CaaOutcome {
  /** 是否登录成功（此时会话已经在 Cookie 罐里了）。 */
  ok: boolean = false;
  /** 是否卡在两步验证（此时要让用户输验证码，然后调 `submitCode`）。 */
  needsCode: boolean = false;
  /** 给人看的一句话（成功是"登录成功 · uid=…"，失败是原因）。 */
  reason: string = '';
  /** 逐步现场（`usdid 200 → attestation 200 → …`），界面上一行就能看出卡在哪。 */
  steps: string = '';

  constructor(ok: boolean, reason: string) {
    this.ok = ok;
    this.reason = reason;
  }
}

export class CaaSession {
  private static store: preferences.Preferences | null = null;
  /** 已解出来的设备身份（进程内缓存：私钥解析要动 crypto，不必每次重做）。 */
  private static device: CaaUsdid | null = null;

  /** 打开设备身份的仓（幂等；`EntryAbility.onCreate` 里和 `MobileSession.init` 一起调）。 */
  static init(context: common.Context): void {
    if (CaaSession.store !== null) {
      return;
    }
    try {
      CaaSession.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      // 上次的诊断读回来：重启之后仍然能"复制诊断"（不然失败一次就得再复现一次）。
      CaaSession.lastDiag = CaaSession.readText(KEY_LAST_DIAG);
      CaaSession.lastRaw = CaaSession.readText(KEY_LAST_RAW);
      CaaSession.lastRequest = CaaSession.readText(KEY_LAST_REQUEST);
      hilog.info(DOMAIN, TAG, 'usdid store opened');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open usdid store failed: %{public}s', (error as Error).message);
    }
  }

  /** 本机有没有存过设备身份（设置页可以据此显示"设备已登记"）。 */
  static hasDevice(): boolean {
    return CaaSession.device !== null || CaaSession.readText(KEY_USDID).length > 0;
  }

  /**
   * 取本机的 USDID（第一次用时生成并落盘）。
   *
   * @returns 拿不到（preferences 没打开）时返回 null。
   */
  static async deviceIdentity(): Promise<CaaUsdid | null> {
    if (CaaSession.device !== null) {
      return CaaSession.device;
    }
    const usdid: string = CaaSession.readText(KEY_USDID);
    const kid: string = CaaSession.readText(KEY_KID);
    const privateKey: string = CaaSession.readText(KEY_PRIVATE);
    const publicKey: string = CaaSession.readText(KEY_PUBLIC);
    if (usdid.length > 0 && kid.length > 0 && privateKey.length > 0) {
      const restored: CaaUsdid | null = await CaaUsdid.restore(usdid, kid, privateKey, publicKey);
      if (restored !== null) {
        CaaSession.device = restored;
        hilog.info(DOMAIN, TAG, 'usdid restored %{public}d chars', usdid.length);
        return restored;
      }
      // 存的东西解不开（换过设备加密/格式变了）：重新生成一份，别让登录彻底卡死。
      hilog.warn(DOMAIN, TAG, 'stored usdid unusable, generating a new one');
    }
    if (CaaSession.store === null) {
      return null;
    }
    const fresh: CaaUsdid = await CaaUsdid.generate();
    CaaSession.writeText(KEY_USDID, fresh.usdid);
    CaaSession.writeText(KEY_KID, fresh.kid);
    CaaSession.writeText(KEY_PRIVATE, fresh.exportPrivateKey());
    CaaSession.writeText(KEY_PUBLIC, fresh.publicKeyBase64());
    CaaSession.device = fresh;
    hilog.info(DOMAIN, TAG, 'usdid generated');
    return fresh;
  }

  /** 忘掉本机设备身份（诊断用：下次登录会像新设备一样）。 */
  static forgetDevice(): void {
    CaaSession.device = null;
    CaaSession.writeText(KEY_USDID, '');
    CaaSession.writeText(KEY_KID, '');
    CaaSession.writeText(KEY_PRIVATE, '');
    CaaSession.writeText(KEY_PUBLIC, '');
  }

  /**
   * 用账号密码登录（CAA 路）。
   *
   * @param username Instagram 用户名（不带 @）
   * @param password 明文密码（只在本进程内存里；加密后才出网，见 MobileCrypto.encryptPassword）
   */
  static async login(username: string, password: string): Promise<CaaOutcome> {
    const user: string = username.trim();
    if (user.length === 0 || password.length === 0) {
      return CaaSession.outcome(false, '用户名和密码都要填');
    }
    // 限流冷却期内直接不发请求：反复撞限流只会把 IG 的窗口推得更远。
    const waitMinutes: number = CaaSession.rateLimitWaitMinutes();
    if (waitMinutes > 0) {
      return CaaSession.outcome(false,
        `上次密码登录被 IG 限流（429），还要等约 ${waitMinutes} 分钟（期间别再点）。`
          + '**换会话不受影响**：先用「用已有会话导入」把电脑上的 settings.caa.json 粘进来即可。');
    }
    const device: CaaUsdid | null = await CaaSession.deviceIdentity();
    if (device === null) {
      return CaaSession.outcome(false, '设备身份没准备好（preferences 没打开？）');
    }
    // 登录用的"设备身份"（uuid / phoneId / mid / app 版本）走和移动 API 完全相同的那一份，
    // 这样登录出来的会话在 `MobileSession` 里就是"同一个客户端"。
    const identity: MobileIdentity = MobileSession.seedIdentity();
    let result: CaaResult;
    /*
     * **把网页那份 Cookie 先喂给 CAA 请求**（真机反馈：CAA 五发全程 `cookie=` 为空、
     * `csrf=no`，而 IG 的官方客户端在登录时一定带着 `csrftoken`/`mid`/`ig_did`/`datr`
     * 这些设备级 Cookie）。2026-10-30 的日志里那位用户网页已经拿到 9 条 Cookie
     * （含 `rd_challenge`），但 CAA 一条都没带 —— 在 IG 眼里这就是"没有会话绑定的客户端"，
     * 正好落进它 `FakeIncorrectPassword` / 反脚本那一档。
     *
     * 只搬**设备级**那几颗：`sessionid` / `ds_user_id` 这类会话材料不搬（登录本来就还没有）。
     */
    try {
      const web: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      CaaLogin.seedCookies(web.cookie);
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'seed caa cookies skipped: %{public}s', (error as Error).message);
    }
    try {
      result = await CaaLogin.login(identity, user, password, device, null);
    } catch (error) {
      // 传输层（自建 TLS）抛出来的错要变成一句人话，而不是让界面炸掉。
      const thrown: CaaOutcome = CaaSession.outcome(false,
        `登录请求异常：${(error as Error).message}`, CaaSession.stepsText());
      CaaSession.rememberDiag('登录', thrown.reason, thrown.steps);
      return thrown;
    }
    return await CaaSession.finish(result);
  }

  /** 交两步验证码，把登录走完（必须在 `login` 返回 needsCode 之后）。 */
  static async submitCode(code: string): Promise<CaaOutcome> {
    const result: CaaResult = await CaaLogin.submitCode(code);
    return await CaaSession.finish(result);
  }


  /** 现在是不是等着交验证码。 */
  static waitingCode(): boolean {
    return CaaLogin.waitingCode();
  }




















  /**
   * 限流冷却还剩几分钟（0 = 可以试了）。
   *
   * 读 preferences 里的 `last_429_at`：冷却期内直接拒绝发请求，只提示还要等多久。
   * 冷却期一到就把**两份记录一起清掉**（时间和次数）—— 只清时间的话，次数会一直累加，
   * 下一次偶发 429 又会直接跳到 60 分钟档，用户会觉得"这 App 越用越登不上"。
   */
  static rateLimitWaitMinutes(): number {
    const text: string = CaaSession.readText(KEY_LAST_429_AT);
    if (text.length === 0) {
      return 0;
    }
    const at: number = Number.parseInt(text, 10);
    if (!Number.isFinite(at) || at <= 0) {
      return 0;
    }
    const remain: number = at + cooldownMsOf(CaaSession.rateLimitCount()) - Date.now();
    if (remain <= 0) {
      // 冷却期过了就清掉，别让它一直挡着
      CaaSession.clearRateLimit();
      return 0;
    }
    return Math.max(1, Math.ceil(remain / 60000));
  }

  /**
   * **清掉限流冷却记录**（设置页/登录面板给一颗按钮）。
   *
   * 为什么需要它：这份记录是"本机自己记的"，判断依据只有一次 HTTP 429。
   * 一旦那次 429 其实另有原因（这一轮就查到过：Cookie / `X-CSRFToken` 没带全，
   * IG 同样回 429），这条记录会**白白把用户挡在 10~60 分钟**之外，
   * 让他以为"程序坏了"。修好请求之后要能立刻重试，所以得有个显式的清入口。
   */
  static clearRateLimit(): void {
    CaaSession.writeText(KEY_LAST_429_AT, '');
    CaaSession.writeText(KEY_429_COUNT, '');
  }

  /** 连续 429 次数（读不到 / 脏数据当 0）。 */
  private static rateLimitCount(): number {
    const text: string = CaaSession.readText(KEY_429_COUNT);
    const count: number = Number.parseInt(text, 10);
    return Number.isFinite(count) && count > 0 ? count : 0;
  }

  /** 收尾：成功就把 Cookie 种进罐、让 MobileSession 捡起会话材料。 */
  private static async finish(result: CaaResult): Promise<CaaOutcome> {
    if (!result.ok) {
      if (result.needsCode) {
        const waiting: CaaOutcome = CaaSession.outcome(false, '需要两步验证码',
          CaaSession.stepsText());
        waiting.needsCode = true;
        CaaSession.rememberDiag('登录', waiting.reason, waiting.steps);
        return waiting;
      }
      const failed: CaaOutcome = CaaSession.outcome(false, result.reason, CaaSession.stepsText());
      CaaSession.rememberDiag('登录', failed.reason, failed.steps);
      // 失败时把原始响应留下（真机上唯一的现场；成功时不存，避免会话材料被随手复制）。
      CaaSession.rememberRaw(result.raw);
      // 这一发请求体（脱敏）也留一份：和桌面 JS 那条回 200 的链路逐键比对用。
      CaaSession.rememberRequest(CaaLogin.lastRequestDump);
      // 被限流就记下时间与次数：冷却期内不再发请求，避免把 IG 的窗口越推越远。
      if (result.rateLimited) {
        const count: number = CaaSession.rateLimitCount() + 1;
        CaaSession.writeText(KEY_429_COUNT, `${count}`);
        CaaSession.writeText(KEY_LAST_429_AT, `${Date.now()}`);
        const waitMinutes: number = Math.max(1, Math.ceil(cooldownMsOf(count) / 60000));
        const failedLimited: CaaOutcome = CaaSession.outcome(false,
          `密码登录被 IG 限流（429）—— 这是按「尝试次数」算的，已记为第 ${count} 次：`
            + `等约 ${waitMinutes} 分钟再点密码登录。`
            + '**换会话不受影响**：可以先用「用已有会话导入」把电脑上的 settings.caa.json 粘进来。',
          failed.steps);
        CaaSession.rememberDiag('登录', failedLimited.reason, failedLimited.steps);
        return failedLimited;
      }
      return failed;
    }
    // 登录成功：清掉限流记录（下次若再被限流重新计时）。
    CaaSession.writeText(KEY_LAST_429_AT, '');
    CaaSession.writeText(KEY_429_COUNT, '');
    const outcome: CaaOutcome = await CaaSession.applySession(result.cookie, result.authorization,
      '登录', result.mid, result.rur, result.claim);
    CaaSession.rememberDiag('登录', outcome.reason, outcome.steps);
    return outcome;
  }

  /**
   * **粘贴会话导入**（备用路：不从密码登录拿会话，而是把已有的设备级会话搬进来）。
   *
   * 为什么要这条：CAA 登录要账号密码、还可能撞验证码；而**设备级会话**本身可以从别处拿
   * （比如电脑上 `node instamony.js --caa-login` 跑出来的 `settings.caa.json` / `session.json`）。
   * 有了它，App 内的实时私信与本地通知**今天就能验**，不必等密码登录先成功 —— 万一密码那条
   * 路卡住，实时这条线也不是瞎子。
   *
   * 两种形状都收（都是我们自己产出的文件）：
   *   · `session.json`：`{ cookie: "name=value; …", authorization: "Bearer IGT:2:…" }`
   *   · `settings.caa.json`（instagrapi 形状）：`{ cookies: {…}, authorization_data: {…} }`
   *
   * @param text 粘贴进来的 JSON 文本
   */
  static async adoptPasted(text: string): Promise<CaaOutcome> {
    const raw: string = text.trim();
    if (raw.length === 0) {
      return CaaSession.outcome(false, '粘贴框是空的');
    }
    let parsed: Record<string, ESObject>;
    try {
      parsed = JSON.parse(raw) as Record<string, ESObject>;
    } catch (error) {
      return CaaSession.outcome(false, '不是合法 JSON（整份复制，别漏括号）');
    }
    const cookie: string = CaaSession.cookieTextOf(parsed);
    if (cookie.length === 0) {
      return CaaSession.outcome(false, '里面没有会话 Cookie（要么是 session.json，'
        + '要么是 instagrapi 的 settings.json）');
    }
    const authorization: string = CaaSession.authorizationOf(parsed);
    // 粘贴的两种形状都带 `mid`（instagrapi 的 settings.json 里是 `mid` 字段），有就一起用上。
    const outcome: CaaOutcome = await CaaSession.applySession(cookie, authorization, '导入',
      CaaSession.textFieldOf(parsed, 'mid'), CaaSession.textFieldOf(parsed, 'rur'),
      CaaSession.textFieldOf(parsed, 'claim'));
    CaaSession.rememberDiag('导入', outcome.reason, outcome.steps);
    return outcome;
  }

  /** 取一个字符串字段（不是字符串就当没有）。 */
  private static textFieldOf(parsed: Record<string, ESObject>, name: string): string {
    const value: ESObject = parsed[name];
    return typeof value === 'string' ? (value as string).trim() : '';
  }

  /** 从两种形状里取出 Cookie 串（`name=value; …`）。 */
  private static cookieTextOf(parsed: Record<string, ESObject>): string {
    const direct: ESObject = parsed['cookie'];
    if (typeof direct === 'string' && (direct as string).trim().length > 0) {
      return (direct as string).trim();
    }
    const map: ESObject = parsed['cookies'];
    if (map === null || map === undefined || typeof map !== 'object') {
      return '';
    }
    const record: Record<string, ESObject> = map as Record<string, ESObject>;
    const pairs: Array<string> = [];
    for (const name of Object.keys(record)) {
      const value: string = `${record[name]}`;
      if (name.length > 0 && value.length > 0) {
        pairs.push(`${name}=${value}`);
      }
    }
    return pairs.join('; ');
  }

  /** 从两种形状里取出 `authorization`（settings.json 里是解开的 `authorization_data`）。 */
  private static authorizationOf(parsed: Record<string, ESObject>): string {
    const direct: ESObject = parsed['authorization'];
    if (typeof direct === 'string' && (direct as string).trim().length > 0) {
      return (direct as string).trim();
    }
    const data: ESObject = parsed['authorization_data'];
    if (data === null || data === undefined || typeof data !== 'object') {
      return '';
    }
    const record: Record<string, ESObject> = data as Record<string, ESObject>;
    if (Object.keys(record).length === 0) {
      return '';
    }
    // 和 relay 的 `session-format.js` 同一个拼法：`Bearer IGT:2:` + base64(JSON)。
    return `Bearer IGT:2:${base64(utf8(JSON.stringify(record)), false)}`;
  }

  /**
   * **会话落地的唯一实现**（密码登录与粘贴导入共用）。
   *
   * @param cookieText    `name=value; …`
   * @param authorization `Bearer IGT:2:…`（可为空：那就用本地按 userId/sessionid 拼的那份）
   * @param what          用在提示文案里（"登录"/"导入"）
   * @param mid           登录响应头带回来的机器 id（空 = 用现有身份里的）
   * @param rur           登录响应头带回来的 `IG-U-RUR`
   * @param claim         登录响应头带回来的 `X-IG-WWW-Claim`
   */
  private static async applySession(cookieText: string, authorization: string, what: string,
                                    mid: string = '', rur: string = '',
                                    claim: string = ''): Promise<CaaOutcome> {
    const sessionId: string = CaaSession.cookieValue(cookieText, 'sessionid');
    /*
     * **`sessionid` 不再是硬要求**：IG 现在会下发设备级会话 —— 只有
     * `Authorization: Bearer IGT:2:…` + `ig-u-*` cookie（`ds_user_id` 在），没有 sessionid。
     * 真机实测这种会话探活 200、`push/register/` 也 ok。判据改成"有账号 id，且
     * sessionid / authorization 至少有一个"。
     */
    const cookieUserId: string = CaaSession.cookieValue(cookieText, 'ds_user_id');
    if (cookieUserId.length === 0 || (sessionId.length === 0 && authorization.length === 0)) {
      return CaaSession.outcome(false,
        `${what}的会话不完整（没有 ds_user_id，或 sessionid / authorization 都缺）`,
        CaaSession.stepsText());
    }
    // authorization 先落到身份里：设备级会话没有 sessionid，只能靠它打私有 API。
    if (sessionId.length === 0) {
      hilog.info(DOMAIN, TAG, 'device-level session (no sessionid), adopting authorization');
      MobileSession.adoptAuthorization(authorization, cookieUserId);
      // 紧接着界面会经历一次「未登录 → 已登录」的复位；给这一份 authorization 一张免清通行证，
      // 否则它会被 `clearSession()` 抹掉 —— 设备级会话的唯一凭据就没了。
      MobileSession.keepAuthorizationForNextReset();
    }
    // 整串都种：除了会话三件套，还带 mid / rur / ig_did 这类设备材料。
    let written: number = await InstagramCookieJar.adoptCookieText(cookieText);
    if (written === 0) {
      // 兜底：退回只种会话三件套（和网页登录/切换账号同一个接口）。
      const userId: string = CaaSession.cookieValue(cookieText, 'ds_user_id');
      const csrf: string = CaaSession.cookieValue(cookieText, 'csrftoken');
      const adopted: boolean = await InstagramCookieJar.adoptSession(sessionId, userId, csrf);
      written = adopted ? 3 : 0;
    }
    if (written === 0) {
      return CaaSession.outcome(false, '会话 Cookie 写不进罐（WebCookieManager 失败）',
        CaaSession.stepsText());
    }
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    if (!snapshot.signedIn) {
      return CaaSession.outcome(false, 'Cookie 写进去了，但罐里读不到登录态（重开 App 再试）',
        CaaSession.stepsText());
    }
    // 让 MobileSession 重新捡会话：它读罐、拼身份、并把 authorization 一起带上。
    // 注意 authorization 要**服务端下发的那一份**（`Bearer IGT:2:…`），不是本地算的。
    try {
      const session: MobileSession = MobileSession.getInstance();
      const identity: MobileIdentity | null = await session.ensure();
      if (identity !== null) {
        if (authorization.length > 0) {
          identity.authorization = authorization;
        }
        /*
         * **把响应头里的会话材料也吸收进身份**。
         *
         * 全新安装时 `mid` 是空的；IG 在登录响应里会下发真正的机器 id（`ig-set-x-mid`），
         * 之后每个移动 API 都带 `X-MID`。只留 authorization、把 mid 丢掉，等于登录成功之后
         * 仍是个"没有机器 id 的客户端"。
         */
        if (mid.length > 0) {
          identity.mid = mid;
        }
        if (rur.length > 0) {
          identity.igURur = rur;
        }
        if (claim.length > 0) {
          identity.wwwClaim = claim;
        }
        session.persist();
        hilog.info(DOMAIN, TAG, 'session adopted uid=%{public}s mid=%{public}s rur=%{public}d',
          identity.userId, identity.mid.length > 0 ? 'y' : 'n', identity.igURur.length);
        return CaaSession.outcome(true, `${what}成功 · uid=${identity.userId}`,
          CaaSession.stepsText());
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'mobile session ensure failed: %{public}s',
        (error as Error).message);
    }
    // Cookie 罐已经是登录态了（网页那边能用），只是移动 API 身份没建起来：不算失败。
    return CaaSession.outcome(true, `${what}成功（移动会话材料未就绪）`, CaaSession.stepsText());
  }

  private static outcome(ok: boolean, reason: string, steps: string = ''): CaaOutcome {
    const outcome: CaaOutcome = new CaaOutcome(ok, reason);
    outcome.steps = steps;
    return outcome;
  }

  /** `name=value; name=value` → 取某一颗的值（取不到返回空串）。 */
  private static cookieValue(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      const cut: number = one.indexOf('=');
      if (cut <= 0) {
        continue;
      }
      if (one.substring(0, cut).trim() === name) {
        return one.substring(cut + 1).trim();
      }
    }
    return '';
  }

  /**
   * **导出当前会话**（给 relay 用：反过来把手机上拿到的设备级会话搬回电脑）。
   *
   * 产出的是 **instagrapi `settings.json` 的形状**（`cookies` 映射 + `uuids` +
   * `authorization_data`），所以电脑那边**不需要新命令**：直接
   * `node instamony.js --import-session <这份文件>` 就能用。
   *
   * 这一步补上了闭环的另一半：以前只有"电脑 → 手机"（粘贴导入），现在是双向的。
   * 用户可以在手机上用密码登录拿到会话，再把会话搬到电脑跑中转，不必在电脑上重登一次。
   *
   * @returns JSON 文本（没有会话时返回空串）
   */
  static async exportSession(): Promise<string> {
    let identity: MobileIdentity | null = null;
    try {
      identity = await MobileSession.getInstance().ensure();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'export: ensure failed %{public}s', (error as Error).message);
    }
    const snapshot: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
    if (identity === null || !snapshot.signedIn) {
      return '';
    }
    // cookie 串 → 映射（instagrapi settings.json 里是对象，不是串）
    const cookies: Record<string, string> = {};
    const parts: Array<string> = snapshot.cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      const cut: number = one.indexOf('=');
      if (cut <= 0) {
        continue;
      }
      cookies[one.substring(0, cut).trim()] = one.substring(cut + 1).trim();
    }
    const authorizationData: Record<string, ESObject> = CaaSession.authorizationDataOf(identity.authorization);
    const uuids: Record<string, string> = {
      'phone_id': identity.phoneId,
      'uuid': identity.uuid,
      'android_device_id': `android-${identity.androidDeviceId}`,
      'client_session_id': identity.clientSessionId
    };
    const deviceSettings: Record<string, string> = {
      'app_version': identity.app.appVersion,
      'version_code': identity.app.versionCode,
      'bloks_versioning_id': identity.app.bloksVersioningId
    };
    const out: Record<string, ESObject> = {};
    out['cookies'] = cookies;
    out['uuids'] = uuids;
    out['authorization_data'] = authorizationData;
    out['device_settings'] = deviceSettings;
    out['user_agent'] = identity.userAgent();
    out['mid'] = identity.mid;
    out['last_login'] = new Date().toISOString();
    return JSON.stringify(out, null, 2);
  }

  /** `Bearer IGT:2:<base64(JSON)>` → 那个 JSON 对象（解不开回空对象）。 */
  private static authorizationDataOf(authorization: string): Record<string, ESObject> {
    const marker: string = 'Bearer IGT:2:';
    if (!authorization.startsWith(marker)) {
      return {};
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(authorization.substring(marker.length));
      const text: string = new util.TextDecoder().decodeToString(bytes);
      return JSON.parse(text) as Record<string, ESObject>;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'authorization decode failed: %{public}s', (error as Error).message);
      return {};
    }
  }

  /** 逐步现场，压成一行（界面只有一行能显示）。 */
  static stepsText(): string {
    const steps: Array<CaaStep> = CaaLogin.lastSteps();
    const parts: Array<string> = [];
    for (let index: number = 0; index < steps.length; index++) {
      const one: CaaStep = steps[index];
      // **note 也要带上**：`aac 303` / `cookie=…` / `csrf=yes` 这些是排障的分辨点，
      // 只报状态码的话，两种完全不同的原因在界面上一模一样。
      const note: string = one.note.length > 0 ? ` (${one.note})` : '';
      parts.push(one.status > 0 ? `${one.name} ${one.status}${note}` : `${one.name}${note}`);
    }
    return parts.join(' → ');
  }

  /*
   * **登录诊断（一键复制）**。
   *
   * 为什么要它：CAA 登录的失败点很多（USDID / attestation / aac / oauth / send_login_request /
   * 2SV），而真机上既没有 hdc、hilog 又会被冲掉。把最近一次的结论 + 逐步现场 + 响应里出现过的
   * **名字**（cookie 名 / header 名，**不含任何值**）攒成一段文字，用户复制出来发给我们，
   * 就能判断是"布局形状变了"还是"账号侧的问题"。
   */
  private static lastDiag: string = '';
  /** 最近一次失败时的原始响应（截断；有就存 preferences，重启后仍可复制）。 */
  private static lastRaw: string = '';
  /** 最近一次 `send_login_request` 的请求体（脱敏副本，见 rememberRequest）。 */
  private static lastRequest: string = '';

  /**
   * **退出登录：把登录痕迹一起抹掉**（诊断文本 / 原始响应 / 最近请求体 / 限流冷却）。
   *
   * 为什么必须清：`last_raw` 是**原始响应**（里面有 `user.pk`、`username`、session 相关的
   * 字段名与值），`last_request` 里也有账号与设备信息 —— 用户要求"退出登录必须清除所有
   * 相关信息"，这些留着就是把上一个人的登录记录躺在盘上。
   * **USDID / 密钥（设备身份）保留**：它属于这台设备，换账号不该重新登记。
   */
  static clearLoginTraces(): void {
    CaaSession.lastDiag = '';
    CaaSession.lastRaw = '';
    CaaSession.lastRequest = '';
    CaaSession.writeText(KEY_LAST_DIAG, '');
    CaaSession.writeText(KEY_LAST_RAW, '');
    CaaSession.writeText(KEY_LAST_REQUEST, '');
    CaaSession.writeText(KEY_LAST_429_AT, '');
    CaaSession.writeText(KEY_429_COUNT, '');
    hilog.info(DOMAIN, TAG, 'login traces cleared (device identity kept)');
  }

  /** 最近一次登录/前检/导入的诊断文本（给"复制诊断"用）。 */
  static diagText(): string {
    if (CaaSession.lastDiag.length === 0) {
      return '还没有跑过登录 / 前检 / 导入（先点一次「设备/网络前检」）';
    }
    return CaaSession.lastDiag;
  }

  /** 最近一次失败时的**原始响应**（没有就返回空串）。 */
  static lastResponseText(): string {
    return CaaSession.lastRaw;
  }

  /** 记下失败时的原始响应（截断，见 CaaResult.raw 的说明）。 */
  private static rememberRaw(raw: string): void {
    CaaSession.lastRaw = raw.length > 100000 ? raw.substring(0, 100000) : raw;
    if (CaaSession.lastRaw.length > 0) {
      CaaSession.writeText(KEY_LAST_RAW, CaaSession.lastRaw);
    }
  }

  /** 把一次结论记成诊断文本（只存给人看的字段，不含 cookie / authorization）。 */
  private static rememberDiag(what: string, reason: string, steps: string,
                              extra: string = ''): void {
    const lines: Array<string> = [];
    lines.push(`[CAA ${what}] ${reason}`);
    if (steps.length > 0) {
      lines.push(`步骤：${steps}`);
    }
    if (extra.length > 0) {
      lines.push(extra);
    }
    lines.push(`设备身份：${CaaSession.hasDevice() ? '有' : '无'}`);
    /*
     * **机器 id / UA 落到诊断里**。
     *
     * 这一轮查到：`send_login_request` 的 429（空 body）有一个成因是 `machine_id` 为空
     * （app 老版本 `mint()` 里 `mid = ''`，见 MobileSession.ensureMid）。光看状态码分不出
     * "被限流"和"请求不成形"，所以把这两项写进诊断，一眼就能看出来。
     */
    try {
      const identity: MobileIdentity = MobileSession.seedIdentity();
      lines.push(`机器 id：${identity.mid.length > 0 ? `${identity.mid.length} 位` : '空（登录会被判成非真机）'}`);
      lines.push(`UA：${identity.userAgent()}`);
    } catch (error) {
      lines.push('机器 id：读取失败');
    }
    lines.push(`等待验证码：${CaaSession.waitingCode() ? '是' : '否'}`);
    const text: string = lines.join('\n');
    CaaSession.lastDiag = text;
    CaaSession.writeText(KEY_LAST_DIAG, text);
    hilog.info(DOMAIN, TAG, 'diag remembered (%{public}d chars)', text.length);
  }

  private static readText(key: string): string {
    const store: preferences.Preferences | null = CaaSession.store;
    if (store === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = store.getSync(key, '');
      return typeof value === 'string' ? value as string : '';
    } catch (error) {
      return '';
    }
  }

  private static writeText(key: string, value: string): void {
    const store: preferences.Preferences | null = CaaSession.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'write %{public}s failed: %{public}s', key, (error as Error).message);
    }
  }

  /**
   * 记下这一发 `send_login_request` 的**请求体脱敏副本**（见 `CaaLogin.lastRequestDump`）。
   *
   * 和「最近一次响应」分两个键存：响应是"IG 说了什么"，请求是"我们发了什么"，
   * 排查 429 时两边都要能拿出来对照（桌面 JS 那条同样的链路是通的）。
   */
  static lastRequestText(): string {
    return CaaSession.lastRequest;
  }

  private static rememberRequest(dump: string): void {
    const headers: string = CaaLogin.lastRequestHeaders;
    const combined: string = headers.length > 0 ? `${dump}\n\n--- headers ---\n${headers}` : dump;
    const text: string = combined.length > 200000 ? combined.substring(0, 200000) : combined;
    CaaSession.lastRequest = text;
    CaaSession.writeText(KEY_LAST_REQUEST, text);
  }
}

