// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LegacyCore",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "LegacyCore", targets: ["LegacyCore"])],
    targets: [
        .target(name: "CStoreIO"),
        .target(name: "LegacyCore", dependencies: ["CStoreIO"]),
        .testTarget(name: "LegacyCoreTests", dependencies: ["LegacyCore"])
    ]
)
