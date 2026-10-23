#!/usr/bin/env bash
# Put FreeRDP where the build expects it:
#
#   Vendor/FreeRDP.xcframework     static FreeRDP 3 + OpenSSL + headers (Package.swift binaryTarget)
#   Vendor/FreeRDP-licenses/       FreeRDP + OpenSSL licence texts (bundle.sh -> Contents/Resources)
#
# Both are git-ignored (~35 MB universal). Usage:
#
#   ./scripts/fetch-freerdp.sh             # copy from an existing build (FREERDP_OUT)
#   ./scripts/fetch-freerdp.sh --build     # build it with scripts/build-freerdp.sh (needs cmake + ninja)
#
# FREERDP_OUT is a build-freerdp.sh output dir; default build/freerdp/out.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${FREERDP_OUT:-build/freerdp/out}"

if [[ "${1:-}" == "--build" ]]; then
    ./scripts/build-freerdp.sh "${SRC}"
fi

if [[ ! -d "${SRC}/FreeRDP.xcframework" ]]; then
    echo "no FreeRDP.xcframework in ${SRC} — set FREERDP_OUT or pass --build" >&2
    exit 1
fi

mkdir -p Vendor
rm -rf Vendor/FreeRDP.xcframework Vendor/FreeRDP-licenses
cp -R "${SRC}/FreeRDP.xcframework" Vendor/
cp -R "${SRC}/LICENSES" Vendor/FreeRDP-licenses
[[ -f "${SRC}/BUILD-INFO.txt" ]] && cp "${SRC}/BUILD-INFO.txt" Vendor/FreeRDP-licenses/

echo "✓ Vendor/FreeRDP.xcframework ($(du -sh Vendor/FreeRDP.xcframework | cut -f1))"
echo "✓ Vendor/FreeRDP-licenses"
