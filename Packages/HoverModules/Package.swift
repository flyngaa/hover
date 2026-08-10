// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HoverModules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HoverCore", targets: ["HoverCore"]),
        .library(name: "HoverPlatform", targets: ["HoverPlatform"]),
    ],
    targets: [
        .target(
            name: "HoverCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "HoverPlatform",
            dependencies: ["HoverCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "HoverCoreTests",
            dependencies: ["HoverCore"]
        ),
        .testTarget(
            name: "HoverPlatformTests",
            dependencies: ["HoverCore", "HoverPlatform"]
        ),
    ]
)
