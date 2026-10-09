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

# Whether falling behind in decoding can ever put a damaged frame on screen.
# Real frames, really decoded, each scored against what it should have been.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-decoderdrop"
mkdir -p "$OUT"

xcrun clang -fobjc-arc -O2 -Wall -Wno-unused-parameter \
    -I "$ROOT/Client/src" \
    -framework Foundation -framework VideoToolbox \
    -framework CoreMedia -framework CoreVideo \
    "$ROOT/Client/src/LSDecodeQueue.m" \
    "$ROOT/Tests/DecoderDrop/main.m" \
    -o "$OUT/lsdecoderdrop"
"$OUT/lsdecoderdrop"
