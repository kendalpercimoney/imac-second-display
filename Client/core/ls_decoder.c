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

#include "ls_decoder.h"
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <stdio.h>
#include <string.h>

struct ls_decoder {
    AVCodecContext *context;
    AVPacket *packet;
    AVFrame *frame;
    enum AVPixelFormat hw_format;   /* AV_PIX_FMT_NONE when decoding in software */
    int chose_hardware;
};

/* Picks the hardware surface format when FFmpeg offers it -- it only does when
 * the device can decode this stream -- and otherwise lets it fall back to
 * software, rather than failing. */
static enum AVPixelFormat choose_format(AVCodecContext *context,
                                        const enum AVPixelFormat *offered) {
    ls_decoder *decoder = (ls_decoder *)context->opaque;
    for (const enum AVPixelFormat *f = offered; *f != AV_PIX_FMT_NONE; f++) {
        if (decoder->hw_format != AV_PIX_FMT_NONE && *f == decoder->hw_format) {
            decoder->chose_hardware = 1;
            return *f;
        }
    }
    decoder->chose_hardware = 0;
    for (const enum AVPixelFormat *f = offered; *f != AV_PIX_FMT_NONE; f++) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*f);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *f;
    }
    return offered[0];
}

ls_decoder *ls_decoder_create(AVBufferRef *hw_device, char *error, size_t error_size) {
    ls_decoder *decoder = (ls_decoder *)calloc(1, sizeof(*decoder));
    if (!decoder) { snprintf(error, error_size, "out of memory"); return NULL; }
    decoder->hw_format = AV_PIX_FMT_NONE;

    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec) { snprintf(error, error_size, "this FFmpeg has no H.264 decoder"); goto fail; }
    decoder->context = avcodec_alloc_context3(codec);
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    if (!decoder->context || !decoder->packet || !decoder->frame) {
        snprintf(error, error_size, "out of memory");
        goto fail;
    }

    AVCodecContext *c = decoder->context;
    c->opaque = decoder;
    // Either of these alone keeps it one in, one out on this host's streams,
    // which never reorder. Measured with Tests/run_windows_core_test.sh:
    // automatic threading without low-delay mode holds back eight frames,
    // 133 ms at 60 fps, before the first picture comes out.
    c->flags |= AV_CODEC_FLAG_LOW_DELAY;
    c->thread_count = 1;
    c->get_format = choose_format;

    if (hw_device) {
        AVHWDeviceContext *device = (AVHWDeviceContext *)hw_device->data;
        for (int i = 0;; i++) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
            if (!config) break;
            if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)
                && config->device_type == device->type) {
                decoder->hw_format = config->pix_fmt;
                break;
            }
        }
        if (decoder->hw_format == AV_PIX_FMT_NONE) {
            snprintf(error, error_size, "FFmpeg's H.264 decoder cannot use a %s device",
                     av_hwdevice_get_type_name(device->type));
            goto fail;
        }
        c->hw_device_ctx = av_buffer_ref(hw_device);
    }

    int status = avcodec_open2(c, codec, NULL);
    if (status < 0) {
        snprintf(error, error_size, "avcodec_open2 failed: %s", av_err2str(status));
        goto fail;
    }
    return decoder;

fail:
    ls_decoder_destroy(decoder);
    return NULL;
}

void ls_decoder_destroy(ls_decoder *decoder) {
    if (!decoder) return;
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->context);
    free(decoder);
}

int ls_decoder_decode(ls_decoder *decoder, const uint8_t *annexb, size_t length,
                      uint32_t timestamp, AVFrame **frame) {
    *frame = NULL;
    // FFmpeg reads a little past the end of its input, so it is copied into a
    // padded buffer rather than handed the caller's.
    int status = av_new_packet(decoder->packet, (int)length);
    if (status < 0) return status;
    memcpy(decoder->packet->data, annexb, length);
    decoder->packet->pts = timestamp;

    status = avcodec_send_packet(decoder->context, decoder->packet);
    av_packet_unref(decoder->packet);
    if (status < 0) return status;

    av_frame_unref(decoder->frame);
    status = avcodec_receive_frame(decoder->context, decoder->frame);
    if (status == AVERROR(EAGAIN)) return 0;
    if (status < 0) return status;
    *frame = decoder->frame;
    return 1;
}

int ls_decoder_is_hardware(const ls_decoder *decoder) {
    return decoder->chose_hardware;
}
