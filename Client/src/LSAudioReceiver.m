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

#import "LSAudioReceiver.h"
#import "rtp_protocol.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

@implementation LSAudioReceiver {
    int       _fd;
    uint16_t  _port;
    LSAudioPlayer *_player;
    NSThread *_thread;
    BOOL      _running;
    BOOL      _haveSequence;
    uint16_t  _expectedSequence;
}

- (id)initWithPort:(uint16_t)port player:(LSAudioPlayer *)player {
    if (!(self = [super init])) return nil;
    _fd = -1;
    _port = port;
    _player = player;
    return self;
}

- (void)dealloc {
    [self stop];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (BOOL)start:(NSError **)error {
    _fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (_fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"LanScreen.Audio" code:errno userInfo:
            @{NSLocalizedDescriptionKey:
              [NSString stringWithFormat:@"audio socket() failed: %s", strerror(errno)]}];
        return NO;
    }

    int reuse = 1;
    setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    // A quarter of a second of audio is ample: unlike video there is no burst
    // to absorb, packets arrive at a steady 187 a second.
    int wanted = 256 * 1024;
    setsockopt(_fd, SOL_SOCKET, SO_RCVBUF, &wanted, sizeof(wanted));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(_port);
    if (bind(_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        if (error) *error = [NSError errorWithDomain:@"LanScreen.Audio" code:errno userInfo:
            @{NSLocalizedDescriptionKey:
              [NSString stringWithFormat:@"could not bind audio port %u: %s",
               (unsigned)_port, strerror(errno)]}];
        close(_fd); _fd = -1;
        return NO;
    }

    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(receiveLoop) object:nil];
    [_thread setName:@"LanScreen audio receive"];
    [_thread setThreadPriority:1.0];
    [_thread start];
    return YES;
}

- (void)stop {
    _running = NO;
    if (_fd >= 0) {
        // Shutting the socket down wakes the blocking recvfrom so the thread
        // can notice it should leave.
        shutdown(_fd, SHUT_RDWR);
        close(_fd);
        _fd = -1;
    }
    _thread = nil;
}

- (void)receiveLoop {
    uint8_t packet[LS_AUDIO_MAX_PACKET];
    ls_audio_packet parsed;

    while (_running && _fd >= 0) {
        ssize_t n = recvfrom(_fd, packet, sizeof(packet), 0, NULL, NULL);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            break;
        }
        _bytesReceived += (uint64_t)n;

        if (ls_audio_parse(packet, (size_t)n, &parsed) != 0) continue;
        _packetsReceived++;

        if (_haveSequence) {
            uint16_t gap = (uint16_t)(parsed.sequence - _expectedSequence);
            // A small forward gap is loss. A large one is the host restarting,
            // and treating that as half a million lost packets would be a lie.
            if (gap > 0 && gap < 1024) _packetsLost += gap;
        }
        _expectedSequence = (uint16_t)(parsed.sequence + 1);
        _haveSequence = YES;

        uint32_t frameBytes = (uint32_t)parsed.channels * 2u;
        if (frameBytes == 0 || parsed.payload_length == 0) continue;
        [_player enqueueSamples:(const int16_t *)(packet + parsed.payload_offset)
                         frames:parsed.payload_length / frameBytes];
    }
}

@end
