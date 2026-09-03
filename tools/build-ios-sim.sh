#!/usr/bin/env bash
# Builds OUR client (client/) for the iPad/iPhone SIMULATOR and installs it
# on the booted simulator. Test bench for the iOS client without hardware
# (includes the virtual external monitor: Simulator → I/O → External Displays).
#
# Usage:  tools/build-ios-sim.sh [--install]
#   --install  installs on the booted simulator (xcrun simctl install booted)
#
# Differences vs build-ios.sh (device):
#   - Rust target aarch64-apple-ios-sim, WITHOUT hwcodec (the vcpkg ffmpeg of the
#     simulator triplet is built for device; software VP9 is good enough for
#     testing) and WITHOUT LTO (Xcode's linker chokes on the bitcode objects from
#     rustc's LTO: "Undefined symbol: _wire_*").
#   - vcpkg deps for the arm64-ios-simulator triplet in ~/vcpkg/installed-ios-sim.
#     NOTE: the libvpx port ignores the simulator's sysroot and builds for
#     device; the sim triplet's libvpx.a was recompiled by hand (generic-gnu +
#     clang -target arm64-apple-ios14.0-simulator). If the triplet is reinstalled,
#     check with: otool -l <object> | grep -A3 LC_BUILD_VERSION (platform 7).
#   - during the build, ~/vcpkg/installed/arm64-ios is pointed at the sim triplet
#     (magnum-opus resolves vcpkg through that path); it's restored on exit.
#
# The simulator's external-display framebuffer is separate from UIKit mode:
# the app's non-interactive scene always connects at 720x480 (a simulator
# quirk; on a real monitor UIScreen reports the native resolution).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/rustdesk"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export PATH="${FLUTTER_HOME:-$HOME/flutter}/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=14.0

DO_INSTALL=0
[ "${1:-}" = "--install" ] && DO_INSTALL=1

{ flutter --version 2>/dev/null || true; } | grep -q "Flutter 3.24.5" || { echo "ERROR: Flutter 3.24.5 is required" >&2; exit 1; }
[ -d "$VCPKG_ROOT/installed-ios-sim/arm64-ios-simulator" ] || { echo "ERROR: missing the arm64-ios-simulator triplet in $VCPKG_ROOT/installed-ios-sim" >&2; exit 1; }
ln -sfn arm64-ios-simulator "$VCPKG_ROOT/installed-ios-sim/arm64-ios"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# magnum-opus looks for vcpkg in $VCPKG_ROOT/installed/arm64-ios: point it at the
# simulator triplet ONLY during this build and ALWAYS restore it.
SAVED_LINK="$(readlink "$VCPKG_ROOT/installed/arm64-ios" || true)"
restore_link() { [ -n "$SAVED_LINK" ] && ln -sfn "$SAVED_LINK" "$VCPKG_ROOT/installed/arm64-ios"; }
trap restore_link EXIT
ln -sfn ../installed-ios-sim/arm64-ios-simulator "$VCPKG_ROOT/installed/arm64-ios"

echo "*** Rust lib (aarch64-apple-ios-sim, features flutter, no LTO)"
cd "$ENGINE"
VCPKG_INSTALLED_ROOT="$VCPKG_ROOT/installed-ios-sim" \
BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--target=arm64-apple-ios14.0-simulator -isysroot $SDK" \
CARGO_PROFILE_RELEASE_LTO=false \
  cargo build --locked --features flutter --release --target aarch64-apple-ios-sim --lib
ls -la target/aarch64-apple-ios-sim/release/liblibrustdesk.a

echo "*** iOS simulator app (flutter build ios --simulator --debug)"
cd "$ROOT/client"
cp "$ENGINE/flutter/macos/Runner/bridge_generated.h" ios/Runner/bridge_generated.h
flutter pub get
flutter build ios --simulator --debug
APP="$ROOT/client/build/ios/iphonesimulator/Runner.app"
echo "*** app ready: $APP"

if [ "$DO_INSTALL" = 1 ]; then
  xcrun simctl install booted "$APP"
  echo "*** installed. Launch:  xcrun simctl launch booted app.remotedisplay.client"
  echo "*** connect:  xcrun simctl openurl booted 'rustdesk://connection/new/<ip>?password=<pw>'"
fi
