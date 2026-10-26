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

#include "ls_decode_queue.h"
#include <string.h>

void ls_decode_queue_init(ls_decode_queue *q, size_t depth, ls_unit_release_fn release) {
    memset(q, 0, sizeof(*q));
    q->depth = depth < 1 ? 1 : (depth > LS_DECODE_QUEUE_MAX ? LS_DECODE_QUEUE_MAX : depth);
    q->release = release;
}

static void discard_all(ls_decode_queue *q) {
    for (size_t i = 0; i < q->count; i++) {
        if (q->release) q->release(q->units[i]);
    }
    q->dropped += (uint32_t)q->count;
    q->count = 0;
}

void ls_decode_queue_push(ls_decode_queue *q, void *unit, int is_keyframe) {
    if (!unit) return;
    if (is_keyframe) {
        // Depends on nothing, so it ends any wait, and anything older still
        // waiting would only put the picture further behind.
        discard_all(q);
        q->waiting_for_keyframe = 0;
        q->units[q->count++] = unit;
        return;
    }
    if (q->waiting_for_keyframe) {
        q->dropped++;
        if (q->release) q->release(unit);
        return;
    }
    if (q->count >= q->depth) {
        // The newest goes: the frames already waiting are a complete chain.
        q->dropped++;
        q->overflows++;
        q->waiting_for_keyframe = 1;
        if (q->release) q->release(unit);
        return;
    }
    q->units[q->count++] = unit;
}

void *ls_decode_queue_pop(ls_decode_queue *q) {
    if (q->count == 0) return NULL;
    void *unit = q->units[0];
    memmove(&q->units[0], &q->units[1], (q->count - 1) * sizeof(void *));
    q->count--;
    return unit;
}

void ls_decode_queue_decode_failed(ls_decode_queue *q) {
    discard_all(q);
    q->waiting_for_keyframe = 1;
}

void ls_decode_queue_clear(ls_decode_queue *q) {
    discard_all(q);
}
