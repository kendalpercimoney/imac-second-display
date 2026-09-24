// swift-tools-version:5.7
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

import PackageDescription

let package = Package(
    name: "LanScreen",
    platforms: [.macOS(.v13)],
    targets: [
        // The shared wire format. Compiled into the host here, and compiled
        // straight from Common/ by Client/build.sh for the 10.9 side.
        .target(
            name: "LSProtocol",
            path: "Common",
            publicHeadersPath: "include"
        ),
        // Private-API virtual display support, kept in Objective-C because the
        // CoreGraphics classes it talks to only exist at runtime.
        .target(
            name: "LSVirtualDisplay",
            path: "Host/VirtualDisplay",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "LanScreenHost",
            dependencies: ["LSProtocol", "LSVirtualDisplay"],
            path: "Host/Sources"
        ),
    ]
)
