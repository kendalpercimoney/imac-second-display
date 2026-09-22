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
//  LSReceiver.h
//  Bound UDP socket plus a tight receive loop.
//
//  The only job of this thread is to get packets out of the kernel and into the
//  depacketizer. Nothing slow happens here -- decoding lives on its own thread
//  precisely so a long decode can never cause a socket buffer overrun.
//
#import <Foundation/Foundation.h>
#import "LSDepacketizer.h"

@interface LSReceiver : NSObject

- (id)initWithPort:(uint16_t)port depacketizer:(LSDepacketizer *)depacketizer;

- (BOOL)start:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) uint64_t bytesReceived;
/// Wall-clock time of the last datagram, for "has the host gone away" checks.
@property (nonatomic, readonly) NSTimeInterval lastPacketTime;

@end
