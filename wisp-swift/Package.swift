// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wisp-swift",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wisp", targets: ["Wisp"]),
        .library(name: "WispAI", targets: ["WispAI"]),
    ],
    targets: [
        .target(
            name: "WispAI",
            path: "Sources/WispAI"
        ),
        .executableTarget(
            name: "Wisp",
            dependencies: ["WispAI"],
            path: "Sources/Wisp"
        ),
    ]
)
