#!/usr/bin/env bash
# Put libghostty where the build expects it:
#
#   Vendor/GhosttyKit.xcframework          static libghostty + ghostty.h (Package.swift binaryTarget)
#   Vendor/ghostty-share/ghostty/          shell-integration (bundle.sh -> Contents/Resources/ghostty)
#   Vendor/ghostty-share/terminfo/         xterm-ghostty     (bundle.sh -> Contents/Resources/terminfo)
#
# Both are git-ignored (~150 MB). Usage:
#
#   ./scripts/fetch-ghosttykit.sh                 # copy from an existing build (GHOSTTYKIT_SRC)
#   ./scripts/fetch-ghosttykit.sh --build         # build it with scripts/build-ghosttykit.sh (needs zig)
#
# GHOSTTYKIT_SRC is a build output dir (GhosttyKit.xcframework + share/) of
# Wireline's Ghostty fork (branch `wireline`, wireline/build-ghosttykit.sh) —
# the manual-IO termio the engine needs; default /tmp/libghostty-spike/out-wireline-universal-2.
# (scripts/build-ghosttykit.sh builds *stock* Ghostty: the engine stays off with it.)
#
# TODO: once the fork publishes releases (current: 1.3.2-wireline+6f488dfb6,
# zip sha256 63f7b5e0d16cc0fe1e7f026e363275a6a830ae076da6757009b0d94960e071ab),
# this downloads the pinned GhosttyKit.xcframework.zip + share tarball from
# the release, checks them against the sha256 pinned below (the same value as
# `swift package compute-checksum`), and unpacks into Vendor/. Package.swift can
# then switch to `.binaryTarget(name:url:checksum:)` and this step disappears
# for the framework (resources still come from here).
#   GHOSTTYKIT_URL=…  GHOSTTYKIT_SHA256=…
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${GHOSTTYKIT_SRC:-/tmp/libghostty-spike/out-wireline-universal-2}"

if [[ "${1:-}" == "--build" ]]; then
    SRC="build/ghosttykit"
    ./scripts/build-ghosttykit.sh "${SRC}"
fi

if [[ ! -d "${SRC}/GhosttyKit.xcframework" ]]; then
    echo "no GhosttyKit.xcframework in ${SRC} — set GHOSTTYKIT_SRC or pass --build" >&2
    exit 1
fi

mkdir -p Vendor
rm -rf Vendor/GhosttyKit.xcframework Vendor/ghostty-share
cp -R "${SRC}/GhosttyKit.xcframework" Vendor/
mkdir -p Vendor/ghostty-share/ghostty
# Themes are not needed: Wireline generates every colour itself.
cp -R "${SRC}/share/ghostty/shell-integration" Vendor/ghostty-share/ghostty/
cp -R "${SRC}/share/terminfo" Vendor/ghostty-share/
[[ -f "${SRC}/BUILD-INFO.txt" ]] && cp "${SRC}/BUILD-INFO.txt" Vendor/ghostty-share/

echo "✓ Vendor/GhosttyKit.xcframework ($(du -sh Vendor/GhosttyKit.xcframework | cut -f1))"
echo "✓ Vendor/ghostty-share"
