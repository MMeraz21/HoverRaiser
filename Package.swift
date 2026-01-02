// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HoverRaiser",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "HoverRaiser"
        ),
    ]
)
