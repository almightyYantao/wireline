#!/bin/bash
# Reproducible static FreeRDP build for Wireline's native RDP panes.
#
#   ./scripts/build-freerdp.sh [out_dir]    (default build/freerdp/out)
#
#   env: FREERDP_REV      FreeRDP tag (default below)
#        OPENSSL_VERSION  OpenSSL LTS release built from source (default below)
#        FREERDP_WORK     scratch dir for sources + per-arch builds (default build/freerdp)
#        TARGET           universal | native (default universal = arm64 + x86_64)
#
# Everything is static and built for macOS 14 (the app's deployment target):
# OpenSSL is compiled here rather than taken from Homebrew because Homebrew's
# libcrypto.a targets the build machine's macOS and is arm64-only.
#
# Produces in out_dir:
#   FreeRDP/lib/libFreeRDP.a   one fat static lib (freerdp3 + freerdp-client3 + winpr3 +
#                              builtin channels + libssl/libcrypto)
#   FreeRDP/include/           freerdp/ + winpr/ headers (only the C shim uses them)
#   LICENSES/              FreeRDP (Apache-2.0) and OpenSSL (Apache-2.0) licence texts
#   BUILD-INFO.txt         revs, cmake options, sha256s, sizes
set -euo pipefail

FREERDP_REV="${FREERDP_REV:-3.32.2}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.9}"
OPENSSL_SHA256="${OPENSSL_SHA256:-}"   # optional pin; printed in BUILD-INFO either way
MACOS_MIN="14.0"
TARGET="${TARGET:-universal}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${FREERDP_WORK:-$HERE/../build/freerdp}"; mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
OUT="${1:-$WORK/out}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
JOBS="$(sysctl -n hw.ncpu)"

case "$TARGET" in
  universal) ARCHS=(arm64 x86_64) ;;
  native)    ARCHS=("$(uname -m)") ;;
  *) echo "TARGET must be universal or native" >&2; exit 1 ;;
esac

for tool in cmake ninja; do
  command -v "$tool" >/dev/null || { echo "need $tool (brew install $tool)" >&2; exit 1; }
done

# ---- sources ---------------------------------------------------------------
FREERDP_SRC="$WORK/src"
if [[ ! -d "$FREERDP_SRC/.git" ]]; then
  git clone -q --depth 1 --branch "$FREERDP_REV" https://github.com/FreeRDP/FreeRDP "$FREERDP_SRC"
else
  git -C "$FREERDP_SRC" fetch -q --depth 1 origin "refs/tags/$FREERDP_REV:refs/tags/$FREERDP_REV"
  git -C "$FREERDP_SRC" checkout -q --force "$FREERDP_REV"
fi
FREERDP_COMMIT="$(git -C "$FREERDP_SRC" rev-parse HEAD)"

OSSL_TGZ="$WORK/openssl-$OPENSSL_VERSION.tar.gz"
if [[ ! -f "$OSSL_TGZ" ]]; then
  curl -fsSL -o "$OSSL_TGZ.part" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
  mv "$OSSL_TGZ.part" "$OSSL_TGZ"
fi
OSSL_SUM="$(shasum -a 256 "$OSSL_TGZ" | cut -d' ' -f1)"
if [[ -n "$OPENSSL_SHA256" && "$OSSL_SUM" != "$OPENSSL_SHA256" ]]; then
  echo "openssl tarball sha256 mismatch: $OSSL_SUM" >&2; exit 1
fi

# ---- per-arch builds -------------------------------------------------------
build_openssl() { # arch prefix
  local arch="$1" prefix="$2" src="$WORK/openssl-$OPENSSL_VERSION-$1"
  [[ -f "$prefix/lib/libcrypto.a" ]] && return
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$OSSL_TGZ" -C "$src" --strip-components 1
  local target=darwin64-arm64-cc; [[ "$arch" == x86_64 ]] && target=darwin64-x86_64-cc
  (
    cd "$src"
    # no-shared/no-module: everything (incl. the default provider) is in libcrypto.a.
    # no-legacy is fine: FreeRDP brings its own MD4/RC4 for NTLM (WITH_INTERNAL_*).
    ./Configure "$target" no-shared no-module no-tests no-docs no-apps no-legacy no-engine \
      --prefix="$prefix" --openssldir=/etc/ssl -mmacosx-version-min="$MACOS_MIN" >/dev/null
    make -j"$JOBS" build_libs >/dev/null
    make install_dev >/dev/null
  )
}

FREERDP_CMAKE_OPTS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  # FreeRDP turns on LTO when supported: the .a files would hold LLVM bitcode,
  # which lipo/xcframework can't take and which ties the app to this clang.
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
  -DWITH_VERBOSE_WINPR_ASSERT=OFF
  -DBUILD_TESTING=OFF
  # library only: no clients, no server, no sample, no tools
  -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_CHANNELS=ON
  -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_INTERFACE=OFF
  -DWITH_SERVER=OFF -DWITH_SERVER_CHANNELS=OFF -DWITH_SAMPLE=OFF -DWITH_WINPR_TOOLS=OFF
  -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF -DWITH_RDTK=OFF
  # heavy / Linux-only deps off
  -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_CAIRO=OFF
  -DWITH_OPENH264=OFF -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_LAME=OFF
  -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_GSM=OFF -DWITH_SOXR=OFF -DWITH_AOM=OFF -DWITH_DAV1D=OFF -DWITH_YUV=OFF
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF
  -DWITH_SNDIO=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_PKCS11=OFF -DWITH_FUSE=OFF
  -DWITH_KRB5=OFF -DWITH_LIBUSB=OFF -DWITH_URIPARSER=OFF -DWITH_WEBVIEW=OFF -DWITH_AAD=OFF
  -DWITH_JSON_DISABLED=ON -DWITH_CJSON_REQUIRED=OFF -DWITH_ICU=OFF -DWITH_UNICODE_BUILTIN=ON
  -DWITH_MANPAGES=OFF -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF -DWITH_MEDIACODEC=OFF
  -DWITH_OPENCL=OFF -DWITH_MBEDTLS=OFF -DWITH_LIBRESSL=OFF
  # crypto: OpenSSL 3 without the legacy provider -> MD4/MD5/RC4 for NTLM compiled in
  -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON
  # audio out (rdpsnd -> AudioToolbox); no mic, no camera, no device redirection
  -DWITH_MACAUDIO=ON
  -DCHANNEL_AUDIN=OFF -DCHANNEL_RDPECAM=OFF -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF
  -DCHANNEL_PRINTER=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_SERIAL=OFF -DCHANNEL_PARALLEL=OFF
  # rdpdr itself stays: rdpsnd and RDP8 auto-detect require it to be registered
  # (it redirects no devices — drive/printer/smartcard/serial are off).
  -DCHANNEL_DRIVE=OFF -DCHANNEL_RDPEAR=OFF -DCHANNEL_SSHAGENT=OFF
  -DCHANNEL_VIDEO=OFF -DCHANNEL_GEOMETRY=OFF -DCHANNEL_RDPEWA=OFF -DCHANNEL_LOCATION=OFF
  -DCHANNEL_RAIL=OFF -DCHANNEL_REMDESK=OFF -DCHANNEL_ENCOMSP=OFF -DCHANNEL_ECHO=OFF -DCHANNEL_RDP2TCP=OFF
  -DCHANNEL_GFXREDIR=OFF
)

build_freerdp() { # arch ossl_prefix prefix
  local arch="$1" ossl="$2" prefix="$3" bdir="$WORK/build-$1"
  rm -rf "$bdir" "$prefix"
  cmake -S "$FREERDP_SRC" -B "$bdir" -G Ninja \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DOPENSSL_ROOT_DIR="$ossl" -DOPENSSL_USE_STATIC_LIBS=ON \
    "${FREERDP_CMAKE_OPTS[@]}" > "$WORK/cmake-$arch.log"
  cmake --build "$bdir" -j"$JOBS" > "$WORK/build-$arch.log"
  cmake --install "$bdir" > /dev/null
}

start=$(date +%s)
FAT_INPUTS=()
for arch in "${ARCHS[@]}"; do
  ossl="$WORK/openssl-prefix-$arch"
  prefix="$WORK/prefix-$arch"
  echo "== $arch: OpenSSL $OPENSSL_VERSION"
  build_openssl "$arch" "$ossl"
  echo "== $arch: FreeRDP $FREERDP_REV"
  build_freerdp "$arch" "$ossl" "$prefix"
  # Merge every static archive into one so SwiftPM links a single library.
  libs=( $(find "$prefix/lib" -name '*.a' | sort) "$ossl/lib/libssl.a" "$ossl/lib/libcrypto.a" )
  libtool -static -no_warning_for_no_symbols -o "$WORK/libfreerdp-all-$arch.a" "${libs[@]}"
  FAT_INPUTS+=("$WORK/libfreerdp-all-$arch.a")
done
echo "builds took $(( $(date +%s) - start ))s"

# ---- package ---------------------------------------------------------------
# A plain lib + include dir, not an xcframework: SwiftPM copies every binary
# target's headers into one shared include dir, and GhosttyKit's umbrella
# module map would then claim FreeRDP's headers too (and break the C shim's
# build). Package.swift points the shim at these paths directly.
rm -rf "$OUT/FreeRDP"; mkdir -p "$OUT/FreeRDP/lib" "$OUT/FreeRDP/include"
lipo -create "${FAT_INPUTS[@]}" -output "$OUT/FreeRDP/lib/libFreeRDP.a"
P0="$WORK/prefix-${ARCHS[0]}"
cp -R "$P0/include/freerdp3/freerdp" "$OUT/FreeRDP/include/"
cp -R "$P0/include/winpr3/winpr" "$OUT/FreeRDP/include/"

mkdir -p "$OUT/LICENSES"
cp "$FREERDP_SRC/LICENSE" "$OUT/LICENSES/FreeRDP-LICENSE"
tar -xzf "$OSSL_TGZ" -O "openssl-$OPENSSL_VERSION/LICENSE.txt" > "$OUT/LICENSES/OpenSSL-LICENSE"

{
  echo "freerdp_rev=$FREERDP_REV ($FREERDP_COMMIT)"
  echo "openssl=$OPENSSL_VERSION sha256=$OSSL_SUM"
  echo "archs=${ARCHS[*]} macos_min=$MACOS_MIN"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "cmake=$(cmake --version | head -1)"
  echo "built_at=$(date -u +%FT%TZ)"
  echo "cmake_opts=${FREERDP_CMAKE_OPTS[*]}"
  echo "-- feature summary (${ARCHS[0]})"
  grep -E 'Using OpenSSL|Adding (STATIC|DYNAMIC) channel client' "$WORK/cmake-${ARCHS[0]}.log" || true
  shasum -a 256 "$OUT/FreeRDP/lib/libFreeRDP.a"
  lipo -info "$OUT/FreeRDP/lib/libFreeRDP.a"
  du -sh "$OUT/FreeRDP"
} > "$OUT/BUILD-INFO.txt"
tail -3 "$OUT/BUILD-INFO.txt"
