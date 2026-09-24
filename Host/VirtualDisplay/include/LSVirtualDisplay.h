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
//  LSVirtualDisplay.h
//  A headless display that exists only so the iMac has something to show.
//
//  Capturing an existing display mirrors what is already on the MacBook's
//  screen. To use the iMac as a genuine *second* monitor, macOS has to believe
//  a second monitor is plugged in. The sanctioned ways to do that are a
//  hardware dummy plug or a DriverKit display extension; the practical way is
//  CoreGraphics' private CGVirtualDisplay, which is what every third-party
//  tool in this space uses.
//
//  Because it is private API, everything here goes through NSClassFromString
//  and respondsToSelector. If a future macOS removes or renames it, this
//  returns nil and the host falls back to capturing a real display instead of
//  crashing.
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSVirtualDisplay : NSObject

/// NO if this macOS does not expose the private classes we need.
+ (BOOL)isSupported;

/// Creates a headless display and publishes it to the window server. Returns
/// nil on failure with a description in `error`.
///
/// The display disappears when this object is deallocated.
- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                           refreshRate:(double)refreshRate
                                  name:(NSString *)name
                                 error:(NSError **)error;

/// The CGDirectDisplayID to hand to ScreenCaptureKit.
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
/// What the window server actually settled on. A HiDPI display is addressed in
/// points and stored in pixels, two to one; these are zero until it is created.
@property (nonatomic, readonly) NSUInteger modePointsWide;
@property (nonatomic, readonly) NSUInteger modePointsHigh;
@property (nonatomic, readonly) NSUInteger modePixelsWide;
@property (nonatomic, readonly) NSUInteger modePixelsHigh;

/// Reads back the mode the window server settled on. Call it once the display
/// has been published, not straight after creating it.
- (void)refreshModeGeometry;

@end

NS_ASSUME_NONNULL_END
