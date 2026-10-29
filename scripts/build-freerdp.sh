#!/bin/bash
# Builds FreeRDP 3 and OpenSSL 3 for bundling inside Pstsc.app: only what Pstsc uses, without
# FFmpeg (Homebrew's FreeRDP pulls in GPL codecs such as x264/x265 that can't ship in an MIT app),
# and for macOS 14+ (Homebrew bottles only load on the macOS they were built for).
# Result: build/deps/freerdp (FreeRDP + OpenSSL headers and dylibs). Needs: brew install cmake ninja
# 사용법: scripts/build-freerdp.sh
set -euo pipefail

cd "$(dirname "$0")/.."
version="3.32.2"
sha256="9ccb8357bf0188044a460de775c7ea289ca7d2a2a917eca0f0a7c4dc9c8b08ea"
ssl_version="3.6.5"
ssl_sha256="a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98"
deps="$PWD/build/deps"
# Libraries are configured for a neutral prefix (it gets compiled into them, so a path under the
# builder's home folder would leak the user name) and staged into build/deps/freerdp.
neutral="/opt/pstsc"
stage="$deps/stage"
prefix="$deps/freerdp"
src="$deps/FreeRDP-$version"
ssl_src="$deps/openssl-$ssl_version"
export MACOSX_DEPLOYMENT_TARGET=14.0

# fetch <url> <sha256> <file>: download once and verify.
fetch() {
    [ -f "$3" ] || curl -fsSL -o "$3" "$1"
    echo "$2  $3" | shasum -a 256 -c -
}

mkdir -p "$deps"
if [ ! -d "$ssl_src" ]; then
    fetch "https://github.com/openssl/openssl/releases/download/openssl-$ssl_version/openssl-$ssl_version.tar.gz" \
        "$ssl_sha256" "$deps/openssl-$ssl_version.tar.gz"
    tar -xzf "$deps/openssl-$ssl_version.tar.gz" -C "$deps"
fi
if [ ! -f "$prefix/lib/libcrypto.3.dylib" ]; then
    (cd "$ssl_src" && ./Configure darwin64-arm64-cc shared no-tests no-docs --prefix="$neutral" --libdir=lib \
        && make -j"$(sysctl -n hw.ncpu)" && make install_sw DESTDIR="$stage") >/dev/null
    # Load through @rpath, like the FreeRDP libraries.
    lib="$stage$neutral/lib"
    install_name_tool -id "@rpath/libssl.3.dylib" "$lib/libssl.3.dylib"
    install_name_tool -id "@rpath/libcrypto.3.dylib" "$lib/libcrypto.3.dylib"
    install_name_tool -change "$neutral/lib/libcrypto.3.dylib" "@rpath/libcrypto.3.dylib" "$lib/libssl.3.dylib"
    install_name_tool -add_rpath "@loader_path" "$lib/libssl.3.dylib"
    mkdir -p "$prefix"
    cp -R "$stage$neutral/." "$prefix/"
fi
openssl="$prefix"

if [ ! -d "$src" ]; then
    fetch "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/$version.tar.gz" "$sha256" "$deps/freerdp-$version.tar.gz"
    tar -xzf "$deps/freerdp-$version.tar.gz" -C "$deps"
fi

cmake -S "$src" -B "$deps/freerdp-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$neutral" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DOPENSSL_ROOT_DIR="$openssl" \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CHANNELS=ON -DBUILTIN_CHANNELS=ON \
    -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_SDL=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
    -DWITH_SERVER=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF \
    -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_VIDEO_FFMPEG=OFF \
    -DWITH_OPENH264=OFF -DWITH_FAAC=OFF -DWITH_FAAD2=OFF -DWITH_GSM=OFF -DWITH_LAME=OFF \
    -DWITH_SOXR=OFF -DWITH_FDK_AAC=OFF -DWITH_OPUS=OFF \
    -DWITH_MACAUDIO=ON -DWITH_PULSE=OFF -DWITH_OSS=OFF -DWITH_ALSA=OFF \
    -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_PKCS11=OFF \
    -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON \
    -DWITH_WEBVIEW=OFF -DWITH_LIBSYSTEMD=OFF -DWITH_URIPARSER=OFF -DWITH_FIDO2=OFF \
    -DCHANNEL_URBDRC=OFF -DWITH_JPEG=OFF -DWITH_CAIRO=OFF \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON \
    -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF
cmake --build "$deps/freerdp-build"
DESTDIR="$stage" cmake --install "$deps/freerdp-build" >/dev/null
cp -R "$stage$neutral/." "$prefix/"
echo "FreeRDP $version -> $prefix"
