/*
 * 限时快拍托盘（主页 feeds 流上方那条）与单条快拍的**取数** —— 只走移动端私有接口
 * （`core/mobileapi/MobileStories`，instagrapi 同源）：
 *   · 托盘   `POST/GET feed/reels_tray/`
 *   · 某人   `GET feed/user/{uid}/story/` 与 `GET feed/reels_media/?reel_ids=…`
 *
 * 解析**不写死键名**：托盘的键名与"看过没有"的字段名各版本不一样（`tray` / `reels_tray`、
 * `seen` / `is_seen` / `view_state`…），所以字段读取都走候选键 + 结构特征。
 *
 * 历史：这里原来还有"回放网页抓来的 PolarisStories 模板""换三种身份打网页主机""读故事页
 * 渲染出来的媒体"三条退路 —— 页面注入退役后模板抓不到、`x-ig-www-claim` 也拿不到，全部删除。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { ApiThrottle } from './ApiThrottle';
import { JsonRead } from './JsonRead';
import { StoryItem, StoryReel, StoryTray, StoryTrayItem } from '../model/Story';
import { MobileStories } from './mobileapi/MobileStories';
import { MobileChallenge } from './mobileapi/MobileChallenge';
// 托盘落盘缓存（每次成功都写一份，冷启动先画它，见 core/TrayCache）。
import { TrayCache } from './TrayCache';
// 「是不是我自己的快拍」要读当前会话的 `ds_user_id`（见 reelOf 里 selfReel 那一段）。
import { NativeProfile } from './NativeProfile';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeStories';
/** 图片快拍没有时长，按 5 秒播（和 Instagram 自己的默认一致）。 */
const IMAGE_DURATION_MS: number = 5000;
/** 视频快拍的候选时长键（秒，浮点）。 */
const DURATION_KEYS: Array<string> = ['video_duration', 'duration'];
/** 快拍数组元素的候选"媒体类型"键（2 = 视频）。 */
const MEDIA_TYPE_KEYS: Array<string> = ['media_type', 'mediaType'];
/** "看过没有"的候选键（顺序即优先级）。 */
const SEEN_KEYS: Array<string> = ['seen', 'is_seen', 'all_seen', 'viewed', 'is_viewed'];
/** 用户名 / 头像 / id 的候选键。 */
const NAME_KEYS: Array<string> = ['username', 'user_name'];
const AVATAR_KEYS: Array<string> = ['profile_pic_url', 'profile_pic_url_hd'];
const ID_KEYS: Array<string> = ['pk', 'id', 'user_id', 'strong_id__'];

export class NativeStories {
  private static detail: string = '-';
  /**
   * **已经关注过的"推荐快拍"**（userId 集合）。
   *
   * 需求："头像底部…点击后关注并消失"。光把它从界面数组里删掉不够：托盘缓存只有 3 分钟
   * （见 StoriesTray.TRAY_FRESH_MS），过期后我们会重新拉一次 `feed/reels_tray/`，
   * 而 IG 那边**这次**的推荐位多半还带着他（关注关系刚落库）—— 于是刚点过关注的那一项
   * 又冒出来了。所以在取数这一层就把它们滤掉：这一轮会话里不再出现，换账号时清空。
   */
  private static followedSuggested: Set<string> = new Set<string>();
  /**
   * **最近一次拿到的托盘**（含时间戳）。
   *
   * 为什么必须留一份：启动预热链（`warmOtherTabs` 的 `stories` 那一步）和托盘组件自己的
   * `aboutToAppear` 会**各发一发** `feed/reels_tray/`。真机实测（18:08 的日志）：
   * 第一发拿到 12 条推荐快拍，第二发回 `tray:[]` —— IG 的推荐位**一轮只发一次**，
   * 于是界面上刚长出来的推荐又被第二发抹成空（用户报的"快拍推荐数据没有加载"）。
   *
   * 现在：短窗口内（TRAY_REUSE_MS）直接复用这一份，不再打接口；更久之后真发了
   * 却回了空，也退回这一份（TRAY_STALE_FALLBACK_MS 之内），不让推荐位凭空消失。
   */
  private static lastTray: StoryTray | null = null;
  private static lastTrayAt: number = 0;
  /** 正在飞的那一发（见 tray 的说明：并发请求直接搭这一发，不各打一次）。 */
  private static trayInflight: Promise<StoryTray | null> | null = null;
  /** 这份托盘多久之内可以直接复用（毫秒）：避免"预热 + 组件"两发打同一个接口。 */
  private static readonly TRAY_REUSE_MS: number = 10 * 60 * 1000;
  /** 新鲜那发回了空时，旧的这一份还能顶多久（毫秒）：推荐位一轮只发一次，空了不代表没内容。 */
  private static readonly TRAY_STALE_FALLBACK_MS: number = 30 * 60 * 1000;
  /**
   * 每个用户各自的**逐候选轨迹**（uid → 行数组，最多留 TRACE_MAX 行）。
   *
   * 为什么必须留（用户报的"点开快拍说没取到"）：这条链一次可能发好几发、每发的身份和 URL 都不同，
   * 失败原因（`http-500` / `http-4xx` / 非 JSON / 抛 / 真的没内容）**只有逐发看才能定位**；
   * 而 hilog 在真机上被 chromium 冲得几秒就没了（我们自己的 INFO 行根本留不住）。
   *
   * 为什么按 uid 分开（用户回传的诊断文件暴露的第二个问题）：托盘预取会**并发**对 5 位用户
   * 各发一次 `reel()`，而轨迹原来是一个全局数组 —— 于是一次失败记录里混进了**六个人的 URL**，
   * 根本看不出"被点的那位到底收到了什么"。现在按 uid 存，报告里只看这一位的轨迹。
   */
  private static traces: Map<string, Array<string>> = new Map<string, Array<string>>();
  /** 轨迹最多留几行（四发 + 头尾各留一点余量）。 */
  private static readonly TRACE_MAX: number = 12;
  /** 最多给几个用户留轨迹（防止长时间浏览把内存撑起来）。 */
  private static readonly TRACE_UIDS_MAX: number = 24;
  /**
   * 托盘里每条条目的**原始 JSON**（userId → 该条目的 JSON 文本，截断保存）。
   *
   * 两个用途，都是"远端用户复现时我们看不到现场"逼出来的：
   *   ① **兜底**：`reels_media` 不给内容时，用手上这份条目自己带的 media 拼一条（见 reelFromTrayNode）；
   *   ② **诊断**：写进 `storyfail_*.txt` 的 `raw[node]=…` —— entry 里到底有哪些 id / 有没有 items，
   *      只有原始数据能说清（我们解析出来的那几个字段不够）。
   */
  private static nodeRaw: Map<string, string> = new Map<string, string>();
  /** 原始条目最多留多少条（托盘的 143 条也没必要全留）。 */
  private static readonly NODE_RAW_MAX: number = 80;
  /** 每条原始 JSON 截断到多少字符（够看清键名与值，又不至于让内存里的字符串太大）。 */
  private static readonly NODE_RAW_CHARS: number = 1200;
  /**
   * 每条条目的**形状摘要**（userId → `reel_type=… besties=… expiring=… …`）。
   *
   * 为什么单存这个而不是只留原始 JSON：真机上 80 条条目的 JSON 全在 1200 字符处被截断
   * （`items`/`user` 都排在后面），**恰恰是这几个短字段能一眼看出"这条该不该有快拍"**：
   *   · `reel_type` —— 只有 `user_reel` 才是"某个用户的快拍"；别的类型拿用户 pk 去问
   *     `reels_media` 本来就该是空的；
   *   · `has_besties_media` / `latest_besties_reel_media` —— 只发给"密友"的那部分快拍；
   *   · `expiring_at` —— 过期时刻（用来算"我们问的时候是不是已经过期了"）。
   */
  private static nodeShape: Map<string, string> = new Map<string, string>();

  /** 记一条条目的形状摘要（读的就是托盘原始字段，见 nodeShape 的说明）。 */
  private static rememberShape(userId: string, node: Record<string, Object>,
                               user: Record<string, Object> | null): void {
    if (userId.length === 0 || NativeStories.nodeShape.has(userId)) {
      return;
    }
    const reelType: string = JsonRead.strOf(node, 'reel_type');
    const besties: boolean = JsonRead.boolOf(node, 'has_besties_media');
    const latest: number = JsonRead.numOf(node, 'latest_reel_media');
    const expiring: number = JsonRead.numOf(node, 'expiring_at');
    const seen: number = JsonRead.numOf(node, 'seen');
    const nodeId: string = JsonRead.strOf(node, 'id');
    const userPk: string = user === null ? '' : JsonRead.strOf(user, 'pk');
    NativeStories.nodeShape.set(userId,
      `reel_type=${reelType.length > 0 ? reelType : '(none)'} besties=${besties}`
      + ` latest_reel_media=${latest} expiring_at=${expiring} seen=${seen}`
      + ` entryItems=${JsonRead.arrayOf(node, 'items').length}`
      + ` node.id=${nodeId.length > 0 ? nodeId : '(none)'}`
      + ` user.pk=${userPk.length > 0 ? userPk : '(none)'}`);
  }

  /** 某一轮托盘的形状摘要（userId → 摘要行），供诊断落盘。 */
  static shapesDump(): Array<string> {
    const out: Array<string> = [];
    NativeStories.nodeShape.forEach((value: string, key: string): void => {
      out.push(`uid=${key} ${value}`);
    });
    return out;
  }

  /**
   * 把这一轮托盘的**原始条目**整理成文本（诊断：进 `Instarmony_diag.txt`，见 core/StoryDiag）。
   *
   * 为什么值得单独留一份：托盘条目的形状**按账号/设备不一样**（带不带 `user`、有没有 `items`、
   * id 字段叫什么），而"点开快拍 empty 只有部分用户"恰恰取决于这些差异 ——
   * 只留我们自己解析出来的那几个字段，等于把判断依据丢了。
   */
  static rawNodes(): Array<string> {
    const out: Array<string> = [];
    NativeStories.nodeRaw.forEach((value: string, key: string): void => {
      out.push(`uid=${key} ${value}`);
    });
    return out;
  }

  /** 记下一条条目的原始 JSON（见 nodeRaw 的说明）。 */
  private static rememberNode(userId: string, node: Record<string, Object>): void {
    if (userId.length === 0 || NativeStories.nodeRaw.has(userId)) {
      return;
    }
    if (NativeStories.nodeRaw.size >= NativeStories.NODE_RAW_MAX) {
      return;
    }
    try {
      let text: string = JSON.stringify(node);
      if (text.length > NativeStories.NODE_RAW_CHARS) {
        text = text.substring(0, NativeStories.NODE_RAW_CHARS);
      }
      NativeStories.nodeRaw.set(userId, text);
    } catch (error) {
      // 循环引用之类：存一份标记就够了，诊断时看得出"没存成"。
      NativeStories.nodeRaw.set(userId, '(stringify-failed)');
    }
  }

  static lastDetail(): string {
    return NativeStories.detail;
  }

  /**
   * 把一位"推荐快拍"从后续托盘里永久滤掉（用户点了关注，见 followedSuggested 的说明）。
   *
   * 只影响这一轮会话：换账号时 `clearHidden()`。
   */
  static hideSuggested(userId: string): void {
    if (userId.length > 0) {
      NativeStories.followedSuggested.add(userId);
    }
  }

  /** 换账号 / 退出登录：把"已关注过的推荐"那张表清掉（那是上一个人的关注关系）。 */
  static clearHidden(): void {
    NativeStories.followedSuggested.clear();
  }

  /** 记下"最新这份合格的托盘"（见 lastTray 的说明）。 */
  private static rememberTray(tray: StoryTray): void {
    NativeStories.lastTray = tray;
    NativeStories.lastTrayAt = Date.now();
  }

  /**
   * 新鲜那发回了空（或失败）时的兜底：手上那份还不太旧就顶上。
   *
   * 为什么不让它一直顶：快拍 24 小时就过期，托盘内容本来就会变空；超过
   * `TRAY_STALE_FALLBACK_MS` 之后就该如实显示空（用户发的快拍真的都过期了）。
   */
  private static staleFallback(nowMs: number): StoryTray | null {
    if (NativeStories.lastTray === null || NativeStories.lastTray.items.length === 0) {
      return null;
    }
    const ageMs: number = nowMs - NativeStories.lastTrayAt;
    if (ageMs >= NativeStories.TRAY_STALE_FALLBACK_MS) {
      hilog.info(DOMAIN, TAG, 'tray empty and cached too old age=%{public}dms → give up', ageMs);
      return null;
    }
    hilog.info(DOMAIN, TAG, 'tray empty → reuse cached age=%{public}dms n=%{public}d',
      ageMs, NativeStories.lastTray.items.length);
    NativeStories.detail = '-cached';
    return NativeStories.lastTray;
  }

  /** 换账号 / 退出登录：上一份托盘属于上一个人，整个作废。 */
  static forgetTray(): void {
    NativeStories.lastTray = null;
    NativeStories.lastTrayAt = 0;
  }

  /**
   * "推荐快拍的候选账号"由宿主提供（首页那一排「为你推荐」里的作者）。
   *
   * 为什么放在宿主：这些账号来自信息流，而 `core` 不该直接依赖页面的数据；
   * 钩子为空时整条兜底路径直接跳过（行为和没有它一样）。
   */
  private static suggestSource: (() => Array<StoryTrayItem>) | null = null;

  static setSuggestSource(provider: () => Array<StoryTrayItem>): void {
    NativeStories.suggestSource = provider;
  }

  /** 兜底一次最多问几位（每一位 1~2 发，别把新号的启动打成请求风暴）。 */
  private static readonly SUGGEST_MAX: number = 3;
  /** 兜底最多凑几条（够铺满半屏就行）。 */
  private static readonly SUGGEST_KEEP: number = 3;

  /**
   * **用"为你推荐"里的账号现拼一条推荐快拍**（IG 自己那份没发下来时的兜底）。
   *
   * 为什么需要（真机证据）：新号关注 0 人时，IG 的推荐位**大约一小时才发一轮**，
   * 而我们的托盘每开一次就要问一次 —— 绝大多数时候回的是 `tray:[]`，界面上就只剩
   * 「你的快拍」（用户报的"还是没有显示快拍推荐"）。既然首页本来就在铺「为你推荐」，
   * 就拿那几个公开账号去问"有没有快拍"：有内容的才留下来，标成推荐快拍
   * （于是头像底部那条「+关注」胶囊、点开播放页的关注按钮都照常工作）。
   *
   * 只问前 3 位、凑到 3 条就停：这是兜底，不是主路径。
   */
  private static async trayFromSuggestions(): Promise<StoryTray | null> {
    if (NativeStories.suggestSource === null) {
      return null;
    }
    const candidates: Array<StoryTrayItem> = NativeStories.suggestSource();
    if (candidates.length === 0) {
      return null;
    }
    const items: Array<StoryTrayItem> = [];
    for (let index: number = 0; index < candidates.length
      && index < NativeStories.SUGGEST_MAX && items.length < NativeStories.SUGGEST_KEEP; index++) {
      const one: StoryTrayItem = candidates[index];
      /*
       * **idle 优先级**：这条兜底链要连问好几位（每位 1~2 发），全走 warm 会把启动那段
       * 限速闸门塞满 —— 真机日志里"进我的页面拿头部"因此要在闸门后面等 3~4 秒。
       * 它是"兜底数据"，晚几秒到没关系；交互请求（用户点开的那一发）会插到它前面。
       */
      const reel: StoryReel | null = await MobileStories.reel(one.userId, [], one.username,
        ApiThrottle.idle());
      if (reel === null || reel.items.length === 0) {
        hilog.info(DOMAIN, TAG, 'suggest story miss uid=%{public}s name=%{public}s',
          one.userId, one.username);
        continue;
      }
      items.push(new StoryTrayItem(one.userId,
        one.username.length > 0 ? one.username : reel.username,
        one.avatarUrl.length > 0 ? one.avatarUrl : reel.avatarUrl,
        false, reel.items.length, [], false, true, true, false));
      hilog.info(DOMAIN, TAG, 'suggest story ok uid=%{public}s name=%{public}s n=%{public}d',
        one.userId, one.username, reel.items.length);
    }
    if (items.length === 0) {
      return null;
    }
    NativeStories.detail = '-suggest';
    hilog.info(DOMAIN, TAG, 'tray via suggestions n=%{public}d', items.length);
    return new StoryTray(items);
  }

  /** 取数之后统一过一遍：已关注过的推荐不再出现（托盘条目、顺序、预取都跟着少一位）。 */
  private static pruneHidden(tray: StoryTray): StoryTray {    if (NativeStories.followedSuggested.size === 0) {
      return tray;
    }
    const kept: Array<StoryTrayItem> = [];
    for (let index: number = 0; index < tray.items.length; index++) {
      const one: StoryTrayItem = tray.items[index];
      if (one.suggested && NativeStories.followedSuggested.has(one.userId)) {
        continue;
      }
      kept.push(one);
    }
    if (kept.length === tray.items.length) {
      return tray;
    }
    hilog.info(DOMAIN, TAG, 'tray pruned followed-suggested %{public}d → %{public}d',
      tray.items.length, kept.length);
    return new StoryTray(kept, tray.selfAvatar);
  }

  /** 记一行轨迹（按 uid 分开存，见 traces 的说明）。 */
  private static note(userId: string, line: string): void {
    let list: Array<string> | undefined = NativeStories.traces.get(userId);
    if (list === undefined) {
      // 控制在 TRACE_UIDS_MAX 个用户以内：满了就整表清空（诊断够用，不做 LRU）。
      if (NativeStories.traces.size >= NativeStories.TRACE_UIDS_MAX) {
        NativeStories.traces.clear();
      }
      list = [];
      NativeStories.traces.set(userId, list);
    }
    list.push(line);
    while (list.length > NativeStories.TRACE_MAX) {
      list.shift();
    }
  }

  /** 某一位的轨迹（没有就给空数组）。 */
  private static traceOf(userId: string): Array<string> {
    const list: Array<string> | undefined = NativeStories.traces.get(userId);
    return list === undefined ? [] : list;
  }

  /** 开一次新尝试：清掉这一位的旧轨迹（同一位被点两次时不会把上一次的行混进来）。 */
  private static resetTrace(userId: string): void {
    NativeStories.traces.set(userId, []);
  }

  /**
   * 把"这一次为什么没取到"整理成一段可读文本（落文件用，见 pages/Index.dumpProbeFile）。
   *
   * 内容刻意全都是**下次能直接判定的东西**：问了哪个 uid、托盘的原始条目、缓存队列状态。
   */
  static failureReport(userId: string, username: string, trayCount: number,
                       trayHead: string, queueIndex: number, cachedAvailable: boolean,
                       trayAgeMs: number): string {
    const lines: Array<string> = [];
    lines.push(`Instamony 快拍取数失败 uid=${userId} name=${username}`);
    lines.push(`detail=${NativeStories.detail}`);
    lines.push(`tray items=${trayCount} at=${queueIndex} storyCacheHas=${cachedAvailable}`);
    /*
     * 托盘那份数据有多旧。这一条是**判断"快拍已经过期"还是"我们问错了 id"的关键**：
     * 托盘的种子最长允许 3 分钟（见 StoriesTray.TRAY_FRESH_MS），期间 IG 侧完全可能有人的
     * 快拍刚好到期 —— 那种情况下托盘还列着他，而 `reels_media` 已经回空。
     */
    lines.push(`tray age=${trayAgeMs}ms (~${Math.round(trayAgeMs / 1000)}s)`);
    lines.push(`tray head=${trayHead}`);
    /*
     * **这一条条目的原始 JSON**（见 nodeRaw 的说明）：`reels_media` 回空时，判断"是我们取错了 id
     * 字段 / 条目来自别的分区 / 根本就没带 media"，只有原始数据能说清 —— 我们解析出来的那几个
     * 字段（uid/username/seen/count）不足以区分这几种。
     */
    const raw: string | undefined = NativeStories.nodeRaw.get(userId);
    lines.push(`raw[node]=${raw === undefined ? '(not kept)' : raw}`);
    /*
     * **形状摘要**（见 nodeShape）：比上面那坨截断的 JSON 好读，
     * 而且直接回答了"这条该不该有快拍"——`reel_type` 不是 `user_reel`、或者
     * `expiring_at` 已经过去，那 `empty` 就是**正常**结果，不是我们的 bug。
     */
    const shape: string | undefined = NativeStories.nodeShape.get(userId);
    lines.push(`shape=${shape === undefined ? '(not kept)' : shape}`);
    lines.push('== 这一位的逐发轨迹 ==');
    const trace: Array<string> = NativeStories.traceOf(userId);
    for (let index: number = 0; index < trace.length; index++) {
      lines.push(`  ${trace[index]}`);
    }
    if (trace.length === 0) {
      lines.push('  (空：还没发过请求就被判定失败 —— 看 detail)');
    }
    return lines.join('\n');
  }

  /**
   * 拉一条**精选快拍（高光）**的媒体（个人页那一排点开后播的就是它）。
   *
   * 薄包装：真正的端点与解析在 core/mobileapi/MobileStories.highlightReel
   * （`feed/reels_media/?reel_ids=highlight:<id>&source=highlight`）。
   */
  static async highlightReel(id: string, title: string): Promise<StoryReel | null> {
    return MobileStories.highlightReel(id, title);
  }

  /**
   * 拉一次托盘（拿不到给 null）。
   *
   * **同一时刻只跑一发**：启动预热、托盘组件挂载、以及"推荐快拍"兜底的重试可能同时来要，
   * 每一发都会各打一次 `feed/reels_tray/`（兜底那条还会各问几位候选人）—— 并发重复
   * 既浪费配额，也让 IG 更容易把推荐位判成"发过了"。这里让后来者直接搭上在飞的那一发。
   */
  static tray(): Promise<StoryTray | null> {
    if (NativeStories.trayInflight !== null) {
      hilog.info(DOMAIN, TAG, 'tray join inflight');
      return NativeStories.trayInflight;
    }
    const job: Promise<StoryTray | null> = NativeStories.loadTray();
    NativeStories.trayInflight = job;
    job.then((): void => {
      NativeStories.trayInflight = null;
    }).catch((): void => {
      NativeStories.trayInflight = null;
    });
    return job;
  }

  /** `tray()` 的真身（拿到之后走缓存、模板回放、推荐兜底这几级）。 */
  private static async loadTray(): Promise<StoryTray | null> {
    /*
     * **先看手上这份还能不能直接用**（见 lastTray 的说明）。
     *
     * 典型场景：启动预热刚拉回来一份（带推荐快拍），托盘组件紧接着挂载又要一次 ——
     * 那一发会让 IG 把推荐位判成"已经发过"，回 `tray:[]`，界面于是从"有推荐"跳回"空"。
     */
    const nowMs: number = Date.now();
    if (NativeStories.lastTray !== null
      && nowMs - NativeStories.lastTrayAt < NativeStories.TRAY_REUSE_MS) {
      hilog.info(DOMAIN, TAG, 'tray reused age=%{public}dms n=%{public}d',
        nowMs - NativeStories.lastTrayAt, NativeStories.lastTray.items.length);
      NativeStories.detail = '-';
      return NativeStories.lastTray;
    }
    /*
     * **移动端私有 API**（见 core/mobileapi/MobileStories 的文件头）：
     * 一发 `feed/reels_tray/` 就把整条托盘带回来（实测 213 条 / 425KB），
     * 而且不依赖"网页抓到的模板"——模板缺失正是这条路上最常见的失败（`no-template`）。
     * 失败**静默**落回下面那条老路：老路仍然是模板/GQL 的唯一入口，不该因为新路失败就丢功能。
     */
    const mobile: StoryTray | null = await MobileStories.tray();
    if (mobile !== null && mobile.items.length > 0) {
      NativeStories.detail = '-';
      const tray: StoryTray = NativeStories.pruneHidden(mobile);
      hilog.info(DOMAIN, TAG, 'tray via mobile n=%{public}d first=%{public}s',
        tray.items.length, tray.items.length > 0 ? tray.items[0].username : '-');
      if (tray.items.length > 0) {
        NativeStories.rememberTray(tray);
        // 落盘一份：下次冷启动先画它（见 core/TrayCache / StoriesTray.aboutToAppear）。
        TrayCache.save(tray.items);
        return tray;
      }
      // 全被"已关注过的推荐"滤掉了：当作真的没有，别把空表塞给界面。
      return null;
    }
    /*
     * 这一发回了空（或失败）：**推荐位一轮只发一次**，空了不等于没内容 ——
     * 手上那份还不太旧就先顶上，别让刚长出来的推荐凭空消失。
     */
    const fallback: StoryTray | null = NativeStories.staleFallback(nowMs);
    if (fallback !== null) {
      return fallback;
    }
    /*
     * **IG 的推荐位没发**（新号最常见：它一个小时才发一轮，而请求一多就一直空）：
     * 退一步用"推荐流里那些账号"现拼一条推荐快拍（见 trayFromSuggestions）。
     * 这样新号的托盘不会永远是空的，用户也能直接在这排里关注人。
     */
    const suggested: StoryTray | null = await NativeStories.trayFromSuggestions();
    if (suggested !== null) {
      NativeStories.rememberTray(suggested);
      return suggested;
    }
    // 移动端这条路都没拿到：如实记原因（原先的网页模板兜底已随模板机制删除）。
    if (NativeStories.detail === '-') {
      NativeStories.detail = 'no-mobile-tray';
    }
    return null;
  }

  private static pickStr(host: Record<string, Object>, keys: Array<string>,
                         fallback: string): string {
    for (let index: number = 0; index < keys.length; index++) {
      const value: string = JsonRead.strOf(host, keys[index]);
      if (value.length > 0) {
        return value;
      }
    }
    return fallback;
  }

  /** 认不出结构时把键树打出来（照着它补候选键名）。 */
  private static logMiss(host: Record<string, Object>, why: string): void {
    const keys: Array<string> = Object.keys(host);
    const lines: Array<string> = [];
    for (let index: number = 0; index < keys.length && index < 8; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        lines.push(`${keys[index]}{${Object.keys(child).slice(0, 6).join(',')}}`);
        continue;
      }
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        lines.push(`${keys[index]}[${list.length}]${first === null ? ''
          : '{' + Object.keys(first).slice(0, 6).join(',') + '}'}`);
        continue;
      }
      lines.push(keys[index]);
    }
    hilog.info(DOMAIN, TAG, 'story tray miss why=%{public}s tree=%{public}s',
      why, lines.join(' '));
  }

  // ---------------------------------------------------------------- 播放页取数

  /**
   * 拉某个用户**当前未过期**的全部快拍（点开托盘里那一项时用；拿不到给 null）。
   *
   * 为什么不用模板：网页版那条"快拍播放页"的查询（doc_id）只有网页真的点开过某个人的快拍
   * 才会被抓到，而托盘是从首页进的 —— 手里只有托盘那条模板。所以这里走**私有 REST**
   * （App 接口），它一次就把 media 列表给全（见 MobileStories.reel）。
   *
   * @param altIds 这条托盘条目的**备选 id**（见 StoryTrayItem.altIds）：主 id 问不出内容时逐个再问。
   *   它解决的正是"只有部分用户点开提示没取到（原因 empty）"那一类 —— 托盘条目取错了 id 字段。
   */
  static async reel(userId: string, altIds: Array<string> = [],
                    username: string = '',
                    priority: number = ApiThrottle.warm()): Promise<StoryReel | null> {
    if (userId.length === 0) {
      NativeStories.detail = 'no-user';
      return null;
    }
    /*
     * **移动端私有接口**（见文件头）。候选顺序是**实测定的**（自检报告见
     * core/mobileapi/MobileStories 的文件头）：
     *   ① `GET /api/v1/feed/user/{uid}/story/` —— 一发拿到这个人当前全部快拍（媒体在 `reel.items`）；
     *   ② `GET /api/v1/feed/reels_media/?reel_ids=<裸 id>` —— 用户 pk 与 reel id 不一致时靠它；
     *      注意 **JSON 数组形式回空**，所以是裸 id。
     */
    const mobile: StoryReel | null = await MobileStories.reel(userId, altIds, username, priority);
    if (mobile !== null && mobile.items.length > 0) {
      NativeStories.detail = '-';
      hilog.info(DOMAIN, TAG, 'reel via mobile uid=%{public}s user=%{public}s n=%{public}d',
        userId, mobile.username, mobile.items.length);
      return mobile;
    }
    // 记一行轨迹：失败报告里要能看出"移动端这条也试过了、结果是什么"。
    NativeStories.note(userId, `mobile=none user=${userId}`);
    /*
     * **第二道：用托盘那份数据自己拼一条**（不需要任何请求，见 reelFromTrayNode）。
     *
     * 拿不到"正经那一份"时，**手上这份托盘条目自带的 media** 远好过弹一句"没取到"并把整层收掉。
     * 走这条路时 `detail` 记 `-tray`，报告与日志里一眼能看出"这次是托盘兜底顶上的"。
     *
     * 历史：这两者之间原来还有"一条 URL × 三种身份"的网页候选链、备选 id 重试、以及
     * "网页查询回放 / 读页面媒体"两条模板退路 —— 页面注入退役后一并删除。
     */
    const fromTray: StoryReel | null = NativeStories.reelFromTrayNode(userId);
    if (fromTray !== null && fromTray.items.length > 0) {
      NativeStories.detail = '-tray';
      NativeStories.note(userId, `托盘兜底：条目自带 items=${fromTray.items.length}`);
      hilog.info(DOMAIN, TAG, 'reel ok via tray node uid=%{public}s n=%{public}d',
        userId, fromTray.items.length);
      return fromTray;
    }
    if (NativeStories.detail === '-') {
      NativeStories.detail = 'no-answer';
    }
    return null;
  }

  /**
   * 任意"装着这一位快拍的 JSON 对象" → StoryReel（**托盘兜底**用）。
   *
   * 两条接口的外壳不一样：
   *   · `/feed/reels_media/`       → `{reels: {"<uid>": {items: […]}}}`
   *   · `/feed/user/<uid>/story/`  → `{reel: {items: […]}}`
   *   · **托盘条目自己**            → `{user:{…}, items: […]}`（见 reelFromTrayNode）
   * 所以外壳不认键名，直接从根上按"结构像媒体"的数组找（findMediaArray）。
   *
   * @param logMiss 认不出结构时要不要打键树（托盘兜底那条**不打**：它失败很正常，别刷日志）。
   */
  private static reelOf(root: Record<string, Object>, userId: string,
                        logMiss: boolean): StoryReel | null {
    const nodes: Array<Object> | null = NativeStories.findMediaArray(root, 0);
    if (nodes === null) {
      if (logMiss) {
        NativeStories.logMiss(root, 'reel-no-media-array');
      }
      return null;
    }
    const items: Array<StoryItem> = [];
    for (let index: number = 0; index < nodes.length; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(nodes[index]);
      if (node === null) {
        continue;
      }
      const item: StoryItem | null = NativeStories.itemOf(node);
      if (item !== null) {
        items.push(item);
      }
    }
    if (items.length === 0) {
      return null;
    }
    let username: string = '';
    let avatar: string = '';
    const first: Record<string, Object> | null = JsonRead.asRecord(nodes[0]);
    if (first !== null) {
      const user: Record<string, Object> | null = JsonRead.recordOf(first, 'user');
      if (user !== null) {
        username = NativeStories.pickStr(user, NAME_KEYS, '');
        avatar = NativeStories.avatarOf(user);
      }
    }
    return new StoryReel(userId, username, avatar, items);
  }

  /**
   * **托盘兜底**：拿托盘响应里这一条条目自己带的 media 拼一个 StoryReel（**不需要任何请求**）。
   *
   * 为什么要有它：有些条目 IG 的 `reels_media` 就是不给内容（刚过期但托盘还留着、
   * 私密号未关注、条目来自别的分区……），但**托盘响应里本来就带着这一位的 media**
   * （解析托盘时我们就在数 `items`）。与其弹一句"没取到"，不如把手上这份用起来 ——
   * 用户至少能点开看，而不是整层被收掉。
   */
  static reelFromTrayNode(userId: string): StoryReel | null {
    const raw: string | undefined = NativeStories.nodeRaw.get(userId);
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    try {
      const node: Record<string, Object> = JsonRead.parse(raw);
      return NativeStories.reelOf(node, userId, false);
    } catch (error) {
      return null;
    }
  }

  /** 找"媒体数组"：元素看着像一条 media 的那个数组（广度优先，深度封顶）。 */
  private static findMediaArray(host: Record<string, Object>, depth: number): Array<Object> | null {
    if (depth > 4) {
      return null;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null && NativeStories.looksLikeMedia(first)) {
          return list;
        }
      }
    }
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: Array<Object> | null = NativeStories.findMediaArray(child, depth + 1);
        if (hit !== null) {
          return hit;
        }
      }
    }
    return null;
  }

  /** 一个对象"像不像一条 media"（有图候选 / 有图地址 / 有 media_type）。 */
  private static looksLikeMedia(node: Record<string, Object>): boolean {
    if (JsonRead.recordOf(node, 'image_versions2') !== null) {
      return true;
    }
    if (JsonRead.strOf(node, 'display_url').length > 0) {
      return true;
    }
    for (let at: number = 0; at < MEDIA_TYPE_KEYS.length; at++) {
      if (JsonRead.has(node, MEDIA_TYPE_KEYS[at])) {
        return true;
      }
    }
    return false;
  }

  /** 一条 media → StoryItem（认不出来给 null）。 */
  private static itemOf(node: Record<string, Object>): StoryItem | null {
    let image: string = '';
    /*
     * 顺手把**这张图（或视频封面）的真实宽高**记下来：媒体区的比例要按它算，
     * 不然媒体区定死 9:16 而媒体是别的比例时，`Contain` 会在卡片里留出黑边（用户报过）。
     */
    let width: number = JsonRead.numOf(node, 'original_width');
    let height: number = JsonRead.numOf(node, 'original_height');
    const versions: Record<string, Object> | null = JsonRead.recordOf(node, 'image_versions2');
    if (versions !== null) {
      const list: Array<Object> = JsonRead.arrayOf(versions, 'candidates');
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null) {
          image = JsonRead.strOf(first, 'url');
          if (width <= 0 || height <= 0) {
            width = JsonRead.numOf(first, 'width');
            height = JsonRead.numOf(first, 'height');
          }
        }
      }
    }
    if (image.length === 0) {
      image = NativeStories.pickStr(node, ['display_url', 'image_url', 'thumbnail_url'], '');
    }
    let video: string = '';
    const videos: Array<Object> = JsonRead.arrayOf(node, 'video_versions');
    if (videos.length > 0) {
      const first: Record<string, Object> | null = JsonRead.asRecord(videos[0]);
      if (first !== null) {
        video = JsonRead.strOf(first, 'url');
      }
    }
    if (image.length === 0 && video.length === 0) {
      return null;
    }
    let durationMs: number = IMAGE_DURATION_MS;
    if (video.length > 0) {
      let seconds: number = 0;
      for (let at: number = 0; at < DURATION_KEYS.length; at++) {
        if (JsonRead.has(node, DURATION_KEYS[at])) {
          seconds = JsonRead.numOf(node, DURATION_KEYS[at]);
          break;
        }
      }
      // 时长离谱（0 / 超大）就按默认走：宁可多停一会儿，也别让进度条一闪而过。
      if (seconds > 0.2 && seconds < 120) {
        durationMs = Math.round(seconds * 1000);
      }
    }
    const id: string = NativeStories.pickStr(node, ID_KEYS, '');
    const takenAt: number = JsonRead.numOf(node, 'taken_at');
    return new StoryItem(id.length > 0 ? id : `story-${takenAt}`, image, video, takenAt, durationMs,
      width, height);
  }

  /** 头像地址：先试直接的几个键，再试 `hd_profile_pic_url_info.url`。 */
  private static avatarOf(host: Record<string, Object>): string {
    const direct: string = NativeStories.pickStr(host, AVATAR_KEYS, '');
    if (direct.length > 0) {
      return direct;
    }
    const hd: Record<string, Object> | null = JsonRead.recordOf(host, 'hd_profile_pic_url_info');
    return hd === null ? '' : JsonRead.strOf(hd, 'url');
  }
}
