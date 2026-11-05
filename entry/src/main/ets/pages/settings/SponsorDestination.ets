/*
 * **赞助开发者页 destination**：从 pages/Index 迁出的小页面。
 */

import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { SponsorPage } from '../../components/SponsorPage';

@Component
export struct SponsorDestination {
  @Prop titleStyle: TitleBarStyleOptions;

  build() {
    HdsNavDestination() {
      SponsorPage()
    }
    .titleBar({
      content: {
        title: { mainTitle: '赞助开发者' }
      },
      style: this.titleStyle,
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .hideBackButton(false)
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .clip(false)
  }
}
