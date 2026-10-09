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

#import "LSDecodeQueue.h"

@implementation LSDecodeQueue {
    NSMutableArray *_units;
    NSUInteger _depth;
}

- (id)initWithDepth:(NSUInteger)depth {
    self = [super init];
    if (self) {
        _units = [[NSMutableArray alloc] initWithCapacity:depth + 1];
        _depth = depth > 0 ? depth : 1;
    }
    return self;
}

- (NSUInteger)count { return [_units count]; }

- (void)push:(id)unit isKeyframe:(BOOL)isKeyframe {
    if (!unit) return;

    if (isKeyframe) {
        // A keyframe depends on nothing, so it ends any wait. Anything still
        // queued ahead of it is older and now pointless to decode -- showing
        // it would only put the picture further behind -- so the decoder goes
        // straight to the keyframe.
        _dropped += (uint32_t)[_units count];
        [_units removeAllObjects];
        _waitingForKeyframe = NO;
        [_units addObject:unit];
        return;
    }

    if (_waitingForKeyframe) {
        // It follows a frame that was never decoded.
        _dropped++;
        return;
    }

    if ([_units count] >= _depth) {
        // Full. The newest goes, not the oldest: the frames already waiting
        // are a complete chain and still decode correctly. Everything from
        // here waits for a keyframe.
        _dropped++;
        _overflows++;
        [self beginWaitingForKeyframe];
        return;
    }

    [_units addObject:unit];
}

- (id)pop {
    if ([_units count] == 0) return nil;
    id unit = [_units objectAtIndex:0];
    [_units removeObjectAtIndex:0];
    return unit;
}

- (void)decodeFailed {
    // What is queued was built on the frame that failed.
    _dropped += (uint32_t)[_units count];
    [_units removeAllObjects];
    [self beginWaitingForKeyframe];
}

- (void)beginWaitingForKeyframe {
    _waitingForKeyframe = YES;
}

@end
