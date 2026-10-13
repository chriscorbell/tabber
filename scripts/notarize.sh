#!/usr/bin/env bash
# Builds, notarizes and staples Tabber.app, then packages a signed DMG around it and notarizes that too.
#
# Uses the notarytool profile in TABBER_NOTARY_PROFILE (default tabber-notary). Store it once; it asks for an
# app-specific password from account.apple.com:
#   xcrun notarytool store-credentials tabber-notary --apple-id <id> --team-id M5MQ93V9V8
# Without a profile it falls back to the Apple ID signed into Xcode (Settings > Accounts), which can notarize
# the app but not the DMG, so the DMG then fails Gatekeeper's distribution check.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="build/notary"
ARCHIVE="$OUT/Tabber.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

PROFILE="${TABBER_NOTARY_PROFILE:-tabber-notary}"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || PROFILE=""

command -v xcodegen >/dev/null && xcodegen generate --quiet

echo "==> Archiving"
xcodebuild -project Tabber.xcodeproj -scheme Tabber -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation -archivePath "$ARCHIVE" archive \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$ARCHIVE" ] || { echo "Archive failed" >&2; exit 1; }

if [ -n "$PROFILE" ]; then
  echo "==> Notarizing with notarytool profile $PROFILE"
  APP="$ARCHIVE/Products/Applications/Tabber.app"
  ZIP="$OUT/Tabber.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  mkdir -p "$OUT/notarized" && ditto "$APP" "$OUT/notarized/Tabber.app"
else
  echo "==> Uploading to Apple's notary service with the Xcode account"
  cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>M5MQ93V9V8</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/upload" -allowProvisioningUpdates 2>&1 | grep -E "error|EXPORT (SUCCEEDED|FAILED)|Uploaded" || true

  echo "==> Waiting for Apple (usually a minute or two)"
  for _ in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" >"$OUT/notarized.log" 2>&1; then
      break
    fi
    sleep 30
  done
  [ -d "$OUT/notarized/Tabber.app" ] || { echo "Notarization didn't finish; see $OUT/notarized.log" >&2; exit 1; }
fi

spctl --assess --type execute --verbose "$OUT/notarized/Tabber.app"
xcrun stapler validate "$OUT/notarized/Tabber.app"

echo "==> Packaging"
rm -rf build/Tabber.app
ditto "$OUT/notarized/Tabber.app" build/Tabber.app
scripts/package-dmg.sh

if [ -n "$PROFILE" ]; then
  echo "==> Notarizing the DMG"
  xcrun notarytool submit build/Tabber.dmg --keychain-profile "$PROFILE" --wait
  xcrun stapler staple build/Tabber.dmg
  syspolicy_check distribution build/Tabber.dmg
else
  echo "Warning: no notarytool profile, so build/Tabber.dmg is not notarized. See the top of this script." >&2
fi
