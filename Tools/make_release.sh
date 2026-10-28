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
# Packages a release: the host, built here and signed ad-hoc, and the client the
# iMac built, each zipped, with nothing in either that says who made them.
#
#     ./Tools/make_release.sh v2.1.0
#
# It publishes nothing. It ends by printing the checksums and the gh command.
#
# Ad-hoc, because the certificate build_app.sh otherwise signs with is named
# after its owner's Apple ID, which is usually an email address, and codesign
# writes that name into the app, where `codesign -dv` shows it to anyone who
# downloads it. An ad-hoc signature carries no name. What that costs is that
# every release is a new app to macOS, so a downloaded host asks for Screen
# Recording and Accessibility again after each update. The copy in build/ that
# you run is left alone, signed as it was.
#
# Both apps are then searched for this Mac's git email, the name on every
# signing certificate in the keychain, and the home directory. Any of them, in
# either app or in either zip, stops the release.
set -euo pipefail

VERSION="${1:-}"
case "$VERSION" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: $0 vMAJOR.MINOR.PATCH" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="${CLIENT_APP:-$ROOT/build/LanScreenClient.app}"
OUT="$ROOT/dist/$VERSION"
STAGE="$OUT/stage"
cd "$ROOT"

# ------------------------------------------------------------------ the commit --
# A release is a commit. Uncommitted changes would ship code nobody can read.
if ! git diff --quiet HEAD --; then
    echo "error: the tree has uncommitted changes; commit them first" >&2
    exit 1
fi
COMMIT="$(git rev-parse --short HEAD)"
if TAGGED="$(git rev-parse -q --verify "refs/tags/$VERSION^{commit}")"; then
    if [ "$TAGGED" != "$(git rev-parse HEAD)" ]; then
        echo "error: $VERSION is tagged at $(git rev-parse --short "$TAGGED"), not at $COMMIT" >&2
        exit 1
    fi
else
    echo "note: $VERSION is not tagged yet; building $COMMIT"
fi

# ------------------------------------------------------------------ the client --
# No current toolchain targets 10.9, so the client is the one the iMac built
# with ./Client/build.sh. It must be newer than the last commit that changed
# it, or the release would pair this host with an older client.
CLIENT_SOURCES="Client/src Client/Info.plist Client/build.sh Common"
BIN="$CLIENT/Contents/MacOS/LanScreenClient"
if [ ! -f "$BIN" ]; then
    echo "error: no client at $CLIENT -- build it on the iMac with ./Client/build.sh" >&2
    exit 1
fi
if ! file "$BIN" | grep -q "Mach-O.*x86_64"; then
    echo "error: $BIN is not an x86_64 Mach-O binary" >&2
    exit 1
fi
MINOS="$(otool -l "$BIN" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
if [ "$MINOS" != "10.9" ]; then
    echo "error: the client's deployment target is ${MINOS:-unknown}, not 10.9 -- was it built on the iMac?" >&2
    exit 1
fi
# shellcheck disable=SC2086
CHANGED="$(git log -1 --format=%ct -- $CLIENT_SOURCES)"
if [ "$(stat -f %m "$BIN")" -lt "$CHANGED" ] && [ -z "${ALLOW_OLDER_CLIENT:-}" ]; then
    echo "error: the client was built $(date -r "$(stat -f %m "$BIN")" '+%d %b %H:%M'), before the last" >&2
    # shellcheck disable=SC2086
    echo "       change to its source ($(git log -1 --format='%h, %cd' --date=format:'%d %b %H:%M' -- $CLIENT_SOURCES))." >&2
    echo "       Rebuild it on the iMac, or set ALLOW_OLDER_CLIENT=1 if you know it matches." >&2
    exit 1
fi

# -------------------------------------------------------------------- the host --
rm -rf "$OUT"
mkdir -p "$STAGE"
LS_SIGN_IDENTITY=- OUT_DIR="$STAGE" "$ROOT/Host/build_app.sh"
# The linker leaves the path of every object file it read in the binary's debug
# map: 43 copies of this checkout's full path, home directory and all. Function
# names stay, so a crash report still says where it was.
strip -S "$STAGE/LanScreenHost.app/Contents/MacOS/LanScreenHost" 2> /dev/null
codesign --force --sign - --timestamp=none "$STAGE/LanScreenHost.app"
ditto --norsrc --noextattr --noacl "$CLIENT" "$STAGE/LanScreenClient.app"

# ----------------------------------------------------------- who made them --
# Read from this Mac each time, so none of it is written down in the repo.
NEEDLES=()
LABELS=()
need() { if [ -n "$2" ]; then NEEDLES+=("$2"); LABELS+=("$1"); fi; }
need "your git email" "$(git config --global user.email || true)"
need "your home directory" "$HOME"
while IFS= read -r name; do
    need "the name on a signing certificate" "$name"
done < <(security find-identity -v -p codesigning 2>/dev/null \
         | sed -n 's/.*"[^:]*: \(.*\) ([A-Z0-9]*)"$/\1/p' | sort -u)

# Says which kind of thing it found and where, never the thing itself.
clean() {   # clean <what> <path>...
    local what="$1" i dirty=0
    shift
    for ((i = 0; i < ${#NEEDLES[@]}; i++)); do
        if LC_ALL=C grep -r -q -a -i -F -e "${NEEDLES[$i]}" "$@"; then
            echo "error: ${LABELS[$i]} is in $what:" >&2
            LC_ALL=C grep -r -l -a -i -F -e "${NEEDLES[$i]}" "$@" | sed 's/^/       /' >&2
            dirty=1
        fi
    done
    return $dirty
}

for app in "$STAGE"/*.app; do
    if codesign -dv --verbose=2 "$app" 2>&1 | grep -q '^Authority='; then
        echo "error: $(basename "$app") is signed with a certificate, which names its owner" >&2
        exit 1
    fi
done
codesign -dv "$STAGE/LanScreenHost.app" 2>&1 | grep -q '^Signature=adhoc' \
    || { echo "error: the host is not signed ad-hoc" >&2; exit 1; }
clean "the apps" "$STAGE" || exit 1

# -------------------------------------------------------------------- the zips --
for name in LanScreenHost LanScreenClient; do
    ditto -c -k --norsrc --noextattr --noacl --keepParent \
        "$STAGE/$name.app" "$OUT/$name-$VERSION.zip"
done

# And again on what will actually be downloaded.
UNZIPPED="$OUT/unzipped"
mkdir -p "$UNZIPPED"
for zip in "$OUT"/*.zip; do ditto -x -k "$zip" "$UNZIPPED"; done
codesign --verify --strict "$UNZIPPED/LanScreenHost.app"
clean "the zips" "$OUT"/*.zip "$UNZIPPED" || exit 1

HOST_BIN="$UNZIPPED/LanScreenHost.app/Contents/MacOS/LanScreenHost"
HOST_ARCHS="$(lipo -archs "$HOST_BIN" | sed 's/ /, /g')"
HOST_MINOS="$(otool -l "$HOST_BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
rm -rf "$UNZIPPED" "$STAGE"

sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
echo
echo "Built $VERSION from $COMMIT, signed ad-hoc. Neither app names anyone."
echo
echo "| | Architecture | Minimum OS | SHA-256 |"
echo "|---|---|---|---|"
echo "| \`LanScreenHost-$VERSION.zip\` | $HOST_ARCHS | macOS ${HOST_MINOS%.0} | \`$(sum "$OUT/LanScreenHost-$VERSION.zip")\` |"
echo "| \`LanScreenClient-$VERSION.zip\` | x86_64 | OS X $MINOS | \`$(sum "$OUT/LanScreenClient-$VERSION.zip")\` |"
echo
echo "Publish with:"
echo "    gh release create $VERSION dist/$VERSION/*.zip --title \"$VERSION\" --notes-file <notes.md>"
