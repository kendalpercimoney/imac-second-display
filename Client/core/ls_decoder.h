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

// H.264 decoding through FFmpeg, in hardware when a device is given and in
// software otherwise. The Windows client hands it a DXVA2 device; the tests on
// the Mac run the same code in software, so how the stream is framed and how
// the decoder is configured are checked before anything reaches the iMac.
//
// Configured for one frame in, one frame out: low-delay mode, and a single
// decoding thread, because FFmpeg's frame threading holds a frame per thread
// in flight -- exactly the latency this project spends its time removing.

#ifndef LS_DECODER_H
#define LS_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct AVBufferRef;
struct AVFrame;
typedef struct ls_decoder ls_decoder;

/* `hw_device` is an FFmpeg hardware device context to decode with, or NULL
 * for software. On failure returns NULL and writes why into `error`. */
ls_decoder *ls_decoder_create(struct AVBufferRef *hw_device, char *error, size_t error_size);
void ls_decoder_destroy(ls_decoder *decoder);

/* Decodes one Annex B access unit. Returns 1 and sets `*frame` when a picture
 * came out -- owned by the decoder, valid until the next call -- 0 when none
 * did, and a negative FFmpeg error when the unit was rejected. */
int ls_decoder_decode(ls_decoder *decoder, const uint8_t *annexb, size_t length,
                      uint32_t timestamp, struct AVFrame **frame);

/* Whether the pictures coming out are hardware surfaces. Only known once the
 * first keyframe has set the decoder up; until then 0. */
int ls_decoder_is_hardware(const ls_decoder *decoder);

#ifdef __cplusplus
}
#endif
#endif
