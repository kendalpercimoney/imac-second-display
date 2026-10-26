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
# Whether the client shows the colours it was sent, to within a few code
# values, on the colours that matter: mid-tones, not saturated primaries.
#
# The host captures with ScreenCaptureKit, which converts to YCbCr with the
# BT.709 matrix. The client has to convert back with the same one, or every
# colour that is not grey or fully saturated shifts -- foliage and skin by over
# ten code values. The render test cannot see that: its quadrants are pure
# primaries, which clip at 0 and 255 whichever matrix is used, and it allows
# +/-40. This uses mid-tone patches and allows +/-4.
#
# This opens a window for a couple of seconds.
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-colour"
PORT="${PORT:-5058}"
SNAPSHOT="$OUT/colours.png"
TOLERANCE="${TOLERANCE:-4}"
mkdir -p "$OUT"

xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"

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

xcrun clang -fobjc-arc -O1 -framework Foundation -framework CoreGraphics \
    -framework ImageIO "$ROOT/Tests/checkcolours.m" -o "$OUT/checkcolours"

# A throwaway native client, kept out of build/ for the same reason as the
# render test: that holds the real 10.9 binary.
ARCH="$(uname -m)" MIN_VERSION=14.0 OUT_DIR="$OUT/nativeclient" \
    "$ROOT/Client/build.sh" > "$OUT/clientbuild.log" 2>&1 \
    || { cat "$OUT/clientbuild.log"; exit 1; }

# One run of the client against the patch pattern. Prints the client's colour
# check and the checker's verdict, and returns the checker's exit status.
run_case() {
    local colour_path="$1" strip="$2"
    rm -f "$SNAPSHOT"
    "$OUT/nativeclient/LanScreenClient.app/Contents/MacOS/LanScreenClient" \
        -host 127.0.0.1 -videoPort "$PORT" -windowed YES -input NO \
        -colourPath "$colour_path" -colourStripTags "$strip" \
        -snapshot "$SNAPSHOT" -snapshotAfter 40 > "$OUT/client.log" 2>&1 &
    local client=$!
    sleep 1.5
    "$OUT/lsloopsend" 127.0.0.1 "$PORT" 200 60 patches shipping > /dev/null 2>&1
    wait $client 2>/dev/null || true
    grep -E "colour check" "$OUT/client.log" | sed 's/^.*\] /  /'
    "$OUT/checkcolours" "$SNAPSHOT" "$TOLERANCE" > "$OUT/check.log" 2>&1
    local status=$?
    grep -E "worst channel" "$OUT/check.log" | sed 's/^/  /'
    return $status
}

failures=0
expect() {   # expect <description> <condition result: 0 = true>
    if [ "$2" = "0" ]; then echo "  ok   $1"; else echo "  FAIL $1"; failures=$((failures + 1)); fi
}

echo
echo "==> frames tagged as the decoder tags them, check left to decide"
run_case auto NO; status=$?
expect "the colours come out right" $status
grep -q "built-in conversion is within" "$OUT/client.log"; kept=$?
expect "the check measured what real frames get, so it kept the built-in conversion" $kept

echo
echo "==> the BT.709 shader, forced"
run_case shader NO; status=$?
expect "the shader gets the colours right too" $status

echo
echo "==> untagged frames, the built-in conversion forced"
echo "    (what a Mac whose decoder does not tag its frames would show)"
run_case builtin YES; status=$?
[ $status -ne 0 ]; wrong=$?
expect "the built-in conversion really does get them wrong -- so this case is real" $wrong

echo
echo "==> untagged frames, check left to decide"
run_case auto YES; status=$?
expect "the check notices and switches to the shader" \
    "$(grep -q "so a BT.709 shader is used instead" "$OUT/client.log"; echo $?)"
expect "and the colours come out right" $status

echo
echo "last snapshot: $SNAPSHOT"
if [ $failures -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL ($failures)"; exit 1; fi
