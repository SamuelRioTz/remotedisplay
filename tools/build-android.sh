#!/usr/bin/env bash
# Builds the Android APK (arm64) ON the Mac and optionally installs it via adb.
# By default builds OUR client (client/, own home + engine's mobile session,
# applicationId app.remotedisplay.client); with --engine it builds the engine's flutter_hbb
# (RustDesk's upstream mobile UI, com.carriez.flutter_hbb). Both use the same serverless
# Rust lib (config.rs → 127.0.0.1) and coexist installed side by side.
#
# Usage:  tools/build-android.sh [--engine] [--deps] [--install [SERIAL]]
#   --engine   build the engine's APK instead of the client's
#   --deps     (re)builds the vcpkg deps for arm64-android (only needed the 1st time, ~5 min)
#   --install  installs the APK on the tablet/phone connected via adb (SERIAL optional)
#
# Requirements (all verified on sam's Mac, August 2026):
#   - Flutter 3.24.5 in ~/flutter (NOT the system's 3.44)
#   - Android SDK in ~/Library/Android/sdk with NDK r28c (28.2.13676358)
#   - JDK 17 (brew install openjdk@17) → Gradle 7.6.4 does NOT run with Android Studio's JDK 21.
#     Set via `flutter config --jdk-dir /opt/homebrew/opt/openjdk@17` (already done).
#   - rustup target aarch64-linux-android + cargo-ndk (4.x works; CI uses 3.1.2)
#   - vcpkg in ~/vcpkg (same one the macOS engine build uses)
#   - Signing: engine/rustdesk/flutter/android/key.properties (gitignored) pointing to
#     ~/.remotedisplay/android-release.jks (alias remotedisplay). STABLE identity so that
#     `adb install -r` updates without uninstalling.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/rustdesk"
export FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export PATH="$FLUTTER_HOME/bin:$JAVA_HOME/bin:$PATH"
# libsodium-sys runs ./configure using only CC/CFLAGS → without this it uses macOS's ar/ranlib on
# ELF objects and libsodium.a ends up without an index: the .so links against sodium_* UNRESOLVED
# and fails to load on the device. Force the NDK's own tools:
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
export AR="$NDK_BIN/llvm-ar" RANLIB="$NDK_BIN/llvm-ranlib"

DO_DEPS=0; DO_INSTALL=0; SERIAL=""; TARGET=client
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) TARGET=engine ;;
    --deps) DO_DEPS=1 ;;
    --install) DO_INSTALL=1; if [ -n "${2:-}" ] && [[ "$2" != --* ]]; then SERIAL="$2"; shift; fi ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

{ flutter --version 2>/dev/null || true; } | grep -q "Flutter 3.24.5" || { echo "ERROR: Flutter 3.24.5 is required in $FLUTTER_HOME" >&2; exit 1; }
if [ "$TARGET" = client ]; then APPDIR="$ROOT/client"; else APPDIR="$ENGINE/flutter"; fi
[ -f "$APPDIR/android/key.properties" ] || { echo "ERROR: missing $APPDIR/android/key.properties (see header)" >&2; exit 1; }

cd "$ENGINE"

# One install-root PER PLATFORM: in manifest mode, `vcpkg install` for one triplet DELETES the
# packages of other triplets living in the same root (the iOS install deleted Android's).
# The build.rs scripts look for $VCPKG_ROOT/installed/<triplet> → symlink to its own root.
if [ "$DO_DEPS" = 1 ] || [ ! -f "$VCPKG_ROOT/installed-android/arm64-android/lib/libvpx.a" ]; then
  echo "*** deps vcpkg arm64-android → $VCPKG_ROOT/installed-android"
  "$VCPKG_ROOT/vcpkg" install --triplet arm64-android --x-install-root="$VCPKG_ROOT/installed-android"
fi
if [ ! -L "$VCPKG_ROOT/installed/arm64-android" ]; then
  rm -rf "$VCPKG_ROOT/installed/arm64-android"
  ln -s ../installed-android/arm64-android "$VCPKG_ROOT/installed/arm64-android"
fi

echo "*** lib Rust (cargo ndk, aarch64-linux-android, features flutter,hwcodec)"
cargo ndk --platform 21 --target aarch64-linux-android build --lib --locked --release --features flutter,hwcodec

JNI="$APPDIR/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI"
SO="$ENGINE/target/aarch64-linux-android/release/liblibrustdesk.so"
if "$NDK_BIN/llvm-nm" -D --undefined-only "$SO" | grep -q "sodium_"; then
  echo "ERROR: the .so has unresolved sodium_* symbols (libsodium.a is broken). Clean and retry:" >&2
  echo "  cargo clean -p libsodium-sys --release --target aarch64-linux-android" >&2
  exit 1
fi
cp "$SO" "$JNI/librustdesk.so"
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$JNI/"
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" "$JNI/librustdesk.so"

echo "*** APK $TARGET (flutter build apk --release arm64)"
cd "$APPDIR"
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi

OUT="$ROOT/tools/out"; mkdir -p "$OUT"
if [ "$TARGET" = client ]; then APK="$OUT/remotedisplay-client-android-arm64.apk"; else APK="$OUT/remotedisplay-engine-android-arm64.apk"; fi
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$APK"
echo "*** APK ready: $APK"

if [ "$DO_INSTALL" = 1 ]; then
  ADB=(adb); [ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
  echo "*** installing on ${SERIAL:-adb device}"
  "${ADB[@]}" install -r "$APK"
fi
