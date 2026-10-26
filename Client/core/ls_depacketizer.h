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

// RTP in, whole H.264 access units out -- the client's packet reassembly, in
// portable C so the Windows client can share it and the tests can run it here.
//
// A port of Client/src/LSDepacketizer.m, with one difference: it emits Annex B
// (start codes) rather than AVCC (length prefixes), with the parameter sets in
// front of every keyframe, because that is what FFmpeg's H.264 decoder reads
// without any further setup.
//
// The rule that matters most is carried over unchanged: after any loss, nothing
// reaches the decoder until a fresh keyframe has arrived. A frame decoded on
// top of a picture the decoder never saw is how moshing starts.

#ifndef LS_DEPACKETIZER_H
#define LS_DEPACKETIZER_H

#include <stddef.h>
#include <stdint.h>
#include "rtp_protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A complete, undamaged access unit in Annex B form, valid only for the
 * duration of the call. */
typedef void (*ls_unit_fn)(void *context, const uint8_t *annexb, size_t length,
                           uint32_t timestamp, int is_keyframe);
/* The stream is damaged and only a keyframe will repair it. */
typedef void (*ls_need_keyframe_fn)(void *context);

typedef struct {
    ls_unit_fn on_unit;
    ls_need_keyframe_fn on_need_keyframe;
    void *context;

    uint8_t *unit;      size_t unit_length, unit_capacity;    /* NALs, start codes  */
    uint8_t *fragment;  size_t fragment_length, fragment_capacity;
    uint8_t *output;    size_t output_capacity;               /* what is emitted     */
    uint8_t sps[256];   size_t sps_length;
    uint8_t pps[256];   size_t pps_length;

    int have_sequence;  uint16_t expected_sequence;
    int have_timestamp; uint32_t current_timestamp;
    int unit_corrupt, unit_has_idr, fragment_active, waiting_for_keyframe;

    /* When the access unit now being built began, in the caller's
     * milliseconds, or 0. A frame that never finishes -- its tail lost just
     * before the screen went still -- is spotted from this. */
    uint64_t partial_since_ms;

    uint32_t packets_received, packets_lost, frames_corrupt, units_emitted;
} ls_depacketizer;

int  ls_depacketizer_init(ls_depacketizer *dp, ls_unit_fn on_unit,
                          ls_need_keyframe_fn on_need_keyframe, void *context);
void ls_depacketizer_free(ls_depacketizer *dp);
/* Forget everything and wait for a keyframe again. */
void ls_depacketizer_reset(ls_depacketizer *dp);
/* One RTP packet's payload. `now_ms` is any monotonic clock in milliseconds. */
void ls_depacketizer_handle(ls_depacketizer *dp, const uint8_t *payload, size_t length,
                            const ls_rtp_packet *rtp, uint64_t now_ms);

#ifdef __cplusplus
}
#endif
#endif
