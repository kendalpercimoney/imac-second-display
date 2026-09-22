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
//  LSDecoder.h
//  VideoToolbox H.264 decode for OS X 10.9.
//
//  Runs its own thread with a deliberately shallow queue: if we cannot keep
//  up, the right answer for a remote-display tool is to drop the old frame,
//  not to build a buffer of stale ones.
//
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface LSDecoder : NSObject

/// Called on the decode thread with a retained pixel buffer. The handler must
/// release it (or hand ownership to something that will).
///
/// `presentationTime` is the sender's clock, carried through the RTP
/// timestamp. It is only comparable to local time when both ends share a
/// clock -- i.e. on a loopback test. Across two machines it is a frame
/// identifier, not a latency measurement.
@property (nonatomic, copy) void (^frameHandler)(CVPixelBufferRef pixelBuffer,
                                                 CMTime presentationTime);

- (void)start;
- (void)stop;

/// Thread-safe. Called from the receive thread.
- (void)submitAccessUnit:(NSData *)avcc
                     sps:(NSData *)sps
                     pps:(NSData *)pps
               timestamp:(uint32_t)timestamp;

@property (nonatomic, readonly) uint32_t framesDecoded;
@property (nonatomic, readonly) uint32_t framesDropped;
@property (nonatomic, readonly) uint32_t decodeMicroseconds;       // rolling average
@property (nonatomic, readonly) uint32_t decodeMicrosecondsLast;
@property (nonatomic, readonly) uint32_t decodeMicrosecondsPeak;
@property (nonatomic, readonly) uint32_t queueDepth;
/// YES once a session exists and at least one frame came out of it.
@property (nonatomic, readonly) BOOL hasDecodedFrame;
/// Human-readable reason the decoder is unhappy, or nil.
@property (nonatomic, readonly) NSString *statusMessage;

@end
