/*
 * 列表滚动 → 底栏动画的**共用记账**。
 *
 * 底栏那两套动画（下沉收缩 / 系统显隐）的判据是"这一帧往上还是往下滚了多少"，
 * 所以每个带底栏的页面都要做同一件事：把 List 的 `onDidScroll` 里读到的偏移量，换算成
 * **增量**再报给页面（见 pages/Index.onFeedScroll）。
 *
 * 三个页面（私信 / 搜索 / 我的）各抄一份太容易抄歪（比如忘了"首帧只记基准"），所以收在这里；
 * 首页那条信息流有自己的版本（它还要顺手报叠字行的位置，见 FeedList.reportScrollDelta），
 * 逻辑一致。
 */

/**
 * 逐帧算滚动增量。
 *
 * 用法：页面持有一个实例，在 List 的 `onDidScroll` 里
 * `this.delta.report(scroller.currentOffset().yOffset, state, this.onFeedScroll)`。
 */
export class ScrollDelta {
  /** 上一帧的纵向偏移量。 */
  private last: number = 0;
  /** 有没有采到过基准。 */
  private sampled: boolean = false;

  /**
   * 算这一帧的增量并回调。
   *
   * **首帧只记基准、不报增量**：列表被重建时（切 tab 回来）偏移量会先归零再恢复，
   * 直接做差会凭空报一次几千 vp 的大滚动 —— 底栏会被那次假增量猛地沉下去。
   */
  report(y: number, state: ScrollState,
         sink: (deltaY: number, offsetY: number, scrollState: ScrollState) => void): void {
    if (!this.sampled) {
      this.sampled = true;
      this.last = y;
      return;
    }
    const delta: number = y - this.last;
    this.last = y;
    if (delta === 0) {
      return;
    }
    sink(delta, y, state);
  }

  /** 列表重建 / 切页时清掉基准（下一次 report 重新采样）。 */
  reset(): void {
    this.sampled = false;
    this.last = 0;
  }
}
