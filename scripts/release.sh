#!/usr/bin/env bash
# Publishes a release: a notarized Tabber.dmg plus the signed appcast the in-app updater reads, on a new GitHub
# release tagged v<MARKETING_VERSION>.
#
#   scripts/release.sh <release-notes.md>
#
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml in a PR first; the updater compares
# CURRENT_PROJECT_VERSION. Needs the notarytool profile described in notarize.sh and the update-signing key in the
# login Keychain (Sparkle's generate_keys; keep a backup made with `generate_keys -x <file>`).
set -euo pipefail

cd "$(dirname "$0")/.."
NOTES="${1:?usage: scripts/release.sh <release-notes.md>}"
[ -f "$NOTES" ] || { echo "No release notes at $NOTES" >&2; exit 1; }

REPO="chriscorbell/tabber"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p' project.yml)
TAG="v$VERSION"
PROFILE="${TABBER_NOTARY_PROFILE:-tabber-notary}"

[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Release from main." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "The working tree has changes." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main doesn't match origin/main." >&2; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then echo "$TAG is already released." >&2; exit 1; fi
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "No notarytool profile \"$PROFILE\"; see scripts/notarize.sh." >&2; exit 1; }

echo "==> Releasing Tabber $VERSION ($BUILD)"
TABBER_NOTARY_PROFILE="$PROFILE" scripts/notarize.sh
BUILT=$(defaults read "$PWD/build/Tabber.app/Contents/Info.plist" CFBundleVersion)
[ "$BUILT" = "$BUILD" ] || { echo "Built version $BUILT, expected $BUILD." >&2; exit 1; }

echo "==> Signing the appcast"
swift package resolve >/dev/null
STAGE="build/appcast"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp build/Tabber.dmg "$STAGE/Tabber.dmg"
# generate_appcast embeds notes from a file named like the archive.
cp "$NOTES" "$STAGE/Tabber.md"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes --maximum-deltas 0 --link "https://github.com/$REPO" \
  -o "$STAGE/appcast.xml" "$STAGE"
grep -q 'sparkle:edSignature=' "$STAGE/appcast.xml" || { echo "The appcast isn't signed." >&2; exit 1; }

echo "==> Publishing $TAG"
gh release create "$TAG" build/Tabber.dmg "$STAGE/appcast.xml" --repo "$REPO" --target main \
  --title "Tabber $VERSION" --notes-file "$NOTES"
