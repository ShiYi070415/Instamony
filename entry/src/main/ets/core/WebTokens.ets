/*
 * 页面会话令牌：**按需读取**（不再"等用户先做一次动作"去抓模板）。
 *
 * ## 为什么需要它
 * IG 的写类接口（点赞 / 取消赞 / 转发 / 取消转发 / ayml）除了 Cookie + `x-csrftoken`，
 * 还要一串**每次页面加载都会变**的值：
 *   `lsd`、`fb_dtsg`、`jazoest`、`__rev`(=x-instagram-ajax)、`__hsi`、`__hs`、`__dyn`、`__csr`、`__s`
 * 以及账号自己的 id（请求体里的 `av` / `input.actor_id`）。
 *
 * 以前的唯一来源是"页面自己发过一次同类请求 → 把那条请求存成模板"，代价是**新装或换会话后
 * 必须先手动做一次同类动作**（第一次点赞走网页、通知页首次要导航活动页抓 ayml）。
 *
 * 真机探针（.tmp/tokendiag3.txt）确认这些值可以**只读地**从当前页面拿到：
 *   `require("LSD").token`、`require("DTSGInitialData").token`、
 *   `require("SiteData").server_revision / .hsi`，
 *   整页指纹（__hs/__dyn/__csr/__s）在页面自己发过的请求 URL 里（performance 资源表）；
 *   `jazoest` 是**算出来的**：`"2" + fb_dtsg 各字符码之和`（两个真实样本都验过）；
 *   账号 id 就在 Cookie 罐的 `ds_user_id` 里（原生直接读，不经页面）。
 *
 * ## 缓存
 * 这些值跟着**一次页面加载**走，所以缓存很轻：拿到就存内存，页面重载（路由变化/loadUrl）
 * 时 `invalidate()` 清掉，下次用之前再读一遍（一条几毫秒的脚本）。
 *
 * 任何一步失败都只是"这次用不了快路"，调用方照旧回退到抓模板那条路 —— 这里绝不抛异常。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramPageBridge } from '../bridge/PageBridge';
import { PAGE_TOKENS_SCRIPT } from '../bridge/WebScripts';
import { InstagramCookieJar, InstagramCookieSnapshot } from './InstagramCookieJar';

const DOMAIN: number = 0xFF00;
const TAG: string = 'WebTokens';
/** 读一次页面令牌的超时（毫秒）。它就是一条同步脚本，正常几十毫秒。 */
const TOKEN_TIMEOUT_MS: number = 6000;

/** 页面侧回报的原始字段（都可能是空串）。 */
interface PageTokenPayload {
  ok?: number;
  lsd?: string;
  dtsg?: string;
  rev?: string;
  hsi?: string;
  spin?: string;
  spinb?: string;
  url?: string;
}

export class WebTokens {
  private static lsd: string = '';
  private static dtsg: string = '';
  private static rev: string = '';
  private static hsi: string = '';
  private static spinB: string = 'trunk';
  private static hs: string = '';
  private static dyn: string = '';
  private static csr: string = '';
  private static s: string = '';
  private static ready: boolean = false;
  private static reading: boolean = false;

  /**
   * 确保这一轮页面加载的令牌已经读到（已读过就直接返回 true）。
   *
   * @param force 页面重载后强制重读（一般由 invalidate() 处理，这里留着给"怀疑过期"的场合）。
   */
  static async ensure(force: boolean = false): Promise<boolean> {
    if (WebTokens.ready && !force) {
      return true;
    }
    if (WebTokens.reading) {
      // 并发调用（比如同时点赞两条）：等第一次读完就行，不重复过桥。
      for (let i: number = 0; i < 30 && WebTokens.reading; i++) {
        await WebTokens.delay(100);
      }
      return WebTokens.ready;
    }
    WebTokens.reading = true;
    try {
      const raw: string = await InstagramPageBridge.getInstance()
        .runBridge(PAGE_TOKENS_SCRIPT, TOKEN_TIMEOUT_MS, 'page-tokens');
      const data: PageTokenPayload = JSON.parse(raw) as PageTokenPayload;
      WebTokens.lsd = (data.lsd ?? '').trim();
      WebTokens.dtsg = (data.dtsg ?? '').trim();
      WebTokens.rev = (data.rev ?? '').trim();
      WebTokens.hsi = (data.hsi ?? '').trim();
      WebTokens.spinB = (data.spinb ?? 'trunk').trim();
      WebTokens.readUrl(data.url ?? '');
      // lsd + dtsg + rev 是写请求的硬门槛；缺任何一样就当没读到（照旧回退抓模板）。
      WebTokens.ready = WebTokens.lsd.length > 0 && WebTokens.dtsg.length > 0
        && WebTokens.rev.length > 0;
      hilog.info(DOMAIN, TAG,
        'page tokens ready=%{public}s lsd=%{public}d dtsg=%{public}d rev=%{public}s hs=%{public}d dyn=%{public}d csr=%{public}d',
        `${WebTokens.ready}`, WebTokens.lsd.length, WebTokens.dtsg.length,
        WebTokens.rev, WebTokens.hs.length, WebTokens.dyn.length, WebTokens.csr.length);
      return WebTokens.ready;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read page tokens failed: %{public}s', (error as Error).message);
      return false;
    } finally {
      WebTokens.reading = false;
    }
  }

  /** 页面重载/换路由时调用：这些值跟着**一份文档**走，文档换了就作废。 */
  static invalidate(): void {
    WebTokens.ready = false;
  }

  static isReady(): boolean {
    return WebTokens.ready;
  }

  static lsdValue(): string {
    return WebTokens.lsd;
  }

  static dtsgValue(): string {
    return WebTokens.dtsg;
  }

  static revValue(): string {
    return WebTokens.rev;
  }

  static hsiValue(): string {
    return WebTokens.hsi;
  }

  static spinBValue(): string {
    return WebTokens.spinB;
  }

  static hsValue(): string {
    return WebTokens.hs;
  }

  static dynValue(): string {
    return WebTokens.dyn;
  }

  static csrValue(): string {
    return WebTokens.csr;
  }

  static sValue(): string {
    return WebTokens.s;
  }

  /**
   * `jazoest`：FB 的 Sprinkle 参数，**算法就是 "2" + fb_dtsg 的字符码之和**
   * （用两个真机抓到的 fb_dtsg/jazoest 样本核对过：6197 → 26197）。
   */
  static jazoest(): string {
    return WebTokens.jazoestOf(WebTokens.dtsg);
  }

  /** 见 jazoest 的说明。 */
  static jazoestOf(dtsg: string): string {
    let sum: number = 0;
    for (let i: number = 0; i < dtsg.length; i++) {
      sum += dtsg.charCodeAt(i);
    }
    return `2${sum}`;
  }

  /**
   * 当前账号在 IG 里的数字 id（请求体里的 `av` / `input.actor_id`）。
   *
   * 直接读 Cookie 罐的 `ds_user_id`：网页每次请求也带它，和接口里的 actor_id 是同一个值
   * （真机核对：cookie ds_user_id=12345678901，转发变更里 actor_id=12345678901）。
   */
  static async actorId(): Promise<string> {
    try {
      const jar: InstagramCookieSnapshot = await InstagramCookieJar.inspect();
      const cookie: string = jar.cookie ?? '';
      const parts: Array<string> = cookie.split(';');
      for (let i: number = 0; i < parts.length; i++) {
        const one: string = parts[i].trim();
        if (one.indexOf('ds_user_id=') === 0) {
          return one.substring('ds_user_id='.length).trim();
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'read ds_user_id failed: %{public}s', (error as Error).message);
    }
    return '';
  }

  /** 从页面自己发过的请求 URL 里取整页指纹（`__hs/__dyn/__csr/__s/__rev/__hsi`）。 */
  private static readUrl(url: string): void {
    WebTokens.hs = WebTokens.paramOf(url, '__hs');
    WebTokens.dyn = WebTokens.paramOf(url, '__dyn');
    WebTokens.csr = WebTokens.paramOf(url, '__csr');
    WebTokens.s = WebTokens.paramOf(url, '__s');
    const rev: string = WebTokens.paramOf(url, '__rev');
    if (rev.length > 0) {
      WebTokens.rev = rev;
    }
    const hsi: string = WebTokens.paramOf(url, '__hsi');
    if (hsi.length > 0) {
      WebTokens.hsi = hsi;
    }
  }

  /** 取 URL 查询串里某个参数（已解码）。 */
  private static paramOf(url: string, name: string): string {
    const at: number = url.indexOf(`${name}=`);
    if (at < 0) {
      return '';
    }
    const start: number = at + name.length + 1;
    const end: number = url.indexOf('&', start);
    const raw: string = end < 0 ? url.substring(start) : url.substring(start, end);
    try {
      return decodeURIComponent(raw);
    } catch (error) {
      return raw;
    }
  }

  private static delay(ms: number): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void): void => {
      setTimeout((): void => {
        resolve('done');
      }, ms);
    });
  }
}
