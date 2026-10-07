# Remote Display - client discovery diagnostics (Windows). READ-ONLY.
#
# Dumps what the home screen groups computers from, so a "same Mac shown twice" or a
# "no computers found" report can be settled in minutes:
#   - the discovered peers cache (lan_peers.toml): one entry per address, with the engine id
#     (machine_id) when the host's discovery reply reached this PC, empty for addresses the
#     port scan found only;
#   - every recent peer (peers\*.toml): the identity saved at the last connection to that
#     address (hostname, platform, username, machine_id);
#   - the home's own local options (rd-fingerprints, rd-last-keys, rd-aliases, ...);
#   - the Windows Firewall rules that name remotedisplay.exe;
#   - the last discovery lines of the client log ("discover ping sent", "discover done: N
#     replies, M port hits" - hits without replies = the UDP replies are being dropped).
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools\scripts\discovery-diag.ps1 [-Out report.txt]
param([string]$Out)

$ErrorActionPreference = 'Continue'
$cfg = Join-Path $env:APPDATA 'RemoteDisplay\config'
$log = Join-Path $env:APPDATA 'RemoteDisplay\log'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s) }

Say "Remote Display discovery diagnostics - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $env:COMPUTERNAME"
Say "config: $cfg"
Say ""

# Installed client version(s)
Say "== client binaries =="
foreach ($p in @("$env:LOCALAPPDATA\Programs\Remote Display\remotedisplay.exe",
                 "$env:ProgramFiles\Remote Display\remotedisplay.exe")) {
  if (Test-Path $p) { $v = (Get-Item $p).VersionInfo.FileVersion; Say "  $p  ($v)" }
}
Get-Process remotedisplay -ErrorAction SilentlyContinue | ForEach-Object {
  Say "  running: $($_.Path)"
}
Say ""

# Discovered peers cache
Say "== discovered peers (RemoteDisplay_lan_peers.toml) =="
$lan = Join-Path $cfg 'RemoteDisplay_lan_peers.toml'
if (Test-Path $lan) {
  $cur = @{}
  foreach ($l in Get-Content $lan) {
    if ($l -match '^\[\[peers\]\]') {
      if ($cur.Count) { Say ("  {0,-22} id={1,-10} host={2,-24} platform={3,-8} user={4,-10} online={5}" -f $cur.id, $cur.machine_id, $cur.hostname, $cur.platform, $cur.username, $cur.online) }
      $cur = @{}
    } elseif ($l -match '^(\w+)\s*=\s*(.*)$') {
      $cur[$matches[1]] = $matches[2].Trim().Trim('"', "'")
    }
  }
  if ($cur.Count) { Say ("  {0,-22} id={1,-10} host={2,-24} platform={3,-8} user={4,-10} online={5}" -f $cur.id, $cur.machine_id, $cur.hostname, $cur.platform, $cur.username, $cur.online) }
} else { Say "  (no file)" }
Say ""

# Recent peers
Say "== recent peers (peers\*.toml -> [info]) =="
$peers = Join-Path $cfg 'peers'
if (Test-Path $peers) {
  foreach ($f in Get-ChildItem $peers -Filter '*.toml') {
    $id = $f.BaseName
    if ($id -match '^base64_(.+)$') {
      try { $id = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[1])) } catch {}
    }
    $info = @{}; $inInfo = $false; $hasPassword = $false
    foreach ($l in Get-Content $f.FullName) {
      if ($l -match '^\[(.+)\]') { $inInfo = ($matches[1] -eq 'info'); continue }
      if (-not $inInfo -and $l -match '^password\s*=\s*(.+)$' -and $matches[1].Trim() -notin @('""', "''", '[]')) { $hasPassword = $true }
      if ($inInfo -and $l -match '^(\w+)\s*=\s*(.*)$') { $info[$matches[1]] = $matches[2].Trim().Trim('"', "'") }
    }
    Say ("  {0,-22} id={1,-10} host={2,-24} platform={3,-8} user={4,-10} password={5}  ({6:yyyy-MM-dd HH:mm})" -f $id, $info.machine_id, $info.hostname, $info.platform, $info.username, $hasPassword, $f.LastWriteTime)
  }
} else { Say "  (no folder)" }
Say ""

# Home's local options
Say "== home options (RemoteDisplay_local.toml, rd-*) =="
$local = Join-Path $cfg 'RemoteDisplay_local.toml'
if (Test-Path $local) {
  Get-Content $local | Where-Object { $_ -match '^\s*"?rd-' } | ForEach-Object { Say "  $_" }
} else { Say "  (no file)" }
Say ""

# Firewall rules for the app
Say "== Windows Firewall rules naming remotedisplay.exe =="
try {
  $rules = Get-NetFirewallApplicationFilter -ErrorAction Stop |
    Where-Object { $_.Program -like '*remotedisplay.exe' } |
    Get-NetFirewallRule
  if ($rules) {
    foreach ($r in $rules) {
      $pf = ($r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)
      Say ("  {0,-8} {1,-6} enabled={2,-5} profile={3,-16} proto={4,-4} port={5,-6} {6}" -f $r.Direction, $r.Action, $r.Enabled, $r.Profile, $pf.Protocol, $pf.LocalPort, $r.DisplayName)
    }
  } else { Say "  (none - Windows will ask on the first inbound packet, or drop it silently on a public network)" }
} catch { Say "  (could not read the firewall: $($_.Exception.Message))" }
Say ""

# Client log: discovery lines
Say "== client log: last discovery lines =="
if (Test-Path $log) {
  $recent = Get-ChildItem $log -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 2
  foreach ($f in $recent) {
    Say "  -- $($f.Name)"
    Select-String -Path $f.FullName -Pattern 'discover|pong|lan discovery|port scan' |
      Select-Object -Last 12 | ForEach-Object { Say "  $($_.Line)" }
  }
} else { Say "  (no log folder)" }

$text = $lines -join "`r`n"
if ($Out) { Set-Content -Path $Out -Value $text -Encoding UTF8; Write-Host "written: $Out" } else { Write-Output $text }
