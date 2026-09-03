#!/usr/bin/env bash
# Compila NUESTRO client (client/) para iPad/iPhone EN el Mac y opcionalmente lo instala.
#
# Uso:  tools/build-ios.sh [--deps] [--install [UDID]]
#   --deps     (re)construye las deps vcpkg para arm64-ios (solo la 1ª vez, ~5 min)
#   --install  instala y lanza en el dispositivo (UDID de `xcrun devicectl list devices`;
#              sin UDID usa el primer iPad/iPhone disponible)
#
# Requisitos: Xcode con la cuenta de Apple logueada (firma automática, equipo K45698KZ4W =
# "Samuel Rioja"), dispositivo emparejado con Xcode y en modo desarrollador, Flutter 3.24.5
# en ~/flutter, target Rust aarch64-apple-ios, vcpkg en ~/vcpkg. El runner client/ios/ es
# copia del del engine con bundle id app.remotedisplay.client, equipo propio y rutas a
# engine/rustdesk (liblibrustdesk.a). Sin push/wifi-info en entitlements.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/rustdesk"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export PATH="${FLUTTER_HOME:-$HOME/flutter}/bin:$PATH"
# Mismo target mínimo para los objetos C (cc-rs), el link de rustc y el Runner: sin esto cc-rs
# compila aom para el iOS del SDK (26.x, emite ___chkstk_darwin) y rustc enlaza con mínimo 10.0
# → "Undefined symbols: ___chkstk_darwin".
export IPHONEOS_DEPLOYMENT_TARGET=14.0

DO_DEPS=0; DO_INSTALL=0; UDID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --deps) DO_DEPS=1 ;;
    --install) DO_INSTALL=1; if [ -n "${2:-}" ] && [[ "$2" != --* ]]; then UDID="$2"; shift; fi ;;
    *) echo "arg desconocido: $1" >&2; exit 2 ;;
  esac
  shift
done

{ flutter --version 2>/dev/null || true; } | grep -q "Flutter 3.24.5" || { echo "ERROR: se requiere Flutter 3.24.5" >&2; exit 1; }

cd "$ENGINE"
# Install-root propio (ver build-android.sh: un install de otro triplet en el mismo root borra los demás).
if [ "$DO_DEPS" = 1 ] || [ ! -f "$VCPKG_ROOT/installed-ios/arm64-ios/lib/libvpx.a" ]; then
  echo "*** deps vcpkg arm64-ios → $VCPKG_ROOT/installed-ios"
  "$VCPKG_ROOT/vcpkg" install --triplet arm64-ios --x-install-root="$VCPKG_ROOT/installed-ios"
fi
if [ ! -L "$VCPKG_ROOT/installed/arm64-ios" ]; then
  rm -rf "$VCPKG_ROOT/installed/arm64-ios"
  ln -s ../installed-ios/arm64-ios "$VCPKG_ROOT/installed/arm64-ios"
fi

echo "*** lib Rust (aarch64-apple-ios, features flutter,hwcodec)"
cargo build --locked --features flutter,hwcodec --release --target aarch64-apple-ios --lib
ls -la target/aarch64-apple-ios/release/liblibrustdesk.a

echo "*** app iOS (flutter build ios --release, firma automática)"
cd "$ROOT/client"
cp "$ENGINE/flutter/macos/Runner/bridge_generated.h" ios/Runner/bridge_generated.h
flutter pub get
flutter build ios --release
APP="$ROOT/client/build/ios/iphoneos/Runner.app"
echo "*** app lista: $APP"

if [ "$DO_INSTALL" = 1 ]; then
  if [ -z "$UDID" ]; then
    UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPad|iPhone/ {print $0}' | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
  fi
  [ -n "$UDID" ] || { echo "ERROR: no hay iPad/iPhone emparejado disponible" >&2; exit 1; }
  echo "*** instalando en $UDID"
  xcrun devicectl device install app --device "$UDID" "$APP"
  xcrun devicectl device process launch --device "$UDID" app.remotedisplay.client
fi
