/*
 * **把 pushToken 报给中转**（BYO relay 的 `POST /token`）。
 *
 * ## 为什么需要这一层
 * Push Kit 给的 token **不是永久的**：重装 App、清除应用数据、系统更新 HMS Core、
 * 恢复出厂，任何一件都会换一条新 token。而华为的发送接口在旧 token 上**照样回
 * `80000000` 成功**（它只是把消息交给 Push 服务器），于是故障表现成
 * "推送突然不响了，但脚本日志全是成功" —— 最难查的那一类。
 *
 * 以前的做法是在设置页点「复制中转材料」再手工粘进 relay 的配置，几乎必然忘。
 * 现在只要在设置里填过一次中转地址，启动和 `tokenUpdate` 时都会自动报。
 *
 * ## 边界
 *   · **没配地址就一个请求都不发**（默认就是没配）；
 *   · 全程静默失败：中转没开 / 手机不在同一网络 / 明文被拦，都只写日志，
 *     绝不弹窗、绝不影响启动和任何界面（token 上报失败不该让用户看见任何东西）；
 *   · 同一进程内同一个 token 只报一次（`tokenUpdate` / 手动点按例外）；
 *   · 与 `PushCenter` **不做循环依赖**：那边把 token 传进来，这里只管发。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettings } from './AppSettings';

const DOMAIN: number = 0xFF00;
const TAG: string = 'PushTokenReporter';

/** 和中转通信的超时（内网一次往返，几秒足够；失败就算了，下次启动再报）。 */
const CONNECT_TIMEOUT_MS: number = 6000;
const READ_TIMEOUT_MS: number = 6000;

/**
 * 包名兜底（和 AppScope/app.json5 一致）。
 *
 * 这里没拿 context 就是为了**不留到 UI 或 Ability 那条链上**：上报是后台的杂活，
 * 而 relay 只是拿它写进日志，写错也不影响功能。
 */
const BUNDLE_FALLBACK: string = 'com.oneleaf.instamony';

export class PushTokenReporter {
  /** 正在发（防抖：@Builder 连点、启动与 tokenUpdate 撞在一起时只发一次）。 */
  private static inFlight: boolean = false;
  /** 上一次成功发出去的 `token|url`（同一进程内去重）。 */
  private static lastSent: string = '';
  /** 最近一次的结果文案（设置页显示用）。 */
  private static lastStatus: string = '';
  /** 最近一次成功的时间戳（毫秒，0 = 从没成功过）。 */
  private static lastOkAt: number = 0;

  /** 设置页显示的那行状态。 */
  static statusNow(): string {
    if (PushTokenReporter.lastStatus.length === 0) {
      return PushTokenReporter.lastOkAt > 0
        ? `上次上报成功（${PushTokenReporter.clockOf(PushTokenReporter.lastOkAt)}）`
        : '还没报过';
    }
    return PushTokenReporter.lastStatus;
  }

  /** 毫秒时间戳 → `HH:mm`（只给状态文案用，不追求跨天精确）。 */
  private static clockOf(at: number): string {
    const date: Date = new Date(at);
    const hour: string = `${date.getHours()}`.padStart(2, '0');
    const minute: string = `${date.getMinutes()}`.padStart(2, '0');
    return `${hour}:${minute}`;
  }

  /**
   * 异步上报（**不返回、不抛错**）：启动、`tokenUpdate` 这种地方调用。
   *
   * @param token  Push Kit 的 token（空串会直接跳过）
   * @param reason `startup` / `tokenUpdate` / `manual`，只用于对端日志
   */
  static report(token: string, reason: string): void {
    PushTokenReporter.post(token, reason, false).catch((): void => {
      // post 内部已经吞掉了所有异常，这里只是兜底
    });
  }

  /**
   * 手动上报（**等结果**）：设置页那颗按钮用，好当场告诉用户成没成。
   *
   * @returns 一行给人看的结果文案
   */
  static async reportNow(token: string, reason: string): Promise<string> {
    return await PushTokenReporter.post(token, reason, true);
  }

  /** 真正发请求。`force=false` 时同一 token + 同一地址不重复发。 */
  private static async post(token: string, reason: string, force: boolean): Promise<string> {
    const raw: string = AppSettings.relayReportUrlNow().trim();
    if (raw.length === 0) {
      PushTokenReporter.lastStatus = '未配置中转上报地址';
      return PushTokenReporter.lastStatus;
    }
    if (token.length === 0) {
      /*
       * 还没有 token（侧载的 debug 包永远拿不到，见 PushCenter 的 1000900010）。
       * 这时**仍然值得打一发 GET /health**：能分清"网络/地址/明文策略有问题"，
       * 还是"只是没有 token"。否则用户只会看到一句"还没有 push token"，
       * 却不知道中转到底通不通。
       */
      return await PushTokenReporter.probeHealth(AppSettings.relayReportUrlNow().trim(),
        AppSettings.relayReportKeyNow().trim());
    }
    const url: string = PushTokenReporter.endpointOf(raw);
    const fingerprint: string = `${token}|${url}`;
    if (!force && fingerprint === PushTokenReporter.lastSent) {
      hilog.info(DOMAIN, TAG, 'skip: already reported this token (%{public}s)', reason);
      return PushTokenReporter.lastStatus;
    }
    if (PushTokenReporter.inFlight) {
      return PullStatus();
    }
    PushTokenReporter.inFlight = true;
    const request: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json; charset=UTF-8'
      };
      const key: string = AppSettings.relayReportKeyNow().trim();
      if (key.length > 0) {
        header['X-Relay-Key'] = key;
      }
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify({
          token: token,
          reason: reason,
          bundle: BUNDLE_FALLBACK,
          at: Date.now()
        }),
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const body: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      if (response.responseCode !== 200) {
        PushTokenReporter.lastStatus = `中转回了 HTTP ${response.responseCode}`;
        hilog.warn(DOMAIN, TAG, 'report failed (%{public}d): %{public}s',
          response.responseCode, body.substring(0, 120));
        return PushTokenReporter.lastStatus;
      }
      PushTokenReporter.lastSent = fingerprint;
      PushTokenReporter.lastOkAt = Date.now();
      PushTokenReporter.lastStatus = '上报成功';
      hilog.info(DOMAIN, TAG, 'token reported (%{public}s) → %{public}s',
        reason, body.substring(0, 120));
      return PushTokenReporter.lastStatus;
    } catch (error) {
      /*
       * 常见成因（只写日志，不改行为）：
       *   · 中转没开 / 不在同一网络 → 连接失败；
       *   · 地址写成 https 而 relay 是明文监听 → 握手失败；
       *   · 明文 HTTP 不用额外配置：官方 `networkSecurity.isCleartextPermitted()`
       *     写明默认就是 true（系统默认放行明文），见 module.json5 里的同一处说明。
       */
      PushTokenReporter.lastStatus = `连不上中转：${(error as Error).message ?? '-'}`;
      hilog.warn(DOMAIN, TAG, 'report threw: %{public}s', (error as Error).message ?? '-');
      return PushTokenReporter.lastStatus;
    } finally {
      PushTokenReporter.inFlight = false;
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 没有 token 时的一发探活：`GET /health`。
   *
   * 只用来回答"中转到底通不通" —— 这条**不会**改变任何状态，中转也拿它没法做什么。
   */
  private static async probeHealth(base: string, key: string): Promise<string> {
    let url: string = base;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/token')) {
      url = url.substring(0, url.length - '/token'.length);
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {};
      if (key.length > 0) {
        header['X-Relay-Key'] = key;
      }
      const response: http.HttpResponse = await request.request(`${url}/health`, {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode !== 200) {
        PushTokenReporter.lastStatus = `中转可达，但 /health 回了 HTTP ${response.responseCode}`;
        return PushTokenReporter.lastStatus;
      }
      PushTokenReporter.lastStatus = '中转可达；但还没有 push token（正式签名包才有）';
      hilog.info(DOMAIN, TAG, 'health ok: %{public}s', JSON.stringify(response.result).substring(0, 160));
      return PushTokenReporter.lastStatus;
    } catch (error) {
      PushTokenReporter.lastStatus = `连不上中转：${(error as Error).message ?? '-'}`;
      hilog.warn(DOMAIN, TAG, 'health threw: %{public}s', (error as Error).message ?? '-');
      return PushTokenReporter.lastStatus;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /**
   * 把用户填的地址补成 `…/token`。
   *
   * 用户可能填 `http://1.2.3.4:8787`、`http://1.2.3.4:8787/`、或者带 `/token`，
   * 三种都接受 —— 让人记住"末尾要不要斜杠"是没意义的心智负担。
   */
  private static endpointOf(raw: string): string {
    let url: string = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/token')) {
      return url;
    }
    return `${url}/token`;
  }
}

/** 当前进度文案（in-flight 时给调用方一句人话）。 */
function PullStatus(): string {
  return PushTokenReporter.statusNow().length > 0
    ? PushTokenReporter.statusNow() : '正在上报…';
}
