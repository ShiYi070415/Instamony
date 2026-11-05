/*
 * **窗口断点服务**：多设备适配只认这一份宽度判断。
 *
 * 目标（见 docs/multi-device-adaptive-refactor-plan.md）：删除散落在 Index 里的
 * `>= 600` / `>= 840` 魔法数字，页面只读 Breakpoint。
 *
 * 现在先做“取值收敛”：行为与原来的 tabletWideShell / tabletSplitEnabled 完全一致，
 * 不改布局，只把阈值收到一处，后续再让侧边栏/标题/内容框架都从这里派生。
 */

/** 官方断点：Compact < 600vp，Medium 600–839vp，Expanded ≥ 840vp。 */
export enum LayoutBreakpoint {
  Compact = 0,
  Medium = 1,
  Expanded = 2
}

export class WindowLayoutService {
  static readonly MEDIUM_MIN_VP: number = 600;
  static readonly EXPANDED_MIN_VP: number = 840;

  /** 按窗口宽度（vp）取断点；宽度无效时按 Compact 处理。 */
  static breakpointOf(widthVp: number): LayoutBreakpoint {
    if (!Number.isFinite(widthVp) || widthVp < WindowLayoutService.MEDIUM_MIN_VP) {
      return LayoutBreakpoint.Compact;
    }
    if (widthVp < WindowLayoutService.EXPANDED_MIN_VP) {
      return LayoutBreakpoint.Medium;
    }
    return LayoutBreakpoint.Expanded;
  }

  /** 宽屏壳：有侧边栏、内容按侧栏让位（原来的 tabletWideShell）。 */
  static isWide(widthVp: number): boolean {
    return WindowLayoutService.breakpointOf(widthVp) !== LayoutBreakpoint.Compact;
  }

  /** 双栏：侧边栏 + 右栏（原来的 tabletSplitEnabled）。 */
  static isExpanded(widthVp: number): boolean {
    return WindowLayoutService.breakpointOf(widthVp) === LayoutBreakpoint.Expanded;
  }
}
