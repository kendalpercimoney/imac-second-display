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
//  What the iMac puts on the wire when its keyboard and mouse are forwarded.
//  Every datagram the forwarder sends is captured and run back through the
//  real parser, so a mistake in either shows up here.
//
#import <Foundation/Foundation.h>
#import "LSInputForwarder.h"
#include "rtp_protocol.h"

static int failures = 0;
// The condition is evaluated once: several of these call -engage, and
// evaluating it a second time to count would engage twice.
#define CHECK(cond, what) do { \
    BOOL ok_ = (cond); \
    printf("  %s %s\n", ok_ ? "ok  " : "FAIL", what); \
    if (!ok_) failures++; \
} while (0)

static NSMutableArray *gSent;

static LSInputForwarder *makeForwarder(void) {
    gSent = [NSMutableArray array];
    return [[LSInputForwarder alloc] initWithSender:^(const uint8_t *bytes, size_t length) {
        [gSent addObject:[NSData dataWithBytes:bytes length:length]];
    }];
}

static ls_ctrl_message parsed(NSData *d) {
    ls_ctrl_message m;
    memset(&m, 0, sizeof(m));
    if (ls_ctrl_parse([d bytes], [d length], &m) != 0) m.type = 0;
    return m;
}

static int movedX(void) {
    int total = 0;
    for (NSData *d in gSent) {
        ls_ctrl_message m = parsed(d);
        if (m.type == LS_MSG_INPUT_MOVE) total += m.input_dx;
    }
    return total;
}

#define CONTROL (1u << 18)
#define OPTION  (1u << 19)
#define COMMAND (1u << 20)
#define SHIFT   (1u << 17)

int main(void) {
    @autoreleasepool {
        printf("\n==> only when allowed\n");
        {
            LSInputForwarder *f = makeForwarder();
            [f mouseMovedByX:50 y:0];
            [f key:0 down:YES repeat:NO modifiers:0];
            CHECK([gSent count] == 0, "nothing is sent before engaging");

            CHECK(![f engage], "engaging is refused while the host is not accepting");
            CHECK(![f isEngaged], "...and so the iMac keeps its own pointer");

            f.hostAccepting = YES;
            CHECK([f engage], "it engages once the host says it will act on input");
        }

        printf("\n==> pointer motion\n");
        {
            LSInputForwarder *f = makeForwarder();
            f.hostAccepting = YES;
            [f engage];
            [gSent removeAllObjects];

            // Ten movements of three tenths of a point. Rounded one at a time,
            // that is ten zeros and the pointer never moves.
            for (int i = 0; i < 10; i++) [f mouseMovedByX:0.3 y:0];
            CHECK(movedX() == 3, "slow, fractional motion adds up instead of vanishing");

            [gSent removeAllObjects];
            f.hostPointsPerViewPoint = 0.75;      // 1080p drawn across a 1440-line panel
            [f mouseMovedByX:400 y:0];
            CHECK(movedX() == 300, "motion is scaled to the size the picture is drawn at");

            [gSent removeAllObjects];
            f.hostPointsPerViewPoint = 1.0;
            [f mouseMovedByX:-12 y:0];
            CHECK(movedX() == -12, "left is left");

            [gSent removeAllObjects];
            [f mouseMovedByX:100000 y:0];
            CHECK(movedX() == INT16_MAX, "an absurd delta is clamped, not wrapped round to negative");
        }

        printf("\n==> held state, and letting go\n");
        {
            LSInputForwarder *f = makeForwarder();
            f.hostAccepting = YES;
            [f engage];
            [f key:0 down:YES repeat:NO modifiers:SHIFT];
            [f key:127 down:YES repeat:NO modifiers:SHIFT];
            [f mouseButton:LS_BUTTON_LEFT down:YES clickCount:1];
            [gSent removeAllObjects];
            [f sendState];
            ls_ctrl_message m = parsed([gSent lastObject]);
            CHECK(m.type == LS_MSG_INPUT_STATE && m.input_engaged == 1, "state is sent while engaged");
            CHECK((m.input_held_keys[0] & 1) && (m.input_held_keys[15] & 0x80),
                  "it lists the keys held, at both ends of the bitmap");
            CHECK(m.input_buttons == 1, "and the button held");
            CHECK(m.input_modifiers == SHIFT, "and the modifiers");

            [f key:0 down:NO repeat:NO modifiers:SHIFT];
            [gSent removeAllObjects];
            [f sendState];
            m = parsed([gSent lastObject]);
            CHECK(!(m.input_held_keys[0] & 1) && (m.input_held_keys[15] & 0x80),
                  "a key that comes up leaves the list, the other stays");

            [gSent removeAllObjects];
            [f disengage];
            m = parsed([gSent lastObject]);
            CHECK(m.type == LS_MSG_INPUT_STATE && m.input_engaged == 0,
                  "letting go tells the host to release everything");
            CHECK(![f isEngaged], "...and stops forwarding");

            [gSent removeAllObjects];
            [f key:5 down:YES repeat:NO modifiers:0];
            [f mouseMovedByX:20 y:0];
            CHECK([gSent count] == 0, "nothing more is sent after letting go");

            f.hostAccepting = YES;
            [f engage];
            [gSent removeAllObjects];
            [f sendState];
            m = parsed([gSent lastObject]);
            BOOL empty = YES;
            for (int i = 0; i < LS_INPUT_KEY_BITMAP_BYTES; i++) if (m.input_held_keys[i]) empty = NO;
            CHECK(empty && m.input_buttons == 0,
                  "engaging again starts clean, not with the old session's keys");
        }

        printf("\n==> the way out\n");
        {
            CHECK([LSInputForwarder isReleaseKey:53 modifiers:CONTROL | OPTION],
                  "Control-Option-Escape releases");
            CHECK(![LSInputForwarder isReleaseKey:53 modifiers:0],
                  "Escape alone goes to the Mac, where it belongs");
            CHECK(![LSInputForwarder isReleaseKey:53 modifiers:COMMAND | OPTION],
                  "Command-Option-Escape is Force Quit, and is not taken over");
            CHECK(![LSInputForwarder isReleaseKey:53 modifiers:CONTROL | OPTION | SHIFT],
                  "with Shift too it is a different shortcut, and goes to the Mac");
            CHECK(![LSInputForwarder isReleaseKey:12 modifiers:CONTROL | OPTION],
                  "Control-Option with another key goes to the Mac");
        }

        printf("\n%s\n", failures == 0 ? "RESULT: PASS" : "RESULT: FAIL");
        return failures == 0 ? 0 : 1;
    }
}
