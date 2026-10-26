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

/// When to send a still picture again at near-lossless quality, and what that
/// obliges the stream to do afterwards.
///
/// A picture that has stopped changing stays at whatever quality it was left
/// at mid-gesture, because nothing is sent until the screen changes again. For
/// looking closely at a photo that is the wrong way round: the encoder rationed
/// that last frame while it was moving. Sending it again does little -- 42.3 dB
/// becomes 43.0 at 25 Mb/s and then the encoder sends nothing, because its
/// rate controller thinks it is good enough. A keyframe from a second encoder
/// running at constant quality reaches 50.5 dB, the point past which nobody can
/// tell, for about a megabyte, and carries the same parameter sets as the
/// stream so the client does not have to rebuild its decoder.
///
/// That keyframe does oblige one thing. It replaces the picture the client
/// predicts from, so the motion encoder's next frame -- built on its own last
/// frame, which the client no longer holds -- has to be a keyframe too, or it
/// is decoded against the wrong picture. That is moshing again, quietly.
///
/// Not every pause earns a refresh. Typing sends small frames, and a caret
/// blinks twice a second; refreshing after each would be a megabyte per blink
/// plus a keyframe on the next one. So it is earned by real change -- enough
/// encoded bytes since the last refresh to mean something actually moved --
/// and the keyframes it forces do not count towards earning the next.
struct StillRefinement {
    /// How long the screen has to have been still.
    var stillAfter: TimeInterval = 0.3
    /// How much change earns a refresh: motion frames' bytes since the last
    /// one, keyframes not counted. A few frames of scrolling or zooming; about
    /// thirty keystrokes.
    var earnedAfterBytes = 300_000
    var enabled = true

    private(set) var bytesSinceRefresh = 0
    private(set) var lastFrameAt: TimeInterval = -.infinity
    /// A refresh has gone out and nothing has been encoded since.
    private(set) var refreshed = false

    /// A frame from the motion encoder. Called with its size, whether it is a
    /// keyframe, and when it was captured.
    mutating func motionFrameEncoded(bytes: Int, isKeyframe: Bool) {
        if !isKeyframe { bytesSinceRefresh += bytes }
    }

    /// A new frame has been captured, so the screen is not still. Returns
    /// whether it must be encoded as a keyframe: the first frame after a
    /// refresh always must.
    mutating func frameCaptured(at time: TimeInterval) -> Bool {
        lastFrameAt = time
        if refreshed {
            refreshed = false
            return true
        }
        return false
    }

    /// Whether to send the refresh now.
    func shouldRefresh(now: TimeInterval) -> Bool {
        enabled && !refreshed
            && bytesSinceRefresh >= earnedAfterBytes
            && now - lastFrameAt >= stillAfter
    }

    /// The refresh went out. Also called when a keyframe of the still picture
    /// went out for any other reason -- the client asking for one -- since that
    /// is a refresh too, and the next motion frame owes it the same keyframe.
    mutating func refreshSent() {
        refreshed = true
        bytesSinceRefresh = 0
    }

    /// The stream started over, so nothing is owed in either direction.
    mutating func reset() {
        bytesSinceRefresh = 0
        refreshed = false
        lastFrameAt = -.infinity
    }
}
