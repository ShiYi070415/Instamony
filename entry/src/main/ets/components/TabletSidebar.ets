/*
 * 平板左侧浮层侧边栏。
 *
 * **为什么单独一个组件**：展开/收起如果放在 Index 的 @State 里，点一下展开按钮
 * 会让整个 Index（包括 HdsNavigation 和页面内容）重算一遍，已经返回的页面可能
 * 在重建时被重新画出来。展开状态收进这个组件后，父页面不参与状态变化，只传固定
 * 尺寸和回调。
 */
import { curves } from '@kit.ArkUI';
import { AppTab } from '../model/AppTab';
import { MaterialChipButton, SurfaceModifier } from './MaterialSurface';

interface SidebarTab {
  tab: AppTab;
  iconNormal: Resource;
  iconSelected: Resource;
  label: ResourceStr;
}

const TABS: SidebarTab[] = [
  { tab: AppTab.Home, iconNormal: $r('sys.symbol.house'), iconSelected: $r('sys.symbol.house_fill'), label: $r('app.string.tab_home') },
  { tab: AppTab.Reels, iconNormal: $r('sys.symbol.template'), iconSelected: $r('sys.symbol.template_fill'), label: $r('app.string.tab_reels') },
  { tab: AppTab.Direct, iconNormal: $r('sys.symbol.paperplane'), iconSelected: $r('sys.symbol.paperplane_fill'), label: $r('app.string.tab_direct') },
  { tab: AppTab.Search, iconNormal: $r('sys.symbol.magnifyingglass'), iconSelected: $r('sys.symbol.magnifyingglass'), label: $r('app.string.tab_search') },
  { tab: AppTab.Profile, iconNormal: $r('sys.symbol.person'), iconSelected: $r('sys.symbol.person_fill'), label: $r('app.string.tab_profile') }
];

const TAB_ICON: number = 25;

@Component
export struct TabletSidebar {
  @Prop selectedIndex: number = 0;
  @Prop whiteIcons: boolean = false;
  @Prop loginPage: boolean = false;
  @Prop settingsOverlay: boolean = false;
  @Prop buttonSize: number = 56;
  @Prop uiScale: number = 1;
  @Prop gutter: number = 14;
  @Prop collapsedWidth: number = 84;
  @Prop expandedWidth: number = 220;
  @Prop expandedItemWidth: number = 196;
  @Prop thickness: string = '';
  onTab: (index: number) => void = (index: number): void => {
  };
  onNotifications: () => void = (): void => {
  };
  onSettings: () => void = (): void => {
  };

  @State private expanded: boolean = false;
  @State private progress: number = 0;

  private panelWidth(): number {
    return Math.round(this.collapsedWidth + (this.expandedWidth - this.collapsedWidth) * this.progress);
  }

  private itemWidth(): number {
    return Math.round(this.buttonSize + (this.expandedItemWidth - this.buttonSize) * this.progress);
  }

  private ink(selected: boolean): ResourceColor {
    if (this.whiteIcons) {
      return Color.White;
    }
    return selected ? $r('sys.color.font_primary') : $r('sys.color.font_secondary');
  }

  private toggle(): void {
    const target: boolean = !this.expanded;
    this.expanded = target;
    this.getUIContext().animateTo({
      duration: 320,
      curve: curves.springMotion(0.42, 0.82)
    }, (): void => {
      this.progress = target ? 1 : 0;
    });
  }

  build() {
    Column() {
      Row() {
        MaterialChipButton({
          symbol: this.expanded ? $r('sys.symbol.chevron_left') : $r('sys.symbol.chevron_right'),
          labelRes: $r('app.string.sidebar_collapse'),
          labelVisible: this.expanded,
          anchorStart: true,
          swallowLongPress: true,
          tapDebounceMs: 100,
          chipHeight: this.buttonSize,
          chipWidth: this.itemWidth(),
          iconSlotWidth: this.buttonSize,
          iconSize: Math.round(22 * this.uiScale),
          fontSize: Math.round(14 * this.uiScale),
          autoInvert: false,
          tint: this.whiteIcons ? '#FFFFFF' : '',
          onTap: (): void => {
            this.toggle();
          }
        })
      }
      .width('100%')
      .height(this.buttonSize + 8)
      .justifyContent(FlexAlign.Start)
      .padding({ left: this.gutter })

      Stack({ alignContent: Alignment.Start }) {
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Column() {
            ForEach(TABS, (item: SidebarTab, index: number): void => {
              Row({ space: Math.round(8 * this.uiScale) }) {
                Stack({ alignContent: Alignment.Center }) {
                  SymbolGlyph(this.selectedIndex === index ? item.iconSelected : item.iconNormal)
                    .fontSize(Math.round(TAB_ICON * this.uiScale))
                    .fontColor([this.ink(this.selectedIndex === index)])
                }
                .width(this.buttonSize)
                .height(this.buttonSize)
                if (this.expanded) {
                  Text(item.label)
                    .fontSize(Math.round(14 * this.uiScale))
                    .fontWeight(this.selectedIndex === index ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(this.ink(this.selectedIndex === index))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .transition(TransitionEffect.OPACITY
                      .combine(TransitionEffect.translate({ x: -8 }))
                      .animation({ duration: 160, curve: Curve.EaseOut }))
                }
              }
              .width(this.itemWidth())
              .height(this.buttonSize)
              .padding({ right: this.expanded ? Math.round(12 * this.uiScale) : 0 })
              .justifyContent(FlexAlign.Start)
              .borderRadius(this.buttonSize / 2)
              .backgroundColor(Color.Transparent)
              .onClick((): void => {
                if (this.loginPage) {
                  return;
                }
                this.onTab(index);
              })
            }, (item: SidebarTab): string => `${item.tab}`)
          }
          .width(this.itemWidth())
          .height(5 * this.buttonSize + Math.round(24 * this.uiScale))
          .padding({
            top: Math.round(12 * this.uiScale),
            bottom: Math.round(12 * this.uiScale)
          })
          .alignItems(HorizontalAlign.Center)
        }
        .width(this.itemWidth())
        .height(5 * this.buttonSize + Math.round(24 * this.uiScale))
        .padding(0)
        .borderRadius(this.buttonSize / 2)
        .clip(true)
        .backgroundColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .attributeModifier(new SurfaceModifier(this.thickness, false, true))
      }
      .width('100%')
      .padding({ left: this.gutter })
      .layoutWeight(1)

      Blank()

      Column({ space: Math.round(8 * this.uiScale) }) {
        MaterialChipButton({
          symbol: $r('sys.symbol.heart'),
          labelRes: $r('app.string.notifications'),
          labelVisible: this.expanded,
          anchorStart: true,
          swallowLongPress: true,
          tapDebounceMs: 100,
          chipHeight: this.buttonSize,
          chipWidth: this.itemWidth(),
          iconSlotWidth: this.buttonSize,
          iconSize: Math.round(22 * this.uiScale),
          fontSize: Math.round(14 * this.uiScale),
          autoInvert: false,
          tint: this.whiteIcons ? '#FFFFFF' : '',
          onTap: (): void => {
            if (this.loginPage) {
              return;
            }
            this.onNotifications();
          }
        })
        .enabled(!this.loginPage)

        MaterialChipButton({
          symbol: $r('sys.symbol.more'),
          labelRes: $r('app.string.action_settings'),
          labelVisible: this.expanded,
          anchorStart: true,
          swallowLongPress: true,
          tapDebounceMs: 100,
          chipHeight: this.buttonSize,
          chipWidth: this.itemWidth(),
          iconSlotWidth: this.buttonSize,
          iconSize: Math.round(22 * this.uiScale),
          fontSize: Math.round(14 * this.uiScale),
          autoInvert: false,
          tint: this.whiteIcons ? '#FFFFFF' : '',
          onTap: (): void => {
            this.onSettings();
          }
        })
      }
      .width('100%')
      .padding({ left: this.gutter, bottom: Math.round(16 * this.uiScale) })
      .alignItems(HorizontalAlign.Start)
    }
    .width(this.panelWidth())
    .height('100%')
    .padding({ top: 4 })
    .backgroundColor(this.settingsOverlay ? $r('app.color.page_background') : Color.Transparent)
    .border({
      width: { right: this.settingsOverlay ? 0.5 : 0 },
      color: $r('app.color.divider')
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
