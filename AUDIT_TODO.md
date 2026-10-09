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
- [ ] **E14 `viewmodel/FeedViewModel.noteDebug`** 每次取数把 debug 串写进 `hilog.info`。→ 降 `hilog.debug`。

## F. 资源、注释与死代码

- [ ] **E5b DM 读路径查冷却**（待做）：`ApiThrottle.blocked(DIRECT)` 只在 `sendText` 里查，
      `inbox/thread` 读照样猛打。→ 读路径也查冷却并直接返回明细。
- [x] **F1**（`0574bdf`）`en_US` 补 7 键 + 新增的 `save_rate_limited`；两文件现已一致（161/161）。
- [ ] **F2 `Index.notifyTitleText()`** 硬编码中文 + 诊断串（`通知 ${src}·${n}`）→ 改回
      `$r('app.string.notifications')`，删 `notifySrc`；该函数当前**无调用方**（先确认再删）。
- [ ] **F3** 探针遗留：`Index` 里那段定时器已用 `if (false)` 停用（提交 `334dc4a`），
      连同 `probeTimer/probeTicks` 字段与"每 15 秒"的旧注释一起删干净。
      `DirectThreadPage` 的 8 秒 `capture('')` 探针、`NativeSearch.probePageSizes()`、
      `NativeDirect.mqttSetupProbe()`、`DmRealtime` 整套：按"留着当排查工具但不自动跑"的原则处理。
- [ ] **F4** 可安全删除的无用 string 键 13 个（`login_*` 6、`session_*` 2、`action_reload`、
      `action_share_to`、`comments_close`、`comments_photo`、`direct_thread_older`）；
      `app_name`/`module_desc`/`EntryAbility_*` 由 `module.json5` 引用，**勿删**。
- [ ] **F5** 死代码：`Index.clearNotifications/openNotificationsWeb/profileTabIndex/parseUserParam/
      onCommentsScrollVelocity`、`WebScripts.commentsByReplayScript`、`ApiRegistry.hasVar/lastSyncMs`、
      `MediaQuality.targetWidth`、`NativeStories.hasTrayTemplate`、`NativeSearch.lastOp`、
      `DirectThreadViewModel.currentThreadId/sendingNow`、`ScrollReport.reset`（无调用点）等
      （完整清单见审计原文；删前用 grep 复核一次引用数）。

## G. 需要先给计划的（牵涉状态机，改动前先出一页方案）

- [ ] **G1 `viewmodel/ProfileViewModel.load`** 跨 await 仍用 `this.tab` 取 `opName` 并写回 state：
      切分页/并发时会把 **A 分页的帖子写进 B 分页**（同文件 698/707/1043 都有 `this.tab===tab` 守卫，
      只有 `load` 漏了）。→ 入口保存 `const tab/state`，全程用 `opNameOf(tab)`，写回前按
      `this.tab===tab` 守卫。
- [ ] **G2 评论面板状态机**：`commentsVisible` 与 `commentsSuspended` 同帧互覆、`commentsClosing`
      卡 true 时 `closeComments` 直接 return → 面板再也拉不起/关不掉。→ 单一状态机 + token。
- [ ] **G3 `Index.applyComments`** 未重置 `commentsMediaId/commentsShortcode`（`openComments` 也不重置）
      → 翻页可能拿上一条帖子的 mediaId 要评论。
- [ ] **G4 `Index.loadCommentReplies`** await 后直接改数组元素，期间数组被替换会挂错条目
      → await 后按 `pk` 重新定位。
- [ ] **G5 评论定时器**：`commentsExitTimer/commentsSettleTimer` 未在 `aboutToDisappear` 清理
      → 统一清定时器并把 `closing/suspended` 复位。
- [ ] **G6 预热链**：`warmOtherTabs` 每一步都先 `waitIdle + awaitPageReady`（最长 30 秒），
      首屏网页没就绪时后面 4 步全被判 not-ready → 网页就绪只等一次并共享结果，纯原生步骤不等网页。

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
