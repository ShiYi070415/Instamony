/*
 * 三条「探索流」的**分道**台账（首页为你推荐 / Reels 探索流 / 搜索推荐网格）。
 *
 * ## 为什么要它
 * 这三个入口原来全都打 `discover/topical_explore/`（instagrapi 的 `explore_page()` 也是这一个），
 * 而且是**同一个游标、同一个 `session_id`、同一份 20 秒缓存** ——
 * 于是三处显示的内容基本一模一样（用户反馈："三个探索流显示的内容基本上是重复的"）。
 *
 * 一条上游接口不换，就只能从两处下手：
 *   1. **每个入口一条独立 `session_id`**（见 MobileDiscover 的 laneSession）：IG 会把它们当成
 *      三个不同的探索会话，section 组合与排序会分叉；
 *   2. **跨入口去重**（本文件）：同一张帖子在 TTL 内只发给一个入口，后到的入口把它剔掉、
 *      用自己的游标继续往上翻。
 *
 * 去重是"宁可少一条，也不要在三个页面看到同一条"；但一页**全被别的入口占住**时原样放行
 * （否则会空屏，比重复更糟）。
 */

/** 首页"为你推荐"那一段。 */
export const EXPLORE_LANE_FEED: string = 'feed';
/** Reels 页的探索流。 */
export const EXPLORE_LANE_REELS: string = 'reels';
/** 搜索页的推荐网格。 */
export const EXPLORE_LANE_SEARCH: string = 'search';

/** 全部入口（去重时"别的入口"就从这里取，只有一个数组，不会漏）。 */
const LANES: Array<string> = [EXPLORE_LANE_FEED, EXPLORE_LANE_REELS, EXPLORE_LANE_SEARCH];
/** 一条帖子被某个入口"占住"的时长（毫秒）。10 分钟：够跨几次切页，又不会长期占着池子。 */
const CLAIM_TTL_MS: number = 10 * 60 * 1000;
/** 台账条目上限：到了就整体清一次（条目很小，不值得写 LRU）。 */
const MAX_CLAIMS: number = 800;

export class ExploreLanes {
  /** key = `${lane}|${mediaId}` → 占住时刻（毫秒）。 */
  private static claims: Map<string, number> = new Map();

  /** 清空台账（换账号 / 退出登录时调，见 MobileDiscover.clearCache）。 */
  static clear(): void {
    ExploreLanes.claims.clear();
  }

  /**
   * 从这一页里挑出**能发给 lane** 的 id。
   *
   * @param lane 请求方是哪条入口（见 EXPLORE_LANE_*）。
   * @param ids 这一页的媒体 id（按页面顺序）。
   * @returns 可以给这条入口的 id（顺序保持）。**全被别的入口占住时原样返回 ids** ——
   *          宁可重复一次，也别让这一屏空掉（空屏比重复更像"坏了"）。
   */
  static claim(lane: string, ids: Array<string>): Array<string> {
    if (ids.length === 0) {
      return ids;
    }
    const now: number = Date.now();
    ExploreLanes.prune(now);
    const kept: Array<string> = [];
    for (let index: number = 0; index < ids.length; index++) {
      if (!ExploreLanes.takenByOthers(lane, ids[index], now)) {
        kept.push(ids[index]);
      }
    }
    const finalIds: Array<string> = kept.length === 0 ? ids : kept;
    for (let index: number = 0; index < finalIds.length; index++) {
      ExploreLanes.claims.set(`${lane}|${finalIds[index]}`, now);
    }
    return finalIds;
  }

  /** 这条 id 是否在 TTL 内被**别的**入口占着。 */
  private static takenByOthers(lane: string, id: string, now: number): boolean {
    for (let index: number = 0; index < LANES.length; index++) {
      const other: string = LANES[index];
      if (other === lane) {
        continue;
      }
      const at: number | undefined = ExploreLanes.claims.get(`${other}|${id}`);
      if (at !== undefined && now - at <= CLAIM_TTL_MS) {
        return true;
      }
    }
    return false;
  }

  /** 过期的条目顺手清掉；太多了就整体清空。 */
  private static prune(now: number): void {
    if (ExploreLanes.claims.size <= MAX_CLAIMS) {
      return;
    }
    const kept: Map<string, number> = new Map();
    ExploreLanes.claims.forEach((at: number, key: string) => {
      if (now - at <= CLAIM_TTL_MS) {
        kept.set(key, at);
      }
    });
    ExploreLanes.claims = kept;
  }
}
