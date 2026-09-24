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
//  The host's control channel must survive a client that goes away and comes
//  back.
//
//  Written to chase a reported disconnect, on the theory that the host's ping
//  landing on a restarted client's closed port would bounce an ICMP unreachable
//  into the receive loop, which used to treat any unexpected error as fatal and
//  end silently. No further pings would mean the client timed out and blanked.
//
//  That theory did not hold: this test passes against the pre-fix code too, so
//  the unreachable does not surface as a recvfrom error on a bound UDP socket
//  on macOS. The loop no longer dies on a transient error regardless, because
//  a channel that can vanish for the rest of a session with no log is not worth
//  keeping. This stays as a regression guard on the come-and-go path itself,
//  not as a reproduction of a known fault.
//
import Foundation
import Darwin
import LSProtocol

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("  FAIL \(message)") }
}

let port: UInt16 = 5402

let channel = ControlChannel()
do { try channel.start(port: port) } catch {
    print("could not start the control channel: \(error)")
    exit(2)
}

/// A throwaway stand-in for the client: says hello, then waits for a ping.
func speakToHost(label: String, timeout: Double) -> Bool {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = try! makeSockaddr(host: "127.0.0.1", port: port)
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    var tv = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var hello = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
    let n = ls_ctrl_build_hello(&hello, hello.count, 1920, 1080, 5000, 0, nil)

    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 256)
    while Date() < deadline {
        _ = hello.withUnsafeBytes { send(fd, $0.baseAddress, Int(n), 0) }
        let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if got > 0 {
            var message = ls_ctrl_message()
            if buffer.withUnsafeBufferPointer({ ls_ctrl_parse($0.baseAddress!, got, &message) }) == 0,
               Int32(message.type) == LS_MSG_PING {
                print("  \(label): got a ping back")
                return true
            }
        }
    }
    print("  \(label): no ping within \(timeout)s")
    return false
}

print("a client connects")
check(speakToHost(label: "first client", timeout: 6), "the host never pinged the first client")

// The first client's socket is closed now. The host keeps pinging that dead
// port, and the ICMP unreachable comes back at the host's receive loop.
print("first client is gone; letting the host ping a closed port")
Thread.sleep(forTimeInterval: 4)

print("a second client connects")
check(speakToHost(label: "second client", timeout: 8),
      "the control channel died after the first client went away")

channel.stop()
print(failures == 0 ? "\nRESULT: PASS" : "\nRESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
