// swift-tools-version:5.9
// asbuilt-recon: Mac companion for AsBuilt. Rebuilds Object Capture photo sets at the highest
// detail Apple's PhotogrammetrySession allows (full / raw / custom 8K), which iPhones can't do.
// Self-contained on purpose: no dependency on AsBuiltCore.
import PackageDescription

let package = Package(
    name: "asbuilt-recon",
    // macOS 14: custom detail, requestProgressInfo, checkpoints. 15+ features are #available-gated.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "asbuilt-recon", targets: ["asbuilt-recon"]),
    ],
    targets: [
        .target(name: "ReconKit"),
        .executableTarget(name: "asbuilt-recon", dependencies: ["ReconKit"]),
        .testTarget(name: "ReconKitTests", dependencies: ["ReconKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
