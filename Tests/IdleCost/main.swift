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
//  Measures what the idle heartbeat actually costs.
//
//  When the screen is static, ScreenCaptureKit stops delivering frames, and the
//  host re-encodes the last one as a forced IDR once a second so a late-joining
//  client still gets a picture. This asks: how many bytes is that, compared to
//  letting the encoder emit a normal inter frame, and compared to sending
//  nothing at all?
//
//  Usage: idlecost [width] [height] [seconds]
//
import Foundation
import CoreVideo
import CoreMedia
import LSProtocol

let width  = Int(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1920") ?? 1920
let height = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1080") ?? 1080
let seconds = Int(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "10") ?? 10

/// Something desktop-shaped: large flat areas, a few window rectangles, and a
/// band of fine detail standing in for text. Compresses roughly like a real
/// idle desktop rather than like noise or a flat colour.
func desktopFrame() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                        &buffer)
    guard let pixelBuffer = buffer else { fatalError("CVPixelBufferCreate failed") }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        let row = base + y * stride
        for x in 0..<width {
            let p = row + x * 4
            var r: UInt8 = 32, g: UInt8 = 36, b: UInt8 = 44          // desktop
            if x > 120 && x < width - 220 && y > 90 && y < height - 160 {
                r = 244; g = 244; b = 246                             // a window
                if y % 26 < 9 && x % 7 < 4 && x < width - 420 {
                    r = 40; g = 40; b = 44                            // "text"
                }
            }
            if x > width - 190 && y > 60 && y < 300 { r = 70; g = 90; b = 130 }  // a panel
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

let frame = desktopFrame()

func measure(label: String, forceKeyframeEveryFrame: Bool, frames: Int, fps: Int,
             keyframeInterval: Double = 2.0) -> Int {
    var total = 0
    let finished = DispatchSemaphore(value: 0)
    var seen = 0

    let encoder = VideoEncoder(config: .init(width: width, height: height,
                                             frameRate: fps,
                                             bitrate: 25_000_000,
                                             profileIsBaseline: true,
                                             keyframeInterval: keyframeInterval)) { sampleBuffer in
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            total += CMBlockBufferGetDataLength(block)
        }
        seen += 1
        if seen >= frames { finished.signal() }
    }
    try! encoder.start()

    for index in 0..<frames {
        let pts = CMTime(value: Int64(index) * Int64(90_000 / fps),
                         timescale: CMTimeScale(LS_RTP_CLOCK_HZ))
        encoder.encode(pixelBuffer: frame, presentationTime: pts,
                       forceKeyframe: forceKeyframeEveryFrame || index == 0)
        usleep(4000)
    }
    _ = finished.wait(timeout: .now() + 20)
    encoder.stop()
    print(String(format: "  %-46s %8d bytes over %d frames  (%.1f KB/frame)",
                 (label as NSString).utf8String!, total, frames,
                 Double(total) / Double(frames) / 1024.0))
    return total
}

print("Static \(width)x\(height) desktop, \(seconds) seconds of idle screen\n")

// What the heartbeat does today: one forced IDR per second.
let forced = measure(label: "heartbeat as built (forced IDR every second)",
                     forceKeyframeEveryFrame: true, frames: seconds, fps: 1)

// What it would cost to let the encoder decide. On a static screen an inter
// frame referencing an identical picture is almost nothing.
let natural = measure(label: "same cadence, encoder chooses the frame type",
                      forceKeyframeEveryFrame: false, frames: seconds, fps: 1)

let forcedMbps = Double(forced) * 8.0 / Double(seconds) / 1_000_000.0
let naturalMbps = Double(natural) * 8.0 / Double(seconds) / 1_000_000.0

print(String(format: "\nIdle bandwidth: %.2f Mb/s forced, %.3f Mb/s natural, %.0fx difference",
             forcedMbps, naturalMbps,
             natural > 0 ? Double(forced) / Double(natural) : 0))
print("Sending nothing at all while idle: 0 Mb/s, and no decode work on the iMac.")

// A nearly-still screen -- a blinking cursor, a clock -- keeps frames flowing,
// so the idle path never engages and the periodic IDR is paid in full.
print("\nNearly-still screen at 30 fps, \(seconds) seconds, by keyframe interval:\n")
let short = measure(label: "keyframe every 2s (the old default)",
                    forceKeyframeEveryFrame: false, frames: seconds * 30, fps: 30,
                    keyframeInterval: 2.0)
let long = measure(label: "keyframe every 10s",
                   forceKeyframeEveryFrame: false, frames: seconds * 30, fps: 30,
                   keyframeInterval: 10.0)
print(String(format: "\n%.2f Mb/s vs %.2f Mb/s -- %.0f%% less data, and that many fewer IDR decodes",
             Double(short) * 8.0 / Double(seconds) / 1_000_000.0,
             Double(long) * 8.0 / Double(seconds) / 1_000_000.0,
             short > 0 ? (1.0 - Double(long) / Double(short)) * 100.0 : 0))
