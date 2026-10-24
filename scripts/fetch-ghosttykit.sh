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
FORK_REV="8b01b39beb84eb8d13234d3cd0461e1fbade542a"
RELEASE="wireline-8b01b39"
KIT_SHA256="63f7b5e0d16cc0fe1e7f026e363275a6a830ae076da6757009b0d94960e071ab"
SHARE_SHA256="846e1148a38c4d864250d6b0669fc33c6be45c8c147e38a6d8f5702d2c581744"

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
    rm -rf Vendor/GhosttyKit.xcframework Vendor/ghostty-share
    ditto -x -k "${TMP}/kit.zip" Vendor/
    tar -C Vendor -xzf "${TMP}/share.tar.gz"
fi

echo "✓ Vendor/GhosttyKit.xcframework ($(du -sh Vendor/GhosttyKit.xcframework | cut -f1))"
echo "✓ Vendor/ghostty-share"
