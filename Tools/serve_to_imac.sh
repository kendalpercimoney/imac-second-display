#!/bin/bash
#
# Packages the client source and serves it over the direct Ethernet link so the
# iMac can fetch it with curl.
#
# Why not scp? Current OpenSSH refuses the SHA-1 host keys and algorithms that
# OS X 10.9's sshd offers, so scp from a modern Mac to a 10.9 box fails with
# "no matching host key type" unless you re-enable deprecated crypto. A plain
# HTTP fetch avoids the whole argument, and the link is a cable between two
# machines you own.
#
# Run on the MacBook:   ./Tools/serve_to_imac.sh
# Then on the iMac:     curl -O http://10.0.0.1:8000/LanScreen-client.tar.gz
#
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8000}"
HOST_IP="${HOST_IP:-10.0.0.1}"
# Stage outside build/. That directory is a build artifact people delete
# routinely, and pulling it out from under a running server turns every
# subsequent fetch into a 404 with no explanation.
STAGING="${TMPDIR:-/tmp}/lanscreen-transfer"
TARBALL="LanScreen-client.tar.gz"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

rm -rf "$STAGING"
mkdir -p "$STAGING"

# Only what the iMac needs: the shared wire format and the client. No .build,
# no host binaries, no Swift.
#
# The sources are required and the script should fail loudly if any are
# missing. The README is a nicety -- do not abandon the whole transfer because
# a documentation file was renamed or is being edited.
REQUIRED="Common/include Common/rtp_protocol.c Client/src Client/Info.plist Client/build.sh"
for item in $REQUIRED; do
    if [ ! -e "$ROOT/$item" ]; then
        echo "error: $item is missing from $ROOT" >&2
        echo "       Run this from a complete checkout." >&2
        exit 1
    fi
done

EXTRAS=""
if [ -f "$ROOT/README.md" ]; then
    EXTRAS="README.md"
else
    echo "note: README.md not found, packaging the sources without it."
fi

tar czf "$STAGING/$TARBALL" -C "$ROOT" $REQUIRED $EXTRAS

SIZE="$(du -h "$STAGING/$TARBALL" | cut -f1 | tr -d ' ')"

cat <<MESSAGE

Packaged $TARBALL ($SIZE)

On the iMac, in Terminal:

    cd ~
    curl -O http://$HOST_IP:$PORT/$TARBALL
    mkdir -p LanScreen && tar xzf $TARBALL -C LanScreen
    cd LanScreen
    ./Client/build.sh

Serving on http://$HOST_IP:$PORT/  --  press Ctrl-C when the iMac has it.

MESSAGE

cd "$STAGING"

# Serve only on the direct link rather than every interface. If that address is
# not configured yet, python would fail with "Can't assign requested address",
# which says nothing useful -- so check first.
if ifconfig 2>/dev/null | grep -q "inet $HOST_IP "; then
    # Not exec: the EXIT trap has to run so the staging copy is cleaned up.
    python3 -m http.server "$PORT" --bind "$HOST_IP" || true
    exit 0
fi

echo "warning: $HOST_IP is not configured on any interface."
echo "         Set up the direct link first (README section 1), or the iMac"
echo "         will not be able to reach this."
echo "         Serving on all interfaces for now."
echo
python3 -m http.server "$PORT" || true
