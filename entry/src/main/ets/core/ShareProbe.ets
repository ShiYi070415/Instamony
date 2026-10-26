/*
 * **分享数取证**：把每条取数响应里"第一条帖子的键名清单 + 分享类键的值"写进
 * `files/Instamony_share_probe.txt`。
 *
 * ## 为什么需要它（本次要回答的问题）
 * 需求："feeds 与 reels 实际没显示分享数量，查清是请求 / 解析 / 映射 / UI 哪一段断了。"
 *
 * 前三段里，"请求"这一段**没法靠读代码下结论**：本项目现在的信息流与视频流走的都是
 * **移动端私有 REST**（`feed/timeline/`、`clips/*`、`discover/topical_explore/`），
 * 这些端点**没有字段选择参数**（不像 GraphQL 那样"要什么字段回什么字段"，见
 * core/mobileapi/MobileFeedTimeline 与 MobileClips 的实测记录）——
 * 也就是说"把 share_count 加进请求"这件事在这条路上**根本不存在**，响应当中没有，
 * 就是 IG 不给。要确认这一点，只能把真实响应的键名打出来看。
 *
 * 而真机上 hilog 抓不住（chromium 每秒几千行把环形缓冲冲掉，见 core/StoryDiag 的说明），
 * 所以这里**落盘**：固定文件名、只写键名与计数，不写账号信息、不写全量正文。
 *
 * ## 写什么（刻意很小）
 * 每个来源（时间线 / clips / 探索流）只记一次，内容只有三行：
 *   · 第一条媒体节点的**键名清单**（判断"这个字段到底在不在"）；
 *   · 分享类候选键（`share_count` / `shares_count` / `media_share_count` /
 *     `edge_media_to_share`）在**整包**里出现过几次、第一次的值是多少；
 *   · 转发 / 收藏类键的同一份信息（对照用：`media_repost_count` 有值而 share 一族完全没有，
 *     就说明 IG 确实只给转发数）。
 * 文件末尾附一段**结论**：按"三路都没有分享类键" / "有键但值全 0" / "有 >0 的值"三种情况
 * 之一给出下一步该看哪里。
 *
 * ## 开关
 * `PROBE_ON` 是唯一的开关，改成 false 就连字符串扫描都不做（release 里就该是 false）。
 * 写盘发生在主线程、每来源一次、每次几 KB —— 不会像解析那样压帧。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsonRead } from './JsonRead';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ShareProbe';
/** 固定的落盘文件名（`dumpFixed` 的口径：沙箱 filesDir 下补 `.txt`）。 */
const FILE_NAME: string = 'Instamony_share_probe';
/** **调试开关**：false = 完全不做诊断（release 里应该是 false）。 */
const PROBE_ON: boolean = true;
/** 最多记几个来源（时间线 / clips 三条 / 探索流，6 个够）。 */
const MAX_SOURCES: number = 6;
/** 键名清单最多列多少个（媒体节点通常 30~60 个键，别把文件撑大）。 */
const MAX_KEYS: number = 80;
/** 找"第一条媒体节点"时往下走的最大层数（有界，防畸形响应把主线程拖住）。 */
const MAX_DEPTH: number = 6;

/**
 * 分享类候选键（与 core/NativeTimelineParser、core/NativeReels、core/NativeSearch 里那份
 * 候选表**同一组名字**）—— 哪一路改了候选名，这里也要跟着改，否则诊断会说"没有"。
 */
const SHARE_KEYS: Array<string> = ['share_count', 'shares_count', 'media_share_count',
  'edge_media_to_share'];
/** 对照用的转发 / 收藏计数（这些在真机载荷里是有的，见 core/RepostState 的实测记录）。 */
const OTHER_KEYS: Array<string> = ['media_repost_count', 'repost_count', 'reshare_count',
  'save_count', 'saves_count'];

/** 一个来源的取证结果。 */
class ProbeSource {
  readonly tag: string;
  /** 要写进文件的那几行。 */
  readonly block: string;
  /** 整包里出现过分享类键名没有（不管值是多少）。 */
  readonly shareFound: boolean;
  /** 分享类键里出现过 > 0 的值。 */
  readonly sharePositive: boolean;

  constructor(tag: string, block: string, shareFound: boolean, sharePositive: boolean) {
    this.tag = tag;
    this.block = block;
    this.shareFound = shareFound;
    this.sharePositive = sharePositive;
  }
}

export class ShareProbe {
  /** 落盘要 `filesDir`；由 EntryAbility.onCreate 给（没有就只在内存里攒着）。 */
  private static context: common.UIAbilityContext | null = null;
  /** 来源 → 结果（同一来源只取一次证）。 */
  private static readonly sources: Map<string, ProbeSource> = new Map<string, ProbeSource>();
  /** 落盘顺序（Map 的遍历顺序不保证，写文件按这个来）。 */
  private static order: Array<string> = [];

  /** 打开诊断（`EntryAbility.onCreate` 里调一次；幂等）。 */
  static init(context: common.UIAbilityContext): void {
    ShareProbe.context = context;
  }

  /**
   * 记一条响应（`body` 是**原始响应体**，同一 `tag` 只取第一次）。
   *
   * 为什么收原始 body 而不是解析好的模型：要回答的正是"解析之前载荷里有没有这个字段"，
   * 拿模型就绕回去了。
   */
  static noteBody(tag: string, body: string): void {
    if (!PROBE_ON || body.length === 0) {
      return;
    }
    if (ShareProbe.sources.has(tag) || ShareProbe.order.length >= MAX_SOURCES) {
      return;
    }
    const source: ProbeSource = ShareProbe.describe(tag, body);
    ShareProbe.sources.set(tag, source);
    ShareProbe.order.push(tag);
    hilog.info(DOMAIN, TAG, 'probe %{public}s shareFound=%{public}s positive=%{public}s',
      tag, `${source.shareFound}`, `${source.sharePositive}`);
    ShareProbe.flush();
  }

  /**
   * 记一条**已经取到节点的**媒体（探索 / 搜索那条路：调用方给的是原始 media 节点，没有整包）。
   *
   * 与 `noteBody` 的区别只是拿不到"整包里出现几次"——决定性的事实（节点上有没有这几个键、
   * 值是多少）一样记全。
   */
  static noteMedia(tag: string, media: Record<string, Object>): void {
    if (!PROBE_ON) {
      return;
    }
    if (ShareProbe.sources.has(tag) || ShareProbe.order.length >= MAX_SOURCES) {
      return;
    }
    const lines: Array<string> = [];
    lines.push(`== ${tag}（探索 / 搜索那条 REST，按媒体节点取证）==`);
    const keys: Array<string> = Object.keys(media);
    const shown: Array<string> = keys.length > MAX_KEYS ? keys.slice(0, MAX_KEYS) : keys;
    lines.push(`第一条媒体节点的键名：${shown.join(',')}`
      + `${keys.length > MAX_KEYS ? `…(共 ${keys.length} 个)` : ''}`);
    const shareHits: Array<string> = ShareProbe.keysHit(media, SHARE_KEYS);
    lines.push(`分享类键：${shareHits.length > 0 ? shareHits.join(' ') : '无（节点上没有这几个键名）'}`);
    const otherHits: Array<string> = ShareProbe.keysHit(media, OTHER_KEYS);
    lines.push(`对照（转发/收藏类键）：${otherHits.length > 0 ? otherHits.join(' ') : '无'}`);
    lines.push('');
    const source: ProbeSource = new ProbeSource(tag, lines.join('\n'),
      shareHits.length > 0, ShareProbe.positiveOf(media, SHARE_KEYS));
    ShareProbe.sources.set(tag, source);
    ShareProbe.order.push(tag);
    hilog.info(DOMAIN, TAG, 'probe %{public}s shareFound=%{public}s positive=%{public}s',
      tag, `${source.shareFound}`, `${source.sharePositive}`);
    ShareProbe.flush();
  }

  /** 节点上命中候选键名的那些（写成 `键=值`，值只看数字/布尔）。 */
  private static keysHit(media: Record<string, Object>, names: Array<string>): Array<string> {
    const out: Array<string> = [];
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      if (!JsonRead.has(media, name)) {
        continue;
      }
      const value: Object | undefined = media[name];
      const text: string = typeof value === 'number' || typeof value === 'string'
        ? `${value}` : (value === true || value === false ? `${value}` : '对象');
      out.push(`${name}=${text}`);
    }
    return out;
  }

  /** 节点上这几族键里有没有 > 0 的值。 */
  private static positiveOf(media: Record<string, Object>, names: Array<string>): boolean {
    for (let index: number = 0; index < names.length; index++) {
      if (JsonRead.numOf(media, names[index]) > 0) {
        return true;
      }
    }
    return false;
  }

  /** 把已经收到的几个来源整体写一遍（覆盖写，固定名）。 */
  private static flush(): void {
    const context: common.UIAbilityContext | null = ShareProbe.context;
    if (context === null) {
      return;
    }
    const text: string = ShareProbe.compose();
    try {
      const path: string = `${context.filesDir}/${FILE_NAME}.txt`;
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      hilog.info(DOMAIN, TAG, 'probe saved sources=%{public}d chars=%{public}d',
        ShareProbe.order.length, text.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'probe save failed: %{public}s', (error as Error).message);
    }
  }

  /** 一个来源的取证正文（键名清单 + 分享/转发/收藏那几族键的命中情况）。 */
  private static describe(tag: string, body: string): ProbeSource {
    const lines: Array<string> = [];
    lines.push(`== ${tag} ==`);
    // ① 整包字符串扫描：这一步不解析 JSON，几十万字符的 indexOf 也是微秒级。
    const shareHits: Array<string> = [];
    let sharePositive: boolean = false;
    for (let index: number = 0; index < SHARE_KEYS.length; index++) {
      const hit: string = ShareProbe.scan(body, SHARE_KEYS[index]);
      if (hit.length > 0) {
        shareHits.push(hit);
      }
      if (ShareProbe.positiveIn(body, SHARE_KEYS[index])) {
        sharePositive = true;
      }
    }
    const otherHits: Array<string> = [];
    for (let index: number = 0; index < OTHER_KEYS.length; index++) {
      const hit: string = ShareProbe.scan(body, OTHER_KEYS[index]);
      if (hit.length > 0) {
        otherHits.push(hit);
      }
    }
    // ② 第一条媒体节点的键名（解析一次，只在第一次取这个来源时做）。
    lines.push(`第一条媒体节点的键名：${ShareProbe.keysOfFirstMedia(body)}`);
    lines.push(`分享类键：${shareHits.length > 0 ? shareHits.join(' ') : '无（整包里一次都没出现）'}`);
    lines.push(`对照（转发/收藏类键）：${otherHits.length > 0 ? otherHits.join(' ')
      : '无'}`);
    lines.push('');
    return new ProbeSource(tag, lines.join('\n'), shareHits.length > 0, sharePositive);
  }

  /** `<key>` 在整包里出现几次、第一次的值（只截一小段，足够看清是 0 还是别的数）。 */
  private static scan(body: string, key: string): string {
    const token: string = `"${key}"`;
    const at: number = body.indexOf(token);
    if (at < 0) {
      return '';
    }
    let count: number = 1;
    let next: number = body.indexOf(token, at + token.length);
    while (next >= 0 && count < 99) {
      count++;
      next = body.indexOf(token, next + token.length);
    }
    const tail: string = body.substring(at, Math.min(body.length, at + token.length + 24));
    return `${token}×${count} 首值 ${tail}`;
  }

  /** 这个键名在整包里有没有**正数**的值（`"key":  12` 这种中间带空格的也认）。 */
  private static positiveIn(body: string, key: string): boolean {
    const token: string = `"${key}"`;
    let at: number = body.indexOf(token);
    while (at >= 0) {
      if (ShareProbe.digitAfter(body, at + token.length)) {
        return true;
      }
      at = body.indexOf(token, at + token.length);
    }
    return false;
  }

  /** 从 `from` 起跳过空白 / 冒号，看第一个有效字符是不是 1~9（0 与 null 都不算正数）。 */
  private static digitAfter(body: string, from: number): boolean {
    let at: number = from;
    while (at < body.length) {
      const ch: string = body.charAt(at);
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === ':') {
        at++;
        continue;
      }
      return ch >= '1' && ch <= '9';
    }
    return false;
  }

  /**
   * 第一条媒体节点的键名清单（拿不到就给一句说明）。
   *
   * 判据：**带 `code`（短码）+ `pk` 或 `id`** 的那个对象 —— 三种形状（时间线 `feed_items[].media_or_ad`、
   * clips `items[].media`、探索流 `sectional_items[].layout_content.medias[]`）都能这样认出来，
   * 不用为每种形状写一条路径。
   */
  private static keysOfFirstMedia(body: string): string {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      return '(响应不是 JSON，无法列键名)';
    }
    const media: Record<string, Object> | null = ShareProbe.findMedia(root, MAX_DEPTH);
    if (media === null) {
      return '(这一页里没有媒体节点：多半是"关注流已看完"那种占位页)';
    }
    const keys: Array<string> = Object.keys(media);
    const shown: Array<string> = keys.length > MAX_KEYS ? keys.slice(0, MAX_KEYS) : keys;
    return `${shown.join(',')}${keys.length > MAX_KEYS ? `…(共 ${keys.length} 个)` : ''}`;
  }

  /** 有界递归找第一个媒体节点（深度、每层键数、每个数组取的条数都有上限）。 */
  private static findMedia(node: Record<string, Object>, depth: number): Record<string, Object> | null {
    if (JsonRead.has(node, 'code') && (JsonRead.has(node, 'pk') || JsonRead.has(node, 'id'))) {
      return node;
    }
    if (depth <= 0) {
      return null;
    }
    const keys: Array<string> = Object.keys(node);
    const limit: number = keys.length > 48 ? 48 : keys.length;
    for (let index: number = 0; index < limit; index++) {
      const value: Object | undefined = node[keys[index]];
      if (value === undefined || value === null) {
        continue;
      }
      if (Array.isArray(value)) {
        const list: Array<Object> = value as Array<Object>;
        const take: number = list.length > 3 ? 3 : list.length;
        for (let at: number = 0; at < take; at++) {
          const one: Record<string, Object> | null = JsonRead.asRecord(list[at]);
          if (one === null) {
            continue;
          }
          const found: Record<string, Object> | null = ShareProbe.findMedia(one, depth - 1);
          if (found !== null) {
            return found;
          }
        }
        continue;
      }
      const one: Record<string, Object> | null = JsonRead.asRecord(value);
      if (one === null) {
        continue;
      }
      const found: Record<string, Object> | null = ShareProbe.findMedia(one, depth - 1);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }

  /** 整份文件的正文（怎么读 + 各来源 + 结论）。 */
  private static compose(): string {
    const lines: Array<string> = [];
    lines.push('Instamony 分享数取证（固定文件名，每次覆盖）');
    lines.push(`生成时间 ${ShareProbe.stamp()}  来源 ${ShareProbe.order.length} 个`);
    lines.push('');
    lines.push('== 怎么读 ==');
    lines.push('1) 看每个来源下面「分享类键」那一行：');
    lines.push('   「无」= 这个接口的响应里**根本没有**分享数字段（那我们永远显示不出来，不是 bug）；');
    lines.push('   有 `"share_count"×N 首值 "share_count":0` = 字段在，值是 0；');
    lines.push('   有非 0 的首值 = 数据源给了数字 —— 那种情况下界面还没显示，就是解析/映射的问题。');
    lines.push('2) 「第一条媒体节点的键名」是同一页里第一个媒体对象的**全部键名**，');
    lines.push('   可以拿它核对解析器有没有漏读（只列名字，不含任何内容与账号信息）。');
    lines.push('3) 「对照（转发/收藏类键）」：`media_repost_count` 一直有、share 一族一直没有，');
    lines.push('   就说明 IG 只给转发数，不给分享数。');
    lines.push('');
    const shareAny: boolean = ShareProbe.anyShare();
    const positiveAny: boolean = ShareProbe.anyPositive();
    for (let index: number = 0; index < ShareProbe.order.length; index++) {
      const one: ProbeSource | undefined = ShareProbe.sources.get(ShareProbe.order[index]);
      if (one !== undefined) {
        lines.push(one.block);
      }
    }
    lines.push('== 结论 ==');
    if (positiveAny) {
      lines.push('有来源给了 > 0 的分享数：解析/映射若仍把它丢了，改那一段（见 NativeTimelineParser /');
      lines.push('NativeReels.toReel / NativeSearch.readPost / pages/Index.searchPostsToMedia）。');
    } else if (shareAny) {
      lines.push('有来源出现过分享类键，但值全是 0 —— 界面按 0 不画那颗数字（这是设计）。');
    } else {
      lines.push('以上来源的载荷里**一次都没出现**分享类键（share_count / shares_count /');
      lines.push('media_share_count / edge_media_to_share）。这些端点是移动端 REST，**没有字段选择参数**，');
      lines.push('所以"把字段加进请求"这条路不存在 —— 结论是 IG 不返回分享数，界面那颗数字只能保持不画。');
      lines.push('（官方 Graph API 的分享指标只在自己的媒体洞察里给，见 Media Insights 的 shares，');
      lines.push('  公开的信息流载荷里没有这个数字。）');
    }
    return lines.join('\n');
  }

  private static anyShare(): boolean {
    const keys: Array<string> = ShareProbe.order;
    for (let index: number = 0; index < keys.length; index++) {
      const one: ProbeSource | undefined = ShareProbe.sources.get(keys[index]);
      if (one !== undefined && one.shareFound) {
        return true;
      }
    }
    return false;
  }

  private static anyPositive(): boolean {
    const keys: Array<string> = ShareProbe.order;
    for (let index: number = 0; index < keys.length; index++) {
      const one: ProbeSource | undefined = ShareProbe.sources.get(keys[index]);
      if (one !== undefined && one.sharePositive) {
        return true;
      }
    }
    return false;
  }

  /** `2026-10-24 21:03:11`（不用本地化格式，避免中文/时区差异）。 */
  private static stamp(): string {
    const now: Date = new Date();
    const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())} `
      + `${two(now.getHours())}:${two(now.getMinutes())}:${two(now.getSeconds())}`;
  }
}
