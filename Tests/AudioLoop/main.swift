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

// Audio from the host's packetiser to the client's parser, over a real socket.
//
// The part worth testing is the seam: ScreenCaptureKit hands over audio in
// whatever sized chunks it likes, and the wire wants fixed packets of whole
// frames. Getting that wrong does not fail loudly — it swaps the channels over
// and stays swapped, or drops a few samples per callback, which sounds like
// nothing in particular until you listen for it.
//
// So: feed the real AudioSender deliberately awkward chunk sizes, and check
// that what comes out the other side is exactly what went in.

import Foundation
import Darwin
import LSProtocol

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

let port: UInt16 = 5099
let channels = Int(LS_AUDIO_CHANNELS)

// A receiver on a real socket, so the packets go through the kernel.
let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
precondition(fd >= 0, "socket")
var reuse: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
var rcvbuf: Int32 = 4 * 1024 * 1024
setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_addr.s_addr = INADDR_ANY
addr.sin_port = port.bigEndian
let bound = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
precondition(bound == 0, "bind: \(String(cString: strerror(errno)))")
// So the receive loop ends instead of blocking forever if nothing arrives.
var timeout = timeval(tv_sec: 2, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

// A ramp rather than a tone: every sample is distinguishable from every other
// one nearby, so a swap or a dropped frame shows up as a mismatch at a known
// index rather than as something that still looks plausible.
let totalFrames = 20_000
var source = [Int16](repeating: 0, count: totalFrames * channels)
for frame in 0..<totalFrames {
    for channel in 0..<channels {
        source[frame * channels + channel] = Int16(truncatingIfNeeded: frame &* 2 &+ channel)
    }
}

var received = [Int16]()
var sequences = [UInt16]()
var timestamps = [UInt32]()
var frameCounts = [Int]()
let done = DispatchSemaphore(value: 0)

let receiver = Thread {
    var packet = [UInt8](repeating: 0, count: Int(LS_AUDIO_MAX_PACKET))
    var parsed = ls_audio_packet()
    while true {
        let n = packet.withUnsafeMutableBytes { raw -> Int in
            recvfrom(fd, raw.baseAddress, raw.count, 0, nil, nil)
        }
        if n <= 0 { break }
        let ok = packet.withUnsafeBytes { raw -> Bool in
            ls_audio_parse(raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                           n, &parsed) == 0
        }
        if !ok { continue }
        sequences.append(parsed.sequence)
        timestamps.append(parsed.timestamp)
        let frames = Int(parsed.payload_length) / (Int(parsed.channels) * 2)
        frameCounts.append(frames)
        packet.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: Int(parsed.payload_offset))
            let samples = base.assumingMemoryBound(to: Int16.self)
            received.append(contentsOf: UnsafeBufferPointer(start: samples,
                                                            count: frames * Int(parsed.channels)))
        }
        if received.count >= totalFrames * channels { break }
    }
    done.signal()
}
receiver.start()
Thread.sleep(forTimeInterval: 0.3)

print("==> sending \(totalFrames) frames through the real packetiser")
let sender = try AudioSender(host: "127.0.0.1", port: port)

// Chunk sizes chosen to be awkward: none of them is a multiple of the packet
// size, one is larger than a packet, one is a single frame.
let chunks = [100, 333, 1, 1024, 7, 512, 999]
var offset = 0
var chunkIndex = 0
while offset < totalFrames {
    let frames = min(chunks[chunkIndex % chunks.count], totalFrames - offset)
    chunkIndex += 1
    source.withUnsafeBufferPointer { buffer in
        let base = buffer.baseAddress!.advanced(by: offset * channels)
        sender.send(base, frames: frames, channels: channels)
    }
    offset += frames
    // Without this the sender outruns the socket buffer and the test measures
    // the kernel dropping packets rather than anything we wrote.
    if chunkIndex % 16 == 0 { Thread.sleep(forTimeInterval: 0.002) }
}
sender.flush()

_ = done.wait(timeout: .now() + 5)
close(fd)

print()
print("==> what arrived")
check("every frame arrived", received.count == totalFrames * channels,
      "\(received.count / channels) of \(totalFrames) frames")

if received.count == totalFrames * channels {
    var firstMismatch = -1
    for i in 0..<received.count where received[i] != source[i] { firstMismatch = i; break }
    check("every sample is identical, in order", firstMismatch < 0,
          firstMismatch < 0 ? "" : "first mismatch at sample \(firstMismatch)")

    // A channel swap keeps every value present but puts them in the wrong
    // order, which the check above would catch — this says so explicitly.
    let leftOK = stride(from: 0, to: received.count, by: channels).allSatisfy {
        received[$0] == source[$0]
    }
    check("the channels did not swap", leftOK)
}

check("packets are numbered contiguously",
      sequences == Array(0..<UInt16(sequences.count)).map { $0 },
      "\(sequences.count) packets")

let full = frameCounts.dropLast()
check("every packet but the last is exactly one packet's worth",
      full.allSatisfy { $0 == Int(LS_AUDIO_FRAMES_PER_PACKET) },
      "sizes seen: \(Set(full).sorted())")

var timestampsAdvance = true
var expected: UInt32 = 0
for (index, stamp) in timestamps.enumerated() {
    if stamp != expected { timestampsAdvance = false; break }
    expected &+= UInt32(frameCounts[index])
}
check("timestamps advance by exactly the frames sent", timestampsAdvance)

print()
print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
