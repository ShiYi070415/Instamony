/*
 * 原生直接要首页信息流 —— 数据来自移动端 `feed/timeline/`
 * （见 core/mobileapi/MobileFeedTimeline，与 instagrapi 同源的 App 私有接口）。
 *
 * 模板相关的一切（页面抓包、模板表、模板头）都已删除：这里只保留"要一页 + 解析"两件事。
 *
 * 失败一律**不抛**，返回 null，调用方据此提示重试。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedItemDto } from '../model/FeedDto';
import { NativeTimeline, NativeTimelineParser } from './NativeTimelineParser';
// 首页时间线的移动端通道（实测 POST feed/timeline/ → 200；见那个文件的文件头）。
import { MobileFeedPage, MobileFeedTimeline } from './mobileapi/MobileFeedTimeline';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeFeed';

/**
 * 原生取好的一页（解析好的条目 + 游标）。
 *
 * 两个用途：① 分页缓存里"备好的下一页"；② 冷启动**预热**（见 warmStart/takeWarm）。
 */
export class NativeFeedPage {
  readonly items: Array<FeedItemDto>;
  readonly nextCursor: string;
  readonly hasMore: boolean;
  /** 这一发花了多久（毫秒，日志用）。 */
  readonly ms: number;
  /** 这一页是什么时候取到的（判断预热的那份还新不新鲜）。 */
  readonly at: number;

  constructor(items: Array<FeedItemDto>, nextCursor: string, hasMore: boolean, ms: number) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
    this.ms = ms;
    this.at = Date.now();
  }
}

/** 一次原生取数的结果（不抛异常，用 error 表达失败）。 */export class NativeFetchResult {
  readonly ok: boolean;
  readonly error: string;
  readonly code: number;
  readonly ms: number;
  readonly bytes: number;
  readonly hasConn: boolean;
  /** 响应里数出来的帖子条数（粗数，只用于日志/判断有没有拿到货）。 */
  readonly codes: number;
  readonly body: string;

  constructor(ok: boolean, error: string, code: number, ms: number, bytes: number,
              hasConn: boolean, codes: number, body: string) {
    this.ok = ok;
    this.error = error;
    this.code = code;
    this.ms = ms;
    this.bytes = bytes;
    this.hasConn = hasConn;
    this.codes = codes;
    this.body = body;
  }

  /** 一行摘要（日志用）。 */
  summary(): string {
    return `ok=${this.ok ? 'y' : 'n'} err=${this.error} http=${this.code} ms=${this.ms} `
      + `bytes=${this.bytes} conn=${this.hasConn ? 'y' : 'n'} codes=${this.codes}`;
  }
}

export class NativeFeed {
  /**
   * 冷启动预热的那一页（app 一起来就发，见 warmStart）。
   *
   * 为什么要有它：现在首屏数据是"页面问才要"（1.2~2.4 秒），而 app 起来到用户看到信息流
   * 中间还有一段（启动窗口、组件构建、网页宿主创建）。把这一发**提前到 ability onCreate**
   * 发出去，等页面来要时数据多半已经躺在内存里，用户看到的就是"秒出内容"。
   */
  private static warmPage: NativeFeedPage | null = null;
  private static warming: boolean = false;

  /**
   * app 启动时就发一发第一页，结果留在内存里等页面来取（幂等，重复调用不会重复发）。
   *
   * 不 await、不抛：预热失败无所谓，页面那条路会照旧自己发一次。
   */
  static warmStart(first: number): void {
    if (NativeFeed.warming || NativeFeed.warmPage !== null) {
      return;
    }
    NativeFeed.warming = true;
    const started: number = Date.now();
    NativeFeed.fetchPage(first, '').then((page: NativeFeedPage | null): void => {
      NativeFeed.warming = false;
      if (page === null) {
        hilog.info(DOMAIN, TAG, 'warmStart miss after %{public}dms', Date.now() - started);
        return;
      }
      NativeFeed.warmPage = page;
      hilog.info(DOMAIN, TAG, 'warmStart ready n=%{public}d ms=%{public}d (since launch %{public}d)',
        page.items.length, page.ms, Date.now() - started);
    }).catch((): void => {
      NativeFeed.warming = false;
    });
  }

  /**
   * 取走预热的那一页（取走即清空）。
   *
   * @param maxAgeMs 太旧的不要：app 可能在后台躺了很久，那份数据已经不新鲜。
   */
  static takeWarm(maxAgeMs: number): NativeFeedPage | null {
    const page: NativeFeedPage | null = NativeFeed.warmPage;
    if (page === null) {
      return null;
    }
    NativeFeed.warmPage = null;
    if (Date.now() - page.at > maxAgeMs) {
      hilog.info(DOMAIN, TAG, 'warm page discarded age=%{public}dms', Date.now() - page.at);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'warm page used age=%{public}dms n=%{public}d',
      Date.now() - page.at, page.items.length);
    return page;
  }

  /**
   * 要一页并解析好（预热、首屏、翻页都走这里，保证解析规则只有一份）。
   *
   * **只走移动端 `feed/timeline/`**（见 core/mobileapi/MobileFeedTimeline）。
   * 模板回放那条兜底已经删了：四批迁移（评论 / Reels / 搜索 / 首页）之后，
   * 页面里不再注入抓包钩子（`NETWORK_WATCHER` 已退役），模板既抓不到，
   * 也不该再当数据源 —— 失败就让用户重试，而不是悄悄换一条自动化痕迹更重的路。
   *
   * 失败一律返回 null（无会话 / 非 200 / 形状变了 / 解析不出条目）。
   */
  static async fetchPage(first: number, cursor: string): Promise<NativeFeedPage | null> {
    const viaMobile: NativeFeedPage | null = await NativeFeed.viaMobile(cursor);
    if (viaMobile !== null) {
      return viaMobile;
    }
    hilog.warn(DOMAIN, TAG, 'feed mobile failed (%{public}s)', MobileFeedTimeline.detail());
    return null;
  }

  /**
   * 移动端那一发（拿不到给 null）。
   *
   * 解析用 `NativeTimelineParser.parseMobileFeed`（v1 媒体 → 同一套卡片 DTO），
   * 所以界面模型与模板那条完全一致，不需要第二份映射。
   */
  private static async viaMobile(cursor: string): Promise<NativeFeedPage | null> {
    const page: MobileFeedPage | null = await MobileFeedTimeline.page(cursor);
    if (page === null) {
      return null;
    }
    const parsed: NativeTimeline | null = NativeTimelineParser.parseMobileFeed(page.body);
    if (parsed === null) {
      hilog.info(DOMAIN, TAG, 'feed mobile unparsable bytes=%{public}d (%{public}s)',
        page.body.length, MobileFeedTimeline.detail());
      return null;
    }
    hilog.info(DOMAIN, TAG, 'feed via mobile n=%{public}d more=%{public}s cursor=%{public}d ms=%{public}d',
      parsed.items.length, `${parsed.hasNext}`, parsed.nextCursor.length, page.ms);
    return new NativeFeedPage(parsed.items, parsed.nextCursor, parsed.hasNext, page.ms);
  }

}
