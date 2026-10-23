/*
 * 移动 API 的**设备身份与会话**（对应 instagrapi 的 `LoginMixin` 里那部分状态）。
 *
 * ## 会话从哪来：复用网页 Cookie 罐（这是本项目选的路线）
 * instagrapi 的 `login_by_sessionid(sessionid)` 其实**不做任何登录**，它只是：
 *   1. 把 `sessionid` 放进 cookie 罐；
 *   2. 从 sessionid 的**数字前缀**取出 user id；
 *   3. 把 `{"ds_user_id", "sessionid", "should_use_header_over_cookies": true}`
 *      base64 成 `Authorization: Bearer IGT:2:<...>` 直接开始打私有 API。
 * 也就是说"用网页会话打移动 API"在 instagrapi 里本来就是**一等公民**，
 * 我们走同一条路，只是会话来源换成 ArkWeb 的 Cookie 罐（`core/InstagramCookieJar`）——
 * 于是 L3（密码登录 / 2FA / challenge）**一行都不用写**。
 *
 * ## 首启会缺什么：claim 与 rur
 * instagrapi 的默认 `x-ig-www-claim` 就是字符串 `"0"`，它同样**不自己算**这个值：
 * 真实 claim 由服务端在**响应头**里下发（`x-ig-set-www-claim`），客户端记住并在后续请求带上。
 * 也就是说这条路的"自举"是：先带 `0` 打一发 → 从响应头捡起 claim/rur/mid → 存下来。
 * 本项目在网页那条路上已经撞过同一堵墙（`AUDIT_TODO.md`：快拍 500 的根因之一就是缺 claim），
 * 所以这里把"捡取回写"做成第一等公民（见 MobileSession.absorbResponseHeaders）。
 *
 * ## 持久化
 * 设备身份（8 个 UUID）与 `mid` / `claim` / `rur` 必须**跨重启稳定**：
 * 每次启动重新随机一套 UUID，在 IG 看来就是"同一账号天天换设备"，比不换更可疑。
 * 用 preferences 落盘（与 `bridge/ApiRegistry` 的模板落盘同一套做法）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramCookieJar, InstagramCookieSnapshot } from '../InstagramCookieJar';
import {
  API_DOMAIN,
  APP_SETTINGS,
  AppProfile,
  COHERENT_FINGERPRINT,
  DEFAULT_APP_VERSION,
  DEFAULT_COUNTRY,
  DEFAULT_LOCALE,
  DEFAULT_TIMEZONE_NAME,
  DEFAULT_TIMEZONE_OFFSET,
  DeviceProfile,
  USER_AGENT_BASE,
  deviceLocale,
  deviceTimezoneOffset
} from './MobileConfig';
import { androidDeviceId, base64UrlNoPad, genToken, utf8, uuid4 } from './MobileSign';
// 真机设备档案（见 DeviceTruth 的文件头：把"自称 Pixel 8 Pro"换成"这台机器自己"）。
import { DeviceTruth } from './DeviceTruth';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileSession';
/** 身份落盘的 preferences 文件名 / 键。 */
const STORE_NAME: string = 'instarmony_mobile_session';
const STORE_KEY: string = 'identity_v1';

/** 落盘的身份（字段短名 = 直接进 preferences 的 JSON）。 */
class StoredIdentity {
  phoneId: string = '';
  uuid: string = '';
  clientSessionId: string = '';
  advertisingId: string = '';
  androidDeviceId: string = '';
  requestId: string = '';
  traySessionId: string = '';
  mid: string = '';
  wwwClaim: string = '';
  igURur: string = '';
  authorization: string = '';
  appVersion: string = '';
  savedAt: number = 0;
}

/** IG 会话 cookie 里我们要读的那几个（名字照抄 instagrapi 的 `cookie_dict` 用法）。 */
const COOKIE_SESSIONID: string = 'sessionid';
const COOKIE_DS_USER_ID: string = 'ds_user_id';
const COOKIE_CSRF: string = 'csrftoken';
const COOKIE_RUR: string = 'rur';
const COOKIE_MID: string = 'mid';

/**
 * 设备身份 + 会话材料。
 *
 * 不可变字段（uuid 等）在构造时定下来，可变字段（`mid` / `wwwClaim` / `igURur` /
 * `authorization`）由服务端响应头回写 —— 与 instagrapi 的可变属性一一对应。
 */
export class MobileIdentity {
  readonly phoneId: string;
  readonly uuid: string;
  readonly clientSessionId: string;
  readonly advertisingId: string;
  readonly androidDeviceId: string;
  readonly requestId: string;
  readonly traySessionId: string;
  /** 账号数字 id（= cookie `ds_user_id`，也是 sessionid 的数字前缀）。 */
  readonly userId: string;
  /** 网页会话串（Cookie 罐里的 `sessionid`）。 */
  readonly sessionId: string;
  /** CSRF（Cookie 罐里的 `csrftoken`；没有就现生成，见 MobileSession.ensure）。 */
  readonly csrf: string;
  /** `X-MID`：优先用服务端下发的，其次 cookie `mid`，最后本地生成。 */
  mid: string;
  /** `x-ig-www-claim`：服务端响应头下发，首启是 `0`。 */
  wwwClaim: string;
  /** `IG-U-RUR`：服务端响应头下发，首启取 cookie `rur`。 */
  igURur: string;
  /** `Authorization: Bearer IGT:2:<base64url>`。 */
  authorization: string;
  readonly device: DeviceProfile;
  readonly app: AppProfile;
  readonly locale: string;
  readonly country: string;
  readonly timezoneOffset: number;
  readonly timezoneName: string;
  readonly pushDisabled: boolean;

  constructor(seed: StoredIdentity, userId: string, sessionId: string, csrf: string, mid: string,
              rurFromCookie: string) {
    this.phoneId = seed.phoneId;
    this.uuid = seed.uuid;
    this.clientSessionId = seed.clientSessionId;
    this.advertisingId = seed.advertisingId;
    this.androidDeviceId = seed.androidDeviceId;
    this.requestId = seed.requestId;
    this.traySessionId = seed.traySessionId;
    this.userId = userId;
    this.sessionId = sessionId;
    this.csrf = csrf.length > 0 ? csrf : genToken(64);
    // mid：服务端下发 > cookie > 本地生成（instagrapi 的 `self.settings.get("mid", cookie_dict.get("mid"))`）
    this.mid = mid.length > 0 ? mid : seed.mid;
    this.wwwClaim = seed.wwwClaim.length > 0 ? seed.wwwClaim : '0';
    this.igURur = seed.igURur.length > 0 ? seed.igURur : rurFromCookie;
    this.authorization = seed.authorization.length > 0
      ? seed.authorization : MobileIdentity.buildAuthorization(userId, sessionId);
    // 设备档案：用**这台机器自己的**品牌/型号/分辨率/DPI（见 DeviceTruth）。
    // 只生成一次、终身不变 —— 轮换等于"同一账号天天换手机"，比不换更可疑。
    this.device = COHERENT_FINGERPRINT ? DeviceTruth.profile() : DeviceProfile.DEFAULT;
    const known: AppProfile | undefined = APP_SETTINGS.get(seed.appVersion);
    this.app = known !== undefined ? known : MobileSession.appProfileOrDefault(seed.appVersion);
    // 身份自洽（见 MobileConfig.COHERENT_FINGERPRINT）：时区/语言跟系统走，国家拿不到就不发。
    this.locale = COHERENT_FINGERPRINT ? deviceLocale() : DEFAULT_LOCALE;
    this.country = COHERENT_FINGERPRINT ? '' : DEFAULT_COUNTRY;
    this.timezoneOffset = COHERENT_FINGERPRINT ? deviceTimezoneOffset() : DEFAULT_TIMEZONE_OFFSET;
    this.timezoneName = COHERENT_FINGERPRINT ? '' : DEFAULT_TIMEZONE_NAME;
    this.pushDisabled = true;
  }

  /** 会话是否可用（有 sessionid 且有 user id 才能打私有 API）。 */
  isComplete(): boolean {
    return this.sessionId.length > 0 && this.userId.length > 0;
  }

  /**
   * `Authorization: Bearer IGT:2:<base64url(JSON)>`
   * （instagrapi 的 `authorization` property + `login_by_sessionid` 里那份 authorization_data）。
   *
   * 注意 `should_use_header_over_cookies` 必须是**真布尔**：这一位就是"请优先认这个头、
   * 别只认 cookie 罐"的开关，也是"网页会话能不能当移动会话用"的关键。
   */
  static buildAuthorization(userId: string, sessionId: string): string {
    if (userId.length === 0 || sessionId.length === 0) {
      return '';
    }
    const data: Record<string, Object> = {
      'ds_user_id': userId,
      'sessionid': sessionId,
      'should_use_header_over_cookies': true
    };
    return `Bearer IGT:2:${base64UrlNoPad(utf8(JSON.stringify(data)))}`;
  }

  /** User-Agent（instagrapi 的 `set_user_agent`：用模板把设备档案填进去）。 */
  userAgent(): string {
    return USER_AGENT_BASE
      .replace('{app_version}', this.app.appVersion)
      .replace('{android_version}', this.device.androidVersion)
      .replace('{android_release}', this.device.androidRelease)
      .replace('{dpi}', this.device.dpi)
      .replace('{resolution}', this.device.resolution)
      .replace('{manufacturer}', this.device.manufacturer)
      .replace('{model}', this.device.model)
      .replace('{device}', this.device.device)
      .replace('{cpu}', this.device.cpu)
      .replace('{locale}', this.locale)
      .replace('{version_code}', this.app.versionCode);
  }

  /** 落盘用的形状。 */
  toStored(): StoredIdentity {
    const out: StoredIdentity = new StoredIdentity();
    out.phoneId = this.phoneId;
    out.uuid = this.uuid;
    out.clientSessionId = this.clientSessionId;
    out.advertisingId = this.advertisingId;
    out.androidDeviceId = this.androidDeviceId;
    out.requestId = this.requestId;
    out.traySessionId = this.traySessionId;
    out.mid = this.mid;
    out.wwwClaim = this.wwwClaim;
    out.igURur = this.igURur;
    out.authorization = this.authorization;
    out.appVersion = this.app.appVersion;
    out.savedAt = Date.now();
    return out;
  }

  /** 一行摘要（日志 / 诊断用；**不含** sessionid 与 authorization 的值，只给长度）。 */
  summary(): string {
    return `user=${this.userId} mid=${this.mid.length > 0 ? 'y' : 'n'} `
      + `claim=${this.wwwClaim} rur=${this.igURur.length > 0 ? 'y' : 'n'} `
      + `auth=${this.authorization.length}b dev=${this.device.model} `
      + `app=${this.app.appVersion} csrf=${this.csrf.length}`;
  }
}

export class MobileSession {
  private static instance: MobileSession | null = null;
  private static store: preferences.Preferences | null = null;
  /**
   * 落盘那份身份的**进程内缓存**。
   *
   * 为什么必须是静态缓存而不是"每次读一遍盘"：`ensure()` 每次请求都会调 `loadSeed()`，
   * 而身份里有 8 个 UUID 是**一次随机、终身不变**的（见文件头"持久化"）。早先的写法用
   * `loaded` 布尔做闸门——第一次读盘，之后**每次调用都掉进 `mint()` 造一套新身份**：
   * 同一次运行里每发请求都换 phone_id / uuid / android_id，正是"同一账号疯狂换设备"，
   * 比不换设备更容易被 IG 判成异常（也会让自检结论忽好忽坏，无法复现）。
   */
  private static seed: StoredIdentity | null = null;
  private identity: MobileIdentity | null = null;

  static getInstance(): MobileSession {
    if (MobileSession.instance === null) {
      MobileSession.instance = new MobileSession();
    }
    return MobileSession.instance;
  }

  /** 打开身份落盘文件（幂等；ab`EntryAbility` 启动时调一次即可）。 */
  static init(context: common.Context): void {
    if (MobileSession.store !== null) {
      return;
    }
    try {
      MobileSession.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      hilog.info(DOMAIN, TAG, 'identity store opened');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open identity store failed: %{public}s', (error as Error).message);
    }
  }

  /** 已建好的身份（没有就返回 null，调用方据此决定要不要 `ensure`）。 */
  current(): MobileIdentity | null {
    return this.identity;
  }

  /**
   * 确保身份就绪：读落盘（或造一份新的）+ 从 Cookie 罐补齐会话材料。
   *
   * 每调用一次都会**重新读 Cookie 罐**：网页那边重新登录后 sessionid 会变，
   * 而身份（UUID / mid / claim）要保持不变 —— 两者来源不同，不能一起缓存。
   *
   * @returns 会话不完整（没登录）时返回 null。
   */
  async ensure(): Promise<MobileIdentity | null> {
    const seed: StoredIdentity = MobileSession.loadSeed();
    let jar: InstagramCookieSnapshot;
    try {
      jar = await InstagramCookieJar.inspect();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'cookie jar read failed: %{public}s', (error as Error).message);
      return null;
    }
    if (!jar.signedIn) {
      hilog.info(DOMAIN, TAG, 'ensure: not signed in');
      return null;
    }
    const sessionId: string = MobileSession.cookieOf(jar.cookie, COOKIE_SESSIONID);
    let userId: string = MobileSession.cookieOf(jar.cookie, COOKIE_DS_USER_ID);
    if (userId.length === 0) {
      // 兜底：sessionid 的数字前缀就是 user id（instagrapi 的 `re.search(r"^\d+", sessionid)`）。
      userId = MobileSession.userIdOfSession(sessionId);
    }
    if (sessionId.length === 0 || userId.length === 0) {
      hilog.warn(DOMAIN, TAG, 'ensure: session incomplete sid=%{public}d uid=%{public}d',
        sessionId.length, userId.length);
      return null;
    }
    const csrf: string = MobileSession.cookieOf(jar.cookie, COOKIE_CSRF);
    const midCookie: string = MobileSession.cookieOf(jar.cookie, COOKIE_MID);
    const rur: string = MobileSession.cookieOf(jar.cookie, COOKIE_RUR);
    const identity: MobileIdentity =
      new MobileIdentity(seed, userId, sessionId, csrf, midCookie, rur);
    this.identity = identity;
    hilog.info(DOMAIN, TAG, 'ensure ok %{public}s', identity.summary());
    return identity;
  }

  /**
   * 把服务端响应头里的会话材料**捡回来存下**（这条路的自举，见文件头）。
   *
   * instagrapi 在 `_send_private_request` 里只捡了 `ig-set-x-mid`，其余靠 cookie 罐；
   * 我们多做两步（claim / rur / authorization），因为**我们的会话来自网页**，
   * cookie 罐里未必带得住 claim —— 而本项目恰恰在"缺 claim"上吃过 500（见 AUDIT_TODO）。
   *
   * @returns 是否有任何一项被更新（调用方据此决定要不要落盘）。
   */
  absorbResponseHeaders(headers: Record<string, string>): boolean {
    const identity: MobileIdentity | null = this.identity;
    if (identity === null) {
      return false;
    }
    let changed: boolean = false;
    const mid: string = MobileSession.headerOf(headers, 'ig-set-x-mid');
    if (mid.length > 0 && mid !== identity.mid) {
      identity.mid = mid;
      changed = true;
    }
    const claim: string = MobileSession.headerOf(headers, 'x-ig-set-www-claim');
    if (claim.length > 0 && claim !== identity.wwwClaim) {
      identity.wwwClaim = claim;
      changed = true;
    }
    const rur: string = MobileSession.headerOf(headers, 'ig-set-ig-u-rur');
    if (rur.length > 0 && rur !== identity.igURur) {
      identity.igURur = rur;
      changed = true;
    }
    const auth: string = MobileSession.headerOf(headers, 'ig-set-authorization');
    if (auth.length > 0 && auth !== identity.authorization) {
      identity.authorization = auth;
      changed = true;
    }
    if (changed) {
      hilog.info(DOMAIN, TAG, 'server gave session material: mid=%{public}s claim=%{public}d rur=%{public}d',
        mid.length > 0 ? 'y' : 'n', claim.length, rur.length);
      this.persist();
    }
    return changed;
  }

  /** 把当前身份落盘（有变化时才调，见 absorbResponseHeaders）。 */
  persist(): void {
    const identity: MobileIdentity | null = this.identity;
    if (identity === null) {
      return;
    }
    const stored: StoredIdentity = identity.toStored();
    // 缓存一起更新：否则下次 `ensure()` 会拿旧 seed 再把 claim / mid 覆盖回去
    // （服务端刚下发的会话材料等于白捡）。
    MobileSession.seed = stored;
    MobileSession.writeSeed(stored);
  }

  /**
   * 退出登录：会话材料作废，设备身份**保留**（换账号也不该换设备）。
   *
   * 注意落盘这一步不能省：早先写成"先 `this.identity = null` 再 `persist()`"，
   * 而 `persist()` 见身份为空直接返回 —— 于是盘上那份旧 claim / rur / authorization
   * 会被下一段会话继续带上（都是**会话级**材料，串会话用就是失败）。
   */
  clearSession(): void {
    const identity: MobileIdentity | null = this.identity;
    if (identity === null) {
      return;
    }
    identity.mid = '';
    identity.wwwClaim = '0';
    identity.igURur = '';
    identity.authorization = '';
    // 先按"清空会话材料、保留设备身份"的形状写盘，再丢掉内存里的身份。
    const kept: StoredIdentity = identity.toStored();
    MobileSession.seed = kept;
    MobileSession.writeSeed(kept);
    this.identity = null;
    hilog.info(DOMAIN, TAG, 'session cleared (device identity kept)');
  }

  /**
   * **登录专用的设备身份**（不需要会话已建立）。
   *
   * `accounts/login/` 恰恰是在"还没有 sessionid"的时候发的：用 `ensure()` 会被
   * `not signed in` 直接挡掉。所以登录那条链用这一份 —— 只有设备 UUID（终身不变）、
   * 空 userId / 空 sessionId，以及一个临时 csrf（IG 登录表单也就要它）。
   *
   * 与 instagrapi 的对应：`self.private_request(..., login=True)` 用的还是那个 Client，
   * 只是请求上不带 Authorization / Cookie；设备身份来自 `set_uuids()`。
   */
  static seedIdentity(): MobileIdentity {
    const seed: StoredIdentity = MobileSession.loadSeed();
    // 登录请求要带 `_csrftoken`（instagrapi 的 `self.token` = cookie 里的 csrftoken，
    // 没有就 `gen_token(64)` 现造）——这里走"没有就现造"那一支。
    return new MobileIdentity(seed, '', '', '', seed.mid, '');
  }

  /**
   * **把登录拿到的会话材料吸收进来**（`entries` 见 MobileLogin 的返回值）。
   *
   * 与 `absorbResponseHeaders` 的区别：那份要求"身份已存在且有会话"，
   * 而登录是在那之前发生的 —— 这里直接从 seed 造一份完整身份，再落盘。
   *
   * @returns 是否拿到了可用的会话（false = 响应里没有 authorization / sessionid）
   */
  async adoptLogin(authorization: string, sessionId: string, userId: string,
                   mid: string, rur: string): Promise<boolean> {
    if (sessionId.length === 0 || userId.length === 0) {
      return false;
    }
    const seed: StoredIdentity = MobileSession.loadSeed();
    const identity: MobileIdentity =
      new MobileIdentity(seed, userId, sessionId, '', mid, rur);
    if (authorization.length > 0) {
      identity.authorization = authorization;
    }
    this.identity = identity;
    this.persist();
    hilog.info(DOMAIN, TAG, 'adopt login ok %{public}s', identity.summary());
    return true;
  }

  /**
   * 读落盘的身份；没有（全新安装 / 被清）就**造一份新的**。
   *
   * 造新的时候 8 个 UUID 全部现随机 —— 这是**一次性的**：
   * 之后每次启动都从盘里读同一份（见文件头"持久化"那段），进程内则走 `seed` 缓存。
   */
  private static loadSeed(): StoredIdentity {
    const cached: StoredIdentity | null = MobileSession.seed;
    if (cached !== null) {
      return cached;
    }
    const store: preferences.Preferences | null = MobileSession.store;
    if (store !== null) {
      try {
        const raw: string = store.getSync(STORE_KEY, '') as string;
        if (raw.length > 0) {
          const parsed: StoredIdentity = JSON.parse(raw) as StoredIdentity;
          if (MobileSession.isUsable(parsed)) {
            MobileSession.seed = parsed;
            hilog.info(DOMAIN, TAG, 'identity restored (saved %{public}d ago)',
              parsed.savedAt > 0 ? Math.round((Date.now() - parsed.savedAt) / 1000) : -1);
            return parsed;
          }
          hilog.warn(DOMAIN, TAG, 'stored identity unusable, minting a new one');
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'read identity failed: %{public}s', (error as Error).message);
      }
    }
    const fresh: StoredIdentity = MobileSession.mint();
    MobileSession.seed = fresh;
    // 造出来就落盘：否则每次冷启动都是一套新设备（正是要避免的事）。
    MobileSession.writeSeed(fresh);
    hilog.info(DOMAIN, TAG, 'minted a new device identity');
    return fresh;
  }

  /** 身份落盘的唯一入口（失败只记日志：身份拿不到不该让调用方崩）。 */
  private static writeSeed(value: StoredIdentity): void {
    const store: preferences.Preferences | null = MobileSession.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(STORE_KEY, JSON.stringify(value));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'persist identity failed: %{public}s', (error as Error).message);
    }
  }

  /** 一份全新的设备身份。 */
  private static mint(): StoredIdentity {
    const out: StoredIdentity = new StoredIdentity();
    out.phoneId = uuid4();
    out.uuid = uuid4();
    out.clientSessionId = uuid4();
    out.advertisingId = uuid4();
    out.androidDeviceId = androidDeviceId();
    out.requestId = uuid4();
    out.traySessionId = uuid4();
    out.mid = '';
    out.wwwClaim = '0';
    out.igURur = '';
    out.authorization = '';
    out.appVersion = DEFAULT_APP_VERSION;
    out.savedAt = Date.now();
    return out;
  }

  /** 落盘那份还能不能用（缺关键字段就作废，走 mint）。 */
  private static isUsable(seed: StoredIdentity): boolean {
    return `${seed.phoneId ?? ''}`.length > 0 && `${seed.uuid ?? ''}`.length > 0
      && `${seed.androidDeviceId ?? ''}`.length > 0
      && `${seed.clientSessionId ?? ''}`.length > 0;
  }

  /** 版本号查不到时的兜底档案（用默认那组，只是换掉版本号本身）。 */
  static appProfileOrDefault(appVersion: string): AppProfile {
    const fallback: AppProfile | undefined = APP_SETTINGS.get(DEFAULT_APP_VERSION);
    if (fallback === undefined) {
      return new AppProfile(DEFAULT_APP_VERSION, '', '');
    }
    if (appVersion.length === 0) {
      return fallback;
    }
    return new AppProfile(appVersion, fallback.versionCode, fallback.bloksVersioningId);
  }

  /** sessionid 的数字前缀（instagrapi 的 `re.search(r"^\d+", sessionid)`）。 */
  static userIdOfSession(sessionId: string): string {
    let end: number = 0;
    while (end < sessionId.length) {
      const code: number = sessionId.charCodeAt(end);
      if (code < 48 || code > 57) {
        break;
      }
      end++;
    }
    return sessionId.substring(0, end);
  }

  /** 从 Cookie 头字符串里取一个 cookie 的值。 */
  static cookieOf(cookie: string, name: string): string {
    const parts: Array<string> = cookie.split(';');
    for (let index: number = 0; index < parts.length; index++) {
      const pair: string = parts[index].trim();
      if (pair.startsWith(`${name}=`)) {
        return pair.substring(name.length + 1).trim();
      }
    }
    return '';
  }

  /** 从响应头对象里按名取一个值（大小写不敏感）。 */
  private static headerOf(headers: Record<string, string>, name: string): string {
    const needle: string = name.toLowerCase();
    const keys: Array<string> = Object.keys(headers);
    for (let index: number = 0; index < keys.length; index++) {
      if (keys[index].toLowerCase() === needle) {
        return `${headers[keys[index]] ?? ''}`.trim();
      }
    }
    return '';
  }

  /** 会话材料一行摘要（诊断用）。 */
  describe(): string {
    const identity: MobileIdentity | null = this.identity;
    return identity === null ? 'session=none' : identity.summary();
  }

  /** 主机名（给日志用；实际发请求时见 MobileRequest）。 */
  static host(): string {
    return API_DOMAIN;
  }
}
