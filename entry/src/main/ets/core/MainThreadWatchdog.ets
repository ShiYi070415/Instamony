/*
 * **主线程卡顿看门狗**（诊断用，成本极低）。
 *
 * ## 为什么需要它
 * `AppFreeze`（系统弹「应用无响应」）的判据是"主线程被占住 6 秒以上"。用户能看到的现象很明确，
 * 但事后没有任何办法知道"是哪一个操作把主线程按住"：系统的 faultlog 在
 * `/data/log/faultlog/faultlogger`（普通 shell 读不到），hilog 缓冲区也早就滚过去了。
 * 于是唯一的办法是**自己记**：在主线程上挂一个 100ms 的定时器，一旦某一拍迟到，就说明
 * 这一拍之前的那段代码把主线程占住了，迟到多久就是占住多久。
 *
 * ## 能给出什么
 * 一行 `main blocked <N>ms`，带时间戳。配合同时段的业务日志（哪个页面、哪个请求刚回来），
 * 就能把"卡了 6 秒"落到具体函数上 —— 这比猜有效得多。
 *
 * ## 为什么这样测是准的
 * ArkTS 的定时器和 UI 事件在**同一个主线程**上排队：主线程一被同步代码占住，定时器回调就
 * 不会被调度，恢复后的第一拍会带着"欠下的时间"一起到。所以 `实际间隔 - 应有间隔` 就是
 * 主线程被占住的时长（误差是调度抖动，几十毫秒量级，远小于我们关心的秒级）。
 *
 * 另外**不要把它当成修复**：它只是让下一次卡顿变成一条可读的证据。真凶要靠这条证据去定位。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLifecycle } from './AppLifecycle';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MainThreadWatchdog';

/** 心跳间隔（毫秒）。太小会白耗电，太大会漏掉短卡顿。 */
const TICK_MS: number = 100;
/** 迟到多少毫秒就算"主线程被占住"（低于此值是正常调度抖动）。 */
const BLOCK_MS: number = 800;
/** 两次报告之间的最小间隔（毫秒）：卡顿时日志本身也会排队，别自己把日志刷满。 */
const REPORT_GAP_MS: number = 3000;

export class MainThreadWatchdog {
  private static timer: number = -1;
  private static lastTick: number = 0;
  private static lastReport: number = 0;
  /** 本次运行里最长的一次卡顿（毫秒），退出时打一行总结。 */
  private static worstMs: number = 0;
  /** 累计报告次数。 */
  private static blockedCount: number = 0;
  /**
   * 应用是否在前台。
   *
   * **必须判这个**：进后台后系统会**冻结整个进程**（`SUSPEND_MANAGER` 的 freeze/thaw，
   * 省电机制），所有线程都停住，心跳那一拍自然"迟到"几十秒 —— 那是挂起，不是卡顿。
   * 早期版本没判，于是后台放一会儿再回来就报一条"main blocked 24241ms"，纯属误报。
   */
  private static foreground: boolean = true;
  /** 前后台监听是否已挂（幂等）。 */
  private static watchingVisibility: boolean = false;
  /**
   * 超过这个量的"迟到"一律当成进程被挂起（而不是主线程卡顿）。
   *
   * ArkTS 里 6 秒就够系统报 AppFreeze 了；真超过一分钟的"卡顿"只可能是整个进程没在跑。
   */
  private static readonly SUSPEND_GAP_MS: number = 60000;

  /** 开始监测（幂等）。 */
  static start(): void {
    if (MainThreadWatchdog.timer >= 0) {
      return;
    }
    MainThreadWatchdog.watchVisibility();
    MainThreadWatchdog.lastTick = Date.now();
    MainThreadWatchdog.lastReport = 0;
    MainThreadWatchdog.timer = setInterval((): void => {
      MainThreadWatchdog.tick();
    }, TICK_MS);
    hilog.info(DOMAIN, TAG, 'watchdog started tick=%{public}dms threshold=%{public}dms',
      TICK_MS, BLOCK_MS);
  }

  /** 监听前后台：切到后台就把判据重置，回来的第一拍不算迟到（见 foreground 的说明）。 */
  private static watchVisibility(): void {
    if (MainThreadWatchdog.watchingVisibility) {
      return;
    }
    MainThreadWatchdog.watchingVisibility = true;
    AppLifecycle.addVisibilityListener((foreground: boolean): void => {
      MainThreadWatchdog.foreground = foreground;
      // 无论进出，都把基准时间重新锚定：跨越前后台的那一段不算"主线程被占住"。
      MainThreadWatchdog.lastTick = Date.now();
    });
  }

  /** 停止监测（页面销毁时调）。 */
  static stop(): void {
    if (MainThreadWatchdog.timer >= 0) {
      clearInterval(MainThreadWatchdog.timer);
      MainThreadWatchdog.timer = -1;
      hilog.info(DOMAIN, TAG, 'watchdog stopped worst=%{public}dms count=%{public}d',
        MainThreadWatchdog.worstMs, MainThreadWatchdog.blockedCount);
    }
  }

  /**
   * 手动上报一次"从 mark 到现在花了多久"（给怀疑的同步重活包一层用）。
   *
   * 与心跳互补：心跳能测到卡顿，但测不到"是哪一段"；关键路径上手动量一下就能对上号。
   */
  static measure(label: string, startedAt: number): void {
    const cost: number = Date.now() - startedAt;
    if (cost >= BLOCK_MS) {
      hilog.warn(DOMAIN, TAG, 'slow span %{public}s took %{public}dms', label, cost);
    }
  }

  private static tick(): void {
    const now: number = Date.now();
    const gap: number = now - MainThreadWatchdog.lastTick;
    MainThreadWatchdog.lastTick = now;
    // 后台只更新基准，不判（系统冻结进程会让每一拍都"迟到"，见 foreground 的说明）。
    if (!MainThreadWatchdog.foreground || gap > MainThreadWatchdog.SUSPEND_GAP_MS) {
      return;
    }
    // 丢掉的时长 = 实际间隔 - 应有间隔。多出来的那部分就是主线程被别的同步代码占住的时间。
    const blocked: number = gap - TICK_MS;
    if (blocked < BLOCK_MS) {
      return;
    }
    MainThreadWatchdog.blockedCount++;
    if (blocked > MainThreadWatchdog.worstMs) {
      MainThreadWatchdog.worstMs = blocked;
    }
    if (now - MainThreadWatchdog.lastReport < REPORT_GAP_MS) {
      return;
    }
    MainThreadWatchdog.lastReport = now;
    hilog.warn(DOMAIN, TAG, 'main blocked %{public}dms (gap=%{public}dms) worst=%{public}dms',
      blocked, gap, MainThreadWatchdog.worstMs);
  }
}
