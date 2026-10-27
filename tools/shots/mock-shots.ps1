// 生成 AGC 商店截图用的**示意界面**（1080x1920，9:16，PNG）
// 为什么是画出来的而不是真机截图：真机截图里必然带着别人的用户名、头像、私信正文和媒体，
// 那是隐私与版权问题；这个脚本用假数据把同一套界面重画一遍，画面前后一致、可以放心上传。
// 运行：powershell -ExecutionPolicy Bypass -File tools/shots/mock-shots.ps1
Add-Type -AssemblyName System.Drawing

$W = 1080
$H = 1920
$outDir = Join-Path $PSScriptRoot '..\..\docs\shots'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outDir = (Resolve-Path $outDir).Path

# 配色跟应用里一致：纯黑底、卡片 #1C1C1E、次要字 #8E8E93
$bg = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
$card = [System.Drawing.Color]::FromArgb(255, 28, 28, 30)
$card2 = [System.Drawing.Color]::FromArgb(255, 44, 44, 46)
$white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
$grey = [System.Drawing.Color]::FromArgb(255, 142, 142, 147)
$dim = [System.Drawing.Color]::FromArgb(255, 99, 99, 102)
$accent = [System.Drawing.Color]::FromArgb(255, 237, 73, 86)
$line = [System.Drawing.Color]::FromArgb(255, 38, 38, 40)

$fName = New-Object System.Drawing.Font('Microsoft YaHei UI', 30, [System.Drawing.FontStyle]::Regular)
$fNameB = New-Object System.Drawing.Font('Microsoft YaHei UI', 34, [System.Drawing.FontStyle]::Bold)
$fSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 24, [System.Drawing.FontStyle]::Regular)
$fTiny = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Regular)
$fBody = New-Object System.Drawing.Font('Microsoft YaHei UI', 28, [System.Drawing.FontStyle]::Regular)
$fHuge = New-Object System.Drawing.Font('Microsoft YaHei UI', 64, [System.Drawing.FontStyle]::Bold)
$fIcon = New-Object System.Drawing.Font('Segoe UI Symbol', 40, [System.Drawing.FontStyle]::Regular)

function New-Canvas {
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $g.Clear($bg)
  return @($bmp, $g)
}

function Fill-Round($g, $color, $x, $y, $w, $h, $r) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $path.AddArc($x, $y, $d, $d, 180, 90)
  $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $brush = New-Object System.Drawing.SolidBrush($color)
  $g.FillPath($brush, $path)
  $brush.Dispose()
  $path.Dispose()
}

# 用一块渐变当"照片"，避免出现任何真实媒体
function Fill-Art($g, $x, $y, $w, $h, $seed) {
  $sets = @(
    @(@(255, 88, 64, 156), @(255, 255, 122, 89)),
    @(@(255, 30, 90, 140), @(255, 96, 200, 190)),
    @(@(255, 240, 160, 70), @(255, 200, 60, 120)),
    @(@(255, 60, 60, 90), @(255, 150, 110, 220)),
    @(@(255, 40, 130, 90), @(255, 180, 220, 120)),
    @(@(255, 120, 60, 30), @(255, 240, 200, 120))
  )
  $pair = $sets[$seed % $sets.Count]
  $c1 = [System.Drawing.Color]::FromArgb($pair[0][0], $pair[0][1], $pair[0][2], $pair[0][3])
  $c2 = [System.Drawing.Color]::FromArgb($pair[1][0], $pair[1][1], $pair[1][2], $pair[1][3])
  $rect = New-Object System.Drawing.RectangleF($x, $y, $w, $h)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
  $g.FillRectangle($brush, $rect)
  $brush.Dispose()
  # 一条细高光，让平面渐变看着不那么"塑料"
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 255, 255, 255), 3)
  $g.DrawEllipse($pen, $x + $w * 0.55, $y + $h * 0.2, $w * 0.5, $w * 0.5)
  $pen.Dispose()
}

function Fill-Line($g, $x, $y, $w, $color) {
  $brush = New-Object System.Drawing.SolidBrush($color)
  $g.FillRectangle($brush, $x, $y, $w, 2)
  $brush.Dispose()
}

function Draw-Text($g, $text, $font, $color, $x, $y) {
  $brush = New-Object System.Drawing.SolidBrush($color)
  $g.DrawString($text, $font, $brush, [single]$x, [single]$y)
  $brush.Dispose()
}

function Draw-Avatar($g, $x, $y, $size, $seed) {
  $sets = @(
    @(@(255, 120, 90, 200), @(255, 60, 40, 120)),
    @(@(255, 70, 160, 200), @(255, 30, 80, 140)),
    @(@(255, 230, 150, 80), @(255, 180, 70, 60)),
    @(@(255, 120, 200, 140), @(255, 40, 120, 90))
  )
  $pair = $sets[$seed % $sets.Count]
  $c1 = [System.Drawing.Color]::FromArgb($pair[0][0], $pair[0][1], $pair[0][2], $pair[0][3])
  $c2 = [System.Drawing.Color]::FromArgb($pair[1][0], $pair[1][1], $pair[1][2], $pair[1][3])
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.RectangleF($x, $y, $size, $size)), $c1, $c2, 45.0)
  $g.FillEllipse($brush, $x, $y, $size, $size)
  $brush.Dispose()
}

function Draw-StatusBar($g) {
  Draw-Text $g '9:41' $fSmall $white 60 40
  Draw-Text $g '5G' $fSmall $white 900 40
  $brush = New-Object System.Drawing.SolidBrush($white)
  $g.FillRectangle($brush, 952, 46, 58, 24)
  $brush.Dispose()
  $brush = New-Object System.Drawing.SolidBrush($bg)
  $g.FillRectangle($brush, 956, 50, 46, 16)
  $brush.Dispose()
}

function Draw-TabBar($g, $active) {
  Fill-Line $g 0 1790 $W $line
  $labels = @('首页', '探索', 'Reels', '私信', '我的')
  $glyphs = @([char]0x2302, [char]0x2315, [char]0x25B6, [char]0x2709, [char]0x263A)
  $step = 1080 / 5
  for ($i = 0; $i -lt 5; $i++) {
    $cx = $step * $i + $step / 2
    $color = if ($i -eq $active) { $white } else { $dim }
    Draw-Text $g ([string]$glyphs[$i]) $fIcon $color ($cx - 20) 1806
    Draw-Text $g $labels[$i] $fTiny $color ($cx - 30) 1862
  }
}

function Draw-Actions($g, $x, $y) {
  Draw-Text $g '♡' $fIcon $white $x $y
  Draw-Text $g '◌' $fIcon $white ($x + 90) $y
  Draw-Text $g '➤' $fIcon $white ($x + 180) $y
  Draw-Text $g '⛉' $fIcon $white ($x + 900) $y
}

# ---------------------------------------------------------------- 01 首页
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Draw-StatusBar $g
Draw-Text $g 'Instamony' $fNameB $white 60 110
# 快拍托盘
for ($i = 0; $i -lt 5; $i++) {
  $cx = 90 + $i * 200
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 190, 60, 160), 5)
  $g.DrawEllipse($pen, $cx - 62, 196, 124, 124)
  $pen.Dispose()
  Draw-Avatar $g ($cx - 52) 206 104 $i
  Draw-Text $g ('用户' + ($i + 1)) $fTiny $grey ($cx - 34) 334
}
Fill-Line $g 0 400 $W $line
# 帖子头
Draw-Avatar $g 60 440 96 1
Draw-Text $g 'alice.w' $fNameB $white 180 452
Draw-Text $g '3 小时前 · 原声' $fTiny $grey 180 500
# 封面（居中，2/3 宽卡片）
Fill-Art $g 60 570 960 900 0
# 动作栏
Draw-Actions $g 60 1500
Draw-Text $g '1,284 次赞' $fSmall $white 60 1590
Draw-Text $g 'alice.w  今天的光线很好，随手拍了一张。' $fBody $white 60 1640
Draw-Text $g '查看全部 32 条评论' $fSmall $grey 60 1690
Draw-TabBar $g 0
$bmp.Save((Join-Path $outDir '01-feed.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()

# ---------------------------------------------------------------- 02 Reels
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Fill-Art $g 0 0 $W $H 1
# 顶部渐隐
$rect = New-Object System.Drawing.RectangleF(0, 0, $W, 400)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
  [System.Drawing.Color]::FromArgb(170, 0, 0, 0), [System.Drawing.Color]::FromArgb(0, 0, 0, 0), 90.0)
$g.FillRectangle($brush, $rect); $brush.Dispose()
Draw-StatusBar $g
Draw-Text $g 'Reels' $fNameB $white 60 150
Draw-Avatar $g 60 1460 84 2
Draw-Text $g 'bob_dev' $fNameB $white 160 1470
Draw-Text $g '光感材质叠加在封面上，左上角悬浮作者栏。' $fBody $white 160 1520
Draw-Text $g '原声 · bob_dev' $fSmall ([System.Drawing.Color]::FromArgb(230, 255, 255, 255)) 60 1600
# 右侧动作列：图标固定间距，数字贴在各自图标下面（不要压到下一条）
$icons = @([char]0x2661, [char]0x25CC, [char]0x27A4, [char]0x26C9)
$ys = @(1330, 1450, 1570, 1690)
for ($i = 0; $i -lt 4; $i++) {
  Draw-Text $g ([string]$icons[$i]) $fIcon $white 928 $ys[$i]
}
Draw-Text $g '3,902' $fTiny $white 916 1386
Draw-Text $g '128' $fTiny $white 922 1506
# 进度条
Fill-Round $g ([System.Drawing.Color]::FromArgb(90, 255, 255, 255)) 60 1780 960 6 3
Fill-Round $g $white 60 1780 360 6 3
$bmp.Save((Join-Path $outDir '02-reels.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()

# ---------------------------------------------------------------- 03 私信列表
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Draw-StatusBar $g
Draw-Text $g '私信' $fNameB $white 60 110
Fill-Round $g $card2 60 200 960 88 44
Draw-Text $g '搜索' $fSmall $grey 470 232
Fill-Line $g 0 320 $W $line
$names = @('camille', 'dong_dev', 'elena.k', 'frank', 'grace', 'hana')
$previews = @('发来一条分享', '在吗？看到那个 Reels 了吗', '语音消息 · 0:12', '好的，明天见', '分享了 1 张图片', '赞了你的消息')
for ($i = 0; $i -lt 6; $i++) {
  $y = 360 + $i * 150
  Draw-Avatar $g 60 $y 108 $i
  $dot = if ($i -lt 3) { $white } else { $grey }
  Draw-Text $g $names[$i] $fNameB $dot 200 ($y + 6)
  Draw-Text $g $previews[$i] $fSmall $grey 200 ($y + 60)
  Draw-Text $g ('0' + (9 - $i) + ':' + (10 + $i * 4)) $fTiny $dim 880 ($y + 10)
  if ($i -lt 2) {
    $brush = New-Object System.Drawing.SolidBrush($accent)
    $g.FillEllipse($brush, 940, $y + 56, 18, 18)
    $brush.Dispose()
  }
  Fill-Line $g 200 ($y + 132) 820 $line
}
Draw-TabBar $g 3
$bmp.Save((Join-Path $outDir '03-inbox.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()

# ---------------------------------------------------------------- 04 会话页（含分享卡片）
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Draw-StatusBar $g
Draw-Avatar $g 40 100 72 3
Draw-Text $g 'camille' $fNameB $white 130 108
Draw-Text $g 'camille_w' $fTiny $grey 130 150
Fill-Line $g 0 200 $W $line
# 对方气泡
Fill-Round $g $card 200 230 700 96 26
Draw-Text $g '看到这个了吗？' $fBody $white 236 260
# 分享的帖子卡片（2/3 宽：作者行 → 封面 → 正文，整卡圆角）
Fill-Round $g $card2 200 350 640 850 34
Draw-Avatar $g 232 378 56 2
Draw-Text $g 'bob_dev' $fSmall $white 304 388
Fill-Art $g 200 450 640 590 2
Draw-Text $g 'bob_dev  这张构图不错。' $fSmall $white 232 1070
Draw-Text $g '正文最多两行，多出来的用省略号。' $fSmall $white 232 1112
# 视频卡片（帖子卡片的 2/3 宽：圆角封面 + 左上作者栏 + 居中播放三角）
Fill-Round $g $card2 200 1240 320 520 34
Fill-Art $g 200 1240 320 520 3
Fill-Round $g ([System.Drawing.Color]::FromArgb(120, 0, 0, 0)) 214 1254 180 54 27
Draw-Avatar $g 224 1263 36 4
Draw-Text $g 'elena.k' $fTiny $white 268 1272
Draw-Text $g ([string][char]0x25B6) $fIcon $white 330 1440
# 我的气泡（在视频卡片右侧，避免压住卡片）
Fill-Round $g $card2 570 1400 450 96 26
Draw-Text $g '刚看了，很好' $fBody $white 606 1430
# 输入条
Fill-Round $g $card2 60 1760 780 88 44
Draw-Text $g '发消息...' $fSmall $grey 100 1792
Draw-Text $g '发送' $fSmall $white 900 1792
$bmp.Save((Join-Path $outDir '04-thread.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()

# ---------------------------------------------------------------- 05 探索
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Draw-StatusBar $g
Draw-Text $g '探索' $fNameB $white 60 110
Fill-Round $g $card2 60 200 960 88 44
Draw-Text $g '搜索' $fSmall $grey 470 232
$colX = @(60, 400, 740)
$colH = @(0, 0, 0)
for ($i = 0; $i -lt 12; $i++) {
  $col = $i % 3
  $tileH = 360 + (($i * 97) % 320)
  $y = 340 + $colH[$col]
  Fill-Art $g $colX[$col] $y 280 $tileH ($i % 6)
  $colH[$col] += $tileH + 24
}
Draw-TabBar $g 1
$bmp.Save((Join-Path $outDir '05-explore.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()

# ---------------------------------------------------------------- 06 个人主页
$c = New-Canvas; $bmp = $c[0]; $g = $c[1]
Draw-StatusBar $g
Draw-Avatar $g 60 120 220 0
Draw-Text $g 'alice.w' $fNameB $white 320 150
Draw-Text $g '一些日常。' $fSmall $grey 320 210
$stats = @('128 帖子', '3,204 关注者', '180 正在关注')
for ($i = 0; $i -lt 3; $i++) {
  Draw-Text $g $stats[$i] $fSmall $white (320 + $i * 240) 270
}
Fill-Round $g $card2 60 400 460 80 40
Draw-Text $g '编辑主页' $fSmall $white 220 426
Fill-Round $g $card2 560 400 460 80 40
Draw-Text $g '分享主页' $fSmall $white 720 426
Fill-Line $g 0 520 $W $line
$colX = @(0, 360, 720)
$colH = @(0, 0, 0)
for ($i = 0; $i -lt 9; $i++) {
  $col = $i % 3
  $y = 540 + $colH[$col]
  Fill-Art $g $colX[$col] $y 356 356 ($i % 6)
  $colH[$col] += 360
}
Draw-TabBar $g 4
$bmp.Save((Join-Path $outDir '06-profile.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()

Get-ChildItem $outDir -Filter *.png | Select-Object Name, Length
