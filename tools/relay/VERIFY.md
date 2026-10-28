# CAA 登录移植：验收清单（更新于 R12 真机验证后）

目标：把 IG 的 CAA（Bloks）密码登录移植成 JS（替代 `login_ig.py` 的 Python 依赖），
产出与 instagrapi `settings.json` 等价的会话；再移植进 App，使 App 内可直接密码登录（含 2FA）
拿到设备级会话，从而启用实时私信与本地通知。

**状态：JS 侧已在真实账号上跑通（含 TOTP 两步验证），拿到设备级会话；
App 侧同一套逻辑已移植并编译通过，待真机确认。**

---

## 〇、真实账号验证结果（R12，决定性证据）

真机第四次运行（账号 `_yijin.__`，TOTP）：
`attestation/aac/oauth/send_login_request` 全 200 →
`2sv_entrypoint / 2sv_method_picker / 2sv_select_method / 2sv_verify_code` **全 200 且有载荷**，
验证码被接受。随后用那份响应 `--caa-replay` 重建会话并 `--verify-session`：

```
② HTTP 200 —— 会话有效（@_yijin.__）
③ sessionid 一致，authorization 一致，账号 一致
④ push/register/ HTTP 200 {"status":"ok"} —— 设备信任通过
结论：会话是设备级的
```

即：**CAA 密码登录 + TOTP 2FA → 设备级会话**这条链路已被真实账号验证。

途中修掉的四个真 bug（都由真机数据发现，均已加回归测试）：
1. 2FA entrypoint 的 app id 少 `_async`；
2. 2FA 票据抓错（13 字符 vs 真实 2234 字符）——改为**照布局里给的调用规范**；
3. Cookie 串按 `\r\n` 分行（旧实现把 `Secure\r\nSet-Cookie: ds_user_id` 当 Cookie 名）；
4. 载荷被日志文本 `[trait:called_handle_login_response]` 挡住（旧实现从第一个
   `login_response` 往回扫，永远扫不到后面的真载荷）。

---

## 一、已完成并**实测**验证的（可复现）

| # | 项目 | 证据 | 复现命令 |
| --- | --- | --- | --- |
| 1 | JS 移植的**密码之前**整条链（USDID 注册 → attestation → aac → 密码公钥）对真服务器全通 | attestation 200、`process_client_data` 200（aac 303 字符）、`qe/sync` keyId=181 + 公钥 604 字符 | `node instamony.js --caa-preflight` |
| 2 | 登录响应解析（`login_response` → cookie + authorization + mid/rur/claim） | 23 项离线断言，含两层 JSON 编码、转义引号、Cookie 属性剔除 | `node test-caa-parse.js` |
| 3 | 密码加密可被 IG 的格式解开（RSA-PKCS1 + AES-256-GCM，AAD=时间戳） | 本地 RSA-2048 加密后按 IG 结构解回明文（含非 ASCII），字节布局逐字节对齐 | 同上（① 组） |
| 4 | CAA 结果 ⇄ instagrapi `settings.json` **逐字段等价** | 同一解析路径读回后 sessionid / authorization / 账号 / mid 全一致 | 同上（③ 组），另见第 6 项 |
| 5 | App 的「解析自检」四项断言 | 与离线测试第⑤组用**同一批 fixture**，23/23 通过（手机上是同一套解析器） | `node test-caa-parse.js` |
| 6 | 与 instagrapi `settings.json` 的导入兼容 | 真实 settings.json：账号 / sessionid 78 字符 / authorization 已有 / mid / app_version | `node instamony.js --import-check settings.json` |
| 7 | 会话是**设备级**的（网页会话过不了这道闸） | 探活 200、等价一致、`push/register/` 回 `{"status":"ok"}` | `node instamony.js --verify-session` |
| 8 | ArkTS 移植字段齐全 | 五个请求体（networkInfo / 取 aac / oauth / send_login_request / 2SV）键集合一致；请求头仅 `Connection` 有意不发 | `node audit-arkts-parity.js` |
| 9 | App 侧链路接线 | 登录/导入 → Cookie 罐 → `MobileSession` → Worker 实时通道 → `DirectRealtime` → `DirectViewModel` → `PushCenter.notifyDirect`（本地通知）；同账号换会话来源后会重启实时通道 | 代码 + 编译通过 |

## 二、还差的一步（只能由用户完成）

| 项目 | 怎么做 | 预期 |
| --- | --- | --- |
| **真机登录（App）** | 登录页 →「App 协议登录（实验）」→ 先「解析自检」(应 `6/6`) → 再「设备/网络前检」 → 填账号密码 → 输验证码 | 状态行走到 `2sv_verify_code 200`，壳切进主界面 |
| **真机实时** | 面板「用已有会话导入」粘 `settings.caa.json`（或先完成上一步） | 私信页实时刷新；来消息弹出本地通知（标题=用户名、正文=内容） |

> 命令行那份已经验证过了；App 侧是**同一套逻辑的移植**（含 2FA 两条链、spec 解析、
> Cookie 与载荷解析修复），但只有真机才能确认 ArkUI/网络栈层面没问题。

### App 侧为这次真机测试补的保险（R13–R15）

| 项 | 作用 |
| --- | --- |
| `test-arkts-parsers.js` | **把 App 的 ArkTS 源码直接摘出来在 Node 里跑**（真数据，10 项）：解析、2FA 参数拼装，以及 `CaaLogin.ets → CaaSession.ets` 接力（response → sessionid/ds_user_id/authorization），与 JS 版**完全一致** |
| `--caa-replay <dump>` | 从落盘响应重建会话，不必为解析 bug 再登录一次（桌面已用它救回过一次成功登录） |
| 交验证码走对链（`CaaPending.context`） | 修掉"手机上输完码报没有待提交验证码" |
| 解析自检 6 项（含 Cookie `\r\n`、日志文本挡路、2FA 规范） | 手机上点一下就能判定解析器好坏，自检 fixture 与 JS 测试逐字镜像 |
| 2FA 每跳双域名回退（`bloksAppBestHost` / `bloksBestHost`） | 私有域名空载荷时自动改打 CAA 域名 |
| 步骤里记域名（`2sv_entrypoint@i.instagram.com`…） | 失败时一眼看出哪一步打到了哪个域名 |
| 「复制最近一次响应（失败时才有）」 | 真机无 hdc 时唯一的现场；失败响应不含可用会话材料 |

失败时请点 App 里的「**复制登录诊断**」+（解析类失败）「**复制最近一次响应**」——里面只有结论、
步骤和字段的**名字**，不含会话值。`LOGIN.md` 有「状态行 → 含义 → 下一步」自诊表。

## 三、设计上刻意做的几个决定（避免以后重复踩）

1. **两边同源**：JS 与 ArkTS 的解析器必须同时改；`audit-arkts-parity.js` 就是防"只改一边"。
2. **登录响应头里的会话材料不许丢**：`ig-set-x-mid` / `ig-set-ig-u-rur` / `x-ig-set-www-claim`
   会写进身份，否则登录成功之后的请求像"没有机器 id 的客户端"。
3. **"解析出结果"≠"会话可用"**：缺 `sessionid`/`ds_user_id` 时**不覆盖**现有会话（relay 侧 exit 4）。
4. **会话双向搬运**，两端形状统一到 instagrapi settings：电脑 → 手机（粘贴导入）、手机 → 电脑
   （复制当前会话 → `--import-session`）。
5. **2FA 现场留在内存**（`CaaPending`）：第一段布局里的 `context_data` 与请求头都要复用，
   否则只能重跑整条链、多一次登录尝试。
6. **`qe/sync` 的 405 是预期的**（IG 对 GET 固定回 405，公钥头照常下发）。

## 四、一条命令跑完全部离线检查

```powershell
cd tools/relay
node test-caa-parse.js && node audit-arkts-parity.js
```
