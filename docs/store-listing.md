# Instamony —— AGC 商店文案（Brief / Full introduction）

> 用途：AppGallery Connect → App information 里的 **Brief introduction**（≤80 字符）与
> **Full introduction**（≤8000 字符）。英文给 English 站，中文给中文站。
> 说明：这是第三方客户端，文案里**不出现**"官方/授权"，并明确写免责声明，降低审核风险。

## English

### Brief introduction（78 chars）

```
A fast, native HarmonyOS client for browsing feeds, Reels and direct messages.
```

备选（更含蓄，若审核对平台名敏感就换这条）：

```
A native HarmonyOS app for social feeds, short videos and direct messages.
```

### Full introduction

```
Instamony is a fast, native application for HarmonyOS NEXT that keeps your social
inbox within reach.

Instead of loading a full web page for every screen, Instamony talks to the service
APIs directly and renders everything with native ArkUI components. Scrolling stays
smooth, images are prefetched ahead of your finger, and the app remembers what you
were reading so it can come back instantly.

WHAT YOU CAN DO
• Home feed — photos, carousels and videos with inline playback, likes, saves,
  reposts and comment threads.
• Reels — full-screen vertical playback with seek, hold-to-speed, and comments.
• Explore and Search — a waterfall grid plus a search page that keeps the current
  results until the new ones arrive, so nothing flickers.
• Stories — tap the tray to watch, with a progress bar and the usual gestures.
• Direct messages — the whole inbox: unread badges, read receipts, typing-free
  realtime updates, attachments, voice notes, and shared posts/Reels rendered as
  cards you can tap to open in a Reels-style page.
• Profiles — grid, Reels tab and tagged tab, follow/unfollow, saved collections.
• Notifications — likes, comments and new followers in one list.
• Multi-account — keep several accounts signed in and switch with one tap.

DESIGNED FOR HARMONYOS
• Immersive material (glass) surfaces on controls, following the system look,
  with an automatic fallback on devices that don't support it.
• Haptic feedback on the gestures that deserve it (long-press for 2× speed).
• Light and dark themes, and layouts that adapt to phone and foldable widths.
• Data is cached locally where it helps: the inbox, the last screen of a
  conversation, and media details load from memory first, network second.

PRIVACY
• No analytics SDK, no advertising SDK, no third-party trackers.
• Sign in with your own account inside the app; the session stays on your device.
• Your credentials and cookies are never uploaded to any server of ours — there
  is no "our server": everything runs on the device.
• Nothing is shared with anyone. Uninstalling the app removes its local data.

REQUIREMENTS
• HarmonyOS NEXT 5.0 or later (API 20+).
• A network connection and your own account credentials for the service you use.

DISCLAIMER
Instamony is an independent, unofficial project. It is not affiliated with,
endorsed by, or sponsored by Instagram or Meta Platforms, Inc. All trademarks
belong to their respective owners. The app is a viewer: it does not host, resell
or redistribute any content, and it does not bypass any paywall or private
content. You use it with your own account and remain bound by that service's
terms.
```

## 中文

### 简短介绍（30 字）

```
轻快的鸿蒙原生客户端：信息流、Reels、快拍、私信一站浏览，手势与沉浸光感都是原生的。
```

### 详细描述

```
Instamony 是一个为 HarmonyOS NEXT 打造的原生客户端，把社交信息流装进一个即点即开的
应用里。

它不靠"每个页面套一个网页"：数据直接走接口，界面全部由 ArkUI 原生组件绘制。所以滑动
是顺的、图片会提前预载、退出再进来还能直接回到刚才的位置。

可以做什么
• 首页信息流 —— 单图、多图、视频内联播放，点赞、收藏、转发、评论区。
• Reels —— 整屏竖向播放，可拖动进度、长按 2 倍速、打开评论。
• 探索与搜索 —— 瀑布流网格；搜索页在新结果回来之前保留当前列表，不会闪空。
• 快拍 —— 点头像托盘即看，带进度条与常用手势。
• 私信 —— 完整收件箱：未读角标、已读回执、实时更新、附件与语音，转发的帖子/Reels
  会画成卡片，点开进入类 Reels 页面。
• 个人主页 —— 网格、Reels 分页、被提及分页，关注/取关、收藏合集。
• 通知 —— 点赞、评论、新关注集中在一条时间线里。
• 多账号 —— 同时登录多个账号，一键切换。

为 HarmonyOS 做的设计
• 控件使用系统的沉浸光感材质，不支持的设备自动降级为毛玻璃观感。
• 该有触感的地方给触感（长按 2 倍速）。
• 深浅色主题、手机与折叠屏宽度自适应。
• 该缓存的地方缓存：收件箱、会话最后一屏、媒体详情都是"先内存、再网络"。

隐私
• 没有统计 SDK、没有广告 SDK、没有任何第三方追踪。
• 用你自己的账号在应用内登录，登录态只留在你的设备上。
• 凭据与 Cookie 不会上传到任何服务器 —— 因为这个应用没有"我们的服务器"。
• 卸载即清除本地数据。

运行要求
• HarmonyOS NEXT 5.0 及以上（API 20+）。
• 需要网络，以及你所使用服务的账号。

免责声明
Instamony 是一个独立的非官方项目，与 Instagram、Meta Platforms, Inc. 没有任何隶属、
授权或赞助关系；相关商标归各自所有者。本应用只做浏览：不托管、不转售、不再分发任何
内容，也不绕过任何付费墙或私密内容。请使用你自己的账号，并遵守相应服务的条款。
```

## 填表提示

- **Brief introduction** 上限 80 字符（中文按字符算），上面英文版 78、中文版 30 左右，都在限内；
- **Full introduction** 上限 8000 字符，上面两份都远低于上限，可以按需增删；
- **Privacy policy URL** 是必填项，建议单独放一页（我可以直接生成 HTML 然后你挂 GitHub Pages）；
- 如果审核提示"第三方平台/商标"问题，把 Brief 换成上面那条更含蓄的备选，并把 Full 里
  "Instagram / Meta" 的出现次数降到最低（改成"the service"）。
