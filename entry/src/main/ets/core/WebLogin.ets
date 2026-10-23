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

/** 判定"登录页的表单已经在了"，同时把页面状态一起带回来（诊断用）。 */
const FORM_PROBE_JS: string =
  '(function(){try{'
  + 'var u=document.querySelector(\'input[name="username"]\')||document.querySelector(\'#username\');'
  + 'var p=document.querySelector(\'input[name="password"]\')||document.querySelector(\'#password\');'
  + 'var inputs=document.querySelectorAll("input").length;'
  + 'return JSON.stringify({r:document.readyState,h:location.href.slice(0,120),'
  + 't:(document.title||"").slice(0,40),f:(u&&p)?1:0,n:inputs,'
  + 'len:(document.body?document.body.innerText.length:0)});'
  + '}catch(e){return JSON.stringify({r:"err",m:String(e).slice(0,80)});}})()';

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
  private static running: boolean = false;
  /**
   * 最近一次表单探测的结果（诊断用）。
   *
   * 为什么把它带进**界面文案**：无头登录失败时用户看到的只有一句"加载不出来"，
   * 而"到底卡在哪"（页面没起来 / 重定向了 / JS 没执行）全在探测结果里。
   * 把最关键的三四个字段附在错误后面，用户截个图就能定位 —— 比让他捞 hilog 现实得多。
   */
  private static lastProbe: string = '';

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
      bridge.loadUrl(LOGIN_URL);
      let formReady: boolean = await WebLogin.waitForForm(bridge);
      if (!formReady && bridge.isAttached()) {
        /*
         * **再来一次导航**：第一次 `loadUrl` 很可能撞上"控制器刚绑上、页面还没开始导航"
         * （无头模式下宿主的 `src` 也是登录页，但引擎恢复渲染后那一次可能被丢掉）。
         * 重发一次是安全的（等同用户刷新登录页），代价是多等一个 FORM_WAIT 周期。
         */
        hilog.warn(DOMAIN, TAG, 'form missing → navigate login page again');
        bridge.loadUrl(LOGIN_URL);
        formReady = await WebLogin.waitForForm(bridge);
      }
      if (!formReady) {
        // 把诊断摘要带进界面文案（见 lastProbe 的说明）。
        return `登录页没能加载出来（检查网络后重试）${WebLogin.lastProbe}`;
      }
      const submitted: string = await bridge.runScript(WebLogin.fillScript(user, password));
      hilog.info(DOMAIN, TAG, 'submit script → %{public}s', submitted);
      if (submitted.indexOf('submitted') < 0 && submitted.indexOf('formsubmit') < 0) {
        return '没找到登录按钮，请在网页里登录一次';
      }
      return await WebLogin.waitForSession(bridge);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'headless login threw: %{public}s', (error as Error).message);
      return `登录出错：${(error as Error).message}`;
    } finally {
      WebLogin.running = false;
    }
  }

  /**
   * 等登录表单出现，并把**页面现在长什么样**记进日志。
   *
   * 诊断为什么重要：上一版只回 '0'/'1'，于是"表单没出现"到底是
   * 页面没加载、加载到了别的页、还是 JS 根本没执行，全看不出来（用户只看到一句
   * "登录页没能加载出来"）。现在每 3 拍打一行 `readyState / url / title / inputs / 文本长度`。
   */
  private static async waitForForm(bridge: InstagramPageBridge): Promise<boolean> {
    const deadline: number = Date.now() + FORM_WAIT_MS;
    let tick: number = 0;
    let lastState: string = '';
    let sawAnything: boolean = false;
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
        lastState = raw;
        sawAnything = true;
        if (tick % 3 === 0) {
          hilog.info(DOMAIN, TAG, 'probe %{public}s', raw);
        }
        if (raw.indexOf('"f":1') >= 0) {
          return true;
        }
      }
      tick++;
      await WebLogin.sleep(POLL_MS);
    }
    // 诊断摘要：一会儿要拼到界面文案里（见 lastProbe）。
    WebLogin.lastProbe = `\n[诊断] ${sawAnything ? WebLogin.probeSummary(lastState)
      : `JS 无返回 (attached=${bridge.isAttached()})`}`;
    hilog.warn(DOMAIN, TAG, 'form not found in %{public}dms, last=%{public}s',
      FORM_WAIT_MS, lastState.length > 0 ? lastState : '(none)');
    return false;
  }

  /**
   * 把探测 JSON 压成一行给人看的东西（只留关键几项）。
   *
   * 例：`ready=complete form=0 inputs=3 text=812 url=/accounts/login/`
   */
  private static probeSummary(raw: string): string {
    const ready: string = WebLogin.fieldOf(raw, 'r');
    const form: string = WebLogin.fieldOf(raw, 'f');
    const inputs: string = WebLogin.fieldOf(raw, 'n');
    const len: string = WebLogin.fieldOf(raw, 'len');
    const href: string = WebLogin.fieldOf(raw, 'h');
    const title: string = WebLogin.fieldOf(raw, 't');
    const path: string = href.indexOf('instagram.com') >= 0
      ? href.substring(href.indexOf('instagram.com') + 'instagram.com'.length) : href;
    return `ready=${ready.length > 0 ? ready : '?'} form=${form.length > 0 ? form : '?'}`
      + ` inputs=${inputs.length > 0 ? inputs : '?'} text=${len.length > 0 ? len : '?'}`
      + ` url=${path.length > 0 ? path : '?'}`
      + `${title.length > 0 ? ` title=${title}` : ''}`;
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
      const close: number = raw.indexOf('"', cursor + 1);
      return close > cursor ? raw.substring(cursor + 1, close) : '';
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
      + 'var btns=Array.prototype.slice.call(document.querySelectorAll(\'button,div[role="button"]\'));'
      + 'var hit=null;'
      + 'for(var i=0;i<btns.length;i++){var b=btns[i];var t=(b.innerText||"").trim();'
      + 'if(b.type==="submit"||/^(log\\s*in|登录|登入)$/i.test(t)){hit=b;break;}}'
      + 'if(hit){hit.click();return "submitted";}'
      + 'var f=u.closest("form");if(f){if(f.requestSubmit){f.requestSubmit();}else{f.submit();}return "formsubmit";}'
      + 'return "nobutton";'
      + '}catch(e){return "error:"+String(e).slice(0,120);}})()';
  }

  /** 等会话落地：Cookie 罐里出现 sessionid + ds_user_id 就算成功。 */
  private static async waitForSession(bridge: InstagramPageBridge): Promise<string> {
    const deadline: number = Date.now() + SESSION_WAIT_MS;
    while (Date.now() < deadline) {
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
