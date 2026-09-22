// swift-tools-version:5.7
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
