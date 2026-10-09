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

/// Sends this machine's keyboard and mouse to the host.
///
/// Deliberately knows nothing about NSEvent. The app delegate turns events into
/// these calls; everything here works on plain numbers, so what reaches the
/// wire can be tested without synthesising a single AppKit event -- which for
/// mouse motion is not even possible, since NSEvent will not construct one
/// with a delta.
@interface LSInputForwarder : NSObject

/// `send` is handed each finished datagram. It is called on whichever thread
/// made the call that produced it.
- (id)initWithSender:(void (^)(const uint8_t *bytes, size_t length))send;

/// Whether input is currently going to the host.
@property (nonatomic, readonly, getter=isEngaged) BOOL engaged;

/// What the host last said about whether it will act on input. Engaging is
/// refused while this is NO: taking the iMac's pointer away from it with
/// nowhere for it to go would just leave the iMac unusable.
@property (nonatomic, assign) BOOL hostAccepting;

/// Host points per point of motion on this screen. The stream is drawn scaled
/// to fit, so on a 27-inch iMac showing 1080p a hand movement across the
/// picture has to be scaled down to cross the same distance on the host.
@property (nonatomic, assign) double hostPointsPerViewPoint;

- (BOOL)engage;
/// Tells the host to let go of everything, and forgets all held state.
- (void)disengage;

- (void)mouseMovedByX:(double)dx y:(double)dy;
- (void)mouseButton:(int)button down:(BOOL)down clickCount:(int)clickCount;
/// Line deltas for a wheel, pixel deltas for a trackpad.
- (void)scrollByX:(double)dx y:(double)dy precise:(BOOL)precise;
- (void)key:(uint16_t)keycode down:(BOOL)down repeat:(BOOL)isRepeat modifiers:(uint32_t)modifiers;
/// A modifier key went down or up; `modifiers` is the state after it.
- (void)modifiersChanged:(uint32_t)modifiers keycode:(uint16_t)keycode;

/// Everything currently held, for the host to reconcile against. Sent
/// periodically while engaged, because a lost key-up over UDP is otherwise a
/// key held down on the host for good.
- (void)sendState;

/// Control-Option-Escape. Swallowed rather than forwarded, and the only way
/// out once the keyboard belongs to the host. Not Command-Option-Escape, which
/// is Force Quit and best left alone.
+ (BOOL)isReleaseKey:(uint16_t)keycode modifiers:(uint32_t)modifiers;

@end
