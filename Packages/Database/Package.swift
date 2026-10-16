// swift-tools-version: 6.0

import PackageDescription

// The SQLite database — migrations, transactions, observation, backup — over GRDB. It is a
// package of its own so that GRDB is fetched only by those who use the database.
let package = Package(
    name: "Database",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "StorageGRDB", targets: ["StorageGRDB"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "StorageGRDB", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(
            name: "StorageGRDBTests",
            dependencies: ["StorageGRDB", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
