#!/usr/bin/env bash
# Build a distributable Wireline.app and package it as a .dmg and .zip.
#
#   ./scripts/package.sh
#
# Output: build/Wireline-<version>.dmg  and  build/Wireline-<version>.zip
#
# NOTE: the app is ad-hoc signed (no paid Apple Developer account required).
# Gatekeeper will warn on other Macs the first time — recipients open it via
# right-click → Open, or `xattr -cr /Applications/Wireline.app`. For friction-
# free distribution, sign with a Developer ID certificate and notarize (see the
# bottom of this script).

set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="0.5.0"
APP="build/Wireline.app"

echo "▸ Forcing a clean release build (avoids stale-cache bundles)…"
rm -rf .build/arm64-apple-macosx/release/Wireline.build
FORCE_ICON=1 ./scripts/bundle.sh

echo "▸ Creating .zip…"
ZIP="build/Wireline-${VERSION}.zip"
rm -f "$ZIP"
# ditto preserves the code signature and resource forks.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Creating .dmg…"
DMG="build/Wireline-${VERSION}.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # drag-to-install target
hdiutil create -volname "Wireline" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "✓ Done:"
echo "   $DMG"
echo "   $ZIP"
echo ""
echo "Recipients (unsigned/ad-hoc): mount the DMG, drag Wireline to Applications,"
echo "then first launch via right-click → Open (or run: xattr -cr /Applications/Wireline.app)."

# ---------------------------------------------------------------------------
# Optional: Developer ID signing + notarization (needs a paid Apple account).
#   codesign --deep --force --options runtime \
#     --sign "Developer ID Application: YOUR NAME (TEAMID)" "$APP"
#   xcrun notarytool submit "$ZIP" --apple-id you@example.com \
#     --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
#   xcrun stapler staple "$APP"
# Then re-create the DMG/zip from the stapled app.
# ---------------------------------------------------------------------------
