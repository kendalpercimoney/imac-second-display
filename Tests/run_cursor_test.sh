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
"$OUT/cursorsend" "$CONTROL_PORT" "$CURSOR_X" "$CURSOR_Y" "${SWEEP_SECONDS:-9}" "${CURSOR_RATE:-1000}" > "$OUT/cursorsend.log" 2>&1 &
CURSOR=$!
sleep 0.5
"$OUT/nativeclient/LanScreenClient.app/Contents/MacOS/LanScreenClient" \
    -host 127.0.0.1 -videoPort "$PORT" -controlPort "$CONTROL_PORT" -windowed YES \
    -vsync "${VSYNC:-NO}" \
    -snapshot "$SNAPSHOT" -snapshotAfter "${SNAPSHOT_AFTER:-240}" > "$OUT/client.log" 2>&1 &
CLIENT=$!
sleep 1.5
"$OUT/lsloopsend" 127.0.0.1 "$PORT" 420 60 bars greedy > /dev/null 2>&1
wait $CLIENT 2>/dev/null || true
kill $CURSOR 2>/dev/null || true

grep -E "snapshot |cursor positions processed|slowest pointer update|render time" "$OUT/client.log" || true

# The invariant, stated directly rather than inferred from throughput: handing
# over a pointer update must not wait on a draw. Inferring it from how many
# updates got through only works when the display is slower than the send rate,
# which is not true on every machine -- this is true everywhere.
SLOWEST="$(grep -oE "slowest pointer update: [0-9]+" "$OUT/client.log" | grep -oE "[0-9]+$" || echo 0)"
# A draw takes 8-12 ms here, so 5 ms separates "waited on a draw" from the
# scheduler noise you get sampling a maximum over thousands of updates. The
# fixed path peaks around 2 ms; blocking on a draw puts it at 8 ms or more.
if [ "$SLOWEST" -gt 5000 ]; then
    echo "RESULT: FAIL (a pointer update took ${SLOWEST}us; it must not wait on a draw)"
    exit 1
fi
SENT="$(grep -oE "sent [0-9]+ positions" "$OUT/cursorsend.log" | grep -oE "[0-9]+" || echo 0)"
GOT="$(grep -oE "cursor positions processed: [0-9]+" "$OUT/client.log" | grep -oE "[0-9]+$" || echo 0)"
echo "host sent $SENT pointer updates, client processed $GOT"

# 1000 updates a second is far above the 120 the host actually sends. That is
# deliberate: the fault is that a receiving thread waits on the display, and at
# or below the refresh rate it stays hidden. The first version of this test ran
# at 120 Hz on a 120 Hz screen and passed against the broken code.
#
# The real signature of the bug this guards against: the client drawing on the
# thread that receives these can only service half of them under vsync, and the
# rest queue in the socket buffer and are drawn stale, one refresh apart.
if [ "$SENT" -gt 100 ]; then
    if [ "$GOT" -lt $(( SENT * 3 / 4 )) ]; then
        echo "RESULT: FAIL (client kept up with only $GOT of $SENT pointer updates)"
        exit 1
    fi
    echo "client kept up with the pointer"
fi
echo
echo "==> with vsync ${VSYNC:-NO}: the pointer must be at the settled position,"
echo "    not at one it swept through seconds ago"
"$OUT/checkpattern" "$SNAPSHOT" 40 --at "$CURSOR_X" "$CURSOR_Y" 255 0 255
echo "snapshot: $SNAPSHOT"
