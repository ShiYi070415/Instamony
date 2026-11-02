# Build a debug-cert App Pack (bundle com.yijin.instamony).
#
# When a device is connected: build + install the HAP.
# When no device is connected: build + upload the .app to catbox + push the
# download link through MeoW to user "yijin".
#
# Usage:
#   & .\tools\build-debug-app.ps1
#   & .\tools\build-debug-app.ps1 -SkipBuild
#
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

param(
  [string]$Hvigor = 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat',
  [string]$SdkHome = 'C:\Program Files\Huawei\DevEco Studio\sdk',
  [string]$HvigorHome = "$PSScriptRoot\..\.hvigor-home",
  [string]$Bundle = 'com.yijin.instamony',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$env:DEVECO_SDK_HOME = $SdkHome
$env:HVIGOR_USER_HOME = (New-Item -ItemType Directory -Force -Path $HvigorHome).FullName
$env:npm_config_cache = (New-Item -ItemType Directory -Force -Path "$projectRoot\.hvigor-home\npm-cache").FullName
$env:npm_config_store_dir = (New-Item -ItemType Directory -Force -Path "$projectRoot\.hvigor-home\pnpm-store").FullName
# The correct bundle id is com.yijin.instamony; keep the parameter default
# above overridable but never let a typo leak into the artifact.
$env:INSTAMONY_BUNDLE_NAME = 'com.yijin.instamony'
$Bundle = 'com.yijin.instamony'

if (-not $SkipBuild) {
  Push-Location $projectRoot
  try {
    # Native tools write warnings to stderr; with ErrorActionPreference=Stop
    # PowerShell would turn a harmless warning into a terminating error.
    $ErrorActionPreference = 'Continue'
    & $Hvigor clean --no-daemon *> $null
    & $Hvigor assembleApp --mode project -p product=default -p buildMode=debug --no-daemon
    $buildCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($buildCode -ne 0) { throw "hvigor build failed (exit $buildCode)" }
  } finally {
    Pop-Location
  }
}

$app = Join-Path $projectRoot 'build\outputs\default\Instamony-default-signed.app'
$hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not (Test-Path $app)) { throw "no .app artifact: $app" }
if (-not (Test-Path $hap)) { throw "no .hap artifact: $hap" }

$appJson = [IO.File]::ReadAllText((Join-Path $projectRoot 'AppScope\app.json5'), [Text.Encoding]::UTF8)
$version = ([regex]::Match($appJson, '"versionName"\s*:\s*"([^"]+)"')).Groups[1].Value
$appSize = (Get-Item $app).Length
Write-Host "app      : $app ($([math]::Round($appSize / 1KB, 0)) KB)" -ForegroundColor Green
Write-Host "bundle   : $Bundle" -ForegroundColor Green
Write-Host "version  : $version" -ForegroundColor Green

$targets = (& hdc list targets 2>&1) -join "`n"
if ($targets -notmatch 'Empty' -and $targets.Trim().Length -gt 0) {
  Write-Host "device connected, installing HAP..." -ForegroundColor Cyan
  & hdc install -r $hap
  if ($LASTEXITCODE -ne 0) { throw "hdc install failed" }
  Write-Host "installed on device" -ForegroundColor Green
  exit 0
}

Write-Host "no device connected, uploading .app..." -ForegroundColor Yellow
$upload = (& curl.exe -sS -F 'reqtype=fileupload' -F "fileToUpload=@$app" 'https://catbox.moe/user/api.php') -join ''
if ($LASTEXITCODE -ne 0 -or $upload -notmatch '^https?://') {
  Write-Host "catbox unavailable, falling back to litterbox (72h)..." -ForegroundColor Yellow
  $upload = (& curl.exe -sS -F 'reqtype=fileupload' -F 'time=72h' -F "fileToUpload=@$app" 'https://litterbox.catbox.moe/resources/internals/api.php') -join ''
}
if ($LASTEXITCODE -ne 0 -or $upload -notmatch '^https?://') {
  throw "upload failed: $upload"
}
Write-Host "download : $upload" -ForegroundColor Green

$msg = "Instamony debug build`nversion: $version`nbundle: $Bundle`nsize: $([math]::Round($appSize / 1KB, 0)) KB`ndownload: $upload`n`n(.app; debug cert; rename to .app after download if needed)"
$body = @{
  title = "Instamony $version debug"
  msg = $msg
  msgType = 'text'
}
$resp = Invoke-RestMethod -Uri 'https://api.chuckfang.com/yijin' -Method Post -Body $body -TimeoutSec 60
$resp | ConvertTo-Json -Compress
Write-Host "MeoW push sent to yijin" -ForegroundColor Green
