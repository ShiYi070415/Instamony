/*
 * 赞助开发者页面。
 *
 * 收款方式分 CNY / HKD 两套，每套各一张支付宝、一张微信收款码：
 *   · CNY：sponsor_cny_alipay.png / sponsor_cny_wechat.png
 *   · HKD：sponsor_hkd_alipay.png / sponsor_hkd_wechat.png
 *
 * 图片都放在 entry/src/main/resources/base/media/ 下；替换同名文件即可生效。
 *
 * 赞助是自愿行为，页面不接支付 SDK、不校验金额，也不承诺任何权益。
 */

import { ProfileSegmentBar, SEGMENT_MODE_SPONSOR } from './ProfileSegmentBar';
import { MaterialLabelButton } from './MaterialSurface';
import { fileIo, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const PAGE_PADDING: number = 12;
const CARD_RADIUS: number = 16;
const CARD_BORDER: number = 1;
const TOP_OFFSET: number = 94;
const BOTTOM_SAFE: number = 34;

@Component
export struct SponsorPage {
  /** 0 = CNY，1 = HKD。 */
  @State private currencyIndex: number = 0;
  private swiperController: SwiperController = new SwiperController();

  @Builder
  groupHeader(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.secondary_text'))
      .width('100%')
      .padding({ left: 4, right: 4, top: 18, bottom: 6 })
  }

  /** 把内置收款码写到用户选的路径（不需要存储权限）。 */
  private async downloadQr(image: Resource, fileName: string): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      const data: Uint8Array = await context.resourceManager.getMediaContent(image.id);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [fileName];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: Array<string> = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, data.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      promptAction.showToast({ message: '收款码已保存', duration: 1800 });
    } catch (error) {
      const message: string = (error as BusinessError).message ?? 'save-failed';
      hilog.warn(0xFF00, 'SponsorPage', 'save qr failed: %{public}s', message);
      promptAction.showToast({ message: `保存失败：${message}`, duration: 2200 });
    }
  }

  @Builder
  qrCard(title: string, image: Resource, fileName: string) {
    Column({ space: 10 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      // 两张收款码统一铺满卡片内容宽度，并保持正方形，宽度/高度完全一致。
      Image(image)
        .width('100%')
        .aspectRatio(1)
        .objectFit(ImageFit.Contain)
        .borderRadius(12)
        .draggable(false)
      Text('扫码赞助，金额随意')
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
      // 沉浸光感材质按钮（全 app 同一套 MaterialLabelButton）。
      MaterialLabelButton({
        labelText: '下载收款码',
        fullWidth: true,
        pillHeight: 40,
        fontSize: 14,
        onTap: (): void => {
          this.downloadQr(image, fileName);
        }
      })
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(CARD_RADIUS)
    .border({ width: CARD_BORDER, color: $r('app.color.divider') })
    .backgroundColor(Color.Transparent)
  }

  @Builder
  currencyPage(index: number) {
    Column({ space: 10 }) {
      this.groupHeader(index === 0 ? '人民币收款码' : '港币收款码')
      this.qrCard('微信支付', index === 0
        ? $r('app.media.sponsor_cny_wechat')
        : $r('app.media.sponsor_hkd_wechat'),
        index === 0 ? 'sponsor_cny_wechat.png' : 'sponsor_hkd_wechat.png')
      this.qrCard('支付宝', index === 0
        ? $r('app.media.sponsor_cny_alipay')
        : $r('app.media.sponsor_hkd_alipay'),
        index === 0 ? 'sponsor_cny_alipay.png' : 'sponsor_hkd_alipay.png')
    }
    .width('100%')
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
  }

  build() {
    Column() {
      Stack()
        .width('100%')
        .height(TOP_OFFSET)

      List() {
        ListItem() {
          Column({ space: 10 }) {
            Text('支持 Instamony')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary_text'))
              .width('100%')
            Text('如果这个 App 对你有帮助，可以请开发者喝杯咖啡。赞助完全自愿，金额随意，不代表任何付费权益。')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
          }
          .borderRadius(CARD_RADIUS)
          .border({ width: CARD_BORDER, color: $r('app.color.divider') })
          .backgroundColor(Color.Transparent)
          .padding(16)
        }
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

        ListItem() {
          // 和「我的」页/Reels 同一条分段按钮：沉浸光感胶囊 + 可拖动灰底药丸。
          ProfileSegmentBar({
            tab: this.currencyIndex,
            count: 2,
            mode: SEGMENT_MODE_SPONSOR,
            onSelect: (index: number): void => {
              this.currencyIndex = index;
              this.swiperController.changeIndex(index, true);
            }
          })
        }

        ListItem() {
          Swiper(this.swiperController) {
            this.currencyPage(0)
            this.currencyPage(1)
          }
          .width('100%')
          .height(960)
          .loop(false)
          .indicator(false)
          .duration(220)
          .curve(Curve.EaseOut)
          .onChange((index: number): void => {
            this.currencyIndex = index;
          })
        }

        ListItem() {
          Text('提示：二维码是静态收款码，请只用于本人扫码赞助；不要转发给陌生人。'
            + '海外用户如果扫码失败，可以切换到 HKD 或使用对应钱包的跨境支付。')
            .fontSize(11)
            .lineHeight(17)
            .fontColor($r('app.color.secondary_text'))
            .width('100%')
            .padding({ left: 4, right: 4, top: 14 })
        }
        .padding({ left: PAGE_PADDING, right: PAGE_PADDING })

        ListItem() {
          Row().width('100%').height(BOTTOM_SAFE)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .clip(false)
    }
    .width('100%')
    .height('100%')
    .linearGradient({
      angle: 180,
      colors: [
        [$r('app.color.settings_gradient_top'), 0.0],
        [$r('app.color.settings_gradient_bottom'), 1.0]
      ]
    })
  }
}
