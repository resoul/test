// swift-tools-version: 6.0

import PackageDescription

// LayoutCore depends only on Foundation, so the package builds and tests on Linux as well as
// on Apple platforms. LayoutUIKit and LayoutAppKit adapt it to views; on a platform without
// that framework they build as empty modules.
let package = Package(
    name: "Layout",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "LayoutUIKit", targets: ["LayoutUIKit"]),
        .library(name: "LayoutAppKit", targets: ["LayoutAppKit"]),
        .library(name: "StateCore", targets: ["StateCore"]),
    ],
    targets: [
        .target(name: "LayoutCore"),
        .target(name: "LayoutUIKit", dependencies: ["LayoutCore"]),
        .target(name: "LayoutAppKit", dependencies: ["LayoutCore"]),
        .target(name: "StateCore"),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
        .testTarget(name: "StateCoreTests", dependencies: ["StateCore"]),
        .testTarget(
            name: "LayoutAdapterTests",
            dependencies: ["LayoutCore", "LayoutUIKit", "LayoutAppKit"]
        ),
    ]
)
