// This file is part of LanScreen.
// Copyright (C) 2026 Kendal Percimoney
//
// LanScreen is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// LanScreen is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.

// Does the host find out what the link can carry, and does it act on it?
//
// The failure this guards against is silent by construction: an oversized
// payload is not rejected by anything, it is fragmented by IP and delivered,
// and the only symptom is a stream that comes apart under loss. So the check
// has to be the thing that is tested.
//
//     ./Tests/run_mtu_test.sh
//
// The MTU is read against the loopback interface, whose MTU is 16384 on macOS
// and fixed, and against whatever interface actually routes to a given address.

import Foundation
import Darwin

var failures = 0

func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

// MARK: - the interface lookup

print("==> reading the MTU of the interface that routes to a destination")

guard let loopback = try? UDPSender(host: "127.0.0.1", port: 9) else {
    print("FAIL could not open a socket to loopback")
    exit(1)
}
let loopbackMTU = loopback.linkMTU
check("loopback MTU is found", loopbackMTU != nil, "got \(loopbackMTU.map(String.init) ?? "nil")")
// lo0 is 16384 on macOS and has been for a very long time. Asserting a
// specific number rather than "not nil" is deliberate: "not nil" passes when
// the lookup returns the wrong interface's MTU, which is the mistake worth
// catching.
check("loopback MTU is lo0's 16384", loopbackMTU == 16384,
      "got \(loopbackMTU.map(String.init) ?? "nil")")

// Something off-box. The MTU should be a real Ethernet or Wi-Fi figure, not
// loopback's, which proves the lookup follows the route rather than always
// answering with the same interface.
if let external = try? UDPSender(host: "10.0.0.2", port: 9) {
    let mtu = external.linkMTU
    check("an off-box destination resolves to a different interface",
          mtu != nil && mtu != 16384, "got \(mtu.map(String.init) ?? "nil")")
    if let mtu = mtu {
        check("and its MTU is a plausible link MTU", mtu >= 576 && mtu <= 9216, "got \(mtu)")
    }
}

// MARK: - the clamp

print()
print("==> the payload the host would use, given a link MTU")

/// The host's own function, compiled from Host/Sources/UDPSocket.swift. The
/// first version of this test reimplemented the arithmetic here, which would
/// have let it pass with the real thing broken.
func effectivePayload(requested: Int, linkMTU: Int?, headerSize: Int = 12) -> Int {
    lsEffectiveMTUPayload(requested: requested, linkMTU: linkMTU, headerSize: headerSize)
}

check("1400 B on a 1500 B link is left alone",
      effectivePayload(requested: 1400, linkMTU: 1500) == 1400)
check("8900 B on a 9000 B link is left alone",
      effectivePayload(requested: 8900, linkMTU: 9000) == 8900)
check("8900 B on a 1500 B link is cut to 1472 B",
      effectivePayload(requested: 8900, linkMTU: 1500) == 1472,
      "got \(effectivePayload(requested: 8900, linkMTU: 1500))")
check("the result plus overhead exactly fills the link",
      effectivePayload(requested: 8900, linkMTU: 1500) + lsIPv4UDPOverhead == 1500)
check("an unknown MTU changes nothing",
      effectivePayload(requested: 8900, linkMTU: nil) == 8900)
check("a tiny MTU still leaves room for a header",
      effectivePayload(requested: 8900, linkMTU: 100) >= 12 + 64)

print()
if failures == 0 {
    print("RESULT: PASS")
    exit(0)
} else {
    print("RESULT: FAIL (\(failures))")
    exit(1)
}
