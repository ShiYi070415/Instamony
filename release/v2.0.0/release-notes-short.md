# Instamony v2.0.0 精简版

> `2.0.0`（2000000）｜侧载 `com.yijin.instamony`｜AGC `com.oneleaf.instamony`

- 新增 **越南语、意大利语**，共 9 种语言。
- 多图帖下载：一次保存全部原图，不再只存第一张。
- 快拍卡片切下一位：预渲染/预取、媒体就绪再换面，减少黑闪和等待。
- 新增平板 UI：侧边栏独立第一列、左右栏统一宽度、分割线对齐、底部安全区。
- 快拍/Highlight 支持按当前媒体下载图片或视频。
- 侧载 HAP 使用 `com.yijin.instamony`，AGC 邀测包使用 `com.oneleaf.instamony`，两者可共存。
- Reels 稳定性：播放器池、LazyForEach、@Reusable，继续收敛闪退。
- 换账号取消在飞请求，清账号级状态，减少串号。
- 新增 2FA「其他设备同意」登录，等待同意后自动完成，无需手输验证码。
- 通知失败态可重试；评论/快拍输入条避让底部系统条。

**下载**

- `Instamony-2.0.0.hap`：`hdc install`
- `Instamony-2.0.0.app.delete`：去掉 `.delete` 即 App Pack

**注意**

- 从 1.6.0 升级需重新登录；旧包数据不自动迁移。
- Reels 闪退受机型和视频源影响，本轮为继续收敛，不保证全部消失。
- Push Kit 侧载仍不可用。

完整说明见 GitHub Release。
