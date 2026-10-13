#!/usr/bin/env bash
# Builds, notarizes and staples Tabber.app, then packages a signed DMG around the notarized app.
#
# Uses the Apple ID signed into Xcode (Settings > Accounts), so no extra credentials are needed:
# archive -> export with destination "upload" (submits to Apple's notary service) -> wait -> export the
# notarized, stapled app. If you'd rather use notarytool, store a profile once and set TABBER_NOTARY_PROFILE:
#   xcrun notarytool store-credentials tabber-notary --apple-id <id> --team-id M5MQ93V9V8 --password <app password>
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="build/notary"
ARCHIVE="$OUT/Tabber.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

command -v xcodegen >/dev/null && xcodegen generate --quiet

echo "==> Archiving"
xcodebuild -project Tabber.xcodeproj -scheme Tabber -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation -archivePath "$ARCHIVE" archive \
  | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$ARCHIVE" ] || { echo "Archive failed" >&2; exit 1; }

if [ -n "${TABBER_NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing with notarytool profile $TABBER_NOTARY_PROFILE"
  APP="$ARCHIVE/Products/Applications/Tabber.app"
  ZIP="$OUT/Tabber.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$TABBER_NOTARY_PROFILE" --wait
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
