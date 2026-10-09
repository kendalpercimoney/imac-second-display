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

// Does the iMac's keyboard and mouse turn into the right events on this Mac?
//
// Every event the injector would post is recorded instead, so this needs no
// Accessibility permission and moves nothing. The messages it is fed are built
// with the real wire-format builders and parsed with the real parser, so the
// path under test starts at the bytes the client sends.

import Foundation
import CoreGraphics
import LSProtocol

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

struct Posted {
    var type: CGEventType
    var location: CGPoint
    var flags: CGEventFlags
    var keycode: Int64
    var clickState: Int64
    var autorepeat: Int64
}

/// An injector with the outside world replaced: two displays laid out like the
/// real ones, a clock this test controls, and a list instead of the event tap.
final class Rig {
    var posted: [Posted] = []
    var clock: TimeInterval = 1000
    var cursor = CGPoint(x: 100, y: 100)
    let injector = InputInjector()
    var echoes = 0

    // The laptop's own screen, and the virtual display to its right -- taller,
    // so there is dead space beside the laptop's lower edge. That gap is what
    // the clamping exists for.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let imac = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    init() {
        injector.post = { [unowned self] e in
            posted.append(Posted(
                type: e.type, location: e.location, flags: e.flags,
                keycode: e.getIntegerValueField(.keyboardEventKeycode),
                clickState: e.getIntegerValueField(.mouseEventClickState),
                autorepeat: e.getIntegerValueField(.keyboardEventAutorepeat)))
        }
        injector.displayBounds = { [unowned self] in [laptop, imac] }
        injector.realCursorLocation = { [unowned self] in cursor }
        injector.now = { [unowned self] in clock }
        injector.onPointerMoved = { [unowned self] in echoes += 1 }
    }

    func send(_ build: (UnsafeMutablePointer<UInt8>, Int) -> Int) {
        var buffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
        let n = buffer.withUnsafeMutableBufferPointer { build($0.baseAddress!, $0.count) }
        var message = ls_ctrl_message()
        guard n > 0, ls_ctrl_parse(buffer, n, &message) == 0 else {
            print("  FAIL could not build a message"); failures += 1; return
        }
        injector.handle(message)
    }
    func move(_ dx: Int16, _ dy: Int16) { send { ls_ctrl_build_input_move($0, $1, dx, dy) } }
    func button(_ b: Int32, _ down: Bool, clicks: UInt8 = 1) {
        send { ls_ctrl_build_input_button($0, $1, UInt8(b), down ? 1 : 0, clicks) }
    }
    func key(_ code: UInt16, _ down: Bool, repeat r: Bool = false, mods: UInt32 = 0) {
        send { ls_ctrl_build_input_key($0, $1, code, down ? 1 : 0, r ? 1 : 0, mods) }
    }
    func state(engaged: Bool, buttons: UInt8 = 0, mods: UInt32 = 0, held: [UInt16] = []) {
        var bitmap = [UInt8](repeating: 0, count: Int(LS_INPUT_KEY_BITMAP_BYTES))
        for code in held { bitmap[Int(code) / 8] |= 1 << (code % 8) }
        send { ls_ctrl_build_input_state($0, $1, engaged ? 1 : 0, buttons, mods, bitmap) }
    }
    var last: Posted? { posted.last }
}

let commandFlag: UInt32 = UInt32(CGEventFlags.maskCommand.rawValue)
let shiftFlag: UInt32 = UInt32(CGEventFlags.maskShift.rawValue)

print("\n==> pointer motion")
do {
    let rig = Rig()
    rig.cursor = CGPoint(x: 1600, y: 500)        // on the iMac's display
    rig.move(10, -5)
    check("a move starts from where the cursor really is",
          rig.last?.location == CGPoint(x: 1610, y: 495), "\(rig.last?.location ?? .zero)")
    check("...and with nothing held it is a plain move", rig.last?.type == .mouseMoved)
    check("...and the new position is echoed to the client straight away", rig.echoes == 1)

    rig.clock += 0.01
    rig.cursor = CGPoint(x: 9999, y: 9999)      // the real cursor lags what was posted
    rig.move(10, 0)
    check("mid-gesture, motion builds on what was posted, not on a lagging cursor",
          rig.last?.location == CGPoint(x: 1620, y: 495), "\(rig.last?.location ?? .zero)")

    rig.clock += 1.0
    rig.cursor = CGPoint(x: 300, y: 300)        // the laptop's trackpad moved it meanwhile
    rig.move(1, 1)
    check("after a pause, it picks up wherever this Mac's own trackpad left it",
          rig.last?.location == CGPoint(x: 301, y: 301), "\(rig.last?.location ?? .zero)")
}

print("\n==> across both displays")
do {
    let rig = Rig()
    rig.cursor = CGPoint(x: 1500, y: 500)
    rig.move(50, 0)
    check("moving right off the laptop lands on the iMac's display",
          rig.last.map { rig.imac.contains($0.location) } == true,
          "\(rig.last?.location ?? .zero)")
    rig.clock += 0.01
    rig.move(-100, 0)
    check("...and moving back crosses back", rig.last.map { rig.laptop.contains($0.location) } == true,
          "\(rig.last?.location ?? .zero)")

    // Low on the iMac's display, beside the laptop's bottom edge: moving left
    // would go into space no screen shows. It has to stop at the edge.
    rig.clock += 1
    rig.cursor = CGPoint(x: 1600, y: 1050)
    rig.move(-300, 0)
    check("moving into the gap beside a shorter display stops at the edge",
          rig.last?.location == CGPoint(x: 1512, y: 1050), "\(rig.last?.location ?? .zero)")

    rig.clock += 1
    rig.cursor = CGPoint(x: 10, y: 10)
    rig.move(-500, -500)
    check("it cannot leave the outer edges either",
          rig.last?.location == CGPoint(x: 0, y: 0), "\(rig.last?.location ?? .zero)")
}

print("\n==> buttons")
do {
    let rig = Rig()
    rig.cursor = CGPoint(x: 1700, y: 400)
    rig.move(0, 1)
    rig.button(LS_BUTTON_LEFT, true)
    check("a left press is a left mouse down", rig.last?.type == .leftMouseDown)
    rig.clock += 0.01
    rig.move(20, 0)
    check("moving with it held is a drag, or nothing can be dragged",
          rig.last?.type == .leftMouseDragged, "\(rig.last?.type.rawValue ?? 0)")
    rig.button(LS_BUTTON_LEFT, false)
    check("...and releasing it is a mouse up", rig.last?.type == .leftMouseUp)

    rig.button(LS_BUTTON_LEFT, true, clicks: 2)
    check("a double-click carries its click count, or nothing opens on double-click",
          rig.last?.clickState == 2, "\(rig.last?.clickState ?? 0)")
    rig.button(LS_BUTTON_LEFT, false, clicks: 2)

    rig.button(LS_BUTTON_RIGHT, true)
    check("a right press is a right mouse down", rig.last?.type == .rightMouseDown)
    rig.clock += 0.01
    rig.move(5, 5)
    check("...and moving with it held is a right drag", rig.last?.type == .rightMouseDragged)
    rig.button(LS_BUTTON_RIGHT, false)
}

print("\n==> keyboard")
do {
    let rig = Rig()
    rig.key(12, true, mods: commandFlag)            // Command-Q
    let down = rig.posted.filter { $0.type == .keyDown }.last
    check("a key arrives as that key", down?.keycode == 12, "\(down?.keycode ?? -1)")
    check("...with its modifiers on it", down?.flags.contains(.maskCommand) == true)
    check("...and a modifier carried only on the key is pressed first",
          rig.posted.first?.type == .flagsChanged)
    rig.key(12, true, repeat: true, mods: commandFlag)
    check("the iMac's key repeat comes through marked as repeat", rig.last?.autorepeat == 1)
    rig.key(12, false, mods: commandFlag)
    check("...and the key comes back up", rig.last?.type == .keyUp)
}

print("\n==> nothing is left held down")
do {
    let rig = Rig()
    rig.key(0, true, mods: shiftFlag)               // Shift-A, and the key-up gets lost
    rig.button(LS_BUTTON_LEFT, true)                // so does a button-up
    rig.posted.removeAll()
    rig.state(engaged: true, buttons: 0, mods: 0, held: [])
    check("a key the client no longer holds is released",
          rig.posted.contains { $0.type == .keyUp && $0.keycode == 0 })
    check("so is a button", rig.posted.contains { $0.type == .leftMouseUp })
    check("so is a modifier",
          rig.posted.contains { $0.type == .flagsChanged && !$0.flags.contains(.maskShift) })

    // The other way round must not happen: a key the client holds that this
    // side never heard go down is a lost key-down, and typing it late is worse.
    rig.posted.removeAll()
    rig.state(engaged: true, held: [4])
    check("a key-down that was lost is not typed late", rig.posted.isEmpty, "\(rig.posted.count) posted")

    let rig2 = Rig()
    rig2.key(1, true); rig2.key(2, true); rig2.button(LS_BUTTON_RIGHT, true)
    rig2.posted.removeAll()
    rig2.state(engaged: false)
    check("when the client stops forwarding, every key goes up",
          Set(rig2.posted.filter { $0.type == .keyUp }.map(\.keycode)) == [1, 2])
    check("...and every button", rig2.posted.contains { $0.type == .rightMouseUp })

    let rig3 = Rig()
    rig3.key(7, true)
    rig3.posted.removeAll()
    rig3.clock += 1.0
    rig3.injector.watchdog()
    check("a second of silence is not enough to give up", rig3.posted.isEmpty)
    rig3.clock += 1.0
    rig3.injector.watchdog()
    check("but a client that has gone quiet with a key held has its key released",
          rig3.posted.contains { $0.type == .keyUp && $0.keycode == 7 })
}

print()
print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
