# =========================
# SSTV Auto-Publish (MMSTV -> GitHub Pages)
# Repo:   C:\w4ewb\W4EWB
# Source: C:\Ham\MMSSTV\History (BMP files like Hist1.bmp)
# Output: repo\sstv\rx\full + thumbs + latest.jpg + index.html
# =========================

# ---- SETTINGS (edit if needed) ----
$RepoRoot   = "C:\w4ewb\W4EWB"
$MmsstvDir  = "C:\Ham\MMSSTV\History"     # MMSTV BMP history folder
$MaxImages  = 200                         # rolling gallery size
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

# ---- update latest.jpg to newest full image ----
$latest = Get-ChildItem $FullDir -Filter "*.jpg" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) {
  & magick "$($latest.FullName)" -auto-orient -strip -quality 85 "$LatestFile"
}

# ---- rebuild gallery HTML ----
$items = Get-ChildItem $FullDir -Filter "*.jpg" -File | Sort-Object LastWriteTime -Descending

# Build list of unique months (for navigation)
$monthsHash = @{}
foreach ($it in $items) {
  $monthKey = $it.LastWriteTime.ToString("yyyy-MM")
  if (-not $monthsHash.ContainsKey($monthKey)) {
    $monthsHash[$monthKey] = $it.LastWriteTime
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
  <style>
    :root {
      --bg: #0d1117;
      --card-bg: #161b22;
      --border: #30363d;
      --text: #c9d1d9;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --accent-hover: #79b8ff;
    }
    * { box-sizing: border-box; }
    body {
      font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 20px;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    .container { max-width: 1400px; margin: 0 auto; }
    
    /* Header */
    .header { margin-bottom: 24px; }
    .header h1 {
      margin: 0 0 8px 0;
      font-size: 1.8rem;
      font-weight: 600;
      color: #fff;
    }
    .header .callsign { color: var(--accent); }
    .header .subtitle {
      color: var(--text-muted);
      font-size: 0.95rem;
      margin-bottom: 12px;
    }
    .header .subtitle a {
      color: var(--accent);
      text-decoration: none;
    }
    .header .subtitle a:hover { text-decoration: underline; }
    .header .latest-link {
      display: inline-block;
      margin-top: 8px;
      padding: 6px 14px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      color: var(--accent);
      text-decoration: none;
      font-size: 0.85rem;
    }
    .header .latest-link:hover {
      background: #21262d;
      border-color: var(--accent);
    }
    
    /* Month Navigation */
    .month-nav {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-bottom: 20px;
      padding-bottom: 16px;
      border-bottom: 1px solid var(--border);
    }
    .month-btn {
      padding: 6px 14px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 20px;
      color: var(--text-muted);
      font-size: 0.85rem;
      cursor: pointer;
      transition: all 0.15s ease;
    }
    .month-btn:hover {
      border-color: var(--accent);
      color: var(--text);
    }
    .month-btn.active {
      background: var(--accent);
      border-color: var(--accent);
      color: #0d1117;
      font-weight: 500;
    }
    
    /* Stats bar */
    .stats {
      font-size: 0.85rem;
      color: var(--text-muted);
      margin-bottom: 16px;
    }
    .stats span { color: var(--text); font-weight: 500; }
    
    /* Grid */
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
      gap: 16px;
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      overflow: hidden;
      transition: transform 0.15s ease, border-color 0.15s ease;
    }
    .card:hover {
      transform: translateY(-2px);
      border-color: var(--accent);
    }
    .card a { display: block; text-decoration: none; color: inherit; }
    .card img {
      display: block;
      width: 100%;
      aspect-ratio: 1;
      object-fit: cover;
      background: #000;
    }
    .card .meta {
      padding: 10px 12px;
    }
    .card .filename {
      font-size: 0.8rem;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      margin-bottom: 2px;
    }
    .card .timestamp {
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .card.hidden { display: none; }
    
    /* No results */
    .no-results {
      grid-column: 1 / -1;
      text-align: center;
      padding: 60px 20px;
      color: var(--text-muted);
    }
    
    /* Footer */
    .footer {
      margin-top: 40px;
      padding-top: 20px;
      border-top: 1px solid var(--border);
      text-align: center;
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .footer a { color: var(--accent); text-decoration: none; }
    .footer a:hover { text-decoration: underline; }
    
    @media (max-width: 600px) {
      body { padding: 12px; }
      .header h1 { font-size: 1.4rem; }
      .grid { grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; }
      .month-btn { padding: 5px 10px; font-size: 0.8rem; }
    }
  </style>
</head>
<body>
  <div class="container">
    <header class="header">
      <h1><span class="callsign">W4EWB</span>'s SSTV RX Gallery</h1>
      <p class="subtitle">
        A collection of SSTV images received on my Yaesu FT-710 in Louisville, KY.<br>
        <a href="https://www.qrz.com/db/W4EWB" target="_blank" rel="noopener">View my QRZ profile &rarr;</a>
      </p>
      <a href="latest.jpg" class="latest-link">📡 View Latest RX</a>
    </header>
    
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
    
    <div class="stats">
      Showing <span id="visible-count">$($items.Count)</span> of <span>$($items.Count)</span> images
    </div>
    
    <div class="grid" id="gallery">
"@

# Generate cards with data-month attribute
$cards = foreach ($it in $items) {
  $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
  $thumb = "thumbs/$base.jpg"
  $full  = "full/$($it.Name)"
  $stamp = $it.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
  $monthData = $it.LastWriteTime.ToString("yyyy-MM")
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
      <div class="no-results" id="no-results" style="display:none;">
        No images found for this month.
      </div>
    </div>
    
    <footer class="footer">
      73 de W4EWB &bull; 
      <a href="https://www.qrz.com/db/W4EWB">QRZ</a> &bull;
      Gallery auto-updated via MMSSTV
    </footer>
  </div>
  
  <script>
    (function() {
      const buttons = document.querySelectorAll('.month-btn');
      const cards = document.querySelectorAll('.card');
      const countEl = document.getElementById('visible-count');
      const noResults = document.getElementById('no-results');
      
      function filterByMonth(month) {
        let visible = 0;
        cards.forEach(card => {
          const cardMonth = card.getAttribute('data-month');
          const show = (month === 'all' || cardMonth === month);
          card.classList.toggle('hidden', !show);
          if (show) visible++;
        });
        countEl.textContent = visible;
        noResults.style.display = visible === 0 ? 'block' : 'none';
      }
      
      buttons.forEach(btn => {
        btn.addEventListener('click', function() {
          buttons.forEach(b => b.classList.remove('active'));
          this.classList.add('active');
          filterByMonth(this.getAttribute('data-month'));
        });
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
