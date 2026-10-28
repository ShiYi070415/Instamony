# CAA 登录移植：验收清单（截至 R12）

目标：把 IG 的 CAA（Bloks）密码登录移植成 JS（替代 `login_ig.py` 的 Python 依赖），
产出与 instagrapi `settings.json` 等价的会话；再移植进 App，使 App 内可直接密码登录（含 2FA）
拿到设备级会话，从而启用实时私信与本地通知。

**当前状态：代码全部就绪并逐项验过；缺最后一步——用真实账号跑一次登录（密码只在用户手上，
且失败登录本身是风控信号，不能让 AI 代试）。**

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
| **真实账号登录（JS）** | `node instamony.js --caa-login`（2FA 会当场提示） → `node instamony.js --verify-session` | 输出 `usdid/attestation/aac/oauth/send_login_request` 均 200，且 `--verify-session` 四步全绿 |
| **真机登录（App）** | 登录页 →「App 协议登录（实验）」→ 先「解析自检」(`4/4`) → 再「设备/网络前检」 → 填账号密码 | 状态行走到 `send_login_request 200`，壳切进主界面 |
| **真机实时** | 「用已有会话导入」粘 `settings.caa.json`（或先完成上一步） | 私信页实时刷新；来消息弹出本地通知（标题=用户名、正文=内容） |

失败时请点 App 里的「**复制登录诊断**」——里面只有结论、步骤和各字段的**名字**，不含任何会话值。

`LOGIN.md` 有「状态行 → 含义 → 下一步」自诊表；错误文案是 IG 原话（例如 `Can't find account`、
`The password you entered isn't correct`、`Please wait a few minutes`）。

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
