//
//  LSControlClient.h
//  The other half of the back-channel.
//
//  One socket, connected to the host's control port, used in both directions.
//  Connecting means the host learns our address from the source of our HELLO
//  and can ping us without any configuration on its side.
//
#import <Foundation/Foundation.h>
#include "rtp_protocol.h"

@interface LSControlClient : NSObject

- (id)initWithHost:(NSString *)host port:(uint16_t)port;

- (BOOL)start:(NSError **)error;
- (void)stop;

/// Announce ourselves and ask for an immediate keyframe.
- (void)sendHelloWithWidth:(uint16_t)width height:(uint16_t)height videoPort:(uint16_t)videoPort;

/// Rate-limited internally to at most one per 100 ms: a burst of loss would
/// otherwise turn into a burst of keyframes, which is its own kind of outage.
- (void)requestKeyframe;

- (void)sendStats:(const ls_stats *)stats;

/// Fired on the control thread when the host says goodbye.
@property (nonatomic, copy) void (^hostSaidGoodbye)(void);

@property (nonatomic, readonly) NSTimeInterval lastHostContact;

@end
