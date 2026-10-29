# Generates ImageCake's app icon into Assets.xcassets/AppIcon.appiconset.
# Why this exists: a dual-destination (iOS + macOS) target needs an AppIcon set, otherwise
# actool fails the whole build with `None of the input catalogs contained a matching ... "AppIcon"`.
# Artwork is drawn with System.Drawing at a 1024 master and downscaled, so the repo needs no
# binary source of truth beyond the generated PNGs and no network access.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/make-app-icon.ps1
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$outDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'ImageCake\Resources\Assets.xcassets\AppIcon.appiconset'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$accent = [System.Drawing.Color]::FromArgb(255, 74, 158, 255)   # AccentColor.colorset
$plum   = [System.Drawing.Color]::FromArgb(255, 46, 32, 64)
$cream  = [System.Drawing.Color]::FromArgb(255, 255, 214, 186)
$frost  = [System.Drawing.Color]::FromArgb(255, 250, 246, 244)
$frost2 = [System.Drawing.Color]::FromArgb(255, 224, 213, 229)

function New-Master {
    $size = 1024
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    # Background: plum to cream, read as "darkroom -> print".
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect, $plum, $cream, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillRectangle($brush, $rect)

    # Safe area: Apple masks the artwork, so everything sits inside ~78% of the canvas.
    $s = 0.78
    $cx = $size / 2.0
    $unit = $size * $s

    # Ground shadow.
    $sh = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
    $g.FillEllipse($sh, [single]($cx - $unit * 0.36), [single]($size * 0.735), [single]($unit * 0.72), [single]($unit * 0.11))

    # Two tiers, bottom-up, each with a frosting lip.
    $tiers = @(
        @{ y = 0.655; h = 0.135; w = 0.52 },
        @{ y = 0.535; h = 0.125; w = 0.38 }
    )
    foreach ($t in $tiers) {
        $w = $unit * $t.w
        $h = $unit * $t.h
        $x = $cx - $w / 2.0
        $y = $size * $t.y - $h
        $body = New-Object System.Drawing.SolidBrush($accent)
        $g.FillRectangle($body, [single]$x, [single]$y, [single]$w, [single]$h)
        $lip = New-Object System.Drawing.SolidBrush($frost)
        $g.FillRectangle($lip, [single]$x, [single]$y, [single]$w, [single]($h * 0.30))
    }

    # Cherry and stem.
    $cherry = New-Object System.Drawing.SolidBrush($frost)
    $d = $unit * 0.10
    $g.FillEllipse($cherry, [single]($cx - $d / 2.0), [single]($size * 0.535 - $unit * 0.125 - $d * 1.5), [single]$d, [single]$d)
    $pen = New-Object System.Drawing.Pen($frost2, [single]($unit * 0.018))
    $g.DrawLine($pen,
        [single]($cx), [single]($size * 0.535 - $unit * 0.125 - $d * 1.5 + $d * 0.2),
        [single]($cx + $d * 0.7), [single]($size * 0.535 - $unit * 0.125 - $d * 2.4))

    $g.Dispose()
    return $bmp
}

function Save-Scaled($master, $path, $px) {
    # 1024 deliverables must be opaque (App Store rejects an alpha channel there),
    # so flatten those onto 24bpp and keep the rest 32bpp.
    $bpp = if ($px -ge 1024) { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb } else { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb }
    $dst = New-Object System.Drawing.Bitmap($px, $px, $bpp)
    $gg = [System.Drawing.Graphics]::FromImage($dst)
    $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gg.Clear([System.Drawing.Color]::White)
    $gg.DrawImage($master, 0, 0, $px, $px)
    $gg.Dispose()
    $dst.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $dst.Dispose()
}

# idiom -> list of (px, filename). iOS entries carry explicit scales; macOS uses @1x/@2x naming.
$plan = [ordered]@{
    'icon-ios-20@2x.png'      = 40
    'icon-ios-20@3x.png'      = 60
    'icon-ios-29@2x.png'      = 58
    'icon-ios-29@3x.png'      = 87
    'icon-ios-40@2x.png'      = 80
    'icon-ios-40@3x.png'      = 120
    'icon-ios-60@2x.png'      = 120
    'icon-ios-60@3x.png'      = 180
    'icon-ios-76@1x.png'      = 76
    'icon-ios-76@2x.png'      = 152
    'icon-ios-83.5@2x.png'    = 167
    'icon-ios-marketing.png'  = 1024
    'icon-macos-16@1x.png'    = 16
    'icon-macos-16@2x.png'    = 32
    'icon-macos-32@1x.png'    = 32
    'icon-macos-32@2x.png'    = 64
    'icon-macos-128@1x.png'   = 128
    'icon-macos-128@2x.png'   = 256
    'icon-macos-256@1x.png'   = 256
    'icon-macos-256@2x.png'   = 512
    'icon-macos-512@1x.png'   = 512
    'icon-macos-512@2x.png'   = 1024
}

# Contents.json in the appiconset is the manifest of record (hand-written, Xcode-shaped);
# this script only fills the PNGs it references. It validates that every referenced file exists.
$manifestPath = Join-Path $outDir 'Contents.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$want = @($manifest.images | ForEach-Object { $_.filename } | Sort-Object -Unique)

$master = New-Master
foreach ($name in $plan.Keys) {
    if ($name -notin $want) { throw "$name is not declared in Contents.json; sync the manifest first" }
    Save-Scaled $master (Join-Path $outDir $name) $plan[$name]
}
$master.Dispose()

$missing = @($want | Where-Object { -not (Test-Path (Join-Path $outDir $_)) })
if ($missing.Count -gt 0) { throw "declared in Contents.json but missing on disk: $($missing -join ', ')" }

'generated:'
Get-ChildItem $outDir -Filter *.png | ForEach-Object {
    $img = [System.Drawing.Image]::FromFile($_.FullName)
    "{0,-26} {1,5}px {2,-16} {3,6} KB" -f $_.Name, $img.Width, $img.PixelFormat, [math]::Round($_.Length / 1KB, 1)
    $img.Dispose()
}
"Contents.json: $($want.Count) declared entries, all present"


