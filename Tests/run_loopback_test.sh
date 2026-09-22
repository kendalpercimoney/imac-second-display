#!/bin/bash
#
# End-to-end loopback test, run on the modern Mac.
#
# Encodes real H.264 with the host's VideoToolbox + RTP code, sends it over a
# real UDP socket to 127.0.0.1, and decodes it with the client's real receive,
# depacketize and decode path. Everything except ScreenCaptureKit and the
# OpenGL view is exercised, and nothing needs Screen Recording permission.
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-test"
PORT="${PORT:-5055}"
FRAMES="${FRAMES:-30}"
FPS="${FPS:-60}"

mkdir -p "$OUT"

echo "==> building shared protocol object"
xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"

echo "==> building sender (Swift: encoder + packetizer + socket)"
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

echo "==> building receiver (Objective-C: receiver + depacketizer + decoder)"
xcrun clang -fobjc-arc -O1 -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    -I "$ROOT/Common/include" -I "$ROOT/Client/src" \
    -framework Foundation -framework VideoToolbox -framework CoreMedia \
    -framework CoreVideo -framework CoreFoundation \
    "$ROOT/Common/rtp_protocol.c" \
    "$ROOT/Client/src/LSReceiver.m" \
    "$ROOT/Client/src/LSDepacketizer.m" \
    "$ROOT/Client/src/LSDecoder.m" \
    "$ROOT/Tests/loopreceive.m" \
    -o "$OUT/lsloopreceive"

echo "==> building depacketizer unit tests"
xcrun clang -fobjc-arc -O1 -Wall -Wno-unused-parameter \
    -I "$ROOT/Common/include" -I "$ROOT/Client/src" \
    -framework Foundation \
    "$ROOT/Common/rtp_protocol.c" \
    "$ROOT/Client/src/LSDepacketizer.m" \
    "$ROOT/Tests/depacketizer_test.m" \
    -o "$OUT/lsdepacketizertest"

echo
echo "==> unit tests"
"$OUT/lsdepacketizertest"

echo
echo "==> loopback: encode -> RTP -> UDP -> depacketize -> decode"
# A floor only. The real assertion inside the receiver is that nothing is
# dropped once the pipeline is running; startup drops are by design.
MIN_FRAMES=$(( FRAMES - 12 ))
"$OUT/lsloopreceive" "$PORT" "$MIN_FRAMES" 25 &
RECEIVER=$!
sleep 1
"$OUT/lsloopsend" 127.0.0.1 "$PORT" "$FRAMES" "$FPS"

wait $RECEIVER
