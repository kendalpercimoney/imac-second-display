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

// The frames waiting to be decoded, and the rule that keeps the picture from
// moshing: never decode a frame whose predecessor was not decoded. A port of
// Client/src/LSDecodeQueue.m; see that file for why each rule is there.
//
// When full, the newest frame is refused, not the oldest, so the chain already
// waiting still decodes correctly; nothing after a gap is queued until a
// keyframe; a keyframe overtakes anything older still waiting. No threads in
// here: the owner provides the locking.

#ifndef LS_DECODE_QUEUE_H
#define LS_DECODE_QUEUE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LS_DECODE_QUEUE_MAX 8

/* Called on every unit the queue refuses or discards, so it can be freed.
 * The queue owns whatever is pushed into it until it is popped. */
typedef void (*ls_unit_release_fn)(void *unit);

typedef struct {
    void *units[LS_DECODE_QUEUE_MAX];
    size_t count, depth;
    int waiting_for_keyframe;
    uint32_t dropped, overflows;
    ls_unit_release_fn release;
} ls_decode_queue;

void  ls_decode_queue_init(ls_decode_queue *q, size_t depth, ls_unit_release_fn release);
void  ls_decode_queue_push(ls_decode_queue *q, void *unit, int is_keyframe);
void *ls_decode_queue_pop(ls_decode_queue *q);
/* The decoder rejected a frame: treat it exactly like a gap. */
void  ls_decode_queue_decode_failed(ls_decode_queue *q);
void  ls_decode_queue_clear(ls_decode_queue *q);

#ifdef __cplusplus
}
#endif
#endif
