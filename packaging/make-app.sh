#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Multi-Profile Fingerprint Browser"
BINARY_NAME="MultiProfileFingerprintBrowser"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/packaging/AppIcon.icns"
LPROJ_SOURCE="$ROOT/packaging/lproj"

cd "$ROOT"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/release/$BINARY_NAME" "$MACOS/$BINARY_NAME"
cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES/AppIcon.icns"
else
  echo "warning: icon not found at $ICON_SOURCE" >&2
fi

if [[ -d "$LPROJ_SOURCE" ]]; then
  for lproj_dir in "$LPROJ_SOURCE"/*.lproj; do
    [[ -d "$lproj_dir" ]] || continue
    cp -R "$lproj_dir" "$RESOURCES/"
  done
else
  echo "warning: lproj sources not found at $LPROJ_SOURCE" >&2
fi

chmod +x "$MACOS/$BINARY_NAME"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
