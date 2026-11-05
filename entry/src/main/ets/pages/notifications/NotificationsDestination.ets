/*
 * **通知页 destination**：从 pages/Index 迁出的第二页。
 *
 * HDS 标题、刷新、关注回调、显示/隐藏、返回语义保持原样。
 */

import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { NotificationsPanel } from '../../components/NotificationsPanel';
import { NotifyItem } from '../../model/Notification';

@Component
export struct NotificationsDestination {
  @Prop items: Array<NotifyItem> = [];
  @Prop loading: boolean = false;
  @Prop state: string = '';
  @Prop diag: string = '';
  @Link refreshing: boolean;
  @Prop titleStyle: TitleBarStyleOptions;

  onRefresh: () => void = (): void => {
  };
  onFollow: (item: NotifyItem) => void = (item: NotifyItem): void => {
  };
  onShown: () => void = (): void => {
  };
  onHidden: () => void = (): void => {
  };
  onBackPressed: () => boolean = (): boolean => false;

  build() {
    HdsNavDestination() {
      NotificationsPanel({
        items: this.items,
        loading: this.loading,
        state: this.state,
        diag: this.diag,
        refreshing: this.refreshing,
        onRefresh: (): void => {
          this.onRefresh();
        },
        onFollow: (item: NotifyItem): void => {
          this.onFollow(item);
        }
      })
    }
    .titleBar({
      content: {
        title: { mainTitle: $r('app.string.notifications') }
      },
      style: this.titleStyle,
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .hideBackButton(false)
    .titleMode(HdsNavDestinationTitleMode.MINI)
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
