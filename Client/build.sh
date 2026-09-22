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

#
# Builds LanScreenClient.app on the iMac (OS X 10.9.5, Xcode 6.2).
#
# Copy the whole LanScreen folder across -- this script compiles
# ../Common/rtp_protocol.c, so Client/ on its own is not enough.
#
#   ./Client/build.sh
#
# If Xcode 6.2 lives somewhere unusual:
#   DEVELOPER_DIR=/Applications/Xcode6.2.app/Contents/Developer ./Client/build.sh
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so the render test can build a throwaway native client without
# clobbering the real 10.9 binary that ships in build/.
OUT="${OUT_DIR:-$ROOT/build}"
APP="$OUT/LanScreenClient.app"

# ---------------------------------------------------------------- toolchain --
# Find the Developer directory first and export it, so xcrun uses the toolchain
# we chose rather than whatever xcode-select happens to point at. On a machine
# where Xcode 6.2 was installed but xcode-select was never run, xcrun would
# otherwise fail outright.
find_developer_dir() {
    for candidate in \
        "${DEVELOPER_DIR:-}" \
        /Applications/Xcode6.2.app/Contents/Developer \
        /Applications/Xcode-6.2.app/Contents/Developer \
        /Applications/Xcode.app/Contents/Developer \
        "$(xcode-select -p 2>/dev/null || true)"
    do
        [ -n "$candidate" ] || continue
        if [ -d "$candidate/Toolchains/XcodeDefault.xctoolchain/usr/bin" ]; then
            echo "$candidate"; return
        fi
    done
}

DEVELOPER_DIR="$(find_developer_dir)"
if [ -z "$DEVELOPER_DIR" ]; then
    echo "error: could not find an Xcode installation." >&2
    echo "       Point DEVELOPER_DIR at it, e.g." >&2
    echo "       DEVELOPER_DIR=/Applications/Xcode6.2.app/Contents/Developer $0" >&2
    exit 1
fi
export DEVELOPER_DIR

find_sdk() {
    if [ -n "${SDKROOT:-}" ] && [ -d "$SDKROOT" ]; then
        echo "$SDKROOT"; return
    fi
    # Prefer an SDK that can actually target 10.9.
    for version in 10.9 10.10 10.11; do
        candidate="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX$version.sdk"
        if [ -d "$candidate" ]; then echo "$candidate"; return; fi
    done
    # Otherwise whatever this Xcode ships, which is right for a native build.
    candidate="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    if [ -d "$candidate" ]; then echo "$candidate"; return; fi
    xcrun --show-sdk-path 2>/dev/null || true
}

SDK="$(find_sdk)"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "error: could not find a macOS SDK under $DEVELOPER_DIR." >&2
    exit 1
fi

CC="${CC:-$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang}"
if [ ! -x "$CC" ]; then
    CC="$(xcrun -find clang 2>/dev/null || echo clang)"
fi

# Overridable only so the script can be smoke-tested on a modern Mac, where a
# current SDK refuses to target 10.9. Leave it alone on the iMac.
MIN_VERSION="${MIN_VERSION:-10.9}"
# x86_64 for the iMac. Override to build a native binary for testing the client
# on a modern Mac:  ARCH=$(uname -m) MIN_VERSION=14.0 ./Client/build.sh
ARCH="${ARCH:-x86_64}"

# ARC with a deployment target below 10.11 needs libarclite, which current
# Xcode toolchains no longer ship. That is fine -- this build is meant to run on
# the iMac under Xcode 6.2 -- but the raw clang error is baffling, so say what
# is actually going on.
if [ "$MIN_VERSION" = "10.9" ] || [ "$MIN_VERSION" = "10.10" ]; then
    ARCLITE="$(dirname "$CC")/../lib/arc/libarclite_macosx.a"
    if [ ! -f "$ARCLITE" ]; then
        echo "error: this toolchain cannot target macOS $MIN_VERSION." >&2
        echo "       libarclite_macosx.a is missing, which means you are on a modern" >&2
        echo "       Xcode. Run this script on the iMac with Xcode 6.2 installed." >&2
        echo >&2
        echo "       To build a test client for THIS Mac instead:" >&2
        echo "           ARCH=\$(uname -m) MIN_VERSION=14.0 $0" >&2
        exit 1
    fi
fi

echo "==> Xcode    $DEVELOPER_DIR"
echo "==> SDK      $SDK"
echo "==> compiler $CC"
echo "==> target   macOS $MIN_VERSION $ARCH"

# ------------------------------------------------------------------- build --
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# An array, not a string: the project path may contain spaces.
SOURCES=(
    "$ROOT/Common/rtp_protocol.c"
    "$ROOT/Client/src/main.m"
    "$ROOT/Client/src/LSAppDelegate.m"
    "$ROOT/Client/src/LSGLView.m"
    "$ROOT/Client/src/LSReceiver.m"
    "$ROOT/Client/src/LSDecoder.m"
    "$ROOT/Client/src/LSDepacketizer.m"
    "$ROOT/Client/src/LSControlClient.m"
    "$ROOT/Client/src/LSPowerManager.m"
)

# -fobjc-arc is fine on 10.9; weak references need 10.7+ and we are well past.
# -O2 rather than -Os: the depacketizer runs on every packet and this machine
# does not have cycles to spare.
"$CC" \
    -isysroot "$SDK" \
    -mmacosx-version-min="$MIN_VERSION" \
    -arch "$ARCH" \
    -fobjc-arc \
    -O2 \
    -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    -I"$ROOT/Common/include" \
    -I"$ROOT/Client/src" \
    -framework Cocoa \
    -framework VideoToolbox \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CoreFoundation \
    -framework OpenGL \
    -framework IOSurface \
    -framework ImageIO \
    -framework CoreServices \
    -framework IOKit \
    "${SOURCES[@]}" \
    -o "$APP/Contents/MacOS/LanScreenClient"

cp "$ROOT/Client/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo
echo "Built: $APP"
echo
echo "Run fullscreen against the host:"
echo "  \"$APP/Contents/MacOS/LanScreenClient\" -host 10.0.0.1"
echo
echo "Run in a window with statistics showing:"
echo "  \"$APP/Contents/MacOS/LanScreenClient\" -host 10.0.0.1 -windowed YES -stats YES"
