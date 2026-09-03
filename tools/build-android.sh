#!/usr/bin/env bash
# Compila el APK Android (arm64) EN el Mac y opcionalmente lo instala por adb.
# Por defecto compila NUESTRO cliente (client/, home propia + sesión móvil del engine,
# applicationId app.remotedisplay.client); con --engine compila el flutter_hbb del engine
# (UI móvil upstream de RustDesk, com.carriez.flutter_hbb). Ambos usan la misma lib Rust
# serverless (config.rs → 127.0.0.1) y conviven instalados.
#
# Uso:  tools/build-android.sh [--engine] [--deps] [--install [SERIAL]]
#   --engine   APK del engine en vez del client
#   --deps     (re)construye las deps vcpkg para arm64-android (solo la 1ª vez, ~5 min)
#   --install  instala el APK en la tablet/teléfono conectado por adb (SERIAL opcional)
#
# Requisitos (todos verificados en el Mac de sam, agosto 2026):
#   - Flutter 3.24.5 en ~/flutter (NO el 3.44 del sistema)
#   - Android SDK en ~/Library/Android/sdk con NDK r28c (28.2.13676358)
#   - JDK 17 (brew install openjdk@17) → Gradle 7.6.4 NO corre con el JDK 21 de Android Studio.
#     Se fija con `flutter config --jdk-dir /opt/homebrew/opt/openjdk@17` (ya hecho).
#   - rustup target aarch64-linux-android + cargo-ndk (4.x anda; CI usa 3.1.2)
#   - vcpkg en ~/vcpkg (mismo que usa el build del motor macOS)
#   - Firma: engine/rustdesk/flutter/android/key.properties (gitignored) apuntando a
#     ~/.remotedisplay/android-release.jks (alias remotedisplay). Identidad ESTABLE para que
#     `adb install -r` actualice sin desinstalar.
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
# libsodium-sys corre ./configure solo con CC/CFLAGS → sin esto usa el ar/ranlib de macOS sobre
# objetos ELF y el libsodium.a queda sin índice: la .so enlaza con sodium_* SIN RESOLVER y
# no carga en el dispositivo. Forzar las herramientas del NDK:
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
export AR="$NDK_BIN/llvm-ar" RANLIB="$NDK_BIN/llvm-ranlib"

DO_DEPS=0; DO_INSTALL=0; SERIAL=""; TARGET=client
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) TARGET=engine ;;
    --deps) DO_DEPS=1 ;;
    --install) DO_INSTALL=1; if [ -n "${2:-}" ] && [[ "$2" != --* ]]; then SERIAL="$2"; shift; fi ;;
    *) echo "arg desconocido: $1" >&2; exit 2 ;;
  esac
  shift
done

{ flutter --version 2>/dev/null || true; } | grep -q "Flutter 3.24.5" || { echo "ERROR: se requiere Flutter 3.24.5 en $FLUTTER_HOME" >&2; exit 1; }
if [ "$TARGET" = client ]; then APPDIR="$ROOT/client"; else APPDIR="$ENGINE/flutter"; fi
[ -f "$APPDIR/android/key.properties" ] || { echo "ERROR: falta $APPDIR/android/key.properties (ver header)" >&2; exit 1; }

cd "$ENGINE"

# Un install-root POR PLATAFORMA: en modo manifest, `vcpkg install` de un triplet BORRA los
# paquetes de otros triplets que viva en el mismo root (el install de iOS borró los de Android).
# Los build.rs buscan $VCPKG_ROOT/installed/<triplet> → symlink al root propio.
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
  echo "ERROR: la .so tiene simbolos sodium_* sin resolver (libsodium.a roto). Limpiar y reintentar:" >&2
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
echo "*** APK listo: $APK"

if [ "$DO_INSTALL" = 1 ]; then
  ADB=(adb); [ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
  echo "*** instalando en ${SERIAL:-dispositivo adb}"
  "${ADB[@]}" install -r "$APK"
fi
