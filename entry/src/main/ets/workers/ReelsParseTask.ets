/*
 * **reels 响应解析任务**（跑在 TaskPool 线程里）。
 *
 * 只做**一件事**：把 200~330KB 的 `clips/*` 响应 `JSON.parse` 成结构化对象，再把
 * `items[].media` 与 `paging_info` 摘出来。这是整条解析链里最贵的一段（真机 100~200ms），
 * 而它**完全不需要** AppStorage / 设置 / 网络状态 —— 所以可以安全地搬出主线程。
 *
 * 剩下的逐条映射（`toReel`：要读 EngageState / 画质档 / 打诊断日志）仍在主线程做，
 * 那部分每个条目只有几百微秒，且必须能看到会话状态。
 *
 * 线程契约：参数只传 string；回传的是纯字段对象（`IgClipsMedia` 全是 string/number/boolean），
 * 可以跨线程。
 */

import { IgClipsMedia, ReelsPageRaw } from '../core/NativeReels';

/** `clips/*` 响应 → 纯数据（`items[].media` 列表 + 分页信息）。 */
@Concurrent
export function parseReelsItems(body: string): ReelsPageRaw | null {
  if (body.length === 0) {
    return null;
  }
  let root: Record<string, Object>;
  try {
    root = JSON.parse(body) as Record<string, Object>;
  } catch (error) {
    return null;
  }
  let items: Array<Object> = [];
  const plain: Object | undefined = root['items'];
  if (plain !== undefined && plain !== null && Array.isArray(plain)) {
    items = plain as Array<Object>;
  }
  if (items.length === 0) {
    const ads: Object | undefined = root['items_with_ads'];
    if (ads !== undefined && ads !== null && Array.isArray(ads)) {
      items = ads as Array<Object>;
    }
  }
  const out: ReelsPageRaw = new ReelsPageRaw();
  for (let index: number = 0; index < items.length; index++) {
    const item: Object = items[index];
    if (item === null || item === undefined || typeof item !== 'object') {
      continue;
    }
    const record: Record<string, Object> = item as Record<string, Object>;
    const media: Object | undefined = record['media'];
    if (media === undefined || media === null || typeof media !== 'object') {
      continue;
    }
    out.media.push(media as IgClipsMedia);
  }
  const paging: Object | undefined = root['paging_info'];
  if (paging !== undefined && paging !== null && typeof paging === 'object') {
    const page: Record<string, Object> = paging as Record<string, Object>;
    const maxId: string = `${page['max_id'] ?? ''}`.trim();
    if (maxId.length > 0 && maxId !== 'null') {
      out.cursor = maxId;
    }
    out.more = page['more_available'] === true;
  }
  return out;
}
