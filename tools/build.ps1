# Instamony command-line build (for use without DevEco Studio)
#
# Why this script exists: hvigor writes its build cache to `~/.hvigor` by default.
# Under a restricted sandbox that path is not writable and the build dies with
#   EPERM: mkdir 'C:\Users\<user>\.hvigor\project_caches\...'
# hvigor's own launcher supports an official override: the environment variable
# `HVIGOR_USER_HOME` (see getHvigorUserHomeCacheDir in hvigorw.js). Point it at a
# directory inside the workspace and the build no longer needs outside access.
#
# DEVECO_SDK_HOME must be set explicitly as well: the CLI hvigor does not guess it.
#
# Usage:
#   & .\tools\build.ps1              # compile the debug HAP
#   & .\tools\build.ps1 -Install     # compile + install + launch + capture 8s of log
#
# NOTE: keep every string literal in this file ASCII-only. The harness shell is
# Windows PowerShell 5.1, which reads .ps1 as ANSI/GBK unless the file has a BOM;
# non-ASCII literals get mangled and break the parser.

param(
  # DevEco Studio's bundled hvigor (6.26.4). It understands modelVersion 6.1.0 from
  # hvigor/hvigor-config.json5. Do NOT use C:\command-line-tools' hvigor (6.0.6): it
  # only supports modelVersion 6.0.0 and fails immediately with a config error.
  [string]$Hvigor = 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat',
  [string]$SdkHome = 'C:\Program Files\Huawei\DevEco Studio\sdk',
  # Build cache location (inside the workspace, see the note above).
  [string]$HvigorHome = "$PSScriptRoot\..\.hvigor-home",
  [string]$Bundle = 'com.fanha.instarmony',
  [switch]$Install,
  [switch]$KeepCache,
  # Optional path to tee the build output into (useful when the caller cannot capture stderr).
  [string]$Log
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$env:DEVECO_SDK_HOME = $SdkHome
$env:HVIGOR_USER_HOME = (New-Item -ItemType Directory -Force -Path $HvigorHome).FullName
# npm/pnpm caches live under %LOCALAPPDATA%\npm-cache by default, i.e. also outside the
# workspace. hvigor's bootstrap runs `npm install pnpm`, so that cache must be redirected
# too, otherwise the same EPERM shows up one layer deeper.
$env:npm_config_cache = (New-Item -ItemType Directory -Force -Path "$projectRoot\.hvigor-home\npm-cache").FullName
$env:npm_config_store_dir = (New-Item -ItemType Directory -Force -Path "$projectRoot\.hvigor-home\pnpm-store").FullName

# A build that dies mid-bootstrap (e.g. the npm EPERM above) leaves a half-populated
# project_caches/<hash>/workspace behind, and every later run then fails with
#   ENOENT: ...\workspace\node_modules\@ohos\hvigor\bin\hvigor.js
# Wiping it is what hvigor's own hint recommends. Set -KeepCache to skip this.
if (-not $KeepCache) {
  Get-ChildItem "$env:HVIGOR_USER_HOME\project_caches" -Directory -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Path "$($_.FullName)\workspace\node_modules\@ohos\hvigor\bin\hvigor.js") } |
    ForEach-Object {
      Write-Host "clearing incomplete cache: $($_.Name)" -ForegroundColor Yellow
      Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
    }
}

# The hvigor launcher tries to install its engine (@ohos/hvigor) into
# <HVIGOR_USER_HOME>\project_caches\<hash>\workspace\node_modules. That bootstrap needs to
# touch npm state outside the workspace and silently leaves the workspace without the
# engine, which then fails as
#   ENOENT: ...\workspace\node_modules\@ohos\hvigor\bin\hvigor.js
# DevEco Studio ships the engine, so seed it from there instead. Version is read from the
# shipped package.json so this keeps working when DevEco is updated.
$engineSrc = Split-Path $Hvigor -Parent | Split-Path -Parent   # <deveco>\tools\hvigor
$engineRoot = "$engineSrc\hvigor"
$pluginRoot = "$engineSrc\hvigor-ohos-plugin"
function Repair-Engine([string]$workspace) {
  $target = "$workspace\node_modules\@ohos"
  if (Test-Path "$target\hvigor\bin\hvigor.js") { return }
  $version = ''
  $pkg = "$engineRoot\package.json"
  if (Test-Path $pkg) { $version = (Get-Content $pkg -Raw | ConvertFrom-Json).version }
  Write-Host "seeding hvigor engine $version into $target" -ForegroundColor Yellow
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  foreach ($name in @('hvigor', 'hvigor-ohos-plugin')) {
    $src = "$engineSrc\$name"
    $dst = "$target\$name"
    if (-not (Test-Path $src)) { continue }
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst -ErrorAction SilentlyContinue }
    Copy-Item -Recurse -Force $src $dst
  }
}
# Seed the engine into any cache workspace that already exists (the retry loop below
# covers the workspace hvigor creates on its very first run).
Get-ChildItem "$env:HVIGOR_USER_HOME\project_caches" -Directory -ErrorAction SilentlyContinue |
  ForEach-Object { Repair-Engine "$($_.FullName)\workspace" }

Write-Host "project   : $projectRoot" -ForegroundColor Cyan
Write-Host "hvigor    : $Hvigor" -ForegroundColor Cyan
Write-Host "cache home: $env:HVIGOR_USER_HOME" -ForegroundColor Cyan
Write-Host "sdk home  : $env:DEVECO_SDK_HOME" -ForegroundColor Cyan

Push-Location $projectRoot
try {
  # hvigor's launcher creates the cache workspace on its first run and only then looks for
  # its engine inside it; when the engine is missing it aborts with a hint to delete the
  # workspace. DevEco ships the engine, so after a failed attempt we seed it from there and
  # retry once. That turns an unreproducible bootstrap into a deterministic build.
  $code = 1
  foreach ($attempt in 1..2) {
    # Native commands write warnings (npm/hvigor do this constantly) to stderr. With
    # ErrorActionPreference = 'Stop', PowerShell 5.1 turns any stderr line from a native
    # command into a terminating NativeCommandError, which aborts the build on a mere
    # warning. So relax it for the invocation and judge the build by its exit code.
    $ErrorActionPreference = 'Continue'
    if ($Log) {
      & $Hvigor assembleHap --mode module -p product=default -p buildMode=debug --no-daemon *>&1 |
        Tee-Object -FilePath $Log -Append
    } else {
      & $Hvigor assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -eq 0) { break }
    $repaired = $false
    Get-ChildItem "$env:HVIGOR_USER_HOME\project_caches" -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        $ws = "$($_.FullName)\workspace"
        if ((Test-Path $ws) -and -not (Test-Path "$ws\node_modules\@ohos\hvigor\bin\hvigor.js")) {
          Repair-Engine $ws
          $repaired = $true
        }
      }
    if (-not $repaired -or $attempt -eq 2) { break }
    Write-Host "retrying with a seeded hvigor engine" -ForegroundColor Yellow
  }
  if ($code -ne 0) { throw "hvigor build failed (exit $code)" }
} finally {
  Pop-Location
}

$hap = Get-ChildItem "$projectRoot\entry\build\default\outputs\default" -Filter '*.hap' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -eq $hap) { throw 'no .hap artifact produced' }
$kb = [math]::Round($hap.Length / 1KB, 0)
Write-Host "hap       : $($hap.FullName) ($kb KB)" -ForegroundColor Green

if (-not $Install) { return }

# ---- install / launch / capture log ----
$hdc = (Get-Command hdc -ErrorAction SilentlyContinue).Source
if (-not $hdc) { $hdc = 'C:\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe' }
& $hdc install -r $hap.FullName
if ($LASTEXITCODE -ne 0) { throw 'hdc install failed' }
& $hdc shell hilog -r | Out-Null
& $hdc shell aa force-stop $Bundle | Out-Null
& $hdc shell aa start -a EntryAbility -b $Bundle | Out-Null
Start-Sleep -Seconds 8
& $hdc shell hilog -x | Select-String -Pattern 'MobileProbe|MobileSession|MobileRequest' |
  ForEach-Object { $_.Line }
