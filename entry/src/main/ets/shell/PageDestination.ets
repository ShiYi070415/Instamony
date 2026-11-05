/*
 * **通用详情页 destination**：HDS 标题 + 内容 + 菜单 + 显示/隐藏/返回回调。
 * 用于帖子页、用户主页、Reels 详情、新增账号这些“结构相同、内容不同”的页面。
 */

import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationMenuContentOptions,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';

@Component
export struct PageDestination {
  @Prop title: ResourceStr = '';
  @Prop titleStyle: TitleBarStyleOptions;
  @Prop hideTitleBar: boolean = false;
  @Prop hideBackButton: boolean = false;

  @Prop menu: HdsNavigationMenuContentOptions = {};
  @BuilderParam content: () => void;

  onShown: () => void = (): void => {
  };
  onHidden: () => void = (): void => {
  };
  onBackPressed: () => boolean = (): boolean => false;

  build() {
    HdsNavDestination() {
      this.content()
    }
    .titleBar({
      content: {
        title: { mainTitle: this.title },
        menu: this.menu
      },
      style: this.titleStyle,
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .hideBackButton(this.hideBackButton)
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideTitleBar(this.hideTitleBar, true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .clip(false)
    .onShown((): void => {
      this.onShown();
    })
    .onHidden((): void => {
      this.onHidden();
    })
    .onBackPressed((): boolean => this.onBackPressed())
  }
}
