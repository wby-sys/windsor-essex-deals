<#
  Builds a shareable copy of the deals app (share\windsor-essex-deals.html) from latest-deals.html.

  Hosted pages can't load pictures from other websites, so this embeds small copies of
  the pictures people actually see: the best few deals of every Top Picks product, the
  flyer covers and the store logos. Other items show without a picture. Shrunk pictures are
  cached in data\thumbs so later builds are quick.

  Run after Get-Deals.ps1:  powershell -NoProfile -File app\Build-Share.ps1
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Drawing

$Root     = Split-Path $PSScriptRoot -Parent
$ThumbDir = Join-Path $Root 'data\thumbs'
$OutDir   = Join-Path $Root 'share'
New-Item -ItemType Directory -Force $ThumbDir, $OutDir | Out-Null
$UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
$PerProduct = 8       # best deals per product that get a picture (any area)
$PerProductHome = 3   # plus the top picks in the home area

$page = [IO.File]::ReadAllText((Join-Path $Root 'latest-deals.html'), [Text.Encoding]::UTF8)
$start = $page.IndexOf('const DATA = ') + 13
$end = $page.IndexOf(';</script>', $start)
$data = $page.Substring($start, $end - $start).Replace('<\/', '</') | ConvertFrom-Json

$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$md5 = [Security.Cryptography.MD5]::Create()
$script:fetched = 0

# Small data: URI for a picture, or '' if it can't be fetched.
function Get-Thumb([string]$Url, [int]$Max, [switch]$Png) {
  if (-not $Url) { return '' }
  $u = $Url -replace '^http:', 'https:'
  $key = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$u|$Max|$Png"))).Replace('-', '')
  $ext = if ($Png) { 'png' } else { 'jpg' }
  $path = Join-Path $ThumbDir "$key.$ext"
  if (-not (Test-Path $path)) {
    try {
      $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20 -Headers $UA
      $ms = New-Object IO.MemoryStream(, $resp.RawContentStream.ToArray())
      $img = [Drawing.Image]::FromStream($ms)
      $scale = [math]::Min(1.0, $Max / [math]::Max($img.Width, $img.Height))
      $w = [math]::Max(1, [int]($img.Width * $scale)); $h = [math]::Max(1, [int]($img.Height * $scale))
      $bmp = New-Object Drawing.Bitmap($w, $h)
      $g = [Drawing.Graphics]::FromImage($bmp)
      $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      if (-not $Png) { $g.Clear([Drawing.Color]::White) }
      $g.DrawImage($img, 0, 0, $w, $h)
      $g.Dispose()
      if ($Png) { $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png) }
      else {
        $ep = New-Object Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality, [long]60)
        $bmp.Save($path, $jpeg, $ep)
      }
      $bmp.Dispose(); $img.Dispose(); $ms.Dispose()
      $script:fetched++
    } catch { return '' }
  }
  $mime = if ($Png) { 'image/png' } else { 'image/jpeg' }
  return "data:$mime;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
}

# Rank like the page's Top Picks: household-size packs first, then by unit price within the
# most common unit type, then everything else by price.
function Get-Ranked($list, [double]$Cap) {
  $list = @($list | Where-Object { -not (@($_.cd) -contains 'online') })
  $dom = ($list | Where-Object { $_.cw } | Group-Object cw | Sort-Object Count -Descending | Select-Object -First 1).Name
  return @($list | Sort-Object @{ Expression = { if ($_.tp -gt $Cap) { 1 } else { 0 } } }, @{ Expression = { if ($dom -and $_.cw -eq $dom) { 0 } else { 1 } } }, @{ Expression = { if ($dom -and $_.cw -eq $dom) { [double]$_.cv } else { [double]$_.v } } })
}

$byId = @{}; foreach ($x in $data.items) { $byId[$x.id] = $x }
$homeArea = [string]$data.meta.home
$cap = if ($data.meta.maxPickPrice) { [double]$data.meta.maxPickPrice } else { 35 }
$want = @{}
foreach ($v in $data.varieties) {
  $items = @(@($v.ids) | ForEach-Object { $byId[$_] } | Where-Object { $_ })
  $ranked = Get-Ranked $items $cap
  $seen = @{}; $n = 0
  foreach ($x in $ranked) { $k = "$($x.m)|$($x.n)|$($x.p)"; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = 1; $want[$x.id] = 1; $n++; if ($n -ge $PerProduct) { break } }
  $n = 0
  foreach ($x in ($ranked | Where-Object { @($_.ar) -contains $homeArea })) { $want[$x.id] = 1; $n++; if ($n -ge $PerProductHome) { break } }
}
Write-Host "Pictures for $($want.Count) deals, $(@($data.flyers).Count) flyer covers and store logos..."

$done = 0
foreach ($x in $data.items) {
  if ($want.ContainsKey($x.id)) { $x.i = Get-Thumb $x.i 140; $done++; if ($done % 200 -eq 0) { Write-Host "  $done done" } }
  else { $x.i = '' }
}
$logos = @{}
foreach ($f in $data.flyers) {
  if ($f.lg -and -not $logos.ContainsKey($f.lg)) { $logos[$f.lg] = Get-Thumb $f.lg 72 -Png }
  if ($f.lg) { $f.lg = $logos[$f.lg] }
  $f.th = Get-Thumb $f.th 240
}
Write-Host "Downloaded $script:fetched new pictures (the rest came from data\thumbs)."

# Hosted pages get their own document wrapper, so keep only the page's content.
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'template.html'), [Text.Encoding]::UTF8)
foreach ($tag in '<!doctype html>', '<html lang="en">', '<head>', '</head>', '<body>', '</body>', '</html>', '<meta charset="utf-8">', '<meta name="viewport" content="width=device-width, initial-scale=1">') {
  $template = $template.Replace($tag, '')
}
$json = ($data | ConvertTo-Json -Compress -Depth 10) -replace '</', '<\/'
$out = Join-Path $OutDir 'windsor-essex-deals.html'
[IO.File]::WriteAllText($out, $template.Trim().Replace('__DATA__', $json), (New-Object Text.UTF8Encoding $false))
Write-Host ("Wrote {0} ({1:N1} MB)" -f $out, ((Get-Item $out).Length / 1MB))
