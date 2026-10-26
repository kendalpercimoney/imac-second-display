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

#include "ls_depacketizer.h"
#include <stdlib.h>
#include <string.h>

static const uint8_t kStartCode[4] = {0, 0, 0, 1};

static int reserve(uint8_t **buffer, size_t *capacity, size_t needed) {
    if (needed <= *capacity) return 1;
    size_t grown = *capacity ? *capacity : 64 * 1024;
    while (grown < needed) grown *= 2;
    uint8_t *bigger = (uint8_t *)realloc(*buffer, grown);
    if (!bigger) return 0;
    *buffer = bigger;
    *capacity = grown;
    return 1;
}

int ls_depacketizer_init(ls_depacketizer *dp, ls_unit_fn on_unit,
                         ls_need_keyframe_fn on_need_keyframe, void *context) {
    memset(dp, 0, sizeof(*dp));
    dp->on_unit = on_unit;
    dp->on_need_keyframe = on_need_keyframe;
    dp->context = context;
    dp->waiting_for_keyframe = 1;
    return reserve(&dp->unit, &dp->unit_capacity, 512 * 1024)
        && reserve(&dp->fragment, &dp->fragment_capacity, 256 * 1024);
}

void ls_depacketizer_free(ls_depacketizer *dp) {
    free(dp->unit);
    free(dp->fragment);
    free(dp->output);
    memset(dp, 0, sizeof(*dp));
}

void ls_depacketizer_reset(ls_depacketizer *dp) {
    dp->partial_since_ms = 0;
    dp->unit_length = 0;
    dp->fragment_length = 0;
    dp->have_sequence = 0;
    dp->have_timestamp = 0;
    dp->unit_corrupt = 0;
    dp->unit_has_idr = 0;
    dp->fragment_active = 0;
    dp->waiting_for_keyframe = 1;
}

static void mark_damaged(ls_depacketizer *dp) {
    dp->unit_corrupt = 1;
    dp->fragment_active = 0;
    dp->fragment_length = 0;
    if (!dp->waiting_for_keyframe) {
        dp->waiting_for_keyframe = 1;
        if (dp->on_need_keyframe) dp->on_need_keyframe(dp->context);
    }
}

static void start_unit(ls_depacketizer *dp, uint32_t timestamp, uint64_t now_ms) {
    dp->unit_length = 0;
    dp->unit_corrupt = 0;
    dp->unit_has_idr = 0;
    dp->fragment_active = 0;
    dp->fragment_length = 0;
    dp->current_timestamp = timestamp;
    dp->have_timestamp = 1;
    dp->partial_since_ms = now_ms ? now_ms : 1;
}

static void append_nal(ls_depacketizer *dp, const uint8_t *nal, size_t length) {
    if (length < 1) return;
    switch (LS_NAL_TYPE(nal[0])) {
        case LS_NAL_SPS:
            // Kept aside and put back in front of each keyframe.
            if (length <= sizeof(dp->sps)) { memcpy(dp->sps, nal, length); dp->sps_length = length; }
            return;
        case LS_NAL_PPS:
            if (length <= sizeof(dp->pps)) { memcpy(dp->pps, nal, length); dp->pps_length = length; }
            return;
        case LS_NAL_AUD:
        case LS_NAL_FILLER:
            return;
        case LS_NAL_IDR:
            dp->unit_has_idr = 1;
            break;
        default:
            break;
    }
    if (!reserve(&dp->unit, &dp->unit_capacity, dp->unit_length + 4 + length)) {
        mark_damaged(dp);
        return;
    }
    memcpy(dp->unit + dp->unit_length, kStartCode, 4);
    memcpy(dp->unit + dp->unit_length + 4, nal, length);
    dp->unit_length += 4 + length;
}

static void handle_fragment(ls_depacketizer *dp, const uint8_t *payload, size_t length) {
    if (length < 3) { mark_damaged(dp); return; }
    uint8_t indicator = payload[0], header = payload[1];
    int start = (header & 0x80) != 0, end = (header & 0x40) != 0;

    if (start) {
        dp->fragment_length = 0;
        // The original NAL header: F and NRI from the indicator, the type
        // from the FU header.
        uint8_t reconstructed = (uint8_t)((indicator & 0xE0) | (header & 0x1F));
        if (!reserve(&dp->fragment, &dp->fragment_capacity, 1)) { mark_damaged(dp); return; }
        dp->fragment[0] = reconstructed;
        dp->fragment_length = 1;
        dp->fragment_active = 1;
    } else if (!dp->fragment_active) {
        // A middle or end with no start: the head of this NAL was lost.
        mark_damaged(dp);
        return;
    }
    if (!reserve(&dp->fragment, &dp->fragment_capacity, dp->fragment_length + length - 2)) {
        mark_damaged(dp);
        return;
    }
    memcpy(dp->fragment + dp->fragment_length, payload + 2, length - 2);
    dp->fragment_length += length - 2;

    if (end) {
        if (dp->fragment_active && dp->fragment_length > 1) {
            append_nal(dp, dp->fragment, dp->fragment_length);
        }
        dp->fragment_active = 0;
        dp->fragment_length = 0;
    }
}

static void handle_stap_a(ls_depacketizer *dp, const uint8_t *payload, size_t length) {
    size_t offset = 1;
    while (offset + 2 <= length) {
        size_t size = ((size_t)payload[offset] << 8) | payload[offset + 1];
        offset += 2;
        if (size == 0 || offset + size > length) { mark_damaged(dp); return; }
        append_nal(dp, payload + offset, size);
        offset += size;
    }
}

static void finish_unit(ls_depacketizer *dp) {
    dp->partial_since_ms = 0;
    if (dp->unit_corrupt) {
        dp->frames_corrupt++;
        dp->unit_length = 0;
        dp->unit_has_idr = 0;
        return;
    }
    if (dp->unit_length == 0) return;        // parameter sets only
    if (dp->waiting_for_keyframe) {
        if (!dp->unit_has_idr) { dp->unit_length = 0; return; }   // still resyncing
        dp->waiting_for_keyframe = 0;
    }
    if (dp->unit_has_idr && (!dp->sps_length || !dp->pps_length)) {
        // A keyframe with no parameter sets to go with it cannot be decoded.
        dp->unit_length = 0;
        dp->waiting_for_keyframe = 1;
        if (dp->on_need_keyframe) dp->on_need_keyframe(dp->context);
        return;
    }

    size_t total = dp->unit_length;
    if (dp->unit_has_idr) total += 8 + dp->sps_length + dp->pps_length;
    if (!reserve(&dp->output, &dp->output_capacity, total)) { dp->unit_length = 0; return; }
    size_t at = 0;
    if (dp->unit_has_idr) {
        memcpy(dp->output + at, kStartCode, 4); at += 4;
        memcpy(dp->output + at, dp->sps, dp->sps_length); at += dp->sps_length;
        memcpy(dp->output + at, kStartCode, 4); at += 4;
        memcpy(dp->output + at, dp->pps, dp->pps_length); at += dp->pps_length;
    }
    memcpy(dp->output + at, dp->unit, dp->unit_length); at += dp->unit_length;

    int keyframe = dp->unit_has_idr;
    dp->unit_length = 0;
    dp->unit_has_idr = 0;
    dp->units_emitted++;
    if (dp->on_unit) dp->on_unit(dp->context, dp->output, at, dp->current_timestamp, keyframe);
}

void ls_depacketizer_handle(ls_depacketizer *dp, const uint8_t *payload, size_t length,
                            const ls_rtp_packet *rtp, uint64_t now_ms) {
    if (length < 1) return;
    dp->packets_received++;

    // Sequence continuity. The signed 16-bit difference handles wraparound;
    // a gap of either sign is damage.
    if (dp->have_sequence && rtp->sequence != dp->expected_sequence) {
        int16_t gap = (int16_t)(uint16_t)(rtp->sequence - dp->expected_sequence);
        if (gap > 0) dp->packets_lost += (uint32_t)gap;
        mark_damaged(dp);
    }
    dp->expected_sequence = (uint16_t)(rtp->sequence + 1);
    dp->have_sequence = 1;

    // A new timestamp means the previous frame never got its marker bit,
    // which means its tail was lost.
    if (dp->have_timestamp && rtp->timestamp != dp->current_timestamp) {
        if (dp->unit_length > 0 || dp->fragment_active) {
            dp->frames_corrupt++;
            mark_damaged(dp);
        }
        start_unit(dp, rtp->timestamp, now_ms);
    } else if (!dp->have_timestamp) {
        start_unit(dp, rtp->timestamp, now_ms);
    }

    uint8_t type = (uint8_t)LS_NAL_TYPE(payload[0]);
    if (type == LS_NAL_FU_A) handle_fragment(dp, payload, length);
    else if (type == LS_NAL_STAP_A) handle_stap_a(dp, payload, length);
    else append_nal(dp, payload, length);

    if (rtp->marker) finish_unit(dp);
}
