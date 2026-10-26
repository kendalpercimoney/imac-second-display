#!/bin/bash
# This file is part of LanScreen.
# Copyright (C) 2026 Kendal Percimoney
#
# LanScreen is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# LanScreen is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.

# Cross-builds the smallest FFmpeg the Windows client needs: the H.264 decoder,
# DXVA2 hardware decoding, nothing else. Static, for x86_64 Windows 7.
#
# FFmpeg 7.1, not the newest. The newest series is where Windows 8-only APIs
# would arrive first, and the Windows check audits every import the finished
# exe makes against what Windows 7 has, so a version that drifted would be
# caught -- this just starts from the one least likely to.
#
# Downloaded once, into a cache outside the repository, and checked against the
# SHA-256 recorded here. ffmpeg.org signs its releases with GPG as well; that
# is not checked, since this Mac has no GPG, so the HTTPS download and this
# checksum are what is relied on.
set -euo pipefail

VERSION="7.1.5"
SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
CACHE="${LANSCREEN_CACHE:-$HOME/Library/Caches/LanScreen}"
TARBALL="$CACHE/ffmpeg-$VERSION.tar.xz"
SRC="$CACHE/ffmpeg-$VERSION"
PREFIX="$CACHE/ffmpeg-$VERSION-win64"
CROSS="x86_64-w64-mingw32-"

if [ -f "$PREFIX/lib/libavcodec.a" ] && [ "${1:-}" != "--rebuild" ]; then
    echo "FFmpeg $VERSION for Windows already built: $PREFIX"
    exit 0
fi

command -v "${CROSS}gcc" >/dev/null || { echo "need mingw-w64: brew install mingw-w64" >&2; exit 1; }
command -v nasm >/dev/null || { echo "need nasm: brew install nasm" >&2; exit 1; }

mkdir -p "$CACHE"
if [ ! -f "$TARBALL" ]; then
    echo "==> downloading FFmpeg $VERSION"
    curl -sSL -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null \
    || { echo "FFmpeg tarball checksum does not match; refusing to build it" >&2; exit 1; }

rm -rf "$SRC"
tar -xf "$TARBALL" -C "$CACHE"

echo "==> configuring"
cd "$SRC"
# --disable-autodetect so nothing is linked that was not asked for: no
# Direct3D 11, no Media Foundation, no Schannel. Every one of those is an
# import the Windows 7 audit would have to clear, for a feature never used.
./configure \
    --prefix="$PREFIX" \
    --enable-cross-compile --cross-prefix="$CROSS" \
    --target-os=mingw32 --arch=x86_64 \
    --disable-everything --disable-autodetect \
    --disable-programs --disable-doc --disable-network \
    --disable-swscale --disable-swresample --disable-avformat \
    --disable-avfilter --disable-avdevice \
    --enable-w32threads --enable-dxva2 \
    --enable-decoder=h264 --enable-hwaccel=h264_dxva2 \
    --enable-static --disable-shared \
    --extra-cflags="-D_WIN32_WINNT=0x0601 -DWINVER=0x0601 -O2" \
    > "$CACHE/ffmpeg-configure.log" 2>&1 \
    || { tail -30 "$CACHE/ffmpeg-configure.log"; exit 1; }

echo "==> building (a few minutes)"
make -j"$(sysctl -n hw.ncpu)" > "$CACHE/ffmpeg-build.log" 2>&1 \
    || { tail -30 "$CACHE/ffmpeg-build.log"; exit 1; }
make install > /dev/null

echo "Built FFmpeg $VERSION for Windows: $PREFIX"
