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

# Sharpening a still picture: when it happens, and whether it works -- encoded
# for real through the host's own still-encoder configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lanscreen-still"
mkdir -p "$OUT"

xcrun swiftc -O \
    "$ROOT/Host/Sources/VideoEncoder.swift" \
    "$ROOT/Host/Sources/StillRefinement.swift" \
    "$ROOT/Tests/StillRefine/main.swift" \
    -o "$OUT/lsstill"
"$OUT/lsstill"
