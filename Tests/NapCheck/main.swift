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

// Does an app with no window get throttled, and does a window stop it?
//
// Moving the host into the menu bar changed exactly one thing about how the OS
// sees the process: it no longer has a window. That is one of the conditions
// App Nap looks for, and App Nap does not apply immediately — which matches a
// report of the stream being fine at first and worse a few minutes in.
//
// Three configurations, run at the same time so they share the same machine
// and the same conditions:
//
//   plain      accessory, no window, no activity assertion
//   accessory  accessory, no window, with the assertion   <- the app as shipped
//   window     regular, visible window, with the assertion <- the app before
//
// Each one runs a 120 Hz timer on a user-interactive queue, which is what the
// capture and encode path is really made of, and measures two things: whether
// the timer fires when it should, and whether a fixed slice of arithmetic still
// takes as long as it did at the start. Timer coalescing shows up in the first;
// being moved to the efficiency cores shows up in the second.

import Foundation
import AppKit

let args = ProcessInfo.processInfo.arguments
func value(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex
    else { return fallback }
    return args[args.index(after: i)]
}

let mode = value("--mode", "accessory")
let minutes = Double(value("--minutes", "8")) ?? 8
let logPath = value("--log", "/tmp/napcheck-\(mode).log")

let log = FileHandle(forWritingAtPath: logPath) ?? {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    return FileHandle(forWritingAtPath: logPath)!
}()

func say(_ line: String) {
    log.write((line + "\n").data(using: .utf8)!)
    try? log.synchronize()
}

// MARK: - the fixed slice of work
//
// Deliberately plain scalar arithmetic with a data dependency, so it cannot be
// vectorised away and so its duration reflects the clock it is running on.
@inline(never)
func fixedWork(_ rounds: Int) -> Double {
    var x = 1.000001
    for _ in 0..<rounds { x = x * 1.0000001 + 0.0000001 }
    return x
}

// Fixed, not calibrated. Calibrating per process was the first version of this
// and it was useless: each of the three picked a different workload, so their
// work times could not be compared with each other, which is the entire point.
// This is about a millisecond on an M1 Pro performance core.
let rounds = 250_000

let app = NSApplication.shared

switch mode {
case "window":
    app.setActivationPolicy(.regular)
default:
    app.setActivationPolicy(.accessory)
}

var token: NSObjectProtocol?
if mode != "plain" {
    token = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "nap check")
}

var window: NSWindow?
if mode == "window" {
    // Visible, but it must not steal focus: the whole question is what happens
    // to an app the user is not looking at.
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 70),
                     styleMask: [.titled], backing: .buffered, defer: false)
    w.title = "nap check"
    if let screen = NSScreen.main {
        w.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 260,
                                 y: screen.visibleFrame.maxY - 100))
    }
    w.orderFrontRegardless()
    window = w
}

let interval = 1.0 / 120.0
let deadline = 1.5 * interval * 1000.0   // ms; a fire later than this is late
var intervals: [Double] = []
var workTimes: [Double] = []
var late = 0
var last = Date()
let started = Date()
var nextReport = 30.0

say("mode=\(mode) rounds=\(rounds) minutes=\(minutes) started=\(started)")

let queue = DispatchQueue(label: "napcheck", qos: .userInteractive)
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
timer.setEventHandler {
    let now = Date()
    let gap = now.timeIntervalSince(last) * 1000.0
    last = now
    intervals.append(gap)
    if gap > deadline { late += 1 }

    let w0 = Date()
    _ = fixedWork(rounds)
    workTimes.append(Date().timeIntervalSince(w0) * 1000.0)

    let elapsed = now.timeIntervalSince(started)
    if elapsed >= nextReport {
        nextReport += 30.0
        func pct(_ xs: [Double], _ p: Double) -> Double {
            guard !xs.isEmpty else { return 0 }
            let s = xs.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        say(String(format:
            "mode=%@ t=%4.0fs fires=%5d late=%4d  gap p50=%5.2f p95=%6.2f max=%7.2f  "
            + "work p50=%5.3f p95=%6.3f max=%7.3f",
            mode, elapsed, intervals.count, late,
            pct(intervals, 0.5), pct(intervals, 0.95), intervals.max() ?? 0,
            pct(workTimes, 0.5), pct(workTimes, 0.95), workTimes.max() ?? 0))
        intervals.removeAll(keepingCapacity: true)
        workTimes.removeAll(keepingCapacity: true)
        late = 0
    }

    if elapsed >= minutes * 60 {
        say("mode=\(mode) done")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
timer.resume()

_ = window
_ = token
app.run()
