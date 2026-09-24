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
/// The three settings that actually decide latency:
///   - RealTime = true          : encoder must keep up with wall clock
///   - AllowFrameReordering = false : no B-frames, so frame N never waits for N+1
///   - MaxFrameDelayCount = 0   : encoder may not sit on frames to look ahead
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
        var lowLatencyRateControl: Bool = false
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

        set(session, kVTCompressionPropertyKey_RealTime, true)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, false)
        // 0 means "hold nothing". The Apple Silicon encoder rejects it outright
        // (kVTPropertyNotSupportedErr), so try 1 as well before giving up --
        // on encoders that do honour it, this is worth a whole frame.
        if !trySet(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 0) {
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
