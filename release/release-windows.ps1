# Windows release for Remote Display: builds the client (Dart), ensures the engine DLL,
# assembles the portable ZIP and the Inno Setup installer in release/out/, and optionally
# uploads everything to a GitHub Release of the repo (private) with `gh`.
#
# Usage:  powershell -ExecutionPolicy Bypass -File release/release-windows.ps1 [-Tag v0.1.0] [-Upload] [-SkipBuild]
#   -Tag        release tag (default: v<version from client/pubspec.yaml>)
#   -Upload     creates (if it doesn't exist) the GitHub Release and uploads the artifacts
#   -SkipBuild  doesn't rebuild the Flutter client (uses the existing Release)
# Requirements: Flutter 3.24.5 (via fvm: C:\Users\sam\fvm\versions\3.24.5), Inno Setup 6, gh authenticated
# and pointed at THIS repo (the repo is a fork: `gh repo set-default SamuelRioTz/remotedisplay`).
# The engine DLL (engine/rustdesk/target/release/librustdesk.dll) is built separately
# (recipe and gotchas in tools/README.md, "Building the Windows CLIENT").
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
  if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
  Pop-Location
}

# Engine DLL: whichever is newer between cargo's target build and the one already bundled.
$dllSrc = Join-Path $root 'engine\rustdesk\target\release\librustdesk.dll'
$dllDst = Join-Path $release 'librustdesk.dll'
if (Test-Path $dllSrc) {
  if (-not (Test-Path $dllDst) -or (Get-Item $dllSrc).LastWriteTime -gt (Get-Item $dllDst).LastWriteTime) {
    Copy-Item $dllSrc $dllDst -Force; Write-Host 'librustdesk.dll updated from target/release'
  }
}
if (-not (Test-Path $dllDst)) { throw "missing $dllDst (build the engine first)" }

# AGPL: ship the license text and the third-party notices with the binaries
# (they end up in the portable ZIP and, via {#SourceDir}\*, in the installer).
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $release 'LICENSE.txt') -Force
Copy-Item (Join-Path $root 'NOTICE.md') (Join-Path $release 'NOTICE.md') -Force

# 1) Portable ZIP (the Release folder runs from anywhere, no install needed)
$zip = Join-Path $out "RemoteDisplay-$version-windows-x64-portable.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $release '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host "portable: $zip"

# 2) Inno Setup installer
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe', 'C:\Program Files\Inno Setup 6\ISCC.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe not found (winget install JRSoftware.InnoSetup)' }
& $iscc /Q "/DAppVersion=$version" "/DSourceDir=$release" "/DOutDir=$out" (Join-Path $root 'release\windows\remotedisplay.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
$setup = Join-Path $out "RemoteDisplay-Setup-$version.exe"
Write-Host "installer: $setup"

# 3) GitHub Release (private repo: only collaborators can see it)
if ($Upload) {
  Push-Location $root
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  gh release view $Tag *> $null; $exists = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prev
  if (-not $exists) {
    gh release create $Tag --title "Remote Display $version" --notes "Build $version. Windows: installer + portable. Mac/Android/iOS: see assets." | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }
    Write-Host "release $Tag created"
  }
  gh release upload $Tag $zip $setup --clobber
  if ($LASTEXITCODE -ne 0) { throw 'gh release upload failed' }
  Write-Host "uploaded to GitHub Releases ($Tag)"
  Pop-Location
}
Write-Host 'OK'
