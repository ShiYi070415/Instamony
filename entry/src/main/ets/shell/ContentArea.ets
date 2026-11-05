/*
 * **内容区宿主**：侧边栏之外的整块区域。
 *
 * 宽度/权重规则从 Index 的 Column 链搬进来：
 *   · 双栏且左栏固定宽：widthVp > 0，layoutWeight 0；
 *   · 单栏/整页：width 100%，layoutWeight 1。
 *
 * 页面级键盘 RESIZE 只影响这里；侧边栏固定在 SidebarHost，不跟着缩。
 */

@Component
export struct ContentArea {
  @Prop widthVp: number = 0;
  @Prop fill: boolean = true;

  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }
    .width(this.widthVp > 0 ? this.widthVp : '100%')
    .layoutWeight(this.fill ? 1 : 0)
    .height('100%')
  }
}
