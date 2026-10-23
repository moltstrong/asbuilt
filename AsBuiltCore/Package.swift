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
        // Optimized even in Debug: the Simulator demo runs real depth fusion (18 frames) and the coach
        // preview fuses a partial volume at launch; unoptimized that is ~25x slower (250 ms/frame).
        .target(name: "AsBuiltCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "AsBuiltCoreTests", dependencies: ["AsBuiltCore"]),
    ]
)
