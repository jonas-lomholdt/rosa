#!/usr/bin/env bash
# Builds Rosa.app into ./build. Usage: scripts/build.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Rosa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Rosa" "$APP/Contents/MacOS/Rosa"
if [[ "$CONFIG" == "release" ]]; then
    # Drop local symbols (~45% of the binary); debug builds keep them for readable crash logs.
    strip -x "$APP/Contents/MacOS/Rosa"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.png (1024px, made by scripts/make-icon.swift) -> .icns.
# The 1024px (512@2x) rendition is skipped: it alone is ~60% of the file and is only used
# above 512pt on Retina (Quick Look, Finder's largest zoom), where 512px upscales fine.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if [[ $size -lt 512 ]]; then
        sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${2:-}" == "--run" ]]; then
    open "$APP"
fi
