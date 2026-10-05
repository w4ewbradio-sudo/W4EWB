# =========================
# SSTV Auto-Publish (MMSTV -> GitHub Pages)
# Repo:   C:\w4ewb\W4EWB
# Source: C:\Ham\MMSSTV\History (BMP files like Hist1.bmp)
# Output: repo\sstv\rx\full + thumbs + latest.jpg + index.html
# =========================

# ---- SETTINGS (edit if needed) ----
$RepoRoot   = "C:\w4ewb\W4EWB"
$MmsstvDir  = "C:\Ham\MMSSTV\History"     # MMSTV BMP history folder
$MaxImages  = 10000                        # rolling gallery size (effectively unlimited)
$ThumbSize  = 240                         # square thumbs (240px, downscaled: v2 2026-10-05)

$RxDir      = Join-Path $RepoRoot "sstv\rx"
$FullDir    = Join-Path $RxDir "full"
$ThumbDir   = Join-Path $RxDir "thumbs"
$IndexFile  = Join-Path $RxDir "index.html"
$LatestFile = Join-Path $RxDir "latest.jpg"
$StateFile  = Join-Path $RxDir ".state.json"

# ---- sanity ----
foreach ($p in @($RepoRoot, $RxDir, $FullDir, $ThumbDir, $MmsstvDir)) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

# ---- require ImageMagick ----
$magick = (Get-Command magick -ErrorAction SilentlyContinue)
if (-not $magick) {
  Write-Host "ERROR: ImageMagick not found. Install ImageMagick so 'magick' works in PowerShell."
  exit 1
}

# ---- extract capture time from the filename so ordering is stable across machines.
#      Matches MMSSTV '{stamp}_Hist#' and the Pi's QSSTV '{mode}_{stamp}' names.
#      (git does not preserve file mtimes, so the Pi can't rely on LastWriteTime.) ----
function Get-StampFromName {
  param($Name, $Fallback)
  if ($Name -match '(\d{8})_(\d{6})') {
    try { return [datetime]::ParseExact(($matches[1] + $matches[2]), 'yyyyMMddHHmmss', $null) } catch {}
  }
  return $Fallback
}

# ---- pull first: the Pi also pushes captures into sstv/rx, so sync before we build/push ----
Push-Location $RepoRoot
try { git pull --rebase --autostash 2>&1 | Out-Null } catch {}
Pop-Location

# ---- load state (tracks already-published BMP writes) ----
$state = @{ processed = @{} }

if (Test-Path $StateFile) {
  try {
    $raw = Get-Content $StateFile -Raw
    $loaded = $raw | ConvertFrom-Json

    # Normalize processed -> hashtable
    $processed = @{}
    if ($loaded -and $loaded.processed) {
      foreach ($p in $loaded.processed.PSObject.Properties) {
        $processed[$p.Name] = [bool]$p.Value
      }
    }
    $state = @{ processed = $processed }
  } catch {
    # If state is corrupt, start fresh
    $state = @{ processed = @{} }
  }
}

# ---- find candidate BMPs ----
$bmps = Get-ChildItem $MmsstvDir -Filter "Hist*.bmp" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime

$publishedCount = 0

foreach ($bmp in $bmps) {
  $key = "$($bmp.Name)|$($bmp.LastWriteTimeUtc.Ticks)|$($bmp.Length)"
  if ($state.processed.ContainsKey($key)) { continue }

  # Create a unique filename in /full so overwrites never happen
  $stamp = $bmp.LastWriteTime.ToString("yyyyMMdd_HHmmss")
  $base  = "{0}_{1}" -f $stamp, ($bmp.BaseName)
  $jpgName = "$base.jpg"

  $fullOut  = Join-Path $FullDir  $jpgName
  $thumbOut = Join-Path $ThumbDir "$base.jpg"

  # Convert BMP -> JPG (full)
  & magick "$($bmp.FullName)" -auto-orient -strip -quality 85 "$fullOut"

  # Create square thumbnail
  & magick "$($bmp.FullName)" -auto-orient -strip -thumbnail "${ThumbSize}x${ThumbSize}^" -gravity center -extent "${ThumbSize}x${ThumbSize}" -quality 78 "$thumbOut"

  # Mark processed
  $state.processed[$key] = $true
  $publishedCount++
}

# ---- enforce rolling limit ----
$fullFiles = Get-ChildItem $FullDir -Filter "*.jpg" -File | Sort-Object LastWriteTime -Descending
if ($fullFiles.Count -gt $MaxImages) {
  $toRemove = $fullFiles | Select-Object -Skip $MaxImages
  foreach ($f in $toRemove) {
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $thumb = Join-Path $ThumbDir "$base.jpg"
    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    Remove-Item $thumb -Force -ErrorAction SilentlyContinue
  }
}

# ---- update latest.jpg to newest full image (by filename timestamp) ----
$latest = Get-ChildItem $FullDir -Filter "*.jpg" -File |
  ForEach-Object { $_ | Add-Member -NotePropertyName Stamp -NotePropertyValue (Get-StampFromName $_.Name $_.LastWriteTime) -PassThru } |
  Sort-Object Stamp -Descending | Select-Object -First 1
if ($latest) {
  & magick "$($latest.FullName)" -auto-orient -strip -quality 85 "$LatestFile"
}

# ---- one-time thumbnail regeneration (v2, 2026-10-05) ----
# The old 360px square thumbs were UPSCALED from 320x256 originals and came out
# BIGGER than the full images (median 58 KB vs 46 KB). v2 = 240px, q78 (~15 KB).
$ThumbMarker = Join-Path $RxDir ".thumbs-v2"
if (-not (Test-Path $ThumbMarker)) {
  foreach ($f in Get-ChildItem $FullDir -Filter "*.jpg" -File) {
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    & magick "$($f.FullName)" -auto-orient -strip -thumbnail "${ThumbSize}x${ThumbSize}^" -gravity center -extent "${ThumbSize}x${ThumbSize}" -quality 78 (Join-Path $ThumbDir "$base.jpg")
  }
  New-Item -ItemType File -Path $ThumbMarker -Force | Out-Null
}

# ---- rebuild gallery HTML (2026-10-05) ----
# index.html = the newest $Recent images + a month menu; every month gets its own
# page under m/. The old single page carried all ~2,900 cards (1.2 MB of HTML).
$Recent   = 240
$MonthDir = Join-Path $RxDir "m"
if (-not (Test-Path $MonthDir)) { New-Item -ItemType Directory -Force -Path $MonthDir | Out-Null }
$items = Get-ChildItem $FullDir -Filter "*.jpg" -File |
  ForEach-Object { $_ | Add-Member -NotePropertyName Stamp -NotePropertyValue (Get-StampFromName $_.Name $_.LastWriteTime) -PassThru } |
  Sort-Object Stamp -Descending
$byMonth = [ordered]@{}
foreach ($it in $items) {
  $k = $it.Stamp.ToString("yyyy-MM")
  if (-not $byMonth.Contains($k)) { $byMonth[$k] = New-Object System.Collections.ArrayList }
  [void]$byMonth[$k].Add($it)
}

$template = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>W4EWB &middot; {TITLE}</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/lcars.css">
  <style>
    .month-nav{display:flex;flex-wrap:wrap;gap:6px;padding:6px 2px 12px}
    .month-btn{padding:6px 15px;background:var(--peri);color:#000;border:none;border-radius:16px;font-family:inherit;font-weight:600;text-transform:uppercase;font-size:12px;letter-spacing:.08em;text-decoration:none;display:inline-block}
    .month-btn:hover{background:var(--ice)} .month-btn.active{background:var(--gold)}
    .stats{color:var(--dim);text-transform:uppercase;font-size:12px;letter-spacing:.12em;padding:0 4px 10px}
    .stats span{color:var(--gold)}
    .grid{grid-template-columns:repeat(auto-fill,minmax(170px,1fr))}
    .card a{display:block;color:inherit} .card img{width:100%;height:auto;aspect-ratio:1;object-fit:cover;background:#111}
    .card .meta{padding:9px 12px}
    .card .filename{font-size:12px;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-transform:uppercase}
    .card .timestamp{font-size:12px;color:var(--dim)}
    #load-more-btn{background:var(--orange);color:#000;border:none;padding:12px 34px;border-radius:22px;font-family:inherit;font-weight:700;text-transform:uppercase;letter-spacing:.1em;cursor:pointer}
  </style>
</head>
<body>
  <div class="lcars">
    <div class="rail">
      <div class="cap"></div>
      <a class="blk o" href="/">&#9666; W4EWB<small>Home</small></a>
      <a class="blk p" href="{PREFIX}./">SSTV<small>RX</small></a>
      <div class="blk l">FT-710<small>HF</small></div>
      <a class="blk i" href="{PREFIX}latest.jpg">Latest<small>View RX</small></a>
      <div class="railfill"></div>
      <a class="blk g" href="https://www.qrz.com/db/W4EWB">QRZ<small>W4EWB</small></a>
    </div>
    <div class="col">
      <div class="hdr"><span class="title">{TITLE}</span><span class="sub">{SUB}</span></div>
      <div class="strip">{STRIP}</div>
      <div class="content">
      <nav class="month-nav">
{NAV}
      </nav>
      <div class="stats">Showing <span id="visible-count">0</span> of <span id="total-count">{COUNT}</span> images{TOTALNOTE}</div>
      <div class="grid" id="gallery">
{CARDS}
      </div>
      <div id="load-more-container" style="text-align:center;padding:30px 20px;display:none;">
        <button id="load-more-btn">Load More Images</button>
        <p style="color:var(--dim);font-size:12px;margin-top:8px;text-transform:uppercase;letter-spacing:.1em">Or just keep scrolling</p>
      </div>
      </div>
      <div class="foot">73 de W4EWB &middot; SSTV RX &middot; FT-710/MMSSTV + hamsdr SDR ear + satellites</div>
    </div>
  </div>
  <script>
    (function(){var B=60,cards=Array.prototype.slice.call(document.querySelectorAll('.card')),n=0,
      c=document.getElementById('visible-count'),btn=document.getElementById('load-more-btn'),box=document.getElementById('load-more-container');
      cards.forEach(function(x){x.style.display='none'});
      function more(){var e=Math.min(n+B,cards.length);for(var i=n;i<e;i++)cards[i].style.display='';n=e;c.textContent=n;box.style.display=n>=cards.length?'none':'block'}
      more();btn.addEventListener('click',more);
      window.addEventListener('scroll',function(){if(window.innerHeight+window.scrollY>=document.body.offsetHeight-500&&n<cards.length)more()});
    })();
  </script>
</body>
</html>
'@

$StripText = "Slow-scan TV received at W4EWB &middot; Louisville KY &middot; Yaesu FT-710 (MMSSTV) + hamsdr SDR ear on the band's SSTV calling frequency + ISS &amp; satellite SSTV (hamsdr, Diamond X30A). Tap an image for full size."

function New-Cards($list, $prefix) {
  foreach ($it in $list) {
    $base  = [IO.Path]::GetFileNameWithoutExtension($it.Name)
    $stamp = $it.Stamp.ToString("yyyy-MM-dd HH:mm")
    '      <div class="card"><a href="' + $prefix + 'full/' + $it.Name + '" target="_blank"><img src="' + $prefix + 'thumbs/' + $base + '.jpg" loading="lazy" width="240" height="240" alt="SSTV image received ' + $stamp + '"><div class="meta"><div class="filename">' + $it.Name + '</div><div class="timestamp">' + $stamp + '</div></div></a></div>'
  }
}
function New-Nav($active, $prefix) {
  $out = @()
  $cls = if ($active -eq "latest") { "month-btn active" } else { "month-btn" }
  $out += '      <a class="' + $cls + '" href="' + $prefix + './">Latest</a>'
  foreach ($m in $byMonth.Keys) {
    $dt = [datetime]::ParseExact($m, "yyyy-MM", $null)
    $cls = if ($active -eq $m) { "month-btn active" } else { "month-btn" }
    $out += '      <a class="' + $cls + '" href="' + $prefix + 'm/' + $m + '.html">' + $dt.ToString("MMM yyyy").ToUpper() + ' <small>' + $byMonth[$m].Count + '</small></a>'
  }
  $out -join "`n"
}
function Write-IfChanged($path, $html) {
  $enc = New-Object System.Text.UTF8Encoding $false
  if ((Test-Path $path) -and ([IO.File]::ReadAllText($path) -eq $html)) { return }
  [IO.File]::WriteAllText($path, $html, $enc)
}
function New-Page($title, $sub, $nav, $cards, $count, $totalNote, $prefix) {
  $template.Replace('{TITLE}', $title).Replace('{SUB}', $sub).Replace('{STRIP}', $StripText).Replace('{NAV}', $nav).Replace('{CARDS}', (@($cards) -join "`n")).Replace('{COUNT}', "$count").Replace('{TOTALNOTE}', $totalNote).Replace('{PREFIX}', $prefix)
}

$recentItems = @($items | Select-Object -First $Recent)
Write-IfChanged $IndexFile (New-Page "SSTV RX Gallery" "W4EWB &middot; latest $($recentItems.Count) of $($items.Count)" (New-Nav "latest" "") (New-Cards $recentItems "") $recentItems.Count " &middot; $($items.Count) in the archive, by month above" "")
foreach ($m in $byMonth.Keys) {
  $dt = [datetime]::ParseExact($m, "yyyy-MM", $null)
  $list = @($byMonth[$m])
  Write-IfChanged (Join-Path $MonthDir "$m.html") (New-Page ("SSTV RX &middot; " + $dt.ToString("MMMM yyyy")) "W4EWB &middot; $($list.Count) images" (New-Nav $m "../") (New-Cards $list "../") $list.Count "" "../")
}
# month pages whose month no longer has images (rolling limit) go away
foreach ($old in Get-ChildItem $MonthDir -Filter "*.html" -File) {
  if (-not $byMonth.Contains([IO.Path]::GetFileNameWithoutExtension($old.Name))) { Remove-Item $old.FullName -Force }
}

# ---- save state ----
($state | ConvertTo-Json -Depth 5) | Set-Content -Encoding UTF8 $StateFile

# ---- git commit + push if anything changed ----
Set-Location $RepoRoot
git add . | Out-Null

# If no changes, exit quietly
$diff = git status --porcelain
if (-not $diff) {
  Write-Host "No changes to publish."
  exit 0
}

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
git commit -m "Auto SSTV RX update $ts" | Out-Null
git push | Out-Null

Write-Host "Published $publishedCount new image(s)."
