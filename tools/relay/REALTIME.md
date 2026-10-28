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

## 四、最终形态：**轻量探测 + 立刻推送**（实测 1~2 秒）

真·实时走不通之后，能做到的最快路径是"探到就推"：

| 档位 | 触发条件 | 探测间隔 | 探测窗口 | 体积 |
| --- | --- | --- | --- | --- |
| 热档 | 最近 10 分钟有过新消息 | **1 秒** | 3 会话 × 3 条 | 13 KB |
| 空闲 | 其余时间 | **2 秒** | 同上 | 13 KB |
| 全量兜底 | 每 300 秒 | — | 30 会话 × 20 条 | 261 KB |

关键设计：

- **探测发现变化时直接用探测结果推**，不再回头拉全量 —— 省掉一次往返；
- 探测窗口只取前 3 个会话，依据是 **IG 收件箱按最后活跃时间排序**：任何会话来了新消息都会顶到最前；
- 探测到就**按时间顺序逐条推**，每条独立 `notifyId`（堆叠）、独立 `appMessageId`（服务端去重）；
- 推完立刻继续探（尾部的三档睡眠已删掉 —— 它曾经让"1 秒探测"变成实际 15 秒）。

实测延迟账（1 秒探测档）：

| 环节 | 耗时 | 谁决定 |
| --- | --- | --- |
| 对方发出 → IG 写入收件箱 | ~0.2~0.5 s | IG |
| 探测等待（最坏一个间隔） | 1 s | **我们可调** |
| 探测响应（13 KB） | 0.3 s | 网络/IG |
| 华为 Push 受理 | 0.2~0.5 s | 华为 |
| 下发到设备 + 弹出 | 0.5~2 s | 华为/设备 |
| **端到端** | **实测 1~2 秒** | — |

再往下压只剩"把探测间隔调到 0.5 秒"，代价是带宽 13 KB/s → 26 KB/s（约 94 MB/小时），
且更接近 IG 的风控阈值。**物理下限约 0.8 秒**（0.3 s 响应 + 0.2 s 受理 + 0.3 s 下发），
拿不到"零延迟"：那需要 IG 主动推，而 iris 订阅拒绝这类会话。

> 另一个真正"即时"的路径是**手机上 App 自己弹本地通知**（App 活着时零服务器往返，
> 见 `PushCenter.notifyDirect`）。relay 的价值在于"App 被系统杀掉"那段。

## 六、FBNS：另一条真正"IG 主动推"的通道（已打通 3/4，卡在注册）

iris 那条死了，但上网查到一个关键线索 —— instagrapi 官方文档写着：

> FBNS push notifications use a separate `mqtt-mini.facebook.com` device-auth connection.
> **Use FBNS when you need Instagram push payloads, for example Direct message notification callbacks.**

也就是说 IG 另有一条**设备认证**的推送通道，与 iris 完全独立。照 instagrapi 的
`realtime/fbns.py` 实现了 `fbns.js`，实测进展：

| 步骤 | 状态 |
| --- | --- |
| 1. 连 `mqtt-mini.facebook.com:443`（`clientType=device_auth`） | ✅ |
| 2. 引导：**空 userId** 首连 → `CONNACK rc=0` 并下发设备凭据 `{ck,cs,di,ds}` | ✅ |
| 3. 用凭据重连 → `CONNACK rc=0` | ✅ |
| 4. 订阅 topic 76 + 往 79 发注册请求 → topic 80 回 push token | ✅（token 长度 189） |
| 5. **把 token 注册给 IG**（`POST /api/v1/push/register/`） | ❌ `400 Invalid request` |
| 6. 之后 IG 就会往 topic 76 推 `fbpushnotif`（`collapse_key: direct_v2_message`） | 未验证 |

### 两个反直觉的实测结论（别再走回去）

1. **引导连接必须把 `userId` 留空**。填 `ds_user_id`、或把 `sessionid` 当密码，全都回
   `CONNACK rc=4`（bad user name or password）；留空反而成功，并在回包里下发设备凭据。
   这一条是试出来的（`fbns-probe.js` 的 A~E 变体）。
2. 设备凭据里的 `ck` **不等于账号 id**（实测 `ck=1039423658233371`，而账号是
   `46473815227`），`di`/`ds` 也是 broker 自己发的，与本地 `mqtt-device.json` 无关。

### 卡点（下一步要解决的就是它）

`push/register/` 对所有试过的形态都回 `400 {"message":"Invalid request","status":"fail"}`：

| 变体 | 结果 |
| --- | --- |
| form / `signed_body=SIGNATURE.…` / JSON body | 400 |
| `guid`+`uuid` 取 `ig_did` / 设备 uuid / `di` | 400 |
| `family_device_id` 取新 uuid4 / `phoneId` / `di` | 400 |
| `users` 取 `ds_user_id` / `ck` | 400 |
| `device_token` 取整串 JSON / 内层 `k` | 400 |
| `X-IG-App-ID` 取 567067343352427 / 567310203415052 | 400 |
| `is_main_push_channel` 取 `true` / `True` / `true` | 400 |

下一步最值得做的是**对照一个有实际运行的实现**（比如 `mautrix-instagram` 的 FBNS 注册），
看它的请求头/字段与 instagrapi 有何差异 —— 差一步就成了，成了之后端到端延迟会从
1~2 秒变成亚秒级。

## 七、这些文件留着干什么

| 文件 | 用途 |
| --- | --- |
| `realtime.js` | 可用的 MQTToT 客户端（握手/心跳/收帧/发布）。哪天 iris 通了，接上去就能用 |
| `realtime-test.js` | 手动验证：连上、订阅、打印收到的帧 |
| `subscribe-probe.js` | 一次性变体探针（上面那张表就是它跑出来的） |

若之后 IG 放宽了 cookie_auth 的 iris 权限，重跑 `node subscribe-probe.js`，
看到 `{"succeeded":true}` 就可以把 `realtime.js` 接到 relay 主循环里当触发器。
