// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AsBuiltCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AsBuiltCore", targets: ["AsBuiltCore"]),
    ],
    targets: [
        .target(name: "AsBuiltCore"),
        .testTarget(name: "AsBuiltCoreTests", dependencies: ["AsBuiltCore"]),
    ]
)
