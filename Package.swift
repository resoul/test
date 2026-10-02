// swift-tools-version: 6.0

import PackageDescription

// LayoutCore depends only on Foundation, so the package builds and tests on Linux as well as
// on Apple platforms. LayoutUIKit and LayoutAppKit adapt it to views; on a platform without
// that framework they build as empty modules. StateCore is synchronous main-actor state with
// dependency tracking; StateAsyncRay connects it to AsyncRay streams, the package's dependency.
// RichTextCore is styled text as a value — blocks, runs, marks — with the operations an editor
// needs; it depends on Foundation only, so it builds on Linux too.
// StorageCore is preferences as typed keys over a store protocol, with an in-memory store;
// StorageFoundation keeps them in UserDefaults. Both depend on Foundation only. StorageGRDB is
// the SQLite database — migrations, transactions, observation, backup — over GRDB, the one
// target that imports it. NetworkCore is an HTTP client over a transport protocol — statuses,
// retries, credentials — and depends on Foundation only; NetworkFoundation is the URLSession
// transport. DataAsyncRay turns the observations of the storage and network layers into AsyncRay
// streams, whose subscriptions end the observation; SyncDemo is a worked example that joins
// them — a repository over the database, HTTP and a socket, and a model for the screens.
// PermissionCore is what the app knows about the system's permissions — kinds, status, errors, and
// one order of asking — with a stand-in for tests; it depends on Foundation only.
// Nodes is the tree of nodes laid out by LayoutCore and driven by StateCore; NodesRender draws
// it into CALayers (Apple platforms), NodesUIKit and NodesAppKit put it into views. ThemeCore
// holds the theme — colors, text, radii, motion, spacing and breakpoints — for nodes and for
// plain views alike; it depends on LayoutCore only, so it builds on Linux too. AppShell is the
// app layer — screens and navigation stacks — over Nodes, without UIKit or AppKit;
// AppShellUIKit and AppShellAppKit show it in the platform's containers.
let package = Package(
    name: "Espalier",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "LayoutCore", targets: ["LayoutCore"]),
        .library(name: "ThemeCore", targets: ["ThemeCore"]),
        .library(name: "LayoutUIKit", targets: ["LayoutUIKit"]),
        .library(name: "LayoutAppKit", targets: ["LayoutAppKit"]),
        .library(name: "StateCore", targets: ["StateCore"]),
        .library(name: "StateAsyncRay", targets: ["StateAsyncRay"]),
        .library(name: "RichTextCore", targets: ["RichTextCore"]),
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .library(name: "StorageFoundation", targets: ["StorageFoundation"]),
        .library(name: "StorageGRDB", targets: ["StorageGRDB"]),
        .library(name: "DataAsyncRay", targets: ["DataAsyncRay"]),
        .library(name: "SyncDemo", targets: ["SyncDemo"]),
        .library(name: "PermissionCore", targets: ["PermissionCore"]),
        .library(name: "NetworkCore", targets: ["NetworkCore"]),
        .library(name: "NetworkFoundation", targets: ["NetworkFoundation"]),
        .library(name: "Nodes", targets: ["Nodes"]),
        .library(name: "NodesRender", targets: ["NodesRender"]),
        .library(name: "NodesUIKit", targets: ["NodesUIKit"]),
        .library(name: "NodesAppKit", targets: ["NodesAppKit"]),
        .library(name: "AppShell", targets: ["AppShell"]),
        .library(name: "AppShellUIKit", targets: ["AppShellUIKit"]),
        .library(name: "AppShellAppKit", targets: ["AppShellAppKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/resoul/AsyncRay.git", exact: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "LayoutCore"),
        .target(name: "ThemeCore", dependencies: ["LayoutCore"]),
        .target(name: "LayoutUIKit", dependencies: ["LayoutCore", "ThemeCore"]),
        .target(name: "LayoutAppKit", dependencies: ["LayoutCore", "ThemeCore"]),
        .target(name: "StateCore"),
        .target(name: "RichTextCore"),
        .target(name: "StorageCore"),
        .target(name: "StorageFoundation", dependencies: ["StorageCore"]),
        .target(name: "StorageGRDB", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(
            name: "DataAsyncRay",
            dependencies: [
                "StorageCore", "StorageGRDB", "NetworkCore",
                .product(name: "AsyncRay", package: "asyncray"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "SyncDemo",
            dependencies: [
                "DataAsyncRay", "StateCore", "StateAsyncRay", "StorageCore", "StorageGRDB",
                "NetworkCore",
                .product(name: "AsyncRay", package: "asyncray"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "PermissionCore"),
        .target(name: "NetworkCore"),
        .target(name: "NetworkFoundation", dependencies: ["NetworkCore"]),
        .target(name: "Nodes", dependencies: ["LayoutCore", "StateCore", "ThemeCore"]),
        .target(
            name: "NodesRender",
            dependencies: ["Nodes", "LayoutCore", "StateCore", "ThemeCore", "RichTextCore"]
        ),
        .target(
            name: "NodesUIKit",
            dependencies: [
                "Nodes", "NodesRender", "LayoutCore", "LayoutUIKit", "StateCore", "ThemeCore",
            ]
        ),
        .target(
            name: "NodesAppKit",
            dependencies: ["Nodes", "NodesRender", "LayoutCore", "LayoutAppKit", "ThemeCore"]
        ),
        .target(name: "AppShell", dependencies: ["Nodes", "StateCore"]),
        .target(
            name: "AppShellUIKit",
            dependencies: ["AppShell", "Nodes", "NodesUIKit", "StateCore"]
        ),
        .target(
            name: "AppShellAppKit",
            dependencies: ["AppShell", "Nodes", "NodesAppKit", "StateCore"]
        ),
        .target(
            name: "StateAsyncRay",
            dependencies: ["StateCore", .product(name: "AsyncRay", package: "asyncray")]
        ),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
        .testTarget(name: "ThemeCoreTests", dependencies: ["ThemeCore", "LayoutCore"]),
        .testTarget(name: "StateCoreTests", dependencies: ["StateCore"]),
        .testTarget(name: "RichTextCoreTests", dependencies: ["RichTextCore"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
        .testTarget(
            name: "StorageFoundationTests",
            dependencies: ["StorageFoundation", "StorageCore"]
        ),
        .testTarget(
            name: "NodesTests",
            dependencies: ["Nodes", "LayoutCore", "StateCore", "ThemeCore"]
        ),
        .testTarget(
            name: "NodesRenderTests",
            dependencies: [
                "Nodes", "NodesRender", "NodesUIKit", "NodesAppKit", "LayoutCore", "ThemeCore",
                "RichTextCore",
            ]
        ),
        .testTarget(
            name: "StateAsyncRayTests",
            dependencies: ["AsyncRay", "StateAsyncRay", "StateCore"]
        ),
        .testTarget(
            name: "StorageGRDBTests",
            dependencies: ["StorageGRDB", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "DataAsyncRayTests",
            dependencies: [
                "DataAsyncRay", "StorageCore", "StorageGRDB", "NetworkCore",
                .product(name: "AsyncRay", package: "asyncray"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SyncDemoTests",
            dependencies: [
                "SyncDemo", "StateCore", "StorageCore", "StorageGRDB", "StorageFoundation",
                "NetworkCore",
                .product(name: "AsyncRay", package: "asyncray"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "PermissionCoreTests", dependencies: ["PermissionCore"]),
        .testTarget(name: "NetworkCoreTests", dependencies: ["NetworkCore"]),
        .testTarget(
            name: "NetworkFoundationTests",
            dependencies: ["NetworkFoundation", "NetworkCore"]
        ),
        .testTarget(name: "AppShellTests", dependencies: ["AppShell", "Nodes", "StateCore"]),
        .testTarget(
            name: "AppShellAdapterTests",
            dependencies: [
                "AppShell", "AppShellUIKit", "AppShellAppKit", "Nodes", "NodesUIKit",
                "NodesAppKit", "LayoutCore", "StateCore",
            ]
        ),
        .testTarget(
            name: "LayoutAdapterTests",
            dependencies: ["LayoutCore", "LayoutUIKit", "LayoutAppKit", "ThemeCore"]
        ),
    ]
)
