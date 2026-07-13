// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NovelCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "NovelCore", targets: ["NovelCore"])
    ],
    targets: [
        .target(name: "NovelCore"),
        .testTarget(name: "NovelCoreTests", dependencies: ["NovelCore"])
    ]
)
