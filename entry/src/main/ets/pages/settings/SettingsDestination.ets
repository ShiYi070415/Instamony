/*
 * **设置二级/三级页 destination**：从 pages/Index 的 destinationBuilder 里搬出来的第一页。
 *
 * 视觉、HDS 标题、返回键、SettingsPanel 参数都保持原样；Index 只负责传回调。
 */

import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { SettingsPanel } from '../../components/SettingsPanel';

@Component
export struct SettingsDestination {
  @Prop detailSection: string = '';
  @Prop title: ResourceStr = '';
  @Prop signedIn: boolean = false;
  @Prop titleStyle: TitleBarStyleOptions;

  onSignOut: () => void = (): void => {
  };
  onQualityChanged: () => void = (): void => {
  };
  onOpenSection: (section: string) => void = (section: string): void => {
  };
  onOpenSubsection: (section: string) => void = (section: string): void => {
  };
  onOpenSponsor: () => void = (): void => {
  };
  onBackPressed: () => boolean = (): boolean => false;

  build() {
    HdsNavDestination() {
      SettingsPanel({
        detailSection: this.detailSection,
        standaloneDetail: true,
        signedIn: this.signedIn,
        onSignOut: (): void => {
          this.onSignOut();
        },
        onQualityChanged: (): void => {
          this.onQualityChanged();
        },
        onOpenSponsor: (): void => {
          this.onOpenSponsor();
        },
        onOpenSection: (section: string): void => {
          this.onOpenSection(section);
        },
        onOpenSubsection: (section: string): void => {
          this.onOpenSubsection(section);
        }
      })
    }
    .titleBar({
      content: {
        title: { mainTitle: this.title }
      },
      style: this.titleStyle,
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .hideBackButton(false)
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .clip(false)
    .onBackPressed((): boolean => this.onBackPressed())
  }
}
