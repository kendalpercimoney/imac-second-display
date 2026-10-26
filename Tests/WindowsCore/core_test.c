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

// The Windows client's portable core -- packet reassembly and the decode
// queue -- checked here, on the Mac, where it is easy to run. These are the
// same rules the macOS client is held to, written against the C port.

#include "ls_depacketizer.h"
#include "ls_decode_queue.h"
#include "rtp_protocol.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, what) do { int ok_ = (cond); \
    printf("  %s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) failures++; } while (0)

// ---- a tiny RTP sender, building packets the way the host does ---------

typedef struct {
    int units, keyframes, keyframe_requests;
    uint8_t last[1 << 20]; size_t last_length; int last_keyframe;
} Sink;

static void on_unit(void *ctx, const uint8_t *data, size_t length, uint32_t ts, int keyframe) {
    Sink *s = (Sink *)ctx;
    (void)ts;
    s->units++;
    s->keyframes += keyframe;
    if (length <= sizeof(s->last)) { memcpy(s->last, data, length); s->last_length = length; }
    s->last_keyframe = keyframe;
}
static void on_need(void *ctx) { ((Sink *)ctx)->keyframe_requests++; }

static uint16_t g_seq = 1000;
static uint64_t g_now = 1;

static void feed(ls_depacketizer *dp, const uint8_t *payload, size_t length, uint32_t ts, int marker) {
    uint8_t packet[2048];
    size_t h = ls_rtp_write_header(packet, sizeof(packet), marker, g_seq++, ts, 0x1234);
    memcpy(packet + h, payload, length);
    ls_rtp_packet parsed;
    if (ls_rtp_parse(packet, h + length, &parsed) == 0) {
        ls_depacketizer_handle(dp, packet + parsed.payload_offset, parsed.payload_length, &parsed, g_now++);
    }
}

/* A NAL of `length` bytes whose header byte is `header`, sent as FU-A
 * fragments of at most 1000 bytes, the last one carrying the marker if asked. */
static void feed_nal(ls_depacketizer *dp, uint8_t header, size_t length, uint32_t ts, int marker,
                     int drop_fragment) {
    static uint8_t nal[100000];
    nal[0] = header;
    for (size_t i = 1; i < length; i++) nal[i] = (uint8_t)(i * 7 + 3);
    if (length <= 1000) { feed(dp, nal, length, ts, marker); return; }
    size_t offset = 1; int index = 0;
    while (offset < length) {
        size_t chunk = length - offset < 1000 ? length - offset : 1000;
        int end = offset + chunk == length;
        uint8_t payload[1100];
        size_t p = ls_rtp_write_fu_a_prefix(payload, sizeof(payload), header, offset == 1, end);
        memcpy(payload + p, nal + offset, chunk);
        if (index != drop_fragment) feed(dp, payload, p + chunk, ts, marker && end);
        else g_seq++;                                  // a packet lost on the wire
        offset += chunk; index++;
    }
}

static const uint8_t kSPS[] = {0x67, 0x42, 0x00, 0x2a, 0xab, 0x40};
static const uint8_t kPPS[] = {0x68, 0xce, 0x3c, 0x80};

static void send_keyframe(ls_depacketizer *dp, uint32_t ts, int drop) {
    feed(dp, kSPS, sizeof(kSPS), ts, 0);
    feed(dp, kPPS, sizeof(kPPS), ts, 0);
    feed_nal(dp, 0x65, 9000, ts, 1, drop);
}

static int starts_with_nal(const uint8_t *data, size_t length, uint8_t type) {
    return length >= 5 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1
        && (data[4] & 0x1F) == type;
}

static void test_depacketizer(void) {
    printf("\n==> reassembly\n");
    Sink s; memset(&s, 0, sizeof(s));
    ls_depacketizer dp;
    ls_depacketizer_init(&dp, on_unit, on_need, &s);

    feed_nal(&dp, 0x41, 3000, 100, 1, -1);
    CHECK(s.units == 0, "nothing comes out before the first keyframe");

    send_keyframe(&dp, 200, -1);
    CHECK(s.units == 1 && s.last_keyframe, "a keyframe comes out whole");
    CHECK(starts_with_nal(s.last, s.last_length, 7), "...as Annex B, starting with the SPS");
    // SPS, PPS and IDR each behind their own start code.
    size_t at = 4 + sizeof(kSPS);
    CHECK(starts_with_nal(s.last + at, s.last_length - at, 8), "...then the PPS");
    at += 4 + sizeof(kPPS);
    CHECK(starts_with_nal(s.last + at, s.last_length - at, 5), "...then the picture itself");
    CHECK(s.last_length == 4 + sizeof(kSPS) + 4 + sizeof(kPPS) + 4 + 9000,
          "...and nothing is lost or added in reassembling its fragments");

    feed_nal(&dp, 0x41, 2500, 300, 1, -1);
    CHECK(s.units == 2 && !s.last_keyframe && starts_with_nal(s.last, s.last_length, 1),
          "a following frame comes out, without parameter sets in front");

    printf("\n==> loss\n");
    int requests = s.keyframe_requests;
    feed_nal(&dp, 0x41, 5000, 400, 1, 2);              // a fragment goes missing
    CHECK(s.units == 2, "a frame with a lost fragment is not passed on");
    CHECK(s.keyframe_requests == requests + 1, "...and a keyframe is asked for, once");
    feed_nal(&dp, 0x41, 2500, 500, 1, -1);
    feed_nal(&dp, 0x41, 2500, 600, 1, -1);
    CHECK(s.units == 2, "frames after the gap are held back, not decoded on a broken picture");
    send_keyframe(&dp, 700, -1);
    CHECK(s.units == 3 && s.last_keyframe, "a keyframe ends the wait");
    feed_nal(&dp, 0x41, 2500, 800, 1, -1);
    CHECK(s.units == 4, "...and frames flow again after it");

    printf("\n==> the edges\n");
    // A frame whose marker never arrives: the next timestamp gives it away.
    feed_nal(&dp, 0x41, 2500, 900, 0, -1);
    uint32_t corrupt = dp.frames_corrupt;
    feed_nal(&dp, 0x41, 2500, 1000, 1, -1);
    CHECK(dp.frames_corrupt == corrupt + 1, "a frame that never finished is counted as corrupt");

    // Sequence numbers wrap at 65535 without that being loss.
    ls_depacketizer_reset(&dp);
    g_seq = 65530;
    int before = s.units, req = s.keyframe_requests;
    send_keyframe(&dp, 1100, -1);
    feed_nal(&dp, 0x41, 2500, 1200, 1, -1);
    CHECK(s.units == before + 2 && s.keyframe_requests == req,
          "sequence numbers wrapping round are not mistaken for loss");

    // STAP-A: several NALs in one packet.
    ls_depacketizer_reset(&dp);
    uint8_t stap[64]; size_t n = 0;
    stap[n++] = 24;
    stap[n++] = 0; stap[n++] = sizeof(kSPS); memcpy(stap + n, kSPS, sizeof(kSPS)); n += sizeof(kSPS);
    stap[n++] = 0; stap[n++] = sizeof(kPPS); memcpy(stap + n, kPPS, sizeof(kPPS)); n += sizeof(kPPS);
    stap[n++] = 0; stap[n++] = 3; stap[n++] = 0x65; stap[n++] = 1; stap[n++] = 2;
    before = s.units;
    feed(&dp, stap, n, 1300, 1);
    CHECK(s.units == before + 1 && s.last_keyframe, "an aggregation packet with a keyframe in it comes out");
    ls_depacketizer_free(&dp);
}

// ---- the queue ------------------------------------------------------------

static int g_released = 0;
static void release(void *unit) { (void)unit; g_released++; }

static void test_queue(void) {
    printf("\n==> the decode queue\n");
    ls_decode_queue q;
    ls_decode_queue_init(&q, 2, release);
    int a, b, c, d, e, f;
    ls_decode_queue_push(&q, &a, 1); ls_decode_queue_pop(&q);
    for (int i = 0; i < 20; i++) { ls_decode_queue_push(&q, &b, 0); ls_decode_queue_pop(&q); }
    CHECK(q.dropped == 0 && !q.waiting_for_keyframe, "a decoder that keeps up loses nothing");

    ls_decode_queue_push(&q, &b, 0);
    ls_decode_queue_push(&q, &c, 0);
    ls_decode_queue_push(&q, &d, 0);              // no room
    CHECK(q.waiting_for_keyframe && q.overflows == 1, "falling behind means waiting for a keyframe");
    CHECK(ls_decode_queue_pop(&q) == &b && ls_decode_queue_pop(&q) == &c && !ls_decode_queue_pop(&q),
          "...keeping the frames already waiting, and refusing the newest");
    ls_decode_queue_push(&q, &e, 0);
    CHECK(q.count == 0, "a frame after the gap is refused");
    ls_decode_queue_push(&q, &f, 1);
    CHECK(!q.waiting_for_keyframe && ls_decode_queue_pop(&q) == &f, "a keyframe ends the wait");

    ls_decode_queue_push(&q, &b, 0);
    ls_decode_queue_push(&q, &a, 1);
    CHECK(ls_decode_queue_pop(&q) == &a && !ls_decode_queue_pop(&q),
          "a keyframe overtakes older frames still waiting");
    ls_decode_queue_push(&q, &b, 0);
    ls_decode_queue_decode_failed(&q);
    CHECK(q.waiting_for_keyframe && q.count == 0, "a frame the decoder rejected is treated as a gap");
    // d (refused), e (refused), b (overtaken), b (cleared on failure)
    CHECK(g_released == 4, "every frame the queue gives up on is handed back to be freed");
}

int main(void) {
    test_depacketizer();
    test_queue();
    printf("\n%s\n", failures == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    return failures == 0 ? 0 : 1;
}
