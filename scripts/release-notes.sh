#!/bin/bash
# Prints release notes for a tag: its section of CHANGELOG.md (`## vX.Y.Z`), or the
# Unreleased section, or, failing both, the commit subjects since the previous stable tag.
set -euo pipefail
TAG=${1:?usage: release-notes.sh vX.Y.Z}
cd "$(dirname "$0")/.."

section() {
    awk -v heading="## $1" '
        $0 == heading { found = 1; next }
        found && /^## / { exit }
        found { print }
    ' CHANGELOG.md | sed -e '/./,$!d'
}

NOTES=$(section "$TAG")
[ -n "$NOTES" ] || NOTES=$(section "Unreleased")
if [ -z "$NOTES" ]; then
    PREVIOUS=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' "$TAG^" 2>/dev/null || true)
    NOTES=$(git log --no-merges --pretty='- %s' ${PREVIOUS:+"$PREVIOUS.."}"$TAG")
fi
printf '%s\n' "$NOTES"
