# Reels 原生闪退：复盘（2026-10-30）

> 用途：以后遇到「reels 闪退 / 播一会儿就没了 / feeds 不崩 reels 崩」这类反馈，先看这份。

## 现象

- reels 打开后**不滑动也会闪退**（常常是首帧出来几秒后，`progress=4s` 附近）；
- **信息流（feeds）不闪退**；
- 没有任何 JS 异常被 `errorManager` 抓到，`hiAppEvent` 也没有 fault 记录 → **原生层 abort**；
- hilog 在真机上会被冲掉，用户没有 hdc，所以只能靠 App 自己写的滚动日志。

## 排查路径（可按顺序复用）

1. **先分清"JS 崩"还是"原生崩"**
   - `errorManager.on('globalErrorOccurred')`（API 18+）抓 JS 未捕获异常，写进 `Instamony_reels.log`；
   - `hiAppEvent.addWatcher`（domain=OS、`EventType.FAULT`）抓系统级崩溃/卡死；
   - 两条都没有、却出现 `session ABORTED` → 原生层，别再翻 JS 堆栈。

2. **崩溃现场日志必须"立即落盘"**
   - `ReelsCrashLog.note()` 是攒 4 行才刷盘，硬崩时最后 0~3 行会丢；
   - 关键路径一律用 `ReelsCrashLog.noteNow()`（记一行立刻 fsync）。

3. **崩溃日志要"只推尾部"**
   - MeoW 单条上限 3500 字，按头部推会把崩溃现场截掉；
   - `SettingsPanel.pushReelsCrashLog` 只发末尾 3000 字（开头标注省略多少）。

## 根因（两个叠加）

### 1) worker 里 `@Observed` 未定义（JS 崩）

```
uncaught ReferenceError: Observed is not defined @Taskpool Thread func_main_0
    at func_main_0 (entry|entry|1.0.0|src/main/ets/model/Reel.ts:75:1)
```

`workers/ReelsParseTask`（`@Concurrent`）从 `core/NativeReels` 取纯数据模型，而 `NativeReels`
import 了带 `@Observed` 的 `model/Reel`。TaskPool 线程没有 ArkUI 状态管理运行时，模块求值到
`@Observed` 就抛。

**修法**：纯字段类型（`Ig*` 接口 + `ReelsPageRaw`）整体搬到 `workers/ReelsParseModels.ets`，
worker 与 `NativeReels` 都从那里取 —— worker 的模块图里不再出现 `Reel`。

### 2) 同时活着的 AVPlayer 太多（原生崩）

崩溃前的现场（真机日志）：

```
18:03:54.38 player create begin alive=1 preload=y
18:03:54.48 player create begin alive=1 preload=y
18:03:54.67 player create ok alive=3        ← 0.3 秒内建出 3 个播放器
18:04:09.14 progress=4s
session ABORTED
```

reels 原来**预加载下两条**（`activeIndex+1` 与 `+2`），于是"当前 1 个 + 预加载 2 个"= 3 个
解码器 + 3 块 XComponent 表面；feeds 只挂 1 个，所以 feeds 不崩。

**修法**（两道一起上）：

- `ReelsPage`：预加载收回到**只有下一条**；
- `VideoSurface`：
  · 预算 = 已建好 + **创建中**（`pendingCreates`）。上一版只看 `alivePlayers`，三个并发创建时
    `alive` 还是 1，闸门形同虚设；
  · 全局串行：同一时刻只允许一个 `createAVPlayer` 在飞，其它实例 150ms 后重试。

## 结果

按上述改动后复测通过（用户确认"问题解决"）。

## 留下的常驻能力（别删）

- `core/ReelsCrashLog`：滚动崩溃日志（同步写、上限 64KB、每 4 行刷盘）+ `noteNow()`；
- `EntryAbility`：`globalErrorOccurred` + `hiAppEvent` fault watcher 两路打点；
- 设置 → 诊断：**推送 reels 崩溃日志（MeoW）**（只推尾部，昵称 `Yijin0`、标题 `栗子炸弹`）、
  **推送登录日志（MeoW）**、**网络节点体检**、**登录通道自检**。

## 调试打点的取舍

排查期间 `state=…` / `progress=…` 是 `noteNow`（每行 fsync）；问题解决后已降回 `note`（攒批刷盘），
只保留播放器初始化关键步（create / mediaSource / bind / prepare / play / first frame）的 `noteNow`。
下次再查类似问题时，把这几处临时改回 `noteNow` 即可。
