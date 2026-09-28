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
//  Does the decoder survive the RTP timestamp going round?
//
//  The timestamp is 32 bits at 90 kHz, so it wraps every 13 hours 15 minutes.
//  The client froze after about twelve, which is close enough to be worth
//  ruling in or out rather than reasoning about. The depacketizer compares
//  timestamps only for equality and is fine; the decoder hands them to
//  VideoToolbox as a CMTime presentation stamp, and at the wrap that stamp
//  jumps back by thirteen hours.
//
//  So: encode a few real frames, then push them through LSDecoder with
//  timestamps walking up to the wrap, across it, and out the other side, and
//  require that frames keep coming out.
//
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import "LSDecoder.h"
#import "rtp_protocol.h"

static NSMutableArray *gEncoded;    // NSData, AVCC access units
static NSData *gSPS, *gPPS;

static void gotFrame(void *outputCallbackRefCon, void *sourceFrameRefCon,
                     OSStatus status, VTEncodeInfoFlags flags,
                     CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) return;

    if (!gSPS) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        const uint8_t *ps = NULL; size_t psSize = 0; size_t count = 0; int nalLen = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, 0, &ps, &psSize, &count, &nalLen) == noErr) {
            gSPS = [NSData dataWithBytes:ps length:psSize];
        }
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, 1, &ps, &psSize, &count, &nalLen) == noErr) {
            gPPS = [NSData dataWithBytes:ps length:psSize];
        }
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t total = 0; char *data = NULL;
    if (CMBlockBufferGetDataPointer(block, 0, NULL, &total, &data) == kCMBlockBufferNoErr) {
        [gEncoded addObject:[NSData dataWithBytes:data length:total]];
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        gEncoded = [NSMutableArray array];
        const int width = 640, height = 360, frameCount = 12;

        VTCompressionSessionRef session = NULL;
        VTCompressionSessionCreate(kCFAllocatorDefault, width, height,
                                   kCMVideoCodecType_H264, NULL, NULL, NULL,
                                   gotFrame, NULL, &session);
        VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
        VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                             kVTProfileLevel_H264_Baseline_AutoLevel);

        for (int i = 0; i < frameCount; i++) {
            CVPixelBufferRef pb = NULL;
            NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attrs, &pb);
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t *base = CVPixelBufferGetBaseAddress(pb);
            size_t stride = CVPixelBufferGetBytesPerRow(pb);
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++) {
                    uint8_t *p = base + y * stride + x * 4;
                    p[0] = (uint8_t)(x + i * 9); p[1] = (uint8_t)(y + i * 5);
                    p[2] = (uint8_t)(x ^ y); p[3] = 255;
                }
            CVPixelBufferUnlockBaseAddress(pb, 0);
            NSDictionary *props = (i == 0)
                ? @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES } : nil;
            VTCompressionSessionEncodeFrame(session, pb,
                CMTimeMake(i, 60), kCMTimeInvalid,
                (__bridge CFDictionaryRef)props, NULL, NULL);
            CVPixelBufferRelease(pb);
        }
        VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(session);
        CFRelease(session);

        if ([gEncoded count] < 2 || !gSPS || !gPPS) {
            printf("could not encode a sample stream to replay\n");
            return 1;
        }
        printf("\n  encoded %lu access units at %dx%d\n",
               (unsigned long)[gEncoded count], width, height);

        LSDecoder *decoder = [[LSDecoder alloc] init];
        __block uint64_t emitted = 0;
        __block uint64_t emittedBeforeWrap = 0;
        __block BOOL wrapped = NO;
        decoder.frameHandler = ^(CVPixelBufferRef pixelBuffer, CMTime pts) {
            emitted++;
            if (!wrapped) emittedBeforeWrap++;
            CVBufferRelease(pixelBuffer);
        };
        [decoder start];

        // Walk the last few seconds before the wrap, across it, and out the
        // other side. 1500 ticks is one frame at 60 fps.
        const uint32_t step = 1500;
        // Five seconds each way. Submitted slower than the decoder needs, so
        // that a frame missing from the output means something went wrong
        // rather than that the queue -- which is deliberately two deep --
        // dropped it for being overtaken.
        const int framesEitherSide = 300;
        uint32_t timestamp = (uint32_t)(0u - (uint32_t)(framesEitherSide * step));
        uint32_t previous = timestamp;

        for (int i = 0; i < framesEitherSide * 2; i++) {
            NSData *unit = gEncoded[(NSUInteger)(i % (int)[gEncoded count])];
            [decoder submitAccessUnit:unit sps:gSPS pps:gPPS timestamp:timestamp];
            previous = timestamp;
            timestamp += step;
            if (timestamp < previous) {
                wrapped = YES;
                printf("  timestamp wrapped: %u -> %u after %llu frames out\n",
                       previous, timestamp, emitted);
            }
            usleep(3000);     // slower than a decode, so nothing is dropped
        }

        // Let the queue drain.
        for (int i = 0; i < 100 && decoder.queueDepth > 0; i++) usleep(10000);
        usleep(200000);

        uint64_t after = emitted - emittedBeforeWrap;
        printf("  frames out: %llu before the wrap, %llu after\n\n",
               emittedBeforeWrap, after);

        int failures = 0;
        #define CHECK(what, ok) do { \
            printf("  %s %s\n", (ok) ? "ok  " : "FAIL", what); \
            if (!(ok)) failures++; \
        } while (0)

        CHECK("the run actually crossed the wrap", wrapped);
        CHECK("frames came out before it", emittedBeforeWrap > 250);
        CHECK("frames kept coming out after it", after > 250);
        CHECK("the decoder did not stall at the wrap",
              after > emittedBeforeWrap / 2);
        CHECK("nothing was left stuck in the queue", decoder.queueDepth == 0);

        printf("\nRESULT: %s\n", failures == 0 ? "PASS" : "FAIL");
        return failures == 0 ? 0 : 1;
    }
}
