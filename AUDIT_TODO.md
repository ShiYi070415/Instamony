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
- [x] **E9 `core/Translator`** 缓存键只有原文、不含目标语言 → 切系统语言后返回旧语种译文。
      → 键改 `target + '\u0000' + source`。（`88402bc`）
      追加修复（`BUG`：用户报"全部文本点翻译都失败"）：真机自检落盘证明 gtx 回 **`http-429`**
      ——只备一个端点等于功能随时整体挂掉。现在 ①gtx → ②`clients5.google.com/translate_a/t`
      → ③MyMemory 三级兜底，每发都带浏览器 UA/Accept-Language，成功的那个钉成本会话首选；
      自检（`Translator.scheduleSelfTest`）启动 5 秒后三发各打一次并落盘
      `filesDir/Instamony_translate.txt`。
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
| `1abc8d0` | **搜索修复** 结果模板排除 `searchbox`（此前拿错模板）；预热链最后加"启动体检 + 失败重抓"；新增**不需要模板**的 REST 搜索；搜索改成先原生再冷路径 |
| `86b20b3` | **快拍失败诊断** 消息里带原因（`story_load_failed` 加 `%s`）+ 逐发轨迹落 `storyfail_<ts>.txt`（身份/URL/状态码/长度/响应开头/托盘年龄），供远端测试者截图或 hdc 回传 |
| `65e9e09` | **快拍 empty 修复** 托盘条目收全部候选 id（`StoryTrayItem.altIds`）；主 id 答空时**换备选 id 再问**；预取链同样带上；报告里写出备选 id |
| `107ffb7` | **快拍 empty 诊断加强** `trayshape_<ts>.txt`（每条条目 `reel_type`/`besties`/`expiring_at`/`entryItems`/`node.id`/`user.pk`）+ `trayraw_<ts>.txt`；`storyfail` 加 `shape=`/`raw[node]=`；加"用托盘条目自带 items 兜底" |
| `71a53dc` | **诊断汇总文件** `Instamony_diag.txt`（固定名，覆盖写）：怎么读 + 当前状态 + 最近 8 条失败记录 + 全部托盘形状 + 前 40 条原始条目；首启落盘一次、每次失败追加；**重启前先捞回上一份的失败记录**（实测重启不丢） |
| `4b5a6fb` | **私信会话页三处** 最新消息贴底（媒体晚到后补贴底，且不抢正在翻历史的人）+ 顶部居中加载动画（列表第 0 格恒占位）+ 输入法避让（量实测矩形自校正，`need` 三次收敛到 0） |
| 本轮 | **账号分区 + 彻底退出登录**（用户："退出登录后登另一个账号，快拍还是上一个人的"）：新增 `core/AccountScope`，把"按人抓的"落盘缓存全部按账号分槽（信息流 / reels / 搜索×2 / 私信快照 / 请求模板）；退出登录时**活跃分区搬到备份位**（活跃位清空，备份留给本人以后回来），并清内存（列表 / 托盘队列与快照 / 预取队列 / 关注·收藏·互动覆盖表 / 设备会话材料 / 模板 / 译文 / 限流冷却）、清 Web 存储与 HTTP 缓存、删诊断文件（uid / 托盘形状 / 媒体地址）。换账号（在网页里登出再登入）走 `applySession` 的账号变更判定，同样搬分区 + 清内存 |
| 本轮 | **快拍托盘左右不留白**（用户："屏幕边缘又出现空隙"）：`StoriesTray` 的 List 去掉左右 padding —— 它会把**滑动区一起缩窄**，内容在离屏幕边 8vp 处就被裁掉、两端永远有一条空带（截图里左边那条黑边 + 半个圆环）；负 margin 与 `contentStartOffset/EndOffset` 都试过不能用的原因写在代码注释里。改完第一位紧贴左边、内容滑到两端直接穿出屏幕 |
| 本轮 | **整页登录页 + 退出登录清空五个页面**（用户："退出登录需要清空主页/reels/私信列表/搜索/我的页面。新增一个登录页面…需要沉浸光感效果，点击登录按钮才跳转网页登录。登录后立刻通过 http 请求按正常加载流程获取数据"）：新增 `components/LoginPage`，未登录时由 `Index.nativeShellContent` **整页**渲染它（五个 tab 的内容层与底栏都不建，于是退出登录/换账号时它们整批销毁重建，不会残留上一个人的数据）；同一判据 `loginPageShown()` 同时喂给 `nativeShell` 的 `hideTitleBar`，未登录时标题栏与它的通知/发帖两颗按钮一并收走；背景铺一层强调色光晕渐变（`login_glow_*` 明暗两套）让材质有可采样的底；登录按钮走 Toggle 承载的沉浸光感材质，点了才 `openLoginWeb()` 跳网页登录；`applySession(signedIn=true)` 里补 `warmStarted=false` + `loadFeed()` + `warmOtherTabs()`，登录完立刻按正常流程取数。顺带删掉被它取代的 `components/LoginPanel` 与两个随之无用的字符串键（基座/en_US 各 166 键、集合一致）。实机验证：登录页满屏无标题栏、已登录路径信息流正常 |
| 本轮 | **搜索推荐流触底修复 + "我的"四个分页改走移动端**（用户："搜索推荐流无法触底刷新，修复一下"；"搜索功能和我的（及其下四个分页）尝试改为 instagrapi 的协议"；"切换分页无需重新加载"）。触底那个 bug 的真凶：`SearchViewModel.loadMore` 里"被限流就不发"的判据是 `ApiThrottle.blocked(CLIPS)`，而推荐流现在走 `discover/topical_explore/`（另一个端点）—— reels 打 clips 那条 GraphQL 会把 `CLIPS` 打到 12 分钟冷却，于是搜索推荐流滑到底一声不响什么都不加载；改成移动端来源时不再按 `CLIPS` 拦（新增 `NativeSearch.usingMobileRecommended()`）。"我的"四个分页改走移动端：新增 `MobileProfile.tab()`（帖子 `feed/user/{pk}/`、Reels `clips/user/`、被标注 `usertags/{pk}/feed/`、收藏 `feed/saved/`），乐观性分级（帖子/被标注乐观；Reels/收藏是试出来的端点，先走原模板路、通了才立标记），`NativeProfile.fetchPosts` 按操作名判 kind（合成名 `mobile:<kind>` 与真模板名都认）、移动端优先、模板路完整保留。`ProfileViewModel.opNameOf` 在"没有模板"时返回合成名 —— 这是"切换分页无需重新加载"的关键：原来返回空串会去跑 `captureTab()`（导航隐藏网页抓模板，秒级），现在四段都不需要模板，`preloadAllSegments` 也能在没模板时把四段都预取上。**本轮装机/真机验证被设备掉线打断**（已挂自动装包任务）：新增的三条分页端点与触底修复尚未真机跑过；`ENDPOINT_SCOUT` 里已备好 `clips/user`(GET+POST)、`usertags/{pk}/feed`、`feed/saved`、`collections/list` 五条候选 |
| 本轮 | **搜索推荐流与 reels 分开 + 搜索/主页改走移动端点**（用户："搜索推荐流和 reels 的 http 请求应该不是同一个，然后尽量把 reels/搜索/主页的数据加载速度提升，参考 instagrapi 的协议逻辑"）。先前推荐网格在抓不到探索模板时会回落 `CLIPS_HINTS`（就是 reels 的 `ClipsTabRoot`），所以两个页面是同一发请求、同一批内容。本轮先用**端点侦察**（`MobileProbe.ENDPOINT_SCOUT`，默认关，写 `Instamony_scout.txt`）在真机上把候选端点逐条问了一遍：`clips/home/` **404**（这一版 App 没这个端点，reels 只能继续 GraphQL）、`discover/topical_explore/` ✓（1.30MB/4.7s，媒体在 `sectional_items[].layout_content.medias[].media`，游标是 **`max_id`**）、`fbsearch/account_serp/` ✓（32KB/1.9s，`users[].pk` 齐）、`users/search/` ✓、`fbsearch/top_serp/` ✓（帖子在 `media_grid`）、`users/{pk}/info/` ✓、`feed/user/{pk}/?count=12` ✓（377KB/2.2s）。据此新增 `core/mobileapi/MobileDiscover`（探索流/账号搜索/搜帖子）与 `core/mobileapi/MobileProfile`（资料/主页网格），两者**只搬原始节点**、映射复用 `NativeSearch.postOf` 与 `NativeProfile.headerFromUser/postsFromItems`；`NativeSearch.recommendedPage/searchUsers` 与 `NativeProfile.fetchHeader/fetchPosts(仅 OP_POSTS)` 改成移动端优先、原模板路留作退路；`SearchViewModel` 四处"有没有推荐模板"改成"有没有推荐**来源**"（否则冷启动会跳过推荐流、还会去跑十几秒的网页冷路径）。顺带修掉 `ApiThrottle.looksLimited` 的字面误判（真机上把 reels 预热打成了 12 分钟冷却，现在只认 `1675004`/`rate_limit_error`/错误结构里的文案）并在 `NativeReels` 打出响应开头便于定位 |
| 本轮 | **未登录时不再驱动共用网页**（用户："已登录状态退出登录后正确进入登录页面，但该状态的网页登录会出现页面反复刷新，用户名自动填充 instagram"）。真机日志（新增 `web route` / `page begin` / `main frame error` 三条诊断 + `-T InstamonyBridge,InstamonyHome` 抓取）定位到三条独立原因：① 网页的 `SESSION_WATCHER` 只看 DOM 地标就报"已登录"，未登录时会**误报**，`handleSessionSignal(true)` 又直接采信 → `applySession(true)`（首页导航 + `warmStarted=false` + 整条预热链重跑）→ IG 把这次导航踢回登录页 → 读罐又是未登录 …… 每 3 秒一轮，这就是"登录页反复刷新"的主体，现在**正信号一律回 Cookie 罐复核**；② `prefetchLikelyPages` 在每次整页加载结束都预加载 `/reels/`、`/direct/inbox/`，未登录时这几条全被重定向到登录页、而重定向本身又触发下一次预加载 —— 自踩循环，现在未登录直接跳过（`InstagramWebHost.signedIn` 由 Index 传入）；③ 关注网页兜底写死 `username.length > 0 ? username : 'instagram'`，用户名缺失时把网页导航去 `/instagram/`，IG 转登录页就把路径里的 "instagram" 填进用户名框（"自动填充"就是这么来的），现在改成退回数字 id 且**没有用户名就不走网页兜底**，`followAccount` 另加 IG 用户名白名单正则（日志里还出现过把 `{"state":"not-ready"}` 当用户名导航的地址）。结构性兜底：新增 `core/SessionGate`，`InstagramPageBridge.loadUrl` 作为全 app 唯一导航入口统一设闸 —— 未登录只放行 `/accounts/…`、`/challenge`、`/consent`（`reload()` 不设闸，它是刷新键与渲染进程崩溃后的恢复路径）；`warmStep` / `warmOtherTabs` / 首屏自动重试同样按登录态停手。实机验证：未登录静置 35 秒零导航、零预热（此前每 3 秒一轮），点登录只导航一次登录页且不再刷新、用户名框为空 |

## 遗留 / 下一步（本轮未做）

- **搜索结果那条 GraphQL 模板已抓不到**（`1abc8d0`）：页面这一版把词打进搜索框后**一个新请求都不发**
  （`type try=1 out=typed:search signal=timeout`，3 轮打字 + 4 轮抓取全空），所以"重抓"这条路
  目前是断的；现在靠**不需要模板的 REST 搜索**（`/web/search/topsearch/`）顶着。
  以后若要恢复模板那条路，得先弄清页面为什么不发请求（可能是输入框需要更真实的按键序列，
  或者 IG 换成了别的触发方式）—— 体检日志里的 `op=` 为空就说明在用 REST。
- **快拍取数 500** —— **三份诊断文件逐层定案，根因是"账号被要求安全验证"**（`f2b005c`/`4cf9041`/`3c6db74`）：
  * 第一份：`empty` 是我自己的 bug（收尾无条件把 `detail` 覆盖成 `empty`，盖掉了 `http-500`/`http-400`）；
  * 第二份：`reels_media` 回 500，而**头清单里没有 `x-ig-www-claim`**（用的是信息流 GraphQL 那套头）
    → 改成用 `RestSession.headers()`（带 claim/instagram-ajax），并删掉注定 `unsupported_version` 的 `android-old`；
  * 第三份：**claim 已就位（`claim=true ajax=true`、cookie 含 `sessionid`/`ds_user_id`）仍然 500**
    → claim 不是原因。
  随后把三条退路**逐条真机实测**：① 私有 REST 500（安卓身份那条回 `challenge_required` + `lock:true`）；
  ② "抓网页快拍查询"这条路**在当前 IG 版本不存在**（打开 `/stories/<用户>/` 后页面一个新请求都不发；
  顺带修掉 `storyOps()` 的假阳性 —— `PolarisProfileReelsTabContentQuery` 被当成快拍查询，
  导致抓取被整个跳过）；③ "直接读页面媒体"也拿不到（页面标题/就绪都对，但只有 2 个 `<img>`、
  0 个 `<video>`，URL 没跳到第一条 media）。
  ⇒ 三条路都指向**同一根**：该账号/会话被 IG 要求完成 challenge（安全验证），
  这也解释了"网页 GraphQL 托盘正常、私有一类接口一律被拒"这组现象。
  **用户补充的关键信息**：他那边是**香港网络**（同账号正常），出问题的测试者**内地挂 VPN**
  —— 与"IG 按来源判定"完全吻合（VPN 出口 IP 被标记，或透明代理改写头/压坏 HTTP2）。
  `2895b4d` 补了两件能证实/绕过它的东西：
  * **网络探针** `net=robots.txt http-…|throw:…` 写进失败报告 ——
    探针 200 而接口 500 ⇒ 链路通、服务端按来源拒；探针也失败 ⇒ 链路本身不通；
  * 新增 **`i.instagram.com` + 安卓身份** 候选（官方 App 的主机，另一套网关，值得单独一试）。
  已落地其余项：`RestSession.headers()`、删死候选、5xx 补抓模板重试、轨迹带
  **响应体/头名/cookie 名**、`challenge_required` 单独识别并在界面提示「先完成安全验证」。
  **下一步看对方**：① 换 VPN 节点/国家；② 在 App 内网页同一网络下重新登录一次（会话绑该 IP，
  更能过验证）；③ 手机浏览器同一 VPN 下看那个人快拍 —— 浏览器也看不了即账号/IP 侧。
  **✅ 已绕过（2026-10-16，`f048071`/`5c4ad73`）：快拍改走移动端私有 API** ——
  见 `INSTAGRAPI_PORT.md` 第 9 节。同一台设备换成移动端那套头（App-ID / UA / `signed_body` /
  `Authorization: Bearer IGT:2:`）后**七发全通**（`ok=7/7`），托盘一发带回 213 条，
  点开头像能出媒体；老路径整体保留为回退（`NativeStories.MOBILE_STORIES_FIRST`）。
  实测还纠正了两条假设：**托盘响应已不再带 `items`**（媒体必须按 id 现取）、
  以及 **`reels_media` 只认裸 id**（网页那条用的 JSON 数组形式回空壳 —— 这也是老路径"答了但没内容"的一个来源）。
- **快拍"点开显示取不到、页面自己收起"**：`story_load_failed` 的三处分支里有两处会
  **按设计把空卡片收走**（"自动收起"不是收起逻辑坏了，而是取数失败后被带走）。
  现场一律进 `Instamony_diag.txt`（测试同学截图 `（原因 …）` 或直接发那个文件即可）；
  按 `detail` 分档处理：`empty`（见上一条）、`http-4xx`（会话或身份）、`throttled-Nmin`（节流）、
  `no-session`、`throw:`（网络）。
- **私信"会话只显示 4~5 条"**：**已定案并修掉**（`f048071`/`5c4ad73` 之后的私信那一提交）。
  根因不在请求，而在**解析层漏了整类消息**：`DirectMapper.threadFromJson` 只认
  `text`/`media`/`media_share`/`clip`/`reel_share`/`link`，而新版分享消息是
  `xma_clip` / `xma_media_share` / `generic_xma` —— 附件是**数组**（预览图 `preview_url`、
  视频 `playable_url`）。1:1 会话里整条线程可以是这三类，于是 21 条全被丢成 **0 条**，
  界面报「读取失败: http-404/non-json」（真机 16:19 复现，`xma_clip=18,xma_media_share=2,
  generic_xma=1`）。补上映射后同一会话 `msgs=20 raw=21`，分享的 Reel 预览正常显示。
  顺带：`animated_media`（贴纸/GIF，`images.{fixed_height,…}.url`）也补了。
  私信取数同时改走移动端私有 API（`core/mobileapi/MobileDirect`，见 `INSTAGRAPI_PORT.md` 第 9.6 节），
  收件箱 20 条会话 / 会话 21 条消息。
  **翻页与预取也做完了**（用户反馈"列表加载慢、滑到底拉不出更多"）：
  ① 收件箱翻页游标解开了 —— 是 `inbox.oldest_cursor`（105 字符串）**放在查询串**里，
  `next_cursor`（结构体）/`prev_cursor_v2` 会被 400 拒、放表单体里会被忽略（详见 9.6 的实测表）；
  真机连续翻 4 页、列表 20 → 80 条，日期回到 9 月；
  ② feeds 页并行预取收件箱（`Index.warmOtherTabs` 开头起一发、不等它），配合
  `DirectViewModel.isFresh(2min)` + `DirectPage.aboutToAppear` 的新鲜度判断 ——
  实测创建后 10.2 秒预取完成，切过去零等待（状态行「已加载（feeds 页已预热）」）。
- **Reels 视频宽高诊断**（`reel aspect w=… h=… ratio=…`）与**信息流高视频黑底占位**两项没动。
- **`WebScripts.commentsByReplayScript`**（只在注释里被提到）删前要确认没有按名字间接调用。

