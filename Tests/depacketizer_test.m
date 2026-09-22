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
//  Deterministic unit tests for LSDepacketizer: FU-A reassembly, AVCC framing,
//  sequence wraparound, and the loss-recovery state machine.
//
//  The loss path is the one worth testing hardest. It is rare on a direct
//  cable, impossible to trigger on demand, and if it is wrong the symptom is a
//  screen that stays broken -- exactly the failure you cannot debug from the
//  other room.
//
#import <Foundation/Foundation.h>
#import "LSDepacketizer.h"

static int gFailures = 0;

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        gFailures++; \
        printf("  FAIL %s:%d ", __FILE__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

// --------------------------------------------------------------- harness --

@interface Harness : NSObject <LSDepacketizerDelegate>
@property (nonatomic, strong) NSMutableArray *accessUnits;   // NSData, AVCC
@property (nonatomic, strong) NSData *lastSPS;
@property (nonatomic, strong) NSData *lastPPS;
@property (nonatomic, assign) NSUInteger keyframeRequests;
@end

@implementation Harness
- (id)init {
    self = [super init];
    if (self) _accessUnits = [[NSMutableArray alloc] init];
    return self;
}
- (void)depacketizer:(LSDepacketizer *)d
 didCompleteAccessUnit:(NSData *)avcc
                   sps:(NSData *)sps
                   pps:(NSData *)pps
             timestamp:(uint32_t)timestamp
            isKeyframe:(BOOL)isKeyframe {
    [_accessUnits addObject:avcc];
    _lastSPS = sps;
    _lastPPS = pps;
}
- (void)depacketizerNeedsKeyframe:(LSDepacketizer *)d { _keyframeRequests++; }
@end

// ------------------------------------------------------------- packet gen --

typedef struct {
    LSDepacketizer *depacketizer;
    uint16_t sequence;
    uint32_t ssrc;
    size_t mtuPayload;
    int dropIndex;      // -1 for none; otherwise the Nth emitted packet is dropped
    int emitted;
} Sender;

static void feed(Sender *sender, const uint8_t *packet, size_t length) {
    int index = sender->emitted++;
    if (index == sender->dropIndex) return;   // simulate the packet never arriving

    ls_rtp_packet parsed;
    if (ls_rtp_parse(packet, length, &parsed) != 0) {
        gFailures++;
        printf("  FAIL ls_rtp_parse rejected a packet we just wrote\n");
        return;
    }
    [sender->depacketizer handlePayload:(packet + parsed.payload_offset)
                                 length:parsed.payload_length
                                    rtp:&parsed];
}

/// Mirrors the host's RTPPacketizer: single NAL when it fits, FU-A otherwise.
static void sendNAL(Sender *sender, const uint8_t *nal, size_t length,
                    uint32_t timestamp, int marker) {
    uint8_t packet[LS_MAX_UDP_PAYLOAD];
    size_t maxPayload = sender->mtuPayload - LS_RTP_HEADER_SIZE;

    if (length <= maxPayload) {
        size_t header = ls_rtp_write_header(packet, sizeof(packet), marker,
                                            sender->sequence++, timestamp, sender->ssrc);
        memcpy(packet + header, nal, length);
        feed(sender, packet, header + length);
        return;
    }

    uint8_t nalHeader = nal[0];
    size_t offset = 1;
    size_t fragmentCapacity = maxPayload - 2;

    while (offset < length) {
        size_t remaining = length - offset;
        size_t chunk = remaining < fragmentCapacity ? remaining : fragmentCapacity;
        int isStart = (offset == 1);
        int isEnd = (chunk == remaining);

        size_t header = ls_rtp_write_header(packet, sizeof(packet),
                                            (marker && isEnd) ? 1 : 0,
                                            sender->sequence++, timestamp, sender->ssrc);
        size_t fu = ls_rtp_write_fu_a_prefix(packet + header, sizeof(packet) - header,
                                             nalHeader, isStart, isEnd);
        memcpy(packet + header + fu, nal + offset, chunk);
        feed(sender, packet, header + fu + chunk);
        offset += chunk;
    }
}

static NSData *makeNAL(uint8_t headerByte, size_t payloadLength, uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:payloadLength + 1];
    uint8_t *bytes = [data mutableBytes];
    bytes[0] = headerByte;
    for (size_t i = 0; i < payloadLength; i++) {
        bytes[i + 1] = (uint8_t)((i * 31 + seed) & 0xFF);
    }
    return data;
}

static NSData *avccWrap(NSData *nal) {
    NSMutableData *out = [NSMutableData data];
    uint32_t length = (uint32_t)[nal length];
    uint8_t prefix[4] = {
        (uint8_t)(length >> 24), (uint8_t)(length >> 16),
        (uint8_t)(length >> 8),  (uint8_t)length
    };
    [out appendBytes:prefix length:4];
    [out appendData:nal];
    return out;
}

// ------------------------------------------------------------------ tests --

static void testSingleAndFragmented(void) {
    printf("single NAL + FU-A reassembly\n");
    Harness *harness = [[Harness alloc] init];
    LSDepacketizer *depacketizer = [[LSDepacketizer alloc] init];
    depacketizer.delegate = harness;

    Sender sender = { depacketizer, 1000, 0xDEADBEEF, LS_DEFAULT_MTU_PAYLOAD, -1, 0 };

    NSData *sps = makeNAL(0x67, 20, 1);
    NSData *pps = makeNAL(0x68, 8, 2);
    NSData *idr = makeNAL(0x65, 9000, 3);     // forces FU-A across ~7 packets

    sendNAL(&sender, [sps bytes], [sps length], 90000, 0);
    sendNAL(&sender, [pps bytes], [pps length], 90000, 0);
    sendNAL(&sender, [idr bytes], [idr length], 90000, 1);

    CHECK([harness.accessUnits count] == 1, "expected 1 access unit, got %lu",
          (unsigned long)[harness.accessUnits count]);
    CHECK([harness.lastSPS isEqualToData:sps], "SPS did not survive the round trip");
    CHECK([harness.lastPPS isEqualToData:pps], "PPS did not survive the round trip");
    if ([harness.accessUnits count] == 1) {
        CHECK([harness.accessUnits[0] isEqualToData:avccWrap(idr)],
              "reassembled IDR does not match the original");
    }
    CHECK([depacketizer packetsLost] == 0, "phantom packet loss on a clean stream");

    // A small P frame in its own access unit.
    NSData *slice = makeNAL(0x41, 300, 4);
    sendNAL(&sender, [slice bytes], [slice length], 93000, 1);
    CHECK([harness.accessUnits count] == 2, "P frame was not delivered");
    if ([harness.accessUnits count] == 2) {
        CHECK([harness.accessUnits[1] isEqualToData:avccWrap(slice)],
              "P frame bytes do not match");
    }
}

static void testLossAndRecovery(void) {
    printf("packet loss, keyframe request, and resync\n");
    Harness *harness = [[Harness alloc] init];
    LSDepacketizer *depacketizer = [[LSDepacketizer alloc] init];
    depacketizer.delegate = harness;

    Sender sender = { depacketizer, 500, 0xCAFE, LS_DEFAULT_MTU_PAYLOAD, -1, 0 };

    NSData *sps = makeNAL(0x67, 20, 1);
    NSData *pps = makeNAL(0x68, 8, 2);
    NSData *idr = makeNAL(0x65, 4000, 3);

    sendNAL(&sender, [sps bytes], [sps length], 0, 0);
    sendNAL(&sender, [pps bytes], [pps length], 0, 0);
    sendNAL(&sender, [idr bytes], [idr length], 0, 1);
    CHECK([harness.accessUnits count] == 1, "setup: first IDR should have arrived");

    // Lose the second fragment of a large P frame.
    sender.dropIndex = sender.emitted + 1;
    NSData *bigSlice = makeNAL(0x41, 6000, 5);
    sendNAL(&sender, [bigSlice bytes], [bigSlice length], 3000, 1);

    CHECK([harness.accessUnits count] == 1, "a damaged frame was handed to the decoder");
    CHECK([depacketizer packetsLost] == 1, "expected 1 lost packet, got %u",
          [depacketizer packetsLost]);
    CHECK(harness.keyframeRequests >= 1, "no keyframe was requested after loss");

    // Intact P frames must still be withheld: they reference a picture the
    // decoder never received.
    sender.dropIndex = -1;
    NSUInteger requestsBefore = harness.keyframeRequests;
    NSData *nextSlice = makeNAL(0x41, 500, 6);
    sendNAL(&sender, [nextSlice bytes], [nextSlice length], 6000, 1);
    CHECK([harness.accessUnits count] == 1,
          "a P frame was delivered while still waiting for an IDR");

    // A fresh IDR clears the block.
    NSData *recoveryIDR = makeNAL(0x65, 3000, 7);
    sendNAL(&sender, [sps bytes], [sps length], 9000, 0);
    sendNAL(&sender, [pps bytes], [pps length], 9000, 0);
    sendNAL(&sender, [recoveryIDR bytes], [recoveryIDR length], 9000, 1);
    CHECK([harness.accessUnits count] == 2, "stream did not recover on the next IDR");
    if ([harness.accessUnits count] == 2) {
        CHECK([harness.accessUnits[1] isEqualToData:avccWrap(recoveryIDR)],
              "recovery IDR bytes do not match");
    }

    // And normal frames flow again afterwards.
    NSData *afterRecovery = makeNAL(0x41, 400, 8);
    sendNAL(&sender, [afterRecovery bytes], [afterRecovery length], 12000, 1);
    CHECK([harness.accessUnits count] == 3, "P frames did not resume after recovery");
    CHECK(harness.keyframeRequests == requestsBefore,
          "keyframe requests kept firing after recovery");
}

static void testSequenceWraparound(void) {
    printf("RTP sequence number wraparound\n");
    Harness *harness = [[Harness alloc] init];
    LSDepacketizer *depacketizer = [[LSDepacketizer alloc] init];
    depacketizer.delegate = harness;

    // Start just below the 16-bit rollover so the run crosses 65535 -> 0.
    Sender sender = { depacketizer, 65530, 0x1234, LS_DEFAULT_MTU_PAYLOAD, -1, 0 };

    NSData *sps = makeNAL(0x67, 20, 1);
    NSData *pps = makeNAL(0x68, 8, 2);
    sendNAL(&sender, [sps bytes], [sps length], 0, 0);
    sendNAL(&sender, [pps bytes], [pps length], 0, 0);

    for (int frame = 0; frame < 6; frame++) {
        NSData *nal = makeNAL(frame == 0 ? 0x65 : 0x41, 5000, (uint8_t)frame);
        sendNAL(&sender, [nal bytes], [nal length], (uint32_t)(frame * 3000), 1);
    }

    CHECK([harness.accessUnits count] == 6, "expected 6 frames across the wrap, got %lu",
          (unsigned long)[harness.accessUnits count]);
    CHECK([depacketizer packetsLost] == 0,
          "wraparound was mistaken for loss (%u packets)", [depacketizer packetsLost]);
    CHECK(harness.keyframeRequests == 0, "wraparound triggered a keyframe request");
}

static void testControlMessages(void) {
    printf("control message round trips\n");
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    ls_ctrl_message message;

    size_t n = ls_ctrl_build_hello(buffer, sizeof(buffer), 1920, 1200, 5000, 7);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "hello did not parse");
    CHECK(message.type == LS_MSG_HELLO && message.screen_width == 1920 &&
          message.screen_height == 1200 && message.video_port == 5000 &&
          message.flags == 7, "hello fields did not survive");

    n = ls_ctrl_build_ping(buffer, sizeof(buffer), 0x0123456789ABCDEFULL);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "ping did not parse");
    CHECK(message.token == 0x0123456789ABCDEFULL, "64-bit ping token was mangled");

    ls_stats stats;
    memset(&stats, 0, sizeof(stats));
    stats.frames_decoded = 123456; stats.packets_lost = 7; stats.decode_us = 2500;
    n = ls_ctrl_build_stats(buffer, sizeof(buffer), &stats);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "stats did not parse");
    CHECK(message.stats.frames_decoded == 123456 && message.stats.packets_lost == 7 &&
          message.stats.decode_us == 2500, "stats fields did not survive");

    // Junk must never be mistaken for a command.
    uint8_t junk[16];
    memset(junk, 0xAB, sizeof(junk));
    CHECK(ls_ctrl_parse(junk, sizeof(junk), &message) != 0, "junk was accepted as control");

    // A valid header with an unknown type must be rejected too.
    n = ls_ctrl_build_bye(buffer, sizeof(buffer));
    buffer[4] = 99;
    CHECK(ls_ctrl_parse(buffer, n, &message) != 0, "unknown message type was accepted");
}

int main(void) {
    @autoreleasepool {
        testSingleAndFragmented();
        testLossAndRecovery();
        testSequenceWraparound();
        testControlMessages();

        if (gFailures == 0) {
            printf("\nAll depacketizer tests passed.\n");
            return 0;
        }
        printf("\n%d check(s) failed.\n", gFailures);
        return 1;
    }
}
