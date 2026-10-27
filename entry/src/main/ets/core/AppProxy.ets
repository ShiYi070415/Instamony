/*
 * **应用级 HTTP 代理**（设置页「代理」用的核心逻辑）。
 *
 * 参考 HarmonyX 的做法：代理是"整个 App 的出网通道"，所以用系统提供的应用级接口
 * `connection.setAppHttpProxy()` —— 它对本 App 后续的 http / WebView 请求都生效，
 * 不需要改每一处请求，也不需要重启进程。
 *
 * ## 两种形状并存（过渡期，编译必须一直是绿的）
 *   · `AppProxyConfig` + `save/disable/config`：**旧 UI（单份代理）**在用，先保留；
 *   · `ProxyEntry` + `list/add/select/setEnabled`：**新 UI（多份代理 + 下拉）**用。
 * 两套都落到同一个系统接口上，谁在用谁生效。
 *
 * 命名注意：字段一律起名 `activeEntry` / `enabledFlag` 这类，**不要**用 `current` / `on`
 * —— 它们会和同名方法/组件属性撞（ArkTS 报 Duplicate identifier 或
 * Reassigning object methods is not supported）。
 */

import { connection } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'AppProxy';
/** preferences 文件名（和 AppSettings 那个分开：代理里带密码，单独一个罐更好审计）。 */
const STORE_NAME: string = 'instarmony_proxy';

/** 旧（单份）配置的持久键。 */
export const PROXY_HOST: string = 'proxy_host';
export const PROXY_PORT: string = 'proxy_port';
export const PROXY_USER: string = 'proxy_user';
export const PROXY_PASS: string = 'proxy_pass';
/** 新（多份）列表的持久键：JSON 串 + 选中下标 + 总开关。 */
export const PROXY_LIST: string = 'proxy_list_json';
export const PROXY_ACTIVE: string = 'proxy_active_index';
export const PROXY_ON: string = 'proxy_enabled';

/** 旧形状：一份代理（空 host = 未启用）。 */
export class AppProxyConfig {
  host: string = '';
  port: number = 0;
  username: string = '';
  password: string = '';

  enabled(): boolean {
    return this.host.length > 0 && this.port > 0;
  }

  /** 一行摘要（日志/展示用；**不打印密码**）。 */
  summary(): string {
    if (!this.enabled()) {
      return '未启用';
    }
    const auth: string = this.username.length > 0 ? '（含认证）' : '';
    return `${this.host}:${this.port}${auth}`;
  }
}

/** 新形状：带别名的一份代理。 */
export class ProxyEntry {
  /** 别名（设置页下拉里显示的名字）。 */
  name: string = '';
  host: string = '';
  port: number = 0;
  username: string = '';
  password: string = '';

  enabled(): boolean {
    return this.host.length > 0 && this.port > 0;
  }

  summary(): string {
    if (!this.enabled()) {
      return '未填写完整';
    }
    const auth: string = this.username.length > 0 ? '（含认证）' : '';
    return `${this.host}:${this.port}${auth}`;
  }
}

/** 落盘用的扁平行（ArkTS 不允许无类型对象字面量）。 */
class ProxyRow {
  name: string = '';
  host: string = '';
  port: number = 0;
  username: string = '';
  password: string = '';
}

export class AppProxy {
  /** 持久化罐（冷启动时在 restoreAndApply 里打开）。 */
  private static store: preferences.Preferences | null = null;
  /** 旧 UI 的内存镜像。 */
  private static singleConfig: AppProxyConfig = new AppProxyConfig();
  /** 新 UI：列表 / 选中下标 / 总开关。 */
  private static entries: Array<ProxyEntry> = [];
  private static activeIndexValue: number = -1;
  private static enabledFlag: boolean = false;

  /**
   * 冷启动：读回两种形状，并把"该生效的那份"落到系统接口。
   *
   * **为什么必须在这里读盘**：之前代理只写到 AppStorage，进程一结束就没了 ——
   * 用户加过的代理重启后全消失（需求："把添加的代理永久保存到 app"）。
   * preferences 用同步接口（getPreferencesSync / getSync / putSync / flushSync），
   * 因为这里在 onCreate 里，必须同步完成：apply 要在第一个请求发出去之前生效。
   */
  static restoreAndApply(context: common.Context): void {
    try {
      if (AppProxy.store === null) {
        AppProxy.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      }
    } catch (error) {
      // 读不到罐不影响启动：只是"没记住上次的代理"。
      hilog.warn(DOMAIN, TAG, 'open proxy store failed: %{public}s', (error as Error).message);
      AppProxy.store = null;
    }
    AppProxy.loadEntries();
    const config: AppProxyConfig = AppProxy.loadSingle();
    AppProxy.singleConfig = config;
    // 新形状有选中项时优先按它应用（新 UI 是后续方向）。
    const entry: ProxyEntry | null = AppProxy.currentEntry();
    if (AppProxy.enabledFlag && entry !== null) {
      AppProxy.applyEntry(entry);
      return;
    }
    AppProxy.apply(config);
  }

  // ---------------- 旧接口（单份代理） ----------------

  static config(): AppProxyConfig {
    return AppProxy.singleConfig;
  }

  static save(config: AppProxyConfig): boolean {
    AppProxy.singleConfig = config;
    AppProxy.persistSingle(config);
    return AppProxy.apply(config);
  }

  static disable(): boolean {
    const empty: AppProxyConfig = new AppProxyConfig();
    AppProxy.singleConfig = empty;
    AppProxy.persistSingle(empty);
    AppProxy.enabledFlag = false;
    AppProxy.persistState();
    return AppProxy.apply(empty);
  }

  // ---------------- 新接口（多份代理 + 下拉） ----------------

  /** 已保存的代理（按保存顺序）。 */
  static list(): Array<ProxyEntry> {
    return AppProxy.entries;
  }

  /** 当前选中的下标（-1 = 没有）。 */
  static activeIndex(): number {
    return AppProxy.activeIndexValue;
  }

  /** 总开关现在是不是开着。 */
  static enabled(): boolean {
    return AppProxy.enabledFlag;
  }

  /** 当前选中的那一份（没有则 null）。 */
  static currentEntry(): ProxyEntry | null {
    if (AppProxy.activeIndexValue < 0 || AppProxy.activeIndexValue >= AppProxy.entries.length) {
      return null;
    }
    return AppProxy.entries[AppProxy.activeIndexValue];
  }

  /** 添加一份：自动成为选中项；开关已开时立即生效。 */
  static add(entry: ProxyEntry): boolean {
    if (!entry.enabled()) {
      return false;
    }
    AppProxy.entries.push(entry);
    AppProxy.activeIndexValue = AppProxy.entries.length - 1;
    AppProxy.persistEntries();
    if (AppProxy.enabledFlag) {
      AppProxy.applyEntry(entry);
    }
    return true;
  }

  /** 选中第 index 份。 */
  static select(index: number): boolean {
    if (index < 0 || index >= AppProxy.entries.length) {
      return false;
    }
    AppProxy.activeIndexValue = index;
    AppProxy.persistEntries();
    if (AppProxy.enabledFlag) {
      return AppProxy.applyEntry(AppProxy.entries[index]);
    }
    return true;
  }

  /** 打开/关闭总开关（开启时必须有选中的代理）。 */
  static setEnabled(value: boolean): boolean {
    const entry: ProxyEntry | null = AppProxy.currentEntry();
    if (value && entry === null) {
      return false;
    }
    AppProxy.enabledFlag = value;
    // 开关本身也要落盘：否则重启后代理列表还在、开关却是关的。
    AppProxy.persistState();
    if (!value) {
      return AppProxy.apply(new AppProxyConfig());
    }
    return entry === null ? false : AppProxy.applyEntry(entry);
  }

  // ---------------- 内部 ----------------

  private static applyEntry(entry: ProxyEntry): boolean {
    const config: AppProxyConfig = new AppProxyConfig();
    config.host = entry.host;
    config.port = entry.port;
    config.username = entry.username;
    config.password = entry.password;
    return AppProxy.apply(config);
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

  private static persistSingle(config: AppProxyConfig): void {
    AppStorage.setOrCreate(PROXY_HOST, config.host);
    AppStorage.setOrCreate(PROXY_PORT, config.port);
    AppStorage.setOrCreate(PROXY_USER, config.username);
    AppStorage.setOrCreate(PROXY_PASS, config.password);
  }

  private static loadSingle(): AppProxyConfig {
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

  private static persistEntries(): void {
    const plain: Array<ProxyRow> = [];
    for (let i: number = 0; i < AppProxy.entries.length; i++) {
      const one: ProxyEntry = AppProxy.entries[i];
      const row: ProxyRow = new ProxyRow();
      row.name = one.name;
      row.host = one.host;
      row.port = one.port;
      row.username = one.username;
      row.password = one.password;
      plain.push(row);
    }
    // 内存镜像（UI 直接读它）+ 落盘（重启后还在）。
    AppStorage.setOrCreate(PROXY_LIST, JSON.stringify(plain));
    AppProxy.write(PROXY_LIST, JSON.stringify(plain));
    AppProxy.persistState();
  }

  /** 选中项与总开关：**列表变了、换了代理、开关拨了都要落盘**。 */
  private static persistState(): void {
    AppStorage.setOrCreate(PROXY_ACTIVE, AppProxy.activeIndexValue);
    AppStorage.setOrCreate(PROXY_ON, AppProxy.enabledFlag);
    AppProxy.write(PROXY_ACTIVE, AppProxy.activeIndexValue);
    AppProxy.write(PROXY_ON, AppProxy.enabledFlag);
  }

  private static loadEntries(): void {
    const out: Array<ProxyEntry> = [];
    const raw: string = AppProxy.readString(PROXY_LIST, '');
    if (raw.length > 0) {
      try {
        const plain: Array<ProxyRow> = JSON.parse(raw) as Array<ProxyRow>;
        for (let i: number = 0; i < plain.length; i++) {
          const row: ProxyRow = plain[i];
          const one: ProxyEntry = new ProxyEntry();
          one.name = row.name;
          one.host = row.host;
          one.port = row.port;
          one.username = row.username;
          one.password = row.password;
          out.push(one);
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'proxy list parse failed');
      }
    }
    AppProxy.entries = out;
    AppProxy.activeIndexValue = AppProxy.readNumber(PROXY_ACTIVE, -1);
    AppProxy.enabledFlag = AppProxy.readBool(PROXY_ON, false);
    // 下标越界（列表被手工改坏、或者只剩空表）时回落到"没有选中"，免得 setEnabled 出错。
    if (AppProxy.activeIndexValue >= out.length) {
      AppProxy.activeIndexValue = -1;
    }
    if (out.length === 0) {
      AppProxy.activeIndexValue = -1;
    }
    // AppStorage 镜像同步一份：UI 的 @State 靠它初始化。
    AppStorage.setOrCreate(PROXY_ACTIVE, AppProxy.activeIndexValue);
    AppStorage.setOrCreate(PROXY_ON, AppProxy.enabledFlag);
  }

  // ---------------- 持久化（preferences，同步接口） ----------------

  /** 读字符串：罐没打开时退回 AppStorage（老版本只写内存的那批数据）。 */
  private static readString(key: string, fallback: string): string {
    const store: preferences.Preferences | null = AppProxy.store;
    if (store !== null) {
      try {
        const value: preferences.ValueType = store.getSync(key, fallback);
        if (typeof value === 'string') {
          return value;
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'read %{public}s failed: %{public}s', key, (error as Error).message);
      }
    }
    return AppStorage.get<string>(key) ?? fallback;
  }

  private static readNumber(key: string, fallback: number): number {
    const store: preferences.Preferences | null = AppProxy.store;
    if (store !== null) {
      try {
        const value: preferences.ValueType = store.getSync(key, fallback);
        if (typeof value === 'number') {
          return value;
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'read %{public}s failed: %{public}s', key, (error as Error).message);
      }
    }
    return AppStorage.get<number>(key) ?? fallback;
  }

  private static readBool(key: string, fallback: boolean): boolean {
    const store: preferences.Preferences | null = AppProxy.store;
    if (store !== null) {
      try {
        const value: preferences.ValueType = store.getSync(key, fallback);
        if (typeof value === 'boolean') {
          return value;
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'read %{public}s failed: %{public}s', key, (error as Error).message);
      }
    }
    return AppStorage.get<boolean>(key) ?? fallback;
  }

  private static write(key: string, value: preferences.ValueType): void {
    const store: preferences.Preferences | null = AppProxy.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save %{public}s failed: %{public}s', key, (error as Error).message);
    }
  }
}
