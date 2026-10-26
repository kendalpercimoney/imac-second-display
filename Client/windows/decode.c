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

// The decoding thread: takes access units from the receiver through the
// mosh-safe queue, decodes them with FFmpeg, and hands each picture on.
//
// The queue is two deep, like the Mac client's. Anything deeper is latency
// waiting to happen: a decoder that is behind by more than two frames is not
// going to catch up by being given more.

#include "lswin.h"
#include "ls_decode_queue.h"
#include "ls_decoder.h"
#include <libavutil/frame.h>
#include <libavutil/pixdesc.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    size_t length;
    uint32_t timestamp;
    int is_keyframe;
    uint8_t data[];
} Unit;

struct LSDecode {
    AVBufferRef *hw_device;
    ls_frame_fn on_frame;
    void *context;
    LSNetwork *network;

    CRITICAL_SECTION lock;
    CONDITION_VARIABLE ready;
    ls_decode_queue queue;
    volatile LONG running, reset_requested;
    HANDLE thread;

    volatile uint32_t frames_decoded, decode_us, flags;
    double decode_average;
};

static void release_unit(void *unit) { free(unit); }

static DWORD WINAPI decode_loop(LPVOID parameter) {
    LSDecode *d = (LSDecode *)parameter;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);

    char error[256] = "";
    ls_decoder *decoder = d->hw_device ? ls_decoder_create(d->hw_device, error, sizeof(error)) : NULL;
    if (!decoder) {
        if (d->hw_device) ls_log("hardware decoding is not available (%s); decoding in software", error);
        decoder = ls_decoder_create(NULL, error, sizeof(error));
        if (!decoder) { ls_log("no decoder at all: %s", error); return 1; }
    }
    int reported = -1;

    for (;;) {
        EnterCriticalSection(&d->lock);
        Unit *unit = NULL;
        while (d->running && !(unit = (Unit *)ls_decode_queue_pop(&d->queue)))
            SleepConditionVariableCS(&d->ready, &d->lock, INFINITE);
        LeaveCriticalSection(&d->lock);
        if (!unit) break;   // stopping

        // A fresh start after the host went away: the old decoder's reference
        // pictures belong to a stream that no longer exists.
        if (InterlockedExchange(&d->reset_requested, 0)) {
            ls_decoder_destroy(decoder);
            decoder = ls_decoder_create(d->hw_device, error, sizeof(error));
            if (!decoder) decoder = ls_decoder_create(NULL, error, sizeof(error));
            reported = -1;
        }

        uint64_t begin = ls_now_us();
        AVFrame *frame = NULL;
        int status = ls_decoder_decode(decoder, unit->data, unit->length, unit->timestamp, &frame);
        double micros = (double)(ls_now_us() - begin);
        free(unit);

        if (status < 0) {
            // Rejected: exactly like a gap, so nothing more is decoded on top
            // of whatever state that left the decoder in.
            EnterCriticalSection(&d->lock);
            ls_decode_queue_decode_failed(&d->queue);
            LeaveCriticalSection(&d->lock);
            ls_network_request_keyframe(d->network);
            continue;
        }
        if (status == 0) continue;

        d->decode_average = d->decode_average == 0 ? micros : d->decode_average * 0.85 + micros * 0.15;
        d->decode_us = (uint32_t)d->decode_average;
        d->frames_decoded++;
        int hardware = ls_decoder_is_hardware(decoder);
        d->flags = LS_DECODER_KNOWN | (hardware ? LS_DECODER_HARDWARE : 0);
        if (hardware != reported) {
            reported = hardware;
            ls_log("decoding %dx%d %s, as %s", frame->width, frame->height,
                   hardware ? "in hardware (DXVA2)" : "in software",
                   av_get_pix_fmt_name((enum AVPixelFormat)frame->format));
        }
        d->on_frame(d->context, frame);
    }
    ls_decoder_destroy(decoder);
    return 0;
}

LSDecode *ls_decode_start(AVBufferRef *hw_device, ls_frame_fn on_frame, void *context,
                          LSNetwork *network) {
    LSDecode *d = (LSDecode *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->hw_device = hw_device;
    d->on_frame = on_frame;
    d->context = context;
    d->network = network;
    InitializeCriticalSection(&d->lock);
    InitializeConditionVariable(&d->ready);
    ls_decode_queue_init(&d->queue, 2, release_unit);
    d->running = 1;
    d->thread = CreateThread(NULL, 0, decode_loop, d, 0, NULL);
    return d;
}

void ls_decode_stop(LSDecode *d) {
    if (!d) return;
    EnterCriticalSection(&d->lock);
    d->running = 0;
    WakeAllConditionVariable(&d->ready);
    LeaveCriticalSection(&d->lock);
    WaitForSingleObject(d->thread, 5000);
    CloseHandle(d->thread);
    ls_decode_queue_clear(&d->queue);
    DeleteCriticalSection(&d->lock);
    free(d);
}

void ls_decode_submit(LSDecode *d, const uint8_t *annexb, size_t length,
                      uint32_t timestamp, int is_keyframe) {
    Unit *unit = (Unit *)malloc(sizeof(Unit) + length);
    if (!unit) return;
    unit->length = length;
    unit->timestamp = timestamp;
    unit->is_keyframe = is_keyframe;
    memcpy(unit->data, annexb, length);

    EnterCriticalSection(&d->lock);
    ls_decode_queue_push(&d->queue, unit, is_keyframe);
    int waiting = d->queue.waiting_for_keyframe;
    WakeConditionVariable(&d->ready);
    LeaveCriticalSection(&d->lock);
    // The queue gave up on the chain: only a keyframe restarts it. Asking on
    // every refused frame is fine; the requests are rate-limited.
    if (waiting) ls_network_request_keyframe(d->network);
}

void ls_decode_counters(LSDecode *d, ls_stats *stats) {
    EnterCriticalSection(&d->lock);
    stats->frames_dropped = d->queue.dropped;
    stats->queue_depth = (uint32_t)d->queue.count;
    LeaveCriticalSection(&d->lock);
    stats->frames_decoded = d->frames_decoded;
    stats->decode_us = d->decode_us;
    stats->decoder_flags |= d->flags;
}

void ls_decode_reset(LSDecode *d) {
    EnterCriticalSection(&d->lock);
    ls_decode_queue_clear(&d->queue);
    d->queue.waiting_for_keyframe = 1;
    LeaveCriticalSection(&d->lock);
    InterlockedExchange(&d->reset_requested, 1);
}
