// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteDisplayServer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RemoteDisplayServer",
            path: "Sources/RemoteDisplayServer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
