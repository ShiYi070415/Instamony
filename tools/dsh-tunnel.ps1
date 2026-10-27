# 起 cloudflared 快速隧道 → 拿到 trycloudflare 域名 → 用该域名作 --trusted-host 启 dsh web
# → 从 dsh 的输出里取本次进程的 token → 拼出手机可用的 https 链接。
#
# 为什么必须「先隧道后 dsh」：dsh 的 /api 有一道 browser-trust 围栏（--trusted-host），
# 域名是 cloudflared 每次现分配的，启动 dsh 之前不知道，所以顺序不能反。
#
# 为什么 token 要从 dsh 的输出里抓：token 是**每个进程随机生成**的（32 字节 base64url，
# dsh-client-connection 的 PROCESS_LAUNCH_TOKENS），没有配置文件可读；dsh 启动时会打一行
# `dsh web: http://127.0.0.1:3080/?token=…`，这是唯一来源。首次访问 /?token=… 之后
# dsh 会种一个绑定该域名的签名 Cookie，手机之后不用再带 token。
#
# 参数：-Port（默认 3080，也可用 .bat 的第一个参数）、-BindHost（默认 127.0.0.1；
# 想在局域网里直连就把 .bat 里的 BIND_HOST 改成 0.0.0.0）。

param(
  [int]$Port = 3080,
  [string]$BindHost = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot          # tools/ 的上一级
$logDir = Join-Path $repo '.tmp'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$tunLog = Join-Path $logDir 'cloudflared-tunnel.log'
$dshLog = Join-Path $logDir 'dsh-web.log'
$dshErr = Join-Path $logDir 'dsh-web.err.log'
$urlFile = Join-Path $logDir 'tunnel-url.txt'

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }

# Get-Content -Raw 在「日志刚被创建、还是空的」时返回 $null，直接喂给 [regex]::Match
# 会抛 "Value cannot be null. Parameter name: input"（第一版就是这么崩的）
function Get-LogText([string]$path) {
  if (-not (Test-Path $path)) { return '' }
  $t = Get-Content $path -Raw -ErrorAction SilentlyContinue
  if ($null -eq $t) { return '' }
  return [string]$t
}

# 剪贴板两条路：Set-Clipboard（PowerShell 自带），失败再退回 cmd 的 clip.exe。
# 安静失败是这里最讨厌的情况（粘出来还是上一条内容），所以调用方会读回来比对。
function Copy-Text([string]$text) {
  try { Set-Clipboard -Value $text -ErrorAction Stop; return $true } catch { }
  try {
    $text | & clip.exe
    if ($LASTEXITCODE -eq 0) { return $true }
  } catch { }
  return $false
}

# ---------- 1. 找 cloudflared ----------
$cfTarget = Join-Path $env:LOCALAPPDATA 'cloudflared\cloudflared.exe'
$cf = $null
foreach ($candidate in @(
    $cfTarget,
    (Join-Path $repo 'tools\cloudflared.exe'),
    (Join-Path $logDir 'cloudflared.exe')
  )) {
  if ($candidate -and (Test-Path $candidate)) { $cf = $candidate; break }
}
if (-not $cf) {
  $onPath = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
  if ($onPath) { $cf = $onPath.Source }
}
if (-not $cf) {
  Say "没找到 cloudflared.exe，正在下载到 $cfTarget …" 'Yellow'
  New-Item -ItemType Directory -Path (Split-Path -Parent $cfTarget) -Force | Out-Null
  & curl.exe -L --fail --silent --show-error -o $cfTarget 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
  if ($LASTEXITCODE -ne 0) { throw "cloudflared 下载失败（curl exit $LASTEXITCODE）" }
  $cf = $cfTarget
}
Say "cloudflared: $cf"

# ---------- 2. 端口占用检查（多半是已经在跑的 dsh） ----------
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) {
  $owners = ($busy | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
    $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
    if ($p) { "$($p.ProcessName)($($p.Id))" } else { "pid $_" }
  }) -join ', '
  throw "端口 $Port 已被占用：$owners。先关掉它（当前 GUI 会话就是这样起的），或换端口：start-dsh-tunnel.bat 3099"
}

# ---------- 3. 起隧道 ----------
Remove-Item $tunLog, $dshLog, $dshErr, $urlFile -ErrorAction SilentlyContinue
Say "起隧道：cloudflared tunnel --url http://127.0.0.1:$Port" 'Cyan'
$tunnel = Start-Process -FilePath $cf `
  -ArgumentList @('tunnel', '--url', "http://127.0.0.1:$Port", '--no-autoupdate', '--logfile', "$tunLog") `
  -WindowStyle Hidden -PassThru

$dsh = $null
try {
  $domain = $null
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($tunnel.HasExited) {
      $tail = if (Test-Path $tunLog) { (Get-Content $tunLog -Tail 15) -join "`n" } else { '(无日志)' }
      throw "cloudflared 退出了（exit $($tunnel.ExitCode)）：`n$tail"
    }
    if (Test-Path $tunLog) {
      $m = [regex]::Match((Get-LogText $tunLog), 'https://([a-z0-9][a-z0-9-]*\.trycloudflare\.com)')
      if ($m.Success) { $domain = $m.Groups[1].Value; break }
    }
  }
  if (-not $domain) { throw "等了 60 秒没拿到 trycloudflare 域名，看日志：$tunLog" }
  Say "域名: https://$domain" 'Green'

  # ---------- 4. 用该域名作 trust 起 dsh ----------
  $node = 'C:\Program Files\nodejs\node.exe'
  if (-not (Test-Path $node)) { $node = (Get-Command node.exe -ErrorAction Stop).Source }
  $binjs = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (-not (Test-Path $binjs)) { throw "找不到 dsh 本体：$binjs" }

  # dsh 的 --trusted-host 收的是 authority（host 或 host:port），**不要带协议头**
  $dshArgs = @(
    "`"$binjs`" web"
    "--port $Port"
    '--no-open'
    "--trusted-host 127.0.0.1:$Port"
    "--trusted-host $domain"
  )
  if ($BindHost -ne '127.0.0.1') { $dshArgs += "--host $BindHost" }

  Say "起 dsh：dsh web --port $Port --trusted-host $domain" 'Cyan'
  $dsh = Start-Process -FilePath $node -ArgumentList ($dshArgs -join ' ') `
    -RedirectStandardOutput $dshLog -RedirectStandardError $dshErr `
    -WindowStyle Hidden -PassThru

  $token = $null
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($dsh.HasExited) {
      $tail = @()
      if (Test-Path $dshErr) { $tail += Get-Content $dshErr -Tail 15 }
      if (Test-Path $dshLog) { $tail += Get-Content $dshLog -Tail 15 }
      throw "dsh 退出了（exit $($dsh.ExitCode)）：`n$($tail -join "`n")"
    }
    if (Test-Path $dshLog) {
      $m = [regex]::Match((Get-LogText $dshLog), 'token=([A-Za-z0-9_-]{16,})')
      if ($m.Success) { $token = $m.Groups[1].Value; break }
    }
  }
  if (-not $token) { throw "等了 90 秒没从 dsh 输出里抓到 token，看日志：$dshLog" }

  $localUrl = "http://127.0.0.1:$Port/?token=$token"
  $phoneUrl = "https://$domain/?token=$token"

  # ---------- 5. 端到端验证：隧道真的能回源到 dsh ----------
  # token 是进程级的、不是一次性的，所以这里先踩一次不会把它作废（dsh 会种 Cookie 给这个 authority）
  Say '验证隧道（最长 30 秒）…' 'Cyan'
  # 成功的形态是 2xx 或 3xx：/?token=… 这一发是「换 Cookie」的握手，实测回 **303**
  # （不是 200），所以只认 200/302/307 会把成功判成失败。502/503 才是回源没连上。
  $code = '000'
  $ok = $false
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 10 $phoneUrl).Trim()
    if ($code -match '^[23][0-9][0-9]$') { $ok = $true; break }
    Start-Sleep -Milliseconds 1500
  }

  Say ''
  Say '================ 手机打开下面这条链接 ================' 'White'
  Say $phoneUrl 'Green'
  Say '=====================================================' 'White'
  Say "本机打开（不用发手机）：$localUrl" 'DarkGray'
  Say ("隧道自检：HTTP {0} {1}" -f $code, $(if ($ok) { '（通）' } else { '（还没通：等 10~20 秒再点一次；502 一般是回源没起好）' })) $(if ($ok) { 'Green' } else { 'Yellow' })
  Set-Content -Path $urlFile -Value @($phoneUrl, $localUrl, "domain=$domain", "port=$Port") -Encoding UTF8

  # 剪贴板里必须是**隧道那条**，不是 127.0.0.1 那条（本机直接开就行的链接粘到手机上是打不开的）
  $copied = Copy-Text $phoneUrl
  if ($copied) {
    $readback = ''
    try { $readback = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }
    if ($readback -and $readback.Trim() -eq $phoneUrl) {
      Say '（已复制到剪贴板：隧道链接，直接粘贴到手机浏览器）' 'DarkGray'
    } else {
      Say '（已写入剪贴板，但读回来不一致 —— 粘之前先核一下域名是不是 trycloudflare.com）' 'Yellow'
    }
  } else {
    Say '（复制到剪贴板失败：手动选中上面那条复制）' 'Yellow'
  }

  Say ''
  Say '保持这个窗口开着：关掉窗口 = 隧道和 dsh 一起停。' 'Yellow'
  Say "日志：$tunLog / $dshLog" 'DarkGray'
  Say ''

  # ---------- 6. 守着两个进程 ----------
  while ($true) {
    Start-Sleep -Seconds 2
    if ($tunnel.HasExited) {
      Say "cloudflared 退出了（exit $($tunnel.ExitCode)），域名失效。日志：$tunLog" 'Red'
      break
    }
    if ($dsh.HasExited) {
      Say "dsh 退出了（exit $($dsh.ExitCode)）。日志：$dshLog" 'Red'
      break
    }
  }
} finally {
  foreach ($p in @($dsh, $tunnel)) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
}
