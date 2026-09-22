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
    _fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (_fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"socket() failed: %s", strerror(errno)]}];
        return NO;
    }

    int on = 1;
    setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    // A keyframe arrives as a burst of hundreds of datagrams back to back. The
    // 8 MB receive buffer is what stops the kernel from discarding the tail of
    // that burst while the decode thread is busy.
    int rcvbuf = 8 * 1024 * 1024;
    if (setsockopt(_fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf)) != 0) {
        // OS X clamps this to net.inet.udp.recvspace / kern.ipc.maxsockbuf.
        // Not fatal, but worth saying out loud because it shows up later as
        // mysterious packet loss under load.
        NSLog(@"[LanScreen] could not set an 8 MB receive buffer (%s). "
              @"Consider: sudo sysctl -w kern.ipc.maxsockbuf=8388608", strerror(errno));
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

    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(receiveLoop) object:nil];
    [_thread setName:@"com.lanscreen.receive"];
    [_thread setThreadPriority:1.0];
    [_thread start];
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

    while (_running) {
        // The autorelease pool is inside the loop on purpose: the depacketizer
        // creates an NSData per completed frame, and at 60 fps a pool that only
        // drains when the thread exits would grow without bound.
        @autoreleasepool {
            ssize_t n = recv(_fd, buffer, capacity, 0);
            if (n <= 0) {
                if (!_running) break;
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
                break;
            }

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
