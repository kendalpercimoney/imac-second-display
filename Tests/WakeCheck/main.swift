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

//
//  Checks the Wake-on-LAN path: subnet arithmetic, interface selection, and
//  that the packet actually leaves by the direct link rather than following the
//  default route out over Wi-Fi, where the iMac would never see it.
//
//  Usage: wakecheck <client-ip> <mac>
//
import Foundation
import LSProtocol

let clientIP = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "10.0.0.2"
let mac = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "c4:2c:03:07:35:10"

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("  FAIL \(message)") }
}

print("MAC survives a HELLO round trip into Swift")
do {
    // Exactly the conversion ControlChannel performs on an incoming HELLO.
    // The C struct imports as a tuple in Swift, and getting that rebinding
    // wrong would silently produce a wrong wake address.
    let original: [UInt8] = [0xC4, 0x2C, 0x03, 0x07, 0x35, 0x10]
    var buffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
    let written = original.withUnsafeBufferPointer {
        ls_ctrl_build_hello(&buffer, buffer.count, 1920, 1080, 5000, 0, $0.baseAddress)
    }
    check(written > 0, "could not build a HELLO carrying a MAC")

    var message = ls_ctrl_message()
    check(ls_ctrl_parse(&buffer, written, &message) == 0, "HELLO did not parse")
    check(message.has_mac != 0, "parsed HELLO does not report a MAC")

    var bytes = message.mac
    var text = [CChar](repeating: 0, count: 18)
    _ = withUnsafePointer(to: &bytes) { macPointer in
        macPointer.withMemoryRebound(to: UInt8.self, capacity: 6) {
            ls_format_mac(&text, text.count, $0)
        }
    }
    let formatted = String(cString: text)
    check(formatted == "c4:2c:03:07:35:10",
          "MAC came back as '\(formatted)', expected c4:2c:03:07:35:10")

    // And it must survive being handed straight back to the sender.
    let round = WakeOnLAN.wake(macAddress: formatted, clientAddress: clientIP)
    check(round.error == nil || round.error!.contains("link"),
          "a MAC decoded from HELLO was rejected by the sender: \(round.error ?? "")")

    check(message.screen_width == 1920 && message.screen_height == 1080,
          "screen size was disturbed by the MAC field")
}

print("rejects a bad MAC without sending anything")
let bad = WakeOnLAN.wake(macAddress: "nonsense", clientAddress: clientIP)
check(bad.sent == 0 && bad.error != nil, "a malformed MAC should be refused, got \(bad.summary)")

print("interface selection")
let link = WakeOnLAN.localLink(reaching: clientIP)
guard let link else {
    print("  no interface shares a subnet with \(clientIP) -- the direct link is down.")
    print("  Skipping the send check; bring the link up to exercise it.")
    print(failures == 0 ? "\nRESULT: PASS (send check skipped)" : "\nRESULT: FAIL")
    exit(failures == 0 ? 0 : 1)
}
print("  local address: \(link.address)")
print("  interface broadcast: \(link.broadcast ?? "none reported")")
check(link.broadcast != nil,
      "the interface reported no broadcast address, so the broadcast wake cannot be sent")

print("sending a real magic packet")
let result = WakeOnLAN.wake(macAddress: mac, clientAddress: clientIP)
print("  \(result.summary)")
check(result.error == nil, "send reported an error")
check(result.sentFrom == link.address,
      "packets must leave from \(link.address), went from \(result.sentFrom ?? "nil")")

// This is the assertion that matters, and it is self-validating: sendto fails
// outright for an address that is not reachable on the bound interface. The
// previous version computed the broadcast address by assuming a /24 and
// replacing the last octet, which on a link with a 255.255.0.0 mask produces an
// ordinary host address rather than a broadcast -- and those sends failed here.
check(result.destinations.contains("\(clientIP):9"), "missing the unicast destination")
if let broadcast = link.broadcast {
    check(result.destinations.contains("\(broadcast):9"),
          "the interface broadcast \(broadcast) was not reached")
}
check(result.destinations.contains("255.255.255.255:9"),
      "the limited broadcast backstop was not reached")

// Every target, both ports, no silent failures.
let expected = (link.broadcast == nil ? 2 : 3) * 2
check(result.sent == expected,
      "expected \(expected) packets, got \(result.sent) -- a destination was unreachable")

print(failures == 0 ? "\nRESULT: PASS" : "\nRESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
