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
