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
    const sessionId: string = CaaSession.cookieValue(result.cookie, 'sessionid');
    if (sessionId.length === 0) {
      return CaaSession.outcome(false, '登录成功但响应里没有 sessionid（布局形状可能变了）',
        CaaSession.stepsText());
    }
    // 整串都种：CAA 的响应除了会话三件套，还带 mid / rur / ig_did 这类设备材料。
    let written: number = await InstagramCookieJar.adoptCookieText(result.cookie);
    if (written === 0) {
      // 兜底：退回只种会话三件套（和网页登录/切换账号同一个接口）。
      const userId: string = CaaSession.cookieValue(result.cookie, 'ds_user_id');
      const csrf: string = CaaSession.cookieValue(result.cookie, 'csrftoken');
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
        if (result.authorization.length > 0) {
          identity.authorization = result.authorization;
        }
        session.persist();
        hilog.info(DOMAIN, TAG, 'session adopted uid=%{public}s', identity.userId);
        const outcome: CaaOutcome = CaaSession.outcome(true,
          `登录成功 · uid=${identity.userId}`, CaaSession.stepsText());
        return outcome;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'mobile session ensure failed: %{public}s',
        (error as Error).message);
    }
    // Cookie 罐已经是登录态了（网页那边能用），只是移动 API 身份没建起来：不算失败。
    return CaaSession.outcome(true, '登录成功（移动会话材料未就绪）', CaaSession.stepsText());
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
