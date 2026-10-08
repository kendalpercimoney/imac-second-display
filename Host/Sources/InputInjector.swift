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

import Foundation
import CoreGraphics
import ApplicationServices
import LSProtocol

/// Turns the iMac's keyboard and mouse into events on this Mac.
///
/// Motion arrives relative, not as a position on the iMac's screen, and that is
/// the whole design: an absolute position could only ever land somewhere on the
/// virtual display, while a delta can carry the pointer off its edge and on to
/// this Mac's own screen, the same way a second monitor works.
///
/// Everything that touches the outside world is injectable -- where events are
/// posted, where the displays are, where the real cursor is, what time it is --
/// so the mapping can be tested by recording what would have been posted.
/// Posting for real needs the Accessibility permission, which a test binary
/// does not have and should not be given.
final class InputInjector {

    /// Where events go.
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    /// Fired after the pointer moves, so its new position can be sent to the
    /// client straight away rather than at the cursor tracker's next sample --
    /// up to 8 ms sooner, on the one thing the eye is following.
    var onPointerMoved: (() -> Void)?
    var displayBounds: () -> [CGRect] = InputInjector.activeDisplayBounds
    var realCursorLocation: () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Called from the control channel's receive thread, and from the main
    /// thread when a stream stops. One lock is plenty at these rates.
    private let lock = NSLock()
    /// A private event source: the flags on each event are exactly the ones
    /// set on it, not merged with whatever this Mac's own keyboard is holding.
    private let source = CGEventSource(stateID: .privateState)

    private var position: CGPoint?
    private var lastPostTime: TimeInterval = -.infinity
    private var lastInputTime: TimeInterval = -.infinity
    private var buttons: UInt8 = 0
    private var modifiers: CGEventFlags = []
    private var heldKeys = Set<UInt16>()
    private var scrollRemainder = (x: 0.0, y: 0.0)

    // MARK: - Permission

    /// Posting events is gated on Accessibility. Without it CGEventPost does
    /// nothing at all -- no error, no event -- which is why this is checked and
    /// shown rather than assumed.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt, which offers to open the right pane.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Dispatch

    func handle(_ message: ls_ctrl_message) {
        lock.lock(); defer { lock.unlock() }
        lastInputTime = now()
        switch Int(message.type) {
        case LS_MSG_INPUT_MOVE:
            move(dx: Double(message.input_dx), dy: Double(message.input_dy))
        case LS_MSG_INPUT_BUTTON:
            button(Int(message.input_button), down: message.input_down != 0,
                   clicks: Int(message.input_click_count))
        case LS_MSG_INPUT_SCROLL:
            scroll(dxTenths: Int(message.input_dx), dyTenths: Int(message.input_dy),
                   precise: message.input_precise != 0)
        case LS_MSG_INPUT_KEY:
            key(message.input_keycode, down: message.input_down != 0,
                repeat: message.input_repeat != 0,
                modifiers: Self.flags(message.input_modifiers))
        case LS_MSG_INPUT_FLAGS:
            modifiersChanged(to: Self.flags(message.input_modifiers),
                             keycode: message.input_keycode)
        case LS_MSG_INPUT_STATE:
            reconcile(message)
        default:
            break
        }
    }

    /// Lets go of everything. Called when the client says it has stopped
    /// forwarding, when the stream stops, and by the watchdog. A key left down
    /// on this Mac because the iMac went away mid-keystroke repeats forever.
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        releaseAllLocked()
    }

    /// Anything held, with nothing heard from the client for this long, is
    /// released. The client sends its state four times a second while it is
    /// forwarding, so silence this long means it has gone, not that it is idle.
    func watchdog(timeout: TimeInterval = 1.5) {
        lock.lock(); defer { lock.unlock() }
        guard now() - lastInputTime > timeout else { return }
        guard buttons != 0 || !heldKeys.isEmpty || !modifiers.isEmpty else { return }
        releaseAllLocked()
    }

    // MARK: - Pointer

    private func move(dx: Double, dy: Double) {
        let t = now()
        // Start from where the cursor really is if this Mac's own trackpad may
        // have moved it since. Only after a pause, though: checking on every
        // event would race the events just posted, which have not necessarily
        // moved the cursor yet, and would throw motion away.
        if position == nil || t - lastPostTime > 0.1 {
            position = realCursorLocation()
        }
        let from = position!
        let to = Self.nextPosition(from: from, dx: dx, dy: dy, displays: displayBounds())
        position = to
        lastPostTime = t

        let type: CGEventType
        let which: CGMouseButton
        if buttons & 1 << LS_BUTTON_LEFT != 0 {
            type = .leftMouseDragged; which = .left
        } else if buttons & 1 << LS_BUTTON_RIGHT != 0 {
            type = .rightMouseDragged; which = .right
        } else if buttons != 0 {
            type = .otherMouseDragged; which = .center
        } else {
            type = .mouseMoved; which = .left
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: to, mouseButton: which) else { return }
        // The motion that actually happened, after clamping, rather than the
        // motion that was asked for. Anything reading deltas -- a game, a
        // drag that has hit the edge -- should see the cursor stop.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((to.x - from.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((to.y - from.y).rounded()))
        event.flags = modifiers
        post(event)
        onPointerMoved?()
    }

    /// Where the pointer ends up, keeping it on a display.
    ///
    /// If the destination is on any display, that is where it goes, which is
    /// what carries it across the edge between the virtual display and this
    /// Mac's own screen. If it is in the gap -- displays of different heights,
    /// side by side, leave dead space above or below the shorter one -- it is
    /// held to the display it is leaving, so it slides along that edge the way
    /// the real pointer does instead of vanishing into space no screen shows.
    static func nextPosition(from: CGPoint, dx: Double, dy: Double,
                             displays: [CGRect]) -> CGPoint {
        let target = CGPoint(x: from.x + dx, y: from.y + dy)
        guard !displays.isEmpty else { return target }
        if displays.contains(where: { $0.contains(target) }) { return target }

        let home = displays.first(where: { $0.contains(from) })
            ?? displays.min(by: { distance($0, from) < distance($1, from) })!
        return CGPoint(x: min(max(target.x, home.minX), home.maxX - 1),
                       y: min(max(target.y, home.minY), home.maxY - 1))
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func button(_ index: Int, down: Bool, clicks: Int) {
        if position == nil { position = realCursorLocation() }
        let at = position!
        let bit = UInt8(1) << UInt8(min(index, 7))
        let type: CGEventType
        let which: CGMouseButton
        switch index {
        case Int(LS_BUTTON_LEFT):  type = down ? .leftMouseDown : .leftMouseUp; which = .left
        case Int(LS_BUTTON_RIGHT): type = down ? .rightMouseDown : .rightMouseUp; which = .right
        default:              type = down ? .otherMouseDown : .otherMouseUp
                              which = CGMouseButton(rawValue: UInt32(index)) ?? .center
        }
        if down { buttons |= bit } else { buttons &= ~bit }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: at, mouseButton: which) else { return }
        // Double-clicks are counted on the iMac and carried across. A synthetic
        // event is not counted again here, so without this every click is a
        // single click and nothing can be opened by double-clicking it.
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1)))
        if index >= 2 {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(index))
        }
        event.flags = modifiers
        post(event)
    }

    private func scroll(dxTenths: Int, dyTenths: Int, precise: Bool) {
        // Fractions are carried rather than rounded away, or a slow scroll on a
        // wheel with acceleration -- a tenth of a line at a time -- never
        // scrolls at all.
        scrollRemainder.x += Double(dxTenths) / 10
        scrollRemainder.y += Double(dyTenths) / 10
        let x = Int32(scrollRemainder.x.rounded(.towardZero))
        let y = Int32(scrollRemainder.y.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        scrollRemainder.x -= Double(x)
        scrollRemainder.y -= Double(y)

        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: precise ? .pixel : .line,
                                  wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        if precise {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        event.flags = modifiers
        post(event)
    }

    // MARK: - Keyboard

    private func key(_ keycode: UInt16, down: Bool, repeat isRepeat: Bool,
                     modifiers newModifiers: CGEventFlags) {
        // Bring the modifiers into line first. The flags travel with each key,
        // so a modifier change whose own message was lost is still honoured
        // before the key it was meant to modify.
        if newModifiers != modifiers {
            modifiersChanged(to: newModifiers, keycode: nil)
        }
        if down { heldKeys.insert(keycode) } else { heldKeys.remove(keycode) }
        postKey(keycode, down: down, isRepeat: isRepeat)
    }

    private func postKey(_ keycode: UInt16, down: Bool, isRepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode,
                                  keyDown: down) else { return }
        event.flags = modifiers
        // The iMac's own key repeat is forwarded as it happens. A posted
        // key-down does not auto-repeat on this side, so this is what makes
        // holding a key work, at the iMac's repeat rate.
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        post(event)
    }

    /// The left-hand key for each modifier, used when a modifier change has to
    /// be synthesised without knowing which physical key caused it.
    private static let modifierKeycodes: [(CGEventFlags, UInt16)] = [
        (.maskShift, 56), (.maskControl, 59), (.maskAlternate, 58),
        (.maskCommand, 55), (.maskAlphaShift, 57), (.maskSecondaryFn, 63),
    ]

    private func modifiersChanged(to newModifiers: CGEventFlags, keycode: UInt16?) {
        if let keycode {
            modifiers = newModifiers
            postFlagsChanged(keycode: keycode)
            return
        }
        // One event per modifier that differs, so each goes down or up the way
        // a real keyboard would have sent it.
        for (flag, code) in Self.modifierKeycodes where
            modifiers.contains(flag) != newModifiers.contains(flag) {
            if newModifiers.contains(flag) { modifiers.insert(flag) } else { modifiers.remove(flag) }
            postFlagsChanged(keycode: code)
        }
        modifiers = newModifiers
    }

    private func postFlagsChanged(keycode: UInt16) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode,
                                  keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = modifiers
        post(event)
    }

    // MARK: - Reconciliation

    /// Lets go of anything this side thinks is held and the client says is not.
    ///
    /// The other direction -- the client holding something this side never
    /// heard about -- is deliberately not repaired. That is a lost key-down,
    /// and pressing it late would type a character nobody is waiting for.
    private func reconcile(_ message: ls_ctrl_message) {
        guard message.input_engaged != 0 else {
            releaseAllLocked()
            return
        }
        var held = message.input_held_keys
        let clientHolds: (UInt16) -> Bool = { code in
            withUnsafeBytes(of: &held) { raw in
                raw[Int(code) / 8] & (1 << (code % 8)) != 0
            }
        }
        for code in heldKeys where !clientHolds(code) {
            heldKeys.remove(code)
            postKey(code, down: false)
        }
        for index in 0..<8 where buttons & (1 << index) != 0
                                 && message.input_buttons & (1 << index) == 0 {
            button(index, down: false, clicks: 1)
        }
        let clientModifiers = Self.flags(message.input_modifiers)
        if clientModifiers != modifiers {
            modifiersChanged(to: clientModifiers, keycode: nil)
        }
    }

    private func releaseAllLocked() {
        for code in heldKeys { postKey(code, down: false) }
        heldKeys.removeAll()
        for index in 0..<8 where buttons & (1 << index) != 0 {
            button(index, down: false, clicks: 1)
        }
        if !modifiers.isEmpty { modifiersChanged(to: [], keycode: nil) }
        scrollRemainder = (0, 0)
    }

    /// The iMac sends NSEvent modifier flags. Their device-independent bits are
    /// the same bits CGEventFlags uses; everything below them is device
    /// specific -- which side's Shift, for instance -- and is dropped rather
    /// than replayed on a different keyboard.
    static func flags(_ wire: UInt32) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(wire & 0xFFFF_0000))
    }
}
