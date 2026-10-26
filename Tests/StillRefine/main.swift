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

// Sharpening a picture once it is still: when it happens, and whether it works.
//
// The first half checks the rules on their own. The second encodes for real
// through VideoEncoder and `Configuration.forStill(matching:)` -- the same
// path the host takes -- and scores the picture before and after the refresh,
// and checks the refresh keyframe carries the stream's own parameter sets, so
// the client keeps its decoder rather than rebuilding it.

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

// MARK: - the rules

print("\n==> when a refresh is due")
do {
    var r = StillRefinement()
    _ = r.frameCaptured(at: 0)
    for _ in 0..<60 { r.motionFrameEncoded(bytes: 3_000, isKeyframe: false) }   // typing
    check("typing does not earn a refresh", !r.shouldRefresh(now: 5))

    var z = StillRefinement()
    for i in 0..<20 {
        _ = z.frameCaptured(at: Double(i) / 60)
        z.motionFrameEncoded(bytes: 120_000, isKeyframe: false)                  // zooming
    }
    let stopped = 19.0 / 60
    check("a zoom earns one, but not while it is still moving",
          !z.shouldRefresh(now: stopped + 0.1))
    check("...and it is due once the screen has been still long enough",
          z.shouldRefresh(now: stopped + 0.35))
    z.refreshSent()
    check("...once only", !z.shouldRefresh(now: stopped + 2))
    check("the first frame after it has to be a keyframe", z.frameCaptured(at: 3))
    check("...and only the first", !z.frameCaptured(at: 3.02))

    z.motionFrameEncoded(bytes: 600_000, isKeyframe: true)                       // that keyframe
    check("the keyframe a refresh obliges does not earn the next refresh",
          !z.shouldRefresh(now: 10))

    var k = StillRefinement()
    _ = k.frameCaptured(at: 0)
    k.motionFrameEncoded(bytes: 900_000, isKeyframe: true)                       // a keyframe request
    check("keyframes on their own do not earn one", !k.shouldRefresh(now: 5))

    var off = StillRefinement()
    off.enabled = false
    _ = off.frameCaptured(at: 0)
    off.motionFrameEncoded(bytes: 5_000_000, isKeyframe: false)
    check("switched off, it never happens", !off.shouldRefresh(now: 5))
}

// MARK: - doing it for real

let width = 1920, height = 1080
let zoomFrames = 60

/// A photograph-like picture -- gradients, hard edges, fine grain -- being
/// zoomed into, which is about the hardest thing to encode well while moving.
func makeFrames() -> [CVPixelBuffer] {
    var image = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func grain() -> Double {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Double(seed >> 56) / 255 * 24 - 12
    }
    for y in 0..<height {
        for x in 0..<width {
            let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
            var r = 40 + 180 * fx, g = 60 + 150 * fy, b = 200 - 120 * fx * fy
            if (x / 48 + y / 48) % 2 == 0 { r += 30; g -= 20 }
            let dx = Double(x - width / 2), dy = Double(y - height / 2)
            if (dx * dx + dy * dy).squareRoot() < 260 { r = 230; g = 90; b = 50 }
            let n = grain(), i = (y * width + x) * 4
            image[i] = UInt8(max(0, min(255, b + n)))
            image[i + 1] = UInt8(max(0, min(255, g + n)))
            image[i + 2] = UInt8(max(0, min(255, r + n)))
            image[i + 3] = 255
        }
    }
    return (0..<zoomFrames).map { index in
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let out = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let zoom = 1.0 + 0.012 * Double(index)
        for y in 0..<height {
            let sy = min(height - 1, Int(Double(height) / 2 + (Double(y) - Double(height) / 2) / zoom))
            for x in 0..<width {
                let sx = min(width - 1, Int(Double(width) / 2 + (Double(x) - Double(width) / 2) / zoom))
                let s = (sy * width + sx) * 4, d = y * stride + x * 4
                out[d] = image[s]; out[d + 1] = image[s + 1]; out[d + 2] = image[s + 2]; out[d + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}

func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var sum = 0.0, n = 0
    for y in stride(from: 0, to: height, by: 2) {
        for x in stride(from: 0, to: width, by: 2) {
            for c in 0..<3 {
                let d = Double(pa[y * sa + x * 4 + c]) - Double(pb[y * sb + x * 4 + c])
                sum += d * d; n += 1
            }
        }
    }
    return 10 * log10(255 * 255 / (sum / Double(n)))
}

/// Decodes whatever it is given and remembers the last picture and the
/// parameter sets it came with.
final class Receiver {
    var session: VTDecompressionSession?
    var lastPicture: CVPixelBuffer?
    var lastBytes = 0
    var parameterSets: [Data] = []
    func feed(_ sampleBuffer: CMSampleBuffer) {
        let format = CMSampleBufferGetFormatDescription(sampleBuffer)!
        var sets: [Data] = []
        for i in 0..<2 {
            var p: UnsafePointer<UInt8>?; var n = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let p { sets.append(Data(bytes: p, count: n)) }
        }
        parameterSets = sets
        if session == nil {
            VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session)
        }
        lastBytes = CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sampleBuffer)!)
        VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sampleBuffer, flags: [],
                                          infoFlagsOut: nil) { _, _, image, _, _ in
            if let image { self.lastPicture = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
    }
}

print("\nGenerating \(zoomFrames) frames of a \(width)x\(height) zoom…")
let frames = makeFrames()
let still = frames[zoomFrames - 1]

// The last case is Video mode above High's Level 4.2 ceiling: the stream is at
// Level 5.0, and a still encoder left to pick its own level would choose 4.2 --
// different parameter sets, and the client rebuilding its decoder for the
// refresh and again straight after. At the lower bitrates the two happen to
// agree anyway, which is why that case alone shows the matching is needed.
for (name, profile, mbps) in [("Baseline", VideoEncoder.Profile.baseline, 25),
                              ("High", VideoEncoder.Profile.high, 25),
                              ("High", VideoEncoder.Profile.high, 49),
                              ("High, Video mode", VideoEncoder.Profile.high, 80)] {
    print("\n==> \(name), \(mbps) Mb/s: zoom, stop, refresh")
    let receiver = Receiver()
    let motion = VideoEncoder(config: .init(width: width, height: height, frameRate: 60,
                                            bitrate: mbps * 1_000_000, profile: profile,
                                            keyframeInterval: 5.0)) { receiver.feed($0) }
    try! motion.start()
    for (i, frame) in frames.enumerated() {
        motion.encode(pixelBuffer: frame, presentationTime: CMTime(value: Int64(i), timescale: 60),
                      forceKeyframe: i == 0)
        motion.completeFrames()
    }
    let stopped = psnr(still, receiver.lastPicture!)
    let streamSets = receiver.parameterSets
    let level = motion.streamLevel

    let stillEncoder = VideoEncoder(config: motion.config.forStill(matching: level)) { receiver.feed($0) }
    try! stillEncoder.start()
    stillEncoder.encode(pixelBuffer: still, presentationTime: CMTime(value: Int64(zoomFrames), timescale: 60),
                        forceKeyframe: true)
    stillEncoder.completeFrames()
    let refreshed = psnr(still, receiver.lastPicture!)
    let size = receiver.lastBytes

    print(String(format: "  stopped at %.2f dB, refreshed to %.2f dB with a %d KB keyframe (level %.1f)",
                 stopped, refreshed, size / 1024, Double(level?.levelIDC ?? 0) / 10))
    check("the refresh is a big step up", refreshed - stopped > 3,
          String(format: "+%.2f dB", refreshed - stopped))
    check("past the point anyone can see a difference", refreshed >= 49.5,
          String(format: "%.2f dB", refreshed))
    check("it carries the stream's own parameter sets, so the decoder carries on",
          receiver.parameterSets == streamSets && !streamSets.isEmpty)
    check("it fits the client's receive buffer with room to spare", size < 2_000_000, "\(size) bytes")
    stillEncoder.stop()
    motion.stop()
}

print()
print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
