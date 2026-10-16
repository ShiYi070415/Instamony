/*
 * 私信会话消息的**后台预取队列**。
 *
 * ## 需求（用户原话）
 * "切换到私信列表时预取当前私信列表的所有会话消息，每个会话 5 条……
 *  私信列表刷新时预取新刷新出来的会话。"
 *
 * ## 设计取舍
 *   · **串行、一发一收**（不并发）：私信那一族的限流额度最紧，而预取本来就是后台行为。
 *     全局闸门（`ApiThrottle`）也会把它串起来，这里不再自己造并发。
 *   · **优先级 idle**：排在"用户此刻点的"和"首屏要用的"后面 —— 预取绝不能挡住点开会话。
 *   · **跳过新鲜的**：`DirectCache.isFresh` 命中就不发请求，于是"列表刷新"这一动作
 *     只会为**新出现**或**过期**的那几条真的打接口（用户要的正是这个增量语义）。
 *   · **可取消**：列表刷新会重新 `seed`，代次一变旧队列立刻作废（正在飞的那一发回来也不写缓存，
 *     免得把上一份列表的会话塞回新队列）。
 *   · **不重试**：一条失败就跳过（记一行日志），让下一轮列表刷新再补 —— 预取失败不该
 *     在后台反复打接口。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from './ApiThrottle';
import { CACHE_MESSAGES, DirectCache } from './DirectCache';
import { DirectThread, DirectThreadView } from '../model/Direct';
import { NativeDirect } from './NativeDirect';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectPrefetch';
/** 快照多久算新鲜（毫秒）：这个窗口内不再为同一条会话发预取请求。 */
const FRESH_MS: number = 10 * 60 * 1000;
/** 一轮最多预取几条（列表很长时别把后台占满；多出来的等下一轮/滚动时再补）。 */
const MAX_PER_ROUND: number = 24;

export class DirectPrefetch {
  private static queue: Array<DirectThread> = [];
  private static running: boolean = false;
  private static generation: number = 0;
  /** 正在路上的那条会话 id（空串 = 没有）。见 seed 里"不要重复入队"那段。 */
  private static inflightId: string = '';
  /**
   * 最近一次 `seed` 交进来的那页会话（当前列表）。
   *
   * 用途只有一个：**被当成陈旧结果丢掉的那一条要能补回来**。
   * 场景：列表刷新（代次 +1）时上一代那一发还在飞 —— 它回来时结果不留，
   * 但它在**新**那一轮里已经被算作"正在飞"而没入队，于是这一条就永远没有快照了
   * （真机实测：第一条会话就这么漏掉，点开它没有首屏缓存）。
   * 所以丢掉时按这份列表把它重新排到队头补一发。
   */
  private static currentList: Array<DirectThread> = [];
  /** 本轮统计（日志/诊断用）。 */
  private static done: number = 0;
  private static skipped: number = 0;
  private static failed: number = 0;

  /**
   * 把一页会话交给预取（列表拉到 / 刷新后调）。
   *
   * **增量语义**：已经在队列里、**正在路上**、或快照还新鲜的，一律不进队列 ——
   * 所以"下拉刷新"通常只会为刚冒出来的那几条新会话发请求。
   */
  static seed(threads: Array<DirectThread>): void {
    DirectPrefetch.generation = DirectPrefetch.generation + 1;
    DirectPrefetch.currentList = threads;
    DirectPrefetch.queue = [];
    DirectPrefetch.done = 0;
    DirectPrefetch.skipped = 0;
    DirectPrefetch.failed = 0;
    let fresh: number = 0;
    let flying: number = 0;
    for (let index: number = 0; index < threads.length; index++) {
      const one: DirectThread = threads[index];
      if (one.id.length === 0) {
        continue;
      }
      if (DirectCache.isFresh(one.id, FRESH_MS)) {
        fresh++;
        continue;
      }
      /*
       * **正在路上的那条不要重复入队**。
       *
       * 这一条是本模块最容易踩的坑：`seed` 在列表刷新时会被再调一次（代次 +1），
       * 而上一代那一发**已经发出去了、取消不了** —— 如果不管它，同一个会话会被发两遍；
       * 更糟的是闸门是串行的，重复的那一发会把后面真正要用的顶后一秒多。
       */
      if (one.id === DirectPrefetch.inflightId) {
        flying++;
        continue;
      }
      if (DirectPrefetch.queue.length >= MAX_PER_ROUND) {
        break;
      }
      DirectPrefetch.queue.push(one);
    }
    hilog.info(DOMAIN, TAG,
      'seed threads=%{public}d queued=%{public}d fresh=%{public}d flying=%{public}d cache=%{public}s',
      threads.length, DirectPrefetch.queue.length, fresh, flying, DirectCache.describe());
    // 上一代那一发还在飞时 `pump` 会直接返回 —— 它回来时会接着把新队列推下去（见 pump 里那条路径）。
    DirectPrefetch.pump();
  }

  /** 停掉当前队列（退出登录 / 页面销毁时调）。 */
  static cancel(): void {
    DirectPrefetch.generation = DirectPrefetch.generation + 1;
    DirectPrefetch.queue = [];
    DirectPrefetch.running = false;
  }

  /** 一行进度（日志/诊断用）。 */
  static describe(): string {
    return `prefetch queue=${DirectPrefetch.queue.length} running=${DirectPrefetch.running ? 'y' : 'n'}`
      + ` done=${DirectPrefetch.done} fail=${DirectPrefetch.failed}`
      + ` inflight=${DirectPrefetch.inflightId.length > 0 ? 'y' : 'n'}`;
  }

  /** 是否正在预取（界面可以据此决定要不要显示"预热中"）。 */
  static isRunning(): boolean {
    return DirectPrefetch.running;
  }

  /** 把某条会话补回队头（前提：它还在当前列表里、且还没有新鲜快照）。 */
  private static requeue(threadId: string): void {
    if (DirectCache.isFresh(threadId, FRESH_MS)) {
      return;
    }
    for (let index: number = 0; index < DirectPrefetch.queue.length; index++) {
      if (DirectPrefetch.queue[index].id === threadId) {
        return;
      }
    }
    for (let index: number = 0; index < DirectPrefetch.currentList.length; index++) {
      const one: DirectThread = DirectPrefetch.currentList[index];
      if (one.id === threadId) {
        DirectPrefetch.queue.unshift(one);
        hilog.info(DOMAIN, TAG, 'requeue after stale drop id=%{public}s q=%{public}d',
          threadId, DirectPrefetch.queue.length);
        return;
      }
    }
  }

  /** 取下一条发一发；串行，一条结束再取下一条。 */
  private static pump(): void {
    if (DirectPrefetch.running) {
      return;
    }
    if (ApiThrottle.blocked(ApiThrottle.DIRECT)) {
      // 整个私信家族正在冷却：这一轮直接作废（别在冷却期里还排队打接口）。
      hilog.warn(DOMAIN, TAG, 'prefetch skipped: direct family throttled %{public}dmin',
        ApiThrottle.remainingMinutes(ApiThrottle.DIRECT));
      DirectPrefetch.queue = [];
      return;
    }
    const one: DirectThread | undefined = DirectPrefetch.queue.shift();
    if (one === undefined) {
      hilog.info(DOMAIN, TAG, 'round done %{public}s', DirectPrefetch.describe());
      return;
    }
    DirectPrefetch.running = true;
    DirectPrefetch.inflightId = one.id;
    const gen: number = DirectPrefetch.generation;
    // limit 只要 5 条（需求），优先级 idle（见文件头），走 NativeDirect 那条链（新路径优先、失败回退）。
    NativeDirect.thread(one.id, '', one.username, ApiThrottle.idle(), CACHE_MESSAGES)
      .then((view: DirectThreadView | null): void => {
        DirectPrefetch.inflightId = '';
        DirectPrefetch.running = false;
        if (gen !== DirectPrefetch.generation) {
          /*
           * 列表已经刷新过一轮：这一发属于上一份列表，**结果不留**（见文件头"可取消"）。
           *
           * 但**必须接着把新队列推下去** —— 这里曾经直接 return，于是"刷新列表"这个动作
           * 只要撞上一次在飞的旧请求，整条预取链就永久停在那里（现象就是"预取只做了一条"）。
           * 与 StoryCache 里 `loading` 那个坑是同一类，别再犯。
           */
          hilog.info(DOMAIN, TAG, 'drop stale prefetch id=%{public}s %{public}s',
            one.id, DirectPrefetch.describe());
          // 这一条在新那一轮里被当成"正在飞"跳过了，补回队头（见 currentList 的说明）。
          DirectPrefetch.requeue(one.id);
          DirectPrefetch.pump();
          return;
        }
        if (view === null || view.messages.length === 0) {
          DirectPrefetch.failed = DirectPrefetch.failed + 1;
          hilog.info(DOMAIN, TAG, 'prefetch miss id=%{public}s why=%{public}s',
            one.id, NativeDirect.lastDetail());
        } else {
          DirectCache.save(view);
          DirectPrefetch.done = DirectPrefetch.done + 1;
        }
        DirectPrefetch.pump();
      })
      .catch((error: Error): void => {
        DirectPrefetch.inflightId = '';
        DirectPrefetch.running = false;
        DirectPrefetch.failed = DirectPrefetch.failed + 1;
        hilog.warn(DOMAIN, TAG, 'prefetch threw id=%{public}s: %{public}s',
          one.id, error.message ?? '-');
        // 无论代次对不对都要接着推（理由同上）。
        DirectPrefetch.pump();
      });
  }
}
