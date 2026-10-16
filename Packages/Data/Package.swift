// swift-tools-version: 6.0

import PackageDescription

// Storage and network over Foundation, with no third-party dependencies.
// StorageCore is preferences as typed keys over a store protocol, file stores, caches and
// shared loads, with in-memory stand-ins; StorageFoundation keeps them in UserDefaults and on
// disk. NetworkCore is an HTTP and WebSocket client over a transport protocol — statuses,
// retries, credentials, cache validators; NetworkFoundation is the URLSession transport.
// NetworkStorage joins the two: it downloads an HTTP answer into a file store.
let package = Package(
    name: "Data",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .library(name: "StorageFoundation", targets: ["StorageFoundation"]),
        .library(name: "NetworkCore", targets: ["NetworkCore"]),
        .library(name: "NetworkFoundation", targets: ["NetworkFoundation"]),
        .library(name: "NetworkStorage", targets: ["NetworkStorage"]),
    ],
    targets: [
        .target(name: "StorageCore"),
        .target(name: "StorageFoundation", dependencies: ["StorageCore"]),
        .target(name: "NetworkCore"),
        .target(name: "NetworkFoundation", dependencies: ["NetworkCore"]),
        .target(name: "NetworkStorage", dependencies: ["NetworkCore", "StorageCore"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"]),
        .testTarget(
            name: "StorageFoundationTests",
            dependencies: ["StorageFoundation", "StorageCore"]
        ),
        .testTarget(name: "NetworkCoreTests", dependencies: ["NetworkCore"]),
        .testTarget(
            name: "NetworkFoundationTests",
            dependencies: ["NetworkFoundation", "NetworkCore"]
        ),
        .testTarget(
            name: "NetworkStorageTests",
            dependencies: ["NetworkStorage", "NetworkCore", "StorageCore", "StorageFoundation"]
        ),
    ]
)
