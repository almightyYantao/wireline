#!/usr/bin/env bash
# Put FreeRDP where the build expects it:
#
#   Vendor/FreeRDP/lib/libFreeRDP.a   static FreeRDP 3 + OpenSSL (linked by the CFreeRDPShim target)
#   Vendor/FreeRDP/include/            its headers
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

if [[ ! -f "${SRC}/FreeRDP/lib/libFreeRDP.a" ]]; then
    echo "no FreeRDP/lib/libFreeRDP.a in ${SRC} — set FREERDP_OUT or pass --build" >&2
    exit 1
fi

mkdir -p Vendor
rm -rf Vendor/FreeRDP Vendor/FreeRDP-licenses
cp -R "${SRC}/FreeRDP" Vendor/
cp -R "${SRC}/LICENSES" Vendor/FreeRDP-licenses
[[ -f "${SRC}/BUILD-INFO.txt" ]] && cp "${SRC}/BUILD-INFO.txt" Vendor/FreeRDP-licenses/

echo "✓ Vendor/FreeRDP ($(du -sh Vendor/FreeRDP | cut -f1))"
echo "✓ Vendor/FreeRDP-licenses"
