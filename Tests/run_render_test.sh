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

echo "==> building a throwaway native client (not the 10.9 binary in build/)"
# OUT_DIR keeps this out of build/, which holds the real x86_64 client built on
# the iMac and tracked in git. Overwriting that with an arm64 binary would be a
# quiet and confusing way to break the published download.
ARCH="$(uname -m)" MIN_VERSION=14.0 OUT_DIR="$OUT/nativeclient" \
    "$ROOT/Client/build.sh" > "$OUT/clientbuild.log" 2>&1 \
    || { cat "$OUT/clientbuild.log"; exit 1; }

echo "==> running (a window will open briefly)"
rm -f "$SNAPSHOT"
"$OUT/nativeclient/LanScreenClient.app/Contents/MacOS/LanScreenClient" \
    -host 127.0.0.1 -videoPort "$PORT" -windowed YES \
    -snapshot "$SNAPSHOT" -snapshotAfter 40 > "$OUT/client.log" 2>&1 &
CLIENT=$!
sleep 1.5
# "greedy": 4:2:0 capture into the low-latency rate controller, matching what
# the host now does. The colour path differs from BGRA, so testing the old one
# would prove nothing about what actually ships.
"$OUT/lsloopsend" 127.0.0.1 "$PORT" 200 60 bars "${PIPELINE:-greedy}" > /dev/null 2>&1
wait $CLIENT 2>/dev/null || true

tail -1 "$OUT/client.log"
echo
"$OUT/checkpattern" "$SNAPSHOT" 40
echo
echo "snapshot: $SNAPSHOT"

