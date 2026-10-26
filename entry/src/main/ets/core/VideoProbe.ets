/*
 * **播放器探针**（排查版，用完删）。
 *
 * 现象：Reels 里单击或长按暂停后继续播放，进度会从头开始。
 * 靠读代码已经排除过三处（playing 折进、applyUrl 无条件调用、节点被摘掉），
 * 所以直接把"播放器生命周期 + 暂停/恢复时刻的位置"写进文件，一次真机操作就能定案：
 *   · 出现 createPlayer → 播放器被重建了（那就是节点被摘掉/属性导致重建）；
 *   · 只有 pause/play 且 position 前后接得上 → 播放器没变，问题在别处（例如 UI 层把 position 清零）。
 */

import { fileIo } from '@kit.CoreFileKit';

export class VideoProbe {
  static ON: boolean = false;
  private static lines: number = 0;

  static log(what: string): void {
    if (!VideoProbe.ON || VideoProbe.lines > 300) {
      return;
    }
    try {
      const ctx: Context = getContext();
      const path: string = `${ctx.filesDir}/Instarmony_video.txt`;
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${Date.now()} ${what}\n`);
      fileIo.closeSync(file);
      VideoProbe.lines++;
    } catch (error) {
    }
  }
}
