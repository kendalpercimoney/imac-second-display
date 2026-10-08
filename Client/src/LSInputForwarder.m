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

#import "LSInputForwarder.h"
#include "rtp_protocol.h"
#include <math.h>
#include <string.h>

// Device-independent modifier bits, the same values NSEvent and CGEventFlags
// use. Spelled out rather than taken from AppKit so this file needs nothing but
// Foundation.
#define LS_MOD_CONTROL   (1u << 18)
#define LS_MOD_OPTION    (1u << 19)
#define LS_MOD_COMMAND   (1u << 20)
#define LS_MOD_SHIFT     (1u << 17)
#define LS_MOD_DEVICE_INDEPENDENT 0xFFFF0000u
#define LS_KEY_ESCAPE    53

@implementation LSInputForwarder {
    void (^_send)(const uint8_t *, size_t);
    NSLock *_lock;
    double _moveRemainderX, _moveRemainderY;
    double _scrollRemainderX, _scrollRemainderY;
    uint8_t _heldKeys[LS_INPUT_KEY_BITMAP_BYTES];
    uint8_t _buttons;
    uint32_t _modifiers;
}

- (id)initWithSender:(void (^)(const uint8_t *, size_t))send {
    self = [super init];
    if (self) {
        _send = [send copy];
        _lock = [[NSLock alloc] init];
        _hostPointsPerViewPoint = 1.0;
    }
    return self;
}

- (void)emit:(const uint8_t *)bytes length:(size_t)length {
    if (length > 0 && _send) _send(bytes, length);
}

#pragma mark - engaging

- (BOOL)engage {
    [_lock lock];
    BOOL ok = _hostAccepting;
    if (ok) {
        _engaged = YES;
        [self clearHeldState];
    }
    [_lock unlock];
    if (ok) [self sendState];
    return ok;
}

- (void)disengage {
    [_lock lock];
    _engaged = NO;
    [self clearHeldState];
    [_lock unlock];
    // Sent even if this side did not think it was engaged: telling the host to
    // let go of everything is never wrong, and being unsure is exactly when it
    // matters.
    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_state(buffer, sizeof(buffer), 0, 0, 0, NULL);
    [self emit:buffer length:n];
}

- (void)clearHeldState {
    memset(_heldKeys, 0, sizeof(_heldKeys));
    _buttons = 0;
    _modifiers = 0;
    _moveRemainderX = _moveRemainderY = 0;
    _scrollRemainderX = _scrollRemainderY = 0;
}

#pragma mark - pointer

static int16_t takeWhole(double *remainder) {
    // Whole points only on the wire, with the fraction kept for next time.
    // Rounding each event instead would throw away every slow movement -- a
    // hand creeping the pointer half a point per event would never move it --
    // and on a scaled-down 27-inch picture most movements start out fractional.
    // The nudge is for floating point, not for motion: ten tenths of 0.3 add
    // up to 2.9999999999999996, and truncating that sends 2 and carries a
    // near-whole point into the next movement, so an exact gesture comes out
    // one point short and the next one point long. A billionth of a point
    // towards the nearest whole number is far below anything a hand produces.
    double whole = trunc(*remainder + copysign(1e-9, *remainder));
    if (whole > INT16_MAX) whole = INT16_MAX;
    if (whole < INT16_MIN) whole = INT16_MIN;
    *remainder -= whole;
    return (int16_t)whole;
}

- (void)mouseMovedByX:(double)dx y:(double)dy {
    [_lock lock];
    if (!_engaged) { [_lock unlock]; return; }
    double scale = _hostPointsPerViewPoint > 0 ? _hostPointsPerViewPoint : 1.0;
    _moveRemainderX += dx * scale;
    _moveRemainderY += dy * scale;
    int16_t x = takeWhole(&_moveRemainderX);
    int16_t y = takeWhole(&_moveRemainderY);
    [_lock unlock];
    if (x == 0 && y == 0) return;

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_move(buffer, sizeof(buffer), x, y);
    [self emit:buffer length:n];
}

- (void)mouseButton:(int)button down:(BOOL)down clickCount:(int)clickCount {
    if (button < 0 || button >= 32) return;
    [_lock lock];
    if (!_engaged) { [_lock unlock]; return; }
    if (button < 8) {
        if (down) _buttons |= (uint8_t)(1u << button);
        else      _buttons &= (uint8_t)~(1u << button);
    }
    [_lock unlock];

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_button(buffer, sizeof(buffer), (uint8_t)button,
                                          down ? 1 : 0,
                                          (uint8_t)(clickCount < 1 ? 1
                                                    : clickCount > 255 ? 255 : clickCount));
    [self emit:buffer length:n];
}

- (void)scrollByX:(double)dx y:(double)dy precise:(BOOL)precise {
    [_lock lock];
    if (!_engaged) { [_lock unlock]; return; }
    _scrollRemainderX += dx * 10.0;
    _scrollRemainderY += dy * 10.0;
    int16_t x = takeWhole(&_scrollRemainderX);
    int16_t y = takeWhole(&_scrollRemainderY);
    [_lock unlock];
    if (x == 0 && y == 0) return;

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_scroll(buffer, sizeof(buffer), x, y, precise ? 1 : 0);
    [self emit:buffer length:n];
}

#pragma mark - keyboard

- (void)key:(uint16_t)keycode down:(BOOL)down repeat:(BOOL)isRepeat modifiers:(uint32_t)modifiers {
    if (keycode >= LS_INPUT_KEY_BITMAP_BYTES * 8) return;
    [_lock lock];
    if (!_engaged) { [_lock unlock]; return; }
    if (down) _heldKeys[keycode / 8] |= (uint8_t)(1u << (keycode % 8));
    else      _heldKeys[keycode / 8] &= (uint8_t)~(1u << (keycode % 8));
    _modifiers = modifiers & LS_MOD_DEVICE_INDEPENDENT;
    uint32_t mods = _modifiers;
    [_lock unlock];

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_key(buffer, sizeof(buffer), keycode,
                                       down ? 1 : 0, isRepeat ? 1 : 0, mods);
    [self emit:buffer length:n];
}

- (void)modifiersChanged:(uint32_t)modifiers keycode:(uint16_t)keycode {
    if (keycode >= LS_INPUT_KEY_BITMAP_BYTES * 8) return;
    [_lock lock];
    if (!_engaged) { [_lock unlock]; return; }
    _modifiers = modifiers & LS_MOD_DEVICE_INDEPENDENT;
    uint32_t mods = _modifiers;
    [_lock unlock];

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_flags(buffer, sizeof(buffer), keycode, mods);
    [self emit:buffer length:n];
}

#pragma mark - state

- (void)sendState {
    [_lock lock];
    if (!_engaged) { [_lock unlock]; return; }
    uint8_t held[LS_INPUT_KEY_BITMAP_BYTES];
    memcpy(held, _heldKeys, sizeof(held));
    uint8_t buttons = _buttons;
    uint32_t mods = _modifiers;
    [_lock unlock];

    uint8_t buffer[LS_CTRL_MAX_SIZE];
    size_t n = ls_ctrl_build_input_state(buffer, sizeof(buffer), 1, buttons, mods, held);
    [self emit:buffer length:n];
}

+ (BOOL)isReleaseKey:(uint16_t)keycode modifiers:(uint32_t)modifiers {
    if (keycode != LS_KEY_ESCAPE) return NO;
    uint32_t mods = modifiers & (LS_MOD_CONTROL | LS_MOD_OPTION | LS_MOD_COMMAND | LS_MOD_SHIFT);
    return mods == (LS_MOD_CONTROL | LS_MOD_OPTION);
}

@end
