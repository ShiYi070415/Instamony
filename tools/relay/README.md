# Instamony 中转（FBNS 实时推送版）

手机上的 Instamony 被系统杀掉之后收不到新私信。这个脚本常驻在你自己的机器上，
借 **IG 的 FBNS 推送通道**收私信，再用 **华为 Push Kit** 推到手机。

**不轮询**：IG 主动推过来，载荷里直接带消息正文，收到即推（实测亚秒级）。

```
IG ──FBNS 推送──▶ 本脚本 ──华为 Push Kit──▶ 手机通知
```

---

## 一、一次性准备（三步）

### 1. 登录（拿"真机登录过"的会话）

> ⚠️ 这一步是硬门槛。网页 Cookie 派生的会话**进不了** IG 的 FBNS，
> 必须是真机登录产生的会话。IG 已停用旧的密码登录接口，现在能登录的是
> Bloks CAA 流程 —— 由 instagrapi 维护，所以借它登录一次（细节见 [LOGIN.md](LOGIN.md)）。

**两条路，选一条：**

| 路 | 命令 | 依赖 |
| --- | --- | --- |
| **纯 Node（推荐）** | `node instamony.js --caa-login` | 只要 Node |
| Python | `python login_ig.py` → `node instamony.js --import-session settings.json` | Python + instagrapi |

`--caa-login` 成功后除了写 `session.json`，还会写一份**instagrapi 形状**的
`settings.caa.json`，并当场用 `--import-session` 的解析器读回来比对 —— 两条路产出的
会话是等价的，任选一条即可。

设备档案（phoneId / uuid / androidId / mid / 版本号）会落到 `device-profile.json` 并在
后续运行里复用：同一台机器始终是同一台"手机"（每次换新设备会被 IG 当陌生设备，更容易要验证码）。

> 自测/自动化可以用环境变量免交互：`INSTAMONY_IG_USER` / `INSTAMONY_IG_PASS`
> （密码不落盘、不打印；日常还是用交互输入）。

### 1.4 前检（不需要账号密码，随时可跑）

```powershell
node instamony.js --caa-preflight
```

跑密码之前那半条链并逐项汇报：USDID 注册 → attestation（`challenge_nonce`）→ 取 aac
→ `qe/sync` 的密码加密公钥。这几项**与账号无关**，所以能先把"设备/网络这侧通不通"与
"账号对不对"分开：前检绿、登录挂 → 问题在账号（密码/2FA），不用再怀疑协议或网络。

> `qe/sync` 那行会显示 `HTTP 405`，**这是预期的**：IG 对 `GET /api/v1/qe/sync/` 固定回 405，
> 但公钥头照常下发（instagrapi 也走 GET，同一条路）。

### 1.5 会话自证（建议每次登录后跑一次）

```powershell
node instamony.js --verify-session
```

四件事一次验完：会话形状 → `accounts/current_user/` 探活 → 与 instagrapi settings 的等价性 →
**设备信任闸门**（FBNS 申请 token 后 `push/register/` 是否回 `{"status":"ok"}`）。
闸门不过就说明会话来源不对（网页 Cookie），常驻进程收不到推送。

### 1.6 离线自检（不需要账号、不需要网络）

```powershell
node test-caa-parse.js          # 23 项：加密可逆 / 布局解析 / Cookie / 会话等价 / USDID / App 自检镜像
node audit-arkts-parity.js      # ArkTS 移植与 JS 的字段、请求头差异（改一边后跑它）
node test-arkts-parsers.js      # **把 App 的 ArkTS 解析/落地源码摘出来直跑真数据**（10 项）
```

`test-caa-parse.js` 覆盖：密码加密能被 IG 的格式解开（RSA + AES-GCM 可逆）、Bloks 布局解析
（aac / 错误文案 / `login_response` → cookie + authorization / 两步验证上下文）、
Cookie 串解析（对齐 Python `SimpleCookie`）、CAA 结果 ⇄ settings.json 的**逐字段等价**、
USDID 令牌形状。改解析器前后都该跑一次 —— 它已经抓出过两个真 bug（见 LOGIN.md）。

`audit-arkts-parity.js` 比的是 App 里那份 ArkTS 实现（`CaaLogin.ets`）：**「只在 JS 里有」
就是 ArkTS 少发了字段**（IG 会因此换判据），请求头一组只作提示（ArkTS 有意不发
`Accept-Encoding` / `Host` / `Connection`）。当前结论：五个请求体字段齐全。

`test-caa-parse.js` 的第⑤组是 **App「解析自检」的镜像**：真机上那个按钮跑的四项断言，
这里用**同一批 fixture** 再跑一遍。自检若在手机上误报失败，会把整个真机测试带偏 ——
所以这一段是必测的（★ 改自检 fixture 时两处要一起改）。

### 1.7 从已保存的响应重建会话（`--caa-replay`）

```powershell
node instamony.js --caa-replay .tmp\caa-last-response.json
```

登录失败时响应会自动落盘（`.tmp/`）。修好解析之后用这条命令重放，就能把那次登录**已经拿到**
的会话写出来 —— 不必为了一个解析 bug 再登录一次（R12 真机就是这么救回来的）。

### 1.8 退出登录 / 清除所有会话（`--clear`）

```powershell
node instamony.js --clear              # 演练：只列出会删什么，不动文件
node instamony.js --clear --yes        # 真删（会话）
node instamony.js --clear --yes --all  # 连设备身份一起删
```

这台机器上的"登录态"散在十来处，手动删很容易漏 —— 漏一个就等于没退出登录：

| 文件 | 内容 |
| --- | --- |
| `session.json` | 中转会话（cookie + `Bearer IGT:2` + mid） |
| `settings.json` / `settings.caa.json` | 两份 instagrapi 形状的会话 |
| `fbns-auth.json` | FBNS 设备凭据（不清会被"复活"成旧账号的连接） |
| `token.json` | 华为 push token 缓存 |
| `.tmp/caa-last-response.json` 等 | 失败响应转储（可能含 `set-cookie`） |
| `.tmp/ratelimit.json` | 429 冷却标记（不清会拦住下一次登录 10 分钟） |
| `.tmp/session.json.bak` / `.keep` | 会话备份 |
| `.login-profile/` | playwright 浏览器档案（里面是 IG 网页会话） |

`--all` 额外删这些**设备身份**（换账号**不需要**；只有"想换一台设备"才要）：
`mqtt-device.json`、`device-profile.json`、`usdid.json`。清完下次登录在 IG 眼里就是一台
全新机器 —— 更容易触发风控，登录尝试次数也重新算。

别名：`--logout` / `--sign-out`。**不带 `--yes` 永远只演练**（删除是真删，不进回收站）。
常驻中转还在跑时会先警告 —— 它内存里的旧会话不会因为删文件而失效，先停掉它再清。

### 2. 导入会话 + 设备身份

```powershell
node instamony.js --import-session settings.json
```

> 先想确认"这份文件能不能被吃下"、又不覆盖现有会话时，用 `--import-check <文件>`：
> 只解析并打印账号 / sessionid 长度 / authorization / mid / app_version，不落盘。

它会写两份文件（都已在 `.gitignore` 里）：

| 文件 | 内容 |
| --- | --- |
| `session.json` | 会话（cookie + `Bearer IGT:2`） |
| `mqtt-device.json` | 设备三件套（phoneId / uuid / androidId） |

**会话可以从手机上搬过来**：App 的「App 协议登录（实验）」面板里有
「**复制当前会话（给电脑上的中转用）**」，产出的是 instagrapi settings 形状的 JSON。
把它存成文件（比如 `phone.json`），`--import-session phone.json` 即可 —— 手机登录一次，
电脑不用再登。

### 3. 配置推送

```powershell
copy config.example.json config.json
```

填两处：

- `notify.pushToken`：手机 App「设定 → 诊断 → 复制中转材料」里的 `pushToken`；
- `notify.agc.serviceAccountFile`：华为服务账号密钥（AGC → API Console →
  服务账号密钥 → 下载「推送服务 API」的 json，默认放在 `tools/agc/private.json`）。

> **默认全天都推**。想夜里静音再自己加一个键（可选，不写就是不静音）：
>
> ```json
> "quietHours": [23, 7]
> ```
>
> 含义：本地时间 23:00–07:00 之间**不发**推送 —— 这条私信只记一行日志
> （`安静时段：只记账不弹`），**不排队、不补发**，7 点之后也不会补。改成 `[2, 7]`
> 就是只静音凌晨。要临时关掉：把这个键删了、重启中转。

---

## 二、跑起来

```powershell
node instamony.js --check          # 先看会话 / 设备 / 密钥 / token 齐不齐
node instamony.js --test-push 自检  # 只测"发"这一半（手机上应弹一条）
node instamony.js                  # 常驻：连 FBNS → 自动注册 → 收私信即推
```

> **登录已经接进常驻流程**：`node instamony.js` 启动时会先探一次会话
> （`accounts/current_user/`）——
> · 会话可用 → 直接开跑，不打扰；
> · **没有会话 / 会话已失效** → 就地引导登录（CAA，含两步验证），登录完继续启动，
>   不用再单独跑一次 `--caa-login`；
> · 后台运行（不是交互终端）又没有环境变量 → 打印明确命令提示后退出，不会卡在没人应答的输入上。
>
> 运行中若 `push/register/` 被判失败、且探活确认会话已失效：设了
> `INSTAMONY_IG_USER` / `INSTAMONY_IG_PASS` 就会**自动重登并重连 FBNS**；没设则只提示
> （后台进程里不擅自弹交互输入）。

常驻时的正常日志：

```
启动 FBNS 实时通道（只走推送，不轮询）
FBNS 已连上，申请 push token
push token 注册成功 —— 之后新私信由 IG 主动推过来
就绪：手机被杀了也能收到新私信通知（Ctrl+C 停）
```

来一条私信：

```
即时推送：<发信人用户名> —— <消息正文>
已推送到手机（<requestId>）
```

## 三、它做了什么

| 环节 | 说明 |
| --- | --- |
| 登录 | `--caa-login` 是 Node 版 CAA/Bloks 实现（搬运自 instagrapi 3.2.2 的实际行为）；也可以继续用 `login_ig.py` |
| 设备注册 | FBNS 两段式：空 userId 引导拿 `ck/cs/di/ds` → 用凭据重连 → 申请 push token → `push/register/` 注册给 IG |
| 收 | topic 76 的 `fbpushnotif`：`m` 正文 / `t_id` 会话 / `s` 发信人 / `n` 消息 id |
| 发 | 华为 Push Kit v3（服务账号 JWT），`category=IM`（锁屏+铃声+振动） |
| 标题 | 用发信人**用户名**（按 `s` 查 `users/{id}/info/`，带缓存） |
| 去重 | 按消息 id；同一条只推一次 |
| 静音 | `notify.quietHours` 内只记账不弹 |
| 单实例 | 本地端口 47999 占位，防两个实例各推一遍 |
| 断线 | 30 秒自动重连 |

## 四、常见问题

| 现象 | 处理 |
| --- | --- |
| `缺少有效会话` | 先跑第 1、2 步（`--caa-login`，或 `python login_ig.py` → `--import-session`） |
| 登录"成功"但手机不响 | 跑 `--verify-session`：闸门不过 = 会话来源不对（网页 Cookie），换 `--caa-login` 重登 |
| `--caa-login` 只看到提示符就退出 | 旧版的管道读取 bug（多行一起送来、第二行等不到），已修；若还复现，用 `INSTAMONY_IG_USER` / `INSTAMONY_IG_PASS` 跑 |
| `没拿到 push token` | FBNS 引导失败；删掉 `fbns-auth.json` 再启动一次 |
| `push token 注册失败` | 会话可能过期：重跑 `python login_ig.py` 并重新导入 |
| 手机收不到 | `node instamony.js --test-push x` 若成功，说明是 IG 推送没到（检查会话）；若失败，看报错里的 HTTP/code |
| 想临时关掉静音 | 把 `config.json` 的 `quietHours` 删掉 |
| `--caa-login` 提示"被 IG 限流（429）" | 别硬试：等 10~30 分钟。本地 10 分钟冷却记在 `.tmp/ratelimit.json`（`--clear` 会清）；确实要硬试加 `--force` |
| 换账号 / 怀疑串号 | `node instamony.js --clear --yes`，然后重新 `--caa-login` |
| App 重装后 token 变了 | 重新「复制中转材料」，更新 `notify.pushToken` |

## 五、安全

`session.json` / `settings.json` / `settings.caa.json` / `fbns-auth.json` / `mqtt-device.json`
都是**等同密码**的东西，全部已在 `.gitignore` 里，别提交、别外传。
`device-profile.json`（本机设备档案）也一并忽略：它不是会话，但换掉就等于换了一台设备。
用完/换账号就 `node instamony.js --clear --yes` 清干净（见 1.8），别留在机器上。
本脚本只做只读的收私信 + 发通知，不发消息、不点赞、不关注。
