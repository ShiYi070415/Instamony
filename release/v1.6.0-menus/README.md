# Instamony 1.6.0-menus

## 本次修改

- 没有侧边栏（手机 / 窄窗口）时：
  - 首页 HDS 标题栏菜单新增「通知」按钮；
  - 「我的」页 HDS 标题栏菜单新增「设定」按钮。
- 有侧边栏（平板 / 宽窗口）时保持原样，通知和设定仍在侧边栏底部。
- 登录适配 IG 新版网页密码加密：
  - 不再依赖已 404 的 `qe/sync`；
  - 从 Instagram 首页 HTML 读取 `InstagramPasswordEncryption`（version 10）；
  - 通过隐藏 WebView 执行网页加密，生成 `enc_password`。

## 文件

- `Instamony-1.6.0-menus.app` — 侧载安装包
- `Instamony-1.6.0-menus.hap` — HAP
