/*
 * **Reels 崩溃现场日志**（breadcrumb）。
 *
 * 为什么需要：用户反馈"刷 reels 时会闪退"，而真机上拿不到 hilog（chromium 会把环形缓冲冲掉，
 * 测试者也没有 hdc）。唯一能带出来的东西是 App 自己写进沙箱的文件 —— 所以这里做一个
 * **极轻的、只追加的滚动日志**：翻页/切条时记一行，崩了之后下次进「设定 → 诊断 → 导出诊断」
 * 就能把它一起导出来（见 SettingsPanel.exportDiag）。
 *
 * 三条硬约束：
 *   1. **同步写**：崩溃前必须已经落盘（异步写会丢最后几行，而那几行最关键）；
 *   2. **有上限**：超过 MAX_BYTES 只留最近一半，别把沙箱撑大；
 *   3. **不能自己崩**：所有文件操作 try/catch，写失败只是没日志。
 *
 * 实现上的取舍：不用 O_APPEND（这个 API 面里没有），而是"读全文 + 追加 + 整体写回"。
 * 文件上限 64KB、每 4 行刷一次，开销在百微秒级，比正确性便宜。
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ReelsCrashLog';

/** 落地文件名（在 filesDir 下，和 Instamony_diag.txt 同一层）。 */
const FILE_NAME: string = 'Instamony_reels.log';
/** 日志上限（字节）：超过就只保留后半段。 */
const MAX_BYTES: number = 64 * 1024;
/** 内存里攒到这么多行就刷一次盘（崩溃最多丢这么多行）。 */
const FLUSH_LINES: number = 4;

export class ReelsCrashLog {
  /** filesDir（EntryAbility.onCreate 里给；拿不到就等于不记）。 */
  private static dir: string = '';
  private static buffer: Array<string> = [];
  private static ready: boolean = false;

  /** 初始化（幂等）。 */
  static init(filesDir: string): void {
    if (ReelsCrashLog.ready || filesDir.length === 0) {
      return;
    }
    ReelsCrashLog.dir = filesDir;
    ReelsCrashLog.ready = true;
    ReelsCrashLog.note('session start');
  }

  /** 记一行（自动带时间戳；写盘失败静默）。 */
  static note(text: string): void {
    if (!ReelsCrashLog.ready) {
      return;
    }
    const now: Date = new Date();
    const stamp: string = `${ReelsCrashLog.pad(now.getHours())}:${ReelsCrashLog.pad(now.getMinutes())}:`
      + `${ReelsCrashLog.pad(now.getSeconds())}.${ReelsCrashLog.pad(now.getMilliseconds())}`;
    ReelsCrashLog.buffer.push(`${stamp} ${text}`);
    if (ReelsCrashLog.buffer.length >= FLUSH_LINES) {
      ReelsCrashLog.flush();
    }
  }

  /** 立刻把这批行写下去。 */
  static flush(): void {
    if (!ReelsCrashLog.ready || ReelsCrashLog.buffer.length === 0) {
      return;
    }
    const pending: string = ReelsCrashLog.buffer.join('\n') + '\n';
    ReelsCrashLog.buffer = [];
    const path: string = `${ReelsCrashLog.dir}/${FILE_NAME}`;
    try {
      let text: string = ReelsCrashLog.readRaw(path) + pending;
      if (text.length > MAX_BYTES) {
        text = text.substring(text.length - Math.floor(MAX_BYTES / 2));
        // 从整行开始，避免第一条是半行。
        const cut: number = text.indexOf('\n');
        text = cut >= 0 ? text.substring(cut + 1) : text;
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'flush failed: %{public}s', (error as Error).message ?? '-');
    }
  }

  /** 读回整份（给「导出诊断」用；没有就是空串）。 */
  static read(): string {
    if (!ReelsCrashLog.ready) {
      return '';
    }
    // 先把还没写盘的行挤出去，别让它们漏在导出之外。
    ReelsCrashLog.flush();
    try {
      return ReelsCrashLog.readRaw(`${ReelsCrashLog.dir}/${FILE_NAME}`);
    } catch (error) {
      return '';
    }
  }

  /** 直接读文件（不触发 flush，避免递归）。 */
  private static readRaw(path: string): string {
    if (!fileIo.accessSync(path)) {
      return '';
    }
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (stat.size <= 0) {
      return '';
    }
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const read: number = fileIo.readSync(file.fd, buffer);
    fileIo.closeSync(file);
    if (read <= 0) {
      return '';
    }
    try {
      return new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer.slice(0, read)));
    } catch (error) {
      return '';
    }
  }

  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}
