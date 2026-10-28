# Push Kit 服务端推送：怎么发（官方文档核对版）

> 结论先放这儿：**HarmonyOS 5+ 只认「服务账号 JWT」+ v3 接口**。
> 网上大量教程（包括我们早期那版 `tools/agc/agc.js`）写的
> `POST https://push-api.cloud.huawei.com/v1/{appId}/messages:send`
> 配 `grant_type=client_credentials` 换 access_token，
> 在 HarmonyOS NEXT 上**一定失败**，返回 `{"error":1101,"error_description":"parameter invalid","sub_error":20003}`。
> 这不是凭据填错了，是协议过时了——别再往那个方向排查。

依据（官方原文，2026-09 更新）：

- 基于服务账号生成鉴权令牌 —— https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-jwt-token
- 请求体结构说明 —— https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/push-scenariozed-api-request-struct
- 请求体参数说明 —— https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/push-scenariozed-api-request-param
- 请求示例 —— https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/push-scenariozed-api-request-example

## 一、鉴权：服务账号（不是 OAuth 客户端）

官方原文要点：

> 鉴权方式：**JWT 方式**。注意：**HarmonyOS 5 及以上系统版本推送不再支持 OAuth 2.0 开放鉴权方式**。
> 接口版本：请使用 **V3** 版本调用 Push Kit REST API。

所以要的东西只有一样：**服务账号密钥文件**。

1. 打开 API Console：https://developer.huawei.com/consumer/cn/console/api/myApi
2. 选择项目 → 创建凭证 →「服务账号密钥」
3. 下载**推送服务 API** 的服务账号密钥文件（`.json`）

文件长这样（官方样例，已脱敏）：

```json
{
  "project_id": "*****",
  "key_id": "*****",
  "private_key": "-----BEGIN PRIVATE KEY-----\nMIIJ...\n-----END PRIVATE KEY-----\n",
  "sub_account": "*****",
  "auth_uri": "https://oauth-login.cloud.huawei.com/oauth2/v3/authorize",
  "token_uri": "https://oauth-login.cloud.huawei.com/oauth2/v3/token",
  "auth_provider_cert_uri": "https://oauth-login.cloud.huawei.com/oauth2/v3/certs",
  "client_cert_uri": "https://oauth-login.cloud.huawei.com/oauth2/v3/x509?client_id="
}
```

放成 `tools/agc/private.json`（已被 `.gitignore` 拦住，不会进仓库）。

JWT 的字段对应关系（这就是全部规矩）：

| 位置 | 字段 | 取值 |
| --- | --- | --- |
| Header | `kid` | 文件里的 `key_id` |
| Header | `typ` | 固定 `JWT` |
| Header | `alg` | 固定 **`PS256`** |
| Payload | `iss` | 文件里的 `sub_account` |
| Payload | `aud` | 固定 `https://oauth-login.cloud.huawei.com/oauth2/v3/token` |
| Payload | `iat` | 当前 UTC 秒 |
| Payload | `exp` | `iat + 3600`（有效期内可复用，建议直接缓存 1 小时） |
| 签名 | — | SHA256withRSA/**PSS**，盐长 = 摘要长度 |

这个 JWT **本身就是** `Authorization: Bearer <jwt>`，**不需要**再拿它去换 access_token。

## 二、接口

```
POST https://push-api.cloud.huawei.com/v3/{projectId}/messages:send
Content-Type: application/json
Authorization: Bearer <服务账号 JWT>
push-type: 0
```

- `{projectId}` 是**项目 ID**（AGC → 项目设置），就在密钥文件的 `project_id` 里。
  **不是** App ID / `Sender ID`（我们的是 `10163532386415633`），也不是 OAuth Client ID。
- `push-type`：`0` 通知消息、`1` 卡片刷新、`2` 通知扩展、`6` 后台消息、`7` 实况窗、`10` 应用内通话。
- v3 只服务 **HarmonyOS Next / 5.x 及以上**；v2 只服务 3.x/4.x。

## 三、请求体（通知消息）

官方示例（原样）：

```json
{
  "payload": {
    "notification": {
      "category": "IM",
      "title": "普通标题",
      "body": "普通内容",
      "clickAction": { "actionType": 0 },
      "style": 0,
      "image": "https://xxx.png"
    }
  },
  "target": { "token": ["MAAALgE4G98BAAAAst..."] },
  "pushOptions": { "testMessage": true, "ttl": 86400 }
}
```

必填只有三处：`payload.notification`（内含 `category`/`title`/`body`/`clickAction`）、
`target.token`（数组，普通消息最多 1000 个）、以及请求头里的 `push-type`。

`category` 取值（影响频控和展示方式）：

- 服务与通讯类：`IM`（即时聊天）、`VOIP`、`MISS_CALL`、`SUBSCRIPTION`、`TRAVEL`、`HEALTH`、
  `WORK`、`ACCOUNT`、`EXPRESS`、`FINANCE`、`DEVICE_REMINDER`、`MAIL`、`PLAY_VOICE`
- 资讯营销类：`MARKETING`

> `IM` 这类要在 AGC 里**申请通知消息自分类权益**（Push Kit 设置页「自分类」按钮，
> 我们那边现在显示 `Not applied`）。不申请也能发，但走的是营销类频控，容易被限流。
> 只发 `MARKETING` 则不需要申请。

`clickAction.actionType`：`0` 打开应用首页、`1` 打开应用内页面（需配 `action` 或 `uri`）。
`pushOptions`：`testMessage: true` 单项目每天最多 1000 条、每次 ≤10 个 token，调通阶段用它；
`ttl` 默认 86400 秒。

## 四、本地怎么发

```powershell
cd C:\HMStudy\Instamony\tools\agc

# 1. 先核对密钥文件（不发网络请求）
node agc.js --whoami

# 2. 自测 JWT 生成逻辑（不碰真凭据，用临时 RSA 密钥验签）
node self-test.js

# 3. 真发一条到手机
node agc.js --push "Instamony 测试"
node agc.js --push "Instamony 测试" IM    # 显式指定 category
```

`credentials.json`（已 gitignore）里只留两条是必须的：

```json
{
  "pushToken": "手机里「复制中转材料」拿到的 token",
  "serviceAccountFile": "private.json",
  "category": "IM",
  "testMessage": true
}
```

成功时回包是 `{"code":"80000000","msg":"Success","requestId":"..."}`。
其它码的排查方向：

| 现象 | 含义 |
| --- | --- |
| HTTP 401 / `error=1101` + `sub_error=20003` | JWT 不对（alg 不是 PS256、aud 不对、私钥/PEM 拼错） |
| HTTP 403 / `sub_error=1105` | 服务账号不属于这个 project，或项目 ID 拼错 |
| `code` 里带 token 相关错误 | pushToken 过期（重装/HMS 更新都会换），回 App 重新复制 |
| 返回成功但手机没弹 | 通知权限被关 / 应用被冻结 / 频控（看 category） |

## 五、和 App 侧的关系

- App 侧 `pushService.getToken()` 只在 **AppGallery 分发的正式签名包**里成功
  （debug 侧载包必回 `1000900010 Illegal application identity`，别修了，修不了）。
- token 会变（重装、清数据、HMS 更新）。现在靠设置页「复制中转材料」手工取；
  自动上报（`PushTokenReporter` → 中转服务 `POST /token`）还是待办。
- 后台/数据消息（`push-type: 6`）需要在 App 里实现 `RemoteNotificationExtensionAbility`，
  目前没做；现阶段用通知消息（`push-type: 0`）足够。

## 六、自分类权益怎么勾（这一步比代码重要）

依据 [`申请推送场景化消息权益`](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-apply-right)。

**没申请权益的后果**：所有通知消息默认算「资讯营销类」——**静默通知、只在通知中心**、
且**单应用单设备每天 2 条上限**（社交通讯类应用也是 2 条）。也就是说 DM 推送等于废掉。
申请到「服务与通讯类」后：锁屏 + 铃声 + 振动，数量不设单独上限，
只受「所有场景化消息单设备单日 ≤ 3000 条」的总频控。

我们只需要勾 **1 项**：

| 勾选 | category | 为什么 |
| --- | --- | --- |
| ✅ Instant messaging 即时聊天 | `IM` | DM 就是用户间点对点私信，官方定义完全对上（"互关好友之间的点对点消息或私信"）。这是唯一必须的。 |
| ⬜ Voice or video call 语音/视频通话 | `VOIP` / `MISS_CALL` | **只有当 App 真会推「来电邀请」或「未接来电」时才勾。** 只显示 DM 里的消息就不要勾，场景不匹配会被拒，勾了不发也属于虚报。 |
| ⬜ 3~10（订阅/旅行/健康/工作事项/账号动态/订单物流/财务/设备提醒） | — | 全部不勾。每个都要真实场景 + 截图证明，选错是违规（见《通知违规处罚标准》）。 |

关于「软件消息通知」：**没有这个类别**。应用自身的公告 / 更新提醒 / 功能推荐
属于资讯营销类（`MARKETING`），**默认就是这个分类，不需要申请**——但它只有每天
2 条额度且静默，所以别拿它当常规通道，这类内容走 App 内提示或本地通知更合适。

### 两个容易踩的坑

1. **传了没开通的 category 会被静默降级**。官方原文：「若应用推送通知消息时携带未开通权益的
   category 字段值（例如未开通 IM 却传入 IM），应用的通知消息将自动归类为资讯营销消息」。
   所以我们工具里 `category: "IM"` 在权益生效前不会报错，只会变成静默 + 2 条/天。
   排查「返回成功但没弹通知」时先看这里。
2. **「通话」有两个不同的东西**，别混：
   - 本节的 `VOIP` / `MISS_CALL` 只是**通知分类**，可以在自分类权益里勾选；
   - 「**推送应用内通话消息**」（`push-type: 10`，能弹出接听界面）是另一项权益，
     仅邮件申请，要求企业证明函 + 《增值电信业务经营许可证》(B22 国内多方通信)。
     个人 / 开源项目基本拿不到，我们不做。

### IM 的合规红线（勾之前先确认代码能守住）

官方对 `IM` 附了硬性注解：**需承诺不包括未关注人的私信、官方号或商家批量推送给用户的私信或广告**。

所以推送侧要过滤：只推已经存在会话、且对方是互关/有历史往来的线程；
Instagram 的「消息请求」（陌生人首条私信，payload 里通常是 `is_pending` / message requests）
一律不推。否则一旦被抽查，判违规是直接按处罚标准处理的。

### 申请怎么填

1. AGC → 增长 → 推送服务 → 配置 → 选中应用 → 自分类权益「申请」。
2. **优先选标准场景**（审核快）；订阅、语音播报这类才走自定义场景。
3. 场景描述必须覆盖这 5 点（官方申请原则硬要求）：应用分类、应用主要业务、
   推送对象（注明是服务提供方还是消费者）、推送时机、触发条件。
4. 消息模板要跟场景一一对应，一个模板对一个场景。
5. 自定义场景审核 **15 个工作日**；通过后 **5 分钟生效**，随后要在页面点「**激活功能**」；
   超过 2 个月没激活要重新申请。

可以直接用的场景描述（IM）：

```
应用分类：社交通讯
应用主要业务：面向 HarmonyOS NEXT 的社交客户端，用户登录后可浏览信息流、查看动态、
              并与其他用户进行点对点私信（DM）沟通。
推送对象：消费者（应用用户本人），内容为其他用户发给该用户本人的点对点私信。
推送时机：用户账号的私信会话中收到对方新消息，且应用不在前台时。
触发条件：用户已登录并在设置中开启推送开关、系统通知权限已授予；
          仅当该会话已有历史往来（互相关注）时推送，陌生人首条消息（消息请求）不推送。
承诺：本应用 IM 类通知仅用于互相关注用户之间的点对点私信，
      不包含未关注用户的私信请求、官方号或商家批量推送，也不包含任何广告内容。
```

消息内容示例（官方要求"模板与场景对应"）：

```
业务场景：用户 A 向用户 B 发送一条私信，B 未在应用内查看。
通知标题：A 给你发来一条私信
通知内容：私信内容摘要（过长截断）
点击行为：打开与 A 的私信会话
```

