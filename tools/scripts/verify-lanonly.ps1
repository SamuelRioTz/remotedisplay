# Demuestra que rustdesk.exe solo habla con la red local:
# lista todas las conexiones activas del proceso y marca cualquiera que no sea LAN.
$procs = Get-Process rustdesk -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host 'rustdesk no esta corriendo. Conectate primero.'; exit 1 }

$pids = $procs.Id
$conns = Get-NetTCPConnection -OwningProcess $pids -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne 'Listen' -and $_.RemoteAddress -notin '0.0.0.0','::' }

Write-Host "== Conexiones activas de rustdesk (pids: $pids) =="
$externas = 0
foreach ($c in $conns) {
    $esLan = $c.RemoteAddress -match '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|100\.)'
    $tag = if ($esLan) { 'LAN' } else { $externas++; '*** EXTERNA ***' }
    Write-Host ("  {0}:{1} -> {2}:{3}  [{4}]" -f $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $tag)
}
if ($conns.Count -eq 0) { Write-Host '  (sin conexiones activas)' }
Write-Host ("`nConexiones externas: {0}" -f $externas)
if ($externas -eq 0) { Write-Host 'VERIFICADO: solo trafico local.' }
