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
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramCookieJar, InstagramCookieSnapshot } from '../InstagramCookieJar';
import { CaaLogin, CaaResult, CaaStep, CaaUsdid } from './CaaLogin';
import { MobileIdentity, MobileSession } from './MobileSession';
import { base64, utf8 } from './MobileSign';

const DOMAIN: number = 0xFF00;
const TAG: string = 'CaaSession';
/** 设备身份的 preferences 文件名（和 AppSettings / MobileSession 的仓分开，互不覆盖）。 */
const STORE_NAME: string = 'instarmony_caa';
const KEY_USDID: string = 'usdid';
const KEY_KID: string = 'usdid_kid';
const KEY_PRIVATE: string = 'usdid_private';
const KEY_PUBLIC: string = 'usdid_public';

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
    const device: CaaUsdid | null = await CaaSession.deviceIdentity();
    if (device === null) {
      return CaaSession.outcome(false, '设备身份没准备好（preferences 没打开？）');
    }
    // 登录用的"设备身份"（uuid / phoneId / mid / app 版本）走和移动 API 完全相同的那一份，
    // 这样登录出来的会话在 `MobileSession` 里就是"同一个客户端"。
    const identity: MobileIdentity = MobileSession.seedIdentity();
    const result: CaaResult = await CaaLogin.login(identity, user, password, device, null);
    return await CaaSession.finish(result);
  }

  /** 交两步验证码，把登录走完（必须在 `login` 返回 needsCode 之后）。 */
  static async submitCode(code: string): Promise<CaaOutcome> {
    const result: CaaResult = await CaaLogin.submitCode(code);
    return await CaaSession.finish(result);
  }

  /**
   * **设备 / 网络前检**（不填密码、不需要账号）。
   *
   * 只跑到"取到 aac"：USDID 注册 → attestation nonce → aac。这三步与账号无关，
   * 所以它能把两类失败**分开**：
   *   · 前检失败 → 设备身份 / 网络 / IG 端点这侧的问题（改了也白改密码）；
   *   · 前检通过而登录失败 → 账号侧的问题（密码错、要验证码、被风控）。
   *
   * 注意返回的 `ok` 表示"前检通过"，**不是**"已登录"——UI 不要据此切换登录态。
   */
  static async preflight(): Promise<CaaOutcome> {
    const device: CaaUsdid | null = await CaaSession.deviceIdentity();
    if (device === null) {
      return CaaSession.outcome(false, '设备身份没准备好（preferences 没打开？）');
    }
    const identity: MobileIdentity = MobileSession.seedIdentity();
    const result: CaaResult = await CaaLogin.login(identity, '', '', device, null, true);
    const outcome: CaaOutcome = CaaSession.outcome(result.ok, result.reason,
      CaaSession.stepsText());
    return outcome;
  }

  /** 现在是不是等着交验证码。 */
  static waitingCode(): boolean {
    return CaaLogin.waitingCode();
  }

  /** 收尾：成功就把 Cookie 种进罐、让 MobileSession 捡起会话材料。 */
  private static async finish(result: CaaResult): Promise<CaaOutcome> {
    if (!result.ok) {
      if (result.needsCode) {
        const waiting: CaaOutcome = CaaSession.outcome(false, '需要两步验证码',
          CaaSession.stepsText());
        waiting.needsCode = true;
        return waiting;
      }
      return CaaSession.outcome(false, result.reason, CaaSession.stepsText());
    }
    return await CaaSession.applySession(result.cookie, result.authorization, '登录',
      result.mid, result.rur, result.claim);
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
    return await CaaSession.applySession(cookie, authorization, '导入',
      CaaSession.textFieldOf(parsed, 'mid'), CaaSession.textFieldOf(parsed, 'rur'),
      CaaSession.textFieldOf(parsed, 'claim'));
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
    if (sessionId.length === 0) {
      return CaaSession.outcome(false, `${what}的会话里没有 sessionid（内容不完整）`,
        CaaSession.stepsText());
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

  /** 逐步现场，压成一行（界面只有一行能显示）。 */
  static stepsText(): string {
    const steps: Array<CaaStep> = CaaLogin.lastSteps();
    const parts: Array<string> = [];
    for (let index: number = 0; index < steps.length; index++) {
      const one: CaaStep = steps[index];
      parts.push(one.status > 0 ? `${one.name} ${one.status}` : one.name);
    }
    return parts.join(' → ');
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
}
