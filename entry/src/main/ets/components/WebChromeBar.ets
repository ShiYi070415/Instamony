/*
 * 揭出网页时的顶部 chrome：返回 / 标题 / 刷新 / 回到原生。
 *
 * 「返回」的语义由页面决定（网页能后退就后退，否则算关闭），这里只把点击转出去。
 */

@Component
export struct WebChromeBar {
  onBack: () => void = (): void => {
  };
  onReload: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };

  build() {
    Row({ space: 6 }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(25)
          .fontColor([$r('app.color.primary_text')])
      }
      .width(40)
      .height(44)
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onBack();
      })
      Text('Instagram')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Blank()
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(21)
          .fontColor([$r('app.color.primary_text')])
      }
      .width(40)
      .height(44)
      .backgroundColor(Color.Transparent)
      .onClick((): void => {
        this.onReload();
      })
      Button($r('app.string.web_close'))
        .height(34)
        .fontSize(13)
        .backgroundColor($r('app.color.field_background'))
        .fontColor($r('app.color.primary_text'))
        .borderRadius(17)
        .onClick((): void => {
          this.onClose();
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 6, right: 8 })
    .backgroundColor($r('app.color.page_background'))
  }
}
