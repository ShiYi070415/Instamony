# 审计待办（四路只读审计的剩余项）

来源：数据层 / 组件层 / 视图模型+Index / 资源与横切 四路审计。已完成项在文末"已完成"一节，
每完成一项就在提交信息里带上这里的编号。

工作方式：**读准 → 精确改 → 构建通过 → 装模拟器/真机验证 → 单独提交**，不要攒着一起改。

---

## A. 生命周期清理（审计第一优先）

- [ ] **A1 `FeedList`** 全文件没有 `aboutToDisappear`；`restoreAnchor` 的 3 个 `setTimeout`
      在每次 `onAppear` 都会再注册一轮，销毁后仍读 `this.listScroller`。
      → 存句柄 + 补 `aboutToDisappear` 清理 + 加"只注册一次"的守卫。
- [ ] **A2 `DirectThreadPage`** `scrollToNewest` 的 3 个 `setTimeout` 与 8 秒兜底 `settleRefresh`
      都没有句柄、`aboutToDisappear` 也没清（同文件的探针 setInterval 反而清得很干净）。
      → 存句柄 + 清理。
- [ ] **A3 `ReelsPage`** 点赞/转发/保存三处 12 秒兜底 `setTimeout`：无句柄、无代次 ——
      上一次的定时器会在下一次请求中途把 `busy` 置回 false，允许重复发请求。
      → 存句柄 + 销毁时 clear + 每次操作自增序号比对。

## B. 竞态 / 代次（组件层审计）

- [ ] **B1 `ReelsPage`** `onAnimationStart` 一开始就把 `activeIndex` 切到 targetIndex，画面还停在
      旧页约 480ms；这段窗口里双击点赞，`current()` 已经是新那条 → 赞落在没在看的视频上。
      → 以 Swiper 落定 index（`onChange` 之后）为准，或用 `pendingIndex` 到动画结束再提交。
- [ ] **B2 `ReelsPage`** 双击爱心用整页常量 key，`playLikeBurst` 无 epoch：连续双击时前一次的
      清理定时器会提前清掉后一次动画；`switchTo` 也不清 burst（爱心闪在下一条上）。
      → 每条唯一 key（+shortcode），`switchTo` 里清 burst + 自增 epoch。
- [ ] **B3 `CommentsPanel`** `.edgeEffect()` 条件读的是**普通字段** `listAtTopState`（由滚动起停
      回调更新，不触发重绘）→ 回弹/滚动交互停在旧档位。→ 提升为 `@State`。
- [ ] **B4 `CommentsPanel`** `CommentMedia`/`CommentAvatar` 的 `@State failed` 在 `@Prop url` 变化时
      从不复位，外层键又只有 `imageUrl.length` → 换新直链后永久停在占位图。
      → `url` 加 `@Watch` 复位 `failed=false`。
- [ ] **B5 `StoryViewer`** `spaceOffsetX/Y` 是普通字段却参与渲染（`startX/startY`），
      `measureSpace` 写入不重绘（相邻 `overlayW/H` 已是 `@State`，349 行注释自述过这个坑）。
      → 改成 `@State`（先确认首帧实际偏移量再改）。

## C. 三处"加载/翻页被永久锁死"（用户已实测到现象）

- [ ] **C1 搜索推荐"19 格后不再加载"**
      `searchVm.setActive` 只在 `selectTab` 里同步，而 `Index` 另有两处直接给 `selectedTab` 赋值
      → `active` 与实际可见页不符，`requestMoreFromScroll` 被闸门永久挡掉；同时补 `loadingMore`
      的死锁清理（异常路径不复位就会一直 true）。日志诊断已就位：
      `loadMore enter loading=… hasMore=… cursor=… posts=… throttled=…`（实测曾因 `throttled=true`
      被 IG 限流挡住，那是服务端限流，不是这条 bug）。
- [ ] **C2 评论翻页整页重复即停**
      `Index:4589` `hasMore = … && fresh.length>0`：IG 游标常回带，整页都是重复就永久 false，
      面板停在"没有更多"。→ 只在**游标没前进**时停止；游标变了但全重复就跳过这页继续拉。
- [ ] **C3 会话详情读失败后彻底不重试 + 翻页永久停**
      `DirectThreadViewModel`：首屏失败后 `view=null`，之后 `load`/`loadOlder` 直接 return；
      `loadOlder` 去重后新增 0 就置 `hasOlder=false`。
      → 失败置**可重试标记 + 退避**；新增 0 时置 stuck 标志、冷却后重读第一页（参考
      `FeedViewModel` 的 `pagingStuck` 那套）。

## D. ForEach 键与"过期闭包"（症状：显示条数少于数据 / 点 A 改到 B）

- [ ] **D1 `SearchPage`** 账号结果键只有 `user.username` → 补 index。
- [ ] **D2 `DirectThreadPage`** 消息键只有 `message.id`（待发消息 id 为空/重复会吞行）→ 补 index。
- [ ] **D3 `FeedList:1874-1876`** 关注按钮 `onTap` 闭包捕获构建时的 index（键值不变时 item builder
      不重跑）→ 刷新插帖后改到别人的 `uiList[旧index]`。→ 按 key 取 `uiByKey.get(keyOf(post))`。
- [ ] **D4 `FeedList:2728`** `onVisibleAreaChange` 闭包同样捕获过期 index → `visiblePosts` 错位，
      `refreshFocus` 判为过期丢弃，可见集合可能变空并**停掉正在播的视频**（在 iOS 侧解释过类似现象）。
      → 按 key 反查当前下标。
- [ ] **D5 `ReelsPage`** `ForEach` 键用 `reel.shortcode`（可能为空）→ 补 index 兜底。
- [ ] **D6 `StoryViewer`** 进度条键只用 `one.id`；`NativeStories` 兜底 id 是 `story-${takenAt}`，
      `taken_at` 缺失（给 0）时多条同为 `story-0` → 重复键掉段。→ 键改 `${one.id}-${position}`。
- [ ] **D7 `CommentsPanel`** 键用 `text.length`/`imageUrl.length` 且含 index → 同长度不同内容不重建
      （旧节点复用、译文/失败态串味）。→ 键放完整内容或内容哈希，去掉 index。

## E. "静默失败"与限流（最难查的一类）

- [ ] **E1 `bridge/ApiRegistry.storedForNative`** 精确名未命中就退化**子串匹配** →
      `RestSession.formTokens('ayml')` / `NativeFeed.headersFor(op)` 可能拿到**别的模板**的头与令牌。
      → 精确未命中时按名字前缀/独立 token 匹配，或调用方直接传真实模板名。
- [x] **E2 `core/JsonRead`**（`9b07d23`）裸 `id` 分支去掉（它会误伤 `media_id`），白名单收紧到
      真正会读的键，并补上 `thread_fbid`/`thread_key`/`message_id`/`sender_fbid`/`offline_threading_id`。
- [x] **E3 `core/NativeDirect.send`**（`9b07d23`）`looksLimited` 提到 `code!==200||!json` 之前：
      限流响应如果不是标准 JSON 会被前置分支判成 `non-json`，限流既不记账、detail 还被覆盖。
- [ ] **E4 `core/NativeDirect.threadViaTemplate`** 候选 op × 2 个 id 串行各发一次（最多约 10 发），
      中途不查冷却；且 `threadViaRest` 与 `thread()` 里那两段 REST 兜底是重复实现。
      → 候选上限 ≤2、命中限流即 break、合并两份实现。
- [x] **E5/E6 收藏这一支**（`0574bdf`）：`byTemplate`/`setSaved` 入口加 `cooling()` 闸门；
      第一发当场认出限流就不打后两发；`detail` 入口重置 + `note()` 先到先得（具体原因不再被
      `http-404`/`template-fail` 盖掉）；调用方 `saveMedia` 原生失败后**网页那条路也一起停**
      并提示 `save_rate_limited`（网页驱动发的是同一个账号的写请求，撞同一把锁）。
      **E5 的 DM 读路径（`inbox`/`thread`）仍未做**，见下面单独一条。
- [ ] **E7 `core/NativeSearch.pageSizeRejected`** 任何失败都记成"页数被拒"→ 一次网络抖动就永久
      关掉大页数这条优化（进程内）。→ 只在 detail 明确为 `400/noncoercible_variable_value` 时置位。
- [ ] **E8 `core/NativeStories`** try 列表的第 4 个候选与第 1 个同 URL 同身份（纯重复请求，多打一发）。
- [ ] **E9 `core/Translator`** 缓存键只有原文、不含目标语言 → 切系统语言后返回旧语种译文。
      → 键改 `target + '\u0000' + source`。
- [ ] **E10 `core/WebTokens`** 并发等待用 30×100ms 忙等（最多 3 秒），失败无重试入口。
      → 等待同一个 in-flight Promise。
- [ ] **E11 `core/MediaDownloader`** 只 `on('complete'/'fail')` 从不 `off()`、也无超时 → 任务既不完成
      也不失败时 Promise 永不 settle（文件残留 + 调用悬死）。→ 加超时 + settle 后 `off` + finally 清理。
- [ ] **E12 `core/MediaPrefetch`** `seen` 集合无上限、进程内不清（只随 clearCache）→ 与缓存淘汰不同步，
      该预取的图被跳过。另：预取入口未查 `NetworkState.allowPrefetch()`（蜂窝网下仍提交预下载）。
- [ ] **E13 `core/NativeComments`** 用 `body.length` 推断 HTTP method（空体写请求会变 GET）。
      → 显式传 method。
- [x] **E14 `viewmodel/FeedViewModel.noteDebug`**（`88402bc`）中间步骤（`cache=`/`api=`/`dom=`）
      降到 `hilog.debug`；合成后的那一行仍在 `info`（`grep "feed debug"` 一次取数一行）。

> E 区全部完成，见下方"已完成"表：`E1 36b1dcf`、`E2/E3 9b07d23`、`E4/E5b 738ced0`+`7783e30`、
> `E5/E6 0574bdf`、`E7~E14 88402bc`。

## F. 资源、注释与死代码

- [x] **E5b DM 读路径查冷却**（`738ced0`）：`inbox` / `inboxRest` / `thread` / `threadViaTemplate`
      入口都过 `cooling()`，冷却期直接返回并把原因写进 detail；实时轮询拿到 null 本来就静默跳过。
- [x] **F1**（`0574bdf`）`en_US` 补 7 键 + `save_rate_limited`。
- [x] **F2**（`0415591`）删掉无调用方的 `notifyTitleText()`；`@State notifySrc` → 普通字段
      （它现在只进 hilog，@State 只会让整页白重算）。
- [x] **F3**（`d5e3e8d`）删掉两处"一直在跑"的探针：`DirectThreadPage` 的 8 秒
      `capture('')` 定时器（含 `PROBE_MS`/`probeTimer`/只它用到的 import）、
      `Index.warmOtherTabs` 里 `if (false)` 那段（含 `probeTimer`/`probeTicks`/`DmRealtime` import）。
      `probePageSizes` / `mqttSetupProbe` / `DmRealtime` 本体保留，但**没有任何调用点**。
- [x] **F4**（`0415591`）删 13 个无用键，基座/en_US 各 148 个且键名集合一致
      （`login_title`/`login_recheck`/`login_hint`/`login_open_web` 仍有引用，保留）。
- [x] **F5**（`0415591`）删 `Index.clearNotifications/openNotificationsWeb/profileTabIndex/
      parseUserParam/onCommentsScrollVelocity`、`ApiEntry.hasVar`、`ApiRegistry.lastSyncMs`、
      `MediaQuality.targetWidth`、`NativeStories.hasTrayTemplate`、`NativeSearch.lastOp`、
      `DirectThreadViewModel.currentThreadId/sendingNow`（每个删前都 grep 复核过引用数为 0）。
- [ ] **F5b 待复核**：`WebScripts.commentsByReplayScript` 只在注释里被提到（声明处 + Index 注释），
      但它是页面侧脚本，删之前要确认没有按名字间接调用；`ScrollReport.reset` 未找到该名字。

## G. 需要先给计划的（牵涉状态机，改动前先出一页方案）

- [x] **G1 `viewmodel/ProfileViewModel.load`**（`a96984c`）入口取一次 `tab`、全程只用它，
      写显示状态前按 `this.tab === tab` 守卫；`recaptureAndRetry` 改成收 `tab` 参数。
- [x] **G2 评论浮层状态机**（`129d135`）新增 `commentsAfterQueue`：收起动画期间的收尾动作
      **排队而不是丢掉**（`closeComments` 的注释早就这么写了，代码没做 ——
      表现是"收起动画里点评论头像，用户主页永远不打开"）；收尾时把
      `commentsSuspended/commentsSuspendBase` 一起复位（否则会留下一层"已关掉但被记为挂起"的
      空面板，从页面返回时被弹回来）；`openComments` 取消收起动画时当场 flush 队列。
- [x] **G3 `Index.openComments`**（`a96984c`）媒体 id 在开面板时按这一条算好
      （抽出 `Index.mediaIdOfPost`），不再只在原生成功时才写。
- [x] **G4 `Index.loadCommentReplies`**（`a96984c`）await 回来按 `pk` 重新定位
      （`indexOfComment`），定位不到就丢弃并记一行；日志加 `at=`。
- [x] **G5 评论定时器**（`a96984c`）`aboutToDisappear` 清 `commentsExitTimer`/`commentsSettleTimer`
      并把 `commentsClosing` 复位。
- [x] **G6 预热链**（`042bc7f`）改在 `PageBridge.awaitPageReady` 这一层：
      一次超时后 10 秒内再来问**立刻**回 timeout（并记 `awaitPageReady skip`），
      `markReady`/`markUnready` 清记忆 —— 不再"每步白等 20 秒"。

> G 区全部完成。审计的 A~G 七节至此收口，逐项提交见下表。

---

## 已完成

| 提交 | 内容 |
|---|---|
| `6850ffd` | LinkIn 深链参数改走 `LocalStorage` 传给 `loadContent`（A 方案），构建从红恢复绿 |
| `334dc4a` | 关掉界面探针入口（`PROBE_MENU_VISIBLE=false`）+ 停用启动即跑的探针定时器 |
| `bf52ca5` | `StoryViewer.reopen()` 重启计时器（打断收起后进度条/自动前进不再永久停摆） |
| `bfea391` | `StoryViewer.aboutToDisappear` 清全部定时器 + `gen+1`（作废销毁后的动画回调） |
| `5e3edf8` | `StoryViewer.next()/prev()` 重入保护（连点不再跳两位用户） |
| `89151e8` | `StoriesTray` 转圈定时器存句柄 + `aboutToDisappear` 清理 |
| `8ef91ec` | `ReelsPage.aboutToDisappear` 摘掉挂在宿主 vm 上的 `onReels/onBusy/onStatus` |
| `a12863f` | `StoryViewer` 长按暂停补 `onActionCancel`（被 PanGesture 抢手势时 `paused` 卡 true） |
| `5d1c548` | `StoryCache.reset()` 复位 `loading` + 加 `generation` 代次（回调侧的 gen 判断**尚未接**：见 A 区后续） |
| `9b07d23` | **E2/E3** `JsonRead` 大整数白名单收紧（去掉裸 `id`，补 `offline_threading_id` 等）；`NativeDirect.send` 限流判定提到状态码判断之前 |
| `0574bdf` | **E5/E6 + F1** 收藏路径：限流期间不再发请求（含调用方的网页兜底）、`NativeSave.detail` 不再被覆盖；`en_US` 补 7 键 |
| `36b1dcf` | **E1** `storedForNative` 片段匹配从"任意子串"收紧到"独立 token"（片段也过同一分词器）+ `storedForNative miss` 按片段去重上报 |
| `88402bc` | **E7~E14** 八处：`pageSizeRejected` 只在明确被拒时置位、`Translator` 缓存键带目标语言、`WebTokens` 改 in-flight Promise、`MediaDownloader` 超时+off+清理、`MediaPrefetch` `seen` 上限 + `allowPrefetch` 闸门、`NativeComments` 显式 method、`noteDebug` 降级 |
| `738ced0` | **E4/E5b** 私信读路径加退避闸门、会话候选封顶 4、合并两份重复的 REST 兜底（`threadViaRest(id, cursor, identity)`） |
| `7783e30` | **E4 后续** 记住会话能用的那个 id 形态，实时轮询每轮省掉一发请求 |
| `d5e3e8d` | **F3** 删掉两处"一直在跑"的探针（`DirectThreadPage` 8 秒 `capture('')`、`Index` 里 `if (false)` 那段） |
| `0415591` | **F2/F4/F5** 删无调用方的死代码 12 处 + 13 个无用字符串键（基座/en_US 各 148 键、集合一致） |
| `a96984c` | **G1/G3/G4/G5** 个人主页分页串写；评论媒体 id 开面板即算；回复 await 后按 pk 重定位；评论定时器清理 |
| `129d135` | **G2** 评论浮层收起期间的收尾动作排队而不是丢掉；关掉时清挂起记账 |
| `042bc7f` | **G6** `awaitPageReady` 记住"刚刚不就绪"，预热链不再一段一段白等 |
| `ab4732a` | **A 区遗留** `StoryCache` 回调侧代次判断接上（日志抓到双重 reset，6 发旧响应被丢弃） |
| `8b5cb56` | **需求** 快拍托盘：宿主那份数据当首帧内容（切页面不再消失）+ 灰色占位头像 + 3 分钟新鲜度门槛 |
| `6f9f98c` | **需求** 打开动画先 16:9 再变 9:16 —— `StoryViewer.MEDIA_RATIO` 方向写反（`16/9` → `9/16`）+ `media open-start` 现场日志 |
| `4d54e61` | **快拍取数失败链** 同 URL 不再换身份重打、`ApiThrottle.STORIES` 退避、"点开那一发"失败重试一次 |

## 遗留 / 下一步（本轮未做）

- **快拍"点开显示取不到、页面自己收起"**（`4d54e61`）：成因已定位 —— `story_load_failed`
  只在 `Index.playStoryAt` 的三处"这一位 reel 取不到"分支，其中两处会**按设计把空卡片收走**
  （所以"自动收起"不是收起逻辑坏了，而是取数失败后被带走）；三个放大器已堵：
  同 URL 换三种身份重打、`/feed/reels_media/` 完全不看 `ApiThrottle`、"点开那一发"没有重试。
  **本机复现不出来** → 交给其他会复现的测试者，请回传两行日志：
  `story load failed uid=… why=…`（失败原因）与 `reel empty/rate limited …`（哪一发、什么形状）。
- **私信"会话只显示 4~5 条"**：本轮实测 `threadViaTemplate ok … msgs=19`，需要用户侧再复核
  是否还复现（若复现，看 `graphql raw edges=N` 是"服务端就给了几条"还是"解析丢了几条"）。
- **Reels 视频宽高诊断**（`reel aspect w=… h=… ratio=…`）与**信息流高视频黑底占位**两项没动。
- **`WebScripts.commentsByReplayScript`**（只在注释里被提到）删前要确认没有按名字间接调用。

