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

# What the statistics overlay costs the render path.
#
# The overlay is a non-opaque child window ordered above the OpenGL view. That
# is not free: a transparent window over a GL surface has to be composited with
# it, and the overlay is also resized and repositioned on every tick. This runs
# the same stream twice, with the overlay off and on, and compares the client's
# own average render time.
#
#     ./Tests/run_overlay_cost_test.sh [rounds]
set -euo pipefail

ROUNDS="${1:-3}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-overlay"
PORT=5071
CONTROL_PORT=5072
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> building"
xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"
xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/UDPSocket.swift" "$ROOT/Host/Sources/RTPPacketizer.swift" \
    "$ROOT/Host/Sources/VideoEncoder.swift" "$ROOT/Tests/LoopSend/main.swift" \
    -o "$OUT/lsloopsend"
ARCH="$(uname -m)" MIN_VERSION=14.0 OUT_DIR="$OUT/nativeclient" \
    "$ROOT/Client/build.sh" > "$OUT/clientbuild.log" 2>&1 \
    || { cat "$OUT/clientbuild.log"; exit 1; }

run_once() {
    local stats="$1" log="$2"
    rm -f "$OUT/snap.png"
    "$OUT/nativeclient/LanScreenClient.app/Contents/MacOS/LanScreenClient" \
        -host 127.0.0.1 -videoPort "$PORT" -controlPort "$CONTROL_PORT" \
        -windowed YES -vsync NO -stats "$stats" \
        -snapshot "$OUT/snap.png" -snapshotAfter 300 > "$log" 2>&1 &
    local client=$!
    sleep 1.5
    "$OUT/lsloopsend" 127.0.0.1 "$PORT" 400 60 bars greedy > /dev/null 2>&1
    wait $client 2>/dev/null || true
    grep -o "render time: [0-9.]* ms" "$log" | grep -o "[0-9.]*" | head -1
}

echo "==> running $ROUNDS rounds, a window will open and close each time"
printf '%8s  %12s  %12s\n' "round" "stats off" "stats on"
for r in $(seq 1 "$ROUNDS"); do
    off=$(run_once NO  "$OUT/off-$r.log")
    on=$(run_once  YES "$OUT/on-$r.log")
    printf '%8s  %10s ms  %10s ms\n' "$r" "${off:-?}" "${on:-?}"
done
echo
echo "logs: $OUT"
