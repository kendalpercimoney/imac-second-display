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
//  LSAudioReceiver.h
//  The audio socket and its receive loop.
//
//  Separate from the video receiver on purpose. A lost audio packet is
//  concealed and forgotten -- it must never ask for a keyframe -- and audio
//  must not queue behind the hundreds of packets a keyframe arrives as.
//
#import <Foundation/Foundation.h>
#import "LSAudioPlayer.h"

@interface LSAudioReceiver : NSObject

- (id)initWithPort:(uint16_t)port player:(LSAudioPlayer *)player;

- (BOOL)start:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) uint32_t packetsReceived;
/// Inferred from gaps in the sequence number. Audio does not retransmit, so
/// this is purely diagnostic.
@property (nonatomic, readonly) uint32_t packetsLost;
@property (nonatomic, readonly) uint64_t bytesReceived;

@end
