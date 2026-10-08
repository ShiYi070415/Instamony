/*
 * 「发布新帖子」页面。
 *
 * 从首页标题栏的加号进来（见 Index.openCreatePost）。**独立页面**而不是浮层/半模态：
 * 发布是一整条编辑流程，需要自己的整屏空间和返回栈，页面自己 popUrl 回首页即可。
 *
 * 目前是骨架：只交代"这一步要选媒体"，真正的相册选择 / 上传 / 描述还没接。
 * 接的时候照这个结构往下长：
 *   - 选媒体：photoAccessHelper 的 PhotoViewPicker（照片和视频都能选）；
 *   - 预览 + 描述/位置/标签编辑；
 *   - 发布：走 IG 的网页发布器（复用常驻 WebView 的会话，见 Index.openWeb），
 *     原生这边不直接调写接口。
 *
 * 标题栏沿用工程统一的 HdsNavigation（和首页一致：MINI、沉浸光感材质、忽略安全区自己留白），
 * 只是这一页有上一级可回，所以显示返回键，返回走 router.back()。
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
// 沉浸光感的档位来自设定页（和首页同一份设置、同一套换算）。
import { MATERIAL_LEVEL_ADAPTIVE, SETTING_MATERIAL_LEVEL } from '../core/AppSettings';
import { immersiveLevel } from '../core/ImmersiveLight';
import { PlatformCap } from '../core/PlatformCap';

const DOMAIN: number = 0xFF00;
const TAG: string = 'InstarmonyCreatePost';
/** 和首页一样的顶部留白算法：状态栏 38 + MINI 标题栏 56（见 FeedList 的 FEED_START_OFFSET）。 */
const CONTENT_TOP_OFFSET: number = 94;

@Entry
@Component
struct CreatePost {
  /**
   * 沉浸光感的档位：**读设定页那一份**（@StorageProp，改档位这一页也跟着变）。
   *
   * 以前这一页自己按设备能力定了一档（不支持 IMMERSIVE 就 SMOOTH），现在这段判断
   * 收进了 core/ImmersiveLight：档位由用户选，设备能力不够时那里负责降级。
   */
  @StorageProp(SETTING_MATERIAL_LEVEL) materialLevel: string = MATERIAL_LEVEL_ADAPTIVE;

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'page opened, material level=%{public}s', this.materialLevel);
  }

  /**
   * 标题栏样式：沉浸光感那段**只在设备支持 HDS 系统材质时下发**。
   *
   * `hdsMaterial.MaterialType` 与 `systemMaterialEffect` 都是 6.1.0(23) 起才有的，
   * 而本包 compatibleSdk 是 20：直接写在字面量里，低版本设备拿到的是 undefined
   * （枚举成员不存在），轻则没效果、重则抛异常。判定见 core/PlatformCap。
   */
  private titleStyle(): TitleBarStyleOptions {
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: {
        enableScrollEffect: false,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
      }
    };
    if (PlatformCap.hasHdsMaterial()) {
      // 沉浸光感：和首页标题栏同一套配置（档位同源，见 immersiveLevel）。
      style.systemMaterialEffect = {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: immersiveLevel(this.materialLevel)
      };
    }
    return style;
  }

  /** 返回首页：发布页是 pushUrl 进来的，back 就够。 */
  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    HdsNavigation() {
      Column() {
        // 空态骨架：一个图标 + 一句说明。真正的编辑器接上来之后替换这块。
        Column({ space: 14 }) {
          SymbolGlyph($r('sys.symbol.plus_square_on_square'))
            .fontSize(56)
            .fontColor([$r('app.color.secondary_text')])
          Text($r('app.string.create_post_title'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
          Text($r('app.string.create_post_hint'))
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      // 顶部避开标题栏：和首页一样用 padding 而不是 margin（标题栏是浮在上面的）。
      .padding({ top: CONTENT_TOP_OFFSET })
    }
    .width('100%')
    .height('100%')
    .mode(NavigationMode.Stack)
    .titleBar({
      content: {
        title: { mainTitle: $r('app.string.create_post_title') }
      },
      style: this.titleStyle(),
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    // 这一页有上一级（首页），所以显示返回键。
    // 注意：HdsNavigation（不是 HdsNavDestination）没有 onBackPressed/onNavBackClick 回调，
    // 返回由 Navigation 自己的路由栈处理；这一页是 router 页面，栈里没有 NavPath 条目，
    // 所以真正的返回兜底在页面自己的 onBackPress（系统返回键/手势）里。
    .hideBackButton(false)
    .titleMode(HdsNavigationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }

  /** 系统返回键 / 返回手势：和标题栏返回键走同一条路。 */
  onBackPress(): boolean {
    try {
      this.getUIContext().getRouter().back();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'back failed: %{public}s', e.message);
    }
    return true;
  }
}
