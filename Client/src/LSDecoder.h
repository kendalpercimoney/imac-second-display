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
