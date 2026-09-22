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
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

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
        // Measured as a wash on M1 Pro, but it is a documented low-latency hint
        // and costs nothing, so leave it in for other silicon.
        if #available(macOS 14.0, *) {
            set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        }
        set(session, kVTCompressionPropertyKey_ProfileLevel,
            config.profileIsBaseline ? kVTProfileLevel_H264_Baseline_AutoLevel
                                     : kVTProfileLevel_H264_Main_AutoLevel)
        if !config.profileIsBaseline {
            // CAVLC over CABAC: a few percent more bits, noticeably less work
            // for a 2010-era decoder.
            set(session, kVTCompressionPropertyKey_H264EntropyMode,
                kVTH264EntropyMode_CAVLC)
        }
        set(session, kVTCompressionPropertyKey_AverageBitRate, config.bitrate)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, config.frameRate)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
            config.frameRate * Int(config.keyframeInterval.rounded()))
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            config.keyframeInterval)
        set(session, kVTCompressionPropertyKey_MaximizePowerEfficiency, false)

        // Hard cap on burstiness. Without this a keyframe can dump a megabyte
        // into the NIC in one go and overrun the client's receive buffer.
        // Allow 2x the average bitrate over any 1-second window.
        let byteCap = NSNumber(value: config.bitrate / 8 * 2)
        set(session, kVTCompressionPropertyKey_DataRateLimits,
            [byteCap, NSNumber(value: 1.0)] as CFArray)

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
        let byteCap = NSNumber(value: bitsPerSecond / 8 * 2)
        set(session, kVTCompressionPropertyKey_DataRateLimits,
            [byteCap, NSNumber(value: 1.0)] as CFArray)
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
