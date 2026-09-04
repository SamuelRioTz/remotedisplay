#!/bin/bash
# Builds and SIGNS the client. The --deep + disable-library-validation
# signing is MANDATORY: without it the .app crashes on launch with "Library
# not loaded: FlutterMacOS.framework" (macOS library validation).
set -e
export PATH="$HOME/flutter/bin:$PATH"   # Flutter 3.24.5
cd "$(dirname "$0")"
flutter build macos --release
APP=build/macos/Build/Products/Release/RemoteDisplay.app
# Sign with Sam's personal team identity when present (Developer ID Application, else
# Apple Development — see server-mac/sign-identity.sh), ad-hoc otherwise. Never an
# identity of another organisation.
SIGN_ID="${SIGN_ID:-$(../server-mac/sign-identity.sh)}"
if [ -n "$SIGN_ID" ]; then echo "Signing with: $SIGN_ID"; else echo "WARNING: no personal-team identity, ad-hoc signing"; SIGN_ID=-; fi
# --timestamp: secure timestamp, required by notarization (ignored for ad-hoc signing).
TS=--timestamp; [ "$SIGN_ID" = - ] && TS=
codesign --force --deep --options runtime $TS \
  --entitlements macos/Runner/Release.entitlements --sign "$SIGN_ID" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "OK -> $APP  (cp -R to /Applications to install)"
