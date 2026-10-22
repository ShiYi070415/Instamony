# Instarmony 1.2.0 —— 本版变化 / 已知问题

> 版本：`versionName 1.2.0`（`versionCode 1002000`，见 `AppScope/app.json5`）
> 包名：`com.oneleaf.instamony`（1.1.0 起从 `com.fanha.instarmony` 改名，属于**另一个应用**）
> 设备类型：phone / tablet　最低 API：6.0.0(20)　目标 API：26

1.2.0 是一次**"去网页化 + 真·实时"**的版本：把最后一个只在网页里才有的能力（模板回放）整段拆掉，
所有读接口改走移动端私有 API（与 instagrapi 同源）；同时把私信做到"**推过来**"——
MQTToT 长连接、实时落列表、实时插会话、系统通知、点通知直达会话。

## 下载

| 文件 | 用途 |
|---|---|
| `release/v1.2.0/Instarmony-1.2.0.app` | **App Pack**（`.app`，用于 AppGallery / 正式分发） |
| `release/v1.2.0/Instarmony-1.2.0.app.zip` | 同上，压缩包形态（部分渠道/浏览器对 `.app` 后缀不友好时用它，解开即是 `.app`） |
| `release/v1.2.0/Instarmony-1.2.0.hap` | 单模块 HAP（已签名），用于 `hdc install` 直接装机 |

- 构建命令：
  - HAP：`hvigorw --mode module -p product=default assembleHap` → `entry/build/default/outputs/default/entry-default-signed.hap`
  - App Pack：`hvigorw --mode project -p product=default assembleApp` → `build/outputs/default/*.app`
    （`--mode module` 下没有 `assembleApp` 这个任务）
- App Pack 内含 `entry-default.hap`，`pack.info` 里 `version.code=1002000 / version.name=1.2.0`，
  `apiVersion.compatible=20 / target=26`。

---

## 1. 架构：模板机制退役，全面改走移动端私有 API

这是本版工作量最大的一块（也是"为什么以前某些页面总是慢半拍"的根因）。

- **删掉模板表与模板回放链路**：`ApiRegistry`、`RestSession`、`WebRepost`、`DirectPrefetch`、
  `DirectCache`、`EngageSkeleton`、`WebTokens`、`resources/rawfile/api_templates.json` 全部移除。
- 首页信息流 / Reels / 评论 / 关注 / 收藏 / 搜索 / 通知页 / 私信 / 快拍 / 个人主页
  **逐个改走 `i.instagram.com/api/v1/…`**（`core/mobileapi/*`，字段照 instagrapi 逐条对齐）。
- **隐藏网页改为按需挂载**：只在真的要开网页兜底时才建宿主。
  前台 CPU 63~78% → **10.6%**，后台 69% → **3.2%**，内存 409MB → **262MB**。
- 冷启动不再串行等满 8 秒；快拍托盘改为交互优先级、提前到首屏之前发。

## 2. 实时通道（本版最大的新能力）

**MQTToT（MQQT over TLS）真的通了**（1.1.0 曾判定"本机不可用"，本版找到根因并修好）：

- 根因：**`on('message')` 必须在 `connect()` 之后注册**，之前注册的监听全被丢掉；
  以及载荷是 **zlib 压缩**，而 ArkTS 没有内存版 zlib —— 自己写了一份纯 TS inflate
  （`core/mobileapi/Inflate`，puff 风格）。
- 冷启动 **约 1.3 秒**就连上并订阅（`seq_id` / `snapshot_at_ms` 会落盘，先订阅再补差）。
- 收包后的**解压 + 派发挪到下一拍**执行，并记录 `inflate+dispatch ms=`（实测 1~7ms），不占主线程。
- 通道只读：**所有写操作（发消息 / 点赞 / 关注…）仍然走 REST**，节奏由 `ApiThrottle` 人速间隔把关。

## 3. 私信

### 3.1 零延迟

- 推送补丁（topic 146 `message_sync`）解析成"某条会话多了条消息"：
  **当前打开的那条会话直接插入**（不请求、不缓存），否则就地更新收件箱那一行并置顶。
- 会话页仍保留 12~25 秒随机轮询兜底（自己刚发完消息后 30 秒内 4~6 秒突发），
  90 秒无操作自动停 —— 节奏拟人，不做"秒级轮询"。

### 3.2 发消息

- **发送队列**：连点几下就排几条，一条条发（写接口有人速间隔）；不再"上一发还在飞就直接丢掉"
  （那是"一两条发不出去"的真凶）。
- 队列项自带 `threadId`：发送途中切会话也不会串到别人那里；切会话时未发完的**不再被丢弃**。
- 失败的那条**留在屏上标红**「未发送 · 点这里重试」，点击原样重发；状态行给出原因
  （`throttled-Nmin` / `challenge_required` / `send-…`）。
- 乐观气泡立刻可见（列表变长就贴底），气泡下方显示「发送中…」。
- 服务端副本回来时**同帧**撤掉本地那条，并**跳过入场动画** —— 不再"弹两条再收回一条"。

### 3.3 会话页视觉

- 列表铺到屏幕**顶部**（消息从标题栏下穿过），禁用组件自带下拉刷新，只保留触顶刷新 + 动画。
- 气泡入场：从下往上、由小至大、渐显，`curves.springMotion(0.65, 0.56)` 带过冲；
  进会话时从最新一条往上逐条弹（22ms 一档，封顶 16 档）。
- **刷新不再整屏重弹**：`ForEach` 的键只认消息 id（不带序号），发送后的刷新改"增量合并"。
- 触顶刷新保留锚位（撤掉 LazyForEach —— 那会重置滚动位置，造成"一直回到底部"的死循环）。

### 3.4 通知

- 本地系统通知：标题 = **发信人的显示名**（`XingLi`，没有才退回 `xingli_415`），正文 = 消息内容
  （图片/视频/语音/闪照有中文占位）；「私信」分类注册为 `SOCIAL_COMMUNICATION`（社交），
  动态走 `SERVICE_INFORMATION`。
- 判据是"**这条会话真的来了新消息**"（按消息时间戳），不是未读总数 ——
  未读条数封顶 4，按总数判会漏掉"同一条会话继续来消息"。
- 全程异步：整条流程挪到下一拍；取 WantAgent 只等 400ms，超时也先发通知。
- **点通知直达那条会话**：会话 id 同时放进 `want.parameters` 与 `uri`
  （`instarmony://open?route=direct&id=…&from=notify`），两条通道任一生效即可；
  冷启动会被启动期的 `session changed → nav stack cleared` 清栈，所以做了 500ms × 15 次重试，
  并且判"是否已在会话里"用 Nav 栈真实栈顶 + 底栏 + 会话 id 三者一起看。

## 4. Reels

- 关注流 / 探索流**分成两页**，分段按钮在标题栏那一行居中（沉浸光感，套用「我的」页那款）；
  文本「探索 / 好友」。
- 首屏改用 instagrapi 的三条 `clips` 通道；翻页"作者页优先 + 探索流补货"，
  修掉"到底不加载 / 全是固定重复"（`busy` 没收 + `clips/user` 游标读错）。
- 滑动切换动画不再被自己掐断（删掉受控 `.index()`），同作者不再连着出现。

## 5. 信息流与"我的"

- 聚焦播放换判据：媒体矩形 + 三把尺子 + 单一滞回（删掉四条互相打架的旧特例）。
- 探索流：第一页落盘（冷启动 20 秒 → <1 秒）、触底零等待（预取 + 队列）、多图/图文视频适配。
- 点赞 / 转发连点不再"没反应"（合并意图，最后一次点击说了算）；转发改走移动端私有接口。
- 骨架屏按真实组件尺寸逐块占位；冷启动一律占位动画，不再"铺上次缓存再覆盖"。
- 设置页改「圆角实线卡片 + 分类标题在卡片外」，新增「图片和视频」清晰度（图片质量 / 视频质量）。

## 6. 稳定性 / 性能

- 修掉偶发 **appfreeze**（`waitPageReady` 的等待循环退化成微任务自旋）+ 新增主线程看门狗。
- 修掉会话页 **jscrash**：气泡分组取"上一条消息"时索引越界
  （`ForEach` 的序号与之后重算的列表不一致 → `Cannot read property mine of undefined` → 进程被杀）。
- 私信进会话取数从 2.5s → **0.38s**（去掉文本快照缓存 + 那一发插队）。
- 请求节奏全局闸门（`ApiThrottle`）：起发间隔分档（urgent / interactive / warm / idle），
  写操作 3~6 秒人速间隔；私信家族可被单独冷却。

## 7. 已知问题 / 本版没做到

- **远程推送（Push Kit 云端下发）**：本地通知已完备，`pushService.getToken()` 与 `tokenUpdate` 已接；
  但云端下发仍差代码之外的东西 —— AGC 里的 `client_id`（当前 `getToken` 报
  `1000900010 客户端身份非法`）、一台转发服务、证书链配置。所以**App 被系统杀掉后收不到通知**。
- **`.app` 装机渠道**：App Pack 需要 AppGallery / 正式证书配置才能真正分发；本仓产物是调试签名。
- 点通知进会话依赖 Nav 栈时序，冷启动偶发需要 1~3 秒才落到会话页（已做重试，期间会先停在首页）。
- 网页兜底仍保留（登录、验证、个别写操作失败时的出口），但不再是主链路。

## 8. 升级提示

- 版本号：`1.1.0` → `1.2.0`（`versionCode 1001000` → `1002000`）。
- **包名在 1.1.0 已改为 `com.oneleaf.instamony`**：它与旧的 `com.fanha.instarmony`
  是两个应用，覆盖安装不会生效，需要先卸载旧包；本地数据（设置、缓存）不迁移。
- 覆盖安装不需要重新登录（会话来自 Cookie 罐）；账号分区缓存沿用。
- 若私信列表为空：下拉刷新一次，或等实时通道连上后自动补差（会重建收件箱快照）。
