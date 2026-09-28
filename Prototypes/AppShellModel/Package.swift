// swift-tools-version: 6.0
// A prototype of the app layer's screens and navigation stack, to try the shape of the API
// before it becomes a module of the package. Not a product: nothing depends on it. The
// package it depends on is named by the folder it sits in, the repository's.
import PackageDescription

let package = Package(
    name: "AppShellModel",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "AppShellModel",
            dependencies: [
                .product(name: "Nodes", package: "test"),
                .product(name: "StateCore", package: "test"),
            ]
        ),
        .testTarget(
            name: "AppShellModelTests",
            dependencies: [
                "AppShellModel",
                .product(name: "Nodes", package: "test"),
                .product(name: "StateCore", package: "test"),
            ]
        ),
    ]
)
