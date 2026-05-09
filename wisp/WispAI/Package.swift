// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WispAI",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "WispAI", targets: ["WispAI"]),
    ],
    targets: [
        .target(
            name: "WispAI",
            path: "Sources/WispAI"
        ),
        .testTarget(
            name: "WispAITests",
            dependencies: ["WispAI"],
            path: "Tests/WispAITests"
        ),
    ]
)
