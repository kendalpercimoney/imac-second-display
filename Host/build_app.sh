#!/bin/bash
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
