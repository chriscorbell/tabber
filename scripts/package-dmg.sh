#!/usr/bin/env bash
# Packages build/Tabber.app into build/Tabber.dmg with an Applications shortcut.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Tabber.app"
DMG="build/Tabber.dmg"
[ -d "$APP" ] || { echo "Run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Tabber.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Tabber" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null

IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
echo "$DMG"
