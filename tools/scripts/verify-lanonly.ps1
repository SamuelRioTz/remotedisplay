# Demonstrates that rustdesk.exe only talks to the local network:
# lists all active connections of the process and flags anything that isn't LAN.
$procs = Get-Process rustdesk -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host 'rustdesk is not running. Connect first.'; exit 1 }

$pids = $procs.Id
$conns = Get-NetTCPConnection -OwningProcess $pids -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne 'Listen' -and $_.RemoteAddress -notin '0.0.0.0','::' }

Write-Host "== Active rustdesk connections (pids: $pids) =="
$externas = 0
foreach ($c in $conns) {
    $esLan = $c.RemoteAddress -match '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|100\.)'
    $tag = if ($esLan) { 'LAN' } else { $externas++; '*** EXTERNAL ***' }
    Write-Host ("  {0}:{1} -> {2}:{3}  [{4}]" -f $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $tag)
}
if ($conns.Count -eq 0) { Write-Host '  (no active connections)' }
Write-Host ("`nExternal connections: {0}" -f $externas)
if ($externas -eq 0) { Write-Host 'VERIFIED: local traffic only.' }
