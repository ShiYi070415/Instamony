/*
 * Reels **第一页的落盘缓存**（需求："reels 页面加载不了视频"、"无法正确获取数据显示"）。
 *
 * ## 为什么必须有它
 * 视频标签的数据只有一条来源：IG 的 clips 那条重查询（`PolarisClipsTabRootPaginationQuery`）。
 * 而那条查询**会被限流**（真机实测：`{"errors":[{"message":"Rate limit exceeded","code":1675004}]}`）。
 * 一被限流，视频标签就是**一片空白**——连"上次看到的那批"都没有，用户看到的就是坏了。
 * 搜索页的推荐瀑布流用的是同一条查询，所以一起空。
 *
 * 落盘之后：限流期间（见 core/ApiThrottle）把上次成功那一页铺出来，界面照旧有内容可滑，
 * 状态行说明"被限流了，先显示上次的内容"。等冷却过去再整体刷新。
 *
 * ## 存什么、存多久
 *   - 存**映射前的字段摘要**（`ReelCacheDto`）：`Reel` 是类实例（还带 @Observed），
 *     直接 JSON 化不行；DTO 是纯数据，读回来再拼 `Reel` 很便宜。
 *   - 只存**第一页**（十几条，几十 KB）。翻页那些时效性更强、体积更大，不适合当"没网时"的料。
 *   - 有效期放宽到 **6 小时**（比信息流那份 30 分钟长）：这里的用途是"限流时别白屏"，
 *     而不是"开机秒出画面"——内容旧一点也好过一片黑。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { AccountScope } from './AccountScope';
import { common } from '@kit.AbilityKit';
import { Reel } from '../model/Reel';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsCache';

/** 落盘的 preferences 文件名与键。 */
const STORE: string = 'instarmony_reels_cache';
const KEY: string = 'page1_v1';
/** 关注那条流自己那份（两条流分开两页之后各存各的，别互相覆盖，见 pages/Index 的 reelsSegment）。 */
const KEY_FOLLOWING: string = 'page1_follow_v1';
/** 缓存格式版本：改了结构就 +1，旧的一律当没有。 */
const FORMAT: number = 2;
/** 有效期（毫秒）：6 小时（见文件头）。 */
const MAX_AGE_MS: number = 6 * 60 * 60 * 1000;
/** 单份上限（字符）：超过就不存（防呆）。 */
const MAX_CHARS: number = 512 * 1024;
/**
 * 最多存多少条。
 *
 * 36 条 = 首屏 + 一两页：被限流时够滑一阵，JSON 也就一两百 KB。
 * （首页那条 clips 查询首屏有时只回 2~4 条，光存第一页太少，所以翻页之后也会顺手保存，
 *   见 ReelsViewModel.applyNativePage。）
 */
const SAVE_MAX_ITEMS: number = 36;

/** 落盘的一条（`Reel` 的纯数据版）。 */
interface ReelCacheDto {
  c?: string;
  u?: string;
  o?: string;
  v?: string;
  w?: number;
  h?: number;
  a?: string;
  /** 作者数字 id（`pk`）：Reels 页那颗关注按钮要用（见 model/Reel 的 authorId）。 */
  uid?: string;
  av?: string;
  m?: string;
  /** 正文（Reels 页作者行下面那一段）。 */
  cap?: string;
  /** 本机点过赞没有（那颗心按它画）。 */
  lk?: boolean;
  /** 转发数（动作区那颗转发下面的数字）。 */
  rp?: number;
  /** 本机关注作者了没有（那颗关注按钮按它画）。 */
  fol?: boolean;
  /** `fol` 是数据源真的说了（false = 不知道，界面会单独问一次，见 NativeFollow.statesFor）。 */
  fk?: boolean;
  l?: number;
  cm?: number;
  id?: string;
}

interface StoredReelsPage {
  v?: number;
  at?: number;
  items?: Array<ReelCacheDto>;
}

/** 读回来的一页（已过版本与时效校验）。 */
export class CachedReelsPage {
  readonly reels: Array<Reel>;
  readonly ageMs: number;

  constructor(reels: Array<Reel>, ageMs: number) {
    this.reels = reels;
    this.ageMs = ageMs;
  }
}

export class ReelsCache {
  /** 落盘用的键：探索那条用默认的，关注那条用它自己那份（见 KEY_FOLLOWING）。 */
  static keyFor(source: string): string {
    return source === 'following' ? KEY_FOLLOWING : KEY;
  }

  private static store: preferences.Preferences | null = null;

  /** 打开缓存文件（EntryAbility.onCreate 里调一次即可；幂等）。 */
  static init(context: common.Context): void {
    if (ReelsCache.store !== null) {
      return;
    }
    try {
      ReelsCache.store = preferences.getPreferencesSync(context, { name: STORE });
      // 按账号分区（见 core/AccountScope）。
      AccountScope.register(ReelsCache.store, [KEY, KEY_FOLLOWING]);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open store failed: %{public}s', (error as Error).message);
    }
  }

  /** 存一份第一页（同步写 + flush，同 FeedCache）。 */
  static save(reels: Array<Reel>, key: string = KEY): void {
    const store: preferences.Preferences | null = ReelsCache.store;
    if (store === null || reels.length === 0) {
      return;
    }
    try {
      const items: Array<ReelCacheDto> = [];
      const total: number = reels.length < SAVE_MAX_ITEMS ? reels.length : SAVE_MAX_ITEMS;
      for (let index: number = 0; index < total; index++) {
        const one: Reel = reels[index];
        items.push({
          c: one.shortcode,
          u: one.videoUrl,
          o: one.originalVideoUrl,
          v: one.coverUrl,
          w: one.width,
          h: one.height,
          a: one.author,
          // 作者 id / 正文 / 点赞态也要存：缓存那份是**拿来直接显示**的，
          // 少了这几样，限流时铺出来的那条就没有关注按钮、没有正文、心也是灰的
          // （真机上就是这么发现的）。
          uid: one.authorId,
          av: one.avatarUrl,
          m: one.music,
          cap: one.caption,
          lk: one.liked,
          l: one.likeCount,
          cm: one.commentCount,
          id: one.mediaId,
          rp: one.repostCount,
          // 关注状态也要存：缓存那份是"限流时直接拿来显示"的，少了它那颗按钮会显示成"关注"
          // （用户报的"reels 关注按钮状态没正确显示"就是这么发现的）。
          fol: one.following,
          fk: one.followKnown
        });
      }
      const payload: StoredReelsPage = { v: FORMAT, at: Date.now(), items: items };
      const text: string = JSON.stringify(payload);
      if (text.length > MAX_CHARS) {
        hilog.warn(DOMAIN, TAG, 'page1 too big to cache: %{public}d chars', text.length);
        return;
      }
      store.putSync(AccountScope.slot(key), text);
      store.flushSync();
      hilog.info(DOMAIN, TAG, 'saved n=%{public}d chars=%{public}d', total, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save failed: %{public}s', (error as Error).message);
    }
  }

  /**
   * 读第一页缓存。
   *
   * @param maxAgeMs 超过这个年龄就当没有（默认 6 小时，见 MAX_AGE_MS）。
   */
  static load(key: string = KEY, maxAgeMs: number = MAX_AGE_MS): CachedReelsPage | null {
    const store: preferences.Preferences | null = ReelsCache.store;
    if (store === null) {
      return null;
    }
    try {
      const text: string = store.getSync(AccountScope.slot(key), '') as string;
      if (text.length === 0) {
        return null;
      }
      const dto: StoredReelsPage = JSON.parse(text) as StoredReelsPage;
      if ((dto.v ?? 0) !== FORMAT) {
        return null;
      }
      const age: number = Date.now() - (dto.at ?? 0);
      if (age < 0 || age > maxAgeMs) {
        hilog.info(DOMAIN, TAG, 'cache stale age=%{public}dms', age);
        return null;
      }
      const items: Array<ReelCacheDto> = dto.items ?? [];
      const reels: Array<Reel> = [];
      for (let index: number = 0; index < items.length; index++) {
        const one: ReelCacheDto = items[index];
        const code: string = one.c ?? '';
        if (code.length === 0) {
          continue;
        }
        reels.push(new Reel(code, one.u ?? '', one.v ?? '', one.w ?? 0, one.h ?? 0,
          one.a ?? '', one.av ?? '', false, one.m ?? '', one.l ?? 0, one.cm ?? 0,
          one.o ?? '', one.id ?? '', one.uid ?? '', one.cap ?? '', one.lk === true,
          false, one.rp ?? 0, one.fol === true, one.fk === true));
      }
      if (reels.length === 0) {
        return null;
      }
      hilog.info(DOMAIN, TAG, 'hit n=%{public}d age=%{public}dms', reels.length, age);
      return new CachedReelsPage(reels, age);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'load failed: %{public}s', (error as Error).message);
      return null;
    }
  }
}
