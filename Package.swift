// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SeednoteCore",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [.library(name: "SeednoteCore", targets: ["SeednoteCore"])],
    targets: [
        .target(name: "SeednoteCore", path: "Core"),
        .testTarget(name: "SeednoteCoreTests", dependencies: ["SeednoteCore"], path: "Tests/SeednoteCoreTests")
    ]
)
