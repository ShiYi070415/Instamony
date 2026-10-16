/*
 * 快拍**预加载 / 预缓存**（按"独立用户的 story"分页，队列形式）。
 *
 * 需求："stories 预加载和预缓存页做一下，缓存页按照独立用户 story 来分类，大概缓存五个用户的
 * story 就够了，采用队列形式，缓存页抽出一页就补新一页。"
 *
 * 所以这里就是一条**定长队列**，一页 = 一个用户的 StoryReel：
 *   · 托盘顺序到了、或者用户点开某一位时 `reset(items, from)`：以那一位为起点开始预取；
 *   · 队列最多 `DEPTH = 5` 页，**抽走一页**（`take`，用户真的翻到他了）立刻从托盘顺序里取
 *     下一位补到队尾 —— "抽出一页就补新一页"；
 *   · 每一页到手顺手把它的头几条媒体交给 `MediaPrefetch`（系统缓存下载）：播放页里那几张图
 *     于是直接命中缓存，不用现拉。
 *
 * 命中缓存时 `take()` 是**同步返回**的，播放页零等待 —— 这就是"点开不转圈"的来源；
 * 没命中才走 `fetch()`（网络，见 core/NativeStories.reel）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { NativeStories } from './NativeStories';
import { ApiThrottle } from './ApiThrottle';
import { MediaPrefetch } from './MediaPrefetch';
import { StoryItem, StoryReel, StoryTrayItem } from '../model/Story';

const DOMAIN: number = 0xFF00;
const TAG: string = 'StoryCache';
/** 缓存几个用户的 story（需求："大概缓存五个用户的 story 就够了"）。 */
const DEPTH: number = 5;
/** 每一页预下载头几条媒体（再多就是替用户白下了，反正他会停在第一条）。 */
const PREFETCH_ITEMS: number = 3;

/** 排队等闸门的一个请求。 */
class InflightPage {
  readonly userId: string;
  readonly generation: number;

  constructor(userId: string, generation: number) {
    this.userId = userId;
    this.generation = generation;
  }
}

export class StoryCache {
  /** 已缓存的页（队头 = 最先被用到的那个用户）。 */
  private static pages: Array<StoryReel> = [];
  /** 托盘那一整条顺序（"下一位是谁"从这里取）。 */
  private static tray: Array<StoryTrayItem> = [];
  /** 下一位要从托盘顺序的哪个下标开始预取。 */
  private static cursor: number = 0;
  /** 正在取数的页数（避免重复并发同一个用户）。 */
  private static loading: number = 0;
  /**
   * **正在路上**的页（`userId` + 发出时的代次）。
   *
   * 为什么光有 `loading` 计数不够（真机日志实测出来的）：
   * 加入限速闸门之后，一发要排 ~1 秒才发出去、回来得更晚 —— 于是"队列还空着"这个窗口
   * 从两百毫秒变成了好几秒。启动时 `ensure()` 会被调两次（预热链一次、托盘挂载
   * `onStoryLoaded` 一次），两次都看到 `pages` 为空 → **同一批 5 位用户被发了两遍**
   * （日志：同一秒里 5 位用户各两发）。白打的那批还会占住闸门，把真正要用的那批往后顶。
   * 所以这里按"谁在路上"记一份，`ensure` 与 `fill` 都拿它判重。
   *
   * 记**代次**是为了不误伤：用户点了别人触发 `reset()` 之后，上一代在飞的页已经作废，
   * 不该再挡住新一代的取数（它们在响应回来时按代次丢弃，并从这里移除）。
   */
  private static inflight: Array<InflightPage> = [];
  /**
   * 队列代次（每次 `reset()` +1）。
   *
   * 用途：`reset()` 会作废在飞的那几发请求 —— 它们回来时若代次已变，就**不再写缓存、也不动
   * `loading`**（否则 `loading` 会虚高到 `≥DEPTH`，`fill()` 的条件永久为假，预缓存静默停摆）。
   */
  private static generation: number = 0;

  /**
   * 保证"从第 `from` 位开始"的若干页都在队列里（托盘**可见范围**变化时调它）。
   *
   * 和 `reset` 的区别：已经在队列里、而且起点还在可见范围附近时**什么都不做**（不白扔已取好的
   * 页、也不重复打接口）；只有起点跑远了（用户横向滚了托盘）才重新以新起点预取。
   * 这就是"显示在屏幕中的用户 stories 提前加载"的入口。
   */
  static ensure(items: Array<StoryTrayItem>, from: number): void {
    const start: number = from >= 0 ? from : 0;
    if (StoryCache.pages.length > 0) {
      const first: number = StoryCache.indexOf(items, StoryCache.pages[0].userId);
      // 已有队列的起点落在 [start, start+3] 里 → 可见的那几位都盖住了，不用动。
      if (first >= start && first <= start + 3) {
        return;
      }
    }
    /*
     * 队列虽然还空着，但**同一代次已经有一批在路上**（见 inflight 的说明）：
     * 这一批马上就会把队列填上，这里再 reset 一次就是白打 5 发。
     * 判据与上面一致 —— 在飞那批的**起点**落在可见范围里就够了。
     */
    const flying: number = StoryCache.inflightStart(items);
    if (flying >= 0 && flying >= start && flying <= start + 3) {
      hilog.info(DOMAIN, TAG, 'ensure skip: inflight from=%{public}d start=%{public}d',
        flying, start);
      return;
    }
    StoryCache.reset(items, start);
  }

  /** 同一代次里**在飞那批**在托盘顺序里的起点下标（没有给 -1）。 */
  private static inflightStart(items: Array<StoryTrayItem>): number {
    let best: number = -1;
    for (let index: number = 0; index < StoryCache.inflight.length; index++) {
      const one: InflightPage = StoryCache.inflight[index];
      if (one.generation !== StoryCache.generation) {
        continue;
      }
      const at: number = StoryCache.indexOf(items, one.userId);
      if (at >= 0 && (best < 0 || at < best)) {
        best = at;
      }
    }
    return best;
  }

  /** 某一位是不是正在路上（只看当前代次）。 */
  private static inFlight(userId: string): boolean {
    for (let index: number = 0; index < StoryCache.inflight.length; index++) {
      const one: InflightPage = StoryCache.inflight[index];
      if (one.userId === userId && one.generation === StoryCache.generation) {
        return true;
      }
    }
    return false;
  }

  /** 从"在飞"名单里移除一条（响应回来时调，成败都要调）。 */
  private static clearInflight(userId: string, generation: number): void {
    for (let index: number = StoryCache.inflight.length - 1; index >= 0; index--) {
      const one: InflightPage = StoryCache.inflight[index];
      if (one.userId === userId && one.generation === generation) {
        StoryCache.inflight.splice(index, 1);
      }
    }
  }

  /** 某位用户在托盘顺序里的下标（找不到给 -1）。 */
  private static indexOf(items: Array<StoryTrayItem>, userId: string): number {
    for (let index: number = 0; index < items.length; index++) {
      if (items[index].userId === userId) {
        return index;
      }
    }
    return -1;
  }

  /** 现在缓存了几页 / 正在取几页（日志用）。 */
  static size(): number {
    return StoryCache.pages.length;
  }

  static pending(): number {
    return StoryCache.loading;
  }

  /**
   * 重置队列：以托盘顺序里的第 `from` 位为起点开始预取。
   *
   * 什么时候调：
   *   · 托盘刚拉到（`from = 0`）→ 先把前五个用户热起来；
   *   · 用户点开某一位（`from = 他点的下标`）→ 队列对齐到他，保证"下一位"就在缓存里。
   */
  static reset(items: Array<StoryTrayItem>, from: number): void {
    StoryCache.tray = items;
    StoryCache.pages = [];
    StoryCache.cursor = from >= 0 ? from : 0;
    /*
     * **`loading` 必须归零，并且作废在飞的那几发请求**（审计发现的静默失效）。
     *
     * 原来 reset 只清队列、不动 `loading`：清空时正在飞的那几发请求回来后照样 `loading--`，
     * 于是 `loading` 会虚高甚至变负；`Index` 冷启动里 reset 被调了两次（预热一次 + 托盘
     * `onStoryLoaded` 一次），`loading` 涨到 `≥DEPTH` 之后 `fill()` 的 while 条件**永久为假** ——
     * 预缓存整条链就静默停摆了（点开快拍只能现拉，日志里也看不出为什么）。
     * generation 的作用是让那几发"上一代"的响应回来后**不再写缓存、也不再动计数**。
     */
    StoryCache.generation = StoryCache.generation + 1;
    StoryCache.loading = 0;
    hilog.info(DOMAIN, TAG, 'reset from=%{public}d of=%{public}d gen=%{public}d',
      StoryCache.cursor, items.length, StoryCache.generation);
    StoryCache.fill();
  }

  /** 某一位在不在队列里（宿主点开之前先问一下：已在队列里就不要 reset，否则白扔一次预取）。 */
  static has(userId: string): boolean {
    for (let index: number = 0; index < StoryCache.pages.length; index++) {
      if (StoryCache.pages[index].userId === userId) {
        return true;
      }
    }
    return false;
  }

  private static inQueue(userId: string): boolean {
    return StoryCache.has(userId);
  }

  /**
   * 抽走某一位的缓存页（命中即从队列里拿走，并立刻补新的一页）。
   *
   * @returns 命中的 StoryReel；没缓存过给 null（调用方走网络）。
   */
  static take(userId: string): StoryReel | null {
    for (let index: number = 0; index < StoryCache.pages.length; index++) {
      if (StoryCache.pages[index].userId === userId) {
        const page: StoryReel = StoryCache.pages[index];
        StoryCache.pages.splice(index, 1);
        hilog.info(DOMAIN, TAG, 'take hit uid=%{public}s n=%{public}d left=%{public}d',
          userId, page.items.length, StoryCache.pages.length);
        StoryCache.fill();
        return page;
      }
    }
    hilog.info(DOMAIN, TAG, 'take miss uid=%{public}s cached=%{public}d',
      userId, StoryCache.pages.length);
    return null;
  }

  /**
   * 没有缓存时的兜底取数（走网络），回来顺手把队列补满。
   *
   * 注意：这一页是"立刻要用"的，所以**不进队列**（进了就重复占一个位置）。
   *
   * @param altIds 这条托盘条目的备选 id（见 StoryTrayItem.altIds）：主 id 问不出内容时，
   *   取数那边会拿它们再试 —— "只有部分用户点开提示没取到"那一类就靠它兜住。
   */
  static async fetch(userId: string, altIds: Array<string> = [],
                     username: string = ''): Promise<StoryReel | null> {
    /*
     * **交互优先级**：这一发是用户此刻点开的快拍 —— 排在预取/自检前面（见 ApiThrottle.acquire）。
     * 不给的话，它要等在飞的那几发预取后面（最多 5 发 × 约 1 秒的间隔），
     * 现象就是"点了快拍要等几秒才出来"。
     */
    const reel: StoryReel | null = await NativeStories.reel(userId, altIds, username,
      ApiThrottle.interactive());
    if (reel !== null) {
      StoryCache.warmMedia(reel);
    }
    StoryCache.fill();
    return reel;
  }

  /** 把"还缺几页"补齐（火并忘，失败就跳过那一位，不阻塞任何人）。 */
  private static fill(): void {
    while (StoryCache.pages.length + StoryCache.loading < DEPTH
      && StoryCache.cursor < StoryCache.tray.length) {
      const item: StoryTrayItem = StoryCache.tray[StoryCache.cursor];
      StoryCache.cursor = StoryCache.cursor + 1;
      // 已经在队列里的（同一个人可能被点到两次）不重复取；**已经在路上的也不重复取**
      // （后者是加了限速闸门之后才暴露出来的重复源，见 inflight 的说明）。
      if (StoryCache.inQueue(item.userId) || StoryCache.inFlight(item.userId)) {
        continue;
      }
      StoryCache.loading = StoryCache.loading + 1;
      // 预取也带上备选 id 与用户名（同一个理由：id 字段可能不是 pk；用户名给"故事页抓模板"那条路用）。
      StoryCache.loadOne(item.userId, item.altIds, item.username);
    }
  }

  private static loadOne(userId: string, altIds: Array<string> = [],
                         username: string = ''): void {
    // 发这一发时的代次：回来时对不上就整发丢弃（见 generation 的说明）。
    const gen: number = StoryCache.generation;
    StoryCache.inflight.push(new InflightPage(userId, gen));
    // 交互优先级**不在这里**：预取是后台行为，用户真点开那一发走 StoryCache.fetch（见那里）。
    NativeStories.reel(userId, altIds, username).then((reel: StoryReel | null): void => {
      // **先从"在飞"名单里摘掉**（成败、代次对不对都要摘，否则那一页永远挡住重取）。
      StoryCache.clearInflight(userId, gen);
      /*
       * **代次对不上 = 这一发是上一次 `reset()` 之前发的，结果属于旧队列**。
       *
       * 丢掉的理由有两条，都不是洁癖：
       *   ① 写进去就是"把旧起点那几页塞进新队列"（用户已经点了别的用户，队列该从新的起点排）；
       *   ② `loading--` 会把**新一代**的计数扣到负数，而 `fill()` 的判据是
       *      `pages + loading < DEPTH` —— 负数会让它**多要几发**请求，等于白打接口。
       * `reset()` 已经把 `loading` 归零了，所以旧响应什么都不该动。
       */
      if (gen !== StoryCache.generation) {
        hilog.info(DOMAIN, TAG, 'drop stale uid=%{public}s gen=%{public}d now=%{public}d',
          userId, gen, StoryCache.generation);
        return;
      }
      StoryCache.loading = StoryCache.loading - 1;
      if (reel !== null && reel.items.length > 0) {
        StoryCache.pages.push(reel);
        StoryCache.warmMedia(reel);
        hilog.info(DOMAIN, TAG, 'cached uid=%{public}s n=%{public}d pages=%{public}d',
          userId, reel.items.length, StoryCache.pages.length);
      } else {
        hilog.info(DOMAIN, TAG, 'skip uid=%{public}s why=%{public}s',
          userId, NativeStories.lastDetail());
      }
      // 补下一页（成功失败都继续，别让一次失败把队列饿住）。
      StoryCache.fill();
    }).catch((): void => {
      // 抛异常这条路也要摘（否则那一页永久挡住重取）。
      StoryCache.clearInflight(userId, gen);
      if (gen !== StoryCache.generation) {
        return;
      }
      StoryCache.loading = StoryCache.loading - 1;
      StoryCache.fill();
    });
  }

  /** 预下载这一页的头几条媒体（系统缓存下载，Image 组件会命中）。 */
  private static warmMedia(reel: StoryReel): void {
    const urls: Array<string> = [];
    for (let index: number = 0; index < reel.items.length && index < PREFETCH_ITEMS; index++) {
      const item: StoryItem = reel.items[index];
      if (item.imageUrl.length > 0) {
        urls.push(item.imageUrl);
      }
    }
    if (urls.length > 0) {
      MediaPrefetch.prefetch(urls);
    }
  }
}
