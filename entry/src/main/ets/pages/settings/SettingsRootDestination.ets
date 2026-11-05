/*
 * **设置一级页 destination**：左栏单栏 / 右栏打开前的根设置页。
 * 与 SettingsDestination 共用 SettingsPanel，但打开二级页的回调不同。
 */

import {
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { SettingsPanel } from '../../components/SettingsPanel';

@Component
export struct SettingsRootDestination {
  @Prop signedIn: boolean = false;
  @Prop titleStyle: TitleBarStyleOptions;

  onSignOut: () => void = (): void => {
  };
  onQualityChanged: () => void = (): void => {
  };
  onOpenSection: (section: string) => void = (section: string): void => {
  };
  onOpenSponsor: () => void = (): void => {
  };
  onShown: () => void = (): void => {
  };
  onHidden: () => void = (): void => {
  };
  onBackPressed: () => boolean = (): boolean => false;

  build() {
    HdsNavDestination() {
      SettingsPanel({
        signedIn: this.signedIn,
        onSignOut: (): void => {
          this.onSignOut();
        },
        onQualityChanged: (): void => {
          this.onQualityChanged();
        },
        onOpenSection: (section: string): void => {
          this.onOpenSection(section);
        },
        onOpenSponsor: (): void => {
          this.onOpenSponsor();
        }
      })
    }
    .titleBar({
      content: {
        title: { mainTitle: $r('app.string.action_settings') }
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
