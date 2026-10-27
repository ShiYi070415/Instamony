# 隐私政策页面（AGC 的 Privacy policy URL）

文件：`docs/privacy.html` —— 单文件、无脚本、无 Cookie、无外部资源，直接丢到任何静态托管就能用。

## 发布到 GitHub Pages（2 分钟）

1. 把仓库推上去（`docs/privacy.html` 已经在里面）；
2. GitHub → 仓库 → **Settings** → 左侧 **Pages**；
3. **Source** 选 **Deploy from a branch** → Branch 选 `main`、目录选 **`/docs`** → **Save**；
4. 等 1 分钟左右，页面地址是：

```
https://<你的用户名>.github.io/Instamony/privacy.html
```

例如用户名是 `ShiYi070415`，就是
`https://shiyi070415.github.io/Instamony/privacy.html`。

> 注意：私有仓库要用 Pages 需要 GitHub Pro；如果是私有仓库且不想公开源码，
> 可以把 `privacy.html` 单独放到一个公开仓库（或 Gitee Pages / Cloudflare Pages）里。

## 填进 AGC

`App information` → **Privacy policy URL** 粘贴上面那个地址。
同一页还有 **App introduction / Full introduction**（文案在 `docs/store-listing.md`）与截图。

## 上传前要改两处

`docs/privacy.html` 第 10 节留了占位，替换成你自己的：

```html
· 邮箱：<strong>请替换为你的邮箱</strong>
· 或在本项目仓库提交 Issue：<strong>请替换为你的仓库地址</strong>
```

（AGC 审核会点开这个链接看，留占位会被打回。）

## 内容口径（和代码保持一致，别改矛盾）

- 没有任何开发者服务器：登录态、缓存全在设备上；
- 无分析 / 广告 / 崩溃上报 SDK；
- 只申请 3 个权限：网络、网络状态、振动；
- 内嵌网页限定在服务方域名，站外链接交给系统浏览器；
- 删除方式：应用内退出登录，或卸载应用。

如果以后加了云功能（例如中转服务器），第 2、4、9 节要同步更新，否则就成了虚假声明。
