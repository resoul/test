// swift-tools-version: 6.0

import PackageDescription

// The packages' observations as AsyncRay streams. A package of its own so that AsyncRay is
// fetched only by those who use the streams. StateAsyncRay connects state to streams;
// DataAsyncRay turns the observations of the storage and network layers into streams whose
// subscriptions end the observation; PermissionAsyncRay offers a permission's status as a
// stream. SyncDemo is a worked example that joins them — a repository over the database, HTTP
// and a socket, and a model for the screens; it is a target for its tests, not a product.
let package = Package(
    name: "AsyncRayBridges",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "StateAsyncRay", targets: ["StateAsyncRay"]),
        .library(name: "DataAsyncRay", targets: ["DataAsyncRay"]),
        .library(name: "PermissionAsyncRay", targets: ["PermissionAsyncRay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/resoul/AsyncRay.git", exact: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(path: "../Basics"),
        .package(path: "../Data"),
        .package(path: "../Database"),
        .package(path: "../Permissions"),
    ],
    targets: [
        .target(
            name: "StateAsyncRay",
            dependencies: [
                .product(name: "StateCore", package: "Basics"),
                .product(name: "AsyncRay", package: "AsyncRay"),
            ]
        ),
        .target(
            name: "DataAsyncRay",
            dependencies: [
                .product(name: "StorageCore", package: "Data"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "StorageGRDB", package: "Database"),
                .product(name: "AsyncRay", package: "AsyncRay"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "PermissionAsyncRay",
            dependencies: [
                .product(name: "PermissionCore", package: "Permissions"),
                .product(name: "AsyncRay", package: "AsyncRay"),
            ]
        ),
        .target(
            name: "SyncDemo",
            dependencies: [
                "DataAsyncRay", "StateAsyncRay",
                .product(name: "StateCore", package: "Basics"),
                .product(name: "StorageCore", package: "Data"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "StorageGRDB", package: "Database"),
                .product(name: "AsyncRay", package: "AsyncRay"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "StateAsyncRayTests",
            dependencies: [
                "StateAsyncRay", .product(name: "StateCore", package: "Basics"),
                .product(name: "AsyncRay", package: "AsyncRay"),
            ]
        ),
        .testTarget(
            name: "DataAsyncRayTests",
            dependencies: [
                "DataAsyncRay",
                .product(name: "StorageCore", package: "Data"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "StorageGRDB", package: "Database"),
                .product(name: "AsyncRay", package: "AsyncRay"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PermissionAsyncRayTests",
            dependencies: [
                "PermissionAsyncRay", .product(name: "PermissionCore", package: "Permissions"),
                .product(name: "AsyncRay", package: "AsyncRay"),
            ]
        ),
        .testTarget(
            name: "SyncDemoTests",
            dependencies: [
                "SyncDemo",
                .product(name: "StateCore", package: "Basics"),
                .product(name: "StorageCore", package: "Data"),
                .product(name: "StorageFoundation", package: "Data"),
                .product(name: "NetworkCore", package: "Data"),
                .product(name: "StorageGRDB", package: "Database"),
                .product(name: "AsyncRay", package: "AsyncRay"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
