# Instarmony 0.9 —— 功能 / 已知问题 / 未实现

> 版本：`versionName 0.9`（`versionCode 9000`，见 `AppScope/app.json5`）
> 形态：HarmonyOS NEXT 原生 ArkUI + **一个常驻隐藏 Web 组件**（`components/InstagramWebHost`）
> 包名：`com.fanha.instarmony`　设备类型：phone / tablet　最低 API：6.0.0(20)

---

## 0. 一句话架构

会话**完全来自 Instagram 官方网页**：隐藏 Web 加载 `instagram.com`，用户在网页里登录，
原生侧只读 **ArkWeb 的 Cookie 罐**（会话 Cookie 是 HttpOnly，页面脚本看不到）。
取数有两条路：

1. **移动端私有 API 直发**（`core/mobileapi/`，照 instagrapi 的协议实现）——
   自己的请求头套（`X-IG-*` / `signed_body` / `Authorization: Bearer IGT:2:`）、
   不依赖任何网页模板，**这是 0.9 的主路**；
2. **网页模板回放**（`bridge/ApiRegistry` 抓下网页自己发过的请求，原生照原样重发）——
   0.8 时代的主路，现在作为**回退**保留。

再加第三条兜底：让隐藏网页整页导航过去、由页面脚本读 DOM（`bridge/WebScripts`）。

---

## 1. 已实现功能

### 1.1 登录与账号

| 功能 | 说明 |
|---|---|
| 整页登录页 | 未登录时**整页**显示（品牌 + 三条提示 + 登录按钮 + 「我已登录，重新检查」），标题栏与底栏一并收走；背景是强调色光晕渐变，材质走沉浸光感 |
| 网页登录 | 只有点「登录」才把隐藏网页亮出来并导航到 `/accounts/login/`；本 App **不接触账号密码** |
| 登录态判定 | 以 **Cookie 罐**为唯一权威（`sessionid` / `ds_user_id`）；网页 DOM 的「已登录」只是快信号，**必须先回罐复核**（防误报导致的导航循环） |
| 登录后立即取数 | `applySession(true)` → 信息流 + 整条预热链（reels / 私信 / 搜索 / 我的四段） |
| 账号分区 | 每个账号一份独立缓存槽（信息流 / reels / 搜索×2 / 私信快照 / 请求模板 / 账号槽），换账号互不可见（`core/AccountScope`） |
| 退出登录 | 清 Cookie + WebStorage + HTTP 缓存 + 全部内存态 + 诊断文件；活跃分区**搬到备份位**（本人以后回来可恢复）；随后停在原生登录页 |
| 未登录闸门 | 未登录时只放行 `/accounts/…`、`/challenge`、`/consent` 的导航，其余一律丢弃（`core/SessionGate`） |

### 1.2 首页信息流（底栏「主页」）

- 帖子卡片：作者行（头像 / 名字 / 关注按钮）、媒体区、动作区（点赞 / 评论 / 转发 / 分享 / 收藏）、配文、时间。
- **多图 / 多视频媒体**：`MediaCarousel` 轮播，含视频页（走 `VideoSurface` 播放逻辑），按"最高一张图"的比例排版。
- **视频自动播放**：可见即播、预加载下一条；上滑离开屏幕后**立即失焦停播**（含连续长比例视频那条已知问题的修复）。
- 下拉刷新、触底自动翻页、骨架屏、失败原因写在状态行。
- 快拍托盘置顶（见 1.3），左右**不留白**（内容穿过屏幕边缘）。
- 封面走"展示档"（≤1080）省流量；`core/PosterCache` 预解码 + `core/MediaPrefetch` 预下载前几条。

### 1.3 快拍

- 托盘：启动预热（回到 213~220 条），环的状态（是否已看完）按 `seen` 与 `latest_reel_media` 比较得出。
- 内容：**移动端私有 API**（`feed/reels_tray/`、`feed/user/{pk}/story/`、`feed/reels_media/?reel_ids=<裸 id>`），
  老路（模板 + 网页脚本）保留为回退。
- 播放器：进度条、点按前进/后退、长按暂停、右滑收起、图片 5 秒自动前进；
  消息里带失败原因，失败现场落盘 `Instarmony_diag.txt`。

### 1.4 Reels（底栏「视频」）

- 全屏竖向播放器：当前条 `playing`、下一条 `preload`，切过去基本立刻出画面。
- 右侧动作区（点赞 / 评论 / 转发 / 分享 / 收藏）+ 底部作者行（头像 / 名字 / 关注）+ 配文 + 音乐。
- 标题栏右侧：静音、下载（按来源分别记状态：底栏 / 主页视频分页 / 搜索推荐，见 `core/ReelsAction`）。
- 数据来源：**GraphQL `PolarisClipsTabRootPaginationQuery` 模板回放** → 被限流或不可用时
  **移动端探索流兜底**（`discover/topical_explore/`）→ 再不行走网页冷路径。

### 1.5 私信（底栏「私信」）

- 收件箱列表（20 条起，翻页到 9 月）、未读、时间、头像、群聊与 1:1。
- 会话页：气泡（文本 / 媒体 / 分享帖 / Reel / 贴纸 / 语音等，`DirectMapper` 覆盖 XMA 三类）、
  最新消息贴底、顶部居中加载动画、翻历史、**输入法避让（实测矩形自校正）**。
- 发送文本消息（乐观发送 + 失败标记 + 重发）。
- 数据来源：**移动端私有 API**（`direct_v2/inbox/`、`direct_v2/threads/{id}/`）；
  翻页游标用 `oldest_cursor`（查询串）。
- 预取：进首页时并行拉一次收件箱；切到私信列表时**预取各会话最近 5 条**（仅文本，媒体用占位）并落盘
  （`core/DirectCache` / `core/DirectPrefetch`）。
- 实时：会话页 4 秒轮询（`core/DmRealtime`）。

### 1.6 搜索（底栏「搜索」）

- 关键词 → **账号结果**（头像 / 名字 / 认证 / 私密 / 数字 id），点一下进原生用户主页。
- 空关键词 → **推荐瀑布流**（三列、按封面自身比例、点开进 Reels 页）。
- 数据来源（0.9 起都不再依赖模板）：
  - 账号：`fbsearch/account_serp/`（失败退 `users/search/`）→ 再退 REST → 再退模板；
  - 推荐流：**`discover/topical_explore/`**（与 reels **不是同一发请求**）→ 模板（explore/clips）→ 信息流推荐卡片。
- 落盘缓存（`core/SearchCache`）+ 首页预热时预取第一页；瀑布流分页有预取队列。

### 1.7 我的（底栏「我的」，四个分页）

| 分页 | 0.9 走哪条 | 回退 |
|---|---|---|
| 帖子 | `feed/user/{pk}/?count=24` | `PolarisProfilePostsQuery` 模板 → 冷路径抓模板 |
| Reels | `clips/user/`（**不签名表单** + `target_user_id`） | `PolarisProfileReelsTabContentQuery` 模板 |
| 收藏 | `feed/saved/`（媒体在 `items[].media`） | `PolarisProfileSavedPostsTabContentQuery` 模板 |
| 被标注 | `usertags/{pk}/feed/` | `PolarisProfileTaggedTabContentQuery` 模板 |

- 头部（头像 / 名字 / 简介 / 外链 / 认证 / 私密 / 三个计数 / 关注状态）：`users/{pk}/info/`（或按用户名 `usernameinfo/`）。
- 切分页**不再重新加载**：每段各存状态（列表 / 游标 / 是否加载过），切回只预取下一页；切新分页也不再触发"抓模板"。
- 进首页时后台把**四段第一页 + 媒体预解码**都备好（`preloadAllSegments`）。
- 别人主页复用同一套页面（`USER_PROFILE_PAGE`），视频分页可进 Reels 页。
- **这四段转出来的卡片（feeds 页 / Reels 页）现在带点赞态**（0.9 修复）：载荷里的
  `has_liked`（GraphQL 是 `viewer_has_liked`）以前没读，于是从「我的」点进帖子页永远是灰心；
  现在按"短码台账 → 媒体 id 台账 → 载荷"取。媒体 id 也改成**只认精确来源**
  （`strong_id__` → `id` 的 `_` 前段 → 字符串 `pk`），拿不到就用短码问一次 `oembed/`
  （`MobileEngage.mediaPkFor`）—— 这四段的点赞/收藏/补视频地址全靠它，
  否则 19 位 `pk` 丢精度的值会打到一条不存在的媒体上。

### 1.8 帖子页 / 评论 / 互动

- 帖子页把整个分页整理成 feeds 流样式；评论区是浮层（评论 / 回复 / 点赞评论 / 发评论 / 媒体评论）。
- 点赞、收藏、转发、关注：**模板回放优先**，失败再退回网页驱动（关注有网页兜底；取关只认 HTTP 结果）。
- 互动状态有会话级覆盖表（`FollowState` / `SaveState` / `EngageState`），避免翻页把状态顶回去。
- **点赞态跨页面一致**（0.9 修复）：`engage` 台账同时按**媒体 id** 和 **shortcode** 记一份，
  Reels 页（底栏 / 视频分页 / 搜索推荐）点赞后退出重进、切底栏回来，那颗心都保持红色；取消赞同理。
- **正文翻译**（发布时间旁 / 评论"回复"旁 / Reels 正文最后那一颗）：只对非中文文本出现，
  点了翻成**系统语言**、再点回原文。0.9 修复"全部文本点翻译都失败"：
  gtx 那条被 Google 按 IP 限流（`http-429`），现在 ①gtx → ②`clients5.google.com`
  → ③MyMemory **三级兜底**，每发都带浏览器请求头，成功的那个钉成本会话首选；
  译文等于原文（MyMemory 常见）按失败处理。启动 5 秒后会打一次三发自检并落盘
  `filesDir/Instarmony_translate.txt`（`Translator.scheduleSelfTest`，可关）。
  ⚠️ 待翻译的正文会发到第三方接口。

### 1.9 通知页

- 标题栏爱心进入：聚合列表（点赞 / 评论 / 关注 / 提及…）、推荐关注（ayml）、点条目进对应用户或帖子。
- 分组按**日历天**分桶：`今天 / 昨天 / 过去 7 天 / 过去 30 天 / 更早`，最后是 `为你推荐`
  （0.9 改；以前只有 今天/本月/更早 三档，昨天和三十天前的看起来一样新）。
  判据是"两个日期都归到当天 00:00 再算天数差"—— 凌晨看昨晚的通知落"昨天"，不会被算成今天。
- **分段折叠**：默认只展示到「过去 7 天」，紧跟其后一颗「显示更多」；
  点开就把「过去 30 天」与「更早」**整段放出来（不截断条数）**，按钮自己消失；
  「为你推荐」固定在最后一段（不在折叠区里，随时可见）。
- 数据来源（0.9 起 **instagrapi 协议优先**，见 `core/mobileapi/MobileNews`）：
  `POST i.instagram.com/api/v1/news/inbox/`（通知主列表）→
  `POST i.instagram.com/api/v1/friendships/show_many/`（这批人的关注状态）→
  「为你推荐」走网页兜底（模板 / 骨架）。
  移动端这一路**不需要任何网页模板或专有令牌**，和快拍 / 私信 / 主页 / 点赞同一套身份。
  整条失败（没会话 / 被限流 / 形状不认识）才退回原来的网页 REST 那条，输出同构。
- 解析按真机形状做了加固：移动端 `args` 字段类型更松（对象/数字）、文案里的用户名是
  **占位符**（`{用户名|…|user?id=…}`），都由 `expandPlaceholders` / `str` / `idOf` 处理。
- 分组标题「本月」现在是 `10月`（以前把 `%d月` 当文案画出来了）。

### 1.10 设定页与外观

- 底栏原生动效开关、材质厚度（极薄/薄/常规…）、沉浸光感档位（自适应 / 强制 / 关闭）。
- 诊断三件套：导出诊断日志、复制诊断摘要、抓故事页模板（测试）、跑移动 API 自检（测试）+ 结果行。
- 退出登录（底部）。

### 1.11 诊断与自检（0.8 起积累，0.9 保留）

- `core/StoryDiag`：快拍失败逐发轨迹；`core/mobileapi/MobileProbe`：移动 API 9~10 发自检 + 结论落盘
  `filesDir/Instarmony_mobile.txt`；**端点侦察**（`ENDPOINT_SCOUT`，默认关）写 `Instarmony_scout.txt`；
- `probe/InstagramProbe`：网页探针面板（请求 / 响应样本、模板清单、DOM 摘要）；
- 常驻诊断行：`web route`、`page begin`、`main frame error`、`navigation blocked (signed out)` 等。

### 1.12 缓存 / 限速 / 资源

- 落盘缓存：信息流、reels、搜索、私信快照、请求模板（均按账号分区）。
- 主动限速闸门 `core/ApiThrottle`：同一时刻只发一发、最小间隔 900ms±400ms（交互 250ms）、
  优先级插队（交互 / 预热 / 空闲）、撞限流记 12 分钟冷却。
- 媒体：展示档 / 原档分离，下载走 `core/MediaDownloader`；沉浸光感材质见 `components/MaterialSurface`。

---

## 2. 已知问题（Bug / 限制）

### 2.1 数据源相关（影响内容完整性）

1. **Reels 主路（clips GraphQL）常被 IG 限流**：响应 `{"message":"Rate limit exceeded","code":1675004}`
   → 12 分钟冷却。此时靠移动端探索流兜底，**排序是个性化较差的"推荐/探索"**，音乐/封面字段也可能稀疏。
2. **账号级 `feedback_required`**：短时间内密集请求（本项目测试时遇到过）会让 IG 回
   "We limit how often you can do certain things"，此时探索流、clips 一起被拒 → 推荐流与 reels 兜底同时为空，
   等冷却自动恢复（限流原因会写进状态行）。**通知那条链也会被限**（`news/inbox/` 排队到十几秒、
   甚至整段失败）—— 移植测试期间就撞上过一次，等冷却即可。
3. **通知的移动端两处仍是半通**：
   `POST i.instagram.com/api/v1/discover/ayml/` 回 **400**（签名 / 不签名 / GET 都试过，
   body 是 `{"status":"fail","status_code":"400"}`）→ 「为你推荐」只能走网页兜底（要模板）；
   `POST i.instagram.com/api/v1/friendships/show_many/` 回 200 但**不带** `friendship_statuses`
   （60 字节）→ 关注按钮的状态改用载荷里的 `inline_follow/following`，不再逐个问。
3. **信息流首屏仍依赖网页模板**：没有模板时只能走"导航网页 + 让页面自己发请求 + 抓模板"的冷路径（秒级）。
   模板过期（IG 回 `1357004`）同样触发重抓。
4. **评论 / 点赞 / 收藏 / 转发**同样是模板回放，模板要在"真的进过一次帖子页"之后才有；
   转发与收藏的状态字段在部分载荷里缺失（界面用会话覆盖表兜）。
5. **搜索"结果"那条 GraphQL 模板已经抓不到**（IG 页面打完字不发请求）→ 现在靠移动端 / REST 顶着，
   模板那条路目前是断的。
6. **主页 Reels / 收藏分页的移动端点是"试出来"的**：`clips/user/` 必须用不签名表单，
   `feed/saved/` 的媒体在 `items[].media`。IG 改版即失效（各分页都有模板回退，不会白屏）。

### 2.2 交互 / 显示

7. **快拍"已看"不上报**：不写 `seen` 状态，环不会因为看过而变灰（下次进还是渐变环）。
8. **搜索推荐流"触底刷新"的修复尚未在真机确认**（修的是 `loadMore` 误按 clips 限流锁停手），
   验证时正好撞上账号冷却，没跑起来。
9. **信息流"高视频黑底占位"** 与 **Reels 视频宽高诊断**两项遗留未处理（`AUDIT_TODO.md` 有记录）。
10. **点赞的"数"不跟着回灌**：状态（红/灰）以台账为准，但计数仍显示缓存载荷里的旧值
    （例：刚点完 580，退出重进显示 579），要等下一次真正重新拉取才对齐。
    台账只在内存里，App 重启后清空 —— 那时点赞本身已经在服务端生效，重拉一次就是对的。
11. **大载荷**：探索流一页 0.8~1.3MB（模板那条约 400KB），移动网络下每次翻页都偏重。

### 2.3 运维 / 工程

12. **`core/DmRealtime` 4 秒轮询**：耗电与限流风险都在（只在会话页前台时跑）。
13. **死代码待确认**：`WebScripts.commentsByReplayScript` 只在注释里被提到，删前需确认没有按名字间接调用。
14. **快拍取数在"被要求安全验证"的账号上仍会失败**（历史问题，根因是账号/IP 被 IG 判风险，
    现在移动端这条路已绕过大部分场景）。
15. **调试环境**：无线 hdc 目标会因"反复 `tconn` / 多个 hdc 服务端"停在 `Offline`
    （处置办法见提交记录：`-remove` → `kill` → `start` → 单次 `tconn`）。

---

## 3. 未实现 / 未接线

### 3.1 明确没做

| 项 | 现状 |
|---|---|
| 发布帖子 / Reels / 快拍 | 首页标题栏的加号**能进** `pages/CreatePost`（139 行，只有标题 + 提示文案），但**上传 / 压缩 / 发布零实现**；`INSTAGRAM_CREATE_URL` 已备好，未接线 |
| 私信发媒体 / 语音 / 贴纸 | 只实现发**文本** |
| 取关的网页兜底 | 网页取关要点二次确认菜单，脚本点不出来 → 只认 HTTP 结果 |
| 后台定时刷新 | 平台限制（`workScheduler` 最短 2 小时、每天配额约 10 分钟），结论是**不做**，见 `INSTAGRAPI_PORT.md` 第 11 节 |
| 推送通知 | 无（只有应用内通知页） |
| 直播 / IGTV / 购物 / 话题标签页 / 地点页 | 未做 |
| 搜索：帖子结果 / 标签 / 地点 / 音乐 | `MobileDiscover.mediaSearch`（`fbsearch/top_serp`）**已实现但未接线**；标签/地点/音乐未做 |
| 快拍：回复、投票/问答贴纸交互、发布 | 未做 |
| 多账号一键切换 | 账号分区（备份/恢复）已实现，但切换只能通过网页重新登录 |
| 通知的已读/全部标记 | 未做（只读列表） |
| 应用内更新 / 版本检查 | 未做 |

### 3.2 已实现但"半接线"

- `MobileDiscover.mediaSearch`（按词搜帖子）—— 见上。
- `NativeMediaInfo` 按 id 补视频地址：只在视频分页/收藏这类"只给封面"的载荷上用到。
- `core/Translator`（配文翻译）：能力在，入口只在少数位置。
- 端点侦察（`ENDPOINT_SCOUT`）：默认关，需要时手工打开看形状。

---

## 4. 数据来源速查

| 模块 | 首选 | 回退 |
|---|---|---|
| 会话 / 身份 | ArkWeb Cookie 罐 | —— |
| 快拍 | 移动 `feed/reels_tray/`、`feed/user/{pk}/story/` | 模板 + 网页脚本 |
| 私信 | 移动 `direct_v2/inbox/`、`direct_v2/threads/{id}/` | REST 兜底 |
| 搜索账号 | 移动 `fbsearch/account_serp/` | `users/search/` → REST → 模板 |
| 搜索推荐流 | 移动 `discover/topical_explore/` | 模板（explore/clips）→ 信息流推荐卡片 |
| 我的：头部 | 移动 `users/{pk}/info/`、`users/{username}/usernameinfo/` | 模板 `PolarisProfilePageContentQuery` |
| 我的：帖子 / Reels / 收藏 / 被标注 | 移动 `feed/user/{pk}/`、`clips/user/`、`feed/saved/`、`usertags/{pk}/feed/` | 各自模板 |
| 信息流 | 模板 `PolarisFeedTimelineRootV2Query` | 网页脚本读 DOM |
| Reels | 模板 `PolarisClipsTabRootPaginationQuery` | 移动探索流 → 网页冷路径 |
| 评论 / 点赞 / 收藏 / 转发 | 模板回放 | 网页驱动（仅关注） |
| 通知 | 模板回放 | —— |

---

## 5. 构建与安装（本机命令）

```powershell
# 编译（本仓库的原始方法）
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p product=default assembleHap --no-daemon
# 产物：entry\build\default\outputs\default\entry-default-signed.hap

# 安装（设备）
hdc -t <ip:port> install -r entry\build\default\outputs\default\entry-default-signed.hap
```

签名沿用仓库既有的签名配置（`build-profile.json5`），**未做任何改动**。

---

## 6. 相关文档

- `INSTAGRAPI_PORT.md` —— 移动端协议移植全过程：实测端点表、参数、判据、限速与"会话过期"结论（第 1~13 节）。
- `AUDIT_TODO.md` —— 审计待办与遗留项（A~G 分类 + 已完成表 + 遗留清单）。
- `legacy/unwired/README.md` —— 早期 OAuth / Graph API 分层（未接线，已归档）。
