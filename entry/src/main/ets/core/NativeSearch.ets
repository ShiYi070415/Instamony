/*
 * 搜索页的**原生 HTTP 取数**（和「我的」/信息流同一套路数，见 core/NativeProfile 的说明）。
 *
 * ## 用哪些模板
 * 搜索页在网页上会发两条请求，这里都靠**探针抓下来的模板**（bridge/ApiRegistry）：
 *   1) **结果那条**（名字里带 search 但不是 nullstate/recent）：换关键词重发，扫出账号；
 *   2) **空态/推荐那条**（nullstate / search 系列）：原样重发，扫出推荐的帖子，喂三列瀑布流。
 *
 * 名字不写死：IG 这几条操作名换过好几版（`PolarisSearchNullStateQuery`、
 * `PolarisSearchResultsPageContentQuery`、`xdt_api__v1__fbsearch__topsearch_combined`…），
 * 所以按**片段优先级**从"已存模板"里挑，挑不到就报"没有模板"，由视图模型决定退回网页那条路。
 *
 * ## 为什么不写死响应路径
 * 和页面脚本（WebScripts.searchResultsScript）同一个判据：**按形状扫**。
 *   用户 = 有 username，并且带 profile_pic_url 或 full_name 的对象；
 *   帖子 = 有 code，并且带 image_versions2 / video_versions / carousel_media 的对象。
 * 这样 IG 换一层包装（`data.xdt_api__v1__...` 变成别的键）也不会一片空白。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { JsonRead } from './JsonRead';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { NativeFeed } from './NativeFeed';
import { SearchCache } from './SearchCache';
import { ApiThrottle } from './ApiThrottle';
import { SearchPost, SearchUser } from '../model/Search';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeSearch';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 15000;
const SITE: string = 'https://www.instagram.com';

/** 扫响应时的上限：一次取数够用就行，别把整包几万节点都扫一遍。 */
const MAX_USERS: number = 40;
const MAX_POSTS: number = 60;

/**
 * **每页条数**（写进 `variables` 的 `first` / `data.page_size`）。
 *
 * 真机实测（`probePageSizes` 量的，同一个进程里同一尺寸连发两次结果一致）：
 *
 *   | first | 响应大小 | 条数 | 耗时  |
 *   |-------|----------|------|-------|
 *   | 0（模板原样，模板里是 10） | 392~402KB | 15 | 3.5~4.2s |
 *   | 10 / 15 / 24 / 36          | 104~110KB | 4  | 0.8~1.0s |
 *
 * 两条结论：
 *   1. **`first` 本身被服务端忽略**（10 到 36 的响应字节数完全一样，返回条数也一样），所以
 *      "把每页要得更大"并没有换来更多条 —— 这个值取多少都行；
 *   2. 但**改 `variables` 这件事本身有用**：模板里那份变量带着页面自己那一发留下的 `after`
 *      游标（模板是照抄页面请求的），原样重发等于"从半路接着翻"（15 条 / 400KB / 3.5 秒）；
 *      一旦我们改写 `variables`（本函数就是那个开关，见 patchVars），`after` 会被丢掉，
 *      拿到的才是**真正的第一页**（4 条 / 104KB / 0.85 秒）—— 首屏因此快四倍。
 *      那 4 条偏少是 IG 的"没看过的"池子小，界面那头会自动补满（见 SearchViewModel.fillGrid）。
 */
const PAGE_SIZE: number = 36;
/**
 * 封面请求的目标宽度（px）。
 *
 * 网格格子实测约 141vp（≈470px），原来按全 app 的展示档 1080 取 —— 三列铺下来是白给带宽，
 * 解码和上屏都慢。降到 **1080 的三分之一 = 360**，格子尺寸下肉眼看不出差别。
 */
const COVER_WIDTH: number = 360;
/** 递归深度上限：IG 的响应一般四五层，超过就当包装层不看了。 */
const MAX_DEPTH: number = 8;

/**
 * 模板名里出现这些片段就认为"这条是搜索结果"。
 * 顺序 = 优先级：越靠前的越像结果那条。
 */
const RESULT_HINTS: Array<string> = ['searchresult', 'topsearch', 'search'];
/** 这些片段说明"这条不是结果那条"，要排掉（空态/最近搜索/建议词）。 */
const RESULT_EXCLUDE: Array<string> = ['nullstate', 'recent', 'suggested', 'typeahead'];
/**
 * **探索页**那几条操作的片段：推荐网格的真正来源。
 *
 * 单独一组是因为它决定"要不要再抓一次"：搜索页那两条（nullstate / topsearch）名字里也带
 * 'search'，拿它们当"有推荐模板"会让冷路径再也不跑（实测踩过：搜索页抓过之后就以为推荐齐了）。
 */
const EXPLORE_HINTS: Array<string> = ['explore', 'discover', 'chaining'];
/**
 * 短视频流（Reels/Clips）那几条：**推荐网格的兜底来源**。
 *
 * 为什么轮得到它（实测结论，证据在探针摘要的 `explore landing` / `explore replays` 两行）：
 * 推荐网格本该来自 IG 的探索页，但 `/explore/` 要么**一个请求都不发**（服务端直出，
 * `window.__ogReplay` 里没有任何属于该页的请求），要么**直接跳到 `/explore/search/`** ——
 * 两条路都拿不到可用的接口模板。而短视频流本身就是 IG 的推荐流
 * （`PolarisClipsTabRootPaginationQuery`），三列网格铺它的封面，和官方 App 搜索页下面
 * 那面网格观感一致，而且**有模板可抓、有原生 HTTP 可发**。
 */
const CLIPS_HINTS: Array<string> = ['clips', 'reels'];
/**
 * 试推荐数据的候选顺序：探索页那条最可能带网格，后面几个是兜底
 * （搜索页空态实测只回最近搜索，留它只是为了"万一某个版本把推荐塞进搜索页"）。
 */
const RECOMMEND_HINTS: Array<string> = ['explore', 'discover', 'chaining', 'clips', 'reels',
  'nullstate', 'search'];

/**
 * 一条连接的翻页信息（`page_info`）。
 *
 * IG 的 GraphQL 连接统一给这两个字段：`has_next_page` 说有没有下一页，
 * `end_cursor` 是下一页要带上的游标。**只有服务端明确给了布尔值才算"没有更多"** ——
 * 字段缺失时按"还有"处理，否则一次解析失败就把列表永久锁死（信息流那边踩过同样的坑）。
 */
class PageInfo {
  readonly cursor: string;
  readonly hasMore: boolean;

  constructor(cursor: string, hasMore: boolean) {
    this.cursor = cursor;
    this.hasMore = hasMore;
  }
}

/** 一次原生请求的结果（不抛异常，失败用 ok=false + detail 表达）。 */
class NativeSearchResult {
  readonly ok: boolean;
  readonly text: string;
  readonly detail: string;

  constructor(ok: boolean, text: string, detail: string) {
    this.ok = ok;
    this.text = text;
    this.detail = detail;
  }
}

/**
 * 一页推荐帖子。
 *
 * `cursor` / `hasMore` 来自响应里的 `page_info`（`end_cursor` / `has_next_page`）：
 * 瀑布流上滑到底部要接着加载，靠的就是这两个字段（见 SearchViewModel.loadMore）。
 */
export class SearchPostPage {
  readonly posts: Array<SearchPost>;
  readonly cursor: string;
  readonly hasMore: boolean;
  /** 这一页是谁给的（`clips:PolarisClipsTabRootPaginationQuery` / `feed:explore_story`）。 */
  readonly source: string;

  constructor(posts: Array<SearchPost>, cursor: string, hasMore: boolean, source: string) {
    this.posts = posts;
    this.cursor = cursor;
    this.hasMore = hasMore;
    this.source = source;
  }
}

export class NativeSearch {
  /**
   * 上一次推荐数据是从哪儿来的（诊断用：`explore:<操作名>` / `clips:<操作名>` / `feed:explore_story`）。
   *
   * 为什么要记：这几条路的产出差别很大（探索页是真网格，兜底只有零星几张卡），
   * 界面上"推荐流很少"时得能一眼看出走的是哪条（会写进探针摘要）。
   */
  private static source: string = '-';
  /** 每个候选源试出来的结果（诊断用，写进探针摘要）。 */
  private static diag: Array<string> = [];
  /**
   * 第一页用的那条模板名。
   *
   * 翻页**必须**沿用它：游标（`page_info.end_cursor`）是那条查询给的，换一条查询拿到的游标
   * 语义完全不同（轻则空页，重则报变量不合法）。
   */
  private static chosenOp: string = '';
  /**
   * 服务端**拒绝过**我们要求的每页条数（见 pageRequest 的回退）。
   *
   * 一条查询被拒过就不再试 —— 否则每次翻页都白发一次注定 400 的请求，反而更慢。
   * 进程级即可：换一次会话/重启就重新试一遍。
   */
  private static pageSizeRejected: boolean = false;

  static lastSource(): string {
    return NativeSearch.source;
  }

  /**
   * **诊断（临时）**：同一条推荐查询用几个不同的"每页条数"各发一次，量出服务端**实际**
   * 返回多少条、响应多大、花多久。
   *
   * 为什么需要它：`PAGE_SIZE` 是"猜服务端认多少"——模板里 `first` 只有 10，而这条查询实测
   * 一页就是 15 条上下（不管 `first` 写多少），还可能因为"未看过的"池子空了只回 4 条。
   * 想判断"把 first 调小会不会让响应更小、回来更快"，只能真机各发一次对比。
   *
   * `sizes` 里的 **0 表示"模板原样"**（即 `first: 10`），当基线用。
   */
  static async probePageSizes(op: string, sizes: Array<number>): Promise<void> {
    for (let index: number = 0; index < sizes.length; index++) {
      const size: number = sizes[index];
      const started: number = Date.now();
      const result: NativeSearchResult = await NativeSearch.post(op, '', '', '', size);
      const ms: number = Date.now() - started;
      if (!result.ok) {
        hilog.info(DOMAIN, TAG, 'PROBE first=%{public}d -> %{public}s ms=%{public}d',
          size, result.detail, ms);
        continue;
      }
      const posts: Array<SearchPost> = NativeSearch.postsOf(result.text);
      const info: PageInfo = NativeSearch.pageInfoOf(result.text);
      hilog.info(DOMAIN, TAG,
        'PROBE first=%{public}d len=%{public}d posts=%{public}d hasMore=%{public}s cursor=%{public}d ms=%{public}d',
        size, result.text.length, posts.length, `${info.hasMore}`, info.cursor.length, ms);
    }
  }

  /**
   * 打开落盘缓存并**读回上次成功的那条推荐模板**（EntryAbility.onCreate 里调一次；幂等）。
   *
   * 为什么要落盘：`chosenOp` 原来只在内存里，进程一重启就得重新按线索挑候选、一条条试 ——
   * 每条候选都是一次 400KB 的完整请求（实测 2.5 秒量级）。存下来之后下次直接用它。
   */
  static init(context: common.Context): void {
    SearchCache.init(context);
    const stored: string = SearchCache.loadOp();
    if (stored.length > 0) {
      NativeSearch.chosenOp = stored;
      NativeSearch.source = `explore:${stored}`;
    }
  }

  /** 候选源的逐条结果（探针摘要里那一行行 `source op -> ...`）。 */
  static lastDiag(): string {
    return NativeSearch.diag.join('\n');
  }

  /** 结果那条模板在不在（**已存模板**，不是接口索引）。 */
  static hasResultsTemplate(): boolean {
    return NativeSearch.resultsOp().length > 0;
  }

  /** 推荐那条模板在不在（探索页那几条，或短视频流那几条，理由见那两个常量）。 */
  static hasRecommendedTemplate(): boolean {
    return NativeSearch.recommendOp().length > 0;
  }

  /** 有没有**任意**一条搜索/推荐相关的模板（视图模型据此判断要不要走"驱动网页"的冷路径）。 */
  static hasAnyTemplate(): boolean {
    return ApiRegistry.getInstance().storedNames().some((name: string): boolean => {
      return NativeSearch.looksRelevant(name);
    });
  }

  /**
   * 搜账号（原生直发）。
   *
   * @param query 这次要搜的词。
   * @param prevQuery 上一次搜的词 —— 模板里那个字符串就是它，用它**按值**定位要改哪个变量
   *   （键名各版本不同：query / search_query / q …，写死一个名字会出现"换了关键词结果还是上一个"）。
   * @returns 扫到的账号；请求失败或没有模板给 null（调用方据此报错或退回网页）。
   */
  static async searchUsers(query: string, prevQuery: string): Promise<Array<SearchUser> | null> {
    const op: string = NativeSearch.resultsOp();
    if (op.length === 0) {
      return null;
    }
    const result: NativeSearchResult = await NativeSearch.post(op, prevQuery, query);
    if (!result.ok) {
      hilog.warn(DOMAIN, TAG, 'search http failed op=%{public}s: %{public}s', op, result.detail);
      return null;
    }
    const users: Array<SearchUser> = NativeSearch.usersOf(result.text);
    hilog.info(DOMAIN, TAG, 'search op=%{public}s q=%{public}s users=%{public}d',
      op, query, users.length);
    return users;
  }

  /**
   * 推荐帖子 —— **第一页**（`cursor` 传空串）。
   *
   * 两条路，按顺序试：
   *   1) **探索页/短视频流**那几条模板（见 RECOMMEND_HINTS）—— 官方 App 里推荐网格就是它；
   *      某一条的响应里扫不到帖子就换下一条（比"写死一条、抓不到就白屏"稳）；
   *   2) **信息流里的推荐卡片**（`explore_story`）：IG 自己会在首页信息流里插"推荐"帖子
   *      （结构见 core/NativeTimelineParser 的 `explore_story.media`）。上一条抓不到时用它兜底
   *      —— 同样是原生 HTTP，不需要新模板（信息流模板本来就有）。
   */
  static async recommendedPage(cursor: string): Promise<SearchPostPage | null> {
    if (cursor.length > 0) {
      // 翻页：**必须用第一页那条模板**（游标是那条查询给的，换一条就是另一条查询了）。
      const op: string = NativeSearch.chosenOp.length > 0 ? NativeSearch.chosenOp
        : NativeSearch.recommendOp();
      if (op.length === 0) {
        return null;
      }
      const result: NativeSearchResult = await NativeSearch.pageRequest(op, cursor, PAGE_SIZE);
      if (!result.ok) {
        NativeSearch.diag.push(`more ${op} -> ${result.detail}`);
        return null;
      }
      const posts: Array<SearchPost> = NativeSearch.postsOf(result.text);
      const info: PageInfo = NativeSearch.pageInfoOf(result.text);
      NativeSearch.diag.push(`more ${op} after=${cursor.substring(0, 24)} -> posts=${posts.length}`
        + ` hasMore=${info.hasMore} next=${info.cursor.substring(0, 24)}`);
      hilog.info(DOMAIN, TAG, 'more op=%{public}s posts=%{public}d hasMore=%{public}s',
        op, posts.length, `${info.hasMore}`);
      return new SearchPostPage(posts, info.cursor, info.hasMore, NativeSearch.source);
    }
    const names: Array<string> = ApiRegistry.getInstance().storedNames();
    NativeSearch.diag = [];
    const candidates: Array<string> = [];
    // **上次成功那条排最前**（见 core/SearchCache）：它才是真正给推荐的那条查询，
    // 按线索排的话（explore 先于 clips）会先拿别的候选试一遍，每条都是一次 400KB 的请求 ——
    // 用户感受到的就是"切到搜索页要等好几秒"。命中它就直接过去了。
    if (NativeSearch.chosenOp.length > 0 && names.indexOf(NativeSearch.chosenOp) >= 0) {
      candidates.push(NativeSearch.chosenOp);
    }
    for (let hint: number = 0; hint < RECOMMEND_HINTS.length; hint++) {
      for (let index: number = 0; index < names.length; index++) {
        const name: string = names[index];
        if (name.toLowerCase().indexOf(RECOMMEND_HINTS[hint]) < 0) {
          continue;
        }
        if (candidates.indexOf(name) < 0) {
          candidates.push(name);
        }
      }
    }
    for (let index: number = 0; index < candidates.length && index < 6; index++) {
      // 被限流了就别再一个候选一个候选地试了（每条都是几百 KB 的重查询，见 core/ApiThrottle）。
      if (ApiThrottle.blocked(ApiThrottle.CLIPS)) {
        NativeSearch.diag.push('candidates skipped: rate limited');
        break;
      }
      const result: NativeSearchResult = await NativeSearch.pageRequest(candidates[index], '',
        PAGE_SIZE);
      if (!result.ok) {
        NativeSearch.diag.push(`source ${candidates[index]} -> ${result.detail}`);
        continue;
      }
      const posts: Array<SearchPost> = NativeSearch.postsOf(result.text);
      const info: PageInfo = NativeSearch.pageInfoOf(result.text);
      NativeSearch.diag.push(`source ${candidates[index]} -> len=${result.text.length}`
        + ` posts=${posts.length} hasMore=${info.hasMore} cursor=${info.cursor.length}`);
      hilog.info(DOMAIN, TAG, 'recommend op=%{public}s posts=%{public}d hasMore=%{public}s',
        candidates[index], posts.length, `${info.hasMore}`);
      if (posts.length > 0) {
        NativeSearch.chosenOp = candidates[index];
        // 落盘记住它：下次冷启动第一条就试它（见 core/SearchCache）。
        SearchCache.saveOp(candidates[index]);
        NativeSearch.source = `explore:${candidates[index]}`;
        return new SearchPostPage(posts, info.cursor, info.hasMore, NativeSearch.source);
      }
    }
    // 兜底：信息流里的"推荐"卡片（explore_story）。
    const fromFeed: Array<SearchPost> = await NativeSearch.recommendedFromFeed();
    if (fromFeed.length > 0) {
      NativeSearch.chosenOp = 'FeedTimeline';
      NativeSearch.source = 'feed:explore_story';
      // 信息流那条没有"下一页游标"这一说（首页就是一条时间线，翻页另有一套），
      // 所以这一路的推荐是**一页到底**：hasMore=false，界面显示"没有更多了"。
      return new SearchPostPage(fromFeed, '', false, NativeSearch.source);
    }
    return null;
  }

  /**
   * 信息流里的推荐卡片 → 瀑布流条目。
   *
   * 只看 `explore_story.media` 那一种包装（IG 自己标的"推荐"），**不是**把整条信息流端上来 ——
   * 那会把关注列表里的帖子也混进"推荐"。
   */
  private static async recommendedFromFeed(): Promise<Array<SearchPost>> {
    const result: NativeSearchResult = await NativeSearch.post('FeedTimeline', '', '');
    if (!result.ok) {
      NativeSearch.diag.push(`source feed(FeedTimeline) -> ${result.detail}`);
      return [];
    }
    const root: Record<string, Object> = JsonRead.parse(result.text);
    const seen: Array<string> = [];
    const posts: Array<SearchPost> = [];
    let cards: number = 0;
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (!JsonRead.has(node, 'explore_story')) {
        return;
      }
      cards++;
      if (posts.length >= MAX_POSTS) {
        return;
      }
      const story: Record<string, Object> | null = JsonRead.recordOf(node, 'explore_story');
      if (story === null) {
        return;
      }
      const media: Record<string, Object> | null = JsonRead.recordOf(story, 'media');
      if (media === null) {
        return;
      }
      const mapped: SearchPost | null = NativeSearch.postOf(media);
      if (mapped === null || seen.indexOf(mapped.code) >= 0) {
        return;
      }
      seen.push(mapped.code);
      posts.push(mapped);
    });
    NativeSearch.diag.push(`source feed(FeedTimeline) -> len=${result.text.length}`
      + ` exploreCards=${cards} posts=${posts.length}`);
    hilog.info(DOMAIN, TAG, 'recommend from feed cards=%{public}d n=%{public}d',
      cards, posts.length);
    return posts;
  }

  // ==========================================================================
  // 模板挑拣
  // ==========================================================================

  /** 结果那条模板的操作名（挑不到给空串）。 */
  private static resultsOp(): string {
    const names: Array<string> = ApiRegistry.getInstance().storedNames();
    for (let hint: number = 0; hint < RESULT_HINTS.length; hint++) {
      for (let index: number = 0; index < names.length; index++) {
        const lower: string = names[index].toLowerCase();
        if (lower.indexOf(RESULT_HINTS[hint]) < 0) {
          continue;
        }
        if (NativeSearch.excluded(lower)) {
          continue;
        }
        return names[index];
      }
    }
    return '';
  }

  /** 推荐那条模板的操作名（挑不到给空串）：先探索页那几条，再短视频流那几条。 */
  private static recommendOp(): string {
    const names: Array<string> = ApiRegistry.getInstance().storedNames();
    const groups: Array<Array<string>> = [EXPLORE_HINTS, CLIPS_HINTS];
    for (let group: number = 0; group < groups.length; group++) {
      const hints: Array<string> = groups[group];
      for (let hint: number = 0; hint < hints.length; hint++) {
        for (let index: number = 0; index < names.length; index++) {
          if (names[index].toLowerCase().indexOf(hints[hint]) >= 0) {
            return names[index];
          }
        }
      }
    }
    return '';
  }

  private static excluded(lower: string): boolean {
    for (let index: number = 0; index < RESULT_EXCLUDE.length; index++) {
      if (lower.indexOf(RESULT_EXCLUDE[index]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 是不是"搜索/推荐这条链路"的操作名。
   *
   * 包含 explore/discover/chaining：推荐网格在网页上是**探索页**发的（见 AppConfig 的
   * INSTAGRAM_EXPLORE_URL 说明），只认 'search' 会把它漏掉。
   */
  private static looksRelevant(name: string): boolean {
    const lower: string = name.toLowerCase();
    if (lower.indexOf('search') >= 0 || lower.indexOf('nullstate') >= 0
      || lower.indexOf('topsearch') >= 0) {
      return true;
    }
    return lower.indexOf('explore') >= 0 || lower.indexOf('discover') >= 0
      || lower.indexOf('chaining') >= 0;
  }

  // ==========================================================================
  // 发请求
  // ==========================================================================

  /**
   * 按模板发一次请求。
   *
   * @param from / @param to 非空时把请求体里"等于 from 的字符串"和"名字像查词的键"改成 to；
   *   两个都传空 = **原样重发**（推荐那条就是这么发的：模板里那份变量就是页面自己要的）。
   * @param cursor 非空时把 `variables.after` 换成它（翻页）；空 = 用模板原样（第一页）。
   */
  private static async post(op: string, from: string, to: string,
                            cursor: string = '', pageSize: number = 0): Promise<NativeSearchResult> {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(op);
    if (tpl === null) {
      return new NativeSearchResult(false, '', 'no-template');
    }
    const headers: Record<string, string> = await NativeFeed.headersFor(op);
    if (Object.keys(headers).length === 0) {
      return new NativeSearchResult(false, '', 'no-session');
    }
    const isGet: boolean = (tpl.method ?? 'POST').toUpperCase() === 'GET';
    let body: string = isGet ? '' : NativeSearch.bodyWith(tpl, from, to);
    if (!isGet && (cursor.length > 0 || pageSize > 0)) {
      body = NativeSearch.patchVars(body, cursor, pageSize);
    }
    const url: string = tpl.url.startsWith('http') ? tpl.url : `${SITE}${tpl.url}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: isGet ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: headers,
        extraData: body.length > 0 ? body : undefined,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const code: number = response.responseCode;
      const looksJson: boolean = text.indexOf('"data"') >= 0 || text.indexOf('"errors"') >= 0
        || text.charAt(0) === '{' || text.charAt(0) === '[';
      hilog.info(DOMAIN, TAG, 'http op=%{public}s code=%{public}d json=%{public}s len=%{public}d',
        op, code, `${looksJson}`, text.length);
      if (code !== 200 || !looksJson) {
        const head: string = text.substring(0, 160).replace(/[\r\n]+/g, ' ');
        hilog.warn(DOMAIN, TAG, 'http body: %{public}s', head);
        /*
         * **400 的响应体要带给调用方**（审计 E7）：查询变量被服务端拒时 IG 回的是
         * `{"message":"…noncoercible_variable_value…","status":"fail"}`，
         * 调用方（`pageRequest`）只有看到它才能分清"是我改大的每页条数不被接受"，
         * 还是"这一发本身就没成"（网络抖动 / 会话过期 / 限流）。
         * 只带 400 的体、且截断到 120 字 —— 这是给判据用的，不是给业务解析的。
         */
        const carry: string = code === 400 ? `/${head.substring(0, 120)}` : '';
        return new NativeSearchResult(false, '', `http-${code}${looksJson ? '' : '/non-json'}${carry}`);
      }
      /*
       * **被限流**：IG 会回 200 + `{"data":[],"errors":[{"message":"Rate limit exceeded",
       * "code":1675004}]}` —— 只看 HTTP 码会当成"成功但没内容"，于是推荐流那边会一个候选一个
       * 候选地接着试（每条都是几百 KB），越试越久、也把冷却期越拖越长（见 core/ApiThrottle）。
       * 这里当场记账并当成失败返回。
       */
      if (ApiThrottle.looksLimited(text)) {
        ApiThrottle.note(ApiThrottle.CLIPS);
        hilog.warn(DOMAIN, TAG, 'rate limited op=%{public}s → back off %{public}dmin',
          op, ApiThrottle.remainingMinutes(ApiThrottle.CLIPS));
        return new NativeSearchResult(false, '', 'rate-limited');
      }
      return new NativeSearchResult(true, text, '');
    } catch (error) {
      const message: string = (error as Error).message ?? 'request-threw';
      hilog.warn(DOMAIN, TAG, 'http failed op=%{public}s: %{public}s', op, message);
      return new NativeSearchResult(false, '', `throw:${message}`.substring(0, 60));
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 发一页推荐：**先试更大的每页条数**，服务端不认就退回模板原样。
   *
   * 为什么要有这条回退：模板里 `first` 只有 10（真机抓到的那份），把它改大是"猜服务端认"——
   * IG 对没见过的变量值会直接回 `noncoercible_variable_value`（400）。一条查询被拒过就记下来
   * （`pageSizeRejected`），后面的翻页不再试，避免每页都白发一次请求。
   */
  private static async pageRequest(op: string, cursor: string,
                                   pageSize: number): Promise<NativeSearchResult> {
    const size: number = NativeSearch.pageSizeRejected ? 0 : pageSize;
    let result: NativeSearchResult = await NativeSearch.post(op, '', '', cursor, size);
    if (!result.ok && size > 0) {
      /*
       * **先分清"这一发为什么失败"**（审计 E7）。
       *
       * 原来只要 `!ok` 就 `pageSizeRejected = true`：一次网络抖动 / 会话过期 / 被限流，
       * "大页数"这条优化在**整个进程**里就再也不会被尝试了 —— 而它恰好是
       * "翻页翻不动、一页只有十来条"的排查方向之一，却再也看不到现场。
       *
       * 现在只有服务端**明确说这个变量值不认**（`noncoercible_variable_value`）才永久关掉；
       * 其余失败这次退回模板原样，下次仍然会试大页数。
       */
      const refused: boolean = result.detail.indexOf('noncoercible_variable_value') >= 0;
      /*
       * 这几类失败**再发一发也是白打**（没有模板 / 没有会话 / 正在限流）：
       * 直接返回，省一次一模一样的请求（和 core/ApiThrottle 的取向一致）。
       */
      const hopeless: boolean = result.detail === 'no-template' || result.detail === 'no-session'
        || result.detail === 'rate-limited';
      if (hopeless) {
        NativeSearch.diag.push(`pageSize=${size} skipped retry (${result.detail})`);
        return result;
      }
      NativeSearch.diag.push(`pageSize=${size} failed (${result.detail.substring(0, 80)})`
        + (refused ? ' -> 永久退回模板原样' : ' -> 本次退回模板原样'));
      hilog.warn(DOMAIN, TAG, 'page size %{public}d failed refused=%{public}s: %{public}s',
        size, `${refused}`, result.detail.substring(0, 120));
      if (refused) {
        NativeSearch.pageSizeRejected = true;
      }
      result = await NativeSearch.post(op, '', '', cursor, 0);
    }
    return result;
  }

  /**
   * 改请求体里 `variables=` 那一段：**游标** + **每页条数**。
   *
   * 除了这两样，其余变量（模板里那些 relay provider 开关、`data` 里的其它字段……）**原样保留**
   * —— 它们决定服务端返回什么形状，改了就会 `noncoercible_variable_value`（和信息流/个人页
   * 那两条翻页同一个判据，见 NativeProfile.bodyWith）。
   *
   * 每页条数（`pageSize > 0` 时生效）同时看三处写法：顶层 `first`、顶层 `page_size`、
   * 以及 `data.page_size`（IG 两种写法都在用，见 NativeProfile 的 `page_size` 注释）。
   * 页面里没有这些键就一个也不加 —— 加一个查询不认识的变量同样会 400。
   */
  private static patchVars(body: string, cursor: string, pageSize: number = 0): string {
    if (body.length === 0) {
      return body;
    }
    const parts: Array<string> = body.split('&');
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].indexOf('variables=') !== 0) {
        continue;
      }
      try {
        const raw: string = decodeURIComponent(parts[index].substring('variables='.length));
        const src: Record<string, Object> = JsonRead.parse(raw);
        // ArkTS 没有 delete（arkts-no-delete），所以重建一份：拷过来时跳过旧的 after。
        const out: Record<string, Object> = {};
        const keys: Array<string> = Object.keys(src);
        for (let k: number = 0; k < keys.length; k++) {
          const key: string = keys[k];
          if (key === 'after') {
            continue;
          }
          if (pageSize > 0 && (key === 'first' || key === 'page_size')) {
            out[key] = pageSize;
            continue;
          }
          if (pageSize > 0 && key === 'data') {
            out[key] = NativeSearch.withPageSize(src[key], pageSize);
            continue;
          }
          out[key] = src[key];
        }
        if (cursor.length > 0) {
          out['after'] = cursor;
        }
        parts[index] = `variables=${encodeURIComponent(JSON.stringify(out))}`;
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'vars patch failed: %{public}s', (error as Error).message);
      }
      break;
    }
    return parts.join('&');
  }

  /**
   * `data` 那层里如果有 `page_size`，换成新的每页条数；没有就原样返回。
   *
   * 单独拎出来是因为 `data` 是对象不是标量，只能重建（ArkTS 没有 delete，也不方便原地改）。
   */
  private static withPageSize(node: Object, pageSize: number): Object {
    const record: Record<string, Object> | null = JsonRead.asRecord(node);
    if (record === null) {
      return node;
    }
    const out: Record<string, Object> = {};
    const keys: Array<string> = Object.keys(record);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      out[key] = key === 'page_size' ? pageSize : record[key];
    }
    return out;
  }

  /**
   * 响应里的翻页信息：在整包里找那个带 `page_info` 的连接对象。
   *
   * 判据和 postsOf 一样是"按形状"：`page_info.has_next_page` 是布尔就听它的，
   * 只有 `end_cursor` 没有布尔值时，**按"还有下一页"处理**（有游标就能继续翻）；
   * 两样都没有才算到底 —— 不能因为解析不到就把列表锁死。
   */
  private static pageInfoOf(text: string): PageInfo {
    const root: Record<string, Object> = JsonRead.parse(text);
    let cursor: string = '';
    let hasMore: boolean = false;
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (cursor.length > 0 || hasMore) {
        return;
      }
      const info: Record<string, Object> | null = JsonRead.recordOf(node, 'page_info');
      if (info === null) {
        return;
      }
      cursor = JsonRead.strOf(info, 'end_cursor');
      if (JsonRead.has(info, 'has_next_page')) {
        hasMore = JsonRead.boolOf(info, 'has_next_page');
      } else {
        hasMore = cursor.length > 0;
      }
    });
    return new PageInfo(cursor, hasMore);
  }

  /**
   * 把模板请求体里 `variables=` 那一段的查词换掉。
   *
   * **按值 + 按键名双管齐下**（和页面脚本 searchResultsScript 的 patch 同一套判据）：
   *   - 值等于上一次查词的字符串（模板里存的就是那次搜索的词）→ 换成新词；
   *   - 键名像查词的（query / search_query / q / search_term / term / keyword）→ 换成新词。
   * 一次都没命中就不动它：宁可按原词发（至少是条合法请求），也不要猜错键把变量改坏
   * ——改坏了服务端只回一句 `noncoercible_variable_value`。
   */
  private static bodyWith(tpl: ApiTemplate, from: string, to: string): string {
    const body: string = tpl.body ?? '';
    if (body.length === 0 || to.length === 0) {
      return body;
    }
    const parts: Array<string> = body.split('&');
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].indexOf('variables=') !== 0) {
        continue;
      }
      try {
        const raw: string = decodeURIComponent(parts[index].substring('variables='.length));
        const src: Record<string, Object> = JsonRead.parse(raw);
        let hits: number = 0;
        const patched: Record<string, Object> = NativeSearch.patch(src, from, to, (): void => {
          hits++;
        });
        parts[index] = `variables=${encodeURIComponent(JSON.stringify(patched))}`;
        hilog.info(DOMAIN, TAG, 'patch query hits=%{public}d from=%{public}s to=%{public}s',
          hits, from, to);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'patch variables failed: %{public}s', (error as Error).message);
      }
      break;
    }
    return parts.join('&');
  }

  /** 递归改查词（返回新对象；ArkTS 里直接改嵌套值容易踩到只读，重建更稳）。 */
  private static patch(node: Record<string, Object>, from: string, to: string,
                       onHit: () => void): Record<string, Object> {
    const out: Record<string, Object> = {};
    const keys: Array<string> = Object.keys(node);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const value: Object = node[key];
      if (typeof value === 'string') {
        const text: string = value as string;
        if ((from.length > 0 && text === from) || NativeSearch.looksQueryKey(key)) {
          out[key] = to;
          onHit();
        } else {
          out[key] = text;
        }
        continue;
      }
      if (Array.isArray(value)) {
        const list: Array<Object> = value as Array<Object>;
        const copied: Array<Object> = [];
        for (let item: number = 0; item < list.length; item++) {
          const one: Record<string, Object> | null = JsonRead.asRecord(list[item]);
          copied.push(one === null ? list[item] : NativeSearch.patch(one, from, to, onHit));
        }
        out[key] = copied;
        continue;
      }
      const child: Record<string, Object> | null = JsonRead.asRecord(value);
      out[key] = child === null ? value : NativeSearch.patch(child, from, to, onHit);
    }
    return out;
  }

  /** 键名像不像"查词"（各版本叫法不同，见 bodyWith 的说明）。 */
  private static looksQueryKey(key: string): boolean {
    const lower: string = key.toLowerCase();
    return lower === 'query' || lower === 'search_query' || lower === 'q'
      || lower === 'search_term' || lower === 'term' || lower === 'keyword';
  }

  // ==========================================================================
  // 响应 → 模型（按形状扫，见文件头）
  // ==========================================================================

  /** 整包里所有"像用户"的对象（去重、限量）。 */
  private static usersOf(text: string): Array<SearchUser> {
    const root: Record<string, Object> = JsonRead.parse(text);
    const seen: Array<string> = [];
    const users: Array<SearchUser> = [];
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (users.length >= MAX_USERS) {
        return;
      }
      const username: string = JsonRead.strOf(node, 'username');
      if (username.length === 0 || seen.indexOf(username) >= 0) {
        return;
      }
      const hasPic: boolean = JsonRead.has(node, 'profile_pic_url');
      const hasName: boolean = JsonRead.has(node, 'full_name');
      if (!hasPic && !hasName) {
        return;
      }
      seen.push(username);
      const hd: Record<string, Object> | null = JsonRead.recordOf(node, 'hd_profile_pic_url_info');
      const hdUrl: string = hd === null ? '' : JsonRead.strOf(hd, 'url');
      const avatar: string = hdUrl.length > 0 ? hdUrl : JsonRead.strOf(node, 'profile_pic_url');
      // 数字 id（`pk`，退回 `id`）：点一下要进**原生用户主页**，那一页按 id 取数与定位
      // （见 model/Search 的 SearchUser.userId 与 pages/Index.openUserProfile）。
      const rawId: Object = node['pk'] ?? node['id'] ?? '';
      users.push(new SearchUser(username, JsonRead.strOf(node, 'full_name'), avatar,
        JsonRead.boolOf(node, 'is_verified'), JsonRead.boolOf(node, 'is_private'),
        `${rawId}`.trim()));
    });
    return users;
  }

  /** 整包里所有"像帖子"的对象（去重、限量）。 */
  private static postsOf(text: string): Array<SearchPost> {
    const root: Record<string, Object> = JsonRead.parse(text);
    const seen: Array<string> = [];
    const posts: Array<SearchPost> = [];
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (posts.length >= MAX_POSTS) {
        return;
      }
      if (!JsonRead.has(node, 'image_versions2') && !JsonRead.has(node, 'video_versions')
        && !JsonRead.has(node, 'carousel_media')) {
        return;
      }
      // 复用「我的」那条的取字段逻辑（视频首帧优先等判据只写一次，见 NativeProfile.postOf）。
      const mapped: SearchPost | null = NativeSearch.postOf(node);
      if (mapped === null || seen.indexOf(mapped.code) >= 0) {
        return;
      }
      seen.push(mapped.code);
      posts.push(mapped);
    }, (): boolean => posts.length >= MAX_POSTS);
    return posts;
  }

  /** 一个媒体节点 → 瀑布流要的字段；不是帖子给 null。 */
  private static postOf(node: Record<string, Object>): SearchPost | null {
    const inner: SearchPost | null = NativeSearch.readPost(node);
    if (inner !== null) {
      return inner;
    }
    // 多图帖：外层没有封面时取第一张子媒体（和 NativeProfile.postOf 同一套兜底）。
    const carousel: Array<Object> = JsonRead.arrayOf(node, 'carousel_media');
    if (carousel.length === 0) {
      return null;
    }
    const first: Record<string, Object> | null = JsonRead.asRecord(carousel[0]);
    return first === null ? null : NativeSearch.readPost(first);
  }

  /**
   * 单个节点的直读（不递归子媒体）。
   *
   * 封面走 `MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH)` —— 和全 app 的展示档
   * 挑选**同一套判据**（只是把目标宽度压到网格够用的 360，见 COVER_WIDTH），它返回的
   * `url / width / height` 是**同一张图**的三个字段。这一点是瀑布流的关键：
   * 格子高度按"这张图自己的比例"算，`ImageFit.Cover` 才不会裁到画面。
   * （踩过的坑：拿帖子的 `original_width/height` 去套封面 —— 视频帖那是视频帧的尺寸，
   *  和封面不是一张图；尺寸还常常缺，缺了就整批退化成同一个比例，看着就是"等高网格 + 图被裁"。）
   */
  private static readPost(node: Record<string, Object>): SearchPost | null {
    const code: string = JsonRead.strOf(node, 'code');
    if (code.length === 0) {
      return null;
    }
    const images: Record<string, Object> | null = JsonRead.recordOf(node, 'image_versions2');
    const candidates: Array<Object> = images === null ? [] : JsonRead.arrayOf(images, 'candidates');
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(candidates[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(JsonRead.numOf(one, 'width'));
      heights.push(JsonRead.numOf(one, 'height'));
    }
    const picked: PickedMedia = MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH);
    if (picked.url.length === 0) {
      // 没有可显示的静态封面（少数纯视频节点不给 image_versions2）：**不拿 .mp4 顶替**，
      // 那种地址喂给 Image() 只会得到一块空白，不如不放这一格。
      return null;
    }
    const videos: Array<Object> = JsonRead.arrayOf(node, 'video_versions');
    // 推荐流点开要进 **Reels 页**（需求）：所以除了封面，顺手把"播放要用的那几样"也带上 ——
    // 媒体 id（缺地址时按它去补）、视频地址（这条查询通常直接给）、作者名（页面左下角要显示）。
    const videoUrls: Array<string> = [];
    const videoWidths: Array<number> = [];
    const videoHeights: Array<number> = [];
    for (let index: number = 0; index < videos.length; index++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(videos[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length === 0) {
        continue;
      }
      videoUrls.push(url);
      videoWidths.push(JsonRead.numOf(one, 'width'));
      videoHeights.push(JsonRead.numOf(one, 'height'));
    }
    const display: PickedMedia = MediaQuality.displayVideo(videoUrls, videoWidths, videoHeights);
    const original: PickedMedia = MediaQuality.originalVideo(videoUrls, videoWidths, videoHeights);
    const rawId: Object = node['pk'] ?? node['id'] ?? '';
    const user: Record<string, Object> | null = JsonRead.recordOf(node, 'user');
    const username: string = user === null ? '' : JsonRead.strOf(user, 'username');
    const avatar: string = user === null ? '' : JsonRead.strOf(user, 'profile_pic_url');
    // 作者 pk：Reels 页那颗关注按钮要用（见 model/Reel 的 authorId）。
    const authorId: string = user === null ? ''
      : `${user['pk'] ?? user['id'] ?? ''}`.trim();
    const captionNode: Record<string, Object> | null = JsonRead.recordOf(node, 'caption');
    const caption: string = captionNode === null ? '' : JsonRead.strOf(captionNode, 'text');
    // 三个计数 + "本机点过赞没有"：推荐流那条和首页 clips 是同形状的响应
    // （见 core/NativeReels 里同一组字段），Reels 页右侧动作栏要用（用户报的"没有显示
    // 点赞评论转发数量"就是这里没接）。
    const liked: boolean = JsonRead.boolOf(node, 'has_liked')
      || JsonRead.boolOf(node, 'viewer_has_liked');
    // 关注状态（Reels 页那颗按钮）：挂在他/她的 `friendship_status.following` 上；
    // 没有这个字段就留 undefined，让界面自己问一次（见 model/Search 的 following）。
    let following: boolean | undefined = undefined;
    if (user !== null) {
      const friend: Record<string, Object> | null = JsonRead.recordOf(user, 'friendship_status');
      if (friend !== null) {
        if (JsonRead.has(friend, 'following')) {
          following = JsonRead.boolOf(friend, 'following');
        } else if (JsonRead.has(friend, 'followed_by_viewer')) {
          following = JsonRead.boolOf(friend, 'followed_by_viewer');
        }
      }
    }
    return new SearchPost(code, picked.url, picked.width, picked.height, videos.length > 0,
      `${rawId}`.trim(), display.url, original.url, username, avatar, authorId, caption,
      JsonRead.numOf(node, 'like_count'), JsonRead.numOf(node, 'comment_count'),
      JsonRead.numOf(node, 'media_repost_count'), liked, following);
  }

  /** 深度优先遍历整包 JSON，把每个"对象节点"交给回调。 */
  private static walk(node: Object, depth: number,
                      visit: (found: Record<string, Object>) => void,
                      stop: () => boolean = (): boolean => false): void {
    if (depth > MAX_DEPTH || node === null || typeof node !== 'object' || stop()) {
      return;
    }
    if (Array.isArray(node)) {
      const list: Array<Object> = node as Array<Object>;
      for (let index: number = 0; index < list.length; index++) {
        if (stop()) {
          return;
        }
        NativeSearch.walk(list[index], depth + 1, visit, stop);
      }
      return;
    }
    const record: Record<string, Object> | null = JsonRead.asRecord(node);
    if (record === null) {
      return;
    }
    visit(record);
    const keys: Array<string> = Object.keys(record);
    for (let index: number = 0; index < keys.length; index++) {
      const child: Object = record[keys[index]];
      if (child !== null && typeof child === 'object') {
        NativeSearch.walk(child, depth + 1, visit, stop);
      }
    }
  }

  /**
   * 结构摘要（探针用）：把"搜索 + 推荐来源"的模板逐条回放一次，只留"顶层键 + 样本字段"。
   *
   * 这是"写解析之前先看一眼真实结构"的工具 —— 和探针面板的「结构摘要」同一个用途，
   * 区别是这里**限定在这条链路用到的模板**（搜索那两条 + 推荐来源那几条）并返回文本好落盘。
   *
   * 为什么把推荐来源也算进来：摘要只认 'search' 的时候，推荐流（clips）的真实形状一直看不到，
   * 结果就是"封面尺寸/比例"这种字段只能靠猜（踩过：帖子网格整面退化成等高格子）。
   */
  static async digest(): Promise<string> {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    const names: Array<string> = registry.storedNames();
    const lines: Array<string> = [];
    let done: number = 0;
    for (let index: number = 0; index < names.length && done < 8; index++) {
      if (!NativeSearch.looksRelevant(names[index]) && !NativeSearch.looksRecommendSource(names[index])) {
        continue;
      }
      done++;
      const tpl: ApiTemplate | null = registry.storedForNative(names[index]);
      const method: string = tpl === null ? '?' : (tpl.method ?? 'POST');
      const url: string = tpl === null ? '?' : tpl.url;
      const body: string = tpl === null ? '' : (tpl.body ?? '');
      lines.push(`### ${names[index]} ${method} ${url} body=${body.length}`);
      const result: NativeSearchResult = await NativeSearch.post(names[index], '', '');
      if (!result.ok) {
        lines.push(`  http-fail ${result.detail}`);
        continue;
      }
      lines.push(NativeSearch.shapeOf(result.text));
    }
    if (lines.length === 0) {
      lines.push('no search templates stored');
    }
    return lines.join('\n');
  }

  /** 是不是"推荐来源"那几条（clips/reels）：摘要也要看它们的真实结构。 */
  private static looksRecommendSource(name: string): boolean {
    const lower: string = name.toLowerCase();
    for (let index: number = 0; index < CLIPS_HINTS.length; index++) {
      if (lower.indexOf(CLIPS_HINTS[index]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 响应结构摘要：`data` 下的键、以及**第一个像帖子/像用户的节点**的字段名。
   *
   * 只要字段名与少量样本值 —— 整包几十上百 KB，全打出来日志会刷屏（也过不了桥）。
   */
  private static shapeOf(text: string): string {
    const root: Record<string, Object> = JsonRead.parse(text);
    const out: Array<string> = [];
    const data: Record<string, Object> | null = JsonRead.recordOf(root, 'data');
    out.push(`  data.keys=${data === null ? '-' : Object.keys(data).slice(0, 8).join(',')}`);
    const errors: Array<Object> = JsonRead.arrayOf(root, 'errors');
    if (errors.length > 0) {
      const first: Record<string, Object> | null = JsonRead.asRecord(errors[0]);
      out.push(`  errors=${first === null ? '?' : JsonRead.strOf(first, 'message').substring(0, 120)}`);
    }
    let postSample: string = '';
    let userSample: string = '';
    NativeSearch.walk(root, 0, (node: Record<string, Object>): void => {
      if (postSample.length === 0 && JsonRead.has(node, 'code')
        && (JsonRead.has(node, 'image_versions2') || JsonRead.has(node, 'video_versions'))) {
        // 把**封面候选**的档位与挑中的那一张一并打出来：瀑布流的格子比例就来自它，
        // "整面网格等高 + 图被裁"这一类问题看这一行就能定位（尺寸有没有、挑的是哪档）。
        const images: Record<string, Object> | null = JsonRead.recordOf(node, 'image_versions2');
        const cands: Array<Object> = images === null ? [] : JsonRead.arrayOf(images, 'candidates');
        const widths: Array<number> = [];
        const heights: Array<number> = [];
        const urls: Array<string> = [];
        for (let index: number = 0; index < cands.length; index++) {
          const one: Record<string, Object> | null = JsonRead.asRecord(cands[index]);
          if (one === null) {
            continue;
          }
          const url: string = JsonRead.strOf(one, 'url');
          if (url.length === 0) {
            continue;
          }
          urls.push(url);
          widths.push(JsonRead.numOf(one, 'width'));
          heights.push(JsonRead.numOf(one, 'height'));
        }
        const picked: PickedMedia = MediaQuality.displayImageAt(urls, widths, heights, COVER_WIDTH);
        postSample = `  post.keys=${Object.keys(node).slice(0, 14).join(',')}`
          + ` code=${JsonRead.strOf(node, 'code')}`
          + ` original=${JsonRead.numOf(node, 'original_width')}x${JsonRead.numOf(node, 'original_height')}`
          + ` cands=${cands.length} [${widths.slice(0, 6).join('/')}]`
          + ` picked=${picked.width}x${picked.height}`
          + ` aspect=${picked.width > 0 && picked.height > 0
            ? Math.round(picked.width / picked.height * 1000) / 1000 : 0}`;
      }
      if (userSample.length === 0 && JsonRead.strOf(node, 'username').length > 0
        && JsonRead.has(node, 'profile_pic_url')) {
        userSample = `  user.keys=${Object.keys(node).slice(0, 12).join(',')}`;
      }
    });
    if (postSample.length > 0) {
      out.push(postSample);
    }
    if (userSample.length > 0) {
      out.push(userSample);
    }
    const posts: Array<SearchPost> = NativeSearch.postsOf(text);
    const users: Array<SearchUser> = NativeSearch.usersOf(text);
    out.push(`  scanned posts=${posts.length} users=${users.length}`);
    return out.join('\n');
  }
}
