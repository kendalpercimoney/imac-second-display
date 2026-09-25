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
//  Does Video mode actually change the bitrate?
//
//  The first version of it set kVTCompressionPropertyKey_AverageBitRate on the
//  running session, which is the obvious thing to do and does not work. The
//  call returns noErr and the encoder carries on at the old rate -- asked to go
//  from 25 to 60 Mb/s on content that wanted every bit of it, it delivered
//  24.6, 24.8, 24.6, 30.1, 23.9. That shipped, and the report was "video mode
//  doesn't change the stats", which is exactly what it was.
//
//  So this measures both ways of doing it and requires that the one the app
//  uses works and that the one it used to use does not. If a future macOS makes
//  the live property work, the second half fails and this comment is the
//  explanation for why it may then be simplified.
//
import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

let width = 1920, height = 1080, fps = 60
var source = [UInt8](repeating: 0, count: width * height * 4)
var seed: UInt64 = 0x9E3779B97F4A7C15
func noise() -> UInt8 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return UInt8(truncatingIfNeeded: seed >> 33) }
// Photograph-like, not noise: broad gradients, hard-edged shapes, and light
// grain. Pure noise is incompressible, so every rate-control setting produces
// the same 130 Mb/s and the test says nothing -- which is exactly the trap the
// first version of this fell into.
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
        var r = 40.0 + 180.0 * fx, g = 60.0 + 150.0 * fy, b = 200.0 - 120.0 * (fx * fy)
        if (x / 64 + y / 64) % 2 == 0 { r += 30; g -= 20 }
        let dx = Double(x - width / 2), dy = Double(y - height / 2)
        if (dx * dx + dy * dy).squareRoot() < 300 { r = 230; g = 90; b = 50 }
        let grain = Double(noise()) / 255.0 * 18.0 - 9.0
        source[i]   = UInt8(max(0, min(255, b + grain)))
        source[i+1] = UInt8(max(0, min(255, g + grain)))
        source[i+2] = UInt8(max(0, min(255, r + grain)))
        source[i+3] = 255
    }
}
func frame(_ shift: Int) -> CVPixelBuffer {
    var b: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &b)
    let pb = b!
    CVPixelBufferLockBaseAddress(pb, [])
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let out = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        let sy = (y + shift) % height
        source.withUnsafeBufferPointer { s in memcpy(out + y * stride, s.baseAddress! + sy * width * 4, width * 4) }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}
let frames = (0..<30).map { frame($0 * 37) }

let lock = NSLock()
var bytesPerSecond: [Int: Int] = [:]
var started = CFAbsoluteTimeGetCurrent()

func makeSession(_ bitrate: Int) -> VTCompressionSession {
var session: VTCompressionSession?
VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
    codecType: kCMVideoCodecType_H264,
    encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
    imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: { _, _, status, _, sb in
        guard status == noErr, let sb, let blk = CMSampleBufferGetDataBuffer(sb) else { return }
        lock.lock()
        bytesPerSecond[Int(CFAbsoluteTimeGetCurrent() - started), default: 0] += CMBlockBufferGetDataLength(blk)
        lock.unlock()
    }, refcon: nil, compressionSessionOut: &session)
let made = session!
func setOn(_ sess: VTCompressionSession, _ k: CFString, _ v: Any) -> OSStatus {
    VTSessionSetProperty(sess, key: k, value: v as CFTypeRef)
}
_ = setOn(made, kVTCompressionPropertyKey_RealTime, false)
_ = setOn(made, kVTCompressionPropertyKey_AllowFrameReordering, false)
_ = setOn(made, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
_ = setOn(made, kVTCompressionPropertyKey_ExpectedFrameRate, fps)
_ = setOn(made, kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 5)
_ = setOn(made, kVTCompressionPropertyKey_AverageBitRate, bitrate)
_ = setOn(made, kVTCompressionPropertyKey_DataRateLimits,
          [NSNumber(value: Double(bitrate) / 8.0 * 4.0), NSNumber(value: 1.0)] as CFArray)
VTCompressionSessionPrepareToEncodeFrames(made)
return made
}

var s = makeSession(25_000_000)

func run(recreate: Bool) -> (before: Double, after: Double) {
    bytesPerSecond.removeAll()
    started = CFAbsoluteTimeGetCurrent()
    s = makeSession(25_000_000)
    var next = CFAbsoluteTimeGetCurrent()
    for i in 0..<(12 * fps) {
        next += 1.0 / Double(fps)
        let now = CFAbsoluteTimeGetCurrent()
        if next > now { usleep(useconds_t((next - now) * 1_000_000)) }
        if i == 6 * fps {
            if recreate {
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(s)
                s = makeSession(60_000_000)
            } else {
                _ = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                                         value: 60_000_000 as CFTypeRef)
                _ = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                    value: [NSNumber(value: 60_000_000.0 / 8 * 4), NSNumber(value: 1.0)] as CFArray)
            }
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: frames[i % frames.count],
            presentationTimeStamp: CMTime(value: Int64(i), timescale: CMTimeScale(fps)),
            duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(s)

    // Seconds 2-5 are the settled "before"; 8-11 the settled "after". The
    // second either side of the switch is skipped, and so is the last, which
    // only holds the flush.
    func mean(_ range: ClosedRange<Int>) -> Double {
        let v = range.compactMap { bytesPerSecond[$0] }.map { Double($0) * 8 / 1_000_000 }
        return v.isEmpty ? 0 : v.reduce(0,+) / Double(v.count)
    }
    return (mean(2...5), mean(8...11))
}

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

print("\n1080p60 photograph-like content, 25 Mb/s for 6 s then asked for 60\n")

let live = run(recreate: false)
print(String(format: "  setting the property on the live session:  %.1f -> %.1f Mb/s",
             live.before, live.after))
let fresh = run(recreate: true)
print(String(format: "  replacing the session:                     %.1f -> %.1f Mb/s\n",
             fresh.before, fresh.after))

check("both start at the bitrate they were built with",
      live.before > 18 && live.before < 32 && fresh.before > 18 && fresh.before < 32,
      String(format: "%.1f and %.1f", live.before, fresh.before))
check("replacing the session really raises the bitrate", fresh.after > 45,
      String(format: "%.1f Mb/s", fresh.after))
check("...by a lot more than the live property does",
      fresh.after > live.after * 1.5,
      String(format: "%.1f vs %.1f", fresh.after, live.after))
check("the live property still does nothing, which is why the app stopped using it",
      live.after < 35,
      String(format: "%.1f Mb/s — if this fails, VideoToolbox changed and applyEncoderModeNow could be simplified", live.after))

print()
print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
