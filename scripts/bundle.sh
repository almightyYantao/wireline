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
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Wireline</string>
    <!-- Uncomment to run as a menu-bar-only agent (no Dock icon):
    <key>LSUIElement</key><true/> -->
</dict>
</plist>
PLIST

# Ad-hoc sign so Keychain access and Gatekeeper behave on the local machine.
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "${OUT}" >/dev/null 2>&1 || \
    echo "  (codesign skipped — Keychain may prompt on first run)"

echo "✓ Built ${OUT}"
if [[ "${1:-}" == "--run" ]]; then
    open "${OUT}"
fi
