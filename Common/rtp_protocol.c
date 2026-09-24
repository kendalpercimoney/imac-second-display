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

#include "rtp_protocol.h"
#include <string.h>

/* ------------------------------------------------- big-endian primitives */

static void put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v);
}

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)(v);
}

static void put_u64(uint8_t *p, uint64_t v) {
    put_u32(p, (uint32_t)(v >> 32));
    put_u32(p + 4, (uint32_t)(v & 0xFFFFFFFFu));
}

static uint16_t get_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static uint32_t get_u32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

static uint64_t get_u64(const uint8_t *p) {
    return ((uint64_t)get_u32(p) << 32) | (uint64_t)get_u32(p + 4);
}

/* ------------------------------------------------------------------- RTP */

size_t ls_rtp_write_header(uint8_t *dst, size_t cap,
                           int marker, uint16_t sequence,
                           uint32_t timestamp, uint32_t ssrc)
{
    if (!dst || cap < LS_RTP_HEADER_SIZE) return 0;

    dst[0] = (uint8_t)(LS_RTP_VERSION << 6);          /* V=2, P=0, X=0, CC=0 */
    dst[1] = (uint8_t)(LS_RTP_PAYLOAD_TYPE & 0x7Fu);
    if (marker) dst[1] |= 0x80u;
    put_u16(dst + 2, sequence);
    put_u32(dst + 4, timestamp);
    put_u32(dst + 8, ssrc);
    return LS_RTP_HEADER_SIZE;
}

int ls_rtp_parse(const uint8_t *src, size_t len, ls_rtp_packet *out)
{
    size_t offset;
    uint8_t cc;

    if (!src || !out || len < LS_RTP_HEADER_SIZE) return -1;

    memset(out, 0, sizeof(*out));

    out->version = (uint8_t)((src[0] >> 6) & 0x03u);
    if (out->version != LS_RTP_VERSION) return -1;

    out->padding      = (uint8_t)((src[0] >> 5) & 0x01u);
    out->extension    = (uint8_t)((src[0] >> 4) & 0x01u);
    out->csrc_count   = cc = (uint8_t)(src[0] & 0x0Fu);
    out->marker       = (uint8_t)((src[1] >> 7) & 0x01u);
    out->payload_type = (uint8_t)(src[1] & 0x7Fu);
    if (out->payload_type != LS_RTP_PAYLOAD_TYPE) return -1;

    out->sequence  = get_u16(src + 2);
    out->timestamp = get_u32(src + 4);
    out->ssrc      = get_u32(src + 8);

    offset = (size_t)LS_RTP_HEADER_SIZE + (size_t)cc * 4u;
    if (offset > len) return -1;

    if (out->extension) {
        size_t ext_words;
        if (offset + 4 > len) return -1;
        ext_words = (size_t)get_u16(src + offset + 2);
        offset += 4 + ext_words * 4;
        if (offset > len) return -1;
    }

    {
        size_t payload_len = len - offset;
        if (out->padding) {
            uint8_t pad;
            if (payload_len == 0) return -1;
            pad = src[len - 1];
            if (pad == 0 || (size_t)pad > payload_len) return -1;
            payload_len -= pad;
        }
        if (payload_len == 0) return -1;
        out->payload_offset = (uint16_t)offset;
        out->payload_length = (uint16_t)payload_len;
    }
    return 0;
}

size_t ls_rtp_write_fu_a_prefix(uint8_t *dst, size_t cap,
                                uint8_t nal_header, int start, int end)
{
    if (!dst || cap < 2) return 0;
    /* FU indicator keeps the original NRI, type becomes 28. */
    dst[0] = (uint8_t)(LS_NAL_NRI(nal_header) | LS_NAL_FU_A);
    /* FU header: S | E | R(0) | original type */
    dst[1] = (uint8_t)(LS_NAL_TYPE(nal_header));
    if (start) dst[1] |= 0x80u;
    if (end)   dst[1] |= 0x40u;
    return 2;
}

/* --------------------------------------------------------------- control */

/* Header layout on the wire (8 bytes):
 *   0..3  magic  (LS_CTRL_MAGIC)
 *   4     type
 *   5     reserved (0)
 *   6..7  total length including this header
 */
#define CTRL_HDR 8

static size_t ctrl_begin(uint8_t *dst, size_t cap, uint8_t type, size_t body)
{
    size_t total = CTRL_HDR + body;
    if (!dst || cap < total || total > LS_CTRL_MAX_PACKET) return 0;
    put_u32(dst, LS_CTRL_MAGIC);
    dst[4] = type;
    dst[5] = 0;
    put_u16(dst + 6, (uint16_t)total);
    return total;
}

size_t ls_ctrl_build_hello(uint8_t *dst, size_t cap,
                           uint16_t width, uint16_t height,
                           uint16_t video_port, uint16_t flags,
                           const uint8_t *mac)
{
    /* The MAC is appended rather than inserted, so a parser that only knows
     * the 8-byte body still reads the first four fields correctly. */
    size_t body = mac ? 16 : 8;
    size_t total = ctrl_begin(dst, cap, LS_MSG_HELLO, body);
    if (!total) return 0;
    put_u16(dst + CTRL_HDR + 0, width);
    put_u16(dst + CTRL_HDR + 2, height);
    put_u16(dst + CTRL_HDR + 4, video_port);
    put_u16(dst + CTRL_HDR + 6, flags);
    if (mac) {
        memcpy(dst + CTRL_HDR + 8, mac, 6);
        dst[CTRL_HDR + 14] = 0;
        dst[CTRL_HDR + 15] = 0;
    }
    return total;
}

size_t ls_ctrl_build_bye(uint8_t *dst, size_t cap)
{
    return ctrl_begin(dst, cap, LS_MSG_BYE, 0);
}

size_t ls_ctrl_build_keyframe_req(uint8_t *dst, size_t cap)
{
    return ctrl_begin(dst, cap, LS_MSG_KEYFRAME_REQ, 0);
}

size_t ls_ctrl_build_stats(uint8_t *dst, size_t cap, const ls_stats *stats)
{
    size_t total;
    if (!stats) return 0;
    total = ctrl_begin(dst, cap, LS_MSG_STATS, 32);
    if (!total) return 0;
    put_u32(dst + CTRL_HDR +  0, stats->frames_decoded);
    put_u32(dst + CTRL_HDR +  4, stats->frames_dropped);
    put_u32(dst + CTRL_HDR +  8, stats->frames_corrupt);
    put_u32(dst + CTRL_HDR + 12, stats->packets_received);
    put_u32(dst + CTRL_HDR + 16, stats->packets_lost);
    put_u32(dst + CTRL_HDR + 20, stats->decode_us);
    put_u32(dst + CTRL_HDR + 24, stats->render_us);
    put_u32(dst + CTRL_HDR + 28, stats->queue_depth);
    return total;
}

static size_t ctrl_build_token(uint8_t *dst, size_t cap, uint8_t type, uint64_t token)
{
    size_t total = ctrl_begin(dst, cap, type, 8);
    if (!total) return 0;
    put_u64(dst + CTRL_HDR, token);
    return total;
}

size_t ls_ctrl_build_ping(uint8_t *dst, size_t cap, uint64_t token)
{
    return ctrl_build_token(dst, cap, LS_MSG_PING, token);
}

size_t ls_ctrl_build_pong(uint8_t *dst, size_t cap, uint64_t token)
{
    return ctrl_build_token(dst, cap, LS_MSG_PONG, token);
}

size_t ls_ctrl_build_cursor(uint8_t *dst, size_t cap,
                            uint16_t x, uint16_t y,
                            uint8_t visible, uint16_t image_id)
{
    size_t total = ctrl_begin(dst, cap, LS_MSG_CURSOR, 8);
    if (!total) return 0;
    put_u16(dst + CTRL_HDR + 0, x);
    put_u16(dst + CTRL_HDR + 2, y);
    dst[CTRL_HDR + 4] = visible ? 1 : 0;
    dst[CTRL_HDR + 5] = 0;
    put_u16(dst + CTRL_HDR + 6, image_id);
    return total;
}

size_t ls_ctrl_build_volume(uint8_t *dst, size_t cap, uint16_t volume)
{
    size_t total = ctrl_begin(dst, cap, LS_MSG_VOLUME, 2);
    if (!total) return 0;
    if (volume > LS_VOLUME_SCALE) volume = LS_VOLUME_SCALE;
    put_u16(dst + CTRL_HDR + 0, volume);
    return total;
}

size_t ls_ctrl_build_cursor_image(uint8_t *dst, size_t cap,
                                  uint16_t image_id,
                                  uint16_t width, uint16_t height,
                                  uint16_t hotspot_x, uint16_t hotspot_y,
                                  const uint8_t *rgba, uint32_t rgba_length)
{
    size_t total;
    if (!rgba || width == 0 || height == 0) return 0;
    if (rgba_length > LS_CURSOR_MAX_IMAGE_BYTES) return 0;
    if ((uint32_t)width * (uint32_t)height * 4u != rgba_length) return 0;

    total = ctrl_begin(dst, cap, LS_MSG_CURSOR_IMAGE, 12 + rgba_length);
    if (!total) return 0;
    put_u16(dst + CTRL_HDR + 0, image_id);
    put_u16(dst + CTRL_HDR + 2, width);
    put_u16(dst + CTRL_HDR + 4, height);
    put_u16(dst + CTRL_HDR + 6, hotspot_x);
    put_u16(dst + CTRL_HDR + 8, hotspot_y);
    put_u16(dst + CTRL_HDR + 10, 0);
    memcpy(dst + CTRL_HDR + 12, rgba, rgba_length);
    return total;
}

int ls_ctrl_parse(const uint8_t *src, size_t len, ls_ctrl_message *out)
{
    uint16_t total;
    uint8_t type;
    size_t body;

    if (!src || !out || len < CTRL_HDR) return -1;
    if (get_u32(src) != LS_CTRL_MAGIC) return -1;

    total = get_u16(src + 6);
    if (total < CTRL_HDR || (size_t)total > len || total > LS_CTRL_MAX_PACKET) return -1;
    body = (size_t)total - CTRL_HDR;

    type = src[4];
    memset(out, 0, sizeof(*out));
    out->type = type;

    switch (type) {
        case LS_MSG_HELLO:
            if (body < 8) return -1;
            out->screen_width  = get_u16(src + CTRL_HDR + 0);
            out->screen_height = get_u16(src + CTRL_HDR + 2);
            out->video_port    = get_u16(src + CTRL_HDR + 4);
            out->flags         = get_u16(src + CTRL_HDR + 6);
            if (body >= 14) {
                memcpy(out->mac, src + CTRL_HDR + 8, 6);
                out->has_mac = 1;
            }
            return 0;

        case LS_MSG_BYE:
        case LS_MSG_KEYFRAME_REQ:
            return 0;

        case LS_MSG_VOLUME:
            if (body < 2) return -1;
            out->volume = get_u16(src + CTRL_HDR + 0);
            /* A peer that asks for more than unity is malformed, not a licence
             * to amplify. */
            if (out->volume > LS_VOLUME_SCALE) return -1;
            return 0;

        case LS_MSG_STATS:
            if (body < 32) return -1;
            out->stats.frames_decoded   = get_u32(src + CTRL_HDR +  0);
            out->stats.frames_dropped   = get_u32(src + CTRL_HDR +  4);
            out->stats.frames_corrupt   = get_u32(src + CTRL_HDR +  8);
            out->stats.packets_received = get_u32(src + CTRL_HDR + 12);
            out->stats.packets_lost     = get_u32(src + CTRL_HDR + 16);
            out->stats.decode_us        = get_u32(src + CTRL_HDR + 20);
            out->stats.render_us        = get_u32(src + CTRL_HDR + 24);
            out->stats.queue_depth      = get_u32(src + CTRL_HDR + 28);
            return 0;

        case LS_MSG_PING:
        case LS_MSG_PONG:
            if (body < 8) return -1;
            out->token = get_u64(src + CTRL_HDR);
            return 0;

        case LS_MSG_CURSOR:
            if (body < 8) return -1;
            out->cursor_x        = get_u16(src + CTRL_HDR + 0);
            out->cursor_y        = get_u16(src + CTRL_HDR + 2);
            out->cursor_visible  = src[CTRL_HDR + 4];
            out->cursor_image_id = get_u16(src + CTRL_HDR + 6);
            return 0;

        case LS_MSG_CURSOR_IMAGE: {
            uint32_t pixels;
            if (body < 12) return -1;
            out->cursor_image_id = get_u16(src + CTRL_HDR + 0);
            out->image_width     = get_u16(src + CTRL_HDR + 2);
            out->image_height    = get_u16(src + CTRL_HDR + 4);
            out->hotspot_x       = get_u16(src + CTRL_HDR + 6);
            out->hotspot_y       = get_u16(src + CTRL_HDR + 8);
            out->image_length    = (uint32_t)(body - 12);
            out->image_offset    = (uint16_t)(CTRL_HDR + 12);
            if (out->image_width == 0 || out->image_height == 0) return -1;
            /* The declared size and the bytes present have to agree, or a
             * truncated packet would be read past its end. */
            pixels = (uint32_t)out->image_width * (uint32_t)out->image_height * 4u;
            if (pixels != out->image_length) return -1;
            if (out->image_length > LS_CURSOR_MAX_IMAGE_BYTES) return -1;
            return 0;
        }

        default:
            return -1;   /* unknown type -- never treat a stray packet as a command */
    }
}

/* ---------------------------------------------------------- Wake-on-LAN --- */

size_t ls_wol_build_magic_packet(uint8_t *dst, size_t cap, const uint8_t *mac)
{
    int i;
    if (!dst || !mac || cap < LS_WOL_PACKET_SIZE) return 0;
    memset(dst, 0xFF, 6);
    for (i = 0; i < 16; i++) {
        memcpy(dst + 6 + (size_t)i * 6, mac, 6);
    }
    return LS_WOL_PACKET_SIZE;
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int ls_parse_mac(const char *text, uint8_t *out)
{
    int octet = 0;
    const char *p = text;

    if (!text || !out) return -1;

    while (octet < 6) {
        int high, low, next;
        while (*p == ' ') p++;
        high = hex_value(*p);
        if (high < 0) return -1;
        p++;
        low = hex_value(*p);
        if (low < 0) {
            /* Single-digit octet, as `arp` prints for values under 0x10. */
            out[octet] = (uint8_t)high;
        } else {
            out[octet] = (uint8_t)((high << 4) | low);
            p++;
        }
        octet++;
        if (octet == 6) break;
        next = *p;
        if (next != ':' && next != '-') return -1;
        p++;
    }
    while (*p == ' ') p++;
    return (*p == '\0' && octet == 6) ? 0 : -1;
}

size_t ls_format_mac(char *dst, size_t cap, const uint8_t *mac)
{
    static const char digits[] = "0123456789abcdef";
    int i;
    if (!dst || !mac || cap < 18) return 0;
    for (i = 0; i < 6; i++) {
        dst[i * 3]     = digits[(mac[i] >> 4) & 0x0F];
        dst[i * 3 + 1] = digits[mac[i] & 0x0F];
        if (i < 5) dst[i * 3 + 2] = ':';
    }
    dst[17] = '\0';
    return 17;
}

/* ------------------------------------------------------------------ audio */

/* The sizes in the header are literals so Swift can see them. Keep them honest. */
typedef char ls_audio_payload_size_check[
    (LS_AUDIO_MAX_PAYLOAD == LS_AUDIO_FRAMES_PER_PACKET * LS_AUDIO_CHANNELS * 2) ? 1 : -1];
typedef char ls_audio_packet_size_check[
    (LS_AUDIO_MAX_PACKET == LS_AUDIO_HEADER_SIZE + LS_AUDIO_MAX_PAYLOAD) ? 1 : -1];

size_t ls_audio_write_header(uint8_t *dst, size_t cap,
                             uint16_t sequence, uint32_t timestamp,
                             uint32_t sample_rate, uint8_t channels,
                             uint8_t format)
{
    if (!dst || cap < LS_AUDIO_HEADER_SIZE) return 0;
    if (channels == 0) return 0;
    put_u32(dst + 0, LS_AUDIO_MAGIC);
    put_u16(dst + 4, sequence);
    put_u16(dst + 6, 0);                 /* reserved, must be zero */
    put_u32(dst + 8, timestamp);
    put_u32(dst + 12, sample_rate);
    dst[16] = channels;
    dst[17] = format;
    put_u16(dst + 18, 0);                /* reserved */
    return LS_AUDIO_HEADER_SIZE;
}

int ls_audio_parse(const uint8_t *src, size_t len, ls_audio_packet *out)
{
    size_t payload;
    size_t frame_bytes;

    if (!src || !out || len < LS_AUDIO_HEADER_SIZE) return -1;
    if (get_u32(src) != LS_AUDIO_MAGIC) return -1;
    if (len > LS_AUDIO_MAX_PACKET) return -1;

    memset(out, 0, sizeof(*out));
    out->sequence    = get_u16(src + 4);
    out->timestamp   = get_u32(src + 8);
    out->sample_rate = get_u32(src + 12);
    out->channels    = src[16];
    out->format      = src[17];

    if (out->channels == 0 || out->channels > 8) return -1;
    if (out->format != LS_AUDIO_FORMAT_S16LE) return -1;
    if (out->sample_rate == 0 || out->sample_rate > 192000u) return -1;

    payload = len - LS_AUDIO_HEADER_SIZE;
    /* Half a frame would put the channels out of step for the rest of the
     * stream, so a payload that is not a whole number of them is refused
     * rather than truncated. */
    frame_bytes = (size_t)out->channels * 2u;
    if (payload % frame_bytes) return -1;

    out->payload_offset = LS_AUDIO_HEADER_SIZE;
    out->payload_length = (uint16_t)payload;
    return 0;
}
