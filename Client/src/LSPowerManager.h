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

//
//  LSPowerManager.h
//  Keeps the iMac awake for as long as it is showing a stream.
//
//  Without this the iMac has no idea anything is happening: there is no
//  keyboard or mouse activity on it, so Energy Saver puts the display to sleep
//  on its usual timer and the second monitor goes black mid-use. A power
//  assertion tells the OS "something is genuinely going on here".
//
//  The assertion is released the moment the stream stops, so the iMac sleeps
//  normally when you are not using it. It is not a way to keep the machine
//  awake forever.
//
#import <Foundation/Foundation.h>

@interface LSPowerManager : NSObject

/// Idempotent. Safe to call on every frame if that is convenient.
- (void)beginKeepingAwake;
- (void)endKeepingAwake;

/// Wakes the display if it has already gone to sleep. Use when a stream starts
/// arriving -- the assertion below prevents future sleep but does not undo
/// sleep that already happened.
- (void)wakeDisplayNow;

@property (nonatomic, readonly) BOOL isKeepingAwake;
/// Why the assertion could not be taken, or nil.
@property (nonatomic, readonly) NSString *statusMessage;

@end
