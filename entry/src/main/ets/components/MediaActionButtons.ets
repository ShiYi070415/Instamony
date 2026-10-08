/*
 * 媒体操作按钮：**下载**（原图/原视频存相册）与**静音**（仅视频）。
 *
 * 拆成两个小 component（而不是一个带着位置参数的组件）：因为它们的落点不一样 ——
 *   信息流：**两颗都在媒体区右下角**，一排，静音在下载的**左边**；
 *   reels：两颗都在 **HdsNavigation 标题栏**里（那里的沉浸光感是官方支持的区域）。
 * 位置交给调用方（Stack 的 alignContent / 标题栏菜单），组件自己只负责"长什么样、点了做什么"。
 *
 * 外观（圆形 + 沉浸光感 + 交互形变 + 光源效果 + 自动反色）统一走 MaterialSurface：
 * 内容区只有 Toggle/Slider/Select 的沉浸光感生效，且图标必须放在 Toggle **里面**才不会
 * 出现"拖拽时只有材质在动、图标不动"的分层（详见 MaterialSurface.ets 的文件头）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppSettings, SETTING_VIDEO_MUTED } from '../core/AppSettings';
import { MediaDownloader } from '../core/MediaDownloader';
import { MaterialIconButton } from './MaterialSurface';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MediaActions';

/** 下载：把原图/原视频存进相册（系统授权弹窗那条免权限路径）。 */
async function downloadMedia(context: common.UIAbilityContext, url: string, ext: string,
                            title: string, isVideo: boolean): Promise<void> {
  const ok: boolean = await MediaDownloader.save(context, url, ext, title, isVideo);
  const text: ResourceStr = ok ? $r('app.string.media_saved') : $r('app.string.media_save_failed');
  try {
    promptAction.showToast({ message: text, duration: 1600 });
  } catch (error) {
    hilog.warn(DOMAIN, TAG, 'toast failed');
  }
}

/** 下载按钮（原图/原视频 → 相册）。 */
@Component
export struct MediaDownloadButton {
  /**
   * 下载地址的**解析函数**（点按那一刻才调用）。
   *
   * 需求："下载按钮没有绑定当前显示图片" —— 多图轮播翻到第 N 张时，下载要下第 N 张的**原图**。
   * 地址若写成 @Prop（构建时求值），翻页不会重建卡片，按钮会一直拿着第一张的地址；
   * 改成回调后，每次点按都重新问一遍"现在显示的是哪张"（见 FeedList.downloadUrl）。
   */
  resolveUrl: () => string = (): string => '';
  @Prop ext: string = 'jpg';
  @Prop title: string = '';
  @Prop isVideo: boolean = false;

  build() {
    MaterialIconButton({
      symbol: $r('sys.symbol.arrow_down_to_line'),
      onTap: (): void => {
        const host: common.Context | undefined = this.getUIContext().getHostContext();
        const url: string = this.resolveUrl();
        if (host === undefined || url.length === 0) {
          return;
        }
        downloadMedia(host as common.UIAbilityContext, url, this.ext, this.title, this.isVideo);
      }
    })
  }
}

/** 静音按钮（全局静音，落盘）。 */
@Component
export struct MediaMuteButton {
  @StorageLink(SETTING_VIDEO_MUTED) muted: boolean = false;

  build() {
    MaterialIconButton({
      symbol: this.muted ? $r('sys.symbol.speaker_slash') : $r('sys.symbol.speaker_wave_2'),
      isOn: this.muted,
      // **按目标值设置，不做取反**：`on` 是这次点击想要的状态（见 MaterialIconButton.fire）。
      // 取反式写法（`!this.muted`）在"一次点击来了两个回调"时会把状态又翻回去 ——
      // 那正是用户报的"静音按钮按了没反应 / 偶尔切不动"。
      onTap: (on: boolean): void => {
        // 走 AppSettings 而不是只改 @StorageLink：静音要**落盘**（重开 app 也记得）。
        AppSettings.setVideoMuted(on);
      }
    })
  }
}
