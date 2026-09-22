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
        let link = localLink(reaching: clientAddress)

        var sentFrom: String?
        if let link, var bindAddress = try? makeSockaddr(host: link.address, port: 0) {
            let rc = withUnsafePointer(to: &bindAddress) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 { sentFrom = link.address }
        }

        var destinations: [String] = []
        var sent = 0
        // Unicast, then the interface's real broadcast address, then the
        // limited broadcast as a backstop. Sleeping cards differ in what they
        // will accept, and on a direct cable there is nobody else to bother.
        var targets = [clientAddress]
        if let broadcast = link?.broadcast, !targets.contains(broadcast) {
            targets.append(broadcast)
        }
        if !targets.contains("255.255.255.255") { targets.append("255.255.255.255") }

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

    /// This Mac's endpoint on the same link as the client.
    struct LocalLink {
        var address: String
        /// The interface's real broadcast address, read from the kernel.
        var broadcast: String?
    }

    /// Finds the interface that shares a subnet with `clientAddress`, using the
    /// interface's actual netmask.
    ///
    /// This used to assume /24 and compute the broadcast address by replacing
    /// the last octet with 255. On a link configured with a 255.255.0.0 mask
    /// that produces an address which is not the broadcast address at all, just
    /// an ordinary host on the subnet -- so the broadcast half of the wake
    /// silently went nowhere. The kernel already knows the right answer, so ask
    /// it rather than guessing from the address shape.
    static func localLink(reaching clientAddress: String) -> LocalLink? {
        var clientRaw = in_addr()
        guard inet_pton(AF_INET, clientAddress, &clientRaw) == 1 else { return nil }

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return nil }
        defer { freeifaddrs(head) }

        var entry = head
        while let current = entry {
            defer { entry = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let rawAddress = current.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET),
                  let rawNetmask = current.pointee.ifa_netmask else { continue }

            let local = UnsafeRawPointer(rawAddress)
                .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let mask = UnsafeRawPointer(rawNetmask)
                .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr

            // Same subnet under this interface's own mask, whatever it is.
            guard (local & mask) == (clientRaw.s_addr & mask) else { continue }

            var broadcast: String?
            if flags & IFF_BROADCAST != 0, let rawBroadcast = current.pointee.ifa_dstaddr,
               rawBroadcast.pointee.sa_family == UInt8(AF_INET) {
                var value = UnsafeRawPointer(rawBroadcast)
                    .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                broadcast = string(from: &value)
            }
            var localValue = in_addr(s_addr: local)
            guard let addressText = string(from: &localValue) else { continue }
            return LocalLink(address: addressText, broadcast: broadcast)
        }
        return nil
    }

    private static func string(from address: inout in_addr) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }
}
