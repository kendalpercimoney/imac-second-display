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
//  LSAppDelegate.h
//
#import <Cocoa/Cocoa.h>

/// Borderless windows refuse key status unless you say otherwise, and we need
/// key events for the fullscreen and diagnostics shortcuts.
@interface LSWindow : NSWindow
@property (nonatomic, assign) id keyTarget;   // unretained
@end

@interface LSAppDelegate : NSObject <NSApplicationDelegate>
@end
