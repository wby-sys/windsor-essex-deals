<#
  Windsor-Essex grocery deal finder.

  1. Lists every grocery (plus chosen pharmacy) flyer on Flipp for each area in config.json.
  2. Downloads every item in those flyers.
  3. Runs Flipp searches for the watchlist terms to pick up per-lb pricing, savings and categories.
  4. Appends new items to data\history.csv (the price history used for trends).
  5. Writes an HTML report: latest-deals.html plus a dated copy in reports\.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File app\Get-Deals.ps1 [-Open]
#>
param(
  [switch]$Open,
  [switch]$ReportOnly   # rebuild the report from the last download without fetching again
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root        = Split-Path $PSScriptRoot -Parent
$Config      = [IO.File]::ReadAllText((Join-Path $Root 'config.json')) | ConvertFrom-Json
$DataDir     = Join-Path $Root 'data'
$ReportDir   = Join-Path $Root 'reports'
New-Item -ItemType Directory -Force $DataDir, $ReportDir | Out-Null
$HistoryPath = Join-Path $DataDir 'history.csv'
$LogPath     = Join-Path $DataDir 'run.log'
$Inv         = [Globalization.CultureInfo]::InvariantCulture
$Base        = 'https://backflipp.wishabi.com/flipp'
$Now         = Get-Date
$RunId       = $Now.ToString('yyyy-MM-dd HH:mm', $Inv)
$LbPerKg     = 2.20462
$HomeArea    = [string]$Config.homeArea
$script:Failures = 0

# ---------------------------------------------------------------- helpers

function Write-Log([string]$Message) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

# Flipp sends UTF-8 without a charset header; decode the bytes ourselves so
# trademark symbols and accents don't come out garbled in PowerShell 5.1.
function Get-Json([string]$Url) {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
      $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      Start-Sleep -Milliseconds ([int]$Config.requestDelayMs)
      return ($text | ConvertFrom-Json)
    } catch {
      if ($attempt -eq 3) {
        $script:Failures++
        Write-Log "FAILED $Url : $($_.Exception.Message)"
        return $null
      }
      Start-Sleep -Seconds (2 * $attempt)
    }
  }
}

function ConvertTo-Num($Value) {
  if ($null -eq $Value) { return $null }
  $s = ([string]$Value).Trim() -replace '[^0-9.]', ''
  if ($s -eq '') { return $null }
  $d = 0.0
  if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
  return $null
}

function Format-Num($Value) {
  if ($null -eq $Value -or $Value -eq '') { return '' }
  return ([double]$Value).ToString('0.00', $Inv)
}

function Clean-Text($Text) {
  if (-not $Text) { return '' }
  return (([Net.WebUtility]::HtmlDecode([string]$Text)) -replace '\s+', ' ').Trim()
}


function Get-NameKey([string]$Name) {
  return (($Name.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim())
}

function ConvertTo-Date([string]$Text) {
  $d = [datetime]::MinValue
  if ([datetime]::TryParse($Text, $Inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  return $null
}

# "strawberries" -> "strawberr", "potatoes" -> "potato", "eggs" -> "egg"
function Get-Stem([string]$Word) {
  if ($Word -match 'ies$') { return $Word.Substring(0, $Word.Length - 3) }
  if ($Word -match 'oes$') { return $Word.Substring(0, $Word.Length - 2) }
  if ($Word -match '[^s]s$') { return $Word.Substring(0, $Word.Length - 1) }
  return $Word
}

# A config entry is either "term" or { "term": "...", "exclude": [...] }.
function New-Matcher($Entry, [string[]]$ExtraExclude) {
  if ($Entry -is [string]) { $term = $Entry; $excl = @() } else { $term = [string]$Entry.term; $excl = @($Entry.exclude) }
  $stems = @(foreach ($word in ($term.ToLowerInvariant() -split '\s+')) { Get-Stem $word })
  [pscustomobject]@{
    Term     = $term
    Stems    = $stems
    Patterns = @(foreach ($s in $stems) { '\b' + [regex]::Escape($s) + '(s|es|ies|y)?\b' })
    Exclude  = @(@($excl) + @($ExtraExclude) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
  }
}

$Watch = @(foreach ($w in $Config.watchlist) { New-Matcher $w })

# Everything that can become a Top Pick, used to decide which items get their fine print checked.
$PickMatchers = @(foreach ($sec in @($Config.picks)) { foreach ($grp in @($sec.groups)) { foreach ($e in @($grp.items)) { New-Matcher $e } } }) + $Watch

function Test-WatchMatch($W, [string]$Name) {
  $n = $Name.ToLowerInvariant()
  foreach ($s in $W.Stems) { if (-not $n.Contains($s)) { return $false } }
  foreach ($p in $W.Patterns) { if ($n -notmatch $p) { return $false } }
  foreach ($x in $W.Exclude) { if ($n.Contains($x)) { return $false } }
  return $true
}

function Test-AnyPick([string]$Name) {
  foreach ($m in $PickMatchers) { if (Test-WatchMatch $m $Name) { return $true } }
  return $false
}

# Works out the effective price per item ("2 for $5" -> $2.50) and, for
# weighed items, a normalized price per lb so stores can be compared.
function Get-UnitInfo([string]$Post, [string]$Pre, [double]$Price) {
  $post = $Post.ToLowerInvariant()
  $qty = 1
  if ($Pre -match '^\s*(\d+)\s*(/|for)') { $qty = [math]::Max([int]$Matches[1], 1) }
  $eff = $Price / $qty
  if ($post -match '^\W*lb')     { return @{ Unit = 'lb'; Eff = $eff; PerLb = $eff } }
  if ($post -match '^\W*kg')     { return @{ Unit = 'lb'; Eff = $eff; PerLb = $eff / $LbPerKg } }
  if ($post -match '100\s*g')    { return @{ Unit = 'lb'; Eff = $eff; PerLb = $eff * 4.53592 } }
  if ($post -match '\blb\b')     { return @{ Unit = 'lb'; Eff = $eff; PerLb = $eff } }
  if ($post -match '\bkg\b')     { return @{ Unit = 'lb'; Eff = $eff; PerLb = $eff / $LbPerKg } }
  return @{ Unit = 'ea'; Eff = $eff; PerLb = $null }
}

function Get-SavingsPct($Price, $Orig, [string]$Story) {
  if ($Orig -and $Price -and $Orig -gt $Price) { return [int][math]::Round(100 * ($Orig - $Price) / $Orig) }
  if ($Story -match '(?i)save\s+(up\s+to\s+)?(\d{1,2})\s*%') { return [int]$Matches[2] }
  if ($Story -match '(?i)(\d{1,2})\s*%\s*off') { return [int]$Matches[1] }
  if ($Story -match '(?i)save\s+(up\s+to\s+)?\$?(\d+(\.\d+)?)' -and $Price -gt 0) {
    $s = [double]::Parse($Matches[2], $Inv)
    return [int][math]::Round(100 * $s / ($s + $Price))
  }
  return $null
}

Write-Log "Run started ($($Config.areas.Count) areas, $($Watch.Count) watchlist terms)"

$CachePath = Join-Path $DataDir 'last-fetch.clixml'
if ($ReportOnly) {
  $cache  = Import-Clixml $CachePath
  $Flyers = $cache.Flyers
  $Items  = $cache.Items
  Write-Log "Loaded $($Items.Count) items from last download"
} else {

# ---------------------------------------------------------------- 1. flyers per area

$Flyers = @{}
$ExtraMerchants   = @($Config.extraMerchants)
$ExcludeMerchants = @($Config.excludeMerchants)
foreach ($area in $Config.areas) {
  $d = Get-Json "$Base/data?locale=en-ca&postal_code=$($area.postal)"
  if (-not $d) { continue }
  foreach ($f in $d.flyers) {
    $merchant = Clean-Text $f.merchant
    $isGrocery = @($f.categories) -contains 'Groceries'
    if (-not ($isGrocery -or ($ExtraMerchants -contains $merchant))) { continue }
    if ($ExcludeMerchants -contains $merchant) { continue }
    $key = [string]$f.id
    if (-not $Flyers.ContainsKey($key)) {
      $Flyers[$key] = [pscustomobject]@{
        Id        = $key
        Merchant  = $merchant
        Title     = Clean-Text $f.name
        Logo      = [string]$f.merchant_logo
        Thumb     = [string]$f.thumbnail_url
        ValidFrom = [string]$f.valid_from
        ValidTo   = [string]$f.valid_to
        Areas     = New-Object 'Collections.Generic.List[string]'
        ItemCount = 0
      }
    }
    if (-not $Flyers[$key].Areas.Contains($area.name)) { $Flyers[$key].Areas.Add($area.name) }
  }
}
Write-Log "Found $($Flyers.Count) flyers from $(@($Flyers.Values | Select-Object -ExpandProperty Merchant -Unique).Count) stores"

# ---------------------------------------------------------------- 2. every item in every flyer

$Items = @{}
foreach ($f in $Flyers.Values) {
  $fd = Get-Json "$Base/flyers/$($f.Id)?locale=en-ca"
  if (-not $fd) { continue }
  foreach ($it in $fd.items) {
    $price = ConvertTo-Num $it.price
    $name  = Clean-Text $it.name
    if ($null -eq $price -or $price -le 0 -or -not $name) { continue }
    $vf = [string]$it.valid_from; if (-not $vf) { $vf = $f.ValidFrom }
    $vt = [string]$it.valid_to;   if (-not $vt) { $vt = $f.ValidTo }
    $Items[[string]$it.id] = [pscustomobject]@{
      ItemId        = [string]$it.id
      FlyerId       = $f.Id
      Merchant      = $f.Merchant
      Name          = $name
      Price         = $price
      PrePrice      = ''
      PostPrice     = ''
      Unit          = ''
      Eff           = $price
      PerLb         = $null
      OriginalPrice = $null
      SavingsPct    = $null
      SaleStory     = ''
      Notes         = ''
      Category      = ''
      Image         = [string]$it.cutout_image_url
      Brand         = Clean-Text $it.brand
      Logo          = $f.Logo
      Left          = [double]$it.left
      Top           = [double]$it.top
      ValidFrom     = $vf
      ValidTo       = $vt
      Areas         = $f.Areas
      WatchTerms    = New-Object 'Collections.Generic.List[string]'
    }
    $f.ItemCount++
  }
}
Write-Log "Downloaded $($Items.Count) flyer items"

# ---------------------------------------------------------------- 3. search enrichment

function Update-FromSearch($S) {
  $id = [string]$S.flyer_item_id
  if (-not $id) { $id = [string]$S.id }
  if (-not $Items.ContainsKey($id)) { return }
  $it = $Items[$id]
  if ($it.Category) { return }
  $price = ConvertTo-Num $S.current_price
  if ($null -eq $price -or $price -le 0) { $price = $it.Price }
  $u = Get-UnitInfo ([string]$S.post_price_text) ([string]$S.pre_price_text) $price
  $it.Price         = $price
  $it.PrePrice      = Clean-Text $S.pre_price_text
  $it.PostPrice     = Clean-Text $S.post_price_text
  $it.Unit          = $u.Unit
  $it.Eff           = $u.Eff
  $it.PerLb         = $u.PerLb
  $it.OriginalPrice = ConvertTo-Num $S.original_price
  $it.SaleStory     = Clean-Text $S.sale_story
  $it.SavingsPct    = Get-SavingsPct $price $it.OriginalPrice $it.SaleStory
  $it.Category      = Clean-Text $S._L1
  if (-not $it.Category) { $it.Category = 'Other' }
  if ($S.clean_image_url) { $it.Image = [string]$S.clean_image_url }
}

$terms = @($Watch | ForEach-Object { $_.Term }) + @($Config.discoveryTerms)
$done = 0
foreach ($term in $terms) {
  foreach ($area in $Config.areas) {
    $r = Get-Json "$Base/items/search?locale=en-ca&postal_code=$($area.postal)&q=$([uri]::EscapeDataString($term))"
    if (-not $r) { continue }
    foreach ($s in $r.items) { Update-FromSearch $s }
  }
  $done++
  if ($done % 10 -eq 0) { Write-Log "  searched $done of $($terms.Count) terms" }
}
$enriched = @($Items.Values | Where-Object { $_.Category }).Count
Write-Log "Search details added to $enriched items"

# ---------------------------------------------------------------- 3b. fine print for possible picks
# Search results carry the price text ("Member Price**", "2/") and sale message; for possible
# picks that searches didn't reach, fetch the item's details so hidden conditions aren't missed.
$DetailCachePath = Join-Path $DataDir 'item-details.clixml'
$detailCache = @{}
if (Test-Path $DetailCachePath) { try { $detailCache = Import-Clixml $DetailCachePath } catch { $detailCache = @{} } }
$need = @($Items.Values | Where-Object { -not $_.Category -and (Test-AnyPick $_.Name) })
Write-Log "Checking fine print on $($need.Count) more possible picks ($(@($need | Where-Object { $detailCache.ContainsKey($_.ItemId) }).Count) already saved)"
$fetched = 0
foreach ($it in $need) {
  $d = $detailCache[$it.ItemId]
  if (-not $d) {
    $j = Get-Json "$Base/items/$($it.ItemId)"
    if (-not $j -or -not $j.item) { continue }
    $d = @{
      Pre   = Clean-Text $j.item.pre_price_text
      Story = Clean-Text $j.item.sale_story
      Notes = Clean-Text "$($j.item.description) $($j.item.disclaimer_text)"
      Orig  = ConvertTo-Num $j.item.original_price
    }
    $detailCache[$it.ItemId] = $d
    $fetched++
    if ($fetched % 200 -eq 0) { Write-Log "  checked $fetched" }
  }
  if ($d.Pre -and -not $it.PrePrice) {
    $it.PrePrice = $d.Pre
    $it.Eff = (Get-UnitInfo ([string]$it.PostPrice) $d.Pre $it.Price).Eff
  }
  if ($d.Story -and -not $it.SaleStory) { $it.SaleStory = $d.Story }
  if ($d.Orig -and -not $it.OriginalPrice) { $it.OriginalPrice = $d.Orig }
  $it.Notes = $d.Notes
  $it.SavingsPct = Get-SavingsPct $it.Price $it.OriginalPrice $it.SaleStory
}
$keep = @{}
foreach ($k in $detailCache.Keys) { if ($Items.ContainsKey($k)) { $keep[$k] = $detailCache[$k] } }
$keep | Export-Clixml -Path $DetailCachePath
Write-Log "Fine print fetched for $fetched items"

@{ Flyers = $Flyers; Items = $Items } | Export-Clixml -Path $CachePath -Depth 4

}

# Bulk Barn's flyer prices are per 100 g but Flipp rarely says so.
foreach ($it in $Items.Values) {
  if ($it.Merchant -eq 'Bulk Barn' -and -not $it.PostPrice) {
    $u = Get-UnitInfo '/100 g' ([string]$it.PrePrice) $it.Price
    $it.PostPrice = '/100 g'; $it.Unit = $u.Unit; $it.Eff = $u.Eff; $it.PerLb = $u.PerLb
  }
}

# Tag watchlist matches across all items (not only search hits), using the current config.
foreach ($it in $Items.Values) {
  $it.WatchTerms = New-Object 'Collections.Generic.List[string]'
  foreach ($w in $Watch) { if (Test-WatchMatch $w $it.Name) { $it.WatchTerms.Add($w.Term) } }
}

# ---------------------------------------------------------------- 4. history

$History = @()
if (Test-Path $HistoryPath) { $History = @(Import-Csv -Path $HistoryPath -Encoding UTF8) }
$known = New-Object 'Collections.Generic.HashSet[string]'
foreach ($h in $History) { [void]$known.Add($h.ItemId) }

$newRows = @(foreach ($it in $Items.Values) {
  if ($known.Contains($it.ItemId)) { continue }
  [pscustomobject][ordered]@{
    RunId         = $RunId
    ItemId        = $it.ItemId
    FlyerId       = $it.FlyerId
    Merchant      = $it.Merchant
    Name          = $it.Name
    Price         = Format-Num $it.Price
    PrePrice      = $it.PrePrice
    PostPrice     = $it.PostPrice
    Unit          = $it.Unit
    EffPrice      = Format-Num $it.Eff
    PerLb         = Format-Num $it.PerLb
    OriginalPrice = Format-Num $it.OriginalPrice
    SavingsPct    = $it.SavingsPct
    SaleStory     = $it.SaleStory
    Category      = $it.Category
    ValidFrom     = $it.ValidFrom
    ValidTo       = $it.ValidTo
    Areas         = ($it.Areas -join ';')
    WatchTerms    = ($it.WatchTerms -join ';')
  }
})
if ($newRows.Count -gt 0) {
  $newRows | Export-Csv -Path $HistoryPath -NoTypeInformation -Encoding UTF8 -Append
}
Write-Log "Saved $($newRows.Count) new items to history ($($History.Count) already stored)"

# Past prices = history rows that aren't part of the current flyers.
$cutoff = $Now.AddDays(-[int]$Config.trendDays)
$Past = @(foreach ($h in $History) {
  if ($Items.ContainsKey($h.ItemId)) { continue }
  $vf = ConvertTo-Date $h.ValidFrom
  if (-not $vf -or $vf -lt $cutoff) { continue }
  if ($h.Unit -eq 'lb') { $unit = 'lb'; $val = ConvertTo-Num $h.PerLb } else { $unit = 'ea'; $val = ConvertTo-Num $h.EffPrice }
  if ($null -eq $val -or $val -le 0) { continue }
  [pscustomobject]@{
    Key      = "$($h.Merchant)|$(Get-NameKey $h.Name)"
    Name     = $h.Name
    Merchant = $h.Merchant
    Week     = $vf.Date
    Unit     = $unit
    Value    = $val
  }
})
$PastByKey = @{}
foreach ($p in $Past) {
  if (-not $PastByKey.ContainsKey($p.Key)) { $PastByKey[$p.Key] = New-Object 'Collections.Generic.List[object]' }
  $PastByKey[$p.Key].Add($p)
}
$HistoryWeeks = @($Past | Select-Object -ExpandProperty Week -Unique).Count

# ---------------------------------------------------------------- 5. scoring helpers

function Get-Value($It) {
  if ($It.Unit -eq 'lb') { return $It.PerLb }
  return $It.Eff
}

function Get-PastRows($It) {
  $unit = 'ea'; if ($It.Unit -eq 'lb') { $unit = 'lb' }
  $key = "$($It.Merchant)|$(Get-NameKey $It.Name)"
  if (-not $PastByKey.ContainsKey($key)) { return @() }
  return @($PastByKey[$key] | Where-Object { $_.Unit -eq $unit })
}

function Get-ItemTrend($It) {
  $val = Get-Value $It
  $rows = Get-PastRows $It
  if ($rows.Count -eq 0) { return @{ Css = 'none'; Text = '' } }
  $weeks = @($rows | Select-Object -ExpandProperty Week -Unique).Count
  $stats = $rows | Measure-Object -Property Value -Minimum -Average
  $wk = "$weeks wk"; if ($weeks -gt 1) { $wk += 's' }
  if ($val -lt $stats.Minimum - 0.005) { return @{ Css = 'good'; Text = "Lowest in $wk" } }
  if ($val -le $stats.Minimum + 0.005) { return @{ Css = 'good'; Text = "Ties $wk low" } }
  if ($val -le $stats.Average * 0.9)   { return @{ Css = 'good'; Text = ('{0}% below usual' -f [math]::Round(100 * (1 - $val / $stats.Average))) } }
  if ($val -ge $stats.Average * 1.05)  { return @{ Css = 'bad';  Text = ('{0}% above usual' -f [math]::Round(100 * ($val / $stats.Average - 1))) } }
  return @{ Css = 'none'; Text = 'Usual price' }
}

# Lowest price per past week for the same store + product, oldest first.
function Get-PriceHistory($It) {
  $rows = Get-PastRows $It
  return @($rows | Group-Object Week | Sort-Object { $_.Group[0].Week } | ForEach-Object {
    @{ w = $_.Group[0].Week.ToString('yyyy-MM-dd', $Inv); v = [math]::Round(($_.Group | Measure-Object -Property Value -Minimum).Minimum, 2) }
  })
}

function Format-Price($It) {
  $price = '$' + (Format-Num $It.Price)
  $pre = [string]$It.PrePrice
  if ($pre -match '(?i)member|scene|optimum|\bmoi\b|online') { $pre = '' }   # shown as a badge instead
  if ($pre -match '^\s*(\d+)\s*(/|for)') { $main = "$($Matches[1]) for $price" }
  elseif ($pre) { $main = "$pre $price" }
  else { $main = $price }
  $suffix = ''
  if ($It.PostPrice -match '^\W*kg') { $suffix = '/kg' }
  elseif ($It.PostPrice -match '100\s*g' -and $It.PostPrice -notmatch '\blb\b') { $suffix = '/100g' }
  elseif ($It.Unit -eq 'lb') { $suffix = '/lb' }
  $main += $suffix
  $sub = ''
  if ($It.Unit -eq 'lb' -and $suffix -ne '/lb') { $sub = '$' + (Format-Num $It.PerLb) + '/lb' }
  elseif ($It.Eff -lt $It.Price - 0.001) { $sub = '$' + (Format-Num $It.Eff) + ' each' }
  return @{ Main = $main; Sub = $sub }
}

# Loyalty programs by store, for naming "members only" prices.
$ProgramPatterns = [ordered]@{
  'PC Optimum' = '^(Real Canadian Superstore|No Frills|Zehrs|Your Independent Grocer|Wholesale Club|Shoppers Drug Mart|Loblaws|Fortinos|Valu-mart)'
  'Scene+'     = '^(Sobeys|FreshCo|Foodland|Safeway|IGA)'
  'moi'        = '^(Metro|Food Basics)'
  'M&M Rewards' = '^M&M Food Market'
}
$MembershipStores = @($Config.membershipStores)

# Hidden conditions on a deal. Mp = membership needed for the price (program or store name);
# Cond = other strings attached: "buy:2" (price needs a multi-buy), "points", "limit:4".
function Get-Conditions($It) {
  $text = "$($It.Name) | $($It.SaleStory) | $($It.PrePrice) | $($It.PostPrice) | $($It.Notes)"
  $mp = ''
  if ($MembershipStores -contains $It.Merchant) { $mp = $It.Merchant }
  elseif ($text -match '(?i)\bmembers?\b|member pric|digital coupon|\bcoupon\b|app only|in[- ]app|loyalty card|with (your )?card') {
    $mp = 'Members'
    foreach ($k in $ProgramPatterns.Keys) { if ($It.Merchant -match $ProgramPatterns[$k]) { $mp = $k; break } }
  }
  $cond = @()
  $buy = 0
  if ([string]$It.PrePrice -match '^\s*(\d+)\s*(/|for)') { $buy = [int]$Matches[1] }
  elseif ("$($It.SaleStory) $($It.Notes)" -match '(?i)(save|get|price|for)[^|]{0,40}when you buy (\d+)' -and "$($It.SaleStory)" -notmatch '(?i)\bpts\b|points') { $buy = [int]$Matches[2] }
  if ($buy -gt 1) { $cond += "buy:$buy" }
  if ($text -match '(?i)\b\d[\d,]*\s*(scene\+\s*)?(pts|points)\b|bonus points') { $cond += 'points' }
  if ($text -match '(?i)\blimit\s*(of\s*)?(\d+)') { $cond += "limit:$($Matches[2])" }
  if ($text -match '(?i)online (price|only|exclusive)|web only|delivery only') { $cond += 'online' }
  return @{ Mp = $mp; Cond = $cond }
}

# Package size from the item name: "454 G", "1.5 KG", "2 X 113 G", "4 L", "12'S", "8=16 rolls".
# Returns K = w (kg), v (litres) or c (count) and Q = the amount, or $null.
function Get-Size([string]$Name) {
  $n = $Name.ToLowerInvariant()
  $num = { param($s) [double]::Parse($s, $Inv) }
  $q = $null; $u = $null
  if ($n -match '(\d+)\s*x\s*(\d+(?:\.\d+)?)\s*(kg|g|ml|l)\b') { $q = (& $num $Matches[1]) * (& $num $Matches[2]); $u = $Matches[3] }
  elseif ($n -match '(\d+(?:\.\d+)?)(?:\s*(?:-|/|to)\s*\d+(?:\.\d+)?)?\s*(kg|g|lbs?|ml|l)\b') { $q = & $num $Matches[1]; $u = $Matches[2] }
  if ($u) {
    switch -regex ($u) {
      '^kg$'  { return @{ K = 'w'; Q = $q } }
      '^g$'   { return @{ K = 'w'; Q = $q / 1000 } }
      '^lbs?$' { return @{ K = 'w'; Q = $q * 0.453592 } }
      '^ml$'  { return @{ K = 'v'; Q = $q / 1000 } }
      '^l$'   { return @{ K = 'v'; Q = $q } }
    }
  }
  if ($n -match "\b(\d+)\s*(?:'s\b|pk\b|pack\b|ct\b|count\b|rolls?\b)") { return @{ K = 'c'; Q = & $num $Matches[1] } }
  if ($n -match '\bdozen\b') { return @{ K = 'c'; Q = 12 } }
  return $null
}

# Comparable unit price: per kg for anything weighed, per litre, or per piece.
function Get-Compare($It) {
  if ($It.Unit -eq 'lb' -and $It.PerLb) { return @{ K = 'w'; V = $It.PerLb * 2.20462 } }
  # "Tuna 170 g OR salmon 80 g": we can't tell which size goes with which product.
  if ($It.Name -match '\bor\b') { return @{ K = ''; V = $It.Eff } }
  $size = Get-Size $It.Name
  if ($size -and $size.Q -gt 0) {
    $ok = ($size.K -ne 'w' -or ($size.Q -ge 0.01 -and $size.Q -le 50)) -and ($size.K -ne 'v' -or $size.Q -le 30) -and ($size.K -ne 'c' -or $size.Q -le 200)
    if ($ok) { return @{ K = $size.K; V = $It.Eff / $size.Q } }
  }
  return @{ K = ''; V = $It.Eff }
}

# Flyer items don't come with a reliable department, so sort them into aisles by
# keywords in the name. Order matters: earlier rules win ("chicken noodle soup" is Pantry).
$DeptRules = @(
  # Meat substitutes first, so "plant-based burgers" never land in Meat & Poultry
  # (margarine is plant-based too, but it belongs with butter).
  @('Dairy & Eggs',    '\b(margarine)\b'),
  @('Plant-Based',     '\b(plant[- ]?based|plant protein|meatless|meat[- ]free|meat alternatives?|simulated meat|vegan|vegetarian|beyond meat|impossible|gardein|yves|lightlife|tofurky|field roast|sol cuisine|daring|very good butchers|seitan|textured vegetable protein|tvp|soy protein|veggie (burgers?|patties|dogs?|ground|crumbles|sausages?|nuggets|strips)|aloo tikki)\b'),
  @('Snacks & Candy',  '\b(york|peppermint patties|werther.?s|pumpkin seeds|sunflower seeds)\b'),
  @('Pantry',          '\b(pickled|pickles?)\b'),
  @('Pet',             '\b(dogs?|cats?|pets?|puppy|kitten|litter|kibble|purina|whiskas|meow mix|temptations|milk-bone|pedigree|friskies|iams)\b'),
  @('Baby',            '\b(diapers?|huggies|pampers|baby|babies|infant|toddler|similac|enfamil|gerber)\b'),
  @('Household',       '\b(degreaser|bath tissue|dish tabs|auto dish|wipes|lawn and leaf bags|gain|palmolive|savvy|fabric rinse|detergent|laundry|tide|downy|bounce|bounty|sponge ?towels|paper towels?|bathroom tissue|toilet paper|facial tissues?|kleenex|garbage bags?|trash bags?|foil|plastic wrap|cleaners?|cleaning|bleach|clorox|lysol|febreze|dish ?soap|dishwasher|cascade|sponges?|batter(y|ies)|duracell|energizer|light bulbs?|ziploc|napkins|charcoal|air freshener|swiffer|windex|fabric softener|dryer sheets)\b'),
  @('Health & Beauty', '\b(shampoo|conditioner|deodorant|antiperspirant|toothpaste|toothbrush(es)?|mouthwash|floss|razors?|shaving|vitamins?|supplements?|lotion|moisturi[sz]er|cosmetics?|makeup|mascara|lipstick|nail|hair|skin ?care|sunscreen|tylenol|advil|cold & flu|allergy|tampons?|body wash|hand soap|bar soap|cleanser|serum|fragrance|perfume|cologne|colgate|crest|gillette|olay|nivea|cetaphil|aveeno|neutrogena|old spice|speed ?stick|pantene|garnier|maybelline|covergirl|revlon|band-aid|medicine|pain relief|eye drops|aspirin|aleve|alevex|vicks|polysporin|robax\w*|neocitran|cough|flu|cold relief|thermometers?|sinus|crutches|oximeter|zonnic|epsom|eau de (toilette|parfum)|parfum|align|carex|liners|pads|tums|benylin|buckley.?s|nicorette|reactine|claritin|antacid|lozenges|first aid|option\+|beauty|body mist|brush set|gift sets?|lip|lanc.me|rabanne|protein powder|collagen|boost|ensure|pediasure|nutrition shakes|voltaren|laxative|lens solution|needles|sitz|bed pan|docosanol|wake-ups|curling wand|trimmer|massager)\b'),
  @('Home & General',  '\b(cutting boards?|knives|dinnerware|drinkware|serveware|cookware|frying pans?|pots|candles?|tealights|puzzles?|toys?|lego|games?|bouquets?|roses|flowers|potted|planters?|hyacinth|venus fly trap|mums|advent calendars?|gift cards?|decor|blankets?|socks|storage|containers|mugs|prints|photos?|prep station|tv|mattress|towels?|tote|air fryer|humidifier|comforter|bakeware|plush|figures|costumes?|beanie|suit set|resistance band|cutlery|compartment tray|karahi|tawa)\b'),
  @('Pantry',          '\b(hamburger helper|entr.es|dinners|mixes|flours?|all-bran|dough|appetizers|alfredo|fettuccine|ravioli|gnocchi|spaghettios|taco kits?|biscuit mix|kimchi?|kraut|soups?|sauces?|broth|seasonings?|dressings?|noodles?|ramen|peanut butter|nutella|spreads?|ketchup|mustard|mayo|mayonnaise|salsa|kraft dinner|macaroni|mac & cheese|gravy|bouillon)\b'),
  @('Frozen',          '\b(frozen|ice cream|gelato|sorbet|popsicles?|freezies|pizzas?|fries|waffles|eggo|pogo|perogies|pierogies|dumplings|nuggets|hungry-man|lean cuisine|mccain)\b'),
  @('Beverages',       '\b(juices?|pop|soda|cola|coke|coca-cola|pepsi|sprite|7up|ginger ale|water|sparkling|coffee|k-cups?|tea|drinks?|beverages?|gatorade|powerade|red bull|monster|kombucha|lemonade|beer|wine|cider|lager|smoothies?|almond milk|oat milk|soy milk|ale|sauvignon|cabernet|merlot|chardonnay|pinot|riesling|vodka|whisky|rum|gin|nectar|punch|smartwater|seltzer|coolers?|radler)\b'),
  @('Snacks & Candy',  '\b(chips|chocolates?|candy|candies|cookies?|crackers?|popcorn|pretzels?|granola|bars|gum|snacks?|doritos|cheetos|lays|ruffles|pringles|oreo|nuts|almonds|cashews|peanuts|trail mix|gummies|gummy|licorice|jujubes|treats|fun size|kit ?kat|reese|twizzlers|rice cakes|pistachios|veggie straws|puffies|crunchers|kisses|swiss sticks|currants|raisins|dried fruit|caramels|wafers|lollipops|party mix|treat bags|cello bags|mithai|hershey|cadbury|nestl.|brookside|uncrustables|pepperettes|jell-o)\b'),
  @('Bakery',          '\b(bread|breads|bagels?|buns?|muffins?|croissants?|tortillas?|wraps|pitas?|naan|cakes?|pies?|donuts?|doughnuts|baguettes?|rolls|loaf|danish|cupcakes|brownies|tarts?|pastr(y|ies)|dempster.?s|wonder|panettone|biscuits)\b'),
  @('Dairy & Eggs',    '\b(milk|cheese|cheddar|mozzarella|parmesan|feta|brie|yogou?rt|yoghurt|butter|cream|eggs?|margarine|kefir|cottage|creamer|lactantia|neilson|natrel|gay lea|becel|babybel|activia|oikos|iogo|yop|tofu|paneer|dahi|ghee|singles|rasmalai|parmigiano|black diamond|slices)\b'),
  @('Deli',            '\b(deli|ham|salami|bologna|pepperoni|prosciutto|capicollo|mortadella|hummus|dips?|wieners|hot dogs?|sandwiches?|sushi|rotisserie|prepared|ready to (eat|serve)|meal kits?|olives|lunch kits?|lunchables|platters?)\b'),
  @('Seafood',         '\b(salmon|shrimp|prawns|fish|tilapia|cod|tuna|trout|crab|lobster|haddock|halibut|scallops?|seafood|mussels|clams|sole|pollock|basa|sardines|high liner)\b'),
  @('Meat & Poultry',  '\b(chicken|beef|pork|steaks?|turkey|bacon|sausages?|lamb|ribs|roasts?|ground|chops|wings|drumsticks?|thighs?|breasts?|veal|meats?|burgers?|patties|tenderloin|sirloin|striploin|brisket|loin|legs|halal|kebabs?|kabobs?|meatballs|goat|stewing)\b'),
  @('Produce',         '\b(apples?|bananas?|oranges?|grapes?|berries|strawberr(y|ies)|blueberr(y|ies)|raspberr(y|ies)|blackberr(y|ies)|lettuce|tomato(es)?|potato(es)?|onions?|carrots?|peppers?|cucumbers?|broccoli|cauliflower|celery|avocados?|lemons?|limes?|mangos?|mangoes|pears?|peach(es)?|plums?|melons?|cantaloupe|watermelon|squash|pumpkins?|mushrooms?|spinach|kale|salads?|cabbage|corn|garlic|fruits?|vegetables?|veggies|produce|cherries|kiwis?|pineapples?|clementines?|mandarins?|zucchini|asparagus|green beans|herbs|cilantro|parsley|ginger|beets|radish(es)?|yams?|grapefruit|pomegranates?|eggplant|leeks?|sprouts|papayas?|guavas?|plantains?|dates|figs|okra|bok choy|coconuts?|cranberries)\b'),
  @('Pantry',          '\b(rice|pasta|spaghetti|penne|cereal|flour|sugar|oil|vinegar|spices?|canned|beans|lentils|chickpeas|jam|jelly|honey|syrup|oatmeal|oats|baking|cake mix|condiments?|pickles|relish|couscous|quinoa)\b')
)
function Get-Department($It) {
  $n = $It.Name.ToLowerInvariant()
  foreach ($r in $DeptRules) { if ($n -match $r[1]) { return $r[0] } }
  $c = [string]$It.Category
  if ($c -match 'Health|Beauty|Personal|Medic') { return 'Health & Beauty' }
  if ($c -match 'Pet') { return 'Pet' }
  if ($c -match 'Baby') { return 'Baby' }
  if ($c -match 'Home|Household|Clean') { return 'Household' }
  if ($c -match 'Food') { return 'Pantry' }
  return 'Other'
}

$TextInfo = $Inv.TextInfo
function Get-Brands($It) {
  if (-not $It.Brand) { return @() }
  return @(([string]$It.Brand -split '\|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'Unknown' } |
    ForEach-Object { $TextInfo.ToTitleCase($_.ToLowerInvariant()) } | Select-Object -Unique)
}

# ---------------------------------------------------------------- 6. report: data + app\template.html

function Format-Ymd($Text) {
  $d = ConvertTo-Date $Text
  if ($d) { return $d.ToString('yyyy-MM-dd', $Inv) }
  return ''
}

# History keeps everything, but the report only carries flyers that haven't ended.
$itemList = @($Items.Values | Where-Object { $to = ConvertTo-Date $_.ValidTo; (-not $to) -or $to -ge $Now })
$liveCount = @{}
foreach ($it in $itemList) { $liveCount[$it.FlyerId] = 1 + [int]$liveCount[$it.FlyerId] }

$deptOf = @{}
foreach ($it in $itemList) { $deptOf[$it.ItemId] = Get-Department $it }

$itemData = @(foreach ($it in $itemList) {
  $p = Format-Price $it
  $cmp = Get-Compare $it
  $cnd = Get-Conditions $it
  $story = ''
  if ($it.SaleStory -and $it.SaleStory -notmatch '^\d+%?$') { $story = $it.SaleStory }
  $trend = Get-ItemTrend $it
  $was = ''
  if ($it.OriginalPrice -and $it.OriginalPrice -gt $it.Price) { $was = '$' + (Format-Num $it.OriginalPrice) }
  $end = Format-Ymd $it.ValidTo; if (-not $end) { $end = '9999-12-31' }
  @{
    id   = $it.ItemId
    f    = $it.FlyerId
    m    = $it.Merchant
    n    = $it.Name
    b    = @(Get-Brands $it)
    d    = $deptOf[$it.ItemId]
    cw   = $cmp.K
    cv   = [math]::Round([double]$cmp.V, 3)
    tp   = [math]::Round([double]$it.Eff, 2)
    mp   = $cnd.Mp
    cd   = @($cnd.Cond)
    p    = $p.Main
    ps   = $p.Sub
    op   = $was
    u    = $(if ($it.Unit -eq 'lb') { 'lb' } else { '' })
    v    = [math]::Round([double](Get-Value $it), 2)
    s    = $it.SavingsPct
    st   = $story
    sd   = (Format-Ymd $it.ValidFrom)
    e    = $end
    ar   = @($it.Areas)
    i    = ([string]$it.Image -replace '^http:', 'https:')
    tr   = $trend.Text
    tc   = $trend.Css
    x    = [int]$it.Left
    y    = [int]$it.Top
    hist = @(Get-PriceHistory $it)
  }
})

$pharmacies = @($Config.extraMerchants)
$flyerData = @(foreach ($f in $Flyers.Values) {
  if (-not $liveCount.ContainsKey($f.Id)) { continue }
  $end = Format-Ymd $f.ValidTo; if (-not $end) { $end = '9999-12-31' }
  @{
    id = $f.Id
    m  = $f.Merchant
    lg = ([string]$f.Logo -replace '^http:', 'https:')
    t  = $f.Title
    th = ([string]$f.Thumb -replace '^http:', 'https:')
    sd = (Format-Ymd $f.ValidFrom)
    e  = $end
    ar = @($f.Areas)
    k  = $(if ($pharmacies -contains $f.Merchant) { 'Pharmacy' } else { 'Groceries' })
    c  = $liveCount[$f.Id]
  }
})

# Watchlist matches, cheapest first (weighed items compared per lb come first).
$watchData = @(foreach ($w in $Watch) {
  $hits = @($itemList | Where-Object { $_.WatchTerms.Contains($w.Term) } |
    Sort-Object @{ Expression = { if ($_.Unit -eq 'lb') { 0 } else { 1 } } }, @{ Expression = { Get-Value $_ } })
  @{ t = $w.Term; ids = @($hits | ForEach-Object { $_.ItemId }) }
})

# Product varieties for the Top Picks page. Each variety only matches items in its own
# aisle, so "apples" skips apple juice and apple pie. Watchlist terms are starred, and any
# watchlist term with no variety of its own is added (matching any aisle).
$byAisle = @{}
foreach ($it in $itemList) {
  $d = $deptOf[$it.ItemId]
  if (-not $byAisle.ContainsKey($d)) { $byAisle[$d] = New-Object 'Collections.Generic.List[object]' }
  $byAisle[$d].Add($it)
}
$watchByTerm = @{}
foreach ($w in $Watch) { $watchByTerm[$w.Term.ToLowerInvariant()] = $w }
$varieties = New-Object 'Collections.Generic.List[object]'
$lastSection = ''
$groupForAisle = @{}   # last section's groups, used to place leftover watchlist terms
foreach ($sec in @($Config.picks)) {
  $lastSection = [string]$sec.section
  $groupForAisle = @{}
  foreach ($grp in @($sec.groups)) {
    $groupForAisle[[string]$grp.aisle] = [string]$grp.name
    foreach ($entry in @($grp.items)) {
      $term = $(if ($entry -is [string]) { $entry } else { [string]$entry.term })
      $aisle = [string]$grp.aisle
      if ($entry -isnot [string] -and $entry.aisle) { $aisle = [string]$entry.aisle; $groupForAisle[$aisle] = [string]$grp.name }
      $extra = @()
      if ($watchByTerm.ContainsKey($term.ToLowerInvariant())) { $extra = $watchByTerm[$term.ToLowerInvariant()].Exclude }
      $m = New-Matcher $entry $extra
      $m | Add-Member -NotePropertyName Aisle -NotePropertyValue $aisle
      $m | Add-Member -NotePropertyName Section -NotePropertyValue ([string]$sec.section)
      $m | Add-Member -NotePropertyName Group -NotePropertyValue ([string]$grp.name)
      $varieties.Add($m)
    }
  }
}
foreach ($w in $Watch) {
  if (-not @($varieties | Where-Object { $_.Term -ieq $w.Term }).Count) {
    $m = New-Matcher @{ term = $w.Term; exclude = $w.Exclude }
    $m | Add-Member -NotePropertyName Aisle -NotePropertyValue $null
    $m | Add-Member -NotePropertyName Section -NotePropertyValue $lastSection
    $m | Add-Member -NotePropertyName Group -NotePropertyValue $null
    $varieties.Add($m)
  }
}
$varietyData = @(foreach ($v in $varieties) {
  $pool = $itemList
  if ($v.Aisle) { $pool = $byAisle[$v.Aisle] }
  if (-not $pool) { continue }
  $ids = @(foreach ($it in $pool) { if (Test-WatchMatch $v $it.Name) { $it.ItemId } })
  if ($ids.Count -eq 0) { continue }
  $aisle = $v.Aisle
  if (-not $aisle) { $aisle = ($ids | ForEach-Object { $deptOf[$_] } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name }
  $group = $v.Group
  if (-not $group) { $group = $(if ($groupForAisle.ContainsKey($aisle)) { $groupForAisle[$aisle] } else { 'Other' }) }
  @{ t = $v.Term; a = $aisle; s = $v.Section; g = $group; l = $watchByTerm.ContainsKey($v.Term.ToLowerInvariant()); ids = $ids }
})
Write-Log "Matched $($varietyData.Count) product varieties"

$trackingSince = $Now.ToString('yyyy-MM-dd', $Inv)
if ($History.Count -gt 0) { $trackingSince = ([string]$History[0].RunId).Substring(0, 10) }

# ---------------------------------------------------------------- 7. store locations (for distances and the map)

function Get-DistanceKm($LatA, $LonA, $LatB, $LonB) {
  $r = [math]::PI / 180
  $a = [math]::Pow([math]::Sin(($LatB - $LatA) * $r / 2), 2) + [math]::Cos($LatA * $r) * [math]::Cos($LatB * $r) * [math]::Pow([math]::Sin(($LonB - $LonA) * $r / 2), 2)
  return 6371 * 2 * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a))
}

# Grocery and pharmacy locations from OpenStreetMap around the configured areas, Canada only,
# matched to flyer stores with the storeMatch patterns. Uses curl.exe: the Overpass servers
# need a newer TLS setup than Windows PowerShell 5.1 offers.
function Get-Stores {
  $rules = @($Config.storeMatch.PSObject.Properties | ForEach-Object { @{ m = $_.Name; rx = [string]$_.Value } })
  $pts = @($Config.areas | Where-Object { $_.lat })
  $lat = ($pts | Measure-Object -Property lat -Average).Average
  $lon = ($pts | Measure-Object -Property lon -Average).Average
  $radius = [int](1000 * (45 + (($pts | ForEach-Object { Get-DistanceKm $lat $lon $_.lat $_.lon }) | Measure-Object -Maximum).Maximum))
  $rx = ($rules | ForEach-Object { $_.rx }) -join '|'
  $around = "(area.ca)(around:$radius,$($lat.ToString($Inv)),$($lon.ToString($Inv)))"
  $query = "[out:json][timeout:120];area[`"ISO3166-1`"=`"CA`"][admin_level=2]->.ca;(" +
    "nwr[`"shop`"][`"name`"~`"$rx`",i]$around;nwr[`"shop`"][`"brand`"~`"$rx`",i]$around;nwr[`"amenity`"=`"pharmacy`"][`"name`"~`"$rx`",i]$around;);out center tags;"
  $body = Join-Path $env:TEMP 'deals-overpass.txt'
  [IO.File]::WriteAllText($body, 'data=' + [uri]::EscapeDataString($query))
  foreach ($server in 'https://overpass-api.de/api/interpreter', 'https://overpass.kumi.systems/api/interpreter') {
    $raw = & curl.exe -s --max-time 150 -A 'WindsorEssexDealFinder/1.0' --data "@$body" $server
    try { $j = ($raw -join "`n") | ConvertFrom-Json } catch { $j = $null }
    if ($j -and $j.elements) { break }
  }
  if (-not $j -or -not $j.elements) { return $null }
  $seen = @{}
  $out = foreach ($e in $j.elements) {
    $t = $e.tags
    $name = [string]$t.name; $brand = [string]$t.brand
    $m = $null
    foreach ($r in $rules) { if ($name -match "(?i)$($r.rx)" -or ($brand -and $brand -match "(?i)$($r.rx)")) { $m = $r.m; break } }
    if (-not $m) { continue }
    $la = if ($e.lat) { [double]$e.lat } else { [double]$e.center.lat }
    $lo = if ($e.lon) { [double]$e.lon } else { [double]$e.center.lon }
    $key = '{0}|{1:N3}|{2:N3}' -f $m, $la, $lo
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = 1
    $addr = (@(("$($t.'addr:housenumber') $($t.'addr:street')").Trim(), [string]$t.'addr:city') | Where-Object { $_ }) -join ', '
    @{ m = $m; n = $(if ($name) { $name } else { $brand }); a = $addr; lat = [math]::Round($la, 5); lon = [math]::Round($lo, 5) }
  }
  return @($out)
}

$StoresPath = Join-Path $DataDir 'stores.json'
if (-not $ReportOnly -or -not (Test-Path $StoresPath)) {
  $found = Get-Stores
  if ($found) {
    ($found | ConvertTo-Json -Compress -Depth 3) | Set-Content -Path $StoresPath -Encoding UTF8
    Write-Log "Store locations: $($found.Count) stores for $(@($found | ForEach-Object { $_.m } | Select-Object -Unique).Count) flyer chains"
  } else { Write-Log 'Store locations unavailable this run; keeping the last saved list.' }
}
$stores = @()
# (ConvertFrom-Json hands back the whole array as one object in PS 5.1, so unroll it.)
if (Test-Path $StoresPath) { $stores = @(([IO.File]::ReadAllText($StoresPath) | ConvertFrom-Json) | ForEach-Object { $_ }) }

$data = @{
  meta = @{
    home          = $HomeArea
    areas         = @($Config.areas | ForEach-Object { $_.name })
    updated       = $Now.ToString('ddd MMM d, h:mm tt', $Inv)
    historyWeeks  = $HistoryWeeks
    failures      = $script:Failures
    trackingSince = $trackingSince
    priority      = @($Config.aislePriority | ForEach-Object { , @($_) })
    maxPickPrice  = $(if ($Config.maxPickPrice) { [double]$Config.maxPickPrice } else { 35 })
    myMemberships = @($Config.myMemberships | Where-Object { $_ })
    notCovered    = 'Not included: Remark Fresh Markets (no online flyer) and stores that do not use Flipp.'
    areaPoints    = @($Config.areas | Where-Object { $_.lat } | ForEach-Object { @{ name = $_.name; lat = [double]$_.lat; lon = [double]$_.lon } })
    defaultLoc    = $Config.defaultLocation
  }
  stores = $stores
  flyers = $flyerData
  items     = $itemData
  watch     = $watchData
  varieties = $varietyData
}
$json = ($data | ConvertTo-Json -Compress -Depth 6) -replace '</', '<\/'
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'template.html'), [Text.Encoding]::UTF8)
$html = $template.Replace('__DATA__', $json)

$utf8 = New-Object Text.UTF8Encoding $false
$latest = Join-Path $Root 'latest-deals.html'
$dated  = Join-Path $ReportDir ('deals-' + $Now.ToString('yyyy-MM-dd', $Inv) + '.html')
[IO.File]::WriteAllText($latest, $html, $utf8)
[IO.File]::WriteAllText($dated,  $html, $utf8)
Write-Log "Report written: $latest ($($itemData.Count) items, $($flyerData.Count) flyers)"

if ($Open -or $Config.openReportAfterRun) { Start-Process $latest }
