// swift-tools-version: 6.0

import PackageDescription

// The node tree and the app layer over the layout package.
// Nodes is the tree of nodes laid out by FlexEngine and LayoutCore and driven by StateCore;
// NodesRender draws it into CALayers (Apple platforms) and loads images through the HTTP cache
// validators and shared loads of the data package. NodesUIKit and NodesAppKit put it into
// views. AppShell is the app layer — screens and navigation stacks — without UIKit or AppKit;
// AppShellUIKit and AppShellAppKit show it in the platform's containers.
let package = Package(
    name: "NodesUI",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "Nodes", targets: ["Nodes"]),
        .library(name: "NodesRender", targets: ["NodesRender"]),
        .library(name: "NodesUIKit", targets: ["NodesUIKit"]),
        .library(name: "NodesAppKit", targets: ["NodesAppKit"]),
        .library(name: "AppShell", targets: ["AppShell"]),
        .library(name: "AppShellUIKit", targets: ["AppShellUIKit"]),
        .library(name: "AppShellAppKit", targets: ["AppShellAppKit"]),
    ],
    dependencies: [
        .package(path: "../Layout"),
        .package(path: "../Basics"),
        .package(path: "../Data"),
    ],
    targets: [
        .target(
            name: "Nodes",
            dependencies: [
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "LocalizationCore", package: "Basics"),
                .product(name: "Tracing", package: "Basics"),
            ]
        ),
        .target(
            name: "NodesRender",
            dependencies: [
                "Nodes",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "RichTextCore", package: "Basics"),
                .product(name: "LocalizationCore", package: "Basics"),
                .product(name: "Tracing", package: "Basics"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "StorageCore", package: "Data"),
            ]
        ),
        .target(
            name: "NodesUIKit",
            dependencies: [
                "Nodes", "NodesRender",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "LayoutUIKit", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
            ]
        ),
        .target(
            name: "NodesAppKit",
            dependencies: [
                "Nodes", "NodesRender",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "LayoutAppKit", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
            ]
        ),
        .target(
            name: "AppShell",
            dependencies: ["Nodes", .product(name: "StateCore", package: "Basics")]
        ),
        .target(
            name: "AppShellUIKit",
            dependencies: [
                "AppShell", "Nodes", "NodesUIKit", .product(name: "StateCore", package: "Basics"),
            ]
        ),
        .target(
            name: "AppShellAppKit",
            dependencies: [
                "AppShell", "Nodes", "NodesAppKit", .product(name: "StateCore", package: "Basics"),
            ]
        ),
        .testTarget(
            name: "NodesTests",
            dependencies: [
                "Nodes",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "Tracing", package: "Basics"),
            ]
        ),
        .testTarget(
            name: "NodesRenderTests",
            dependencies: [
                "Nodes", "NodesRender", "NodesUIKit", "NodesAppKit",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "RichTextCore", package: "Basics"),
                .product(name: "LocalizationCore", package: "Basics"),
            ]
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", "Nodes", .product(name: "StateCore", package: "Basics")]
        ),
        .testTarget(
            name: "AppShellAdapterTests",
            dependencies: [
                "AppShell", "AppShellUIKit", "AppShellAppKit", "Nodes", "NodesUIKit",
                "NodesAppKit",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
            ]
        ),
    ]
)
