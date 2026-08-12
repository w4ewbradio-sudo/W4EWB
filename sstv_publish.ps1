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
$ThumbSize  = 360                         # square thumbs

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
  & magick "$($bmp.FullName)" -auto-orient -strip -thumbnail "${ThumbSize}x${ThumbSize}^" -gravity center -extent "${ThumbSize}x${ThumbSize}" -quality 82 "$thumbOut"

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

# ---- rebuild gallery HTML (order by filename timestamp so it matches the Pi's builds) ----
$items = Get-ChildItem $FullDir -Filter "*.jpg" -File |
  ForEach-Object { $_ | Add-Member -NotePropertyName Stamp -NotePropertyValue (Get-StampFromName $_.Name $_.LastWriteTime) -PassThru } |
  Sort-Object Stamp -Descending

# Build list of unique months (for navigation)
$monthsHash = @{}
foreach ($it in $items) {
  $monthKey = $it.Stamp.ToString("yyyy-MM")
  if (-not $monthsHash.ContainsKey($monthKey)) {
    $monthsHash[$monthKey] = $it.Stamp
  }
}
$sortedMonths = $monthsHash.Keys | Sort-Object -Descending

$head = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>W4EWB's SSTV RX Gallery</title>
  <link rel="stylesheet" href="/lcars.css">
  <style>
    .month-nav{display:flex;flex-wrap:wrap;gap:6px;padding:6px 2px 12px}
    .month-btn{padding:6px 15px;background:var(--peri);color:#000;border:none;border-radius:16px;font-family:inherit;font-weight:600;text-transform:uppercase;font-size:12px;letter-spacing:.05em;cursor:pointer}
    .month-btn:hover{background:var(--ice)} .month-btn.active{background:var(--gold)}
    .stats{color:var(--dim);text-transform:uppercase;font-size:12px;letter-spacing:.12em;padding:0 4px 10px}
    .stats span{color:var(--gold)}
    .grid{grid-template-columns:repeat(auto-fill,minmax(190px,1fr))}
    .card a{display:block;color:inherit} .card img{height:auto;aspect-ratio:1}
    .card .meta{padding:9px 12px}
    .card .filename{font-size:12px;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-transform:uppercase}
    .card .timestamp{font-size:12px;color:var(--dim)} .card.hidden{display:none}
    .no-results{grid-column:1/-1;color:var(--dim);text-transform:uppercase;letter-spacing:.1em;text-align:center;padding:50px 20px}
    #load-more-btn{background:var(--orange);color:#000;border:none;padding:12px 34px;border-radius:22px;font-family:inherit;font-weight:700;text-transform:uppercase;letter-spacing:.08em;font-size:15px;cursor:pointer}
  </style>
</head>
<body>
  <div class="lcars">
    <div class="rail">
      <div class="cap"></div>
      <a class="blk o" href="/">&#9666; W4EWB<small>Home</small></a>
      <div class="blk p">SSTV<small>RX</small></div>
      <div class="blk l">FT-710<small>HF</small></div>
      <a class="blk i" href="latest.jpg">Latest<small>View RX</small></a>
      <div class="railfill"></div>
      <a class="blk g" href="https://www.qrz.com/db/W4EWB">QRZ<small>W4EWB</small></a>
    </div>
    <div class="col">
      <div class="hdr"><span class="title">SSTV RX Gallery</span><span class="sub">W4EWB &middot; FT-710</span></div>
      <div class="strip">Slow-scan TV received on the Yaesu FT-710 &middot; Louisville KY &middot; auto-updated via MMSSTV</div>
      <nav class="month-nav">
      <button class="month-btn active" data-month="all">All Images</button>
"@

# Generate month buttons
$monthButtons = foreach ($m in $sortedMonths) {
  $dt = [datetime]::ParseExact($m, "yyyy-MM", $null)
  $label = $dt.ToString("MMM yyyy").ToUpper()
  "      <button class=`"month-btn`" data-month=`"$m`">$label</button>"
}

$navClose = @"
    </nav>
      <div class="stats">Showing <span id="visible-count">50</span> of <span id="total-count">$($items.Count)</span> images</div>
      <div class="content">
      <div class="grid" id="gallery">
"@

# Generate cards with data-month attribute
$cards = foreach ($it in $items) {
  $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
  $thumb = "thumbs/$base.jpg"
  $full  = "full/$($it.Name)"
  $stamp = $it.Stamp.ToString("yyyy-MM-dd HH:mm")
  $monthData = $it.Stamp.ToString("yyyy-MM")
@"
      <div class="card" data-month="$monthData">
        <a href="$full" target="_blank">
          <img src="$thumb" loading="lazy" alt="SSTV image received $stamp">
          <div class="meta">
            <div class="filename">$($it.Name)</div>
            <div class="timestamp">$stamp</div>
          </div>
        </a>
      </div>
"@
}

$foot = @"
        <div class="no-results" id="no-results" style="display:none;">No images found for this month.</div>
      </div>
      <div id="load-more-container" style="text-align:center;padding:30px 20px;display:none;">
        <button id="load-more-btn">Load More Images</button>
        <p style="color:var(--dim);font-size:12px;margin-top:8px;text-transform:uppercase;letter-spacing:.1em">Or just keep scrolling</p>
      </div>
      </div>
      <div class="foot">73 de W4EWB &middot; SSTV RX &middot; auto-updated via MMSSTV</div>
    </div>
  </div>
  
  <script>
    (function() {
      const BATCH_SIZE = 50;
      const buttons = document.querySelectorAll('.month-btn');
      const allCards = Array.from(document.querySelectorAll('.card'));
      const countEl = document.getElementById('visible-count');
      const totalEl = document.getElementById('total-count');
      const noResults = document.getElementById('no-results');
      const loadMoreBtn = document.getElementById('load-more-btn');
      const loadMoreContainer = document.getElementById('load-more-container');
      
      let currentFilter = 'all';
      let loadedCount = 0;
      
      // Get cards matching current filter
      function getFilteredCards() {
        if (currentFilter === 'all') return allCards;
        return allCards.filter(c => c.getAttribute('data-month') === currentFilter);
      }
      
      // Hide all cards initially
      function hideAllCards() {
        allCards.forEach(card => {
          card.classList.add('hidden');
          card.style.display = 'none';
        });
      }
      
      // Show next batch of cards
      function showNextBatch() {
        const filtered = getFilteredCards();
        const end = Math.min(loadedCount + BATCH_SIZE, filtered.length);
        
        for (let i = loadedCount; i < end; i++) {
          filtered[i].classList.remove('hidden');
          filtered[i].style.display = '';
        }
        
        loadedCount = end;
        countEl.textContent = loadedCount;
        
        // Show/hide load more button
        if (loadedCount >= filtered.length) {
          loadMoreContainer.style.display = 'none';
        } else {
          loadMoreContainer.style.display = 'block';
        }
        
        noResults.style.display = loadedCount === 0 ? 'block' : 'none';
      }
      
      // Filter by month
      function filterByMonth(month) {
        currentFilter = month;
        loadedCount = 0;
        
        // Hide all cards first
        hideAllCards();
        
        // Update total count for this filter
        const filtered = getFilteredCards();
        totalEl.textContent = filtered.length;
        
        // Show first batch
        showNextBatch();
      }
      
      // Initialize
      hideAllCards();
      totalEl.textContent = allCards.length;
      showNextBatch();
      
      // Month button clicks
      buttons.forEach(btn => {
        btn.addEventListener('click', function() {
          buttons.forEach(b => b.classList.remove('active'));
          this.classList.add('active');
          filterByMonth(this.getAttribute('data-month'));
        });
      });
      
      // Load more button click
      loadMoreBtn.addEventListener('click', showNextBatch);
      
      // Infinite scroll - load more when near bottom
      window.addEventListener('scroll', function() {
        if ((window.innerHeight + window.scrollY) >= document.body.offsetHeight - 500) {
          const filtered = getFilteredCards();
          if (loadedCount < filtered.length) {
            showNextBatch();
          }
        }
      });
    })();
  </script>
</body>
</html>
"@

# Combine all parts
$htmlContent = $head + "`n" + ($monthButtons -join "`n") + "`n" + $navClose + "`n" + ($cards -join "`n") + "`n" + $foot
$htmlContent | Set-Content -Encoding UTF8 $IndexFile

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
