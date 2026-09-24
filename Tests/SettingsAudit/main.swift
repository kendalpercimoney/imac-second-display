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

// Does every control in the window actually do something?
//
// Two of them did not. The Profile picker was silently replaced with
// Constrained Baseline whenever the low-latency rate controller was on, and
// Include mouse cursor was ignored whenever the pointer was being sent
// separately. Both looked like live controls and neither was.
//
// So: flip each setting in turn and require that it either changes the plan the
// pipeline is built from, or is named in that plan's overrides. A control is
// allowed to be ignored. It is not allowed to be ignored quietly.

import Foundation

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

/// StreamSettings persists to UserDefaults on every change, so this leaves a
/// plist behind under the test binary's own domain. Removed at the end.
let testDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

struct Control {
    var name: String
    var change: (StreamSettings) -> Void
}

let controls: [Control] = [
    Control(name: "Display size (width)")  { $0.width = $0.width == 1920 ? 1280 : 1920 },
    Control(name: "Display size (height)") { $0.height = $0.height == 1080 ? 720 : 1080 },
    Control(name: "Frame rate")            { $0.frameRate = $0.frameRate == 60 ? 30 : 60 },
    Control(name: "Bitrate")               { $0.bitrateMbps = $0.bitrateMbps == 25 ? 40 : 25 },
    Control(name: "Profile")               { $0.profile = $0.profile == .baseline ? .main : .baseline },
    Control(name: "Keyframe")              { $0.keyframeSeconds = $0.keyframeSeconds == 5 ? 2 : 5 },
    Control(name: "Include mouse cursor")  { $0.showsCursor.toggle() },
    Control(name: "Packet size")           { $0.mtuPayload = $0.mtuPayload == 1400 ? 8900 : 1400 },
    Control(name: "Low-latency encoder")   { $0.lowLatencyEncoder.toggle() },
    Control(name: "4:2:0 capture")         { $0.captureYUV420.toggle() },
    Control(name: "Send the pointer separately") { $0.forwardCursor.toggle() },
    Control(name: "Client IP")             { $0.clientAddress = $0.clientAddress == "10.0.0.2" ? "10.0.0.9" : "10.0.0.2" },
    Control(name: "Video port")            { $0.videoPort += 1 },
    Control(name: "Control port")          { $0.controlPort += 1 },
    Control(name: "Wake the client")       { $0.wakeClientAutomatically.toggle() },
    Control(name: "Keep at full performance") { $0.preventAppNap.toggle() },
    Control(name: "Stop streaming when this Mac sleeps") { $0.stopOnSleep.toggle() },
]

/// A plan built with no link MTU, so the packet-size clamp is out of the way
/// unless a case deliberately asks for it.
func plan(_ settings: StreamSettings, linkMTU: Int? = nil) -> StreamPlan {
    StreamPlan(settings: settings, linkMTU: linkMTU)
}

func sweep(_ label: String, configure: (StreamSettings) -> Void) {
    print()
    print("==> \(label)")
    for control in controls {
        let settings = StreamSettings()
        configure(settings)
        let before = plan(settings)
        control.change(settings)
        let after = plan(settings)

        let changed = after != before
        let declared = after.inertFor(control.name) != nil
            || before.inertFor(control.name) != nil
        check(control.name, changed || declared,
              changed ? "" : (declared ? "overridden, and says so" : "NOTHING HAPPENS"))
    }
}

// With the two overriding settings off, every control must reach the pipeline.
sweep("every control, with nothing overriding anything") { settings in
    settings.lowLatencyEncoder = false
    settings.captureYUV420 = false
    settings.forwardCursor = false
    settings.showsCursor = true
    settings.profile = .baseline
    settings.mtuPayload = 1400
}

// And with them on, the two that get overridden must still be accounted for.
sweep("every control, with low latency and the separate pointer on") { settings in
    settings.lowLatencyEncoder = true
    settings.captureYUV420 = true
    settings.forwardCursor = true
    settings.showsCursor = true
    settings.profile = .main
    settings.mtuPayload = 1400
}

// MARK: - the overrides themselves

print()
print("==> the overrides are reported when they apply, and only then")

do {
    let s = StreamSettings()
    s.lowLatencyEncoder = true
    s.profile = .main
    let p = plan(s)
    check("Main + low latency is reported as overridden", p.overrideFor("Profile") != nil)
    check("...and the plan really is Constrained Baseline", p.profile == .constrainedBaseline,
          "\(p.profile.rawValue)")
}
do {
    let s = StreamSettings()
    s.lowLatencyEncoder = false
    s.profile = .main
    let p = plan(s)
    check("Main without low latency is not reported", p.overrideFor("Profile") == nil)
    check("...and the plan really is Main", p.profile == .main, "\(p.profile.rawValue)")
}
do {
    let s = StreamSettings()
    s.lowLatencyEncoder = true
    s.profile = .baseline
    let p = plan(s)
    check("Baseline + low latency loses nothing, so it is not warned about",
          p.overrideFor("Profile") == nil)
    check("...but the picker is still inert, because it cannot do anything",
          p.inertFor("Profile") != nil)
}
do {
    let s = StreamSettings()
    s.forwardCursor = true
    s.showsCursor = true
    let p = plan(s)
    check("cursor in the video + separate pointer is reported as overridden",
          p.overrideFor("Include mouse cursor") != nil)
    check("...and the capture really does not draw it", p.capturesCursor == false)
}
do {
    let s = StreamSettings()
    s.forwardCursor = false
    s.showsCursor = true
    let p = plan(s)
    check("cursor in the video without the separate pointer is not reported",
          p.overrideFor("Include mouse cursor") == nil)
    check("...and the capture really does draw it", p.capturesCursor == true)
}
do {
    let s = StreamSettings()
    s.mtuPayload = 8900
    let p = plan(s, linkMTU: 1500)
    check("a packet size the link cannot carry is reported as overridden",
          p.overrideFor("Packet size") != nil)
    check("...and the plan really uses what fits", p.mtuPayload == 1472, "\(p.mtuPayload)")
}
do {
    let s = StreamSettings()
    s.mtuPayload = 8900
    let p = plan(s, linkMTU: 9000)
    check("a packet size the link can carry is not reported",
          p.overrideFor("Packet size") == nil)
    check("...and the plan really uses it", p.mtuPayload == 8900, "\(p.mtuPayload)")
}

UserDefaults.standard.removePersistentDomain(forName: testDomain)

print()
print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
