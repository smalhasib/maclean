// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "maclean",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacleanCore", targets: ["MacleanCore"]),
        .executable(name: "maclean-scan", targets: ["maclean-scan"]),
    ],
    targets: [
        .target(name: "MacleanCore"),
        .executableTarget(name: "maclean-scan", dependencies: ["MacleanCore"]),
        .testTarget(name: "MacleanCoreTests", dependencies: ["MacleanCore"]),
    ]
)
