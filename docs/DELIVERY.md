# 交付约定（每次打包都按这个来）

> 这是给"下次的我"看的清单，别每次重新猜。

## 1. 包格式

- **直接给未压缩的 `.app`**（用户明确要求："下次记得上传未压缩的 .app 给我"）。
- 不要为了能上传而压成 `.app.zip`：GitHub Release 拒绝 `.app` 后缀（`name has a file extension
  that is not allowed`），那就**用能收 `.app` 的图床**，而不是改包结构。
- `.hap` 也一起给（侧载安装用）。

## 2. 图床顺序（按可用性）

1. `catbox`：`curl -F "reqtype=fileupload" -F "fileToUpload=@<file>" https://catbox.moe/user/api.php`
   —— 会间歇性 500/502，失败就换下一个；
2. `tmpfiles`：`curl -F "file=@<file>" https://tmpfiles.org/api/v1/upload`
   —— 直链要把 `/` 改成 `/dl/`，约 1 小时后失效，只当备用；
3. `litterbox`：同上家族，也会 500。
4. GitHub Release 资产：**长期可用**，但只收 `.zip`（`.app` 会被拒），所以它是"长期链接"而不是"未压缩交付"。

## 3. 随包一起给的东西

- **MeoW 推送链接**（`https://api.chuckfang.com/Yijin/Instamony/app-<字节>B?url=<urlencoded>`）；
- 说明本次改了什么（中文，按"新增功能 / UI / 修复 / 待办"或用户当次要求的结构）。

## 4. 已知不可用/受限

- **MeoW 推送 API 从这台机器恒返回 `429 IP限制，请联系开发者`**（换写法、换消息内容都一样）：
  只能给"可点的 MeoW 链接"，无法真正 push 出去。
- **真机不稳定**：`hdc list targets` 经常变空，装包前先确认；断连时如实说明"已打包、未安装"。
- **Push Kit 不可用**（侧载包拿不到 token，详见 `docs/release-notes-1.3.5.md` 的"已知问题"）。

## 5. 版本号

- 固定在 **1.4**（`versionName: "1.4"`，`versionCode: 1003011`）—— 用户要求"版本号卡在 1.4，不用动了"。
