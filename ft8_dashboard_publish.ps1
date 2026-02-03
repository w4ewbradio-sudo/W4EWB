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

# Check if WSJT-X directory exists, try alternate locations
if (-not (Test-Path $WsjtxDir)) {
  # Try other common locations
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
    
    # Extract fields with regex: <FIELD:length>value
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
  param([string]$FilePath, [int]$MaxLines = 50000)
  
  if (-not (Test-Path $FilePath)) { return @() }
  
  # Read last N lines for performance
  $lines = Get-Content $FilePath -Tail $MaxLines -ErrorAction SilentlyContinue
  
  $decodes = @()
  
  foreach ($line in $lines) {
    # Format: 231215_234500    14.074 Rx FT8    -10  0.2 1523 CQ DX K1ABC FN42
    if ($line -match "^(\d{6})_(\d{6})\s+(\d+\.\d+)\s+Rx\s+(\w+)\s+(-?\d+)\s+[\d.]+\s+\d+\s+(.*)$") {
      $dateStr = $matches[1]
      $timeStr = $matches[2]
      $freq = [double]$matches[3]
      $mode = $matches[4]
      $snr = [int]$matches[5]
      $message = $matches[6]
      
      # Determine band from frequency
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
      
      # Extract grid from message if present
      $grid = ""
      if ($message -match "\b([A-R]{2}\d{2}[a-x]{0,2})\b") {
        $grid = $matches[1]
      }
      
      # Extract callsign (rough parse)
      $call = ""
      $parts = $message -split "\s+"
      foreach ($part in $parts) {
        if ($part -match "^[A-Z0-9]{1,3}[0-9][A-Z0-9]{0,3}[A-Z]$") {
          $call = $part
          break
        }
      }
      
      # Parse date
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
  
  # Format date nicely
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
Write-Host "Looking for ALL.TXT at $allTxtFile"

$decodes = @()
if (Test-Path $allTxtFile) {
  Write-Host "Found ALL.TXT, parsing decodes..."
  $decodes = Parse-AllTxt -FilePath $allTxtFile -MaxLines 100000
  Write-Host "Parsed $($decodes.Count) decodes"
} else {
  Write-Host "ALL.TXT not found - propagation data will be empty (this is OK)"
}

# Aggregate decode stats by band and hour (last 7 days)
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
        
        # Keep last 1000 decodes with grids for map
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

# Convert band stats to array format for JSON
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
      --purple: #a371f7;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: system-ui, -apple-system, 'Segoe UI', sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    .container { max-width: 1600px; margin: 0 auto; padding: 20px; }
    
    /* Header */
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
    .title-section h1 {
      font-size: 1.8rem;
      font-weight: 600;
      color: #fff;
    }
    .title-section h1 .call { color: var(--accent); }
    .title-section .subtitle {
      color: var(--text-muted);
      font-size: 0.95rem;
      margin-top: 4px;
    }
    .title-section .subtitle a { color: var(--accent); text-decoration: none; }
    .title-section .subtitle a:hover { text-decoration: underline; }
    
    .stats-row {
      display: flex;
      gap: 20px;
      flex-wrap: wrap;
    }
    .stat-box {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px 20px;
      text-align: center;
    }
    .stat-box .value {
      font-size: 1.8rem;
      font-weight: 600;
      color: var(--accent);
    }
    .stat-box .label {
      font-size: 0.8rem;
      color: var(--text-muted);
      text-transform: uppercase;
    }
    
    /* Tabs */
    .tabs {
      display: flex;
      gap: 8px;
      margin-bottom: 20px;
      border-bottom: 1px solid var(--border);
      padding-bottom: 12px;
    }
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
    .tab.active {
      background: var(--accent);
      border-color: var(--accent);
      color: #0d1117;
      font-weight: 500;
    }
    
    /* Panels */
    .panel { display: none; }
    .panel.active { display: block; }
    
    /* Map */
    #map {
      height: 500px;
      border-radius: 10px;
      border: 1px solid var(--border);
      margin-bottom: 20px;
    }
    
    /* Map controls */
    .map-controls {
      display: flex;
      gap: 12px;
      margin-bottom: 16px;
      flex-wrap: wrap;
      align-items: center;
    }
    .map-controls label {
      font-size: 0.85rem;
      color: var(--text-muted);
    }
    .map-controls select, .map-controls input {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 6px 12px;
      color: var(--text);
      font-size: 0.85rem;
    }
    .band-toggle {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      font-size: 0.8rem;
      cursor: pointer;
    }
    .band-toggle input { margin: 0; }
    .band-toggle.active { border-color: var(--accent); }
    
    /* Band colors */
    .band-160m { color: #ff6b6b; }
    .band-80m { color: #ffa94d; }
    .band-60m { color: #ffd43b; }
    .band-40m { color: #69db7c; }
    .band-30m { color: #38d9a9; }
    .band-20m { color: #4dabf7; }
    .band-17m { color: #748ffc; }
    .band-15m { color: #9775fa; }
    .band-12m { color: #da77f2; }
    .band-10m { color: #f783ac; }
    .band-6m { color: #e599f7; }
    
    /* Propagation heatmap */
    .prop-grid {
      display: grid;
      grid-template-columns: 60px repeat(24, 1fr);
      gap: 2px;
      font-size: 0.7rem;
      margin-bottom: 20px;
    }
    .prop-cell {
      aspect-ratio: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 3px;
      font-weight: 500;
    }
    .prop-label {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      padding-right: 8px;
      font-weight: 500;
    }
    .prop-hour {
      text-align: center;
      color: var(--text-muted);
      font-size: 0.65rem;
    }
    
    /* PSK Reporter section */
    .psk-section {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
    }
    @media (max-width: 900px) {
      .psk-section { grid-template-columns: 1fr; }
    }
    .psk-card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 16px;
    }
    .psk-card h3 {
      font-size: 1rem;
      margin-bottom: 12px;
      color: var(--text);
    }
    .psk-card h3 .count {
      font-weight: normal;
      color: var(--text-muted);
    }
    .spot-list {
      max-height: 400px;
      overflow-y: auto;
    }
    .spot {
      display: flex;
      justify-content: space-between;
      padding: 8px 0;
      border-bottom: 1px solid var(--border);
      font-size: 0.85rem;
    }
    .spot:last-child { border-bottom: none; }
    .spot .call { font-weight: 500; color: var(--accent); }
    .spot .info { color: var(--text-muted); }
    .spot .snr { font-weight: 500; }
    .spot .snr.good { color: var(--green); }
    .spot .snr.ok { color: var(--yellow); }
    .spot .snr.weak { color: var(--red); }
    
    /* QSO Log table */
    .qso-table-wrap {
      overflow-x: auto;
      border: 1px solid var(--border);
      border-radius: 10px;
    }
    .qso-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.85rem;
    }
    .qso-table th, .qso-table td {
      padding: 10px 14px;
      text-align: left;
      border-bottom: 1px solid var(--border);
    }
    .qso-table th {
      background: var(--card-bg);
      font-weight: 500;
      color: var(--text-muted);
      text-transform: uppercase;
      font-size: 0.75rem;
    }
    .qso-table tr:hover { background: rgba(88, 166, 255, 0.05); }
    .qso-table .call { color: var(--accent); font-weight: 500; }
    
    /* Footer */
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
    
    /* Loading */
    .loading {
      text-align: center;
      padding: 40px;
      color: var(--text-muted);
    }
    .loading::after {
      content: '';
      display: inline-block;
      width: 20px;
      height: 20px;
      border: 2px solid var(--border);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin-left: 10px;
      vertical-align: middle;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    
    /* Responsive */
    @media (max-width: 768px) {
      .container { padding: 12px; }
      header { flex-direction: column; }
      .title-section h1 { font-size: 1.4rem; }
      #map { height: 350px; }
      .prop-grid { font-size: 0.6rem; }
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
          <a href="https://www.qrz.com/db/$MyCallsign" target="_blank">QRZ Profile</a> &bull;
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
        <label>Filter by band:</label>
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
        <label>
          <input type="checkbox" id="show-lines" checked> Show path lines
        </label>
        <label>
          <input type="checkbox" id="show-decodes"> Show recent decodes
        </label>
      </div>
      <div id="map"></div>
    </div>
    
    <!-- Propagation Panel -->
    <div id="prop-panel" class="panel">
      <h3 style="margin-bottom: 16px;">Band Activity Heatmap (Last 7 Days)</h3>
      <p style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 20px;">
        Based on FT8 decodes from your station. Brighter = more activity.
      </p>
      <div id="prop-heatmap" class="loading">Loading propagation data...</div>
    </div>
    
    <!-- PSK Reporter Panel -->
    <div id="psk-panel" class="panel">
      <p style="color: var(--text-muted); font-size: 0.85rem; margin-bottom: 20px;">
        Live data from PSK Reporter (last 24 hours). 
        <button id="refresh-psk" style="background: var(--accent); border: none; padding: 4px 12px; border-radius: 4px; color: #000; cursor: pointer; font-size: 0.8rem;">Refresh</button>
      </p>
      <div class="psk-section">
        <div class="psk-card">
          <h3>📡 Where I'm Being Heard <span class="count" id="tx-count"></span></h3>
          <div id="tx-spots" class="spot-list loading">Loading TX spots...</div>
        </div>
        <div class="psk-card">
          <h3>📻 What I'm Hearing <span class="count" id="rx-count"></span></h3>
          <div id="rx-spots" class="spot-list loading">Loading RX spots...</div>
        </div>
      </div>
    </div>
    
    <!-- QSO Log Panel -->
    <div id="log-panel" class="panel">
      <div class="qso-table-wrap">
        <table class="qso-table">
          <thead>
            <tr>
              <th>Date</th>
              <th>Time</th>
              <th>Callsign</th>
              <th>Grid</th>
              <th>Band</th>
              <th>Mode</th>
              <th>RST Sent</th>
              <th>RST Rcvd</th>
            </tr>
          </thead>
          <tbody id="qso-tbody">
          </tbody>
        </table>
      </div>
    </div>
    
    <footer>
      73 de $MyCallsign &bull;
      <a href="https://www.qrz.com/db/$MyCallsign">QRZ</a> &bull;
      <a href="../sstv/rx/">SSTV Gallery</a> &bull;
      Dashboard auto-generated from WSJT-X logs
    </footer>
  </div>
  
  <script>
    // Configuration
    const MY_CALL = '$MyCallsign';
    const MY_GRID = '$MyGrid';
    const MY_LAT = $MyLat;
    const MY_LON = $MyLon;
    
    // Band colors
    const BAND_COLORS = {
      '160m': '#ff6b6b', '80m': '#ffa94d', '60m': '#ffd43b',
      '40m': '#69db7c', '30m': '#38d9a9', '20m': '#4dabf7',
      '17m': '#748ffc', '15m': '#9775fa', '12m': '#da77f2',
      '10m': '#f783ac', '6m': '#e599f7', '2m': '#fcc419'
    };
    
    // State
    let qsoData = [];
    let decodeData = {};
    let map, markersLayer, linesLayer, decodesLayer;
    
    // Initialize
    document.addEventListener('DOMContentLoaded', async () => {
      initTabs();
      initMap();
      await loadData();
      initPskReporter();
    });
    
    // Tab switching
    function initTabs() {
      document.querySelectorAll('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
          document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
          document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
          tab.classList.add('active');
          document.getElementById(tab.dataset.panel).classList.add('active');
          if (map) map.invalidateSize();
        });
      });
    }
    
    // Map initialization
    function initMap() {
      map = L.map('map').setView([MY_LAT, MY_LON], 3);
      
      L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
        attribution: '&copy; OpenStreetMap, &copy; CartoDB',
        maxZoom: 19
      }).addTo(map);
      
      // Add home marker
      L.circleMarker([MY_LAT, MY_LON], {
        radius: 10, fillColor: '#58a6ff', color: '#fff',
        weight: 2, fillOpacity: 1
      }).addTo(map).bindPopup('<strong>' + MY_CALL + '</strong><br>' + MY_GRID);
      
      markersLayer = L.layerGroup().addTo(map);
      linesLayer = L.layerGroup().addTo(map);
      decodesLayer = L.layerGroup();
      
      // Controls
      document.getElementById('band-filter').addEventListener('change', updateMapMarkers);
      document.getElementById('show-lines').addEventListener('change', updateMapMarkers);
      document.getElementById('show-decodes').addEventListener('change', () => {
        if (document.getElementById('show-decodes').checked) {
          decodesLayer.addTo(map);
        } else {
          decodesLayer.remove();
        }
      });
    }
    
    // Load QSO and decode data
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
        updateDecodeMarkers();
      } catch (e) {
        console.error('Error loading data:', e);
      }
    }
    
    // Update statistics
    function updateStats() {
      document.getElementById('total-qsos').textContent = qsoData.length;
      
      const grids = new Set(qsoData.map(q => q.grid).filter(g => g));
      document.getElementById('total-grids').textContent = grids.size;
      
      // Rough DXCC count from callsign prefixes
      const prefixes = new Set();
      qsoData.forEach(q => {
        const match = q.call.match(/^([A-Z0-9]{1,2})/);
        if (match) prefixes.add(match[1]);
      });
      document.getElementById('total-dxcc').textContent = prefixes.size;
    }
    
    // Update map markers
    function updateMapMarkers() {
      markersLayer.clearLayers();
      linesLayer.clearLayers();
      
      const bandFilter = document.getElementById('band-filter').value;
      const showLines = document.getElementById('show-lines').checked;
      
      qsoData.forEach(qso => {
        if (!qso.lat || !qso.lon) return;
        if (bandFilter !== 'all' && qso.band !== bandFilter) return;
        
        const color = BAND_COLORS[qso.band] || '#888';
        
        const marker = L.circleMarker([qso.lat, qso.lon], {
          radius: 6, fillColor: color, color: '#fff',
          weight: 1, fillOpacity: 0.8
        });
        
        marker.bindPopup(
          '<strong class="band-' + qso.band + '">' + qso.call + '</strong><br>' +
          qso.grid + ' • ' + qso.band + ' ' + qso.mode + '<br>' +
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
    
    // Update decode markers (for recent RX)
    function updateDecodeMarkers() {
      if (!decodeData.recentDecodes) return;
      
      decodeData.recentDecodes.forEach(dec => {
        if (!dec.lat || !dec.lon) return;
        
        const color = BAND_COLORS[dec.band] || '#888';
        
        const marker = L.circleMarker([dec.lat, dec.lon], {
          radius: 4, fillColor: color, color: color,
          weight: 1, fillOpacity: 0.4
        });
        
        marker.bindPopup(
          dec.call + '<br>' + dec.grid + ' • ' + dec.band + '<br>' +
          'SNR: ' + dec.snr + ' dB'
        );
        
        decodesLayer.addLayer(marker);
      });
    }
    
    // Update QSO table
    function updateQsoTable() {
      const tbody = document.getElementById('qso-tbody');
      tbody.innerHTML = qsoData.slice(0, 500).map(qso => 
        '<tr>' +
        '<td>' + qso.date + '</td>' +
        '<td>' + qso.time + '</td>' +
        '<td class="call">' + qso.call + '</td>' +
        '<td>' + qso.grid + '</td>' +
        '<td class="band-' + qso.band + '">' + qso.band + '</td>' +
        '<td>' + qso.mode + '</td>' +
        '<td>' + qso.rstSent + '</td>' +
        '<td>' + qso.rstRcvd + '</td>' +
        '</tr>'
      ).join('');
    }
    
    // Propagation heatmap
    function updatePropHeatmap() {
      if (!decodeData.bands) {
        document.getElementById('prop-heatmap').innerHTML = '<p>No propagation data available.</p>';
        return;
      }
      
      const bands = ['6m', '10m', '12m', '15m', '17m', '20m', '30m', '40m', '80m', '160m'];
      const hours = Array.from({length: 24}, (_, i) => i);
      
      // Get last 7 days of data, aggregated by hour of day
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
      
      // Find max for scaling
      let maxCount = 1;
      Object.values(bandHourCounts).forEach(arr => {
        arr.forEach(c => { if (c > maxCount) maxCount = c; });
      });
      
      let html = '<div class="prop-grid">';
      
      // Header row
      html += '<div class="prop-label"></div>';
      hours.forEach(h => {
        html += '<div class="prop-hour">' + h.toString().padStart(2, '0') + '</div>';
      });
      
      // Band rows
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
      html += '<p style="font-size: 0.75rem; color: var(--text-muted); text-align: center;">Hours are in UTC. Data from the last 7 days.</p>';
      
      document.getElementById('prop-heatmap').innerHTML = html;
    }
    
    // PSK Reporter integration
    function initPskReporter() {
      loadPskData();
      document.getElementById('refresh-psk').addEventListener('click', loadPskData);
    }
    
    async function loadPskData() {
      document.getElementById('tx-spots').innerHTML = '<div class="loading">Loading TX spots...</div>';
      document.getElementById('rx-spots').innerHTML = '<div class="loading">Loading RX spots...</div>';
      
      try {
        // TX spots (where I'm being heard)
        const txUrl = 'https://pskreporter.info/cgi-bin/pskquery5.pl?' +
          'encap=0&callback=processTx&statistics=0&noactive=1&nolocator=0&senderCallsign=' + MY_CALL;
        
        // RX spots (what I'm hearing)
        const rxUrl = 'https://pskreporter.info/cgi-bin/pskquery5.pl?' +
          'encap=0&callback=processRx&statistics=0&noactive=1&nolocator=0&receiverCallsign=' + MY_CALL;
        
        // Use JSONP via script injection
        loadJsonp(txUrl, 'processTx');
        loadJsonp(rxUrl, 'processRx');
        
      } catch (e) {
        console.error('PSK Reporter error:', e);
        document.getElementById('tx-spots').innerHTML = '<p>Error loading PSK Reporter data.</p>';
        document.getElementById('rx-spots').innerHTML = '<p>Error loading PSK Reporter data.</p>';
      }
    }
    
    function loadJsonp(url, callbackName) {
      const script = document.createElement('script');
      script.src = url;
      document.body.appendChild(script);
      script.onload = () => script.remove();
      script.onerror = () => {
        script.remove();
        document.getElementById(callbackName === 'processTx' ? 'tx-spots' : 'rx-spots')
          .innerHTML = '<p>Could not load PSK Reporter data. Try refreshing.</p>';
      };
    }
    
    // JSONP callbacks
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
      
      // Sort by time descending
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
        const snrNum = parseInt(s.snr);
        const snrClass = snrNum >= 0 ? 'good' : (snrNum >= -10 ? 'ok' : 'weak');
        
        return '<div class="spot">' +
          '<div><span class="call">' + call + '</span> <span class="info">' + loc + '</span></div>' +
          '<div class="info">' + s.frequency + ' MHz ' + s.mode + '</div>' +
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

# Verify the file was created
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
