#!/bin/bash
# Builds and SIGNS the client. The --deep + disable-library-validation
# signing is MANDATORY: without it the .app crashes on launch with "Library
# not loaded: FlutterMacOS.framework" (macOS library validation).
set -e
export PATH="$HOME/flutter/bin:$PATH"   # Flutter 3.24.5
cd "$(dirname "$0")"
flutter build macos --release
APP=build/macos/Build/Products/Release/RemoteDisplay.app
codesign --force --deep --options runtime \
  --entitlements macos/Runner/Release.entitlements --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "OK -> $APP  (cp -R to /Applications to install)"
