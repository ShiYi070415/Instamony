/*
 * **MeoW 推送**（鸿蒙上的消息提醒 App，`api.chuckfang.com`）。
 *
 * 用它的原因很实际：真机上没有 hdc，hilog 会被冲掉，用户也不愿意为了发一份日志去翻文件管理器。
 * 登录失败时点一下「推送登录日志」，日志直接进开发者的 MeoW，比"导出 txt → 找文件 → 发微信"
 * 少好几步。
 *
 * ## 接口（https://www.chuckfang.com/MeoW/api_doc.html）
 *
 * ```
 * POST https://api.chuckfang.com/{昵称}/[title]
 * Content-Type: application/x-www-form-urlencoded
 * title=…&msg=…
 * → {"status":200,"msg":"推送成功"}
 * ```
 *
 * 状态码：`200` 成功 / `400` 参数错 / `403` 内容策略 / `404` 昵称未注册 /
 * `429` 频率或 **IP** 超限 / `500` 服务端错。注意 `429` 在共享出口 IP 上很常见
 * （这也是为什么"在本机 curl 恒 429、在用户手机上却能推成功"）。
 *
 * ## 隐私
 *
 * 推的是**已脱敏的登录日志**（`LoginLog.compose` 里不含密码、Cookie 值、会话），
 * 只带设备型号/系统版本、链路状态、失败原因、IG 的原话与响应摘要。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MeoW';
const ENDPOINT: string = 'https://api.chuckfang.com/';
/**
 * MeoW **接收方昵称**（消息落到谁那里）。
 *
 * 2026-10-30 用户指定：日志统一推到 **Yijin0**（先 Yijin，后改为 Yijin0）。
 */
const NICKNAME: string = 'Yijin0';
/**
 * 通知里显示的**名字/标题**。
 *
 * 2026-10-30 用户指定：推送用户名称用 **栗子炸弹**（就是通知标题那一行）。
 * 接口形态是 `POST /{昵称}/{title}`，所以"谁收"和"显示成什么"分别对应
 * 昵称与标题两个位置。
 */
const SENDER_NAME: string = '栗子炸弹';
/** 单条消息的长度上限：接口没写死，但通知里几万字也没法看，截断更稳。 */
const MAX_MSG_CHARS: number = 3500;

export class MeoW {
  /** 接收方昵称（界面上可以显示，方便核对）。 */
  static nickname(): string {
    return NICKNAME;
  }

  /** 通知标题里显示的名字。 */
  static senderName(): string {
    return SENDER_NAME;
  }

  /**
   * 推一条**登录日志**：标题固定用 `栗子炸弹`，正文是已脱敏的日志。
   *
   * @returns 一行给人看的结论
   */
  static async pushLog(msg: string): Promise<string> {
    return MeoW.push(SENDER_NAME, msg);
  }

  /**
   * 推一条纯文本消息。
   *
   * @param title 标题（会出现在通知标题上）
   * @param msg   正文（超过 3500 字会被截断并标注）
   * @returns 一行给人看的结论（也会进日志）
   */
  static async push(title: string, msg: string): Promise<string> {
    if (msg.trim().length === 0) {
      return '没有内容可推';
    }
    const body: string = msg.length > MAX_MSG_CHARS
      ? `${msg.substring(0, MAX_MSG_CHARS)}\n…（已截断，共 ${msg.length} 字）` : msg;
    const form: string = 'title=' + encodeURIComponent(title)
      + '&msg=' + encodeURIComponent(body)
      + '&msgType=text';
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(
        `${ENDPOINT}${encodeURIComponent(NICKNAME)}`, {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': 'application/x-www-form-urlencoded' },
          extraData: form,
          connectTimeout: 15000,
          readTimeout: 20000,
          expectDataType: http.HttpDataType.STRING
        });
      const text: string = `${response.result}`;
      const status: number = MeoW.field(text, 'status');
      const message: string = MeoW.fieldText(text, 'msg');
      hilog.info(DOMAIN, TAG, 'push status=%{public}d len=%{public}d', status, body.length);
      if (status === 200) {
        return `已推送到 MeoW（${NICKNAME}，标题「${title}」，${body.length} 字）`;
      }
      const why: string = status === 404 ? '昵称未注册'
        : status === 429 ? '频率/IP 超限（等几分钟再试，或换网络）'
          : status === 403 ? '内容被策略拦下'
            : status === 400 ? '参数不对' : '服务端错误';
      return `推送失败（${status}：${why}${message.length > 0 ? `｜${message}` : ''}）`;
    } catch (error) {
      return `推送失败（网络）：${(error as Error).message}`;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 取 JSON 里的数字字段。 */
  private static field(json: string, name: string): number {
    const match: RegExpMatchArray | null =
      json.match(new RegExp(`"${name}"\\s*:\\s*(\\d+)`));
    return match !== null && match.length > 1 ? Number.parseInt(match[1], 10) : 0;
  }

  /** 取 JSON 里的字符串字段（中文可能带转义，够用即可）。 */
  private static fieldText(json: string, name: string): string {
    const match: RegExpMatchArray | null =
      json.match(new RegExp(`"${name}"\\s*:\\s*"([^"]{0,120})"`));
    return match !== null && match.length > 1 ? match[1] : '';
  }
}
