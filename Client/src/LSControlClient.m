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

#import "LSControlClient.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>

@implementation LSControlClient {
    NSString *_host;
    uint16_t _port;
    int _fd;
    NSThread *_thread;
    volatile BOOL _running;
    NSTimeInterval _lastKeyframeRequest;
    NSLock *_sendLock;
    uint8_t _localMAC[6];
    BOOL _haveLocalMAC;
}

- (id)initWithHost:(NSString *)host port:(uint16_t)port {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _fd = -1;
        _sendLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)start:(NSError **)error {
    _fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (_fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"control socket() failed: %s", strerror(errno)]}];
        return NO;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    if (inet_pton(AF_INET, [_host UTF8String], &addr.sin_addr) != 1) {
        close(_fd); _fd = -1;
        if (error) *error = [NSError errorWithDomain:@"LanScreen" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"'%@' is not a valid IPv4 address", _host]}];
        return NO;
    }

    // Binding to the same port we send to would collide with the host on a
    // loopback test, so let the kernel pick our source port. The host replies
    // to whatever it sees.
    if (connect(_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int e = errno;
        close(_fd); _fd = -1;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:e
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"control connect() failed: %s", strerror(e)]}];
        return NO;
    }

    [self discoverLocalMAC];

    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(receiveLoop) object:nil];
    [_thread setName:@"com.lanscreen.control"];
    [_thread start];
    return YES;
}

/// Works out which NIC we are actually reaching the host over, and reads its
/// hardware address.
///
/// Guessing "en0" would be wrong often enough to matter: on this machine the
/// direct link might be built-in Ethernet, a Thunderbolt adapter or a USB one.
/// Asking the kernel which local address the connected socket ended up with
/// removes the guesswork, and the MAC we report is then guaranteed to be the
/// NIC that will have to hear the magic packet.
- (void)discoverLocalMAC {
    _haveLocalMAC = NO;

    struct sockaddr_in local;
    socklen_t length = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (getsockname(_fd, (struct sockaddr *)&local, &length) != 0) {
        NSLog(@"[LanScreen] getsockname failed: %s", strerror(errno));
        return;
    }

    struct ifaddrs *addresses = NULL;
    if (getifaddrs(&addresses) != 0) {
        NSLog(@"[LanScreen] getifaddrs failed: %s", strerror(errno));
        return;
    }

    char wanted[IFNAMSIZ];
    memset(wanted, 0, sizeof(wanted));

    struct ifaddrs *entry;
    for (entry = addresses; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        struct sockaddr_in *candidate = (struct sockaddr_in *)entry->ifa_addr;
        if (candidate->sin_addr.s_addr == local.sin_addr.s_addr) {
            strncpy(wanted, entry->ifa_name, sizeof(wanted) - 1);
            break;
        }
    }

    if (wanted[0]) {
        for (entry = addresses; entry; entry = entry->ifa_next) {
            if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_LINK) continue;
            if (strcmp(entry->ifa_name, wanted) != 0) continue;
            struct sockaddr_dl *link = (struct sockaddr_dl *)entry->ifa_addr;
            if (link->sdl_alen == 6) {
                const uint8_t *bytes = (const uint8_t *)LLADDR(link);
                // macOS 11 and later hand unentitled apps a masked placeholder
                // (02:00:00:00:00:00) instead of the real hardware address.
                // OS X 10.9 has no such restriction, so this should never fire
                // on the intended target -- but sending a placeholder to the
                // host would have it store a wake address that can never work,
                // which is worse than admitting we do not know.
                static const uint8_t masked[6] = {0x02, 0, 0, 0, 0, 0};
                static const uint8_t zero[6]   = {0, 0, 0, 0, 0, 0};
                if (memcmp(bytes, masked, 6) == 0 || memcmp(bytes, zero, 6) == 0) {
                    NSLog(@"[LanScreen] the OS masked this machine's MAC address; "
                          @"not reporting it to the host");
                } else {
                    memcpy(_localMAC, bytes, 6);
                    _haveLocalMAC = YES;
                }
            }
            break;
        }
    }

    freeifaddrs(addresses);

    if (_haveLocalMAC) {
        char text[18];
        ls_format_mac(text, sizeof(text), _localMAC);
        _localMACString = [NSString stringWithUTF8String:text];
        NSLog(@"[LanScreen] reaching the host over %s (%@)", wanted, _localMACString);
    } else {
        NSLog(@"[LanScreen] could not determine this machine's MAC; "
              @"the host will not be able to wake it automatically");
    }
}

- (void)stop {
    if (_fd >= 0 && _running) {
        uint8_t buffer[LS_CTRL_MAX_SIZE];
        size_t n = ls_ctrl_build_bye(buffer, sizeof(buffer));
        if (n > 0) send(_fd, buffer, n, 0);
    }
    _running = NO;
    if (_fd >= 0) {
        shutdown(_fd, SHUT_RDWR);
        close(_fd);
        _fd = -1;
    }
    while (_thread && ![_thread isFinished]) usleep(1000);
    _thread = nil;
}

- (void)sendBytes:(const uint8_t *)bytes length:(size_t)length {
    if (_fd < 0 || length == 0) return;
    [_sendLock lock];
    send(_fd, bytes, length, 0);
    [_sendLock unlock];
}

- (void)sendHelloWithWidth:(uint16_t)width height:(uint16_t)height videoPort:(uint16_t)videoPort {
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    // Tell the host this build draws the pointer itself. A host that forwards
    // the pointer to a client that cannot draw it would leave no pointer on
    // screen anywhere.
    size_t n = ls_ctrl_build_hello(buffer, sizeof(buffer), width, height, videoPort,
                                   LS_CLIENT_FLAG_DRAWS_CURSOR,
                                   _haveLocalMAC ? _localMAC : NULL);
    [self sendBytes:buffer length:n];
}

- (void)requestKeyframe {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastKeyframeRequest < 0.1) return;
    _lastKeyframeRequest = now;

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_keyframe_req(buffer, sizeof(buffer));
    [self sendBytes:buffer length:n];
}

- (void)sendStats:(const ls_stats *)stats {
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_stats(buffer, sizeof(buffer), stats);
    [self sendBytes:buffer length:n];
}

- (void)receiveLoop {
    // Sized for the largest message rather than the common one: a cursor bitmap
    // is 16 KB, everything else is a few dozen bytes.
    uint8_t *buffer = (uint8_t *)malloc(LS_CTRL_MAX_PACKET);
    if (!buffer) return;
    int consecutiveErrors = 0;

    while (_running) {
        @autoreleasepool {
            ssize_t n = recv(_fd, buffer, LS_CTRL_MAX_PACKET, 0);
            if (n <= 0) {
                if (!_running) break;
                int code = errno;
                if (code == EINTR) continue;
                // ECONNREFUSED means the host's control port is closed -- it has
                // quit, or has not started yet. Keep looping; the app notices
                // via lastHostContact, and the host may well come back.
                if (code == ECONNREFUSED) { usleep(200000); continue; }
                // Anything unexpected used to end the loop for good, which
                // silently killed this socket for the rest of the session. A
                // UDP socket can surface transient errors that say nothing
                // about its health, so only a socket that is genuinely gone is
                // fatal; everything else is logged and retried.
                if (code == EBADF || code == ENOTSOCK) {
                    NSLog(@"[LanScreen] control socket closed (%s)", strerror(code));
                    break;
                }
                consecutiveErrors++;
                if (consecutiveErrors == 1 || consecutiveErrors % 50 == 0) {
                    NSLog(@"[LanScreen] control receive error, continuing (%s, %d in a row)",
                          strerror(code), consecutiveErrors);
                }
                if (consecutiveErrors > 500) {
                    NSLog(@"[LanScreen] control socket is not recovering, giving up");
                    break;
                }
                usleep(2000);
                continue;
            }
            consecutiveErrors = 0;

            ls_ctrl_message message;
            if (ls_ctrl_parse(buffer, (size_t)n, &message) != 0) continue;

            _lastHostContact = [NSDate timeIntervalSinceReferenceDate];

            switch (message.type) {
                case LS_MSG_PING: {
                    // Echo the token untouched. The host measures RTT against
                    // its own clock, so the two machines never need synced time.
                    uint8_t reply[LS_CTRL_MAX_SIZE];
                    size_t len = ls_ctrl_build_pong(reply, sizeof(reply), message.token);
                    [self sendBytes:reply length:len];
                    break;
                }
                case LS_MSG_CURSOR:
                    if (self.cursorMoved) {
                        self.cursorMoved(message.cursor_x, message.cursor_y,
                                         message.cursor_visible != 0,
                                         message.cursor_image_id);
                    }
                    break;

                case LS_MSG_CURSOR_IMAGE:
                    if (self.cursorImageChanged) {
                        NSData *rgba = [NSData dataWithBytes:(buffer + message.image_offset)
                                                      length:message.image_length];
                        self.cursorImageChanged(message.cursor_image_id,
                                                message.image_width, message.image_height,
                                                message.hotspot_x, message.hotspot_y, rgba);
                    }
                    break;

                case LS_MSG_BYE:
                    if (self.hostSaidGoodbye) self.hostSaidGoodbye();
                    break;
                default:
                    break;
            }
        }
    }

    free(buffer);
}

@end
