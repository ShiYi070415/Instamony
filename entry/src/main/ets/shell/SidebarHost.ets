/*
 * **侧边栏宿主**：只负责“第一列 + 固定窗口高度 + 安全区”，不关心里面放什么。
 *
 * 为什么要单独一层：
 *   · 页面级键盘 RESIZE 会缩短根页面；侧边栏如果直接写 height('100%')，会跟着缩，
 *     底部按钮被压到一起；
 *   · 侧边栏必须始终是 Row 的第一列，高度取窗口高度，而不是内容页高度；
 *   · 背景铺到系统状态栏/手势条，避免设置页打开时透出后面的内容。
 *
 * 里面的内容仍由 pages/Index 的 tabletSidebar() 提供，视觉不变。
 */

@Component
export struct SidebarHost {
  @Prop widthVp: number = 0;
  /** 固定窗口高度（vp）；0 = 退回 100%。 */
  @Prop heightVp: number = 0;
  /** Reels 时侧栏透明，让视频背景铺过去。 */
  @Prop transparent: boolean = false;

  @BuilderParam content: () => void;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.content()
    }
    .width(this.widthVp > 0 ? this.widthVp : '100%')
    .height(this.heightVp > 0 ? this.heightVp : '100%')
    .backgroundColor(this.transparent
      ? Color.Transparent : $r('app.color.page_background'))
    // 背景铺进上下系统避让区（状态栏 / 手势条），不留下透明缝。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
