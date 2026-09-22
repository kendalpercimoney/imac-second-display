#!/bin/bash
#
# Verifies the client's OpenGL render path on a modern Mac, without the iMac.
#
# Builds the client for the native architecture, points it at the loopback
# sender, has it snapshot its own framebuffer, and checks the four quadrants
# came out the colours they went in as. That exercises the one path the
# headless loopback test cannot reach: IOSurface -> GL_YCBCR_422_APPLE -> RGB.
#
# A wrong colour matrix, a video-range mismatch, or a flipped image all fail
# here rather than surprising you once the code is on a machine in another room.
#
# This opens a window for a couple of seconds.
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-test"
PORT="${PORT:-5056}"
SNAPSHOT="$OUT/render.png"

mkdir -p "$OUT"

echo "==> building shared protocol object"
xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"

echo "==> building loopback sender"
xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" \
    -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/UDPSocket.swift" \
    "$ROOT/Host/Sources/RTPPacketizer.swift" \
    "$ROOT/Host/Sources/VideoEncoder.swift" \
    "$ROOT/Tests/LoopSend/main.swift" \
    -o "$OUT/lsloopsend"

echo "==> building pattern checker"
xcrun clang -fobjc-arc -O1 -framework Foundation -framework CoreGraphics \
    -framework ImageIO "$ROOT/Tests/checkpattern.m" -o "$OUT/checkpattern"

echo "==> building the client for this Mac (arm64/native, not the iMac build)"
ARCH="$(uname -m)" MIN_VERSION=14.0 "$ROOT/Client/build.sh" > "$OUT/clientbuild.log" 2>&1 \
    || { cat "$OUT/clientbuild.log"; exit 1; }

echo "==> running (a window will open briefly)"
rm -f "$SNAPSHOT"
"$ROOT/build/LanScreenClient.app/Contents/MacOS/LanScreenClient" \
    -host 127.0.0.1 -videoPort "$PORT" -windowed YES \
    -snapshot "$SNAPSHOT" -snapshotAfter 40 > "$OUT/client.log" 2>&1 &
CLIENT=$!
sleep 1.5
"$OUT/lsloopsend" 127.0.0.1 "$PORT" 200 60 bars > /dev/null 2>&1
wait $CLIENT 2>/dev/null || true

tail -1 "$OUT/client.log"
echo
"$OUT/checkpattern" "$SNAPSHOT" 40
echo
echo "snapshot: $SNAPSHOT"

echo
echo "NOTE: build/LanScreenClient.app is now a native binary for this Mac."
echo "      Re-run ./Client/build.sh on the iMac for the real 10.9 build."
