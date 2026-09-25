// swift-tools-version: 6.0

import PackageDescription

// LayoutCore depends only on Foundation, so the package builds and tests on Linux as well as
// on Apple platforms. LayoutUIKit and LayoutAppKit adapt it to views; on a platform without
// that framework they build as empty modules. StateCore is synchronous main-actor state with
// dependency tracking; StateAsyncRay connects it to AsyncRay streams, the package's dependency.
// Nodes is the tree of nodes laid out by LayoutCore and driven by StateCore; NodesRender draws
// it into CALayers (Apple platforms), NodesUIKit and NodesAppKit put it into views.
let package = Package(
    name: "Espalier",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "LayoutUIKit", targets: ["LayoutUIKit"]),
        .library(name: "LayoutAppKit", targets: ["LayoutAppKit"]),
        .library(name: "StateCore", targets: ["StateCore"]),
        .library(name: "StateAsyncRay", targets: ["StateAsyncRay"]),
        .library(name: "Nodes", targets: ["Nodes"]),
        .library(name: "NodesRender", targets: ["NodesRender"]),
        .library(name: "NodesUIKit", targets: ["NodesUIKit"]),
        .library(name: "NodesAppKit", targets: ["NodesAppKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/resoul/AsyncRay.git", exact: "1.0.0")
    ],
    targets: [
        .target(name: "LayoutCore"),
        .target(name: "LayoutUIKit", dependencies: ["LayoutCore"]),
        .target(name: "LayoutAppKit", dependencies: ["LayoutCore"]),
        .target(name: "StateCore"),
        .target(name: "Nodes", dependencies: ["LayoutCore", "StateCore"]),
        .target(name: "NodesRender", dependencies: ["Nodes", "LayoutCore", "StateCore"]),
        .target(name: "NodesUIKit", dependencies: ["Nodes", "NodesRender", "LayoutCore"]),
        .target(name: "NodesAppKit", dependencies: ["Nodes", "NodesRender", "LayoutCore"]),
        .target(
            name: "StateAsyncRay",
            dependencies: ["StateCore", .product(name: "AsyncRay", package: "asyncray")]
        ),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
        .testTarget(name: "StateCoreTests", dependencies: ["StateCore"]),
        .testTarget(name: "NodesTests", dependencies: ["Nodes", "LayoutCore", "StateCore"]),
        .testTarget(
            name: "NodesRenderTests",
            dependencies: ["Nodes", "NodesRender", "NodesUIKit", "NodesAppKit", "LayoutCore"]
        ),
        .testTarget(
            name: "StateAsyncRayTests",
            dependencies: ["AsyncRay", "StateAsyncRay", "StateCore"]
        ),
        .testTarget(
            name: "LayoutAdapterTests",
            dependencies: ["LayoutCore", "LayoutUIKit", "LayoutAppKit"]
        ),
    ]
)
