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

import Foundation
import Darwin
import LSProtocol

/// Sends Wake-on-LAN magic packets to the client.
///
/// A magic packet is recognised by the network card itself, not by the
/// operating system, which is why it can wake a machine that is asleep. The
/// card must be left powered: on the iMac that means Energy Saver ▸
/// "Wake for network access" has to be ticked, or none of this does anything.
///
/// The host cannot discover the client's MAC on its own. Since macOS 11 the
/// hardware address is masked from unentitled apps through getifaddrs, arp and
/// the routing sysctl alike, so the address has to come from the client (which
/// runs on OS X 10.9, where no such restriction exists) or be typed in by hand.
enum WakeOnLAN {

    struct Result {
        var sent: Int
        var destinations: [String]
        /// The local address the packets went out from. If this is not on the
        /// direct link, the packet went out the wrong interface and the iMac
        /// will never see it.
        var sentFrom: String?
        var error: String?

        var summary: String {
            if let error { return error }
            let via = sentFrom.map { " from \($0)" } ?? ""
            return "Sent \(sent) magic packet(s)\(via) to \(destinations.joined(separator: ", "))"
        }
    }

    /// Sends the magic packet to the client's unicast address and to the
    /// directed broadcast for its subnet.
    ///
    /// Both, because a sleeping card's behaviour varies: some accept a unicast
    /// packet, others only see broadcast traffic. On a direct cable there is no
    /// one else to bother, so sending twice costs nothing.
    static func wake(macAddress: String, clientAddress: String) -> Result {
        var mac = [UInt8](repeating: 0, count: 6)
        guard ls_parse_mac(macAddress, &mac) == 0 else {
            return Result(sent: 0, destinations: [], sentFrom: nil,
                          error: "'\(macAddress)' is not a MAC address.")
        }

        var packet = [UInt8](repeating: 0, count: Int(LS_WOL_PACKET_SIZE))
        guard ls_wol_build_magic_packet(&packet, packet.count, mac) > 0 else {
            return Result(sent: 0, destinations: [], sentFrom: nil,
                          error: "Could not build the magic packet.")
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return Result(sent: 0, destinations: [], sentFrom: nil,
                          error: "socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // Bind to our address on the client's subnet so the packet leaves by the
        // direct link. Without this a broadcast would follow the default route
        // and go out over Wi-Fi, where the iMac is not listening.
        var sentFrom: String?
        if let localAddress = localAddressOnSameSubnet(as: clientAddress) {
            if var bindAddress = try? makeSockaddr(host: localAddress, port: 0) {
                let rc = withUnsafePointer(to: &bindAddress) { p -> Int32 in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc == 0 { sentFrom = localAddress }
            }
        }

        var destinations: [String] = []
        var sent = 0
        var targets = [clientAddress]
        if let broadcast = directedBroadcast(for: clientAddress) { targets.append(broadcast) }

        for host in targets {
            for port in [UInt16(LS_WOL_PORT), UInt16(7)] {
                guard var destination = try? makeSockaddr(host: host, port: port) else { continue }
                let n = withUnsafePointer(to: &destination) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        packet.withUnsafeBytes { bytes in
                            sendto(fd, bytes.baseAddress, bytes.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if n > 0 {
                    sent += 1
                    destinations.append("\(host):\(port)")
                }
            }
        }

        if sent == 0 {
            return Result(sent: 0, destinations: [], sentFrom: sentFrom,
                          error: "No magic packet could be sent. Is the Ethernet link up?")
        }
        return Result(sent: sent, destinations: destinations, sentFrom: sentFrom, error: nil)
    }

    /// The /24 directed broadcast for an address, e.g. 10.0.0.2 -> 10.0.0.255.
    ///
    /// /24 is assumed because that is what the setup instructions specify. A
    /// wider mask still works for the unicast attempt above.
    static func directedBroadcast(for address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    /// Our own IPv4 address on the same /24 as the client, if we have one.
    /// IP addresses are not masked by the OS the way hardware addresses are.
    static func localAddressOnSameSubnet(as clientAddress: String) -> String? {
        let clientParts = clientAddress.split(separator: ".")
        guard clientParts.count == 4 else { return nil }
        let prefix = clientParts.prefix(3).joined(separator: ".") + "."

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let rawAddress = current.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = UnsafeRawPointer(rawAddress).assumingMemoryBound(to: sockaddr_in.self).pointee
            inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            let text = String(cString: buffer)
            if text.hasPrefix(prefix) { return text }
        }
        return nil
    }
}
