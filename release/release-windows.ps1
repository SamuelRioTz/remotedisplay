# Release Windows de Remote Display: compila el cliente (Dart), asegura la DLL del motor,
# arma el ZIP portable y el instalador Inno Setup en release/out/, y opcionalmente
# sube todo a un GitHub Release del repo (privado) con `gh`.
#
# Uso:  powershell -ExecutionPolicy Bypass -File release/release-windows.ps1 [-Tag v0.1.0] [-Upload] [-SkipBuild]
#   -Tag        etiqueta del release (default: v<version de client/pubspec.yaml>)
#   -Upload     crea (si no existe) el GitHub Release y sube los artefactos
#   -SkipBuild  no recompila el cliente Flutter (usa el Release existente)
# Requisitos: Flutter 3.24.5 (via fvm: C:\Users\sam\fvm\versions\3.24.5), Inno Setup 6, gh autenticado
# y apuntando a ESTE repo (el repo es fork: `gh repo set-default SamuelRioTz/remotedisplay`).
# La DLL del motor (engine/rustdesk/target/release/librustdesk.dll) se compila aparte
# (receta y trampas en tools/README.md, "Compilar el CLIENTE Windows").
param([string]$Tag = '', [switch]$Upload, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $PSCommandPath) '..')
$client = Join-Path $root 'client'
$release = Join-Path $client 'build\windows\x64\runner\Release'
$out = Join-Path $root 'release\out'
New-Item -ItemType Directory -Force $out | Out-Null

$version = ((Get-Content (Join-Path $client 'pubspec.yaml') | Select-String '^version:') -replace 'version:\s*', '' -split '\+')[0].Trim()
if (-not $Tag) { $Tag = "v$version" }
Write-Host "Remote Display $version  (tag $Tag)"

if (-not $SkipBuild) {
  $env:PATH = "C:\Users\sam\fvm\versions\3.24.5\bin;$env:PATH"
  Push-Location $client
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build fallo' }
  Pop-Location
}

# DLL del motor: la mas nueva entre la del target de cargo y la ya ensamblada.
$dllSrc = Join-Path $root 'engine\rustdesk\target\release\librustdesk.dll'
$dllDst = Join-Path $release 'librustdesk.dll'
if (Test-Path $dllSrc) {
  if (-not (Test-Path $dllDst) -or (Get-Item $dllSrc).LastWriteTime -gt (Get-Item $dllDst).LastWriteTime) {
    Copy-Item $dllSrc $dllDst -Force; Write-Host 'librustdesk.dll actualizada desde target/release'
  }
}
if (-not (Test-Path $dllDst)) { throw "falta $dllDst (compilar el motor primero)" }

# 1) ZIP portable (la carpeta Release corre desde cualquier lado, sin instalar)
$zip = Join-Path $out "RemoteDisplay-$version-windows-x64-portable.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $release '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host "portable: $zip"

# 2) Instalador Inno Setup
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe', 'C:\Program Files\Inno Setup 6\ISCC.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'No se encontro ISCC.exe (winget install JRSoftware.InnoSetup)' }
& $iscc /Q "/DAppVersion=$version" "/DSourceDir=$release" "/DOutDir=$out" (Join-Path $root 'release\windows\remotedisplay.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC fallo' }
$setup = Join-Path $out "RemoteDisplay-Setup-$version.exe"
Write-Host "instalador: $setup"

# 3) GitHub Release (repo privado: solo colaboradores lo ven)
if ($Upload) {
  Push-Location $root
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  gh release view $Tag *> $null; $exists = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prev
  if (-not $exists) {
    gh release create $Tag --title "Remote Display $version" --notes "Build $version. Windows: instalador + portable. Mac/Android/iOS: ver assets." | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gh release create fallo' }
    Write-Host "release $Tag creado"
  }
  gh release upload $Tag $zip $setup --clobber
  if ($LASTEXITCODE -ne 0) { throw 'gh release upload fallo' }
  Write-Host "subido a GitHub Releases ($Tag)"
  Pop-Location
}
Write-Host 'OK'
