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

/*
 * rtp_protocol.h -- shared wire format for LanScreen.
 *
 * ONE canonical copy, compiled into both ends:
 *   - Host  (Swift, macOS 13+) imports it as the SwiftPM C target "LSProtocol".
 *   - Client (Objective-C, OS X 10.9 SDK) compiles rtp_protocol.c directly.
 *
 * Everything on the wire is big-endian (network byte order). The structs below
 * are HOST-byte-order value types used only in memory; the build/parse helpers
 * do the byte shuffling. That deliberate split keeps Swift happy -- Swift's C
 * importer mishandles __attribute__((packed)) structs, so we never put one on
 * the wire as a raw memcpy.
 */
#ifndef LS_RTP_PROTOCOL_H
#define LS_RTP_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ ports */

#define LS_DEFAULT_VIDEO_PORT     5000   /* host -> client, RTP/H.264       */
#define LS_DEFAULT_CONTROL_PORT   5001   /* bidirectional control messages  */
#define LS_DEFAULT_AUDIO_PORT     5002   /* host -> client, raw PCM         */

/* -------------------------------------------------------------------- RTP */

#define LS_RTP_VERSION            2
#define LS_RTP_PAYLOAD_TYPE       96     /* dynamic, matches the .sdp file  */
#define LS_RTP_CLOCK_HZ           90000u
#define LS_RTP_HEADER_SIZE        12

/* Max bytes we will ever put in one UDP datagram (RTP header included). */
#define LS_MAX_UDP_PAYLOAD        9200
/* Safe for a standard 1500-byte Ethernet MTU: 1500 - 20 (IP) - 8 (UDP). */
#define LS_DEFAULT_MTU_PAYLOAD    1400
/* For a direct link with jumbo frames enabled on both NICs (MTU 9000). */
#define LS_JUMBO_MTU_PAYLOAD      8900

/* ------------------------------------------------------------------ audio */

/*
 * Audio is raw PCM on its own socket, deliberately.
 *
 * Not compressed: 48 kHz stereo 16-bit is 1.5 Mb/s, against 25 to 50 for the
 * video, on a link that has a gigabit to spare. An AAC round trip would add
 * more algorithmic latency than the entire rest of the pipeline costs, to save
 * bandwidth that is not scarce.
 *
 * Not on the video socket: a lost audio packet must be concealed and forgotten,
 * never treated the way a lost video packet is, and audio must not queue behind
 * the burst of packets a keyframe makes.
 *
 * The header is network byte order like everything else. The samples are not:
 * they are little-endian because both machines are, and byte-swapping ninety-six
 * thousand samples a second on a 2010 CPU would buy nothing at all. The format
 * field says so explicitly rather than leaving it as an exception to the rule.
 */
#define LS_AUDIO_MAGIC            0x4C534131u   /* "LSA1" */
#define LS_AUDIO_HEADER_SIZE      20
#define LS_AUDIO_SAMPLE_RATE      48000u
#define LS_AUDIO_CHANNELS         2
#define LS_AUDIO_FORMAT_S16LE     1
/* 256 frames is 5.33 ms, and 1024 bytes of payload -- comfortably inside a
 * 1400-byte packet, so audio never fragments even on a standard MTU. */
#define LS_AUDIO_FRAMES_PER_PACKET 256
/* Spelled out rather than computed from the three above: Swift's C importer
 * drops a macro defined in terms of other computed macros, and silently, so the
 * constant simply does not exist on the host side. rtp_protocol.c asserts at
 * compile time that these still agree with the arithmetic. */
#define LS_AUDIO_MAX_PAYLOAD      1024
#define LS_AUDIO_MAX_PACKET       1044

typedef struct {
    uint16_t sequence;
    uint32_t timestamp;      /* frames since the stream started               */
    uint32_t sample_rate;
    uint8_t  channels;
    uint8_t  format;         /* LS_AUDIO_FORMAT_*                             */
    uint16_t payload_offset; /* indexes into the buffer handed to the parser   */
    uint16_t payload_length; /* bytes, so frames = length / (channels * 2)     */
} ls_audio_packet;

/* Returns bytes written, or 0 if cap is too small. */
size_t ls_audio_write_header(uint8_t *dst, size_t cap,
                             uint16_t sequence, uint32_t timestamp,
                             uint32_t sample_rate, uint8_t channels,
                             uint8_t format);

/* Returns 0 on success, -1 if this is not one of ours or is malformed. A
 * payload that is not a whole number of frames is rejected: half a frame would
 * desynchronise the channels for the rest of the stream. */
int ls_audio_parse(const uint8_t *src, size_t len, ls_audio_packet *out);

/* ------------------------------------------------------------ H.264 NAL --*/

#define LS_NAL_SLICE               1
#define LS_NAL_IDR                 5
#define LS_NAL_SEI                 6
#define LS_NAL_SPS                 7
#define LS_NAL_PPS                 8
#define LS_NAL_AUD                 9
#define LS_NAL_FILLER             12
#define LS_NAL_STAP_A             24     /* RFC 6184 aggregation            */
#define LS_NAL_FU_A               28     /* RFC 6184 fragmentation          */

#define LS_NAL_TYPE(header_byte)  ((header_byte) & 0x1Fu)
#define LS_NAL_NRI(header_byte)   ((header_byte) & 0x60u)

/* A parsed RTP packet. payload_offset/payload_length index into the buffer
 * that was handed to ls_rtp_parse(); nothing is copied. */
typedef struct {
    uint8_t  version;
    uint8_t  padding;
    uint8_t  extension;
    uint8_t  csrc_count;
    uint8_t  marker;
    uint8_t  payload_type;
    uint16_t sequence;
    uint32_t timestamp;
    uint32_t ssrc;
    uint16_t payload_offset;
    uint16_t payload_length;
} ls_rtp_packet;

/* Writes the fixed 12-byte RTP header. Returns bytes written, or 0 if cap is
 * too small. */
size_t ls_rtp_write_header(uint8_t *dst, size_t cap,
                           int marker, uint16_t sequence,
                           uint32_t timestamp, uint32_t ssrc);

/* Returns 0 on success, -1 if the datagram is not a well-formed RTP packet
 * carrying our payload type. Handles the CSRC list and the header extension
 * so payload_offset is always the real start of the H.264 payload. */
int ls_rtp_parse(const uint8_t *src, size_t len, ls_rtp_packet *out);

/* Writes the 2-byte FU-A prefix (FU indicator + FU header).
 * nal_header is the ORIGINAL single-byte NAL header of the unit being split. */
size_t ls_rtp_write_fu_a_prefix(uint8_t *dst, size_t cap,
                                uint8_t nal_header, int start, int end);

/* ---------------------------------------------------------------- control */

#define LS_CTRL_MAGIC       0x4C534331u   /* "LSC1" */
/* Buffer size for the small fixed messages. */
#define LS_CTRL_MAX_SIZE    128
/* A cursor bitmap is far bigger than the rest put together, so parsing has a
 * higher ceiling than the small-message buffer. 64x64 RGBA is 16 KB, which one
 * UDP datagram carries happily even if IP fragments it on the way. */
#define LS_CURSOR_MAX_IMAGE_BYTES 16384
#define LS_CTRL_MAX_PACKET  (LS_CURSOR_MAX_IMAGE_BYTES + 64)

enum {
    LS_MSG_HELLO        = 1,  /* client -> host: I am here, this is my screen */
    LS_MSG_BYE          = 2,  /* either way: tearing down                     */
    LS_MSG_KEYFRAME_REQ = 3,  /* client -> host: my stream is broken, IDR now */
    LS_MSG_STATS        = 4,  /* client -> host: once a second                */
    LS_MSG_PING         = 5,  /* host -> client: opaque token                 */
    LS_MSG_PONG         = 6,  /* client -> host: same token echoed back       */
    /* The pointer is sent out of band and drawn by the client, rather than
     * being burned into the video. Video is one encode, one network trip and
     * one decode behind; the pointer is what the eye tracks, and this way it
     * lags by about a screen refresh instead. The cost is that the pointer runs
     * slightly ahead of a window being dragged under it. */
    LS_MSG_CURSOR       = 7,  /* host -> client: where the pointer is         */
    LS_MSG_CURSOR_IMAGE = 8,  /* host -> client: what it looks like           */
    /* Playback volume for the client, because the slider is on the host and
     * the speakers are not. Resent periodically so a lost one heals itself. */
    LS_MSG_VOLUME       = 9,
    /* How long the client should hold audio before playing it. Negative pulls
     * it earlier, which is the direction that usually matters: audio takes a
     * shorter path than video but sits in a jitter buffer and an audio queue at
     * the far end, so it tends to arrive late rather than early. */
    LS_MSG_AUDIO_DELAY  = 10,
    /* The iMac's panel brightness. The screen is over there; the slider is not. */
    LS_MSG_BRIGHTNESS   = 11
};

/* Volume is carried as thousandths, so 1000 is unity and 0 is silence. An
 * integer keeps it exact across the wire and across both languages. */
#define LS_VOLUME_SCALE     1000u

/* Audio delay in milliseconds, signed. The range is what a person can usefully
 * drag; the client clamps whatever it is actually able to do on top of that,
 * because it cannot buffer less than nothing.
 *
 * An enum rather than #define so both ends get a real symbol rather than a
 * textual substitution, which matters for the one value here that is signed. */
enum {
    LS_AUDIO_DELAY_MIN_MS = -50,
    LS_AUDIO_DELAY_MAX_MS = 250
};

/* Brightness in thousandths, like volume. */
#define LS_BRIGHTNESS_SCALE 1000u

/* Flags a client sets in its HELLO. */
/* It can draw the pointer itself, so the host may leave it out of the video.
 * Without this the host must burn the pointer in, or there would be no pointer
 * on screen anywhere. */
#define LS_CLIENT_FLAG_DRAWS_CURSOR 0x0001u
/* It can play the audio stream. Without this the host does not send any, rather
 * than pouring 1.5 Mb/s into a socket nothing is listening to. */
#define LS_CLIENT_FLAG_PLAYS_AUDIO  0x0002u
/* Its display accepted a brightness reading. Without this the host greys the
 * brightness control out and says why, rather than moving a slider that does
 * nothing at the far end. */
#define LS_CLIENT_FLAG_SETS_BRIGHTNESS 0x0004u

/* Client-reported counters. All cumulative since the client started, except
 * the *_us fields which are rolling averages over the last reporting period. */
typedef struct {
    uint32_t frames_decoded;
    uint32_t frames_dropped;    /* discarded before decode (queue overflow)   */
    uint32_t frames_corrupt;    /* abandoned due to packet loss               */
    uint32_t packets_received;
    uint32_t packets_lost;      /* inferred from RTP sequence gaps            */
    uint32_t decode_us;
    uint32_t render_us;
    uint32_t queue_depth;
    /* Audio. Appended after the fields above, so a client built before audio
     * existed still sends a shorter STATS that parses fine. */
    uint32_t audio_underruns;   /* gaps the client had to conceal            */
    uint32_t audio_overruns;    /* frames dropped because the ring filled    */
    uint32_t audio_buffered_us; /* what is waiting, which is the delay it adds */
} ls_stats;

typedef struct {
    uint8_t  type;              /* one of LS_MSG_*                            */
    /* HELLO */
    uint16_t screen_width;
    uint16_t screen_height;
    uint16_t video_port;        /* where the client wants RTP delivered       */
    uint16_t flags;
    /* The client's Ethernet MAC on the link it is talking to us over, so the
     * host can wake it with a magic packet later. has_mac is 0 on a HELLO from
     * an older client that did not send one. */
    uint8_t  mac[6];
    uint8_t  has_mac;
    /* PING / PONG */
    uint64_t token;
    /* STATS */
    ls_stats stats;

    /* CURSOR: position in streamed pixels, origin top left. */
    uint16_t cursor_x;
    uint16_t cursor_y;
    uint8_t  cursor_visible;
    uint16_t cursor_image_id;   /* which bitmap this refers to */

    /* CURSOR_IMAGE: premultiplied RGBA, one row after another.
     * image_offset indexes into the buffer handed to ls_ctrl_parse; nothing is
     * copied, so it is only valid while that buffer is. */
    uint16_t image_width;
    uint16_t image_height;
    uint16_t hotspot_x;
    uint16_t hotspot_y;
    uint16_t image_offset;
    uint32_t image_length;

    /* VOLUME: thousandths, 0 to LS_VOLUME_SCALE. */
    uint16_t volume;
    /* AUDIO_DELAY: milliseconds, signed. */
    int16_t  audio_delay_ms;
    /* BRIGHTNESS: thousandths, 0 to LS_BRIGHTNESS_SCALE. */
    uint16_t brightness;
} ls_ctrl_message;

/* Each builder returns the number of bytes written, or 0 if cap was too small.
 * cap should be at least LS_CTRL_MAX_SIZE. */
/* `mac` may be NULL, in which case the shorter legacy HELLO is written. */
size_t ls_ctrl_build_hello(uint8_t *dst, size_t cap,
                           uint16_t width, uint16_t height,
                           uint16_t video_port, uint16_t flags,
                           const uint8_t *mac);
size_t ls_ctrl_build_bye(uint8_t *dst, size_t cap);
size_t ls_ctrl_build_keyframe_req(uint8_t *dst, size_t cap);
size_t ls_ctrl_build_stats(uint8_t *dst, size_t cap, const ls_stats *stats);
size_t ls_ctrl_build_ping(uint8_t *dst, size_t cap, uint64_t token);
size_t ls_ctrl_build_pong(uint8_t *dst, size_t cap, uint64_t token);

/* Small and sent often -- hundreds of times a second is the point. */
size_t ls_ctrl_build_cursor(uint8_t *dst, size_t cap,
                            uint16_t x, uint16_t y,
                            uint8_t visible, uint16_t image_id);

/* Clamped to LS_VOLUME_SCALE, so a caller cannot ask for amplification. */
size_t ls_ctrl_build_volume(uint8_t *dst, size_t cap, uint16_t volume);

/* Clamped to the range above. */
size_t ls_ctrl_build_audio_delay(uint8_t *dst, size_t cap, int16_t delay_ms);

/* Clamped to LS_BRIGHTNESS_SCALE. */
size_t ls_ctrl_build_brightness(uint8_t *dst, size_t cap, uint16_t brightness);

/* `cap` must be at least LS_CTRL_MAX_PACKET. Returns 0 if the bitmap is larger
 * than LS_CURSOR_MAX_IMAGE_BYTES. */
size_t ls_ctrl_build_cursor_image(uint8_t *dst, size_t cap,
                                  uint16_t image_id,
                                  uint16_t width, uint16_t height,
                                  uint16_t hotspot_x, uint16_t hotspot_y,
                                  const uint8_t *rgba, uint32_t rgba_length);

/* Returns 0 on success, -1 if the datagram is not one of ours. Unknown message
 * types are rejected so a stray packet can never be mistaken for a command. */
int ls_ctrl_parse(const uint8_t *src, size_t len, ls_ctrl_message *out);

/* ---------------------------------------------------------- Wake-on-LAN --- */

#define LS_WOL_PACKET_SIZE 102   /* 6 sync bytes + the MAC repeated 16 times */
#define LS_WOL_PORT        9     /* the discard port, by convention          */

/* Builds a magic packet for `mac`. Returns LS_WOL_PACKET_SIZE, or 0 if cap is
 * too small. The packet is not IP-specific: it is recognised by the NIC itself,
 * which is why it can wake a machine whose OS is asleep. */
size_t ls_wol_build_magic_packet(uint8_t *dst, size_t cap, const uint8_t *mac);

/* Parses "c4:2c:03:07:35:10" or "c4-2c-3-7-35-10" into six bytes.
 * Returns 0 on success, -1 if the string is not a MAC. */
int ls_parse_mac(const char *text, uint8_t *out);

/* Formats six bytes as "c4:2c:03:07:35:10". `cap` must be at least 18. */
size_t ls_format_mac(char *dst, size_t cap, const uint8_t *mac);

#ifdef __cplusplus
}
#endif

#endif /* LS_RTP_PROTOCOL_H */
