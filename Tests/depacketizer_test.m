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
#import "LSAudioPlayer.h"

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
    /// Set before a sendNAL call to lose that NAL's final packet -- the one
    /// carrying the marker bit. Computing the index by hand is easy to get
    /// wrong, and getting it wrong silently tests the opposite case.
    int dropLastPacketOfNextNAL;
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

    if (sender->dropLastPacketOfNextNAL) {
        sender->dropLastPacketOfNextNAL = 0;
        size_t packets;
        if (length <= maxPayload) {
            packets = 1;
        } else {
            size_t capacity = maxPayload - 2;
            packets = ((length - 1) + capacity - 1) / capacity;
        }
        sender->dropIndex = sender->emitted + (int)packets - 1;
    }

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

    Sender sender = { depacketizer, 1000, 0xDEADBEEF, LS_DEFAULT_MTU_PAYLOAD, -1, 0, 0 };

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

    Sender sender = { depacketizer, 500, 0xCAFE, LS_DEFAULT_MTU_PAYLOAD, -1, 0, 0 };

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

static void testStalledPartialFrame(void) {
    printf("a frame that never finishes arriving is detectable\n");
    Harness *harness = [[Harness alloc] init];
    LSDepacketizer *depacketizer = [[LSDepacketizer alloc] init];
    depacketizer.delegate = harness;

    Sender sender = { depacketizer, 90, 0xFEED, LS_DEFAULT_MTU_PAYLOAD, -1, 0, 0 };
    NSData *sps = makeNAL(0x67, 20, 1);
    NSData *pps = makeNAL(0x68, 8, 2);
    NSData *idr = makeNAL(0x65, 3000, 3);

    CHECK([depacketizer partialFrameStartedAt] == 0,
          "nothing has arrived yet, so no frame should be part-built");

    sendNAL(&sender, [sps bytes], [sps length], 0, 0);
    sendNAL(&sender, [pps bytes], [pps length], 0, 0);
    sendNAL(&sender, [idr bytes], [idr length], 0, 1);
    CHECK([harness.accessUnits count] == 1, "setup: the IDR should have arrived");
    CHECK([depacketizer partialFrameStartedAt] == 0,
          "a completed frame should leave nothing part-built");

    // A frame whose final packet never turns up: no marker bit, and nothing
    // follows it. This is the case the stall check exists for -- there is no
    // later packet to expose the gap, so without a timer nobody ever notices.
    NSData *tail = makeNAL(0x41, 6000, 4);
    sender.dropLastPacketOfNextNAL = 1;
    sendNAL(&sender, [tail bytes], [tail length], 3000, 1);

    CHECK([harness.accessUnits count] == 1, "the truncated frame must not be delivered");
    CHECK([depacketizer partialFrameStartedAt] > 0,
          "a part-built frame should report when assembly started");

    // Recovery: a fresh IDR arrives and the part-built frame is abandoned.
    sender.dropIndex = -1;
    NSData *recovery = makeNAL(0x65, 2000, 5);
    sendNAL(&sender, [sps bytes], [sps length], 6000, 0);
    sendNAL(&sender, [pps bytes], [pps length], 6000, 0);
    sendNAL(&sender, [recovery bytes], [recovery length], 6000, 1);
    CHECK([harness.accessUnits count] == 2, "the stream should recover on the next IDR");
    CHECK([depacketizer partialFrameStartedAt] == 0,
          "recovery should clear the part-built frame");
}

static void testSequenceWraparound(void) {
    printf("RTP sequence number wraparound\n");
    Harness *harness = [[Harness alloc] init];
    LSDepacketizer *depacketizer = [[LSDepacketizer alloc] init];
    depacketizer.delegate = harness;

    // Start just below the 16-bit rollover so the run crosses 65535 -> 0.
    Sender sender = { depacketizer, 65530, 0x1234, LS_DEFAULT_MTU_PAYLOAD, -1, 0, 0 };

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

static void testCursorMessages(void) {
    printf("cursor position and bitmap messages\n");
    uint8_t small[LS_CTRL_MAX_SIZE];
    ls_ctrl_message message;

    size_t n = ls_ctrl_build_cursor(small, sizeof(small), 1234, 567, 1, 42);
    CHECK(n > 0 && ls_ctrl_parse(small, n, &message) == 0, "cursor position did not parse");
    CHECK(message.type == LS_MSG_CURSOR && message.cursor_x == 1234 &&
          message.cursor_y == 567 && message.cursor_visible == 1 &&
          message.cursor_image_id == 42, "cursor position fields did not survive");

    n = ls_ctrl_build_cursor(small, sizeof(small), 0, 0, 0, 0);
    CHECK(n > 0 && ls_ctrl_parse(small, n, &message) == 0, "hidden cursor did not parse");
    CHECK(message.cursor_visible == 0, "a hidden cursor came back visible");

    // A bitmap, which is far larger than the small-message buffer.
    const uint16_t w = 24, h = 24;
    const uint32_t bytes = (uint32_t)w * h * 4;
    uint8_t *rgba = malloc(bytes);
    for (uint32_t i = 0; i < bytes; i++) rgba[i] = (uint8_t)(i * 7);

    uint8_t *packet = malloc(LS_CTRL_MAX_PACKET);
    n = ls_ctrl_build_cursor_image(packet, LS_CTRL_MAX_PACKET, 42, w, h, 5, 6, rgba, bytes);
    CHECK(n > 0, "cursor bitmap would not build");
    CHECK(ls_ctrl_parse(packet, n, &message) == 0, "cursor bitmap did not parse");
    CHECK(message.image_width == w && message.image_height == h &&
          message.hotspot_x == 5 && message.hotspot_y == 6 &&
          message.cursor_image_id == 42, "bitmap header fields did not survive");
    CHECK(message.image_length == bytes, "bitmap length wrong: %u vs %u",
          message.image_length, bytes);
    CHECK(memcmp(packet + message.image_offset, rgba, bytes) == 0,
          "bitmap pixels did not survive the round trip");

    // Refusals. A bitmap whose declared size disagrees with the bytes present
    // would otherwise be read past its end.
    CHECK(ls_ctrl_build_cursor_image(packet, LS_CTRL_MAX_PACKET, 1, w, h, 0, 0, rgba, bytes - 4) == 0,
          "a bitmap with a mismatched length was accepted");
    CHECK(ls_ctrl_build_cursor_image(packet, LS_CTRL_MAX_PACKET, 1, 0, h, 0, 0, rgba, bytes) == 0,
          "a zero-width bitmap was accepted");
    CHECK(ls_ctrl_build_cursor_image(packet, LS_CTRL_MAX_PACKET, 1, 200, 200, 0, 0, rgba, 160000) == 0,
          "an oversized bitmap was accepted");
    CHECK(ls_ctrl_build_cursor_image(packet, 40, 1, w, h, 0, 0, rgba, bytes) == 0,
          "a bitmap was written into a buffer too small for it");

    // Truncated on the wire: header says 24x24 but the bytes are not there.
    n = ls_ctrl_build_cursor_image(packet, LS_CTRL_MAX_PACKET, 42, w, h, 5, 6, rgba, bytes);
    CHECK(ls_ctrl_parse(packet, n - 100, &message) != 0,
          "a truncated bitmap packet was accepted");

    free(rgba);
    free(packet);
}

static void testWakeOnLAN(void) {
    printf("Wake-on-LAN magic packet and MAC parsing\n");

    uint8_t mac[6] = {0xC4, 0x2C, 0x03, 0x07, 0x35, 0x10};
    uint8_t packet[LS_WOL_PACKET_SIZE];

    size_t n = ls_wol_build_magic_packet(packet, sizeof(packet), mac);
    CHECK(n == LS_WOL_PACKET_SIZE, "magic packet should be 102 bytes, got %lu",
          (unsigned long)n);

    // Six 0xFF sync bytes, then the MAC sixteen times. A NIC in sleep scans for
    // exactly this byte pattern, so any deviation means it simply will not wake.
    int i;
    for (i = 0; i < 6; i++) {
        CHECK(packet[i] == 0xFF, "sync byte %d should be 0xFF, got 0x%02X", i, packet[i]);
    }
    for (i = 0; i < 16; i++) {
        CHECK(memcmp(packet + 6 + i * 6, mac, 6) == 0,
              "MAC repetition %d does not match", i);
    }
    CHECK(ls_wol_build_magic_packet(packet, 10, mac) == 0,
          "should refuse to write into a buffer that is too small");
    CHECK(ls_wol_build_magic_packet(packet, sizeof(packet), NULL) == 0,
          "should refuse a NULL MAC");

    // Parsing, including the single-digit octets that `arp` prints.
    uint8_t parsed[6];
    CHECK(ls_parse_mac("c4:2c:03:07:35:10", parsed) == 0 &&
          memcmp(parsed, mac, 6) == 0, "colon-separated MAC did not parse");
    CHECK(ls_parse_mac("c4:2c:3:7:35:10", parsed) == 0 &&
          memcmp(parsed, mac, 6) == 0, "arp-style short octets did not parse");
    CHECK(ls_parse_mac("C4-2C-03-07-35-10", parsed) == 0 &&
          memcmp(parsed, mac, 6) == 0, "dash-separated uppercase MAC did not parse");

    CHECK(ls_parse_mac("not a mac", parsed) != 0, "garbage was accepted as a MAC");
    CHECK(ls_parse_mac("c4:2c:03:07:35", parsed) != 0, "five octets were accepted");
    CHECK(ls_parse_mac("c4:2c:03:07:35:10:99", parsed) != 0, "seven octets were accepted");
    CHECK(ls_parse_mac("", parsed) != 0, "empty string was accepted");

    char text[18];
    CHECK(ls_format_mac(text, sizeof(text), mac) == 17 &&
          strcmp(text, "c4:2c:03:07:35:10") == 0,
          "formatting produced '%s'", text);
    CHECK(ls_format_mac(text, 4, mac) == 0, "should refuse a buffer that is too small");
}

static void testControlMessages(void) {
    printf("control message round trips\n");
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    ls_ctrl_message message;

    size_t n = ls_ctrl_build_hello(buffer, sizeof(buffer), 1920, 1200, 5000, 7, NULL);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "hello did not parse");
    CHECK(message.type == LS_MSG_HELLO && message.screen_width == 1920 &&
          message.screen_height == 1200 && message.video_port == 5000 &&
          message.flags == 7, "hello fields did not survive");
    CHECK(message.has_mac == 0, "a hello without a MAC claimed to have one");

    // With a MAC, and the older fields must still land in the same places.
    uint8_t mac[6] = {0xC4, 0x2C, 0x03, 0x07, 0x35, 0x10};
    n = ls_ctrl_build_hello(buffer, sizeof(buffer), 1920, 1200, 5000, 7, mac);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "hello with MAC did not parse");
    CHECK(message.screen_width == 1920 && message.video_port == 5000,
          "adding a MAC disturbed the earlier hello fields");
    CHECK(message.has_mac == 1 && memcmp(message.mac, mac, 6) == 0,
          "MAC did not survive the round trip");

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

static void testVolumeMessages(void) {
    printf("volume messages\n");
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    ls_ctrl_message message;

    size_t n = ls_ctrl_build_volume(buffer, sizeof(buffer), 640);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "volume did not parse");
    CHECK(message.type == LS_MSG_VOLUME && message.volume == 640, "volume round trip wrong");

    // The extremes have to survive: silence is a legitimate setting.
    n = ls_ctrl_build_volume(buffer, sizeof(buffer), 0);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 && message.volume == 0,
          "silence did not round trip");
    n = ls_ctrl_build_volume(buffer, sizeof(buffer), LS_VOLUME_SCALE);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 &&
          message.volume == LS_VOLUME_SCALE, "unity did not round trip");

    // Asking for more than unity is clamped when building...
    n = ls_ctrl_build_volume(buffer, sizeof(buffer), 60000);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 &&
          message.volume == LS_VOLUME_SCALE, "over-unity was not clamped");

    // ...and rejected when it arrives from somewhere else, so a corrupt packet
    // cannot turn into an amplifier.
    n = ls_ctrl_build_volume(buffer, sizeof(buffer), 500);
    buffer[8] = 0xFF;   /* rewrite the volume field past unity */
    buffer[9] = 0xFF;
    CHECK(ls_ctrl_parse(buffer, n, &message) != 0, "an over-unity packet was accepted");
}

static void testAudioPackets(void) {
    printf("audio packets\n");
    uint8_t packet[LS_AUDIO_MAX_PACKET];
    ls_audio_packet parsed;

    const int frames = LS_AUDIO_FRAMES_PER_PACKET;
    size_t header = ls_audio_write_header(packet, sizeof(packet), 7, 4096,
                                          LS_AUDIO_SAMPLE_RATE, LS_AUDIO_CHANNELS,
                                          LS_AUDIO_FORMAT_S16LE);
    CHECK(header == LS_AUDIO_HEADER_SIZE, "audio header size wrong");

    // A recognisable ramp, so a byte-order mistake cannot pass unnoticed.
    int16_t *samples = (int16_t *)(packet + header);
    for (int i = 0; i < frames * LS_AUDIO_CHANNELS; i++) samples[i] = (int16_t)(i - 300);
    size_t total = header + (size_t)frames * LS_AUDIO_CHANNELS * 2;

    CHECK(ls_audio_parse(packet, total, &parsed) == 0, "audio packet did not parse");
    CHECK(parsed.sequence == 7 && parsed.timestamp == 4096, "audio header round trip wrong");
    CHECK(parsed.sample_rate == LS_AUDIO_SAMPLE_RATE && parsed.channels == LS_AUDIO_CHANNELS,
          "audio format round trip wrong");
    CHECK(parsed.payload_length == frames * LS_AUDIO_CHANNELS * 2, "audio payload length wrong");

    const int16_t *back = (const int16_t *)(packet + parsed.payload_offset);
    int intact = 1;
    for (int i = 0; i < frames * LS_AUDIO_CHANNELS; i++) {
        if (back[i] != (int16_t)(i - 300)) { intact = 0; break; }
    }
    CHECK(intact, "audio samples did not survive the round trip");

    // Anything that is not ours, or is malformed, must be refused rather than
    // played: a wrong frame boundary desynchronises the channels permanently.
    CHECK(ls_audio_parse(packet, LS_AUDIO_HEADER_SIZE - 1, &parsed) != 0,
          "a truncated audio header was accepted");
    CHECK(ls_audio_parse(packet, header + 3, &parsed) != 0,
          "a partial frame was accepted");

    uint8_t stray[LS_AUDIO_MAX_PACKET];
    memcpy(stray, packet, total);
    stray[0] ^= 0xFF;
    CHECK(ls_audio_parse(stray, total, &parsed) != 0, "a foreign packet was accepted");

    memcpy(stray, packet, total);
    stray[17] = 99;                       /* unknown sample format */
    CHECK(ls_audio_parse(stray, total, &parsed) != 0, "an unknown sample format was accepted");

    memcpy(stray, packet, total);
    stray[16] = 0;                        /* zero channels */
    CHECK(ls_audio_parse(stray, total, &parsed) != 0, "zero channels was accepted");

    // An empty packet is well formed: it means "no samples", not a broken one.
    CHECK(ls_audio_parse(packet, header, &parsed) == 0 && parsed.payload_length == 0,
          "an empty audio packet should be valid");
}

static void testAudioRing(void) {
    printf("audio ring buffer and delay line\n");
    // 48 kHz stereo, so one millisecond is 96 samples.
    LSAudioPlayer *player = [[LSAudioPlayer alloc] initWithSampleRate:48000 channels:2];
    [player setTargetBufferMilliseconds:0];

    int16_t out[8192];
    // Nothing has arrived, so a drain must produce silence rather than noise
    // and must not claim to have played anything.
    memset(out, 0xAB, sizeof(out));
    [player drainInto:out samples:256];
    int silent = 1;
    for (int i = 0; i < 256; i++) if (out[i] != 0) { silent = 0; break; }
    CHECK(silent, "an empty ring did not produce silence");
    CHECK([player framesPlayed] == 0, "an empty ring claimed to have played frames");

    // With no delay asked for, audio is playable the moment it lands.
    int16_t ramp[8192];
    for (int i = 0; i < 8192; i++) ramp[i] = (int16_t)(i + 1);
    [player enqueueSamples:ramp frames:128];       // 256 samples
    [player drainInto:out samples:256];
    int ordered = 1;
    for (int i = 0; i < 256; i++) if (out[i] != ramp[i]) { ordered = 0; break; }
    CHECK(ordered, "with no delay the ring did not return what went in, in order");

    // The delay line proper: with a 10 ms target (960 samples) exactly that
    // much must stay behind, and only what is in excess of it comes out.
    LSAudioPlayer *delayed = [[LSAudioPlayer alloc] initWithSampleRate:48000 channels:2];
    [delayed setTargetBufferMilliseconds:10];
    CHECK([delayed targetBufferMilliseconds] > 9.9 && [delayed targetBufferMilliseconds] < 10.1,
          "the target was not what was asked for");

    [delayed enqueueSamples:ramp frames:480];      // exactly 960 samples = 10 ms
    memset(out, 0xAB, sizeof(out));
    [delayed drainInto:out samples:256];
    silent = 1;
    for (int i = 0; i < 256; i++) if (out[i] != 0) { silent = 0; break; }
    CHECK(silent, "the delay line played audio it was supposed to be holding");

    // One millisecond more, and exactly one millisecond becomes playable.
    [delayed enqueueSamples:ramp + 960 frames:48]; // 96 samples
    memset(out, 0xAB, sizeof(out));
    [delayed drainInto:out samples:256];
    int playedCount = 0;
    for (int i = 0; i < 256; i++) if (out[i] != 0) playedCount++;
    CHECK(playedCount == 96, "the delay line released %d samples, not 96", playedCount);
    // And what came out is the OLDEST audio, not the newest: a delay line is
    // first in, first out, otherwise it is just a reordering bug.
    CHECK(out[0] == ramp[0], "the delay line released the newest audio first");

    // Overrun: push far more than the ring holds and the oldest audio is what
    // goes, because what has just arrived is what the screen is showing now.
    LSAudioPlayer *small = [[LSAudioPlayer alloc] initWithSampleRate:48000 channels:2];
    [small setTargetBufferMilliseconds:0];
    // Each block is stamped with its round number. Kept small deliberately:
    // these are int16 samples, and a marker that overflows wraps negative and
    // makes a late round look like an early one, which is how the first
    // version of this check failed against correct code.
    for (int round = 0; round < 40; round++) {
        int16_t block[2048];
        for (int i = 0; i < 2048; i++) block[i] = (int16_t)(round * 500 + 1);
        [small enqueueSamples:block frames:1024];
    }
    CHECK([small overruns] > 0, "overflowing the ring did not count an overrun");
    [small drainInto:out samples:64];
    CHECK(out[0] != 0, "after an overrun the ring returned silence");
    // The ring holds 400 ms of a stream far longer than that, so what survives
    // must come from the later rounds -- anything under round ten would mean
    // the newest audio was the part thrown away.
    CHECK(out[0] > 5000, "an overrun dropped the newest audio instead of the oldest (%d)",
          (int)out[0]);

    // Underrun: keep draining past what is there and the shortfall is silence.
    uint32_t before = [player underruns];
    [player drainInto:out samples:4096];
    CHECK([player underruns] == before + 1, "running dry did not count an underrun");
    int tailSilent = 1;
    for (int i = 0; i < 4096; i++) if (out[i] != 0) { tailSilent = 0; break; }
    CHECK(tailSilent, "the shortfall was not padded with silence");
}

static void testAudioDelayAndBrightness(void) {
    printf("audio delay and brightness messages\n");
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    ls_ctrl_message message;

    // Negative is the direction that matters here, so it is the first thing
    // checked: a signed value travelling through an unsigned field is exactly
    // the sort of thing that works for positive numbers and silently does not
    // for negative ones.
    size_t n = ls_ctrl_build_audio_delay(buffer, sizeof(buffer), -40);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "negative delay did not parse");
    CHECK(message.type == LS_MSG_AUDIO_DELAY && message.audio_delay_ms == -40,
          "negative delay did not round trip");

    n = ls_ctrl_build_audio_delay(buffer, sizeof(buffer), 0);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 && message.audio_delay_ms == 0,
          "zero delay did not round trip");

    n = ls_ctrl_build_audio_delay(buffer, sizeof(buffer), 175);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 && message.audio_delay_ms == 175,
          "positive delay did not round trip");

    // Both ends of the range clamp when built.
    n = ls_ctrl_build_audio_delay(buffer, sizeof(buffer), -3000);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 &&
          message.audio_delay_ms == LS_AUDIO_DELAY_MIN_MS, "delay did not clamp low");
    n = ls_ctrl_build_audio_delay(buffer, sizeof(buffer), 3000);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 &&
          message.audio_delay_ms == LS_AUDIO_DELAY_MAX_MS, "delay did not clamp high");

    // And an out-of-range value arriving from elsewhere is refused rather than
    // clamped: nothing we build can produce it, so it is a corrupt packet.
    n = ls_ctrl_build_audio_delay(buffer, sizeof(buffer), 100);
    buffer[8] = 0x7F; buffer[9] = 0xFF;      /* 32767 ms */
    CHECK(ls_ctrl_parse(buffer, n, &message) != 0, "an absurd delay was accepted");

    printf("brightness\n");
    n = ls_ctrl_build_brightness(buffer, sizeof(buffer), 250);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0, "brightness did not parse");
    CHECK(message.type == LS_MSG_BRIGHTNESS && message.brightness == 250,
          "brightness did not round trip");
    n = ls_ctrl_build_brightness(buffer, sizeof(buffer), 0);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 && message.brightness == 0,
          "a dark screen did not round trip");
    n = ls_ctrl_build_brightness(buffer, sizeof(buffer), 9000);
    CHECK(n > 0 && ls_ctrl_parse(buffer, n, &message) == 0 &&
          message.brightness == LS_BRIGHTNESS_SCALE, "brightness did not clamp");
    n = ls_ctrl_build_brightness(buffer, sizeof(buffer), 500);
    buffer[8] = 0xFF; buffer[9] = 0xFF;
    CHECK(ls_ctrl_parse(buffer, n, &message) != 0, "an over-range brightness was accepted");
}

int main(void) {
    @autoreleasepool {
        testSingleAndFragmented();
        testLossAndRecovery();
        testSequenceWraparound();
        testStalledPartialFrame();
        testControlMessages();
        testWakeOnLAN();
        testCursorMessages();
        testVolumeMessages();
        testAudioPackets();
        testAudioRing();
        testAudioDelayAndBrightness();

        if (gFailures == 0) {
            printf("\nAll depacketizer tests passed.\n");
            return 0;
        }
        printf("\n%d check(s) failed.\n", gFailures);
        return 1;
    }
}
