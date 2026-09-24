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

import AppKit
import Foundation

/// Lets the app be run without anyone clicking it, which is the only way to
/// measure something that takes ten minutes to show up.
///
///     --autostart            start streaming as soon as it launches
///     --quit-after <seconds> and then quit
///     --with-window          run as a regular app with the settings window
///                            open, the way it behaved before it moved into
///                            the menu bar
///
/// `--with-window` exists to answer one question: whether having no window is
/// what changed. Same binary, same settings, same everything else.
enum UnattendedRun {
    private static let args = ProcessInfo.processInfo.arguments

    static func has(_ flag: String) -> Bool { args.contains(flag) }

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex
        else { return nil }
        return args[args.index(after: i)]
    }

    static var wantsWindow: Bool { has("--with-window") }

    static func begin(settings: StreamSettings, controller: StreamController) {
        if wantsWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                HostWindows.showSettings(settings: settings, controller: controller)
            }
        }
        if has("--autostart") {
            // A moment for the scene to come up first, so this is not racing
            // the status item into existence.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.start()
            }
        }
        if let seconds = value("--quit-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                controller.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
