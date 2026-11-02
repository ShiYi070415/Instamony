# Instamony 多语言审计

> 生成时间：2026-10-31T03:45:04.454Z
> 扫描范围：`entry/src/main/ets/**/*.ets`，注释已排除；日志/诊断与 UI 文案分开统计。

## 总览

- 资源键：base **311** 个，en_US **311** 个
- en_US 缺少的键：**0** 个
- en_US 仍是中文的键：**0** 个
- en_US 多出、base 没有的键：**0** 个
- `$r('app.string.*')` 引用但未定义的键：**0** 个
- 仍含中文的字符串字面量：**573** 个（UI 线索 **2** / 日志诊断 **79** / 其他 **492**）

> “UI 线索”是按所在行是否出现 `Text(` / `Button(` / `placeholder` / `title` 等关键字判断的，仍需人工复核；日志/诊断类通常不需要翻译。

## 语言资源

| 目录 | 键数 | 相对 base 缺键 |
|---|---:|---:|
| `zh_CN` | 311 | 0 |
| `zh_TW` | 311 | 0 |
| `en_US` | 311 | 0 |
| `ja_JP` | 311 | 0 |
| `ko_KR` | 311 | 0 |
| `es_ES` | 311 | 0 |
| `de_DE` | 311 | 0 |
| `it_IT` | 311 | 0 |
| `vi_VN` | 311 | 0 |

## 优先处理：UI 中文最多的文件

| 文件 | UI 中文串 | 其他中文串 | 日志/诊断 | 已用 `$r` 次数 |
|---|---:|---:|---:|---:|
| `entry/src/main/ets/core/net/Tls13Client.ets` | 1 | 27 | 24 | 0 |
| `entry/src/main/ets/core/StoryDiag.ets` | 1 | 20 | 6 | 0 |
| `entry/src/main/ets/core/mobileapi/CaaLogin.ets` | 0 | 60 | 0 | 0 |
| `entry/src/main/ets/bridge/WebScripts.ets` | 0 | 39 | 0 | 0 |
| `entry/src/main/ets/components/SettingsPanel.ets` | 0 | 38 | 2 | 96 |
| `entry/src/main/ets/core/LoginLog.ets` | 0 | 38 | 6 | 0 |
| `entry/src/main/ets/core/mobileapi/CaaSession.ets` | 0 | 31 | 0 | 2 |
| `entry/src/main/ets/core/ShareProbe.ets` | 0 | 30 | 0 | 0 |
| `entry/src/main/ets/core/mobileapi/WebLoginProbe.ets` | 0 | 23 | 0 | 0 |
| `entry/src/main/ets/viewmodel/SearchViewModel.ets` | 0 | 18 | 0 | 0 |
| `entry/src/main/ets/core/mobileapi/MobileProbe.ets` | 0 | 12 | 25 | 0 |
| `entry/src/main/ets/viewmodel/ProfileViewModel.ets` | 0 | 12 | 1 | 0 |
| `entry/src/main/ets/viewmodel/ReelsViewModel.ets` | 0 | 12 | 0 | 0 |
| `entry/src/main/ets/components/DirectPage.ets` | 0 | 11 | 0 | 3 |
| `entry/src/main/ets/core/MeoW.ets` | 0 | 11 | 0 | 0 |
| `entry/src/main/ets/core/ProxyProbe.ets` | 0 | 11 | 0 | 0 |
| `entry/src/main/ets/core/PushTokenReporter.ets` | 0 | 10 | 0 | 0 |
| `entry/src/main/ets/probe/InstagramProbe.ets` | 0 | 10 | 0 | 0 |
| `entry/src/main/ets/viewmodel/DirectViewModel.ets` | 0 | 10 | 1 | 0 |
| `entry/src/main/ets/components/LoginPage.ets` | 0 | 9 | 0 | 17 |
| `entry/src/main/ets/core/mobileapi/MobileCrypto.ets` | 0 | 9 | 0 | 0 |
| `entry/src/main/ets/viewmodel/DirectThreadViewModel.ets` | 0 | 7 | 0 | 0 |
| `entry/src/main/ets/core/net/DoHResolver.ets` | 0 | 6 | 0 | 0 |
| `entry/src/main/ets/pages/Index.ets` | 0 | 6 | 7 | 87 |
| `entry/src/main/ets/components/ReelsPage.ets` | 0 | 4 | 0 | 3 |
| `entry/src/main/ets/core/AppProxy.ets` | 0 | 4 | 0 | 0 |
| `entry/src/main/ets/core/NetQuality.ets` | 0 | 4 | 0 | 0 |
| `entry/src/main/ets/core/Translator.ets` | 0 | 4 | 0 | 0 |
| `entry/src/main/ets/components/ProfilePage.ets` | 0 | 3 | 0 | 13 |
| `entry/src/main/ets/core/NativeStories.ets` | 0 | 3 | 1 | 0 |

## 典型硬编码示例

### `entry/src/main/ets/core/net/Tls13Client.ets`
- L2096: `系统 HTTP 栈也失败：${Tls13Client.errorText(error)}`

### `entry/src/main/ets/core/StoryDiag.ets`
- L224: `2) 再看 detail= 与「逐发轨迹」：detail=empty 表示服务端答了 200+JSON 但没有媒体；`

## en_US 缺少的键

- 无

## en_US 仍是中文的键

- 无

## 未定义的 `$r('app.string.*')` 引用

- 无

## 当前状态 / 下一步

1. `en_US` 已补齐（0 缺键）；9 个语言目录均为 311 键；
2. UI 文案已基本迁完，只剩 2 条内部诊断串（Tls13Client / StoryDiag），它们不是界面文案；
3. 带变量文案已统一走 `%s` / `%d` 占位符（`$r(key, arg)` 或 resourceManager.getStringSync）；
4. 单复数规则尚未接入 `getIntPluralStringValueSync`，下一步优先处理“N 条消息 / N 分钟 / N 天”这类文案；
5. 9 个语言资源已按语义翻译；意大利语/越南语为本轮新增，仍建议母语者做最终校对。
