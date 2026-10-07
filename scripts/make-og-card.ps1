<#
.SYNOPSIS
  Renders the KanaAI Open Graph card (1200x630) as a PNG.

.DESCRIPTION
  Social crawlers (X, Facebook, LinkedIn, Slack) do not render SVG og:image
  values, so the share card must be a raster image. This script draws it with
  System.Drawing so the card stays reproducible from the repository instead of
  becoming a binary with no source.

  Colours and wording match site-assets/landing.css and site-assets/index.html.
  The card states the published beta and its limits; it must not be reworded
  into a quality claim that STATE.md does not support.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/make-og-card.ps1
#>
[CmdletBinding()]
param(
  [string]$OutDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDirectory) { $OutDirectory = Join-Path $repositoryRoot 'site-assets' }
if (-not (Test-Path -LiteralPath $OutDirectory)) {
  throw "OutDirectory does not exist: $OutDirectory"
}

$width = 1200
$height = 630

# Brand tokens (kept in sync with site-assets/landing.css).
$ink = [System.Drawing.Color]::FromArgb(255, 20, 46, 41)        # #142e29
$inkDeep = [System.Drawing.Color]::FromArgb(255, 18, 33, 38)    # #122126
$accent = [System.Drawing.Color]::FromArgb(255, 212, 244, 141)  # #d4f48d
$accentSoft = [System.Drawing.Color]::FromArgb(255, 185, 216, 255)
$accentWarm = [System.Drawing.Color]::FromArgb(255, 245, 182, 122)
$paper = [System.Drawing.Color]::FromArgb(255, 245, 243, 235)   # #f5f3eb
$paperMuted = [System.Drawing.Color]::FromArgb(255, 214, 227, 218)

function New-RoundedPath {
  param([float]$X, [float]$Y, [float]$W, [float]$H, [float]$Radius)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $Radius * 2
  $path.AddArc($X, $Y, $d, $d, 180, 90)
  $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
  $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
  $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

function Draw-Mark {
  # Vector replica of site-assets/kanai-mark.svg, scaled to $Size.
  param($Graphics, [float]$X, [float]$Y, [float]$Size)
  $s = $Size / 64.0
  $background = New-Object System.Drawing.SolidBrush($inkDeep)
  $graphics.FillPath($background, (New-RoundedPath -X $X -Y $Y -W $Size -H $Size -Radius (16 * $s)))
  $lime = New-Object System.Drawing.SolidBrush($accent)
  $graphics.FillRectangle($lime, $X + 16 * $s, $Y + 17 * $s, 32 * $s, 7 * $s)
  $graphics.FillRectangle($lime, $X + 16 * $s, $Y + 24 * $s, 7 * $s, 23 * $s)
  $graphics.FillRectangle($lime, $X + 23 * $s, $Y + 24 * $s, 19 * $s, 7 * $s)
  $graphics.FillRectangle($lime, $X + 23 * $s, $Y + 31 * $s, 19 * $s, 7 * $s)
  $graphics.FillRectangle($lime, $X + 16 * $s, $Y + 38 * $s, 14 * $s, 9 * $s)
  $blue = New-Object System.Drawing.SolidBrush($accentSoft)
  $graphics.FillRectangle($blue, $X + 41 * $s, $Y + 31 * $s, 7 * $s, 16 * $s)
  $warm = New-Object System.Drawing.SolidBrush($accentWarm)
  $graphics.FillEllipse($warm, $X + 44 * $s, $Y + 13 * $s, 8 * $s, 8 * $s)
  $background.Dispose(); $lime.Dispose(); $blue.Dispose(); $warm.Dispose()
}

function Render-Card {
  param(
    [string]$OutPath,
    [string]$Kicker,
    [string]$Headline1,
    [string]$Headline2,
    [string]$Lede,
    [string]$FactLine,
    [string]$UrlText,
    [string]$Footnote
  )

  $bitmap = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

  $inkBrush = New-Object System.Drawing.SolidBrush($ink)
  $graphics.FillRectangle($inkBrush, 0, 0, $width, $height)

  # Ambient rings plus the accent rule, echoing the site hero.
  $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(26, 212, 244, 141), 2)
  $graphics.DrawEllipse($ringPen, 760, -190, 640, 640)
  $graphics.DrawEllipse($ringPen, 860, -90, 440, 440)
  $ringPen.Dispose()

  $accentBrush = New-Object System.Drawing.SolidBrush($accent)
  $graphics.FillRectangle($accentBrush, 96, 214, 88, 6)

  Draw-Mark -Graphics $graphics -X 96 -Y 96 -Size 88
  $paperBrush = New-Object System.Drawing.SolidBrush($paper)
  $wordFont = New-Object System.Drawing.Font('Yu Gothic UI', 40, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $graphics.DrawString('KanaAI', $wordFont, $paperBrush, 208, 108)
  $wordFont.Dispose()

  $kickerFont = New-Object System.Drawing.Font('Yu Gothic UI', 21, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $graphics.DrawString($Kicker, $kickerFont, $accentBrush, 96, 166)
  $kickerFont.Dispose()

  $headFont = New-Object System.Drawing.Font('Yu Gothic UI', 62, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $graphics.DrawString($Headline1, $headFont, $paperBrush, 92, 244)
  $graphics.DrawString($Headline2, $headFont, $paperBrush, 92, 324)
  $headFont.Dispose()

  $ledeFont = New-Object System.Drawing.Font('Yu Gothic UI', 27, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $mutedBrush = New-Object System.Drawing.SolidBrush($paperMuted)
  $graphics.DrawString($Lede, $ledeFont, $mutedBrush, 96, 422)
  $ledeFont.Dispose()

  $dividerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 60, 92, 82), 2)
  $graphics.DrawLine($dividerPen, 96, 494, 1104, 494)
  $dividerPen.Dispose()

  $factFont = New-Object System.Drawing.Font('Yu Gothic UI', 24, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $graphics.DrawString($FactLine, $factFont, $accentBrush, 96, 516)
  $factFont.Dispose()

  $urlFont = New-Object System.Drawing.Font('Yu Gothic UI', 24, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $urlSize = $graphics.MeasureString($UrlText, $urlFont)
  $graphics.DrawString($UrlText, $urlFont, $paperBrush, (1104 - $urlSize.Width), 516)
  $urlFont.Dispose()

  $metaFont = New-Object System.Drawing.Font('Yu Gothic UI', 19, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $metaBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 150, 172, 160))
  $graphics.DrawString($Footnote, $metaFont, $metaBrush, 96, 564)
  $metaFont.Dispose()

  $bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose()
  $bitmap.Dispose()
  $inkBrush.Dispose(); $accentBrush.Dispose(); $paperBrush.Dispose()
  $mutedBrush.Dispose(); $metaBrush.Dispose()
}

# Wording lives in a UTF-8 data file and is decoded explicitly, so this script
# stays pure ASCII and cannot be corrupted by the console or the ANSI code page.
$textPath = Join-Path $PSScriptRoot 'og-card-text.json'
if (-not (Test-Path -LiteralPath $textPath)) {
  throw "Missing wording file: $textPath"
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
$copy = [System.IO.File]::ReadAllText($textPath, $utf8) | ConvertFrom-Json

$cards = @()
foreach ($card in $copy.cards) {
  $outPath = Join-Path $OutDirectory $card.file
  Render-Card -OutPath $outPath `
    -Kicker $card.kicker `
    -Headline1 $card.headline1 `
    -Headline2 $card.headline2 `
    -Lede $card.lede `
    -FactLine $card.fact `
    -UrlText $copy.url `
    -Footnote $card.footnote
  $item = Get-Item -LiteralPath $outPath
  $probe = [System.Drawing.Image]::FromFile($outPath)
  $cards += [pscustomobject]@{
    File   = $card.file
    Width  = $probe.Width
    Height = $probe.Height
    Bytes  = $item.Length
  }
  $probe.Dispose()
}

Write-Host 'KanaAI OG cards'
foreach ($card in $cards) {
  Write-Host ("  {0}  {1}x{2}  {3} bytes" -f $card.File, $card.Width, $card.Height, $card.Bytes)
}

