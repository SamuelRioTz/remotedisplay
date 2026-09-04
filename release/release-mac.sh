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
# When the signing identity is a "Developer ID Application" certificate (see
# server-mac/sign-identity.sh) the macOS apps and DMGs are also notarized with Apple and
# stapled, so Gatekeeper opens them without warnings. The notarytool keychain profile
# (default `remotedisplay-notary`) and the dedicated signing keychain are described in
# release/README.md ("Signing and notarization").
#
# Usage:  release/release-mac.sh [--skip-android] [--skip-ios] [--skip-server] [--skip-notarize] [--upload]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/release/out"; mkdir -p "$OUT"
VER=$(grep '^version:' "$ROOT/client/pubspec.yaml" | sed 's/version:[[:space:]]*//; s/+.*//')
# Homebrew first: over a non-interactive SSH session the PATH doesn't include it and gh/others don't show up.
export PATH="$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "Remote Display $VER"

SKIP_ANDROID=0; SKIP_IOS=0; SKIP_SERVER=0; SKIP_NOTARIZE=0; UPLOAD=0
for a in "$@"; do case "$a" in --skip-android) SKIP_ANDROID=1;; --skip-ios) SKIP_IOS=1;; --skip-server) SKIP_SERVER=1;; --skip-notarize) SKIP_NOTARIZE=1;; --upload) UPLOAD=1;; esac; done

# Signing identity (personal team only) and notarization. ~/.config/remotedisplay/signing.env
# may set RD_NOTARY_PROFILE; it is optional. Notarization is attempted only with a Developer ID.
[ -f "$HOME/.config/remotedisplay/signing.env" ] && . "$HOME/.config/remotedisplay/signing.env"
NOTARY_PROFILE="${RD_NOTARY_PROFILE:-remotedisplay-notary}"
SIGN_ID="$("$ROOT/server-mac/sign-identity.sh")" || SIGN_ID=""
NOTARIZE=0
case "$SIGN_ID" in "Developer ID Application:"*) NOTARIZE=1;; esac
if [ $SKIP_NOTARIZE = 1 ]; then NOTARIZE=0; fi
if [ $NOTARIZE = 1 ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "WARNING: notarytool profile '$NOTARY_PROFILE' is not usable; the DMGs will NOT be notarized"; NOTARIZE=0
fi
echo "signing: ${SIGN_ID:-ad-hoc}   notarize: $NOTARIZE"

notarize() { # notarize <file>: submit to Apple, wait, fail unless Accepted (prints the log otherwise)
  local f="$1" out id status
  out=$(xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  id=$(echo "$out" | sed -n 's/^ *id: //p' | head -1); status=$(echo "$out" | sed -n 's/^ *status: //p' | tail -1)
  echo "notarization of $(basename "$f"): ${status:-no answer} (id ${id:-?})"
  if [ "$status" != "Accepted" ]; then
    echo "$out"; [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    return 1
  fi
}
notarize_app() { # notarize_app <App.app>: verify the signature, notarize a zip of it, staple the bundle
  local app="$1" tmp; [ $NOTARIZE = 1 ] || return 0
  codesign --verify --deep --strict "$app"
  tmp=$(mktemp -d); /usr/bin/ditto -c -k --keepParent "$app" "$tmp/app.zip"
  notarize "$tmp/app.zip"; rm -rf "$tmp"
  xcrun stapler staple -q "$app"; echo "stapled: $app"
}

make_dmg() { # make_dmg <App.app> <output.dmg> <volname>
  local app="$1" dmg="$2" vol="$3" stage
  stage=$(mktemp -d); cp -R "$app" "$stage/"; ln -s /Applications "$stage/Applications"
  # AGPL: ship the license text and the third-party notices with the binaries.
  cp "$ROOT/LICENSE" "$stage/LICENSE.txt"; cp "$ROOT/NOTICE.md" "$stage/NOTICE.md"
  rm -f "$dmg"; hdiutil create -volname "$vol" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$stage"
  if [ $NOTARIZE = 1 ]; then # signed + notarized + stapled DMG: Gatekeeper accepts it offline too
    codesign --force --timestamp --sign "$SIGN_ID" "$dmg"
    notarize "$dmg"; xcrun stapler staple -q "$dmg"
    spctl -a -vv --type open --context context:primary-signature "$dmg" 2>&1 | sed 's/^/  gatekeeper: /'
  fi
  echo "dmg: $dmg"
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

# 2) macOS client (signed by build-sign.sh with the personal-team identity, hardened runtime)
( cd "$ROOT/client" && SIGN_ID="$SIGN_ID" bash ./build-sign.sh )
CLIENT_APP="$ROOT/client/build/macos/Build/Products/Release/RemoteDisplay.app"
STAGED="$ROOT/client/build/macos/Build/Products/Release/Remote Display.app"
rm -rf "$STAGED"; cp -R "$CLIENT_APP" "$STAGED"
notarize_app "$STAGED"
make_dmg "$STAGED" "$OUT/RemoteDisplay-$VER-macos-client.dmg" "Remote Display"

# 3) macOS Server (stable personal-team signing; the identity lives in the dedicated
#    signing keychain, so no keychain prompt)
if [ $SKIP_SERVER = 0 ]; then
  ENGINE_BIN="${ENGINE_BIN:-$ROOT/engine/rustdesk/target/release/rustdesk}"
  ( cd "$ROOT/server-mac" && make sign ENGINE_BIN="$ENGINE_BIN" ${SIGN_ID:+SIGN_ID="$SIGN_ID"} )
  notarize_app "$ROOT/server-mac/.build/Remote Display Server.app"
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
