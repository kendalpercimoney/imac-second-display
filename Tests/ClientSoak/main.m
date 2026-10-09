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
//  Runs the client's receive path for as many frames as it would see in half a
//  day, as fast as it will go, and watches its own resident memory.
//
//  The iMac freezes after about twelve hours. That is 2.6 million frames and
//  something over 50 million packets, which is far too long to sit and watch,
//  and far too long for a leak to need to be large: a hundred bytes a frame is
//  a quarter of a gigabyte by then. Pushing the same number of frames through
//  in minutes finds anything that accumulates per frame or per packet.
//
//  Also walks the RTP timestamp through its 32-bit wrap, which happens every
//  13.25 hours at 90 kHz and is the first thing that fits the symptom's clock.
//
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import "LSDepacketizer.h"
#import "rtp_protocol.h"

static size_t residentBytes(void) {
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (size_t)info.resident_size;
}

@interface Sink : NSObject <LSDepacketizerDelegate>
@property (nonatomic) uint64_t units;
@property (nonatomic) uint64_t keyframeRequests;
@end

@implementation Sink
- (void)depacketizer:(LSDepacketizer *)d
 didCompleteAccessUnit:(NSData *)avcc
                   sps:(NSData *)sps
                   pps:(NSData *)pps
             timestamp:(uint32_t)timestamp
            isKeyframe:(BOOL)isKeyframe
{
    _units++;
}
- (void)depacketizerNeedsKeyframe:(LSDepacketizer *)d { _keyframeRequests++; }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        // Frames to push. Twelve hours at 60 fps is 2,592,000.
        uint64_t frames = argc > 1 ? strtoull(argv[1], NULL, 10) : 2592000;
        // Where to start the RTP timestamp, so the wrap can be aimed at. The
        // default starts far enough back that the run crosses it.
        uint32_t timestamp = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 10)
                                      : (uint32_t)(0xFFFFFFFFu - 60u * 1500u);

        LSDepacketizer *dp = [[LSDepacketizer alloc] init];
        Sink *sink = [[Sink alloc] init];
        dp.delegate = sink;

        // A frame's worth of slices, sized so each one fragments the way a real
        // one does on a 1500 B link.
        const size_t payloadMax = 1400;
        static uint8_t nal[24000];
        for (size_t i = 0; i < sizeof(nal); i++) nal[i] = (uint8_t)(i * 7 + 13);

        uint16_t sequence = 0;
        uint32_t ssrc = 0x1234abcd;
        static uint8_t packet[1500];
        size_t baseline = 0;
        uint64_t wrapsSeen = 0;
        uint32_t previousTimestamp = timestamp;

        NSDate *started = [NSDate date];
        for (uint64_t f = 0; f < frames; f++) {
            @autoreleasepool {
                // One IDR every 300 frames, the rest non-IDR, matching a
                // five-second keyframe interval at 60 fps.
                BOOL keyframe = (f % 300) == 0;
                nal[0] = keyframe ? 0x65 : 0x41;

                // Parameter sets lead every keyframe, as single-NAL packets,
                // exactly as the host emits them. Without them the depacketizer
                // has no format description and discards every frame -- which
                // is what the first version of this harness did, and it looked
                // like the client was broken rather than the test.
                if (keyframe) {
                    static const uint8_t sps[] = { 0x67, 0x42, 0x00, 0x1f, 0xac, 0xd9 };
                    static const uint8_t pps[] = { 0x68, 0xce, 0x3c, 0x80 };
                    const uint8_t *sets[2] = { sps, pps };
                    size_t sizes[2] = { sizeof(sps), sizeof(pps) };
                    for (int k = 0; k < 2; k++) {
                        size_t header = ls_rtp_write_header(packet, sizeof(packet), 0,
                                                            sequence++, timestamp, ssrc);
                        memcpy(packet + header, sets[k], sizes[k]);
                        ls_rtp_packet parsed;
                        if (ls_rtp_parse(packet, header + sizes[k], &parsed) == 0) {
                            [dp handlePayload:packet + parsed.payload_offset
                                       length:parsed.payload_length
                                          rtp:&parsed];
                        }
                    }
                }

                size_t length = keyframe ? 22000 : 9000;
                // FU-A fragments, exactly as the host emits them.
                size_t offset = 1;
                uint8_t nalHeader = nal[0];
                while (offset < length) {
                    size_t capacity = payloadMax - (size_t)LS_RTP_HEADER_SIZE - 2;
                    size_t remaining = length - offset;
                    size_t chunk = remaining < capacity ? remaining : capacity;
                    BOOL isEnd = (chunk == remaining);
                    size_t header = ls_rtp_write_header(packet, sizeof(packet),
                                                        isEnd ? 1 : 0, sequence++,
                                                        timestamp, ssrc);
                    size_t fu = ls_rtp_write_fu_a_prefix(packet + header,
                                                         sizeof(packet) - header,
                                                         nalHeader,
                                                         offset == 1 ? 1 : 0,
                                                         isEnd ? 1 : 0);
                    memcpy(packet + header + fu, nal + offset, chunk);

                    ls_rtp_packet parsed;
                    if (ls_rtp_parse(packet, header + fu + chunk, &parsed) == 0) {
                        [dp handlePayload:packet + parsed.payload_offset
                                   length:parsed.payload_length
                                      rtp:&parsed];
                    }
                    offset += chunk;
                }

                previousTimestamp = timestamp;
                timestamp += 1500;               // 90000 / 60
                if (timestamp < previousTimestamp) wrapsSeen++;
            }

            if (f == 20000) baseline = residentBytes();
            if (f > 20000 && (f % 200000) == 0) {
                size_t now = residentBytes();
                double grownKB = ((double)now - (double)baseline) / 1024.0;
                printf("  %8llu frames   rss %6.1f MB   grown %+8.1f KB   "
                       "%+.4f bytes/frame   units %llu  wraps %llu\n",
                       f, (double)now / 1048576.0, grownKB,
                       ((double)now - (double)baseline) / (double)(f - 20000),
                       sink.units, wrapsSeen);
                fflush(stdout);
            }
        }

        size_t final = residentBytes();
        double perFrame = baseline ? ((double)final - (double)baseline)
                                   / (double)(frames - 20000) : 0;
        printf("\n  %llu frames in %.1fs, %llu access units, %llu keyframe requests, "
               "%llu timestamp wraps\n", frames,
               -[started timeIntervalSinceNow], sink.units,
               sink.keyframeRequests, wrapsSeen);
        printf("  rss %.1f MB -> %.1f MB   %+.4f bytes per frame\n",
               (double)baseline / 1048576.0, (double)final / 1048576.0, perFrame);

        // A quarter of a kilobyte per frame is 650 MB over twelve hours. Ten
        // bytes is 26 MB, which is noise on any machine. The line between them
        // is generous on purpose: this is looking for a leak, not for jitter in
        // the allocator's high-water mark.
        BOOL leaking = perFrame > 32.0;
        BOOL sawWrap = wrapsSeen > 0;
        BOOL producedFrames = sink.units > frames / 2;
        printf("\n  %s no per-frame growth\n", leaking ? "FAIL" : "ok  ");
        printf("  %s the run crossed the RTP timestamp wrap\n", sawWrap ? "ok  " : "FAIL");
        printf("  %s frames kept being produced across it\n",
               producedFrames ? "ok  " : "FAIL");
        BOOL ok = !leaking && sawWrap && producedFrames;
        printf("\nRESULT: %s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
