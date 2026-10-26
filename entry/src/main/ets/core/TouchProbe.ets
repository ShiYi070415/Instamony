/*
 * **触摸探针**（排查用，随时可删）。
 *
 * 为什么要它：Reels 页的单击 / 长按 / 横滑连改三版都"毫无反应"，靠读代码已经推不出来
 * 事件到底进没进到卡片这一支；而真机上 ArkTS 的 hilog 常常抓不到（见 EntryAbility.dumpIdentity）。
 * 所以把"哪个节点收到了哪种触摸"追加写进 files/Instarmony_touch.txt，一次真机点击就能定案。
 *
 * 只有几行、只在 onTouch 里调用，命中不到不影响任何功能。
 */

import { fileIo } from '@kit.CoreFileKit';

export class TouchProbe {
  /** 调试开关：排查完改成 false 即可全部停写。 */
  static ON: boolean = false;
  /** 文件行数上限（避免一直点把文件写爆）。 */
  private static lines: number = 0;

  static log(node: string, type: number): void {
    if (!TouchProbe.ON || TouchProbe.lines > 400) {
      return;
    }
    try {
      const ctx: Context = getContext();
      const path: string = `${ctx.filesDir}/Instarmony_touch.txt`;
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, `${Date.now()} ${node} t=${type}\n`);
      fileIo.closeSync(file);
      TouchProbe.lines++;
    } catch (error) {
    }
  }
}
