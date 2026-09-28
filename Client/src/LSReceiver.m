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

#import "LSReceiver.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

@implementation LSReceiver {
    uint16_t _port;
    LSDepacketizer *_depacketizer;
    int _fd;
    NSThread *_thread;
    volatile BOOL _running;
    /// How many times the socket had to be replaced. Reported, because a
    /// stream that keeps needing this is a different problem from one that
    /// never does, and neither used to leave any trace.
    uint32_t _socketRestarts;
}

- (id)initWithPort:(uint16_t)port depacketizer:(LSDepacketizer *)depacketizer {
    self = [super init];
    if (self) {
        _port = port;
        _depacketizer = depacketizer;
        _fd = -1;
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)start:(NSError **)error {
    if (![self openSocket:error]) return NO;

    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(receiveLoop) object:nil];
    [_thread setName:@"com.lanscreen.receive"];
    [_thread setThreadPriority:1.0];
    [_thread start];
    return YES;
}

/// Creates and binds the socket. Split out from -start: so the receive loop can
/// do it again: a socket that has stopped working is worth replacing, and the
/// loop used to simply end instead, which left the iMac showing the last frame
/// it received for the rest of the session with one line in the log to say why.
- (BOOL)openSocket:(NSError **)error {
    if (_fd >= 0) { close(_fd); _fd = -1; }
    _fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (_fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"socket() failed: %s", strerror(errno)]}];
        return NO;
    }

    int on = 1;
    setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    // A large frame arrives as hundreds of datagrams back to back -- a 1080p
    // keyframe is around 490 KB, which is some 360 packets. The receive buffer
    // is what absorbs that while the decode thread is busy with the previous
    // frame.
    //
    // This used to ask for 8 MB once and give up if that failed, which was a
    // bad bug: the kernel refuses the whole request when it exceeds
    // kern.ipc.maxsockbuf rather than granting what it can, and OS X 10.9
    // defaults that ceiling to 4 MB. So on the intended target the call failed
    // and the socket was left at the default receive space -- tens of
    // kilobytes, a couple of dozen packets. Everything beyond that was dropped
    // on every large frame, which looks like blocky corruption whenever the
    // picture gets busy.
    //
    // Ask for progressively less until something is granted, then read back
    // what we actually got rather than assuming.
    static const int kCandidates[] = {
        16 * 1024 * 1024, 8 * 1024 * 1024, 4 * 1024 * 1024,
        2 * 1024 * 1024, 1024 * 1024, 512 * 1024, 256 * 1024
    };
    for (size_t i = 0; i < sizeof(kCandidates) / sizeof(kCandidates[0]); i++) {
        int wanted = kCandidates[i];
        if (setsockopt(_fd, SOL_SOCKET, SO_RCVBUF, &wanted, sizeof(wanted)) == 0) break;
    }
    int granted = 0;
    socklen_t grantedSize = sizeof(granted);
    if (getsockopt(_fd, SOL_SOCKET, SO_RCVBUF, &granted, &grantedSize) == 0) {
        _receiveBufferBytes = granted;
    }

    if (_receiveBufferBytes >= 1024 * 1024) {
        NSLog(@"[LanScreen] receive buffer: %d KB", _receiveBufferBytes / 1024);
    } else {
        NSLog(@"[LanScreen] receive buffer is only %d KB, which is too small to "
              @"absorb a keyframe. Expect blocky corruption on busy pictures. "
              @"Fix with: sudo sysctl -w kern.ipc.maxsockbuf=8388608",
              _receiveBufferBytes / 1024);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        int e = errno;
        close(_fd); _fd = -1;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:e
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Could not bind UDP port %u: %s",
                 (unsigned)_port, strerror(e)]}];
        return NO;
    }

    return YES;
}

- (void)stop {
    _running = NO;
    if (_fd >= 0) {
        shutdown(_fd, SHUT_RDWR);
        close(_fd);
        _fd = -1;
    }
    while (_thread && ![_thread isFinished]) usleep(1000);
    _thread = nil;
}

- (void)receiveLoop {
    // One buffer for the life of the thread. Sized for jumbo frames so the
    // 8900-byte packet mode works without reallocating.
    const size_t capacity = LS_MAX_UDP_PAYLOAD;
    uint8_t *buffer = (uint8_t *)malloc(capacity);
    if (!buffer) return;
    int consecutiveErrors = 0;

    while (_running) {
        // The autorelease pool is inside the loop on purpose: the depacketizer
        // creates an NSData per completed frame, and at 60 fps a pool that only
        // drains when the thread exits would grow without bound.
        @autoreleasepool {
            ssize_t n = recv(_fd, buffer, capacity, 0);
            if (n <= 0) {
                if (!_running) break;
                int code = errno;
                if (code == EINTR || code == EAGAIN || code == EWOULDBLOCK) continue;
                // Anything unexpected used to end the loop for good, which
                // silently killed this socket for the rest of the session. A
                // UDP socket can surface transient errors that say nothing
                // about its health, so only a socket that is genuinely gone is
                // fatal; everything else is logged and retried.
                consecutiveErrors++;
                if (consecutiveErrors == 1 || consecutiveErrors % 50 == 0) {
                    NSLog(@"[LanScreen] video receive error, continuing (%s, %d in a row)",
                          strerror(code), consecutiveErrors);
                }
                // A socket that is gone, or one that has failed several hundred
                // times running, is replaced rather than abandoned. Giving up
                // here is indistinguishable from a freeze: the picture stops
                // and the app goes on running as if nothing happened.
                if (code == EBADF || code == ENOTSOCK || consecutiveErrors > 500) {
                    _socketRestarts++;
                    NSLog(@"[LanScreen] video socket is not working (%s); "
                          @"reopening it (restart %u)", strerror(code), _socketRestarts);
                    NSError *reopenError = nil;
                    if (![self openSocket:&reopenError]) {
                        NSLog(@"[LanScreen] could not reopen the video socket: %@; "
                              @"retrying in a second", [reopenError localizedDescription]);
                        usleep(1000000);
                    } else {
                        consecutiveErrors = 0;
                    }
                    continue;
                }
                usleep(2000);
                continue;
            }
            consecutiveErrors = 0;

            _bytesReceived += (uint64_t)n;
            _lastPacketTime = [NSDate timeIntervalSinceReferenceDate];

            ls_rtp_packet packet;
            if (ls_rtp_parse(buffer, (size_t)n, &packet) != 0) {
                continue;   // not ours, or malformed
            }
            [_depacketizer handlePayload:(buffer + packet.payload_offset)
                                  length:packet.payload_length
                                     rtp:&packet];
        }
    }

    free(buffer);
}

@end
