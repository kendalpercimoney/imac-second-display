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
//  Loopback receiver: the client's real receive -> depacketize -> decode path,
//  with no window. Prints a one-line verdict and exits non-zero on failure.
//
//  Usage: lsloopreceive <port> <expectedFrames> <timeoutSeconds>
//
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#import "LSReceiver.h"
#import "LSDepacketizer.h"
#import "LSDecoder.h"

@interface LoopHarness : NSObject <LSDepacketizerDelegate>
@property (nonatomic, assign) uint32_t accessUnits;
@property (nonatomic, assign) uint32_t keyframeRequests;
@property (nonatomic, assign) uint32_t pixelBuffers;
@property (nonatomic, assign) OSType   pixelFormat;
@property (nonatomic, assign) size_t   frameWidth;
@property (nonatomic, assign) size_t   frameHeight;
/// framesDropped and queueOverflows at the moment the first frame came out, so
/// the assertions below can talk about steady state rather than about startup.
@property (nonatomic, assign) uint32_t dropsAtFirstFrame;
@property (nonatomic, assign) uint32_t overflowsAtFirstFrame;
@property (nonatomic, strong) NSMutableArray *latencySamples;   // NSNumber, ms
@property (nonatomic, strong) LSDecoder *decoder;
@property (nonatomic, assign) int keyframeSocket;
@property (nonatomic, assign) struct sockaddr_in keyframeAddress;
@property (nonatomic, assign) NSTimeInterval lastKeyframeAsk;
- (void)askForKeyframe;
@end

@implementation LoopHarness

- (void)depacketizer:(LSDepacketizer *)depacketizer
 didCompleteAccessUnit:(NSData *)avcc
                   sps:(NSData *)sps
                   pps:(NSData *)pps
             timestamp:(uint32_t)timestamp
            isKeyframe:(BOOL)isKeyframe
{
    _accessUnits++;
    [_decoder submitAccessUnit:avcc sps:sps pps:pps timestamp:timestamp
                    isKeyframe:isKeyframe];
}

- (void)depacketizerNeedsKeyframe:(LSDepacketizer *)depacketizer {
    _keyframeRequests++;
    [self askForKeyframe];
}

/// The real client's keyframe request, cut down: one datagram to the sender's
/// keyframe port, at most ten a second, exactly the rate the control channel
/// allows.
- (void)askForKeyframe {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastKeyframeAsk < 0.1) return;
    _lastKeyframeAsk = now;
    if (_keyframeSocket < 0) return;
    uint8_t byte = 1;
    sendto(_keyframeSocket, &byte, 1, 0,
           (const struct sockaddr *)&_keyframeAddress, sizeof(_keyframeAddress));
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        uint16_t port    = argc > 1 ? (uint16_t)atoi(argv[1]) : 5000;
        uint32_t expect  = argc > 2 ? (uint32_t)atoi(argv[2]) : 30;
        double   timeout = argc > 3 ? atof(argv[3]) : 20.0;

        LoopHarness *harness = [[LoopHarness alloc] init];
        harness.latencySamples = [NSMutableArray array];
        LSDepacketizer *depacketizer = [[LSDepacketizer alloc] init];
        depacketizer.delegate = harness;

        LSDecoder *decoder = [[LSDecoder alloc] init];
        harness.decoder = decoder;

        harness.keyframeSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        struct sockaddr_in keyframeAddress;
        memset(&keyframeAddress, 0, sizeof(keyframeAddress));
        keyframeAddress.sin_len = sizeof(keyframeAddress);
        keyframeAddress.sin_family = AF_INET;
        keyframeAddress.sin_port = htons((uint16_t)(port + 1));
        keyframeAddress.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        harness.keyframeAddress = keyframeAddress;
        __unsafe_unretained LoopHarness *keyframeHarness = harness;
        decoder.keyframeNeeded = ^{ [keyframeHarness askForKeyframe]; };
        // The decoder owns the block, so capture it weakly or the two keep each
        // other alive.
        __unsafe_unretained LSDecoder *weakDecoder = decoder;
        decoder.frameHandler = ^(CVPixelBufferRef pixelBuffer, CMTime presentationTime) {
            if (harness.pixelBuffers == 0) {
                harness.dropsAtFirstFrame = [weakDecoder framesDropped];
                harness.overflowsAtFirstFrame = [weakDecoder queueOverflows];
            }
            harness.pixelBuffers++;

            // Both ends share the host time clock here. The RTP timestamp is
            // only 32 bits, so compare in 90 kHz ticks and let unsigned
            // arithmetic absorb the wrap.
            uint32_t sent90k = (uint32_t)((uint64_t)presentationTime.value & 0xFFFFFFFFu);
            // Truncate through uint64 first. Casting a double larger than
            // UINT32_MAX straight to uint32_t is undefined behaviour, and the
            // host clock passes that point after ~13 hours of uptime.
            uint64_t nowTicks = (uint64_t)(CMTimeGetSeconds(
                CMClockGetTime(CMClockGetHostTimeClock())) * 90000.0);
            uint32_t now90k = (uint32_t)(nowTicks & 0xFFFFFFFFu);
            double ms = (double)(uint32_t)(now90k - sent90k) / 90.0;
            if (ms >= 0 && ms < 2000) [harness.latencySamples addObject:@(ms)];
            harness.pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
            harness.frameWidth  = CVPixelBufferGetWidth(pixelBuffer);
            harness.frameHeight = CVPixelBufferGetHeight(pixelBuffer);
            CVBufferRelease(pixelBuffer);
        };
        [decoder start];

        NSError *error = nil;
        LSReceiver *receiver = [[LSReceiver alloc] initWithPort:port depacketizer:depacketizer];
        if (![receiver start:&error]) {
            fprintf(stderr, "FAIL: %s\n", [[error localizedDescription] UTF8String]);
            return 2;
        }
        fprintf(stderr, "listening on %u\n", (unsigned)port);

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while ([deadline timeIntervalSinceNow] > 0 && harness.pixelBuffers < expect) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }

        [receiver stop];
        [decoder stop];

        OSType format = harness.pixelFormat;
        char tag[5] = {0};
        tag[0] = (char)((format >> 24) & 0xFF); tag[1] = (char)((format >> 16) & 0xFF);
        tag[2] = (char)((format >> 8) & 0xFF);  tag[3] = (char)(format & 0xFF);

        printf("access units: %u\n", harness.accessUnits);
        printf("decoded frames: %u\n", harness.pixelBuffers);
        printf("pixel format: %s  size: %zux%zu\n", tag, harness.frameWidth, harness.frameHeight);
        printf("packets: %u  lost: %u  corrupt frames: %u  keyframe requests: %u\n",
               [depacketizer packetsReceived], [depacketizer packetsLost],
               [depacketizer framesCorrupt], harness.keyframeRequests);
        // Drop the first few samples: they carry decompression session setup and
        // say nothing about steady-state latency.
        NSArray *samples = harness.latencySamples;
        if ([samples count] > 8) {
            samples = [samples subarrayWithRange:NSMakeRange(5, [samples count] - 5)];
            samples = [samples sortedArrayUsingSelector:@selector(compare:)];
            NSUInteger n = [samples count];
            double total = 0;
            for (NSNumber *value in samples) total += [value doubleValue];
            printf("pipeline latency, encode->wire->decode, %lu steady samples:\n",
                   (unsigned long)n);
            printf("   min %.2f  median %.2f  p95 %.2f  max %.2f  mean %.2f ms\n",
                   [samples[0] doubleValue],
                   [samples[n / 2] doubleValue],
                   [samples[(NSUInteger)(n * 0.95)] doubleValue],
                   [[samples lastObject] doubleValue],
                   total / n);
        }
        printf("decode avg: %.2f ms  last: %.2f ms  peak: %.2f ms\n",
               [decoder decodeMicroseconds] / 1000.0,
               [decoder decodeMicrosecondsLast] / 1000.0,
               [decoder decodeMicrosecondsPeak] / 1000.0);
        uint32_t steadyDrops = [decoder framesDropped] - harness.dropsAtFirstFrame;
        uint32_t steadyOverflows = [decoder queueOverflows] - harness.overflowsAtFirstFrame;
        printf("decoding fell behind %u times after startup, refusing %u frames "
               "(%u refused during startup)\n",
               steadyOverflows, steadyDrops, harness.dropsAtFirstFrame);

        // Building the decompression session takes tens of milliseconds, and
        // the queue is deliberately only two deep, so whatever arrives during
        // that first decode is refused on purpose.
        //
        // What matters afterwards is that the client keeps up, so this counts
        // the times it fell behind, not the frames that cost. Once the queue
        // overflows, nothing more is decoded until a keyframe -- decoding a
        // frame whose predecessor was skipped is what moshes the picture -- and
        // this harness never asks the sender for one, so a single overflow
        // refuses everything up to the next scheduled keyframe. The real client
        // asks at once and waits a round trip. A single overflow on a loaded
        // machine is tolerated; systematically falling behind is not.
        uint32_t allowedOverflows = harness.pixelBuffers / 50;   // 2%
        if (allowedOverflows < 2) allowedOverflows = 2;
        if (steadyOverflows > allowedOverflows) {
            printf("RESULT: FAIL (decoding fell behind %u times after startup, tolerating %u)\n",
                   steadyOverflows, allowedOverflows);
            return 1;
        }
        if (harness.pixelBuffers < expect) {
            printf("RESULT: FAIL (decoded %u, needed at least %u)\n",
                   harness.pixelBuffers, expect);
            return 1;
        }
        if ([depacketizer packetsLost] > 0) {
            printf("RESULT: FAIL (%u packets lost on loopback)\n", [depacketizer packetsLost]);
            return 1;
        }
        if ([depacketizer framesCorrupt] > 0) {
            printf("RESULT: FAIL (%u corrupt frames on loopback)\n",
                   [depacketizer framesCorrupt]);
            return 1;
        }
        printf("RESULT: PASS\n");
        return 0;
    }
}
