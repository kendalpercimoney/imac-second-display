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

@main
struct LanScreenHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = StreamSettings()
    @StateObject private var controller: StreamController

    init() {
        let settings = StreamSettings()
        _settings = StateObject(wrappedValue: settings)
        let controller = StreamController(settings: settings)
        _controller = StateObject(wrappedValue: controller)
        UnattendedRun.begin(settings: settings, controller: controller)
    }

    var body: some Scene {
        // The menu bar is the app. There is no window scene at all, because a
        // SwiftUI `Window` opens itself at launch and this is not a thing you
        // want a window for — the settings window is built on demand instead.
        MenuBarExtra {
            MenuBarPanel(settings: settings, controller: controller)
                .task { await controller.refreshDisplays() }
        } label: {
            Image(nsImage: Aero.menuBarIcon(
                running: controller.isRunning,
                attention: controller.lastError != nil
                    || (controller.isRunning && !controller.client.hasSaidHello)))
                .renderingMode(.original)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Runs as an accessory: no Dock icon, no menu bar of its own, just the status
/// item. It becomes a regular app for as long as the settings window is open,
/// so that window gets a real Edit menu — without one there is no Paste, and
/// the MAC address field exists specifically to have something pasted into it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UISnapshot.runIfRequested() { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(UnattendedRun.wantsWindow ? .regular : .accessory)

        // After the scene is up, so the icon the box is pointing at is already
        // there when the box is dismissed.
        DispatchQueue.main.async { Self.announceTheMenuBar() }
    }

    /// Says where the app went.
    ///
    /// An accessory app has no Dock icon and opens no window, so launching it
    /// looks exactly like launching nothing. On a laptop with a notch the icon
    /// may also be the far side of it, or pushed out of the menu bar entirely
    /// by whatever else is up there, and then there is genuinely nothing to see
    /// anywhere on screen.
    ///
    /// So the box carries the icon itself, at a size you can actually make out,
    /// rather than describing it.
    private static func announceTheMenuBar() {
        guard !UnattendedRun.wantsWindow else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "ls.hideLaunchNotice") else { return }

        let alert = NSAlert()
        alert.messageText = "LanScreen is running, in the menu bar"
        alert.informativeText =
            "There is no Dock icon and no window. Click this icon at the top of "
            + "the screen to start streaming, reach Settings, or quit.\n\n"
            + "If you cannot find it, the menu bar may be full — macOS hides the "
            + "items that do not fit, and on a Mac with a notch they go behind it."
        alert.icon = Aero.menuBarIcon(running: false, attention: false, scale: 6)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: "ls.hideLaunchNotice")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The settings window, built by hand rather than as a SwiftUI scene so that it
/// exists only once it is asked for.
enum HostWindows {
    private static var settings: NSWindow?
    private static var observer: NSObjectProtocol?

    static func showSettings(settings streamSettings: StreamSettings,
                             controller: StreamController) {
        if settings == nil {
            let view = SettingsView(settings: streamSettings, controller: controller)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "LanScreen Host"
            window.contentView = NSHostingView(rootView: view)
            window.contentMinSize = NSSize(width: 560, height: 480)
            window.isReleasedWhenClosed = false
            // Aero has no dark mode, so the window is pinned light and the
            // titlebar is left to blend into the glass behind it.
            window.appearance = NSAppearance(named: .aqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 0.91, green: 0.96, blue: 1.0, alpha: 1)
            window.center()
            settings = window

            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    // Back to an accessory once it is gone, or the Dock icon
                    // outlives the only window that justified it. Except under
                    // --with-window, where staying a regular app is the point.
                    if !UnattendedRun.wantsWindow { NSApp.setActivationPolicy(.accessory) }
                }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}
