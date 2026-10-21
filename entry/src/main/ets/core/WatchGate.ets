/*
 * **网页抓包闸门**：决定"现在要不要在页面里钩 fetch/XHR"。
 *
 * ## 为什么需要它
 * 页面里那套 `NETWORK_WATCHER` 会包住 `fetch` / `XMLHttpRequest` 并记录请求配置
 * （回放用）。它是这个项目"原生自己取数"的地基，但**同时也是一个很明显的自动化痕迹**：
 * 任何一段页面脚本都能看出 `fetch` 不是原生的。之前它在**每个文档加载时都装**，
 * 也就是说不管用户在看什么，网页里永远挂着一层钩子。
 *
 * ## 现在的做法
 * 只在**真的要抓模板**的那几秒打开（见 `arm()` 的调用点），抓到就关：
 *   · 页面脚本在 document-start 时通过 `ogNative.shouldWatch()` **同步**问一句
 *     "这次要不要装"（同步很关键：必须在页面自己发请求之前决定）；
 *   · 原生这里只是记一个"截止时刻"，判断是纯内存操作。
 *
 * 读数写进日志（`arm/expire` 各一行），方便确认"钩子只在少数时刻存在"。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'WatchGate';

export class WatchGate {
  /** 闸门打开的截止时刻（0 = 关闭）。 */
  private static until: number = 0;
  /** 为什么打开（日志用）。 */
  private static reason: string = '';

  /**
   * 打开抓包窗口。
   *
   * @param ms     窗口长度（毫秒）。默认 90 秒：一次"导航 + 等页面自己发请求"够用了。
   * @param reason 原因（`cold-start` / `ayml` / `story` / `probe` …，日志里能看出是谁要的）
   */
  static arm(ms: number = 90000, reason: string = '-'): void {
    const until: number = Date.now() + ms;
    // 只延长、不缩短：多个调用点同时要，别让后一个把窗口关掉。
    if (until <= WatchGate.until) {
      return;
    }
    WatchGate.until = until;
    WatchGate.reason = reason;
    hilog.info(DOMAIN, TAG, 'arm %{public}dms reason=%{public}s', ms, reason);
  }

  /** 抓到了就提前关掉（少挂一会儿是一会儿）。 */
  static disarm(reason: string = '-'): void {
    if (WatchGate.until <= 0) {
      return;
    }
    WatchGate.until = 0;
    WatchGate.reason = '';
    hilog.info(DOMAIN, TAG, 'disarm reason=%{public}s', reason);
  }

  /** 现在要不要在页面里装钩子（页面 document-start 时**同步**调一次）。 */
  static armed(): boolean {
    if (WatchGate.until <= 0) {
      return false;
    }
    if (Date.now() >= WatchGate.until) {
      WatchGate.until = 0;
      WatchGate.reason = '';
      return false;
    }
    return true;
  }

  /** 状态一行（诊断用）。 */
  static describe(): string {
    if (!WatchGate.armed()) {
      return 'watch=off';
    }
    const left: number = Math.max(0, WatchGate.until - Date.now());
    return `watch=on ${Math.ceil(left / 1000)}s reason=${WatchGate.reason}`;
  }
}
