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
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AudioToolbox
import LSProtocol

struct DisplayInfo: Identifiable, Hashable {
    let id: UInt32
    let width: Int
    let height: Int
    var label: String { "Display \(id) — \(width)×\(height)" }
}

/// ScreenCaptureKit wrapper. Hands out BGRA pixel buffers already scaled to the
/// streaming resolution, so the GPU does the resize and VideoToolbox never sees
/// a frame bigger than it needs to encode.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.lanscreen.capture", qos: .userInteractive)
    /// Audio gets its own queue so a slow frame never delays a buffer of sound.
    /// Ears notice a gap of a few milliseconds; eyes do not notice a frame.
    private let audioQueue = DispatchQueue(label: "com.lanscreen.capture.audio",
                                           qos: .userInteractive)
    /// Reused across callbacks so a buffer of audio costs no allocation.
    private var interleaveBuffer = [Int16]()

    /// Called on outputQueue for every complete frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called on audioQueue with interleaved 16-bit samples, when audio capture
    /// is on. Nil-ing this out does not stop capture; pass capturesAudio: false.
    var onAudio: ((UnsafePointer<Int16>, Int, Int) -> Void)?
    /// Called if the stream dies on its own (display disconnected, permission
    /// revoked, and so on).
    var onStreamStopped: ((Error) -> Void)?

    static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        return content.displays.map {
            DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height)
        }
    }

    func start(displayID: UInt32, width: Int, height: Int,
               frameRate: Int, showsCursor: Bool, useYUV420: Bool = true,
               capturesAudio: Bool = false) async throws {
        // Retried, because the answer right after this Mac wakes is wrong
        // rather than final. The window server has not finished republishing
        // displays, so SCShareableContent returns an empty list -- or throws --
        // for a second or two, and asking once turned every wake into
        // "No capturable display found" when there was nothing wrong with the
        // display and waiting would have found it.
        var display: SCDisplay?
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                if let found = content.displays.first(where: { $0.displayID == displayID })
                            ?? content.displays.first {
                    display = found
                    break
                }
            } catch {
                lastError = error
            }
            if attempt < 9 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        guard let display else {
            throw NSError(domain: "LanScreen", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No capturable display found after five seconds."
                    + (lastError.map { " (\($0.localizedDescription))" } ?? "")
                    + " If this Mac has just woken, try Start again; if it keeps"
                    + " happening, check Screen Recording in System Settings."
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // 4:2:0 video range rather than BGRA. The encoder wants YUV either way,
        // so handing it BGRA just means VideoToolbox converts every frame
        // first. On its own that changes nothing measurable, but combined with
        // the low-latency rate controller it takes the encoder's hold time from
        // about 16 ms to about 9 ms, and the p95 from the mid-twenties to the
        // low teens.
        config.pixelFormat = useYUV420 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                       : kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        // System audio, straight from ScreenCaptureKit. No virtual audio device
        // to install, and no extra permission beyond the screen recording grant
        // the app already needs.
        config.capturesAudio = capturesAudio
        if capturesAudio {
            config.sampleRate = Int(LS_AUDIO_SAMPLE_RATE)
            config.channelCount = Int(LS_AUDIO_CHANNELS)
            config.excludesCurrentProcessAudio = true
        }
        // The frame interval is an upper bound on rate, not a promise: SCK only
        // delivers when something actually changed on screen. A static desktop
        // costs zero bandwidth, which is why StreamController keeps its own
        // heartbeat for idle periods.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // Shallow, because we would rather drop an old frame than show a late
        // one -- but not as shallow as it was: StreamController now retains the
        // most recent frame for the whole session so it can answer a keyframe
        // request on a still screen, and that holds one buffer out of the pool.
        config.queueDepth = 5
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: outputQueue)
        if capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        if type == .audio {
            handleAudio(sampleBuffer)
            return
        }
        guard type == .screen else { return }

        // SCK also sends .idle and .blank frames with no useful pixels; encoding
        // those would waste bitrate re-sending an unchanged screen.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: - audio

    /// ScreenCaptureKit hands over 32-bit float, one buffer per channel. The
    /// wire wants interleaved 16-bit, which is half the bytes and is what the
    /// 2010 iMac's audio stack wants anyway, so the conversion happens once
    /// here rather than at either end of the network.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let onAudio else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return }

        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return }

        // Only the float path is implemented, because it is the only thing SCK
        // produces. Anything else is dropped rather than reinterpreted as
        // float, which would be loud.
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size
            + (max(channels, 1) - 1) * MemoryLayout<AudioBuffer>.size
        let listMemory = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let list = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let outChannels = min(channels, Int(LS_AUDIO_CHANNELS))
        if interleaveBuffer.count < frames * outChannels {
            interleaveBuffer = [Int16](repeating: 0, count: frames * outChannels)
        }

        interleaveBuffer.withUnsafeMutableBufferPointer { out in
            guard let out = out.baseAddress else { return }
            for channel in 0..<outChannels {
                // Non-interleaved: one AudioBuffer per channel. If a stream ever
                // arrives interleaved there is one buffer holding everything,
                // and the stride handles that too.
                let source: UnsafeMutablePointer<Float>
                let stride: Int
                if buffers.count > channel, let data = buffers[channel].mData {
                    source = data.assumingMemoryBound(to: Float.self)
                    stride = Int(buffers[channel].mNumberChannels)
                } else if let data = buffers[0].mData {
                    source = data.assumingMemoryBound(to: Float.self).advanced(by: channel)
                    stride = channels
                } else {
                    continue
                }
                for frame in 0..<frames {
                    let value = source[frame * stride]
                    // Clamp before scaling: a sample slightly over 1.0 would
                    // wrap to full-scale negative, which is an audible click.
                    let clamped = max(-1.0, min(1.0, value))
                    out[frame * outChannels + channel] = Int16(clamped * 32767.0)
                }
            }
        }

        interleaveBuffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            onAudio(base, frames, outChannels)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }
}
