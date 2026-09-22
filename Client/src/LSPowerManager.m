//
//  This file is part of LanScreen.
//  Copyright (C) 2026 Kendal Percimoney
//
//  LanScreen is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at your option) any later
//  version.
//
//  LanScreen is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with
//  this program. If not, see <https://www.gnu.org/licenses/>.

#import "LSPowerManager.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation LSPowerManager {
    IOPMAssertionID _assertionID;
    BOOL _held;
}

- (id)init {
    self = [super init];
    if (self) _assertionID = kIOPMNullAssertionID;
    return self;
}

- (void)dealloc { [self endKeepingAwake]; }

- (BOOL)isKeepingAwake { return _held; }

- (void)beginKeepingAwake {
    if (_held) return;

    // PreventUserIdleDisplaySleep rather than PreventSystemSleep: we want the
    // screen lit, and keeping the display awake keeps the system awake anyway.
    // Asserting system sleep alone would leave a black screen on an awake
    // machine, which is the opposite of useful here.
    IOReturn result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("LanScreen is showing a remote display"),
        &_assertionID);

    if (result == kIOReturnSuccess) {
        _held = YES;
        _statusMessage = nil;
        NSLog(@"[LanScreen] holding display-sleep assertion");
    } else {
        _assertionID = kIOPMNullAssertionID;
        _statusMessage = [NSString stringWithFormat:
            @"Could not prevent display sleep (0x%08X). The screen may blank "
            @"during use; set Energy Saver's display sleep to Never as a "
            @"workaround.", result];
        NSLog(@"[LanScreen] %@", _statusMessage);
    }
}

- (void)endKeepingAwake {
    if (!_held) return;
    IOPMAssertionRelease(_assertionID);
    _assertionID = kIOPMNullAssertionID;
    _held = NO;
    NSLog(@"[LanScreen] released display-sleep assertion");
}

- (void)wakeDisplayNow {
    // Declaring user activity is what actually lights a display that has
    // already slept. The returned assertion is short-lived and owned by the
    // system, so it is not ours to release.
    IOPMAssertionID activityID = kIOPMNullAssertionID;
    IOReturn result = IOPMAssertionDeclareUserActivity(
        CFSTR("LanScreen received a frame"), kIOPMUserActiveLocal, &activityID);
    if (result != kIOReturnSuccess) {
        NSLog(@"[LanScreen] could not wake the display (0x%08X)", result);
    }
}

@end
