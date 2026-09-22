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
//  LSControlClient.h
//  The other half of the back-channel.
//
//  One socket, connected to the host's control port, used in both directions.
//  Connecting means the host learns our address from the source of our HELLO
//  and can ping us without any configuration on its side.
//
#import <Foundation/Foundation.h>
#include "rtp_protocol.h"

@interface LSControlClient : NSObject

- (id)initWithHost:(NSString *)host port:(uint16_t)port;

- (BOOL)start:(NSError **)error;
- (void)stop;

/// Announce ourselves and ask for an immediate keyframe.
- (void)sendHelloWithWidth:(uint16_t)width height:(uint16_t)height videoPort:(uint16_t)videoPort;

/// Rate-limited internally to at most one per 100 ms: a burst of loss would
/// otherwise turn into a burst of keyframes, which is its own kind of outage.
- (void)requestKeyframe;

- (void)sendStats:(const ls_stats *)stats;

/// Fired on the control thread when the host says goodbye.
@property (nonatomic, copy) void (^hostSaidGoodbye)(void);

@property (nonatomic, readonly) NSTimeInterval lastHostContact;

/// The MAC of the interface we are reaching the host over, as "c4:2c:03:07:35:10",
/// or nil if it could not be determined. Sent to the host in HELLO so it can
/// wake this machine later.
@property (nonatomic, readonly) NSString *localMACString;

@end
