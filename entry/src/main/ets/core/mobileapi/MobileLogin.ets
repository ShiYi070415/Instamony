/*
 * 原生密码登录 —— 逐条对齐 instagrapi 的 `login_legacy`（`mixins/auth.py`）。
 *
 * ## 为什么是 legacy 那条
 * instagrapi 现在默认走 **Bloks CAA 登录**（`bloks_caa_login`）—— 那是一条把界面编排
 * 编成 bytecode 的 RPC，本机没有 Bloks 运行时，照搬不现实。它的 `login_legacy` 才是
 * 经典三发：
 *   1. `launcher/sync/`（登录前预热，instagrapi 的 `pre_login_flow`）
 *   2. `accounts/login/`（`enc_password` = RSA+AES 加密封装，见 MobileCrypto）
 *   3. 需要时 `accounts/two_factor_login/`（2FA）
 * 而且 `login_legacy` 里那套"错误怎么读"（`two_factor_required` / `challenge_required` /
 * `bad_password`）正是我们要给界面看的东西，所以这条路的信息量最大。
 *
 * ## 会话怎么落地
 * 登录成功后 `ig-set-authorization` 头里就带着 `{ds_user_id, sessionid, …}`
 * （instagrapi 的 `parse_authorization`）。我们把它们**写进 Cookie 罐**
 * （`InstagramCookieJar.adoptSession`），于是 App 其余部分（MobileSession / 网页兜底）
 * 与"网页登录"那条路完全一致 —— 不需要第二套会话观。
 *
 * ## 不保存密码
 * 密码只在这一次请求里用，跑完就从内存丢掉；落盘的只有会话 cookie。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { ApiThrottle } from '../ApiThrottle';
import { InstagramCookieJar } from '../InstagramCookieJar';
import { MobileCrypto, PasswordKeys } from './MobileCrypto';
import { MobileIdentity, MobileSession } from './MobileSession';
import { MobileOptions, MobileRequest, MobileResult } from './MobileRequest';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileLogin';
/**
 * 登录那一发的 UA 版本号覆盖（**默认关**，空串 = 用 App 自己的版本）。
 *
 * 只用于诊断"`needs_upgrade` 是不是纯版本门槛"：填一个更高的版本号重试一次，
 * 看回包会不会从 needs_upgrade 变成别的东西（详见 login 里的说明）。
 * 生产环境必须保持空串 —— 版本号必须与 Bloks 版本、version_code 是一套（见 MobileConfig）。
 */
const LOGIN_UA_VERSION_OVERRIDE: string = '';

/** 登录走到了哪一步（界面据此切 UI）。 */
export enum LoginStage {
  /** 成功：会话已写进 Cookie 罐。 */
  Ok = 'ok',
  /** 需要 2FA 验证码。 */
  TwoFactor = 'twofactor',
  /** 需要安全验证（邮箱/短信验证码，或去 App/网页里点确认）。 */
  Challenge = 'challenge',
  /** 账号或密码不对。 */
  BadPassword = 'badpassword',
  /**
   * **IG 以"客户端版本过旧"拒绝密码登录**（`error_type: needs_upgrade`）。
   *
   * 这是账号层面无法绕过的一类：IG 只允许"当前官方版本"的客户端做密码登录，
   * 第三方客户端拿到的版本号（449 已经是 instagrapi 里最新的一档）永远追不上，
   * 而且新版本登录实际走的是 Bloks CAA 编排（本机没有 Bloks 运行时）。
   * 所以这一支不给"重试"，直接引导去网页登录。
   */
  NeedsUpgrade = 'upgrade',
  /** 其它失败（网络、限流、服务端拒收…），`message` 里有原因。 */
  Failed = 'failed'
}

/** 一次登录尝试的结果（不抛异常，与项目其它 core 模块同风格）。 */
export class LoginOutcome {
  readonly stage: LoginStage;
  /** 给用户看的一句话（中文）。 */
  readonly message: string;
  /** 2FA 的 `two_factor_identifier`（下一步要用）。 */
  readonly twoFactorIdentifier: string;
  /** 安全验证的 `api_path`（下一步要用；空 = 只能去网页处理）。 */
  readonly challengePath: string;
  /** 安全验证的类型（`verify_code` / `select_contact_point` / …）。 */
  readonly challengeType: string;
  /** 会话里的账号 id（成功时才有）。 */
  readonly userId: string;

  constructor(stage: LoginStage, message: string = '', twoFactorIdentifier: string = '',
              challengePath: string = '', challengeType: string = '', userId: string = '') {
    this.stage = stage;
    this.message = message;
    this.twoFactorIdentifier = twoFactorIdentifier;
    this.challengePath = challengePath;
    this.challengeType = challengeType;
    this.userId = userId;
  }

  isOk(): boolean {
    return this.stage === LoginStage.Ok;
  }
}

/** 登录成功时从响应里抠出来的会话材料。 */
class LoginSession {
  readonly authorization: string;
  readonly sessionId: string;
  readonly userId: string;
  readonly mid: string;
  readonly rur: string;

  constructor(authorization: string, sessionId: string, userId: string, mid: string, rur: string) {
    this.authorization = authorization;
    this.sessionId = sessionId;
    this.userId = userId;
    this.mid = mid;
    this.rur = rur;
  }

  usable(): boolean {
    return this.sessionId.length > 0 && this.userId.length > 0;
  }
}

export class MobileLogin {
  /** 上一次失败的原因（诊断用，界面提示里带上它）。 */
  private static lastDetail: string = '-';
  /**
   * 上一次登录卡在两步验证时的 `two_factor_identifier` 与用户名。
   *
   * 用途：界面第二次调用（带验证码）时**直接发 `accounts/two_factor_login/`**，
   * 不用先把同一份账号密码再打一遍 `accounts/login/`（那会白挨一次风控。
   * instagrapi 是同一个对象里接着发，我们这里没有对象，就把这两样记住）。
   */
  private static pendingTwoFactorId: string = '';
  private static pendingUsername: string = '';

  static detail(): string {
    return MobileLogin.lastDetail;
  }

  /**
   * 账号密码登录（instagrapi `login_legacy`）。
   *
   * @param username IG 用户名（不是显示名）
   * @param password 密码（只在本次请求里用，不落盘）
   * @param verificationCode 有 2FA 时带验证码（第一次可以先传空串）
   */
  static async login(username: string, password: string,
                     verificationCode: string = ''): Promise<LoginOutcome> {
    const user: string = username.trim();
    if (user.length === 0 || password.length === 0) {
      return new LoginOutcome(LoginStage.Failed, '请输入账号和密码');
    }
    const identity: MobileIdentity = MobileSession.seedIdentity();
    /*
     * 带验证码的第二次调用：上一次卡在两步验证的话**直接发 two_factor_login/**，
     * 不重复打 `accounts/login/`（见 pendingTwoFactorId 的说明）。
     */
    if (verificationCode.trim().length > 0 && MobileLogin.pendingTwoFactorId.length > 0
      && MobileLogin.pendingUsername === user) {
      return await MobileLogin.twoFactor(identity, user, verificationCode.trim(),
        MobileLogin.pendingTwoFactorId);
    }
    /*
     * 1) 登录前预热：`launcher/sync/`（instagrapi `pre_login_flow`）。
     *
     * 拿不到就继续 —— instagrapi 也只对 429 做"忽略并继续"，其余异常才中断。
     */
    await MobileLogin.syncLauncher(identity);
    // 2) 取密码公钥（`qe/sync/` 的两个响应头）。
    const keys: PasswordKeys | null = await MobileLogin.publicKeys(identity);
    let encPassword: string = '';
    if (keys !== null && keys.isUsable()) {
      encPassword = await MobileCrypto.encryptPassword(password, keys);
    }
    if (encPassword.length === 0) {
      /*
       * 加密不可用时**不退回明文**：明文密码在 IG 那边会被当成"老客户端"直接拒
       * （`bad_password` / `needs_upgrade`），而且把密码裸发出去也不合适。
       */
      hilog.warn(DOMAIN, TAG, 'password encryption unavailable');
      return new LoginOutcome(LoginStage.Failed, '密码加密不可用（拿不到 IG 的公钥），请用网页登录');
    }
    // 3) `accounts/login/`（字段照 instagrapi 那条 data 逐条对齐）。
    const data: Record<string, string> = {};
    data['jazoest'] = MobileLogin.jazoest(identity.phoneId);
    data['country_codes'] = '[{"country_code":"1","source":["default"]}]';
    data['phone_id'] = identity.phoneId;
    data['enc_password'] = encPassword;
    data['username'] = user;
    data['adid'] = identity.advertisingId;
    data['guid'] = identity.uuid;
    data['device_id'] = identity.androidDeviceId;
    data['google_tokens'] = '[]';
    data['login_attempt_count'] = '0';
    if (verificationCode.trim().length > 0) {
      // 2FA 那次走的是两段式（见下），这里只在"带码重试登录"时补上，和 instagrapi 一致。
      data['two_factor_verification_code'] = verificationCode.trim();
    }
    /*
     * 登录这一发额外带 `X-IG-Nav-Chain`：本项目在"身份自洽"模式里**全局不发**这个头
     * （见 MobileRequest.baseHeaders 的说明），但 instagrapi 的登录请求是带的
     * （`base_headers` 里那条固定串）。登录是这个端点族里唯一"还没有会话"的请求，
     * 缺头和缺会话叠在一起更容易被当成异常客户端，所以按 instagrapi 补回来。
     */
    const loginHeaders: Record<string, string> = {};
    loginHeaders['X-IG-Nav-Chain'] =
      '9MV:self_profile:2,ProfileMediaTabFragment:self_profile:3,9Xf:self_following:4';
    /*
     * **版本号实验开关**（默认关）：只把这一发的 User-Agent 里的版本号换成别的值。
     *
     * 为什么要这个：IG 对 legacy 密码登录回 `needs_upgrade`（"客户端太旧"）。
     * 如果那个判断纯粹看 UA 里的版本号，换一个更高的版本号就能看到回包变化
     * （比如变成 `bad_password`）—— 那就说明"只是版本门槛"，值得继续想办法；
     * 如果仍然是 needs_upgrade，说明版本号是和 Bloks 编排绑定的，换号无用。
     * 只影响登录这一发，不动其它请求的指纹（其余请求必须是同一套版本，见 MobileConfig）。
     */
    if (LOGIN_UA_VERSION_OVERRIDE.length > 0) {
      const base: string = identity.userAgent();
      loginHeaders['User-Agent'] = base.replace(`Instagram ${identity.app.appVersion}`,
        `Instagram ${LOGIN_UA_VERSION_OVERRIDE}`);
      hilog.warn(DOMAIN, TAG, 'login UA override → %{public}s', LOGIN_UA_VERSION_OVERRIDE);
    }
    /*
     * **明文表单先发，签名体兜底**。
     *
     * 真机实测（同一套身份、同一个账号，只有请求体不同）：
     *   · 签名体（`signed_body=SIGNATURE.{…}`）→ `400 {"message":"","status":"fail"}`（30 字节，什么都没说）；
     *   · 明文表单 → `400 {"message":"你的 Instagram 不是最新版本。请升级应用以登录 Instagram。", …}`
     *     （98 字节，IG 真的解析了并给出带类型的错误）。
     * 也就是说这个端点**只认明文表单**，签名体在协议层就被丢了 —— 先用明文那条，
     * 只有它也"静默 400"时才退回签名体。
     */
    const plain: MobileResult = await MobileRequest.sendAs(identity, 'accounts/login/',
      MobileRequest.formOf(data), '', false, loginHeaders,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.urgent()));
    hilog.info(DOMAIN, TAG, 'login resp (unsigned) %{public}s', plain.summary());
    if (plain.ok) {
      return await MobileLogin.finish(plain, identity, user);
    }
    if (MobileLogin.isSilent400(plain)) {
      const signed: MobileResult = await MobileRequest.sendAs(identity, 'accounts/login/',
        MobileRequest.formOf(data), '', true, loginHeaders,
        new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.urgent()));
      hilog.info(DOMAIN, TAG, 'login retry signed %{public}s', signed.summary());
      if (signed.ok) {
        return await MobileLogin.finish(signed, identity, user);
      }
      return MobileLogin.classifyFailure(signed, user);
    }
    return MobileLogin.classifyFailure(plain, user);
  }

  /** `400` + `{"message":"","status":"fail"}` —— 协议层被丢的那种回包（见 login 里的说明）。 */
  private static isSilent400(result: MobileResult): boolean {
    if (result.code !== 400) {
      return false;
    }
    const message: string = MobileLogin.fieldOf(result.body, 'message');
    const status: string = MobileLogin.fieldOf(result.body, 'status');
    return message.length === 0 && status === 'fail';
  }

  /**
   * 是不是"客户端版本过旧"（IG 的 `needs_upgrade`）。
   *
   * 判据要宽一点：真机上见到的形状是
   * `{"message":"Your Instagram app is out of date. Please upgrade to log in.",
   *   "status":"fail","error_type":"needs_upgrade"}`，
   * 但不同地区/版本里 `error_type` 可能缺、message 也可能只有 "Please upgrade" 一句。
   */
  private static isNeedsUpgrade(result: MobileResult): boolean {
    const errorType: string = MobileLogin.fieldOf(result.body, 'error_type').toLowerCase();
    if (errorType === 'needs_upgrade') {
      return true;
    }
    const text: string = `${result.body} ${result.detail}`.toLowerCase();
    if (text.indexOf('needs_upgrade') >= 0) {
      return true;
    }
    return text.indexOf('out of date') >= 0 || text.indexOf('please upgrade') >= 0;
  }

  /**
   * 回包里的 `two_factor_identifier`（**顶层或嵌套**都认）。
   *
   * 为什么要单独一个：IG 把它放在 `two_factor_info.two_factor_identifier` 里，
   * 而 `fieldOf` 只看顶层 —— 于是"需要 2FA"的回包被当成"登录失败"（真机 bug）。
   */
  private static twoFactorIdOf(body: string): string {
    const direct: string = MobileLogin.fieldOf(body, 'two_factor_identifier');
    if (direct.length > 0) {
      return direct;
    }
    const info: string = MobileLogin.fieldOf(body, 'two_factor_info');
    if (info.length > 0) {
      const nested: string = MobileLogin.fieldOf(info, 'two_factor_identifier');
      if (nested.length > 0) {
        return nested;
      }
    }
    const challenge: string = MobileLogin.fieldOf(body, 'challenge');
    if (challenge.length > 0) {
      return MobileLogin.fieldOf(challenge, 'two_factor_identifier');
    }
    return '';
  }

  /** 回包有没有说"要两步验证"（`two_factor_required: true` / `"1"`）。 */
  private static twoFactorRequired(body: string): boolean {
    const text: string = body.toLowerCase();
    return text.indexOf('"two_factor_required":true') >= 0
      || text.indexOf('"two_factor_required":"1"') >= 0
      || text.indexOf('"two_factor_required":1') >= 0;
  }

  /** 失败分类：2FA / 安全验证 / 版本过旧 / 密码错 / 限流 / 其它（见 login 的调用点）。 */  private static async classifyFailure(result: MobileResult, user: string): Promise<LoginOutcome> {
    /*
     * 先判"版本过旧"：IG 回的是
     * `{"message":"Your Instagram app is out of date. Please upgrade to log in.","status":"fail",
     *   "error_type":"needs_upgrade"}`（真机实测里界面显示的就是这句被翻译过的提示）。
     * 这一支**重试没有意义**：账号没错、密码也没错，是客户端版本被政策挡住了。
     */
    if (MobileLogin.isNeedsUpgrade(result)) {
      hilog.warn(DOMAIN, TAG, 'login blocked by client version: needs_upgrade');
      return new LoginOutcome(LoginStage.NeedsUpgrade,
        'IG 提示客户端版本过旧，已关闭第三方客户端的密码登录；请用网页登录（网页登录不受影响）');
    }
    // 4) 失败分支：先看是不是 2FA / 安全验证，再落到"账号密码不对"。
    const twoFactorId: string = MobileLogin.twoFactorIdOf(result.body);
    if (result.error === 'two_factor' || twoFactorId.length > 0) {
      // 记住 id：界面第二次调用（带验证码）时直接从 two_factor_login/ 接着走。
      MobileLogin.pendingTwoFactorId = twoFactorId;
      MobileLogin.pendingUsername = user;
      return new LoginOutcome(LoginStage.TwoFactor, '需要两步验证码', twoFactorId, '', '', '');
    }
    if (result.error === 'challenge_required') {
      const path: string = MobileLogin.fieldOf(result.body, 'api_path');
      const type: string = MobileLogin.fieldOf(result.body, 'challenge_type');
      return new LoginOutcome(LoginStage.Challenge,
        type.length > 0 ? `需要安全验证（${type}）` : '需要安全验证',
        '', path, type, '');
    }
    if (result.error === 'bad_password' || result.detail === 'bad_password'
      || result.detail.indexOf('bad_password') >= 0) {
      return new LoginOutcome(LoginStage.BadPassword, '账号或密码不正确');
    }
    if (result.error === 'rate_limit' || result.error === 'throttled') {
      return new LoginOutcome(LoginStage.Failed, '被 IG 限流了，过几分钟再试');
    }
    if (MobileLogin.isSilent400(result)) {
      /*
       * 两种体都被这个 400 拒了：说明不是"密码错"，而是这套客户端版本 / 参数不被这套后端接受。
       * 如实说清楚 + 给网页登录兜底（别让用户以为密码打错了）。
       */
      return new LoginOutcome(LoginStage.Failed,
        'IG 拒收了这次登录请求（未给原因，通常是客户端版本过旧或该账号被要求走验证），请用网页登录');
    }
    MobileLogin.lastDetail = result.detail.length > 0 ? result.detail : result.error;
    return new LoginOutcome(LoginStage.Failed, `登录失败：${MobileLogin.lastDetail}`);
  }

  /**
   * **用 sessionid 登录**（instagrapi 的 `login_by_sessionid`）—— 密码登录被政策挡住时的原生替代。
   *
   * ## 为什么需要这一条
   * instagrapi 官方文档（Login Migration）写得很清楚：
   *   · 3.x 的 `login()` 直接走 **CAA（Bloks 编排）**；`login_legacy()` 是旧的 accounts 端点；
   *   · "An explicit legacy login **may invoke its CAA fallback**, including when the accounts
   *     endpoint returns `needs_upgrade`" —— 也就是说**密码登录离开 CAA 就走不完**；
   *   · 推荐的迁移方式是 **Reuse saved sessions**（保存/复用会话）。
   * 本机没有 Bloks 运行时，所以照文档走"复用会话"这一支：用户从浏览器（或别的客户端）
   * 拿一条 `sessionid` 贴进来，我们按 `login_by_sessionid` 的做法验证并接管。
   *
   * ## 做法（与 instagrapi 一一对应）
   *   1. sessionid 的数字前缀就是 user id（`userIdOfSession`）；
   *   2. 先用它发一发只读请求（`users/{id}/info/`）验证这个会话还有效 —— 验过再写罐；
   *   3. 写进 Cookie 罐（`InstagramCookieJar.adoptSession`）+ `MobileSession.adoptLogin`
   *      （Authorization 由 `MobileIdentity.buildAuthorization` 现生成）。
   */
  static async loginBySessionId(rawSessionId: string): Promise<LoginOutcome> {
    const sessionId: string = rawSessionId.trim();
    if (sessionId.length < 30) {
      return new LoginOutcome(LoginStage.Failed,
        'sessionid 看起来不完整（一般是 30 位以上，以数字账号 id 开头）');
    }
    const userId: string = MobileSession.userIdOfSession(sessionId);
    if (userId.length === 0) {
      return new LoginOutcome(LoginStage.Failed, 'sessionid 应该以数字账号 id 开头，请检查是否复制完整');
    }
    const identity: MobileIdentity = MobileSession.identityForSession(sessionId, userId);
    // 只读验证：拿自己的资料（instagrapi `login_by_sessionid` 也是先 `user_info_v1`）。
    const check: MobileResult = await MobileRequest.sendAs(identity, `users/${userId}/info/`,
      '', '', false, null, new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.urgent()));
    hilog.info(DOMAIN, TAG, 'sessionid check %{public}s', check.summary());
    if (!check.ok) {
      MobileLogin.lastDetail = check.detail.length > 0 ? check.detail : check.error;
      return new LoginOutcome(LoginStage.Failed,
        `这个 sessionid 已失效或不被接受（${MobileLogin.lastDetail}）`);
    }
    // 验证通过：写罐 + 登记身份（顺序很重要 —— 罐是唯一会话来源，见 adoptSession 的说明）。
    const wrote: boolean = await InstagramCookieJar.adoptSession(sessionId, userId, identity.csrf);
    if (!wrote) {
      return new LoginOutcome(LoginStage.Failed, '会话写入失败，请重试');
    }
    const mid: string = MobileLogin.headerOf(check.headers, 'ig-set-x-mid');
    const rur: string = MobileLogin.headerOf(check.headers, 'ig-set-ig-u-rur');
    await MobileSession.getInstance().adoptLogin(identity.authorization, sessionId, userId, mid, rur);
    MobileSession.getInstance().absorbResponseHeaders(check.headers);
    hilog.info(DOMAIN, TAG, 'login by sessionid ok user=%{public}d sid=%{public}d',
      userId.length, sessionId.length);
    return new LoginOutcome(LoginStage.Ok, '', '', '', '', userId);
  }

  /**
   * 提交两步验证码（instagrapi `accounts/two_factor_login/`）。
   */
  private static async twoFactor(identity: MobileIdentity, username: string, code: string,
                                 twoFactorIdentifier: string): Promise<LoginOutcome> {
    if (code.length === 0) {
      return new LoginOutcome(LoginStage.TwoFactor, '请输入两步验证码', twoFactorIdentifier);
    }
    const data: Record<string, string> = {};
    data['verification_code'] = code;
    data['phone_id'] = identity.phoneId;
    data['_csrftoken'] = identity.csrf;
    data['two_factor_identifier'] = twoFactorIdentifier;
    data['username'] = username;
    data['trust_this_device'] = '0';
    data['guid'] = identity.uuid;
    data['device_id'] = identity.androidDeviceId;
    data['waterfall_id'] = `${identity.uuid}`;
    data['verification_method'] = '3';
    const result: MobileResult = await MobileRequest.sendAs(identity, 'accounts/two_factor_login/',
      MobileRequest.formOf(data), '', true, null,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.urgent()));
    hilog.info(DOMAIN, TAG, '2fa resp %{public}s', result.summary());
    if (result.ok) {
      return await MobileLogin.finish(result, identity, twoFactorIdentifier);
    }
    MobileLogin.lastDetail = result.detail.length > 0 ? result.detail : result.error;
    return new LoginOutcome(LoginStage.TwoFactor, `验证码不对或已过期（${MobileLogin.lastDetail}）`,
      twoFactorIdentifier);
  }

  /**
   * 安全验证：提交验证码（instagrapi `challenge/{api_path}/`）。
   *
   * 只做**验证码**这一类（邮箱/短信发到注册联系方式那种）。`select_contact_point`
   * 之类需要多点几步的，界面上会引导去网页完成 —— 不假装能做。
   *
   * @param apiPath 登录响应里 `challenge.api_path`（形如 `challenge/1234567/AbC…/`）
   * @param code    收到的 6 位验证码
   */
  static async challengeVerify(apiPath: string, code: string): Promise<LoginOutcome> {
    const path: string = apiPath.trim();
    if (path.length === 0) {
      return new LoginOutcome(LoginStage.Challenge, '这次验证只能在网页里完成');
    }
    if (code.trim().length === 0) {
      return new LoginOutcome(LoginStage.Challenge, '请输入收到的验证码', '', path);
    }
    const identity: MobileIdentity = MobileSession.seedIdentity();
    const data: Record<string, string> = {};
    data['security_code'] = code.trim();
    data['_csrftoken'] = identity.csrf;
    const result: MobileResult = await MobileRequest.sendAs(identity, path,
      MobileRequest.formOf(data), '', false, null,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.urgent()));
    hilog.info(DOMAIN, TAG, 'challenge verify %{public}s', result.summary());
    if (result.ok) {
      return new LoginOutcome(LoginStage.Challenge, '验证通过，请重新点一次登录', '', path);
    }
    MobileLogin.lastDetail = result.detail.length > 0 ? result.detail : result.error;
    return new LoginOutcome(LoginStage.Challenge,
      `验证没通过（${MobileLogin.lastDetail}）`, '', path);
  }

  /**
   * 收尾：从响应里抠会话材料 → 写进 Cookie 罐 → adopt 进 MobileSession。
   *
   * 会话材料有两条来源，按顺序用：
   *   ① `ig-set-authorization`（`Bearer IGT:2:<base64 JSON{ds_user_id, sessionid}>`）——
   *      instagrapi 就是解析它；
   *   ② `set-cookie` 里的 `sessionid` / `ds_user_id`（有些回包只给 cookie）。
   */
  private static async finish(result: MobileResult, identity: MobileIdentity,
                              user: string): Promise<LoginOutcome> {
    /*
     * **先看"是不是卡在两步验证"**（真机 bug：登录不跳 2FA）。
     *
     * IG 对"密码对了但要 2FA"的回包是 **HTTP 200**，形状有两种：
     *   `{"two_factor_required":true,"two_factor_info":{"two_factor_identifier":"…"}}`
     *   `{"message":"challenge_required","challenge":{"…two_factor_identifier…"}}`
     * 而 `classifyFailure` 只在**非 200** 时才跑，所以这一支以前直接走到下面
     * "登录成功但没拿到会话"（界面上看着就是"登录失败"），**永远进不了验证码面板**。
     * 现在在收尾处先认它：把 id 记下来，返回 TwoFactor —— 面板里输码就能过。
     */
    const tfId: string = MobileLogin.twoFactorIdOf(result.body);
    if (tfId.length > 0 || MobileLogin.twoFactorRequired(result.body)) {
      MobileLogin.pendingTwoFactorId = tfId;
      MobileLogin.pendingUsername = user;
      hilog.warn(DOMAIN, TAG, 'login 200 but needs 2FA (id=%{public}d) → panel',
        tfId.length);
      return new LoginOutcome(LoginStage.TwoFactor, '需要两步验证码', tfId, '', '', '');
    }
    const session: LoginSession = MobileLogin.sessionOf(result);
    if (!session.usable()) {
      hilog.warn(DOMAIN, TAG, 'login ok but no session material: keys=%{public}s',
        result.headers === undefined ? '-' : Object.keys(result.headers).join(','));
      MobileLogin.lastDetail = 'no-session-material';
      return new LoginOutcome(LoginStage.Failed, '登录成功但没拿到会话，请用网页登录');
    }
    const csrf: string = identity.csrf.length > 0 ? identity.csrf : MobileLogin.genToken(64);
    const wrote: boolean = await InstagramCookieJar.adoptSession(session.sessionId,
      session.userId, csrf);
    if (!wrote) {
      return new LoginOutcome(LoginStage.Failed, '会话写入失败，请重试或用网页登录');
    }
    await MobileSession.getInstance().adoptLogin(session.authorization, session.sessionId,
      session.userId, session.mid, session.rur);
    // 登录响应里也可能带着 claim / mid / rur：捡起来（和平时那条链一致）。
    MobileSession.getInstance().absorbResponseHeaders(result.headers);
    // 登录成功：忘掉两步验证的中间状态（下次是新的登录）。
    MobileLogin.pendingTwoFactorId = '';
    MobileLogin.pendingUsername = '';
    hilog.info(DOMAIN, TAG, 'login finished user=%{public}d sid=%{public}d',
      session.userId.length, session.sessionId.length);
    return new LoginOutcome(LoginStage.Ok, '', '', '', '', session.userId);
  }

  /** 从响应头里抠会话材料（见 finish 的两条来源）。 */
  private static sessionOf(result: MobileResult): LoginSession {
    const headers: Record<string, string> = result.headers === undefined ? {} : result.headers;
    const authorization: string = MobileLogin.headerOf(headers, 'ig-set-authorization');
    let sessionId: string = '';
    let userId: string = '';
    if (authorization.length > 0) {
      const decoded: string = MobileLogin.decodeAuthorization(authorization);
      sessionId = MobileLogin.fieldOf(decoded, 'sessionid');
      userId = MobileLogin.fieldOf(decoded, 'ds_user_id');
    }
    if (sessionId.length === 0) {
      sessionId = MobileLogin.cookieOf(headers, 'sessionid');
    }
    if (userId.length === 0) {
      userId = MobileLogin.cookieOf(headers, 'ds_user_id');
    }
    // 兜底：sessionid 的数字前缀就是 user id（instagrapi `login_by_sessionid` 那一条）。
    if (userId.length === 0 && sessionId.length > 0) {
      let digits: string = '';
      for (let index: number = 0; index < sessionId.length; index++) {
        const ch: string = sessionId.charAt(index);
        if (ch < '0' || ch > '9') {
          break;
        }
        digits += ch;
      }
      userId = digits;
    }
    return new LoginSession(authorization, sessionId, userId,
      MobileLogin.headerOf(headers, 'ig-set-x-mid'), MobileLogin.headerOf(headers, 'ig-set-ig-u-rur'));
  }

  /**
   * 取密码公钥：`qe/sync/` 的响应头（instagrapi `password_publickeys`）。
   *
   * ⚠️ 三个真机/线上实测出来的坑（照 instagrapi 那个 `self.public.get(...)` 搬会全踩）：
   *   1. **必须 POST**：`GET /api/v1/qe/sync/` 直接回 **405 Method Not Allowed**（响应体为空，
   *      我们的分类器会报 `non-json http=405`）；
   *   2. **必须带 `id` + `server_config_retrieval`**：只发一个 `id=1234` 会 400；
   *   3. **不能签名**（`withSignature=false`）：这个端点在"还没有会话"时用明文表单就能通，
   *      包成 `signed_body=` 反而被拒。
   */
  private static async publicKeys(identity: MobileIdentity): Promise<PasswordKeys | null> {
    const data: Record<string, string> = {};
    data['id'] = identity.uuid;
    data['server_config_retrieval'] = '1';
    const result: MobileResult = await MobileRequest.sendAs(identity, 'qe/sync/',
      MobileRequest.formOf(data), '', false, null,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.urgent()));
    if (!result.ok) {
      MobileLogin.lastDetail = result.detail.length > 0 ? result.detail : result.error;
      hilog.warn(DOMAIN, TAG, 'qe/sync for keys failed: %{public}s', MobileLogin.lastDetail);
      return null;
    }
    const idText: string = MobileLogin.headerOf(result.headers, 'ig-set-password-encryption-key-id');
    const publicKey: string = MobileLogin.headerOf(result.headers, 'ig-set-password-encryption-pub-key');
    const keyId: number = Number.parseInt(idText, 10);
    if (!Number.isFinite(keyId) || keyId <= 0 || publicKey.length === 0) {
      hilog.warn(DOMAIN, TAG, 'no password keys in headers: keys=%{public}s',
        Object.keys(result.headers).join(','));
      return null;
    }
    hilog.info(DOMAIN, TAG, 'password keys keyId=%{public}d len=%{public}d', keyId, publicKey.length);
    return new PasswordKeys(keyId, publicKey);
  }

  /**
   * 登录前预热：`launcher/sync/`（instagrapi `pre_login_flow`）。失败只记日志。
   *
   * 同样**必须不签名**：包成 `signed_body=` 时 IG 回 `400 No valid ID given`
   * （它只认明文表单里的 `id`），这一点是模拟器上实测出来的。
   */
  private static async syncLauncher(identity: MobileIdentity): Promise<void> {
    const data: Record<string, string> = {};
    data['id'] = identity.uuid;
    data['server_config_retrieval'] = '1';
    const result: MobileResult = await MobileRequest.sendAs(identity, 'launcher/sync/',
      MobileRequest.formOf(data), '', false, null,
      new MobileOptions(ApiThrottle.DIRECT, ApiThrottle.warm()));
    hilog.info(DOMAIN, TAG, 'launcher/sync %{public}s', result.summary());
  }

  // ------------------------------------------------------------------ 小工具

  /** instagrapi `generate_jazoest`：`"2" + sum(ord(c))`。 */
  private static jazoest(symbols: string): string {
    let sum: number = 0;
    for (let index: number = 0; index < symbols.length; index++) {
      sum += symbols.charCodeAt(index);
    }
    return `2${sum}`;
  }

  /** `Bearer IGT:2:<base64>` 里的 JSON 部分（instagrapi `parse_authorization`）。 */
  private static decodeAuthorization(authorization: string): string {
    const cut: number = authorization.lastIndexOf(':');
    if (cut < 0 || cut + 1 >= authorization.length) {
      return '';
    }
    const b64: string = authorization.substring(cut + 1);
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(b64);
      return new util.TextDecoder().decodeToString(bytes);
    } catch (error) {
      return '';
    }
  }

  /** 响应头取值（键统一小写比较）。 */
  private static headerOf(headers: Record<string, string>, name: string): string {
    if (headers === undefined) {
      return '';
    }
    const keys: Array<string> = Object.keys(headers);
    for (let index: number = 0; index < keys.length; index++) {
      if (keys[index].toLowerCase() === name) {
        return `${headers[keys[index]]}`.trim();
      }
    }
    return '';
  }

  /** `set-cookie` 里某个 cookie 的值。 */
  private static cookieOf(headers: Record<string, string>, name: string): string {
    const raw: string = MobileLogin.headerOf(headers, 'set-cookie');
    if (raw.length === 0) {
      return '';
    }
    const parts: Array<string> = raw.split(/,(?=[^;]*=)/);
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index].trim();
      if (!one.startsWith(`${name}=`)) {
        continue;
      }
      const end: number = one.indexOf(';');
      const pair: string = end >= 0 ? one.substring(0, end) : one;
      return pair.substring(name.length + 1).trim();
    }
    return '';
  }

  /** JSON 文本里取一个深层字段（登录响应结构不固定，够用就行）。 */
  private static fieldOf(text: string, key: string): string {
    if (text.length === 0) {
      return '';
    }
    const needle: string = `"${key}"`;
    const at: number = text.indexOf(needle);
    if (at < 0) {
      return '';
    }
    let cursor: number = text.indexOf(':', at + needle.length);
    if (cursor < 0) {
      return '';
    }
    cursor++;
    while (cursor < text.length && (text.charAt(cursor) === ' ' || text.charAt(cursor) === '\n'
      || text.charAt(cursor) === '\r' || text.charAt(cursor) === '\t')) {
      cursor++;
    }
    if (cursor >= text.length) {
      return '';
    }
    const first: string = text.charAt(cursor);
    if (first === '"') {
      const close: number = text.indexOf('"', cursor + 1);
      return close > cursor ? text.substring(cursor + 1, close) : '';
    }
    let end: number = cursor;
    while (end < text.length) {
      const ch: string = text.charAt(end);
      if (ch === ',' || ch === '}' || ch === ']' || ch === ' ' || ch === '\n') {
        break;
      }
      end++;
    }
    return text.substring(cursor, end).trim();
  }

  /** 随机 token（instagrapi `gen_token`）。 */
  private static genToken(size: number): string {
    const chars: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let out: string = '';
    for (let index: number = 0; index < size; index++) {
      out += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return out;
  }
}
