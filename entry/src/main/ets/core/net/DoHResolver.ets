/*
 * **DNS over HTTPS（DoH）解析器**（RFC 8484）—— 只活在这个 app 里，不改系统设置。
 *
 * ## 为什么要它
 * 我们那条登录链（`core/net/Tls13Client`）是**自己拼 ClientHello 的裸 TLS**，所以对 IG 的
 * 连接完全走自己的通道；但**域名解析仍然交给系统 net stack**。系统 DNS 在一些网络里会被
 * 篡改/污染或劫持（返回错误的 A 记录、插广告页），登录就可能连到一个错的 IP 上，
 * 表现成"握手失败 / 429 / 挑战"这类难以定位的怪现象。DoH 把"查询"这一步加密，能排掉这一层。
 *
 * ## 作用域（用户问的"只存在于 app 里吗"—— 是）
 *   · 用 `@ohos.net.http` 直接 POST 到 DoH 端点，**不写系统设置、不影响其它 app**；
 *   · 解析出来的 IP 只交给 `Tls13Client` 去 connect；**SNI 与证书校验仍然按域名**做
 *     （见 Tls13Client.request：连 IP、`handshake(host)`）—— 这是"连 IP 也不影响 TLS 身份"的关键；
 *   · 开关在设置页（`AppSettings.SETTING_DOH`），默认**关**：DoH 端点在某些网络里不可达，
 *     没被测过就默认打开，等于给登录链多埋一个失败点。
 *
 * ## 降级
 * 任何一步失败（端点不通 / 证书不对 / 报文解不开 / 超时）都**返回空串**，调用方退回
 * 系统解析 —— 换句话说：DoH 是**增强**，不是依赖。
 *
 * ## 报文
 * 走标准 wire format（`application/dns-message`），只查 **A 记录**（Tls13Client 用 IPv4；
 * AAAA 以后再补）。手写编解码的原因：项目里没有 DNS 库，而且报文很短（< 100 字节）。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettings, SETTING_DOH } from '../AppSettings';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DoH';
/** 一次查询的整体预算（毫秒）：超了就降级，别拖住登录链。 */
const QUERY_TIMEOUT_MS: number = 3000;
/** 缓存条目上限（超出就整表清空，够用且简单）。 */
const CACHE_MAX: number = 200;
/** 查不到时的负缓存（毫秒）：免得每一发都去问一遍。 */
const NEGATIVE_TTL_MS: number = 30000;

/**
 * 端点：**优先用 IP 字面量**，避免"解析 DoH 服务器自己的域名"这个鸡生蛋问题。
 *
 * 这些公共 DoH 的证书都带 IP SAN（`1.1.1.1` / `8.8.8.8` / `223.5.5.5` / `9.9.9.9`），
 * 所以 `https://<IP>/dns-query` 能正常过证书校验。最后两条是**域名**端点：
 * 它们要依赖系统解析，只作为"IP 端点都被墙/都不通"时的兜底。
 */
const ENDPOINTS: Array<string> = [
  // 国内优先：223.5.5.5 有 IP SAN，且在国内网络最稳。
  'https://223.5.5.5/dns-query',
  'https://1.1.1.1/dns-query',
  'https://8.8.8.8/dns-query',
  'https://9.9.9.9/dns-query',
  'https://dns.alidns.com/dns-query',
  'https://cloudflare-dns.com/dns-query'
];

/** 一条缓存。 */
class DnsEntry {
  readonly ip: string;
  readonly expiresAt: number;

  constructor(ip: string, expiresAt: number) {
    this.ip = ip;
    this.expiresAt = expiresAt;
  }
}

export class DoHResolver {
  private static cache: Map<string, DnsEntry> = new Map<string, DnsEntry>();
  /** 最近一次查询的现场（设置页那一行 + 日志用）。 */
  private static lastLine: string = '-';
  /**
   * 当前选中的端点：先按默认顺序试，`addressFor` 成功一次就换成真正能用的那个。
   *
   * 全局 HTTP / WebView 都拿它当 `dnsOverHttps`，所以它必须是**实测能通**的那一条；
   * 默认指向国内最稳的 223.5.5.5（IP 字面量，不依赖系统 DNS）。
   */
  private static activeEndpoint: string = ENDPOINTS[0];
  /**
   * 端点是否已经**实测可用**。
   *
   * 没探通之前 `httpDns()` 返回空串（这一发走系统 DNS）—— 不能拿一个没验证过的端点
   * 去配置全 app 的 HTTP：端点被墙时会把所有请求一起拖死。探通一次之后才全量启用。
   */
  private static ready: boolean = false;
  /** 预热是否在跑（避免启动时重复探）。 */
  private static warming: boolean = false;

  /** 开关（设置页那个 Toggle；默认开 —— 全 app 的 HTTP / WebView / 自建 TLS 都走它）。 */
  static enabled(): boolean {
    const value: boolean | undefined = AppStorage.get<boolean>(SETTING_DOH);
    return value !== false;
  }

  /**
   * 给 `HttpRequestOptions.dnsOverHttps` 的值（空串 = 这次不用 DoH）。
   *
   * 只返回 `https://…/dns-query`：HTTP 栈会用它解析**这一发请求**的域名，
   * 不写系统设置、不影响别的 app。
   */
  static httpDns(): string {
    return DoHResolver.enabled() && DoHResolver.ready ? DoHResolver.activeEndpoint : '';
  }

  /** 给 `WebviewController.setHttpDns` 的配置（空串 = 不配置）。 */
  static webviewDns(): string {
    return DoHResolver.httpDns();
  }

  /**
   * 把 `dnsOverHttps` 塞进一次 HTTP 请求的 options（开关关着时原样返回）。
   *
   * 所有 `http.createHttp().request(...)` 都过这一层，才能叫"全 app 的 HTTP 都走 DoH"。
   */
  static apply(options: http.HttpRequestOptions): http.HttpRequestOptions {
    const endpoint: string = DoHResolver.httpDns();
    if (endpoint.length > 0) {
      options.dnsOverHttps = endpoint;
    }
    return options;
  }

  /**
   * 启动时**探一次端点**（fire-and-forget）：挑一条真能解析的，之后全 app 都用它。
   *
   * 为什么不在每发请求前探：那会把 DoH 变成所有请求的串行前置，得不偿失。
   * 这里只在启动 / 切网 / 用户点"测一下"时更新 `activeEndpoint`。
   */
  static warmUp(): void {
    if (!DoHResolver.enabled() || DoHResolver.warming) {
      return;
    }
    DoHResolver.warming = true;
    DoHResolver.probeEndpoint().then((): void => {
      DoHResolver.warming = false;
    }).catch((): void => {
      DoHResolver.warming = false;
    });
  }

  /** 探一条能用的端点（成功则更新 activeEndpoint）。 */
  private static async probeEndpoint(): Promise<void> {
    for (let index: number = 0; index < ENDPOINTS.length; index++) {
      const endpoint: string = ENDPOINTS[index];
      try {
        const outcome: DnsOutcome = await DoHResolver.queryA(endpoint, 'i.instagram.com');
        if (outcome.ip.length > 0) {
          DoHResolver.activeEndpoint = endpoint;
          DoHResolver.ready = true;
          hilog.info(DOMAIN, TAG, 'active endpoint=%{public}s', DoHResolver.hostOf(endpoint));
          return;
        }
      } catch (error) {
        hilog.info(DOMAIN, TAG, 'endpoint unavailable %{public}s (%{public}s)',
          DoHResolver.hostOf(endpoint), (error as Error).message ?? '-');
      }
    }
    hilog.warn(DOMAIN, TAG, 'no doh endpoint reachable, keep %{public}s',
      DoHResolver.hostOf(DoHResolver.activeEndpoint));
  }

  /** 最近一次查询的现场（`host=… ip=… via=… ms=…` / `fallback: …`）。 */
  static last(): string {
    return DoHResolver.lastLine;
  }

  /** 已经缓存了多少条（诊断用）。 */
  static cacheSize(): number {
    return DoHResolver.cache.size;
  }

  /** 清空缓存（换账号 / 设置项切换时调；纯内存，不落盘）。 */
  static clear(): void {
    DoHResolver.cache.clear();
    DoHResolver.lastLine = '-';
    // 换端点/换网之后要重新探通才全量启用（见 ready 的说明）。
    DoHResolver.ready = false;
    hilog.info(DOMAIN, TAG, 'doh cache cleared');
  }

  /**
   * **给一个域名要一个 IPv4**（拿不到就给空串 = 调用方退回系统解析）。
   *
   * 只会被 `Tls13Client` 用：它的 connect 需要一个地址，而 SNI 仍然是域名。
   */
  static async addressFor(host: string, force: boolean = false): Promise<string> {
    if ((!DoHResolver.enabled() && !force) || host.length === 0) {
      return '';
    }
    if (DoHResolver.isIpLiteral(host)) {
      // 已经是 IP（我们的端点就是这么用的）：不用查。
      return host;
    }
    const hit: DnsEntry | undefined = DoHResolver.cache.get(host);
    if (hit !== undefined) {
      if (hit.expiresAt > Date.now()) {
        return hit.ip;
      }
      DoHResolver.cache.delete(host);
    }
    const started: number = Date.now();
    for (let index: number = 0; index < ENDPOINTS.length; index++) {
      const endpoint: string = ENDPOINTS[index];
      try {
        const outcome: DnsOutcome = await DoHResolver.queryA(endpoint, host);
        if (outcome.ip.length === 0) {
          hilog.info(DOMAIN, TAG, 'doh empty host=%{public}s via=%{public}s', host,
            DoHResolver.hostOf(endpoint));
          continue;
        }
        DoHResolver.remember(host, new DnsEntry(outcome.ip, Date.now() + outcome.ttlMs));
        DoHResolver.activeEndpoint = endpoint;
        DoHResolver.ready = true;
        DoHResolver.lastLine = `host=${host} ip=${outcome.ip} via=${DoHResolver.hostOf(endpoint)}`
          + ` ttl=${Math.round(outcome.ttlMs / 1000)}s ms=${Date.now() - started}`;
        hilog.info(DOMAIN, TAG, 'doh ok %{public}s', DoHResolver.lastLine);
        return outcome.ip;
      } catch (error) {
        const message: string = (error as Error).message ?? '-';
        hilog.warn(DOMAIN, TAG, 'doh miss host=%{public}s via=%{public}s (%{public}s)',
          host, DoHResolver.hostOf(endpoint), message);
      }
    }
    // 全都失败：负缓存一小会儿，然后把决定权交回系统解析。
    DoHResolver.remember(host, new DnsEntry('', Date.now() + NEGATIVE_TTL_MS));
    DoHResolver.lastLine = `host=${host} 全部端点失败 → 退回系统解析 ms=${Date.now() - started}`;
    hilog.info(DOMAIN, TAG, 'doh all endpoints failed host=%{public}s → system dns', host);
    return '';
  }

  /**
   * 设置页那一行的"测一下"：对某个域名做一次真实查询，返回给人看的一行。
   *
   * 为什么要单独一个入口：开关打开之后如果端点不可达，用户看到的现象是"没变化"——
   * 有一行现场就能分清"DoH 生效了"和"DoH 在降级"。
   */
  static async probe(host: string = 'i.instagram.com'): Promise<string> {
    const started: number = Date.now();
    DoHResolver.cache.delete(host);
    // `force = true`：开关没开也允许测一次（否则用户点了"测一下"只会看到"没解析出来"）。
    const ip: string = await DoHResolver.addressFor(host, true);
    if (ip.length > 0) {
      return `${host} → ${ip}（${DoHResolver.lastLine}）`;
    }
    return `${host} 没解析出 IPv4，已降级回系统解析（共试 ${ENDPOINTS.length} 个端点，`
      + `${Date.now() - started}ms）`;
  }

  // ------------------------------------------------------------------ 内部

  /** 查一次 A 记录（失败抛异常，由调用方换端点）。 */
  private static async queryA(endpoint: string, host: string): Promise<DnsOutcome> {
    const query: Uint8Array = DoHResolver.buildQuery(host, 1);
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(endpoint, {
        method: http.RequestMethod.POST,
        header: {
          'content-type': 'application/dns-message',
          'accept': 'application/dns-message'
        },
        extraData: query.buffer as ArrayBuffer,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: QUERY_TIMEOUT_MS,
        readTimeout: QUERY_TIMEOUT_MS,
        usingCache: false
      });
      if (response.responseCode !== 200) {
        throw new Error(`http ${response.responseCode}`);
      }
      const body: ArrayBuffer = response.result as ArrayBuffer;
      if (body === undefined || body === null || body.byteLength < 12) {
        throw new Error('empty body');
      }
      return DoHResolver.parseAnswer(new Uint8Array(body));
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 拼一条 A 查询的 wire format（header + QNAME + QTYPE + QCLASS）。 */
  private static buildQuery(host: string, qtype: number): Uint8Array {
    const labels: Array<string> = host.split('.');
    let length: number = 12 + 1 + 4;
    for (let index: number = 0; index < labels.length; index++) {
      length += 1 + labels[index].length;
    }
    const out: Uint8Array = new Uint8Array(length);
    const view: DataView = new DataView(out.buffer);
    // ID：随便给一个（我们用不上，但有的服务器要求非 0）。
    const id: number = Math.floor(Math.random() * 65535) + 1;
    view.setUint16(0, id);
    view.setUint16(2, 0x0100); // RD=1（要递归解析）
    view.setUint16(4, 1);      // QDCOUNT
    view.setUint16(6, 0);      // ANCOUNT
    view.setUint16(8, 0);      // NSCOUNT
    view.setUint16(10, 0);     // ARCOUNT
    let offset: number = 12;
    for (let index: number = 0; index < labels.length; index++) {
      const label: string = labels[index];
      out[offset] = label.length;
      offset++;
      for (let at: number = 0; at < label.length; at++) {
        out[offset] = label.charCodeAt(at) & 0xFF;
        offset++;
      }
    }
    out[offset] = 0; // 根
    offset++;
    view.setUint16(offset, qtype); // QTYPE
    offset += 2;
    view.setUint16(offset, 1);     // QCLASS = IN
    return out;
  }

  /** 解析响应，取第一条 A 记录（没有就给空 ip，不抛）。 */
  private static parseAnswer(bytes: Uint8Array): DnsOutcome {
    const view: DataView = new DataView(bytes.buffer);
    const qdcount: number = view.getUint16(4);
    const ancount: number = view.getUint16(6);
    let offset: number = 12;
    // 跳过问题区
    for (let index: number = 0; index < qdcount; index++) {
      offset = DoHResolver.skipName(bytes, offset);
      offset += 4; // QTYPE + QCLASS
    }
    let ip: string = '';
    let ttlMs: number = 60000;
    for (let index: number = 0; index < ancount; index++) {
      offset = DoHResolver.skipName(bytes, offset);
      if (offset + 10 > bytes.length) {
        break;
      }
      const type: number = view.getUint16(offset);
      const ttl: number = view.getUint32(offset + 4);
      const length: number = view.getUint16(offset + 8);
      offset += 10;
      if (offset + length > bytes.length) {
        break;
      }
      if (type === 1 && length === 4 && ip.length === 0) {
        ip = `${bytes[offset]}.${bytes[offset + 1]}.${bytes[offset + 2]}.${bytes[offset + 3]}`;
        ttlMs = Math.max(10, ttl) * 1000;
      }
      offset += length;
    }
    return new DnsOutcome(ip, ttlMs);
  }

  /** 跳过一个（可能被压缩的）域名：标签式，或 `0xC0` 两字节指针。 */
  private static skipName(bytes: Uint8Array, start: number): number {
    let offset: number = start;
    while (offset < bytes.length) {
      const length: number = bytes[offset];
      if (length === 0) {
        return offset + 1;
      }
      if ((length & 0xC0) === 0xC0) {
        return offset + 2;
      }
      offset += 1 + length;
    }
    return offset;
  }

  /** 写缓存（顺手控一下条目数）。 */
  private static remember(host: string, entry: DnsEntry): void {
    if (DoHResolver.cache.size >= CACHE_MAX) {
      DoHResolver.cache.clear();
    }
    DoHResolver.cache.set(host, entry);
  }

  /** 端点 → 主机名（日志用）。 */
  private static hostOf(endpoint: string): string {
    const stripped: string = endpoint.replace('https://', '');
    const slash: number = stripped.indexOf('/');
    return slash > 0 ? stripped.substring(0, slash) : stripped;
  }

  /** 是不是 IP 字面量（IPv4 / 粗判 IPv6）。 */
  static isIpLiteral(host: string): boolean {
    if (host.indexOf(':') >= 0) {
      return true;
    }
    const parts: Array<string> = host.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let index: number = 0; index < parts.length; index++) {
      const one: string = parts[index];
      if (one.length === 0 || one.length > 3) {
        return false;
      }
      const value: number = Number(one);
      if (!Number.isFinite(value) || value < 0 || value > 255) {
        return false;
      }
    }
    return true;
  }

  /** 设置项切换后用一行话说明当前状态（设置页显示）。 */
  static describe(): string {
    if (!DoHResolver.enabled()) {
      return '未启用（HTTP / 网页 / 自建 TLS 都走系统 DNS）';
    }
    if (!DoHResolver.ready) {
      return '已启用（全 app）· 正在探测可用端点，探测通过前先走系统 DNS';
    }
    const cached: number = DoHResolver.cacheSize();
    return `已启用（全 app）· 当前端点 ${DoHResolver.hostOf(DoHResolver.activeEndpoint)}`
      + ` · 缓存 ${cached} 条 · 最近：${DoHResolver.lastLine}`;
  }
}

/** 一次查询的结果（ip 空串 = 没拿到）。 */
class DnsOutcome {
  readonly ip: string;
  readonly ttlMs: number;

  constructor(ip: string, ttlMs: number) {
    this.ip = ip;
    this.ttlMs = ttlMs;
  }
}
