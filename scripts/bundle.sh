#!/usr/bin/env bash
# Build Wireline and assemble a runnable Wireline.app bundle.
#
#   ./scripts/bundle.sh          # release build -> ./build/Wireline.app
#   ./scripts/bundle.sh --run    # build, then open the app
#
# A SwiftUI app that uses MenuBarExtra / multiple windows / Keychain needs a
# real .app bundle with an Info.plist; running the bare SwiftPM binary won't
# behave correctly. This script produces that bundle.

set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Wireline"
BUNDLE_ID="com.wireline.app"
CONFIG="${CONFIG:-release}"
OUT="build/${APP_NAME}.app"

echo "▸ Building (${CONFIG})…"
swift build -c "${CONFIG}" --product "${APP_NAME}"
BIN="$(swift build -c "${CONFIG}" --product "${APP_NAME}" --show-bin-path)/${APP_NAME}"

echo "▸ Assembling ${OUT}…"
rm -rf "${OUT}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "${BIN}" "${OUT}/Contents/MacOS/${APP_NAME}"

# Icon is cached so repeated (dev) bundles stay fast; FORCE_ICON=1 rebuilds it.
ICNS_CACHE="build/AppIcon.icns"
if [[ ! -f "${ICNS_CACHE}" || "${FORCE_ICON:-}" == "1" ]]; then
    echo "▸ Generating app icon…"
    ICON_PNG="build/icon_1024.png"
    swift scripts/make_icon.swift "${ICON_PNG}" >/dev/null
    ICONSET="build/AppIcon.iconset"
    rm -rf "${ICONSET}"; mkdir -p "${ICONSET}"
    for s in 16 32 128 256 512; do
        sips -z $s $s      "${ICON_PNG}" --out "${ICONSET}/icon_${s}x${s}.png"    >/dev/null
        sips -z $((s*2)) $((s*2)) "${ICON_PNG}" --out "${ICONSET}/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET}" -o "${ICNS_CACHE}"
fi
cp "${ICNS_CACHE}" "${OUT}/Contents/Resources/AppIcon.icns"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.8.5</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Wireline</string>
    <!-- Sparkle auto-update -->
    <key>SUFeedURL</key><string>https://almightyyantao.github.io/wireline/appcast.xml</string>
    <key>SUPublicEDKey</key><string>287T2lrvbuglzkTSFgQ7ROtOoxWT2EdBr+vdO82Xosc=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>3600</integer>
    <!-- Uncomment to run as a menu-bar-only agent (no Dock icon):
    <key>LSUIElement</key><true/> -->
</dict>
</plist>
PLIST

# Embed Sparkle.framework (auto-update) so the app can update itself in place,
# and point the executable's rpath at Contents/Frameworks. Must happen before
# signing (modifying the binary after signing would invalidate it).
BINDIR="$(dirname "${BIN}")"
if [[ -d "${BINDIR}/Sparkle.framework" ]]; then
    echo "▸ Embedding Sparkle.framework…"
    mkdir -p "${OUT}/Contents/Frameworks"
    rm -rf "${OUT}/Contents/Frameworks/Sparkle.framework"
    cp -R "${BINDIR}/Sparkle.framework" "${OUT}/Contents/Frameworks/"
    # The binary already has an @loader_path rpath (= MacOS/); add Frameworks too.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${OUT}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
fi

# Code signing.
#
# Keychain items are ACL-bound to the app's *code signing identity*. An ad-hoc
# signature (`--sign -`) has no stable designated requirement, so every rebuild
# looks like a different app to the Keychain and saved passwords become
# unreadable after an update (user is forced to re-enter them). Signing with a
# stable "Developer ID Application" cert keeps that identity constant, so saved
# passwords survive version updates.
#
# Resolution order:
#   1. MACOS_SIGN_IDENTITY if set (same env var as the lb-clash build scripts):
#        MACOS_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./scripts/bundle.sh
#   2. else auto-pick the first "Developer ID Application" identity in the keychain
#   3. else fall back to ad-hoc (passwords WILL be lost on the next rebuild)
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')"
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "▸ Signing with stable identity: ${SIGN_IDENTITY}"
    codesign --force --deep --options runtime \
        --sign "${SIGN_IDENTITY}" "${OUT}"
    codesign --verify --strict --verbose=2 "${OUT}" >/dev/null 2>&1 \
        && echo "  ✓ signature verified" || echo "  ⚠ signature verify reported issues"
else
    echo "▸ Ad-hoc signing (unstable identity — saved passwords won't survive updates)…"
    echo "  Set MACOS_SIGN_IDENTITY, or install a Developer ID cert, to keep Keychain passwords across versions."
    codesign --force --deep --sign - "${OUT}" >/dev/null 2>&1 || \
        echo "  (codesign skipped — Keychain may prompt on first run)"
fi

echo "✓ Built ${OUT}"
if [[ "${1:-}" == "--run" ]]; then
    open "${OUT}"
fi
