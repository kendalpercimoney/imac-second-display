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
# The Windows client's portable core, tested on this Mac.
#
# First the reassembly and queue rules on their own (Tests/WindowsCore/
# core_test.c), then a real stream from the host's encoder through the same
# depacketizer and FFmpeg decoder the Windows client uses -- in software here,
# since only Windows has DXVA2 -- for both profiles the host can send.
#
# Needs Homebrew's ffmpeg for the native build (brew install ffmpeg).
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-windows-core"
PORT="${PORT:-5062}"
FFMPEG="$(brew --prefix ffmpeg 2>/dev/null)"
mkdir -p "$OUT"
[ -d "$FFMPEG/include/libavcodec" ] || { echo "needs Homebrew ffmpeg"; exit 2; }

CORE=("$ROOT/Common/rtp_protocol.c" "$ROOT/Client/core/ls_depacketizer.c" "$ROOT/Client/core/ls_decode_queue.c")
FLAGS=(-O1 -Wall -Wextra -std=c99 -I "$ROOT/Client/core" -I "$ROOT/Common/include")

xcrun clang "${FLAGS[@]}" "${CORE[@]}" "$ROOT/Tests/WindowsCore/core_test.c" -o "$OUT/core_test" || exit 1
xcrun clang "${FLAGS[@]}" -I "$FFMPEG/include" "${CORE[@]}" "$ROOT/Client/core/ls_decoder.c" \
    "$ROOT/Tests/WindowsCore/streamtest.c" -L "$FFMPEG/lib" -lavcodec -lavutil -o "$OUT/streamtest" || exit 1

xcrun clang -c -O2 -I "$ROOT/Common/include" "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"
xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/UDPSocket.swift" \
    "$ROOT/Host/Sources/RTPPacketizer.swift" \
    "$ROOT/Host/Sources/VideoEncoder.swift" \
    "$ROOT/Tests/LoopSend/main.swift" \
    -o "$OUT/lsloopsend" || exit 1

failures=0

echo
echo "==> reassembly and queue rules"
"$OUT/core_test" || failures=$((failures + 1))

for profile in baseline high; do
    echo
    echo "==> a real $profile stream, decoded by the core"
    "$OUT/streamtest" "$PORT" 100 20 > "$OUT/stream-$profile.log" 2>&1 &
    receiver=$!
    sleep 0.5
    LS_PROFILE=$profile "$OUT/lsloopsend" 127.0.0.1 "$PORT" 160 60 patches shipping > /dev/null 2>&1
    wait $receiver; status=$?
    grep -v "^listening" "$OUT/stream-$profile.log"
    [ $status -eq 0 ] || failures=$((failures + 1))
done

echo
if [ $failures -eq 0 ]; then echo "ALL: PASS"; else echo "ALL: FAIL ($failures)"; exit 1; fi
