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

# Brings the client the iMac just built back to this Mac.
#
# serve_to_imac.sh goes the other way, and there is no scp between them: modern
# OpenSSH refuses 10.9's SHA-1 host keys. So the iMac serves over HTTP and this
# fetches. On the iMac, in the directory that contains LanScreenClient.app:
#
#     python -m SimpleHTTPServer 8000
#
# then here:
#
#     ./Tools/fetch_from_imac.sh [host] [port]
set -euo pipefail

HOST="${1:-10.0.0.2}"
PORT="${2:-8000}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/LanScreenClient.app"
BASE="http://$HOST:$PORT/LanScreenClient.app/Contents"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> fetching from $HOST:$PORT"
mkdir -p "$STAGE/Contents/MacOS"
curl -fsS --connect-timeout 5 "$BASE/MacOS/LanScreenClient" -o "$STAGE/Contents/MacOS/LanScreenClient"
curl -fsS --connect-timeout 5 "$BASE/Info.plist" -o "$STAGE/Contents/Info.plist"
curl -fsS --connect-timeout 5 "$BASE/PkgInfo" -o "$STAGE/Contents/PkgInfo" || printf 'APPL????' > "$STAGE/Contents/PkgInfo"

BIN="$STAGE/Contents/MacOS/LanScreenClient"

# It is worth checking what arrived. A binary built on the wrong machine, or a
# 404 page saved under the right name, both look fine until someone runs them
# on the iMac.
if ! file "$BIN" | grep -q "Mach-O.*x86_64"; then
    echo "error: that is not an x86_64 Mach-O binary:" >&2
    file "$BIN" >&2
    exit 1
fi
MINOS="$(otool -l "$BIN" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
case "$MINOS" in
    10.*) ;;
    *) echo "error: deployment target is $MINOS, not 10.x — was this built on the iMac?" >&2
       exit 1 ;;
esac

if [ -f "$APP/Contents/MacOS/LanScreenClient" ] \
   && cmp -s "$BIN" "$APP/Contents/MacOS/LanScreenClient"; then
    echo "==> identical to the copy already in build/, nothing to do"
    exit 0
fi

chmod +x "$BIN"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
cp -R "$STAGE" "$APP"

echo "==> updated $APP"
echo "    x86_64, deployment target $MINOS, $(stat -f %z "$APP/Contents/MacOS/LanScreenClient") bytes"
