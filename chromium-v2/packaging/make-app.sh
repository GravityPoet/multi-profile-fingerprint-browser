#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Chromium Fingerprint Browser v2"
BINARY_NAME="ChromiumFingerprintBrowser"
CEF_APP_NAME="ChromiumFingerprintCEF"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/../packaging/AppIcon.icns"
ARCH="$(uname -m)"

cd "$ROOT"

swift build -c release

cmake -S "$ROOT/cef" -B "$ROOT/cef/build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPROJECT_ARCH="$ARCH" \
  -DUSE_SANDBOX=OFF \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
  -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)"
cmake --build "$ROOT/cef/build" --target "$CEF_APP_NAME" -- -j4

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$FRAMEWORKS" "$RESOURCES"

cp ".build/release/$BINARY_NAME" "$MACOS/$BINARY_NAME"
cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"
ditto "$ROOT/cef/build/Release/$CEF_APP_NAME.app" "$FRAMEWORKS/$CEF_APP_NAME.app"
if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES/AppIcon.icns"
else
  echo "warning: icon not found at $ICON_SOURCE" >&2
fi
chmod +x "$MACOS/$BINARY_NAME"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
