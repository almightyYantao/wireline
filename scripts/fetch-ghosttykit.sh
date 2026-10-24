#!/usr/bin/env bash
# Put libghostty where the build expects it:
#
#   Vendor/GhosttyKit.xcframework          static libghostty + ghostty.h (Package.swift binaryTarget)
#   Vendor/ghostty-share/ghostty/          shell-integration (bundle.sh -> Contents/Resources/ghostty)
#   Vendor/ghostty-share/terminfo/         xterm-ghostty     (bundle.sh -> Contents/Resources/terminfo)
#   Vendor/GhosttyVt/                      libghostty-vt headers + static lib (the session agent)
#
# Both are git-ignored (~300 MB unpacked). libghostty comes from Wireline's
# Ghostty fork, https://github.com/almightyYantao/ghostty (branch `wireline`:
# manual-IO termio, last-command output, regex search, prompt clear on reflow).
# Usage:
#
#   ./scripts/fetch-ghosttykit.sh            # download the pinned prebuilt release, verify sha256
#   ./scripts/fetch-ghosttykit.sh --build    # build the fork at the pinned commit (needs zig 0.17)
#   GHOSTTYKIT_SRC=dir ./scripts/fetch-ghosttykit.sh
#                                            # copy from a local fork build (wireline/build-ghosttykit.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_REPO="almightyYantao/ghostty"
FORK_REV="484039fb2c1d817d02fcb959d603cfe111208130"
RELEASE="wireline-484039f"
KIT_SHA256="e71c0691c5bb1a129d3d143a8b122f2ad8824017ba115b1b1a0333b30ac79b52"
SHARE_SHA256="f049d84acbd2a85ad4523ef1ac38ea40a8383bee0af982d8469a6332cb638457"
VT_SHA256="733020d4724352eea2ecf7843a518c4e3f2de579f3c1a0f31c6aa3f745e08323"

install_from_dir() {   # a fork build output: GhosttyKit.xcframework + share/
    local src="$1"
    if [[ ! -d "${src}/GhosttyKit.xcframework" ]]; then
        echo "no GhosttyKit.xcframework in ${src}" >&2
        exit 1
    fi
    rm -rf Vendor/GhosttyKit.xcframework Vendor/ghostty-share Vendor/GhosttyVt
    cp -R "${src}/GhosttyKit.xcframework" Vendor/
    if [[ -d "${src}/GhosttyVt" ]]; then
        cp -R "${src}/GhosttyVt" Vendor/
    else
        echo "warning: no GhosttyVt in ${src} (older fork build): wireline-agent won't build" >&2
    fi
    mkdir -p Vendor/ghostty-share/ghostty
    # Themes are not needed: Wireline generates every colour itself.
    cp -R "${src}/share/ghostty/shell-integration" Vendor/ghostty-share/ghostty/
    cp -R "${src}/share/terminfo" Vendor/ghostty-share/
    [[ -f "${src}/BUILD-INFO.txt" ]] && cp "${src}/BUILD-INFO.txt" Vendor/ghostty-share/
    return 0
}

download() {   # url sha256 dest
    curl -fL --progress-bar -o "$3" "$1"
    local got
    got="$(shasum -a 256 "$3" | cut -d' ' -f1)"
    if [[ "${got}" != "$2" ]]; then
        echo "sha256 mismatch for $1: got ${got}, want $2" >&2
        exit 1
    fi
}

mkdir -p Vendor

if [[ -n "${GHOSTTYKIT_SRC:-}" ]]; then
    install_from_dir "${GHOSTTYKIT_SRC}"
elif [[ "${1:-}" == "--build" ]]; then
    SRC="build/ghostty-wireline-src"
    if [[ ! -d "${SRC}/.git" ]]; then
        git init -q "${SRC}"
        git -C "${SRC}" remote add origin "https://github.com/${FORK_REPO}.git"
    fi
    git -C "${SRC}" fetch -q --depth 1 origin "${FORK_REV}"
    git -C "${SRC}" checkout -q --force "${FORK_REV}"
    TARGET="${TARGET:-universal}" "${SRC}/wireline/build-ghosttykit.sh" "$(pwd)/build/ghosttykit"
    install_from_dir build/ghosttykit
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "${TMP}"' EXIT
    BASE="https://github.com/${FORK_REPO}/releases/download/${RELEASE}"
    download "${BASE}/GhosttyKit.xcframework.zip" "${KIT_SHA256}" "${TMP}/kit.zip"
    download "${BASE}/ghostty-share.tar.gz" "${SHARE_SHA256}" "${TMP}/share.tar.gz"
    download "${BASE}/GhosttyVt.tar.gz" "${VT_SHA256}" "${TMP}/vt.tar.gz"
    rm -rf Vendor/GhosttyKit.xcframework Vendor/ghostty-share Vendor/GhosttyVt
    ditto -x -k "${TMP}/kit.zip" Vendor/
    tar -C Vendor -xzf "${TMP}/share.tar.gz"
    tar -C Vendor -xzf "${TMP}/vt.tar.gz"
fi

echo "✓ Vendor/GhosttyKit.xcframework ($(du -sh Vendor/GhosttyKit.xcframework | cut -f1))"
echo "✓ Vendor/ghostty-share"
echo "✓ Vendor/GhosttyVt"
