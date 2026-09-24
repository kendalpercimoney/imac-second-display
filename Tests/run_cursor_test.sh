#!/bin/bash
#
# Verifies the client draws the pointer where the host says it is.
#
# The pointer is sent out of band and drawn by the client, so nothing else in
# the pipeline can catch a mistake in the coordinate mapping or the hotspot --
# it would simply appear in the wrong place on the iMac and nowhere else.
#
# Sends a solid magenta pointer to a known position over a red area of the test
# pattern, then checks that pixel in the client's own framebuffer. Magenta
# proves it drew, and that it drew on top of the video.
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-test"
PORT="${PORT:-5062}"
CONTROL_PORT="${CONTROL_PORT:-5063}"
CURSOR_X="${CURSOR_X:-400}"
CURSOR_Y="${CURSOR_Y:-300}"
SNAPSHOT="$OUT/cursor.png"

mkdir -p "$OUT"

echo "==> building"
xcrun clang -c -O2 -I "$ROOT/Common/include" "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"
xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/UDPSocket.swift" "$ROOT/Host/Sources/RTPPacketizer.swift" \
    "$ROOT/Host/Sources/VideoEncoder.swift" "$ROOT/Tests/LoopSend/main.swift" \
    -o "$OUT/lsloopsend"
xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" "$ROOT/Tests/CursorSend/main.swift" -o "$OUT/cursorsend"
xcrun clang -fobjc-arc -O1 -framework Foundation -framework CoreGraphics \
    -framework ImageIO "$ROOT/Tests/checkpattern.m" -o "$OUT/checkpattern"
ARCH="$(uname -m)" MIN_VERSION=14.0 OUT_DIR="$OUT/nativeclient" \
    "$ROOT/Client/build.sh" > "$OUT/clientbuild.log" 2>&1 \
    || { cat "$OUT/clientbuild.log"; exit 1; }

echo "==> running (a window will open briefly)"
rm -f "$SNAPSHOT"
"$OUT/cursorsend" "$CONTROL_PORT" "$CURSOR_X" "$CURSOR_Y" 12 > "$OUT/cursorsend.log" 2>&1 &
CURSOR=$!
sleep 0.5
"$OUT/nativeclient/LanScreenClient.app/Contents/MacOS/LanScreenClient" \
    -host 127.0.0.1 -videoPort "$PORT" -controlPort "$CONTROL_PORT" -windowed YES \
    -snapshot "$SNAPSHOT" -snapshotAfter 60 > "$OUT/client.log" 2>&1 &
CLIENT=$!
sleep 1.5
"$OUT/lsloopsend" 127.0.0.1 "$PORT" 300 60 bars greedy > /dev/null 2>&1
wait $CLIENT 2>/dev/null || true
kill $CURSOR 2>/dev/null || true

tail -1 "$OUT/client.log"
echo
echo "==> the pointer should be magenta over a red background"
"$OUT/checkpattern" "$SNAPSHOT" 40 --at "$CURSOR_X" "$CURSOR_Y" 255 0 255
echo "snapshot: $SNAPSHOT"
