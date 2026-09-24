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

# Whether an app with no window gets throttled, and whether a window prevents
# it. See Tests/NapCheck/main.swift for what is being measured and why.
#
#     ./Tests/run_nap_check.sh [minutes]        # default 8
#
# Real .app bundles, ad-hoc signed and launched through LaunchServices, because
# App Nap is a decision the OS makes about an *app* and a bare binary run from a
# shell is not the same thing.
set -euo pipefail

MINUTES="${1:-8}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/lanscreen-napcheck"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> compiling"
xcrun swiftc -O "$ROOT/Tests/NapCheck/main.swift" -o "$WORK/napcheck"

make_app() {
    local mode="$1" uielement="$2"
    local app="$WORK/NapCheck-$mode.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$WORK/napcheck" "$app/Contents/MacOS/NapCheck"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NapCheck</string>
    <key>CFBundleIdentifier</key><string>com.lanscreen.napcheck.$mode</string>
    <key>CFBundleName</key><string>NapCheck $mode</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><$uielement/>
</dict>
</plist>
PLIST
    printf 'APPL????' > "$app/Contents/PkgInfo"
    codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1
    echo "$app"
}

PLAIN_APP=$(make_app plain true)
ACC_APP=$(make_app accessory true)
WIN_APP=$(make_app window false)

echo "==> running all three for $MINUTES minutes"
echo "    plain      accessory, no window, no activity assertion"
echo "    accessory  accessory, no window, with the assertion    (the app now)"
echo "    window     regular, visible window, with the assertion (the app before)"
echo

for m in plain accessory window; do
    : > "$WORK/$m.log"
done

open -a "$PLAIN_APP" --args --mode plain     --minutes "$MINUTES" --log "$WORK/plain.log"
open -a "$ACC_APP"   --args --mode accessory --minutes "$MINUTES" --log "$WORK/accessory.log"
open -a "$WIN_APP"   --args --mode window    --minutes "$MINUTES" --log "$WORK/window.log"

# Wait for all three to say they are finished, or give up a minute late.
LIMIT=$(echo "$MINUTES * 60 + 60" | bc)
WAITED=0
while [ "$WAITED" -lt "$LIMIT" ]; do
    DONE=$(grep -l "done" "$WORK"/plain.log "$WORK"/accessory.log "$WORK"/window.log 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DONE" = "3" ]; then break; fi
    sleep 10
    WAITED=$((WAITED + 10))
done

pkill -f "NapCheck-" 2>/dev/null || true

echo "==> results"
for m in plain accessory window; do
    echo
    cat "$WORK/$m.log"
done
echo
echo "logs: $WORK"
