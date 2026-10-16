# instagrapi 协议移植 —— 交接文档

> 面向：在**另一个工作区**接手这件事的 agent。
> 本文件记录「已经查清的事实」「已经写完的代码」「卡在哪」「下一步做什么」。
>
> **本文件位于工程根目录，路径：`C:\HMStudy\Instarmony\INSTAGRAPI_PORT.md`。**
> 让另一个 agent 读它，只要在提示词里给出这个绝对路径（或让它先读工程根的 `*.md`）即可，
> 例如：「读 `C:\HMStudy\Instarmony\INSTAGRAPI_PORT.md`，按里面的第 3.3 与第 5 节继续」。
>
> 最后更新：2026-10-16（编译已通过，只剩签名）。

---

## 0. 一句话背景

`Instarmony` 是一个**鸿蒙 ArkTS 应用**（`com.fanha.instarmony`），取数路线是：
把 Instagram 自己的移动版网页跑在常驻 WebView 里，原生层通过页面桥读页面渲染出的数据、
并回放网页自己发出的同源请求（见 `legacy/unwired/README.md` 对既有路线的说明）。

本次要做的：**把 instagrapi 的私有移动 API 协议逻辑移植到 ArkTS 侧**，
与现有 `Native*` 取数路径**并行新增**、失败自动回退，用来解决现有网页路线最痛的两块 ——
**快拍（stories）** 与 **私信（direct_v2）**。

已与用户确认的四条约束（**不要擅自更改**）：

1. **登录路径**：先做「复用网页 Cookie 罐」，**不实现**密码登录 / 2FA / challenge（instagrapi 的 L3）。
2. **第一批端点范围**：只做 **stories** + **direct_v2**（含实时通道），不做信息流/搜索/写操作。
3. **与现有实现的关系**：**并行新增**，调用方先试新路径、失败自动回退现有 `Native*` / 网页路径。
4. **验证方式**：用户在**鸿蒙模拟器**上跑，通过 `hdc` 抓 hilog 日志判读（模拟器**已登录 IG**）。

---

## 1. 已验证的关键事实（读这一节能省你几小时）

这些都是**读源码 + 读官方文档确认过的**，不是猜测。

### 1.1 instagrapi 的"签名"不是密码学签名

`instagrapi/utils/auth.py`：

```python
def generate_signature(data):
    return "signed_body=SIGNATURE.{data}".format(data=urllib.parse.quote_plus(data))
```

`SIGNATURE` 是**写死的常量前缀**，没有 HMAC、没有密钥、没有设备参与。
所以移植它**不需要**任何密钥学能力，只需要逐字节一致的 URL 编码。

真正用到 HMAC-SHA256 的只有两处：`x-ig-www-claim` 的形态（`hmac.<base64url>`）
与评论输入的 `gen_user_breadcrumb`（密钥常量 `iN4$aGr0m`）。
鸿蒙侧用 `cryptoFramework.createMac({algName:'HMAC', mdName:'SHA256'})` 即可
（官方文档 `crypto-compute-hmac`）。

### 1.2 `login_by_sessionid` 其实不登录 —— 这就是本项目的路线

`instagrapi/mixins/auth.py::login_by_sessionid` 全文做的事：

1. 把 `sessionid` 放进 cookie 罐；
2. 用 `re.search(r"^\d+", sessionid)` 取出 **user id（sessionid 的数字前缀）**；
3. 组装 `authorization_data = {"ds_user_id", "sessionid", "should_use_header_over_cookies": True}`，
   base64 成 `Authorization: Bearer IGT:2:<base64url(JSON)>`；
4. 直接开始打私有 API（`user_info_v1`）。

也就是说「拿网页会话打移动 API」在 instagrapi 里本来就是**一等公民**，
所以我们这条路**一行登录代码都不用写**。
（官方文档同时提醒：浏览器 sessionid 可能被私有 API 判 `login_required`，
真不行要用密码登录一次并 `dump_settings()` —— 但用户已选择先试复用。）

### 1.3 这条路的"自举"靠响应头

instagrapi 的默认 `x-ig-www-claim` 就是字符串 `"0"`，它**同样不自己算**这个值：
真实 claim 由服务端在**响应头**下发，客户端记住并在后续请求带上。

本项目在网页那条路上已经撞过同一堵墙：`AUDIT_TODO.md` 记录快拍 500 的根因之一
就是「缺 `x-ig-www-claim`」。所以移植版把「捡响应头回写」做成第一等公民
（见 `MobileSession.absorbResponseHeaders`）。

### 1.4 项目与 instagrapi 的重叠度比想象中高

项目里早就用着 instagrapi 的同款常量：

| 项目位置 | 内容 | 与 instagrapi 的关系 |
| --- | --- | --- |
| `core/NativeComments.ets:42` | `APP_UA = 'Instagram 448.0.0.52.84 Android (...)'` | 抄 instagrapi 的 UA 格式 |
| `core/NativeComments.ets:45` 等 5 处 | `x-ig-app-id: 567067343352427` | **就是 instagrapi 的 `app_id`** |
| `core/NativeSave.ets`、`NativeStories.ets`、`NativeDirect.ets`、`NativeSearch.ets` | `i.instagram.com` + 安卓身份 | instagrapi 的 `API_DOMAIN` 与身份 |
| `core/NativeComments.ets:125` | `COMMENTS_DOC: '6974885689225067'` | 注明取自 instagrapi 的 `MEDIA_COMMENTS_DOC_ID` |

所以「移植」的真正增量是 **设备身份 + 完整请求骨架 + 异常映射 + 响应模型**，
不是从零开始。

### 1.5 instagrapi 当前状态（2026-10 查）

- 版本 **3.0.21**（2026-10-09 发布），仍在维护；
- 私有请求默认走 `curl_cffi` 的 **HTTP/2**；登录用 **Bloks CAA** 流程（legacy 保留为 `login_legacy`）；
- 支持 Realtime MQTT（`realtime_connect` + `direct_subscribe`）与 FBNS 推送 —— 对私信实时很有用；
- 官方自述：「适合测试、研究、受控内网自动化」，生产建议用官方 API 或托管服务。

---

## 2. 已完成的代码

新增目录 **`entry/src/main/ets/core/mobileapi/`**（5 个文件，约 67KB）。
代码风格与注释风格**刻意对齐本项目既有 `core/Native*.ets`**（中文注释、讲清"为什么"）。

| 文件 | 对应 instagrapi | 内容 |
| --- | --- | --- |
| `MobileConfig.ets` | `config.py` | `API_DOMAIN`、`USER_AGENT_BASE`、`DeviceProfile.DEFAULT`(Pixel 8 Pro/Android 14)、6 组 `APP_SETTINGS`(app 版本 + version_code + bloks id)、`SUPPORTED_CAPABILITIES`、`FixedHeaders`(4 个 `IG-U-*` + `NAV_CHAIN` + `IG_CAPABILITIES` + `FB_HTTP_ENGINE`)、超时、locale/country/timezone |
| `MobileSign.ets` | `utils/auth.py` + `utils/timing.py` | `signedBody()`、`quotePlus()`（等价 python `quote_plus`，含 `~`→`%7E`）、`jazoest()`、`userBreadcrumb()`、`hmacSha256()`、`base64()`/`base64UrlNoPad()`、`androidDeviceId()`、`uuid4()`、`genToken()`、`randomInt()`/`randomFloat()` |
| `MobileSession.ets` | `LoginMixin` 的状态部分 | 8 个设备 UUID 的**落盘持久化**（`preferences` 文件 `instarmony_mobile_session`）、从 Cookie 罐取 `sessionid`/`ds_user_id`/`csrftoken`/`mid`/`rur`、`userIdOfSession()` 兜底、`MobileIdentity.buildAuthorization()`、**`absorbResponseHeaders()`**（捡 `ig-set-x-mid` / `x-ig-set-www-claim` / `ig-set-ig-u-rur` / `ig-set-authorization` 并落盘）、`clearSession()`（保留设备身份） |
| `MobileRequest.ets` | `PrivateRequestMixin` | `baseHeaders()`（约 40 个头）、`send()`、`classify()` 异常映射表、`absoluteUrl()`（`/v1/` 前缀与 `/challenge/` 特例）、`cookieHeader()`（剥 Cookie 属性）、`withDefaultData`/`withActionData`/`withExtraData`/`formOf` |
| `MobileProbe.ets` | （自检） | `scheduleSelfTest()`（启动 6 秒后跑）、三发自检：`users/{uid}/info/`、`feed/reels_tray/`、`direct_v2/inbox/`；`logShape()` 只打形状与结论文案 |

修改 **`entry/src/main/ets/entryability/EntryAbility.ets`**（3 处）：

- L30/L31：import `MobileSession` / `MobileProbe`；
- L128：`MobileSession.init(this.context)`（放在既有 warmup try 块里，只开落盘文件，不读 Cookie、不发请求）；
- L144：`MobileProbe.scheduleSelfTest()`（延迟 6 秒，不挡 UI）。

### 与 instagrapi 的**故意差异**（不是偷懒，见文件内注释）

1. **不抛异常**：用 `MobileResult.ok/error` 表达失败，异常语义落在 `error` 字段
   （instagrapi 的类名 → `challenge_required` / `rate_limit_error` … 一一对应）。
   原因：本项目调用方习惯「失败回 null、换下一条路」。
2. **不写 `time.sleep(request_timeout)`**：instagrapi 每次私有请求前固定睡 1 秒。
   本项目已有 `core/ApiThrottle` 那套"撞限流才退避"，不该再叠一层固定延迟。
3. **cookie 每发现读**：会话属于 ArkWeb 的 Cookie 罐，不自己维护 cookie jar。

---

## 3. 当前卡点：**只剩签名**（编译已通过）

**2026-10-16 更新：编译已经打通。** `MobileProbe` / `MobileSession` / `MobileRequest` /
`MobileSign` / `MobileConfig` 全部编译通过，无 ArkTS 错误，HAP 已产出。
唯一阻塞是**签名证书已过期**（见 3.3）。

### 3.1 命令行构建：**已跑通**的完整配方

| 坑 | 结论 |
| --- | --- |
| `C:\command-line-tools` 的 hvigor 是 **6.0.6**，只支持 `modelVersion 6.0.0`，工程是 6.1.0 | **必须**用 DevEco 自带的 `C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat`（**6.26.4**） |
| `DEVECO_SDK_HOME` 未设置 | 命令行 hvigor 不会猜，显式设为 `C:\Program Files\Huawei\DevEco Studio\sdk` |
| hvigor 默认把缓存写 `~/.hvigor` | **官方开关**：环境变量 `HVIGOR_USER_HOME`（见 `hvigorw.js` 的 `getHvigorUserHomeCacheDir`）指到任意可写目录 |
| npm 缓存默认 `%LOCALAPPDATA%\npm-cache` | 重定向 `npm_config_cache` |
| **hvigor 引擎引导失败**（启动器只报 `ENOENT ... workspace\node_modules\@ohos\hvigor\bin\hvigor.js`） | **根因**：工程根 `node_modules/@ohos/{hvigor,hvigor-ohos-plugin}` 必须是**完整**的。`C:\HMStudy\Instarmony` 那份是完整的 → 引导成功；`Instarmony - instagrapi` 那份是**空壳**（早先 npm 失败留下的残骸）→ 无论怎么补缓存都报同一个 ENOENT（启动器把真实错误吞了，只留 ENOENT）。**修法**：让工程根的这两个包完整（用 DevEco 构建一次会自动补，或从 `C:\Program Files\Huawei\DevEco Studio\tools\hvigor\` 用 robocopy 复制，注意路径超 260 字符要用 robocopy 而非 `Copy-Item`） |
| PowerShell 5.1 按 GBK 读无 BOM 的 `.ps1` | **脚本里所有字符串字面量必须 ASCII-only**，否则中文被读坏、解析报错 |
| 原生命令往 stderr 写警告时 `$ErrorActionPreference='Stop'` 会误判失败 | 调用期间改 `Continue`，用退出码判成败 |

**可直接用的命令**（`tools/build.ps1` 已封装同样的逻辑）：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:HVIGOR_USER_HOME = 'C:\HMStudy\Instarmony\.tmp-hvigor-home'   # 任意可写目录
$env:npm_config_cache = "$env:HVIGOR_USER_HOME\npm-cache"
Set-Location 'C:\HMStudy\Instarmony'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' `
    assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

实测输出（2026-10-16）：

```
Finished :entry:default@CompileArkTS... after 5 s 897 ms      ← 编译通过，无 ArkTS 错误
Finished :entry:default@PackageHap...   after 874 ms
ERROR: Failed :entry:default@SignHap...                        ← 只有签名失败（见 3.3）
产物：entry/build/default/outputs/default/entry-default-unsigned.hap  (4.4 MB)
```

我新增的 5 个文件**没有任何 ArkTS 错误**，只有 lint 级告警（见 3.4）。

### 3.2 建议的绕法

**在 DevEco Studio 里构建**最省事：`C:\HMStudy\Instarmony\node_modules/@ohos/` 是完整的，
DevEco 走自己的路径，完全不碰上面的引导问题。自动签名也会顺手把过期证书换掉。

构建产物与安装/抓日志：

```powershell
# 产物
entry/build/default/outputs/default/*.hap

# 安装 + 启动 + 抓日志
hdc install -r <hap路径>
hdc shell hilog -r
hdc shell aa force-stop com.fanha.instarmony
hdc shell aa start -a EntryAbility -b com.fanha.instarmony
Start-Sleep 8
hdc shell hilog -x | Select-String 'MobileProbe|MobileSession|MobileRequest'
```

`tools/build.ps1 -Install` 已把这套流程写好（含环境变量、缓存重定向、清残缓存、失败重试一次）。

### 3.3 **当前唯一阻塞：签名证书已过期**

`build-profile.json5` 里 `signingConfigs` 指向用户目录下的证书：

```
C:\Users\ShiYi\.ohos\config\default_Instarmony_xdBfzhVo_HdK1AuBYDE0AvxUW8aPPEsEcPxKsIhgmog=.p12/.cer/.p7b
```

报错：

```
ERROR - The certificate has expired! NotAfter: Sat Oct 10 22:55:18 CST 2026
ERROR: 11013002 Certificate format is incorrect, please check your appCertFile parameter.
```

**两条修法**（用户已表示编译签名这部分由他来做，接手方不必自行折腾）：

1. **DevEco Studio 里重新自动签名**（推荐，一次点击）：
   `File → Project Structure → Signing Configs → 勾选 Automatically generate signature`，
   它会生成新证书并写回 `build-profile.json5`。
2. **命令行手动重签**（我已把材料摸清，供参考）：
   - 工具：`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar`
     （用 `C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe -jar` 跑；用法是 `sign-app [options]`）
   - SDK 自带调试签名三件套（同一 `lib` 目录）：`OpenHarmony.p12`（**密钥库口令 `123456`**，
     里面有 `openharmony application debug` / `..._profile_debug` / `..._profile_release` / `..._release` 等别名）、
     `OpenHarmonyProfileDebug.pem`、`OpenHarmonyProfileRelease.pem`
   - `sign-app` 必填：`-mode localSign`、`-keyAlias`、`-appCertFile`、`-profileFile`、`-inFile`、
     `-signAlg SHA256withECDSA`、`-keystoreFile`、`-keystorePwd`、`-outFile`、`-compatibleVersion`
   - 注意 `OpenHarmonyProfileDebug.pem` 是 **pem 格式**，`sign-app` 的 `-profileFile` 要 **p7b**：
     需要先 `sign-profile` 得到 p7b，或改用 `-profileSigned 0`

### 3.4 我新增文件的 lint 告警（非阻塞，但值得处理）

`MobileSign.ets` 有两条系统性告警，与项目既有的 `PlatformCap` 降级理念一致，**建议按项目风格处理**：

```
The system capacity of this api 'createMd' is not supported on all devices
The system capacity of this api 'createRandom' is not supported on all devices
Function may throw exceptions. Special handling is required.
```

即：`cryptoFramework.createMd` / `createRandom` 不是所有设备都支持，且会抛异常。
项目里同类的先例是 `core/InstagramCookieJar`（按 API 等级降级）与 `core/PlatformCap`。
处理方式：给这些调用加 try/catch，失败时退回非 CSPRNG 的兜底
（`androidDeviceId` 可以退回 `Math.random` 拼的 id，`genToken` 同理），
并在日志里说明"这次用的是弱随机"。**不要**为此静默失败。


---

## 4. 验证方法：看这三行日志

启动后 6 秒，`MobileProbe` 会打：

```
MobileProbe  selftest done ok=<n>/3 info=… tray=… inbox=…
MobileProbe  1) 会话与身份：就绪 / 不完整
MobileProbe  2) 请求被 IG 接受：是 / 否（看上面每一发的 err）
MobileProbe  3) 结论：三发全通 / 部分通 / 全失败
```

判读要点：

- `MobileSession ensure: not signed in` → Cookie 罐里没有会话（**模拟器已登录**，出现它说明读罐时机或域判定有问题）；
- `err=no-session` → 同上；
- `err=login_required` / `err=challenge_required` → **真正的坏消息**：
  IG 不认「网页会话当移动会话」这条捷径，需要回头和用户讨论要不要做密码登录（L3）；
- `err=non-json` + HTML 体 → 请求被当成页面导航，通常是头不全；
- 成功时 `logShape()` 会打响应键名与首元素形状，照它写解析层。

---

## 5. 待办（下一步）

1. ~~拿到一次编译通过~~ —— **已完成**（2026-10-16，见 3.1）；签名也已解决（见第 9 节）。
2. ~~**跑自检**，把第 4 节那三行日志回报给用户~~ —— **已完成**：`ok=7/7`（见第 9 节）。
3. ~~**实现 stories 端点**（`core/mobileapi/MobileStories.ets`）~~ —— **已完成**：
   - `tray()` → `feed/reels_tray/`（一发 213 条）；`reel()` → 先 `feed/user/{id}/story/`，
     再 `feed/reels_media/?reel_ids=<裸 id>`（**JSON 数组形式回空**，见第 9 节）；
   - 已接进 `core/NativeStories.tray()/reel()`，由 `MOBILE_STORIES_FIRST` 控制，
     真机日志 `tray via mobile n=213` / `reel via mobile …` 为证；失败静默回退老路径。
4. **实现 direct_v2 端点**（`core/mobileapi/MobileDirect.ets`）：
   - 参照 `instagrapi/mixins/direct.py`：`direct_threads` → `direct_v2/inbox/`、
     `direct_messages` → `direct_v2/threads/{id}/`、发送 → `direct_v2/threads/broadcast/text/`
   - 响应模型对齐现有 `model/Direct.ets`；
   - 现有实现 `core/NativeDirect.ets`（1493 行）候选 op × id 串行、易撞限流。
5. **接管 `core/DmRealtime.ets`**：该文件（228 行）目前是**死代码**
   （`AUDIT_TODO.md` F3 明确写「没有任何调用点」），已实现裸 TLS / wss 连
   `edge-mqtt.facebook.com` 与 MQTT 3.1 CONNECT 探测。instagrapi 的 Realtime MQTT
   成熟得多，可作为参照把它救活。
6. **接入调用方**：`StoriesTray.ets` / `Index.ets` 的快拍路径、`DirectPage.ets` /
   `DirectThreadViewModel.ets` 的私信路径 —— **先试新层、失败回退旧层**。
7. ~~**诊断面板接线**：把 `MobileProbe.lastSummary()` 挂到设置里的诊断项~~ —— **已完成**：
   设置 → 诊断新增「跑移动 API 自检（测试）」+ 结果行（点一下复制）；
   同时自检结论与每一发的响应形状落盘到 `filesDir/Instarmony_mobile.txt`（`hdc file recv` 可取）。

---

## 6. 不要破坏的项目约束

- **不在原生侧保存账号密码**；登录一律走 IG 网页（`components/LoginPanel.ets`）。
  这是项目既有路线的核心，也是本次选「复用 Cookie 罐」的原因。
- **不删现有 `Native*` / 网页取数路径**：新层是并行的，旧层是回退。
- **`legacy/unwired/` 里的 OAuth / Graph API 分层已归档且不可用**（其 README 列了 4 个已知缺陷），
  不要把它当参考实现。
- 代码注释请沿用本项目风格：中文、解释「为什么这么做」、引证据（真机日志 / 提交号）。
- 改动 `README`/文档时，本文件（`INSTAGRAPI_PORT.md`）是这次移植的权威说明。

---

## 7. 参考来源

- instagrapi 仓库：<https://github.com/subzeroid/instagrapi>
  （本次读过的文件：`config.py`、`utils/auth.py`、`mixins/auth.py`、`mixins/private.py`）
- PyPI 说明（版本与路线、`login_by_sessionid` 的官方提醒）：
  <https://pypi.org/project/instagrapi/>
- 鸿蒙 HMAC 计算文档（`crypto-compute-hmac`，`@kit.CryptoArchitectureKit`）
- 项目内证据：`AUDIT_TODO.md`（尤其「快拍 500」那一节与 E 类「静默失败」）、
  `legacy/unwired/README.md`（路线变更的来龙去脉）

---

## 8. 进展日志

| 事项 | 状态 |
| --- | --- |
| 读通现有取数链路（`bridge/`、`core/Native*`、`core/RestSession`、`legacy/unwired`、`AUDIT_TODO`） | 完成 |
| 查清 instagrapi 协议要点（签名/会话/自举/异常表） | 完成 |
| 与用户确认四条约束 | 完成 |
| L0 工具层 `MobileSign.ets` | 完成，**编译通过** |
| L1 配置与身份 `MobileConfig.ets` / `MobileSession.ets` | 完成，**编译通过** |
| L2 请求骨架 `MobileRequest.ets` | 完成，**编译通过** |
| 自检探针 `MobileProbe.ets` + `EntryAbility` 接线 | 完成，**编译通过** |
| 命令行构建引导（`HVIGOR_USER_HOME` + 工程根 `node_modules` 完整性） | **已跑通**（见 3.1） |
| 代码搬到 `C:\HMStudy\Instarmony`（用户指定） | 完成 |
| 签名 | **已解决**（用户 2026-10-16 15:48 重新自动签名；`install -r` 原地覆盖成功，会话未丢） |
| 模拟器真机验证（跑自检看三行结论） | **完成，全部通过**：`ok=7/7`（见第 9 节） |
| stories 端点 `MobileStories.ets` + 接进 `NativeStories` | **完成并在真机跑通**：托盘 213 条、点开播放页有媒体（见第 9 节） |
| direct_v2 端点 `MobileDirect.ets` + 接进 `NativeDirect` | **完成（只读）**：收件箱 20 条会话、会话消息 21 条；顺手修掉 `DirectMapper` 丢 `xma_*` 消息的缺陷（见 9.6） |

### 下一步的最短路径（原计划，已完成）

1. ~~把签名换掉~~ → **已完成**（用户重新自动签名）。
2. ~~`hdc install -r` 装上，启动，抓 `MobileProbe` 日志~~ → **已完成**，`ok=7/7`。
3. ~~按第 4 节判读~~ → **结论：全通，这条路成立**（明细见第 9 节）。

---

## 9. 实测结论（2026-10-16，模拟器 + 已登录会话）

设备：DevEco 模拟器 `127.0.0.1:5555`（Mate 80 镜像，已登录 IG 的 Instarmony 0.8.1）。
取证方式：`MobileProbe` 自检报告落盘 →
`hdc file recv /data/app/el2/100/base/com.fanha.instarmony/haps/entry/files/Instarmony_mobile.txt`。

### 9.1 自检 `ok=7/7`（**这条路成立**）

```
结论 ok=7/7 info=ok(17358b) tray=ok(423408b) inbox=ok(832979b) self=ok(75b) user=ok(35271b) media=ok(36240b) mediaJson=ok(26b)
身份 user=12345678901 mid=y claim=0 rur=y auth=173b dev=Pixel 8 Pro app=449.0.0.52.84 csrf=32
主机 i.instagram.com
```

要点：
- **`X-IG-WWW-Claim: 0` 也被接受**（读接口不校验 claim）；`auth=173b` 说明服务端下发的
  `ig-set-authorization` 被捡回来并落盘了 —— 自举（`absorbResponseHeaders`）有效。
- 网页那条 REST 在这台机器上**没有**被复现成 500（这里是"已经通的会话"），
  所以 500 是否只由"来源/出口 IP"触发，仍需在测试者那边复测；但移动端这条路**至少多一条独立通路**。

### 9.2 响应形状（写解析层的依据，全部实测）

| 请求 | 形状 |
| --- | --- |
| `POST feed/reels_tray/`（表单带 `supported_capabilities_new`/`reason`/`timezone_offset`/`tray_session_id`/`request_id`/`page_size`/`_uuid`） | `{tray:[…213 条…], status:"ok"}`；**这一版不再带 `items`** |
| 托盘条目 | `id`(= reel id)、`strong_id__`、`latest_reel_media`、`seen`(时刻，非布尔)、`media_count`、`media_ids`、`expiring_at`、`has_video`、`reel_type`、`user:{pk,id,username,full_name,profile_pic_url,is_private,is_verified}` |
| `GET feed/user/{pk}/story/` | `{reel:{…27 键…}, status:"ok"}`，**媒体在 `reel.items`**（不在顶层 `items`）；自己没发快拍时 `reel:null` |
| `GET feed/reels_media/?reel_ids=<裸 id>` | `{reels:{"<id>":{items:[…]}}}` ✓ 36KB |
| `GET feed/reels_media/?reel_ids=["<id>"]`（**网页那条用的 JSON 数组形式**） | `{reels:{},status:"ok"}` ✗ **回空** —— 这很可能就是网页那条路拿不到东西的原因之一 |
| media 条目 | `media_type`(1 图 / 2 视频)、`image_versions2.candidates[]`(实测 `2(640x1136)`)、`video_versions[]`、`original_width/height`、`taken_at`、`expiring_at`、`video_duration`、`pk`/`id`、`user` |
| `POST direct_v2/inbox/` | `{inbox:{threads:[…20…], pinned_threads, unseen_count}, viewer:{…}, seq_id, has_pending_top_requests, status:"ok"}`；`threads[0]` 约 140 键（`thread_id`/`users`/`items[11]`/`last_activity_at`/`next_cursor`/`has_older`…）；`items[0]` 是消息（`item_id`/`item_type`/`text`/`timestamp`/`user_id`） |

### 9.3 快拍已在真机跑通（不只是自检通过）

- `NativeStories: tray via mobile n=213 first=peter928z`（老路径那一发**根本没发**，说明没有回退）；
- `NativeStories: reel via mobile uid=… user=… n=1..3`（预热与点开都在走新路）；
- 点第一个头像 → 播放页显示该用户的快拍媒体与文案（截图确认），转场/进度条正常。

### 9.4 顺手修掉的两个身份稳定性缺陷（**不是这两个模块新引入的**）

1. `MobileSession.loadSeed()` 用 `loaded` 布尔做闸门：**第一次读盘之后每次调用都掉进 `mint()`**
   → 同一次运行里每发请求都换一套 phone_id / uuid / android_id（IG 视角就是"同一账号疯狂换设备"）。
   已改为进程内缓存 `seed`，并让 `persist()` 同步更新缓存。
2. `clearSession()` 先把 `this.identity = null` 再 `persist()`，而 `persist()` 见身份为空直接返回
   → 盘上那份旧 `claim`/`rur`/`authorization`（**会话级**材料）会串到下一段会话。已改为显式落盘。

### 9.5 复现命令（接手方照抄）```powershell
# 构建（用户指定的原方法；注意它成功时也可能回 exit code 1，看 BUILD SUCCESSFUL）
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p product=default assembleHap --no-daemon

# 装 + 跑 + 取自检报告
hdc -t 127.0.0.1:5555 install -r entry\build\default\outputs\default\entry-default-signed.hap
hdc shell "aa force-stop com.fanha.instarmony"; hdc shell "aa start -a EntryAbility -b com.fanha.instarmony"
hdc file recv "/data/app/el2/100/base/com.fanha.instarmony/haps/entry/files/Instarmony_mobile.txt" .\Instarmony_mobile.txt
```

### 9.6 私信（direct_v2）也已接上（只读）

新文件 `core/mobileapi/MobileDirect.ets`，接进 `NativeDirect.inbox / inboxRest / thread`
（常量 `MOBILE_DIRECT_FIRST`，同样可一处整体回退）。**发送不做**（写接口的握手与风控判据不同，
既有 `probeSendShape` 那套先留着）。

实测（模拟器 + 已登录会话，16:27）：

```
MobileDirect: inbox ok n=20 more=true             → NativeDirect: inboxRest via mobile n=20
MobileDirect: thread ok id=…363010 msgs=20 raw=21 older=true with=meowlok0w0
              → NativeDirect: thread via mobile … msgs=20     （没有回退到模板/网页）
```

解析层**复用** `model/Direct.ets` 的两个映射（`inboxFromRestJson` / `threadFromJson`），
自检报告里可见 `parser inbox=ok n=20`、`parser thread=ok` —— 移动端响应与老解析器兼容。

**顺手修掉一个真缺陷（用户报的"会话只显示 4~5 条"就是它）**：

- `DirectMapper.threadFromJson` 原本只认 `text` / `media` / `media_share` / `clip` / `reel_share` / `link`；
- 真机 1:1 会话里**整条线程可以是** `xma_clip`(18) + `xma_media_share`(2) + `generic_xma`(1)
  → 21 条全被当成"既没文字也没画面"丢掉 → 解析出 **0 条**，界面报「读取失败: http-404/non-json」；
- 形状（实测）：`item.xma_clip` / `item.xma_media_share` / `item.generic_xma` 都是**数组**（通常 1 个元素），
  元素里有 `preview_url`(+`preview_width/height`)、`playable_url`（视频）、`title_text`/`caption_body_text`；
- 已补 `xmaImageUrl` / `animatedImageUrl`（贴纸 GIF：`animated_media.images.{fixed_height,…}.url`）
  与 XMA 的 `hasVideoMedia`（`playable_url` / `preview_url_mime_type` 含 `video`）；
- 修完同一会话 `msgs=20 raw=21`，界面正常显示分享的 Reel 预览与文字消息。
- 顺带说明：会话页每 4 秒轮询一次（`DirectThreadViewModel.THREAD_POLL_MS`）是**既有设计**，
  不是新路径引入的循环。

**收件箱翻页游标：已解开**（`MobileProbe.inboxPageVariants`，2026-10-17）。
`inbox.next_cursor` **不是字符串**，是结构
`{cursor_thread_v2_id, cursor_timestamp_seconds, cursor_relevancy_score, cursor_primary_sort_id}`
（旁边还有 `prev_cursor` / `prev_cursor_v2` / `prev_cursor_type=PAGING`）。判据是**回来的第一会话 id
是否与上一页不同**（只看状态码会被"原地打转"骗过去）。逐个试的结果：

| 传法 | 结果 |
| --- | --- |
| `?cursor=<oldest_cursor>`（105 字符串） | **200 且真的换了页**（n=20，第一会话变了）✓ |
| `?cursor=<prev_cursor>`（同一串值） | 同样 200/NEW ✓ |
| `?cursor=<next_cursor>`（180 结构体） | **400** `Invalid Inbox Cursor: The cursor parameter passed in the Inbox API is not valid.` |
| `?cursor=<prev_cursor_v2>`（81） | 400（同上） |
| `cursor=<…>` 放在**表单体**里 | 200，但**又是第一页**（参数被忽略） |
| `?cursor_v2=…` / `?max_id=…` | 200，但**又是第一页**（参数被忽略） |

⇒ 实现：`MobileDirect.withCursor` 只认 `oldest_cursor` / `prev_cursor`（`CURSOR_KEYS`），
游标**只走查询串**，`MOBILE_INBOX_CURSOR_USABLE` 已打开。
真机验证（18:39）：连续 4 页 `req cursorLen=105/105/106/106`，第一会话依次为
`MeowlokHongKong → 𝐀𝐁𝐁𝐘❀ → choy → Nulla`，列表从 20 条长到 80 条，日期一路回到 9 月。
实验本身留在探针里（`INBOX_CURSOR_EXPERIMENT`，**默认关**：结论已拿到，不必每次开机白打六发）。

### 9.7 私信体验：feeds 页预取 + 上拉翻页（用户报的两个问题）

1. **列表加载慢 → 在 feeds 页预取**：
   `Index.warmOtherTabs` 开头起一发 `directVm.load(false)`，**与后面的预热链并行、不等它**
   （挂在链尾要 30 秒开外，用户早就点进私信了）。`directVm` 与 `DirectPage` 是**同一个实例**，
   所以预取结果直接成为用户切过去时的第一屏。
   配套：`DirectViewModel.loadedAtMs` + `isFresh(2 分钟)`；`DirectPage.aboutToAppear` 先
   `syncFromVm()`，**新鲜就不再重拉**（状态行显示「已加载（feeds 页已预热）」）。
   实测：`Ability onCreate` 之后 **10.2 秒**预热完成（`direct prefetch done n=20`），
   16 秒时切到私信页 → 列表已就绪、状态行显示"已预热"。
2. **滑到底拉不出更多 → 修好**：根因就是上面那条游标（修之前移动端如实报 `hasMore=false`，
   触底哨兵因此一次都不触发）。修完触底即翻页，`more` 由服务端继续给 `oldest_cursor` 决定何时到底。

### 9.8 私信会话消息的预取 + 落盘快照（用户要求的四个行为）

需求原文：*"切换到私信列表时预取当前私信列表的所有会话消息，每个会话 5 条，点进去覆盖并触发
刷新获取一页历史消息，私信列表刷新时预取新刷新出来的会话。预取的会话可以存进 app，
无新消息就直接覆盖会话消息，预取数据仅限文本，图片/视频媒体用占位加载表示，加载成功后显示。"*

新增两个模块 + 四处接线：

| 文件 | 职责 |
| --- | --- |
| `core/DirectCache.ets`（新） | 每条会话一份**只含文本**的快照（最近 5 条 + `newestId/newestTs` 判新 + 翻页游标），落盘在 `instarmony_direct_cache`（preferences，同 FeedCache 那套），上限 80 条会话 |
| `core/DirectPrefetch.ets`（新） | 后台预取队列：串行、`idle` 优先级（绝不挡用户点开）、跳过新鲜快照、按代次可取消、**不重试** |
| `DirectViewModel.load/requestMore` | 列表到手/翻页后 `DirectPrefetch.seed(threads)` —— 增量：只给缺快照的那几条发请求 |
| `DirectThreadViewModel.open` | 先用快照铺第一屏（`first paint from cache`），媒体位置画占位 |
| `DirectThreadViewModel.load` | 刷新一页后：**没有新消息 → 保持快照画面**（只把媒体地址按 id 填进去，不跳）；有新消息 → 直接显示新那一页。两种都写回快照 |
| `DirectThreadPage.bubbleContent` | 媒体类消息而地址为空时画**占位块**（尺寸与真媒体一致），地址到了自然换成图/封面 |

**为什么只存文本**（三条理由，第一条是硬的）：① IG 媒体 URL 带签名且**会过期**，存下来的
几小时后就是死链（快拍那边吃过这个亏），界面反而更糟；② 体积：带 URL 的话 20 条会话就上百 KB，
而这份缓存每次列表刷新都要重写；③ 媒体本来就要点进去看，现取最准。

实测（模拟器）：

```
第一次启动：seed threads=20 queued=20 fresh=0 cache=threads=0      → round done done=24 fail=0
            拉回的缓存文件：24 条会话 / 102 条消息 / 每条 5 条；消息字段只有 id,userId,mine,tsMs,kind,text
            （整份 22KB，唯一一处 "http" 是某条消息正文里的一个链接，不是媒体地址）
第二次启动：seed threads=20 queued=0 fresh=20                       ← 全部命中快照，零请求
翻到 40 条：seed threads=40 queued=15 fresh=25                      ← 只预取新出来的 15 条
点开会话：  first paint from cache id=…767129 msgs=5                ← 第一屏来自快照
             no new message → keep cache paint msgs=20               ← 无新消息：画面不跳，媒体补齐
```

**过程中修掉预取队列自己的两个坑**（都与 StoryCache 那两个同源，注释里都写了"别再犯"）：
① 陈旧结果那条分支设了 `running=false` 就 `return`，**没有接着推队列** —— 只要刷新列表撞上一次
在飞的旧请求，整条预取链就永久停住（现象："只预取了一条"）；② 被当成陈旧丢掉的那一条，
在新一轮里已被算作"正在飞"而没入队 → **它永远不会有快照**（真机第一条会话就是这么漏的），
现在丢掉时按当前列表补回队头。

### 9.9 会话页三个界面问题（用户反馈）

1. **"最新消息要保持在输入框上方合适距离"**：
   - 列表靠 `contentEndOffset(BOTTOM_OFFSET=92vp)` 留出输入条那块（输入条高 44 + 底距 28），
     最新一条因此落在输入条上方约 20vp；
   - 真正会破坏它的是**媒体晚到**：气泡里的图/贴纸是异步解码的，解码完高度才变，
     那一刻列表不会自己重新贴底 → 最新那条被顶到输入框下面。修法两处：
     气泡 `Image.onComplete` 里补一次贴底；贴底后再补几次延迟检查（600/1500/3000ms）。
     但只在**用户本来就贴着底部**时才补（`pinnedToBottom`：向上滚过一小段就置 false），
     绝不把正在翻历史的人拽走。
2. **"加载时在最顶部消息上方显示刷新动画、置中"**：列表**第 0 格**放一行
   `LoadingProgress`（`busy` 时高 36vp、否则高 0，始终占位 → 下标恒定），
   水平居中。原生 `Refresh` 那颗只在"手动下拉"那一下看得见，而"触顶自动加载""点开会话"
   "媒体补齐重排"都不经过手势，用户此前看不到任何反馈。注意：因为多了这一格，
   `scrollToIndex` 的锚点要 `+1`（不然"加载更老后位置跳一条"）。
3. **"点输入框弹出输入法，输入框被盖住"**（真机复现：键盘整条压在输入条上）：
   这一页是 `HdsNavDestination` 里的整屏内容，**窗口层的避让没有作用到它**，所以自己听
   `window.on('keyboardHeightChange')` 并按**实测矩形**自校正：
   - 输入条外层 padding = `COMMENT_INPUT_BOTTOM_VP + keyboardVp`；列表那一侧也抬 `keyboardVp`；
   - `keyboardVp` 不是按键盘高度算的，而是"量输入条实际位置 → 差多少补多少"迭代出来的。
     实测（1280×2832px / 365.7×809.1vp，键盘 1099px）：`need=1043px → -903px → 0px` 三次收敛；
     **为什么不能一次按键盘高度抬**：窗口那层自己也避让，两者叠加在大偏移处约 1:1.87，
     一次抬满会飘到键盘上方 900px（实测）；近目标处才是 1:1。
   - 踩坑记录：`getRectangleById` 的 id **必须挂在"不含 padding 的那一层"**上 ——
     id 与 padding 同一节点时量到的是含 padding 的外框，外框被 Stack 钉在页面底部、永远不动，
     自校正于是读到恒定值（日志里 `need` 一直不变就是这么来的）。



---

## 10. 主动限速闸门（用户要求："给 http 请求加 delay，避免被限流"）

`core/ApiThrottle` 原来只有**被动退避**（撞上限流才记 12 分钟冷却）。现在加了一道**主动闸门**：

- **同一时刻只允许一发在路上**（串行），两发之间至少隔 **900ms ± 400ms 抖动**
  （固定间隔本身就是指纹）；
- **三级优先级**：`interactive()`（用户此刻点开的，间隔只要 250ms）→ `warm()`（首屏/预取）
  → `idle()`（自检/诊断）。优先级高的**插队**，所以"用户点开"永远不会被后台预取排住；
- 拿到闸门必须 `release()`：`MobileRequest.send` / `NativeStories.fetchText` / `NativeDirect.send`
  三处都用 try/finally 包住，另外闸门自带 **30 秒防呆**（忘放闸时强制放闸并打 warn，
  宁可多发一发也不要整条链静默卡死）；
- 移动端那条路**也接了限流记账**（`classify` 认出限流 → `ApiThrottle.note(家族)`）：
  以前只有网页那几条路记账，而移动端的连发恰恰最容易把额度打满。

接进去的位置：移动端全部请求（快拍记 `STORIES`、私信记 `DIRECT`、自检记 `MOBILE`）、
老快拍路径 `NativeStories.fetchText`、老私信路径 `NativeDirect.send`。

**顺带修掉闸门暴露出来的一个真重复**：`StoryCache.ensure()` 在"队列还空着"时会 reset，
而启动时它被调两次（预热链一次、托盘 `onStoryLoaded` 一次）——以前第一批 ~200ms 就回来了，
第二次调用看到队列已有内容就不动；加了闸门之后第一批要排 ~1 秒才发出去，于是**同一批 5 位用户被发了两遍**
（真机日志：同一秒 5 位用户各两发）。修法：`StoryCache` 记一份"在飞名单"（带代次），
`ensure`/`fill` 都拿它判重；`Index` 里那次多余的 `reset` 改成 `ensure`。
实测同一批只剩 5 发，且 `StoryCache: ensure skip: inflight from=0 start=0`。

## 11. 会话/模板过期（调研结论，用户问："定时后台刷新可以吗"）

**结论：不要做定时后台刷新。** 三条理由，前一条是硬约束：

1. **鸿蒙侧没有可用的形态**（官方文档）：
   - 延迟任务（`workScheduler`）按**应用活跃分组**限频 —— 活跃分组最小间隔 **2 小时**，
     常用分组 24 小时，极少使用 48 小时，受限/从未使用**禁止调度**；单次回调最长 2 分钟；
     且调度时机由系统按内存/功耗/温度决定。
   - 短时任务（`backgroundTaskManager`）只在**前台或 onBackground 内**能申请，
     单日配额默认 **10 分钟**、单次最长 3 分钟，低电量时更短。
   ⇒ "每几分钟心跳一次保活"在这种约束下根本排不出来。
2. **IG 侧反而更危险**：固定间隔、后台来源、无交互的请求模式是典型的机器人特征，
   而且这些请求同样消耗限流额度 —— 花了电还把自己往风控上推。
3. **收益接近零**：`sessionid` 的有效期不由我们决定，心跳既不能续期，也拦不住 IG 风控作废；
   而"接口模板过期"是服务端版本变化，心跳同样阻止不了。

**建议的做法（按性价比排序）**：

1. **按需判定 + 明确提示**：冷启动/回前台各发**一发**便宜请求（现在已经有：启动自检 +
   设置→诊断里那行结论）。三态要分清：`正常` / `会话过期需重登`（`login_required`/403）/
   `被要求安全验证`（`challenge_required`）。过期时给**明确的一键重新登录**入口（走已有的网页登录），
   **不要自动重载网页** —— 那既解决不了过期，也让请求形态更像机器人。
2. **模板：失败驱动 + 前台空闲预热**，不要靠定时。用户还在用的时候（前台空闲）就把已经过期的
   模板换新，下次冷启动直接命中；失败时再重抓（现有 5xx 重抓那条逻辑就是这一类）。
3. **结构性解法：不依赖模板**。快拍、私信已经改走移动端私有 API（没有 doc_id 模板这回事），
   所以这两块**已经不会再因为"接口过期"而要重载**；剩下的信息流/评论可以逐步同样处理。
4. 冷启动**先用上次内容**（`FeedCache` / `ReelsCache` / `SearchCache` / 快拍托盘已有这套），
   模板刷新在背后进行 —— 用户看到的是"秒开"，而不是"重加载"。

## 12. 搜索结果 / 探索流 / 主页改走移动端点（2026-10-17）

用户要求："搜索推荐流和 reels 的 http 请求应该不是同一个，然后尽量把 reels/搜索/主页的数据加载速度提升，
参考 instagrapi 的协议逻辑。"

### 12.1 为什么"搜索推荐流和 reels 是同一发请求"

在这之前，搜索页那面**推荐网格**是靠**模板回放**拿的，而模板候选的优先级是
`EXPLORE_HINTS`（explore/discover/chaining）→ `CLIPS_HINTS`（clips/reels）。真机上 `/explore/`
要么服务端直出（一个请求都不发）、要么直接跳到 `/explore/search/`，所以**探索模板常常根本抓不到**,
于是回落到 `CLIPS_HINTS` —— 那就是 reels 的 `PolarisClipsTabRootPaginationQuery`。
结果：两个页面拿同一发请求、同一批内容，而且两条路还共用 `ApiThrottle.CLIPS` 那把限流锁。

### 12.2 端点侦察（真机实测，`filesDir/Instarmony_scout.txt`）

`MobileProbe` 里新加了**端点侦察**（`ENDPOINT_SCOUT`，默认关，设定页那颗自检按钮即可触发）：
它把候选端点各打一发，把"通不通 + 结构树"写进单独一份文件。本轮结论（账号 `alice`）：

| 端点 | 结果 | 关键形状 |
|---|---|---|
| `GET clips/home/`（GET 与 POST 都试） | **404**（HTML） | 这一版 App **没有**这个端点 → reels 只能继续走 GraphQL |
| `GET discover/topical_explore/` | ✓ 200，1.30MB / 4.7s | `sectional_items[]` → `layout_content.medias[].media`（`feed_type=clips`/`media`）；游标 = **`max_id`**（长串，这一版 `next_max_id` 是 `"0"`）+ `session_paging_token`；`more_available` / `rank_token` |
| `GET fbsearch/account_serp/` | ✓ 200，32KB / 1.9s | `users[]`（`pk` / `username` / `full_name` / `profile_pic_url` / `is_verified` / `is_private` / `friendship_status.following`）+ `page_token` / `has_more` |
| `GET users/search/`（v1，参数是 `q`） | ✓ 200，43KB / 2.0s | `users[]`，`pk` 同样齐 |
| `GET fbsearch/top_serp/` | ✓ 200，595KB / 3.8s | 帖子在 `media_grid.sections[].layout_content.medias[].media`；游标 `media_grid.next_max_id` / `has_next` |
| `GET users/{pk}/info/` | ✓ 200，几百毫秒 | `user{username, full_name, biography, external_url, profile_pic_url, hd_profile_pic_url_info, is_private, is_verified, follower_count, following_count, media_count, friendship_status}` |
| `GET feed/user/{pk}/?count=12` | ✓ 200，377KB / 2.2s | `items[]`（与信息流同形状：`pk`/`code`/`media_type`/`carousel_media`/`image_versions2`/…）+ `more_available` / `next_max_id` |
| `users/{username}/usernameinfo/` | 见下一轮侦察 | 别人主页只有用户名时走这条（instagrapi 的 `user_info_by_username`） |

参数按 instagrapi / `instagram-private-api` 的原样：探索流是
`is_prefetch=false & omit_cover_media=true & module=explore_popular & reels_configuration=hide_hero &
use_sectional_payload=true & cluster_id=explore_all:0 & session_id=<设备 uuid> & include_fixed_destinations=true`。

### 12.3 落地的改动

- 新增 `core/mobileapi/MobileDiscover.ets`（对应 instagrapi 的 `ExploreMixin` + `FbSearchMixin`）：
  `explore()`（推荐网格）/ `mediaSearch()`（搜帖子的 `media_grid`）/ `accounts()`（账号搜索，
  v2 失败落 v1）。**只搬原始节点**，字段映射留给 `NativeSearch`（它有现成的 `readPost`），
  这样 mobileapi 只依赖 model，不会和 core 形成循环 import。
- 新增 `core/mobileapi/MobileProfile.ets`（对应 `UserMixin.user_info* / user_medias`）：
  `info()`（`users/{pk}/info/`，没 id 时 `users/{username}/usernameinfo/`）+ `medias()`
  （`feed/user/{pk}/?count=N&max_id=…`），同样只搬原始节点。
- `core/NativeSearch`：`recommendedPage()` **先走移动端探索流**（并记住第一页是哪条路给的 ——
  两种游标互不通用）；`searchUsers()` **先走移动端账号搜索**；新增 `postsFromMedias()` 复用
  `postOf` 的映射；新增 `hasRecommendedSource()` / `mobileRecommendedUsable()`。
- `core/NativeProfile`：`fetchHeader()` 移动端优先（模板那条留作退路）；`fetchPosts()` 对
  **帖子那一段**（`OP_POSTS`）移动端优先（视频/收藏/被标注三段移动端没有等价物，仍走模板）；
  抽出 `headerFromUser()` / `postsFromItems()` 让两条路共用同一套字段映射。
- `viewmodel/SearchViewModel`：四处"有没有推荐模板"的判断改成"有没有推荐**来源**"——
  否则冷启动（还没抓过模板）会直接跳过推荐流、甚至去跑 `coldTemplateCapture()`
  （导航隐藏网页十几秒，正是"进搜索页就卡住"）。限流那把 `CLIPS` 锁**不再拦移动端探索流**
  （不同的端点）。
- `core/ApiThrottle.looksLimited` 收紧：`"rate limit"` 字面会误命中整页 HTML（真机上把 reels
  预热打成了 12 分钟冷却）。现在只有 `1675004` / `rate_limit_error`，或者该字面出现在
  IG 的错误结构（`"message"`/`"error_type"`/`"errors"`/`"severity"` 附近）时才算；
  `NativeReels` 那两个分支同时把**响应开头 160 字**打进日志，便于下次一眼看出误判。

### 12.4 reels：主路被限流时用探索流兜底（本轮实测后补上）

真机实测（2026-10-17 01:30）：clips 那条 GraphQL **确实被 IG 限流**了，响应就是
`{"errors":[{"message":"Rate limit exceeded","severity":"CRITICAL","code":1675004}],...}`
（severity=CRITICAL → 12 分钟冷却）。所以"把 reels 提速"在这条路上没有空间：它现在根本发不出去。

于是加了兜底：`NativeReels.viaExplore()` 在被限流（或 clips 那发受限）时改用
`discover/topical_explore/` —— 那一份 `sectional_items[].layout_content.medias[].media` 就是
**clips 媒体对象**（`code`/`pk`/`video_versions`/`image_versions2`/`user`/计数），直接喂给
现成的 `toReel` 即可。实测：`reels via mobile explore n=12 medias=16 more=true`，
页面正常播放、作者行/计数/关注按钮都在。

代价写在代码注释里：那是探索/推荐的排序，不是 Reels 标签那套个性化排序；封面/音乐字段可能稀疏。
所以只在主路不可用时走，并且**游标不通用** —— 第一页从哪条路来，翻页就继续走哪条
（`NativeReels.exploreUsable`）。`ReelsViewModel.loadFirst` 同时改成"先铺缓存、再试兜底"，
而不是一被限流就直接认输（预取深度仍是 `NATIVE_CACHE_PAGES=2`，没有被这次改动放大）。

另外 `clips/home/` 既然 404，reels 的**主路**仍然是 GraphQL 模板回放（预热更早 + 模板落盘 +
不再被假的限流锁住 + 去掉不必要的重发）。侦察脚本留着（`ENDPOINT_SCOUT`），随时可以再跑一遍看
IG 有没有给出等价端点。

### 12.5 真机验证（2026-10-17 01:30，账号 `alice`）

- 搜索推荐流：`MobileDiscover: explore ok sections=8 medias=16 more=true ms=6221 bytes=1261017`
  → `NativeSearch: recommend mobile medias=16 posts=16`（16/16 全部映射成功），
  搜索页截图为三列瀑布流、比例各异、视频格有播放角标；翻页也走探索流自己的游标。
- 搜索账号：`discover/topical_explore/` 与 `fbsearch/account_serp/` 都不需要模板，
  所以 `hasRecommendedSource()` 一为真就不再跑 `coldTemplateCapture()`（那一步要导航隐藏网页）。
- 主页：`MobileProfile: info ok (users/12345678901/info/) user=alice` +
  `medias ok items=8` → `NativeProfile: posts via mobile items=8 posts=8`（8/8），
  视频/收藏/被标注三段仍走模板（`PolarisProfileReelsTabContentQuery` 等）。
- reels：clips 被限流 → 立刻落探索流兜底，页面正常播放（截图可见作者 `carol`、
  计数 2622/6/92、关注按钮、静音/下载按钮）。
- 耗时说明：日志里的 `ms` 常常是 6~13 秒，那是**排队等待**（`paced … waited=…`）而不是网络 ——
  启动那一轮快拍预取（5 位用户）+ 托盘 + 私信排在前面，交互优先级那一发会插队。

## 13. "我的"四个分页 + 搜索触底（2026-10-17 第二轮）

用户要求："进入首页时要加载 reels/私信/搜索页/我的（及其下四个分页）。搜索功能和我的（及其下四个分页）
尝试改为 instagrapi 的协议。切换分页无需重新加载。搜索推荐流无法触底刷新，修复一下。"

### 13.1 搜索推荐流触底不加载（真凶）

`SearchViewModel.loadMore` 里有一道"被限流就不发"的闸，判据是 `ApiThrottle.blocked(CLIPS)`。
但推荐流现在走的是 `discover/topical_explore/`（**另一个端点**），而 `CLIPS` 记的是 clips 那条
GraphQL 的冷却 —— reels 一打那条就会把 `CLIPS` 打到 12 分钟冷却，于是搜索推荐流滑到底
**一声不响什么都不加载**（原来连状态行都不变，所以看起来像"功能坏了"）。

修法：新增 `NativeSearch.usingMobileRecommended()`（= 当前这份推荐流是不是移动端给的），
移动端来源时不再按 `CLIPS` 拦。`loadRecommendedOnce` 那处同一类判断上一轮已经改过。

### 13.2 "我的"四个分页改走移动端

`core/mobileapi/MobileProfile.tab(kind, pk, maxId)`：

| 分页 | 端点 | 依据 |
|---|---|---|
| 帖子 | `GET /api/v1/feed/user/{pk}/?count=24[&max_id=]` | instagrapi `user_medias`，**已实测**（8/8 解析成功） |
| Reels | `POST /api/v1/clips/user/`（表单 `target_user_id` / `page_size`） | instagrapi `user_clips`，**待实测** |
| 被标注 | `GET /api/v1/usertags/{pk}/feed/[?max_id=]` | instagram-private-api `UsertagsFeed`，**待实测** |
| 收藏 | `GET /api/v1/feed/saved/`（候选） | 无权威依据，**待实测** |

乐观性分两级（`MobileProfile.tabOptimistic` / `tabUsable`）：**帖子与被标注**有据可查，直接乐观使用；
**Reels 与收藏**是试出来的端点 —— 先按原来的模板路走，哪次真通了再把标记立起来。
这样即使这一版 IG 不给，也不会把本来好用的分页弄坏。

`core/NativeProfile.fetchPosts` 按操作名判 kind（**合成名** `mobile:<kind>` 或**真模板名**
`PolarisProfileReelsTabContentQuery` 等都能认），移动端优先、模板路完整保留。
新增 `mobileKindOf` / `mobileOpFor` / `isMobileOp`。

### 13.3 切分页不再重新加载

`ProfileViewModel.opNameOf(tab)` 以前在"没有模板"时返回空串 → `setTab` / `load` 于是去跑
`captureTab()`：**导航隐藏网页 + 抓模板**（秒级），用户看到的就是"每次切到没抓过的分页都要等"。
现在没有模板时返回**合成操作名**（`mobileOpFor(kind)`），四段都不需要模板。

配合原有的分页缓存（`ProfileTabState.loaded` → 切回已加载分页只 `prefetchNext` 不重拉），
"切换分页无需重新加载"就成立了；`preloadAllSegments` / `prefetchOthersSequential` 也因此
在"没模板"时能把四段都预取上（对应用户第 1 条要求：进首页就把 reels/私信/搜索/我的四段都备好）。

### 13.4 验证状态（本轮）

- 编译通过（`BUILD SUCCESSFUL`），提交 `df78313`。
- **装机与真机验证未完成**：收尾时设备再次从 hdc 掉线（`list targets` 为空、`tconn` 失败）。
  已挂后台任务，设备回来会自动装包并重启 App。
- 已实测过的（上一轮，同一批代码路径）：`feed/user/{pk}/`（帖子 8/8）、`users/{pk}/info/`（头部）、
  `discover/topical_explore/`（推荐 16/16，截图确认三列瀑布流）。
- 本轮新增的三条分页端点与触底修复**尚未在真机上跑**；`MobileProbe.ENDPOINT_SCOUT` 里已加了
  `clips/user`（GET+POST）、`usertags/{pk}/feed`、`feed/saved`、`collections/list` 五条候选，
  设备回来后从设定页那颗自检按钮跑一次即可拿到"通不通 + 结构树"。
