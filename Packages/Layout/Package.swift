// swift-tools-version: 6.0

import PackageDescription

// Layout with no dependencies outside Foundation and the platform frameworks.
// FlexEngine is the engine: CSS flexbox and absolute positioning as pure functions over Sendable
// trees; it builds on Linux. LayoutCore is the declarative layer over it — specs placing
// elements on the main actor, spacing and breakpoint scales. ThemeCore is the theme for
// layouts and views. LayoutUIKit and LayoutAppKit put specs into views; on a platform without
// that framework they build as empty modules.
let package = Package(
    name: "Layout",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "FlexEngine", targets: ["FlexEngine"]),
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "ThemeCore", targets: ["ThemeCore"]),
        .library(name: "LayoutUIKit", targets: ["LayoutUIKit"]),
        .library(name: "LayoutAppKit", targets: ["LayoutAppKit"]),
    ],
    targets: [
        .target(name: "FlexEngine"),
        .target(name: "LayoutCore", dependencies: ["FlexEngine"]),
        .target(name: "ThemeCore", dependencies: ["LayoutCore"]),
        .target(name: "LayoutUIKit", dependencies: ["FlexEngine", "LayoutCore", "ThemeCore"]),
        .target(name: "LayoutAppKit", dependencies: ["FlexEngine", "LayoutCore", "ThemeCore"]),
        .testTarget(name: "FlexEngineTests", dependencies: ["FlexEngine"]),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore", "FlexEngine"]),
        .testTarget(name: "ThemeCoreTests", dependencies: ["ThemeCore", "LayoutCore"]),
        .testTarget(
            name: "LayoutAdapterTests",
            dependencies: ["FlexEngine", "LayoutCore", "LayoutUIKit", "LayoutAppKit", "ThemeCore"]
        ),
    ]
)
