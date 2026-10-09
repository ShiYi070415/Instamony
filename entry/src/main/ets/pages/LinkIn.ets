/*
 * 深链落地页（`instarmony://…` 冷启动时先铺这一页）。
 *
 * ## 它在链路里的位置
 *   浏览器/其他 App 打开 instarmony://open?route=post&id=XYZ
 *     → 系统按 module.json5 的 skills.uris 命中本 App
 *     → EntryAbility.onCreate 收到 Want.uri（冷启动），交给 core/DeepLink 解析
 *     → **本页**把"收到了什么"摊开给用户看
 *     → 用户点「打开」→ pages/Index 取走 intent 并执行
 *
 * ## 为什么要单独一页而不是直接进首页
 * 两个理由：
 *   1. 冷启动时首页的网页宿主还没建好，立刻切 tab / 导航网页不可靠（见 Index.consumePendingDeepLink
 *      的等待逻辑）；先落一页、等用户点一下，天然把这个空窗期让过去。
 *   2. 答辩/演示需要**看得见**这一步：Want 到底有没有到、解析出什么、认识不认识这个目标，
 *      全写在这一页上（而不是只在 hilog 里）。
 *
 * 纯展示页：不拉数据、不碰会话，所以任何解析失败都不会影响 App 其它部分。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  hdsMaterial,
  ScrollEffectType,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { MATERIAL_LEVEL_ADAPTIVE, SETTING_MATERIAL_LEVEL } from '../core/AppSettings';
import { immersiveLevel } from '../core/ImmersiveLight';
import { PlatformCap } from '../core/PlatformCap';
import { DeepLink, DeepLinkIntent } from '../core/DeepLink';

const DOMAIN: number = 0xFF00;
const TAG: string = 'InstarmonyDeepLink';
/** 和 CreatePost / 首页一致的顶部留白（状态栏 38 + MINI 标题栏 56）。 */
const CONTENT_TOP_OFFSET: number = 94;

@Entry
@Component
struct LinkIn {
  /** 收到并解析出来的 intent（解析不出来就是 null）。 */
  @State private intent: DeepLinkIntent | null = null;
  @State private rawUri: string = '';
  /** 沉浸光感档位（和工程其它页面同源：读设定页那一份，见 AppSettings）。 */
  @State private materialLevel: string = MATERIAL_LEVEL_ADAPTIVE;

  @StorageProp(SETTING_MATERIAL_LEVEL) private settingLevel: string = MATERIAL_LEVEL_ADAPTIVE;

  aboutToAppear(): void {
    this.materialLevel = this.settingLevel;
    // 路由参数由 EntryAbility 在 loadContent 时传进来（见它的 landingParams）。
    const params: Record<string, Object> | undefined = this.getUIContext().getRouter().getParams();
    const uri: string = params === undefined ? '' : `${params['uri'] ?? ''}`;
    this.rawUri = uri;
    this.intent = DeepLink.parse(uri);
    hilog.info(DOMAIN, TAG, 'landing uri=%{public}s parsed=%{public}s',
      uri, this.intent === null ? 'null' : this.intent.describe());
  }

  /** 标题栏样式：和工程其它页面同一套（沉浸光感只在设备支持 HDS 材质时下发）。 */
  private titleStyle(): TitleBarStyleOptions {
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: {
        enableScrollEffect: false,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
      }
    };
    if (PlatformCap.hasHdsMaterial()) {
      style.systemMaterialEffect = {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: immersiveLevel(this.settingLevel)
      };
    }
    return style;
  }

  /** 进首页：intent 已经由 EntryAbility 存进 core/DeepLink，Index 起来后会自己取走执行。 */
  private openHome(): void {
    try {
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'open home failed: %{public}s', (err as BusinessError).message);
    }
  }

  /** 一行"字段名 + 值"的展示块。 */
  @Builder
  private Field(label: string, value: string, emphasize: boolean) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
      Text(value.length > 0 ? value : '—')
        .fontSize(emphasize ? 17 : 14)
        .fontWeight(emphasize ? FontWeight.Medium : FontWeight.Normal)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    HdsNavigation() {
      Scroll() {
        Column({ space: 18 }) {
          // —— 顶部说明 ——
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.link'))
              .fontSize(40)
              .fontColor([$r('app.color.accent')])
            Text('通过深链进入')
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary_text'))
            Text('链接由系统通过 Want 送进本应用，下面是从 URI 里解析出来的内容。')
              .fontSize(13)
              .fontColor($r('app.color.secondary_text'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: 12 })

          // —— 原始 URI ——
          Column({ space: 6 }) {
            this.Field('原始 URI（Want.uri）', this.rawUri, false)
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.field_background'))
          .borderRadius(12)

          // —— 解析结果 ——
          Column({ space: 12 }) {
            this.Field('route', this.intent === null ? '' : this.intent.route, true)
            this.Field('id', this.intent === null ? '' : this.intent.id, true)
            Row({ space: 8 }) {
              Text(this.intent !== null && this.intent.isKnown() ? '✓ 认识这个目标' : '✗ 不认识的目标')
                .fontSize(12)
                .fontColor(this.intent !== null && this.intent.isKnown()
                  ? $r('app.color.accent') : $r('app.color.like_active'))
              Text(this.intent !== null && this.intent.isComplete() ? '✓ 参数完整' : '✗ 参数缺失')
                .fontSize(12)
                .fontColor(this.intent !== null && this.intent.isComplete()
                  ? $r('app.color.accent') : $r('app.color.like_active'))
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(12)
          .border({ width: 1, color: $r('app.color.divider') })

          // —— 动作 ——
          Column({ space: 10 }) {
            Button('打开并执行这条链接')
              .width('100%')
              .backgroundColor(this.intent !== null && this.intent.isComplete()
                ? $r('app.color.accent') : $r('app.color.divider'))
              .fontColor($r('app.color.on_accent'))
              .enabled(this.intent !== null && this.intent.isComplete())
              .onClick((): void => this.openHome())

            Button('忽略，直接进首页')
              .width('100%')
              .backgroundColor($r('app.color.field_background'))
              .fontColor($r('app.color.primary_text'))
              .onClick((): void => {
                // 丢掉这条 intent，免得首页一起来又被它拽走。
                DeepLink.take();
                this.openHome();
              })
          }
          .width('100%')

          // —— 支持的形态（演示时把要试的链接直接抄走）——
          Column({ space: 6 }) {
            Text('支持的链接')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.secondary_text'))
            Text('instarmony://open?route=home\n' +
              'instarmony://open?route=reels\n' +
              'instarmony://open?route=search\n' +
              'instarmony://open?route=direct\n' +
              'instarmony://open?route=profile&id=<用户名>\n' +
              'instarmony://open?route=post&id=<shortcode>')
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor($r('app.color.field_background'))
          .borderRadius(12)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .padding({ top: CONTENT_TOP_OFFSET })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .mode(NavigationMode.Stack)
    .titleBar({
      content: {
        title: { mainTitle: 'Deep Link' }
      },
      style: this.titleStyle(),
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    // 这一页是 replaceUrl 进来的、没有上一级，所以不显示返回键。
    .hideBackButton(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
