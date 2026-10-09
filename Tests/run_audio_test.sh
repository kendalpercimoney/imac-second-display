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

# Audio from the host's packetiser to the client's parser, over a real socket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-audio"
mkdir -p "$OUT"

xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"

xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/UDPSocket.swift" \
    "$ROOT/Host/Sources/AudioSender.swift" \
    "$ROOT/Tests/AudioLoop/main.swift" \
    -o "$OUT/lsaudiotest"

"$OUT/lsaudiotest"
