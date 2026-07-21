#!/usr/bin/env bash
# Build a distributable Wireline.app and package it as a .dmg and .zip.
#
#   ./scripts/package.sh
#
# Output: build/Wireline-<version>.dmg  and  build/Wireline-<version>.zip
#
# SIGNING: bundle.sh signs with a stable "Developer ID Application" identity
# when one is available (MACOS_SIGN_IDENTITY, or auto-detected from the
# keychain). A stable identity is what lets saved Keychain passwords survive
# version updates — ad-hoc builds lose them on every rebuild. Without any
# Developer ID cert it falls back to ad-hoc, and Gatekeeper will warn on other
# Macs the first time (recipients open via right-click → Open, or
# `xattr -cr /Applications/Wireline.app`). For friction-free distribution,
# also notarize (see the bottom of this script).

set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="0.8.5"
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

echo "▸ Generating signed appcast (Sparkle)…"
GEN=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -x "$GEN" ]]; then
    APPCAST_DIR="build/appcast"
    rm -rf "$APPCAST_DIR"; mkdir -p "$APPCAST_DIR"
    cp "$ZIP" "$APPCAST_DIR/"
    # Each release is hosted under its own GitHub release tag, so the enclosure
    # URL prefix is version-specific. The appcast advertises the current build;
    # older versions stay downloadable but drop off the feed.
    "$GEN" "$APPCAST_DIR" \
        --download-url-prefix "https://github.com/almightyYantao/wireline/releases/download/v${VERSION}/"
    cp "$APPCAST_DIR/appcast.xml" docs/appcast.xml
    echo "   ✓ docs/appcast.xml (commit + push so GitHub Pages serves it)"
else
    echo "   ⚠ generate_appcast not found — run 'swift build' first, or skip auto-update for this release."
fi

echo ""
echo "✓ Done:"
echo "   $DMG"
echo "   $ZIP"
echo "   docs/appcast.xml"
echo ""
echo "Recipients (unsigned/ad-hoc): mount the DMG, drag Wireline to Applications,"
echo "then first launch via right-click → Open (or run: xattr -cr /Applications/Wireline.app)."

# ---------------------------------------------------------------------------
# Signing is handled automatically in bundle.sh (Developer ID when available).
# Optional extra step — notarization, for warning-free launch on other Macs
# (needs a paid Apple account):
#   xcrun notarytool submit "$ZIP" --apple-id you@example.com \
#     --team-id TEAMID --password APP_SPECIFIC_PASSWORD --wait
#   xcrun stapler staple "$APP"
# Then re-create the DMG/zip from the stapled app.
# ---------------------------------------------------------------------------
