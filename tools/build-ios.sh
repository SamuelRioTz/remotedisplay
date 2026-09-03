#!/usr/bin/env bash
# Builds OUR client (client/) for iPad/iPhone ON the Mac and optionally installs it.
#
# Usage:  tools/build-ios.sh [--deps] [--install [UDID]]
#   --deps     (re)builds the vcpkg deps for arm64-ios (only needed the 1st time, ~5 min)
#   --install  installs and launches on the device (UDID from `xcrun devicectl list devices`;
#              without a UDID it uses the first available iPad/iPhone)
#
# Requirements: Xcode logged into the Apple account (automatic signing, team K45698KZ4W =
# "Samuel Rioja"), device paired with Xcode and in developer mode, Flutter 3.24.5
# in ~/flutter, Rust target aarch64-apple-ios, vcpkg in ~/vcpkg. The client/ios/ runner is
# a copy of the engine's with bundle id app.remotedisplay.client, its own team, and paths to
# engine/rustdesk (liblibrustdesk.a). No push/wifi-info in entitlements.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/rustdesk"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export PATH="${FLUTTER_HOME:-$HOME/flutter}/bin:$PATH"
# Same minimum target for the C objects (cc-rs), rustc's link step, and the Runner: without this
# cc-rs builds aom for the SDK's iOS (26.x, emits ___chkstk_darwin) and rustc links with a minimum
# of 10.0 → "Undefined symbols: ___chkstk_darwin".
export IPHONEOS_DEPLOYMENT_TARGET=14.0

DO_DEPS=0; DO_INSTALL=0; UDID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --deps) DO_DEPS=1 ;;
    --install) DO_INSTALL=1; if [ -n "${2:-}" ] && [[ "$2" != --* ]]; then UDID="$2"; shift; fi ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

{ flutter --version 2>/dev/null || true; } | grep -q "Flutter 3.24.5" || { echo "ERROR: Flutter 3.24.5 is required" >&2; exit 1; }

cd "$ENGINE"
# Own install-root (see build-android.sh: installing another triplet in the same root deletes the rest).
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

echo "*** iOS app (flutter build ios --release, automatic signing)"
cd "$ROOT/client"
cp "$ENGINE/flutter/macos/Runner/bridge_generated.h" ios/Runner/bridge_generated.h
flutter pub get
flutter build ios --release
APP="$ROOT/client/build/ios/iphoneos/Runner.app"
echo "*** app ready: $APP"

if [ "$DO_INSTALL" = 1 ]; then
  if [ -z "$UDID" ]; then
    UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /iPad|iPhone/ {print $0}' | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
  fi
  [ -n "$UDID" ] || { echo "ERROR: no paired iPad/iPhone available" >&2; exit 1; }
  echo "*** installing on $UDID"
  xcrun devicectl device install app --device "$UDID" "$APP"
  xcrun devicectl device process launch --device "$UDID" app.remotedisplay.client
fi
