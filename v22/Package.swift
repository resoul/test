// swift-tools-version: 6.0

import PackageDescription

// V22Layout depends only on Foundation, so the package builds and tests on Linux as well as
// on Apple platforms.
let package = Package(
    name: "V22",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "V22Layout", targets: ["V22Layout"])
    ],
    targets: [
        .target(name: "V22Layout"),
        .testTarget(name: "V22LayoutTests", dependencies: ["V22Layout"]),
    ]
)
