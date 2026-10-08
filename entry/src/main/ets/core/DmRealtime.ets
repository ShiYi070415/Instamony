/*
 * 私信**实时通道**（IG 的 iris / MQTT）—— 第一步：只验证"能不能连上 broker"。
 *
 * 计划分步走，每步都能单独验证：
 *   ① 本文件：TLS 连 `edge-mqtt.facebook.com:443`，确认网络/TLS 这层通（日志里给出结论）；
 *   ② 下一步：发 MQTT CONNECT（用户名 = 自己的 fbid、密码 = 会话令牌，见
 *      `IGDMqttSetupStandaloneQuery` 拿到的 `id` 与 `iris_inactive_subscription_uq_seq_id`），
 *      读 CONNACK 的返回码；
 *   ③ 再往后：SUBSCRIBE 私信 topic、解析 IG 的封套（外层 JSON + Base64/Thrift）、
 *      按 `iris_inactive_subscription_uq_seq_id` 做一次离线补偿，最后把 4 秒轮询放宽成兜底。
 *
 * 为什么先做这一步：第 ② 步能不能过是最不确定的一环（IG 可能像封 REST 读接口那样要求
 * 签名身份）。先把"连得上/连不上、被谁拒"这件事变成日志里一行确定的话，再决定往下做多少。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket } from '@kit.NetworkKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DmRealtime';
/** IG 的 iris（MQTT）broker：固定域名，不随会话变化。 */
const MQTT_HOST: string = 'edge-mqtt.facebook.com';
const MQTT_PORT: number = 443;
/** 连接超时（毫秒）。 */
const CONNECT_TIMEOUT_MS: number = 12000;

export class DmRealtime {
  /**
   * 连一次 broker 并把结论打进日志（连上就立刻断开 —— 这一步只验证可达性）。
   */
  static async probeTls(): Promise<void> {
    let tcp: socket.TLSSocket | null = null;
    try {
      tcp = socket.constructTLSSocketInstance();
      const options: socket.TLSConnectOptions = {
        address: { address: MQTT_HOST, port: MQTT_PORT },
        // 空的 secureOptions = 用系统预设 CA（SDK 里 ca 的注释写明：默认就是预置 CA 证书）。
        secureOptions: {},
        timeout: CONNECT_TIMEOUT_MS
      };
      // **必须先 bind**：真机上不 bind 直接 connect 会报 `No bind socket`（TLSSocket 内部要拿
      // 已绑定的本地套接字）。0.0.0.0 + 端口 0 = 让系统自己挑本地地址/端口。
      await tcp.bind({ address: '0.0.0.0', port: 0 });
      await tcp.connect(options);
      hilog.info(DOMAIN, TAG, 'tls connect ok host=%{public}s port=%{public}d —— 可以进下一步（MQTT CONNECT）',
        MQTT_HOST, MQTT_PORT);
      try {
        tcp.close();
      } catch (error) {
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'tls connect failed host=%{public}s: %{public}s',
        MQTT_HOST, (error as Error).message ?? 'unknown');
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (inner) {
        }
      }
    }
  }
}
