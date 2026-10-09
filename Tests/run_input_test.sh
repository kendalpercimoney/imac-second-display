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

# Keyboard and mouse forwarding, both ends: the client's forwarder, and the
# host's injector with its events recorded rather than posted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-input"
mkdir -p "$OUT"

xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"

echo "==> the host turning messages into events"
xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" \
    -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/InputInjector.swift" \
    "$ROOT/Tests/InputInjection/main.swift" \
    -o "$OUT/lsinject"
"$OUT/lsinject"

if [ -f "$ROOT/Tests/InputForwarder/main.m" ]; then
    echo
    echo "==> the client turning events into messages"
    xcrun clang -fobjc-arc -O1 -Wall -Wno-unused-parameter \
        -I "$ROOT/Common/include" -I "$ROOT/Client/src" \
        -framework Foundation \
        "$ROOT/Common/rtp_protocol.c" \
        "$ROOT/Client/src/LSInputForwarder.m" \
        "$ROOT/Tests/InputForwarder/main.m" \
        -o "$OUT/lsforward"
    "$OUT/lsforward"
fi
