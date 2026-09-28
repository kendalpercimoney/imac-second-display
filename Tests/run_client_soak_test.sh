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

# Twelve hours of frames through the client's receive path, in about ten
# seconds, watching for anything that accumulates -- and across the 32-bit RTP
# timestamp wrap, which happens every 13h15m and was the first suspect for a
# freeze that took about twelve hours to arrive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-soak"
mkdir -p "$OUT"
FRAMES="${FRAMES:-2592000}"

echo "==> building the depacketizer soak"
xcrun clang -fobjc-arc -O1 -Wall -Wno-unused-parameter \
    -I "$ROOT/Common/include" -I "$ROOT/Client/src" \
    -framework Foundation -framework AudioToolbox \
    "$ROOT/Common/rtp_protocol.c" \
    "$ROOT/Client/src/LSDepacketizer.m" \
    "$ROOT/Tests/ClientSoak/main.m" \
    -o "$OUT/lssoak"

echo "==> building the decoder wrap check"
xcrun clang -fobjc-arc -O1 -Wall -Wno-unused-parameter \
    -I "$ROOT/Common/include" -I "$ROOT/Client/src" \
    -framework Foundation -framework VideoToolbox \
    -framework CoreMedia -framework CoreVideo \
    "$ROOT/Common/rtp_protocol.c" \
    "$ROOT/Client/src/LSDecoder.m" \
    "$ROOT/Tests/DecoderWrap/main.m" \
    -o "$OUT/lswrap"

echo
echo "==> $FRAMES frames through the depacketizer"
"$OUT/lssoak" "$FRAMES"

echo
echo "==> the decoder across the timestamp wrap"
"$OUT/lswrap"
