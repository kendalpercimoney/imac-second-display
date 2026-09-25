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
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware H.264 encoder tuned for "get this on the wire now", not for
/// squeezing the last few percent out of the bitrate.
///
/// The settings that actually decide latency, and one that turned out to be
/// the opposite of what its name suggests:
///   - AllowFrameReordering = false : no B-frames, so frame N never waits for N+1
///   - RealTime = **false**     : see `Configuration.realTime`
///   - MaxFrameDelayCount       : measured as doing nothing at all here
/// Everything else is quality/bandwidth tuning.
final class VideoEncoder {

    struct Configuration {
        var width: Int
        var height: Int
        var frameRate: Int
        var bitrate: Int
        var profileIsBaseline: Bool
        var keyframeInterval: Double
        /// Trade picture quality for encoder speed. Measured as no help to
        /// latency on Apple Silicon and a real cost to quality on detailed,
        /// fast-moving content, so it defaults off.
        var prioritizeSpeed: Bool = false
        /// Cap on burstiness, as a multiple of the average bitrate over one
        /// second. nil removes the cap. A cap that is too tight starves
        /// demanding content -- zooming a photograph, say -- and shows up as
        /// blotchy blocks.
        var dataRateLimitMultiplier: Double? = 4.0
        /// VideoToolbox's dedicated low-latency rate controller: one frame in,
        /// one frame out, no look-ahead. Has to be requested when the session
        /// is created, not set afterwards, and constrains which profiles and
        /// properties are available.
        ///
        /// The app no longer turns this on. It was on by default for most of
        /// this project's life and it was costing 5.4 ms of real latency.
        ///
        /// `Tests/EncoderLatency` says it is fast -- 9.4 ms of hold time
        /// against 14.5 -- and that is where the belief came from. The
        /// loopback harness, which times capture to decoded frame through the
        /// actual pipeline, says the opposite and says it without ambiguity.
        /// Four hundred frames, interleaved, three rounds, mean end to end:
        ///
        ///     420v, no low latency         8.04  8.07  8.04 ms
        ///     BGRA, no low latency         8.76  8.70  8.82 ms
        ///     420v + low latency          13.46 13.50 13.55 ms
        ///     BGRA + low latency          14.15 14.27 14.39 ms
        ///
        /// No overlap in any statistic, including the minimum, which has no
        /// noise in it: 5.1 ms against 11.2. Hold time measured on a batch fed
        /// as fast as it will go is simply not the same quantity as latency,
        /// and this is what it looks like when the two disagree.
        ///
        /// It also forces Constrained Baseline, undershoots the requested
        /// bitrate by about 1%, and costs 0.2 dB of mean PSNR. The one thing
        /// it genuinely wins is the single worst frame, 33.6 dB against 32.1.
        var lowLatencyRateControl: Bool = false
        /// Whether the encoder must keep up with the wall clock -- and the
        /// other 5 ms, in the direction nobody would guess from the name.
        ///
        /// True does not make the encoder hurry. It appears to make
        /// VideoToolbox *pace* delivery to the frame duration, and the
        /// signature is unmistakable: with it on, the median hold (17.9 ms) is
        /// higher than the mean (14.9 ms), which is what a queue being fed out
        /// on a clock looks like rather than one being emptied.
        ///
        /// End to end through the loopback harness, interleaved, three rounds,
        /// 4:2:0 in and no low-latency rate control either way:
        ///
        ///     real time off   7.96  8.13  8.13 ms   (min 5.21, p95 11.3-12.4)
        ///     real time on   13.00 13.43 13.41 ms   (min 10.31, p95 16.9-17.4)
        ///
        /// Picture is unaffected -- 40.24 dB either way at 25 Mb/s on a 1080p
        /// zoom, the same delivered bitrate, and the profile stays Baseline.
        ///
        /// This only shows up with the low-latency rate controller off. With
        /// it on, that rate controller is in charge and this makes no
        /// difference at all, which is why measuring the two together for so
        /// long hid both of them.
        ///
        /// The risk it buys, and it is a real one: an encoder that is not
        /// promising to keep up with the wall clock is allowed not to, under
        /// load. It kept up throughout, on a machine sitting at load average
        /// 5.8, delivering every frame at the full requested bitrate.
        var realTime: Bool = false
        /// How many frames the encoder may sit on before it has to produce
        /// output. 0 means "hold nothing"; the Apple Silicon encoder rejects
        /// that outright, so 1 is the practical floor.
        ///
        /// Measured as doing nothing whatsoever in either direction: 4 with
        /// `realTime: true` gives 14.98 ms of hold, exactly the 14.93 ms of 0,
        /// and 4 with it false gives 9.08 against 9.10. This encoder has no
        /// look-ahead to ask for. Kept parameterised because that is how it
        /// was established, and because it is the obvious thing to try again.
        var maxFrameDelayCount: Int = 0
        /// What to tell the encoder about the frame rate, when that differs
        /// from the rate we actually feed it. Claimed to affect how long the
        /// encoder is willing to hold a frame.
        var expectedFrameRateOverride: Int? = nil
    }

    private var session: VTCompressionSession?
    private let config: Configuration
    private let onEncodedFrame: (CMSampleBuffer) -> Void

    /// Non-fatal property failures are collected here rather than thrown; a
    /// hardware encoder that refuses one hint is still better than no stream.
    private(set) var warnings: [String] = []

    init(config: Configuration, onEncodedFrame: @escaping (CMSampleBuffer) -> Void) {
        self.config = config
        self.onEncodedFrame = onEncodedFrame
    }

    deinit { stop() }

    func start() throws {
        var encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        if config.lowLatencyRateControl, #available(macOS 11.0, *) {
            encoderSpec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created)

        guard status == noErr, let session = created else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey:
                    "VTCompressionSessionCreate failed (\(status)). " +
                    "Check that the resolution is even-sized and supported."
            ])
        }
        self.session = session

        set(session, kVTCompressionPropertyKey_RealTime, config.realTime)
        // Never, in either mode. B-frames arrive in decode order and the client
        // decodes synchronously and draws whatever comes out, so it has no way
        // to put them back into display order -- the picture would simply play
        // slightly wrong. Reordering is the one quality lever Video mode does
        // not get to pull.
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, false)
        // 0 means "hold nothing". The Apple Silicon encoder rejects it outright
        // (kVTPropertyNotSupportedErr), so fall back a step before giving up --
        // on encoders that do honour it, this is worth a whole frame.
        if !trySet(session, kVTCompressionPropertyKey_MaxFrameDelayCount,
                   config.maxFrameDelayCount), config.maxFrameDelayCount != 1 {
            _ = trySet(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 1)
        }
        if config.prioritizeSpeed, #available(macOS 14.0, *) {
            set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        }
        // The low-latency rate controller only accepts Constrained Baseline for
        // H.264, which is a subset of the Baseline the iMac already decodes.
        let profile: CFString
        if config.lowLatencyRateControl {
            profile = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        } else if config.profileIsBaseline {
            profile = kVTProfileLevel_H264_Baseline_AutoLevel
        } else {
            profile = kVTProfileLevel_H264_Main_AutoLevel
        }
        set(session, kVTCompressionPropertyKey_ProfileLevel, profile)
        if !config.profileIsBaseline {
            // CAVLC over CABAC: a few percent more bits, noticeably less work
            // for a 2010-era decoder.
            set(session, kVTCompressionPropertyKey_H264EntropyMode,
                kVTH264EntropyMode_CAVLC)
        }
        set(session, kVTCompressionPropertyKey_AverageBitRate, config.bitrate)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate,
            config.expectedFrameRateOverride ?? config.frameRate)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
            config.frameRate * Int(config.keyframeInterval.rounded()))
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            config.keyframeInterval)
        set(session, kVTCompressionPropertyKey_MaximizePowerEfficiency, false)

        // Cap on burstiness, so a keyframe cannot dump a megabyte into the NIC
        // in one go and overrun the client's receive buffer.
        if let multiplier = config.dataRateLimitMultiplier {
            let byteCap = NSNumber(value: Double(config.bitrate) / 8.0 * multiplier)
            set(session, kVTCompressionPropertyKey_DataRateLimits,
                [byteCap, NSNumber(value: 1.0)] as CFArray)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil)
    }

    /// Change bitrate without tearing down the session.
    func updateBitrate(_ bitsPerSecond: Int) {
        guard let session else { return }
        set(session, kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond)
        if let multiplier = config.dataRateLimitMultiplier {
            let byteCap = NSNumber(value: Double(bitsPerSecond) / 8.0 * multiplier)
            set(session, kVTCompressionPropertyKey_DataRateLimits,
                [byteCap, NSNumber(value: 1.0)] as CFArray)
        }
    }

    /// Sets a property without recording a warning; returns whether it stuck.
    private func trySet(_ session: VTCompressionSession, _ key: CFString, _ value: Any) -> Bool {
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef) == noErr
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: Any) {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            warnings.append("\(key) rejected (\(status))")
        }
    }

    fileprivate func deliver(_ sampleBuffer: CMSampleBuffer) {
        onEncodedFrame(sampleBuffer)
    }
}

private let encoderCallback: VTCompressionOutputCallback = {
    (refcon, _, status, _, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer),
          let refcon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.deliver(sampleBuffer)
}
