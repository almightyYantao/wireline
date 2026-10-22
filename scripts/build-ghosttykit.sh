#!/bin/bash
# Reproducible GhosttyKit.xcframework build for Wireline.
#
#   ./scripts/build-ghosttykit.sh [out_dir]   (default build/ghosttykit; env: GHOSTTY_REV, GHOSTTY_SRC, TARGET=universal|native)
#
# Produces in out_dir:
#   GhosttyKit.xcframework/                 static libghostty-internal.a + ghostty.h + modulemap
#   GhosttyKit.xcframework.zip + .sha256    SwiftPM remote binaryTarget(url:checksum:) input
#   share/ghostty, share/terminfo           runtime resources to copy into Contents/Resources
#   BUILD-INFO.txt                          rev, zig, xcode, sha256s
set -euo pipefail

GHOSTTY_REV="${GHOSTTY_REV:-67edd20a0292629da7e01b64973de19d356df487}"
ZIG_REQUIRED="0.17.0"
TARGET="${TARGET:-universal}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../build/ghosttykit}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
SRC="${GHOSTTY_SRC:-$HERE/../build/ghostty-src-$GHOSTTY_REV}"

zig_ver="$(zig version 2>/dev/null || true)"
if [[ "$zig_ver" != "$ZIG_REQUIRED" ]]; then
  echo "need zig $ZIG_REQUIRED (have '${zig_ver:-none}'): brew install zig, or ziglang.org tarball" >&2
  exit 1
fi

if [[ ! -d "$SRC/.git" ]]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$SRC" fetch -q --depth 1 origin "$GHOSTTY_REV"
git -C "$SRC" checkout -q --force "$GHOSTTY_REV"

start=$(date +%s)
(
  cd "$SRC"
  rm -rf macos/GhosttyKit.xcframework zig-out
  # ReleaseFast, library only (no Ghostty.app). Deps are fetched by hash from build.zig.zon,
  # so the build is content-addressed; set ZIG_GLOBAL_CACHE_DIR in CI to cache them.
  zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target="$TARGET"
)
echo "zig build took $(( $(date +%s) - start ))s"

rm -rf "$OUT/GhosttyKit.xcframework" "$OUT/share"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT/"
# Runtime resources, same layout Ghostty expects (TERMINFO = <resources>/../terminfo):
#   share/ghostty/{shell-integration,themes}  -> App.app/Contents/Resources/ghostty
#   share/terminfo                            -> App.app/Contents/Resources/terminfo
mkdir -p "$OUT/share/ghostty"
cp -R "$SRC/zig-out/share/ghostty/shell-integration" "$SRC/zig-out/share/ghostty/themes" "$OUT/share/ghostty/"
cp -R "$SRC/zig-out/share/terminfo" "$OUT/share/"
cp "$SRC/LICENSE" "$OUT/GHOSTTY-LICENSE"

(cd "$OUT" && rm -f GhosttyKit.xcframework.zip && ditto -c -k --keepParent GhosttyKit.xcframework GhosttyKit.xcframework.zip)
sum=$(swift package compute-checksum "$OUT/GhosttyKit.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/GhosttyKit.xcframework.zip" | cut -d' ' -f1)
echo "$sum" > "$OUT/GhosttyKit.xcframework.zip.sha256"

{
  echo "ghostty_rev=$GHOSTTY_REV"
  echo "target=$TARGET optimize=ReleaseFast"
  echo "zig=$(zig version)"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "built_at=$(date -u +%FT%TZ)"
  echo "zip_sha256=$sum"
  find "$OUT/GhosttyKit.xcframework" -name '*.a' -exec shasum -a 256 {} \;
  du -sh "$OUT/GhosttyKit.xcframework" "$OUT/GhosttyKit.xcframework.zip" "$OUT/share"
} | tee "$OUT/BUILD-INFO.txt"
