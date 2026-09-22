//
//  LSDepacketizer.h
//  Reassembles RFC 6184 RTP payloads into H.264 access units.
//
//  Targets the OS X 10.9 SDK: no nullability annotations, no lightweight
//  generics, nothing newer than Xcode 6.2 understands.
//
#import <Foundation/Foundation.h>
#include "rtp_protocol.h"

@class LSDepacketizer;

@protocol LSDepacketizerDelegate <NSObject>
/// A complete, uncorrupted access unit in AVCC form (4-byte big-endian length
/// prefixes). SPS/PPS are delivered separately and are NOT part of avcc.
- (void)depacketizer:(LSDepacketizer *)depacketizer
 didCompleteAccessUnit:(NSData *)avcc
                   sps:(NSData *)sps
                   pps:(NSData *)pps
             timestamp:(uint32_t)timestamp
           isKeyframe:(BOOL)isKeyframe;
/// Called when the stream has been damaged and only a fresh IDR can fix it.
- (void)depacketizerNeedsKeyframe:(LSDepacketizer *)depacketizer;
@end


@interface LSDepacketizer : NSObject

@property (nonatomic, assign) id<LSDepacketizerDelegate> delegate;   // unretained

/// Feed one parsed RTP packet. Call from the receive thread only.
- (void)handlePayload:(const uint8_t *)payload
               length:(size_t)length
                  rtp:(const ls_rtp_packet *)rtp;

/// Throw away partial state, e.g. after a long stall.
- (void)reset;

@property (nonatomic, readonly) uint32_t packetsReceived;
@property (nonatomic, readonly) uint32_t packetsLost;
@property (nonatomic, readonly) uint32_t framesCorrupt;

@end
