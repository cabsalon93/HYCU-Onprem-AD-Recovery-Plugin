<#
================================================================================
 Make-Icon.ps1 - Generate assets\HYCU.ico from the official HYCU logomark.
--------------------------------------------------------------------------------
 Renders the white HYCU logomark (vector) centered on a HYCU-purple rounded badge
 at several sizes (16..256) and assembles a multi-resolution .ico for the exe.

 Run:    powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\Make-Icon.ps1
 Output: .\assets\HYCU.ico
================================================================================
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }

# WPF RenderTargetBitmap requires a single-threaded apartment; fail early with a clear message under MTA.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    throw "Run this script with -STA (e.g. powershell -STA -File .\Make-Icon.ps1); WPF rendering needs an STA thread."
}

# Official HYCU logomark geometry (viewBox 1253.98 x 1080), same vector used in the GUI header/About.
$pathData = 'F1 M624.09,888.71h133.67c160.41,0,290.59-130.18,290.59-290.59c0-89.5-40.68-169.7-103.45-223.17L738,816.64 L628.74,707.38l51.14-109.26H519.47l-33.71,74.39c-11.62,25.57-17.44,52.31-17.44,75.55C468.33,827.1,527.61,888.71,624.09,888.71 M309.09,705.06l206.9-441.7l109.26,109.26L574.1,481.88h160.41l33.71-74.39c11.62-25.57,17.44-52.31,17.44-75.55c0-79.04-59.28-140.65-155.76-140.65H496.23c-160.41,0-290.59,130.18-290.59,290.59C205.64,571.38,246.32,651.59,309.09,705.06 M1013.15,830.59c-16.05,0-29.06,13.01-29.06,29.06c0,16.05,13.01,29.06,29.06,29.06c16.05,0,29.06-13.01,29.06-29.06C1042.21,843.6,1029.2,830.59,1013.15,830.59z M1013.15,882.9c-12.84,0-23.25-10.41-23.25-23.25c0-12.84,10.41-23.25,23.25-23.25c12.84,0,23.25,10.41,23.25,23.25C1036.39,872.49,1025.99,882.9,1013.15,882.9z M1020.27,861.73c3.38-1.29,5.74-4,5.74-8.14c0-6.14-5.21-9.48-11.43-9.48h-12.33v30.25h7.12v-11.34h4.32l6.23,11.34h7.87L1020.27,861.73z M1013.86,857.99h-4.5v-8.76h4.5c3.02,0,5.07,1.78,5.07,4.45C1018.93,856.39,1016.89,857.99,1013.86,857.99z'
$geo = [System.Windows.Media.Geometry]::Parse($pathData)
$vbW = 1253.98; $vbH = 1080.0

function New-IconPng([int]$size) {
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    # HYCU-purple rounded badge.
    $bg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x5B, 0x18, 0xC0))
    $radius = [double]$size * 0.18
    $dc.DrawRoundedRectangle($bg, $null, (New-Object System.Windows.Rect 0, 0, $size, $size), $radius, $radius)
    # White logomark, scaled to fit with padding and centered.
    $pad   = [double]$size * 0.20
    $avail = $size - 2 * $pad
    $scale = [Math]::Min($avail / $vbW, $avail / $vbH)
    $offX  = ($size - $vbW * $scale) / 2
    $offY  = ($size - $vbH * $scale) / 2
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform $offX, $offY))
    $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform $scale, $scale))
    $dc.DrawGeometry(([System.Windows.Media.Brushes]::White), $null, $geo)
    $dc.Pop(); $dc.Pop()
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object System.IO.MemoryStream
    $enc.Save($ms)
    return ,([byte[]]$ms.ToArray())
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs  = @{}
foreach ($s in $sizes) { $pngs[$s] = New-IconPng $s }

# Assemble the .ico (PNG-compressed frames; supported by Windows Vista+).
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ms
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($s in $sizes) {
    $len = $pngs[$s].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($s in $sizes) { $bw.Write($pngs[$s]) }
$bw.Flush()

$assets = Join-Path $root 'assets'
if (-not (Test-Path $assets)) { New-Item -ItemType Directory -Path $assets -Force | Out-Null }
$icoPath = Join-Path $assets 'HYCU.ico'
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
Write-Host "Wrote $icoPath ($([math]::Round((Get-Item $icoPath).Length/1KB,1)) KB, sizes: $($sizes -join ', '))"
