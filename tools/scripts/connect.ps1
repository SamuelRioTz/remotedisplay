# Connects to the Mac via direct IP (no server in between).
param(
    [string]$MacHost
)

$cfg = Get-Content (Join-Path $PSScriptRoot '..\config.local.json') | ConvertFrom-Json
if (-not $MacHost) { $MacHost = $cfg.macHost }

& $cfg.clientExe --connect $MacHost --password $cfg.rustdeskPassword
