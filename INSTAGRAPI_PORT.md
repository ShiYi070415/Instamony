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

1. ~~拿到一次编译通过~~ —— **已完成**（2026-10-16，见 3.1）；剩下的签名问题见 3.3。
2. **跑自检**，把第 4 节那三行日志回报给用户 —— 这决定整条路线是否成立。
3. **实现 stories 端点**（`core/mobileapi/MobileStories.ets`）：
   - 参照 `instagrapi/mixins/story.py`：`get_reels_tray_feed` → `feed/reels_tray/`、
     `user_stories` → `feed/user/{id}/story/`、`reels_media` → `feed/reels_media/`
   - 响应模型对齐现有 `model/Story.ets`（`StoryReel` / `StoryItem`）；
   - 现有实现 `core/NativeStories.ets`（1441 行）是硬试「一条 URL × 三种身份」，
     新的作为**第一优先**、失败回退它。
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
7. **诊断面板接线**：把 `MobileProbe.lastSummary()` 挂到设置里的诊断项（现有机制见
   `components/SettingsPanel.ets` 与 `core/StoryDiag.ets`）。

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
| 签名 | **阻塞**：证书 2026-10-10 过期（见 3.3，用户自行处理） |
| 模拟器真机验证（跑自检看三行结论） | 未开始（等签名） |
| stories / direct_v2 端点 | 未开始 |

### 下一步的最短路径

1. 把签名换掉（DevEco 自动签名 / 或 3.3 的手动重签）→ 出可安装的 HAP。
2. `hdc install -r` 装上，启动，抓 `MobileProbe` 三行日志。
3. 按第 4 节判读：**全通** → 继续做 stories / direct_v2；
   **`login_required`/`challenge_required`** → 这条路线不成立，回去和用户讨论要不要做密码登录（L3）。

