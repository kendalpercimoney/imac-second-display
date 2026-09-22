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

#import "LSVirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>

// Private CoreGraphics interfaces, declared here only so the compiler will let
// us send these messages. Nothing is linked against: every class is looked up
// at runtime, so a macOS that no longer has them degrades to "unsupported"
// rather than failing to launch.
@interface LSCGVirtualDisplayDescriptor : NSObject
@property(copy) NSString *name;
@property CGSize sizeInMillimeters;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property unsigned int productID;
@property unsigned int vendorID;
@property unsigned int serialNum;
@property(strong) dispatch_queue_t queue;
@property(copy) void (^terminationHandler)(void);
@end

@interface LSCGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface LSCGVirtualDisplaySettings : NSObject
@property(strong) NSArray *modes;
@property unsigned int hiDPI;
@end

@interface LSCGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(readonly) unsigned int displayID;
@end


static Class LSDescriptorClass(void) { return NSClassFromString(@"CGVirtualDisplayDescriptor"); }
static Class LSModeClass(void)       { return NSClassFromString(@"CGVirtualDisplayMode"); }
static Class LSSettingsClass(void)   { return NSClassFromString(@"CGVirtualDisplaySettings"); }
static Class LSDisplayClass(void)    { return NSClassFromString(@"CGVirtualDisplay"); }


@implementation LSVirtualDisplay {
    id _display;   // LSCGVirtualDisplay
}

+ (BOOL)isSupported {
    return LSDescriptorClass() && LSModeClass() && LSSettingsClass() && LSDisplayClass();
}

+ (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"LanScreen.VirtualDisplay" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                           refreshRate:(double)refreshRate
                                 hiDPI:(BOOL)hiDPI
                                  name:(NSString *)name
                                 error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;

    if (![LSVirtualDisplay isSupported]) {
        if (error) *error = [LSVirtualDisplay errorWithMessage:
            @"This version of macOS does not expose CGVirtualDisplay. "
            @"Use a hardware HDMI dummy plug and capture that display instead."];
        return nil;
    }
    if (width < 2 || height < 2 || (width % 2) || (height % 2)) {
        if (error) *error = [LSVirtualDisplay errorWithMessage:
            @"Virtual display dimensions must be even and at least 2 pixels."];
        return nil;
    }

    LSCGVirtualDisplayDescriptor *descriptor = [[LSDescriptorClass() alloc] init];
    descriptor.name = name.length ? name : @"LanScreen";
    descriptor.maxPixelsWide = (unsigned int)width;
    descriptor.maxPixelsHigh = (unsigned int)height;
    // Roughly 127 dpi, which is close enough to a real panel that macOS picks
    // sane default scaling. The exact number only affects how the display is
    // described, not how it renders.
    descriptor.sizeInMillimeters = CGSizeMake((double)width / 5.0, (double)height / 5.0);
    descriptor.productID = 0x4C53;   // "LS"
    descriptor.vendorID  = 0x4C53;
    descriptor.serialNum = 0x0001;
    descriptor.queue = dispatch_get_main_queue();
    descriptor.terminationHandler = ^{
        NSLog(@"[LanScreen] virtual display terminated by the window server");
    };

    id display = [[LSDisplayClass() alloc] initWithDescriptor:descriptor];
    if (!display) {
        if (error) *error = [LSVirtualDisplay errorWithMessage:
            @"CGVirtualDisplay refused to initialise."];
        return nil;
    }

    LSCGVirtualDisplaySettings *settings = [[LSSettingsClass() alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    id mode = [[LSModeClass() alloc] initWithWidth:(unsigned int)width
                                            height:(unsigned int)height
                                       refreshRate:refreshRate];
    if (!mode) {
        if (error) *error = [LSVirtualDisplay errorWithMessage:
            @"CGVirtualDisplayMode refused these dimensions."];
        return nil;
    }
    settings.modes = @[mode];

    if (![display applySettings:settings]) {
        if (error) *error = [LSVirtualDisplay errorWithMessage:
            @"CGVirtualDisplay rejected the requested mode. Try a standard "
            @"resolution such as 1920x1080."];
        return nil;
    }

    _display = display;
    _displayID = [(LSCGVirtualDisplay *)display displayID];
    _width = width;
    _height = height;

    if (_displayID == 0) {
        if (error) *error = [LSVirtualDisplay errorWithMessage:
            @"The window server did not assign a display ID."];
        return nil;
    }

    NSLog(@"[LanScreen] virtual display %u created at %lux%lu @%.0fHz",
          _displayID, (unsigned long)width, (unsigned long)height, refreshRate);
    return self;
}

- (void)dealloc {
    if (_display) {
        NSLog(@"[LanScreen] tearing down virtual display %u", _displayID);
        _display = nil;   // releasing it removes the display
    }
}

@end
