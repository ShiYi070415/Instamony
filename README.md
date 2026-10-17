# Instarmony

原生 HarmonyOS（ArkTS / ArkUI）的 Instagram 客户端：界面全部用 ArkUI 实现，
数据来自**隐藏 WebView 持有的会话 + instagrapi 那套私有移动 API**。

个人自用 / 学习项目，与 Instagram / Meta 无关。

[English](README.en.md) · 采用 [Apache-2.0](LICENSE) 许可证。

## 功能概览

| | |
|:--|:--|
| **完整的信息流体验** | 首页时间线（下拉刷新 / 触底翻页 / 骨架屏）、快拍托盘与播放器、Reels 全屏竖滑、帖子页与评论浮层。 |
| **私信** | 收件箱、会话页（文本 / 媒体 / 分享帖 / Reel / 贴纸 / 语音等 XMA 类型）、发送文本、预取与快照缓存。 |
| **搜索** | 关键词搜账号、空关键词的三列推荐瀑布流、点开进 Reels。 |
| **个人主页** | 帖子 / 视频 / 收藏 / 被标注四个分页，别人主页复用同一套页面，视频分页可进 Reels。 |
| **通知** | 按 今天 / 昨天 / 过去 7 天 / 过去 30 天 / 更早 / 为你推荐 分段，过期分段折叠在「显示更多」后。 |
| **互动** | 点赞、收藏、转发、关注、评论、评论点赞全部走 HTTP 直发；状态有会话级覆盖表，跨页面一致。 |
| **原生 HarmonyOS 设计** | ArkUI 组件、系统符号、沉浸光感材质（HDS）与降级路径、明暗主题、深浅两种材质厚度。 |
| **诚实的降级** | 接口被限流 / 模板过期 / 会话失效时，界面显示具体原因，并按"移动端 → 模板回放 → 网页驱动"逐级回退。 |

## 工作原理

隐藏 WebView 负责**登录**并持有会话（Cookie 罐），原生侧把这份会话包装成"官方 Android App"
的身份去请求 `i.instagram.com/api/v1/...`。所以：

- 界面**不**依赖抓网页 DOM 渲染（早期版本那样做过，慢且脆）；
- 绝大多数数据源是一发私有 REST：快拍、私信、主页、通知、点赞、收藏、关注、搜索；
- 少数没有 REST 等价物的（信息流时间线、Reels 首屏、转发、评论点赞）走**模板回放**：
  让页面自己发一次请求、存成模板，之后原生照着重发，失败再退回网页驱动。

## 工程配置

| 项目 | 当前配置 |
|:--|:--|
| 应用 | `Instarmony` · `com.fanha.instarmony` · 版本 `0.9`（`versionCode` 9000） |
| 模块 | `entry` · Stage 模型 |
| SDK | 目标 SDK `26.0.0` · **兼容 SDK `6.0.0 (API 20)`** |
| 设备 | `phone`、`tablet` · 全屏 `EntryAbility` |
| 权限 | `ohos.permission.INTERNET` |
| 构建 | DevEco Studio 6.x / hvigor `6.26.4` |

## 构建

**DevEco Studio（推荐）**

1. 安装 DevEco Studio 6.x 与 HarmonyOS SDK（API 20 起）；
2. 复制签名模板并配置签名：
   ```powershell
   copy build-profile.example.json5 build-profile.json5
   ```
   File > Project Structure > Signing Configs > "Automatically generate signature"；
3. Run。

**命令行（不用打开 IDE）**

```powershell
.\tools\build.ps1            # 编译 debug HAP
.\tools\build.ps1 -Install   # 编译 + 安装 + 启动 + 抓 8 秒日志
```

产物：`entry\build\default\outputs\default\entry-default-signed.hap`

> `build-profile.json5` 是**本机签名配置**（含本机路径与签名口令），不随仓库提交；
> 仓库里只有 `build-profile.example.json5`。脚本会把 hvigor / npm 缓存重定向到工程内的
> `.hvigor-home`（沙箱里 `~/.hvigor` 不可写时必需），细节见脚本注释。

## 使用

1. 安装后在 App 内用**自己的 Instagram 账号**登录（登录发生在隐藏 WebView 里，
   会话留在本机 Cookie 罐，不上传任何地方）；
2. 首次进入某些页面时，App 可能让隐藏网页"跑一趟"把请求模板抓下来（日志里会写原因）。

## 风险（请先读）

- 用的是**非公开接口**，IG 随时会改；本项目对失败路径都有降级与提示，但功能可能突然不好用；
- 高频请求会触发 `feedback_required` / `rate limit`（代码里有限速闸门与冷却，仍有概率）；
- **翻译**功能会把待翻译正文发到第三方在线翻译接口（见 `core/Translator.ets` 文件头）；
- 不要拿主账号做压测；任何非官方客户端都有账号风险，自负。

## 目录

```
AppScope/                应用级配置（包名、图标、版本）
entry/src/main/ets/
  entryability/          入口 Ability：引擎初始化、预热、深链
  pages/                 页面（Index 是主壳 + 各 NavDestination）
  components/            原生组件（FeedList / ReelsPage / CommentsPanel / MaterialSurface …）
  viewmodel/             各页面的状态与游标链
  core/                  协议层：取数 / 互动 / 缓存 / 限速 / 身份 / 翻译
    mobileapi/           instagrapi 私有 API 端口（会话、签名、各端点）
  bridge/                隐藏 WebView 的脚本注入与模板抓取
  model/                 UI 用的数据模型
  probe/                 网页探针面板（诊断）
entry/src/main/resources/  字符串 / 颜色 / 媒体 / 预置请求模板
tools/                   构建与校验脚本
legacy/unwired/          早期未接线的分层（已归档）
```

## 文档

- [`RELEASE_0.9.md`](RELEASE_0.9.md) —— 功能清单、已知问题、未实现项
- [`INSTAGRAPI_PORT.md`](INSTAGRAPI_PORT.md) —— 移动端协议移植记录：端点表、参数、判据、限速结论
- [`FINGERPRINT_ANALYSIS.md`](FINGERPRINT_ANALYSIS.md) —— "为什么会被判成自动化"的分析与降噪措施
- [`AUDIT_TODO.md`](AUDIT_TODO.md) —— 审计待办与遗留项

## 许可证

本项目采用 [Apache License 2.0](LICENSE)。

第三方说明：Instagram、Meta 等名称与商标归其各自所有者所有；本项目与它们无关联。
