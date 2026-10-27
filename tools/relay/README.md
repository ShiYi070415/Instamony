# Instamony BYO 中转（AGC 推送 / MeoW 推送）

在自己家里那台机器上低频轮询 IG 收件箱，有新私信就推到你手机。
**一台机器只跑一个账号** —— 原因见下面「为什么不能"一台服务器挂很多用户"」。

```
relay.py           单文件脚本（Python 3.8+，只用标准库，不需要 pip install）
config.example.json 配置模板
```

## 一、为什么要 BYO

- **IG 侧**：instagrapi 的[最佳实践](https://github.com/subzeroid/instagrapi/blob/master/docs/usage-guide/best-practices.md)
  明确写「一个账号一个固定 IP」是最稳的基线，并警告共享 IP 池要压低账号数与请求量；
  "sharing one noisy IP across many unrelated accounts" 被列为常见反模式。
  同一 IP 挂多个账号、请求又密，最可能的结果是**整片账号一起弹验证/被限流**。
- **凭据侧**：中转需要 `sessionid` 这类等同密码的材料。放在公共服务器上，被拖库就是集体丢号。
- **推送渠道侧**：MeoW 的[文档](https://www.chuckfang.com/MeoW/api_doc.html)写着
  「多个使用者共用同一 IP 向多个昵称发送推送时，可能被判定为攻击行为」，会直接 429 封 IP。

所以：**一个用户、一台自己的机器、自己的出口 IP、自己的推送目标**。

## 二、App 侧准备（一次性）

1. 手机装上 Instamony 并登录 IG；
2. 「设定 → 诊断 → **复制中转材料（会话 + 推送 token）**」——剪贴板里会得到一段 JSON：

```json
{
  "cookie": "csrftoken=…; sessionid=…; ds_user_id=…; mid=…; …",
  "pushToken": "…（AGC 推送 token，拿不到时是空串）",
  "signedIn": true
}
```

3. 把 `cookie` 填进 `config.json` 的 `ig.cookie`，`pushToken` 填进 `notify.pushToken`；
4. **粘好就清剪贴板**：这段东西等同账号密码；`sessionid` 换了要重新导出。

## 三、通知通道选一个

### A. AGC（HarmonyOS 原生通知，推荐）

需要你在 AppGallery Connect 里把应用登记好（这一步只能你操作）：

1. AGC 控制台 →「我的项目」→ 创建项目 → 添加应用，**包名必须与 App 一致**：
   `com.oneleaf.instamony`；
2. 「项目设置 → 常规 → 应用」里取得 **App ID**；「项目设置 → 常规 → API 密钥 / OAuth」
   里创建 **Client ID / Client Secret**（服务账号凭据）；
3. 「增长 → Push Kit」里**开启推送**；
4. 让应用拿到 token：用 AGC 的这个应用对应的**签名证书**重新打包安装（现在装的是调试证书，
   真机日志是 `push token unavailable (1000900010) Illegal application identity … clientid
   configuration`，就是"没登记/没配 client id"的意思）。装好后再点一次「复制中转材料」，
   `pushToken` 应该不为空。

配置里的三项对应关系：

```json
"notify": {
  "channel": "agc",
  "agc": { "appId": "<App ID>", "clientId": "<Client ID>", "clientSecret": "<Client Secret>" }
}
```

脚本做的事：用 `client_credentials` 换 access token →
`POST https://push-api.cloud.huawei.com/v1/{appId}/messages:send`，
带 `notification`（标题/正文）与 `data`（里面放 `threadId`，供以后点通知直达会话）。

### B. MeoW（零配置，但通知是 MeoW App 弹的）

1. 手机装 MeoW 并注册昵称；
2. 先在手机的移动流量下打开 `https://api.chuckfang.com/<昵称>/test/hello` 试一下：
   返回 `{"status":200,…}` 说明通；`{"status":404,…}` 说明昵称没注册；`429` 说明这个 IP 被限。
3. 配置：

```json
"notify": { "channel": "meow", "meow": { "nickname": "<昵称>" } }
```

限速：非会员 3 秒 1 条 / 每分钟 15 条 / 每小时 60 条 / 每天 1000 条；私信场景够用。

## 四、跑起来

```bash
cp config.example.json config.json     # 填好 cookie / token / AGC 或 MeoW
python relay.py --config config.json    # 前台跑，Ctrl+C 停
python relay.py --config config.json --once   # 只跑一轮，验证配置
```

- 默认 **90 秒一轮**（最低 60），每轮 ±15% 随机抖动 —— 模仿"人打开 App 看一眼"的节奏；
- 只调 `direct_v2/inbox` 这一条只读接口，不发消息、不点赞、不关注；
- `state.json` 只存"每个会话最后一条消息 id + 时间戳"，**不存聊天正文**；
- 第一次跑只记账不推送（否则会把历史消息全弹一遍）。

### Windows 常开（任务计划程序）

```powershell
# 每天开机自启，隐藏窗口
schtasks /create /tn InstamonyRelay /tr "pythonw.exe C:\relay\relay.py --config C:\relay\config.json" /sc onlogon /rl highest
```

### Linux / 小主机常开（systemd）

```ini
# /etc/systemd/system/instamony-relay.service
[Unit]
Description=Instamony BYO relay
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/relay/relay.py --config /opt/relay/config.json
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now instamony-relay
```

## 五、出问题怎么查

| 现象 | 含义 | 处理 |
|---|---|---|
| 启动就报「配置里没有有效的 cookie」 | 没填 / 填成了别的东西 | 重新在 App 里「复制中转材料」 |
| `IG 拒绝：会话失效` | `sessionid` 过期或被 IG 踢了 | 在 App 里重新登录，再导出一次 |
| `IG HTTP 429` | 这个出口 IP 被限流 | 停 10~30 分钟；把 `pollSeconds` 调到 120 以上 |
| `AGC 取 token 失败` | Client ID/Secret 不对，或服务没开 | 回 AGC 检查「Push Kit 是否开启」「凭据是不是这个应用的」 |
| `AGC 推送已发` 但手机没弹 | token 不匹配 / 通知权限关了 | 重新「复制中转材料」确认 `pushToken` 变了；检查系统通知权限 |
| MeoW 返回 429 | IP 被判成攻击 | 换出口 IP，或按文档联系开发者加白名单 |

## 六、安全底线

- `config.json`、`state.json` 只放在**自己的机器**上，别提交到 git（本目录已加 `.gitignore`）；
- 不要把这个脚本公开成"代挂服务"：那是替别人保管 IG 凭据，风险与责任都落在运营者身上；
- 轮询间隔别低于 60 秒；一天 24 小时连续跑本身就已经比正常用户密集，出现验证就先停一天。
