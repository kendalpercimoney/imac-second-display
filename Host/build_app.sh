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

# Builds LanScreenHost.app from the SwiftPM executable.
#
# Run on the M1 Pro with a current Xcode installed:
#     ./Host/build_app.sh            # release build
#     ./Host/build_app.sh debug      # debug build
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/LanScreenHost.app"

cd "$ROOT"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/LanScreenHost"
if [ ! -f "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LanScreenHost"
cp "$ROOT/Host/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. TCC keys its Screen Recording grant on the code signature,
# so re-signing after a rebuild can make macOS forget the permission. If the
# app stops seeing displays after a rebuild, remove it from
# System Settings > Privacy & Security > Screen Recording and add it again.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo
echo "Built: $APP"
echo "Open it with:  open \"$APP\""
