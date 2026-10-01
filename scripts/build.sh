#!/usr/bin/env bash
# Builds Browser.app into ./build. Usage: scripts/build.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Browser" "$APP/Contents/MacOS/Browser"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${2:-}" == "--run" ]]; then
    open "$APP"
fi
