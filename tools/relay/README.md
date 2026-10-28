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

**先记住这条，能省掉几个小时**：HarmonyOS 5+ 的 Push Kit **只认服务账号 JWT + v3 接口**，
`client_credentials` 换 access_token 那套（v1/v2 接口）已经废弃，会回
`{"error":1101,"sub_error":20003}`。详见 `docs/PUSH_SERVER.md`。

需要你在 AppGallery Connect 里做的（只能你操作）：

1. 应用已通过 **AppGallery 正式签名**分发（邀测也行）。侧载的 debug 包永远拿不到 token：
   `push token unavailable (1000900010) Illegal application identity`，跟配置无关，修不了；
2. 「增长 → 推送服务 → 配置」里**开启推送**；
3. **申请通知消息自分类权益**，只勾 `IM`（即时聊天）。不申请的话所有通知被算成
   「资讯营销类」→ 静默、只在通知中心、**每天每设备限 2 条**；通过后要在页面点「激活功能」；
4. 到 **API Console**（https://developer.huawei.com/consumer/cn/console/api/myApi）
   → 选项目 → 创建「**服务账号密钥**」凭证 → 下载**推送服务 API** 的 json，
   存成 `tools/agc/private.json`（relay 默认就去这儿找，不用配路径）；
5. 让应用拿到 token：装好 AppGallery 包后再点一次「复制中转材料」，`pushToken` 应该不为空。

配置：

```json
"notify": {
  "channel": "agc",
  "agc": {
    "serviceAccountFile": "../agc/private.json",
    "category": "IM",
    "testMessage": true
  },
  "pushToken": "<App 里复制出来的 pushToken>"
}
```

- `serviceAccountFile` 不给就用默认的 `tools/agc/private.json`；
- `project_id` 从密钥文件里读，**不用手填**（也别填成 App ID / OAuth Client ID）；
- `testMessage: true` 走测试通道：单项目每天 1000 条、每次 ≤10 个 token，调通阶段用它。

脚本做的事：用密钥文件的私钥签 PS256 JWT（一小时一签，进程内缓存）→
`POST https://push-api.cloud.huawei.com/v3/{projectId}/messages:send`，
带 `push-type: 0` 头和 `category`；`threadId` 放在 `clickAction.data` 里，供以后点通知直达会话。

### 合规过滤（用 AGC 通道时必看）

我们申请的分类是 `IM`，官方对它的硬性承诺是**只包含互相关注用户之间的点对点私信**，
明确排除未关注人的私信请求、官方号/商家批量推送、广告。违者按《通知违规处罚标准》处理。

所以 relay 在推送前会过一道 `complianceVerdict()`：

| 判据 | 跳过原因 | 说明 |
| --- | --- | --- |
| `is_pending` / `pending` / `approval_factor` | `message-request` | Instagram 的陌生人首条私信 |
| 收件箱只回了 1 条消息 | `no-history` | `thread_message_limit=2`，只有 1 条说明这是该会话第一条 |

跳过时**照常记账**（写 state），所以这条会话以后真成了正常往来仍能正常推送。
日志里会打 `合规过滤跳过 N 条（…）`，跳了谁、为什么跳，一眼能看见。
自测：`node filter-test.js`（不碰网络、不要 cookie）。

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
node relay.js                          # 前台常驻，Ctrl+C 停
node relay.js --once                   # 只跑一轮，验证配置
node relay.js --test-push "通道自检"    # 只验通知通道：不看 IG、不占锁、不写 state
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
| `找不到服务账号密钥文件` | 没下 `private.json` | AGC → API Console → 创建「服务账号密钥」→ 下载推送服务 API 的 json |
| `AGC 推送失败` + HTTP 401/403 | 服务账号 JWT 不对（alg/aud/key_id/project_id） | 用 `node ../agc/agc.js --whoami` 核对密钥文件；注意接口必须是 v3 |
| `AGC 推送失败` + token 相关错误码 | pushToken 失效（重装/清数据/HMS 更新） | 回 App 重新「复制中转材料」，换掉 `notify.pushToken` |
| `AGC 推送成功` 但手机没弹 | 通知权限关了 / 忘了点「激活功能」 | 检查系统通知权限；没激活的话消息会被降级成静默的营销类 |
| `合规过滤跳过 …` | 消息请求或没有历史往来 | 正常行为，不是故障（见上文「合规过滤」） |
| MeoW 返回 429 | IP 被判成攻击 | 换出口 IP，或按文档联系开发者加白名单 |

## 六、安全底线

- `config.json`、`state.json` 只放在**自己的机器**上，别提交到 git（本目录已加 `.gitignore`）；
- 不要把这个脚本公开成"代挂服务"：那是替别人保管 IG 凭据，风险与责任都落在运营者身上；
- 轮询间隔别低于 60 秒；一天 24 小时连续跑本身就已经比正常用户密集，出现验证就先停一天。

## 七、跨平台 / 低功耗（Windows · Linux · Android）

同一个 `relay.js`，只要 Node ≥ 14，三个平台都不用改代码。**低功耗设计**：

| 手段 | 作用 |
|---|---|
| keepAlive 连接复用 | 每轮不再重新 TLS 握手（长轮询里最费电的一步），实测能省掉绝大部分唤醒开销 |
| `Accept-Encoding: gzip` | 收件箱几十 KB 压到几 KB，无线电唤醒时间更短 |
| 自适应间隔 | 有动静 90 秒一轮；一直安静逐步退到 `idleMaxSeconds`（默认 300 秒） |
| 一轮一批 | 同轮多条新私信只推一条汇总，手机少被连续唤醒 |
| quietHours | 例如 `[23, 7]` 夜里只记账不推送，也不会攒着早上一起弹 |
| 脏写才落盘 | state 只在真的变了才写（tmp + rename 原子替换），避免每分钟一次磁盘写 |
| 单实例锁 | `.relay.lock` 里记 pid，重复启动会直接退出（不会两份在跑互相抢） |

### Windows（你现在的机器）

```powershell
# 前台跑（先验配置）
node tools\relay\relay.js --once
node tools\relay\relay.js

# 常驻、不弹窗：开机自启（pythonw 换成 node 的等价物是 wscript 包一层，最省事的是用计划任务隐藏窗口）
schtasks /create /tn InstamonyRelay /tr "node C:\HMStudy\Instamony\tools\relay\relay.js --quiet" /sc onlogon /rl highest /f
```
> 想彻底无窗口：把命令写成 `relay.vbs`（`CreateObject("WScript.Shell").Run "...node ...", 0, False`）交给计划任务。

### Linux（小主机 / NAS / 树莓派）

```ini
# /etc/systemd/system/instamony-relay.service
[Unit]
Description=Instamony BYO relay
After=network-online.target

[Service]
ExecStart=/usr/bin/node /opt/relay/relay.js --quiet
Restart=always
RestartSec=30
Nice=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now instamony-relay
journalctl -u instamony-relay -f      # 看日志
```

`Nice=10` 让它在 CPU 上和别的服务抢的时候主动让步，进一步降低对整机的影响。

### Android（Termux）

```bash
pkg update && pkg install nodejs termux-api
termux-wake-lock            # 关键：不加这个，系统 doze 会掐掉定时器
mkdir -p ~/relay && cd ~/relay
# 把 relay.js 与 config.json 放进来（可以从电脑 scp / 用 termux 的剪贴板粘）
node relay.js --once        # 先验
node relay.js --quiet &     # 后台跑
termux-wake-unlock          # 要停的时候
```

Android 上的省电建议：Termux 加进电池优化白名单（设置 → 应用 → Termux → 电池 → 不受限制），配置里把
`pollSeconds` 放到 120~180、`idleMaxSeconds` 放到 600 —— 手机息屏时 Doze 会合并唤醒，间隔太短反而更耗电。

### 一天的代价（估算）

`pollSeconds=90`、白天约 16 小时活跃：约 640 次请求/天，gzip 后每次几 KB → **每天约几 MB 流量**；
CPU 只在解析那几毫秒用一下；夜间退到 300 秒后约 96 次/天。真正耗电的是网络唤醒，不是脚本本身。
