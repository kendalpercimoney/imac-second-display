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
#define LS_CTRL_MAX_SIZE    128

enum {
    LS_MSG_HELLO        = 1,  /* client -> host: I am here, this is my screen */
    LS_MSG_BYE          = 2,  /* either way: tearing down                     */
    LS_MSG_KEYFRAME_REQ = 3,  /* client -> host: my stream is broken, IDR now */
    LS_MSG_STATS        = 4,  /* client -> host: once a second                */
    LS_MSG_PING         = 5,  /* host -> client: opaque token                 */
    LS_MSG_PONG         = 6   /* client -> host: same token echoed back       */
};

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
