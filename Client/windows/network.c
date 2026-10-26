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

// The two sockets: RTP video in, control messages both ways.
//
// The video socket gets an 8 MB receive buffer. Winsock's default is 8 KB on
// Windows 7 -- under one 1080p keyframe, which arrives as several hundred
// packets inside a millisecond on a gigabit link. With the default, every
// keyframe would lose packets and ask for another keyframe, for ever.

#include "lswin.h"
#include "ls_depacketizer.h"
#include <iphlpapi.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct LSNetwork {
    LSNetworkConfig config;
    char host[64];
    SOCKET video, control;
    HANDLE video_thread, control_thread;
    volatile LONG running, video_running;

    ls_depacketizer depacketizer;
    ls_net_unit_fn on_unit;
    void *context;
    volatile LONG reset_requested;

    CRITICAL_SECTION send_lock;
    uint64_t last_keyframe_request_us;
    volatile LONG64 last_contact_us;   /* 0 until the host is heard from */

    uint8_t mac[6];
    int have_mac;
};

static uint64_t now_ms(void) { return ls_now_us() / 1000; }

static void heard_from_host(LSNetwork *n) {
    InterlockedExchange64(&n->last_contact_us, (LONG64)ls_now_us());
}

static void unit_ready(void *context, const uint8_t *annexb, size_t length,
                       uint32_t timestamp, int is_keyframe) {
    LSNetwork *n = (LSNetwork *)context;
    n->on_unit(n->context, annexb, length, timestamp, is_keyframe);
}

static void need_keyframe(void *context) {
    ls_network_request_keyframe((LSNetwork *)context);
}

static DWORD WINAPI video_loop(LPVOID parameter) {
    LSNetwork *n = (LSNetwork *)parameter;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    static uint8_t buffer[LS_MAX_UDP_PAYLOAD];
    while (n->video_running) {
        int got = recv(n->video, (char *)buffer, sizeof(buffer), 0);
        if (got <= 0) {
            if (!n->video_running) break;
            // Nothing a UDP socket says here is fatal to it.
            Sleep(1);
            continue;
        }
        if (InterlockedExchange(&n->reset_requested, 0)) ls_depacketizer_reset(&n->depacketizer);
        heard_from_host(n);
        ls_rtp_packet rtp;
        if (ls_rtp_parse(buffer, (size_t)got, &rtp) != 0) continue;
        ls_depacketizer_handle(&n->depacketizer, buffer + rtp.payload_offset,
                               rtp.payload_length, &rtp, now_ms());
    }
    return 0;
}

static DWORD WINAPI control_loop(LPVOID parameter) {
    LSNetwork *n = (LSNetwork *)parameter;
    uint8_t *buffer = (uint8_t *)malloc(LS_CTRL_MAX_PACKET);
    if (!buffer) return 1;
    while (n->running) {
        int got = recv(n->control, (char *)buffer, LS_CTRL_MAX_PACKET, 0);
        if (got <= 0) {
            if (!n->running) break;
            // WSAECONNRESET is Windows passing on "port unreachable" for an
            // earlier send: the host is not running yet. It may well start.
            Sleep(got == SOCKET_ERROR && WSAGetLastError() == WSAECONNRESET ? 200 : 2);
            continue;
        }
        ls_ctrl_message message;
        if (ls_ctrl_parse(buffer, (size_t)got, &message) != 0) continue;
        heard_from_host(n);
        if (message.type == LS_MSG_PING) {
            uint8_t reply[LS_CTRL_MAX_SIZE];
            size_t length = ls_ctrl_build_pong(reply, sizeof(reply), message.token);
            EnterCriticalSection(&n->send_lock);
            send(n->control, (const char *)reply, (int)length, 0);
            LeaveCriticalSection(&n->send_lock);
        }
        // Everything else -- pointer, volume, brightness, input status -- is
        // for later phases.
    }
    free(buffer);
    return 0;
}

/* The MAC of the adapter the control socket actually leaves by, so the host
 * can wake this machine later. Asking which local address the connected socket
 * got avoids guessing which of the iMac's adapters is the cable. */
static void find_mac(LSNetwork *n) {
    struct sockaddr_in local;
    int length = sizeof(local);
    if (getsockname(n->control, (struct sockaddr *)&local, &length) != 0) return;

    ULONG size = 16 * 1024;
    IP_ADAPTER_ADDRESSES *adapters = NULL;
    for (int attempt = 0; attempt < 3; attempt++) {
        adapters = (IP_ADAPTER_ADDRESSES *)malloc(size);
        if (!adapters) return;
        ULONG result = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST
                                            | GAA_FLAG_SKIP_DNS_SERVER, NULL, adapters, &size);
        if (result == NO_ERROR) break;
        free(adapters); adapters = NULL;
        if (result != ERROR_BUFFER_OVERFLOW) return;
    }
    if (!adapters) return;
    for (IP_ADAPTER_ADDRESSES *a = adapters; a && !n->have_mac; a = a->Next) {
        for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
            struct sockaddr_in *address = (struct sockaddr_in *)u->Address.lpSockaddr;
            if (address->sin_family == AF_INET && address->sin_addr.s_addr == local.sin_addr.s_addr
                && a->PhysicalAddressLength == 6) {
                memcpy(n->mac, a->PhysicalAddress, 6);
                n->have_mac = 1;
                char text[18];
                ls_format_mac(text, sizeof(text), n->mac);
                char ip[32];
                inet_ntop(AF_INET, &local.sin_addr, ip, sizeof(ip));
                ls_log("reaching the host from %s over \"%ls\" (%s)", ip, a->FriendlyName, text);
                break;
            }
        }
    }
    free(adapters);
    if (!n->have_mac) ls_log("could not tell which adapter reaches the host; the host will not be able to wake this machine");
}

LSNetwork *ls_network_start(const LSNetworkConfig *config, ls_net_unit_fn on_unit,
                            void *context, char *error, size_t error_size) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        snprintf(error, error_size, "Winsock would not start");
        return NULL;
    }
    LSNetwork *n = (LSNetwork *)calloc(1, sizeof(*n));
    if (!n) { snprintf(error, error_size, "out of memory"); WSACleanup(); return NULL; }
    n->config = *config;
    snprintf(n->host, sizeof(n->host), "%s", config->host);
    n->config.host = n->host;
    n->on_unit = on_unit;
    n->context = context;
    n->video = n->control = INVALID_SOCKET;
    InitializeCriticalSection(&n->send_lock);
    ls_depacketizer_init(&n->depacketizer, unit_ready, need_keyframe, n);

    n->video = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int buffer_size = 8 << 20;
    setsockopt(n->video, SOL_SOCKET, SO_RCVBUF, (const char *)&buffer_size, sizeof(buffer_size));
    int actual = 0, actual_length = sizeof(actual);
    getsockopt(n->video, SOL_SOCKET, SO_RCVBUF, (char *)&actual, &actual_length);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(config->video_port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(n->video, (struct sockaddr *)&address, sizeof(address)) != 0) {
        snprintf(error, error_size, "could not listen for video on port %u (error %d); "
                 "is another copy running?", (unsigned)config->video_port, WSAGetLastError());
        ls_network_stop(n);
        return NULL;
    }
    ls_log("listening for video on port %u, receive buffer %d KB",
           (unsigned)config->video_port, actual / 1024);

    n->control = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in host;
    memset(&host, 0, sizeof(host));
    host.sin_family = AF_INET;
    host.sin_port = htons(config->control_port);
    if (inet_pton(AF_INET, config->host, &host.sin_addr) != 1) {
        snprintf(error, error_size, "'%s' is not an IPv4 address", config->host);
        ls_network_stop(n);
        return NULL;
    }
    // Connected, so the kernel picks the source port and the host replies to
    // whatever it sees; and getsockname then says which adapter we leave by.
    if (connect(n->control, (struct sockaddr *)&host, sizeof(host)) != 0) {
        snprintf(error, error_size, "no route to the host at %s (error %d); "
                 "is the cable in and this adapter set to 10.0.0.2?", config->host, WSAGetLastError());
        ls_network_stop(n);
        return NULL;
    }
    find_mac(n);

    n->running = n->video_running = 1;
    n->video_thread = CreateThread(NULL, 0, video_loop, n, 0, NULL);
    n->control_thread = CreateThread(NULL, 0, control_loop, n, 0, NULL);
    return n;
}

void ls_network_stop_video(LSNetwork *n) {
    if (!n || !n->video_thread) return;
    n->video_running = 0;
    closesocket(n->video);
    n->video = INVALID_SOCKET;
    WaitForSingleObject(n->video_thread, 2000);
    CloseHandle(n->video_thread);
    n->video_thread = NULL;
}

void ls_network_stop(LSNetwork *n) {
    if (!n) return;
    ls_network_stop_video(n);
    if (n->running && n->control != INVALID_SOCKET) {
        uint8_t buffer[LS_CTRL_MAX_SIZE];
        size_t length = ls_ctrl_build_bye(buffer, sizeof(buffer));
        send(n->control, (const char *)buffer, (int)length, 0);
    }
    n->running = 0;
    // Closing the sockets is what wakes the threads out of recv.
    if (n->video != INVALID_SOCKET) closesocket(n->video);
    if (n->control != INVALID_SOCKET) closesocket(n->control);
    HANDLE threads[2];
    DWORD count = 0;
    if (n->video_thread) threads[count++] = n->video_thread;
    if (n->control_thread) threads[count++] = n->control_thread;
    if (count) WaitForMultipleObjects(count, threads, TRUE, 2000);
    for (DWORD i = 0; i < count; i++) CloseHandle(threads[i]);
    ls_depacketizer_free(&n->depacketizer);
    DeleteCriticalSection(&n->send_lock);
    free(n);
    WSACleanup();
}

static void send_message(LSNetwork *n, const uint8_t *bytes, size_t length) {
    if (length == 0) return;
    EnterCriticalSection(&n->send_lock);
    send(n->control, (const char *)bytes, (int)length, 0);
    LeaveCriticalSection(&n->send_lock);
}

void ls_network_send_hello(LSNetwork *n) {
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    // No flags: this client cannot yet draw the pointer, play audio, set the
    // panel's brightness or send input, so the host burns the pointer into
    // the video, sends no audio, and greys out the controls that would need
    // the rest.
    size_t length = ls_ctrl_build_hello(buffer, sizeof(buffer), n->config.screen_width,
                                        n->config.screen_height, n->config.video_port, 0,
                                        n->have_mac ? n->mac : NULL);
    send_message(n, buffer, length);
}

void ls_network_request_keyframe(LSNetwork *n) {
    uint64_t now = ls_now_us();
    EnterCriticalSection(&n->send_lock);
    int due = now - n->last_keyframe_request_us >= 100000;
    if (due) n->last_keyframe_request_us = now;
    LeaveCriticalSection(&n->send_lock);
    if (!due) return;
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    send_message(n, buffer, ls_ctrl_build_keyframe_req(buffer, sizeof(buffer)));
}

void ls_network_send_stats(LSNetwork *n, ls_stats *stats) {
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    send_message(n, buffer, ls_ctrl_build_stats(buffer, sizeof(buffer), stats));
}

void ls_network_counters(LSNetwork *n, ls_stats *stats) {
    // Written by the receive thread, read here: aligned 32-bit values, so a
    // read is never torn, and a count one packet stale does not matter.
    stats->packets_received = n->depacketizer.packets_received;
    stats->packets_lost = n->depacketizer.packets_lost;
    stats->frames_corrupt = n->depacketizer.frames_corrupt;
}

int64_t ls_network_ms_since_contact(LSNetwork *n) {
    LONG64 last = InterlockedCompareExchange64(&n->last_contact_us, 0, 0);
    return last ? (int64_t)(ls_now_us() - (uint64_t)last) / 1000 : -1;
}

int64_t ls_network_partial_frame_ms(LSNetwork *n) {
    uint64_t since = n->depacketizer.partial_since_ms;
    return since ? (int64_t)(now_ms() - since) : 0;
}

void ls_network_reset_stream(LSNetwork *n) {
    InterlockedExchange(&n->reset_requested, 1);
}
