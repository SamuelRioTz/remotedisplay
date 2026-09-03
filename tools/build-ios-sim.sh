#!/usr/bin/env bash
# Compila NUESTRO client (client/) para el SIMULADOR de iPad/iPhone y lo instala
# en el simulador arrancado. Banco de pruebas del cliente iOS sin hardware
# (incluye el monitor externo virtual: Simulator → I/O → External Displays).
#
# Uso:  tools/build-ios-sim.sh [--install]
#   --install  instala en el simulador arrancado (xcrun simctl install booted)
#
# Diferencias vs build-ios.sh (device):
#   - target Rust aarch64-apple-ios-sim, SIN hwcodec (el vcpkg ffmpeg del
#     triplet simulador está compilado para device; VP9 por software sobra
#     para probar) y SIN LTO (los objetos bitcode del LTO de rustc no los
#     traga el linker de Xcode: "Undefined symbol: _wire_*").
#   - deps vcpkg del triplet arm64-ios-simulator en ~/vcpkg/installed-ios-sim.
#     OJO: el port libvpx ignora el sysroot del simulador y compila para
#     device; la libvpx.a del triplet sim se recompiló a mano (generic-gnu +
#     clang -target arm64-apple-ios14.0-simulator). Si se reinstala el triplet,
#     revisar con: otool -l <objeto> | grep -A3 LC_BUILD_VERSION (platform 7).
#   - durante el build se apunta ~/vcpkg/installed/arm64-ios al triplet sim
#     (magnum-opus resuelve vcpkg por esa ruta); se restaura al salir.
#
# El framebuffer del display externo del simulador va aparte del modo UIKit:
# la escena no interactiva de la app siempre conecta a 720x480 (quirk del
# simulador; en un monitor real UIScreen trae la resolución nativa).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/rustdesk"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export PATH="${FLUTTER_HOME:-$HOME/flutter}/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=14.0

DO_INSTALL=0
[ "${1:-}" = "--install" ] && DO_INSTALL=1

{ flutter --version 2>/dev/null || true; } | grep -q "Flutter 3.24.5" || { echo "ERROR: se requiere Flutter 3.24.5" >&2; exit 1; }
[ -d "$VCPKG_ROOT/installed-ios-sim/arm64-ios-simulator" ] || { echo "ERROR: falta el triplet arm64-ios-simulator en $VCPKG_ROOT/installed-ios-sim" >&2; exit 1; }
ln -sfn arm64-ios-simulator "$VCPKG_ROOT/installed-ios-sim/arm64-ios"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# magnum-opus busca vcpkg en $VCPKG_ROOT/installed/arm64-ios: apuntarlo al
# triplet del simulador SOLO durante este build y restaurar SIEMPRE.
SAVED_LINK="$(readlink "$VCPKG_ROOT/installed/arm64-ios" || true)"
restore_link() { [ -n "$SAVED_LINK" ] && ln -sfn "$SAVED_LINK" "$VCPKG_ROOT/installed/arm64-ios"; }
trap restore_link EXIT
ln -sfn ../installed-ios-sim/arm64-ios-simulator "$VCPKG_ROOT/installed/arm64-ios"

echo "*** lib Rust (aarch64-apple-ios-sim, features flutter, sin LTO)"
cd "$ENGINE"
VCPKG_INSTALLED_ROOT="$VCPKG_ROOT/installed-ios-sim" \
BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--target=arm64-apple-ios14.0-simulator -isysroot $SDK" \
CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked --features flutter --release --target aarch64-apple-ios-sim --lib
ls -la target/aarch64-apple-ios-sim/release/liblibrustdesk.a

echo "*** app iOS simulador (flutter build ios --simulator --debug)"
cd "$ROOT/client"
cp "$ENGINE/flutter/macos/Runner/bridge_generated.h" ios/Runner/bridge_generated.h
flutter pub get
flutter build ios --simulator --debug
APP="$ROOT/client/build/ios/iphonesimulator/Runner.app"
echo "*** app lista: $APP"

if [ "$DO_INSTALL" = 1 ]; then
  xcrun simctl install booted "$APP"
  echo "*** instalada. Lanzar:  xcrun simctl launch booted app.remotedisplay.client"
  echo "*** conectar:  xcrun simctl openurl booted 'rustdesk://connection/new/<ip>?password=<pw>'"
fi
