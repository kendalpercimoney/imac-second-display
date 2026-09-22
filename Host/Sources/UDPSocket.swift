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

enum UDPError: LocalizedError {
    case socketFailed(Int32)
    case badAddress(String)
    case connectFailed(Int32)
    case bindFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let e):  return "socket() failed: \(String(cString: strerror(e)))"
        case .badAddress(let s):    return "Not a valid IPv4 address: \(s)"
        case .connectFailed(let e): return "connect() failed: \(String(cString: strerror(e)))"
        case .bindFailed(let e):    return "bind() failed: \(String(cString: strerror(e)))"
        }
    }
}

func makeSockaddr(host: String, port: UInt16) throws -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
        throw UDPError.badAddress(host)
    }
    return addr
}

/// A connected UDP socket used to blast RTP at the client.
///
/// We `connect()` even though UDP is connectionless: it lets us use `send()`
/// instead of `sendto()` (one less address copy per packet, and there are a
/// lot of packets) and it makes the kernel surface ICMP port-unreachable as
/// ECONNREFUSED, which is how we notice the client went away.
final class UDPSender {
    private(set) var fd: Int32 = -1

    init(host: String, port: UInt16, sendBufferBytes: Int = 8 * 1024 * 1024) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPError.socketFailed(errno) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // A keyframe is a burst of hundreds of packets. Without a deep send
        // buffer the kernel returns ENOBUFS and we lose them at the source.
        var sndbuf = Int32(sendBufferBytes)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))

        // DSCP EF (46 << 2 = 0xB8). Harmless on a direct cable, useful if this
        // ever crosses a managed switch.
        var tos = Int32(0xB8)
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))

        var addr = try makeSockaddr(host: host, port: port)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd); fd = -1
            throw UDPError.connectFailed(e)
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Returns bytes sent, or -1. ENOBUFS is retried a few times: it means the
    /// interface queue is momentarily full, not that anything is broken.
    @discardableResult
    func send(_ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        var attempts = 0
        while true {
            let n = Darwin.send(fd, bytes, count, 0)
            if n >= 0 { return n }
            if errno == EINTR { continue }
            if errno == ENOBUFS || errno == EAGAIN {
                attempts += 1
                if attempts > 64 { return -1 }
                usleep(50)
                continue
            }
            return -1
        }
    }
}

/// A bound UDP socket for the control back-channel. Receives on a dedicated
/// thread; replies go to whatever address the last datagram came from.
final class UDPBoundSocket {
    private(set) var fd: Int32 = -1

    init(port: UInt16, recvBufferBytes: Int = 1024 * 1024) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPError.socketFailed(errno) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var rcvbuf = Int32(recvBufferBytes)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd); fd = -1
            throw UDPError.bindFailed(e)
        }
    }

    func receive(into buffer: UnsafeMutableRawPointer, capacity: Int,
                 from: inout sockaddr_in) -> Int {
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafeMutablePointer(to: &from) { p -> Int in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, buffer, capacity, 0, sa, &len)
            }
        }
    }

    @discardableResult
    func send(_ bytes: UnsafeRawPointer, _ count: Int, to addr: sockaddr_in) -> Int {
        var a = addr
        return withUnsafePointer(to: &a) { p -> Int in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, bytes, count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Unblocks a thread parked in recvfrom().
    func shutdownAndClose() {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
            fd = -1
        }
    }

    deinit { shutdownAndClose() }
}

func addressString(_ addr: sockaddr_in) -> String {
    var a = addr
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &a.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}
