/*
 * **首页时间线能不能走移动端**的一次性实验。
 *
 * ## 为什么单独做实验
 * instagrapi 里**没有**首页时间线（`__init__.py` 只 import 了 `ReelsMixin`，没有 timeline 相关
 * mixin；`feed/timeline/` 这个端点它一次都没用）。我们现在的首页信息流是"网页 GraphQL 模板回放"
 * 拿到的 —— 也就是说最后一块还依赖抓包的地方正是它。
 * 所以先回答一个问题：**用 App 身份还能不能打 `feed/timeline/`？**
 *   · 能 → 首页也能迁到移动端，模板库可以整体下线；
 *   · 不能（4xx/空）→ 首页保留模板回放，把抓包窗口收窄成"只为主页那一条"。
 *
 * ## 怎么读数
 * 日志在这台设备上偶发整进程无输出，所以结论直接**弹到屏幕上**（截图可读），
 * 每行一个候选端点：`名字 http=… bytes=… keys=…`。
 *
 * ## 实测结论（2026-10-21，模拟器）
 *   `tl-get  feed/timeline/          http=405 bytes=50`     ← GET 不允许（Method Not Allowed）
 *   `tl-post feed/timeline/ (POST)   http=200 bytes=253297`  ← **通了**
 *   `tl-stream feed/timeline/stream/ http=404`               ← 不存在
 * 也就是说：**首页时间线在移动端是"POST + 查询串参数"**，只是 instagrapi 从来没实现它
 * （它的 `__init__.py` 里只有 `ReelsMixin`，没有 timeline mixin）。
 * 结论：feed 也能迁出来 —— 迁完之后模板库与页面抓包钩子就可以整段删除。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from '../ApiThrottle';
import { MobileRequest, MobileResult, MobileOptions } from './MobileRequest';
import { MobileSession, MobileIdentity } from './MobileSession';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileFeedProbe';

/** 一个候选端点的结论。 */
export class FeedProbeLine {
  readonly name: string;
  readonly http: number;
  readonly bytes: number;
  /** 响应里认出来的"时间线"键（能认出就说明这条能用）。 */
  readonly keys: string;

  constructor(name: string, http: number, bytes: number, keys: string) {
    this.name = name;
    this.http = http;
    this.bytes = bytes;
    this.keys = keys;
  }

  text(): string {
    return `${this.name} http=${this.http} bytes=${this.bytes} keys=${this.keys}`;
  }
}

export class MobileFeedProbe {
  /** 只跑一次。 */
  private static ran: boolean = false;

  /**
   * 依次试几个候选，返回每条的结论。
   *
   * 候选说明：
   *   ① `feed/timeline/`          —— IG App 首页最常用的那条（带一批客户端参数）
   *   ② `feed/timeline/stream/`   —— 流式版本（少数版本用它）
   *   ③ `feed/new_feed_posts_exist/` —— 轻量存在性检查（能 200 就说明 App 身份对 feed 域是通的）
   */
  static async run(): Promise<Array<FeedProbeLine>> {
    if (MobileFeedProbe.ran) {
      return [];
    }
    MobileFeedProbe.ran = true;
    const out: Array<FeedProbeLine> = [];
    const identity: MobileIdentity | null = await MobileSession.getInstance().ensure();
    if (identity === null) {
      hilog.info(DOMAIN, TAG, 'probe skipped: no session');
      return out;
    }
    /*
     * 参数照 IG App 首页那一发（`reason=pull_to_refresh` 是拉最新；其余是客户端上下文）。
     * `timezone_offset` 用真机的（身份自洽，见 MobileConfig.COHERENT_FINGERPRINT 的做法）。
     */
    const tz: number = identity.timezoneOffset;
    const common: string = `reason=pull_to_refresh&is_prefetch=false&max_id=`
      + `&feed_view_info=[]&seen_posts=&phone_id=${encodeURIComponent(identity.phoneId)}`
      + `&is_pull_to_refresh=false&battery_level=100&timezone_offset=${tz}`
      + `&is_charging=0&will_sound_on=0&includes_soft_bounce_stories=true`
      + `&auto_refresh=true&is_shelf_life_enabled=true`;
    out.push(await MobileFeedProbe.tryOne('tl-get', 'feed/timeline/', common, ''));
    /*
     * `feed/timeline/` 用 GET 回 **405 Method Not Allowed**（实测）—— 说明这条要 **POST**。
     * 与 clips 那条一样：体里给一个空格强制 POST，参数仍在查询串里。
     */
    out.push(await MobileFeedProbe.tryOne('tl-post', 'feed/timeline/', common, ' '));
    out.push(await MobileFeedProbe.tryOne('tl-stream', 'feed/timeline/stream/', common, ' '));
    out.push(await MobileFeedProbe.tryOne('new_posts', 'feed/new_feed_posts_exist/', '', ''));
    for (let index: number = 0; index < out.length; index++) {
      hilog.info(DOMAIN, TAG, '%{public}s', out[index].text());
    }
    return out;
  }

  private static async tryOne(name: string, endpoint: string, params: string,
                              body: string): Promise<FeedProbeLine> {
    /*
     * **硬超时**：这条实验最怕"某一发挂住把整串拖死"（那样屏幕上一个字都看不到）。
     * 12 秒还没回来就按超时结论输出，继续下一发。
     */
    const pending: Promise<FeedProbeLine> = MobileFeedProbe.request(name, endpoint, params, body);
    const timeout: Promise<FeedProbeLine> = new Promise<FeedProbeLine>(
      (resolve: (line: FeedProbeLine) => void): void => {
        setTimeout((): void => {
          resolve(new FeedProbeLine(name, -1, 0, 'timeout'));
        }, 12000);
      });
    return await Promise.race([pending, timeout]);
  }

  private static async request(name: string, endpoint: string, params: string,
                               body: string): Promise<FeedProbeLine> {
    const result: MobileResult = await MobileRequest.send(
      endpoint, body, params, true, null,
      new MobileOptions(ApiThrottle.MOBILE, ApiThrottle.warm()));
    return new FeedProbeLine(name, result.code, result.bytes,
      result.ok ? MobileFeedProbe.keysOf(result.body) : `err=${result.error}`);
  }

  /** 响应里有没有时间线的特征键（`feed_items` / `items` / `num_results` …）。 */
  private static keysOf(body: string): string {
    const out: Array<string> = [];
    const checks: Array<string> = ['"feed_items"', '"items"', '"more_available"',
      '"next_max_id"', '"num_results"', '"status":"ok"'];
    for (let index: number = 0; index < checks.length; index++) {
      if (body.indexOf(checks[index]) >= 0) {
        out.push(checks[index].replace(/"/g, ''));
      }
    }
    return out.length > 0 ? out.join(',') : 'none';
  }
}
