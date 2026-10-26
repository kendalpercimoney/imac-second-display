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

# A compiler that builds Windows programs against msvcrt.dll, which every
# Windows has, rather than the Universal C Runtime, which Windows 7 only has
# once a particular update is installed. Without it, the program will not start:
# "api-ms-win-crt-convert-l1-1-0.dll is missing from your computer".
#
# Homebrew's mingw-w64 only targets the UCRT. llvm-mingw publishes both, but
# its macOS build only for the UCRT, and the msvcrt one only for Linux. The
# compiler is the same in both -- one release, one LLVM -- and the target
# libraries are Windows files that do not care which machine built them, so
# this takes the macOS compiler and puts the Linux build's msvcrt libraries and
# headers under it.
#
# Both downloads are checked against the SHA-256 digests recorded here, which
# are the ones GitHub publishes for the release assets.
set -euo pipefail

RELEASE="20261020"
MAC="llvm-mingw-$RELEASE-ucrt-macos-universal.tar.xz"
MAC_SHA256="e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e"
LIN="llvm-mingw-$RELEASE-msvcrt-ubuntu-22.04-x86_64.tar.xz"
LIN_SHA256="ceb8c5acc6f76e143f9c714772d2fa677027802561ce68c396e8dc990a80f0b6"
CACHE="${LANSCREEN_CACHE:-$HOME/Library/Caches/LanScreen}/llvm-mingw"
TOOLCHAIN="$CACHE/msvcrt-macos-$RELEASE"

if [ -x "$TOOLCHAIN/bin/x86_64-w64-mingw32-clang" ]; then
    echo "$TOOLCHAIN"
    exit 0
fi

mkdir -p "$CACHE"
for pair in "$MAC $MAC_SHA256" "$LIN $LIN_SHA256"; do
    set -- $pair
    if [ ! -f "$CACHE/$1" ]; then
        echo "==> downloading $1" >&2
        curl -sSL -o "$CACHE/$1" "https://github.com/mstorsjo/llvm-mingw/releases/download/$RELEASE/$1"
    fi
    echo "$2  $CACHE/$1" | shasum -a 256 -c - >/dev/null \
        || { echo "$1 does not match its checksum; refusing to use it" >&2; exit 1; }
done

WORK="$CACHE/assemble"
rm -rf "$WORK" "$TOOLCHAIN"
mkdir -p "$WORK/mac" "$WORK/lin"
tar -xf "$CACHE/$MAC" -C "$WORK/mac" --strip-components 1
tar -xf "$CACHE/$LIN" -C "$WORK/lin" --strip-components 1
CLANG_VERSION="$(ls "$WORK/mac/lib/clang")"
[ "$CLANG_VERSION" = "$(ls "$WORK/lin/lib/clang")" ] \
    || { echo "the two builds have different compilers; they cannot be combined" >&2; exit 1; }
for dir in generic-w64-mingw32 x86_64-w64-mingw32 "lib/clang/$CLANG_VERSION/lib/windows"; do
    rm -rf "$WORK/mac/$dir"
    cp -R "$WORK/lin/$dir" "$WORK/mac/$dir"
done
mv "$WORK/mac" "$TOOLCHAIN"
rm -rf "$WORK"
echo "$TOOLCHAIN"
