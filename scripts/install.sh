#!/usr/bin/env bash
# Installs the latest Rosa release.
#   curl -fsSL https://raw.githubusercontent.com/jonas-lomholdt/rosa/main/scripts/install.sh | bash
set -euo pipefail

REPO="jonas-lomholdt/rosa"
APP_NAME="Rosa.app"

say() { printf '\033[1;35m🐹 %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Rosa is a macOS app."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAJOR >= 26 )) || fail "Rosa needs macOS 26 or later (you have $(sw_vers -productVersion))."

say "Finding the latest release…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[[ -n "$URL" ]] || fail "No release found at https://github.com/$REPO/releases"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "Downloading $(basename "$URL")…"
curl -fL --progress-bar "$URL" -o "$TMP/Rosa.zip"
ditto -x -k "$TMP/Rosa.zip" "$TMP"
[[ -d "$TMP/$APP_NAME" ]] || fail "The download didn't contain $APP_NAME."

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

if pgrep -x Rosa >/dev/null; then
    say "Quitting the running Rosa…"
    osascript -e 'quit app "Rosa"' >/dev/null 2>&1 || true
    sleep 1
fi

rm -rf "${DEST:?}/$APP_NAME"
ditto "$TMP/$APP_NAME" "$DEST/$APP_NAME"
# Not notarised yet: clear the quarantine flag so Gatekeeper doesn't block the first launch.
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

say "Installed to $DEST/$APP_NAME"
open "$DEST/$APP_NAME"
