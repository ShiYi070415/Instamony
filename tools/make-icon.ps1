<#
.SYNOPSIS
  生成 Instarmony 的分层应用图标：黑底 + Instagram 渐变 + 高斯模糊的相机轮廓。

.DESCRIPTION
  标记是**镂空**的：圆角方机身只描边不填充、镜头是空心圆环，只有右上闪光点是实心。
  轮廓线本身套 Instagram 渐变色，并做**真正的高斯模糊**。

  真正的模糊是怎么做的：GDI+ 没有模糊 API，所以自己在像素上算 ——
    1) 先在小画布（320x320）上把轮廓画成白色遮罩，其余透明；
    2) 取出 alpha 通道，做 3 遍可分离的方框模糊（按中心极限定理，3 遍方框 ≈ 高斯）；
    3) 再按像素把渐变色写进去，alpha 用模糊后的值；
    4) 放大到目标尺寸。

  只模糊 alpha、颜色由渐变现算，是为了避开一个常见毛病：RGB 和 alpha 一起模糊的话，
  透明区域里的 RGB 是黑的，模糊会把边缘颜色往黑色拉，光晕就发脏。

  为什么不在最终尺寸上算模糊：320x320 只有 10 万像素，3 遍方框在 PowerShell 里几秒就够；
  1024x1024 是 100 万像素，同样的循环要慢十几倍。而模糊过的图放大回去本来也不会失真。

.EXAMPLE
  powershell -File tools/make-icon.ps1
  powershell -File tools/make-icon.ps1 -GlyphPalette app
  powershell -File tools/make-icon.ps1 -StrokeWidth 0.12 -BlurSigma 0.018
#>
param(
  [ValidateSet('instagram', 'app')]
  [string]$GlyphPalette = 'instagram',
  [string]$OutDir = 'design/icon/black-glass',
  [int]$Size = 1024,
  [int]$StartIconSize = 144,
  [int]$PreviewSize = 512,
  # 线宽，相对机身边长。
  [double]$StrokeWidth = 0.105,
  # 高斯模糊的 sigma，相对画布边长。0 或负数 = 不模糊（硬边）。
  [double]$BlurSigma = 0.013,
  # 形态：camera = 圆角方机身 + 中心镜头 + 闪光点；
  #       lens   = 只有一个中心圆 + 右上角一点。
  [ValidateSet('camera', 'lens')]
  [string]$Shape = 'camera'
)

Add-Type -AssemblyName System.Drawing

# 画遮罩时的超采样倍数：先放大再缩回去，边缘才干净。
$SS = 2
# 模糊与着色在小画布上做（见文件头说明）。
$MaskSize = 320

$palettes = @{
  instagram = @(
    @{ pos = 0.00; hex = '#FFDC80' },   # 左下：奶油黄
    @{ pos = 0.18; hex = '#F77737' },   # 橙
    @{ pos = 0.42; hex = '#E1306C' },   # 玫红
    @{ pos = 0.68; hex = '#C13584' },   # 紫红
    @{ pos = 0.86; hex = '#833AB4' },   # 紫
    @{ pos = 1.00; hex = '#405DE6' }    # 右上：蓝
  )
  app = @(
    @{ pos = 0.00; hex = '#00C6FB' },
    @{ pos = 0.55; hex = '#0095F6' },
    @{ pos = 1.00; hex = '#4F5BD5' }
  )
}

function ConvertTo-Color([string]$hex, [int]$alpha = 255) {
  $c = [System.Drawing.ColorTranslator]::FromHtml($hex)
  return [System.Drawing.Color]::FromArgb($alpha, $c.R, $c.G, $c.B)
}

# 在调色板上按 t（0..1）取色，分段线性。
function Get-PaletteColor($stops, [double]$t) {
  if ($t -lt 0) { $t = 0 }
  if ($t -gt 1) { $t = 1 }
  for ($i = 1; $i -lt $stops.Count; $i++) {
    $lo = $stops[$i - 1]
    $hi = $stops[$i]
    if ($t -gt $hi.pos) { continue }
    $span = $hi.pos - $lo.pos
    $k = if ($span -le 0) { 0.0 } else { ($t - $lo.pos) / $span }
    $ca = ConvertTo-Color $lo.hex
    $cb = ConvertTo-Color $hi.hex
    return @(
      [int]($ca.R + ($cb.R - $ca.R) * $k),
      [int]($ca.G + ($cb.G - $ca.G) * $k),
      [int]($ca.B + ($cb.B - $ca.B) * $k))
  }
  $last = ConvertTo-Color $stops[-1].hex
  return @($last.R, $last.G, $last.B)
}

# 外形几何。
#   camera：圆角方机身（路径）+ 中心镜头圆 + 右上闪光点
#   lens  ：没有机身，只有一个中心圆 + 右上角一点
# 两种形态共用同一套返回值，绘制侧按 $shape 决定画不画机身。
function New-CameraGeometry([single]$cx, [single]$cy, [single]$side, [single]$stroke, [string]$shape) {
  $radius = $side * 0.27
  $d = $radius * 2
  $x = $cx - $side / 2
  $y = $cy - $side / 2
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($x, $y, $d, $d, 180, 90)
  $path.AddArc($x + $side - $d, $y, $d, $d, 270, 90)
  $path.AddArc($x + $side - $d, $y + $side - $d, $d, $d, 0, 90)
  $path.AddArc($x, $y + $side - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  if ($shape -eq 'lens') {
    # 没有机身，中心圆就是主体，所以放大到直径 0.8*side
    $lensR = $side * 0.40
    # 右上角那一点：半径加大（"粗一点"），中心沿 45° 外移到 dotOff*√2 处。
    # 和中心圆的间隙 = dotOff*√2 - dotR - (lensR + stroke/2)
    #             = 0.45*1.414 - 0.09 - (0.40 + 0.0525) ≈ 0.094*side —— 明显分开。
    # （上一版是 0.075 半径 / 0.38 偏移，间隙只有 0.01*side，几乎贴着圆环。）
    $dotR = $side * 0.09
    $dotOff = $side * 0.45
  } else {
    $lensR = $side * 0.225
    $dotR = $side * 0.055
    $dotOff = $side * 0.30
  }
  $lens = New-Object System.Drawing.RectangleF ($cx - $lensR), ($cy - $lensR), ($lensR * 2), ($lensR * 2)
  $dot = New-Object System.Drawing.RectangleF ($cx + $dotOff - $dotR), ($cy - $dotOff - $dotR), ($dotR * 2), ($dotR * 2)
  return @{ path = $path; lens = $lens; dot = $dot; stroke = $stroke; shape = $shape; mainR = $lensR }
}

# 可分离方框模糊（一遍）。边缘用夹取，避免四周变暗。
function Invoke-BoxBlurAlpha($src, [int]$b, [int]$r) {
  $tmp = New-Object 'double[]' ($b * $b)
  $dst = New-Object 'double[]' ($b * $b)
  $w = 2 * $r + 1

  for ($y = 0; $y -lt $b; $y++) {
    $row = $y * $b
    $sum = 0.0
    for ($i = -$r; $i -le $r; $i++) {
      $x = [Math]::Min([Math]::Max($i, 0), $b - 1)
      $sum += $src[$row + $x]
    }
    for ($x = 0; $x -lt $b; $x++) {
      $tmp[$row + $x] = $sum / $w
      $sub = [Math]::Min([Math]::Max($x - $r, 0), $b - 1)
      $add = [Math]::Min([Math]::Max($x + $r + 1, 0), $b - 1)
      $sum += $src[$row + $add] - $src[$row + $sub]
    }
  }
  for ($x = 0; $x -lt $b; $x++) {
    $sum = 0.0
    for ($i = -$r; $i -le $r; $i++) {
      $y = [Math]::Min([Math]::Max($i, 0), $b - 1)
      $sum += $tmp[$y * $b + $x]
    }
    for ($y = 0; $y -lt $b; $y++) {
      $dst[$y * $b + $x] = $sum / $w
      $sub = [Math]::Min([Math]::Max($y - $r, 0), $b - 1)
      $add = [Math]::Min([Math]::Max($y + $r + 1, 0), $b - 1)
      $sum += $tmp[$add * $b + $x] - $tmp[$sub * $b + $x]
    }
  }
  return $dst
}

<#
  画出「渐变 +（可选）高斯模糊」的标记，返回一张 MaskSize 见方的位图（透明底）。
  $sigmaPx 是这张小画布上的 sigma（外层按比例换算好再传进来）；<= 0 表示不模糊。
#>
function New-BlurredMarkBitmap([int]$b, [single]$bodyRatio, [single]$strokeRatio, [single]$sigmaPx, $stops, [string]$shape) {
  $side = $b * $bodyRatio
  $stroke = $side * $strokeRatio

  # 1) 白色遮罩（超采样后再缩，边缘干净）
  $big = $b * $SS
  $mask = New-Object System.Drawing.Bitmap $big, $big, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $mg = [System.Drawing.Graphics]::FromImage($mask)
  $mg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $mg.Clear([System.Drawing.Color]::Transparent)
  $geo = New-CameraGeometry ($big / 2) ($big / 2) ($side * $SS) ($stroke * $SS) $shape
  $mainR = $geo.mainR
  $white = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $geo.stroke
  $white.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  if ($shape -ne 'lens') {
    $mg.DrawPath($white, $geo.path)                            # 机身：只描边 → 镂空
  }
  $mg.DrawEllipse($white, $geo.lens)                           # 中心圆：空心圆环
  $mg.FillEllipse([System.Drawing.Brushes]::White, $geo.dot)   # 右上角一点：实心
  $white.Dispose(); $geo.path.Dispose()
  $mg.Dispose()

  $work = New-Object System.Drawing.Bitmap $b, $b, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $wg = [System.Drawing.Graphics]::FromImage($work)
  $wg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $wg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $wg.DrawImage($mask, (New-Object System.Drawing.Rectangle 0, 0, $b, $b), 0, 0, $big, $big, [System.Drawing.GraphicsUnit]::Pixel)
  $wg.Dispose(); $mask.Dispose()

  # 2) 取 alpha
  $rect = New-Object System.Drawing.Rectangle 0, 0, $b, $b
  $data = $work.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $bytes = New-Object 'byte[]' ($stride * $b)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)

  $alpha = New-Object 'double[]' ($b * $b)
  for ($y = 0; $y -lt $b; $y++) {
    $row = $y * $b
    $off = $y * $stride
    for ($x = 0; $x -lt $b; $x++) {
      # 32bppArgb 在内存里是 BGRA，alpha 是第 4 个字节
      $alpha[$row + $x] = $bytes[$off + $x * 4 + 3] / 255.0
    }
  }

  # 3) 三遍方框 ≈ 高斯。sigma <= 0 就跳过 —— 那样得到的是硬边（不模糊）。
  if ($sigmaPx -gt 0) {
    $r = [int][Math]::Round($sigmaPx)
    if ($r -lt 1) { $r = 1 }
    for ($pass = 0; $pass -lt 3; $pass++) {
      $alpha = Invoke-BoxBlurAlpha $alpha $b $r
    }
  }

  # 4) 着色：颜色由渐变现算，alpha 用模糊后的值。
  #    渐变锚在**主体**（camera = 机身，lens = 中心圆）外扩 12% 的矩形上。
  #    只能锚主体、不能锚「含右上角的整体范围」：那样锚框被那一点撑大，主体就只剩中间
  #    一小段颜色，看不出渐变。
  #    $mainR 是在**超采样**画布上量的（几何是按 $SS 倍画的），而着色循环跑在 $b 画布上，
  #    所以要除回 $SS —— 忘了除，锚框会大一倍，主体只剩中间一段颜色（第一版就是这样）。
  $mainSpan = if ($shape -eq 'lens') { ($mainR * 2) / $SS } else { $side }
  $pad = $mainSpan * 0.12
  $gx0 = $b / 2 - $mainSpan / 2 - $pad
  $gw = $mainSpan + $pad * 2

  for ($y = 0; $y -lt $b; $y++) {
    $row = $y * $b
    $off = $y * $stride
    # t 沿对角线：左下 0 → 右上 1
    $ty = ($gx0 + $gw - $y) / $gw * 0.5
    for ($x = 0; $x -lt $b; $x++) {
      $a = $alpha[$row + $x]
      $i = $off + $x * 4
      if ($a -le 0.002) {
        $bytes[$i] = 0; $bytes[$i + 1] = 0; $bytes[$i + 2] = 0; $bytes[$i + 3] = 0
        continue
      }
      $tx = ($x - $gx0) / $gw * 0.5
      $rgb = Get-PaletteColor $stops ($tx + $ty)
      $v = [int][Math]::Round($a * 255)
      if ($v -gt 255) { $v = 255 }
      $bytes[$i] = $rgb[2]      # B
      $bytes[$i + 1] = $rgb[1]  # G
      $bytes[$i + 2] = $rgb[0]  # R
      $bytes[$i + 3] = $v       # A
    }
  }
  [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $bytes.Length)
  $work.UnlockBits($data)
  return $work
}

function New-Canvas([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  return @{ bmp = $bmp; g = $g }
}

function Save-Scaled($src, [int]$target, [string]$path) {
  if ($target -eq $src.Width) { $src.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); return }
  $dst = New-Object System.Drawing.Bitmap $target, $target, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $dg = [System.Drawing.Graphics]::FromImage($dst)
  $dg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $dg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $attr = New-Object System.Drawing.Imaging.ImageAttributes
  # TileFlipXY：避免缩放时把画布外的透明像素混进来、在边上留一圈灰边。
  $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
  $rect = New-Object System.Drawing.Rectangle 0, 0, $target, $target
  $dg.DrawImage($src, $rect, 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
  $dst.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $attr.Dispose(); $dg.Dispose(); $dst.Dispose()
}

# --- 开始画 ---------------------------------------------------------------

$stops = $palettes[$GlyphPalette]
$bodyRatio = 0.56   # 机身占画布比例：留在中央安全区，系统裁切/缩放时不会被切到

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 前景：在小画布上算好（可选模糊），再放大到目标尺寸
$sigmaSmall = [single]($BlurSigma * $MaskSize)
$mark = New-BlurredMarkBitmap $MaskSize $bodyRatio ([single]$StrokeWidth) $sigmaSmall $stops $Shape
Save-Scaled $mark $Size (Join-Path $OutDir 'foreground.png')

# 背景：纯黑
$plate = New-Canvas $Size
$plate.g.Clear([System.Drawing.Color]::Black)
$plate.g.Dispose()
$plate.bmp.Save((Join-Path $OutDir 'background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$plate.bmp.Dispose()

# 合成图（启动图标 + 预览）
foreach ($pair in @(@{ size = $StartIconSize; name = 'startIcon.png' },
                    @{ size = $PreviewSize; name = 'preview.png' })) {
  $c = New-Canvas $pair.size
  $c.g.Clear([System.Drawing.Color]::Black)
  $c.g.DrawImage($mark, (New-Object System.Drawing.Rectangle 0, 0, $pair.size, $pair.size),
    0, 0, $mark.Width, $mark.Height, [System.Drawing.GraphicsUnit]::Pixel)
  $c.g.Dispose()
  $c.bmp.Save((Join-Path $OutDir $pair.name), [System.Drawing.Imaging.ImageFormat]::Png)
  $c.bmp.Dispose()
}
$mark.Dispose()

"glyph = $GlyphPalette   stroke = $StrokeWidth   sigma = $BlurSigma   out = $OutDir"
Get-ChildItem $OutDir -Filter *.png | Sort-Object Name |
  ForEach-Object { "{0,-16} {1,8} bytes" -f $_.Name, $_.Length }
