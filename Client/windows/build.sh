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
#
# Builds the Windows 7 x64 client on this Mac: build/windows/LanScreen-Windows/
# with lanscreen.exe, run.cmd and README.txt, and a zip of the three.
#
# Needs nasm (brew install nasm). The first time, fetches the compiler
# (setup_toolchain.sh) and builds FFmpeg (build_ffmpeg.sh).
#
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/Client/windows"
CACHE="${LANSCREEN_CACHE:-$HOME/Library/Caches/LanScreen}"
FFMPEG="$CACHE/ffmpeg-7.1.5-win64-msvcrt"
OUT="${OUT_DIR:-$ROOT/build/windows}"
PACKAGE="$OUT/LanScreen-Windows"
# Against msvcrt.dll, which every Windows has; see setup_toolchain.sh.
TOOLCHAIN="$("$HERE/setup_toolchain.sh")"
export PATH="$TOOLCHAIN/bin:$PATH"
CC=x86_64-w64-mingw32-clang

[ -f "$FFMPEG/lib/libavcodec.a" ] || "$HERE/build_ffmpeg.sh"
mkdir -p "$PACKAGE"

# Windows 7 is 6.1: anything newer in the headers stays out of the program.
$CC -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter \
    -D_WIN32_WINNT=0x0601 -DWINVER=0x0601 \
    -I "$ROOT/Common/include" -I "$ROOT/Client/core" -I "$FFMPEG/include" \
    "$HERE/main.c" "$HERE/network.c" "$HERE/decode.c" "$HERE/display.c" \
    "$ROOT/Client/core/ls_depacketizer.c" "$ROOT/Client/core/ls_decode_queue.c" \
    "$ROOT/Client/core/ls_decoder.c" "$ROOT/Common/rtp_protocol.c" \
    -L "$FFMPEG/lib" -lavcodec -lavutil \
    -lbcrypt -lole32 -luser32 -lgdi32 -lws2_32 -liphlpapi -ld3d9 -ldxva2 -luuid -lm \
    -mwindows -static -s \
    -o "$PACKAGE/lanscreen.exe"

cp "$HERE/run.cmd" "$HERE/README.txt" "$PACKAGE/"
# Windows wants CRLF in a batch file and Notepad on 7 wants it in text.
for f in "$PACKAGE/run.cmd" "$PACKAGE/README.txt"; do
    perl -pi -e 's/\r?\n/\r\n/' "$f"
done
rm -f "$OUT/LanScreen-Windows.zip"
(cd "$OUT" && zip -qr LanScreen-Windows.zip LanScreen-Windows)
ls -l "$PACKAGE/lanscreen.exe" "$OUT/LanScreen-Windows.zip"
