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

# Whether every control in the window reaches the pipeline, or says it does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-audit"
mkdir -p "$OUT"

xcrun clang -c -O2 -I "$ROOT/Common/include" \
    "$ROOT/Common/rtp_protocol.c" -o "$OUT/rtp_protocol.o"

xcrun swiftc -O \
    -Xcc -fmodule-map-file="$ROOT/Common/include/module.modulemap" \
    -Xcc -I"$ROOT/Common/include" \
    -I "$ROOT/Common/include" \
    "$OUT/rtp_protocol.o" \
    "$ROOT/Host/Sources/StreamSettings.swift" \
    "$ROOT/Host/Sources/StreamPlan.swift" \
    "$ROOT/Host/Sources/UDPSocket.swift" \
    "$ROOT/Tests/SettingsAudit/main.swift" \
    -o "$OUT/lsaudit"

"$OUT/lsaudit"
