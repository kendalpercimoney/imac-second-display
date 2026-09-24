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
//  Stands in for the host's control channel and sends a pointer, so the
//  client's drawing of it can be checked without running the real host.
//
//  Uses the real ls_ctrl_build_cursor* builders rather than hand-rolled bytes,
//  so the test exercises the same encoding the host uses.
//
//  Usage: cursorsend <control-port> <x> <y> <seconds>
//
import Foundation
import Darwin
import LSProtocol

let port = UInt16(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "5001") ?? 5001
let cursorX = UInt16(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "400") ?? 400
let cursorY = UInt16(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "300") ?? 300
let seconds = Double(CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "6") ?? 6

let size = 16
let hotspot = 8

// Solid magenta, fully opaque. The bars pattern is red where the pointer lands,
// so a magenta pixel there proves both that it drew and that it drew on top.
var rgba = [UInt8](repeating: 0, count: size * size * 4)
for i in 0..<(size * size) {
    rgba[i * 4 + 0] = 255   // R
    rgba[i * 4 + 1] = 0     // G
    rgba[i * 4 + 2] = 255   // B
    rgba[i * 4 + 3] = 255   // A
}

let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = INADDR_ANY.bigEndian
_ = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
var tv = timeval(tv_sec: 0, tv_usec: 200_000)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

print("cursorsend: listening on \(port)")

var client = sockaddr_in()
var imageBuffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_PACKET))
var positionBuffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
var have = false
let deadline = Date().addingTimeInterval(seconds)
var recvBuffer = [UInt8](repeating: 0, count: 2048)

while Date() < deadline {
    var from = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) { p -> Int in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            recvBuffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, sa, &length) }
        }
    }
    if n > 0 && !have { client = from; have = true; print("cursorsend: client found") }
    guard have else { continue }

    // The bitmap first, then position updates. Both are re-sent: there is no
    // acknowledgement, and the bitmap is large enough that IP may fragment it.
    let imageBytes = rgba.withUnsafeBufferPointer { p in
        ls_ctrl_build_cursor_image(&imageBuffer, imageBuffer.count, 1,
                                   UInt16(size), UInt16(size),
                                   UInt16(hotspot), UInt16(hotspot),
                                   p.baseAddress, UInt32(rgba.count))
    }
    var target = client
    _ = withUnsafePointer(to: &target) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            sendto(fd, imageBuffer, Int(imageBytes), 0, sa,
                   socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    let positionBytes = ls_ctrl_build_cursor(&positionBuffer, positionBuffer.count,
                                             cursorX, cursorY, 1, 1)
    _ = withUnsafePointer(to: &target) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            sendto(fd, positionBuffer, Int(positionBytes), 0, sa,
                   socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    usleep(100_000)
}
print("cursorsend: done")
