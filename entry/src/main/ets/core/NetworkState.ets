/*
 * 预下载的"流量闸门"：现在是不是该允许预下载。
 *
 * 为什么要有它：预下载（下一条视频提前 prepare、后面几页接口、封面图提前抓）在 Wi-Fi 上很划算，
 * 但**在蜂窝网下是纯浪费** —— 实测一轮下来最大的一笔开销是"每个播放器 20 秒的预缓冲"，
 * 再加上每次翻页多抓一页 JSON、每次滚动预抓几张原图封面。用户要的是"省流量"，那默认策略就是：
 *
 *   - Wi-Fi / 不计费网络（NET_CAPABILITY_NOT_METERED）→ 照常预下载；
 *   - 蜂窝网，或者**问不出来**的时候 → 只下"马上要用的那一份"，其余一律不预下载
 *     （问不出来时按计费处理：宁可少下，也不要偷偷跑流量）。
 *
 * 查询本身是同步接口（getDefaultNetSync / getNetCapabilitiesSync），但每次滚动都问一下没必要，
 * 所以结果缓存 20 秒；网络切换通常也会在这个窗口内被下一次查询覆盖。
 */

import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NetworkState';
/** 查询结果缓存窗口（毫秒）。 */
const CACHE_MS: number = 20000;
/**
 * 测试/省流量开关：置 true 时**不论真实网络**都按计费网络处理（关掉一切预下载）。
 *
 * 留着它有两个用处：① 真机上验证"受限分支"到底关掉了哪些东西（不用真去插一张流量卡）；
 * ② 用户想彻底省流量时，改这一个常量重装即可（比加一整套设置页便宜）。
 */
const FORCE_METERED: boolean = false;

export class NetworkState {
  private static allow: boolean = false;
  private static checkedAt: number = 0;
  private static described: string = 'unknown';

  /**
   * 允不允许预下载（Wi-Fi / 不计费网络）。
   *
   * 拿不准（查询报错、netId=0）时返回 false：**按计费网络处理**，只下马上要用的那份。
   */
  static allowPrefetch(): boolean {
    if (FORCE_METERED) {
      NetworkState.allow = false;
      NetworkState.described = 'forced';
      NetworkState.checkedAt = Date.now();
      return false;
    }
    const now: number = Date.now();
    if (NetworkState.checkedAt > 0 && now - NetworkState.checkedAt < CACHE_MS) {
      return NetworkState.allow;
    }
    NetworkState.checkedAt = now;
    let allow: boolean = false;
    let why: string = 'unknown';
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      if (handle === undefined || handle.netId === 0) {
        why = 'no-network';
      } else {
        const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
        const bearers: Array<connection.NetBearType> = caps.bearerTypes ?? [];
        const unmetered: Array<connection.NetCap> = caps.networkCap ?? [];
        const wifi: boolean = bearers.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
        const ethernet: boolean = bearers.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0;
        const notMetered: boolean = unmetered.indexOf(connection.NetCap.NET_CAPABILITY_NOT_METERED) >= 0;
        allow = wifi || ethernet || notMetered;
        why = `${wifi ? 'wifi' : (ethernet ? 'ethernet' : 'cellular')}${notMetered ? '+unmetered' : ''}`;
      }
    } catch (error) {
      why = 'probe-failed';
    }
    if (allow !== NetworkState.allow || why !== NetworkState.described) {
      hilog.info(DOMAIN, TAG, 'prefetch %{public}s (%{public}s)',
        allow ? 'allowed' : 'restricted', why);
    }
    NetworkState.allow = allow;
    NetworkState.described = why;
    return allow;
  }

  /** 一行摘要（日志/探针用）。 */
  static describe(): string {
    NetworkState.allowPrefetch();
    return `${NetworkState.allow ? 'prefetch-on' : 'prefetch-off'}(${NetworkState.described})`;
  }
}
