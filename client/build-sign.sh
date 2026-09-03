#!/bin/bash
# Compila y FIRMA el cliente. La firma --deep + disable-library-validation es
# OBLIGATORIA: sin ella el .app crashea al abrir con "Library not loaded:
# FlutterMacOS.framework" (validacion de libreria de macOS).
set -e
export PATH="$HOME/flutter/bin:$PATH"   # Flutter 3.24.5
cd "$(dirname "$0")"
flutter build macos --release
APP=build/macos/Build/Products/Release/RemoteDisplay.app
codesign --force --deep --options runtime \
  --entitlements macos/Runner/Release.entitlements --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "OK -> $APP  (cp -R a /Applications para instalar)"
