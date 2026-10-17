# Instarmony

一个 **HarmonyOS NEXT（ArkTS / ArkUI）** 的 Instagram 客户端：界面全部原生实现，数据来自
**Instagram 私有移动 API（instagrapi 那套协议）+ 一个隐藏的 WebView 会话**。

> 个人自用 / 学习项目。不是 Instagram 官方客户端，与 Meta 无关。
> 它调用的是**非公开接口**，随时可能失效；用真实账号高频使用**有被限流甚至被判异常的风险**，
> 请自己拿主意（置顶提醒见下面的「风险」一节）。

---

## 它是怎么工作的（一句话）

隐藏 WebView 负责**登录**并持有会话（Cookie 罐），原生侧把这份会话包装成"官方 Android App"
的身份去打 `i.instagram.com/api/v1/...`，界面用 ArkUI 重画。所以：

- **不用**抓网页 DOM 来渲染界面（早期版本那样做过，脆、慢）；
- 大部分数据源都是**一发私有 REST**（快拍 / 私信 / 主页 / 通知 / 点赞 / 收藏 / 关注都在这条路上）；
- 少数没有 REST 等价物的接口（信息流时间线、reels 首屏、转发、评论点赞等）走
  **模板回放**：让页面自己发一次、把请求存成模板、之后原生照着发，失败再退回网页驱动。

## 已实现

| 页面 | 数据来源 |
|---|---|
| 首页信息流 | 模板回放（`PolarisFeedTimelineRootV2Query`）+ 网页兜底 |
| 快拍 | `feed/reels_tray/`、`feed/user/{pk}/story/`、`feed/reels_media/` |
| Reels | clips GraphQL 模板 + 移动端 `discover/topical_explore/` 兜底 |
| 私信 | `direct_v2/inbox/`、`direct_v2/threads/{id}/` |
| 搜索 | `fbsearch/account_serp/`、`users/search/`、`fbsearch/top_serp/`、`discover/topical_explore/` |
| 我的 / 他人主页 | `users/{pk}/info/`、`feed/user/{pk}/`、`clips/user/`、`feed/saved/`、`usertags/{pk}/feed/` |
| 帖子页 / 评论 | 模板回放 + 移动端写接口（`media/{pk}/like|save|comment` 等） |
| 通知 | `news/inbox/`（instagrapi 协议）+ 网页 REST 兜底 |
| 翻译 | 在线接口三级兜底（gtx → clients5 → MyMemory），只翻非中文正文 |

更细的功能清单、已知问题与未实现项：[`RELEASE_0.9.md`](RELEASE_0.9.md)。
协议移植的实测记录（端点表 / 参数 / 判据 / 限速结论）：[`INSTAGRAPI_PORT.md`](INSTAGRAPI_PORT.md)。
"为什么会被 IG 判成自动化"的分析与降噪措施：[`FINGERPRINT_ANALYSIS.md`](FINGERPRINT_ANALYSIS.md)。
审计待办： [`AUDIT_TODO.md`](AUDIT_TODO.md)。

## 目录结构

```
AppScope/                     应用级配置（包名 com.fanha.instarmony、图标、版本）
entry/src/main/ets/
  entryability/               入口 Ability：引擎初始化、预热、深链
  pages/                      页面（Index 是主壳 + 各个 NavDestination）
  components/                 原生组件（FeedList / ReelsPage / CommentsPanel / MaterialSurface …）
  viewmodel/                  各页面的状态与游标链
  core/                       协议层：取数 / 互动 / 缓存 / 限速 / 身份
    mobileapi/                **instagrapi 私有 API 端口**（会话、签名、各端点）
  bridge/                     隐藏 WebView 的脚本注入与模板抓取
  model/                      UI 用的数据模型
  probe/                      网页探针面板（诊断用）
entry/src/main/resources/     字符串 / 颜色 / 媒体资源
tools/                        构建与校验脚本（见下）
legacy/unwired/               早期未接线的分层（已归档，仅供追溯）
```

## 构建

**用 DevEco Studio（推荐）**

1. 装 DevEco Studio（本项目用 6.x）+ HarmonyOS SDK **API 20 起**（`compatibleSdkVersion 6.0.0(20)`）；
2. 复制签名模板并配置签名：
   ```powershell
   copy build-profile.example.json5 build-profile.json5
   ```
   然后 File > Project Structure > Signing Configs > "Automatically generate signature"；
3. 直接 Run。

**命令行（不用 IDE 打开工程）**

```powershell
# 编译出 debug HAP
.\tools\build.ps1
# 编译 + 安装 + 启动 + 抓 8 秒日志（需要 hdc 与已连接的设备）
.\tools\build.ps1 -Install
# 路径不在默认位置时显式给（DevEco 装在别处 / 换了 SDK）
.\tools\build.ps1 -Hvigor '<DevEco>\tools\hvigor\bin\hvigorw.bat' -SdkHome '<DevEco>\sdk'
```

脚本会把 hvigor / npm 的缓存重定向到工程内的 `.hvigor-home`（沙箱里 `~/.hvigor` 不可写时
必需），并在 hvigor 引擎没被正确引导时从 DevEco 自带的那份补进去 —— 细节写在脚本注释里。

产物：`entry\build\default\outputs\default\entry-default-signed.hap`

## 运行时需要什么

- 一台 HarmonyOS NEXT 设备或模拟器（API 20+）；
- 首次启动后用**你自己的 Instagram 账号**在 App 内登录（登录发生在隐藏 WebView 里，
  会话留在本机 Cookie 罐中，不会外传）。

## 风险（请先读）

- 用的是**非公开接口**，IG 随时会改；本项目对失败路径都做了降级与提示，但功能可能突然不好用；
- 高频请求会触发 `feedback_required` / `rate limit`（代码里有限速闸门与冷却，仍有概率）；
- **翻译**功能会把待翻译正文发到第三方在线翻译接口（见 `core/Translator.ets` 文件头）；
- 账号安全自负：不要拿主账号做压测；本项目不做点赞/关注自动化爬取，但**任何非官方客户端都存在风险**。

## 未实现 / 半接线

见 [`RELEASE_0.9.md`](RELEASE_0.9.md) 第 3 节。几个大头：信息流首屏仍依赖网页模板、
Reels 主路常被限流、通知的推荐位只能走网页兜底、快拍"已看"不上报。

## 许可

仓库暂未附开源许可文件。若要允许他人使用 / 修改 / 分发，请自行添加（例如 MIT / Apache-2.0）；
在此之前默认保留所有权利。
