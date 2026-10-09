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
//  Measures how long VideoToolbox holds a frame: the gap between handing it a
//  pixel buffer and the encoded output arriving.
//
//  The README attributes most of the pipeline latency to encoder pipelining,
//  which was inferred from the fact that feeding frames faster made the
//  measured end-to-end number smaller. That is consistent with pipelining, but
//  it is also consistent with the encoder simply having more work queued. This
//  measures the encoder on its own, so the two can be told apart.
//
import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

/// Converts BGRA to biplanar 4:2:0 video range, the format ScreenCaptureKit can
/// hand out directly. Uses VTPixelTransferSession, which is the same machinery
/// VideoToolbox uses internally when it has to do this conversion itself --
/// so timing the encoder with 420v input measures what is saved by not making
/// it do the conversion.
func convertTo420v(_ source: CVPixelBuffer) -> CVPixelBuffer {
    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
    guard let transfer else { fatalError("no pixel transfer session") }
    var destination: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault,
                        CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                        &destination)
    guard let destination else { fatalError("no destination buffer") }
    VTPixelTransferSessionTransferImage(transfer, from: source, to: destination)
    return destination
}

let width = Int(ProcessInfo.processInfo.environment["EL_WIDTH"] ?? "1920") ?? 1920
let height = Int(ProcessInfo.processInfo.environment["EL_HEIGHT"] ?? "1080") ?? 1080
// 400, and not fewer. A shorter run does not merely add noise, it reverses the
// answer: over 150 frames every configuration here measures about 9.5 ms and
// the low-latency rate controller looks like it does nothing at all. Over 400
// the same binary reports 14.6 ms without it against 9.4 ms with, every round.
// Whatever the non-low-latency encoder is doing, it takes a few seconds of
// steady feeding to start doing it, and a short run stops before it has.
let frames = Int(ProcessInfo.processInfo.environment["EL_FRAMES"] ?? "400") ?? 400

/// Moving content, so the encoder has real work to do rather than emitting
/// near-empty inter frames that would flatter the timings.
func makeFrames(_ count: Int) -> [CVPixelBuffer] {
    (0..<count).map { index in
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                            &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let shift = index * 11
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let p = row + x * 4
                let v = UInt8(truncatingIfNeeded: (x &+ shift) ^ (y &+ shift / 2))
                p[0] = v; p[1] = UInt8(truncatingIfNeeded: x &+ shift)
                p[2] = UInt8(truncatingIfNeeded: y &- shift); p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}

print("Generating source frames at \(width)x\(height)…")
let sources = makeFrames(60)
let sources420v = sources.map(convertTo420v)

func trial(_ label: String, feedFPS: Int, lowLatency: Bool,
           expectedFrameRateOverride: Int?, keyframeInterval: Double = 5.0,
           use420v: Bool = false,
           realTime: Bool = false, maxFrameDelayCount: Int = 0) {
    let feed = use420v ? sources420v : sources
    let lock = NSLock()
    var submitted: [Int: UInt64] = [:]
    var latencies: [Double] = []
    var keyframes = 0
    var bytes = 0
    let done = DispatchSemaphore(value: 0)
    var seen = 0

    let encoder = VideoEncoder(config: .init(
        width: width, height: height, frameRate: feedFPS, bitrate: 25_000_000,
        profileIsBaseline: true, keyframeInterval: keyframeInterval,
        prioritizeSpeed: false, dataRateLimitMultiplier: 4.0,
        lowLatencyRateControl: lowLatency,
        realTime: realTime,
        maxFrameDelayCount: maxFrameDelayCount,
        expectedFrameRateOverride: expectedFrameRateOverride)) { sampleBuffer in

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let index = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value)
        lock.lock()
        if let start = submitted[index] {
            latencies.append(Double(now - start) / 1_000_000.0)
            submitted[index] = nil
        }
        lock.unlock()
        if RTPPacketizerIsKeyframe(sampleBuffer) { keyframes += 1 }
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            bytes += CMBlockBufferGetDataLength(block)
        }
        seen += 1
        if seen >= frames { done.signal() }
    }

    do { try encoder.start() } catch {
        print(String(format: "  %-52@  unavailable: \(error.localizedDescription)",
                     label as NSString))
        return
    }

    let interval = 1_000_000 / UInt32(feedFPS)
    for index in 0..<frames {
        lock.lock(); submitted[index] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); lock.unlock()
        encoder.encode(pixelBuffer: feed[index % feed.count],
                       presentationTime: CMTime(value: Int64(index), timescale: CMTimeScale(feedFPS)),
                       forceKeyframe: index == 0)
        usleep(interval)
    }
    _ = done.wait(timeout: .now() + 30)
    encoder.stop()

    let steady = Array(latencies.dropFirst(10)).sorted()
    guard !steady.isEmpty else { print("  \(label): no output"); return }
    let mean = steady.reduce(0, +) / Double(steady.count)
    print(String(format: "  %-52@ hold %5.2f ms (median %5.2f, p95 %5.2f)  %2d keyframes  %4.1f Mb/s",
                 label as NSString, mean, steady[steady.count / 2],
                 steady[Int(Double(steady.count) * 0.95)], keyframes,
                 Double(bytes) * 8.0 / (Double(frames) / Double(feedFPS)) / 1_000_000.0))
}

/// Same test the packetizer uses, lifted so this tool does not need the socket.
func RTPPacketizerIsKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
          let first = attachments.first else { return true }
    if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
    return true
}

if ProcessInfo.processInfo.environment["EL_KEYFRAMES"] != nil {
    // Does low-latency mode still honour the periodic keyframe? If it does not,
    // the 5-second safety keyframe silently stops happening, and a client that
    // loses its place has only the on-demand request to fall back on.
    print("\nKeyframes over \(frames) frames at 60 fps with a 2-second interval")
    print("(expect roughly one per 120 frames if the interval is honoured)\n")
    trial("as shipped (not real time)", feedFPS: 60, lowLatency: false,
          expectedFrameRateOverride: nil, keyframeInterval: 2.0, realTime: false)
    trial("real time", feedFPS: 60, lowLatency: false,
          expectedFrameRateOverride: nil, keyframeInterval: 2.0, realTime: true)
    trial("low-latency rate control", feedFPS: 60, lowLatency: true,
          expectedFrameRateOverride: nil, keyframeInterval: 2.0, realTime: true)
} else {
    print("\nHow long VideoToolbox holds a frame, \(width)x\(height), \(frames) frames\n")
    for round in 1...3 {
        print("round \(round)")
        // Every row names both properties, because "as shipped" moved once
        // already and a table whose baseline drifts is worse than no table.
        trial("  real time, holds nothing", feedFPS: 60, lowLatency: false,
              expectedFrameRateOverride: nil, realTime: true)
        trial("  real time, ExpectedFrameRate 120", feedFPS: 60, lowLatency: false,
              expectedFrameRateOverride: 120, realTime: true)
        trial("  real time, 420v input", feedFPS: 60, lowLatency: false,
              expectedFrameRateOverride: nil, use420v: true, realTime: true)
        trial("  real time, holds 4", feedFPS: 60, lowLatency: false,
              expectedFrameRateOverride: nil, realTime: true, maxFrameDelayCount: 4)
        trial("  low-latency rate control", feedFPS: 60, lowLatency: true,
              expectedFrameRateOverride: nil, realTime: true)
        trial("  low-latency + 420v", feedFPS: 60, lowLatency: true,
              expectedFrameRateOverride: nil, use420v: true, realTime: true)
        trial("  AS SHIPPED: not real time, holds nothing", feedFPS: 60,
              lowLatency: false, expectedFrameRateOverride: nil, realTime: false)
        trial("  not real time, holds 4", feedFPS: 60, lowLatency: false,
              expectedFrameRateOverride: nil, realTime: false, maxFrameDelayCount: 4)
    }
}
