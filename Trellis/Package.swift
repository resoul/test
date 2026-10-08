// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trellis",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "TrellisCore", targets: ["TrellisCore"]),
        .library(name: "TrellisRender", targets: ["TrellisRender"]),
        .library(name: "TrellisUIKit", targets: ["TrellisUIKit"]),
        .library(name: "TrellisAppKit", targets: ["TrellisAppKit"]),
        .library(name: "TrellisFlux", targets: ["TrellisFlux"]),
    ],
    dependencies: [
        // Pinned exact release: only Flux 1.2.1 (defects #56-#59 fixed) is an allowed
        // dependency (Scripts/verify_bootstrap.py's manifest_issues). For local
        // development against an unreleased checkout, use `swift package edit Flux
        // --path ../old/flux` (documented in README.md); the published manifest here
        // must keep the remote exact pin.
        .package(url: "https://github.com/resoul/flux.git", exact: "1.2.1")
    ],
    targets: [
        .target(name: "TrellisCore"),
        .target(name: "TrellisRender", dependencies: ["TrellisCore"]),
        .target(name: "TrellisUIKit", dependencies: ["TrellisCore", "TrellisRender"]),
        .target(name: "TrellisAppKit", dependencies: ["TrellisCore", "TrellisRender"]),
        .target(
            name: "TrellisFlux",
            dependencies: [
                "TrellisCore", "TrellisRender",
                .product(name: "Flux", package: "flux"),
            ]
        ),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore"]),
        .testTarget(
            name: "TrellisRenderTests",
            dependencies: ["TrellisRender", "TrellisAppKit", "TrellisUIKit"]
        ),
        .testTarget(name: "TrellisFluxTests", dependencies: ["TrellisFlux"]),
    ],
    swiftLanguageModes: [.v6]
)
