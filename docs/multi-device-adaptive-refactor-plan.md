# Instamony 多设备自适应重构方案

> 目标：把当前“手机一套 / 平板一套”的条件分支，收敛为**一套 Shell + 一套路由 + 一套断点模型**。
> 先保证导航、侧边栏、安全区、Reels 播放四条链路稳定，再谈视觉细节。

## 0. 实施状态（2026-11 修订）

### 0.1 键盘避让排查结论（2026-11-06）

**侧边栏结构问题**：原来 `nativeShell` 是根 `Stack`，主体 `Row` 通过 `margin-left` 让位，侧边栏是另一个 `position: absolute`、`zIndex: 40` 的 `Stack` 兄弟节点。页面级 `RESIZE` 缩短的是整个根 `Stack`，侧边栏和主体一起缩。现已改为 `Row` 第一列：侧边栏固定窗口高度，右侧内容独立参与 `RESIZE`。

**会话第二次不跟随**：`keyboardHeightChange` 里延迟贴底的判断写成了 `if (this.keyboardVp > 0)`，但 `RESIZE` 路径下 `keyboardVp` 恒为 0，导致第二次打开键盘时延迟 `scrollToNewest` 永远不执行。已改为 `if (this.keyboardPx > 0)`。

当前结构：

```text
Row
├─ Sidebar（固定窗口高度）
└─ ContentArea（侧栏右侧整块区域）
```

`contentAreaWidth()` 不再重复减侧栏宽度；ReelsPage 的 `leftInsetVp` 归零；SidebarHost 外层加 `zIndex(100)`；底部安全区只加在组件上，Reels 正文/动作区按“实测 bottomSafeVp + 16”避让。提交：`8f6f1b0`、`beb1f3e`、`4c116ef`、`ea1de3c`、`a39130d`。

这份文档是**目标方案**，不是已经完成的清单。当前实际状态：

| 模块 | 状态 | 说明 |
|---|---|---|
| 账号切换页面清理 | 部分完成 | `resetAccountPageState()` 已清右栏/tab/用户页 VM/帖子页/评论预取；`AccountScope.generation` + `MobileRequest` 已能丢弃换号后晚到的响应；`ProfileViewModel` 延迟预取已可取消并校验代次；通知请求新增代次（换号丢弃旧回包）；`AccountUiReset` 尚未抽出，缓存 key 账号分区未全量审计 |
| 设置/通知路由 | 已验收 | 左栏二级不堆叠、右栏三级可堆叠、二级返回回单栏；仍是 `navStack + tabletProfileStack` 两套栈，不是单栈 Split |
| 侧边栏安全区/误触 | 已修复 | 设置页安全区保持底色；chip 伪事件已加时间门控；`SidebarHost` 固定窗口高度；侧栏顶部/底部按钮分别避让 `topSafeVp` / `bottomSafeVp`；侧栏 `zIndex(100)`，设置页滑入不遮挡 |
| HDS 标题栏 | 已回退 | 按实测改回系统原始 HDS API，不再手写 `maskExtraHeight=48`/`blurRadius=80`；文档 2.4 的旧参数作废 |
| 滚动安全 | 已验收 | `safeScrollY()` / `ScrollerSafe` 已覆盖所有 `currentOffset().yOffset`；剩余只有它们的实现与注释 |
| Reels 崩溃 | 部分完成 | `VideoSurface` 已有 player/epoch 保护，冷启动缓存已移除，`ReelsSeen` 台账改异步落盘；仍无 `ReelsPlayerPool`、`LazyForEach`、`@Reusable` |
| 键盘避让 | 页面级 RESIZE | 按官方文档使用 `KeyboardAvoidMode.RESIZE`；会话输入条键盘弹起时贴页底（0vp），收起时只留 `bottomSafeVp` |
| Index 拆分 | 部分完成 | `SidebarHost`、`ContentArea`、`AppRoutes`、`AppRouter`、`PageRegistry`、`PageDestination` 已落地；所有 destination 分支已改为组件调用（含会话页副标题/头像）；`destinationBuilder` 仍有名字 switch |
| 布局/断点服务 | 部分完成 | `WindowLayoutService` 已抽出，`tabletWideShell`/`tabletSplitEnabled` 改为读断点；`contentAreaWidth` 不再重复减侧栏；Reels 标题/正文左边线统一；页面内容框架、安全区、侧栏宽度尚未统一 |
| 请求调度/幂等 | 部分完成 | 只读请求合并已抽成 `RequestScheduler`，`MobileRequest` 接入；点赞/转发有合并意图，收藏飞去重，Feed 翻页 stuck 判据已改；仍无统一写请求 busy/取消 |
| 主线程下沉 | 部分完成 | 探索流 1MB 级 JSON 已移入 taskpool（失败自动回退主线程）；Feed/Profile 的解析仍有主线程路径，inflate 与其余大包未全量下沉 |

**结论：文档约完成 48%。** 已稳定的是路由返回语义、账号页面清理、账号代次丢弃过期回包、通知代次、Reels epoch、侧栏安全区/层级、滚动安全、收藏/只读去重、`RequestScheduler`、探索流 taskpool 解析；`SidebarHost`、`ContentArea`、`AppRoutes`、`AppRouter`、`PageRegistry`、`PageDestination` 已落地，页面基本迁出。

后续落地顺序调整为：

1. 账号代次 + 请求 token + 页面销毁取消；
2. 键盘单次避让；
3. 写操作 busy/幂等；
4. Reels `LazyForEach` + 播放器池；
5. 主线程大 JSON/inflate 下沉；
6. 请求调度器；
7. 拆 `Index.ets`；
8. 统一断点/布局服务；
9. 侧边栏组件化；
10. 单栈 Navigation Split（风险最高，最后做）。

## 1. 现状判断

当前 `pages/Index.ets` 已经超过 1.3 万行，布局判断分散在：

- `tabletWideShell()`：宽度 ≥ 600
- `tabletSplitEnabled()`：宽度 ≥ 840
- `tabletHomeScoped()`：宽屏 + 右栏/会话舞台
- `reelsFullBleed()`、`settingsOverReels()`、`reelsSidebarWhite()`
- `tabletSidebarWidth()`、`profileStageWidth()`、`contentAreaWidth()`

同时存在多套导航栈：

- `navStack`：全局整页
- `tabletProfileStack`：平板右栏
- `directStageStack`：私信会话舞台

这带来几个结构性问题：

1. **页面会在不同栈之间迁移**，出现返回后旧页面复活、通知/设置页重新弹出。
2. **侧边栏展开会改父级布局状态**，触发 HDS/页面重建，长按和点击手势互相干扰。
3. **标题栏、侧边栏、安全区各自算一套尺寸**，出现 94vp、16vp、12vp 等硬编码。
4. **手机/平板存在隐式分支**，同一功能在两端的路径不完全一致，问题只在某一端复现。
5. **Reels 的 AVPlayer 生命周期与页面状态耦合**，慢网下异步回调晚到，原生层容易崩。

## 2. 目标架构

```text
AppShell
├─ WindowLayoutService
│   ├─ 断点：Compact / Medium / Expanded
│   ├─ 窗口尺寸、方向、折叠状态
│   ├─ 安全区 / 键盘 inset
│   └─ 侧边栏占位
├─ AdaptiveNavigation（唯一 NavPathStack）
│   ├─ Compact：NavigationMode.Stack
│   └─ Medium/Expanded：NavigationMode.Split
│        ├─ navBar：Home / 主导航壳
│        └─ content：Profile / Post / Settings / Notifications / Reels
├─ SidebarHost（HDS SideBar 或 SideBarContainer，独立状态）
└─ PersistentOverlays（Story / Comments / Toast）
```

核心原则：

- **一个路由栈**：不再维护 `tabletProfileStack`；分栏由 Navigation 的 Split 模式完成。
- **一个断点模型**：所有布局只读 `WindowLayoutService`，不再各自判断 `>=600 / >=840`。
- **一个安全区来源**：标题、内容、底栏、侧边栏都从同一份 inset 计算。
- **侧边栏独立**：展开/收起只更新侧边栏组件，不修改页面路由和主内容布局。

### 2.1 断点与栅格

官方建议使用栅格断点和窗口尺寸响应式布局：

- [GridRow/GridCol 栅格布局](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-layout-development-grid-layout?docScope=all#%E6%A0%85%E6%A0%BC%E5%AE%B9%E5%99%A8%E6%96%AD%E7%82%B9)
- [GridRow API](https://developer.huawei.com/consumer/cn/doc/harmonyOS-references/ts-container-gridrow)

建议断点：

| 类别 | 宽度 | 布局 |
|---|---|---|
| Compact | < 600vp | 单栏 + 底部 Tab |
| Medium | 600–839vp | 侧边栏浮层 + 单内容栏 |
| Expanded | ≥ 840vp | 侧边栏 + Navigation Split 双栏 |

实现方式：

- 用 `GridRow.breakpoints({ value: ['600vp', '840vp'], reference: BreakpointsReference.WindowSize })` 作为页面级栅格。
- `WindowLayoutService` 监听 `windowSizeChange`，输出一个不可变的 `LayoutSnapshot`：
  ```ts
  width, height, orientation, breakpoint, insets, sidebarWidth, isFoldable
  ```
- 删除 `tabletWideShell()`、`tabletSplitEnabled()` 等分散布尔值，改为 `layout.breakpoint` 派生。

### 2.2 导航：从“多栈迁移”改为“单栈 Split”

官方 Navigation 推荐单栈 + 自适应模式：

- [Navigation 组件使用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/arkts-navigation-navigation-V5)
- [Split-View 多栏实践](https://developer.huawei.com/consumer/en/doc/best-practices-V5/bpta-multi-columns-V5)

目标：

- 只保留一个 `NavPathStack`。
- Compact：`NavigationMode.Stack`，详情页整页压栈。
- Expanded：`NavigationMode.Split`，`navBarWidth` 在 320–420vp，详情页自动进右栏。
- 二级页面（设置分类、通知详情、用户主页）作为 Split 的 content 区。
- 三级页面继续 `pushPath`，覆盖在右栏 content 区。
- 删除：
  - `tabletProfileStack`
  - `migrateGlobalPageToRight()`
  - `migrateRightToGlobal()`
  - `removeByName()` / 手动补栈

返回语义：

- 一个返回键只做一个动作：pop 当前栈顶。
- 设置一级页单例：打开前检查栈顶，已存在则聚焦/刷新，不重复 push。
- 关闭设置一级页时，右栏 detail 随 Navigation 一起销毁，不靠 `onHidden` 手动清右栈。

> **当前实现（2026-11）**：上面是目标，不是现状。现在仍是 `navStack` + `tabletProfileStack` 两套栈：
> - 设置一级页在 `navStack`；
> - 二级页进 `tabletProfileStack`；
> - 左栏点击二级：先收右栏，再推入，不堆叠；
> - 右栏二级点击三级：压栈，三级返回二级，二级返回收右栏回单栏。
>
> 这套语义已经验收，单栈 Split 列为第 10 阶段，等前面性能/异步项稳定后再做。

### 2.3 侧边栏：独立浮层，不参与主内容布局

官方侧边栏能力：

- [SideBarContainer](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/ts-container-sidebarcontainer-V13)
- [HdsSideBar](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-container-sidebarcontainer)

建议：

- 使用 `SideBarContainer(SideBarContainerType.Overlay)` 或 `HdsSideBar`。
- `showSideBar`、`sideBarWidth`、`autoHide` 由侧边栏组件内部状态管理。
- 展开时**不修改主内容宽度**，侧边栏覆盖在主内容上。
- 侧边栏根节点负责手势隔离：
  - 不整层使用 `HitTestMode.Block`（会连子按钮一起吞掉）。
  - 用子按钮 `swallowLongPress` + 侧边栏实际矩形作为 hit 区域。
- 登录页禁用通知按钮；设置按钮保留。

收益：

- 展开/收起不再触发 `Index` 重排。
- 返回后的页面不会被侧边栏重建“翻出来”。
- 长按、点击不会穿透到 Reels 画面。

### 2.4 标题栏与安全区

统一一个 `AdaptiveTitleBar`：

- 页面只声明 `PageKind`（Home / Search / Profile / Reels / Detail / Settings）。
- 标题栏样式、`mainTitle`、菜单、padding 由同一个适配器输出。
- 删除各页自绘的标题 `Text` 和 `stackBuilder` 标题，统一 HDS `mainTitle`。
- 标题左边距：
  - Compact：屏幕边缘 + 16vp
  - Medium/Expanded：侧边栏实际右边界 + 16vp
- 不再硬编码 `94vp`、`116vp`、`REELS_TITLE_LEFT_PAD_VP`。
- 安全区统一从 `windowAvoidArea` + `expandSafeArea` 获取：
  - 只有需要沉浸的 Shell 层 `expandSafeArea`。
  - 页面内容使用 `SafeAreaInsets`，不自己猜状态栏高度。

#### HDS 标题栏规范（全 App，2026-11 修订）

> 下面这版是**现行实现**，不是最初设想。最初那版手写 `maskExtraHeight=48` / `blurRadius=80` 在真机上出现“有边界的白色蒙版”，已回退。

现策略：

```ts
scrollEffectOpts: {
  enableScrollEffect: true,
  scrollEffectType: titleScrollEffectType(isDarkUi)
},
systemMaterialEffect: {
  materialType: immersiveMaterialType(),
  materialLevel: immersiveLevel(materialLevel)
},
originalStyle: { contentStyle },
scrollEffectStyle: { contentStyle }
```

- 不再写 `backgroundStyle.backgroundColor`、`maskExtraHeight`、`blurRadius`；
- 渐变模糊交给 HDS 原生 API，避免出现一条清晰的蒙版边界；
- 主 Reels 页单独覆盖：`maskExtraHeight=0`、`blurRadius=0`、`materialType=NONE`；
- 首页/我的内容用 `94vp` 顶部避让，避免被标题栏盖住；滚动时内容仍会进入标题栏下方；
- 如果后续要再调模糊，只允许改 `scrollEffectType` 对应能力，不重新引入手写蒙版；
- 所有 `HdsNavigation` 和 `HdsNavDestination` 统一走 `mainTitleStyle()` / `reelsTitleStyle()`。

### 2.5 页面内容框架

新增 `AdaptivePageFrame`：

- Feed / Profile / Search：最大内容宽度 600–640vp，居中。
- 设置 / 表单：最大宽度 640vp。
- Reels / 视频：全宽，但信息层避让安全区。
- 使用 `GridRow/GridCol` 控制列数：
  - Compact：1 列
  - Medium：2 列
  - Expanded：3–4 列（按内容类型）
- 页面根节点不再使用手写 `margin-left: sidebarWidth`。

### 2.6 Reels 与播放器

问题不是“缓存少”，而是**慢网下异步回调与播放器释放竞争**。

方案：

1. 抽出 `ReelsPlayerPool`：
   - 最多 1 个播放中 + 1 个预加载。
   - 只有当前页首帧后才允许预加载下一条。
   - 网络差（RTT > 100ms / 下载速度低）时关闭预加载，优先当前条。
2. `VideoSurface` 生命周期：
   - 每个播放器带 `epoch`；
   - `create / setMediaSource / setPlaybackStrategy / prepare / play` 回调必须校验同一 `player + epoch`；
   - `teardown` 先解绑 surface，再 release；
   - 释放后禁止任何 `prepare`。
3. 页面层：
   - Reels 使用 `LazyForEach + @Reusable`，只保留当前 + 相邻一页。
   - 页面进入先出封面/骨架，播放器就绪后再撤封面，不阻塞首屏。
4. 失败策略：
   - 设源失败重试 1–2 次；
   - 超过阈值只显示封面 + 重试按钮，不无限重建播放器。
5. 诊断：
   - 保留 `ReelsCrashLog`，记录 `create/release/prepare/first frame` 和 alive 数；
   - 设置页提供“导出 Reels 诊断”。

### 2.7 会话输入框与键盘避让

当前 `DirectThreadPage` 的键盘处理是“双抬 + 反馈自校正”：

- 列表底部 `padding(bottom: keyboardVp)` 抬一次；
- 输入条再 `padding(bottom: base + keyboardVp)` 抬一次；
- `keyboardHeightChange` 回来后，又用 `getRectangleById` 量输入条位置，最多重试多次修正。

典型表现就是用户反馈的：

1. 键盘弹出瞬间，输入条先被系统/自身各抬一次，**闪到屏幕中间**；
2. 自校正再把它拉回底部；
3. 最终落点仍被输入法盖住一截。

根因不是某一个 padding 数值，而是**同一份键盘高度被两套布局同时消费，且落点靠事后测量修正**。

目标方案：

- 新增 `KeyboardInsetService`，和 `WindowLayoutService` 共用一份 `keyboardInset`：
  - 监听 `window.on('keyboardHeightChange')`；
  - 统一换算 px → vp；
  - 只保留“键盘顶边”一个坐标，不再让页面自己算屏幕高度。
- 页面只做**一次**避让：
  - 内容区（消息列表）底部 inset = 键盘高度；
  - 输入条不再额外加键盘 padding，而是作为内容区底部的正常子节点布局。
- 输入条锚点由布局决定，不再用 `getRectangleById` + 多次 `setTimeout` 自校正。
- 键盘动画与输入条位置使用同一条 `animateTo`：
  - 键盘高度变化时只做一次属性更新；
  - 避免“先到中间、再归位”的两段式位移。
- 处理首帧竞态：
  - `keyboardHeightChange` 可能先于页面布局完成；
  - 用 `WindowLayoutService` 的窗口/inset 快照做初始值，键盘事件只更新快照，不在回调里直接改多个 `@State`。
- 输入条与列表共用 `KeyboardAvoidingContainer`：
  - 底部安全区、键盘 inset、输入条高度只在这一层计算；
  - `DirectThreadPage` 不再同时维护 `keyboardVp` / `previewKeyboardVp` / `alignLiftPx` 三套值。

验收：

- 键盘弹出时输入条从底部平滑上移，不经过屏幕中间；
- 输入条底边始终在键盘顶边上方 `KEYBOARD_GAP_VP`；
- 键盘收起后输入条回到底部安全区；
- 连续快速开关键盘、切换输入法、横竖屏切换不漂移；
- 手机、平板右栏、分屏窗口表现一致。

### 2.8 状态与性能

- 拆分 `Index.ets`：
  - `AppShell`
  - `SidebarHost`
  - `HomeTab`
  - `ReelsHost`
  - `DirectHost`
  - `SearchHost`
  - `ProfileHost`
  - `DestinationRegistry`
- 页面数据放各自 ViewModel；Shell 只保留布局/路由状态。
- 列表统一 `LazyForEach`；列表项加 `@Reusable`；避免 `ForEach` 全量重建。
- 图片统一 `Image` 缓存与尺寸约束，禁止全屏大图当缩略图。
- 避免在 `build()` 里做网络/同步 IO；异步数据只写 ViewModel。

### 2.9 全局性能预算

| 指标 | 目标 |
|---|---|
| 首屏缓存命中 | ≤ 100ms 出内容 |
| 首屏网络 | ≤ 2.5s 出可交互内容 |
| Tab/侧边栏切换 | ≤ 100ms 出目标页骨架 |
| 主线程任务 | 单次 ≤ 8ms，禁止 > 16ms |
| 列表滚动 | 掉帧 < 1%，白块不可见 |
| Reels 首帧 | 正常网 ≤ 230ms，弱网必须出封面 |
| 页面返回 | 不重新请求、不重建列表 |
| 崩溃 | Reels 慢网/VPN 场景 crash-free |

实现约束：

- 所有耗时任务先进 `taskpool` / Worker，主线程只提交结果；
- 所有页面加载有 skeleton；缓存命中先显示，再后台刷新；
- 动画只做 `transform/opacity/color`，时长 160–320ms，避免长列表 layout 动画；
- 页面销毁取消请求/定时器/播放器，异步回调必须校验页面 token；
- 埋点：首帧、请求耗时、主线程长任务、播放器 alive 数、帧率。

## 3. 全 App UI/UX 与异步审计清单

这一节是重构前必须一起处理的“隐性问题”，不是纯视觉优化。

### P0：会导致崩溃、丢页、无法操作

| # | 位置 | 问题 | 优化 |
|---|---|---|---|
| 1 | `pages/Index.ets` | `navStack` / `tabletProfileStack` / `directStageStack` 三套栈并存，页面迁移和手动 `removeByName` 造成返回后旧页复活 | 收敛为单一 `NavPathStack`，用 Navigation Split 代替右栏栈 |
| 2 | `pages/Index.ets` + `tabletSidebar` | 侧边栏展开改父级状态，触发 HDS/页面重建；overlay 命中测试与标题热区叠加 | 侧边栏独立组件/`SideBarContainer`，主内容不重排，热区按实际矩形 |
| 3 | `components/VideoSurface.ets` | 慢网下 `setMediaSource` / `setPlaybackStrategy` 回调晚于释放/复用，旧 player 仍被 prepare | player + epoch 校验、释放后禁止 prepare、限制并发与重试 |
| 4 | `components/DirectThreadPage.ets` | 列表和输入条各加一次键盘高度，再用 `getRectangleById` 自校正，导致闪到中间、最终仍被盖 | 单一 `KeyboardInsetService`，只做一次布局避让 |
| 5 | `components/ProfilePage.ets`、`CommentsPanel.ets`、`FeedList.ets`、`DirectPage.ets`、`SearchPage.ets` | `Scroller.currentOffset()` 未挂载时返回 undefined，直接读 `.yOffset` 崩溃 | 统一 `scrollY()` 兜底（Profile 已修，其余纳入规范） |

### P1：高频交互/性能问题

| # | 位置 | 问题 | 优化 |
|---|---|---|---|
| 6 | `pages/Index.ets` | 标题栏样式分散，浅色白色蒙版、`maskExtraHeight` 偏矮、各页不一致 | 统一 `AdaptiveTitleBar` + HDS 蒙版策略（见 2.4） |
| 7 | `pages/Index.ets` | 设置一级页重复 push、右栏 detail 与一级页生命周期不同步 | 一级页单例，detail 由同一个 Navigation Split 管理 |
| 8 | `components/ReelsPage.ets` | 页面级 `ForEach` 构建全部 Reels，播放器/封面在切页时重建 | `LazyForEach + @Reusable`，只保留当前 + 相邻页 |
| 9 | `core/mobileapi/MobileRealtime.ets` | `Inflate` + `JSON` 解压仍在主线程 `setTimeout(0)`，大包会顶住一帧 | 移到 Worker/taskpool，主线程只派发结果 |
| 10 | `core/StoryCache.ets` | `DEPTH=8`、每位用户预取 3 条媒体，弱网下预取与当前请求抢带宽 | 网络自适应窗口：Wi-Fi 8/蜂窝 3/弱网 1，取消离屏预取 |
| 11 | `core/ApiThrottle.ets` | 全局并发 3、固定 1.5–3.5s 节奏，交互/预热/空闲共用一条队列 | 保留优先级的 `RequestScheduler`，支持取消和去重 |
| 12 | `components/*` | 按钮无统一 busy/disable，连点会重复点赞、关注、发送、下载 | `AsyncActionButton` + 业务幂等键 + 失败回滚 |
| 13 | 多页面 | 加载/空态/错误态不统一，失败后无重试或重复拉取 | 统一 `LoadState` + 骨架 + 错误重试 |
| 14 | 多页面 | 页面销毁后异步回调仍写 `@State`、定时器未清 | 页面 token/epoch，`aboutToDisappear` 统一清理 |
| 15 | 列表/图片 | 全量大图、未限制缓存、缩略图用原图 | 图片尺寸约束 + LRU + `cacheDownload` 预算 |
| 16 | `components/DirectThreadPage.ets` 等 | 透明热区、`HitTestMode.Transparent` 与手势竞争 | 只在真实交互矩形上挂事件，禁止整屏透明热区 |
| 17 | 全局 | 硬编码 94/116/12/16vp，安全区靠猜 | `WindowLayoutService` + `SafeAreaInsets` 单一来源 |
| 18 | 全局 | 深浅色、字体放大 1.3x、无障碍对比度未系统验收 | 主题 token + 对比度/字号回归 |

### 数据请求/缓存优化

1. **请求调度器**
   - 优先级：urgent（点开会话）> interactive（点开快拍/帖子）> warm（首屏）> idle（预取/诊断）；
   - 同 key 去重，同一资源只保留一个 in-flight；
   - 页面离开时取消非必要请求；
   - 响应带 request token，过期响应直接丢弃；
   - 重试指数退避 + 抖动 + 上限。

2. **缓存策略**
   - 内存 LRU + 24h 落盘 + 按账号隔离；
   - stale-while-revalidate：先显示旧数据，再后台刷新；
   - 缓存 key 包含账号、资源类型、清晰度，避免串号/串清晰度；
   - 弱网优先缓存，网络恢复再刷新。

3. **预取策略**
   - 从“固定 8 位 + 3 条媒体”改为网络/内存自适应；
   - 只预取当前 + 下一位，快速滑动时取消离屏预取；
   - 蜂窝网络默认关闭大图/视频预取；
   - 预取预算按字节/并发双限，不能压过当前请求。

4. **主线程**
   - JSON 解析、zlib inflate、复杂映射、图片元数据解析移到 `taskpool` / Worker；
   - 主线程只做状态提交和 UI 更新；
   - 批量更新 `@State`，避免每帧多次重绘；
   - 禁止在 `build()` 中做同步 IO、网络、排序。

5. **交互一致性**
   - 点赞/关注/收藏/发送：先乐观更新，失败回滚 + toast；
   - 请求中禁用按钮，避免重复写；
   - 统一 loading/empty/error/retry 四态；
   - 发送消息失败保留草稿，不静默丢失。

6. **列表与动画**
   - `LazyForEach` + `@Reusable` + 稳定 key；
   - 固定 item 高度，避免滚动中测量；
   - 动画只改变 `transform/opacity`，不对长列表做 layout 动画；
   - 页面切换动画与数据加载解耦，先出骨架/封面，数据到了再替换。

### 3.1 账号切换审计（重点）

`forgetAccountMemory()` 已经清了 `feed / reels / search / profile / direct` 这几个主 ViewModel，但页面级缓存和“按 tab 保存的右栏/会话状态”没有完整清，换号后可能：

- 切回某个 tab，右栏又恢复上一个账号打开的用户页/通知页；
- 打开用户主页时命中 `userProfileVms` 里上一个账号的 `ProfileViewModel`；
- 搜索 Reels、个人页 Reels 还是上一个人的列表；
- 帖子页缓存、评论预取、点赞/转发意图、媒体详情 Map 残留；
- 上一个账号的私信会话舞台/线程 id 仍挂在 `tabDirectThreads`；
- 旧的异步请求在换号后返回，把旧账号数据写进新账号的 ViewModel。

需要补齐的清理清单：

| 类别 | 需要清理 |
|---|---|
| 路由栈 | `navStack`、`tabletProfileStack`、`directStageStack`、`tabletRightName`、`tabletProfileParam`、`topPage`、`shownPages`、`navDepth` |
| tab 缓存 | `tabRightNames`、`tabRightParams`、`tabDirectThreads` |
| 页面 ViewModel | `profileReelsVm`、`searchReelsVm`、`reelsVm`、`reelsFollowVm`、`searchVm`、`profileVm`、`directVm`、`directThreadVm` |
| 用户页缓存 | `userProfileVms.clear()`（逐个 VM reset 后清 Map） |
| 内容缓存 | `postPagePosts`、`searchReelsOrder`、`mediaDetails`、`commentsPrefetch` |
| 交互意图 | `likeIntent`、`repostIntent`、`commentLiking` |
| 故事/高光 | `storyQueue`、`storyRects`、`highlightQueue`、`highlightRects` |
| 浮层 | 关闭 story / comments / account menu / web chrome / direct stage |
| 选中态 | `selectedTab`、`selectedIndex`、`tabletSidebarExpanded` 复位 |

实现原则：

- 抽出 `AccountUiReset`，由 `applySession(accountChanged)` 统一调用；
- 每个 ViewModel 增加 `accountGeneration`，异步回调写状态前校验；
- 所有缓存 key 必须带 `AccountScope.current()`；内存缓存也要按账号隔离；
- reset 必须是幂等的，任一步失败不阻断其余步骤；
- 增加“A 账号 → B 账号 → A 账号”的三段回归，检查页面、右栏、搜索结果、私信、Reels、通知均不串号。

### 3.2 数据/异步审计（代码定位）

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| 1 | `core/mobileapi/MobileRequest.ets:426` | 每个响应都完整 `JSON.parse`，只为读错误字段；200 成功也照解，大响应重复解析两次 | 先按状态码/前 N 字符判断，只在失败或小体上结构化解析 |
| 2 | `core/mobileapi/MobileDiscover.ets:233` | 探索流 0.5–1.3MB 在主线程解析，最大响应未 taskpool 化 | 新增 `@Concurrent` explore 解析，只回传所需字段 |
| 3 | `viewmodel/FeedViewModel.ets:1736`、`:1053` | 首屏/翻页串行等最多 6 发关注状态核对，叠加节流可能 10–20s | 先按接口字段上屏，后台核对，只查缺失作者 |
| 4 | `viewmodel/ReelsViewModel.ets:570`、`:575` | 每次铺页同步 stringify + putSync + flushSync 两次，最大 512KB | 节流批量异步写盘，seen 用 Set，写盘进 taskpool |
| 5 | `core/ShareProbe.ets:43` | `PROBE_ON = true`，发布版仍整包 parse + 9 次全文 indexOf | 关闭探针或只取前 2KB 判定 |
| 6 | `viewmodel/ReelsViewModel.ets:594-616` | 下拉刷新串行最多 4 页，可能转圈 40s | 8s 总预算，先上屏已有页，后台续补 |
| 7 | `core/DirectRealtime.ets:117`、`:230` | Worker 只解压，整帧 JSON parse + walk 仍在主线程 | 解析也放 Worker，只回传纯数据 |
| 8 | `workers/RealtimeWorker.ets:148-151`、`:107` | 逐字节 push、每帧复制剩余 buffer，粘包 O(n²) | Uint8Array 环形缓冲 + subarray |
| 9 | `viewmodel/ProfileViewModel.ets:1042-1057` | 裸 setTimeout 预取 3 页，无句柄/存活/账号判断 | 存句柄，销毁/换号取消，入口校验 generation |
| 10 | `viewmodel/ProfileReelsViewModel.ets:111-115`、`:217` | 每滑一条 2 发 media/info 且 urgent 插队，退出后仍 publish | 只给点开那条 urgent，下一条 interactive，300ms 去抖 |
| 11 | `viewmodel/FeedViewModel.ets:1626` | stuck 判据用错计数，几乎恒真，失效游标反复请求 | 用同口径计数，恢复 stuck 检测 |
| 12 | `viewmodel/DirectThreadViewModel.ets:1025`、`:882`、`:756` | O(n²) 数组去重；发送后额外 await 整条会话刷新 | Set/Map 去重，本地插入，批量/延迟刷新 |

### 3.3 UI/UX 交互审计补充

- 所有 `currentOffset().yOffset` 统一走 `scrollY()`，不仅 Profile；
- 所有 `setTimeout` 预取/滚动补帧要有页面 token 和 `clearTimeout`；
- 点赞/关注/收藏/发送/下载加 busy 与幂等键；
- 长列表统一 `LazyForEach`，避免 `ForEach` 全量构建；
- 缩略图不得使用原图 URL，统一尺寸约束 + 缓存预算；
- 侧边栏、标题、输入条、键盘只允许一个 inset 来源；
- 深浅色、字体 1.3x、无障碍对比度纳入回归。

### 线程/异步模型

| 层 | 职责 | 禁止 |
|---|---|---|
| UI 主线程 | 状态提交、布局、动画、手势 | JSON 大包解析、inflate、图片解码、同步 IO |
| `taskpool` | 短时 CPU 任务、批量映射、排序、解析 | 持有 UI 对象、直接写 `@State` |
| Worker | 长连接/实时解包、复杂计算、持续任务 | 频繁小消息、每包重建 worker |
| 网络层 | 请求、重试、取消、缓存 | 页面直接发请求、无超时等待 |

统一约定：

- 所有异步入口返回 `Promise` + `AbortSignal` 等价 token；
- 页面进入创建 token，离开时 cancel；回调先校验 token；
- 同一资源用 `inflight` Map 去重；
- 任务分级：urgent/interactive/warm/idle；
- 大对象（ArrayBuffer/字节流）通过 transfer 交给 Worker，不复制；
- 主线程每帧更新状态合并，避免连续 `@State` 写入；
- 定时器统一由页面生命周期管理，销毁时清理。

## 4. 分阶段落地

### Phase 0：基线与开关（1–2 天）

- 加入 `WindowLayoutService` 和 `layoutSnapshot`。
- 加 feature flag：`adaptiveShellV2`。
- 记录：首帧、切页耗时、侧边栏展开重建次数、Reels alive players、崩溃。

### Phase 1：断点/尺寸收敛（2–3 天）

- 删除分散的 `>=600` / `>=840` 判断。
- 统一 `Breakpoint`、`SafeAreaInsets`、`SidebarWidth`。
- 页面先保持现有视觉，只替换取值来源。

### Phase 2：单栈 Navigation Split（3–5 天，风险最高）

- 删除 `tabletProfileStack` 与迁移函数。
- 设置/通知/用户页作为 Split content。
- 验证：设置一级单例、二级右栏、三级叠层、返回语义。

### Phase 2.5：账号隔离与切换复位（2 天）

- 新增 `AccountUiReset`，统一清理路由栈、tab 缓存、页面 VM、用户页 VM Map、内容缓存、故事/高光队列；
- 各 ViewModel 增加 `accountGeneration`，换号后旧请求回包直接丢弃；
- 所有内存缓存 key 带账号分区；
- 回归 A→B→A 三段切换，页面/右栏/搜索/私信/Reels/通知不串号。

### Phase 3：侧边栏组件化（2 天）

- 改用 `SideBarContainer`/`HdsSideBar`。
- 展开状态内部化，主内容不重排。
- 手势隔离、登录页通知禁用。

### Phase 4：标题/安全区/内容框架（2–3 天）

- `AdaptiveTitleBar` 统一 `mainTitle`。
- 删除手写标题和硬编码 94/116。
- 全 App 标题栏走现行 HDS 原生渐变模糊；不再使用手写 `maskExtraHeight=48`/`blurRadius=80`。
- `AdaptivePageFrame` + `GridRow` 内容宽度。
- 抽出 `KeyboardInsetService` / `KeyboardAvoidingContainer`：
  - 会话页列表与输入条只消费一次键盘 inset；
  - 删除 `getRectangleById` 多次自校正；
  - 键盘弹起时输入条从底部一次平滑上移。

### Phase 5：Reels 播放器池（2–4 天）

- `ReelsPlayerPool` + epoch 生命周期。
- 慢网关闭预加载、失败重试上限。
- `LazyForEach/@Reusable`。

### Phase 6：资源与清理（2 天）

- 尺寸进 `resources/*/element/float.json`。
- 清理旧 Shell、死代码、重复样式。
- 回归 + 删除 feature flag。

## 5. 验收矩阵

### 设备/窗口

- 手机 360vp / 420vp，竖屏/横屏
- 折叠屏 600vp / 720vp，展开/半折
- 平板 840vp / 1080vp / 1440vp，分栏/全屏
- 窗口从 500 → 900 → 600 连续拖拽

### 导航

- 任意页面返回后展开侧边栏：不复活旧页
- 设置一级页重复点击：不叠层
- 设置二级页：右栏
- 设置三级页：右栏叠层
- 通知页返回：右栏关闭
- 10 层路由返回逐层正确

### 账号

- A 账号 → B 账号：首页/Reels/搜索/我的/私信/通知均不出现 A 的内容
- B 账号打开过的右栏页面，A 回来时不恢复
- A → B → A：A 的旧列表不覆盖 B，也不在 B 中闪现
- 换号时自动回到首页，底栏高亮与内容一致
- 换号后旧请求晚到，不覆盖新账号状态

### 视觉/安全区

- 浅色/深色
- 状态栏、手势条、刘海/挖孔
- 键盘弹出/收起
- 会话输入框：不闪到屏幕中间、不被输入法盖住半截
- 连续快速开关键盘、切换输入法、横竖屏切换后输入条位置不漂移
- 浅色模式所有页面 HDS 标题栏：无白色背板，使用系统原生渐变模糊，不再手写蒙版参数
- 首页/我的内容顶部避让 94vp，不被标题栏盖住；滚动时内容进入标题栏下方
- 字体放大 1.3x
- 侧边栏展开/收起标题不重叠

### Reels

- 正常 WiFi
- VPN 延迟 100–300ms
- 快速滑动 10 条
- 停在第一条播放 10 秒
- 切后台/回前台
- 弱网设源失败/重试

## 6. 风险与回滚

| 风险 | 处理 |
|---|---|
| HDS Split 能力差异 | 先做 feature flag；不支持时回退现有双栏，但保留单栈路由 |
| 导航重构回归大 | 按页面分批迁移，先设置/通知，再用户页/Reels |
| 侧边栏浮层遮挡标题 | 标题 padding 由 `SideBarHost` 实际矩形提供 |
| 播放器原生崩溃无法完全消除 | 限制并发 + epoch + 失败上限 + 诊断日志 |
| 视觉细节回退 | 每阶段保留截图对比与旧 Shell 开关 |

## 7. 参考文档

- [栅格布局 GridRow/GridCol](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-layout-development-grid-layout?docScope=all#%E6%A0%85%E6%A0%BC%E5%AE%B9%E5%99%A8%E6%96%AD%E7%82%B9)
- [Navigation 组件](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/arkts-navigation-navigation-V5)
- [Split-View 多栏实践](https://developer.huawei.com/consumer/en/doc/best-practices-V5/bpta-multi-columns-V5)
- [SideBarContainer](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V13/ts-container-sidebarcontainer-V13)
- [多设备适配实战](https://developer.huawei.com/consumer/cn/blog/topic/03210322288014042)
- [应用性能优化实践](https://developer.huawei.com/consumer/cn/doc/architecture-guides/practice-common-app-performance-v1-0000001949813401)
- [软键盘避让 FAQ](https://developer.huawei.com/consumer/cn/doc/harmonyOS-faqs/faqs-arkui-1073)
- [拉起软键盘后遮挡页面内容](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1118)
- [HdsNavigation API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/ui-design-hdsnavigation)
