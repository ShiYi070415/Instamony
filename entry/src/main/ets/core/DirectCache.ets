/*
 * 私信会话的**预取快照缓存**（落盘，重启还在）。
 *
 * ## 需求（用户原话）
 * "切换到私信列表时预取当前私信列表的所有会话消息，每个会话 5 条……预取的会话可以存进 app，
 *  无新消息就直接覆盖会话消息，预取数据仅限文本，图片/视频媒体用占位加载表示，加载成功后显示。"
 *
 * ## 为什么只存文本
 * 1. **体积**：一条消息若带上 `image_versions2` 那串签名 URL（几百字符）＋视频地址，
 *    20 条会话 × 5 条就上百 KB，而这个缓存是要**每次列表刷新都重写**的；只存文本时
 *    80 条会话也才几十 KB。
 * 2. **有效期**：IG 的媒体 URL 带签名且**会过期**（本项目在快拍那边吃过这个亏）。
 *    存下来的 URL 过几个小时就是死链，界面反而更糟：本来能占位等加载，结果拿着死链一直转。
 *    所以媒体一律**进页面现取**：先用文本把气泡画出来（媒体位置画占位），
 *    点进去那一发刷新把最近的媒体地址带回来，加载成功即显示（见 DirectThreadPage 的气泡）。
 * 3. 头像也一样不存（`withAvatar` 由收件箱那一行现带，见 DirectThreadViewModel.open 的 fallback）。
 *
 * ## 存什么
 * 每条会话一条快照：最近 `MESSAGES_PER_THREAD` 条**文本**消息 + 判断"有没有新消息"要用的
 * `newestId`/`newestTs` + 翻页游标（`hasOlder`/`oldestCursor`，让"上拉取更老"不用等第一发）+ 拉取时刻。
 * 上限 `MAX_THREADS` 条（超出丢最旧的快照），落盘走 preferences（与 FeedCache/ReelsCache 同一套做法）。
 */

import { preferences } from '@kit.ArkData';
import { AccountScope } from './AccountScope';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DirectMessage, DirectThread, DirectThreadView } from '../model/Direct';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectCache';
const STORE_NAME: string = 'instarmony_direct_cache';
const STORE_KEY: string = 'threads_v1';
/** 每条会话存几条（需求："每个会话 5 条"）。 */
export const CACHE_MESSAGES: number = 5;
/** 最多存几条会话的快照（超出丢最旧的）。 */
const MAX_THREADS: number = 80;

/** 落盘的一条消息（**只有文本字段**，媒体不存，见文件头）。 */
class StoredMessage {
  id: string = '';
  userId: string = '';
  mine: boolean = false;
  tsMs: number = 0;
  kind: string = '';
  text: string = '';
}

/** 落盘的一条会话快照。 */
class StoredThread {
  threadId: string = '';
  title: string = '';
  withUsername: string = '';
  withId: string = '';
  withFullName: string = '';
  isGroup: boolean = false;
  hasOlder: boolean = false;
  oldestCursor: string = '';
  /** 最新一条消息的 id / 时刻（判"无新消息"用）。 */
  newestId: string = '';
  newestTs: number = 0;
  fetchedAt: number = 0;
  messages: Array<StoredMessage> = [];
}

export class DirectCache {
  private static store: preferences.Preferences | null = null;
  /** 内存里的全部快照（键 = threadId）。 */
  private static threads: Map<string, StoredThread> = new Map<string, StoredThread>();
  private static loaded: boolean = false;

  /** 打开落盘文件并读回（幂等；`EntryAbility` 启动时调一次）。 */
  static init(context: common.Context): void {
    if (DirectCache.store !== null) {
      return;
    }
    try {
      DirectCache.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      // 按账号分区（见 core/AccountScope）：私信快照更是"按人"的东西。
      AccountScope.register(DirectCache.store, [STORE_KEY]);
      DirectCache.load();
      hilog.info(DOMAIN, TAG, 'cache opened n=%{public}d', DirectCache.threads.size);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open cache failed: %{public}s', (error as Error).message);
    }
  }

  /** 有几条会话的快照（日志/诊断用）。 */
  static size(): number {
    return DirectCache.threads.size;
  }

  /** 某条会话的快照（没有给 null）。 */
  static get(threadId: string): StoredThread | null {
    const one: StoredThread | undefined = DirectCache.threads.get(threadId);
    return one === undefined ? null : one;
  }

  /**
   * 这条会话的快照还新鲜吗（`maxAgeMs` 之内取的、且有内容）。
   *
   * 预取队列拿它判"要不要再拉一发"：刚拉过的直接跳过，
   * 列表刷新时只有**新出现/过期**的那几条会真的发请求。
   */
  static isFresh(threadId: string, maxAgeMs: number): boolean {
    const one: StoredThread | null = DirectCache.get(threadId);
    if (one === null || one.fetchedAt <= 0 || one.messages.length === 0) {
      return false;
    }
    return Date.now() - one.fetchedAt <= maxAgeMs;
  }

  /**
   * 把一次读到的一页消息**存成快照**（只留最近 `CACHE_MESSAGES` 条文本）。
   *
   * @returns 是否真的写进去了（内容没变时返回 false，调用方据此决定要不要落盘/打日志）
   */
  static save(view: DirectThreadView, maxMessages: number = CACHE_MESSAGES): boolean {
    if (view.id.length === 0 || view.messages.length === 0) {
      return false;
    }
    const messages: Array<DirectMessage> = view.messages;
    const start: number = messages.length > maxMessages ? messages.length - maxMessages : 0;
    const stored: StoredThread = new StoredThread();
    stored.threadId = view.id;
    stored.title = view.title;
    stored.withUsername = view.withUsername;
    stored.withId = view.withId;
    stored.withFullName = view.withFullName;
    stored.isGroup = view.isGroup;
    stored.hasOlder = view.hasOlder;
    stored.oldestCursor = view.oldestCursor;
    stored.fetchedAt = Date.now();
    const last: DirectMessage = messages[messages.length - 1];
    stored.newestId = last.id;
    stored.newestTs = last.tsMs;
    for (let index: number = start; index < messages.length; index++) {
      stored.messages.push(DirectCache.toStored(messages[index]));
    }
    const before: StoredThread | undefined = DirectCache.threads.get(view.id);
    DirectCache.threads.set(view.id, stored);
    DirectCache.trim();
    const changed: boolean = before === undefined
      || before.newestId !== stored.newestId || before.messages.length !== stored.messages.length;
    DirectCache.persist();
    return changed;
  }

  /**
   * 快照 → 可直接显示的 `DirectThreadView`（**媒体地址为空**，界面按占位画）。
   *
   * @param avatar 收件箱那一行带来的头像（快照里不存头像，见文件头）
   */
  static viewOf(threadId: string, avatar: string = ''): DirectThreadView | null {
    const one: StoredThread | null = DirectCache.get(threadId);
    if (one === null || one.messages.length === 0) {
      return null;
    }
    const messages: Array<DirectMessage> = [];
    for (let index: number = 0; index < one.messages.length; index++) {
      const m: StoredMessage = one.messages[index];
      // mediaUrl / isVideo 留空 = 占位；点进去那一发刷新会把它们补上（见 DirectThreadViewModel.load）。
      messages.push(new DirectMessage(m.id, m.userId, m.mine, m.tsMs, m.kind, m.text, '', false));
    }
    return new DirectThreadView(one.threadId, one.title, one.withUsername, avatar, one.withId,
      messages, one.hasOlder, one.oldestCursor, one.isGroup, one.withFullName);
  }

  /**
   * **把"没有新消息"的那一屏补上媒体**（用户："无新消息就直接覆盖会话消息"，而媒体要能显示）。
   *
   * 做法：以**快照的顺序与内容**为底（画面不跳），把新读到那一页里**同 id** 消息的媒体地址填进去；
   * 只在 fresh 里出现的新消息按时间顺序补在后面。这样：
   *   · 没有新消息 → 画面与缓存一模一样（只是占位换成了真图/真视频封面）；
   *   · 有新消息 → 新的那几条自然排到后面，不会把用户正在看的内容抖走。
   */
  static mergeMedia(cached: DirectThreadView, fresh: DirectThreadView): Array<DirectMessage> {
    const freshById: Map<string, DirectMessage> = new Map<string, DirectMessage>();
    for (let index: number = 0; index < fresh.messages.length; index++) {
      const one: DirectMessage = fresh.messages[index];
      if (one.id.length > 0) {
        freshById.set(one.id, one);
      }
    }
    const known: Map<string, boolean> = new Map<string, boolean>();
    const out: Array<DirectMessage> = [];
    for (let index: number = 0; index < cached.messages.length; index++) {
      const one: DirectMessage = cached.messages[index];
      const better: DirectMessage | undefined = freshById.get(one.id);
      known.set(one.id, true);
      if (better === undefined) {
        out.push(one);
        continue;
      }
      out.push(new DirectMessage(one.id, one.userId, one.mine, one.tsMs, one.kind,
        one.text.length > 0 ? one.text : better.text, better.mediaUrl, better.isVideo));
    }
    for (let index: number = 0; index < fresh.messages.length; index++) {
      const one: DirectMessage = fresh.messages[index];
      if (one.id.length > 0 && known.get(one.id) === true) {
        continue;
      }
      out.push(one);
    }
    out.sort((a: DirectMessage, b: DirectMessage): number => a.tsMs - b.tsMs);
    return out;
  }

  /** 清空（退出登录时调）。 */
  static clear(): void {
    DirectCache.threads.clear();
    DirectCache.persist();
  }

  /** 快照条数一行摘要（诊断面板用）。 */
  static describe(): string {
    let messages: number = 0;
    DirectCache.threads.forEach((one: StoredThread): void => {
      messages += one.messages.length;
    });
    return `threads=${DirectCache.threads.size} msgs=${messages}`;
  }

  private static toStored(message: DirectMessage): StoredMessage {
    const out: StoredMessage = new StoredMessage();
    out.id = message.id;
    out.userId = message.userId;
    out.mine = message.mine;
    out.tsMs = message.tsMs;
    out.kind = message.kind;
    out.text = message.text;
    return out;
  }

  /** 超出上限时丢最旧的几条（按 fetchedAt）。 */
  private static trim(): void {
    if (DirectCache.threads.size <= MAX_THREADS) {
      return;
    }
    const all: Array<StoredThread> = [];
    DirectCache.threads.forEach((one: StoredThread): void => {
      all.push(one);
    });
    all.sort((a: StoredThread, b: StoredThread): number => a.fetchedAt - b.fetchedAt);
    const drop: number = all.length - MAX_THREADS;
    for (let index: number = 0; index < drop; index++) {
      DirectCache.threads.delete(all[index].threadId);
    }
    hilog.info(DOMAIN, TAG, 'cache trimmed dropped=%{public}d left=%{public}d',
      drop, DirectCache.threads.size);
  }

  /** 读回落盘的全部快照。 */
  private static load(): void {
    if (DirectCache.loaded) {
      return;
    }
    DirectCache.loaded = true;
    const store: preferences.Preferences | null = DirectCache.store;
    if (store === null) {
      return;
    }
    try {
      const raw: string = store.getSync(AccountScope.slot(STORE_KEY), '') as string;
      if (raw.length === 0) {
        return;
      }
      const list: Array<StoredThread> = JSON.parse(raw) as Array<StoredThread>;
      for (let index: number = 0; index < list.length; index++) {
        const one: StoredThread = list[index];
        if (one !== null && one !== undefined && one.threadId.length > 0) {
          DirectCache.threads.set(one.threadId, one);
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load cache failed: %{public}s', (error as Error).message);
    }
  }

  /** 落盘（一条 JSON 数组；体积见文件头，几十 KB 量级）。 */
  private static persist(): void {
    const store: preferences.Preferences | null = DirectCache.store;
    if (store === null) {
      return;
    }
    const all: Array<StoredThread> = [];
    DirectCache.threads.forEach((one: StoredThread): void => {
      all.push(one);
    });
    try {
      store.putSync(AccountScope.slot(STORE_KEY), JSON.stringify(all));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'persist cache failed: %{public}s', (error as Error).message);
    }
  }
}
