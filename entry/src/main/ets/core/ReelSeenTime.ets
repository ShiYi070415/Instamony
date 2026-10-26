/*
 * **这条 reel 第一次出现在列表里的本机时刻**（毫秒）。
 *
 * ## 为什么需要
 * 评论面板里那张帖子卡片要显示"x 分钟前 / x 小时前"（见 components/PostCardPanel 的 agoText）。
 * 真实发布时间来自 IG 载荷的 `taken_at`（见 model/Reel.takenAtMs 与 core/NativeReels.toReel）；
 * 但载荷**不一定给**（真机上 clips 这条查询本来就稀疏：不给收藏状态、有时不给作者头像，
 * 见 model/Reel.saved 的说明），一旦没有，卡片那一行就只能不画 —— 用户看到的就是"卡片上没有时间"。
 *
 * 所以这里记一份**兜底时间**：ReelsPage 每收到一页列表就调 `note`，把"我们第一次见到这条"
 * 的时刻记下来；卡片打开时如果 `reel.takenAtMs <= 0` 就用它（见 pages/Index.reelTakenAtMs）。
 *
 * ## 局限（必须写清楚）
 * 它是**本机第一次看到这条的时刻**，不是 IG 的发布时间：一条两天前发布的视频，今天第一次刷到
 * 也只会显示"刚刚 / 几分钟前"。所以它只在**载荷确实没给**时启用，而且一旦记下就不再改
 * （"3 小时前"会跟着真实时间长大，不会每次打开都退回"刚刚"）。
 *
 * 只在**内存**里记（App 一退就没了）：它是兜底，不值得落盘；重启后重新记一遍反而更接近
 * "这次会话第一次看到它"的语义。
 */

/**
 * 最多记多少条（超出就把最早那批清掉）。
 *
 * 为什么要有上限：视频流会一直往下翻，一个进程里刷几百条很正常；`Map` 只增不减会慢慢涨，
 * 虽然一条只有几十字节，但代码里"永远不清理的全局表"是个坏习惯。
 */
const MAX_ENTRIES: number = 600;

export class ReelSeenTime {
  /** shortcode → 第一次见到的时刻（毫秒）。 */
  private static seen: Map<string, number> = new Map<string, number>();

  /**
   * 记下一批 reel 的"第一次见到"时刻（**已经记过的不覆盖**）。
   *
   * @param shortcodes 列表里这一批的短码（ReelsPage 收到列表时逐条报上来）。
   */
  static note(shortcodes: Array<string>): void {
    const now: number = Date.now();
    if (ReelSeenTime.seen.size + shortcodes.length > MAX_ENTRIES) {
      // 到量了就从零开始记：兜底值旧一点无所谓，也无从判断哪条"更该留"。
      ReelSeenTime.seen.clear();
    }
    for (let index: number = 0; index < shortcodes.length; index++) {
      const code: string = shortcodes[index];
      if (code.length === 0 || ReelSeenTime.seen.has(code)) {
        continue;
      }
      ReelSeenTime.seen.set(code, now);
    }
  }

  /**
   * 这条第一次见到的时刻；**没见过就当场记下并返回"现在"**。
   *
   * 当场记的理由：兜底值至少和"我们确实见过它"这件事一致，不会返回 0 让卡片那一行空着。
   */
  static of(shortcode: string): number {
    const known: number | undefined = ReelSeenTime.seen.get(shortcode);
    if (known !== undefined) {
      return known;
    }
    const now: number = Date.now();
    ReelSeenTime.note([shortcode]);
    return now;
  }
}
