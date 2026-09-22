#import "LSControlClient.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

@implementation LSControlClient {
    NSString *_host;
    uint16_t _port;
    int _fd;
    NSThread *_thread;
    volatile BOOL _running;
    NSTimeInterval _lastKeyframeRequest;
    NSLock *_sendLock;
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

    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(receiveLoop) object:nil];
    [_thread setName:@"com.lanscreen.control"];
    [_thread start];
    return YES;
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
    size_t n = ls_ctrl_build_hello(buffer, sizeof(buffer), width, height, videoPort, 0);
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
    uint8_t buffer[LS_CTRL_MAX_SIZE * 4];

    while (_running) {
        @autoreleasepool {
            ssize_t n = recv(_fd, buffer, sizeof(buffer), 0);
            if (n <= 0) {
                if (!_running) break;
                if (errno == EINTR) continue;
                // ECONNREFUSED here means the host's control port is closed --
                // it has quit. Keep looping; the app notices via lastHostContact.
                if (errno == ECONNREFUSED) { usleep(200000); continue; }
                break;
            }

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
                case LS_MSG_BYE:
                    if (self.hostSaidGoodbye) self.hostSaidGoodbye();
                    break;
                default:
                    break;
            }
        }
    }
}

@end
