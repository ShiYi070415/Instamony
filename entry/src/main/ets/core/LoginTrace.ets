/*
 * **登录过程的现场抓取**（诊断用：看清"网页版到底走了哪一步、能不能进 2FA"）。
 *
 * ## 为什么需要
 * 半模态 2FA 面板提交后到底发生了什么，光看我们自己的日志分不清：
 *   · IG 的网页登录接口有没有真的返回"要两步验证"？
 *   · 页面里的 `fetch`/XHR 打到了哪些地址、回了什么？
 *   · 页面上到底有没有验证码输入框（还是停在登录页 / 被 checkpoint 拦住）？
 * 这些都在**网页侧**，必须从页面里读出来。
 *
 * ## 抓什么（每次 `snapshot` 一行 JSON）
 *   `label`  调用点名字（`ajax-v0` / `after-form` / `before-2fa` …）
 *   `url` / `title`   页面当前位置
 *   `inputs`  输入框数量、`code` = 有没有验证码框、`user`/`pwd` = 有没有账号密码框
 *   `btns`    按钮文案（前 3 个，各 20 字）
 *   `text`    可见文字前 200 字（IG 会把失败原因写在这里）
 *   `api`     页面自己发出的、与登录/验证有关的请求（最近 8 条：url + status + body 前 200 字）
 *
 * ## 怎么取
 * 只有 `hilog`（tag **LoginTrace**），按 800 字分块打印，整行不会因为过长被系统吃掉：
 * ```
 * hdc -t <id> shell "hilog -x | grep LoginTrace"
 * ```
 * 取之前先 `hilog -r` 清一次缓冲，再复现一次登录，能保证这次的内容都在。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';

const DOMAIN: number = 0xFF00;
const TAG: string = 'LoginTrace';

export class LoginTrace {
  /** 一轮登录里的所有行（也用于 `tail()` 直接回给界面/日志）。 */
  private static lines: Array<string> = [];

  /**
   * 抓一次现场（幂等注入页面钩子，读回快照）。
   *
   * @param bridge 隐藏网页的桥
   * @param label  调用点（写进日志，便于按顺序读）
   */
  static async snapshot(bridge: InstagramPageBridge, label: string): Promise<void> {
    try {
      // 1) 注入网络钩子（只注一次，重复调用返回 hooked）
      await bridge.runScript(LoginTrace.HOOK_JS);
      // 2) 读快照
      const raw: string = await bridge.runScript(LoginTrace.SNAPSHOT_JS);
      LoginTrace.push(`[${label}] ${raw}`);
    } catch (error) {
      LoginTrace.push(`[${label}] snapshot failed: ${(error as Error).message}`);
    }
  }

  /** 记一行（分块进 hilog，避免单条被截断）。 */
  static push(line: string): void {
    LoginTrace.lines.push(line);
    const chunk: number = 800;
    for (let at: number = 0; at < line.length; at += chunk) {
      const end: number = at + chunk < line.length ? at + chunk : line.length;
      hilog.info(DOMAIN, TAG, '%{public}s', line.substring(at, end));
    }
  }

  /** 本轮已抓到的行（诊断面板/排查时可以直接读）。 */
  static tail(): Array<string> {
    return LoginTrace.lines;
  }

  /** 清空（每次登录开始时调一次，避免上一轮的内容混进来）。 */
  static reset(): void {
    LoginTrace.lines = [];
    LoginTrace.push('--- trace start ---');
  }

  /**
   * 页面钩子：把**页面自己发的** fetch/XHR 记进 `window.__igTrace`。
   *
   * 只记与登录/验证/挑战有关的地址，别把整页流量灌进来。
   */
  private static readonly HOOK_JS: string =
    '(function(){if(window.__igTraceHook){return "hooked";}window.__igTraceHook=1;window.__igTrace=[];'
    + 'function keep(u){u=String(u||"");return /login|two_factor|challenge|checkpoint|accounts/.test(u);}'
    + 'function rec(u,s,b){try{window.__igTrace.push({u:String(u||"").slice(0,200),s:String(s||""),b:String(b||"").slice(0,200)});'
    + 'if(window.__igTrace.length>12){window.__igTrace.shift();}}catch(e){}}'
    + 'var of=window.fetch;if(of){window.fetch=function(i,o){var u=(typeof i==="string")?i:(i&&i.url)||"";'
    + 'return of.apply(this,arguments).then(function(r){if(keep(u)){try{var c=r.clone();c.text().then(function(t){rec(u,r.status,t);});'
    + '}catch(e){rec(u,r.status,"");}}return r;});};}'
    + 'var oo=window.XMLHttpRequest&&window.XMLHttpRequest.prototype.open;'
    + 'var os=window.XMLHttpRequest&&window.XMLHttpRequest.prototype.send;'
    + 'if(oo&&os){window.XMLHttpRequest.prototype.open=function(m,u){this.__u=u;return oo.apply(this,arguments);};'
    + 'window.XMLHttpRequest.prototype.send=function(){var x=this;if(keep(x.__u)){x.addEventListener("load",function(){'
    + 'rec(x.__u,x.status,x.responseText||"");});}return os.apply(this,arguments);};}'
    + 'return "hooked";})()';

  /** 读快照（JSON 一行）。 */
  private static readonly SNAPSHOT_JS: string =
    '(function(){var out={url:(location&&location.href||"").slice(0,200),'
    + 'title:(document.title||"").slice(0,80),inputs:0,code:0,user:0,pwd:0,btns:[],text:"",api:[]};'
    + 'var i=document.querySelectorAll("input");out.inputs=i.length;'
    + 'for(var k=0;k<i.length;k++){var t=(i[k].type||"").toLowerCase();'
    + 'var n=((i[k].name||"")+" "+(i[k].id||"")+" "+(i[k].getAttribute("autocomplete")||"")).toLowerCase();'
    + 'if(t==="tel"||t==="number"||/code|verif|otp|security|confirm/.test(n)||i[k].maxLength===6){out.code=1;}'
    + 'if(t==="text"||/user|email|username/.test(n)){out.user=1;}'
    + 'if(t==="password"){out.pwd=1;}}'
    + 'var b=document.querySelectorAll("button,div[role=button],span[role=button]");'
    + 'for(var j=0;j<b.length&&out.btns.length<3;j++){var tx=(b[j].innerText||"").trim();if(tx){out.btns.push(tx.slice(0,20));}}'
    + 'try{out.text=(document.body&&document.body.innerText||"").replace(/\\s+/g," ").slice(0,200);}catch(e){}'
    + 'out.api=(window.__igTrace||[]).slice(-8);'
    + 'return JSON.stringify(out);})()';
}
