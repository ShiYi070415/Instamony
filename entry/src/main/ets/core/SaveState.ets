/*
 * 「收藏了没有」的**会话级覆盖表**（本进程内存）。
 *
 * ## 为什么需要
 * 收藏状态只有一个来源，而且很弱：**用户自己点的那一下**。IG 的 clips / 信息流载荷里
 * 一般不带 `has_saved`（真机上那两段查询连头像都不给，见 core/NativeProfile 的说明），
 * 所以"这条我收藏过没有"没法从数据里读出来。
 *
 * 于是：**点过就以这里为准**。按钮画的时候问一句 `resolve(mediaId, 接口值)`，
 * 这样同一个 reel 的信息层被重建（Swiper 翻页会销毁/重建相邻页）之后，
 * 那颗书签不会又变回空心。
 *
 * ## 过期
 * 和 core/FollowState 一样带一个 TTL：用户可能在**别处**（IG 官方 App / 网页）取消了收藏，
 * TTL 之内以本地为准，之后回到接口值（接口没给值就是 false）。
 */

/** 覆盖值的有效期（毫秒）：半小时（和 FollowState 一个量级）。 */
const OVERRIDE_TTL_MS: number = 30 * 60 * 1000;

/** 一条覆盖记录（值 + 记下来的时刻）。 */
class SaveOverride {
  readonly saved: boolean;
  readonly at: number;

  constructor(saved: boolean, at: number) {
    this.saved = saved;
    this.at = at;
  }

  fresh(now: number): boolean {
    return now - this.at < OVERRIDE_TTL_MS;
  }
}

export class SaveState {
  /** 媒体数字 id → 覆盖值。 */
  private static readonly byId: Map<string, SaveOverride> = new Map<string, SaveOverride>();

  /**
   * 媒体 id 归一化：只留 `_` 前面那一段。
   *
   * 和信息流/个人页两套 id 写法对齐（前者是 `<媒体id>_<作者id>`，后者是纯媒体 id）——
   * 不归的话"在信息流收藏过的那条"到了收藏页/帖子页就查不到，书签又会变空心
   * （同 core/NativeEngage.EngageState.normalize 的理由）。
   */
  private static normalize(mediaId: string): string {
    const text: string = mediaId.trim();
    const cut: number = text.indexOf('_');
    return cut > 0 ? text.substring(0, cut) : text;
  }

  /** 记下"用户点了按钮之后的状态"（id 为空则忽略：谁也匹配不上）。 */
  static remember(mediaId: string, saved: boolean): void {
    const id: string = SaveState.normalize(mediaId);
    if (id.length === 0) {
      return;
    }
    SaveState.byId.set(id, new SaveOverride(saved, Date.now()));
  }

  /**
   * 问一句"这条现在收藏了没有"。
   *
   * @param fallback 接口/载荷给的值（没有覆盖时用它）。
   */
  static resolve(mediaId: string, fallback: boolean): boolean {
    const one: SaveOverride | undefined = SaveState.byId.get(SaveState.normalize(mediaId));
    if (one === undefined || !one.fresh(Date.now())) {
      return fallback;
    }
    return one.saved;
  }

  /** 退出登录时清空（覆盖表跟账号绑定，见 FollowState.clear 的同款理由）。 */
  static clear(): void {
    SaveState.byId.clear();
  }
}
