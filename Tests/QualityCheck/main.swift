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
//  Measures picture quality on hard content, by encoding a zoom and decoding it
//  back in process.
//
//  Zooming into a photograph is close to the worst case for a real-time
//  encoder: every pixel moves, inter prediction is poor, and the detail is
//  high-frequency. It is where rate-control settings that look harmless on a
//  desktop show up as blotches.
//
//  Reports PSNR against the source. Roughly: above 40 dB is visually clean,
//  35-40 dB is good, 30-35 dB is visibly soft, below 30 dB is blocky.
//
import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

let width = Int(ProcessInfo.processInfo.environment["QC_WIDTH"] ?? "1280") ?? 1280
let height = Int(ProcessInfo.processInfo.environment["QC_HEIGHT"] ?? "720") ?? 720
// 400 by default, for the same reason EncoderLatency uses 400: a short run
// stops before the encoder reaches steady state, and the answer it gives
// before then is not a noisier version of the real one, it is a different one.
let frameCount = Int(ProcessInfo.processInfo.environment["QC_FRAMES"] ?? "400") ?? 400
let fps = Int(ProcessInfo.processInfo.environment["QC_FPS"] ?? "60") ?? 60

// ------------------------------------------------------------ source frames --

/// A detailed, photograph-like image: broad gradients for the eye to notice
/// banding in, hard edges, and fine high-frequency texture.
func sourceImage() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt64 = 0x2545F4914F6CDD1D
    func noise() -> UInt8 {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return UInt8(truncatingIfNeeded: seed >> 33)
    }
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
            var r = 40.0 + 180.0 * fx
            var g = 60.0 + 150.0 * fy
            var b = 200.0 - 120.0 * (fx * fy)
            // Hard-edged shapes.
            if (x / 64 + y / 64) % 2 == 0 { r += 30; g -= 20 }
            let dx = Double(x - width / 2), dy = Double(y - height / 2)
            if (dx * dx + dy * dy).squareRoot() < 180 { r = 230; g = 90; b = 50 }
            // Fine texture, which is what falls apart first.
            let n = Double(noise()) / 255.0 * 26.0 - 13.0
            pixels[i + 0] = UInt8(max(0, min(255, b + n)))
            pixels[i + 1] = UInt8(max(0, min(255, g + n)))
            pixels[i + 2] = UInt8(max(0, min(255, r + n)))
            pixels[i + 3] = 255
        }
    }
    return pixels
}

let image = sourceImage()

/// Frame `index` of a slow zoom into the centre, sampled bilinearly so the
/// motion is smooth and sub-pixel rather than a series of jumps.
func zoomFrame(_ index: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                        &buffer)
    guard let pixelBuffer = buffer else { fatalError("CVPixelBufferCreate failed") }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let out = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)

    // A fixed rate per frame, reversing at the ends, rather than a zoom
    // stretched across however many frames the run happens to have. Otherwise
    // a longer run is a slower zoom, which is easier content, and the frame
    // count quietly becomes a difficulty setting -- so two runs of different
    // lengths could not be compared with each other at all.
    let span = 90.0
    let phase = Double(index).truncatingRemainder(dividingBy: 2 * span)
    let zoom = 1.0 + 1.6 * (phase <= span ? phase : 2 * span - phase) / span
    let cropW = Double(width) / zoom, cropH = Double(height) / zoom
    let originX = (Double(width) - cropW) / 2, originY = (Double(height) - cropH) / 2

    for y in 0..<height {
        let sy = originY + cropH * Double(y) / Double(height)
        let y0 = min(height - 2, max(0, Int(sy))), fy = sy - Double(y0)
        for x in 0..<width {
            let sx = originX + cropW * Double(x) / Double(width)
            let x0 = min(width - 2, max(0, Int(sx))), fx = sx - Double(x0)
            let p = out + y * stride + x * 4
            for c in 0..<3 {
                let i00 = ((y0) * width + x0) * 4 + c, i01 = ((y0) * width + x0 + 1) * 4 + c
                let i10 = ((y0 + 1) * width + x0) * 4 + c, i11 = ((y0 + 1) * width + x0 + 1) * 4 + c
                let top = Double(image[i00]) * (1 - fx) + Double(image[i01]) * fx
                let bot = Double(image[i10]) * (1 - fx) + Double(image[i11]) * fx
                p[c] = UInt8(max(0, min(255, top * (1 - fy) + bot * fy)))
            }
            p[3] = 255
        }
    }
    return pixelBuffer
}

print("Generating \(frameCount) frames of a \(width)x\(height) zoom…")
let sourceFrames = (0..<frameCount).map { zoomFrame($0) }

// ------------------------------------------------------------------- PSNR ----

func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    guard let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
          let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self)
    else { return 0 }
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var sum = 0.0, count = 0
    for y in stride(from: 0, to: height, by: 2) {
        for x in stride(from: 0, to: width, by: 2) {
            for c in 0..<3 {
                let d = Double(pa[y * sa + x * 4 + c]) - Double(pb[y * sb + x * 4 + c])
                sum += d * d; count += 1
            }
        }
    }
    if count == 0 || sum == 0 { return 99 }
    return 10 * log10(255.0 * 255.0 / (sum / Double(count)))
}

// ------------------------------------------------------------- the run -------

final class Run {
    var decoded: [Int: CVPixelBuffer] = [:]
    var bytes = 0
    var session: VTDecompressionSession?
    let lock = NSLock()
}

func trial(_ label: String, bitrate: Int, keyframeInterval: Double,
           prioritizeSpeed: Bool, dataRateLimitMultiplier: Double?,
           lowLatency: Bool = false,
           realTime: Bool = true, maxFrameDelayCount: Int = 0) {
    let run = Run()
    let done = DispatchSemaphore(value: 0)
    var seen = 0

    let encoder = VideoEncoder(config: .init(
        width: width, height: height, frameRate: fps, bitrate: bitrate,
        profileIsBaseline: true, keyframeInterval: keyframeInterval,
        prioritizeSpeed: prioritizeSpeed,
        dataRateLimitMultiplier: dataRateLimitMultiplier,
        lowLatencyRateControl: lowLatency,
        realTime: realTime,
        maxFrameDelayCount: maxFrameDelayCount)) { sampleBuffer in

        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            run.bytes += CMBlockBufferGetDataLength(block)
        }
        // Decode in process: this measures the encoder, not the network.
        if run.session == nil, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var created: VTDecompressionSession?
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                formatDescription: fmt, decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &created)
            run.session = created
        }
        if let session = run.session {
            let index = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value)
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
                                              flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
                if let image { run.lock.lock(); run.decoded[index] = image; run.lock.unlock() }
            }
        }
        seen += 1
        if seen >= frameCount { done.signal() }
    }
    try! encoder.start()

    for index in 0..<frameCount {
        encoder.encode(pixelBuffer: sourceFrames[index],
                       presentationTime: CMTime(value: Int64(index), timescale: CMTimeScale(fps)),
                       forceKeyframe: index == 0)
        usleep(3000)
    }
    _ = done.wait(timeout: .now() + 30)
    if let session = run.session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    encoder.stop()

    // Skip the first few: the rate controller is still settling.
    var scores: [Double] = []
    for index in 10..<frameCount {
        if let out = run.decoded[index] { scores.append(psnr(sourceFrames[index], out)) }
    }
    scores.sort()
    let mean = scores.reduce(0, +) / Double(max(scores.count, 1))
    let mbps = Double(run.bytes) * 8.0 / (Double(frameCount) / Double(fps)) / 1_000_000.0
    print(String(format: "  %-44@  PSNR mean %5.2f dB  worst %5.2f dB   %5.1f Mb/s",
                 label as NSString, mean, scores.first ?? 0, mbps))
}

print("\nZooming into a detailed image at \(width)x\(height)/\(fps)\n")
trial("desktop tuning, 25 Mb/s", bitrate: 25_000_000, keyframeInterval: 5.0,
      prioritizeSpeed: false, dataRateLimitMultiplier: 4.0)
trial("low-latency rate control (Constrained Baseline)", bitrate: 25_000_000,
      keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 4.0,
      lowLatency: true)

// What the Video mode switch is worth, and how much of it is simply the
// bitrate. If the last two lines come out the same, the encoder tuning is
// doing nothing and the switch should just move the bitrate slider.
// Which of the three encoder tunings is actually best, at the same bitrate.
// The look-ahead row is the interesting one: EncoderLatency reports it as the
// fastest of the three, which is not what asking an encoder to look ahead is
// supposed to do, so what it costs in picture is the thing to know.
print("\nThe three tunings at the same bitrate\n")
for rate in [12_000_000, 25_000_000] {
    let mb = rate / 1_000_000
    trial("\(mb) Mb/s, real time, holds nothing", bitrate: rate,
          keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 4.0)
    trial("\(mb) Mb/s, low-latency rate control", bitrate: rate,
          keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 4.0,
          lowLatency: true)
    trial("\(mb) Mb/s, not real time, holds 4", bitrate: rate,
          keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 4.0,
          realTime: false, maxFrameDelayCount: 4)
}

print("\nVideo mode, taken apart\n")
trial("desktop tuning at the video bitrate", bitrate: 60_000_000,
      keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 4.0)
trial("video mode (60 Mb/s, 8x burst, look-ahead)", bitrate: 60_000_000,
      keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 8.0,
      realTime: false, maxFrameDelayCount: 4)

// The pair above is quality-saturated -- 60 Mb/s at this size is more than the
// picture needs, so nothing the rate controller does can show up. Repeat the
// comparison where the encoder actually has to choose what to spend bits on,
// which is the only place look-ahead and a loose burst cap could earn anything.
print("\nWhether the burst cap costs anything on a keyframe\n")
// The runs above score a continuous zoom with a single keyframe they skip, so
// the cap is never exercised. Here one lands every second and the worst frame
// is the one right after it.
for multiplier in [2.0, 4.0, 8.0, 16.0] {
    trial("burst cap \(Int(multiplier))x, keyframe every second", bitrate: 12_000_000,
          keyframeInterval: 1.0, prioritizeSpeed: false,
          dataRateLimitMultiplier: multiplier)
}

print("\nThe same tuning where the bitrate is tight\n")
for rate in [6_000_000, 12_000_000] {
    trial("\(rate / 1_000_000) Mb/s, desktop tuning", bitrate: rate,
          keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 4.0)
    trial("\(rate / 1_000_000) Mb/s, video tuning", bitrate: rate,
          keyframeInterval: 5.0, prioritizeSpeed: false, dataRateLimitMultiplier: 8.0,
          realTime: false, maxFrameDelayCount: 4)
}
