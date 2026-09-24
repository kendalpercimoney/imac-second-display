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
//  Loopback sender: real VideoToolbox H.264 encode -> real RTP packetizer ->
//  real UDP socket. No ScreenCaptureKit, so it runs headless with no TCC
//  prompt, but every byte on the wire is produced by the same code the host
//  app uses.
//
//  Usage: lsloopsend <host> <port> <frameCount>
//
import Foundation
import CoreVideo
import CoreMedia
import LSProtocol
import VideoToolbox

/// BGRA to biplanar 4:2:0 video range, as ScreenCaptureKit would hand it over.
func convertTo420v(_ source: CVPixelBuffer) -> CVPixelBuffer {
    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
    guard let transfer else { return source }
    var destination: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault,
                        CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                        &destination)
    guard let destination else { return source }
    VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
    return destination
}

let arguments = CommandLine.arguments
let host = arguments.count > 1 ? arguments[1] : "127.0.0.1"
let port = UInt16(arguments.count > 2 ? arguments[2] : "5000") ?? 5000
let frameCount = Int(arguments.count > 3 ? arguments[3] : "30") ?? 30
let fps = Int(arguments.count > 4 ? arguments[4] : "30") ?? 30
// "motion" exercises the encoder with real detail; "bars" is a flat quadrant
// pattern whose colours can be checked numerically after the round trip.
let pattern = arguments.count > 5 ? arguments[5] : "motion"
// "greedy" mirrors the host's settings: 4:2:0 capture into the low-latency
// rate controller. The colour path differs from BGRA, so the render test has
// to be run through this to mean anything.
let greedy = (arguments.count > 6 ? arguments[6] : "") == "greedy"

let width = 1280, height = 720

func makeFrame(_ index: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        attributes as CFDictionary, &buffer)
    guard let pixelBuffer = buffer else { fatalError("CVPixelBufferCreate failed") }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)

    if pattern == "bars" {
        // Four flat quadrants. Flat so chroma subsampling cannot blur them,
        // and asymmetric so a vertical or horizontal flip is obvious.
        //   top-left red     top-right green
        //   bottom-left blue bottom-right white
        for y in 0..<height {
            let row = base + y * stride
            let top = y < height / 2
            for x in 0..<width {
                let p = row + x * 4
                let left = x < width / 2
                var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
                switch (top, left) {
                case (true,  true):  r = 255
                case (true,  false): g = 255
                case (false, true):  b = 255
                case (false, false): r = 255; g = 255; b = 255
                }
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    // A moving vertical bar over a gradient: enough real detail that the
    // encoder produces multi-packet frames and genuine inter-frame motion.
    let barX = (index * 37) % width
    for y in 0..<height {
        let row = base + y * stride
        for x in 0..<width {
            let p = row + x * 4
            let onBar = abs(x - barX) < 40
            p[0] = onBar ? 250 : UInt8(truncatingIfNeeded: x &* 255 / width)      // B
            p[1] = onBar ? 40  : UInt8(truncatingIfNeeded: y &* 255 / height)     // G
            p[2] = onBar ? 40  : UInt8(truncatingIfNeeded: (x &+ y &+ index * 4)) // R
            p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

let sender = try UDPSender(host: host, port: port)
// Packet size from the environment, so the cost of cutting frames into six
// times as many packets can be measured rather than assumed.
let mtuPayload = ProcessInfo.processInfo.environment["LS_MTU_PAYLOAD"]
    .flatMap(Int.init) ?? Int(LS_DEFAULT_MTU_PAYLOAD)
let packetizer = RTPPacketizer(sender: sender, mtuPayload: mtuPayload)

var emitted = 0
let done = DispatchSemaphore(value: 0)

let encoder = VideoEncoder(config: .init(width: width, height: height,
                                         frameRate: fps,
                                         bitrate: 12_000_000,
                                         profileIsBaseline: true,
                                         keyframeInterval: 1.0,
                                         lowLatencyRateControl: greedy)) { sampleBuffer in
    packetizer.packetize(sampleBuffer: sampleBuffer)
    emitted += 1
    if emitted >= frameCount { done.signal() }
}

try encoder.start()
if !encoder.warnings.isEmpty {
    FileHandle.standardError.write("encoder hints declined: \(encoder.warnings)\n".data(using: .utf8)!)
}

// Generate up front: the pixel-filling loop below is plain Swift and slow, and
// it has no business sitting inside the timed path.
var frames = (0..<min(frameCount, 60)).map { makeFrame($0) }
if greedy { frames = frames.map(convertTo420v) }

for index in 0..<frameCount {
    let pixelBuffer = frames[index % frames.count]
    // Stamp with the host time clock, exactly as ScreenCaptureKit does. Both
    // ends of this test share that clock, so the receiver can measure true
    // end-to-end pipeline latency.
    let pts = CMClockGetTime(CMClockGetHostTimeClock())
    encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts, forceKeyframe: index == 0)
    usleep(UInt32(1_000_000 / fps))
}

_ = done.wait(timeout: .now() + 10)
encoder.stop()

print("sent \(emitted) frames, \(packetizer.packetsSent) packets, \(packetizer.bytesSent) bytes")
