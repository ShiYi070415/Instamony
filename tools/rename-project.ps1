# 把工程目录改名为 Instamony（见 AUDIT_TODO.md 的"改名"条目）
#
# 为什么需要脚本：hvigor 生成的 App Pack 文件名前缀取的是**工程根目录名**，
# 目录叫 Instarmony 时产物就是 Instarmony-default-signed.app。目录改名之后
# 产物自然变成 Instamony-default-signed.app，不需要任何构建配置改动。
#
# 用法（**必须先关掉 DevEco Studio 与本仓库相关的所有终端/会话**，否则目录被占用会报
# "Access to the path ... is denied"）：
#
#   powershell -File .\tools\rename-project.ps1
#   （这台机器只有 Windows PowerShell 5.1，没有 pwsh 7；脚本文件必须带 UTF-8 BOM，
#     否则 5.1 按 ANSI/GBK 解码，中文注释被拆坏、引号配对错乱 → ParserError，已实测）
#
# 可选参数：
#   -Root C:\HMStudy     父目录（默认 C:\HMStudy）
#   -Old  Instarmony     旧目录名（默认 Instarmony）
#   -New  Instamony      新目录名（默认 Instamony）

param(
  [string]$Root = 'C:\HMStudy',
  [string]$Old = 'Instarmony',
  [string]$New = 'Instamony'
)

$ErrorActionPreference = 'Stop'

$oldPath = Join-Path $Root $Old
$newPath = Join-Path $Root $New

if (-not (Test-Path $oldPath)) {
  if (Test-Path $newPath) {
    Write-Host "已经是 $New 了：$newPath" -ForegroundColor Green
    exit 0
  }
  throw "找不到旧目录：$oldPath"
}

if (Test-Path $newPath) {
  throw "目标目录已存在，先确认里面是什么：$newPath"
}

# 占位检查：目录里有没有人正在用（DevEco / hvigor / 终端）
try {
  $probe = Join-Path $oldPath '.rename-probe'
  Set-Content -Path $probe -Value 'x' -Encoding ASCII
  Remove-Item $probe -Force
} catch {
  throw "目录被占用（先关 DevEco Studio、终端、以及正在跑的 hvigor）：$($_.Exception.Message)"
}

Rename-Item -Path $oldPath -NewName $New
Write-Host "已改名：$oldPath → $newPath" -ForegroundColor Green

Write-Host ''
Write-Host '接下来手动做这几件事：' -ForegroundColor Yellow
Write-Host '  1. DevEco Studio 重新 Open 新路径（旧工程条目里的路径已失效）'
Write-Host '  2. 重新构建（hvigorw 不在 PATH 上，用下面这两条完整命令）：'
Write-Host '       $env:DEVECO_SDK_HOME=''C:\Program Files\Huawei\DevEco Studio\sdk'''
Write-Host '       & ''C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe'' ''C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js'' --mode module -p product=default assembleHap --no-daemon'
Write-Host '       & ''C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe'' ''C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js'' --mode project -p product=default assembleApp --no-daemon'
Write-Host '     产物应变成 Instamony-default-signed.app（hvigor 按目录名取前缀）'
Write-Host '  3. 签名证书仍是 %USERPROFILE%\.ohos\config\default_Instarmony_*.cer/.p7b/.p12'
Write-Host '     （build-profile.json5 里引用的是这些**文件名**，改名目录不影响它们；'
Write-Host '      想让证书也改名的话，改完文件后同步改 build-profile.json5 的三处路径）'
