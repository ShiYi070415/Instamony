/*
 * **代理连通性探测**（保存代理前跑一次，见 SettingsPanel.submitProxy）。
 *
 * 需求："添加代理的时候需要确认代理通信是否正常，若无法连接则添加失败"。
 *
 * ## 为什么用 TCP + HTTP CONNECT，而不是"把代理设上去再发个请求"
 *   - 直接调 `connection.setAppHttpProxy()` 再发请求，会**临时改全局出网通道** ——
 *     正在跑的其它请求会一起被拖住，失败了还要收拾现场；
 *   - CONNECT 探测只开一条自己的短连接：连不上（端口错/防火墙/代理没开）在 connect 阶段就失败；
 *     连上了但账号密码不对，代理会回 **407**；能回 **200** 说明它连"代理 → 目标站"这一段也通了。
 *   一次探测同时验了「网络可达」「认证」「能否出网」三件事。
 *
 * 目标主机取 `www.instagram.com:443`：本 app 的流量本来就是往 IG 去的，
 * 代理连不上这个目标，设了也没用。
 */

import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'ProxyProbe';

/** 建连超时（毫秒）：真机上超过这个数多半是地址/端口错或代理没开。 */
const CONNECT_TIMEOUT_MS: number = 6000;
/** 等代理回 CONNECT 响应的超时（毫秒）。 */
const REPLY_TIMEOUT_MS: number = 6000;
/** 探测目标（本 app 的流量方向）。 */
const TARGET_HOST: string = 'www.instagram.com';
const TARGET_PORT: number = 443;

/** 探测结论。 */
export class ProxyCheckResult {
  /** true = 代理可用（连上了、认证过了、能出网）。 */
  reachable: boolean = false;
  /** 给用户看的短原因（失败时非空，直接进 toast）。 */
  reason: string = '';
  /** 排查用的细节（写日志）。 */
  detail: string = '';
}

export class ProxyProbe {
  /**
   * 探测一份代理配置。
   *
   * @param host 代理主机（域名或 IP）。
   * @param port 代理端口。
   * @param username HTTP 代理认证用户名（空 = 不认证）。
   * @param password 对应密码。
   */
  static async check(host: string, port: number, username: string, password: string): Promise<ProxyCheckResult> {
    const result: ProxyCheckResult = new ProxyCheckResult();
    if (host.length === 0) {
      result.reason = '主机为空';
      return result;
    }
    if (port <= 0 || port > 65535) {
      result.reason = '端口无效';
      return result;
    }

    let tcp: socket.TCPSocket | null = null;
    try {
      const ref: socket.TCPSocket = socket.constructTCPSocketInstance();
      tcp = ref;
      await ref.bind({ address: '0.0.0.0', port: 0 });
      await ref.connect({ address: { address: host, port: port }, timeout: CONNECT_TIMEOUT_MS });
      result.detail = 'connected';

      const request: string = ProxyProbe.connectRequest(username, password);
      await ref.send({ data: new util.TextEncoder().encodeInto(request).buffer as ArrayBuffer });

      const reply: string = await ProxyProbe.waitReply(ref, REPLY_TIMEOUT_MS);
      result.detail = `reply=${reply.slice(0, 80).replace(/\s+/g, ' ')}`;
      ProxyProbe.judge(reply, result);
    } catch (error) {
      const message: string = (error as Error).message ?? 'unknown';
      result.reachable = false;
      result.detail = `throw ${message}`;
      // 探针自己的超时是最常见的一种，给个明确说法（不然只有 "timeout" 看不出是代理没回）。
      result.reason = message.indexOf('timeout') >= 0 ? '代理没有响应（超时）' : `连不上（${message}）`;
    } finally {
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (error) {
          // 关不掉不影响结论。
        }
      }
    }
    hilog.info(DOMAIN, TAG, 'check host=%{public}s port=%{public}d ok=%{public}s reason=%{public}s detail=%{public}s',
      host, port, `${result.reachable}`, result.reason, result.detail);
    return result;
  }

  /** 组一条 CONNECT 请求（带可选的基本认证）。 */
  private static connectRequest(username: string, password: string): string {
    const lines: string[] = [];
    lines.push(`CONNECT ${TARGET_HOST}:${TARGET_PORT} HTTP/1.1`);
    lines.push(`Host: ${TARGET_HOST}:${TARGET_PORT}`);
    lines.push('Proxy-Connection: Keep-Alive');
    if (username.length > 0) {
      const token: string = ProxyProbe.basicAuth(username, password);
      if (token.length > 0) {
        lines.push(`Proxy-Authorization: Basic ${token}`);
      }
    }
    lines.push('');
    lines.push('');
    return lines.join('\r\n');
  }

  /** `user:pass` 的 base64（HTTP Basic）。 */
  private static basicAuth(username: string, password: string): string {
    try {
      const raw: Uint8Array = new util.TextEncoder().encodeInto(`${username}:${password}`);
      return new util.Base64Helper().encodeToStringSync(raw);
    } catch (error) {
      return '';
    }
  }

  /** 等代理的**第一段**回包（CONNECT 的响应头）。 */
  private static waitReply(ref: socket.TCPSocket, timeoutMs: number): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void, reject: (reason: Error) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error('timeout'));
      }, timeoutMs);
      ref.on('message', (info: socket.SocketMessageInfo): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(ProxyProbe.decode(info.message));
      });
      ref.on('error', (err: BusinessError): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        reject(new Error(`${err.code}`));
      });
    });
  }

  /** ArrayBuffer → 文本（解不出来就当空串，让 judge 走"响应异常"那一支）。 */
  private static decode(buffer: ArrayBuffer): string {
    try {
      return new util.TextDecoder().decodeToString(new Uint8Array(buffer));
    } catch (error) {
      return '';
    }
  }

  /**
   * 判读 CONNECT 的响应：**200 才算可用**。
   *
   * 其余状态码给具体说法，用户改起来才有方向：
   *   · 407：认证被拒（用户名/密码错，或代理要求认证但没填）；
   *   · 403：代理不允许连这个目标；
   *   · 5xx：代理自己出问题；
   *   · 不是 HTTP 开头：这个端口多半不是 HTTP 代理（SOCKS 之类）。
   */
  private static judge(reply: string, result: ProxyCheckResult): void {
    const text: string = reply.trim();
    if (text.length === 0) {
      result.reachable = false;
      result.reason = '代理没有返回数据';
      return;
    }
    const firstLine: string = text.split('\r\n')[0];
    const parts: string[] = firstLine.split(' ');
    if (parts.length < 2 || parts[0].indexOf('HTTP/') !== 0) {
      result.reachable = false;
      result.reason = '这个端口不是 HTTP 代理（响应不是 HTTP）';
      return;
    }
    const code: number = Number.parseInt(parts[1], 10);
    if (Number.isNaN(code)) {
      result.reachable = false;
      result.reason = '代理响应无法解析';
      return;
    }
    if (code === 200) {
      result.reachable = true;
      result.reason = '';
      return;
    }
    result.reachable = false;
    if (code === 407) {
      result.reason = '代理要求认证（用户名或密码不对）';
    } else if (code === 403) {
      result.reason = '代理拒绝访问该目标（403）';
    } else if (code >= 500) {
      result.reason = `代理内部错误（${code}）`;
    } else {
      result.reason = `代理返回 ${code}`;
    }
  }
}
