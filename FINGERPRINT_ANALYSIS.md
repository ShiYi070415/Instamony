# 为什么 Instarmony 容易被 IG 判成自动化 —— 排查与对策

> 版本基线：0.9（`versionCode 9000`）　排查时间：2026-10-17
> 结论先行：**不是"WebView 登录 + i.instagram.com"本身**，而是三件事叠加：
> **① 身份不自洽（最重）② 位置/语言/时区与大环境矛盾 ③ 节奏与体量像爬虫。**
> 你提的两个方向都对了一半，下面逐条给证据与改法。

---

## 1. 我们现在到底"像什么"

把一条请求拆开看（`core/mobileapi/MobileRequest.baseHeaders` + `MobileSession`）：

| 报出去的东西 | 值来自 | IG 侧看到的语义 |
|---|---|---|
| `Cookie` | ArkWeb 罐（网页登录产生） | 一个**浏览器**会话：`sessionid`、`csrftoken`、`ds_user_id`，外加 `ig_did`、`dpr`、`wd`、`ig_nrcb`、`ps_l`、`ps_n`、`mid` |
| `User-Agent` | `Instagram 449.0.0.52.84 Android (34/14; 480dpi; 1344x2992; Google/google; Pixel 8 Pro; …)` | **安卓官方 App** |
| `X-IG-App-ID` | `567067343352427`（安卓 App 的 app id） | 安卓官方 App |
| `X-IG-Device-ID` / `X-IG-Android-ID` / `X-IG-Family-Device-ID` / `_uuid` / `phone_id` | 本项目**自己生成**并持久化（`MobileSession`） | 一台**全新设备** |
| `X-MID` | **网页 cookie 里的 `mid`** | 一台**浏览器**的机器 id |
| `Authorization` | `IGT:2:<base64>`（`MobileSession.buildAuthorization`，能捡到服务端下发的就捡） | 试图冒充 App 会话 |
| `X-IG-Timezone-Offset` | 恒定 `-14400`（`MobileConfig.DEFAULT_TIMEZONE_OFFSET`，纽约） | 美国东岸 |
| `X-IG-App-Startup-Country` | 恒定 `US`（`DEFAULT_COUNTRY`） | 美国 |
| `Accept-Language` / body `locale` | 恒定 `en_US`（`DEFAULT_LOCALE`） | 美国 |
| `IG-U-SHBID` / `IG-U-SHBTS` / `IG-U-RUR` / `IG-U-IG-DIRECT-REGION-HINT` | `MobileConfig.FixedHeaders` **现造**（userId + 假 HMAC + `now+1y`） | 伪造的服务端令牌 |
| `X-IG-Nav-Chain` | 恒定 `9MV:self_profile:2,ProfileMediaTabFragment:self_profile:3,9Xf:self_following:4` | 每条请求的"导航历史"都停在同一页 |
| `X-FB-HTTP-Engine` / 压缩 | 声明 `Tigon/MNS/TCP`；但我们**主动丢掉** `Accept-Encoding`（无 gzip）、也丢 `Host`/`Connection` | 栈与声明不符 |

一句话：**会话是浏览器的，身份是安卓 App 的，位置是美国的，节奏是脚本的。**

---

## 2. 三条根因（按可疑度排序）

### 根因 A：身份不自洽 —— 浏览器会话被搬到"一台从没登录过的设备"（最重）

IG 内部把**登录事件**与**设备身份**绑定（`mid` 是 machine id，`ds_user_id + sessionid` 是会话，
`device_id/android_id` 是设备）。我们交给它的是：

```
浏览器产生的 sessionid / ds_user_id / mid / ig_did     ← 设备的“身份证”是浏览器的
+ 本项目新造的 device_id / uuid / phone_id / android_id ← 请求声称来自一台安卓设备
+ Authorization: IGT:2:…                                ← App 才有的令牌
```

在风控视角里这就是**"网页会话被导出、在另一台设备上重放"**—— 而"导出会话"是账号接管/自动化的
典型特征。更糟的是我们**同时**还在用网页身份发 GraphQL：

```
www.instagram.com/graphql/query   ← app-id 1217981644879628 + Chrome UA + 网页模板头
i.instagram.com/api/v1/…          ← app-id 567067343352427 + Instagram UA + IGT:2
```

**同一个 sessionid 在一分钟内交替出现两种完全不兼容的客户端**（浏览器 vs 官方 App），
真实用户不可能做到。这是本项目独有的一条强信号，`instagram-private-api` 那类库不会有。

> 补充：本体**并没有**"偷 token"式地伪造，`Authorization` 能捡服务端下发的就捡；
> 但"捡不到就用 `buildAuthorization` 现算"这一手本身也是推断出来的格式，同样属于"我们造的"。

### 根因 B：位置 / 语言 / 时区 / 国家全部恒定成美国

`MobileConfig.ets` 里三条常量写在**默认值**上，`MobileSession` 构造时直接赋值：

```ts
this.locale = DEFAULT_LOCALE;              // 'en_US'
this.country = DEFAULT_COUNTRY;            // 'US'
this.timezoneOffset = DEFAULT_TIMEZONE_OFFSET;  // -14400（纽约）
```

而设备（你自己的手机）在 **UTC+8**，网页登录也在同一台设备上完成（浏览器时区 = +8）。
于是同一条请求里：**cookie 说 +8，头里说 −4，IP 说香港/内地** —— 这是最廉价、也最稳定的判定特征之一
（instagrapi 里这三个值都是可配置项，就是为了对上真实环境）。

### 根因 C：节奏与体量像爬虫

从 0.9 的真机日志里能直接量出来（一次冷启动，前 40 秒）：

```
00:00.8  feed/reels_tray/           434 KB   ← 托盘
00:03.5  feed/user/{uid}/story/ × 5            ← 5 位用户的快拍预取（进了启动预热）
00:04.4  direct_v2/inbox/           822 KB   ← 收件箱（并行预取）
00:15~35 通知链 3 发 + discover/topical_explore/ 1.26 MB
00:56    feed/user/{uid}/           376 KB   ← 我的·帖子
01:00    usertags/… 344 KB · feed/saved/ 1.17 MB · clips/user/ …
之后      每 3~6 秒一发 1 MB 级 explore（搜索推荐自动补满 + 预取队列）
常驻      私信会话 4 秒一次轮询
```

闸门是 `ApiThrottle` 的 **900ms ± 400ms** —— 节奏太稳，且"每次冷启动跑同一条链"本身就是脚本特征。
正常用户 40 秒内不会接触 `discover/topical_explore`、`clips/user`、`feed/saved`、`usertags`
这四个端点全一遍。IG 的 `feedback_required`（"We limit how often you can do certain things…"）
正是这一类的桶。

### 附带：网页侧的自动化痕迹（不等于 App 侧，但也算）

`bridge/WebScripts` 在页面里挂了 `window.__ogSessionWatch` / `__ogNetWatch` / `__ogReplay` /
`__ogCap` / `__ogFeedCfg` / `__ogCommentCfg` 与桥对象 `window.ogNative`，还包了 `fetch` / `XHR`，
并 `setInterval(detect, 3000)`。这些**页面 JS 可以直接枚举到**（`Object.keys(window)` 里就有），
而且是"非 IG 注入的全局 + 被改写的 fetch"这种最典型的扩展/自动化痕迹。

---

## 3. 你两个猜想的评估

**① "登录环境采用真实数据（设备型号、位置、UA、请求头）"**
→ **方向对，但重点不是"更真"，而是"自洽"。** 我们已经在冒充 Pixel 8 Pro + 官方 App 头了，
问题是这套"假设备"和**浏览器会话**、和**真实地理位置**互相矛盾。所以：
- 优先级最高、成本最低：**把时区/语言/国家改成真机的**（收益立刻可见）；
- 型号/UA **不必再换**（换来换去等于天天换设备，比不换更可疑）；
- 服务端下发的令牌（`IG-U-*`）**不要伪造**，没有就不发。

**② "WebView 登录后提取 token 走 i.instagram.com 导致被检测"**
→ **是主因之一，但不是"用了 `i.instagram.com`"这件事**，而是"浏览器会话 + App 身份"混用。
两条干净的路：
- **全用浏览器身份**：`www.instagram.com/api/v1/…` + `x-ig-app-id=1217981644879628` + Chrome UA +
  `x-csrftoken` / `x-ig-www-claim` / `x-asbd-id` / `x-requested-with`。
  问题：`direct_v2/*`、`feed/reels_tray`、`clips/user`、`feed/saved`、`usertags` 这些**网页不给**，
  所以这条路只能覆盖一部分，不能全替代。
- **全用 App 身份（推荐继续走，但要"一次性落地"）**：设备身份生成一次就**永久固定**（现在是持久的 ✓），
  但还要：`X-MID` 用 **App 侧自己的 mid**（不是网页 cookie 里的）、app 请求不再带网页专属 cookie
  （`ig_did` / `dpr` / `wd` / `ig_nrcb`）、**同一会话不要在一分钟内混用网页 GraphQL 与 App REST**。
  最彻底是 App 内走官方 App 登录拿"原生会话"，但你不希望 App 收密码 → 见下面阶段三。

---

## 4. 建议的改法（三阶段，按投入产出排序）

### 阶段一：降噪（零风险，收益最大，建议立刻做）

| 项 | 现在 | 改成 |
|---|---|---|
| 启动预取 explore（1.3 MB） | 有 | **删掉**，改为"用户真的切到搜索页时再拉" |
| 启动快拍预取人数 | 5 位用户 × 1~2 发 | **2 位**，且只在托盘可见时 |
| 通知链预热 | 启动即跑 3 发 | 延后到首屏稳定后（或用户点爱心时） |
| 私信会话轮询 | 4 s | **25~30 s**，页面不可见/后台就停 |
| 搜索推荐自动补满 + 预取队列 | 每 3~6 s 一发 1 MB | 一次访问最多 2 页；不再"自动补满一屏" |
| reels 的 explore 兜底 | 启动预热也发 | 只在**用户进 reels 页**且 clips 冷却时发 |
| `feedback_required` 冷却 | 12 分钟（`ApiThrottle`） | **30~60 分钟**，并暂停该账号所有**可选**流量（预取/轮询），状态行写明原因 |
| 重复请求 | 日志里出现过同一 URL 连发两发 | 加 in-flight 去重（按 URL+参数） |

预期效果：**每 5 分钟请求数与字节数下降一个数量级**，`feedback_required` 出现频率显著下降。

### 阶段二：身份自洽（低风险，改动集中在 `MobileConfig` / `MobileRequest` / `MobileSession`）

1. **时区/语言/国家跟随系统**：`X-IG-Timezone-Offset`、body 里的 `timezone_offset` 用
   `new Date().getTimezoneOffset()` 反算（+8 区 → `28800`）；`Accept-Language` 与 `locale`
   走系统语言（`zh_CN`）；`X-IG-App-Startup-Country` 用网络/SIM 国家，拿不到就**不发**（现在是恒 `US`）。
2. **不再伪造 `IG-U-*`**：`FixedHeaders.shbid/shbts/rur/directRegionHint` 只在
   `identity` 里**有服务端下发的真值**时出现（`absorbResponseHeaders` 已经能捡），否则省略。
3. **删掉固定的 `X-IG-Nav-Chain`**（或只对 profile 类端点、且值随页面变化）。
4. **App 请求不带网页专属 cookie**：`Cookie` 头里过滤 `ig_did` / `dpr` / `wd` / `ig_nrcb` / `ps_l` / `ps_n`。
5. **`X-MID` 用 App 侧 mid**：把首次 App 侧拿到的 `mid`（响应头里的 `x-ig-set-mid` 或 App 登录产出的）
   持久化，别再用网页 `mid`；拿不到就**不发**这个头（比发一个矛盾的值好）。
6. **不要把两种身份放在同一分钟**：给"网页身份请求"和"App 身份请求"加最小间隔（例如 ≥ 60 s），
   或干脆把网页身份那条收敛成"只在必须抓模板时用"。
7. `Accept-Encoding` 交回 ArkWeb/http 栈（现在为了避坑主动丢，代价是"没有 gzip"这个特征）。

### 阶段三：最彻底（需要你拍板）

- **App 内走官方 App 登录**（`/api/v1/accounts/login/` + `enc_password` + 完整设备载荷），
  拿一个"真的是这台设备登录的会话"；网页登录保留为备用。
  代价：App 需要接触账号密码（或让用户在一个"App 登录"页里输），与当前"密码只在网页里输"的
  设计冲突。设置页可以做成二选一，让用户自己决定。
- 或者：**接受"只读、低频"** —— 把 App 定位成"浏览 + 不写"，把预取压到最低，
  这样即使身份混用，行为风险也小。

### 不建议做的事

- ❌ 频繁换 UA / 换设备型号 / 随机指纹轮换（每次换 = 新设备，比不换更可疑）。
- ❌ 挂代理跳国家、或在不同国家间切换（与 cookie 里的时区/语言更矛盾）。
- ❌ 提高并发/缩短间隔来"抢速度"（我们现在的问题恰恰是太快）。
- ❌ 用多个 cookie 罐/多账号在同一 IP 高频切换（同一出口 + 多账号是强关联信号）。

---

## 5. 怎么验证改法有效（别靠感觉）

同一台设备、同一账号，跑同一套"冷启动 + 切五个页签 + 滑两屏"动作，统计：

1. **风险响应计数**：10 分钟内 `feedback_required` / `rate_limit_error` / `challenge_required` 各几次
   （`MobileRequest.classify` 已经把这三类分出来了，日志里有）。
2. **流量基线**：每 5 分钟的请求条数与总字节（现在冷启动前 40 秒约 **4~5 MB / 15~20 发**，
   其中 explore 与 saved 各占 ~1.2 MB）。
3. **端点成功率**：`MobileProbe.run()` 那 9~10 发（设定页那颗自检按钮即触发）的 `ok=N/M`。
4. 观察 `filesDir/Instarmony_mobile.txt` 与 `Instarmony_diag.txt` 里新增的失败原因。

阶段一做完就应该能看到 (1)(2) 明显下降；阶段二主要影响 (1) 与"账号被要求验证"的频率。

---

## 6. 参考

- 本仓库 `INSTAGRAPI_PORT.md` 第 9~13 节：移动端协议移植的实测表（含哪些端点在什么身份下通/不通）。
- instagrapi（本项目移动端协议的蓝本）：<https://github.com/subzeroid/instagrapi> 与文档
  <https://subzeroid.github.io/aiograpi/>。它把 **locale / country / timezone_offset / 设备设置**
  做成可配置项并支持会话持久化（`get_settings` / `set_settings` 一类接口），
  请求之间默认还有 `delay_range` 这类人为间隔 —— 正是为了"环境自洽 + 不像脚本"。
  另外我们这份 `MobileConfig` 里那几个 `IG-U-*` 固定串就是照它抄的（`config.py` 里它们也是硬编码），
  所以它们不是"更真"，只是"和历史库一致"。
- `instagram-private-api` 的设备/Feed 文档：<https://github.com/dilame/instagram-private-api>
  （`TopicalExploreFeed`、`UsertagsFeed`、`UserFeed` 等端点的官方参数，本项目第 12 节即据此实测）。
- 本次排查用到的现场证据：`hilog` 七个 tag（`MobileRequest` / `MobileSession` / `MobileDiscover` /
  `MobileProfile` / `NativeReels` / `NativeSearch` / `InstarmonyHome`）+ 设定页的移动 API 自检报告。
