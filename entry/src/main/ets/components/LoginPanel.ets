/*
 * 未登录时的引导页。
 *
 * 登录本身在 Instagram 官方网页里完成，这里只负责把用户送过去、以及在他回来时
 * 重新核对 Cookie 罐。
 *
 * 两颗按钮都走全 app 统一的沉浸光感材质（内容区只有 Toggle/Slider/Select 生效，
 * 见 MaterialSurface.ets 的文件头）；主次靠文字颜色区分（强调色 / 默认色）。
 */

import { MaterialLabelButton, TONE_ACCENT } from './MaterialSurface';

@Component
export struct LoginPanel {
  onOpenWeb: () => void = (): void => {
  };
  onRecheck: () => void = (): void => {
  };

  build() {
    Column({ space: 16 }) {
      Blank()
      Text($r('app.string.login_title'))
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
      Text($r('app.string.login_hint'))
        .fontSize(14)
        .fontColor($r('app.color.secondary_text'))
        .textAlign(TextAlign.Center)
        .lineHeight(21)
      MaterialLabelButton({
        labelRes: $r('app.string.login_open_web'),
        fullWidth: true,
        fontSize: 16,
        tone: TONE_ACCENT,
        onTap: (): void => {
          this.onOpenWeb();
        }
      })
      MaterialLabelButton({
        labelRes: $r('app.string.login_recheck'),
        fullWidth: true,
        fontSize: 16,
        onTap: (): void => {
          this.onRecheck();
        }
      })
      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 36, right: 36 })
  }
}
