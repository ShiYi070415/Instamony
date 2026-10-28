# IG 账号登录：这次踩通的路（存档，后续攻克 App 登录时看这里）

## 0. 现在有两条登录路（推荐用 JS 版）

| 方式 | 命令 | 依赖 |
| --- | --- | --- |
| **JS 版（正在完善）** | `node instamony.js --caa-login` → `node instamony.js --verify-session` | 只要 Node |
| Python 版（已验证可用） | `python login_ig.py` → `node instamony.js --import-session settings.json` | Python + instagrapi |

JS 版移植自 instagrapi 的 CAA/Bloks 流程，实测已打通的部分：

| 步骤 | 实测结果 |
| --- | --- |
| USDID 设备身份注册 | ✅ `{"usdid_registration":{"success":true,...}}` |
| attestation nonce | ✅ `challenge_nonce` |
| 取 aac（CAA 账号访问上下文） | ✅ 303 字符 |
| oauth token 预取 | ✅ HTTP 200 |
| **提交账号密码** | ✅ HTTP 200，IG 真实处理（假账号回 `login_failed` + "Can't find account"） |
| 两步验证链（ap.2sv） | 已实现 entrypoint → code_entry → 提交验证码，**待真账号验证** |
| 会话形状等价性 | ✅ `settings.caa.json` 经 `--import-session` 解析与 `session.json` 逐字段一致（实测） |
| 设备信任闸门 | ✅ `--verify-session` 四步全绿：形状 / 探活 200 / 等价 / `push/register/` `{"status":"ok"}` |
| 前检（不带账号） | ✅ `--caa-preflight`：attestation 200 / aac 303 / `qe/sync` keyId=181 + 公钥 604 字符（对真服务器实跑） |

> `--caa-preflight` 只跑密码之前那半条链（USDID → attestation → aac → 密码公钥），**不需要账号**。
> 它的用处是分诊：前检绿、登录挂 ⇒ 问题在账号侧（密码/2FA），不必再怀疑设备或协议。
> 其中 `qe/sync` 会显示 `HTTP 405` —— **这是 IG 对 `GET /api/v1/qe/sync/` 的固定答复**，
> 公钥头照常下发（instagrapi 也是 GET，走同一条）。判据是"响应的头里有没有公钥"，不是状态码。

### 会话可以双向搬运（两端形状统一到 instagrapi settings）

| 方向 | 怎么做 |
| --- | --- |
| 电脑 → 手机 | App 面板「用已有会话导入」→ 粘 `settings.caa.json` / `session.json` |
| 手机 → 电脑 | App 面板「复制当前会话（给电脑上的中转用）」→ 存成文件 → `node instamony.js --import-session 文件` |

两边都收敛到 **instagrapi `settings.json` 的形状**（`cookies` 映射 + `uuids` +
`authorization_data`），所以电脑侧不需要新命令：`--import-session` 直接吃手机导出的文件。
想先确认不覆盖现有会话，用 `--import-check <文件>`（只解析、不落盘）。

> 顺带记一个 Windows 上的坑：记事本 / `Set-Content -Encoding UTF8`（PS 5.1）写出来的 JSON
> **带 BOM**，`JSON.parse` 见到 BOM 直接抛 —— 表现是"文件明明在，却报读不到"。
> 现在所有读 JSON 的地方都会先去掉 BOM。

> `--verify-session` 是**判据**，不是装饰：`push/register/` 那一步对网页 Cookie 派生的会话回
> 400（实测过），只有设备级会话回 `{"status":"ok"}`。登录"成功"但这一步不过 = 常驻收不到推送。

### 与 instagrapi 3.2.2 对齐时踩到的两处（直接照抄源码结论，别再自己推）

1. **2SV entrypoint 的 app id 带 `_async`**：`com.bloks.www.ap.two_step_verification.entrypoint_async`
   （少写 `_async` 时"是否需要 2FA"的判断仍然成立 —— 因为前缀匹配得到 —— 但**真正去调**那个
   app 会失败。这个坑很隐蔽：看起来只差一个后缀。）
2. **`password_text_input_id` / `username_text_input_id` 的形状是 `<4 位十六进制>ig:81|82`**
   （instagrapi 注释原文：纯十六进制/UUID 前缀能被 VM 接受，但可能回"空载荷 404"）。

另注：**2FA 有两套链，两套都得在**（R12 真机实测踩到）：

| 链 | 触发标志 | 走法 |
| --- | --- | --- |
| 新版（context 链） | 响应里有 `two_step_verification_context` | `two_step_verification.entrypoint` → `method_picker` → `method_picker.navigation.async`（选 totp/sms/backup_codes）→（备用码才走 `two_factor_login.enter_backup_code`）→ `two_step_verification.verify_code.async` |
| 老版（profile-code 链） | 布局里有 `ap.two_step_verification.entrypoint_async` | entrypoint → code_entry → code_entry_async（用 `context_data` 串） |

判哪套：**先看有没有 `two_step_verification_context`**（真机那次就是它，票据 13 字符），
没有再试 `ap.*`。方式推断照 instagrapi：8 位数字 ⇒ 备用码；只开短信没开 TOTP ⇒ sms；其余 ⇒ totp。
两套都实现前，遇到 context 链会报"布局形状变了"——**这正是 R12 真机第一次的结果**。

另一个真机实测的重要形状：失败/兜底响应里有 `CAA_LOGIN_FALLBACK:fallback_triggered`，
而且数据藏在 `embedded_payloads`（对象，不是字符串）里。所以登录结果的查找是三级：
`layout.bloks_payload.action` → 所有字符串里的 JSON 文本 → 整棵树里的 `{login_response, headers, cookies}` 对象。
失败时 relay 会把**完整响应**写到 `.tmp/caa-last-response.json`，形状变了就发这个文件，不必复现。

### 成功响应里的 `headers` 不止 authorization

登录响应的 `headers` 里还有三条**会话材料**，instagrapi 在 `_send_private_request` 里会捡：
`ig-set-x-mid`（机器 id）、`ig-set-ig-u-rur`、`x-ig-set-www-claim`。

以前我们只留 `IG-Set-Authorization`、把另外三条丢了 —— 全新安装时本机 `mid` 是空的，
而 `X-MID` 是移动 API 的身份头之一，于是"登录成功之后每个请求都像没有机器 id 的客户端"。
现在两条路都会把它们带回来：

- relay：`sessionHeadersOf()` 捡，`session.json` 里多存 `mid` / `rur` / `claim`，
  `settings.caa.json` 的 `mid` 也优先用响应里那份；
- App：`CaaResult.mid/rur/claim` → `CaaSession.applySession()` 写进 `MobileIdentity`
  （`mid` / `igURur` / `wwwClaim`）后落盘 —— 和 `MobileSession.absorbResponseHeaders`
  对普通响应的做法一致。

离线测试里有两条断言专门盯它（小写、大写混着都能认）。

### 离线自检抓出的两个真 bug（解析成功响应这条路径）

成功响应那条路在真账号登录之前**一次都没被执行过**，所以写了 `test-caa-parse.js`
（合成 Bloks 布局 + 本地 RSA 密钥对）。它当场抓出两处：

1. **引号截断**：payload 里的字符串层层转义（`\"login_response\"`），用
   `indexOf('"', start+1)` 找结尾会停在第一个**转义**引号上，截出来的东西 `JSON.parse`
   必然失败 —— 现象就是"IG 说登录成功、我们却解析不出会话"。
   现在按转义规则走完整字面量（`jsonStringAt`）。
2. **Cookie 解析**：真实响应有两种形状 ——
   `sessionid=x; Path=/; Domain=…; HttpOnly` 与
   `Set-Cookie: sessionid=x; Path=/, Set-Cookie: ds_user_id=1; Path=/`。
   只按 `;` 切会把 `Path`/`Domain` 当 Cookie 塞进罐，而 `ds_user_id` 因名字带
   `, Set-Cookie: ` 前缀**整个丢掉**（网页会话能建、账号 id 空）。
   现在对齐 Python `SimpleCookie` 的语义：属性名跳过、按 `;` 与 `,` 都切。

这两处在 JS 与 ArkTS 两侧**同源实现**，改一侧必须改另一侧。ArkTS 跑不了单测，所以在
`CaaLogin.selfTest()` 里放了同样四项断言，界面上的「先跑解析自检（不联网）」就是它 ——
真机上先跑一次，就能把"解析器坏了"和"IG 拒绝了"分开。

### App 那份移植和 JS 是否一致：`audit-arkts-parity.js`

App 里的 `CaaLogin.ets` 是真机才跑得到的移植，字段少一个/拼错一个，IG 就换判据
（典型症状：同样的密码，脚本能登、App 里登不上）。审计脚本按锚点把两边每个请求体的
**键集合**抠出来比：`node tools/relay/audit-arkts-parity.js`。

当前结论（R6）：五个请求体（networkInfo / 取 aac / oauth / send_login_request / 2SV）
**字段齐全**；请求头只差 `Connection`（ArkTS 有意不发，理由见 `MobileRequest.baseHeaders`）。
另外核过三处"只有真机才暴露"的等价性：

- **密码加密字节布局**：`0x01 | keyId | iv(12) | u16LE(rsa) | rsa | tag(16) | cipher`，
  AES-256-GCM 的 AAD = 时间戳字符串 —— 与 JS（离线可逆测试过的那份）逐字节一致；
- **bloks 版本号**：ArkTS 从 `MobileConfig.APP_SETTINGS` 的默认档取
  `799db3e3…`，与 JS `FALLBACK_PROFILE.bloksVersionId` 同一个常量；
- **文本输入框 id**：`<4 位十六进制>ig`（`:81` 用户名 / `:82` 密码）。

三个关键结论（避免以后重复踩）：

1. **`graphql_www` 的路径是 `https://i.instagram.com/graphql_www`，没有 `/api` 前缀**；
   带 `/api` 会回 `404 + not-logged-in` 的 HTML，很容易误判成"未登录"。
2. **设备证明不需要 Play Integrity**：IG 接受 keystore 不可用状态
   （`{"attestation":[{"version":2,"type":"keystore","errors":[-1013],...}]}`），
   USDID 只是本地 P-256 密钥 —— 所以 JS 甚至 ArkTS 都能做。
3. 所有请求都要带 `X-Meta-Usdid`（设备签名头），否则像非本机设备。

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
   自己就在不停修）—— **已完成移植并接进界面**，见下面「六·补」。
3. **继续轮询**：App 侧已有（`BackgroundKeep` + 本地通知），延迟 45 秒级；
   配合 relay 的 FBNS 才能到秒级。

> 若走方案 1，App 侧只需要：一个粘贴框 + 解析（`cookies`/`uuids`/`authorization_data`）+ 
> 落盘 + 启动时把 `sessionid` 注入 Cookie 罐、把 oauth 注入 `MobileSession` 身份。
> 现有 `core/mobileapi/MobileSession` 已经支持 `authorization` 字段，接起来不难。

## 六·补、App 内密码登录：已接线（ArkTS 版 CAA）

这一轮把 scheme 2 做完了，两条路（JS 脚本 / App 内）共用同一套协议知识：

| 位置 | 作用 |
| --- | --- |
| `entry/src/main/ets/core/mobileapi/CaaLogin.ets` | 协议本体：USDID、attestation、aac、oauth、send_login_request、两步验证 |
| `entry/src/main/ets/core/mobileapi/CaaSession.ets` | **落地面**：Cookie 种进罐 + `MobileSession` 重捡会话 + USDID 存 preferences；另有 `adoptPasted()`（粘贴会话导入） |
| `entry/src/main/ets/components/CaaLoginCard.ets` | 界面（输入框 / 验证码 / 逐步 HTTP 状态 / 解析自检 / 粘贴导入），登录页与设置页共用 |
| `entry/src/main/ets/core/InstagramCookieJar.ets` | `adoptCookieText`：把服务端给的每一颗 Cookie 都种进罐 |

界面入口有两个（同一个组件）：
- **未登录的整页登录页** → 底部「App 协议登录（实验）」→ 半模态面板；
- **设置页** → 「账号登录（实验）」那一组。

> **备用路：粘贴会话导入**。面板里还有「用已有会话导入」——把电脑上跑出来的
> `settings.caa.json`（或 `session.json`）整份粘进去，直接把**设备级会话**搬进 App。
> 它和密码登录共用同一个落地实现（`applySession`），所以：**实时私信与本地通知可以先单独验**，
> 不必等密码登录调通；反过来，密码登录一旦成功，走的也是同一条落地。

刻意做成"登录成功后会话直接进 Cookie 罐"。整个 App 只认罐（网页兜底、`MobileSession.ensure`、
退出登录清罐都是），所以成功之后壳会自己从登录页切到已登录（`refreshSessionFromJar → applySession`），
**不需要**为这条路再写一套会话生效逻辑。

几个实现要点（改代码前先看这几条）：

1. **USDID 要落盘复用**。它是设备身份；每次登录换新密钥 = 在 IG 眼里是一台新设备，
   风控更严。存 preferences（`instarmony_caa`：`usdid` / `usdid_kid` / `usdid_private` / `usdid_public`），
   退出登录**不清**（和会话材料分开）。
2. **两步验证的现场留在内存**（`CaaPending`）：第二段要复用第一段布局里的 `context_data`
   和同一份请求头。所以 `login(..., null)` 探到要验证码就停住，UI 收码后调 `submitCode(code)`。
3. **`authorization` 用服务端下发的那一份**（`Bearer IGT:2:…`），不要用本地按 userId/sessionid
   算的 —— 设备信任看的是前者。
4. ArkTS 严格模式的坑（都已踩过）：`cryptoFramework.Signer` 实际叫 **`Sign`**；`convertKey` 传
   `null` 要显式声明成 `DataBlob | null`，否则重载解析落到只收 `DataBlob` 的那两个上；
   嵌套对象字面量必须逐层声明类型。

验证方法（真机）：登录页 →「App 协议登录（实验）」→ 填用户名密码 →
状态行应当依次显示 `usdid 200 → attestation 200 → aac 200 → oauth_token_fetch 200 →
send_login_request 200`，然后壳切进主界面。要验证码时面板会多出「验证码」一行。
失败时状态行会给出 IG 的原话（例如 `Can't find account`），照它判断是账号问题还是形状变了。

### 状态行 → 含义 → 下一步（真机自诊表）

面板里有三个按钮，**先跑前两个再填密码**，失败时就按这张表判断：

| 状态行显示 | 说明 | 下一步 |
| --- | --- | --- |
| `解析自检 4/4 通过` | 解析器（aac / 错误文案 / login_response / 2SV 上下文）没问题 | 继续 |
| `解析自检未通过：xxx` | 我们自己的解析代码坏了（不是账号问题） | 把这一行发我 |
| `前检通过（aac N 字符）` | USDID / attestation / aac 全通 —— 设备与网络这侧没问题 | 继续填密码 |
| `前检` 卡在 `attestation` | 网络到 `i.instagram.com` 有问题，或被中间设备拦 | 换网络（WiFi/流量）再试 |
| 前检卡在 `process_client_data` 且带 IG 文案 | 设备身份被拒（罕见） | 发我状态行 |
| `登录失败：Can't find account` | 用户名不存在/打错 | 核对用户名（不是显示名） |
| `登录失败：The password you entered isn't correct` | 密码错 | 核对密码；**别反复试**（会触发风控） |
| `登录失败：Please wait a few minutes` | 触发限流 | 等 5~10 分钟 |
| `需要两步验证码` | 走到 2SV 了，链路是通的 | 在「两步验证码」那行填码后点「提交验证码」 |
| `两步验证失败：…` | 码错/过期，或 2SV 布局变了 | 重新点登录再试一次；连续失败把状态行发我 |
| `没拿到 aac（CAA 流程可能变了）` | Bloks 布局形状变了 | 发我状态行 + 前检那几行 |
| `登录成功 · uid=…` | 会话已进 Cookie 罐 | 实时通道会自动重启；可去私信页看是否实时刷新 |

> 任何时候点「**复制登录诊断**」都能把最近一次的结论 + 逐步现场 + cookie/header 的**名字**
> （不含值）复制出来 —— 真机上没有 hdc、hilog 会被冲掉，这段文字就是唯一可靠的现场。

## 七、账号侧的注意事项

- 2FA：instagrapi 抛 `TwoFactorRequired`，用 `cl.login(user, pwd, verification_code=…)` 重试；
- 人机校验（`ChallengeRequired`）：手机上点「这是我」再重试；
- 频繁尝试会 `PleaseWaitFewMinutes`，等 5–10 分钟；
- `settings.json` / `session.json` / `fbns-auth.json` 都是**等同密码**的东西，必须在 `.gitignore` 里
  （仓库已加），也不要发给别人。
