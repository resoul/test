// swift-tools-version: 6.0

import PackageDescription

// LayoutCore depends only on Foundation, so the package builds and tests on Linux as well as
// on Apple platforms.
let package = Package(
    name: "Layout",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"])
    ],
    targets: [
        .target(name: "LayoutCore"),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
    ]
)
