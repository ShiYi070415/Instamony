/*
 * Instagram 探针。
 *
 * 对应 WeiboPura 的 `WeiboWebProbe` / `WeiboEndpointProbe`：不靠猜，先让网页
 * 自己在真机上跑一遍，把「它到底用了哪些接口」记下来。
 *
 * 采集方式是在页面里挂钩 `fetch` / `XMLHttpRequest`（以及 Resource Timing 兜底），
 * 只记方法 + URL + 触发方式，不记请求体、不记响应体，也不会主动发任何请求——
 * 因此对账号没有任何副作用。
 *
 * 报告写进应用沙箱 filesDir，可以用 hdc 直接取：
 *   /data/app/el2/100/base/<bundle>/haps/entry/files/probe_*.txt
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'InstagramProbe';
/** 单次会话最多记这么多条不同的接口，防止长时间浏览把内存撑起来。 */
const MAX_KEYS: number = 400;
/** 单条 URL 截断长度。 */
const MAX_URL: number = 160;

/** 一个被观测到的接口。 */
export class ProbeCall {
  readonly key: string;
  method: string = 'GET';
  /** 去掉查询串的路径，用于归类。 */
  path: string = '';
  /** 最后一次见到的完整 URL（已截断）。 */
  sample: string = '';
  kind: string = '';
  count: number = 0;
  lastAt: number = 0;
  /** 请求体样本（截断），用于照着复刻接口。 */
  body: string = '';
  /** 请求头样本（csrf / cookie 一律打码）。 */
  headers: string = '';
  /** 响应体样本（截断），用于确定字段结构。 */
  response: string = '';

  constructor(key: string) {
    this.key = key;
  }
}

export class InstagramProbe {
  private static instance: InstagramProbe | null = null;
  private readonly map: Map<string, ProbeCall> = new Map<string, ProbeCall>();
  private readonly order: Array<string> = [];
  /** 完整 URL → 归类 key，用于把响应挂回对应的接口。 */
  private readonly urlIndex: Map<string, string> = new Map<string, string>();
  /** GraphQL 操作名（x-fb-friendly-name）→ 归类 key。 */
  private readonly nameIndex: Map<string, string> = new Map<string, string>();
  private enabled: boolean = true;
  /** 最近一次网页结构探测的结果。 */
  private domReport: string = '';
  private domAt: number = 0;
  /** 首页 GraphQL 回放摘要。 */
  private apiDigest: string = '';

  static getInstance(): InstagramProbe {
    if (InstagramProbe.instance === null) {
      InstagramProbe.instance = new InstagramProbe();
    }
    return InstagramProbe.instance;
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  setEnabled(value: boolean): void {
    this.enabled = value;
  }

  clear(): void {
    this.map.clear();
    this.order.length = 0;
    this.urlIndex.clear();
    this.nameIndex.clear();
    this.domReport = '';
    this.domAt = 0;
    this.apiDigest = '';
  }

  callCount(): number {
    return this.order.length;
  }

  calls(): Array<ProbeCall> {
    const list: Array<ProbeCall> = [];
    for (let index: number = 0; index < this.order.length; index++) {
      const item: ProbeCall | undefined = this.map.get(this.order[index]);
      if (item !== undefined) {
        list.push(item);
      }
    }
    return list;
  }

  setDomReport(text: string): void {
    this.domReport = text;
    this.domAt = Date.now();
  }

  domReportText(): string {
    return this.domReport;
  }

  setApiDigest(text: string): void {
    this.apiDigest = text;
  }

  /** 页面侧上报的 JSON：请求样本，或 `m=RESP` 的响应样本。 */
  record(json: string): void {
    let parsed: Record<string, string>;
    try {
      parsed = JSON.parse(json) as Record<string, string>;
    } catch (error) {
      return;
    }
    const method: string = `${parsed.m ?? ''}`;
    const url: string = `${parsed.u ?? ''}`;
    const kind: string = `${parsed.k ?? ''}`;
    const body: string = `${parsed.b ?? ''}`;
    const headers: string = `${parsed.h ?? ''}`;
    const name: string = `${parsed.f ?? ''}`;
    if (method === 'RESP') {
      this.attachResponse(url, kind, body);
      return;
    }
    this.recordRequest(method, url, kind, body, headers, name);
  }

  /** 页面侧上报一条请求。页面里可能同时命中 fetch 与 Resource Timing，这里按 key 合并。 */
  private recordRequest(method: string, url: string, kind: string, body: string,
                        headers: string, name: string): void {
    if (!this.enabled) {
      return;
    }
    const safeUrl: string = url.trim();
    if (safeUrl.length === 0 || safeUrl.indexOf('data:') === 0) {
      return;
    }
    const upper: string = method.trim().length > 0 ? method.trim().toUpperCase() : 'GET';
    const media: boolean = InstagramProbe.isMediaUrl(safeUrl);
    const path: string = media ? `${InstagramProbe.hostOf(safeUrl)}/*` : InstagramProbe.pathOf(safeUrl);
    // GraphQL 走同一个路径、靠 x-fb-friendly-name 区分操作，key 里带上它才不会互相盖掉。
    const key: string = name.length > 0 ? `${upper} ${path} #${name}` : `${upper} ${path}`;
    const existing: ProbeCall | undefined = this.map.get(key);
    if (existing !== undefined) {
      existing.count++;
      existing.lastAt = Date.now();
      if (kind.length > 0 && existing.kind.indexOf(kind) < 0) {
        existing.kind = `${existing.kind}/${kind}`;
      }
      if (existing.body.length === 0 && body.length > 0) {
        existing.body = body;
      }
      if (existing.headers.length === 0 && headers.length > 0) {
        existing.headers = headers;
      }
      this.urlIndex.set(safeUrl, key);
      if (name.length > 0) {
        this.nameIndex.set(name, key);
      }
      return;
    }
    if (this.order.length >= MAX_KEYS) {
      return;
    }
    const entry: ProbeCall = new ProbeCall(key);
    entry.method = upper;
    entry.path = path;
    entry.sample = safeUrl.length > MAX_URL ? safeUrl.substring(0, MAX_URL) : safeUrl;
    entry.kind = kind;
    entry.count = 1;
    entry.lastAt = Date.now();
    // 图片 / 视频只留一条按 CDN 归并的记录：它们只是媒体地址，不需要样本。
    entry.body = media ? '' : body;
    entry.headers = media ? '' : headers;
    this.map.set(key, entry);
    this.order.push(key);
    this.urlIndex.set(safeUrl, key);
    if (name.length > 0) {
      this.nameIndex.set(name, key);
    }
  }

  /** 把响应样本挂到对应接口上（只保留第一份样本，避免报告膨胀）。 */
  private attachResponse(url: string, kind: string, text: string): void {
    const safeUrl: string = url.trim();
    if (safeUrl.length === 0 || text.length === 0) {
      return;
    }
    let key: string | undefined = undefined;
    if (kind.length > 0 && kind !== 'xhr' && kind !== 'fetch'
      && kind !== 'xmlhttprequest' && kind !== 'resource') {
      key = this.nameIndex.get(kind);
    }
    if (key === undefined) {
      key = this.urlIndex.get(safeUrl);
    }
    if (key === undefined) {
      return;
    }
    const entry: ProbeCall | undefined = this.map.get(key);
    if (entry === undefined || entry.response.length > 0) {
      return;
    }
    entry.response = text;
  }

  /** 文本报告：接口按「只读候选 / 写候选 / 其它」分组，方便直接照着接原生界面。 */
  report(bundleLine: string): string {
    const lines: Array<string> = [];
    lines.push(`Instamony 探针报告 ${InstagramProbe.stamp()}`);
    lines.push(bundleLine);
    lines.push(`采集开关=${this.enabled ? '开' : '关'} 不同接口=${this.order.length} 条`);
    lines.push('');
    lines.push('== 接口 ==');
    const list: Array<ProbeCall> = this.calls();
    for (let index: number = 0; index < list.length; index++) {
      const item: ProbeCall = list[index];
      lines.push(`x${item.count} [${item.kind}] ${item.key}`);
      if (item.sample !== item.path && item.sample.length > 0) {
        lines.push(`    例 ${item.sample}`);
      }
      if (item.headers.length > 0) {
        lines.push(`    头 ${item.headers}`);
      }
      if (item.body.length > 0) {
        lines.push(`    体 ${item.body}`);
      }
      if (item.response.length > 0) {
        lines.push(`    返 ${item.response}`);
      }
    }
    if (list.length === 0) {
      lines.push('（还没抓到请求：先打开网页随便刷一刷，再回来刷新报告）');
    }
    if (this.domReport.length > 0) {
      lines.push('');
      lines.push(`== 网页结构（${InstagramProbe.stamp(this.domAt)}） ==`);
      lines.push(this.domReport);
    }
    if (this.apiDigest.length > 0) {
      lines.push('');
      lines.push('== 首页接口回放 ==');
      lines.push(this.apiDigest);
    }
    return lines.join('\n');
  }

  /** 写进沙箱，返回文件名（失败返回空串）。 */
  dump(context: common.UIAbilityContext, prefix: string, text: string): string {
    const name: string = `${prefix}_${Date.now()}.txt`;
    try {
      const path: string = `${context.filesDir}/${name}`;
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      hilog.info(DOMAIN, TAG, 'probe report saved');
      return name;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'probe report save failed');
      return '';
    }
  }

  private static pathOf(url: string): string {
    let rest: string = url;
    const scheme: number = rest.indexOf('://');
    if (scheme >= 0) {
      const slash: number = rest.indexOf('/', scheme + 3);
      rest = slash >= 0 ? rest.substring(slash) : '/';
    }
    const cut: number = InstagramProbe.firstIndexOf(rest, '?');
    const hash: number = InstagramProbe.firstIndexOf(rest, '#');
    let end: number = rest.length;
    if (cut >= 0 && cut < end) {
      end = cut;
    }
    if (hash >= 0 && hash < end) {
      end = hash;
    }
    const path: string = rest.substring(0, end);
    return path.length > 0 ? path : '/';
  }

  private static firstIndexOf(text: string, token: string): number {
    return text.indexOf(token);
  }

  /** 媒体 / 静态资源：图片、视频、字体等，不需要抓样本，按 CDN 归并就够。 */
  private static isMediaUrl(url: string): boolean {
    const clean: string = url.toLowerCase();
    if (clean.indexOf('scontent') >= 0 || clean.indexOf('cdninstagram') >= 0) {
      return true;
    }
    if (clean.indexOf('/o1/v/') >= 0) {
      return true;
    }
    const dots: Array<string> = ['.mp4', '.m4s', '.jpg', '.jpeg', '.png', '.webp', '.gif',
      '.ico', '.woff', '.woff2', '.ttf', '.css', '.js'];
    for (let index: number = 0; index < dots.length; index++) {
      const at: number = clean.indexOf(dots[index]);
      if (at < 0) {
        continue;
      }
      const after: string = clean.substring(at + dots[index].length);
      if (after.length === 0 || after.charAt(0) === '?' || after.charAt(0) === '#'
        || after.charAt(0) === '/') {
        return true;
      }
    }
    return false;
  }

  private static hostOf(url: string): string {
    const scheme: number = url.indexOf('://');
    if (scheme < 0) {
      return url;
    }
    const start: number = scheme + 3;
    const slash: number = url.indexOf('/', start);
    return slash < 0 ? url.substring(start) : url.substring(start, slash);
  }

  private static stamp(at: number = 0): string {
    const ms: number = at > 0 ? at : Date.now();
    const date: Date = new Date(ms);
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
      + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  }
}
