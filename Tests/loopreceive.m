//
//  Loopback receiver: the client's real receive -> depacketize -> decode path,
//  with no window. Prints a one-line verdict and exits non-zero on failure.
//
//  Usage: lsloopreceive <port> <expectedFrames> <timeoutSeconds>
//
#import <Foundation/Foundation.h>
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
/// framesDropped at the moment the first frame came out, so the assertions
/// below can talk about steady state rather than about startup.
@property (nonatomic, assign) uint32_t dropsAtFirstFrame;
@property (nonatomic, strong) NSMutableArray *latencySamples;   // NSNumber, ms
@property (nonatomic, strong) LSDecoder *decoder;
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
    [_decoder submitAccessUnit:avcc sps:sps pps:pps timestamp:timestamp];
}

- (void)depacketizerNeedsKeyframe:(LSDepacketizer *)depacketizer {
    _keyframeRequests++;
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
        decoder.frameHandler = ^(CVPixelBufferRef pixelBuffer, CMTime presentationTime) {
            if (harness.pixelBuffers == 0) {
                harness.dropsAtFirstFrame = [decoder framesDropped];
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
        printf("frames dropped by queue: %u total (%u during startup, %u after)\n",
               [decoder framesDropped], harness.dropsAtFirstFrame, steadyDrops);

        // Building the decompression session takes tens of milliseconds, and
        // the queue is deliberately only two deep, so whatever arrives during
        // that first decode is dropped on purpose. The assertion that matters
        // is that nothing is dropped once the pipeline is actually running.
        if (steadyDrops > 0) {
            printf("RESULT: FAIL (%u frames dropped after startup)\n", steadyDrops);
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
