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
import LSProtocol

/// Cuts captured audio into fixed packets and puts them on the wire.
///
/// ScreenCaptureKit delivers audio in whatever sized chunks it feels like, so
/// this keeps a remainder between callbacks rather than emitting a short packet
/// and starting the next one mid-frame. A packet is always a whole number of
/// frames, which is what stops the channels drifting apart.
final class AudioSender {

    private let sender: UDPSender
    private let channels: Int

    /// Leftover samples that did not fill a packet last time.
    private var pending: [Int16] = []
    private var sequence: UInt16 = 0
    /// Frames sent so far, which is the timestamp the client sequences by.
    private var timestamp: UInt32 = 0

    private var packet = [UInt8](repeating: 0, count: Int(LS_AUDIO_MAX_PACKET))

    private(set) var bytesSent: Int = 0
    private(set) var packetsSent: Int = 0

    init(host: String, port: UInt16, channels: Int = Int(LS_AUDIO_CHANNELS)) throws {
        self.sender = try UDPSender(host: host, port: port)
        self.channels = max(1, channels)
        pending.reserveCapacity(Int(LS_AUDIO_FRAMES_PER_PACKET) * self.channels * 2)
    }

    /// Interleaved samples, `frames` of `channels` each. Called on the capture
    /// engine's audio queue and on no other thread.
    func send(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int) {
        guard frames > 0, channels == self.channels else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: samples,
                                                       count: frames * channels))

        let framesPerPacket = Int(LS_AUDIO_FRAMES_PER_PACKET)
        let samplesPerPacket = framesPerPacket * channels

        while pending.count >= samplesPerPacket {
            emit(Array(pending[0..<samplesPerPacket]), frames: framesPerPacket)
            pending.removeFirst(samplesPerPacket)
        }
    }

    /// Anything left over at the end of a stream, so the last fraction of a
    /// second is not swallowed.
    func flush() {
        guard !pending.isEmpty else { return }
        let frames = pending.count / channels
        if frames > 0 { emit(Array(pending[0..<(frames * channels)]), frames: frames) }
        pending.removeAll(keepingCapacity: true)
    }

    private func emit(_ samples: [Int16], frames: Int) {
        let header = packet.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Int(ls_audio_write_header(base, buffer.count,
                                             sequence, timestamp,
                                             LS_AUDIO_SAMPLE_RATE,
                                             UInt8(channels),
                                             UInt8(LS_AUDIO_FORMAT_S16LE)))
        }
        guard header > 0 else { return }

        // Little-endian on the wire by definition of the format, and both ends
        // are little-endian, so this is a copy and not a conversion.
        let payloadBytes = samples.count * 2
        guard header + payloadBytes <= packet.count else { return }
        samples.withUnsafeBytes { source in
            guard let from = source.baseAddress else { return }
            packet.withUnsafeMutableBytes { destination in
                guard let to = destination.baseAddress else { return }
                memcpy(to.advanced(by: header), from, payloadBytes)
            }
        }

        let total = header + payloadBytes
        let written = packet.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return sender.send(base, total)
        }
        if written > 0 {
            bytesSent += written
            packetsSent += 1
        }
        sequence &+= 1
        timestamp &+= UInt32(frames)
    }
}
