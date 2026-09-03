# Trae por scp los artefactos que produjo tools/release-mac.sh en el Mac y los sube
# al GitHub Release del repo (el Mac no tiene gh; acá sí, autenticado).
# Uso:  powershell -ExecutionPolicy Bypass -File tools/release-fetch-mac.ps1 [-Tag v0.1.0]
param([string]$Tag = '')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $PSCommandPath) '..')
$cfg = Get-Content (Join-Path $root 'remotedisplay\config.local.json') | ConvertFrom-Json
$out = Join-Path $root 'remotedisplay\out'; New-Item -ItemType Directory -Force $out | Out-Null
$version = ((Get-Content (Join-Path $root 'client\pubspec.yaml') | Select-String '^version:') -replace 'version:\s*', '' -split '\+')[0].Trim()
if (-not $Tag) { $Tag = "v$version" }
$remote = "$($cfg.sshUser)@$($cfg.macHost)"
$files = ssh -o BatchMode=yes $remote "ls ~/workspace/remotedisplay/release/out/RemoteDisplay-*$version* 2>/dev/null"
if (-not $files) { throw "No hay artefactos $version en el Mac (correr tools/release-mac.sh alla)" }
foreach ($f in $files) { scp -o BatchMode=yes "${remote}:$f" $out; Write-Host "traido: $(Split-Path $f -Leaf)" }
Push-Location $root
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
gh release view $Tag *> $null; $exists = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $prev
if (-not $exists) { gh release create $Tag --title "Remote Display $version" --notes "Build $version." | Out-Null }
$local = $files | ForEach-Object { Join-Path $out (Split-Path $_ -Leaf) }
gh release upload $Tag @local --clobber
Pop-Location
Write-Host "subido a GitHub Releases ($Tag)"
