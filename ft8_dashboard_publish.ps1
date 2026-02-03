# =========================
# FT8 Dashboard Auto-Publish (WSJT-X -> GitHub Pages)
# Repo:   C:\w4ewb\W4EWB
# Source: WSJT-X log files (wsjtx_log.adi, ALL.TXT)
# Output: repo\ft8\index.html + data files
# =========================

# ---- SETTINGS (edit these) ----
$RepoRoot      = "C:\w4ewb\W4EWB"
$WsjtxDir      = "$env:LOCALAPPDATA\WSJT-X"    # Standard WSJT-X location
$MyCallsign    = "W4EWB"
$MyGrid        = "EM78"                         # Your 4 or 6 char grid
$SkipAllTxt    = $true                          # Set to $false to parse ALL.TXT (slow!)

# Check if WSJT-X directory exists, try alternate locations
if (-not (Test-Path $WsjtxDir)) {
  $altPaths = @(
    "C:\Users\$env:USERNAME\AppData\Local\WSJT-X",
    "C:\WSJT-X",
    "$env:USERPROFILE\WSJT-X"
  )
  foreach ($alt in $altPaths) {
    if (Test-Path $alt) {
      $WsjtxDir = $alt
      Write-Host "Found WSJT-X data at: $WsjtxDir"
      break
    }
  }
}

Write-Host "Using WSJT-X directory: $WsjtxDir"

$Ft8Dir        = Join-Path $RepoRoot "ft8"
$DataDir       = Join-Path $Ft8Dir "data"
$IndexFile     = Join-Path $Ft8Dir "index.html"
$QsoDataFile   = Join-Path $DataDir "qsos.json"
$DecodeDataFile= Join-Path $DataDir "decodes.json"

# ---- sanity ----
foreach ($p in @($Ft8Dir, $DataDir)) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

# ---- Grid square to Lat/Lon conversion ----
function Convert-GridToLatLon {
  param([string]$Grid)
  
  if ($Grid.Length -lt 4) { return $null }
  
  $Grid = $Grid.ToUpper()
  
  $lon = ([int][char]$Grid[0] - [int][char]'A') * 20 - 180
  $lat = ([int][char]$Grid[1] - [int][char]'A') * 10 - 90
  
  $lon += ([int][char]$Grid[2] - [int][char]'0') * 2
  $lat += ([int][char]$Grid[3] - [int][char]'0') * 1
  
  if ($Grid.Length -ge 6) {
    $lon += ([int][char]$Grid[4] - [int][char]'A') * (2.0/24) + (1.0/24)
    $lat += ([int][char]$Grid[5] - [int][char]'A') * (1.0/24) + (0.5/24)
  } else {
    $lon += 1
    $lat += 0.5
  }
  
  return @{ lat = $lat; lon = $lon }
}

# ---- Parse ADIF log file ----
function Parse-AdifLog {
  param([string]$FilePath)
  
  if (-not (Test-Path $FilePath)) { return @() }
  
  $content = Get-Content $FilePath -Raw
  
  # Skip header (everything before <eoh>)
  $headerEnd = $content.IndexOf("<eoh>")
  if ($headerEnd -gt 0) {
    $content = $content.Substring($headerEnd + 5)
  }
  
  $qsos = @()
  
  # Split into records by <eor>
  $records = $content -split "<eor>" | Where-Object { $_.Trim() }
  
  foreach ($record in $records) {
    $qso = @{}
    
    # Extract fields with regex
    $matches = [regex]::Matches($record, "<(\w+):(\d+)(?::\w+)?>([^<]*)")
    
    foreach ($match in $matches) {
      $fieldName = $match.Groups[1].Value.ToUpper()
      $fieldLen = [int]$match.Groups[2].Value
      $fieldValue = $match.Groups[3].Value.Substring(0, [Math]::Min($fieldLen, $match.Groups[3].Value.Length))
      $qso[$fieldName] = $fieldValue.Trim()
    }
    
    if ($qso.ContainsKey("CALL")) {
      $qsos += $qso
    }
  }
  
  return $qsos
}

# ---- Parse ALL.TXT for decode statistics ----
function Parse-AllTxt {
  param([string]$FilePath, [int]$MaxLines = 10000)
  
  if (-not (Test-Path $FilePath)) { return @() }
  
  $lines = Get-Content $FilePath -Tail $MaxLines -ErrorAction SilentlyContinue
  
  $decodes = @()
  
  foreach ($line in $lines) {
    if ($line -match "^(\d{6})_(\d{6})\s+(\d+\.\d+)\s+Rx\s+(\w+)\s+(-?\d+)\s+[\d.]+\s+\d+\s+(.*)$") {
      $dateStr = $matches[1]
      $timeStr = $matches[2]
      $freq = [double]$matches[3]
      $mode = $matches[4]
      $snr = [int]$matches[5]
      $message = $matches[6]
      
      $band = switch -Regex ($freq.ToString()) {
        "^1\."    { "160m" }
        "^3\."    { "80m" }
        "^5\."    { "60m" }
        "^7\."    { "40m" }
        "^10\."   { "30m" }
        "^14\."   { "20m" }
        "^18\."   { "17m" }
        "^21\."   { "15m" }
        "^24\."   { "12m" }
        "^28\."   { "10m" }
        "^50\."   { "6m" }
        "^144\."  { "2m" }
        default   { "other" }
      }
      
      $grid = ""
      if ($message -match "\b([A-R]{2}\d{2}[a-x]{0,2})\b") {
        $grid = $matches[1]
      }
      
      $call = ""
      $parts = $message -split "\s+"
      foreach ($part in $parts) {
        if ($part -match "^[A-Z0-9]{1,3}[0-9][A-Z0-9]{0,3}[A-Z]$") {
          $call = $part
          break
        }
      }
      
      try {
        $year = "20" + $dateStr.Substring(0,2)
        $month = $dateStr.Substring(2,2)
        $day = $dateStr.Substring(4,2)
        $hour = $timeStr.Substring(0,2)
        $minute = $timeStr.Substring(2,2)
        $timestamp = "$year-$month-$day $hour`:$minute"
      } catch {
        $timestamp = ""
      }
      
      $decodes += @{
        timestamp = $timestamp
        band = $band
        mode = $mode
        snr = $snr
        call = $call
        grid = $grid
        message = $message
      }
    }
  }
  
  return $decodes
}

# ---- Process QSO log ----
Write-Host "Processing WSJT-X logs..."

$adifFile = Join-Path $WsjtxDir "wsjtx_log.adi"
$allTxtFile = Join-Path $WsjtxDir "ALL.TXT"

$qsos = Parse-AdifLog -FilePath $adifFile
Write-Host "Found $($qsos.Count) QSOs in log"

# Build QSO data with coordinates
$qsoData = @()
foreach ($qso in $qsos) {
  $grid = if ($qso.ContainsKey("GRIDSQUARE")) { $qso["GRIDSQUARE"] } else { "" }
  $coords = Convert-GridToLatLon -Grid $grid
  
  $band = if ($qso.ContainsKey("BAND")) { $qso["BAND"] } else { "" }
  $mode = if ($qso.ContainsKey("MODE")) { $qso["MODE"] } else { "FT8" }
  $date = if ($qso.ContainsKey("QSO_DATE")) { $qso["QSO_DATE"] } else { "" }
  $time = if ($qso.ContainsKey("TIME_ON")) { $qso["TIME_ON"] } else { "" }
  $rstSent = if ($qso.ContainsKey("RST_SENT")) { $qso["RST_SENT"] } else { "" }
  $rstRcvd = if ($qso.ContainsKey("RST_RCVD")) { $qso["RST_RCVD"] } else { "" }
  
  $dateFormatted = ""
  if ($date.Length -eq 8) {
    $dateFormatted = "$($date.Substring(0,4))-$($date.Substring(4,2))-$($date.Substring(6,2))"
  }
  
  $timeFormatted = ""
  if ($time.Length -ge 4) {
    $timeFormatted = "$($time.Substring(0,2)):$($time.Substring(2,2))"
  }
  
  $qsoData += @{
    call = $qso["CALL"]
    grid = $grid
    band = $band
    mode = $mode
    date = $dateFormatted
    time = $timeFormatted
    rstSent = $rstSent
    rstRcvd = $rstRcvd
    lat = if ($coords) { $coords.lat } else { $null }
    lon = if ($coords) { $coords.lon } else { $null }
  }
}

# Save QSO data as JSON
$qsoData | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $QsoDataFile

# ---- Process ALL.TXT for propagation data ----
$decodes = @()

if ($SkipAllTxt) {
  Write-Host "Skipping ALL.TXT parsing (set SkipAllTxt = `$false to enable)"
} else {
  Write-Host "Looking for ALL.TXT at $allTxtFile"
  if (Test-Path $allTxtFile) {
    $fileSize = (Get-Item $allTxtFile).Length / 1MB
    Write-Host "Found ALL.TXT ($([math]::Round($fileSize, 1)) MB) - parsing last 10000 lines..."
    $decodes = Parse-AllTxt -FilePath $allTxtFile -MaxLines 10000
    Write-Host "Parsed $($decodes.Count) decodes"
  } else {
    Write-Host "ALL.TXT not found - propagation data will be empty"
  }
}

# Aggregate decode stats
$now = Get-Date
$weekAgo = $now.AddDays(-7)

$bandStats = @{}
$recentDecodes = @()

foreach ($decode in $decodes) {
  if ($decode.timestamp) {
    try {
      $ts = [datetime]::Parse($decode.timestamp)
      if ($ts -gt $weekAgo) {
        $hourKey = $ts.ToString("yyyy-MM-dd HH")
        $band = $decode.band
        
        if (-not $bandStats.ContainsKey($band)) {
          $bandStats[$band] = @{}
        }
        if (-not $bandStats[$band].ContainsKey($hourKey)) {
          $bandStats[$band][$hourKey] = @{ count = 0; snrSum = 0 }
        }
        $bandStats[$band][$hourKey].count++
        $bandStats[$band][$hourKey].snrSum += $decode.snr
        
        if ($decode.grid -and $recentDecodes.Count -lt 1000) {
          $coords = Convert-GridToLatLon -Grid $decode.grid
          if ($coords) {
            $recentDecodes += @{
              call = $decode.call
              grid = $decode.grid
              band = $decode.band
              snr = $decode.snr
              timestamp = $decode.timestamp
              lat = $coords.lat
              lon = $coords.lon
            }
          }
        }
      }
    } catch { }
  }
}

$propData = @{
  generated = $now.ToString("yyyy-MM-dd HH:mm:ss")
  bands = @{}
}

foreach ($band in $bandStats.Keys) {
  $propData.bands[$band] = @()
  foreach ($hour in ($bandStats[$band].Keys | Sort-Object)) {
    $stats = $bandStats[$band][$hour]
    $avgSnr = if ($stats.count -gt 0) { [math]::Round($stats.snrSum / $stats.count, 1) } else { 0 }
    $propData.bands[$band] += @{
      hour = $hour
      count = $stats.count
      avgSnr = $avgSnr
    }
  }
}

$propData["recentDecodes"] = $recentDecodes

try {
  $propData | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $DecodeDataFile
  Write-Host "Saved propagation data to $DecodeDataFile"
} catch {
  Write-Host "Warning: Could not save decodes.json - $_"
}

Write-Host "Processed $($decodes.Count) decodes, kept $($recentDecodes.Count) with grid info"

# ---- My grid coordinates ----
$myCoords = Convert-GridToLatLon -Grid $MyGrid
$MyLat = if ($myCoords) { $myCoords.lat } else { 38.25 }
$MyLon = if ($myCoords) { $myCoords.lon } else { -85.75 }

Write-Host "My coordinates: $MyLat, $MyLon"

# ---- Generate Dashboard HTML ----
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$MyCallsign FT8 Dashboard</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <style>
    :root {
      --bg: #0d1117;
      --card-bg: #161b22;
      --border: #30363d;
      --text: #c9d1d9;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --green: #3fb950;
      --yellow: #d29922;
      --red: #f85149;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: system-ui, -apple-system, 'Segoe UI', sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    .container { max-width: 1600px; margin: 0 auto; padding: 20px; }
    
    header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      flex-wrap: wrap;
      gap: 16px;
      margin-bottom: 24px;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--border);
    }
    .title-section h1 { font-size: 1.8rem; font-weight: 600; color: #fff; }
    .title-section h1 .call { color: var(--accent); }
    .title-section .subtitle { color: var(--text-muted); font-size: 0.95rem; margin-top: 4px; }
    .title-section .subtitle a { color: var(--accent); text-decoration: none; }
    .title-section .subtitle a:hover { text-decoration: underline; }
    
    .stats-row { display: flex; gap: 20px; flex-wrap: wrap; }
    .stat-box {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px 20px;
      text-align: center;
    }
    .stat-box .value { font-size: 1.8rem; font-weight: 600; color: var(--accent); }
    .stat-box .label { font-size: 0.8rem; color: var(--text-muted); text-transform: uppercase; }
    
    .tabs { display: flex; gap: 8px; margin-bottom: 20px; border-bottom: 1px solid var(--border); padding-bottom: 12px; }
    .tab {
      padding: 8px 20px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      color: var(--text-muted);
      cursor: pointer;
      font-size: 0.9rem;
      transition: all 0.15s;
    }
    .tab:hover { border-color: var(--accent); color: var(--text); }
    .tab.active { background: var(--accent); border-color: var(--accent); color: #0d1117; font-weight: 500; }
    
    .panel { display: none; }
    .panel.active { display: block; }
    
    #map { height: 500px; border-radius: 10px; border: 1px solid var(--border); margin-bottom: 20px; }
    
    .map-controls, .filter-controls {
      display: flex;
      gap: 12px;
      margin-bottom: 16px;
      flex-wrap: wrap;
      align-items: center;
    }
    .map-controls label, .filter-controls label { font-size: 0.85rem; color: var(--text-muted); }
    .map-controls select, .filter-controls select {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 6px 12px;
      color: var(--text);
      font-size: 0.85rem;
    }
    
    .filter-btn {
      padding: 6px 12px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      color: var(--text-muted);
      font-size: 0.8rem;
      cursor: pointer;
      transition: all 0.15s;
    }
    .filter-btn:hover { border-color: var(--accent); color: var(--text); }
    .filter-btn.active { background: var(--accent); border-color: var(--accent); color: #0d1117; }
    
    .band-160m { color: #ff6b6b; } .band-80m { color: #ffa94d; } .band-60m { color: #ffd43b; }
    .band-40m { color: #69db7c; } .band-30m { color: #38d9a9; } .band-20m { color: #4dabf7; }
    .band-17m { color: #748ffc; } .band-15m { color: #9775fa; } .band-12m { color: #da77f2; }
    .band-10m { color: #f783ac; } .band-6m { color: #e599f7; }
    
    .prop-grid {
      display: grid;
      grid-template-columns: 60px repeat(24, 1fr);
      gap: 2px;
      font-size: 0.7rem;
      margin-bottom: 20px;
    }
    .prop-cell { aspect-ratio: 1; display: flex; align-items: center; justify-content: center; border-radius: 3px; }
    .prop-label { display: flex; align-items: center; justify-content: flex-end; padding-right: 8px; font-weight: 500; }
    .prop-hour { text-align: center; color: var(--text-muted); font-size: 0.65rem; }
    
    .psk-section { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    @media (max-width: 900px) { .psk-section { grid-template-columns: 1fr; } }
    .psk-card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 16px;
    }
    .psk-card h3 { font-size: 1rem; margin-bottom: 12px; color: var(--text); }
    .psk-card h3 .count { font-weight: normal; color: var(--text-muted); }
    .spot-list { max-height: 400px; overflow-y: auto; }
    .spot {
      display: grid;
      grid-template-columns: 1fr auto auto auto;
      gap: 12px;
      align-items: center;
      padding: 8px 0;
      border-bottom: 1px solid var(--border);
      font-size: 0.85rem;
    }
    .spot:last-child { border-bottom: none; }
    .spot .call { font-weight: 500; color: var(--accent); }
    .spot .info { color: var(--text-muted); }
    .spot .country { font-size: 0.8rem; }
    .spot .flag { font-size: 1.1rem; margin-right: 4px; }
    .spot .snr { font-weight: 500; }
    .spot .snr.good { color: var(--green); }
    .spot .snr.ok { color: var(--yellow); }
    .spot .snr.weak { color: var(--red); }
    
    .qso-table-wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: 10px; }
    .qso-table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    .qso-table th, .qso-table td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--border); }
    .qso-table th { background: var(--card-bg); font-weight: 500; color: var(--text-muted); text-transform: uppercase; font-size: 0.75rem; }
    .qso-table tr:hover { background: rgba(88, 166, 255, 0.05); }
    .qso-table .call { color: var(--accent); font-weight: 500; }
    .qso-table .flag { font-size: 1rem; margin-right: 6px; }
    
    .empty-state {
      text-align: center;
      padding: 60px 20px;
      color: var(--text-muted);
    }
    .empty-state h3 { color: var(--text); margin-bottom: 8px; }
    .empty-state p { max-width: 400px; margin: 0 auto; }
    
    footer {
      margin-top: 40px;
      padding-top: 20px;
      border-top: 1px solid var(--border);
      text-align: center;
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    footer a { color: var(--accent); text-decoration: none; }
    footer a:hover { text-decoration: underline; }
    
    @media (max-width: 768px) {
      .container { padding: 12px; }
      header { flex-direction: column; }
      .title-section h1 { font-size: 1.4rem; }
      #map { height: 350px; }
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="title-section">
        <h1><span class="call">$MyCallsign</span> FT8 Dashboard</h1>
        <p class="subtitle">
          Digital modes activity from my Yaesu FT-710 in Louisville, KY ($MyGrid)<br>
          <a href="https://www.qrz.com/db/$MyCallsign" target="_blank">QRZ Profile</a> &#8226;
          <a href="../sstv/rx/">SSTV Gallery</a>
        </p>
      </div>
      <div class="stats-row">
        <div class="stat-box">
          <div class="value" id="total-qsos">--</div>
          <div class="label">Total QSOs</div>
        </div>
        <div class="stat-box">
          <div class="value" id="total-grids">--</div>
          <div class="label">Grids Worked</div>
        </div>
        <div class="stat-box">
          <div class="value" id="total-dxcc">--</div>
          <div class="label">DXCC</div>
        </div>
      </div>
    </header>
    
    <div class="tabs">
      <button class="tab active" data-panel="map-panel">QSO Map</button>
      <button class="tab" data-panel="prop-panel">Propagation</button>
      <button class="tab" data-panel="psk-panel">PSK Reporter</button>
      <button class="tab" data-panel="log-panel">QSO Log</button>
    </div>
    
    <!-- QSO Map Panel -->
    <div id="map-panel" class="panel active">
      <div class="map-controls">
        <label>Band:</label>
        <select id="band-filter">
          <option value="all">All Bands</option>
          <option value="160m">160m</option>
          <option value="80m">80m</option>
          <option value="40m">40m</option>
          <option value="30m">30m</option>
          <option value="20m">20m</option>
          <option value="17m">17m</option>
          <option value="15m">15m</option>
          <option value="12m">12m</option>
          <option value="10m">10m</option>
          <option value="6m">6m</option>
        </select>
        <label>Time:</label>
        <select id="time-filter">
          <option value="all">All Time</option>
          <option value="7">Last 7 Days</option>
          <option value="30">Last 30 Days</option>
          <option value="90">Last 90 Days</option>
          <option value="365">Last Year</option>
        </select>
        <label style="display: flex; align-items: center; gap: 6px;">
          <input type="checkbox" id="show-lines" checked> Path lines
        </label>
      </div>
      <div id="map"></div>
    </div>
    
    <!-- Propagation Panel -->
    <div id="prop-panel" class="panel">
      <h3 style="margin-bottom: 16px;">Band Activity Heatmap (Last 7 Days)</h3>
      <div id="prop-heatmap"></div>
    </div>
    
    <!-- PSK Reporter Panel -->
    <div id="psk-panel" class="panel">
      <p style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 20px;">
        Live data from PSK Reporter (last 24 hours). 
        <button id="refresh-psk" style="background: var(--accent); border: none; padding: 4px 12px; border-radius: 4px; color: #000; cursor: pointer; font-size: 0.8rem;">Refresh</button>
      </p>
      <div class="psk-section">
        <div class="psk-card">
          <h3>&#128225; Where I'm Being Heard <span class="count" id="tx-count"></span></h3>
          <div id="tx-spots" class="spot-list">Loading...</div>
        </div>
        <div class="psk-card">
          <h3>&#128251; What I'm Hearing <span class="count" id="rx-count"></span></h3>
          <div id="rx-spots" class="spot-list">Loading...</div>
        </div>
      </div>
    </div>
    
    <!-- QSO Log Panel -->
    <div id="log-panel" class="panel">
      <div class="filter-controls">
        <label>Show:</label>
        <button class="filter-btn active" data-days="all">All</button>
        <button class="filter-btn" data-days="7">7 Days</button>
        <button class="filter-btn" data-days="30">30 Days</button>
        <button class="filter-btn" data-days="90">90 Days</button>
        <button class="filter-btn" data-days="365">1 Year</button>
      </div>
      <div class="qso-table-wrap">
        <table class="qso-table">
          <thead>
            <tr>
              <th>Date</th>
              <th>Time</th>
              <th>Callsign</th>
              <th>Country</th>
              <th>Grid</th>
              <th>Band</th>
              <th>Mode</th>
              <th>RST S/R</th>
            </tr>
          </thead>
          <tbody id="qso-tbody"></tbody>
        </table>
      </div>
      <div id="log-stats" style="margin-top: 12px; font-size: 0.85rem; color: var(--text-muted);"></div>
    </div>
    
    <footer>
      73 de $MyCallsign &#8226;
      <a href="https://www.qrz.com/db/$MyCallsign">QRZ</a> &#8226;
      <a href="../sstv/rx/">SSTV Gallery</a> &#8226;
      Dashboard auto-generated from WSJT-X logs
    </footer>
  </div>
  
  <script>
    const MY_CALL = '$MyCallsign';
    const MY_GRID = '$MyGrid';
    const MY_LAT = $MyLat;
    const MY_LON = $MyLon;
    
    const BAND_COLORS = {
      '160m': '#ff6b6b', '80m': '#ffa94d', '60m': '#ffd43b',
      '40m': '#69db7c', '30m': '#38d9a9', '20m': '#4dabf7',
      '17m': '#748ffc', '15m': '#9775fa', '12m': '#da77f2',
      '10m': '#f783ac', '6m': '#e599f7', '2m': '#fcc419'
    };
    
    // Callsign prefix to country/flag mapping
    const PREFIXES = {
      'A': {f:'&#127462;&#127467;',c:'Afghanistan'}, 'AP': {f:'&#127477;&#127472;',c:'Pakistan'},
      'BV': {f:'&#127481;&#127484;',c:'Taiwan'}, 'BY': {f:'&#127464;&#127475;',c:'China'},
      'CE': {f:'&#127464;&#127473;',c:'Chile'}, 'CM': {f:'&#127464;&#127482;',c:'Cuba'}, 'CO': {f:'&#127464;&#127482;',c:'Cuba'},
      'CT': {f:'&#127477;&#127481;',c:'Portugal'}, 'CU': {f:'&#127477;&#127481;',c:'Portugal'},
      'CX': {f:'&#127482;&#127486;',c:'Uruguay'},
      'DA': {f:'&#127465;&#127466;',c:'Germany'}, 'DB': {f:'&#127465;&#127466;',c:'Germany'}, 
      'DC': {f:'&#127465;&#127466;',c:'Germany'}, 'DD': {f:'&#127465;&#127466;',c:'Germany'},
      'DF': {f:'&#127465;&#127466;',c:'Germany'}, 'DG': {f:'&#127465;&#127466;',c:'Germany'},
      'DH': {f:'&#127465;&#127466;',c:'Germany'}, 'DJ': {f:'&#127465;&#127466;',c:'Germany'},
      'DK': {f:'&#127465;&#127466;',c:'Germany'}, 'DL': {f:'&#127465;&#127466;',c:'Germany'},
      'DM': {f:'&#127465;&#127466;',c:'Germany'}, 'DO': {f:'&#127465;&#127466;',c:'Germany'},
      'DP': {f:'&#127465;&#127466;',c:'Germany'}, 'DQ': {f:'&#127465;&#127466;',c:'Germany'},
      'DR': {f:'&#127465;&#127466;',c:'Germany'},
      'E5': {f:'&#127464;&#127472;',c:'Cook Is.'}, 'E7': {f:'&#127463;&#127462;',c:'Bosnia'},
      'EA': {f:'&#127466;&#127480;',c:'Spain'}, 'EB': {f:'&#127466;&#127480;',c:'Spain'},
      'EC': {f:'&#127466;&#127480;',c:'Spain'}, 'ED': {f:'&#127466;&#127480;',c:'Spain'},
      'EI': {f:'&#127470;&#127466;',c:'Ireland'}, 'EJ': {f:'&#127470;&#127466;',c:'Ireland'},
      'EK': {f:'&#127462;&#127474;',c:'Armenia'}, 'ER': {f:'&#127474;&#127465;',c:'Moldova'},
      'ES': {f:'&#127466;&#127466;',c:'Estonia'}, 'EU': {f:'&#127463;&#127486;',c:'Belarus'},
      'EW': {f:'&#127463;&#127486;',c:'Belarus'},
      'F': {f:'&#127467;&#127479;',c:'France'},
      'G': {f:'&#127468;&#127463;',c:'England'}, 'GB': {f:'&#127468;&#127463;',c:'UK'},
      'GD': {f:'&#127470;&#127474;',c:'Isle of Man'}, 'GI': {f:'&#127468;&#127463;',c:'N. Ireland'},
      'GJ': {f:'&#127468;&#127463;',c:'Jersey'}, 'GM': {f:'&#127468;&#127463;',c:'Scotland'},
      'GU': {f:'&#127468;&#127463;',c:'Guernsey'}, 'GW': {f:'&#127468;&#127463;',c:'Wales'},
      'HA': {f:'&#127469;&#127482;',c:'Hungary'}, 'HB': {f:'&#127464;&#127469;',c:'Switzerland'},
      'HB0': {f:'&#127473;&#127470;',c:'Liechtenstein'},
      'HC': {f:'&#127466;&#127464;',c:'Ecuador'}, 'HI': {f:'&#127465;&#127476;',c:'Dom. Rep.'},
      'HK': {f:'&#127464;&#127476;',c:'Colombia'}, 'HL': {f:'&#127472;&#127479;',c:'South Korea'},
      'HP': {f:'&#127477;&#127462;',c:'Panama'}, 'HR': {f:'&#127469;&#127475;',c:'Honduras'},
      'HS': {f:'&#127481;&#127469;',c:'Thailand'}, 'HZ': {f:'&#127480;&#127462;',c:'Saudi Arabia'},
      'I': {f:'&#127470;&#127481;',c:'Italy'},
      'JA': {f:'&#127471;&#127477;',c:'Japan'}, 'JE': {f:'&#127471;&#127477;',c:'Japan'},
      'JF': {f:'&#127471;&#127477;',c:'Japan'}, 'JG': {f:'&#127471;&#127477;',c:'Japan'},
      'JH': {f:'&#127471;&#127477;',c:'Japan'}, 'JI': {f:'&#127471;&#127477;',c:'Japan'},
      'JJ': {f:'&#127471;&#127477;',c:'Japan'}, 'JK': {f:'&#127471;&#127477;',c:'Japan'},
      'JL': {f:'&#127471;&#127477;',c:'Japan'}, 'JM': {f:'&#127471;&#127477;',c:'Japan'},
      'JN': {f:'&#127471;&#127477;',c:'Japan'}, 'JO': {f:'&#127471;&#127477;',c:'Japan'},
      'JP': {f:'&#127471;&#127477;',c:'Japan'}, 'JQ': {f:'&#127471;&#127477;',c:'Japan'},
      'JR': {f:'&#127471;&#127477;',c:'Japan'}, 'JS': {f:'&#127471;&#127477;',c:'Japan'},
      'JT': {f:'&#127474;&#127475;',c:'Mongolia'}, 'JY': {f:'&#127471;&#127476;',c:'Jordan'},
      'K': {f:'&#127482;&#127480;',c:'USA'}, 'KA': {f:'&#127482;&#127480;',c:'USA'},
      'KB': {f:'&#127482;&#127480;',c:'USA'}, 'KC': {f:'&#127482;&#127480;',c:'USA'},
      'KD': {f:'&#127482;&#127480;',c:'USA'}, 'KE': {f:'&#127482;&#127480;',c:'USA'},
      'KF': {f:'&#127482;&#127480;',c:'USA'}, 'KG': {f:'&#127482;&#127480;',c:'USA'},
      'KH6': {f:'&#127482;&#127480;',c:'Hawaii'}, 'KI': {f:'&#127482;&#127480;',c:'USA'},
      'KJ': {f:'&#127482;&#127480;',c:'USA'}, 'KK': {f:'&#127482;&#127480;',c:'USA'},
      'KL7': {f:'&#127482;&#127480;',c:'Alaska'}, 'KM': {f:'&#127482;&#127480;',c:'USA'},
      'KN': {f:'&#127482;&#127480;',c:'USA'}, 'KO': {f:'&#127482;&#127480;',c:'USA'},
      'KP': {f:'&#127477;&#127479;',c:'Puerto Rico'}, 'KQ': {f:'&#127482;&#127480;',c:'USA'},
      'KR': {f:'&#127482;&#127480;',c:'USA'}, 'KS': {f:'&#127482;&#127480;',c:'USA'},
      'KT': {f:'&#127482;&#127480;',c:'USA'}, 'KU': {f:'&#127482;&#127480;',c:'USA'},
      'KV': {f:'&#127482;&#127480;',c:'USA'}, 'KW': {f:'&#127482;&#127480;',c:'USA'},
      'KX': {f:'&#127482;&#127480;',c:'USA'}, 'KY': {f:'&#127482;&#127480;',c:'USA'},
      'KZ': {f:'&#127482;&#127480;',c:'USA'},
      'LA': {f:'&#127475;&#127476;',c:'Norway'}, 'LB': {f:'&#127475;&#127476;',c:'Norway'},
      'LU': {f:'&#127462;&#127479;',c:'Argentina'}, 'LW': {f:'&#127462;&#127479;',c:'Argentina'},
      'LX': {f:'&#127473;&#127482;',c:'Luxembourg'}, 'LY': {f:'&#127473;&#127481;',c:'Lithuania'},
      'LZ': {f:'&#127463;&#127468;',c:'Bulgaria'},
      'N': {f:'&#127482;&#127480;',c:'USA'}, 'NH': {f:'&#127482;&#127480;',c:'Hawaii'},
      'NL7': {f:'&#127482;&#127480;',c:'Alaska'}, 'NP': {f:'&#127477;&#127479;',c:'Puerto Rico'},
      'OA': {f:'&#127477;&#127466;',c:'Peru'}, 'OE': {f:'&#127462;&#127481;',c:'Austria'},
      'OF': {f:'&#127467;&#127470;',c:'Finland'}, 'OG': {f:'&#127467;&#127470;',c:'Finland'},
      'OH': {f:'&#127467;&#127470;',c:'Finland'}, 'OI': {f:'&#127467;&#127470;',c:'Finland'},
      'OK': {f:'&#127464;&#127487;',c:'Czechia'}, 'OL': {f:'&#127464;&#127487;',c:'Czechia'},
      'OM': {f:'&#127480;&#127472;',c:'Slovakia'}, 'ON': {f:'&#127463;&#127466;',c:'Belgium'},
      'OO': {f:'&#127463;&#127466;',c:'Belgium'}, 'OP': {f:'&#127463;&#127466;',c:'Belgium'},
      'OQ': {f:'&#127463;&#127466;',c:'Belgium'}, 'OR': {f:'&#127463;&#127466;',c:'Belgium'},
      'OS': {f:'&#127463;&#127466;',c:'Belgium'}, 'OT': {f:'&#127463;&#127466;',c:'Belgium'},
      'OZ': {f:'&#127465;&#127472;',c:'Denmark'},
      'P4': {f:'&#127462;&#127484;',c:'Aruba'}, 'PA': {f:'&#127475;&#127473;',c:'Netherlands'},
      'PB': {f:'&#127475;&#127473;',c:'Netherlands'}, 'PC': {f:'&#127475;&#127473;',c:'Netherlands'},
      'PD': {f:'&#127475;&#127473;',c:'Netherlands'}, 'PE': {f:'&#127475;&#127473;',c:'Netherlands'},
      'PF': {f:'&#127475;&#127473;',c:'Netherlands'}, 'PG': {f:'&#127475;&#127473;',c:'Netherlands'},
      'PH': {f:'&#127475;&#127473;',c:'Netherlands'}, 'PI': {f:'&#127475;&#127473;',c:'Netherlands'},
      'PJ': {f:'&#127475;&#127473;',c:'Neth. Antilles'}, 
      'PP': {f:'&#127463;&#127479;',c:'Brazil'}, 'PQ': {f:'&#127463;&#127479;',c:'Brazil'},
      'PR': {f:'&#127463;&#127479;',c:'Brazil'}, 'PS': {f:'&#127463;&#127479;',c:'Brazil'},
      'PT': {f:'&#127463;&#127479;',c:'Brazil'}, 'PU': {f:'&#127463;&#127479;',c:'Brazil'},
      'PV': {f:'&#127463;&#127479;',c:'Brazil'}, 'PW': {f:'&#127463;&#127479;',c:'Brazil'},
      'PX': {f:'&#127463;&#127479;',c:'Brazil'}, 'PY': {f:'&#127463;&#127479;',c:'Brazil'},
      'R': {f:'&#127479;&#127482;',c:'Russia'}, 'RA': {f:'&#127479;&#127482;',c:'Russia'},
      'RK': {f:'&#127479;&#127482;',c:'Russia'}, 'RN': {f:'&#127479;&#127482;',c:'Russia'},
      'RU': {f:'&#127479;&#127482;',c:'Russia'}, 'RV': {f:'&#127479;&#127482;',c:'Russia'},
      'RW': {f:'&#127479;&#127482;',c:'Russia'}, 'RX': {f:'&#127479;&#127482;',c:'Russia'},
      'RZ': {f:'&#127479;&#127482;',c:'Russia'},
      'S5': {f:'&#127480;&#127470;',c:'Slovenia'}, 'SA': {f:'&#127480;&#127466;',c:'Sweden'},
      'SB': {f:'&#127480;&#127466;',c:'Sweden'}, 'SC': {f:'&#127480;&#127466;',c:'Sweden'},
      'SD': {f:'&#127480;&#127466;',c:'Sweden'}, 'SE': {f:'&#127480;&#127466;',c:'Sweden'},
      'SF': {f:'&#127480;&#127466;',c:'Sweden'}, 'SG': {f:'&#127480;&#127466;',c:'Sweden'},
      'SH': {f:'&#127480;&#127466;',c:'Sweden'}, 'SI': {f:'&#127480;&#127466;',c:'Sweden'},
      'SJ': {f:'&#127480;&#127466;',c:'Sweden'}, 'SK': {f:'&#127480;&#127466;',c:'Sweden'},
      'SL': {f:'&#127480;&#127466;',c:'Sweden'}, 'SM': {f:'&#127480;&#127466;',c:'Sweden'},
      'SN': {f:'&#127477;&#127473;',c:'Poland'}, 'SO': {f:'&#127477;&#127473;',c:'Poland'},
      'SP': {f:'&#127477;&#127473;',c:'Poland'}, 'SQ': {f:'&#127477;&#127473;',c:'Poland'},
      'SR': {f:'&#127477;&#127473;',c:'Poland'}, 'SU': {f:'&#127466;&#127468;',c:'Egypt'},
      'SV': {f:'&#127468;&#127479;',c:'Greece'}, 'SW': {f:'&#127468;&#127479;',c:'Greece'},
      'SX': {f:'&#127468;&#127479;',c:'Greece'}, 'SY': {f:'&#127468;&#127479;',c:'Greece'},
      'SZ': {f:'&#127468;&#127479;',c:'Greece'},
      'T7': {f:'&#127480;&#127474;',c:'San Marino'}, 'TA': {f:'&#127481;&#127479;',c:'Turkey'},
      'TC': {f:'&#127481;&#127479;',c:'Turkey'}, 'TF': {f:'&#127470;&#127480;',c:'Iceland'},
      'TG': {f:'&#127468;&#127481;',c:'Guatemala'}, 'TI': {f:'&#127464;&#127479;',c:'Costa Rica'},
      'TK': {f:'&#127467;&#127479;',c:'Corsica'},
      'UA': {f:'&#127479;&#127482;',c:'Russia'}, 'UB': {f:'&#127479;&#127482;',c:'Russia'},
      'UK': {f:'&#127482;&#127487;',c:'Uzbekistan'}, 'UN': {f:'&#127472;&#127487;',c:'Kazakhstan'},
      'UR': {f:'&#127482;&#127462;',c:'Ukraine'}, 'US': {f:'&#127482;&#127462;',c:'Ukraine'},
      'UT': {f:'&#127482;&#127462;',c:'Ukraine'}, 'UU': {f:'&#127482;&#127462;',c:'Ukraine'},
      'UV': {f:'&#127482;&#127462;',c:'Ukraine'}, 'UW': {f:'&#127482;&#127462;',c:'Ukraine'},
      'UX': {f:'&#127482;&#127462;',c:'Ukraine'}, 'UY': {f:'&#127482;&#127462;',c:'Ukraine'},
      'UZ': {f:'&#127482;&#127462;',c:'Ukraine'},
      'V3': {f:'&#127463;&#127487;',c:'Belize'}, 'V5': {f:'&#127475;&#127462;',c:'Namibia'},
      'VA': {f:'&#127464;&#127462;',c:'Canada'}, 'VE': {f:'&#127464;&#127462;',c:'Canada'},
      'VK': {f:'&#127462;&#127482;',c:'Australia'}, 'VP': {f:'&#127468;&#127463;',c:'UK Territories'},
      'VR': {f:'&#127469;&#127472;',c:'Hong Kong'}, 'VU': {f:'&#127470;&#127475;',c:'India'},
      'W': {f:'&#127482;&#127480;',c:'USA'}, 'WA': {f:'&#127482;&#127480;',c:'USA'},
      'WB': {f:'&#127482;&#127480;',c:'USA'}, 'WC': {f:'&#127482;&#127480;',c:'USA'},
      'WD': {f:'&#127482;&#127480;',c:'USA'}, 'WE': {f:'&#127482;&#127480;',c:'USA'},
      'WF': {f:'&#127482;&#127480;',c:'USA'}, 'WG': {f:'&#127482;&#127480;',c:'USA'},
      'WH6': {f:'&#127482;&#127480;',c:'Hawaii'}, 'WI': {f:'&#127482;&#127480;',c:'USA'},
      'WJ': {f:'&#127482;&#127480;',c:'USA'}, 'WK': {f:'&#127482;&#127480;',c:'USA'},
      'WL7': {f:'&#127482;&#127480;',c:'Alaska'}, 'WM': {f:'&#127482;&#127480;',c:'USA'},
      'WN': {f:'&#127482;&#127480;',c:'USA'}, 'WO': {f:'&#127482;&#127480;',c:'USA'},
      'WP': {f:'&#127477;&#127479;',c:'Puerto Rico'}, 'WQ': {f:'&#127482;&#127480;',c:'USA'},
      'WR': {f:'&#127482;&#127480;',c:'USA'}, 'WS': {f:'&#127482;&#127480;',c:'USA'},
      'WT': {f:'&#127482;&#127480;',c:'USA'}, 'WU': {f:'&#127482;&#127480;',c:'USA'},
      'WV': {f:'&#127482;&#127480;',c:'USA'}, 'WW': {f:'&#127482;&#127480;',c:'USA'},
      'WX': {f:'&#127482;&#127480;',c:'USA'}, 'WY': {f:'&#127482;&#127480;',c:'USA'},
      'WZ': {f:'&#127482;&#127480;',c:'USA'},
      'XE': {f:'&#127474;&#127485;',c:'Mexico'}, 'XF': {f:'&#127474;&#127485;',c:'Mexico'},
      'YB': {f:'&#127470;&#127465;',c:'Indonesia'}, 'YC': {f:'&#127470;&#127465;',c:'Indonesia'},
      'YL': {f:'&#127473;&#127483;',c:'Latvia'}, 'YO': {f:'&#127479;&#127476;',c:'Romania'},
      'YP': {f:'&#127479;&#127476;',c:'Romania'}, 'YQ': {f:'&#127479;&#127476;',c:'Romania'},
      'YR': {f:'&#127479;&#127476;',c:'Romania'}, 'YS': {f:'&#127480;&#127483;',c:'El Salvador'},
      'YT': {f:'&#127479;&#127480;',c:'Serbia'}, 'YU': {f:'&#127479;&#127480;',c:'Serbia'},
      'YV': {f:'&#127483;&#127466;',c:'Venezuela'},
      'Z3': {f:'&#127474;&#127472;',c:'N. Macedonia'}, 'ZA': {f:'&#127462;&#127473;',c:'Albania'},
      'ZL': {f:'&#127475;&#127487;',c:'New Zealand'}, 'ZP': {f:'&#127477;&#127486;',c:'Paraguay'},
      'ZR': {f:'&#127487;&#127462;',c:'South Africa'}, 'ZS': {f:'&#127487;&#127462;',c:'South Africa'},
      '3D2': {f:'&#127467;&#127471;',c:'Fiji'}, '4X': {f:'&#127470;&#127473;',c:'Israel'},
      '4Z': {f:'&#127470;&#127473;',c:'Israel'}, '5B': {f:'&#127464;&#127486;',c:'Cyprus'},
      '9A': {f:'&#127469;&#127479;',c:'Croatia'}, '9H': {f:'&#127474;&#127481;',c:'Malta'},
      '9K': {f:'&#127472;&#127484;',c:'Kuwait'}, '9M': {f:'&#127474;&#127486;',c:'Malaysia'},
      '9V': {f:'&#127480;&#127468;',c:'Singapore'}, '9Y': {f:'&#127481;&#127481;',c:'Trinidad'}
    };
    
    function getCountryInfo(call) {
      if (!call) return { flag: '', country: '' };
      call = call.toUpperCase();
      // Try longest prefix first
      for (let len = 4; len >= 1; len--) {
        const prefix = call.substring(0, len);
        if (PREFIXES[prefix]) return PREFIXES[prefix];
      }
      // Fallback: try first char
      const first = call.charAt(0);
      if (PREFIXES[first]) return PREFIXES[first];
      return { f: '&#127760;', c: 'Unknown' };
    }
    
    let qsoData = [];
    let decodeData = {};
    let map, markersLayer, linesLayer;
    
    document.addEventListener('DOMContentLoaded', async () => {
      initTabs();
      initMap();
      await loadData();
      initPskReporter();
      initLogFilters();
    });
    
    function initTabs() {
      document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
          document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
          document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
          tab.classList.add('active');
          document.getElementById(tab.dataset.panel).classList.add('active');
          if (map) setTimeout(() => map.invalidateSize(), 100);
        });
      });
    }
    
    function initMap() {
      map = L.map('map').setView([MY_LAT, MY_LON], 2);
      
      L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
        attribution: '&copy; OpenStreetMap, &copy; CartoDB',
        maxZoom: 19
      }).addTo(map);
      
      L.circleMarker([MY_LAT, MY_LON], {
        radius: 10, fillColor: '#58a6ff', color: '#fff',
        weight: 2, fillOpacity: 1
      }).addTo(map).bindPopup('<strong>' + MY_CALL + '</strong><br>' + MY_GRID);
      
      markersLayer = L.layerGroup().addTo(map);
      linesLayer = L.layerGroup().addTo(map);
      
      document.getElementById('band-filter').addEventListener('change', updateMapMarkers);
      document.getElementById('time-filter').addEventListener('change', updateMapMarkers);
      document.getElementById('show-lines').addEventListener('change', updateMapMarkers);
    }
    
    async function loadData() {
      try {
        const [qsoRes, decodeRes] = await Promise.all([
          fetch('data/qsos.json'),
          fetch('data/decodes.json')
        ]);
        
        qsoData = await qsoRes.json();
        decodeData = await decodeRes.json();
        
        updateStats();
        updateMapMarkers();
        updateQsoTable();
        updatePropHeatmap();
      } catch (e) {
        console.error('Error loading data:', e);
      }
    }
    
    function updateStats() {
      document.getElementById('total-qsos').textContent = qsoData.length;
      
      const grids = new Set(qsoData.map(q => q.grid).filter(g => g));
      document.getElementById('total-grids').textContent = grids.size;
      
      const countries = new Set();
      qsoData.forEach(q => {
        const info = getCountryInfo(q.call);
        if (info.c && info.c !== 'Unknown') countries.add(info.c);
      });
      document.getElementById('total-dxcc').textContent = countries.size;
    }
    
    function filterByTime(data, days) {
      if (days === 'all') return data;
      const cutoff = new Date();
      cutoff.setDate(cutoff.getDate() - parseInt(days));
      return data.filter(q => {
        if (!q.date) return false;
        const qsoDate = new Date(q.date);
        return qsoDate >= cutoff;
      });
    }
    
    function updateMapMarkers() {
      markersLayer.clearLayers();
      linesLayer.clearLayers();
      
      const bandFilter = document.getElementById('band-filter').value;
      const timeFilter = document.getElementById('time-filter').value;
      const showLines = document.getElementById('show-lines').checked;
      
      let filtered = filterByTime(qsoData, timeFilter);
      
      filtered.forEach(qso => {
        if (!qso.lat || !qso.lon) return;
        if (bandFilter !== 'all' && qso.band !== bandFilter) return;
        
        const color = BAND_COLORS[qso.band] || '#888';
        const info = getCountryInfo(qso.call);
        
        const marker = L.circleMarker([qso.lat, qso.lon], {
          radius: 6, fillColor: color, color: '#fff',
          weight: 1, fillOpacity: 0.8
        });
        
        marker.bindPopup(
          '<strong style="color:' + color + '">' + qso.call + '</strong><br>' +
          info.c + '<br>' +
          qso.grid + ' &bull; ' + qso.band + ' ' + qso.mode + '<br>' +
          qso.date + ' ' + qso.time + ' UTC'
        );
        
        markersLayer.addLayer(marker);
        
        if (showLines) {
          const line = L.polyline([[MY_LAT, MY_LON], [qso.lat, qso.lon]], {
            color: color, weight: 1, opacity: 0.3
          });
          linesLayer.addLayer(line);
        }
      });
    }
    
    function initLogFilters() {
      document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.addEventListener('click', function() {
          document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
          this.classList.add('active');
          updateQsoTable(this.dataset.days);
        });
      });
    }
    
    function updateQsoTable(days = 'all') {
      const filtered = filterByTime(qsoData, days);
      const tbody = document.getElementById('qso-tbody');
      
      tbody.innerHTML = filtered.slice(0, 500).map(qso => {
        const info = getCountryInfo(qso.call);
        return '<tr>' +
          '<td>' + qso.date + '</td>' +
          '<td>' + qso.time + '</td>' +
          '<td class="call">' + qso.call + '</td>' +
          '<td><span class="flag">' + info.f + '</span>' + info.c + '</td>' +
          '<td>' + qso.grid + '</td>' +
          '<td class="band-' + qso.band + '">' + qso.band + '</td>' +
          '<td>' + qso.mode + '</td>' +
          '<td>' + qso.rstSent + ' / ' + qso.rstRcvd + '</td>' +
          '</tr>';
      }).join('');
      
      document.getElementById('log-stats').textContent = 
        'Showing ' + Math.min(filtered.length, 500) + ' of ' + filtered.length + ' QSOs' +
        (days !== 'all' ? ' (last ' + days + ' days)' : '');
    }
    
    function updatePropHeatmap() {
      const container = document.getElementById('prop-heatmap');
      
      if (!decodeData.bands || Object.keys(decodeData.bands).length === 0) {
        container.innerHTML = '<div class="empty-state">' +
          '<h3>No Propagation Data Available</h3>' +
          '<p>Propagation data requires parsing your WSJT-X ALL.TXT file. ' +
          'Edit the PowerShell script and set <code>$SkipAllTxt = $false</code> to enable this feature.</p>' +
          '</div>';
        return;
      }
      
      const bands = ['6m', '10m', '12m', '15m', '17m', '20m', '30m', '40m', '80m', '160m'];
      const hours = Array.from({length: 24}, (_, i) => i);
      
      const bandHourCounts = {};
      bands.forEach(band => {
        bandHourCounts[band] = Array(24).fill(0);
        if (decodeData.bands[band]) {
          decodeData.bands[band].forEach(d => {
            const hour = parseInt(d.hour.split(' ')[1]);
            bandHourCounts[band][hour] += d.count;
          });
        }
      });
      
      let maxCount = 1;
      Object.values(bandHourCounts).forEach(arr => {
        arr.forEach(c => { if (c > maxCount) maxCount = c; });
      });
      
      let html = '<div class="prop-grid">';
      html += '<div class="prop-label"></div>';
      hours.forEach(h => {
        html += '<div class="prop-hour">' + h.toString().padStart(2, '0') + '</div>';
      });
      
      bands.forEach(band => {
        html += '<div class="prop-label band-' + band + '">' + band + '</div>';
        hours.forEach(h => {
          const count = bandHourCounts[band][h];
          const intensity = count / maxCount;
          const color = BAND_COLORS[band] || '#888';
          const alpha = Math.min(0.1 + intensity * 0.9, 1);
          html += '<div class="prop-cell" style="background: ' + color + '; opacity: ' + alpha.toFixed(2) + ';" title="' + band + ' @ ' + h + ':00 UTC: ' + count + ' decodes"></div>';
        });
      });
      
      html += '</div>';
      html += '<p style="font-size: 0.75rem; color: var(--text-muted); text-align: center;">Hours in UTC</p>';
      
      container.innerHTML = html;
    }
    
    function initPskReporter() {
      loadPskData();
      document.getElementById('refresh-psk').addEventListener('click', loadPskData);
    }
    
    async function loadPskData() {
      document.getElementById('tx-spots').innerHTML = 'Loading...';
      document.getElementById('rx-spots').innerHTML = 'Loading...';
      
      const txUrl = 'https://pskreporter.info/cgi-bin/pskquery5.pl?' +
        'encap=0&callback=processTx&statistics=0&noactive=1&nolocator=0&senderCallsign=' + MY_CALL;
      const rxUrl = 'https://pskreporter.info/cgi-bin/pskquery5.pl?' +
        'encap=0&callback=processRx&statistics=0&noactive=1&nolocator=0&receiverCallsign=' + MY_CALL;
      
      loadJsonp(txUrl, 'processTx');
      loadJsonp(rxUrl, 'processRx');
    }
    
    function loadJsonp(url, callbackName) {
      const script = document.createElement('script');
      script.src = url;
      document.body.appendChild(script);
      script.onload = () => script.remove();
      script.onerror = () => {
        script.remove();
        const el = document.getElementById(callbackName === 'processTx' ? 'tx-spots' : 'rx-spots');
        el.innerHTML = '<p style="color: var(--text-muted);">Could not load data. Try refreshing.</p>';
      };
    }
    
    window.processTx = function(data) {
      const spots = parseReceptionReports(data, 'tx');
      renderSpots('tx-spots', spots, 'tx');
      document.getElementById('tx-count').textContent = '(' + spots.length + ' spots)';
    };
    
    window.processRx = function(data) {
      const spots = parseReceptionReports(data, 'rx');
      renderSpots('rx-spots', spots, 'rx');
      document.getElementById('rx-count').textContent = '(' + spots.length + ' spots)';
    };
    
    function parseReceptionReports(data, type) {
      const spots = [];
      if (!data || !data.receptionReport) return spots;
      
      const reports = Array.isArray(data.receptionReport) ? data.receptionReport : [data.receptionReport];
      
      reports.forEach(r => {
        spots.push({
          senderCall: r.senderCallsign || '',
          senderLoc: r.senderLocator || '',
          receiverCall: r.receiverCallsign || '',
          receiverLoc: r.receiverLocator || '',
          frequency: r.frequency ? (parseFloat(r.frequency) / 1000000).toFixed(3) : '',
          snr: r.sNR || '',
          mode: r.mode || '',
          time: r.flowStartSeconds ? new Date(parseInt(r.flowStartSeconds) * 1000).toISOString().substr(11, 5) : ''
        });
      });
      
      spots.sort((a, b) => b.time.localeCompare(a.time));
      return spots.slice(0, 100);
    }
    
    function renderSpots(elementId, spots, type) {
      const el = document.getElementById(elementId);
      
      if (spots.length === 0) {
        el.innerHTML = '<p style="color: var(--text-muted); padding: 20px;">No spots in the last 24 hours.</p>';
        return;
      }
      
      el.innerHTML = spots.map(s => {
        const call = type === 'tx' ? s.receiverCall : s.senderCall;
        const loc = type === 'tx' ? s.receiverLoc : s.senderLoc;
        const info = getCountryInfo(call);
        const snrNum = parseInt(s.snr);
        const snrClass = snrNum >= 0 ? 'good' : (snrNum >= -10 ? 'ok' : 'weak');
        
        return '<div class="spot">' +
          '<div><span class="call">' + call + '</span><br><span class="country"><span class="flag">' + info.f + '</span>' + info.c + '</span></div>' +
          '<div class="info">' + s.frequency + ' MHz<br>' + s.mode + '</div>' +
          '<div class="snr ' + snrClass + '">' + s.snr + ' dB</div>' +
          '<div class="info">' + s.time + 'z</div>' +
          '</div>';
      }).join('');
    }
  </script>
</body>
</html>
"@

$html | Set-Content -Encoding UTF8 $IndexFile

Write-Host "Dashboard generated at $IndexFile"

if (Test-Path $IndexFile) {
  Write-Host "SUCCESS: index.html created successfully!"
} else {
  Write-Host "ERROR: index.html was NOT created!"
}

# ---- git commit + push ----
Set-Location $RepoRoot
git add . | Out-Null

$diff = git status --porcelain
if (-not $diff) {
  Write-Host "No changes to publish."
  exit 0
}

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
git commit -m "FT8 Dashboard update $ts" | Out-Null
git push | Out-Null

Write-Host "FT8 Dashboard published successfully!"
