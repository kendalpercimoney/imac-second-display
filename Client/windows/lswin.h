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

// The Windows 7 client: what its parts share.
//
// Phase 0 of running the client on the iMac under Windows: receive the stream
// from the unchanged host, decode it in hardware through DXVA2, show it, and
// report back so the host's panel says whether the decoder really is hardware
// and what decoding and drawing cost. No pointer, audio or input yet -- the
// HELLO says so, and the host burns the pointer into the video instead.
//
// Four threads: the window (and everything Direct3D presents), the video
// receiver, the decoder, and the control channel.

#ifndef LSWIN_H
#define LSWIN_H

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include "rtp_protocol.h"

struct AVFrame;
struct AVBufferRef;

/* ------------------------------------------------------------------ log */

/* lanscreen.log beside the program, and the debugger. */
void ls_log_open(void);
void ls_log(const char *format, ...);
uint64_t ls_now_us(void);   /* monotonic */

/* -------------------------------------------------------------- display */

typedef struct LSDisplay LSDisplay;

/* A Direct3D 9Ex device on `window`, exclusive fullscreen unless `windowed`,
 * with a DXVA2 device manager the decoder shares, so decoded pictures never
 * leave the GPU. */
LSDisplay *ls_display_create(HWND window, int windowed, char *error, size_t error_size);
void ls_display_destroy(LSDisplay *display);
/* The device as FFmpeg wants it, for the decoder. Owned by the display. */
struct AVBufferRef *ls_display_hw_device(LSDisplay *display);
/* Draws a decoded picture -- a DXVA2 surface, or planes from the software
 * decoder -- and presents it. Returns 0, or -1 if the device has gone. */
int ls_display_show_frame(LSDisplay *display, const struct AVFrame *frame);
/* A line or two of text on a dark screen, for before the stream arrives. */
void ls_display_show_message(LSDisplay *display, const char *text);
/* LS_DECODER_COLOUR_* for STATS, once the first picture has been checked. */
uint32_t ls_display_colour_flags(const LSDisplay *display);
uint32_t ls_display_render_us(const LSDisplay *display);

/* -------------------------------------------------------------- network */

typedef struct LSNetwork LSNetwork;

typedef struct {
    const char *host;
    uint16_t video_port, control_port;
    uint16_t screen_width, screen_height;
} LSNetworkConfig;

/* Each complete access unit is handed to `on_unit` on the receive thread. */
typedef void (*ls_net_unit_fn)(void *context, const uint8_t *annexb, size_t length,
                               uint32_t timestamp, int is_keyframe);

LSNetwork *ls_network_start(const LSNetworkConfig *config, ls_net_unit_fn on_unit,
                            void *context, char *error, size_t error_size);
/* Stops the receive thread alone, so nothing more is handed to the decoder
 * while it shuts down; the control channel carries on until ls_network_stop. */
void ls_network_stop_video(LSNetwork *network);
void ls_network_stop(LSNetwork *network);
void ls_network_send_hello(LSNetwork *network);
/* Rate-limited, so every thread that notices damage can simply ask. */
void ls_network_request_keyframe(LSNetwork *network);
void ls_network_send_stats(LSNetwork *network, ls_stats *stats);
/* Fills in the packet and frame counters the receiver keeps. */
void ls_network_counters(LSNetwork *network, ls_stats *stats);
/* Milliseconds since the host was last heard from on either socket, or -1. */
int64_t ls_network_ms_since_contact(LSNetwork *network);
/* Milliseconds an unfinished frame has been waiting for its tail, or 0. */
int64_t ls_network_partial_frame_ms(LSNetwork *network);
/* Throws away anything half-built and waits for a keyframe. */
void ls_network_reset_stream(LSNetwork *network);

/* --------------------------------------------------------------- decode */

typedef struct LSDecode LSDecode;

/* Called on the decoding thread with each picture. The frame is the
 * decoder's, valid only for the call. */
typedef void (*ls_frame_fn)(void *context, const struct AVFrame *frame);

LSDecode *ls_decode_start(struct AVBufferRef *hw_device, ls_frame_fn on_frame,
                          void *context, LSNetwork *network);
void ls_decode_stop(LSDecode *decode);
/* Takes a copy. Called from the receive thread. */
void ls_decode_submit(LSDecode *decode, const uint8_t *annexb, size_t length,
                      uint32_t timestamp, int is_keyframe);
/* frames_decoded, frames_dropped, decode_us, queue_depth, decoder_flags. */
void ls_decode_counters(LSDecode *decode, ls_stats *stats);
void ls_decode_reset(LSDecode *decode);

#endif
