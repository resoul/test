// swift-tools-version: 6.0
import PackageDescription

// Measurement harness for C31 — a consumer package, like the Smoke consumer that
// verify_bootstrap.py generates, so the Trellis manifest keeps its five-library target graph
// (Core/Render/UIKit/AppKit/Flux, R02). Bench measures solver/diff/raster and stays a plain
// two-product consumer; it does not need TrellisFlux (Scripts/verify_bootstrap.py's
// PRODUCTS/manifest_issues is where the exact product count is actually checked).
// Build and run it through Scripts/bench.py (Release, TRELLIS_LOG=off).
let package = Package(
    name: "TrellisBench",
    platforms: [.macOS(.v14)],
    // `name:`: `package: "Trellis"` must not depend on the checkout directory's name (#94).
    dependencies: [.package(name: "Trellis", path: "..")],
    targets: [
        .executableTarget(
            name: "TrellisBench",
            dependencies: [
                .product(name: "TrellisCore", package: "Trellis"),
                .product(name: "TrellisRender", package: "Trellis"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
