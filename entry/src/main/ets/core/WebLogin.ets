/*
 * **无头网页登录**：原生输入账号密码 → 丢进隐藏网页（IG 官方登录页）→ 登录成功进首页，
 * 全程不把网页显示给用户。
 *
 * ## 为什么是这条路
 * IG 已经把第三方客户端的"原生密码登录"收口到 CAA（Bloks 编排）——
 * 我们的 `accounts/login/` 实测固定拿到 `needs_upgrade`（见 core/mobileapi/MobileLogin 的说明）。
 * 而 IG **自己的网页**里就是用账号密码登录的，那一套走的是官方流程，永远不会被版本政策挡。
 * 所以"原生输入 + 隐藏网页完成登录"是唯一既不用写 CAA、又让用户只面对本 App 的做法。
 *
 * ## 它是怎么做的（全部在隐藏网页里）
 *   1. `loadUrl` 到 `https://www.instagram.com/accounts/login/`；
 *   2. 轮询页面里有没有 `input[name="username"]`（React 页面是异步渲染的）；
 *   3. 用原生 setter 写值并派发 `input`/`change`（React 只认这两种事件），再点提交按钮；
 *   4. 每秒看一次 Cookie 罐：出现 `sessionid` + `ds_user_id` 就算成功
 *      （会话判定在全 app 只有这一处，见 core/InstagramCookieJar）；
 *   5. 期间把页面上的错误文案（密码不对 / 需要验证 / 两步验证）读回来，界面照实显示。
 *
 * ## 边界
 *   2FA / challenge 这类需要人参与的步骤：**不假装能做**。检测到就回报"需要在网页里完成验证"，
 *   界面给出「网页登录」按钮（那时才把网页亮出来，用户点几下就完事）。
 *
 * 宿主必须是 `Visibility.Hidden` 状态（见 InstagramWebHost）：JS / 定时器 / 网络照常，
 * 只是不出帧 —— 于是用户看不到网页，也不知道发生了什么。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramCookieSnapshot, InstagramCookieJar } from './InstagramCookieJar';
import { InstagramPageBridge } from '../bridge/PageBridge';

const DOMAIN: number = 0xFF00;
const TAG: string = 'WebLogin';

/** 网页登录页（和 pages/Index 的 openLoginWeb 用同一条地址）。 */
const LOGIN_URL: string = 'https://www.instagram.com/accounts/login/';
/** 等登录表单出现的最长时间（毫秒）。弱网下 IG 首屏要几秒，给宽一点。 */
const FORM_WAIT_MS: number = 20000;
/** 提交之后等会话落地的最长时间（毫秒）。 */
const SESSION_WAIT_MS: number = 45000;
/** 轮询间隔（毫秒）。 */
const POLL_MS: number = 700;
/**
 * 撞上 429 之后的冷却（毫秒）。
 *
 * IG 的登录限流通常按"分钟~小时"计；这里取 10 分钟：足够让窗口滑过去，
 * 又不至于让用户觉得"这功能废了"。冷却期内**一次请求都不发**（见 loginByWebAjax）。
 */
const LOGIN_THROTTLE_COOLDOWN_MS: number = 10 * 60000;
/**
 * "网页已经打开、等用户在网页里点一下登录"这个中间状态（`pages/Index` 用它区分"成功"）。
 *
 * 空串表示**登录成功**；这个标记表示"还在等" —— 两者混用会让登录页误以为已经登好。
 */
export const WEB_LOGIN_OPENED: string = '__web_login_opened__';

/**
 * 探测登录页现在长什么样（诊断 + 决策都靠它）。
 *
 * 返回的 `u` / `p` 分别是"有用户名框" / "有密码框" —— **两者不一定同时出现**：
 * IG 的移动网页版常常是两步（先用户名 → 下一步 → 密码），把"两个都在"当成就绪条件
 * 就会一直等到超时（用户遇到的"加载失败"有一半是这个原因）。
 */
const FORM_PROBE_JS: string =
  '(function(){try{'
  + 'var u=document.querySelector(\'input[name="username"]\')||document.querySelector(\'#username\');'
  + 'var p=document.querySelector(\'input[name="password"]\')||document.querySelector(\'#password\');'
  + 'var inputs=document.querySelectorAll("input").length;'
  // 顺便把"登录按钮候选"找出来（tag/class/尺寸），以及视口尺寸 —— 这两样决定了点不点得动。
  + 'var cand="";'
  + 'try{var els=document.querySelectorAll(\'div,span,a,button,[role="button"],input[type="submit"]\');'
  + 'for(var i=0;i<els.length&&cand.split("|").length<4;i++){var el=els[i];'
  + 'var tx=(el.innerText||el.value||"").trim();if(!tx||tx.length>8){continue;}'
  + 'if(!/登录|登入|log\\s*in/i.test(tx)){continue;}'
  + 'var r=el.getBoundingClientRect();'
  + 'cand=cand+el.tagName+"."+String(el.className||"").slice(0,14)+"@"+Math.round(r.width)+"x"+Math.round(r.height)+"|";}}catch(e){}'
  + 'return JSON.stringify({r:document.readyState,h:location.href.slice(0,140),'
  + 't:(document.title||"").slice(0,40),u:u?1:0,p:p?1:0,n:inputs,'
  + 'w:(window.innerWidth||0),hh:(window.innerHeight||0),btn:cand,'
  + 'len:(document.body?document.body.innerText.length:0)});'
  + '}catch(e){return JSON.stringify({r:"err",m:String(e).slice(0,80)});}})()';

/**
 * 一次探测的结果。
 *
 * `usable()` = 页面上至少有一个可填的输入框（用户名或密码），也就是"登录页真的到了"。
 */
class PageState {
  readonly raw: string;
  readonly hasUser: boolean;
  readonly hasPassword: boolean;
  readonly ready: string;

  constructor(raw: string, hasUser: boolean, hasPassword: boolean, ready: string) {
    this.raw = raw;
    this.hasUser = hasUser;
    this.hasPassword = hasPassword;
    this.ready = ready;
  }

  usable(): boolean {
    return this.hasUser || this.hasPassword;
  }
}

/** 页面上一眼能看出来的错误/验证线索（顺序即优先级）。 */
class PageSignal {
  readonly key: string;
  readonly text: string;
  readonly needle: string;

  constructor(key: string, text: string, needle: string) {
    this.key = key;
    this.text = text;
    this.needle = needle;
  }
}

export class WebLogin {
  /**
   * **单飞闸门**：登录相关动作同一时刻只允许一个在跑。
   *
   * 为什么必须有：`login` / `prefill` / `loginByWebAjax` 三个入口会被界面重复触发
   * （反复点按钮、重试定时器），每个都会导航/发请求 —— 页面于是被反复 reload，
   * 用户看到的就是"网页不停抽搐"。有这一道，后来者直接返回"正在登录中"。
   */
  private static busy: boolean = false;
  /** 429 冷却截止时刻（见 LOGIN_THROTTLE_COOLDOWN_MS）。 */
  private static throttleUntilMs: number = 0;
  /** 兼容旧代码里的名字（`login()` 内部重入判断）。 */
  private static running: boolean = false;
  /**
   * 最近一次表单探测的结果（诊断用）。
   *
   * 为什么把它带进**界面文案**：无头登录失败时用户看到的只有一句"加载不出来"，
   * 而"到底卡在哪"（页面没起来 / 重定向了 / JS 没执行）全在探测结果里。
   * 把最关键的三四个字段附在错误后面，用户截个图就能定位 —— 比让他捞 hilog 现实得多。
   */
  private static lastProbe: string = '';

  /**
   * **只填不点**：把账号密码填进隐藏网页的登录表单，返回空串表示填好了。
   *
   * 为什么只填不点：实测（模拟器 + 日志）IG 现在的登录页是 **Bloks 渲染**，
   * 那颗"登录"是 `div.wbloks_1`，对我们派发的 pointer/touch/mouse/click **全都不响应**
   * （`clicked:1` 但页面文字一动不动 —— 合成事件被这类渲染层按 isTrusted 丢掉）。
   * 所以最后一步只能由真人点一下；能自动化的是"打开登录页 + 填好账号密码"。
   */
  static async prefill(username: string, password: string): Promise<string> {
    const user: string = username.trim();
    if (user.length === 0 || password.length === 0) {
      return '请输入账号和密码';
    }
    if (WebLogin.busy) {
      return '正在登录中，请稍候';
    }
    const bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
    if (!bridge.isAttached()) {
      return '网页还没准备好，请再点一次登录';
    }
    WebLogin.busy = true;
    try {
      const state: PageState = await WebLogin.ensureLoginPage(bridge);
      if (!state.usable()) {
        return `登录页没能加载出来${WebLogin.lastProbe}`;
      }
      const applied: string = await bridge.runScript(WebLogin.submitAllScript(user, password));
      hilog.info(DOMAIN, TAG, 'prefill → %{public}s', applied);
      if (applied.indexOf('"set":0') >= 0) {
        return `没能把账号密码填进登录框${WebLogin.lastProbe}`;
      }
      return '';
    } finally {
      WebLogin.busy = false;
    }
  }

  /**
   * **保证停在登录页上，但绝不重复导航**。
   *
   * 这一条是"网页不停抽搐 reload"的对症药：以前 `login` / `prefill` / `loginByWebAjax`
   * 三处入口各自 `loadUrl`，加上重试与外部的重复调用，页面就被反复重新加载。
   * 现在：先探一次；已经在登录页（有输入框）就直接用，只有真的不在才导航一次。
   */
  private static async ensureLoginPage(bridge: InstagramPageBridge): Promise<PageState> {
    let state: PageState = await WebLogin.probeOnce(bridge);
    if (state.usable()) {
      return state;
    }
    hilog.info(DOMAIN, TAG, 'not on login page yet → navigate once');
    bridge.loadUrl(LOGIN_URL);
    state = await WebLogin.waitForForm(bridge);
    return state;
  }

  /**
   * **走 IG 网页自己的登录接口**（`/api/v1/web/accounts/login/ajax/`），绕开那颗 Bloks 按钮。
   *
   * 为什么这条路值得试：网页 App 登录时发的就是这一发 XHR（带 `X-CSRFToken` + 表单体），
   * 服务端回 `{"authenticated":true,...}` 并种下 `sessionid`。它**不经过 Bloks 渲染层**，
   * 所以我们不需要"点按钮"——这正是零点击的唯一现实入口。
   *
   * 实现上分两步（`runJavaScript` 拿不到 Promise 的结果，只能先起再查）：
   *   ① 在页面里发 fetch（凭证随 cookie 走，csrf 从 `document.cookie` 取）；
   *   ② 轮询 `window.__igwb` 拿状态码与响应体。
   *
   * @returns 空串 = 服务端说"已认证"；否则是失败原因（会带上服务端原话）
   */
  static async loginByWebAjax(username: string, password: string): Promise<string> {
    const user: string = username.trim();
    if (user.length === 0 || password.length === 0) {
      return '请输入账号和密码';
    }
    if (WebLogin.busy) {
      return '正在登录中，请稍候';
    }
    const bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
    if (!bridge.isAttached()) {
      return '网页还没准备好，请再点一次登录';
    }
    WebLogin.busy = true;
    try {
      /*
       * **已经在登录页上就别再导航**：`loadUrl` 会重载页面，把上一次发起、还没回来的 fetch
       * 连同 `window.__igwb` 一起冲掉（真机日志里就是"started"刷了很多行、结果一条没有），
       * 也是"网页不停抽搐 reload"的直接来源。
       */
      const state: PageState = await WebLogin.ensureLoginPage(bridge);
      if (!state.usable()) {
        return `登录页没能加载出来${WebLogin.lastProbe}`;
      }
      /*
       * **三种表单体变体依次试**：这个端点的字段这几年换过几版，只试一种很容易被
       * "明明密码对却回 authenticated:false"误导。每种都把响应体记进日志，便于定位。
       */
      /*
       * **429 就立刻收手**。
       *
       * 实测（模拟器日志）：三种表单体**全部**回 `status=429` —— 说明 IG 限的是这个 IP/设备的
       * 登录尝试频率，和表单字段无关；继续换形状或反复点只会把窗口拉得更长
       * （这正是"越试越久"的老毛病）。所以遇到 429 设一个冷却，期间直接返回、不再发请求。
       */
      if (Date.now() < WebLogin.throttleUntilMs) {
        const leftMin: number = Math.ceil((WebLogin.throttleUntilMs - Date.now()) / 60000);
        return `IG 正在限制登录尝试（429），请约 ${leftMin} 分钟后再试`;
      }
      let lastBody: string = '';
      let lastStatus: string = '';
      for (let variant: number = 0; variant < 3; variant++) {
        const started: string =
          await bridge.runScript(WebLogin.ajaxStartScript(user, password, variant));
        if (started.indexOf('started') < 0) {
          hilog.warn(DOMAIN, TAG, 'ajax variant %{public}d not sent: %{public}s', variant, started);
          continue;
        }
        const deadline: number = Date.now() + 15000;
        let answered: boolean = false;
        while (Date.now() < deadline) {
          await WebLogin.sleep(600);
          const raw: string = WebLogin.normalizeProbe(await bridge.runScript(WebLogin.AJAX_RESULT_JS));
          if (raw.indexOf('"done":1') < 0) {
            continue;
          }
          answered = true;
          lastBody = WebLogin.fieldOf(raw, 'body');
          lastStatus = WebLogin.fieldOf(raw, 'status');
          hilog.info(DOMAIN, TAG, 'web ajax v%{public}d status=%{public}s body=%{public}s',
            variant, lastStatus,
            lastBody.length > 220 ? `${lastBody.substring(0, 220)}…` : lastBody);
          if (lastBody.indexOf('"authenticated":true') >= 0
            || lastBody.indexOf('"authenticated": true') >= 0) {
            // 服务端已认证：会话 cookie 应该已经落罐，交给上层确认。
            return '';
          }
          if (lastStatus === '429' || lastBody.indexOf('429') >= 0) {
            WebLogin.throttleUntilMs = Date.now() + LOGIN_THROTTLE_COOLDOWN_MS;
            return `IG 正在限制登录尝试（429），请约 ${Math.round(LOGIN_THROTTLE_COOLDOWN_MS / 60000)} 分钟后再试`;
          }
          break;
        }
        if (!answered) {
          hilog.warn(DOMAIN, TAG, 'ajax v%{public}d timeout', variant);
        }
      }
      if (lastBody.length === 0) {
        return '网页里的登录请求没有回应（三次都没回）';
      }
      return WebLogin.ajaxFailure(lastBody, lastStatus);
    } finally {
      WebLogin.busy = false;
    }
  }

  /** 只探一次（不导航、不等待），用于"现在是不是已经停在登录页上"。 */
  private static async probeOnce(bridge: InstagramPageBridge): Promise<PageState> {
    const raw: string = await bridge.runScript(FORM_PROBE_JS);
    if (raw.trim().length === 0) {
      return new PageState('', false, false, '');
    }
    const text: string = WebLogin.normalizeProbe(raw);
    return new PageState(text, text.indexOf('"u":1') >= 0, text.indexOf('"p":1') >= 0,
      WebLogin.fieldOf(text, 'r'));
  }

  /** 把网页 ajax 的失败原因翻译成一句中文（尽量用服务端原话）。 */
  private static ajaxFailure(body: string, status: string): string {
    const lower: string = body.toLowerCase();
    if (lower.indexOf('two_factor') >= 0) {
      return '这个账号开了两步验证，请用「网页登录」完成验证码';
    }
    if (lower.indexOf('checkpoint') >= 0 || lower.indexOf('challenge') >= 0) {
      return 'Instagram 要求完成安全验证，请用「网页登录」完成';
    }
    if (lower.indexOf('bad_password') >= 0 || lower.indexOf('password') >= 0) {
      return '账号或密码不正确';
    }
    if (lower.indexOf('wait a few minutes') >= 0) {
      return '操作太频繁，被 IG 暂时限制了，过几分钟再试';
    }
    const message: string = WebLogin.fieldOf(body, 'message');
    if (message.length > 0) {
      return `登录失败：${message}`;
    }
    return `登录没有成功（HTTP ${status}）`;
  }

  /** 在页面里发起一次网页登录 XHR（见 loginByWebAjax）。 */
  private static ajaxStartScript(user: string, password: string, variant: number): string {
    /*
     * 三种表单体变体（网页端这几年换过几版字段，一次试完再报错才有意义）：
     *   0 = 现在的网页 App 那套（queryParams / optIntoOneTap / trustedDeviceRecords）；
     *   1 = 最简（username + enc_password + queryParams）；
     *   2 = 补上移动端那几样（jazoest / adid / guid / device_id / _csrftoken），
     *       以防这个端点走的是同一套后端校验。
     */
    return '(function(){try{'
      + 'var U=' + JSON.stringify(user) + ',P=' + JSON.stringify(password) + ';'
      + 'var V=' + variant + ';'
      + 'window.__igwb={done:0,status:0,body:""};'
      + 'var m=document.cookie.match(/csrftoken=([^;]+)/);var csrf=m?m[1]:"";'
      + 'var ts=Math.floor(Date.now()/1000);'
      // 浏览器端密码封装：`#PWD_INSTAGRAM_BROWSER:0:<ts>:<明文>`（网页 App 自己就是这么发的）
      + 'var enc="#PWD_INSTAGRAM_BROWSER:0:"+ts+":"+P;'
      + 'var body="username="+encodeURIComponent(U)'
      + '+"&enc_password="+encodeURIComponent(enc);'
      + 'if(V===0){body+="&queryParams=%7B%7D&optIntoOneTap=false&stopDeletionNonce="'
      + '+"&trustedDeviceRecords=%7B%7D";}'
      + 'if(V===1){body+="&queryParams=%7B%7D&optIntoOneTap=false";}'
      + 'if(V===2){var guid=(window.crypto&&crypto.randomUUID)?crypto.randomUUID()'
      + ':"xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g,function(c){'
      + 'var r=Math.random()*16|0,v=c==="x"?r:(r&0x3|0x8);return v.toString(16);});'
      + 'var jz=0;for(var i=0;i<guid.length;i++){jz+=guid.charCodeAt(i);}'
      + 'body+="&queryParams=%7B%7D&optIntoOneTap=false"'
      + '+"&jazoest=2"+jz+"&guid="+guid+"&device_id="+guid+"&adid="+guid'
      + '+"&_csrftoken="+encodeURIComponent(csrf)+"&login_attempt_count=0";}'
      + 'fetch("/api/v1/web/accounts/login/ajax/",{method:"POST",credentials:"include",'
      + 'headers:{"Content-Type":"application/x-www-form-urlencoded","X-CSRFToken":csrf,'
      + '"X-Requested-With":"XMLHttpRequest","X-Instagram-AJAX":"1",'
      // 网页 App 的 App ID（和移动端那个 567067343352427 不是同一个）
      + '"X-IG-App-ID":"936619743392459"},body:body})'
      + '.then(function(r){return r.text().then(function(t){'
      + 'window.__igwb={done:1,status:r.status,body:(t||"").slice(0,400),v:V};});})'
      + '.catch(function(e){window.__igwb={done:1,status:-1,body:String(e).slice(0,120),v:V};});'
      + 'return "started";'
      + '}catch(e){return "error:"+String(e).slice(0,100);}})()';
  }

  /** 读上面那一发的结果（`window.__igwb` 的 JSON）。 */
  private static readonly AJAX_RESULT_JS: string =
    '(function(){try{var o=window.__igwb||{done:0,status:0,body:""};'
    + 'return JSON.stringify({done:o.done?1:0,status:o.status,body:o.body||""});}'
    + 'catch(e){return JSON.stringify({done:1,status:-1,body:"err"});}})()';

  /** 正在跑（界面据此显示进度、禁用按钮）。 */
  static isRunning(): boolean {
    return WebLogin.running;
  }

  /**
   * 登录（用隐藏网页）。
   *
   * @returns 空串 = 成功；否则是给用户看的失败原因
   */
  static async login(username: string, password: string): Promise<string> {
    const user: string = username.trim();
    if (user.length === 0 || password.length === 0) {
      return '请输入账号和密码';
    }
    if (WebLogin.running) {
      return '正在登录中，请稍候';
    }
    WebLogin.running = true;
    const bridge: InstagramPageBridge = InstagramPageBridge.getInstance();
    try {
      if (!bridge.isAttached()) {
        return '网页还没准备好，请再点一次登录';
      }
      hilog.info(DOMAIN, TAG, 'headless login start user=%{public}d', user.length);
      // 同样"已在登录页就不再导航"（见 ensureLoginPage：这是 reload 抽搐的对症药）。
      let state: PageState = await WebLogin.ensureLoginPage(bridge);
      if (!state.usable()) {
        // 把诊断摘要带进界面文案（见 lastProbe 的说明）。
        return `登录页没能加载出来（也可点下方「网页登录」手动完成）${WebLogin.lastProbe}`;
      }
      /*
       * **两步登录页**（IG 移动网页版常见形态）：先只给用户名框，点「下一步/继续」
       * 才出现密码框。以前只认"用户名+密码同时在"的形态，遇到这一种就会一直等到超时，
       * 报"加载不出来"。现在两种形态都走：
       *   ① 只有用户名 → 填用户名 → 点下一步 → 等密码框；
       *   ② 用户名+密码都在 → 直接一起填。
       */
      if (state.hasUser && !state.hasPassword) {
        hilog.info(DOMAIN, TAG, 'two-step login page detected → fill username first');
        await bridge.runScript(WebLogin.fillUserScript(user));
        await bridge.runScript(WebLogin.clickNextScript());
        state = await WebLogin.waitForPassword(bridge);
        if (!state.hasPassword) {
          return `登录页没出现密码框（可能被要求在网页里验证）${WebLogin.lastProbe}`;
        }
      }
      /*
       * **填值 + 点提交必须在同一次 JS 里完成**（这一段是"点了没反应"的对策）。
       *
       * 实测现场（很关键）：先用一次 `runJavaScript` 填值，再用另一次点按钮时，
       * 点的那一次里 `document.querySelectorAll("div").length` 竟然是 **0** ——
       * 也就是"填值派发的 input 事件让 React 重渲染/换页，两次调用之间 DOM 已经不是原来那个了"。
       * 分开做永远点不到（日志里就是 `nobutton: divs=0`）。
       *
       * 所以合成一发：找输入框 → 写值 → 找按钮 → 派发 pointer/touch/mouse/click → 回报 JSON。
       * 一次执行，中间不给页面换掉的机会。
       */
      const applied: string = await bridge.runScript(WebLogin.submitAllScript(user, password));
      hilog.info(DOMAIN, TAG, 'fill+submit → %{public}s', applied);
      if (applied.indexOf('"set":0') >= 0) {
        return `没能把账号密码填进登录框${WebLogin.lastProbe}`;
      }
      if (applied.indexOf('"clicked":0') >= 0) {
        // 按钮没点到：补一次"密码框回车"（同样是一发原子脚本）。
        const enterLog: string = await bridge.runScript(WebLogin.onSubmitJs('enter'));
        hilog.info(DOMAIN, TAG, 'enter fallback → %{public}s', enterLog);
      }
      const outcome: string = await WebLogin.waitForSession(bridge);
      return outcome;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'headless login threw: %{public}s', (error as Error).message);
      return `登录出错：${(error as Error).message}`;
    } finally {
      WebLogin.running = false;
    }
  }

  /**
   * 依次试三种提交方式，并用"页面文字有没有变"来判断哪一种真的生效。
   *
   * @returns `方法名:changed` / `nochange`
   */
  private static async submitAndVerify(bridge: InstagramPageBridge, before: string): Promise<string> {
    const attempts: Array<string> = [
      WebLogin.onSubmitJs('click'),
      WebLogin.onSubmitJs('enter'),
      WebLogin.onSubmitJs('form')
    ];
    const names: Array<string> = ['click', 'enter', 'form'];
    for (let index: number = 0; index < attempts.length; index++) {
      const detail: string = await bridge.runScript(attempts[index]);
      hilog.info(DOMAIN, TAG, 'submit %{public}s → %{public}s', names[index], detail);
      // 给它 2.5 秒：IG 登录表单点下去会立刻切到"正在登录"或报错，文字必变。
      await WebLogin.sleep(2500);
      const after: string = await WebLogin.pageText(bridge);
      if (after !== before && after.length > 0) {
        return `${names[index]}:changed`;
      }
    }
    return 'nochange';
  }

  /**
   * 一种提交方式的脚本。
   *
   * @param mode `click` = 派发 MouseEvent 点按钮；`enter` = 密码框按回车；
   *             `form` = 表单 requestSubmit()
   */
  private static onSubmitJs(mode: string): string {
    const head: string = '(function(){try{';
    if (mode === 'enter') {
      return head
        + 'var p=document.querySelector(\'input[name="password"]\')||document.querySelector(\'#password\');'
        + 'if(!p){return "nopass";}'
        + 'p.focus();'
        + 'function key(type){p.dispatchEvent(new KeyboardEvent(type,{key:"Enter",code:"Enter",'
        + 'keyCode:13,which:13,bubbles:true,cancelable:true}));}'
        + 'key("keydown");key("keypress");key("keyup");'
        + 'return "enter";'
        + '}catch(e){return "error:"+String(e).slice(0,80);}})()';
    }
    if (mode === 'form') {
      return head
        + 'var f=document.querySelector("form");'
        + 'if(!f){return "noform";}'
        + 'if(f.requestSubmit){f.requestSubmit();return "requestSubmit";}'
        + 'f.submit();return "formsubmit";'
        + '}catch(e){return "error:"+String(e).slice(0,80);}})()';
    }
    /*
     * **按文字找可点元素**（实测：IG 移动登录页既没有 `<form>`，也没有 `<button>`，
     * 那个"登录"是个普通 div —— 只查 button/submit 就只会回 nobutton）。
     * 取 innerText 与按钮文案匹配、且**文字最短**（= 最深的那个）的元素，
     * 然后沿它的祖先链各派发一遍鼠标事件（React 的合成事件可能挂在任意一层）。
     */
    return head
      // 文案先去掉所有空白/零宽字符再比：IG 的按钮文字里常带换行与 \u200b，锚定正则会被它坑掉。
      + 'var V="v3";var NAMES=["登录","登入","下一步","继续","login","log in","next","continue"];'
      + 'var els=document.querySelectorAll(\'div,span,a,button,[role="button"]\');'
      + 'var hit=null,bestLen=999;'
      + 'for(var i=0;i<els.length;i++){var el=els[i];'
      + 'var t=(el.innerText||"").replace(/[\\s\\u200b]+/g,"");'
      + 'if(!t||t.length>12){continue;}'
      + 'if(NAMES.indexOf(t.toLowerCase())<0){continue;}'
      + 'var r=el.getBoundingClientRect();if(r.width<4||r.height<4){continue;}'
      + 'if(t.length<bestLen){hit=el;bestLen=t.length;}}'
      // 兜底：IG 新版登录按钮是 `div.wbloks_1`（Bloks 渲染的可点区块），文案可能被拆到子节点里。
      // 取"最后一个高 40~56 的 wbloks_1"，通常就是表单底部那颗主按钮。
      + 'if(!hit){var ws=document.querySelectorAll(\'div[class*="wbloks"]\');'
      + 'for(var j=ws.length-1;j>=0;j--){var w=ws[j];var rr=w.getBoundingClientRect();'
      + 'if(rr.height>=40&&rr.height<=60&&rr.width>60){hit=w;break;}}}'
      + 'if(!hit){return "nobutton:"+V+" divs="+document.querySelectorAll("div").length'
      + '+" wb="+document.querySelectorAll(\'div[class*="wbloks"]\').length;}'
      // 这座页面是移动端 Bloks 渲染的：**可能只认 touch / pointer 事件**（鼠标事件被忽略）。
      // 所以把鼠标、指针、触摸三条都派发一遍（含祖先链，React 合成事件可能挂在任意一层）。
      + 'var r0=hit.getBoundingClientRect();var cx=r0.left+r0.width/2,cy=r0.top+r0.height/2;'
      + 'function fire(e,type){try{'
      + 'if(type.indexOf("touch")===0){'
      + 'var tch=new Touch({identifier:1,target:e,clientX:cx,clientY:cy,pageX:cx,pageY:cy});'
      + 'e.dispatchEvent(new TouchEvent(type,{bubbles:true,cancelable:true,'
      + 'touches:type==="touchend"?[]:[tch],targetTouches:type==="touchend"?[]:[tch],'
      + 'changedTouches:[tch]}));'
      + '}else if(type.indexOf("pointer")===0){'
      + 'e.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,'
      + 'pointerId:1,pointerType:"touch",isPrimary:true,clientX:cx,clientY:cy,button:0,buttons:1}));'
      + '}else{'
      + 'e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,composed:true,view:window,'
      + 'clientX:cx,clientY:cy,button:0}));}'
      + '}catch(err){}}'
      + 'var chain=[];var n=hit;for(var k=0;k<3&&n;k++){chain.push(n);n=n.parentElement;}'
      + 'var seq=["pointerdown","touchstart","mousedown","pointerup","touchend","mouseup","click"];'
      + 'for(var c=0;c<chain.length;c++){var e=chain[c];'
      + 'for(var s=0;s<seq.length;s++){fire(e,seq[s]);}}'
      + 'try{hit.click();}catch(e2){}'
      + 'return "clicked:"+hit.tagName+"."+String(hit.className||"").slice(0,12)+"@"+Math.round(r0.width)+"x"+Math.round(r0.height)+":"+hit.innerText.trim().replace(/\\s+/g,"").slice(0,10);'
      + '}catch(e){return "error:"+String(e).slice(0,80);}})()';
  }

  /**
   * **原子版**：填值 + 点提交，一次 JS 内完成（理由见 login 里那段说明）。
   *
   * @returns JSON：`{"set":1,"u":13,"p":9,"clicked":1,"btn":"DIV.wbloks_1@334x44"}`
   */
  private static submitAllScript(user: string, password: string): string {
    return '(function(){try{'
      + 'var U=' + JSON.stringify(user) + ',P=' + JSON.stringify(password) + ';'
      + 'function setv(el,v){var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value");'
      + 'd.set.call(el,v);el.dispatchEvent(new Event("input",{bubbles:true}));'
      + 'el.dispatchEvent(new Event("change",{bubbles:true}));}'
      + 'var u=document.querySelector(\'input[name="username"]\')||document.querySelector(\'#username\');'
      + 'var p=document.querySelector(\'input[name="password"]\')||document.querySelector(\'#password\');'
      + 'if(!u||!p){return JSON.stringify({set:0,why:"noinput"});}'
      + 'u.focus();setv(u,U);p.focus();setv(p,P);'
      + 'var ok=(u.value.length>0&&p.value.length>0)?1:0;'
      // —— 找按钮：先按文案（去空白/零宽字符），再退回 wbloks 区块 ——
      + 'var NAMES=["登录","登入","下一步","继续","login","log in","next","continue"];'
      + 'var els=document.querySelectorAll(\'div,span,a,button,[role="button"]\');'
      + 'var hit=null,best=999;'
      + 'for(var i=0;i<els.length;i++){var el=els[i];'
      + 'var t=(el.innerText||"").replace(/[\\s\\u200b]+/g,"");'
      + 'if(!t||t.length>12){continue;}'
      + 'if(NAMES.indexOf(t.toLowerCase())<0){continue;}'
      + 'var rc=el.getBoundingClientRect();if(rc.width<4||rc.height<4){continue;}'
      + 'if(t.length<best){hit=el;best=t.length;}}'
      + 'if(!hit){var ws=document.querySelectorAll(\'div[class*="wbloks"]\');'
      + 'for(var j=ws.length-1;j>=0;j--){var w=ws[j];var rr=w.getBoundingClientRect();'
      + 'if(rr.height>=40&&rr.height<=60&&rr.width>60){hit=w;break;}}}'
      // —— 派发事件（移动端 Bloks 页面：pointer / touch / mouse / click 全发一遍）——
      + 'var clicked=0,descr="none";'
      + 'if(hit){var r0=hit.getBoundingClientRect();var cx=r0.left+r0.width/2,cy=r0.top+r0.height/2;'
      + 'descr=hit.tagName+"."+String(hit.className||"").slice(0,12)+"@"+Math.round(r0.width)+"x"+Math.round(r0.height);'
      + 'function fire(e,type){try{'
      + 'if(type.indexOf("touch")===0){'
      + 'var tch=new Touch({identifier:1,target:e,clientX:cx,clientY:cy,pageX:cx,pageY:cy});'
      + 'e.dispatchEvent(new TouchEvent(type,{bubbles:true,cancelable:true,composed:true,touches:[tch],'
      + 'targetTouches:[tch],changedTouches:[tch]}));'
      + '}else if(type.indexOf("pointer")===0){'
      + 'e.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,composed:true,pointerId:1,'
      + 'pointerType:"touch",isPrimary:true,clientX:cx,clientY:cy,button:0,buttons:1}));'
      + '}else{e.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,composed:true,view:window,'
      + 'clientX:cx,clientY:cy,button:0}));}}catch(err){}}'
      + 'var chain=[];var n=hit;for(var k=0;k<3&&n;k++){chain.push(n);n=n.parentElement;}'
      + 'var seq=["pointerdown","touchstart","mousedown","pointerup","touchend","mouseup","click"];'
      + 'for(var c=0;c<chain.length;c++){for(var s=0;s<seq.length;s++){fire(chain[c],seq[s]);}}'
      + 'try{hit.click();}catch(e2){}clicked=1;}'
      + 'return JSON.stringify({set:ok,u:u.value.length,p:p.value.length,clicked:clicked,btn:descr});'
      + '}catch(e){return JSON.stringify({set:0,why:"err:"+String(e).slice(0,80)});}})()';
  }

  /** 填**只填用户名**（两步登录页的第一步）。 */
  private static fillUserScript(user: string): string {
    return '(function(){try{'
      + 'var U=' + JSON.stringify(user) + ';'
      + 'function setv(el,v){var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value");'
      + 'd.set.call(el,v);el.dispatchEvent(new Event("input",{bubbles:true}));'
      + 'el.dispatchEvent(new Event("change",{bubbles:true}));}'
      + 'var u=document.querySelector(\'input[name="username"]\')||document.querySelector(\'#username\');'
      + 'if(!u){return "nouser";}'
      + 'u.focus();setv(u,U);return "filled";'
      + '}catch(e){return "error:"+String(e).slice(0,120);}})()';
  }

  /**
   * 点「下一步 / 继续 / Next / Log in」那一颗。
   *
   * 两步登录页的按钮文案随语言变，所以按文案正则匹配一遍（英文 + 中文），
   * 匹配不到再退回 `type=submit` / 表单 `requestSubmit()`。
   */
  private static clickNextScript(): string {
    return '(function(){try{'
      + 'var btns=Array.prototype.slice.call(document.querySelectorAll(\'button,div[role="button"]\'));'
      + 'for(var i=0;i<btns.length;i++){var b=btns[i];var t=(b.innerText||"").trim();'
      + 'if(/^(next|continue|log\\s*in|下一步|继续|登录|登入)$/i.test(t)){b.click();return "clicked:"+t;}}'
      + 'for(var j=0;j<btns.length;j++){if(btns[j].type==="submit"){btns[j].click();return "clicked:submit";}}'
      + 'var f=document.querySelector("form");if(f&&f.requestSubmit){f.requestSubmit();return "formsubmit";}'
      + 'return "nobutton";'
      + '}catch(e){return "error:"+String(e).slice(0,80);}})()';
  }

  /**
   * 等登录表单出现，并把**页面现在长什么样**记进日志。
   *
   * 诊断为什么重要：上一版只回 '0'/'1'，于是"表单没出现"到底是
   * 页面没加载、加载到了别的页、还是 JS 根本没执行，全看不出来（用户只看到一句
   * "登录页没能加载出来"）。现在每 3 拍打一行 `readyState / url / title / inputs / 文本长度`。
   */
  private static async waitForForm(bridge: InstagramPageBridge): Promise<PageState> {
    return await WebLogin.waitForState(bridge, FORM_WAIT_MS, false);
  }

  /** 等**密码框**出现（两步登录页点了「下一步」之后）。 */
  private static async waitForPassword(bridge: InstagramPageBridge): Promise<PageState> {
    return await WebLogin.waitForState(bridge, FORM_WAIT_MS, true);
  }

  /**
   * 轮询页面状态，直到满足条件或超时。
   *
   * @param needPassword true = 要等密码框；false = 只要页面上有可填的输入框就算就绪
   */
  private static async waitForState(bridge: InstagramPageBridge, timeoutMs: number,
                                    needPassword: boolean): Promise<PageState> {
    const deadline: number = Date.now() + timeoutMs;
    let tick: number = 0;
    let last: PageState = new PageState('', false, false, '');
    WebLogin.lastProbe = '';
    while (Date.now() < deadline) {
      const raw: string = await bridge.runScript(FORM_PROBE_JS);
      if (raw.trim().length === 0) {
        // 空串 = runJavaScript 拿不到结果（控制器没绑 / 页面还没起来）。
        if (tick % 3 === 0) {
          hilog.warn(DOMAIN, TAG, 'probe empty (tick=%{public}d) attached=%{public}s',
            tick, `${bridge.isAttached()}`);
        }
      } else {
        /*
         * **必须先"归一化"再判**（真机日志把这一点摆得很清楚）：
         * `runJavaScript` 会把我们 `JSON.stringify` 出来的字符串**再序列化一次**，
         * 于是拿到的是 `"{\"r\":\"complete\",…}"` —— 里面的引号是被转义的。
         * 直接 `indexOf('"u":1')` 永远匹配不到，于是"表单明明在，却一直等到超时"
         * （正是用户看到的"登录页没能加载出来"）。
         */
        const text: string = WebLogin.normalizeProbe(raw);
        last = new PageState(text, text.indexOf('"u":1') >= 0, text.indexOf('"p":1') >= 0,
          WebLogin.fieldOf(text, 'r'));
        if (tick % 3 === 0) {
          hilog.info(DOMAIN, TAG, 'probe %{public}s', raw);
        }
        const ok: boolean = needPassword ? last.hasPassword : last.usable();
        if (ok) {
          return last;
        }
      }
      tick++;
      await WebLogin.sleep(POLL_MS);
    }
    // 诊断摘要：一会儿要拼到界面文案里（见 lastProbe）。
    WebLogin.lastProbe = `\n[诊断] ${last.raw.length > 0 ? WebLogin.probeSummary(last.raw)
      : `JS 无返回 (attached=${bridge.isAttached()})`}`;
    hilog.warn(DOMAIN, TAG, 'form not found in %{public}dms, last=%{public}s',
      timeoutMs, last.raw.length > 0 ? last.raw : '(none)');
    return last;
  }

  /**
   * 把探测 JSON 压成一行给人看的东西（只留关键几项）。
   *
   * 例：`ready=complete 用户名框=1 密码框=0 inputs=1 text=812 url=/accounts/login/`
   */
  private static probeSummary(raw: string): string {
    const ready: string = WebLogin.fieldOf(raw, 'r');
    const hasUser: string = WebLogin.fieldOf(raw, 'u');
    const hasPassword: string = WebLogin.fieldOf(raw, 'p');
    const inputs: string = WebLogin.fieldOf(raw, 'n');
    const len: string = WebLogin.fieldOf(raw, 'len');
    const href: string = WebLogin.fieldOf(raw, 'h');
    const title: string = WebLogin.fieldOf(raw, 't');
    const path: string = href.indexOf('instagram.com') >= 0
      ? href.substring(href.indexOf('instagram.com') + 'instagram.com'.length) : href;
    return `ready=${ready.length > 0 ? ready : '?'} 用户名框=${hasUser} 密码框=${hasPassword}`
      + ` inputs=${inputs.length > 0 ? inputs : '?'} text=${len.length > 0 ? len : '?'}`
      + ` url=${path.length > 0 ? path : '?'}`
      + `${title.length > 0 ? ` title=${title}` : ''}`;
  }

  /**
   * 把探测结果"归一化"成一份普通 JSON 文本。
   *
   * `runJavaScript` 的返回有两层：JS 里 `JSON.stringify` 过一次，桥接又把它当字符串
   * 序列化一次 —— 拿到的是 `"{\"r\":\"complete\",…}"`。这里剥掉外层引号并还原转义，
   * 后面所有 `indexOf('"u":1')` / 取值才成立（否则永远匹配不到，见 waitForState 的说明）。
   */
  private static normalizeProbe(raw: string): string {
    let text: string = raw.trim();
    if (text.length >= 2 && text.charAt(0) === '"' && text.charAt(text.length - 1) === '"') {
      text = text.substring(1, text.length - 1);
    }
    text = text.split('\\"').join('"');
    text = text.split('\\\\').join('\\');
    return text;
  }
  /** 从 `{"k":"v",…}` 里取一个字段（探测结果是我们自己拼的 JSON，够用即可）。 */
  private static fieldOf(raw: string, key: string): string {
    const needle: string = `"${key}":`;
    const at: number = raw.indexOf(needle);
    if (at < 0) {
      return '';
    }
    let cursor: number = at + needle.length;
    if (cursor >= raw.length) {
      return '';
    }
    if (raw.charAt(cursor) === '"') {
      /*
       * 字符串值：要跳过 `\"` 转义再找结束引号。
       *
       * 踩过的坑：响应体是 JSON（里面的引号都转义成 `\"`），原来"找下一个引号"直接停在
       * 第一个转义引号上，于是日志里 `body={\` 只剩一个花括号 —— 429 的真实文案全丢了。
       */
      let index: number = cursor + 1;
      let collected: string = '';
      while (index < raw.length) {
        const ch: string = raw.charAt(index);
        if (ch === '\\' && index + 1 < raw.length) {
          const next: string = raw.charAt(index + 1);
          collected += next === 'n' ? '\n' : next;
          index += 2;
          continue;
        }
        if (ch === '"') {
          break;
        }
        collected += ch;
        index++;
      }
      return collected;
    }
    let end: number = cursor;
    while (end < raw.length) {
      const ch: string = raw.charAt(end);
      if (ch === ',' || ch === '}') {
        break;
      }
      end++;
    }
    return raw.substring(cursor, end).trim();
  }

  /**
   * 填表 + 提交。
   *
   * 两个细节决定了它能不能成功：
   *   · **必须用原型上的 value setter**：React 受控组件劫持了 `value` 属性的赋值，
   *     直接 `el.value = x` 不会更新 React 的内部状态，提交时 IG 收到的是空字符串；
   *   · 必须派发 `input` 与 `change` 两种事件，React 才认为"用户输入过"。
   */
  private static fillScript(user: string, password: string): string {
    return '(function(){try{'
      + 'var U=' + JSON.stringify(user) + ', P=' + JSON.stringify(password) + ';'
      + 'function setv(el,v){var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,"value");'
      + 'd.set.call(el,v);el.dispatchEvent(new Event("input",{bubbles:true}));'
      + 'el.dispatchEvent(new Event("change",{bubbles:true}));}'
      + 'var u=document.querySelector(\'input[name="username"]\')||document.querySelector(\'#username\');'
      + 'var p=document.querySelector(\'input[name="password"]\')||document.querySelector(\'#password\');'
      + 'if(!u||!p){return "noform";}'
      + 'u.focus();setv(u,U);p.focus();setv(p,P);'
      // 读回核对：值真的写进去了吗（React 受控组件可能把值吃掉）。
      + 'return JSON.stringify({set:(u.value.length>0&&p.value.length>0)?1:0,u:u.value.length,p:p.value.length});'
      + '}catch(e){return JSON.stringify({set:0,m:String(e).slice(0,80)});}})()';
  }

  /** 读页面上的一段可见文字（诊断用：登录失败时 IG 会写一句原因，我们需要看原文）。 */
  private static async pageText(bridge: InstagramPageBridge): Promise<string> {
    const js: string = '(function(){try{var t=(document.body?document.body.innerText:"")'
      + '.replace(/\\s+/g," ").trim();return t.slice(0,220);}catch(e){return "";}})()';
    const raw: string = await bridge.runScript(js);
    const text: string = WebLogin.normalizeProbe(raw);
    return text.length >= 2 && text.charAt(0) === '"'
      ? text.substring(1, text.length - 1).split('\\"').join('"') : text;
  }

  /** 等会话落地：Cookie 罐里出现 sessionid + ds_user_id 就算成功。 */
  private static async waitForSession(bridge: InstagramPageBridge): Promise<string> {
    const deadline: number = Date.now() + SESSION_WAIT_MS;
    let textTicks: number = 0;
    while (Date.now() < deadline) {
      /*
       * 每约 5 秒把页面上的文字抓一段进日志（最多 6 次）。
       *
       * 为什么需要：登录失败时 IG 会在页面上写一句原因，而那句话是**动态**的
       * （"密码不对" / "无法登录" / "稍后再试" / "需要验证"…）。只按猜的几组关键词匹配
       * 会漏，日志里有原文才能真正对上。
       */
      if (textTicks < 6 && (textTicks === 0 || Date.now() + SESSION_WAIT_MS - deadline
        > 5000 * textTicks)) {
        const page: string = await WebLogin.pageText(bridge);
        if (page.length > 0) {
          hilog.info(DOMAIN, TAG, 'page text[%{public}d] %{public}s', textTicks, page);
        }
        textTicks++;
      }
      let snapshot: InstagramCookieSnapshot | null = null;
      try {
        snapshot = await InstagramCookieJar.inspect();
      } catch (error) {
        snapshot = null;
      }
      if (snapshot !== null && snapshot.signedIn) {
        hilog.info(DOMAIN, TAG, 'headless login ok (%{public}d cookies)', snapshot.count);
        return '';
      }
      const signal: PageSignal | null = await WebLogin.readPageSignal(bridge);
      if (signal !== null) {
        hilog.warn(DOMAIN, TAG, 'headless login blocked: %{public}s', signal.key);
        return signal.text;
      }
      await WebLogin.sleep(POLL_MS);
    }
    return '登录没能在 45 秒内完成（可能卡在验证步骤），请用「网页登录」完成一次';
  }

  /** 读页面上的错误/验证线索（读不到返回 null）。 */
  private static async readPageSignal(bridge: InstagramPageBridge): Promise<PageSignal | null> {
    const js: string = '(function(){try{var t=(document.body?document.body.innerText:"")'
      + '.toLowerCase();return t.slice(0,4000);}catch(e){return "";}})()';
    const text: string = (await bridge.runScript(js)).toLowerCase();
    if (text.length === 0) {
      return null;
    }
    const signals: Array<PageSignal> = WebLogin.signals();
    for (let index: number = 0; index < signals.length; index++) {
      if (text.indexOf(signals[index].needle) >= 0) {
        return signals[index];
      }
    }
    return null;
  }

  /**
   * 页面线索表（中英文都列，因为 IG 会按设备语言文案）。
   *
   * 命中就**立刻中止等待**：这些步骤都要人参与（输验证码 / 点确认），
   * 在隐藏网页里继续等只会让用户对着一个"登录中"的转圈发呆。
   */
  private static signals(): Array<PageSignal> {
    const list: Array<PageSignal> = [];
    list.push(new PageSignal('twofactor',
      '这个账号开了两步验证，请在「网页登录」里输入验证码', 'two-factor authentication'));
    list.push(new PageSignal('twofactor',
      '这个账号开了两步验证，请在「网页登录」里输入验证码', '两步验证'));
    list.push(new PageSignal('challenge',
      'Instagram 要求完成安全验证，请在「网页登录」里完成', 'challenge_required'));
    list.push(new PageSignal('challenge',
      'Instagram 要求完成安全验证，请在「网页登录」里完成', 'suspicious login'));
    list.push(new PageSignal('challenge',
      'Instagram 要求完成安全验证，请在「网页登录」里完成', 'help us confirm'));
    list.push(new PageSignal('badpassword',
      '账号或密码不正确', 'incorrect password'));
    list.push(new PageSignal('badpassword',
      '账号或密码不正确', 'password you entered is incorrect'));
    list.push(new PageSignal('badpassword',
      '账号或密码不正确', '密码不正确'));
    list.push(new PageSignal('badpassword',
      '账号或密码不正确', '找不到用户'));
    list.push(new PageSignal('badpassword',
      '账号或密码不正确', 'user not found'));
    list.push(new PageSignal('rate',
      '操作太频繁，被 IG 暂时限制了，过几分钟再试', 'wait a few minutes'));
    return list;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}
