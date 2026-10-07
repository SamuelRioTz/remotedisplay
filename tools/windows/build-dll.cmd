@echo off
REM Builds the engine DLL for the Windows client (the recipe of tools/README.md, "Building the
REM Windows CLIENT", in one go so it also works from a plain ssh/cmd session):
REM   - MSVC environment (vcvars64) without the telemetry child that keeps redirected logs open,
REM   - bindgen on LLVM 18 (CLANG_PATH / LIBCLANG_PATH), llvm-mingw taken off PATH,
REM   - vcpkg deps (x64-windows-static), then cargo with the `flutter,hwcodec` features.
REM Output: engine\rustdesk\target\release\librustdesk.dll (release\release-windows.ps1 picks it up).
REM Override LLVM18 / VCPKG_ROOT / VCVARS in the environment for another machine.
setlocal EnableDelayedExpansion
set VSCMD_SKIP_SENDTELEMETRY=1
if "%LLVM18%"=="" set "LLVM18=C:\Users\sam\llvm-18.1.8\bin"
if "%VCPKG_ROOT%"=="" set "VCPKG_ROOT=C:\Users\sam\vcpkg"
if "%VCVARS%"=="" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
call "%VCVARS%" || exit /b 1
set "CLANG_PATH=%LLVM18%\clang.exe"
set "LIBCLANG_PATH=%LLVM18%"
set "BINDGEN_EXTRA_CLANG_ARGS=--target=x86_64-pc-windows-msvc"
REM Drop every llvm-mingw entry from PATH (its headers do not parse for the MSVC target).
set "NEWPATH="
for %%P in ("%PATH:;=";"%") do (
  set "ENTRY=%%~P"
  if "!ENTRY!" neq "" (
    echo !ENTRY! | findstr /i "llvm-mingw" >nul || set "NEWPATH=!NEWPATH!!ENTRY!;"
  )
)
set "PATH=%NEWPATH%"
cd /d "%~dp0..\..\engine\rustdesk" || exit /b 1
echo building librustdesk.dll in %CD%
cargo build --locked --features flutter,hwcodec --lib --release
if errorlevel 1 exit /b 1
dir target\release\librustdesk.dll
