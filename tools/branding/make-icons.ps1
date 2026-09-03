# Generador de iconos de Remote Display (marca: gradiente azul->violeta + glifo
# de pantalla con el "pill" de la toolbar). Dibuja el master con System.Drawing
# y exporta todos los tamaños; empaqueta .ico (PNG-in-ICO) y .icns (PNG chunks).
# Uso:  powershell -File make-icons.ps1  [desde cualquier cwd]
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSCommandPath   # .../remotedisplay/branding
$out = Join-Path $root 'out'
New-Item -ItemType Directory -Force $out | Out-Null

# --- dibujo -----------------------------------------------------------------
function RoundRectPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# Dibuja el icono en un canvas 1024 lógico.
#   $mode: 'full'   = gradiente a sangre completa (iOS: el sistema redondea)
#          'rounded'= gradiente en rounded-rect con margen (Windows/Android legacy)
#          'macos'  = rounded-rect con margen grande (estilo Big Sur, ~10%)
#          'glyph'  = SOLO el glifo blanco sobre transparente (adaptive fg / notif)
#          'glyphgrad' = glifo relleno con el gradiente sobre transparente
function DrawMaster([string]$mode) {
  $S = 1024
  $bmp = New-Object System.Drawing.Bitmap($S, $S)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.PixelOffsetMode = 'HighQuality'

  $c1 = [System.Drawing.Color]::FromArgb(255, 0x3B, 0x82, 0xF6)  # azul
  $c2 = [System.Drawing.Color]::FromArgb(255, 0x8B, 0x5C, 0xF6)  # violeta
  $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.Point(0, 0)),
    (New-Object System.Drawing.Point($S, $S)), $c1, $c2)

  # Fondo
  if ($mode -eq 'full') {
    $g.FillRectangle($grad, 0, 0, $S, $S)
  } elseif ($mode -eq 'rounded') {
    $bg = RoundRectPath 44 44 936 936 210
    $g.FillPath($grad, $bg)
  } elseif ($mode -eq 'macos') {
    $bg = RoundRectPath 100 100 824 824 186
    $g.FillPath($grad, $bg)
  } elseif ($mode -eq 'circle') {
    $g.FillEllipse($grad, 22, 22, 980, 980)
  }

  # Glifo: pantalla redondeada (trazo) + pill sólido abajo-izquierda adentro.
  # En 'glyph'/'glyphgrad' va sobre transparente; si no, blanco sobre gradiente.
  $white = [System.Drawing.Brushes]::White
  $penBrush = if ($mode -eq 'glyphgrad') { $grad } else { [System.Drawing.Brushes]::White }
  $fillBrush = $penBrush

  # Escala del glifo segun el modo (mas chico cuando hay margen de fondo)
  $k = 1.0
  if ($mode -eq 'macos') { $k = 0.86 }
  if ($mode -eq 'glyph' -or $mode -eq 'glyphgrad') { $k = 1.22 }  # adaptive: safe zone 66/108
  function SX([float]$v) { return [float](512 + ($v - 512) * $script:k) }
  $script:k = $k

  $stroke = 60 * $k
  $pen = New-Object System.Drawing.Pen($penBrush, $stroke)
  $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'

  # pantalla: rounded rect centrado (x 240..784, y 268..660)
  $px = SX 240; $py = SX 268; $pw = (SX 784) - $px; $ph = (SX 660) - $py
  $screen = RoundRectPath $px $py $pw $ph (84 * $k)
  $g.DrawPath($pen, $screen)

  # pata + base del monitor
  $g.DrawLine($pen, (SX 512), (SX 660), (SX 512), (SX 742))
  $g.DrawLine($pen, (SX 396), (SX 756), (SX 628), (SX 756))

  # pill (la toolbar) abajo-izquierda dentro de la pantalla
  $bx = SX 306; $by = SX 520; $bw = (SX 500) - $bx; $bh = (SX 588) - $by
  $pill = RoundRectPath $bx $by $bw $bh ($bh / 2)
  $g.FillPath($fillBrush, $pill)

  $g.Dispose()
  return $bmp
}

function SavePng([System.Drawing.Bitmap]$master, [int]$size, [string]$path) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.SmoothingMode = 'AntiAlias'
  $g.PixelOffsetMode = 'HighQuality'
  $g.DrawImage($master, 0, 0, $size, $size)
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# --- empaquetadores ----------------------------------------------------------
function WriteIco([string[]]$pngPaths, [string]$outPath) {
  $entries = @()
  foreach ($p in $pngPaths) {
    $bytes = [IO.File]::ReadAllBytes($p)
    $img = [System.Drawing.Image]::FromFile($p)
    $entries += , @{ w = $img.Width; h = $img.Height; data = $bytes }
    $img.Dispose()
  }
  $fs = [IO.File]::Create($outPath)
  $bw = New-Object IO.BinaryWriter($fs)
  $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$entries.Count)
  $offset = 6 + 16 * $entries.Count
  foreach ($e in $entries) {
    $bw.Write([Byte]$(if ($e.w -ge 256) { 0 } else { $e.w }))
    $bw.Write([Byte]$(if ($e.h -ge 256) { 0 } else { $e.h }))
    $bw.Write([Byte]0); $bw.Write([Byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$e.data.Length); $bw.Write([UInt32]$offset)
    $offset += $e.data.Length
  }
  foreach ($e in $entries) { $bw.Write($e.data) }
  $bw.Close(); $fs.Close()
}

function WriteIcns([hashtable]$typeToPng, [string]$outPath) {
  # $typeToPng: p.ej. @{ 'ic07' = 'path128.png'; 'ic08' = ...256; 'ic09' = ...512; 'ic10' = ...1024 }
  $chunks = @()
  foreach ($t in $typeToPng.Keys) {
    $data = [IO.File]::ReadAllBytes($typeToPng[$t])
    $chunks += , @{ type = $t; data = $data }
  }
  $total = 8; foreach ($c in $chunks) { $total += 8 + $c.data.Length }
  $fs = [IO.File]::Create($outPath)
  $bw = New-Object IO.BinaryWriter($fs)
  $be = { param([UInt32]$v) $b = [BitConverter]::GetBytes($v); [Array]::Reverse($b); $bw.Write($b) }
  $bw.Write([Text.Encoding]::ASCII.GetBytes('icns')); & $be ([UInt32]$total)
  foreach ($c in $chunks) {
    $bw.Write([Text.Encoding]::ASCII.GetBytes($c.type))
    & $be ([UInt32](8 + $c.data.Length))
    $bw.Write($c.data)
  }
  $bw.Close(); $fs.Close()
}

# --- generar todo -------------------------------------------------------------
$mFull = DrawMaster 'full'
$mRound = DrawMaster 'rounded'
$mMac = DrawMaster 'macos'
$mGlyph = DrawMaster 'glyph'
$mCircle = DrawMaster 'circle'

$mFull.Save((Join-Path $out 'master-full-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$mRound.Save((Join-Path $out 'master-rounded-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$mMac.Save((Join-Path $out 'master-macos-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$mGlyph.Save((Join-Path $out 'master-glyph-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# Windows ICO
$icoSizes = 16, 24, 32, 48, 64, 128, 256
$icoPngs = @()
foreach ($s in $icoSizes) { $p = Join-Path $out "win-$s.png"; SavePng $mRound $s $p; $icoPngs += $p }
WriteIco $icoPngs (Join-Path $out 'app_icon.ico')

# iOS (nombres del appiconset existente)
$ios = @{ 'Icon-App-20x20@1x' = 20; 'Icon-App-20x20@2x' = 40; 'Icon-App-20x20@3x' = 60;
  'Icon-App-29x29@1x' = 29; 'Icon-App-29x29@2x' = 58; 'Icon-App-29x29@3x' = 87;
  'Icon-App-40x40@1x' = 40; 'Icon-App-40x40@2x' = 80; 'Icon-App-40x40@3x' = 120;
  'Icon-App-60x60@2x' = 120; 'Icon-App-60x60@3x' = 180;
  'Icon-App-76x76@1x' = 76; 'Icon-App-76x76@2x' = 152;
  'Icon-App-83.5x83.5@2x' = 167; 'Icon-App-1024x1024@1x' = 1024 }
$iosDir = Join-Path $out 'ios'; New-Item -ItemType Directory -Force $iosDir | Out-Null
foreach ($n in $ios.Keys) { SavePng $mFull $ios[$n] (Join-Path $iosDir "$n.png") }

# Android: legacy + round (redondeado con fondo) y foreground adaptive (glifo)
$droid = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
$droidFg = @{ 'mdpi' = 108; 'hdpi' = 162; 'xhdpi' = 216; 'xxhdpi' = 324; 'xxxhdpi' = 432 }
foreach ($d in $droid.Keys) {
  $dir = Join-Path $out "android/mipmap-$d"; New-Item -ItemType Directory -Force $dir | Out-Null
  SavePng $mRound $droid[$d] (Join-Path $dir 'ic_launcher.png')
  SavePng $mCircle $droid[$d] (Join-Path $dir 'ic_launcher_round.png')
  SavePng $mGlyph $droidFg[$d] (Join-Path $dir 'ic_launcher_foreground.png')
  SavePng $mGlyph $droid[$d] (Join-Path $dir 'ic_stat_logo.png')
}

# macOS: icns para el client y para Remote Display Server.app
$macDir = Join-Path $out 'macos'; New-Item -ItemType Directory -Force $macDir | Out-Null
foreach ($s in 16, 32, 64, 128, 256, 512, 1024) { SavePng $mMac $s (Join-Path $macDir "mac-$s.png") }
# OJO: NO emitir 'icp4'/'icp5' (16/32 a 1x) con PNG: macOS los interpreta como datos
# crudos y en displays no-Retina el icono chico de Finder sale como ruido. Sin esos
# chunks macOS reescala desde ic11/ic07. (El icns definitivo se regenera en la Mac con
# `iconutil -c icns`, que escribe is32/il32 correctos; ver server-mac/README.)
WriteIcns @{
  'ic07' = (Join-Path $macDir 'mac-128.png'); 'ic08' = (Join-Path $macDir 'mac-256.png');
  'ic09' = (Join-Path $macDir 'mac-512.png'); 'ic10' = (Join-Path $macDir 'mac-1024.png');
  'ic11' = (Join-Path $macDir 'mac-32.png'); 'ic12' = (Join-Path $macDir 'mac-64.png');
  'ic13' = (Join-Path $macDir 'mac-256.png'); 'ic14' = (Join-Path $macDir 'mac-512.png')
} (Join-Path $out 'AppIcon.icns')

$mFull.Dispose(); $mRound.Dispose(); $mMac.Dispose(); $mGlyph.Dispose(); $mCircle.Dispose()
Write-Output "OK -> $out"
