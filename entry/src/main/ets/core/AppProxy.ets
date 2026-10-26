/*
 * **应用级 HTTP 代理**（设置页「代理」用的核心逻辑）。
 *
 * 参考 HarmonyX 的做法：代理是"整个 App 的出网通道"，所以用系统提供的应用级接口
 * `connection.setAppHttpProxy()` —— 它对本 App 后续的 http / WebView 请求都生效，
 * 不需要改每一处请求，也不需要重启进程（请求时读当前配置）。
 *
 * 设计取舍：
 *   · **只用系统能力**，不做 VPN / 旁路（HarmonyOS 的 VPN 需要系统级权限，普通应用拿不到）；
 *   · 配置落盘在 AppSettings（跟着账号无关，全局一份）；
 *   · 打开/关闭/改地址都**立即生效**，不需要重启 App（用户明确要求"设置目标不用停"）；
 *   · 关闭时传 `null` 清除（官方接口接受 null 表示不使用代理）。
 */

import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AppProxy';
/** 代理配置的持久键（设置页与核心逻辑共用）。 */
export const PROXY_HOST: string = 'proxy_host';
export const PROXY_PORT: string = 'proxy_port';
export const PROXY_USER: string = 'proxy_user';
export const PROXY_PASS: string = 'proxy_pass';

/** 代理配置（空 host = 未启用）。 */
export class AppProxyConfig {
  host: string = '';
  port: number = 0;
  username: string = '';
  password: string = '';

  enabled(): boolean {
    return this.host.length > 0 && this.port > 0;
  }

  /** 一行摘要（设置页显示 / 日志用；**不打印密码**）。 */
  summary(): string {
    if (!this.enabled()) {
      return '未启用';
    }
    const auth: string = this.username.length > 0 ? '（含认证）' : '';
    return `${this.host}:${this.port}${auth}`;
  }
}

export class AppProxy {
  /** 当前配置（内存镜像，AppSettings 里是持久层）。 */
  private static current: AppProxyConfig = new AppProxyConfig();

  /** 从持久层读回并应用（冷启动时调一次）。 */
  static restoreAndApply(): void {
    const config: AppProxyConfig = AppProxy.load();
    AppProxy.current = config;
    AppProxy.apply(config);
  }

  static config(): AppProxyConfig {
    return AppProxy.current;
  }

  /**
   * 保存并**立即应用**（不需要重启 App）。
   *
   * @returns 是否真的应用成功（false = 参数不合法或系统接口报错）。
   */
  static save(config: AppProxyConfig): boolean {
    AppProxy.current = config;
    AppProxy.persist(config);
    return AppProxy.apply(config);
  }

  /** 关闭代理并清除持久化里的地址（保留历史输入由 UI 决定）。 */
  static disable(): boolean {
    const empty: AppProxyConfig = new AppProxyConfig();
    AppProxy.current = empty;
    AppProxy.persist(empty);
    return AppProxy.apply(empty);
  }

  private static apply(config: AppProxyConfig): boolean {
    try {
      if (!config.enabled()) {
        // 官方接口：传 null 表示不使用代理。
        connection.setAppHttpProxy(null);
        hilog.info(DOMAIN, TAG, 'proxy cleared');
        return true;
      }
      const proxy: connection.HttpProxy = {
        host: config.host,
        port: config.port,
        username: config.username,
        password: config.password,
        // 官方类型要求：走代理的主机排除列表（空 = 全部走代理）。
        exclusionList: []
      };
      connection.setAppHttpProxy(proxy);
      hilog.info(DOMAIN, TAG, 'proxy applied host=%{public}s port=%{public}d auth=%{public}s',
        config.host, config.port, config.username.length > 0 ? 'y' : 'n');
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'proxy apply failed: %{public}s',
        (error as Error).message ?? '-');
      return false;
    }
  }

  /** 落盘（当前用 AppStorage；接 preferences 时只改这一个方法）。 */
  private static persist(config: AppProxyConfig): void {
    AppStorage.setOrCreate(PROXY_HOST, config.host);
    AppStorage.setOrCreate(PROXY_PORT, config.port);
    AppStorage.setOrCreate(PROXY_USER, config.username);
    AppStorage.setOrCreate(PROXY_PASS, config.password);
  }

  private static load(): AppProxyConfig {
    const config: AppProxyConfig = new AppProxyConfig();
    const host: string | undefined = AppStorage.get<string>(PROXY_HOST);
    const port: number | undefined = AppStorage.get<number>(PROXY_PORT);
    const user: string | undefined = AppStorage.get<string>(PROXY_USER);
    const pass: string | undefined = AppStorage.get<string>(PROXY_PASS);
    config.host = host === undefined ? '' : host;
    config.port = port === undefined ? 0 : port;
    config.username = user === undefined ? '' : user;
    config.password = pass === undefined ? '' : pass;
    return config;
  }
}

