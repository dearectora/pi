// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "Wisp", targets: ["Wisp"]),
    ],
    targets: [
        .target(
            name: "Wisp",
            path: "Sources/Wisp"
        ),
        .testTarget(
            name: "WispTests",
            dependencies: ["Wisp"],
            path: "Tests/WispTests"
        ),
    ]
)
