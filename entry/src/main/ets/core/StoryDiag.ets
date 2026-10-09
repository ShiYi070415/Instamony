/*
 * **诊断汇总**：把定位"快拍点开提示没取到"需要的东西合并成**一个固定文件名的 txt**。
 *
 * 为什么要有它（真机现场反复踩到的两个坑）：
 *   1. **hilog 留不住**：真机上 chromium 每秒几千行，我们自己的 INFO 行几秒就被冲没了，
 *      而这条失败只在别人的设备上发生 —— 远端复现时我们什么都拿不到；
 *   2. **分散的探针文件不好要**：`probe_<ts>.txt` / `trayraw_<ts>.txt` / `storyfail_<ts>.txt`
 *      都带时间戳，测试同学不知道该回传哪一个。
 *
 * 所以这里统一写 **`Instarmony_diag.txt`**（固定名，每次覆盖）：
 *   ① 每次快拍取数失败都往里**追加一段记录**（保留最近若干次，方便"复现两次再一起发"）；
 *   ② 托盘形状与原始条目一起带上（判断"这一条该不该有快拍"）。
 *
 * 落盘路径（DevEco 的 Device File Browser 或 hdc 都能取）：
 *   /data/app/el2/100/base/com.fanha.instarmony/haps/entry/files/Instarmony_diag.txt
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InstagramProbe } from '../probe/InstagramProbe';
import { NativeStories } from './NativeStories';
import { ApiThrottle } from './ApiThrottle';

const DOMAIN: number = 0xFF00;
const TAG: string = 'StoryDiag';
/** 固定的文件名（不带时间戳，测试同学永远知道该发哪一个）。 */
const FILE_NAME: string = 'Instarmony_diag';
/** 最多保留几次失败记录（复现两次再一起发也装得下，文件又不至于太大）。 */
const MAX_FAILURES: number = 8;
/** 汇总里最多带多少条托盘原始条目（形状摘要全带；原始 JSON 只带前面这些，控制文件大小）。 */
const MAX_RAW_ENTRIES: number = 40;
/**
 * 导出文件名里带的版本号。
 *
 * 只用于**文件名可读**（测试者手上可能同时有好几版）：真要核对版本时看 `AppScope/app.json5`
 * 的 `versionName`，改版本号时这里一起改（两处都在版本相关的提交里）。
 */
const APP_VERSION: string = '0.8.1';

export class StoryDiag {
  /** 最近的失败记录（新的在前）。 */
  private static failures: Array<string> = [];
  /** 最近一轮托盘的形状摘要（一行一条）。 */
  private static shapes: Array<string> = [];
  /** 最近一轮托盘的原始条目。 */
  private static raws: Array<string> = [];

  /**
   * 记一次快拍取数失败（`Index.showStoryFail` 调）。
   *
   * @param report `NativeStories.failureReport` 那份正文（uid/name/detail/轨迹/形状/原始条目）。
   */
  static recordFailure(report: string): void {
    const stamp: string = StoryDiag.stamp();
    StoryDiag.failures.unshift(`----- 失败记录 ${stamp} -----\n${report}`);
    while (StoryDiag.failures.length > MAX_FAILURES) {
      StoryDiag.failures.pop();
    }
  }

  /** 记一轮托盘的形状与原始条目（托盘解析完调一次）。 */
  static setTray(shapes: Array<string>, raws: Array<string>): void {
    StoryDiag.shapes = shapes;
    StoryDiag.raws = raws;
  }

  /** 把汇总写进沙箱（固定名，覆盖）。返回文件名（失败给空串）。 */
  static save(context: common.UIAbilityContext): string {
    // 覆盖之前先把上一次那份里的失败记录捞回来：见 loadOnce。
    StoryDiag.loadOnce(context);
    const text: string = StoryDiag.compose();
    const name: string = InstagramProbe.dumpFixed(context, FILE_NAME, text);
    if (name.length === 0) {
      hilog.warn(DOMAIN, TAG, 'diag save failed');
    }
    return name;
  }

  /**
   * **给"导出给别人"用的文件名**：带上版本与时间，避免多个测试者的文件混在一起。
   *
   * 例：`Instarmony_diag_v0.8.1_20261010_0130.txt`。
   */
  static exportFileName(): string {
    const now: Date = new Date();
    const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    const stamp: string = `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}`
      + `_${two(now.getHours())}${two(now.getMinutes())}`;
    return `Instarmony_diag_v${APP_VERSION}_${stamp}.txt`;
  }

  /** 导出用的正文（当前就是完整那份；单列一个方法，方便以后按需裁剪）。 */
  static exportFull(): string {
    return StoryDiag.compose();
  }

  /**
   * **精简版**：给"复制到剪贴板"那条路用。
   *
   * 只留"怎么读 + 当前状态 + 失败记录"，**不带**整条托盘（142 条形状 + 80 条原始条目会把剪贴板
   * 塞成几十 KB，粘到聊天窗口里对方也读不了）。摘要通常几 KB，粘进微信/邮件都合适。
   */
  static exportBrief(): string {
    const lines: Array<string> = [];
    lines.push('Instarmony 诊断摘要（快拍取数）');
    lines.push(`生成时间 ${StoryDiag.stamp()}`);
    lines.push(`快拍这一族限流：${ApiThrottle.blocked(ApiThrottle.STORIES)
      ? `是，还剩 ${ApiThrottle.remainingMinutes(ApiThrottle.STORIES)} 分钟`
      : '否'}`);
    lines.push(`失败记录 ${StoryDiag.failures.length} 条 / 托盘形状 ${StoryDiag.shapes.length} 条`);
    lines.push('');
    if (StoryDiag.failures.length === 0) {
      lines.push('(还没有失败记录)');
    }
    for (let index: number = 0; index < StoryDiag.failures.length; index++) {
      lines.push(StoryDiag.failures[index]);
      lines.push('');
    }
    return lines.join('\n');
  }

  /** 有没有从上一份文件里捞过记录（一轮进程一次）。 */
  private static loaded: boolean = false;

  /**
   * **首次落盘前，先把上一次那份里的「失败记录」捞回来**。
   *
   * 为什么必须做：这份文件是**覆盖写**的（固定名才好找），而进程重启后的第一次落盘发生在
   * "托盘拉到"那一刻 —— 那时内存里一条失败记录都没有。不捞回来的话，
   * 测试同学"复现 → 应用被系统回收/自己重启 → 再打开应用"这一下就把现场**冲掉了**。
   */
  private static loadOnce(context: common.UIAbilityContext): void {
    if (StoryDiag.loaded) {
      return;
    }
    StoryDiag.loaded = true;
    try {
      const path: string = `${context.filesDir}/${FILE_NAME}.txt`;
      if (!fileIo.accessSync(path)) {
        return;
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer);
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer.slice(0, read)));
      } finally {
        fileIo.closeSync(file);
      }
      StoryDiag.adoptFailures(text);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'diag read failed: %{public}s', (error as Error).message);
    }
  }

  /** 从上一份正文里把「失败记录」段捞回来（接在本次新的记录**后面**，保持新→旧）。 */
  private static adoptFailures(text: string): void {
    const marker: string = '----- 失败记录 ';
    const parts: Array<string> = text.split(marker);
    if (parts.length <= 1) {
      return;
    }
    for (let index: number = 1; index < parts.length; index++) {
      if (StoryDiag.failures.length >= MAX_FAILURES) {
        return;
      }
      let body: string = parts[index];
      // 一段记录的正文到下一个段标题（`\n== `）为止。
      const cut: number = body.indexOf('\n== ');
      if (cut > 0) {
        body = body.substring(0, cut);
      }
      const block: string = marker + body;
      if (StoryDiag.failures.indexOf(block) < 0) {
        StoryDiag.failures.push(block);
      }
    }
  }

  /**
   * 汇总正文。
   *
   * 结构刻意"先结论后依据"：最上面一段是**怎么读这份文件**与当前状态（快拍这一族是否被限流、
   * 失败次数），中间是失败记录（每条自带 shape/raw/逐发轨迹），最后是整条托盘的形状与原始条目。
   */
  private static compose(): string {
    const lines: Array<string> = [];
    lines.push('Instarmony 诊断汇总（快拍取数）');
    lines.push(`生成时间 ${StoryDiag.stamp()}  文件 ${FILE_NAME}.txt`);
    lines.push('');
    lines.push('== 怎么读 ==');
    lines.push('1) 先看下面第一条「失败记录」里的 shape= 那一行：');
    lines.push('   reel_type=user_reel 才是"某个用户的快拍"；别的类型 / expiring_at 已成过去 = 正常空。');
    lines.push('   node.id 与 user.pk 不一致时，说明这条条目里有两个 id（我们要的是 user.pk）。');
    lines.push('2) 再看 detail= 与「逐发轨迹」：detail=empty 表示服务端答了 200+JSON 但没有媒体；');
    lines.push('   http-4xx/non-json 是会话或身份问题；throttled-Nmin 是被 IG 限流。');
    lines.push('3) tray age= 是托盘数据有多旧（托盘允许复用 3 分钟内的那份）。');
    lines.push('');
    lines.push('== 当前状态 ==');
    lines.push(`快拍这一族限流：${ApiThrottle.blocked(ApiThrottle.STORIES)
      ? `是，还剩 ${ApiThrottle.remainingMinutes(ApiThrottle.STORIES)} 分钟`
      : '否'}`);
    lines.push(`失败记录条数：${StoryDiag.failures.length}（最多留 ${MAX_FAILURES} 条）`);
    lines.push(`托盘条目：形状 ${StoryDiag.shapes.length} 条，原始 ${StoryDiag.raws.length} 条`);
    lines.push('');
    lines.push('== 失败记录（新→旧）==');
    if (StoryDiag.failures.length === 0) {
      lines.push('(还没有失败记录：要么没复现，要么这一版还没触发过失败分支)');
    }
    for (let index: number = 0; index < StoryDiag.failures.length; index++) {
      lines.push(StoryDiag.failures[index]);
      lines.push('');
    }
    lines.push('== 托盘形状（全部）==');
    if (StoryDiag.shapes.length === 0) {
      lines.push('(空：托盘还没成功拉到过)');
    }
    for (let index: number = 0; index < StoryDiag.shapes.length; index++) {
      lines.push(StoryDiag.shapes[index]);
    }
    lines.push('');
    lines.push(`== 托盘原始条目（前 ${MAX_RAW_ENTRIES} 条，每条截断）==`);
    const rawCount: number = StoryDiag.raws.length < MAX_RAW_ENTRIES
      ? StoryDiag.raws.length : MAX_RAW_ENTRIES;
    for (let index: number = 0; index < rawCount; index++) {
      lines.push(StoryDiag.raws[index]);
    }
    return lines.join('\n');
  }

  /** `2026-10-10 01:23:45` 这种可读时间（不用 Date 的本地化格式，避免中文/时区差异）。 */
  private static stamp(): string {
    const now: Date = new Date();
    const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())} `
      + `${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())}`;
  }
}
