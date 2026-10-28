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
# Overridable so a release can be built beside the copy you run, rather than
# re-signing that one out from under its permissions (Tools/make_release.sh).
OUT="${OUT_DIR:-$ROOT/build}"
APP="$OUT/LanScreenHost.app"

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

# Signed with an Apple Development certificate when this Mac has one, ad-hoc
# otherwise. It decides whether Screen Recording and Accessibility survive a
# rebuild. macOS keys those grants on the signature's designated requirement:
# an ad-hoc signature's is the hash of this exact binary, so every rebuild is
# a new app to it, the old grant matches nothing, and it asks again -- for ever,
# if the copy being granted is not the copy being run. A certificate's is "this
# bundle identifier, signed by this team", which the next build meets too.
# LS_SIGN_IDENTITY picks a different certificate; "-" forces ad-hoc.
IDENTITY="${LS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> codesign ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "==> codesign (ad-hoc: Screen Recording will have to be granted again after every rebuild)"
    codesign --force --sign - --timestamp=none "$APP"
fi

echo
echo "Built: $APP"
echo "Open it with:  open \"$APP\""
