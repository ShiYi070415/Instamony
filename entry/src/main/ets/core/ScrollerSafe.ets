/**
 * Scroller.currentOffset() 在列表还没挂载 / 页面重建的那一拍会返回 undefined。
 * 直接取 `.yOffset` 会抛 `Cannot read property yOffset of undefined`（真机 jscrash 已复现）。
 *
 * 所有滚动回调统一走这里：拿不到就当 0，只影响一次诊断/位置判断，不影响列表本身。
 */
export function safeScrollY(scroller: Scroller): number {
  try {
    const offset = scroller.currentOffset();
    return offset === undefined ? 0 : offset.yOffset;
  } catch (error) {
    return 0;
  }
}
