# 推送网关（把通知能力开放给其他用户）

## 当前已部署的实例

```
https://vercel-alpha-eight-69.vercel.app/api/push
```

- 项目名 `insta-65ef/vercel`，生产环境变量已配：`HUAWEI_SA_JSON`、`GATEWAY_KEYS`（1 个 key）、`PUSH_CATEGORY=IM`
- 自检：`GET` 该地址应回 `{"ok":true,"service":"instamony-push-gateway","keys":1,...}`
- 实测转发成功：`requestId 179319113648761452000207`（云端网关）／`179319114366286684000107`（客户端经网关）
- 站长本人的 key 只通过私聊给出，**不写进仓库**

### 加一个新用户（1 分钟）

1. 生成一个 key，追加到 `GATEWAY_KEYS`（逗号分隔）：
   ```powershell
   cd tools/gateway/vercel
   "旧key,新key-xxxx" | npx vercel env rm GATEWAY_KEYS production   # 先删
   "旧key,新key-xxxx" | npx vercel env add GATEWAY_KEYS production  # 再加
   npx vercel deploy --prod --yes
   ```
   （Vercel CLI 的 env 只能整条覆盖，所以是"删了再加"）
2. 把 URL 和这个 key 发给对方；对方照下面「用户侧怎么配」写进 `config.json`。

### 吊销某个用户

把那个 key 从 `GATEWAY_KEYS` 里去掉，重新 `vercel deploy --prod --yes` 即可。

## 为什么需要它

其他用户想用 `instamony.js` 收私信通知，就必须能发**华为 Push Kit**，而发推送需要
**服务账号私钥**（`tools/agc/private.json`）。把私钥发给每个人等于把推送权交出去。
所以改成：

```
他的电脑：收 IG 私信 ──POST 通知内容（带他的 key）──▶ 你的网关（持有私钥）──▶ 华为 ──▶ 他手机
```

- 每个用户一个 `key`，可随时吊销；
- 私钥只在网关的环境变量里，谁也不发；
- **无状态**：客户端每次自带 `token`，网关不存任何用户数据 —— 所以能直接跑在
  免费的函数托管（Vercel 等）上，不需要数据库。

## 两种部署方式

### 一、Vercel（推荐，免费、常开）

文件：`vercel/api/push.js`（单文件函数，零依赖，只用 Node 内置 `crypto`/`fetch`）。

1. 部署（二选一）：
   ```bash
   cd tools/gateway/vercel
   npx vercel            # 按提示登录 → 部署
   ```
   或把 `vercel` 目录推到 GitHub，然后在 Vercel 里 Import 该仓库。

2. 在 Vercel 项目 → Settings → Environment Variables 加两个变量：

   | 变量 | 值 |
   | --- | --- |
   | `HUAWEI_SA_JSON` | `tools/agc/private.json` 的**完整内容**（一整段 JSON） |
   | `GATEWAY_KEYS` | 逗号分隔的 key 列表，如 `alice-7f3a9c,bob-2e1d8b`（每个至少 8 字符） |

   可选：`PUSH_CATEGORY`（默认 `IM`）。

3. 拿到地址，形如：

   ```
   https://<项目名>.vercel.app/api/push
   ```

4. 自检：

   ```bash
   curl https://<项目名>.vercel.app/api/push
   # {"ok":true,"service":"instamony-push-gateway","keys":2,...}
   ```

### 二、自己的机器 / 任意常驻 Node（备选）

```bash
cd tools/gateway
copy config.example.json config.json    # 填 port / keys / agc
node gateway.js
```

监听 `0.0.0.0:<port>`，接口与 Vercel 版一致（`POST /send`）。
适合内网使用；放公网请加 HTTPS 反代。

## 接口

```
POST <网关地址>
Header: X-Gateway-Key: <分给该用户的 key>
Body:  {"token":"<他的华为 pushToken>","title":"…","body":"…","itemKey":"…"}
返回:  {"ok":true,"requestId":"…"}
```

`token` 由客户端自带（无常驻存储）；`itemKey` 用于同一条消息去重与堆叠。

## 用户侧怎么配

他自己机器上的 `tools/relay/config.json`：

```json
{
  "notify": {
    "pushToken": "<他自己 App 里复制出来的 pushToken>",
    "gateway": {
      "url": "https://<项目名>.vercel.app/api/push",
      "key": "<你发给他的 key>"
    },
    "quietHours": [23, 7]
  }
}
```

然后照旧：

```bash
python login_ig.py                 # 他自己的 IG 账号
node instamony.js --import-session settings.json
node instamony.js --check
node instamony.js                  # 常驻；通知经网关发到他手机
```

> 他**不需要** `tools/agc/private.json`，也不需要配 `notify.agc` —— 那是你的东西。

## 安全与运维

| 事项 | 做法 |
| --- | --- |
| key 泄露 | 从 `GATEWAY_KEYS` 里删掉那一个，Vercel 会自动重新部署 |
| 限流 | Vercel 免费档每月 100 万次函数调用；异常时可给每个 key 加配额（需自行改代码） |
| 私钥 | 只存在 Vercel 环境变量里；本地 `private.json` 已在 `.gitignore` |
| 日志 | Vercel 控制台能看到每次请求；本地版打在 stdout |
| 合规 | 通知 `category=IM`（你自己的自分类权益）；转发的都是用户自己的私信 |

## 已验证

本地起网关 + 客户端走网关模式，实测：

```
客户端 → 网关（无状态，自带 token）→ 华为 → 手机
已通过网关推送到手机（179319022448377800000106）
```
