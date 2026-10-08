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

import SwiftUI
import AppKit
import LSProtocol

/// `LanScreenHost --render-ui <dir>` draws the menu bar panel and the settings
/// window straight to PNG and exits, without opening either. It exists so the
/// look can be checked and re-checked without a person having to click the
/// status item and describe what they see — the same reason the rest of this
/// project measures rather than assumes.
enum UISnapshot {
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--render-ui"),
              args.index(after: flag) < args.endIndex else { return false }
        let directory = URL(fileURLWithPath: args[args.index(after: flag)])

        // StreamSettings saves every change to the real preferences, and this
        // sets things -- Video mode, a packet size -- to put the panel in the
        // states worth looking at. Run from the app bundle that domain is the
        // user's own, so without this a snapshot quietly turned Video mode on
        // for the next real launch. Put everything back exactly as found.
        let domain = Bundle.main.bundleIdentifier ?? "com.lanscreen.host"
        let saved = UserDefaults.standard.persistentDomain(forName: domain)
        defer {
            if let saved {
                UserDefaults.standard.setPersistentDomain(saved, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
        }

        let settings = StreamSettings()
        let controller = StreamController(settings: settings)

        write(MenuBarPanel(settings: settings, controller: controller),
              to: directory.appendingPathComponent("panel-idle.png"),
              width: 372)

        // 8900 against a 1500 link, which is the state the hint exists for.
        settings.mtuPayload = 8900
        controller.applyPreviewState()
        write(MenuBarPanel(settings: settings, controller: controller),
              to: directory.appendingPathComponent("panel-running.png"),
              width: 372)

        // Video mode above the Level 4.2 ceiling with the client reporting
        // software decode: the one state the level note exists for, and so
        // the one that would otherwise never be looked at before it matters.
        settings.videoMode = true
        settings.videoBitrateMbps = 120
        controller.applyPreviewState(decoderFlags: UInt32(LS_DECODER_KNOWN))
        write(MenuBarPanel(settings: settings, controller: controller),
              to: directory.appendingPathComponent("panel-software-decode.png"),
              width: 372)

        // The status item glyph is hand-drawn, so it gets checked too, blown
        // up eight times so the gloss and the lamp are actually visible.
        write(HStack(spacing: 14) {
                  ForEach([false, true], id: \.self) { running in
                      ForEach(running ? [false, true] : [false], id: \.self) { attention in
                          Image(nsImage: Aero.menuBarIcon(running: running, attention: attention))
                              .renderingMode(.original)
                              .interpolation(.none)
                              .resizable()
                              .frame(width: 152, height: 128)
                      }
                  }
              }
              .padding(16)
              .background(Color(white: 0.92)),
              to: directory.appendingPathComponent("menubar-icon.png"),
              width: 200)

        write(SettingsView(settings: settings, controller: controller)
                .frame(width: 600, height: 1180),
              to: directory.appendingPathComponent("window.png"),
              width: 600)

        return true
    }

    private static func write<V: View>(_ view: V, to url: URL, width: CGFloat) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        if host.frame.width < width {
            host.frame.size.width = width
        }
        host.layoutSubtreeIfNeeded()

        // An offscreen window gives the hosting view a real backing store;
        // cacheDisplay on a detached view comes back empty.
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        FileHandle.standardError.write(
            "wrote \(url.lastPathComponent) \(Int(host.bounds.width))x\(Int(host.bounds.height))\n"
                .data(using: .utf8)!)
    }
}
