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
# We store a simple dictionary: processed[key] = true
# NOTE: ConvertFrom-Json returns PSCustomObject, so we normalize to a hashtable so keys like
# "Hist29.bmp|..." work reliably (dot-property access will break).
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
# MMSTV reuses names (Hist1.bmp etc), so we key off name + LastWriteTimeUtc ticks + size
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

$head = @"
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SSTV RX Gallery</title>
  <style>
    body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:20px;line-height:1.3}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px}
    .card{border:1px solid #ddd;border-radius:10px;overflow:hidden;background:#fff}
    .card img{display:block;width:100%;height:auto}
    .meta{padding:8px 10px;font-size:12px;color:#222}
    .meta div{opacity:.7}
    a{color:inherit;text-decoration:none}
    .top{display:flex;gap:12px;align-items:baseline;flex-wrap:wrap}
  </style>
</head>
<body>
  <div class="top">
    <h2 style="margin:0">SSTV RX Gallery</h2>
    <div>Newest first • Latest RX: <a href="../latest.jpg">latest.jpg</a></div>
  </div>
  <div class="grid">
"@

$cards = foreach ($it in $items) {
  $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
  $thumb = "thumbs/$base.jpg"
  $full  = "full/$($it.Name)"
  $stamp = $it.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
@"
    <div class="card">
      <a href="$full">
        <img src="$thumb" loading="lazy" alt="$($it.Name)">
        <div class="meta">
          <strong>$($it.Name)</strong>
          <div>$stamp</div>
        </div>
      </a>
    </div>
"@
}

$foot = @"
  </div>
</body>
</html>
"@

($head + ($cards -join "`n") + $foot) | Set-Content -Encoding UTF8 $IndexFile

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
