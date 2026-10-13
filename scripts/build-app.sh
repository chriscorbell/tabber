#!/usr/bin/env bash
# Builds a signed Release Tabber.app into build/Tabber.app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DERIVED="$ROOT/build/DerivedData"
APP="$ROOT/build/Tabber.app"

command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }

echo "==> Generating Tabber.xcodeproj"
xcodegen generate --quiet

SIGNING=()
if [ "${TABBER_ADHOC:-}" = "1" ]; then
  # No Developer ID available (CI without secrets, contributors): sign ad hoc.
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=)
fi

echo "==> Building (Release)"
xcodebuild ${SIGNING[@]+"${SIGNING[@]}"} \
  -project Tabber.xcodeproj \
  -scheme Tabber \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  build \
  | { command -v xcbeautify >/dev/null && xcbeautify --quiet || grep -E "error:|warning: .*(TabberApp|App/)|BUILD (SUCCEEDED|FAILED)" || true; }

BUILT="$DERIVED/Build/Products/Release/Tabber.app"
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found" >&2; exit 1; }

echo "==> Copying to build/Tabber.app"
rm -rf "$APP"
ditto "$BUILT" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
if [ ! -d "$APP/Contents/Frameworks/llama.framework" ]; then
  echo "llama.framework is missing from Contents/Frameworks" >&2
  exit 1
fi
codesign -dv "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Runtime Version)=" | head -3 || true

echo "$APP"
