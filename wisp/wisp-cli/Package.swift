// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wisp-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../WispAI"),
    ],
    targets: [
        .executableTarget(
            name: "wisp",
            dependencies: [
                .product(name: "WispAI", package: "WispAI"),
            ],
            path: "Sources/wisp"
        ),
    ]
)
