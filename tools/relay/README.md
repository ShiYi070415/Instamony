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

```powershell
pip install instagrapi          # 只需一次
python login_ig.py              # 输用户名 / 密码（不回显）/ 2FA 码
```

成功会打印 `OK <账号id>`，并生成 `settings.json`。

### 2. 导入会话 + 设备身份

```powershell
node instamony.js --import-session settings.json
```

它会写两份文件（都已在 `.gitignore` 里）：

| 文件 | 内容 |
| --- | --- |
| `session.json` | 会话（cookie + `Bearer IGT:2`） |
| `mqtt-device.json` | 设备三件套（phoneId / uuid / androidId） |

### 3. 配置推送

```powershell
copy config.example.json config.json
```

填两处：

- `notify.pushToken`：手机 App「设定 → 诊断 → 复制中转材料」里的 `pushToken`；
- `notify.agc.serviceAccountFile`：华为服务账号密钥（AGC → API Console →
  服务账号密钥 → 下载「推送服务 API」的 json，默认放在 `tools/agc/private.json`）。

---

## 二、跑起来

```powershell
node instamony.js --check          # 先看会话 / 设备 / 密钥 / token 齐不齐
node instamony.js --test-push 自检  # 只测"发"这一半（手机上应弹一条）
node instamony.js                  # 常驻：连 FBNS → 自动注册 → 收私信即推
```

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
| 登录 | 交给 instagrapi（Bloks CAA 流程，IG 会随时改，别自己重写） |
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
| `缺少有效会话` | 先跑第 1、2 步（`python login_ig.py` → `--import-session`） |
| `没拿到 push token` | FBNS 引导失败；删掉 `fbns-auth.json` 再启动一次 |
| `push token 注册失败` | 会话可能过期：重跑 `python login_ig.py` 并重新导入 |
| 手机收不到 | `node instamony.js --test-push x` 若成功，说明是 IG 推送没到（检查会话）；若失败，看报错里的 HTTP/code |
| 想临时关掉静音 | 把 `config.json` 的 `quietHours` 删掉 |
| App 重装后 token 变了 | 重新「复制中转材料」，更新 `notify.pushToken` |

## 五、安全

`session.json` / `settings.json` / `fbns-auth.json` / `mqtt-device.json` 都是
**等同密码**的东西，全部已在 `.gitignore` 里，别提交、别外传。
本脚本只做只读的收私信 + 发通知，不发消息、不点赞、不关注。
