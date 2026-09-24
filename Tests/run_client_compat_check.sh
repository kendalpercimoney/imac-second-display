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

# Does the client only use things that exist on OS X 10.9?
#
# It is built on the iMac against the 10.9 SDK, but it is *developed* on a
# current Mac against a current SDK, where anything Apple has added since 2013
# compiles perfectly happily. clock_gettime went in like that: fine here,
# "use of undeclared identifier CLOCK_REALTIME" over there, and the only way to
# find out was to walk to the other machine.
#
# Compiling against the current SDK with a 10.9 deployment target and
# -Wunguarded-availability puts that check on this side instead. Note the flag
# has no "-new" on the end: the -new variant only warns about things newer than
# the SDK's own baseline, which is not the question being asked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
TARGET="${MIN_VERSION:-10.9}"

echo "==> checking the client against macOS $TARGET using $(basename "$SDK")"

failed=0
for source in "$ROOT"/Client/src/*.m "$ROOT"/Common/rtp_protocol.c; do
    if ! output=$(xcrun clang -fsyntax-only \
            -isysroot "$SDK" \
            -mmacosx-version-min="$TARGET" \
            -arch x86_64 \
            -fobjc-arc \
            -Werror=unguarded-availability \
            -Wno-deprecated-declarations \
            -Wno-objc-missing-super-calls \
            -I "$ROOT/Common/include" \
            -I "$ROOT/Client/src" \
            "$source" 2>&1); then
        echo
        echo "  $(basename "$source"):"
        echo "$output" | grep -E "error:" | sed 's/^/    /'
        failed=1
    fi
done

echo
if [ "$failed" = "0" ]; then
    echo "RESULT: PASS — nothing newer than $TARGET"
else
    echo "RESULT: FAIL — the iMac's compiler will reject the above"
    exit 1
fi
