# 性能优化笔记（持续更新）

> 记录"为什么慢、改了什么、怎么验证"，避免下次重新踩。

## 1. 请求排队（ApiThrottle）是主页慢的主因

`core/ApiThrottle` 给移动端 API 加了节奏闸门，**间隔按上一发开始算**：

| 优先级 | 间隔 |
|---|---|
| `urgent` | 立即排到最前 |
| `interactive` | **600 + 0~600ms** |
| `warm` | **1500 + 0~2000ms** |
| `idle` | 只在所有交互请求空闲时才跑 |

个人主页一次进入要发 **6 发**（头部 / 当前分页网格 / 高光 / 另外三段首页）。
原来高光和"另外三段首页"都用 `warm`，于是：

- 高光（首屏可见）等 1.5~3.5 秒才轮到；
- 背景预取还和用户切段/翻页抢 in-flight 名额。

**已改**（2026-10-30）：

- `NativeProfile.highlights` → `interactive`；
- `NativeProfile.fetchPosts` 增 `priority` 形参；`ProfileViewModel.loadTabInBackground`
  （另外三段首页）传 `idle`；
- `ProfileViewModel.prefetchNext`（当前段往后翻）传 `warm` —— 让"用户当场触底那一发"
  （`interactive`）先走。

## 2. TLS 连接复用（keep-alive）

原来是**每一发请求都新建一条 TCP + 完整 TLS1.3 握手**（1~2 RTT + X25519/HKDF 计算），
6 发请求= 6 次握手，这在弱网/VPN 下非常贵。

**已改**（`core/net/Tls13Client`）：

- 请求头从 `Connection: close` 改为 `Connection: keep-alive`；
- 增加**连接池**（同 host:port 复用一条，空闲 8 秒过期，过期由定时器关掉）；
- 只有**干净收尾**的响应才把连接放回池子：`TlsHttpReply.complete`（按 `Content-Length`
  收满 / chunked `0\r\n\r\n` 收尾）+ 响应头没有 `Connection: close`；
- 复用失败（对端已关、状态坏了）自动退回"新建一条"，对调用方透明；
- `readHttpReply` 补了一条：**既无 Content-Length 又非 chunked 的响应只交出头**（keep-alive
  下对端不会主动关连接，否则会一直等到超时）；
- 诊断：`Tls13Client.poolHits()` 给出复用命中次数，日志里每次命中打一行 `reuse pooled connection`。

## 3. 解析：已经在 TaskPool，且 worker 是最瘦形态

- 个人主页网格：`MobileProfile` → `taskpool.execute(parseProfileGrid, body)`，
  `workers/ProfileParseTask.ets` **零 import**（官方文档：`@Concurrent` 所在文件 import 过多模块
  会让 TaskPool 首次执行多花几百毫秒）；
- reels 一条：`workers/ReelsParseTask` + `workers/ReelsParseModels`（纯数据模型单独成文件，
  避免把带 `@Observed` 的 `model/Reel` 拖进 worker —— 那会直接 `ReferenceError: Observed is not defined`）。

## 4. 列表与图片

- 个人主页网格**已在用 `LazyForEach`**（行级数据源 + 代次键，见 `ProfileRowSource`）；
- 头部有落盘快照先画（`AppSettings.saveProfileHeader` → `paintHeaderSnapshot`）；
- 高光有内存缓存（`ProfileViewModel.highlightCache`，命中当帧出图）。

## 5. 主页图片预热：只留"界面真吃得到"的那一条

`ProfileViewModel.precacheTabMedia` 原来同时调了 `PosterCache.warm(...)` 和 `MediaPrefetch.prefetch(...)`。
2026-10-30 核对发现：**`PosterCache` 的 PixelMap 只有 `FeedList` / `MediaCarousel` 在读**
（`PosterCache.pixel(...)`），而个人主页的格子 / 高光 / 头像全是普通 `Image(url)` ——
也就是说这里原来最多 96 次"自己发 HTTP 下缩略图 + 解码成 PixelMap"完全没人用，纯烧流量和 CPU。

**已改**：

- `precacheTabMedia` 去掉 `PosterCache.warm`，只留 `MediaPrefetch.prefetch`
  （它走系统的 `cacheDownload`，`Image` 组件命中它，才是主页真正吃得到的预热）；
- 新增 `ProfileViewModel.prefetchHighlightCovers`：高光列表拿到（或缓存命中）时，
  把前 6 张封面丢进同一个系统图片缓存 —— 消掉"那一排灰底慢慢出图"。

## 6. 死代码清理（2026-10-30，净 -817 行）

用两个脚本扫全项目（171 个 ets/ts）：

1. **未使用的具名导入**：43 个，已全部删除；
2. **零引用导出**（其他文件从不引用，且本文件里也只有声明那一行）：31 个，删除 859 行。

其中最大的一块是 `bridge/WebScripts.ets` 的 15 个网页注入脚本常量（655 行）——
那些是"登录/信息流还走 WebView"时代的遗留，改成全原生后早就不用了。

删除后 `BUILD SUCCESSFUL`，且没有新增告警；被删的都验证过"全项目零引用"。

## 7. 还没做（候选）

1. **翻页结果复用**：`nextPages` 队列已有，可把"预取到的下一页"在滚动接近触底时提前 apply；
2. **HTTP/2**：IG 支持 h2，多路复用能进一步减少往返（改动大，需要重写帧层）；
3. **preconnect**：进入主页前先对 `i.instagram.com` 预热一条连接（配合已实现的连接池）；
4. 剩余 20 个"外部零引用但本文件内有用"的导出 → 可以去掉 `export` 关键字（纯整洁，收益小）。
