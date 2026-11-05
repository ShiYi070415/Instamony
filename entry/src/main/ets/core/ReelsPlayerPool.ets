/*
 * **Reels 播放器预算池**：进程内同时活着的 AVPlayer 上限 + 全局串行创建。
 *
 * 真机崩溃结论：多个 AVPlayer 并发创建/持有解码器会让原生层直接 ABORTED。
 * 这里只做预算，不持有 AVPlayer 实例；实例仍归 VideoSurface。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsPlayerPool';

export class ReelsPlayerPool {
  /** 预加载玩家最多允许多少个活着的播放器。 */
  static readonly MAX_ALIVE_FOR_PRELOAD: number = 1;

  private static alive: number = 0;
  private static pending: number = 0;
  private static creating: boolean = false;

  static aliveCount(): number {
    return ReelsPlayerPool.alive;
  }

  static pendingCount(): number {
    return ReelsPlayerPool.pending;
  }

  static budget(): number {
    return ReelsPlayerPool.alive + ReelsPlayerPool.pending;
  }

  static shouldSkipPreload(preloadOnly: boolean): boolean {
    return preloadOnly && ReelsPlayerPool.budget() >= ReelsPlayerPool.MAX_ALIVE_FOR_PRELOAD;
  }

  static isCreating(): boolean {
    return ReelsPlayerPool.creating;
  }

  /** 开始创建：返回 false 表示已有创建在飞，调用方应稍后重试。 */
  static beginCreate(): boolean {
    if (ReelsPlayerPool.creating) {
      return false;
    }
    ReelsPlayerPool.creating = true;
    ReelsPlayerPool.pending++;
    return true;
  }

  /** 创建结束（成功/失败都要调）。 */
  static endCreate(): void {
    ReelsPlayerPool.creating = false;
    if (ReelsPlayerPool.pending > 0) {
      ReelsPlayerPool.pending--;
    }
  }

  static noteCreated(url: string): void {
    ReelsPlayerPool.alive++;
    if (ReelsPlayerPool.alive >= 3) {
      hilog.warn(DOMAIN, TAG, 'players alive=%{public}d url=%{public}s',
        ReelsPlayerPool.alive, url);
    }
  }

  static noteReleased(url: string): void {
    if (ReelsPlayerPool.alive > 0) {
      ReelsPlayerPool.alive--;
    }
    if (ReelsPlayerPool.alive >= 3) {
      hilog.warn(DOMAIN, TAG, 'players still alive=%{public}d after release url=%{public}s',
        ReelsPlayerPool.alive, url);
    }
  }
}
