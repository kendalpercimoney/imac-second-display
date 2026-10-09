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

//
//  LSBrightness.h
//  The iMac's panel brightness, driven from the other machine.
//
//  IODisplayConnect is the old interface, which is exactly why it works here: a
//  2010 iMac's built-in panel exposes brightness through it. Newer Macs do not,
//  so this reports what it managed rather than assuming.
//
#import <Foundation/Foundation.h>

@interface LSBrightness : NSObject

/// Whether any display on this machine accepted a brightness reading at all.
@property (nonatomic, readonly) BOOL available;
/// What went wrong, if it is not available.
@property (nonatomic, readonly, copy) NSString *statusMessage;

/// 0 to 1. Returns NO if no display took it.
- (BOOL)setBrightness:(float)brightness;
/// The current value, or -1 if it cannot be read.
- (float)currentBrightness;

/// Puts back whatever the panel was set to when this object was created. Called
/// on quit so the app does not leave the iMac dimmed.
- (void)restoreOriginal;

@end
