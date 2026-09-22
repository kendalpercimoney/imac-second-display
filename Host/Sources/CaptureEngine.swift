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

    /// Called on outputQueue for every complete frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
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
               frameRate: Int, showsCursor: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)

        guard let display = content.displays.first(where: { $0.displayID == displayID })
                         ?? content.displays.first else {
            throw NSError(domain: "LanScreen", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No capturable display found."
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.capturesAudio = false
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
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

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

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }
}
