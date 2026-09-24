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
//  Tracks the pointer so the client can draw it, instead of it being baked into
//  the video.
//
//  A pointer inside the video is as old as the video: encoded, sent, decoded,
//  displayed. Sent on its own it arrives in well under a millisecond and is
//  drawn on the next refresh, so it stops feeling like the machine is lagging
//  even though the picture underneath is unchanged. VNC has done this for the
//  same reason for decades.
//
//  The trade-off is real: the pointer now runs slightly ahead of whatever it is
//  dragging, because the window moves with the video and the pointer does not.
//
import Foundation
import AppKit
import CoreGraphics

final class CursorTracker {

    /// Position in streamed pixels, whether it is on the captured display, and
    /// which bitmap it is currently using.
    var onPosition: ((UInt16, UInt16, Bool, UInt16) -> Void)?
    /// A bitmap the client has not seen yet: id, size, hotspot, premultiplied RGBA.
    var onImage: ((UInt16, Int, Int, Int, Int, Data) -> Void)?

    private var positionTimer: DispatchSourceTimer?
    private var imageTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.lanscreen.cursor", qos: .userInteractive)

    private var displayID: CGDirectDisplayID = 0
    private var streamWidth = 0
    private var streamHeight = 0

    private var currentImageID: UInt16 = 0
    private var lastImageBytes: Data?
    /// Re-sent periodically so a dropped datagram does not leave the client
    /// drawing the wrong pointer indefinitely. There is no acknowledgement and
    /// a bitmap is big enough that IP may fragment it.
    private var framesSinceImageSent = 0

    func start(displayID: CGDirectDisplayID, streamWidth: Int, streamHeight: Int,
               positionRateHz: Int = 120) {
        stop()
        self.displayID = displayID
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight

        let position = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(max(positionRateHz, 1))
        position.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        position.setEventHandler { [weak self] in self?.samplePosition() }
        position.resume()
        positionTimer = position

        // Rendering an NSImage is far too expensive to do at the position rate,
        // and the pointer bitmap changes when you cross a window edge, not
        // hundreds of times a second.
        let image = DispatchSource.makeTimerSource(queue: .main)
        image.schedule(deadline: .now(), repeating: 0.1)
        image.setEventHandler { [weak self] in self?.sampleImage() }
        image.resume()
        imageTimer = image
    }

    func stop() {
        positionTimer?.cancel(); positionTimer = nil
        imageTimer?.cancel(); imageTimer = nil
        lastImageBytes = nil
    }

    // MARK: - position

    private func samplePosition() {
        guard streamWidth > 0, streamHeight > 0 else { return }
        // CGEvent gives global display coordinates with a top-left origin, which
        // is the same space CGDisplayBounds uses. NSEvent.mouseLocation is
        // bottom-left and relative to the main screen, which would need
        // untangling for no benefit.
        guard let location = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let relativeX = (location.x - bounds.origin.x) / bounds.width
        let relativeY = (location.y - bounds.origin.y) / bounds.height
        let onDisplay = relativeX >= 0 && relativeX < 1 && relativeY >= 0 && relativeY < 1

        let x = Int((relativeX * Double(streamWidth)).rounded())
        let y = Int((relativeY * Double(streamHeight)).rounded())
        onPosition?(UInt16(clamping: x), UInt16(clamping: y),
                    onDisplay, currentImageID)
    }

    // MARK: - bitmap

    private func sampleImage() {
        guard let cursor = NSCursor.currentSystem ?? NSCursor.current as NSCursor? else { return }
        guard let rendered = Self.render(cursor: cursor) else { return }

        framesSinceImageSent += 1
        let changed = rendered.pixels != lastImageBytes
        // Every five seconds even when unchanged, in case the one that mattered
        // was the one that got dropped.
        guard changed || framesSinceImageSent >= 50 else { return }

        if changed {
            currentImageID = currentImageID &+ 1
            if currentImageID == 0 { currentImageID = 1 }
            lastImageBytes = rendered.pixels
        }
        framesSinceImageSent = 0
        onImage?(currentImageID, rendered.width, rendered.height,
                 rendered.hotspotX, rendered.hotspotY, rendered.pixels)
    }

    struct Rendered {
        var width: Int, height: Int
        var hotspotX: Int, hotspotY: Int
        var pixels: Data
    }

    /// Flattens the cursor to premultiplied RGBA at 1x, which is what the iMac's
    /// non-Retina panel wants anyway.
    static func render(cursor: NSCursor) -> Rendered? {
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let width = min(Int(size.width.rounded()), 64)
        let height = min(Int(size.height.rounded()), 64)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height),
                       from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.current = previous
            return true
        }
        guard ok else { return nil }

        // The hotspot is in the image's own coordinates, top-left origin,
        // so it scales with any clamping applied above.
        let scaleX = Double(width) / Double(size.width)
        let scaleY = Double(height) / Double(size.height)
        return Rendered(width: width, height: height,
                        hotspotX: Int((cursor.hotSpot.x * scaleX).rounded()),
                        hotspotY: Int((cursor.hotSpot.y * scaleY).rounded()),
                        pixels: pixels)
    }
}
