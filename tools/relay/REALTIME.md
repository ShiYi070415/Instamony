# 实时通道（MQTToT）可行性结论

> 目标：像 App 那样走 IG 的实时通道，来一条推一条，而不是每 60 秒轮询一次。
> 结论：**握手能通，私信事件订阅被服务端否决**。所以现阶段仍以轮询为主，
> 但把轮询调成"聊天时快、安静时慢"的自适应。

## 一、已经通的（实测 2026-10-28 18:32~18:37）

用 `tools/relay/realtime.js`（零依赖 Node 实现，移植自 App 的
`core/mobileapi/MobileMqtt.ets` + `MobileRealtime.ets`，上游是 instagrapi 的
`realtime/mqttot.py`）：

```
[realtime] CONNACK rc=0，通道已建立
```

也就是说这几层全部正确：

- TLS 到 `edge-mqtt.facebook.com:443`；
- 协议名 `MQTToT`、级别 3 的自定义 CONNECT；
- **Thrift Compact 编码 + zlib** 的载荷；
- `clientType="cookie_auth"` + `password="sessionid=<sessionid>"` 这套"网页会话当移动会话"的凭据；
- `appSpecificInfo` 里那 9 个键（`app_version` / `User-Agent` / `everclear_subscriptions` 等）；
- 心跳（PINGREQ，20 秒一次，2 字节）与 QoS1 PUBACK。

验证器：`node realtime-test.js 150`。

## 二、卡住的：`iris_subscribe`

私信实时同步必须先发一条订阅（topic `134`），回包在 topic `135`：

```json
{"succeeded":false,"error_type":1,"error_message":"Iris_IrisValidationException",
 "seq_id":null,"subscribed_at_ms":null,"latest_seq_id":null}
```

试过的变体（一次只改一个变量，全部同样的错）：

| 变体 | 结果 |
| --- | --- |
| 原样（seq_id + snapshot_at_ms + snapshot_app_version=449.0.0.52.84） | IrisValidationException |
| 完全一样再发一次（排除偶发） | 同上 |
| **不带** snapshot_app_version | `Resnapshot for app upgrade` ← 说明这个字段确实被读取 |
| 版本用 269.0.0.18.75 / 448.0.0.52.84 | IrisValidationException |
| `seq_id` 用字符串 | 同上 |
| `seq_id` 与 `snapshot_at_ms` 都用字符串 | 同上 |
| 位点用 seq-1 / snapshot-1000（老位点） | 同上 |
| 连上 MQTT **之后**重新取一次位点再订阅 | 同上 |
| HTTP 请求也带上同一台设备 id（`X-IG-Device-ID` / `X-IG-Android-ID` / `X-IG-Family-Device-ID`），与 MQTT 的 `deviceId` 一致 | 同上 |

**没有订阅成功就没有任何私信帧**：开着一个 150 秒的窗口、期间确实发了一条私信，
除了 `topic=150 PRN`（保活）以外没有收到任何事件。

## 三、为什么（推断）

`IrisValidationException` 出现在"这条会话的 iris 快照不被承认"这一层。最可能的原因是
**iris 权益绑在"由真实移动客户端登录建立、并在 IG 侧登记过设备"的会话上**，
而我们是拿网页 Cookie 拼出来的移动身份（cookie_auth）。这也解释了为什么 App 里
那条实时链路的注释停在"能收包"这一层，而没有"订阅成功"的实测结论。

要真正解决，大概需要走**密码登录 + 设备注册**（instagrapi 的 L3 流程），
而这与本项目"只用网页会话、不碰密码/2FA/challenge"的约束冲突。目前的判断：不值得。

## 四、于是怎么做（已生效）

轮询不追求"最快"，追求"该快的时候快"：

| 状态 | 间隔 |
| --- | --- |
| 最近一轮有新私信（正在聊天） | `pollSeconds`，默认 **60 秒** |
| 连续安静 `quietRoundsBeforeJump`（默认 2）轮 | 一步跳到 `quietJumpSeconds`，默认 **240 秒** |
| 上限 | `idleMaxSeconds`，默认 300 秒 |

实测序列（前 3 轮有消息，之后安静）：`60 → 60 → 60 → 75 → 240 → 240 → …`
比固定 60 秒少了 3~5 倍请求，而聊天中的延迟仍是"最多 60 秒"。

另外两个降低请求量的措施：

- **`--interval`** 只在人工验证时用（下限 15 秒），常驻别带；
- **App 在跑的时候**，本地通知由 App 自己弹（`PushCenter.notifyDirect`），
  完全不经过中转；中转只负责"App 被杀掉"的那段时间。

## 五、这些文件留着干什么

| 文件 | 用途 |
| --- | --- |
| `realtime.js` | 可用的 MQTToT 客户端（握手/心跳/收帧/发布）。哪天 iris 通了，接上去就能用 |
| `realtime-test.js` | 手动验证：连上、订阅、打印收到的帧 |
| `subscribe-probe.js` | 一次性变体探针（上面那张表就是它跑出来的） |

若之后 IG 放宽了 cookie_auth 的 iris 权限，重跑 `node subscribe-probe.js`，
看到 `{"succeeded":true}` 就可以把 `realtime.js` 接到 relay 主循环里当触发器。
