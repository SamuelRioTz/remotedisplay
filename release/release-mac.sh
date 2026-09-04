#!/usr/bin/env bash
# Mac-side release: produces in release/out/ the artifacts that can only be
# built/signed on the Mac (graphical session: codesign needs the keychain):
#   RemoteDisplay-<ver>-android-arm64.apk        Android client (build-android.sh)
#   RemoteDisplay-<ver>-macos-client.dmg         macOS client (client/build-sign.sh + hdiutil)
#   RemoteDisplay-Server-<ver>-macos.dmg         Remote Display Server.app (server-mac/make sign)
#   RemoteDisplay-<ver>-ios.ipa                  iOS client signed with the development cert
# Afterwards, from the Windows PC: tools/release-fetch-mac.ps1 fetches them via scp and
# uploads them to the GitHub Release (the Mac doesn't have gh).
#
# Usage:  tools/release-mac.sh [--skip-android] [--skip-ios] [--skip-server]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release/out"; mkdir -p "$OUT"
VER=$(grep '^version:' "$ROOT/client/pubspec.yaml" | sed 's/version:[[:space:]]*//; s/+.*//')
# Homebrew first: over a non-interactive SSH session the PATH doesn't include it and gh/others don't show up.
export PATH="$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "Remote Display $VER"

SKIP_ANDROID=0; SKIP_IOS=0; SKIP_SERVER=0; UPLOAD=0
for a in "$@"; do case "$a" in --skip-android) SKIP_ANDROID=1;; --skip-ios) SKIP_IOS=1;; --skip-server) SKIP_SERVER=1;; --upload) UPLOAD=1;; esac; done

make_dmg() { # make_dmg <App.app> <output.dmg> <volname>
  local app="$1" dmg="$2" vol="$3" stage
  stage=$(mktemp -d); cp -R "$app" "$stage/"; ln -s /Applications "$stage/Applications"
  # AGPL: ship the license text and the third-party notices with the binaries.
  cp "$ROOT/LICENSE" "$stage/LICENSE.txt"; cp "$ROOT/NOTICE.md" "$stage/NOTICE.md"
  rm -f "$dmg"; hdiutil create -volname "$vol" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$stage"; echo "dmg: $dmg"
}

# 0) Engine: the macOS client embeds engine/rustdesk/target/release/liblibrustdesk.dylib
#    (Xcode project) and the server bundles target/release/rustdesk. Build both here so
#    the packages never ship a stale engine (the client dylib needs the `flutter` feature).
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"   # scrap/build.rs needs libyuv from vcpkg
#    `hwcodec` = hardware H264/H265 through the prebuilt ffmpeg the hwcodec crate ships
#    (VideoToolbox here; the iOS and Android builds already had it). Without it everything
#    was VP9 in software, even at 3440x1440.
( cd "$ROOT/engine/rustdesk" && cargo build --release --features flutter,hwcodec --lib && cargo build --release --features hwcodec --bin rustdesk )

# 1) Android
if [ $SKIP_ANDROID = 0 ]; then
  bash "$ROOT/tools/build-android.sh"
  cp "$ROOT/tools/out/remotedisplay-client-android-arm64.apk" "$OUT/RemoteDisplay-$VER-android-arm64.apk"
  echo "apk: $OUT/RemoteDisplay-$VER-android-arm64.apk"
fi

# 2) macOS client (ad-hoc signing with disable-library-validation, see build-sign.sh)
( cd "$ROOT/client" && bash ./build-sign.sh )
CLIENT_APP="$ROOT/client/build/macos/Build/Products/Release/RemoteDisplay.app"
STAGED="$ROOT/client/build/macos/Build/Products/Release/Remote Display.app"
rm -rf "$STAGED"; cp -R "$CLIENT_APP" "$STAGED"
make_dmg "$STAGED" "$OUT/RemoteDisplay-$VER-macos-client.dmg" "Remote Display"

# 3) macOS Server (stable signing, asks for the keychain the first time -> "Always Allow")
if [ $SKIP_SERVER = 0 ]; then
  ENGINE_BIN="${ENGINE_BIN:-$ROOT/engine/rustdesk/target/release/rustdesk}"
  ( cd "$ROOT/server-mac" && make sign ENGINE_BIN="$ENGINE_BIN" )
  make_dmg "$ROOT/server-mac/.build/Remote Display Server.app" "$OUT/RemoteDisplay-Server-$VER-macos.dmg" "Remote Display Server"
fi

# 4) iOS: signed build (development) packaged as a .ipa (Payload/). Install with
#    xcrun devicectl device install app --device <UDID> RemoteDisplay-<ver>-ios.ipa
#    (or Finder / Apple Configurator). The device must be in the development profile.
if [ $SKIP_IOS = 0 ]; then
  bash "$ROOT/tools/build-ios.sh"
  IOS_APP="$ROOT/client/build/ios/iphoneos/Runner.app"
  stage=$(mktemp -d); mkdir -p "$stage/Payload"; cp -R "$IOS_APP" "$stage/Payload/"
  ( cd "$stage" && rm -f "$OUT/RemoteDisplay-$VER-ios.ipa" && zip -qr "$OUT/RemoteDisplay-$VER-ios.ipa" Payload )
  rm -rf "$stage"; echo "ipa: $OUT/RemoteDisplay-$VER-ios.ipa"
fi

echo "OK -> $OUT"; ls -la "$OUT" | grep -E "RemoteDisplay-"

# 5) Upload to GitHub Releases (the Mac already has gh authenticated as SamuelRioTz).
if [ "$UPLOAD" = 1 ]; then
  TAG="v$VER"
  if ! gh release view "$TAG" >/dev/null 2>&1; then
    gh release create "$TAG" --title "Remote Display $VER" --notes "Build $VER."
  fi
  # Upload only THIS version's artifacts (don't overwrite Windows's if they're already there).
  FILES=("$OUT"/RemoteDisplay-*"$VER"*)
  [ -e "${FILES[0]}" ] && gh release upload "$TAG" "${FILES[@]}" --clobber
  echo "uploaded to GitHub Releases ($TAG)"
fi
