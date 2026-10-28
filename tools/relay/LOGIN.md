# IG 账号登录：这次踩通的路（存档，后续攻克 App 登录时看这里）

> 一句话结论：**网页 Cookie 派生的会话进不了 IG 的设备信任路径**（iris 实时订阅、FBNS 推送注册
> 全部被拒）；换成**一次真机登录（instagrapi / 密码登录）产生的会话**后，两条通道**双双放行**。
> 所以"要实时"的真正门槛不是代码，而是**会话从哪来**。

## 一、现在的可用链路（已实测通过）

```
instagrapi（Python）登录 → settings.json → node relay.js --import-session settings.json
        ↓
relay 连 FBNS（IG 主动推）→ 收到私信 → 直接推送到华为 Push Kit → 手机
```

实测时间线（2026-10-28 20:02）：

| 项 | 结果 |
| --- | --- |
| iris 订阅（`edge-mqtt`，topic 134→135） | `{"succeeded":true,"latest_seq_id":551508}` |
| iris 事件（topic 146 message_sync） | `[{"event":"patch","data":[{"op":"add","path":"/direct_v2/threads/…/items/…"}]}]` |
| FBNS 连接（`mqtt-mini`） | `CONNACK rc=0` |
| FBNS 取 token（topic 80） | 有（长度 189） |
| FBNS 注册（`push/register/`） | `{"status":"ok"}` |
| FBNS 收到真实私信推送 | `{"m":"n h","t_id":"…","s":"46889056076","c":"direct_v2_text",…}` |

## 二、登录接口这条路：**旧的被停用，新的叫 CAA**

- `POST https://i.instagram.com/api/v1/accounts/login/` 现在可能直接回
  `{"error_type":"needs_upgrade","message":"Your version of Instagram is out of date…"}`。
  试过：5 个版本号（449/460/500/520/600）、instagrapi 的完整 40 个客户端头、
  甚至不存在的用户名 —— 都是同一个错。**这不是版本号不够新**（instagrapi 维护的默认也是 449）。
- 真正还能用的登录流程是 **Bloks CAA**（`com.bloks.www.bloks.caa.login.async.send_login_request`），
  instagrapi 已经实现并持续跟着 IG 改（其 `mixins/auth.py` 的 `login` → `bloks_caa_login`，
  以及 `_try_caa_login` 的兜底逻辑）。
- **对我们的启示**：不要自己重写 CAA。用 instagrapi 登录，把会话导出来即可。
  （如果哪天要"App 内直接密码登录"，就得把这套 CAA 移植进 ArkTS —— 工作量大且易碎，
   见文末"给 App 的方案"。）

## 三、settings.json 里我们实际用到的字段

```jsonc
{
  "cookies": { "sessionid": "…", "ds_user_id": "…", "csrftoken": "…" },   // → Cookie 串
  "uuids": {
    "phone_id": "…",          // → MQTT deviceId / X-IG-Family-Device-ID
    "uuid": "…",              // → X-IG-Device-ID
    "android_device_id": "android-…"   // → X-IG-Android-ID（去掉 android- 前缀）
  },
  "authorization_data": { "ds_user_id": "…", "sessionid": "…" },  // → Authorization: Bearer IGT:2:<base64>
  "device_settings": { "app_version": "449.0.0.52.84", "version_code": "1079242191",
                       "bloks_versioning_id": "799db3e3…" },
  "user_agent": "Instagram 449.0.0.52.84 Android (…)"
}
```

`node relay.js --import-session settings.json` 会把它拆成本项目要的三样：
`config.json` 的 `ig.cookie`、`mqtt-device.json`（三件套设备身份）、`session.json`（含 authorization）。

## 四、FBNS 协议要点（自己实现时别再摸索一遍）

| 步骤 | 关键点 |
| --- | --- |
| 连 `mqtt-mini.facebook.com:443` | `clientType: "device_auth"`、`appId: 567310203415052`、`endpointCapabilities: 128`、`noAutomaticForeground: true`、`subscribeTopics: [76, 80, 231]`、`clientStack: 3`、`anotherUnknown: -1`、keepAlive 60 |
| **引导连接** | 手上没凭据时用**空 userId** 连一次 → `CONNACK rc=0` 并在**回包载荷**里下发 `{"ck","cs","di","ds"}`；填 ds_user_id 或拿 sessionid 当密码都会回 `rc=4` |
| 重连 | 用 `ck/cs/di/ds` 重连（password=cs、deviceSecret=ds、fbnsConnectionSecret=cs、fbnsDeviceId=di） |
| 取 token | SUBSCRIBE `76`，再 PUBLISH `79` = `{"pkg_name":"com.instagram.android","appid":567310203415052}` → 响应在 `80`，取 `token` |
| 注册 | `POST /api/v1/push/register/`（表单）：`device_type=android_mqtt`、`is_main_push_channel=true`、`device_sub_type=2`、`device_token=<整串 token>`、`_csrftoken`、`guid`/`uuid`（用 ig_did 或设备 uuid）、`users=<ds_user_id>`、`family_device_id` |
| 收推送 | topic `76`，体是 `{"fbpushnotif": {…}}`；先 inflate，再剥掉 2 字节长度前缀 |
| 推送字段 | `m` 正文、`t_id` 会话、`s` 发信人 id、`n` 消息 id、`c` 类型（`direct_v2_text` 等）、`a` 头像 URL、`mid`、`ig` 深链 |

**注意**：FBNS 的设备凭据（`fbns-auth.json`）是 broker 下发的；同一份凭据**不要同时开两个连接**
（`fbns-test.js` 与 relay 同时跑可能互相踢）。

## 五、iris（edge-mqtt）要点

- 订阅：先拉收件箱拿顶层 `seq_id` / `snapshot_at_ms`，再往 topic `134` 发
  `{"seq_id":…,"snapshot_at_ms":…,"snapshot_app_version":"<客户端版本>"}`。
- **`snapshot_app_version` 必须带**，缺了会回 `Resnapshot for app upgrade`；
  带了但会话不被信任则回 `Iris_IrisValidationException`（网页会话就是这种）。
- 成功响应在 `135`：`{"succeeded":true,…}`；之后私信补丁从 topic `146` 来
  （路径形如 `/direct_v2/threads/<tid>/items/<iid>/`）。

## 六、给 App 的方案（下一步要攻克的）

App 现在用 WebView 登录，拿到的就是"网页会话"——所以 **App 内的实时私信同样进不了 iris/FBNS**。
三条可选路，按代价从小到大：

1. **导入会话**：App 提供一个入口，把上面那份 `settings.json`（或 `--import-session` 等价物）
   粘进来，把 `cookie + 三件套 uuid + authorization` 存进本地，然后走 FBNS/iris。
   **代价最小、最稳**，缺点是用户得先跑一次 Python 脚本（可引导，或做成"在电脑上登一次"）。
2. **App 内实现 CAA 登录**：把 instagrapi 的 Bloks CAA 流程移植到 ArkTS
   （`bloks_caa_login` + 两步验证 + challenge）。工作量大、且 IG 随时改（instagrapi
   自己就在不停修），**不建议**作为第一选择。
3. **继续轮询**：App 侧已有（`BackgroundKeep` + 本地通知），延迟 45 秒级；
   配合 relay 的 FBNS 才能到秒级。

> 若走方案 1，App 侧只需要：一个粘贴框 + 解析（`cookies`/`uuids`/`authorization_data`）+ 
> 落盘 + 启动时把 `sessionid` 注入 Cookie 罐、把 oauth 注入 `MobileSession` 身份。
> 现有 `core/mobileapi/MobileSession` 已经支持 `authorization` 字段，接起来不难。

## 七、账号侧的注意事项

- 2FA：instagrapi 抛 `TwoFactorRequired`，用 `cl.login(user, pwd, verification_code=…)` 重试；
- 人机校验（`ChallengeRequired`）：手机上点「这是我」再重试；
- 频繁尝试会 `PleaseWaitFewMinutes`，等 5–10 分钟；
- `settings.json` / `session.json` / `fbns-auth.json` 都是**等同密码**的东西，必须在 `.gitignore` 里
  （仓库已加），也不要发给别人。
