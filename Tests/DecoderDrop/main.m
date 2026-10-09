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
//  What dropping one frame before decode does to the picture.
//
//  Every frame in this stream is a set of changes to the one before it. The
//  client's decode queue used to throw away its oldest waiting frame whenever
//  decoding fell behind, and decode the next one regardless -- applying its
//  changes to a picture they were never meant for. That is "moshing": blocks
//  dragged across the screen, persisting until the next keyframe repairs it.
//
//  This scrolls a detailed picture, encodes it the way the host does, and
//  decodes it three ways, scoring every decoded frame against what it should
//  have been:
//    - everything                         (the baseline)
//    - one frame dropped, decode carries on (what the client used to do)
//    - one frame dropped, nothing shown again until the next keyframe
//                                         (what it does now)
//
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#include <math.h>
#include "LSDecodeQueue.h"

enum { W = 1280, H = 720, FRAMES = 120, KEYFRAME_EVERY = 60 };

static NSMutableArray *gUnits;       // AVCC per frame
static NSMutableArray *gKeyframe;    // NSNumber BOOL per frame
static NSData *gSPS, *gPPS;
static uint8_t *gSource[FRAMES];     // BGRA source frames, for scoring

static void encoded(void *a, void *b, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {
    if (st || !sb) return;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!gSPS) {
        const uint8_t *p; size_t n, c; int l;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &p, &n, &c, &l);
        gSPS = [NSData dataWithBytes:p length:n];
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &p, &n, &c, &l);
        gPPS = [NSData dataWithBytes:p length:n];
    }
    BOOL key = YES;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(att, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
        key = !(notSync && CFBooleanGetValue(notSync));
    }
    size_t t; char *data;
    CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sb), 0, NULL, &t, &data);
    [gUnits addObject:[NSData dataWithBytes:data length:t]];
    [gKeyframe addObject:@(key)];
}

/// A detailed picture, scrolled a few pixels a frame: what scrolling a web page
/// or a photo library does to an encoder.
static void makeSource(void) {
    uint32_t seed = 2463534242u;
    int tall = H * 3;
    uint8_t *page = malloc((size_t)W * tall * 4);
    for (int y = 0; y < tall; y++) for (int x = 0; x < W; x++) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        uint8_t *p = page + ((size_t)y * W + x) * 4;
        int band = (y / 48) % 6;
        p[0] = (uint8_t)(40 + band * 30 + (seed & 15));
        p[1] = (uint8_t)(((x / 64) + (y / 64)) % 2 ? 210 : 70);
        p[2] = (uint8_t)((x * 255 / W + y) & 0xFF);
        p[3] = 255;
    }
    for (int i = 0; i < FRAMES; i++) {
        gSource[i] = malloc((size_t)W * H * 4);
        int offset = i * 6;
        memcpy(gSource[i], page + (size_t)offset * W * 4, (size_t)W * H * 4);
    }
    free(page);
}

static void encodeAll(void) {
    gUnits = [NSMutableArray array]; gKeyframe = [NSMutableArray array];
    VTCompressionSessionRef s;
    VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)@{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES},
        NULL, NULL, encoded, NULL, &s);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(12000000));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(KEYFRAME_EVERY));
    for (int i = 0; i < FRAMES; i++) {
        CVPixelBufferRef pb;
        CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &pb);
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *base = CVPixelBufferGetBaseAddress(pb); size_t stride = CVPixelBufferGetBytesPerRow(pb);
        for (int y = 0; y < H; y++) memcpy(base + y * stride, gSource[i] + (size_t)y * W * 4, W * 4);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        NSDictionary *props = (i % KEYFRAME_EVERY == 0)
            ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
        VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 60), kCMTimeInvalid,
                                        (__bridge CFDictionaryRef)props, NULL, NULL);
        CVPixelBufferRelease(pb);
    }
    VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
    VTCompressionSessionInvalidate(s); CFRelease(s);
}

static double gScore[FRAMES];
static int gScored;
static int gCurrent;

static double psnr(CVPixelBufferRef out, const uint8_t *src) {
    CVPixelBufferLockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(out);
    size_t stride = CVPixelBufferGetBytesPerRow(out);
    double sum = 0; long n = 0;
    for (int y = 0; y < H; y += 2) for (int x = 0; x < W; x += 2) {
        const uint8_t *a = base + y * stride + x * 4, *b = src + ((size_t)y * W + x) * 4;
        for (int c = 0; c < 3; c++) { double d = (double)a[c] - b[c]; sum += d * d; n++; }
    }
    CVPixelBufferUnlockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
    double mse = sum / n;
    return mse <= 0 ? 99 : 10 * log10(255.0 * 255.0 / mse);
}

static void decoded(void *a, void *b, OSStatus st, VTDecodeInfoFlags f,
                    CVImageBufferRef img, CMTime pts, CMTime dur) {
    if (st || !img) return;
    gScore[gCurrent] = psnr(img, gSource[gCurrent]);
    gScored++;
}

typedef enum { DECODE_ALL, DROP_AND_CARRY_ON, DROP_AND_RESYNC } Policy;

/// Returns the frames that were put on screen and their scores.
static void run(Policy policy, int dropAt, double *worstShown, int *shown, int *frozen) {
    for (int i = 0; i < FRAMES; i++) gScore[i] = -1;
    gScored = 0;
    CMVideoFormatDescriptionRef fmt;
    const uint8_t *sets[2] = { gSPS.bytes, gPPS.bytes };
    size_t sizes[2] = { gSPS.length, gPPS.length };
    CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &fmt);
    VTDecompressionOutputCallbackRecord cb = { decoded, NULL };
    VTDecompressionSessionRef d;
    VTDecompressionSessionCreate(NULL, fmt, NULL,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)},
        &cb, &d);

    // The real queue, in the policy it would be under. A drop is forced at
    // `dropAt` by pushing three frames before letting one be taken.
    LSDecodeQueue *queue = [[LSDecodeQueue alloc] initWithDepth:2];
    for (int i = 0; i < FRAMES; i++) {
        BOOL key = [gKeyframe[i] boolValue];
        if (policy == DECODE_ALL) {
            // decode straight through
        } else if (i == dropAt) {
            // Three arrive before the decoder can take one: the oldest goes.
            [queue push:@(i) isKeyframe:key];
            [queue push:@(i + 1) isKeyframe:[gKeyframe[i + 1] boolValue]];
            [queue push:@(i + 2) isKeyframe:[gKeyframe[i + 2] boolValue]];
        }

        NSMutableArray *toDecode = [NSMutableArray array];
        if (policy == DECODE_ALL) {
            [toDecode addObject:@(i)];
        } else if (policy == DROP_AND_CARRY_ON) {
            // The old behaviour, reproduced exactly: drop the oldest and decode
            // everything else as if nothing had happened.
            if (i == dropAt) continue;                 // frame `dropAt` is the one lost
            [toDecode addObject:@(i)];
        } else {
            if (i < dropAt) {
                [queue push:@(i) isKeyframe:key];
            } else if (i > dropAt + 2) {
                [queue push:@(i) isKeyframe:key];
            }
            id unit;
            while ((unit = [queue pop])) [toDecode addObject:unit];
        }

        for (NSNumber *index in toDecode) {
            int k = [index intValue];
            gCurrent = k;
            NSData *u = gUnits[k];
            CMBlockBufferRef bb;
            CMBlockBufferCreateWithMemoryBlock(NULL, (void *)u.bytes, u.length, kCFAllocatorNull,
                                               NULL, 0, u.length, 0, &bb);
            CMSampleBufferRef sb; size_t sz = u.length;
            CMSampleBufferCreate(NULL, bb, true, NULL, NULL, fmt, 1, 0, NULL, 1, &sz, &sb);
            VTDecompressionSessionDecodeFrame(d, sb, 0, NULL, NULL);
            CFRelease(sb); CFRelease(bb);
        }
    }
    VTDecompressionSessionInvalidate(d); CFRelease(d); CFRelease(fmt);

    *worstShown = 99; *shown = 0; *frozen = 0;
    for (int i = 1; i < FRAMES; i++) {
        if (gScore[i] < 0) { (*frozen)++; continue; }
        (*shown)++;
        if (gScore[i] < *worstShown) *worstShown = gScore[i];
    }
}

int main(void) {
    @autoreleasepool {
        makeSource();
        encodeAll();
        int keyframes = 0;
        for (NSNumber *k in gKeyframe) keyframes += [k boolValue];
        printf("\n  %lu frames of a scrolling 1280x720 page, keyframe every %d (%d keyframes)\n\n",
               (unsigned long)[gUnits count], KEYFRAME_EVERY, keyframes);

        int dropAt = 10;
        double worstAll, worstOld, worstNew;
        int shownAll, shownOld, shownNew, frozenAll, frozenOld, frozenNew;

        run(DECODE_ALL, dropAt, &worstAll, &shownAll, &frozenAll);
        double after = 99; for (int i = dropAt + 1; i < KEYFRAME_EVERY; i++) if (gScore[i] >= 0 && gScore[i] < after) after = gScore[i];
        printf("  decode everything                      worst frame shown %5.1f dB, %3d shown, %2d not shown\n",
               worstAll, shownAll, frozenAll);

        run(DROP_AND_CARRY_ON, dropAt, &worstOld, &shownOld, &frozenOld);
        double oldAfter = 99; int oldBad = 0;
        for (int i = dropAt + 1; i < KEYFRAME_EVERY; i++) {
            if (gScore[i] < 0) continue;
            if (gScore[i] < oldAfter) oldAfter = gScore[i];
            if (gScore[i] < worstAll - 6) oldBad++;
        }
        double repaired = gScore[KEYFRAME_EVERY];
        printf("  drop frame %d, carry on (old)          worst frame shown %5.1f dB, %3d shown, %2d not shown\n",
               dropAt, worstOld, shownOld, frozenOld);
        printf("      %d frames shown visibly damaged, until the keyframe at %d repairs it (%.1f dB)\n",
               oldBad, KEYFRAME_EVERY, repaired);

        run(DROP_AND_RESYNC, dropAt, &worstNew, &shownNew, &frozenNew);
        printf("  drop frame %d, wait for a keyframe     worst frame shown %5.1f dB, %3d shown, %2d not shown\n\n",
               dropAt, worstNew, shownNew, frozenNew);

        int failures = 0;
        // Evaluated once. Some of these conditions pop the queue, and a macro
        // that evaluates its argument once to print and again to count turns
        // a passing check into a failure the moment the condition has effects.
        #define CHECK(cond, what) do { BOOL ok_ = (cond); \
            printf("  %s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) failures++; } while (0)
        CHECK(worstAll > 30, "decoding everything is clean -- the stream itself is fine");
        CHECK(oldBad >= 10,
              "dropping one frame and carrying on damages the frames after it (the moshing)");
        CHECK(worstNew >= worstAll - 1.0,
              "with the new queue, no damaged frame is ever put on screen");
        CHECK(frozenNew > 0 && frozenNew <= KEYFRAME_EVERY,
              "...which it pays for by holding the last good picture until the keyframe");
        printf("\n  the queue's rules on their own\n\n");
        {
            LSDecodeQueue *q = [[LSDecodeQueue alloc] initWithDepth:2];
            [q push:@1 isKeyframe:YES];
            [q pop];
            for (int i = 2; i < 50; i++) { [q push:@(i) isKeyframe:NO]; [q pop]; }
            CHECK([q dropped] == 0 && ![q waitingForKeyframe],
                  "a decoder that keeps up loses nothing");

            [q push:@50 isKeyframe:NO];
            [q push:@51 isKeyframe:NO];
            [q push:@52 isKeyframe:NO];            // no room
            CHECK([q waitingForKeyframe], "when it falls behind, it waits for a keyframe");
            CHECK([[q pop] isEqual:@50] && [[q pop] isEqual:@51] && [q pop] == nil,
                  "...keeping the frames already waiting, which still decode correctly, "
                  "and refusing the newest");

            [q push:@53 isKeyframe:NO];
            CHECK([q count] == 0, "a frame after the gap is refused");

            [q push:@54 isKeyframe:YES];
            CHECK(![q waitingForKeyframe] && [[q pop] isEqual:@54],
                  "a keyframe ends the wait");

            [q push:@55 isKeyframe:NO];
            [q push:@56 isKeyframe:YES];
            CHECK([[q pop] isEqual:@56] && [q pop] == nil,
                  "a keyframe overtakes older frames still waiting, which would only add delay");

            [q push:@57 isKeyframe:NO];
            [q decodeFailed];
            CHECK([q waitingForKeyframe] && [q count] == 0,
                  "a frame the decoder rejected is treated as a gap");
        }

        printf("\n%s\n", failures == 0 ? "RESULT: PASS" : "RESULT: FAIL");
        return failures == 0 ? 0 : 1;
    }
}
