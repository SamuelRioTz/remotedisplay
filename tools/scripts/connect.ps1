# Conecta al Mac por IP directa (sin ningun servidor de por medio).
param(
    [string]$MacHost
)

$cfg = Get-Content (Join-Path $PSScriptRoot '..\config.local.json') | ConvertFrom-Json
if (-not $MacHost) { $MacHost = $cfg.macHost }

& $cfg.clientExe --connect $MacHost --password $cfg.rustdeskPassword
