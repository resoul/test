// swift-tools-version: 6.0

import PackageDescription

// The examples of every package's guide, compiled and run. Each example target depends only on
// the package it shows, so it proves that package works on its own; `TogetherExamples` and the
// package as a whole prove the packages resolve and work side by side.
let package = Package(
    name: "Examples",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    dependencies: [
        .package(path: "../Layout"),
        .package(path: "../Basics"),
        .package(path: "../Data"),
        .package(path: "../Database"),
        .package(path: "../Permissions"),
        .package(path: "../NodesUI"),
        .package(path: "../AsyncRayBridges"),
        .package(url: "https://github.com/resoul/AsyncRay.git", exact: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "LayoutExamples",
            dependencies: [
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "LayoutUIKit", package: "Layout"),
                .product(name: "LayoutAppKit", package: "Layout"),
            ]
        ),
        .target(
            name: "BasicsExamples",
            dependencies: [
                .product(name: "StateCore", package: "Basics"),
                .product(name: "RichTextCore", package: "Basics"),
                .product(name: "LocalizationCore", package: "Basics"),
                .product(name: "Tracing", package: "Basics"),
            ]
        ),
        .target(
            name: "DataExamples",
            dependencies: [
                .product(name: "StorageCore", package: "Data"),
                .product(name: "StorageFoundation", package: "Data"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "NetworkFoundation", package: "Data"),
                .product(name: "NetworkStorage", package: "Data"),
            ]
        ),
        .target(
            name: "DatabaseExamples",
            dependencies: [
                .product(name: "StorageGRDB", package: "Database"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "PermissionsExamples",
            dependencies: [
                .product(name: "PermissionCore", package: "Permissions"),
                .product(name: "PermissionSystem", package: "Permissions"),
                .product(name: "PermissionUIKit", package: "Permissions"),
                .product(name: "PermissionAppKit", package: "Permissions"),
            ]
        ),
        .target(
            name: "NodesUIExamples",
            dependencies: [
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "Nodes", package: "NodesUI"),
                .product(name: "NodesRender", package: "NodesUI"),
                .product(name: "NodesUIKit", package: "NodesUI"),
                .product(name: "NodesAppKit", package: "NodesUI"),
                .product(name: "AppShell", package: "NodesUI"),
                .product(name: "AppShellUIKit", package: "NodesUI"),
            ]
        ),
        .target(
            name: "StreamsExamples",
            dependencies: [
                .product(name: "StateCore", package: "Basics"),
                .product(name: "StorageCore", package: "Data"),
                .product(name: "PermissionCore", package: "Permissions"),
                .product(name: "StateAsyncRay", package: "AsyncRayBridges"),
                .product(name: "DataAsyncRay", package: "AsyncRayBridges"),
                .product(name: "PermissionAsyncRay", package: "AsyncRayBridges"),
                .product(name: "AsyncRay", package: "AsyncRay"),
            ]
        ),
        .target(
            name: "TogetherExamples",
            dependencies: [
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "StorageCore", package: "Data"),
                .product(name: "PermissionCore", package: "Permissions"),
                .product(name: "Nodes", package: "NodesUI"),
                .product(name: "StateAsyncRay", package: "AsyncRayBridges"),
                .product(name: "DataAsyncRay", package: "AsyncRayBridges"),
                .product(name: "PermissionAsyncRay", package: "AsyncRayBridges"),
                .product(name: "AsyncRay", package: "AsyncRay"),
            ]
        ),
        .testTarget(
            name: "ExamplesTests",
            dependencies: [
                "LayoutExamples", "BasicsExamples", "DataExamples", "DatabaseExamples",
                "PermissionsExamples", "NodesUIExamples", "StreamsExamples", "TogetherExamples",
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "StorageCore", package: "Data"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "PermissionCore", package: "Permissions"),
                .product(name: "Nodes", package: "NodesUI"),
                .product(name: "AppShell", package: "NodesUI"),
            ]
        ),
    ]
)
