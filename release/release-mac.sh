#!/usr/bin/env bash
# Release del lado Mac: produce en release/out/ los artefactos que solo se pueden
# construir/firmar en el Mac (sesión gráfica: codesign necesita el llavero):
#   RemoteDisplay-<ver>-android-arm64.apk        cliente Android (build-android.sh)
#   RemoteDisplay-<ver>-macos-client.dmg         cliente macOS (client/build-sign.sh + hdiutil)
#   RemoteDisplay-Server-<ver>-macos.dmg         Remote Display Server.app (server-mac/make sign)
#   RemoteDisplay-<ver>-ios.ipa                  cliente iOS firmado con el cert de desarrollo
# Después, desde la PC Windows: tools/release-fetch-mac.ps1 los trae por scp y los
# sube al GitHub Release (el Mac no tiene gh).
#
# Uso:  tools/release-mac.sh [--skip-android] [--skip-ios] [--skip-server]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release/out"; mkdir -p "$OUT"
VER=$(grep '^version:' "$ROOT/client/pubspec.yaml" | sed 's/version:[[:space:]]*//; s/+.*//')
# Homebrew primero: por SSH no-interactivo el PATH no lo trae y gh/otros no aparecen.
export PATH="$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "Remote Display $VER"

SKIP_ANDROID=0; SKIP_IOS=0; SKIP_SERVER=0; UPLOAD=0
for a in "$@"; do case "$a" in --skip-android) SKIP_ANDROID=1;; --skip-ios) SKIP_IOS=1;; --skip-server) SKIP_SERVER=1;; --upload) UPLOAD=1;; esac; done

make_dmg() { # make_dmg <App.app> <salida.dmg> <volname>
  local app="$1" dmg="$2" vol="$3" stage
  stage=$(mktemp -d); cp -R "$app" "$stage/"; ln -s /Applications "$stage/Applications"
  rm -f "$dmg"; hdiutil create -volname "$vol" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$stage"; echo "dmg: $dmg"
}

# 1) Android
if [ $SKIP_ANDROID = 0 ]; then
  bash "$ROOT/tools/build-android.sh"
  cp "$ROOT/tools/out/remotedisplay-client-android-arm64.apk" "$OUT/RemoteDisplay-$VER-android-arm64.apk"
  echo "apk: $OUT/RemoteDisplay-$VER-android-arm64.apk"
fi

# 2) Cliente macOS (firma ad-hoc con disable-library-validation, ver build-sign.sh)
( cd "$ROOT/client" && bash ./build-sign.sh )
CLIENT_APP="$ROOT/client/build/macos/Build/Products/Release/RemoteDisplay.app"
STAGED="$ROOT/client/build/macos/Build/Products/Release/Remote Display.app"
rm -rf "$STAGED"; cp -R "$CLIENT_APP" "$STAGED"
make_dmg "$STAGED" "$OUT/RemoteDisplay-$VER-macos-client.dmg" "Remote Display"

# 3) Server macOS (firma estable, pide el llavero la primera vez -> "Permitir siempre")
if [ $SKIP_SERVER = 0 ]; then
  ENGINE_BIN="${ENGINE_BIN:-$ROOT/engine/rustdesk/target/release/rustdesk}"
  ( cd "$ROOT/server-mac" && make sign ENGINE_BIN="$ENGINE_BIN" )
  make_dmg "$ROOT/server-mac/.build/Remote Display Server.app" "$OUT/RemoteDisplay-Server-$VER-macos.dmg" "Remote Display Server"
fi

# 4) iOS: build firmado (development) y empaquetado como .ipa (Payload/). Se instala con
#    xcrun devicectl device install app --device <UDID> RemoteDisplay-<ver>-ios.ipa
#    (o Finder / Apple Configurator). El dispositivo debe estar en el perfil de desarrollo.
if [ $SKIP_IOS = 0 ]; then
  bash "$ROOT/tools/build-ios.sh"
  IOS_APP="$ROOT/client/build/ios/iphoneos/Runner.app"
  stage=$(mktemp -d); mkdir -p "$stage/Payload"; cp -R "$IOS_APP" "$stage/Payload/"
  ( cd "$stage" && rm -f "$OUT/RemoteDisplay-$VER-ios.ipa" && zip -qr "$OUT/RemoteDisplay-$VER-ios.ipa" Payload )
  rm -rf "$stage"; echo "ipa: $OUT/RemoteDisplay-$VER-ios.ipa"
fi

echo "OK -> $OUT"; ls -la "$OUT" | grep -E "RemoteDisplay-"

# 5) Subir a GitHub Releases (el Mac ya tiene gh autenticado como SamuelRioTz).
if [ "$UPLOAD" = 1 ]; then
  TAG="v$VER"
  if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --title "Remote Display $VER" --notes "Build $VER."
  fi
  # Subir solo los artefactos de ESTA versión (no pisar los de Windows si ya están).
  FILES=("$OUT"/RemoteDisplay-*"$VER"*)
  [ -e "${FILES[0]}" ] && gh release upload "$TAG" "${FILES[@]}" --clobber
  echo "subido a GitHub Releases ($TAG)"
fi
