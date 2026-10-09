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

#import <Foundation/Foundation.h>

/// The frames waiting to be decoded, and the one rule that keeps the picture
/// from moshing: never decode a frame whose predecessor was not decoded.
///
/// Every frame after a keyframe is a set of changes to the frame before it. The
/// queue this replaces kept latency down by throwing away its oldest waiting
/// frame whenever decoding fell behind, and then decoded the next one anyway --
/// applying its changes to a picture they were never meant for. The damage is
/// copied forward into every frame after it, smeared blocks dragging across the
/// screen, until the next keyframe up to five seconds later. Decoding falls
/// behind on exactly the frames that scrolling and zooming produce.
///
/// So when something has to go, it is the newest frame, the chain of frames
/// already waiting stays intact and is still shown, and nothing after the gap
/// is decoded until a keyframe arrives. The owner asks for one while
/// `waitingForKeyframe` is set. The cost is the picture holding still for a
/// round trip; the alternative was it being wrong for seconds.
///
/// No threads and no decoder in here, so the policy can be tested on its own.
/// The owner provides the locking.
@interface LSDecodeQueue : NSObject

- (id)initWithDepth:(NSUInteger)depth;

/// Queues a frame, or refuses it if it can no longer be decoded correctly.
- (void)push:(id)unit isKeyframe:(BOOL)isKeyframe;
/// The next frame to decode, or nil.
- (id)pop;

/// The decoder rejected a frame. Whatever it was holding as a reference can no
/// longer be trusted, so this is treated exactly like a gap.
- (void)decodeFailed;

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) BOOL waitingForKeyframe;
/// Frames that were never decoded: refused to make room, refused because they
/// followed a gap, or passed over because a newer keyframe made them moot.
@property (nonatomic, readonly) uint32_t dropped;
/// How many times decoding fell behind far enough to overflow. One overflow
/// can refuse a run of frames, up to the keyframe that ends the wait, so this
/// -- not `dropped` -- is the measure of how often the decoder could not keep up.
@property (nonatomic, readonly) uint32_t overflows;

@end
