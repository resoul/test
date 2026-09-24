// swift-tools-version: 6.0

import PackageDescription

// LayoutCore depends only on Foundation, so the package builds and tests on Linux as well as
// on Apple platforms. LayoutUIKit and LayoutAppKit adapt it to views; on a platform without
// that framework they build as empty modules. StateCore is synchronous main-actor state with
// dependency tracking; StateFlux connects it to Flux streams, the package's one dependency.
// Nodes is the tree of nodes laid out by LayoutCore and driven by StateCore.
let package = Package(
    name: "Layout",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "LayoutUIKit", targets: ["LayoutUIKit"]),
        .library(name: "LayoutAppKit", targets: ["LayoutAppKit"]),
        .library(name: "StateCore", targets: ["StateCore"]),
        .library(name: "StateFlux", targets: ["StateFlux"]),
        .library(name: "Nodes", targets: ["Nodes"]),
    ],
    dependencies: [
        // The lowest release StateFlux works with: packages that also use Trellis, which pins
        // Flux 1.2.1, still resolve. On its own the package gets the newest release.
        .package(url: "https://github.com/resoul/flux.git", from: "1.2.1")
    ],
    targets: [
        .target(name: "LayoutCore"),
        .target(name: "LayoutUIKit", dependencies: ["LayoutCore"]),
        .target(name: "LayoutAppKit", dependencies: ["LayoutCore"]),
        .target(name: "StateCore"),
        .target(name: "Nodes", dependencies: ["LayoutCore", "StateCore"]),
        .target(
            name: "StateFlux",
            dependencies: ["StateCore", .product(name: "Flux", package: "flux")]
        ),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
        .testTarget(name: "StateCoreTests", dependencies: ["StateCore"]),
        .testTarget(name: "NodesTests", dependencies: ["Nodes", "LayoutCore", "StateCore"]),
        .testTarget(name: "StateFluxTests", dependencies: ["StateFlux", "StateCore"]),
        .testTarget(
            name: "LayoutAdapterTests",
            dependencies: ["LayoutCore", "LayoutUIKit", "LayoutAppKit"]
        ),
    ]
)
