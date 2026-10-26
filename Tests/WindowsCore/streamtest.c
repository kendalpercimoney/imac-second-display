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

// A real stream through the Windows client's core: RTP from the host's own
// encoder (Tests/LoopSend), reassembled by ls_depacketizer, decoded by
// ls_decoder through FFmpeg -- the same code the Windows client runs, here in
// software because this Mac has no DXVA2.
//
// Checks that every access unit produces its picture straight away, which is
// what the low-delay setup is for, and that the colour patches decode to the
// values BT.709 says they should, which is what the Windows renderer is told
// to convert with.
//
// usage: streamtest <port> <frames wanted> <seconds>

#include "ls_depacketizer.h"
#include "ls_decoder.h"
#include "rtp_protocol.h"
#include <libavutil/frame.h>
#include <libavutil/pixdesc.h>
#include <arpa/inet.h>
#include <math.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    ls_decoder *decoder;
    int units, frames, no_picture, errors, keyframe_requests;
    int checked, worst_error;
} Run;

static const int kPatches[12][3] = {
    {200, 120,  80}, { 80, 160,  80}, { 90, 150, 210}, {128, 128, 128},
    { 30,  30,  30}, {230, 230, 230}, {200,  40,  40}, { 40, 160, 160},
    {220, 200,  60}, {120,  60, 160}, {230, 140,  40}, {110,  80,  50},
};

static int clampi(double v) { return v < 0 ? 0 : (v > 255 ? 255 : (int)lround(v)); }

/* The decoded picture's colour at (x, y), converted with BT.709 at video
 * range -- the conversion the Windows client asks its video processor for. */
static void rgb_at(const AVFrame *f, int x, int y, int rgb[3]) {
    double Y = f->data[0][y * f->linesize[0] + x], Cb, Cr;
    if (f->format == AV_PIX_FMT_NV12) {
        const uint8_t *uv = f->data[1] + (y / 2) * f->linesize[1] + (x / 2) * 2;
        Cb = uv[0]; Cr = uv[1];
    } else {
        Cb = f->data[1][(y / 2) * f->linesize[1] + x / 2];
        Cr = f->data[2][(y / 2) * f->linesize[2] + x / 2];
    }
    double yy = (Y - 16) * 255.0 / 219.0, cb = (Cb - 128) * 255.0 / 224.0, cr = (Cr - 128) * 255.0 / 224.0;
    rgb[0] = clampi(yy + 1.5748 * cr);
    rgb[1] = clampi(yy - 0.1873 * cb - 0.4681 * cr);
    rgb[2] = clampi(yy + 1.8556 * cb);
}

static void on_unit(void *ctx, const uint8_t *data, size_t length, uint32_t ts, int keyframe) {
    Run *run = (Run *)ctx;
    (void)keyframe;
    run->units++;
    AVFrame *frame = NULL;
    int status = ls_decoder_decode(run->decoder, data, length, ts, &frame);
    if (status < 0) { run->errors++; return; }
    if (status == 0) { run->no_picture++; return; }
    run->frames++;
    // Score the patches once the stream has settled.
    if (run->frames == 20) {
        for (int i = 0; i < 12; i++) {
            int x = (int)((i % 4 + 0.5) * frame->width / 4), y = (int)((i / 4 + 0.5) * frame->height / 3);
            int rgb[3];
            rgb_at(frame, x, y, rgb);
            for (int c = 0; c < 3; c++) {
                int e = abs(rgb[c] - kPatches[i][c]);
                if (e > run->worst_error) run->worst_error = e;
            }
        }
        run->checked = 1;
        printf("  decoded picture: %dx%d %s\n", frame->width, frame->height,
               av_get_pix_fmt_name((enum AVPixelFormat)frame->format));
    }
}
static void on_need(void *ctx) { ((Run *)ctx)->keyframe_requests++; }

static uint64_t now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
    int port = argc > 1 ? atoi(argv[1]) : 5060;
    int wanted = argc > 2 ? atoi(argv[2]) : 100;
    int seconds = argc > 3 ? atoi(argv[3]) : 20;

    Run run; memset(&run, 0, sizeof(run));
    char error[256];
    run.decoder = ls_decoder_create(NULL, error, sizeof(error));
    if (!run.decoder) { printf("decoder: %s\n", error); return 2; }
    ls_depacketizer dp;
    ls_depacketizer_init(&dp, on_unit, on_need, &run);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int size = 4 << 20; setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    struct timeval tv = {0, 200000}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_port = htons((uint16_t)port); addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind"); return 2; }
    printf("listening on %d\n", port); fflush(stdout);

    static uint8_t buffer[LS_MAX_UDP_PAYLOAD];
    uint64_t deadline = now_ms() + (uint64_t)seconds * 1000;
    while (now_ms() < deadline && run.frames < wanted) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n <= 0) continue;
        ls_rtp_packet rtp;
        if (ls_rtp_parse(buffer, (size_t)n, &rtp) != 0) continue;
        ls_depacketizer_handle(&dp, buffer + rtp.payload_offset, rtp.payload_length, &rtp, now_ms());
    }
    close(fd);

    printf("  packets %u, lost %u, access units %d, pictures %d, units with no picture %d, errors %d\n",
           dp.packets_received, dp.packets_lost, run.units, run.frames, run.no_picture, run.errors);
    int failures = 0;
#define CHECK(cond, what) do { int ok_ = (cond); printf("  %s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) failures++; } while (0)
    CHECK(run.frames >= wanted, "the stream decoded");
    CHECK(run.no_picture == 0 && run.errors == 0,
          "every access unit gave its picture at once: one in, one out, nothing held back");
    CHECK(run.checked && run.worst_error <= 4, "the colour patches decode to BT.709 within 4 code values");
    printf("  worst colour error: %d\n", run.worst_error);

    ls_depacketizer_free(&dp);
    ls_decoder_destroy(run.decoder);
    printf("%s\n", failures == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    return failures == 0 ? 0 : 1;
}
