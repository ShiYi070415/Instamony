/*
 * 「已关注 / 未关注」的**会话级覆盖表**（本进程内存）。
 *
 * ## 为什么必须有一个全局的地方存它
 * 关注状态有两个来源，而且**都不够权威**：
 *   ① 接口给的 `friendship_status.following`（信息流 GraphQL / 通知 inbox）——
 *      它是**取数那一刻**的快照。刚点完关注，下一次刷新拿回来的多半还是旧值
 *      （IG 的缓存 + 我们自己的分页缓存都会把旧值带回来）；
 *   ② 用户点按钮造成的即时变化 —— 原本只记在 `FeedList` 组件实例里的一个 Map 上。
 *
 * 问题就出在 ②：那个 Map 的生命周期 = **组件实例**的生命周期。切到 Reels 再切回首页、
 * 进帖子页再返回、刷新重建列表 —— 组件一重建，Map 就没了，界面立刻退回 ① 的旧快照。
 * 用户看到的就是"点完关注是好的，页面一变按钮又变回「关注」，而且状态卡住不动"
 * （真机复现：点掉关注 → 切 Reels → 回首页 → 按钮又变回「已关注」）。
 *
 * 所以把它提到模块级：**点过按钮就以这里为准**，任何页面（信息流 / 通知 / 之后
 * 可能的个人页）只要经过各自的映射函数问一句 `resolve()`，就都拿到同一个答案。
 *
 * ## 为什么还有一份按账号名的
 * 通知页里有两种条目拿不到用户 id：`为你推荐` 里没给 pk 的、以及系统通告。
 * 它们只能用账号名匹配（`username` 本身是唯一的）。
 *
 * ## 过期
 * 覆盖值带时间戳，超过 TTL 就当没有 —— 免得用户在**别处**（IG 官方 App / 网页）
 * 改了关注状态，这里却永远顶着一个旧值。TTL 内以本地为准，之后回到接口值。
 *
 * ## 全局刷新（`FOLLOW_VERSION_KEY`）
 * 上面那套只解决了"**下一次**问 `resolve` 拿到的是新值"，解决不了"**界面已经画好了**"：
 * 卡片上的状态是构建时算一次就定住的（`@ObjectLink` 的 `following`），用户页那颗按钮、
 * 帖子页标题栏那颗、通知列表里那些「回关」也一样。所以在用户主页点了关注，首页那张卡、
 * 帖子页标题栏、通知列表里同一个人的状态**都不会自己变** —— 用户报的"关注状态没有全局刷新"。
 *
 * 办法：每记一次覆盖值就把 AppStorage 里的 `FOLLOW_VERSION_KEY` 加一，各页面用
 * `@StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion')` 盯着它，一变就地把自己的
 * 状态按覆盖表重算一遍（见 pages/Index.onFollowVersion、FeedList.syncFollowStates、
 * ProfilePage.onFollowVersion）。这样不管在哪儿点的关注，已经画出来的地方都会跟着变。
 */

/** 覆盖值的有效期（毫秒）：半小时。见文件头"过期"一节。 */
const OVERRIDE_TTL_MS: number = 30 * 60 * 1000;

/**
 * 全局刷新用的版本号（AppStorage 里的 key）—— 为什么需要它见文件头"全局刷新"那一节。
 *
 * 各页面这样盯它（`@Watch` 回调里把自己的关注状态按覆盖表重算一遍）：
 * ```
 * @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
 * ```
 */
export const FOLLOW_VERSION_KEY: string = 'followVersion';

/** 一条覆盖记录（值 + 记下来的时刻）。 */
class FollowOverride {
  readonly following: boolean;
  readonly at: number;

  constructor(following: boolean, at: number) {
    this.following = following;
    this.at = at;
  }

  /** 还在有效期内吗。 */
  fresh(now: number): boolean {
    return now - this.at < OVERRIDE_TTL_MS;
  }
}

export class FollowState {
  /** 按用户 id（信息流/通知里都能拿到）。 */
  private static readonly byId: Map<string, FollowOverride> = new Map<string, FollowOverride>();
  /** 按账号名（拿不到 id 的条目用）。 */
  private static readonly byName: Map<string, FollowOverride> = new Map<string, FollowOverride>();

  /** 记下"这次用户点了按钮之后的状态"。id 为空时只按名字记。 */
  static remember(userId: string, username: string, following: boolean): void {
    const now: number = Date.now();
    const id: string = userId.trim();
    const name: string = username.trim().toLowerCase();
    if (id.length === 0 && name.length === 0) {
      // 连 id 和名字都没有：谁也匹配不上，没必要惊动界面。
      return;
    }
    if (id.length > 0) {
      FollowState.byId.set(id, new FollowOverride(following, now));
    }
    if (name.length > 0) {
      FollowState.byName.set(name, new FollowOverride(following, now));
    }
    FollowState.bump();
  }

  /**
   * 把全局版本号 +1：盯 `FOLLOW_VERSION_KEY` 的页面会就地重算自己的关注状态。
   *
   * 用 AppStorage 而不是自己攒一份回调表：ArkUI 的 `@StorageLink` 本来就是干这个的，
   * 组件销毁时订阅自动跟着没（自己维护回调表反而要记得反注册，漏一处就是野回调）。
   */
  private static bump(): void {
    const now: number = AppStorage.get<number>(FOLLOW_VERSION_KEY) ?? 0;
    AppStorage.setOrCreate(FOLLOW_VERSION_KEY, now + 1);
  }

  /** 有没有这个 id 的有效覆盖值（诊断用）。 */
  static has(userId: string): boolean {
    const one: FollowOverride | undefined = FollowState.byId.get(userId.trim());
    return one !== undefined && one.fresh(Date.now());
  }

  /**
   * 问一句"这个人现在是不是已关注"。
   *
   * @param fallback 接口给的值（没有覆盖时用它）。
   */
  static resolve(userId: string, fallback: boolean): boolean {
    const one: FollowOverride | undefined = FollowState.byId.get(userId.trim());
    if (one === undefined || !one.fresh(Date.now())) {
      return fallback;
    }
    return one.following;
  }

  /** 同上，按账号名问（拿不到 id 的条目）。 */
  static resolveName(username: string, fallback: boolean): boolean {
    const one: FollowOverride | undefined = FollowState.byName.get(username.trim().toLowerCase());
    if (one === undefined || !one.fresh(Date.now())) {
      return fallback;
    }
    return one.following;
  }

  /**
   * 退出登录时清空。
   *
   * 覆盖表是**跟账号绑定**的：不清的话换个账号登录，上一个人的关注状态会串到新账号上。
   */
  static clear(): void {
    FollowState.byId.clear();
    FollowState.byName.clear();
    // 也惊动一次界面：退出登录后各页面那份"本地覆盖优先"的状态要一起回到接口值。
    FollowState.bump();
  }
}
