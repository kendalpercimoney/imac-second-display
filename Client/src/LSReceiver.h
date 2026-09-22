//
//  LSReceiver.h
//  Bound UDP socket plus a tight receive loop.
//
//  The only job of this thread is to get packets out of the kernel and into the
//  depacketizer. Nothing slow happens here -- decoding lives on its own thread
//  precisely so a long decode can never cause a socket buffer overrun.
//
#import <Foundation/Foundation.h>
#import "LSDepacketizer.h"

@interface LSReceiver : NSObject

- (id)initWithPort:(uint16_t)port depacketizer:(LSDepacketizer *)depacketizer;

- (BOOL)start:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) uint64_t bytesReceived;
/// Wall-clock time of the last datagram, for "has the host gone away" checks.
@property (nonatomic, readonly) NSTimeInterval lastPacketTime;

@end
