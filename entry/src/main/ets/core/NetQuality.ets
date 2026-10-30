/*
 * **网络节点体检**：出口 IP 是"家宽/移动网络"还是"机房/代理"。
 *
 * ## 为什么需要它
 *
 * 2026-10-30 的两次真机反馈，把登录失败的原因钉在了**出口 IP** 上：
 *
 *   · 一位用户：CAA 回"密码错误"，网页接口回
 *     `error_type=AuthPlatformAntiScriptingException` + `/auth_platform/?apc=…`；
 *   · 另一位用户：网页接口回 `error_type=FakeIncorrectPassword`、`is_vetted=false`
 *     （名字里就写着 Fake —— IG 的反脚本挡箭牌）；
 *   · 而**换到另一个机场节点后立刻登进去了**。
 *
 * 也就是说：账号密码、协议、TLS、`enc_password` 全都是对的（我们逐字节核对过），
 * 卡住的是 IG 对**这条出口 IP** 的风险判定。用户能做的、也唯一有效的动作就是
 * **换节点**，但他没法判断"哪个节点是好的"——机场给的多半是机房 IP。
 *
 * 这个类就干一件事：把当前出口 IP 连同它的归属（ISP / 云厂商 / 托管商）取回来，
 * 让用户和我们都能一眼看出"这条线路是不是机房"，换节点时有个客观依据。
 *
 * ## 数据来源
 *
 * 用 `ipinfo.io/json`（免 key、够用；失败退 `ipapi.co/json/`）。只发一个 GET，
 * 不含任何账号信息 —— 查询方看到的就是用户自己的出口 IP，与 IG 看到的一致。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NetQuality';

/** 一眼就像机房/代理的机构名（命中任一即判定"机房 IP"）。 */
const HOSTING_HINTS: Array<string> = [
  'hosting', 'host', 'cloud', 'vps', 'server', 'data center', 'datacenter', 'colo',
  'amazon', 'aws', 'google', 'microsoft', 'azure', 'oracle', 'digitalocean', 'linode',
  'vultr', 'ovh', 'hetzner', 'contabo', 'leaseweb', 'choopa', 'm247', 'psychz',
  'alibaba', 'aliyun', 'tencent', 'huawei cloud', 'ucloud', 'ksyun', 'baidu',
  'vpn', 'proxy', 'tunnel', 'cdn', 'akamai', 'cloudflare', 'fastly'
];

/** 一次体检的结果。 */
export class NodeReport {
  /** 出口 IP（取不到给空串）。 */
  readonly ip: string;
  /** 国家/地区码（`US` / `HK` …）。 */
  readonly country: string;
  /** 城市。 */
  readonly city: string;
  /** 归属机构（ISP / 云厂商）。 */
  readonly org: string;
  /** 判定：看起来像机房/代理（IG 容易判成脚本）。 */
  readonly datacenter: boolean;
  /** 给人看的一行结论。 */
  readonly text: string;

  constructor(ip: string, country: string, city: string, org: string,
              datacenter: boolean, text: string) {
    this.ip = ip;
    this.country = country;
    this.city = city;
    this.org = org;
    this.datacenter = datacenter;
    this.text = text;
  }
}

export class NetQuality {
  /**
   * 查一次出口 IP 的归属。
   *
   * @returns 一行结论（同时给出结构化的 {@link NodeReport}）
   */
  static async check(): Promise<NodeReport> {
    const first: NodeReport | null = await NetQuality.fromIpinfo();
    if (first !== null) {
      return first;
    }
    const second: NodeReport | null = await NetQuality.fromIpapi();
    if (second !== null) {
      return second;
    }
    return new NodeReport('', '', '', '', false, '查不到出口 IP（网络不通，或者节点把 ipinfo/ipapi 也挡了）');
  }

  /** 机构名像不像机房（导出给别处用）。 */
  static looksDatacenter(org: string): boolean {
    const lower: string = org.toLowerCase();
    for (let index: number = 0; index < HOSTING_HINTS.length; index++) {
      if (lower.indexOf(HOSTING_HINTS[index]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static async fromIpinfo(): Promise<NodeReport | null> {
    const body: string = await NetQuality.get('https://ipinfo.io/json');
    if (body.length === 0) {
      return null;
    }
    const ip: string = NetQuality.field(body, 'ip');
    if (ip.length === 0) {
      return null;
    }
    const org: string = NetQuality.field(body, 'org');
    return NetQuality.report(ip, NetQuality.field(body, 'country'),
      NetQuality.field(body, 'city'), org);
  }

  private static async fromIpapi(): Promise<NodeReport | null> {
    const body: string = await NetQuality.get('https://ipapi.co/json/');
    if (body.length === 0) {
      return null;
    }
    const ip: string = NetQuality.field(body, 'ip');
    if (ip.length === 0) {
      return null;
    }
    const org: string = NetQuality.field(body, 'org');
    return NetQuality.report(ip, NetQuality.field(body, 'country_code'),
      NetQuality.field(body, 'city'), org);
  }

  private static report(ip: string, country: string, city: string, org: string): NodeReport {
    const datacenter: boolean = NetQuality.looksDatacenter(org);
    const where: string = `${country.length > 0 ? country : '?'}`
      + `${city.length > 0 ? '/' + city : ''}`;
    const text: string = datacenter
      ? `${ip}（${where}｜${org.length > 0 ? org : '归属未知'}）—— 看着是**机房/代理 IP**，`
        + `IG 很容易判成脚本。登录失败时换个节点再试（换到"家宽/原生"线路通常就过了）`
      : `${ip}（${where}｜${org.length > 0 ? org : '归属未知'}）—— 不像机房，这条线路可以先用着`;
    hilog.info(DOMAIN, TAG, 'node %{public}s dc=%{public}s', ip, datacenter ? 'y' : 'n');
    return new NodeReport(ip, country, city, org, datacenter, text);
  }

  private static async get(url: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'application/json', 'User-Agent': 'Instamony/1.5.0' },
        connectTimeout: 8000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode !== 200) {
        return '';
      }
      return `${response.result}`;
    } catch (error) {
      hilog.info(DOMAIN, TAG, 'node check failed: %{public}s', (error as Error).message);
      return '';
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 取一个字符串字段（响应很小，不需要完整 JSON 解析）。 */
  private static field(body: string, key: string): string {
    const re: RegExp = new RegExp(`"${key}"\\s*:\\s*"([^"]{0,120})"`);
    const match: RegExpMatchArray | null = body.match(re);
    return match !== null && match.length > 1 ? match[1] : '';
  }
}
