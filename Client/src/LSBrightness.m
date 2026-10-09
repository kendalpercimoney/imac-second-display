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

#import "LSBrightness.h"
#import <IOKit/graphics/IOGraphicsLib.h>
#import <ApplicationServices/ApplicationServices.h>

@implementation LSBrightness {
    float _original;
    BOOL  _haveOriginal;
}

- (id)init {
    if (!(self = [super init])) return nil;
    _original = -1.0f;

    float current = [self currentBrightness];
    if (current >= 0.0f) {
        _available = YES;
        _original = current;
        _haveOriginal = YES;
        _statusMessage = nil;
    } else {
        _available = NO;
        _statusMessage = @"no display here exposes brightness (IODisplayConnect)";
    }
    return self;
}

/// Every display service that might have a brightness control. On the 2010 iMac
/// that is the built-in panel; on a machine with only external displays it is
/// usually nothing at all, which is not an error worth shouting about.
- (io_iterator_t)displayIterator {
    io_iterator_t iterator = 0;
    CFMutableDictionaryRef matching = IOServiceMatching("IODisplayConnect");
    if (!matching) return 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }
    return iterator;
}

- (BOOL)setBrightness:(float)brightness {
    if (brightness < 0.0f) brightness = 0.0f;
    if (brightness > 1.0f) brightness = 1.0f;

    io_iterator_t iterator = [self displayIterator];
    if (!iterator) return NO;

    BOOL any = NO;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        kern_return_t result = IODisplaySetFloatParameter(service, kNilOptions,
                                                          CFSTR(kIODisplayBrightnessKey),
                                                          brightness);
        if (result == KERN_SUCCESS) any = YES;
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return any;
}

- (float)currentBrightness {
    io_iterator_t iterator = [self displayIterator];
    if (!iterator) return -1.0f;

    float value = -1.0f;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        float read = 0.0f;
        if (IODisplayGetFloatParameter(service, kNilOptions,
                                       CFSTR(kIODisplayBrightnessKey),
                                       &read) == KERN_SUCCESS) {
            value = read;
            IOObjectRelease(service);
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return value;
}

- (void)restoreOriginal {
    // Leaving someone's screen dark because an app quit would be rude, and on a
    // machine used as a second display it would not be obvious what had done it.
    if (_haveOriginal && _original >= 0.0f) [self setBrightness:_original];
}

@end
