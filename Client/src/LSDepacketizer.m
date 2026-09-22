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

#import "LSDepacketizer.h"

@implementation LSDepacketizer {
    NSMutableData *_accessUnit;      // AVCC bytes for the frame being built
    NSMutableData *_fragment;        // FU-A reassembly buffer
    NSMutableData *_sps;
    NSMutableData *_pps;

    BOOL     _haveSequence;
    uint16_t _expectedSequence;

    BOOL     _haveTimestamp;
    uint32_t _currentTimestamp;

    BOOL     _accessUnitCorrupt;
    BOOL     _accessUnitHasIDR;
    BOOL     _fragmentActive;

    /// Set after any loss. While true we refuse to hand anything to the
    /// decoder until a fresh IDR arrives -- feeding a decoder P-frames that
    /// reference a picture it never saw is how you get a screen full of green
    /// blocks that never clears.
    BOOL     _waitingForKeyframe;
}

- (id)init {
    self = [super init];
    if (self) {
        _accessUnit = [[NSMutableData alloc] initWithCapacity:512 * 1024];
        _fragment   = [[NSMutableData alloc] initWithCapacity:256 * 1024];
        _waitingForKeyframe = YES;
    }
    return self;
}

- (void)reset {
    [_accessUnit setLength:0];
    [_fragment setLength:0];
    _haveSequence = NO;
    _haveTimestamp = NO;
    _accessUnitCorrupt = NO;
    _accessUnitHasIDR = NO;
    _fragmentActive = NO;
    _waitingForKeyframe = YES;
}

- (void)markDamaged {
    _accessUnitCorrupt = YES;
    _fragmentActive = NO;
    [_fragment setLength:0];
    if (!_waitingForKeyframe) {
        _waitingForKeyframe = YES;
        [_delegate depacketizerNeedsKeyframe:self];
    }
}

#pragma mark - packet entry point

- (void)handlePayload:(const uint8_t *)payload
               length:(size_t)length
                  rtp:(const ls_rtp_packet *)rtp
{
    if (length < 1) return;
    _packetsReceived++;

    // --- sequence continuity ------------------------------------------------
    if (_haveSequence && rtp->sequence != _expectedSequence) {
        // Signed 16-bit difference handles wraparound. A negative gap means a
        // duplicate or a reordered packet; on a direct cable that is vanishing
        // rare, and we treat it as damage either way.
        int16_t gap = (int16_t)(rtp->sequence - _expectedSequence);
        if (gap > 0) {
            _packetsLost += (uint32_t)gap;
        }
        [self markDamaged];
    }
    _expectedSequence = (uint16_t)(rtp->sequence + 1);
    _haveSequence = YES;

    // --- access unit boundaries ---------------------------------------------
    // A timestamp change means the previous frame never got its marker bit,
    // which means we lost the tail of it.
    if (_haveTimestamp && rtp->timestamp != _currentTimestamp) {
        if ([_accessUnit length] > 0 || _fragmentActive) {
            _framesCorrupt++;
            [self markDamaged];
        }
        [self startNewAccessUnitWithTimestamp:rtp->timestamp];
    } else if (!_haveTimestamp) {
        [self startNewAccessUnitWithTimestamp:rtp->timestamp];
    }

    // --- payload ------------------------------------------------------------
    uint8_t type = (uint8_t)LS_NAL_TYPE(payload[0]);

    if (type == LS_NAL_FU_A) {
        [self handleFragment:payload length:length];
    } else if (type == LS_NAL_STAP_A) {
        [self handleSTAPA:payload length:length];
    } else {
        [self appendNAL:payload length:length];
    }

    if (rtp->marker) {
        [self finishAccessUnit];
    }
}

- (void)startNewAccessUnitWithTimestamp:(uint32_t)timestamp {
    [_accessUnit setLength:0];
    _accessUnitCorrupt = NO;
    _accessUnitHasIDR = NO;
    _fragmentActive = NO;
    [_fragment setLength:0];
    _currentTimestamp = timestamp;
    _haveTimestamp = YES;
}

#pragma mark - NAL handling

- (void)appendNAL:(const uint8_t *)nal length:(size_t)length {
    if (length < 1) return;
    uint8_t type = (uint8_t)LS_NAL_TYPE(nal[0]);

    switch (type) {
        case LS_NAL_SPS:
            if (!_sps || [_sps length] != length || memcmp([_sps bytes], nal, length) != 0) {
                _sps = [[NSMutableData alloc] initWithBytes:nal length:length];
            }
            return;   // parameter sets travel in the format description, not the sample

        case LS_NAL_PPS:
            if (!_pps || [_pps length] != length || memcmp([_pps bytes], nal, length) != 0) {
                _pps = [[NSMutableData alloc] initWithBytes:nal length:length];
            }
            return;

        case LS_NAL_AUD:
        case LS_NAL_FILLER:
            return;   // nothing for the decoder to do with these

        case LS_NAL_IDR:
            _accessUnitHasIDR = YES;
            break;

        default:
            break;
    }

    // AVCC framing: 4-byte big-endian length, then the NAL including its header.
    uint8_t prefix[4];
    prefix[0] = (uint8_t)((length >> 24) & 0xFF);
    prefix[1] = (uint8_t)((length >> 16) & 0xFF);
    prefix[2] = (uint8_t)((length >> 8)  & 0xFF);
    prefix[3] = (uint8_t)(length & 0xFF);
    [_accessUnit appendBytes:prefix length:4];
    [_accessUnit appendBytes:nal length:length];
}

- (void)handleFragment:(const uint8_t *)payload length:(size_t)length {
    if (length < 3) { [self markDamaged]; return; }

    uint8_t indicator = payload[0];
    uint8_t header    = payload[1];
    BOOL start = (header & 0x80) != 0;
    BOOL end   = (header & 0x40) != 0;
    uint8_t type = (uint8_t)(header & 0x1F);

    if (start) {
        [_fragment setLength:0];
        // Rebuild the original NAL header: F and NRI from the FU indicator,
        // type from the FU header.
        uint8_t reconstructed = (uint8_t)((indicator & 0xE0) | type);
        [_fragment appendBytes:&reconstructed length:1];
        _fragmentActive = YES;
    } else if (!_fragmentActive) {
        // Middle or end fragment with no start: we lost the head of this NAL.
        [self markDamaged];
        return;
    }

    [_fragment appendBytes:(payload + 2) length:(length - 2)];

    if (end) {
        if (_fragmentActive && [_fragment length] > 1) {
            [self appendNAL:(const uint8_t *)[_fragment bytes] length:[_fragment length]];
        }
        _fragmentActive = NO;
        [_fragment setLength:0];
    }
}

// We never send STAP-A, but a defensive implementation costs ten lines and
// means a future host change cannot silently break the client.
- (void)handleSTAPA:(const uint8_t *)payload length:(size_t)length {
    size_t offset = 1;
    while (offset + 2 <= length) {
        size_t nalSize = ((size_t)payload[offset] << 8) | (size_t)payload[offset + 1];
        offset += 2;
        if (nalSize == 0 || offset + nalSize > length) { [self markDamaged]; return; }
        [self appendNAL:(payload + offset) length:nalSize];
        offset += nalSize;
    }
}

#pragma mark - delivery

- (void)finishAccessUnit {
    if (_accessUnitCorrupt) {
        _framesCorrupt++;
        [_accessUnit setLength:0];
        _accessUnitHasIDR = NO;
        return;
    }
    if ([_accessUnit length] == 0) {
        // Parameter-set-only access unit. Harmless; nothing to decode.
        return;
    }
    if (_waitingForKeyframe) {
        if (!_accessUnitHasIDR) {
            [_accessUnit setLength:0];
            return;     // still resyncing
        }
        _waitingForKeyframe = NO;
    }
    if (!_sps || !_pps) {
        // Cannot build a format description yet. Ask for a keyframe, which is
        // what carries the parameter sets.
        [_accessUnit setLength:0];
        [_delegate depacketizerNeedsKeyframe:self];
        return;
    }

    NSData *frame = [_accessUnit copy];
    BOOL isKeyframe = _accessUnitHasIDR;
    [_accessUnit setLength:0];
    _accessUnitHasIDR = NO;

    [_delegate depacketizer:self
      didCompleteAccessUnit:frame
                        sps:_sps
                        pps:_pps
                  timestamp:_currentTimestamp
                 isKeyframe:isKeyframe];
}

@end
