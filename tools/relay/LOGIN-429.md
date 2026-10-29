# App 内账密登录一直 429 —— 排查记录（2026-10-29）

> 结论先说：**不是账号、不是 IP、不是设备身份、不是请求内容、不是 HTTP 框架**。
> 桌面链路（`tools/relay`，Node）发同一份字节是 **200**；手机 App 发同一份字节是 **429**，
> 而且换传输实现（`http` / `rcp`）、换 TLS 参数都还是 429。
> 也就是说：IG 的 edge 在**登录这一个端点**上按"客户端/连接特征"挡手机，而不是按请求内容挡。

## 一、症状（真机现场）

界面上那行 + `preferences/instarmony_caa` 的 `last_raw`：

```
usdid 200 → attestation 200 (nonce ok) → process_client_data 200 (aac 303)
→ oauth_token_fetch 200 → send_login_request 429 (cookie=; csrf=no)

429 响应头：content-length: 0, content-type: text/plain,
           proxy-status: http_request_error(×2), server: proxygen-bolt,
           x-fb-server-cluster-forwarded: hkg1c01,
           x-fb-client-ip-forwarded: 119.247.85.205
```

`proxy-status: http_request_error` 是 Meta 代理层"这一发没能正常完成"的说法（两次尝试都失败）。

## 二、已排除的项（都是实测）

| 假设 | 怎么验的 | 结果 |
| --- | --- | --- |
| 这个账号被限流 | App 里「假账号探针」（`instarmony_probe_<ts>`） | 同样 429 ⇒ 与账号无关 |
| 出口 IP 被挡 | PC 与手机同一公网 IP（119.247.85.205）、同解析 IP（57.145.12.34） | PC 同 IP 发同一发 = 200 |
| 设备身份（uuid/phoneId/androidId/mid/usdid） | 把 App 那一整套装到 Node 链路上发 | 200 |
| UA（含 `Android (12/12)` 这种非法 API level） | 把 App 的 UA 装到 Node 上 | 200 |
| 请求头取值（locale=zh_Hans / bandwidth 随机大数 / Priority / IG-INTENDED-USER-ID / Accept-Language） | 逐组加进 Node 那发 | 全 200 |
| 请求体 | App 自己 dump 的 body 与 JS 的 body **逐键比对** | 一致（只有随机 textInputId 不同） |
| `X-IG-Attest-Params` | Node 上删掉/置空/乱码/错 nonce | 200 / 500，没有 429 |
| `X-Meta-Usdid` | Node 上篡改签名 / 删掉 | 200 |
| HTTP 框架细节 | 手写 TLS socket 重放：单/双 Content-Length、chunked、头名全小写、HTTP/2 | 全 200 |
| 请求体被截断 | 手写 TLS：截到 4096 / 只发 4096 | 404 / timeout，不是 429 |
| 鸿蒙 `http` 模块本身 | App 内「换传输重发（rcp）」：同一份字节换 `@kit.RemoteCommunicationKit` | 也是 429 |
| TLS 版本/套件（ClientHello 主要变量） | App 内「TLS 变体探针」：1.2 / 1.2+AES128 / 1.3 | 三档全 429 |
| cookie / X-CSRFToken | 补齐 Cookie 罐（IG 这几个端点根本不下发 cookie） | 无变化（对齐 instagrapi 而已） |

## 三、这一轮修掉的真 bug（与 429 无关，但确实是 bug）

1. **设备身份从来没生成 `mid`**：`MobileSession.mint()` 里 `mid = ''` ⇒ CAA 的
   `client_input_params.machine_id` 是空串、请求头也没有 `X-MID`。桌面那份一直能登，
   正是因为它 `settings.caa.json` 里有 28 位 mid。现已 mint 时生成 + 存量身份就地补
   （`ensureMid`，真机验证：`mid` 从空串变成 28 位）。
2. **UA 里 `Android (12/12; …)`**：第一个数是 **API level**，HarmonyOS 4（Android 12）应为 `31/12`。
3. **429 现场不可诊断**：以前 body 为空时 `String(null)` 存成字符串 `null`。现在落
   `machine_id / aac / attest / body 长度 / UA / Cookie 名 / 脱敏响应头 / body 片段`，
   并把**请求体+实际发出的头**也存一份（`last_request`）。
4. **本机 429 冷却只记账不判据**：加「清除限流冷却」入口；冷却过期时把次数一起清掉。

## 四、留给下一步的两条路

- **A. 登录走电脑中转**：App 里输入的账号密码 POST 给自己的中转（局域网），由 Node 侧跑
  `caaLogin()`（指纹能过），拿回 `cookie/authorization` 再由 App `applySession` 落地。
  代价：密码在局域网里明文传一次（可用 `X-Relay-Key` + 只走内网）。
- **B. 直接从电脑拉会话**（不传密码）：中转把自己那份 `settings.caa.json` 会话交给 App，
  App 自动导入，省掉现在"复制粘贴一大段 JSON"的手工步骤。

两条都保留现有的「粘贴会话导入」作为兜底。
